import 'dart:convert';

import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

/// SSH 工作空间执行站（`ssh_executor` 自建）的**站名段**。
///
/// 核心把自建站 id 拼成 `plugin.<plugin_id>.execute.<name>`（见
/// `PluginBus.selfBuiltStationId`），因此本插件注册出来的完整 id 是
/// `plugin.ssh_executor.execute.ssh_workspace`。
const String kSshWorkspaceStationName = 'ssh_workspace';

/// `ssh.lease.register`：登记一条**远端工作空间租约**（tree.agent 第一次用某个
/// SSH 工作空间时发一次；之后所有命令只带 `ssh_lease_id`）。
const String kSshLeaseRegisterCommand = 'ssh.lease.register';

/// 自建执行站的命令表（**与 `local_executor` 的 `file.*` / `exec.command` 语义对齐**）。
///
/// 为什么命令名要加 `ssh.` 前缀，而不是直接复用 `file.read`：
/// 核心 `station/command` **只按命令名全局查执行站**（`StationPoints.ownerOfCommand` →
/// 自建站命令表），而 `local_executor` 已经登记了 `file.*` / `exec.command`；
/// 同名会被核心以“已被其它插件执行站占用”拒绝，也分不清该走本机还是远端。
/// 所以本插件用独立的 `ssh.*` 命令族，由 tree.agent 在 SSH 模式下改写命令名后下发。
const List<String> kSshWorkspaceCommands = <String>[
  kSshLeaseRegisterCommand,
  'ssh.file.read',
  'ssh.file.write',
  'ssh.file.list',
  'ssh.file.grep',
  'ssh.file.delete',
  'ssh.file.mkdir',
  'ssh.file.writeBytes',
  'ssh.exec.command',
];

/// 站介绍（`station/register` 的 `readme` 必填；面板的站点详情直接展示）。
const String kSshWorkspaceStationReadme =
    'SSH 工作空间执行站（ssh_executor 自建）：tree.agent 在 SSH 模式下把 '
    'file.* / exec.command 改写成 ssh.* 后经核心下发到这里。插件先按 ssh 配置'
    '建/复用一条既有中转站隧道，再把命令翻译成目标机 tree_agent 的 fs.* / exec.run；'
    '路径校验用「远端根 + 工作空间内相对路径」，插件不碰本机文件、不起本机进程。'
    '租约由 ssh.lease.register 登记（凭据只在登记时过线一次），插件重启后命令会回 '
    'ssh_lease_unknown，调用方应重新登记。';

/// 核心拼出的自建站 id（与 `PluginBus.selfBuiltStationId` 同形；自检/测试可用）。
String sshWorkspaceStationId(String pluginId) =>
    'plugin.$pluginId.execute.$kSshWorkspaceStationName';

/// 执行站命令失败（可读中文；由 [SshWorkspaceExecutor.execute] 的调用方转成
/// `{reply: {error: ...}}`，与 `local_executor` 的错误面同形）。
class SshStationError implements Exception {
  SshStationError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一次 SSH 工作空间租约：远端根 + 隧道会话（插件进程内有效）。
class _SshLease {
  _SshLease({
    required this.leaseId,
    required this.connId,
    required this.root,
    required this.ssh,
  });

  final String leaseId;
  final String connId;

  /// 目标机上的**绝对**工作空间根（`agent.hello.root`；越界校验的基线）。
  final String root;

  /// 登记时的 SSH 配置（**含凭据**，只在本插件内存里；不回给调用方）。
  final Map<String, dynamic> ssh;
}

/// 租约未登记 / 插件重启过：调用方应重新 `ssh.lease.register` 再重试一次。
///
/// 这个前缀是**契约**：tree.agent 只在看到它时丢弃缓存租约并重登记重试
/// （其它失败可能是 `file.write` 写了一半之类的业务错误，**绝不重试**）。
const String kSshLeaseUnknownCode = 'ssh_lease_unknown';

/// `ssh.file.read` 单次最多读的原文（8 MiB）：租约命令没有分块数据面，
/// 超过这个量级应改用 `ssh.exec.command`（head/tail）——真实大文件读取是后续 TODO。
const int _kMaxReadBytes = 8 * 1024 * 1024;

/// `ssh.file.read` 返回文本的上限（与 `local_executor` 的 512 KiB 同口径）。
const int _kMaxReadTextChars = 512 * 1024;

/// SSH 工作空间命令执行器：把 `local_executor` 的 `file.*` / `exec.command` 契约
/// **翻译成目标机 tree_agent 的 L2 方法**（`fs.*` / `exec.run`）。
///
/// 依赖注入两个窄回调（生产由 [PluginLoop] 接到 `TunnelManager`；测试用假隧道）：
/// - [ensureTunnel]：入参是 L1 `tunnel.ensure` 的 `config` 对象，回
///   `{ok, conn_id, root, agent}`；
/// - [requestAgent]：转发一条 L2 请求，回 `{ok: true, result: {...}}` 或
///   `{ok: false, error, error_kind?}`（`TunnelManager.request` 的形状）。
class SshWorkspaceExecutor {
  SshWorkspaceExecutor({
    required this.ensureTunnel,
    required this.requestAgent,
    this.log,
  });

  final Future<Map<String, dynamic>> Function(Map<String, dynamic> config)
  ensureTunnel;
  final Future<Map<String, dynamic>> Function(
    String connId,
    String method,
    Map<String, dynamic> params,
  )
  requestAgent;
  final void Function(String message)? log;

  final Map<String, _SshLease> _leases = <String, _SshLease>{};

  /// 已登记的租约数（诊断 / 测试）。
  int get leaseCount => _leases.length;

  /// 执行一条命令；失败抛 [SshStationError]（调用方转成 `reply.error`）。
  Future<Map<String, dynamic>> execute(
    String command,
    Map<String, dynamic> arguments,
  ) async {
    switch (command) {
      case kSshLeaseRegisterCommand:
        return _registerLease(arguments);
      case 'ssh.file.read':
        return _read(await _leaseOf(arguments), arguments);
      case 'ssh.file.write':
        return _write(await _leaseOf(arguments), arguments);
      case 'ssh.file.list':
        return _list(await _leaseOf(arguments), arguments);
      case 'ssh.file.grep':
        return _grep(await _leaseOf(arguments), arguments);
      case 'ssh.file.delete':
        return _delete(await _leaseOf(arguments), arguments);
      case 'ssh.file.mkdir':
        return _mkdir(await _leaseOf(arguments), arguments);
      case 'ssh.file.writeBytes':
        return _writeBytes(await _leaseOf(arguments), arguments);
      case 'ssh.exec.command':
        return _terminal(await _leaseOf(arguments), arguments);
      default:
        throw SshStationError('SSH 工作空间执行站不支持命令：$command');
    }
  }

  // ───────────────────────── 租约 ─────────────────────────

  /// `ssh.lease.register`：`{ssh: {...}, root?: string, ssh_lease_id?: string}`
  /// → `{ok, lease_id, conn_id, root, host, agent}`。
  Future<Map<String, dynamic>> _registerLease(
    Map<String, dynamic> arguments,
  ) async {
    final Map<String, dynamic> ssh = _asMap(arguments['ssh']);
    if (ssh.isEmpty) {
      throw SshStationError(
        'ssh.lease.register 需要 ssh 配置对象（host / username / 凭据）',
      );
    }
    final Map<String, dynamic> ensured = await ensureTunnel(ssh);
    if (ensured['ok'] != true) {
      throw SshStationError('建立 SSH 隧道失败：${ensured['error'] ?? '未给出原因'}');
    }
    final String connId = (ensured['conn_id'] ?? '').toString().trim();
    if (connId.isEmpty) {
      throw SshStationError('建立 SSH 隧道失败：核心未回 conn_id');
    }
    final String root = (ensured['root'] ?? '').toString().trim();
    if (!root.startsWith('/')) {
      throw SshStationError('远端工作空间根不是绝对路径：${root.isEmpty ? '(空)' : root}');
    }
    final String requested =
        (arguments['ssh_lease_id'] ?? arguments['lease_id'] ?? '')
            .toString()
            .trim();
    final String leaseId = requested.isNotEmpty
        ? requested
        : _leaseIdFor(ssh, root);
    _leases[leaseId] = _SshLease(
      leaseId: leaseId,
      connId: connId,
      root: root,
      ssh: ssh,
    );
    log?.call(
      'SSH 工作空间租约登记：$leaseId → $root（$connId，'
      '${(ssh['host'] ?? '').toString()}）',
    );
    return <String, dynamic>{
      'ok': true,
      'lease_id': leaseId,
      'conn_id': connId,
      'root': root,
      'host': (ssh['host'] ?? '').toString(),
      'agent': ensured['agent'] ?? const <String, dynamic>{},
    };
  }

  /// 取命令要用的租约：优先 `ssh_lease_id`；只有带完整 `ssh` 配置时才允许自动登记。
  Future<_SshLease> _leaseOf(Map<String, dynamic> arguments) async {
    final String leaseId =
        (arguments['ssh_lease_id'] ?? arguments['lease_id'] ?? '')
            .toString()
            .trim();
    if (leaseId.isNotEmpty) {
      final _SshLease? cached = _leases[leaseId];
      if (cached != null) return cached;
      final Map<String, dynamic> ssh = _asMap(arguments['ssh']);
      if (ssh.isNotEmpty) {
        await _registerLease(<String, dynamic>{
          ...arguments,
          'ssh': ssh,
          'ssh_lease_id': leaseId,
        });
        return _leases[leaseId]!;
      }
      throw SshStationError(
        '$kSshLeaseUnknownCode: 租约 $leaseId 未登记（插件进程可能重启过；'
        '请重新 ssh.lease.register）',
      );
    }
    final Map<String, dynamic> ssh = _asMap(arguments['ssh']);
    if (ssh.isEmpty) {
      throw SshStationError('缺少 ssh_lease_id（先 ssh.lease.register）或 ssh 配置');
    }
    await _registerLease(arguments);
    final String registered = (arguments['ssh_lease_id'] ?? '')
        .toString()
        .trim();
    if (registered.isNotEmpty && _leases.containsKey(registered)) {
      return _leases[registered]!;
    }
    return _leases.values.last;
  }

  /// 确定性租约 id（同一 host/port/user/root/login_shell 复用同一条）。
  String _leaseIdFor(Map<String, dynamic> ssh, String root) {
    final String identity = <String>[
      (ssh['host'] ?? '').toString(),
      (ssh['port'] ?? 22).toString(),
      (ssh['username'] ?? '').toString(),
      root,
      ssh.containsKey('login_shell') ? '${ssh['login_shell']}' : '~',
    ].join('|');
    return 'ssh_ws_${base64Url.encode(utf8.encode(identity)).replaceAll('=', '')}';
  }

  // ───────────────────────── file.read ─────────────────────────

  Future<Map<String, dynamic>> _read(
    _SshLease lease,
    Map<String, dynamic> arguments,
  ) async {
    final String relative = (arguments['path'] ?? arguments['file_path'] ?? '')
        .toString();
    final String path = _absPath(lease, relative);
    final Map<String, dynamic> stat = await _call(
      lease,
      AgentMethods.fsStat,
      <String, dynamic>{'path': path},
    );
    final String type = (stat['type'] ?? '').toString();
    if (type == 'missing') throw SshStationError('文件不存在：$relative');
    if (type == 'dir') throw SshStationError('目标是目录，不能读取：$relative');
    final _ReadResult read = await _readAll(lease, path);
    String text;
    String? encoded;
    try {
      text = utf8.decode(read.bytes);
    } on FormatException {
      text = '';
      encoded = base64Encode(read.bytes);
    }
    final List<String> lines = text.split('\n');
    final int total = text.isEmpty ? 0 : lines.length;
    final int start = (arguments['start_line'] as num?)?.toInt() ?? 1;
    final int first = start < 1 ? 1 : (start > total ? total : start);
    final int? count = (arguments['line_count'] as num?)?.toInt();
    final int end = count != null && count > 0
        ? (first + count - 1 > total ? total : first + count - 1)
        : total;
    final String content = total == 0
        ? ''
        : lines.sublist(first - 1, end).join('\n');
    final bool truncated =
        read.truncatedByCap || content.length > _kMaxReadTextChars;
    return <String, dynamic>{
      'path': _relativePath(lease, path),
      'content': content.length > _kMaxReadTextChars
          ? content.substring(0, _kMaxReadTextChars)
          : content,
      'total_lines': total,
      'start_line': total == 0 ? 1 : first,
      'truncated': truncated,
      'base64': ?encoded,
    };
  }

  Future<_ReadResult> _readAll(_SshLease lease, String path) async {
    final List<int> bytes = <int>[];
    int offset = 0;
    bool capped = false;
    while (true) {
      final int remaining = _kMaxReadBytes - bytes.length;
      if (remaining <= 0) {
        capped = true;
        break;
      }
      final int want = remaining < kReadChunkBytes
          ? remaining
          : kReadChunkBytes;
      final Map<String, dynamic> result = await _call(
        lease,
        AgentMethods.fsRead,
        <String, dynamic>{'path': path, 'offset': offset, 'length': want},
      );
      final String data = (result['data'] ?? '').toString();
      final List<int> chunk = data.isEmpty ? const <int>[] : base64Decode(data);
      bytes.addAll(chunk);
      offset += chunk.length;
      if (result['eof'] == true) break;
      if (chunk.isEmpty) {
        // 没数据、也没 eof：不猜，按“已读到当前尾部”收口（agent 的契约不应出现）。
        break;
      }
    }
    return _ReadResult(bytes: bytes, truncatedByCap: capped);
  }

  // ───────────────────────── file.write / writeBytes ─────────────────────────

  Future<Map<String, dynamic>> _write(
    _SshLease lease,
    Map<String, dynamic> arguments,
  ) async {
    final String relative = (arguments['path'] ?? arguments['file_path'] ?? '')
        .toString();
    final String path = _absPath(lease, relative);
    final String content = (arguments['content'] ?? '').toString();
    final List<int> bytes = utf8.encode(content);
    await _ensureParent(lease, path);
    final Map<String, dynamic> result = await _call(
      lease,
      AgentMethods.fsWrite,
      <String, dynamic>{
        'path': path,
        'data': base64Encode(bytes),
        'mode': 'write',
        'flush': true,
      },
    );
    return <String, dynamic>{
      'path': _relativePath(lease, path),
      'bytes_written': (result['size'] as num?)?.toInt() ?? bytes.length,
    };
  }

  Future<Map<String, dynamic>> _writeBytes(
    _SshLease lease,
    Map<String, dynamic> arguments,
  ) async {
    final String relative = (arguments['path'] ?? arguments['file_path'] ?? '')
        .toString();
    final String path = _absPath(lease, relative);
    final String encoded =
        (arguments['base64'] ?? arguments['content_base64'] ?? '').toString();
    if (encoded.isEmpty) {
      throw SshStationError('ssh.file.writeBytes 需要 base64（要写入的二进制）');
    }
    final List<int> bytes;
    try {
      bytes = base64Decode(encoded);
    } on FormatException {
      throw SshStationError('ssh.file.writeBytes 的 base64 非法');
    }
    await _ensureParent(lease, path);
    final Map<String, dynamic> result = await _call(
      lease,
      AgentMethods.fsWrite,
      <String, dynamic>{
        'path': path,
        'data': base64Encode(bytes),
        'mode': 'write',
        'flush': true,
      },
    );
    return <String, dynamic>{
      'path': _relativePath(lease, path),
      'bytes_written': (result['size'] as num?)?.toInt() ?? bytes.length,
    };
  }

  Future<void> _ensureParent(_SshLease lease, String path) async {
    final String parent = _posixDirname(path);
    if (parent.isEmpty || parent == path || parent == lease.root) return;
    await _call(lease, AgentMethods.fsMkdir, <String, dynamic>{
      'path': parent,
      'recursive': true,
    });
  }

  // ───────────────────────── file.list ─────────────────────────

  Future<Map<String, dynamic>> _list(
    _SshLease lease,
    Map<String, dynamic> arguments,
  ) async {
    final String relative = (arguments['path'] ?? '.').toString();
    final String base = _absPath(lease, relative.isEmpty ? '.' : relative);
    final int maxDepth = ((arguments['max_depth'] as num?)?.toInt() ?? 2).clamp(
      0,
      32,
    );
    final int maxEntries = ((arguments['max_entries'] as num?)?.toInt() ?? 500)
        .clamp(1, 5000);
    final Map<String, dynamic> stat = await _call(
      lease,
      AgentMethods.fsStat,
      <String, dynamic>{'path': base},
    );
    final String type = (stat['type'] ?? '').toString();
    if (type == 'missing') throw SshStationError('路径不存在：$relative');
    final List<String> entries = <String>[];
    if (type != 'dir') {
      entries.add(_relativePath(lease, base));
    } else {
      await _walkEntries(lease, base, '', 0, maxDepth, maxEntries, entries);
    }
    return <String, dynamic>{
      'path': relative,
      'root': lease.root,
      'entries': entries,
      'count': entries.length,
      'truncated': entries.length >= maxEntries,
    };
  }

  Future<void> _walkEntries(
    _SshLease lease,
    String dir,
    String prefix,
    int depth,
    int maxDepth,
    int maxEntries,
    List<String> entries,
  ) async {
    if (entries.length >= maxEntries) return;
    final Map<String, dynamic> result = await _call(
      lease,
      AgentMethods.fsListEntries,
      <String, dynamic>{'path': dir, 'max_entries': maxEntries},
    );
    final Object? raw = result['entries'];
    final List<Map<String, dynamic>> children =
        <Map<String, dynamic>>[
          if (raw is List)
            for (final Object? item in raw)
              if (item is Map) _asMap(item),
        ]..sort(
          (Map<String, dynamic> a, Map<String, dynamic> b) => (a['name'] ?? '')
              .toString()
              .compareTo((b['name'] ?? '').toString()),
        );
    for (final Map<String, dynamic> child in children) {
      if (entries.length >= maxEntries) return;
      final String name = (child['name'] ?? '').toString();
      if (name.isEmpty || name == '.' || name == '..') continue;
      final String relative = prefix.isEmpty ? name : '$prefix/$name';
      final String childType = (child['type'] ?? '').toString();
      if (childType == 'dir') {
        entries.add('$relative/');
        if (depth < maxDepth) {
          await _walkEntries(
            lease,
            _posixJoin(dir, name),
            relative,
            depth + 1,
            maxDepth,
            maxEntries,
            entries,
          );
        }
      } else if (childType == 'file') {
        entries.add(relative);
      }
      // 链接与其它类型不列（与 local_executor 的 walk（只认 Directory / File）同口径）。
    }
  }

  // ───────────────────────── file.grep ─────────────────────────

  Future<Map<String, dynamic>> _grep(
    _SshLease lease,
    Map<String, dynamic> arguments,
  ) async {
    final String pattern = (arguments['pattern'] ?? '').toString();
    if (pattern.isEmpty) throw SshStationError('ssh.file.grep 需要 pattern');
    final bool regex = arguments['regex'] == true;
    final bool ignoreCase = arguments['ignore_case'] == true;
    final RegExp matcher = regex
        ? RegExp(pattern, caseSensitive: !ignoreCase)
        : RegExp(RegExp.escape(pattern), caseSensitive: !ignoreCase);
    final String relative = (arguments['path'] ?? '.').toString();
    final String base = _absPath(lease, relative.isEmpty ? '.' : relative);
    final int maxDepth = ((arguments['max_depth'] as num?)?.toInt() ?? 0).clamp(
      0,
      64,
    );
    final int maxResults = ((arguments['max_results'] as num?)?.toInt() ?? 200)
        .clamp(1, 5000);
    final bool includeHidden = arguments['include_hidden'] == true;
    final Map<String, dynamic> stat = await _call(
      lease,
      AgentMethods.fsStat,
      <String, dynamic>{'path': base},
    );
    final String type = (stat['type'] ?? '').toString();
    if (type == 'missing') throw SshStationError('路径不存在：$relative');

    final List<String> files = <String>[];
    if (type == 'dir') {
      await _collectFiles(lease, base, '', 0, maxDepth, includeHidden, files);
    } else {
      files.add(base);
    }
    final List<Map<String, dynamic>> matches = <Map<String, dynamic>>[];
    int scanned = 0;
    bool truncated = false;
    for (final String file in files) {
      if (matches.length >= maxResults) {
        truncated = true;
        break;
      }
      final _ReadResult read;
      try {
        read = await _readAll(lease, file);
      } on SshStationError {
        continue;
      }
      final String text;
      try {
        text = utf8.decode(read.bytes);
      } on FormatException {
        continue;
      }
      scanned++;
      final String rel = _relativePath(lease, file);
      final List<String> lines = text.split('\n');
      for (int i = 0; i < lines.length; i++) {
        if (!matcher.hasMatch(lines[i])) continue;
        matches.add(<String, dynamic>{
          'path': rel,
          'line': i + 1,
          'text': lines[i],
        });
        if (matches.length >= maxResults) {
          truncated = true;
          break;
        }
      }
    }
    return <String, dynamic>{
      'pattern': pattern,
      'count': matches.length,
      'matches': matches,
      'truncated': truncated,
      'scanned_file_count': scanned,
    };
  }

  Future<void> _collectFiles(
    _SshLease lease,
    String dir,
    String prefix,
    int depth,
    int maxDepth,
    bool includeHidden,
    List<String> files,
  ) async {
    final Map<String, dynamic> result = await _call(
      lease,
      AgentMethods.fsListEntries,
      <String, dynamic>{'path': dir, 'max_entries': 5000},
    );
    final Object? raw = result['entries'];
    final List<Map<String, dynamic>> children =
        <Map<String, dynamic>>[
          if (raw is List)
            for (final Object? item in raw)
              if (item is Map) _asMap(item),
        ]..sort(
          (Map<String, dynamic> a, Map<String, dynamic> b) => (a['name'] ?? '')
              .toString()
              .compareTo((b['name'] ?? '').toString()),
        );
    for (final Map<String, dynamic> child in children) {
      final String name = (child['name'] ?? '').toString();
      if (name.isEmpty || name == '.' || name == '..') continue;
      if (!includeHidden && name.startsWith('.')) continue;
      final String relative = prefix.isEmpty ? name : '$prefix/$name';
      final String childType = (child['type'] ?? '').toString();
      if (childType == 'dir') {
        if (maxDepth == 0 || depth < maxDepth) {
          await _collectFiles(
            lease,
            _posixJoin(dir, name),
            relative,
            depth + 1,
            maxDepth,
            includeHidden,
            files,
          );
        }
      } else if (childType == 'file') {
        files.add(_posixJoin(dir, name));
      }
    }
  }

  // ───────────────────────── file.delete / mkdir ─────────────────────────

  Future<Map<String, dynamic>> _delete(
    _SshLease lease,
    Map<String, dynamic> arguments,
  ) async {
    final String relative = (arguments['path'] ?? '').toString();
    final String path = _absPath(lease, relative);
    final Map<String, dynamic> stat = await _call(
      lease,
      AgentMethods.fsStat,
      <String, dynamic>{'path': path},
    );
    final String type = (stat['type'] ?? '').toString();
    if (type == 'missing') throw SshStationError('路径不存在：$relative');
    final bool recursive = arguments['recursive'] == true;
    if (type == 'dir') {
      if (!recursive) {
        final Map<String, dynamic> listed = await _call(
          lease,
          AgentMethods.fsListEntries,
          <String, dynamic>{'path': path, 'max_entries': 1},
        );
        final Object? entries = listed['entries'];
        if (entries is List && entries.isNotEmpty) {
          throw SshStationError('目录非空，删除需要 recursive=true：$relative');
        }
      }
      await _call(lease, AgentMethods.fsRemove, <String, dynamic>{
        'path': path,
        'recursive': recursive,
      });
    } else {
      await _call(lease, AgentMethods.fsDelete, <String, dynamic>{
        'path': path,
      });
    }
    return <String, dynamic>{'path': relative, 'deleted': true};
  }

  Future<Map<String, dynamic>> _mkdir(
    _SshLease lease,
    Map<String, dynamic> arguments,
  ) async {
    final String relative = (arguments['path'] ?? '').toString();
    final String path = _absPath(lease, relative);
    await _call(lease, AgentMethods.fsMkdir, <String, dynamic>{
      'path': path,
      'recursive': arguments['recursive'] != false,
    });
    return <String, dynamic>{'path': relative, 'created': true};
  }

  // ───────────────────────── exec.command ─────────────────────────

  Future<Map<String, dynamic>> _terminal(
    _SshLease lease,
    Map<String, dynamic> arguments,
  ) async {
    final String hookAction = (arguments['hook_action'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (hookAction.isNotEmpty) {
      throw SshStationError(
        'SSH 工作空间执行站暂不支持 hook_action（$hookAction）：'
        '后台任务台账属后续切片（TODO：接 agent 的 exec.list / exec.query / exec.kill）',
      );
    }
    if (arguments['hook'] == true) {
      throw SshStationError(
        'SSH 工作空间执行站暂不支持后台 hook：'
        '后续切片接 agent 的 exec.spawn / exec.list / exec.query / exec.kill',
      );
    }
    final String command = (arguments['command'] ?? '').toString().trim();
    if (command.isEmpty) throw SshStationError('ssh.exec.command 需要 command');
    final int timeoutSeconds =
        (arguments['timeout_seconds'] as num?)?.toInt() ?? 0;
    final int timeout = (arguments['timeout'] as num?)?.toInt() ?? 0;
    final int timeoutMs = timeout > 0 ? timeout * 1000 : timeoutSeconds * 1000;
    final Map<String, dynamic> result = await _call(
      lease,
      AgentMethods.execRun,
      <String, dynamic>{
        'command': command,
        if (timeoutMs > 0) 'timeout_ms': timeoutMs,
      },
    );
    final String stdout = _decodeStream(result['stdout']);
    final String stderr = _decodeStream(result['stderr']);
    final int exitCode = (result['exit_code'] as num?)?.toInt() ?? -1;
    final String text = <String>[
      if (stdout.trimRight().isNotEmpty) stdout.trimRight(),
      if (stderr.trimRight().isNotEmpty) stderr.trimRight(),
    ].join('\n');
    return <String, dynamic>{
      'text': text,
      'is_error': exitCode != 0,
      'exit_code': exitCode,
      if (result['truncated'] == true) 'truncated': true,
      if (result['timed_out'] == true) 'timed_out': true,
    };
  }

  // ───────────────────────── 基础设施 ─────────────────────────

  Future<Map<String, dynamic>> _call(
    _SshLease lease,
    String method,
    Map<String, dynamic> params,
  ) async {
    final Map<String, dynamic> reply = await requestAgent(
      lease.connId,
      method,
      params,
    );
    if (reply['ok'] != true) {
      final String reason = (reply['error'] ?? '未知失败').toString();
      final Object? kind = reply['error_kind'];
      throw SshStationError(
        kind == null ? reason : '$reason（${kind.toString()}）',
      );
    }
    final Object? result = reply['result'];
    return result is Map ? _asMap(result) : <String, dynamic>{};
  }

  /// 工作空间内相对路径 → 目标机绝对路径（越界校验与 agent 侧同一口径）。
  String _absPath(_SshLease lease, Object? raw) {
    final String relative = (raw ?? '').toString().trim();
    if (relative.isEmpty) {
      throw SshStationError('缺少 path（工作空间内相对路径）');
    }
    if (relative.startsWith('/')) {
      throw SshStationError('path 必须是工作空间内相对路径：$relative');
    }
    final String root = lease.root.endsWith('/')
        ? lease.root.substring(0, lease.root.length - 1)
        : lease.root;
    final String absolute = normalizePosixPath('$root/$relative');
    if (!isWithinRoot(absolute, lease.root)) {
      throw SshStationError('path 越出工作空间根目录：$relative');
    }
    return absolute;
  }

  String _relativePath(_SshLease lease, String absolute) {
    final String root = lease.root.endsWith('/')
        ? lease.root.substring(0, lease.root.length - 1)
        : lease.root;
    if (absolute == root || absolute == lease.root) return '.';
    final String prefix = root.isEmpty ? '/' : '$root/';
    return absolute.startsWith(prefix)
        ? absolute.substring(prefix.length)
        : absolute;
  }

  static String _decodeStream(Object? raw) {
    final String encoded = (raw ?? '').toString();
    if (encoded.isEmpty) return '';
    try {
      return utf8.decode(base64Decode(encoded), allowMalformed: true);
    } on FormatException {
      return '';
    }
  }

  static Map<String, dynamic> _asMap(Object? raw) {
    if (raw is! Map) return <String, dynamic>{};
    return <String, dynamic>{
      for (final MapEntry<Object?, Object?> entry in raw.entries)
        entry.key.toString(): entry.value,
    };
  }

  static String _posixDirname(String path) {
    final int index = path.lastIndexOf('/');
    if (index < 0) return '';
    if (index == 0) return '/';
    return path.substring(0, index);
  }

  static String _posixJoin(String dir, String name) {
    if (dir.isEmpty || dir == '/') return '/$name';
    return dir.endsWith('/') ? '$dir$name' : '$dir/$name';
  }
}

class _ReadResult {
  const _ReadResult({required this.bytes, required this.truncatedByCap});

  final List<int> bytes;
  final bool truncatedByCap;
}
