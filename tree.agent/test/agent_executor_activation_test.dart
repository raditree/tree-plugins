import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_agent_loop/src/delegate.dart';
import 'package:tree_agent_loop/src/paths.dart';
import 'package:tree_agent_loop/src/runtime/agent_runtime.dart';
import 'package:tree_agent_loop/src/settings/ssh_config.dart';
import 'package:tree_agent_loop/src/station/agent_executor.dart';
import 'package:tree_agent_loop/src/store/file_store.dart';
import 'package:tree_agent_loop/src/store/records.dart';
import 'package:tree_agent_loop/src/store/tree_paths.dart';

/// 「激活指定 agent 执行器」：执行站命令与 REST 共用同一实现。
///
/// 钉住三件事：
/// 1. **local 只检查**：建工作空间、验证可写、回设备信息，**不**下任何执行站命令；
/// 2. **ssh 真激活**：经 `ssh.lease.register` 建连并回租约句柄，重复激活走缓存；
/// 3. **统一回包**：成败都在 `ok` 上；REST 层只做状态码映射（404 / 502 / 200）。
void main() {
  late Directory temp;
  late AgentDataPaths paths;
  late List<Map<String, dynamic>> calls;

  Future<void> seedAgents() async {
    final FileTreeStore store = FileTreeStore(TreePaths(temp.path));
    store.putAgent(
      CoreAgent(
        id: 'local_agt',
        name: '本机',
        createdAt: 1,
        updatedAt: 1,
        modelId: 'm1',
      ),
    );
    store.putAgent(
      CoreAgent(
        id: 'ssh_agt',
        name: '远端',
        createdAt: 2,
        updatedAt: 2,
        modelId: 'm1',
        sshConfig: SshConfig(
          host: '10.0.0.9',
          username: 'tester',
          password: 'secret',
          root: '/srv/app',
        ),
      ),
    );
    await store.flush();
    await store.close();
  }

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tree_agent_activate_');
    paths = AgentDataPaths(temp.path);
    await seedAgents();
    await AgentRuntime.debugCloseAll();
    calls = <Map<String, dynamic>>[];
    AgentRuntime.workspaceRegister = (String id, String dir) async {};
    AgentRuntime.stationClient =
        (
          String command,
          Map<String, dynamic> arguments,
          Map<String, dynamic> scope,
        ) async {
          calls.add(<String, dynamic>{
            'command': command,
            'arguments': arguments,
            'scope': scope,
          });
          if (command == 'ssh.lease.register') {
            return <String, dynamic>{
              'ok': true,
              'lease_id': arguments['ssh_lease_id'],
              'conn_id': 'conn-ssh-1',
              'root': '/srv/app',
            };
          }
          return <String, dynamic>{'ok': true};
        };
  });

  tearDown(() async {
    AgentRuntime.stationClient = null;
    AgentRuntime.workspaceRegister = null;
    await AgentRuntime.debugCloseAll();
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {
      // Windows 偶发占用：临时目录交给系统清理。
    }
  });

  test('local：建工作空间 + 可写检查 + 设备信息，且不下执行站命令', () async {
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    final Map<String, dynamic> result = await runtime.handleAgentExecutorCommand(
      kActivateExecutorCommand,
      <String, dynamic>{'agent_id': 'local_agt'},
      <String, dynamic>{},
    );

    expect(result['ok'], isTrue);
    expect(result['mode'], 'local');
    expect(result['executor'], 'local_executor');
    final String workspace = result['workspace'] as String;
    expect(Directory(workspace).existsSync(), isTrue);
    expect(workspace, contains('workspaces'));
    final Map<String, dynamic> device =
        (result['device'] as Map).cast<String, dynamic>();
    expect('${device['os']}'.isNotEmpty, isTrue);
    expect('${device['hostname']}'.isNotEmpty, isTrue);
    expect(result['text'], contains('本机执行器就绪'));
    expect(calls, isEmpty, reason: 'local 是检查，不该有任何远端调用');
  });

  test('ssh：真激活（ssh.lease.register），回租约句柄；重复激活走缓存', () async {
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    final Map<String, dynamic> first = await runtime.activateAgentExecutor(
      'ssh_agt',
    );

    expect(first['ok'], isTrue);
    expect(first['mode'], 'ssh');
    expect(first['executor'], 'ssh_executor');
    expect(first['root'], '/srv/app');
    expect(first['conn_id'], 'conn-ssh-1');
    expect(first['host'], '10.0.0.9');
    expect('${first['ssh_lease_id']}'.isNotEmpty, isTrue);
    expect(calls.length, 1);
    expect(calls.single['command'], 'ssh.lease.register');
    final Map<String, dynamic> sent =
        (calls.single['arguments'] as Map).cast<String, dynamic>();
    final Map<String, dynamic> ssh =
        (sent['ssh'] as Map).cast<String, dynamic>();
    expect(ssh['host'], '10.0.0.9');
    expect(ssh['password'], 'secret');

    final Map<String, dynamic> second = await runtime.activateAgentExecutor(
      'ssh_agt',
    );
    expect(second['ok'], isTrue);
    expect(second['ssh_lease_id'], first['ssh_lease_id']);
    expect(calls.length, 1, reason: '同一份 SSH 配置不该重复建连');
  });

  test('scope.agent_id 可作为参数兜底；缺 id / 未知 agent 都回统一失败形状', () async {
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    final Map<String, dynamic> byScope = await runtime
        .handleAgentExecutorCommand(
          kActivateExecutorCommand,
          <String, dynamic>{},
          <String, dynamic>{'agent_id': 'local_agt'},
        );
    expect(byScope['ok'], isTrue);

    final Map<String, dynamic> missing = await runtime
        .handleAgentExecutorCommand(
          kActivateExecutorCommand,
          <String, dynamic>{},
          <String, dynamic>{},
        );
    expect(missing['ok'], isFalse);
    expect(missing['error'], contains('缺少 agent_id'));

    final Map<String, dynamic> ghost = await runtime.activateAgentExecutor(
      'ghost',
    );
    expect(ghost['ok'], isFalse);
    expect(ghost['error'], contains('agent 不存在'));
  });

  test('未知命令回 ok:false（不静默成功）', () async {
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    final Map<String, dynamic> result = await runtime
        .handleAgentExecutorCommand(
          'executor.explode',
          <String, dynamic>{'agent_id': 'local_agt'},
          <String, dynamic>{},
        );
    expect(result['ok'], isFalse);
    expect(result['error'], contains('不支持命令'));
  });

  test('REST：POST /api/agents/{id}/activate → 200 / 404', () async {
    final Map<String, dynamic> ok = await handleApiDelegate(
      _envelope(paths, 'local_agt'),
    );
    expect(ok['status'], 200);
    final Map<String, dynamic> body = _bodyOf(ok);
    expect(body['ok'], isTrue);
    expect(body['mode'], 'local');

    final Map<String, dynamic> ghost = await handleApiDelegate(
      _envelope(paths, 'ghost'),
    );
    expect(ghost['status'], 404);
    expect(_bodyOf(ghost)['detail'], contains('agent 不存在'));
  });
}

Map<String, dynamic> _envelope(AgentDataPaths paths, String agentId) =>
    <String, dynamic>{
      'method': 'POST',
      'path': '/api/agents/$agentId/activate',
      'params': <String, dynamic>{'agentId': agentId},
      'query': <String, dynamic>{},
      'headers': <String, dynamic>{},
      'scope': <String, dynamic>{},
      'workspace_dir': '',
      'data_dir': paths.root,
      'agent_id': agentId,
      'team_id': '',
      'request_id': 'test-activate-$agentId',
      'body': '{}',
    };

Map<String, dynamic> _bodyOf(Map<String, dynamic> reply) =>
    (jsonDecode('${reply['body'] ?? '{}'}') as Map).cast<String, dynamic>();
