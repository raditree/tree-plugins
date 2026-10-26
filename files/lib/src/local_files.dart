import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'errors.dart';

/// 本机工作空间的文件操作（从核心 `FileService` 的本地分支平移）。
///
/// 只做「工作空间相对路径 + dart:io」这一条路；路径安全边界是本文件唯一的
/// 写盘/读盘入口（绝对路径 / 盘符 / `~` / `..` 逃逸一律 400），与核心旧
/// `FileService.resolve` 同口径。
class LocalFiles {
  LocalFiles(this.root, {this.log});

  final String root;
  final void Function(String message)? log;

  static const int maxListEntries = 2000;
  static const int maxContentBytes = 8 * 1024 * 1024;
  static const int maxWriteBytes = 4 * 1024 * 1024;
  static const int binaryProbeBytes = 4096;
  static const int maxSyncFiles = 50000;
  static const int maxSyncBytes = 2 * 1024 * 1024 * 1024;
  static const int maxArchiveBytes = 256 * 1024 * 1024;

  /// 拒绝按文本写回的扩展名（与核心旧 FileService 一致）。
  static const Set<String> nonTextExtensions = <String>{
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
    'ico',
    'tif',
    'tiff',
    'pdf',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
    'zip',
    'rar',
    '7z',
    'tar',
    'gz',
    'bz2',
    'xz',
  };

  /// 图片按 base64 回给前端（与核心旧预览口径一致）。
  static const Set<String> imageExtensions = <String>{
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
    'ico',
    'tif',
    'tiff',
  };

  String relative(String absolute) =>
      p.posix.joinAll(p.split(p.relative(absolute, from: root)));

  /// 解析工作空间内相对路径（空 path 仅在 allowRoot 时允许）。
  String resolve(String path, {bool allowRoot = false}) {
    final String raw = path.trim().replaceAll('\\', '/');
    if (raw.isEmpty) {
      if (allowRoot) return p.normalize(root);
      throw const FileRouteError(400, 'invalid_path', '路径不能为空');
    }
    if (raw.startsWith('~') ||
        p.posix.isAbsolute(raw) ||
        RegExp(r'^[A-Za-z]:').hasMatch(raw)) {
      throw FileRouteError(400, 'invalid_path', '必须是工作空间内的相对路径：$path');
    }
    final String normalizedRoot = p.normalize(root);
    final String absolute = p.normalize(p.join(normalizedRoot, raw));
    if (absolute != normalizedRoot && !p.isWithin(normalizedRoot, absolute)) {
      throw FileRouteError(400, 'invalid_path', '越出工作空间根目录：$path');
    }
    return absolute;
  }

  Future<Map<String, dynamic>> list(String path) async {
    final String dirPath = resolve(path, allowRoot: true);
    final Directory dir = Directory(dirPath);
    if (!dir.existsSync()) {
      throw FileRouteError.read('目录不存在：${path.isEmpty ? '/' : path}');
    }
    final List<Map<String, dynamic>> entries = <Map<String, dynamic>>[];
    try {
      for (final FileSystemEntity entity in dir.listSync(followLinks: false)) {
        if (entries.length >= maxListEntries) break;
        final String name = p.basename(entity.path);
        final FileStat stat = entity.statSync();
        final bool isDir = stat.type == FileSystemEntityType.directory;
        entries.add(<String, dynamic>{
          'name': name,
          'size': isDir ? 0 : stat.size,
          'type': isDir ? 'dir' : 'file',
          'modified': stat.modified.toIso8601String(),
          'path': relative(entity.path),
        });
      }
    } catch (error) {
      throw FileRouteError.read('读取目录失败：$error', 500);
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
      if (entries.length >= maxListEntries) 'truncated': true,
    };
  }

  Future<Map<String, dynamic>> content(String path) async {
    final String absolute = resolve(path);
    final File file = File(absolute);
    if (!file.existsSync()) throw FileRouteError.read('文件不存在：$path');
    final int size = file.lengthSync();
    final List<int> bytes;
    try {
      if (size > maxContentBytes) {
        final RandomAccessFile raf = await file.open();
        try {
          bytes = await raf.read(maxContentBytes);
        } finally {
          await raf.close();
        }
      } else {
        bytes = await file.readAsBytes();
      }
    } catch (error) {
      throw FileRouteError.read('读取文件失败：$error', 500);
    }
    final String ext = p
        .extension(absolute)
        .replaceFirst('.', '')
        .toLowerCase();
    return _previewJson(path, bytes, size: size, extension: ext);
  }

  Future<Map<String, dynamic>> writeContent(
    String path, {
    required String content,
    int? ifSize,
    bool force = false,
  }) async {
    final String absolute = resolve(path);
    final String rel = relative(absolute);
    final String ext = p
        .extension(absolute)
        .replaceFirst('.', '')
        .toLowerCase();
    if (nonTextExtensions.contains(ext)) {
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
    final File file = File(absolute);
    final _ExistingFile existing = _probeLocal(file);
    if (ifSize != null && !force) {
      if (!existing.exists) {
        throw const FileRouteError(409, 'conflict', '文件已不存在，请刷新后再保存');
      }
      if (existing.size != ifSize) {
        throw FileRouteError(
          409,
          'conflict',
          '文件已被外部修改，请刷新后再保存',
          size: existing.size,
        );
      }
    }
    if (existing.exists && _hasNul(existing.head)) {
      throw FileRouteError(400, 'not_text', '该文件不是纯文本（含 NUL），不能作为文本保存：$path');
    }
    final int written;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(content, flush: true);
      written = utf8.encode(content).length;
    } catch (error) {
      throw FileRouteError.read('保存失败：$error', 500);
    }
    log?.call('保存文本文件：$rel（$written 字节）');
    return <String, dynamic>{
      'success': true,
      'path': rel,
      'size': written,
      'written': written,
    };
  }

  Future<Map<String, dynamic>> mkdir(String path) async {
    final String absolute = resolve(path);
    final String rel = relative(absolute);
    if (rel.isEmpty || rel == '.') {
      throw FileRouteError(400, 'invalid_path', '不能把工作空间根当作新建目标：$path');
    }
    final FileSystemEntityType type = FileSystemEntity.typeSync(absolute);
    if (type != FileSystemEntityType.notFound) {
      throw FileRouteError(409, 'already_exists', '目标已存在：$path');
    }
    final Directory parent = Directory(p.dirname(absolute));
    if (!parent.existsSync()) {
      throw FileRouteError(400, 'parent_missing', '父目录不存在：$path');
    }
    try {
      Directory(absolute).createSync(recursive: false);
    } catch (error) {
      throw FileRouteError.read('新建文件夹失败：$error', 500);
    }
    log?.call('新建文件夹：$rel');
    return <String, dynamic>{'success': true, 'path': rel};
  }

  Future<Map<String, dynamic>> rename(String from, String to) async {
    final String source = relative(resolve(from));
    final String target = relative(resolve(to));
    if (source.isEmpty || source == '.' || target.isEmpty || target == '.') {
      throw FileRouteError(400, 'invalid_path', '源与目标都不能是工作空间根：$from → $to');
    }
    if (source == target) {
      throw FileRouteError(400, 'invalid_path', '源与目标相同，无需重命名：$from');
    }
    final String sourceAbsolute = resolve(from);
    final String targetAbsolute = resolve(to);
    if (FileSystemEntity.typeSync(sourceAbsolute) ==
        FileSystemEntityType.notFound) {
      throw FileRouteError(404, 'not_found', '源不存在：$from');
    }
    if (FileSystemEntity.typeSync(targetAbsolute) !=
        FileSystemEntityType.notFound) {
      throw FileRouteError(409, 'already_exists', '目标已存在：$to');
    }
    if (!Directory(p.dirname(targetAbsolute)).existsSync()) {
      throw FileRouteError(400, 'parent_missing', '目标父目录不存在：$to');
    }
    try {
      if (FileSystemEntity.typeSync(sourceAbsolute) ==
          FileSystemEntityType.directory) {
        Directory(sourceAbsolute).renameSync(targetAbsolute);
      } else {
        File(sourceAbsolute).renameSync(targetAbsolute);
      }
    } on FileSystemException catch (error) {
      throw FileRouteError.read('重命名失败：$error', 500);
    }
    log?.call('重命名：$source → $target');
    return <String, dynamic>{'success': true, 'from': source, 'to': target};
  }

  Future<Map<String, dynamic>> remove(
    String path, {
    bool recursive = false,
  }) async {
    final String absolute = resolve(path);
    final String rel = relative(absolute);
    if (rel.isEmpty || rel == '.') {
      throw FileRouteError(400, 'invalid_path', '拒绝对工作空间根执行删除：$path');
    }
    final FileSystemEntityType type = FileSystemEntity.typeSync(absolute);
    if (type == FileSystemEntityType.notFound) {
      throw FileRouteError(404, 'not_found', '路径不存在：$path');
    }
    try {
      if (type == FileSystemEntityType.directory) {
        final Directory dir = Directory(absolute);
        if (!recursive && dir.listSync().isNotEmpty) {
          throw FileRouteError(
            409,
            'directory_not_empty',
            '目录非空，删除需要 recursive=1：$path',
          );
        }
        dir.deleteSync(recursive: recursive);
      } else {
        File(absolute).deleteSync();
      }
    } on FileRouteError {
      rethrow;
    } catch (error) {
      throw FileRouteError.read('删除失败：$error', 500);
    }
    log?.call('删除：$rel${recursive ? '（递归）' : ''}');
    return <String, dynamic>{'success': true, 'path': rel};
  }

  Future<Map<String, dynamic>> pdfInfo(String path) async {
    final String absolute = resolve(path);
    final File file = File(absolute);
    if (!file.existsSync()) throw FileRouteError.read('文件不存在：$path');
    final int size = file.lengthSync();
    if (size <= pdfFullReadBytes) {
      return pdfInfoFromBytes(await file.readAsBytes());
    }
    final RandomAccessFile raf = await file.open();
    try {
      final List<int> head = await raf.read(pdfHeadBytes);
      await raf.setPosition(max(0, size - pdfTailBytes));
      final List<int> tail = await raf.read(pdfTailBytes);
      return pdfInfoFromSlices(head, tail);
    } on FileSystemException catch (error) {
      throw FileRouteError.read('读取 PDF 失败：$error', 500);
    } finally {
      await raf.close();
    }
  }

  /// 把工作空间子树复制到本机目录（保留相对层级、覆盖同名、排除 .git）。
  Future<Map<String, dynamic>> syncToLocal(
    String localPath, {
    String path = '',
  }) async {
    final String raw = localPath.trim();
    if (raw.isEmpty) {
      throw FileRouteError.read('local_path 不能为空', 400);
    }
    final String target = p.normalize(p.absolute(raw));
    final String rootNormalized = p.normalize(root);
    if (target == rootNormalized || p.isWithin(rootNormalized, target)) {
      throw FileRouteError.read('目标目录不能是工作空间本身或它的子目录：$raw', 400);
    }
    final String source = resolve(path, allowRoot: true);
    final FileSystemEntityType type = FileSystemEntity.typeSync(source);
    if (type == FileSystemEntityType.notFound) {
      throw FileRouteError.read('目录不存在：${path.isEmpty ? '/' : path}');
    }
    final _CopyCounters counters = _CopyCounters(
      maxFiles: maxSyncFiles,
      maxBytes: maxSyncBytes,
    );
    try {
      if (type == FileSystemEntityType.directory) {
        await _copyLocalTree(Directory(source), target, counters);
      } else {
        await _copyLocalFile(File(source), relative(source), target, counters);
      }
    } catch (error) {
      throw FileRouteError.read('同步失败（已复制 ${counters.files} 个文件）：$error', 500);
    }
    if (counters.limitHit) {
      throw FileRouteError.read(
        '同步超过上限（${counters.files} 个文件 / ${counters.bytes} 字节），请分批下载',
        413,
      );
    }
    log?.call('同步到本地：$source → $target（${counters.files} 个文件）');
    return <String, dynamic>{
      'success': true,
      'local_path': target,
      'path': path,
      'files': counters.files,
      'bytes': counters.bytes,
    };
  }

  /// 把目录/单文件打包到 [outputPath]（tar.gz），返回文件名与条目数。
  Future<Map<String, dynamic>> archive(String path, String outputPath) async {
    final String absolute = resolve(path, allowRoot: true);
    final FileSystemEntityType type = FileSystemEntity.typeSync(absolute);
    if (type == FileSystemEntityType.notFound) {
      throw FileRouteError.read('目录不存在：${path.isEmpty ? '/' : path}');
    }
    final bool isDirectory = type == FileSystemEntityType.directory;
    if (!isDirectory && type != FileSystemEntityType.file) {
      throw FileRouteError.read('不支持打包该类型：$path', 400);
    }
    final List<_WalkEntry> entries = isDirectory
        ? _enumerate(Directory(absolute))
        : <_WalkEntry>[
            _WalkEntry(
              absolutePath: absolute,
              size: File(absolute).lengthSync(),
            ),
          ];
    final int total = entries.fold<int>(
      0,
      (int sum, _WalkEntry entry) => sum + entry.size,
    );
    if (total > maxArchiveBytes) {
      throw FileRouteError.read(
        '目录过大（${total ~/ (1024 * 1024)} MB > 上限 '
        '${maxArchiveBytes ~/ (1024 * 1024)} MB），请分批下载',
        413,
      );
    }
    final String rel = path.trim().isEmpty ? '.' : relative(absolute);
    final ProcessResult result;
    try {
      result = await Process.run('tar', <String>[
        '-czf',
        outputPath,
        '--exclude=.git',
        '-C',
        root,
        rel,
      ]);
    } catch (error) {
      throw FileRouteError.read('打包失败（系统没有 tar？）：$error', 500);
    }
    if (result.exitCode != 0) {
      final String errText = '${result.stderr}'.trim();
      throw FileRouteError.read('打包失败：$errText', 500);
    }
    final String name = '${p.basename(absolute)}.tar.gz';
    return <String, dynamic>{'name': name, 'entries': entries.length};
  }

  List<_WalkEntry> _enumerate(Directory dir) {
    final List<_WalkEntry> entries = <_WalkEntry>[];
    void walk(Directory current) {
      final List<FileSystemEntity> children;
      try {
        children = current.listSync(followLinks: false);
      } catch (error) {
        log?.call('遍历目录失败（${current.path}）：$error');
        return;
      }
      for (final FileSystemEntity entity in children) {
        final String name = p.basename(entity.path);
        if (name == '.git') continue;
        if (entity is Directory) {
          walk(entity);
        } else if (entity is File) {
          try {
            entries.add(
              _WalkEntry(absolutePath: entity.path, size: entity.lengthSync()),
            );
          } catch (error) {
            log?.call('读取文件大小失败（${entity.path}）：$error');
          }
        }
      }
    }

    walk(dir);
    return entries;
  }

  Future<void> _copyLocalTree(
    Directory dir,
    String target,
    _CopyCounters counters,
  ) async {
    final List<FileSystemEntity> children;
    try {
      children = dir.listSync(followLinks: false);
    } catch (error) {
      log?.call('遍历目录失败（${dir.path}）：$error');
      return;
    }
    for (final FileSystemEntity entity in children) {
      if (counters.limitHit) return;
      final String name = p.basename(entity.path);
      if (name == '.git') continue;
      if (entity is Directory) {
        await _copyLocalTree(entity, target, counters);
      } else if (entity is File) {
        await _copyLocalFile(entity, relative(entity.path), target, counters);
      }
    }
  }

  Future<void> _copyLocalFile(
    File file,
    String relativePath,
    String target,
    _CopyCounters counters,
  ) async {
    final String destination = p.joinAll(<String>[
      target,
      ...p.posix.split(relativePath),
    ]);
    final String parent = p.dirname(destination);
    if (counters.created.add(parent)) {
      await Directory(parent).create(recursive: true);
    }
    final int size = await file.length();
    await file.copy(destination);
    counters.add(size);
  }

  /// 字节 → 前端文件内容 JSON（图片 base64，其余文本解码）。
  static Map<String, dynamic> _contentJson(
    String path,
    List<int> bytes, {
    required String extension,
  }) {
    if (imageExtensions.contains(extension)) {
      return <String, dynamic>{
        'content': base64Encode(bytes),
        'path': path,
        'size': bytes.length,
        'encoding': 'base64',
      };
    }
    return <String, dynamic>{
      'content': _decodeText(bytes),
      'path': path,
      'size': bytes.length,
      'encoding': 'utf-8',
    };
  }

  static Map<String, dynamic> _previewJson(
    String path,
    List<int> bytes, {
    required int size,
    required String extension,
  }) {
    return <String, dynamic>{
      ..._contentJson(path, bytes, extension: extension),
      'size': size,
      'truncated': size > bytes.length,
      if (size > bytes.length) 'preview_bytes': bytes.length,
    };
  }

  static String _decodeText(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }

  static _ExistingFile _probeLocal(File file) {
    if (!file.existsSync()) return const _ExistingFile(exists: false);
    final RandomAccessFile raf;
    try {
      raf = file.openSync();
    } catch (_) {
      return const _ExistingFile(exists: false);
    }
    try {
      final int size = raf.lengthSync();
      final int count = size > binaryProbeBytes ? binaryProbeBytes : size;
      final List<int> head = count <= 0 ? <int>[] : raf.readSync(count);
      return _ExistingFile(exists: true, size: size, head: head);
    } catch (_) {
      return const _ExistingFile(exists: false);
    } finally {
      try {
        raf.closeSync();
      } catch (_) {}
    }
  }

  static bool _hasNul(List<int> bytes) {
    final int n = bytes.length > binaryProbeBytes
        ? binaryProbeBytes
        : bytes.length;
    for (int i = 0; i < n; i++) {
      if (bytes[i] == 0) return true;
    }
    return false;
  }

  static String _mbText(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  /// PDF 元信息整读上限；更大的文件只取头 [pdfHeadBytes] + 尾 [pdfTailBytes] 两段。
  ///
  /// 三个常量对外可见：`RemoteFiles` 的 SSH 版本要按同一口径定点读取。
  static const int pdfFullReadBytes = 4 * 1024 * 1024;
  static const int pdfHeadBytes = 64 * 1024;
  static const int pdfTailBytes = 512 * 1024;

  static Map<String, dynamic> pdfInfoFromBytes(List<int> bytes) {
    final String text = latin1.decode(bytes, allowInvalid: true);
    int pages = 0;
    String source = '';
    for (final RegExpMatch match in RegExp(
      r'/Count\s+(\d+)',
    ).allMatches(text)) {
      final int value = int.tryParse(match.group(1) ?? '') ?? 0;
      if (value > pages) {
        pages = value;
        source = 'count';
      }
    }
    if (pages <= 0) {
      pages = RegExp(r'/Type\s*/Page(?![s])').allMatches(text).length;
      source = 'scan';
    }
    return <String, dynamic>{
      'total_pages': pages,
      'title': _pdfString(text, 'Title'),
      'author': _pdfString(text, 'Author'),
      'pages_source': source,
    };
  }

  static Map<String, dynamic> pdfInfoFromSlices(
    List<int> head,
    List<int> tail,
  ) {
    return <String, dynamic>{
      ...pdfInfoFromBytes(<int>[...head, ...tail]),
      'scanned': 'head+tail',
    };
  }

  static String _pdfString(String text, String key) {
    final RegExpMatch? literal = RegExp(
      '/$key'
      r'\s*\(([^)]*)\)',
    ).firstMatch(text);
    if (literal != null) {
      final List<int> bytes = (literal.group(1) ?? '').codeUnits;
      try {
        return utf8.decode(bytes);
      } on FormatException {
        return latin1.decode(bytes);
      }
    }
    final RegExpMatch? hex = RegExp(
      '/$key'
      r'\s*<([0-9A-Fa-f]+)>',
    ).firstMatch(text);
    if (hex == null) return '';
    final String raw = hex.group(1) ?? '';
    if (raw.length.isOdd) return '';
    try {
      final List<int> bytes = <int>[];
      for (int i = 0; i < raw.length; i += 2) {
        bytes.add(int.parse(raw.substring(i, i + 2), radix: 16));
      }
      if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
        return String.fromCharCodes(<int>[
          for (int i = 2; i + 1 < bytes.length; i += 2)
            (bytes[i] << 8) | bytes[i + 1],
        ]);
      }
      return latin1.decode(bytes);
    } catch (_) {
      return '';
    }
  }
}

class _ExistingFile {
  const _ExistingFile({
    required this.exists,
    this.size = 0,
    this.head = const <int>[],
  });

  final bool exists;
  final int size;
  final List<int> head;
}

class _WalkEntry {
  const _WalkEntry({required this.absolutePath, required this.size});

  final String absolutePath;
  final int size;
}

class _CopyCounters {
  _CopyCounters({required this.maxFiles, required this.maxBytes});

  final int maxFiles;
  final int maxBytes;
  int files = 0;
  int bytes = 0;
  bool limitHit = false;
  final Set<String> created = <String>{};

  void add(int size) {
    files++;
    bytes += size;
    if (files > maxFiles || bytes > maxBytes) limitHit = true;
  }
}
