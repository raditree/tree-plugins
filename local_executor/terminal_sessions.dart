// 本机终端会话（L-26 定案）：REST 管会话，广播站推输出。
//
// 为什么不去核心加流原语：核心定位是调度微内核，PTY 是"具体工作"。
// 这里把 PTY 句柄、字节流与生命周期全部关在插件进程内，核心只转发
// `api/delegate` 与 `station/trigger`，不认识终端语义。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

// PTY 后端按"通用小件复制进插件仓"的纪律随插件分发（不依赖桌面仓）。
import 'package:tree_local_executor/src/pty/pty_session.dart';

/// 本机终端的委派路由（与 ssh 侧同形，用字面量 `local` 段区分归属）。
const String kSessionsPattern = '/api/terminal/local/sessions';
const String kSessionPattern = '/api/terminal/local/sessions/{sessionId}';
const String kSessionInputPattern =
    '/api/terminal/local/sessions/{sessionId}/input';
const String kSessionCancelPattern =
    '/api/terminal/local/sessions/{sessionId}/cancel';
const String kSessionResizePattern =
    '/api/terminal/local/sessions/{sessionId}/resize';

/// 全部申报路由（`system.collect.api.routes` 逐条回给核心）。
const List<Map<String, String>> kTerminalRoutes = <Map<String, String>>[
  <String, String>{'method': 'POST', 'pattern': kSessionsPattern},
  <String, String>{'method': 'DELETE', 'pattern': kSessionPattern},
  <String, String>{'method': 'POST', 'pattern': kSessionInputPattern},
  <String, String>{'method': 'POST', 'pattern': kSessionCancelPattern},
  <String, String>{'method': 'POST', 'pattern': kSessionResizePattern},
];

/// 输出广播站（核心拼成 `plugin.local_executor.broadcast.terminal`）。
const String kTerminalStationName = 'terminal';
const String kTerminalStationId = 'plugin.local_executor.broadcast.terminal';

const String kTerminalReadme =
    '本机终端输出站：topic = terminal.<session_id>.output / .exit。'
    'payload 是原终端帧（terminal_output 带 base64 bytes；terminal_exit 带 exit_code），'
    'UI 先经 REST 建会话，再订阅本站收输出；插件停用/崩溃时收到 closed。';

/// 一条在跑的终端会话。
class _TerminalSession {
  _TerminalSession(this.sessionId, this.pty, this.subscription);

  final String sessionId;
  final PtySession pty;
  final StreamSubscription<List<int>> subscription;
  bool closed = false;
}

/// 本机终端会话表（单实例；id 由调用方给，插件不猜业务身份）。
class TerminalSessions {
  TerminalSessions({required this.publish, this.log});

  /// (topic, payload) → 经 `station/trigger` 投到自建广播站。
  final Future<void> Function(String topic, Map<String, dynamic> payload)
  publish;
  final void Function(String message)? log;

  final Map<String, _TerminalSession> _sessions = <String, _TerminalSession>{};

  int get count => _sessions.length;

  /// 建会话。`cwd` 为空时用数据根（调用方通常传 workspace 绝对路径）。
  Future<Map<String, dynamic>> open({
    required String sessionId,
    String cwd = '',
    String shell = '',
    int columns = 80,
    int rows = 24,
  }) async {
    if (sessionId.trim().isEmpty) {
      throw StateError('session_id 不能为空');
    }
    if (_sessions.containsKey(sessionId)) {
      throw StateError('终端会话已存在：$sessionId');
    }
    final String dir = cwd.trim().isEmpty
        ? Directory.current.path
        : cwd.trim();
    final PtySession pty = await startPtySession(
      command: shell,
      workingDirectory: dir,
      columns: columns <= 0 ? 80 : columns,
      rows: rows <= 0 ? 24 : rows,
      log: log,
    );
    late final _TerminalSession session;
    final StreamSubscription<List<int>> sub = pty.output.listen(
      (List<int> bytes) {
        unawaited(
          publish('terminal.$sessionId.output', <String, dynamic>{
            'type': 'terminal_output',
            'terminal_id': sessionId,
            'bytes': base64Encode(bytes),
          }),
        );
      },
      onDone: () => _finish(sessionId, '输出流已结束'),
      onError: (Object error) => _finish(sessionId, error.toString()),
    );
    session = _TerminalSession(sessionId, pty, sub);
    _sessions[sessionId] = session;
    unawaited(
      pty.exitCode.then((int code) {
        unawaited(
          publish('terminal.$sessionId.exit', <String, dynamic>{
            'type': 'terminal_exit',
            'terminal_id': sessionId,
            'exit_code': code,
          }),
        );
        _sessions.remove(sessionId);
      }),
    );
    return <String, dynamic>{
      'session_id': sessionId,
      'shell': pty.shell,
      'cwd': dir,
      'columns': columns <= 0 ? 80 : columns,
      'rows': rows <= 0 ? 24 : rows,
    };
  }

  Future<void> input(String sessionId, List<int> bytes) async {
    await _require(sessionId).pty.write(bytes);
  }

  /// 取消当前前台进程：向 PTY 写 Ctrl+C（真实语义仍由 shell/程序决定）。
  Future<void> cancel(String sessionId) async {
    await _require(sessionId).pty.write(<int>[0x03]);
  }

  Future<void> resize(String sessionId, int columns, int rows) async {
    await _require(sessionId).pty.resize(columns, rows);
  }

  Future<void> close(String sessionId) async {
    final _TerminalSession? session = _sessions.remove(sessionId);
    if (session == null) return;
    await _dispose(session);
  }

  /// 插件下线：全部会话收掉（不留孤儿进程）。
  Future<void> closeAll() async {
    final List<_TerminalSession> all = _sessions.values.toList();
    _sessions.clear();
    for (final _TerminalSession session in all) {
      await _dispose(session);
    }
  }

  _TerminalSession _require(String sessionId) {
    final _TerminalSession? session = _sessions[sessionId];
    if (session == null) {
      throw StateError('终端会话不存在：$sessionId');
    }
    return session;
  }

  void _finish(String sessionId, String reason) {
    final _TerminalSession? session = _sessions.remove(sessionId);
    if (session == null) return;
    log?.call('终端会话 $sessionId 结束：$reason');
    unawaited(_dispose(session));
  }

  Future<void> _dispose(_TerminalSession session) async {
    if (session.closed) return;
    session.closed = true;
    await session.subscription.cancel();
    await session.pty.close();
  }
}
