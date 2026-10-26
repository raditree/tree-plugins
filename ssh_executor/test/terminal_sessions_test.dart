import 'dart:convert';

import 'package:test/test.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'package:tree_ssh_plugin/src/exec_station.dart';
import 'package:tree_ssh_plugin/src/terminal_sessions.dart';

/// 记录发往"目标机 agent"的每条 L2 请求，并按方法回固定形状。
class _FakeAgent {
  final List<Map<String, dynamic>> calls = <Map<String, dynamic>>[];
  Map<String, dynamic> reply = <String, dynamic>{
    'ok': true,
    'result': <String, dynamic>{'shell_id': 'sh-1', 'pty': true},
  };

  Future<Map<String, dynamic>> call(
    String connId,
    String method,
    Map<String, dynamic> params,
  ) async {
    calls.add(<String, dynamic>{
      'conn_id': connId,
      'method': method,
      'params': params,
    });
    return reply;
  }

  Map<String, dynamic>? lastOf(String method) {
    for (final Map<String, dynamic> call in calls.reversed) {
      if (call['method'] == method) return call;
    }
    return null;
  }
}

void main() {
  const SshLeaseTarget lease = SshLeaseTarget(
    leaseId: 'lease-1',
    connId: 'conn-1',
    root: '/srv/app',
    host: '10.0.0.6',
  );

  late _FakeAgent agent;
  late List<Map<String, dynamic>> published;
  late SshTerminalSessions sessions;

  setUp(() {
    agent = _FakeAgent();
    published = <Map<String, dynamic>>[];
    sessions = SshTerminalSessions(
      requestAgent: agent.call,
      leaseOfId: (String id) => id == lease.leaseId ? lease : null,
      leaseOfHost: (String host, String username) =>
          host == lease.host ? lease : null,
      publish: (String topic, Map<String, dynamic> payload) async {
        published.add(<String, dynamic>{'topic': topic, ...payload});
      },
    );
  });

  test('按 ssh_lease_id 建会话：带 cwd / 尺寸，回包带 shell 与 host', () async {
    final Map<String, dynamic> opened = await sessions.open(
      sessionId: 'term_1',
      body: <String, dynamic>{
        'ssh_lease_id': 'lease-1',
        'cwd': '/srv/app/sub',
        'columns': 120,
        'rows': 30,
      },
    );

    final Map<String, dynamic> call = agent.lastOf(AgentMethods.shellOpen)!;
    expect(call['conn_id'], 'conn-1');
    final Map<String, dynamic> params =
        call['params'] as Map<String, dynamic>;
    expect(params['cwd'], '/srv/app/sub');
    expect(params['columns'], 120);
    expect(params['rows'], 30);
    expect(opened['session_id'], 'term_1');
    expect(opened['host'], '10.0.0.6');
    expect(sessions.count, 1);
  });

  test('没给租约时按 host 找已建立的连接（UI 拿不到密码）', () async {
    await sessions.open(
      sessionId: 'term_2',
      body: <String, dynamic>{'host': '10.0.0.6', 'username': 'root'},
    );
    expect(agent.lastOf(AgentMethods.shellOpen), isNotNull);
  });

  test('找不到租约 ⇒ 409，不偷偷回退本机', () async {
    await expectLater(
      sessions.open(
        sessionId: 'term_3',
        body: <String, dynamic>{'host': '192.168.1.9'},
      ),
      throwsA(
        isA<SshTerminalError>()
            .having((SshTerminalError e) => e.status, 'status', 409),
      ),
    );
    expect(agent.calls, isEmpty);
  });

  test('输入 / 取消 / 调整尺寸都转发到同一个 shell', () async {
    await sessions.open(
      sessionId: 'term_4',
      body: <String, dynamic>{'ssh_lease_id': 'lease-1'},
    );
    await sessions.input('term_4', utf8.encode('ls\r'));
    final Map<String, dynamic> write =
        agent.lastOf(AgentMethods.shellWrite)!['params'] as Map<String, dynamic>;
    expect(write['shell_id'], 'sh-1');
    expect(base64Decode(write['data'] as String), utf8.encode('ls\r'));

    await sessions.cancel('term_4');
    await sessions.resize('term_4', 100, 40);

    final List<Map<String, dynamic>> writes = agent.calls
        .where((Map<String, dynamic> c) => c['method'] == AgentMethods.shellWrite)
        .map((Map<String, dynamic> c) => c['params'] as Map<String, dynamic>)
        .toList();
    expect(base64Decode(writes.last['data'] as String), <int>[0x03]);

    final Map<String, dynamic> resize =
        agent.lastOf(AgentMethods.shellResize)!['params']
            as Map<String, dynamic>;
    expect(resize['columns'], 100);
    expect(resize['rows'], 40);
  });

  test('远端事件按会话转成广播帧；exit 会收起会话', () async {
    await sessions.open(
      sessionId: 'term_5',
      body: <String, dynamic>{'ssh_lease_id': 'lease-1'},
    );

    sessions.handleEvent(<String, dynamic>{
      'kind': TunnelEventKind.shellData,
      'shell_id': 'sh-1',
      'data': base64Encode(utf8.encode('hi')),
    });
    sessions.handleEvent(<String, dynamic>{
      'kind': TunnelEventKind.shellExit,
      'shell_id': 'sh-1',
      'exit_code': 7,
    });
    await Future<void>.delayed(Duration.zero);

    expect(published[0]['topic'], 'terminal.term_5.output');
    expect(published[0]['type'], 'terminal_output');
    expect(published[0]['terminal_id'], 'term_5');
    expect(published[1]['topic'], 'terminal.term_5.exit');
    expect(published[1]['type'], 'terminal_exit');
    expect(published[1]['exit_code'], 7);
    expect(sessions.count, 0);
  });

  test('别的 shell 的事件不归本插件管（不拦、不误发）', () async {
    await sessions.open(
      sessionId: 'term_6',
      body: <String, dynamic>{'ssh_lease_id': 'lease-1'},
    );
    expect(sessions.ownsShell('other-shell'), isFalse);
    sessions.handleEvent(<String, dynamic>{
      'kind': TunnelEventKind.shellData,
      'shell_id': 'other-shell',
      'data': 'AA==',
    });
    await Future<void>.delayed(Duration.zero);
    expect(published, isEmpty);
  });

  test('close 会通知远端关 shell 并清掉会话', () async {
    await sessions.open(
      sessionId: 'term_7',
      body: <String, dynamic>{'ssh_lease_id': 'lease-1'},
    );
    await sessions.close('term_7');

    final Map<String, dynamic> close =
        agent.lastOf(AgentMethods.shellClose)!['params'] as Map<String, dynamic>;
    expect(close['shell_id'], 'sh-1');
    expect(sessions.count, 0);
    expect(sessions.ownsShell('sh-1'), isFalse);
  });

  test('远端回 ok:false ⇒ 502（不假装会话建好了）', () async {
    agent.reply = <String, dynamic>{'ok': false, 'error': '没有 PTY'};
    await expectLater(
      sessions.open(
        sessionId: 'term_8',
        body: <String, dynamic>{'ssh_lease_id': 'lease-1'},
      ),
      throwsA(
        isA<SshTerminalError>()
            .having((SshTerminalError e) => e.status, 'status', 502),
      ),
    );
    expect(sessions.count, 0);
  });
}
