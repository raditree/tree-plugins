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

  test('工作空间租约：先 local.lease.register，再让 local.* 带 local_lease_id', () async {
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
      if (command == 'local.lease.register') {
        return <String, dynamic>{
          'ok': true,
          'lease_id': arguments['local_lease_id'],
          'root': arguments['dir'],
        };
      }
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
    expect(calls, hasLength(2));
    expect(calls.first['command'], 'local.lease.register');
    final Map<String, dynamic> registerArgs =
        calls.first['arguments'] as Map<String, dynamic>;
    expect('${registerArgs['dir']}', contains(temp.path));
    expect(calls.last['command'], 'local.file.read');
    final Map<String, dynamic> args =
        calls.last['arguments'] as Map<String, dynamic>;
    expect(args['local_lease_id'], registerArgs['local_lease_id']);
    expect(args.containsKey('root'), isFalse, reason: 'root 只在执行器那张租约表里');
    expect(args.containsKey('lease_id'), isFalse, reason: '核心租约簿记已撤');

    await io.deleteFile('b.txt');
    final WorkspaceFiles files = io as WorkspaceFiles;
    await files.writeBytes('c.bin', <int>[1, 2, 3]);
    await files.makeDirectory('d');
    final List<String> commands = calls
        .map((Map<String, dynamic> call) => '${call['command']}')
        .toList();
    expect(
      commands,
      containsAll(<String>[
        'local.file.delete',
        'local.file.writeBytes',
        'local.file.mkdir',
      ]),
    );
    expect(
      commands.where((String c) => c == 'local.lease.register').length,
      1,
      reason: '同一个根只登记一次',
    );
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
