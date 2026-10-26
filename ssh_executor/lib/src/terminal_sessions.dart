import 'dart:async';
import 'dart:convert';

import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'exec_station.dart';

/// SSH 终端会话（L-26 定案）：REST 管会话，广播站推输出。
///
/// PTY 在**目标机**上（`tree_agent` 的 `shell.*`），本插件只持有 shell_id 与到目标机
/// 的那条常驻通道；核心既不开 PTY，也不认识终端语义，只转发 `api/delegate` 与
/// `station/trigger`。
///
/// 凭据问题：UI 拿不到 SSH 密码（`GET /api/agents/{id}` 刻意不回显），所以这里
/// **复用 tree.agent 已登记的租约**（`ssh.lease.register` 建好的连接）——按
/// `ssh_lease_id` 精确找，或按 `host`（+`username`）找最近一条。找不到就如实报错，
/// 不偷偷回退到本机。
const String kSshSessionsPattern = '/api/terminal/ssh/sessions';
const String kSshSessionPattern = '/api/terminal/ssh/sessions/{sessionId}';
const String kSshSessionInputPattern =
    '/api/terminal/ssh/sessions/{sessionId}/input';
const String kSshSessionCancelPattern =
    '/api/terminal/ssh/sessions/{sessionId}/cancel';
const String kSshSessionResizePattern =
    '/api/terminal/ssh/sessions/{sessionId}/resize';

/// 全部申报路由（`system.collect.api.routes` 逐条回给核心）。
const List<Map<String, String>> kSshTerminalRoutes = <Map<String, String>>[
  <String, String>{'method': 'POST', 'pattern': kSshSessionsPattern},
  <String, String>{'method': 'DELETE', 'pattern': kSshSessionPattern},
  <String, String>{'method': 'POST', 'pattern': kSshSessionInputPattern},
  <String, String>{'method': 'POST', 'pattern': kSshSessionCancelPattern},
  <String, String>{'method': 'POST', 'pattern': kSshSessionResizePattern},
];

/// 输出广播站（核心拼成 `plugin.ssh_executor.broadcast.terminal`）。
const String kSshTerminalStationName = 'terminal';
const String kSshTerminalStationId = 'plugin.ssh_executor.broadcast.terminal';

const String kSshTerminalReadme =
    'SSH 终端输出站：topic = terminal.<session_id>.output / .exit。'
    'payload 是原终端帧（terminal_output 带 base64 bytes；terminal_exit 带 exit_code），'
    'UI 先经 REST 建会话，再订阅本站收输出；插件停用/崩溃时收到 closed。';

/// 终端会话的可读失败（[status] 直接映射成 REST 状态码）。
class SshTerminalError implements Exception {
  SshTerminalError(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => message;
}

class _SshTerminal {
  _SshTerminal({
    required this.sessionId,
    required this.connId,
    required this.shellId,
  });

  final String sessionId;
  final String connId;
  final String shellId;
}

/// SSH 终端会话表（单实例；id 由调用方给，插件不猜业务身份）。
class SshTerminalSessions {
  SshTerminalSessions({
    required this.requestAgent,
    required this.leaseOfId,
    required this.leaseOfHost,
    required this.publish,
    this.log,
  });

  /// 转发一条 L2 请求（`TunnelManager.request` 的形状）。
  final Future<Map<String, dynamic>> Function(
    String connId,
    String method,
    Map<String, dynamic> params,
  )
  requestAgent;

  /// 按租约 id 找连接（找不到 = null）。
  final SshLeaseTarget? Function(String leaseId) leaseOfId;

  /// 按 host（+可选 username）找最近登记的租约（找不到 = null）。
  final SshLeaseTarget? Function(String host, String username) leaseOfHost;

  /// (topic, payload) → 经 `station/trigger` 投到自建广播站。
  final Future<void> Function(String topic, Map<String, dynamic> payload)
  publish;

  final void Function(String message)? log;

  final Map<String, _SshTerminal> _sessions = <String, _SshTerminal>{};

  /// `shell_id` → `session_id`（远端 `shell.data` / `shell.exit` 只带 shell_id）。
  final Map<String, String> _byShell = <String, String>{};

  int get count => _sessions.length;

  /// 这个 shell 是不是本插件开的会话（事件出口据此决定走广播站还是原路）。
  bool ownsShell(String shellId) => _byShell.containsKey(shellId.trim());

  /// 建会话。`body` 见 `_resolveLease`（`ssh_lease_id` 或 `host`+`username`）。
  Future<Map<String, dynamic>> open({
    required String sessionId,
    required Map<String, dynamic> body,
  }) async {
    if (sessionId.trim().isEmpty) {
      throw SshTerminalError(400, 'session_id 不能为空');
    }
    if (_sessions.containsKey(sessionId)) {
      throw SshTerminalError(409, '终端会话已存在：$sessionId');
    }
    final SshLeaseTarget lease = _resolveLease(body);
    final int columns = (body['columns'] as num?)?.toInt() ?? 80;
    final int rows = (body['rows'] as num?)?.toInt() ?? 24;
    final String cwd = (body['cwd'] ?? '').toString().trim();
    final String command = (body['shell'] ?? body['command'] ?? '').toString().trim();
    final Map<String, dynamic> reply = await requestAgent(
      lease.connId,
      AgentMethods.shellOpen,
      <String, dynamic>{
        if (cwd.isNotEmpty) 'cwd': cwd,
        if (command.isNotEmpty) 'command': command,
        'columns': columns <= 0 ? 80 : columns,
        'rows': rows <= 0 ? 24 : rows,
      },
    );
    if (reply['ok'] != true) {
      throw SshTerminalError(
        502,
        '远端打开终端失败：${reply['error'] ?? '未给出原因'}',
      );
    }
    final Map<String, dynamic> result = _asMap(reply['result']);
    final String shellId = (result['shell_id'] ?? '').toString().trim();
    if (shellId.isEmpty) {
      throw SshTerminalError(502, '远端未返回 shell_id（agent 版本过旧？）');
    }
    _sessions[sessionId] = _SshTerminal(
      sessionId: sessionId,
      connId: lease.connId,
      shellId: shellId,
    );
    _byShell[shellId] = sessionId;
    log?.call('SSH 终端会话建立：$sessionId → ${lease.host}（shell $shellId）');
    return <String, dynamic>{
      'session_id': sessionId,
      'shell': command.isEmpty ? 'login shell' : command,
      'cwd': cwd.isEmpty ? lease.root : cwd,
      'columns': columns <= 0 ? 80 : columns,
      'rows': rows <= 0 ? 24 : rows,
      'host': lease.host,
    };
  }

  Future<void> input(String sessionId, List<int> bytes) async {
    final _SshTerminal session = _require(sessionId);
    final Map<String, dynamic> reply = await requestAgent(
      session.connId,
      AgentMethods.shellWrite,
      <String, dynamic>{
        'shell_id': session.shellId,
        'data': base64Encode(bytes),
      },
    );
    _expectOk(reply, '写入终端');
  }

  /// 取消当前前台进程：向 PTY 写 Ctrl+C（真实语义仍由远端程序决定）。
  Future<void> cancel(String sessionId) => input(sessionId, <int>[0x03]);

  Future<void> resize(String sessionId, int columns, int rows) async {
    final _SshTerminal session = _require(sessionId);
    final Map<String, dynamic> reply = await requestAgent(
      session.connId,
      AgentMethods.shellResize,
      <String, dynamic>{
        'shell_id': session.shellId,
        'columns': columns,
        'rows': rows,
      },
    );
    _expectOk(reply, '调整终端尺寸');
  }

  Future<void> close(String sessionId) async {
    final _SshTerminal? session = _sessions.remove(sessionId);
    if (session == null) return;
    _byShell.remove(session.shellId);
    try {
      await requestAgent(session.connId, AgentMethods.shellClose, <String, dynamic>{
        'shell_id': session.shellId,
      });
    } catch (error) {
      log?.call('关闭 SSH 终端会话出错（忽略）：$error');
    }
  }

  /// 插件下线：全部会话收掉（远端进程不留孤儿）。
  Future<void> closeAll() async {
    final List<String> ids = _sessions.keys.toList(growable: false);
    for (final String id in ids) {
      await close(id);
    }
  }

  /// 处理隧道层的 `shell.data` / `shell.exit`（由 `PluginLoop` 的事件出口转来）。
  ///
  /// 只认**本插件开的** shell（[_byShell] 里有），其它 shell（旧核心时代的会话）不拦。
  void handleEvent(Map<String, dynamic> event) {
    final String kind = (event['kind'] ?? '').toString();
    final String shellId = (event['shell_id'] ?? '').toString();
    if (shellId.isEmpty) return;
    final String? sessionId = _byShell[shellId];
    if (sessionId == null) return;
    if (kind == TunnelEventKind.shellData) {
      final Object? data = event['data'];
      if (data == null || '$data'.isEmpty) return;
      unawaited(
        publish('terminal.$sessionId.output', <String, dynamic>{
          'type': 'terminal_output',
          'terminal_id': sessionId,
          'bytes': '$data',
        }),
      );
      return;
    }
    if (kind == TunnelEventKind.shellExit) {
      _byShell.remove(shellId);
      _sessions.remove(sessionId);
      unawaited(
        publish('terminal.$sessionId.exit', <String, dynamic>{
          'type': 'terminal_exit',
          'terminal_id': sessionId,
          'exit_code': (event['exit_code'] as num?)?.toInt() ?? 0,
        }),
      );
    }
  }

  /// 租约解析：`ssh_lease_id` 精确匹配 → `host`(+`username`) 找最近一条。
  ///
  /// 两条都不成立就**显式失败**（409）：UI 没有凭据，凭空建不了新连接；
  /// 悄悄回退本机会让用户以为自己在改远端。
  SshLeaseTarget _resolveLease(Map<String, dynamic> body) {
    final String leaseId = (body['ssh_lease_id'] ?? body['lease_id'] ?? '')
        .toString()
        .trim();
    if (leaseId.isNotEmpty) {
      final SshLeaseTarget? found = leaseOfId(leaseId);
      if (found == null) {
        throw SshTerminalError(
          409,
          '$kSshLeaseUnknownCode: 租约 $leaseId 未登记（插件进程可能重启过），'
          '请先在该工作区执行一次操作再开终端',
        );
      }
      return found;
    }
    final String host = (body['host'] ?? '').toString().trim();
    final String username = (body['username'] ?? '').toString().trim();
    final SshLeaseTarget? found = leaseOfHost(host, username);
    if (found == null) {
      throw SshTerminalError(
        409,
        '没有可复用的 SSH 连接（host=${host.isEmpty ? '(未给)' : host}）：'
        '请先在该工作区执行一次操作，或显式提供 ssh_lease_id',
      );
    }
    return found;
  }

  _SshTerminal _require(String sessionId) {
    final _SshTerminal? session = _sessions[sessionId];
    if (session == null) {
      throw SshTerminalError(404, '终端会话不存在：$sessionId');
    }
    return session;
  }

  void _expectOk(Map<String, dynamic> reply, String action) {
    if (reply['ok'] == true) return;
    throw SshTerminalError(502, '$action失败：${reply['error'] ?? '未给出原因'}');
  }

  static Map<String, dynamic> _asMap(Object? raw) {
    if (raw is! Map) return <String, dynamic>{};
    return raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
  }
}
