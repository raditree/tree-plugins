import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_agent_loop/src/agent/scripted_agent.dart';
import 'package:tree_agent_loop/src/llm/llm_agent_engine.dart';
import 'package:tree_agent_loop/src/paths.dart';
import 'package:tree_agent_loop/src/runtime/agent_runtime.dart';
import 'package:tree_agent_loop/src/store/file_store.dart';
import 'package:tree_agent_loop/src/store/records.dart';
import 'package:tree_agent_loop/src/store/tree_paths.dart';
import 'package:tree_agent_loop/src/workspace/workspace_io.dart';

void main() {
  late Directory temp;
  late AgentDataPaths paths;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tree_agent_runtime_');
    paths = AgentDataPaths(temp.path);
    final FileTreeStore store = FileTreeStore(TreePaths(temp.path));
    store.putAgent(
      CoreAgent(id: 'agt', name: '夹具', createdAt: 1, updatedAt: 1, modelId: 'm1'),
    );
    await store.flush();
    await store.close();
    await AgentRuntime.debugCloseAll();
  });

  tearDown(() async {
    AgentRuntime.stationClient = null;
    AgentRuntime.workspaceRegister = null;
    await AgentRuntime.debugCloseAll();
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('sendMessage：新会话 + 落库 + 脚本回复 + 帧序列；第二次复用会话', () async {
    final AgentRuntime runtime = AgentRuntime(paths: paths, engine: ScriptedAgent(chunkDelay: Duration.zero));
    final Map<String, dynamic> first = (await runtime.sendMessage(
      agentId: 'agt',
      content: '你好',
    ))!;
    expect(first['success'], isTrue);
    expect(first['agent_id'], 'agt');
    expect(first['session_created'], isTrue);
    final String sessionId = first['session_id'] as String;
    expect(sessionId, isNotEmpty);
    await runtime.waitIdle();
    await runtime.store.flush();

    final List<CoreMessage> messages = FileTreeStore(
      TreePaths(paths.root),
    ).sessionMessages('agt', sessionId);
    expect(messages.first.role, 'user');
    expect(messages.first.content, '你好');
    expect(
      messages.where((CoreMessage m) => m.role == 'agent').single.content,
      contains('【占位回复】'),
    );
    expect(
      runtime.frames.any(
        (Map<String, dynamic> f) => f['type'] == 'session_created',
      ),
      isTrue,
    );
    final List<String> types = runtime.frames
        .map((Map<String, dynamic> f) => '${f['type']}')
        .toList();
    expect(types, containsAll(<String>['msg_start', 'msg_chunk', 'msg_end', 'agent_status']));

    final Map<String, dynamic> second = (await runtime.sendMessage(
      agentId: 'agt',
      content: '再来',
      sessionId: sessionId,
    ))!;
    expect(second['session_created'], isFalse);
    expect(second['session_id'], sessionId);
    await runtime.waitIdle();
  });

  test('工作空间租约：先 register 再让 fs.* 带 lease_id', () async {
    final AgentRuntime runtime = AgentRuntime(
      paths: paths,
      engine: ScriptedAgent(chunkDelay: Duration.zero),
    );
    final List<Map<String, dynamic>> registered = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> calls = <Map<String, dynamic>>[];
    AgentRuntime.workspaceRegister = (String id, String dir) async {
      registered.add(<String, dynamic>{'id': id, 'dir': dir});
    };
    AgentRuntime.stationClient = (
      String command,
      Map<String, dynamic> arguments,
      Map<String, dynamic> scope,
    ) async {
      calls.add(<String, dynamic>{
        'command': command,
        'arguments': arguments,
        'scope': scope,
      });
      return <String, dynamic>{
        'content': 'hello',
        'total_lines': 1,
        'start_line': 1,
        'truncated': false,
      };
    };
    final WorkspaceIO? io = await runtime.workspaceIoFor(
      'agt',
      'session_default',
    );
    expect(io, isNotNull);
    final content = await io!.readFile('a.txt');
    expect(content.text, 'hello');
    expect(registered, hasLength(1));
    expect(registered.single['dir'], contains(temp.path));
    expect(calls.single['command'], 'file.read');
    final Map<String, dynamic> args =
        calls.single['arguments'] as Map<String, dynamic>;
    expect(args['lease_id'], registered.single['id']);
    expect(args.containsKey('root'), isFalse, reason: 'root 由核心注入，不由 agent 传');

    await io.deleteFile('b.txt');
    final WorkspaceFiles files = io as WorkspaceFiles;
    await files.writeBytes('c.bin', <int>[1, 2, 3]);
    await files.makeDirectory('d');
    final List<String> commands = calls
        .map((Map<String, dynamic> call) => '${call['command']}')
        .toList();
    expect(commands, containsAll(<String>['file.delete', 'file.writeBytes', 'file.mkdir']));
  });

  test('reconnectSsh：经执行站下发 ssh.reconnect，带 agent 身份', () async {
    final AgentRuntime runtime = AgentRuntime(
      paths: paths,
      engine: ScriptedAgent(chunkDelay: Duration.zero),
    );
    final List<Map<String, dynamic>> calls = <Map<String, dynamic>>[];
    AgentRuntime.stationClient = (
      String command,
      Map<String, dynamic> arguments,
      Map<String, dynamic> scope,
    ) async {
      calls.add(<String, dynamic>{
        'command': command,
        'arguments': arguments,
        'scope': scope,
      });
      return <String, dynamic>{'ok': true, 'agent_id': 'agt', 'stale': true};
    };
    final Map<String, dynamic> result = await runtime.reconnectSsh('agt');
    expect(result['stale'], isTrue);
    expect(calls.single['command'], 'ssh.reconnect');
    expect((calls.single['arguments'] as Map)['agent_id'], 'agt');
    expect((calls.single['scope'] as Map)['agent_id'], 'agt');
  });

  test('默认引擎是 LlmAgentEngine（生产路径）；未知 agent 返回 null（端点 404）', () async {
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    expect(runtime.conversation.engine, isA<LlmAgentEngine>());
    expect(
      await runtime.sendMessage(agentId: 'ghost', content: '你好'),
      isNull,
    );
  });

  test('cancel：TOP 级联自身 + 成员；成员只停自己；空态仍回摘要', () async {
    final FileTreeStore store = FileTreeStore(TreePaths(paths.root));
    store.putAgent(
      CoreAgent(
        id: 'top',
        name: '指挥',
        createdAt: 2,
        updatedAt: 2,
        modelId: 'm1',
      ),
    );
    store.putAgent(
      CoreAgent(
        id: 'm1',
        name: '成员',
        createdAt: 3,
        updatedAt: 3,
        modelId: 'm1',
        teamId: 'top',
        parentAgentId: 'top',
        level: 1,
      ),
    );
    await store.flush();
    await store.close();
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    final Map<String, dynamic> top = runtime.cancel('top')!;
    expect(top['cascade'], isTrue);
    expect(top['cascade_ids'], <String>['top', 'm1']);
    expect(top['any_running'], isFalse);
    expect(top['idle'], containsAll(<String>['top', 'm1']));
    final Map<String, dynamic> member = runtime.cancel('m1')!;
    expect(member['cascade'], isFalse);
    expect(member['cascade_ids'], <String>['m1']);
    expect(runtime.cancel('ghost'), isNull);
  });
}
