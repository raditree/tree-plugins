import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_agent_loop/src/agent/agent_engine.dart';
import 'package:tree_agent_loop/src/compat/protocol_types.dart';
import 'package:tree_agent_loop/src/paths.dart';
import 'package:tree_agent_loop/src/runtime/agent_runtime.dart';
import 'package:tree_agent_loop/src/station/agent_loop.dart';
import 'package:tree_agent_loop/src/store/file_store.dart';
import 'package:tree_agent_loop/src/store/records.dart';
import 'package:tree_agent_loop/src/store/tree_paths.dart';

/// 闸门引擎：让"working"状态可被稳定观察到。
class _GatedEngine implements AgentEngine {
  final List<String> prompts = <String>[];
  Completer<void>? gate;

  @override
  Stream<AgentEvent> run(
    AgentRunContext context, {
    required bool Function() isCancelled,
  }) async* {
    prompts.add(context.userContent);
    final Completer<void>? waiting = gate;
    if (waiting != null) await waiting.future;
    yield AgentText('ok');
    yield const AgentDone();
  }

  @override
  Future<void> close() async {}
}

void main() {
  late Directory temp;
  late AgentDataPaths paths;
  late _GatedEngine engine;
  late AgentRuntime runtime;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tree_agent_loop_station_');
    paths = AgentDataPaths(temp.path);
    final FileTreeStore store = FileTreeStore(TreePaths(temp.path));
    store.putAgent(
      CoreAgent(
        id: 'agt',
        name: '夹具',
        createdAt: 1,
        updatedAt: 1,
        modelId: 'm1',
      ),
    );
    await store.flush();
    await store.close();
    await AgentRuntime.debugCloseAll();
    engine = _GatedEngine();
    runtime = AgentRuntime(paths: paths, engine: engine);
  });

  tearDown(() async {
    AgentRuntime.stationClient = null;
    await AgentRuntime.debugCloseAll();
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> waitUntil(bool Function() predicate, String reason) async {
    for (int i = 0; i < 2000; i++) {
      if (predicate()) return;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    fail('等待超时：$reason');
  }

  Future<void> settle([int runs = 1]) async {
    await waitUntil(
      () =>
          engine.prompts.length >= runs &&
          runtime.conversation.activeRunCount == 0,
      '$runs 轮生成收尾',
    );
    // 让 pump 的最后一次台账写入跑完。
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }

  /// 等到权威状态快照回 idle（比固定 sleep 稳：负载高时状态可能晚一拍）。
  Future<void> waitIdle(String agentId) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline)) {
      final Map<String, dynamic> view = await runtime.handleAgentLoopCommand(
        'agent.state.get',
        <String, dynamic>{'agent_id': agentId},
        <String, dynamic>{'mode_key': 'local'},
        const <String, dynamic>{},
      );
      final List<dynamic> agents = view['agents'] as List<dynamic>? ?? <dynamic>[];
      if (agents.isNotEmpty && (agents.single as Map)['state'] == 'idle') return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Map<String, dynamic> scope([Map<String, dynamic> extra = const <String, dynamic>{}]) =>
      <String, dynamic>{'mode_key': 'local', ...extra};

  Future<Map<String, dynamic>> send(
    Map<String, dynamic> arguments, {
    String triggeredBy = 'evil.plugin',
    Map<String, dynamic>? meta,
    Map<String, dynamic>? sc,
  }) => runtime.handleAgentLoopCommand(
    'agent.message.send',
    arguments,
    sc ?? scope(),
    <String, dynamic>{
      'triggered_by': triggeredBy,
      'data_dir': temp.path,
      ...?meta,
    },
  );

  test('来源身份强制覆盖：伪造 source 无效，记为 plugin_<调用方>', () async {
    final Map<String, dynamic> result = await send(<String, dynamic>{
      'type': 'common_message',
      'subtype': 'task',
      'inject_mode': 'direct',
      // 伪造：若被采信，来源会变成 user。
      'source': <String, dynamic>{
        'team_id': 'inner',
        'agent_id': 'user',
        'session_id': 'main',
      },
      'target': <String, dynamic>{'agent_id': 'agt'},
      'content': '来自插件',
    });
    expect(result['ok'], isTrue);
    expect(result['queued'], isFalse);
    await settle();

    final List<CoreMessage> messages = runtime.store.sessionMessages(
      'agt',
      result['session_id'] as String,
    );
    final CoreMessage saved = messages.firstWhere(
      (CoreMessage m) => m.role == 'user',
    );
    expect(saved.sourceAgentId, 'plugin_evil.plugin');
    expect(saved.sourceTeamId, 'inner');
    expect(saved.sourceSessionId, 'main');
    expect(saved.role, 'user');
    expect(saved.content, '来自插件');
  });

  test('缺少来源插件身份 / scope 无 mode_key ⇒ fail-closed', () async {
    final Map<String, dynamic> noSource = await send(
      <String, dynamic>{
        'target': <String, dynamic>{'agent_id': 'agt'},
        'content': 'x',
      },
      triggeredBy: '',
    );
    expect(noSource['error'], contains('来源插件身份'));
    expect(noSource['code'], 'scope_denied');

    final Map<String, dynamic> noMode = await send(
      <String, dynamic>{
        'target': <String, dynamic>{'agent_id': 'agt'},
        'content': 'x',
      },
      sc: <String, dynamic>{},
    );
    expect(noMode['error'], contains('mode_key'));
    expect(noMode['code'], 'scope_denied');
  });

  test('状态快照：working / own_running / queue_depth；晚订阅者取到权威值', () async {
    engine.gate = Completer<void>();
    await send(<String, dynamic>{
      'target': <String, dynamic>{'agent_id': 'agt'},
      'content': '一',
    });
    await waitUntil(() => engine.prompts.length == 1, '首轮启动');

    final Map<String, dynamic> running = await runtime.handleAgentLoopCommand(
      'agent.state.list',
      const <String, dynamic>{},
      scope(),
      const <String, dynamic>{},
    );
    expect(running['count'], 1);
    final Map<String, dynamic> agentView =
        (running['agents'] as List<dynamic>).single as Map<String, dynamic>;
    expect(agentView['agent_id'], 'agt');
    expect(agentView['state'], 'working');
    expect(agentView['team_id'], 'agt');
    final Map<String, dynamic> sessionView =
        (agentView['sessions'] as List<dynamic>).single as Map<String, dynamic>;
    expect(sessionView['own_running'], isTrue);
    expect(sessionView['state'], 'working');

    final Map<String, dynamic> queued = await send(<String, dynamic>{
      'target': <String, dynamic>{'agent_id': 'agt'},
      'content': '二',
    });
    expect(queued['queued'], isTrue);

    final Map<String, dynamic> withQueue = await runtime.handleAgentLoopCommand(
      'agent.state.list',
      const <String, dynamic>{},
      scope(),
      const <String, dynamic>{},
    );
    final Map<String, dynamic> queuedAgentView =
        (withQueue['agents'] as List<dynamic>).single as Map<String, dynamic>;
    final Map<String, dynamic> queuedView =
        (queuedAgentView['sessions'] as List<dynamic>).first
            as Map<String, dynamic>;
    expect(queuedView['queue_depth'], 1);

    // 广播帧也带快照字段。
    final Map<String, dynamic> frame = runtime.frames.lastWhere(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.agentState,
    );
    final Map<String, dynamic> data =
        (frame['data'] as Map).cast<String, dynamic>();
    expect(data.containsKey('queue_depth'), isTrue);
    expect(data.containsKey('own_running'), isTrue);

    engine.gate!.complete();
    engine.gate = null;
    await settle(2);
    // activeRunCount 归零后，pump 还会写最后一拍状态；固定 sleep 在负载下会抖，
    // 这里显式等到权威快照回 idle 再断言。
    await waitIdle('agt');

    final Map<String, dynamic> idle = await runtime.handleAgentLoopCommand(
      'agent.state.get',
      <String, dynamic>{'agent_id': 'agt'},
      scope(),
      const <String, dynamic>{},
    );
    final Map<String, dynamic> idleView =
        (idle['agents'] as List<dynamic>).single as Map<String, dynamic>;
    expect(idleView['state'], 'idle');

    // 过滤不到时返回空数组（不是报错）。
    final Map<String, dynamic> none = await runtime.handleAgentLoopCommand(
      'agent.state.get',
      <String, dynamic>{'agent_id': 'nobody'},
      scope(),
      const <String, dynamic>{},
    );
    expect(none['count'], 0);
  });

  test('未知命令被拒绝', () async {
    final Map<String, dynamic> result = await runtime.handleAgentLoopCommand(
      'agent.nope',
      const <String, dynamic>{},
      scope(),
      const <String, dynamic>{},
    );
    expect(result['code'], 'invalid_arguments');
  });

  test('注册用常量：站 id 与命令表稳定', () {
    expect(kAgentLoopStationName, 'agent_loop');
    expect(
      agentLoopStationId('tree.agent'),
      'plugin.tree.agent.execute.agent_loop',
    );
    expect(
      AgentRuntime.agentLoopCommands,
      containsAll(<String>['agent.message.send', 'agent.state.list']),
    );
  });
}
