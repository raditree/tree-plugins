import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'errors.dart';
import 'local_files.dart';
import 'workspace.dart';

/// 调一条执行站命令（核心 `station/command`）：生产接 `PluginChannel.command`，
/// 测试注入假实现。返回**命令 payload**（外层信封已被核心剥掉）。
typedef StationCommandCaller = Future<Map<String, dynamic>> Function(
  String command,
  Map<String, dynamic> arguments,
);

/// 一条 SSH 工作空间租约（插件进程内缓存；插件/执行站重启后失效）。
class SshLease {
  const SshLease({
    required this.leaseId,
    required this.root,
    required this.connId,
  });

  final String leaseId;
  final String root;
  final String connId;
}

/// SSH 工作空间的文件操作（经 `ssh_executor` 自建执行站）。
///
/// 覆盖与本机同形的**全部 13 条能力**：list / content / readBytes / write /
/// mkdir / delete / rename（`ssh.file.rename`，目标机 `fs.rename` 原子语义）/
/// pdf_info / download / upload / syncToLocal / download_folder（远端 tar + 分块回传）。
///
/// 大文件走**分块通道**：读用 `ssh.file.read{raw, offset, length}`（按 `eof` 收口），
/// 写用 `ssh.file.writeBytes{append}`，不再有 8 MiB 单次上限。
class RemoteFiles {
  RemoteFiles({
    required this.target,
    required this.call,
    required this.leases,
    this.log,
  });

  final WorkspaceTarget target;
  final StationCommandCaller call;
  final Map<String, SshLease> leases;
  final void Function(String message)? log;

  /// `content` 预览的单次读取上限（与 `LocalFiles.maxContentBytes` 同口径）。
  static const int maxReadBytes = 8 * 1024 * 1024;

  /// 文本保存上限（`content` 是 JSON 内联体，不适合走分块）。
  static const int maxWriteBytes = 4 * 1024 * 1024;

  /// 分块读：单次 `ssh.file.read` 请求的最大字节数。
  static const int readChunkBytes = 8 * 1024 * 1024;

  /// 分块写：单次 `ssh.file.writeBytes` 的最大字节数（base64 后会膨胀约 4/3）。
  static const int writeChunkBytes = 4 * 1024 * 1024;

  /// 取（或登记）租约；同一工作空间 + 同一 SSH 配置复用一条。
  Future<SshLease> lease() async {
    final String key = target.leaseKey;
    final SshLease? cached = leases[key];
    if (cached != null) return cached;
    final Map<String, dynamic> result;
    try {
      result = await call('ssh.lease.register', <String, dynamic>{
        'ssh': target.ssh,
        'ssh_lease_id': _leaseId(),
      });
    } catch (error) {
      if (error is FileRouteError) rethrow;
      throw FileRouteError.read(
        'SSH 工作空间租约登记失败（ssh_executor 执行站不可用？）：$error',
        400,
      );
    }
    final String leaseId = (result['lease_id'] ?? _leaseId()).toString();
    final String root = (result['root'] ?? '').toString().trim();
    if (root.isEmpty || !root.startsWith('/')) {
      throw FileRouteError.read(
        'SSH 租约未返回远端绝对根（agent=${target.agent.id}）',
        400,
      );
    }
    final SshLease lease = SshLease(
      leaseId: leaseId,
      root: root,
      connId: (result['conn_id'] ?? '').toString(),
    );
    leases[key] = lease;
    log?.call('SSH 租约：${target.agent.id} → $root');
    return lease;
  }

  String _leaseId() {
    final String identity = target.leaseKey;
    return 'files_ws_${base64Url.encode(utf8.encode(identity)).replaceAll('=', '')}';
  }

  /// 调一条命令；租约丢了（执行站重启）时重登记并只重试一次。
  Future<Map<String, dynamic>> command(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final SshLease current = await lease();
    try {
      return await call(name, <String, dynamic>{
        ...arguments,
        'ssh_lease_id': current.leaseId,
      });
    } catch (error) {
      if (!'$error'.contains('ssh_lease_unknown')) rethrow;
      leases.remove(target.leaseKey);
      final SshLease renewed = await lease();
      return call(name, <String, dynamic>{
        ...arguments,
        'ssh_lease_id': renewed.leaseId,
      });
    }
  }

  Future<Map<String, dynamic>> list(String path) async {
    final Map<String, dynamic> result;
    try {
      result = await command('ssh.file.list', <String, dynamic>{
        'path': path.isEmpty ? '.' : path,
        'max_depth': 0,
        'max_entries': LocalFiles.maxListEntries,
      });
    } catch (error) {
      throw _opError(error, action: '列目录');
    }
    final List<dynamic> raw =
        result['entries'] as List<dynamic>? ?? const <dynamic>[];
    final Map<String, Map<String, dynamic>> detailOf =
        <String, Map<String, dynamic>>{};
    final Object? rawDetails = result['details'];
    if (rawDetails is List) {
      for (final Object? item in rawDetails) {
        if (item is! Map) continue;
        final Map<String, dynamic> map = item.cast<String, dynamic>();
        detailOf['${map['name']}'] = map;
      }
    }
    final List<Map<String, dynamic>> entries = <Map<String, dynamic>>[];
    for (final Object? item in raw) {
      final String entry = '$item';
      if (entry.isEmpty) continue;
      final bool isDir = entry.endsWith('/');
      final String clean = isDir ? entry.substring(0, entry.length - 1) : entry;
      final Map<String, dynamic>? detail = detailOf[clean];
      final int mtime = (detail?['mtime_ms'] as num?)?.toInt() ?? 0;
      entries.add(<String, dynamic>{
        'name': p.posix.basename(clean),
        'size': isDir ? 0 : ((detail?['size'] as num?)?.toInt() ?? 0),
        'type': isDir ? 'dir' : 'file',
        'modified': mtime > 0
            ? DateTime.fromMillisecondsSinceEpoch(
                mtime,
                isUtc: true,
              ).toIso8601String()
            : '',
        'path': clean,
      });
    }
    entries.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
      final bool aDir = a['type'] == 'dir';
      final bool bDir = b['type'] == 'dir';
      if (aDir != bDir) return aDir ? -1 : 1;
      return (a['name'] as String).toLowerCase().compareTo(
        (b['name'] as String).toLowerCase(),
      );
    });
    return <String, dynamic>{
      'files': entries,
      'path': path,
      'total': entries.length,
      if (entries.length >= LocalFiles.maxListEntries) 'truncated': true,
    };
  }

  Future<Map<String, dynamic>> content(String path) async {
    final ({Uint8List bytes, bool truncated}) read = await _read(path);
    final Uint8List bytes = read.bytes;
    final String ext = p.posix
        .extension(path)
        .replaceFirst('.', '')
        .toLowerCase();
    final bool truncated = read.truncated;
    if (LocalFiles.imageExtensions.contains(ext)) {
      return <String, dynamic>{
        'content': base64Encode(bytes),
        'path': path,
        'size': bytes.length,
        'encoding': 'base64',
        'truncated': truncated,
        if (truncated) 'preview_bytes': bytes.length,
      };
    }
    return <String, dynamic>{
      'content': _decodeText(bytes),
      'path': path,
      'size': bytes.length,
      'encoding': 'utf-8',
      'truncated': truncated,
      if (truncated) 'preview_bytes': bytes.length,
    };
  }

  Future<Map<String, dynamic>> writeContent(
    String path, {
    required String content,
    int? ifSize,
    bool force = false,
  }) async {
    final String rel = _relative(path);
    final String ext = p.posix
        .extension(rel)
        .replaceFirst('.', '')
        .toLowerCase();
    if (LocalFiles.nonTextExtensions.contains(ext)) {
      throw FileRouteError(400, 'not_text', '该文件不是纯文本（.$ext），不能作为文本保存：$path');
    }
    final int newBytes = utf8.encode(content).length;
    if (newBytes > maxWriteBytes) {
      throw FileRouteError(
        400,
        'too_large',
        '内容过大（${_mbText(newBytes)} > 上限 ${_mbText(maxWriteBytes)}），'
            '请改用上传通道保存：$path',
      );
    }
    final int? currentSize = await _remoteSize(rel);
    if (ifSize != null && !force) {
      if (currentSize == null) {
        throw const FileRouteError(409, 'conflict', '文件已不存在，请刷新后再保存');
      }
      if (currentSize != ifSize) {
        throw FileRouteError(
          409,
          'conflict',
          '文件已被外部修改，请刷新后再保存',
          size: currentSize,
        );
      }
    }
    final List<int> head = await _remoteHead(rel);
    if (head.contains(0)) {
      throw FileRouteError(400, 'not_text', '该文件不是纯文本（含 NUL），不能作为文本保存：$path');
    }
    final Map<String, dynamic> result;
    try {
      result = await command('ssh.file.write', <String, dynamic>{
        'path': rel,
        'content': content,
      });
    } catch (error) {
      throw _opError(error, action: '保存');
    }
    final int written = (result['bytes_written'] as num?)?.toInt() ?? newBytes;
    return <String, dynamic>{
      'success': true,
      'path': rel,
      'size': written,
      'written': written,
    };
  }

  Future<Map<String, dynamic>> mkdir(String path) async {
    final String rel = _relative(path);
    if (rel.isEmpty || rel == '.') {
      throw FileRouteError(400, 'invalid_path', '不能把工作空间根当作新建目标：$path');
    }
    if (await _exists(rel)) {
      throw FileRouteError(409, 'already_exists', '目标已存在：$path');
    }
    final String parent = _parentOf(rel);
    if (parent.isNotEmpty && !await _exists(parent)) {
      throw FileRouteError(400, 'parent_missing', '父目录不存在：$path');
    }
    try {
      await command('ssh.file.mkdir', <String, dynamic>{'path': rel});
    } catch (error) {
      throw _opError(error, action: '新建文件夹');
    }
    return <String, dynamic>{'success': true, 'path': rel};
  }

  Future<Map<String, dynamic>> rename(String from, String to) async {
    final String source = _relative(from);
    final String targetRel = _relative(to);
    if (source.isEmpty ||
        source == '.' ||
        targetRel.isEmpty ||
        targetRel == '.') {
      throw FileRouteError(400, 'invalid_path', '源与目标都不能是工作空间根：$from → $to');
    }
    if (source == targetRel) {
      throw FileRouteError(400, 'invalid_path', '源与目标相同，无需重命名：$from');
    }
    if (!await _exists(source)) {
      throw FileRouteError(404, 'not_found', '源不存在：$from');
    }
    if (await _exists(targetRel)) {
      throw FileRouteError(409, 'already_exists', '目标已存在：$to');
    }
    final String parent = _parentOf(targetRel);
    if (parent.isNotEmpty && !await _exists(parent)) {
      throw FileRouteError(400, 'parent_missing', '目标父目录不存在：$to');
    }
    final Map<String, dynamic> result;
    try {
      // 原子重命名（目标机 `fs.rename`：源不存在 / 目标已存在都由远端显式拒绝）。
      // 不再用 `mv` —— shell 拼接既非原子，也把路径当命令文本处理。
      result = await command('ssh.file.rename', <String, dynamic>{
        'from': source,
        'to': targetRel,
      });
    } catch (error) {
      throw _opError(error, action: '重命名');
    }
    return <String, dynamic>{
      'success': true,
      'from': '${result['from'] ?? source}',
      'to': '${result['to'] ?? targetRel}',
    };
  }

  Future<Map<String, dynamic>> remove(
    String path, {
    bool recursive = false,
  }) async {
    final String rel = _relative(path);
    if (rel.isEmpty || rel == '.') {
      throw FileRouteError(400, 'invalid_path', '拒绝对工作空间根执行删除：$path');
    }
    try {
      await command('ssh.file.delete', <String, dynamic>{
        'path': rel,
        'recursive': recursive,
      });
    } catch (error) {
      throw _opError(error, action: '删除');
    }
    return <String, dynamic>{'success': true, 'path': rel};
  }

  /// PDF 元信息：小文件整读；大文件只取头 + 尾两段（与 [LocalFiles] 同口径），
  /// 两段都用 `ssh.file.read{raw}` 定点读取，不把整文件搬回本机。
  Future<Map<String, dynamic>> pdfInfo(String path) async {
    final String rel = _relative(path);
    final Map<String, dynamic>? entry = await _remoteEntry(rel);
    if (entry == null) throw FileRouteError.read('文件不存在：$path');
    final int size = (entry['size'] as num?)?.toInt() ?? 0;
    if (size <= LocalFiles.pdfFullReadBytes) {
      return LocalFiles.pdfInfoFromBytes(await _readRange(rel, 0, size));
    }
    final List<int> head = await _readRange(rel, 0, LocalFiles.pdfHeadBytes);
    final List<int> tail = await _readRange(
      rel,
      math.max(0, size - LocalFiles.pdfTailBytes),
      LocalFiles.pdfTailBytes,
    );
    return LocalFiles.pdfInfoFromSlices(head, tail);
  }

  /// 单个文件下载到 [outputPath]（分块读，按远端 `eof` 收口；无 8 MiB 上限）。
  Future<Map<String, dynamic>> download(String path, String outputPath) async {
    final Map<String, dynamic> copied = await _downloadTo(path, outputPath);
    return <String, dynamic>{
      'name': p.posix.basename(path),
      'size': copied['bytes'],
    };
  }

  /// 分片上传完成：本机暂存文件**分块**写到远端（首块截断重建，后续 append）。
  Future<Map<String, dynamic>> uploadComplete(
    String relativePath,
    List<int> bytes,
  ) async {
    final String rel = _relative(relativePath);
    try {
      if (bytes.isEmpty) {
        // 空文件没有「块」可写：用 writeBytes 的现状不被 ssh_executor 接受，走文本写。
        await command('ssh.file.write', <String, dynamic>{
          'path': rel,
          'content': '',
        });
      } else {
        for (int offset = 0; offset < bytes.length; offset += writeChunkBytes) {
          final int end = math.min(offset + writeChunkBytes, bytes.length);
          await command('ssh.file.writeBytes', <String, dynamic>{
            'path': rel,
            'base64': base64Encode(bytes.sublist(offset, end)),
            'append': offset > 0,
          });
        }
      }
    } catch (error) {
      throw _opError(error, action: '保存上传文件');
    }
    return <String, dynamic>{
      'success': true,
      'path': rel,
      'size': bytes.length,
    };
  }

  /// 把远端目录/单文件复制到本机 [localPath]（保留相对层级、覆盖同名）。
  ///
  /// 与本机口径一致：目标目录不能是工作空间本身（远端工作空间不可能落在本机，
  /// 但仍拒绝把 [localPath] 指回工作空间根对应的字符串）；超过文件数/字节上限即拒绝。
  Future<Map<String, dynamic>> syncToLocal(
    String localPath, {
    String path = '',
  }) async {
    final String raw = localPath.trim();
    if (raw.isEmpty) {
      throw FileRouteError.read('local_path 不能为空', 400);
    }
    final String target = p.normalize(p.absolute(raw));
    final String rel = path.trim().isEmpty || path.trim() == '.'
        ? ''
        : _relative(path);
    final Map<String, dynamic>? entry = await _remoteEntry(rel);
    if (entry == null) {
      throw FileRouteError.read('路径不存在：${path.isEmpty ? '/' : path}');
    }
    final List<Map<String, dynamic>> files = <Map<String, dynamic>>[];
    if ('${entry['type']}' != 'dir') {
      files.add(<String, dynamic>{
        'path': rel,
        'size': (entry['size'] as num?)?.toInt() ?? 0,
      });
    } else {
      final Map<String, dynamic> listing = await command('ssh.file.list', {
        'path': rel.isEmpty ? '.' : rel,
        'max_depth': 32,
        'max_entries': LocalFiles.maxSyncFiles,
      });
      final Object? details = listing['details'];
      if (details is List) {
        for (final Object? item in details) {
          if (item is! Map) continue;
          if ('${item['type']}' != 'file') continue;
          files.add(<String, dynamic>{
            'path': '${item['name']}',
            'size': (item['size'] as num?)?.toInt() ?? 0,
          });
        }
      }
      if (listing['truncated'] == true) {
        throw FileRouteError.read(
          '目录条目超过上限（${LocalFiles.maxSyncFiles}），请分批下载',
          413,
        );
      }
    }
    final int totalBytes = files.fold<int>(
      0,
      (int sum, Map<String, dynamic> file) =>
          sum + (file['size'] as num?)!.toInt(),
    );
    if (files.length > LocalFiles.maxSyncFiles ||
        totalBytes > LocalFiles.maxSyncBytes) {
      throw FileRouteError.read(
        '同步超过上限（${files.length} 个文件 / ${_mbText(totalBytes)}），请分批下载',
        413,
      );
    }
    int copied = 0;
    int bytes = 0;
    try {
      for (final Map<String, dynamic> file in files) {
        final String relFile = file['path'] as String;
        final String suffix = rel.isEmpty
            ? relFile
            : p.posix.relative(relFile, from: rel);
        final String output = p.joinAll(<String>[
          target,
          ...suffix.split('/'),
        ]);
        await Directory(p.dirname(output)).create(recursive: true);
        final Map<String, dynamic> result = await _downloadTo(relFile, output);
        copied++;
        bytes += (result['bytes'] as num?)?.toInt() ?? 0;
        if (bytes > LocalFiles.maxSyncBytes) {
          throw FileRouteError.read(
            '同步超过字节上限（${_mbText(LocalFiles.maxSyncBytes)}），请分批下载',
            413,
          );
        }
      }
    } catch (error) {
      if (error is FileRouteError) rethrow;
      throw FileRouteError.read('同步失败（已复制 $copied 个文件）：$error', 500);
    }
    log?.call('SSH 同步到本地：$rel → $target（$copied 个文件）');
    return <String, dynamic>{
      'success': true,
      'local_path': target,
      'path': path,
      'files': copied,
      'bytes': bytes,
    };
  }

  /// 目录/单文件打包下载：远端 `tar` 生成临时包，再分块回传到 [outputPath]。
  Future<Map<String, dynamic>> archive(String path, String outputPath) async {
    final String rel = path.trim().isEmpty || path.trim() == '.'
        ? ''
        : _relative(path);
    final Map<String, dynamic>? entry = await _remoteEntry(rel);
    if (entry == null) {
      throw FileRouteError.read('目录不存在：${path.isEmpty ? '/' : path}');
    }
    final SshLease current = await lease();
    final String stamp = DateTime.now().microsecondsSinceEpoch.toString();
    final String remoteTmp = '${current.root}/.tree-archive-$stamp.tar.gz';
    final String remoteRel = '.tree-archive-$stamp.tar.gz';
    final String source = rel.isEmpty ? '.' : rel;
    try {
      final Map<String, dynamic> result = await command(
        'ssh.exec.command',
        <String, dynamic>{
          'command':
              "tar -czf '${_escape(remoteTmp)}' --exclude=.git "
              "-C '${_escape(current.root)}' '${_escape(source)}'",
        },
      );
      if ((result['exit_code'] as num?)?.toInt() != 0) {
        throw FileRouteError.read(
          '远端打包失败：${result['text'] ?? 'tar 非零退出'}',
          500,
        );
      }
      final Map<String, dynamic> copied = await _downloadTo(
        remoteRel,
        outputPath,
      );
      final String base = rel.isEmpty
          ? p.posix.basename(current.root)
          : p.posix.basename(rel);
      return <String, dynamic>{
        'name': '$base.tar.gz',
        'bytes': copied['bytes'],
      };
    } finally {
      try {
        await command('ssh.file.delete', <String, dynamic>{
          'path': remoteRel,
        });
      } catch (error) {
        log?.call('清理远端临时包失败（$remoteRel）：$error');
      }
    }
  }

  // ── 内部 ────────────────────────────────────────────────────────────

  /// 某条目的元信息（`{name,type,size,mtime_ms}`）；不存在回 null。
  ///
  /// 走父目录的 `ssh.file.list{max_depth:0}`：一次往返同时拿到类型与大小，
  /// 不必为「这是目录还是文件」再发 `test -d`。
  Future<Map<String, dynamic>?> _remoteEntry(String rel) async {
    if (rel.isEmpty) return <String, dynamic>{'name': '', 'type': 'dir', 'size': 0};
    final String parent = _parentOf(rel);
    final Map<String, dynamic> result = await command('ssh.file.list', {
      'path': parent.isEmpty ? '.' : parent,
      'max_depth': 0,
      'max_entries': LocalFiles.maxListEntries,
    });
    final Object? details = result['details'];
    if (details is List) {
      for (final Object? item in details) {
        if (item is! Map) continue;
        if ('${item['name']}' == rel) return item.cast<String, dynamic>();
      }
    }
    return null;
  }

  /// 定点读一段（`raw` 通道：二进制原样回，不做行处理）。
  Future<List<int>> _readRange(String rel, int offset, int length) async {
    final Map<String, dynamic> result;
    try {
      result = await command('ssh.file.read', <String, dynamic>{
        'path': rel,
        'raw': true,
        'offset': offset,
        'length': length,
      });
    } catch (error) {
      throw _opError(error, action: '读取');
    }
    final String encoded = (result['base64'] ?? '').toString();
    if (encoded.isEmpty) return const <int>[];
    return base64Decode(encoded);
  }

  /// 分块把远端文件流到本机 [outputPath]，按远端 `eof` 收口（没有单次上限）。
  Future<Map<String, dynamic>> _downloadTo(
    String path,
    String outputPath,
  ) async {
    final String rel = _relative(path);
    final RandomAccessFile out = await File(outputPath).open(
      mode: FileMode.write,
    );
    int offset = 0;
    int size = 0;
    try {
      while (true) {
        final Map<String, dynamic> chunk;
        try {
          chunk = await command('ssh.file.read', <String, dynamic>{
            'path': rel,
            'raw': true,
            'offset': offset,
            'length': readChunkBytes,
          });
        } catch (error) {
          throw _opError(error, action: '下载');
        }
        final String encoded = (chunk['base64'] ?? '').toString();
        final List<int> bytes = encoded.isEmpty
            ? const <int>[]
            : base64Decode(encoded);
        if (bytes.isNotEmpty) {
          await out.writeFrom(bytes);
          offset += bytes.length;
        }
        size = (chunk['size'] as num?)?.toInt() ?? size;
        if (chunk['eof'] == true) break;
        if (bytes.isEmpty) {
          // 没数据也没 eof：不猜，按已读到尾部收口（与执行站同一保守口径）。
          break;
        }
      }
      await out.flush();
    } finally {
      await out.close();
    }
    return <String, dynamic>{'bytes': offset, 'size': size};
  }

  Future<({Uint8List bytes, bool truncated})> _read(String path) async {
    final Map<String, dynamic> result;
    try {
      result = await command('ssh.file.read', <String, dynamic>{'path': path});
    } catch (error) {
      throw _opError(error, action: '读取');
    }
    final String? encoded = result['base64']?.toString();
    final Uint8List bytes = encoded != null && encoded.isNotEmpty
        ? base64Decode(encoded)
        : Uint8List.fromList(utf8.encode((result['content'] ?? '').toString()));
    final bool truncated = result['truncated'] == true;
    if (!truncated && bytes.length > maxReadBytes) {
      throw FileRouteError.read('SSH 单次读取上限 8 MiB：$path', 413);
    }
    return (bytes: bytes, truncated: truncated);
  }

  Future<bool> _exists(String rel) async {
    try {
      await command('ssh.file.list', <String, dynamic>{
        'path': rel,
        'max_depth': 0,
        'max_entries': 1,
      });
      return true;
    } catch (error) {
      final FileRouteError mapped = _opError(error, action: '检查路径');
      if (mapped.status == 404) return false;
      rethrow;
    }
  }

  Future<int?> _remoteSize(String rel) async {
    final SshLease current;
    try {
      current = await lease();
    } catch (_) {
      return null;
    }
    final Map<String, dynamic> result;
    try {
      result = await command('ssh.exec.command', <String, dynamic>{
        'command': "wc -c < '${_escape(_absolute(current.root, rel))}'",
      });
    } catch (_) {
      return null;
    }
    if ((result['exit_code'] as num?)?.toInt() != 0) return null;
    final String text = (result['text'] ?? '').toString();
    return int.tryParse(text.trim().split(RegExp(r'\s+')).first);
  }

  Future<List<int>> _remoteHead(String rel) async {
    final SshLease current;
    try {
      current = await lease();
    } catch (_) {
      return const <int>[];
    }
    try {
      final Map<String, dynamic>
      result = await command('ssh.exec.command', <String, dynamic>{
        'command':
            "head -c 4096 '${_escape(_absolute(current.root, rel))}' | base64",
      });
      if ((result['exit_code'] as num?)?.toInt() != 0) return const <int>[];
      final String text = (result['text'] ?? '').toString().trim();
      final int breakAt = text.indexOf(RegExp(r'\s'));
      final String encoded = breakAt < 0 ? text : text.substring(0, breakAt);
      return encoded.isEmpty ? const <int>[] : base64Decode(encoded);
    } catch (_) {
      return const <int>[];
    }
  }

  String _relative(String raw) {
    final String path = raw.trim().replaceAll('\\', '/');
    if (path.isEmpty) {
      throw const FileRouteError(400, 'invalid_path', '路径不能为空');
    }
    if (path.startsWith('~') ||
        path.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(path)) {
      throw FileRouteError(400, 'invalid_path', '必须是工作空间内的相对路径：$raw');
    }
    final String normalized = p.posix.normalize(path);
    if (normalized == '..' || normalized.startsWith('../')) {
      throw FileRouteError(400, 'invalid_path', '越出工作空间根目录：$raw');
    }
    return normalized == '.' ? '' : normalized;
  }

  static String _parentOf(String rel) {
    final int index = rel.lastIndexOf('/');
    return index < 0 ? '' : rel.substring(0, index);
  }

  static String _absolute(String root, String rel) => p.posix.join(root, rel);

  static String _escape(String value) => value.replaceAll("'", "'\\''");

  FileRouteError _opError(Object error, {required String action}) {
    if (error is FileRouteError) return error;
    final String message = '$error';
    if (message.contains('路径不存在') ||
        message.contains('文件不存在') ||
        message.contains('不存在：')) {
      return FileRouteError.read(message, 404);
    }
    if (message.contains('非空')) {
      return FileRouteError(409, 'directory_not_empty', message);
    }
    if (message.contains('已存在')) {
      return FileRouteError(409, 'already_exists', message);
    }
    if (message.contains('越出') ||
        message.contains('相对路径') ||
        message.contains('缺少 path')) {
      return FileRouteError(400, 'invalid_path', message);
    }
    return FileRouteError.read('SSH $action失败：$message', 500);
  }

  static String _decodeText(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }

  static String _mbText(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
