import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 自建执行站的**站名段**（核心拼成 `plugin.local_executor.execute.local`）。
const String kLocalWorkspaceStationName = 'local';

/// `local.lease.register`：登记一条**本机工作空间租约**（tree.agent 第一次用某个
/// 本机工作空间时发一次；之后所有命令只带 `local_lease_id`）。
const String kLocalLeaseRegisterCommand = 'local.lease.register';

/// 本机执行站的命令表。
///
/// **与 `ssh_executor` 逐字对称**（[docs/exec_station_contract.md] §8.1）：后缀同一套，
/// 只换限定词 `local.` / `ssh.`，限定词正是 `StationScope.mode_key` 的两个取值。
/// 命令名全局唯一（核心按名字查自建站），所以本机族**不能**再叫 `file.*`——
/// 那既分不清本机还是远端，也和 A5 之后"核心不认识执行器"的口径不符。
const List<String> kLocalWorkspaceCommands = <String>[
  kLocalLeaseRegisterCommand,
  'local.file.read',
  'local.file.write',
  'local.file.list',
  'local.file.grep',
  'local.file.delete',
  'local.file.mkdir',
  'local.file.writeBytes',
  'local.file.rename',
  'local.exec.command',
];

/// 租约未登记 / 插件重启过：调用方应重新 `local.lease.register` 再重试一次。
///
/// 这个码是**契约**（与 `ssh_executor` 的同一个 `lease_unknown` 同一角色，契约 §4.2）：
/// 调用方只在看到它时才丢弃缓存租约、重登记并重试；其它失败可能是写了一半，
/// **绝不重试**。
const String kLeaseUnknownCode = 'lease_unknown';

/// 租约归属不符：登记方与调用方不是同一个插件，**fail-closed 拒绝且不重试**。
///
/// 为什么这条必须在插件侧：核心过去替本机看着"租约只能登记方自己用"
/// （`workspace/register` 那套簿记），租约统一到插件侧后这个判断只剩这里一个落点。
const String kLeaseDeniedCode = 'lease_denied';

/// 本机执行器产生的稳定错误码（值逐字对齐 `tree_protocol` 的
/// `ExecStationErrorCodes`；插件仓不 import 协议包，一致性由桌面仓的码表门禁
/// 扫字面量兜住）。
abstract final class LocalCodes {
  static const String commandUnknown = 'command_unknown';
  static const String invalidArguments = 'invalid_arguments';
  static const String fileNotFound = 'file_not_found';
  static const String notAFile = 'not_a_file';
  static const String dirNotEmpty = 'dir_not_empty';
  static const String targetExists = 'target_exists';
  static const String badBase64 = 'bad_base64';
}

/// `local.file.read` **文本模式**单次最多读的原文（8 MiB，与 SSH 侧同口径）。
const int _kMaxReadBytes = 8 * 1024 * 1024;

/// `local.file.read` 返回文本的上限（512 KiB，与 SSH 侧同口径）。
const int _kMaxReadTextChars = 512 * 1024;

/// 核心拼出的自建站 id（与 `PluginBus.selfBuiltStationId` 同形；自检/测试可用）。
String localWorkspaceStationId(String pluginId) =>
    'plugin.$pluginId.execute.$kLocalWorkspaceStationName';

/// 执行器错误：带可读中文原因与**稳定错误码**（契约 §4：失败必带码，禁空）。
class ExecutorError implements Exception {
  ExecutorError(this.message, {required this.code})
    : assert(code.isNotEmpty, 'ExecutorError 必须带错误码');
  final String message;

  /// 稳定错误码（值必须是 `tree_protocol` 码表里的一条）。
  final String code;
  @override
  String toString() => message;
}

/// 一条本机工作空间租约：绝对根目录 + 登记方插件 id（插件进程内有效）。
class _LocalLease {
  _LocalLease({
    required this.leaseId,
    required this.root,
    required this.registrant,
  });

  final String leaseId;

  /// 本机**绝对**工作空间根（越界校验的基线）。
  final String root;

  /// 登记方的插件 id（空 = 核心登记的）；只有它自己能再用这条租约。
  final String registrant;
}

/// 本机执行器：只认**自己登记的租约**与相对路径，**不认 agent/team/mode 身份**。
///
/// `root` 的唯一来源是租约表：arguments 里出现的 `root` / `workspace_root` 一律忽略
/// （核心 `sanitizeStationArguments` 也会剥掉调用方自带的那份，两道都不靠调用方自觉）。
class LocalExecutor {
  LocalExecutor();

  final Map<String, _HookTask> _hooks = <String, _HookTask>{};
  final Map<String, _LocalLease> _leases = <String, _LocalLease>{};
  int _hookSeq = 0;

  /// 已登记的租约数（诊断 / 自检）。
  int get leaseCount => _leases.length;

  Future<Map<String, dynamic>> execute(
    String command,
    Map<String, dynamic> arguments, {
    String sourcePluginId = '',
  }) async {
    if (command == kLocalLeaseRegisterCommand) {
      return _registerLease(arguments, sourcePluginId);
    }
    final String root = _rootOf(arguments, sourcePluginId);
    switch (command) {
      case 'local.file.read':
        return _read(root, arguments);
      case 'local.file.write':
        return _write(root, arguments);
      case 'local.file.list':
        return _list(root, arguments);
      case 'local.file.grep':
        return _grep(root, arguments);
      case 'local.file.delete':
        return _delete(root, arguments);
      case 'local.file.mkdir':
        return _mkdir(root, arguments);
      case 'local.file.writeBytes':
        return _writeBytes(root, arguments);
      case 'local.file.rename':
        return _rename(root, arguments);
      case 'local.exec.command':
        return _terminal(root, arguments);
      default:
        throw ExecutorError(
          '本机执行器不支持命令：$command',
          code: LocalCodes.commandUnknown,
        );
    }
  }

  /// `local.lease.register`：`{dir, local_lease_id?}` → `{ok, lease_id, root}`。
  ///
  /// 目录键刻意叫 `dir` 而不是 `root`：核心的 `sanitizeStationArguments` 会把
  /// `root` / `workspace_root` 从 arguments 里剥掉，用那两个键**根本到不了插件**。
  Future<Map<String, dynamic>> _registerLease(
    Map<String, dynamic> arguments,
    String sourcePluginId,
  ) async {
    final String requested =
        (arguments['local_lease_id'] ?? '').toString().trim();
    final String raw = (arguments['dir'] ?? '').toString().trim();
    if (raw.isEmpty || !p.isAbsolute(raw)) {
      throw ExecutorError(
        'local.lease.register 需要绝对路径 dir（本机工作空间根）',
        code: LocalCodes.invalidArguments,
      );
    }
    final String normalized = p.normalize(raw);
    if (!Directory(normalized).existsSync()) {
      throw ExecutorError(
        '工作空间根目录不存在：$normalized',
        code: LocalCodes.fileNotFound,
      );
    }
    final String leaseId = requested.isNotEmpty
        ? requested
        : _leaseIdFor(normalized);
    final _LocalLease? existing = _leases[leaseId];
    if (existing != null && existing.registrant != sourcePluginId) {
      throw ExecutorError(
        '租约 $leaseId 由插件 '
        '${existing.registrant.isEmpty ? '核心' : existing.registrant} 登记，'
        '${sourcePluginId.isEmpty ? '核心' : sourcePluginId} 不能顶掉它'
        '（fail-closed）',
        code: kLeaseDeniedCode,
      );
    }
    _leases[leaseId] = _LocalLease(
      leaseId: leaseId,
      root: normalized,
      registrant: sourcePluginId,
    );
    return <String, dynamic>{
      'ok': true,
      'lease_id': leaseId,
      'root': normalized,
    };
  }

  /// 命令进来的第一道：租约必须存在、必须是自己人登记、根目录必须还在。
  String _rootOf(Map<String, dynamic> args, String sourcePluginId) {
    final String id = (args['local_lease_id'] ?? '').toString().trim();
    if (id.isEmpty) {
      throw ExecutorError(
        '缺少 local_lease_id（先 local.lease.register 登记工作空间根）',
        code: LocalCodes.invalidArguments,
      );
    }
    final _LocalLease? lease = _leases[id];
    if (lease == null) {
      throw ExecutorError(
        '租约 $id 未登记（插件进程可能重启过；请重新 local.lease.register）',
        code: kLeaseUnknownCode,
      );
    }
    if (lease.registrant != sourcePluginId) {
      throw ExecutorError(
        '租约 $id 由插件 '
        '${lease.registrant.isEmpty ? '核心' : lease.registrant} 登记，'
        '${sourcePluginId.isEmpty ? '核心' : sourcePluginId} 不能用它'
        '（fail-closed）',
        code: kLeaseDeniedCode,
      );
    }
    if (!Directory(lease.root).existsSync()) {
      throw ExecutorError(
        '工作空间根目录不存在：${lease.root}',
        code: LocalCodes.fileNotFound,
      );
    }
    return lease.root;
  }

  /// 确定性租约 id（同一目录复用同一条；Windows 大小写不敏感）。
  String _leaseIdFor(String normalizedRoot) {
    final String identity =
        normalizedRoot.replaceAll('\\', '/').toLowerCase();
    return 'local_ws_${base64Url.encode(utf8.encode(identity)).replaceAll('=', '')}';
  }

  String _resolve(String root, String relative) {
    final String rel = relative.trim();
    if (rel.isEmpty) {
      throw ExecutorError(
        '缺少 path（工作空间内相对路径）',
        code: LocalCodes.invalidArguments,
      );
    }
    if (p.isAbsolute(rel)) {
      throw ExecutorError(
        'path 必须是工作空间内相对路径：$rel',
        code: LocalCodes.invalidArguments,
      );
    }
    final String joined = p.normalize(p.join(root, rel));
    if (joined != root && !p.isWithin(root, joined)) {
      throw ExecutorError(
        'path 越出工作空间根目录：$rel',
        code: LocalCodes.invalidArguments,
      );
    }
    return joined;
  }

  String _relative(String root, String absolute) =>
      p.relative(absolute, from: root).replaceAll('\\', '/');

  Future<Map<String, dynamic>> _read(
    String root,
    Map<String, dynamic> args,
  ) async {
    final String relative = (args['path'] ?? args['file_path'] ?? '').toString();
    final String path = _resolve(root, relative);
    final File file = File(path);
    if (!file.existsSync()) {
      throw ExecutorError(
        '文件不存在：$relative',
        code: LocalCodes.fileNotFound,
      );
    }
    if (FileSystemEntity.typeSync(path) == FileSystemEntityType.directory) {
      throw ExecutorError(
        '目标是目录，不能读取：$relative',
        code: LocalCodes.notAFile,
      );
    }
    final int size = file.lengthSync();
    // **分块下载通道**（`raw: true`）：二进制原样回 base64，不做行处理、不受
    // 8 MiB 的文本读取上限约束——调用方按 `offset` 递进、按 `eof` 收口。
    if (args['raw'] == true) {
      final int startOffset =
          ((args['offset'] as num?)?.toInt() ?? 0).clamp(0, 1 << 62);
      final int? length = (args['length'] as num?)?.toInt();
      final int want = length != null && length > 0 ? length : _kMaxReadBytes;
      final List<int> chunk = <int>[];
      if (startOffset < size) {
        final RandomAccessFile raf = file.openSync();
        try {
          raf.setPositionSync(startOffset);
          final int remaining = size - startOffset;
          final int take = remaining < want ? remaining : want;
          chunk.addAll(raf.readSync(take));
        } finally {
          raf.closeSync();
        }
      }
      return <String, dynamic>{
        'path': _relative(root, path),
        'base64': base64Encode(chunk),
        'offset': startOffset,
        'size': size,
        'eof': startOffset + chunk.length >= size,
      };
    }
    List<int> rawBytes;
    if (size > _kMaxReadBytes) {
      final RandomAccessFile raf = file.openSync();
      try {
        rawBytes = raf.readSync(_kMaxReadBytes);
      } finally {
        raf.closeSync();
      }
    } else {
      rawBytes = await file.readAsBytes();
    }
    final bool cappedBySize = rawBytes.length < size;
    String text;
    String? base64;
    try {
      text = utf8.decode(rawBytes);
    } on FormatException {
      text = '';
      base64 = base64Encode(rawBytes);
    }
    final List<String> lines = text.split('\n');
    final int total = text.isEmpty ? 0 : lines.length;
    final int start = ((args['start_line'] as num?)?.toInt() ?? 1);
    final int first = start < 1 ? 1 : (start > total ? total : start);
    final int? count = (args['line_count'] as num?)?.toInt();
    final int end = count != null && count > 0
        ? (first + count - 1 > total ? total : first + count - 1)
        : total;
    final String content = total == 0
        ? ''
        : lines.sublist(first - 1, end).join('\n');
    final bool truncated =
        cappedBySize || content.length > _kMaxReadTextChars;
    return <String, dynamic>{
      'path': _relative(root, path),
      'content': content.length > _kMaxReadTextChars
          ? content.substring(0, _kMaxReadTextChars)
          : content,
      'total_lines': total,
      'start_line': total == 0 ? 1 : first,
      'truncated': truncated,
      'base64': ?base64,
    };
  }

  Future<Map<String, dynamic>> _write(
    String root,
    Map<String, dynamic> args,
  ) async {
    final String relative = (args['path'] ?? args['file_path'] ?? '').toString();
    final String path = _resolve(root, relative);
    final String content = (args['content'] ?? '').toString();
    final File file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(content, flush: true);
    return <String, dynamic>{
      'path': _relative(root, path),
      'bytes_written': utf8.encode(content).length,
    };
  }

  Future<Map<String, dynamic>> _list(
    String root,
    Map<String, dynamic> args,
  ) async {
    final String relative = (args['path'] ?? '.').toString();
    final String base = _resolve(root, relative);
    final int maxDepth = ((args['max_depth'] as num?)?.toInt() ?? 2).clamp(0, 32);
    final int maxEntries = ((args['max_entries'] as num?)?.toInt() ?? 500).clamp(1, 5000);
    final List<String> entries = <String>[];
    // 与 `entries` 同序的元信息（文件面板要 size / mtime；`entries` 保持纯字符串
    // 是为了兼容既有调用方：tree.agent 的 WorkspaceIO 只吃字符串表）。
    final List<Map<String, dynamic>> details = <Map<String, dynamic>>[];
    void addDetail(FileSystemEntity entity, String rel, String type) {
      final FileStat stat = entity.statSync();
      details.add(<String, dynamic>{
        'name': rel,
        'type': type,
        if (type != 'dir') 'size': stat.size,
        'mtime_ms': stat.modified.millisecondsSinceEpoch,
      });
    }
    void walk(Directory dir, int depth) {
      if (entries.length >= maxEntries) return;
      final List<FileSystemEntity> children = dir.listSync(followLinks: false)
        ..sort((FileSystemEntity a, FileSystemEntity b) => a.path.compareTo(b.path));
      for (final FileSystemEntity child in children) {
        if (entries.length >= maxEntries) return;
        final String rel = _relative(root, child.path);
        if (child is Directory) {
          entries.add('$rel/');
          addDetail(child, rel, 'dir');
          if (depth < maxDepth) walk(child, depth + 1);
        } else if (child is File) {
          entries.add(rel);
          addDetail(child, rel, 'file');
        }
      }
    }
    final FileSystemEntityType type = FileSystemEntity.typeSync(base);
    if (type == FileSystemEntityType.directory) {
      walk(Directory(base), 0);
    } else if (type == FileSystemEntityType.file) {
      entries.add(_relative(root, base));
      addDetail(File(base), _relative(root, base), 'file');
    } else {
      throw ExecutorError(
        '路径不存在：$relative',
        code: LocalCodes.fileNotFound,
      );
    }
    return <String, dynamic>{
      'path': relative,
      'root': root,
      'entries': entries,
      'details': details,
      'count': entries.length,
      'truncated': entries.length >= maxEntries,
    };
  }

  Future<Map<String, dynamic>> _delete(
    String root,
    Map<String, dynamic> args,
  ) async {
    final String relative = (args['path'] ?? '').toString();
    final String path = _resolve(root, relative);
    final FileSystemEntityType type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) {
      throw ExecutorError(
        '路径不存在：$relative',
        code: LocalCodes.fileNotFound,
      );
    }
    final bool recursive = args['recursive'] == true;
    if (type == FileSystemEntityType.directory) {
      final Directory dir = Directory(path);
      if (!recursive && dir.listSync().isNotEmpty) {
        throw ExecutorError(
          '目录非空，删除需要 recursive=true：$relative',
          code: LocalCodes.dirNotEmpty,
        );
      }
      dir.deleteSync(recursive: recursive);
    } else {
      File(path).deleteSync();
    }
    return <String, dynamic>{'path': relative, 'deleted': true};
  }

  Future<Map<String, dynamic>> _mkdir(
    String root,
    Map<String, dynamic> args,
  ) async {
    final String relative = (args['path'] ?? '').toString();
    final String path = _resolve(root, relative);
    final Directory dir = Directory(path);
    if (!dir.existsSync()) {
      dir.createSync(recursive: args['recursive'] != false);
    }
    return <String, dynamic>{'path': relative, 'created': true};
  }

  Future<Map<String, dynamic>> _writeBytes(
    String root,
    Map<String, dynamic> args,
  ) async {
    final String relative = (args['path'] ?? '').toString();
    final String path = _resolve(root, relative);
    final String encoded = (args['base64'] ?? args['content_base64'] ?? '')
        .toString();
    if (encoded.isEmpty) {
      throw ExecutorError(
        'local.file.writeBytes 需要 base64（要写入的二进制）',
        code: LocalCodes.invalidArguments,
      );
    }
    final List<int> bytes;
    try {
      bytes = base64Decode(encoded);
    } on FormatException {
      throw ExecutorError(
        'local.file.writeBytes 的 base64 非法',
        code: LocalCodes.badBase64,
      );
    }
    final File file = File(path);
    await file.parent.create(recursive: true);
    // `append: true` = 分块写的后续块（第一块用默认 write 截断重建）。
    final bool append = args['append'] == true;
    await file.writeAsBytes(
      bytes,
      mode: append ? FileMode.append : FileMode.write,
      flush: true,
    );
    return <String, dynamic>{
      'path': _relative(root, path),
      'bytes_written': bytes.length,
      'appended': append,
    };
  }

  /// 原子重命名（与 SSH 侧同口径：源不存在 / 目标已存在都显式报错，绝不覆盖）。
  Future<Map<String, dynamic>> _rename(
    String root,
    Map<String, dynamic> args,
  ) async {
    final String from = (args['from'] ?? args['path'] ?? '').toString();
    final String to = (args['to'] ?? args['new_path'] ?? '').toString();
    if (from.trim().isEmpty || to.trim().isEmpty) {
      throw ExecutorError(
        'local.file.rename 需要 from 与 to',
        code: LocalCodes.invalidArguments,
      );
    }
    final String source = _resolve(root, from);
    final String target = _resolve(root, to);
    final FileSystemEntityType type = FileSystemEntity.typeSync(source);
    if (type == FileSystemEntityType.notFound) {
      throw ExecutorError(
        '文件不存在：$from',
        code: LocalCodes.fileNotFound,
      );
    }
    if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
      throw ExecutorError(
        '目标已存在，rename 不覆盖：$to',
        code: LocalCodes.targetExists,
      );
    }
    final String parent = p.dirname(target);
    if (!Directory(parent).existsSync()) {
      Directory(parent).createSync(recursive: true);
    }
    final FileSystemEntity moved = type == FileSystemEntityType.directory
        ? Directory(source).renameSync(target)
        : File(source).renameSync(target);
    return <String, dynamic>{
      'path': _relative(root, moved.path),
      'from': _relative(root, source),
      'to': _relative(root, moved.path),
    };
  }

  Future<Map<String, dynamic>> _grep(
    String root,
    Map<String, dynamic> args,
  ) async {
    final String pattern = (args['pattern'] ?? '').toString();
    if (pattern.isEmpty) {
      throw ExecutorError(
        'local.file.grep 需要 pattern',
        code: LocalCodes.invalidArguments,
      );
    }
    final bool regex = args['regex'] == true;
    final bool ignoreCase = args['ignore_case'] == true;
    final RegExp matcher = regex
        ? RegExp(pattern, caseSensitive: !ignoreCase)
        : RegExp(RegExp.escape(pattern), caseSensitive: !ignoreCase);
    final String relative = (args['path'] ?? '.').toString();
    final String base = _resolve(root, relative);
    final int maxDepth = ((args['max_depth'] as num?)?.toInt() ?? 0).clamp(0, 64);
    final int maxResults = ((args['max_results'] as num?)?.toInt() ?? 200).clamp(1, 5000);
    final bool includeHidden = args['include_hidden'] == true;
    final List<Map<String, dynamic>> matches = <Map<String, dynamic>>[];
    int scanned = 0;
    bool truncated = false;
    void scanFile(File file) {
      if (matches.length >= maxResults) return;
      final String rel = _relative(root, file.path);
      if (!includeHidden &&
          p.split(rel).any((String part) => part.startsWith('.'))) {
        return;
      }
      String text;
      try {
        text = utf8.decode(file.readAsBytesSync());
      } catch (_) {
        return;
      }
      scanned++;
      final List<String> lines = text.split('\n');
      for (int i = 0; i < lines.length; i++) {
        if (matcher.hasMatch(lines[i])) {
          matches.add(<String, dynamic>{
            'path': rel,
            'line': i + 1,
            'text': lines[i],
          });
          if (matches.length >= maxResults) {
            truncated = true;
            return;
          }
        }
      }
    }

    void walk(Directory dir, int depth) {
      if (matches.length >= maxResults) return;
      for (final FileSystemEntity child in dir.listSync(followLinks: false)) {
        if (child is Directory) {
          if (depth >= maxDepth && maxDepth > 0) continue;
          walk(child, depth + 1);
        } else if (child is File) {
          scanFile(child);
        }
      }
    }

    if (FileSystemEntity.typeSync(base) == FileSystemEntityType.directory) {
      walk(Directory(base), 0);
    } else if (FileSystemEntity.typeSync(base) == FileSystemEntityType.file) {
      scanFile(File(base));
    } else {
      throw ExecutorError(
        '路径不存在：$relative',
        code: LocalCodes.fileNotFound,
      );
    }
    return <String, dynamic>{
      'pattern': pattern,
      'count': matches.length,
      'matches': matches,
      'truncated': truncated,
      'scanned_file_count': scanned,
    };
  }

  Future<Map<String, dynamic>> _terminal(
    String root,
    Map<String, dynamic> args,
  ) async {
    final String command = (args['command'] ?? '').toString().trim();
    final String hookAction =
        (args['hook_action'] ?? '').toString().trim().toLowerCase();
    if (hookAction.isNotEmpty) {
      final String taskId = (args['task_id'] ?? '').toString().trim();
      final _HookTask? task = _hooks[taskId];
      if (task == null) {
        throw ExecutorError(
          '未知 task_id：$taskId（现有：${_hooks.keys.join('、')}）',
          code: LocalCodes.invalidArguments,
        );
      }
      if (hookAction == 'cancel') {
        if (!task.running) return task.statusPayload();
        await task.cancel();
        return task.statusPayload(prefix: '已请求终止');
      }
      if (hookAction == 'status') return task.statusPayload();
      throw ExecutorError(
        '未知 hook_action：$hookAction（可用：status / cancel）',
        code: LocalCodes.invalidArguments,
      );
    }
    if (args['hook'] == true) {
      if (command.isEmpty) {
        throw ExecutorError('command 不能为空', code: LocalCodes.invalidArguments);
      }
      return _startHook(root, command);
    }
    if (command.isEmpty) {
      throw ExecutorError(
        'local.exec.command 需要 command',
        code: LocalCodes.invalidArguments,
      );
    }
    final int softTimeout =
        ((args['timeout_seconds'] as num?)?.toInt() ?? 0);
    if (softTimeout > 0) {
      final Map<String, dynamic> started = await _startHook(root, command);
      final String taskId = (started['task_id'] ?? '').toString();
      final _HookTask task = _hooks[taskId]!;
      try {
        final int code = await task.exitCode!.timeout(
          Duration(seconds: softTimeout),
        );
        final String output = await task.readLog();
        _hooks.remove(taskId);
        return <String, dynamic>{
          'text': <String>[
            '退出码 $code',
            if (output.isNotEmpty) '--- 输出 ---',
            if (output.isNotEmpty) output.trimRight(),
          ].join('\n'),
          'is_error': code != 0,
          'exit_code': code,
        };
      } on TimeoutException {
        return <String, dynamic>{
          'text':
              '[terminal] 命令超过软超时 ${softTimeout}s，未终止；已转后台。\ntask_id: $taskId\n日志：${task.logRelative}（用 read 查看，或 hook_action=status + task_id 查询）',
          'is_error': false,
          'task_id': taskId,
          'log_relative': task.logRelative,
          'adopted': true,
        };
      }
    }
    final int timeout = ((args['timeout'] as num?)?.toInt() ?? 0);
    final bool windows = Platform.isWindows;
    final Process process = await Process.start(
      windows ? 'cmd' : '/bin/sh',
      windows ? <String>['/c', command] : <String>['-c', command],
      workingDirectory: root,
      runInShell: false,
    );
    final Future<String> stdout = process.stdout.transform(utf8.decoder).join();
    final Future<String> stderr = process.stderr.transform(utf8.decoder).join();
    int code;
    if (timeout > 0) {
      code = await process.exitCode.timeout(
        Duration(seconds: timeout),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
    } else {
      code = await process.exitCode;
    }
    final String out = await stdout;
    final String err = await stderr;
    final String text = <String>[
      if (out.isNotEmpty) out.trimRight(),
      if (err.isNotEmpty) err.trimRight(),
    ].join('\n');
    return <String, dynamic>{
      'text': text,
      'is_error': code != 0,
      'exit_code': code,
    };
  }

  Future<Map<String, dynamic>> _startHook(
    String root,
    String command,
  ) async {
    final String id =
        'hook_${++_hookSeq}_${DateTime.now().millisecondsSinceEpoch}';
    final String relative = '.self/hooks/$id.log';
    final File logFile = File(p.join(root, relative));
    await logFile.parent.create(recursive: true);
    final IOSink sink = logFile.openWrite();
    final bool windows = Platform.isWindows;
    final Process process = await Process.start(
      windows ? 'cmd' : '/bin/sh',
      windows ? <String>['/c', command] : <String>['-c', command],
      workingDirectory: root,
      runInShell: false,
    );
    final _HookTask task = _HookTask(
      id: id,
      command: command,
      process: process,
      logFile: logFile,
      logRelative: relative,
      sink: sink,
      startedAt: DateTime.now(),
    );
    _hooks[id] = task;
    process.stdout.listen(sink.add, onError: (_) {});
    process.stderr.listen(sink.add, onError: (_) {});
    task.exitCode = process.exitCode.then((int code) async {
      task.running = false;
      task.code = code;
      await task.closeSink();
      return code;
    });
    return <String, dynamic>{
      'text':
          '[terminal hook] 已在后台启动。\ntask_id: $id\n日志：$relative（用 read 查看，或 hook_action=status + task_id 查询）',
      'is_error': false,
      'running': true,
      'task_id': id,
      'log_relative': relative,
    };
  }

}
class _HookTask {
  _HookTask({
    required this.id,
    required this.command,
    required this.process,
    required this.logFile,
    required this.logRelative,
    required this.sink,
    required this.startedAt,
  });

  final String id;
  final String command;
  final Process process;
  final File logFile;
  final String logRelative;
  final IOSink sink;
  final DateTime startedAt;
  bool running = true;
  int? code;
  Future<int>? exitCode;

  Future<void> closeSink() async {
    try {
      await sink.flush();
      await sink.close();
    } catch (_) {}
  }

  Future<String> readLog() async {
    try {
      return await logFile.readAsString();
    } catch (_) {
      return '';
    }
  }

  Future<void> cancel() async {
    if (!running) return;
    if (Platform.isWindows) {
      await Process.run('taskkill', <String>[
        '/PID',
        process.pid.toString(),
        '/T',
        '/F',
      ]);
    } else {
      process.kill(ProcessSignal.sigterm);
    }
  }

  Future<Map<String, dynamic>> statusPayload({String prefix = ''}) async {
    String tail = '';
    try {
      if (logFile.existsSync()) {
        final String all = await logFile.readAsString();
        tail = all.length > 4000 ? all.substring(all.length - 4000) : all;
      }
    } catch (_) {}
    final String state = running
        ? '运行中'
        : '已结束（exit_code=${code?.toString() ?? '未知'}）';
    return <String, dynamic>{
      'text': <String>[
        if (prefix.isNotEmpty) prefix,
        'task_id: $id',
        '状态：$state',
        '命令：$command',
        '日志：$logRelative',
        if (tail.isNotEmpty) '--- 日志尾部 ---',
        if (tail.isNotEmpty) tail.trimRight(),
      ].join('\n'),
      'is_error': false,
      'running': running,
      if (code != null) 'exit_code': code,
    };
  }
}
