import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_agent_loop/src/agent/agent_instance.dart';
import 'package:tree_agent_loop/src/message/inbox_ledger.dart';
import 'package:tree_agent_loop/src/paths.dart';

import 'fake_transport.dart';
import 'ported_core.dart';

/// 一次响应带 **两个** 工具调用的脚本（FakeTransport 遇到 finish 就停，不能拼两段）。
List<LlmStreamEvent> twoToolCalls() => const <LlmStreamEvent>[
  LlmToolCallDelta(index: 0, id: 'c1', name: 'a'),
  LlmToolCallDelta(index: 0, argumentsDelta: '{}'),
  LlmToolCallDelta(index: 1, id: 'c2', name: 'b'),
  LlmToolCallDelta(index: 1, argumentsDelta: '{}'),
  LlmFinishEvent('tool_calls'),
];

/// 记录 `specsFor` 调用次数的工具执行器（验证工具表快照）。
class _CountingRunner implements ToolRunner {
  int specsCalls = 0;

  @override
  List<ToolSpec> specsFor({
    required String agentId,
    required String sessionId,
  }) {
    specsCalls++;
    return const <ToolSpec>[];
  }

  @override
  Future<ToolOutcome> run(
    ToolInvocation invocation, {
    bool Function()? isCancelled,
  }) async => const ToolOutcome('ok');

  @override
  Future<void> close() async {}
}

/// 模拟"两跳 + 一次工具批"的引擎：在工具批里放一个闸门，测试可在批中途投消息。
class _LoopingEngine implements AgentEngine {
  final List<String> runInputs = <String>[];
  final List<List<String>> hopInputs = <List<String>>[];
  Completer<void>? toolGate;
  int toolStarts = 0;
  int runs = 0;

  @override
  Stream<AgentEvent> run(
    AgentRunContext context, {
    required bool Function() isCancelled,
  }) async* {
    runs++;
    final int runIndex = runs;
    runInputs.add(context.userContent);
    final List<String> hops = <String>[];
    hopInputs.add(hops);
    for (int turn = 0; turn < 3; turn++) {
      if (turn > 0) {
        final AgentInputBatch batch =
            context.pullInputs?.call() ?? const AgentInputBatch();
        hops.addAll(batch.history.map((CoreMessageRef r) => r.content));
      }
      yield AgentText('run$runIndex-hop$turn');
      toolStarts++;
      yield AgentToolStart(
        id: 'tool_$runIndex$turn',
        callId: 'call_$runIndex$turn',
        name: 'noop',
        arguments: const <String, dynamic>{},
      );
      if (turn == 0 && runIndex == 1 && toolGate != null) {
        await toolGate!.future;
        toolGate = null;
      }
      yield AgentToolEnd(
        id: 'tool_$runIndex$turn',
        name: 'noop',
        result: 'ok',
        modelContent: 'ok',
      );
      // 与真实 loop 同口径：整个工具批跑完后才询问是否终止。
      if (context.shouldTerminate?.call() ?? false) {
        yield const AgentDone(finishReason: 'terminated');
        return;
      }
      if (turn >= 1) {
        yield const AgentDone(finishReason: 'stop');
        return;
      }
    }
    yield const AgentDone(finishReason: 'stop');
  }

  @override
  Future<void> close() async {}
}

void main() {
  final CoreModelConfig config = CoreModelConfig(
    modelId: 'demo',
    name: '演示',
    baseUrl: 'https://api.example.com/v1',
    apiKey: 'sk-test',
    maxSeqlen: 64000,
    maxOutputTokens: 512,
  );

  LlmSession session(
    FakeTransport transport, {
    ToolRunner? tools,
    Future<List<LlmMessage>> Function()? pullInputs,
    bool Function()? shouldTerminate,
  }) => LlmSession(
    transport: transport,
    model: 'demo',
    toolRunner: tools ?? const EmptyToolRunner(),
    pullInputs: pullInputs,
    shouldTerminate: shouldTerminate,
  );

  group('LlmSession：工具批原子性 + 迭代边界终止（AC-3）', () {
    test('direct task 到达：整个工具批跑完才结束，不再进入下一跳', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        twoToolCalls(),
        textScript('不应到达'),
      ]);
      final FakeToolRunner tools = FakeToolRunner(
        specs: const <ToolSpec>[
          ToolSpec(name: 'a', description: 'a'),
          ToolSpec(name: 'b', description: 'b'),
        ],
      );
      final List<AgentEvent> events = await session(
        transport,
        tools: tools,
        shouldTerminate: () => true,
      ).run(
        messages: <LlmMessage>[const LlmMessage.user('hi')],
        agentId: 'a',
        sessionId: 's',
        isCancelled: () => false,
      ).toList();

      expect(tools.invocations, hasLength(2), reason: '工具批必须整体执行');
      expect(transport.turnsUsed, 1, reason: '终止发生在下一跳之前');
      final AgentDone done = events.last as AgentDone;
      expect(done.cancelled, isFalse);
      expect(
        events.whereType<AgentText>().map((AgentText e) => e.delta).join(),
        isNot(contains('不应到达')),
      );
    });

    test('插入点：注入消息只追加在末尾，前一跳的前缀逐字不变', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        toolCallScript(name: 'a', arguments: '{}'),
        textScript('完成'),
      ]);
      final FakeToolRunner tools = FakeToolRunner(
        specs: const <ToolSpec>[ToolSpec(name: 'a', description: 'a')],
      );
      int pulls = 0;
      final LlmSession loop = session(
        transport,
        tools: tools,
        pullInputs: () async {
          pulls++;
          // 首跳之前没有消息；第一跳的工具批跑完后（第二跳之前）才出现。
          return pulls == 2
              ? const <LlmMessage>[
                  LlmMessage.system('系统提示'),
                  LlmMessage.user('补充一句'),
                ]
              : const <LlmMessage>[];
        },
      );
      await loop.run(
        messages: <LlmMessage>[const LlmMessage.user('hi')],
        agentId: 'a',
        sessionId: 's',
        isCancelled: () => false,
      ).toList();

      final List<LlmMessage> first = transport.requests[0].messages;
      final List<LlmMessage> second = transport.requests[1].messages;
      expect(
        second
            .take(first.length)
            .map((LlmMessage m) => '${m.role.name}:${m.content}'),
        first.map((LlmMessage m) => '${m.role.name}:${m.content}'),
        reason: '注入只能追加，不能改动已发前缀（端点缓存）',
      );
      expect(
        second.map((LlmMessage m) => '${m.role.name}:${m.content}'),
        containsAll(<String>['system:系统提示', 'user:补充一句']),
      );
    });
  });

  group('LlmAgentEngine：注入翻译 + 工具表快照（AC-3）', () {
    LlmAgentEngine engine(
      FakeTransport transport, {
      ToolRunner? tools,
    }) => LlmAgentEngine(
      resolveModel: (String id) => id == config.modelId ? config : null,
      toolRunner: tools ?? const EmptyToolRunner(),
      transportFactory: (CoreModelConfig c) => transport,
    );

    test('tip / system_message 在下一跳前注入；system 走 system 通道', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        toolCallScript(name: 'a', arguments: '{}'),
        textScript('完成'),
      ]);
      final FakeToolRunner tools = FakeToolRunner(
        specs: const <ToolSpec>[ToolSpec(name: 'a', description: 'a')],
      );
      int pulls = 0;
      final AgentRunContext context = AgentRunContext(
        agentId: 'agt',
        sessionId: 'ses',
        modelId: 'demo',
        systemPrompt: '系统提示词',
        userContent: 'hi',
        history: const <CoreMessageRef>[CoreMessageRef(role: 'user', content: 'hi')],
        pullInputs: () {
          pulls++;
          // 首跳之前没有消息；工具批跑完后（第二跳之前）才出现。
          if (pulls != 2) return const AgentInputBatch();
          return const AgentInputBatch(
            history: <CoreMessageRef>[
              CoreMessageRef(
                role: 'system',
                content: '插件提示',
                messageType: 'system_message',
                messageSubtype: 'tip',
              ),
              CoreMessageRef(
                role: 'user',
                content: '补充',
                messageType: 'common_message',
                messageSubtype: 'tip',
              ),
            ],
          );
        },
      );
      await engine(transport, tools: tools)
          .run(context, isCancelled: () => false)
          .toList();

      final List<String> first = transport.requests[0].messages
          .map((LlmMessage m) => '${m.role.name}:${m.content}')
          .toList();
      final List<String> second = transport.requests[1].messages
          .map((LlmMessage m) => '${m.role.name}:${m.content}')
          .toList();
      expect(first, isNot(contains('system:插件提示')));
      expect(second, contains('system:插件提示'));
      expect(second, contains('user:补充'));
    });

    test('工具表按 agent×会话钉住；失效后重建', () async {
      final _CountingRunner runner = _CountingRunner();
      final LlmAgentEngine loop = engine(
        FakeTransport(<List<LlmStreamEvent>>[textScript('一')]),
        tools: runner,
      );
      AgentRunContext context(String sessionId) => AgentRunContext(
        agentId: 'agt',
        sessionId: sessionId,
        modelId: 'demo',
        systemPrompt: '系统',
        userContent: 'hi',
        history: const <CoreMessageRef>[CoreMessageRef(role: 'user', content: 'hi')],
      );

      await loop.run(context('ses_a'), isCancelled: () => false).toList();
      await loop.run(context('ses_a'), isCancelled: () => false).toList();
      expect(runner.specsCalls, 1, reason: '同一会话复用快照');
      expect(loop.toolSnapshotCount, 1);

      await loop.run(context('ses_b'), isCancelled: () => false).toList();
      expect(runner.specsCalls, 2, reason: '不同会话各一份');

      loop.invalidateToolSnapshots('agt', sessionId: 'ses_a');
      await loop.run(context('ses_a'), isCancelled: () => false).toList();
      expect(runner.specsCalls, 3, reason: '收到失效信号后重建');

      loop.invalidateAllToolSnapshots();
      expect(loop.toolSnapshotCount, 0);
    });
  });

  group('消息机 × loop：tip 下一跳注入 / direct task 边界终止', () {
    late Directory temp;
    late AgentInstanceRegistry registry;
    late MemoryStore store;
    late _RecordingHub hub;
    late _LoopingEngine engine;
    late ConversationService service;
    late CoreAgent agent;
    const String sessionId = TreeStore.defaultSessionId;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('tree_agent_ac3_');
      registry = AgentInstanceRegistry(paths: AgentDataPaths(temp.path));
      store = MemoryStore();
      hub = _RecordingHub();
      engine = _LoopingEngine();
      service = ConversationService(
        store: store,
        hub: hub,
        settings: CoreSettings(),
        engine: engine,
        agentInstances: registry,
        pacingEnabled: false,
      );
      agent = store.createAgent(name: 'AC-3 用例');
    });

    tearDown(() async {
      service.dispose();
      await registry.disposeAll();
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows 偶发占用：临时目录交给系统清理。
      }
    });

    Future<void> waitUntil(bool Function() predicate, String reason) async {
      for (int i = 0; i < 2000; i++) {
        if (predicate()) return;
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      fail('等待超时：$reason');
    }

    Map<String, dynamic> task(String content, {String inject = 'direct'}) =>
        <String, dynamic>{
          'type': 'common_message',
          'subtype': 'task',
          'inject_mode': inject,
          'source': <String, dynamic>{
            'team_id': 'inner',
            'agent_id': 'user',
            'session_id': 'main',
          },
          'target': <String, dynamic>{
            'agent_id': agent.id,
            'session_id': sessionId,
          },
          'content': content,
        };

    test('工具批中到达的 tip 在下一跳注入；台账在注入后 done', () async {
      engine.toolGate = Completer<void>();
      final Future<Map<String, dynamic>> running = service.acceptMessage(
        task('一'),
      );
      await waitUntil(() => engine.toolStarts == 1, '首轮工具开始');

      final Map<String, dynamic> tip = await service.acceptMessage(
        <String, dynamic>{
          'message_id': 'tip_mid',
          'type': 'system_message',
          'subtype': 'tip',
          'inject_mode': 'direct',
          'source': <String, dynamic>{
            'team_id': 'inner',
            'agent_id': 'plugin_x',
            'session_id': 'main',
          },
          'target': <String, dynamic>{
            'agent_id': agent.id,
            'session_id': sessionId,
          },
          'content': '工具批中途的提示',
        },
      );
      expect(tip['ok'], isTrue);
      engine.toolGate!.complete();
      await running;

      expect(engine.hopInputs.first, contains('工具批中途的提示'));
      expect(engine.runs, 1, reason: 'tip 不唤醒新 loop');
      final InboxEntry entry = (await registry
              .instanceOf(agent.id)
              .inbox(sessionId)
              .readAll())
          .firstWhere((InboxEntry e) => e.messageId == 'tip_mid');
      expect(entry.status, InboxStatus.done);
    });

    test('工具批中到达的 direct task：本批跑完终止，随后单独开新 loop', () async {
      engine.toolGate = Completer<void>();
      final Future<Map<String, dynamic>> first = service.acceptMessage(
        task('一'),
      );
      await waitUntil(() => engine.toolStarts == 1, '首轮工具开始');

      final Future<Map<String, dynamic>> second = service.acceptMessage(
        task('二'),
      );
      engine.toolGate!.complete();
      await Future.wait(<Future<Map<String, dynamic>>>[first, second]);

      expect(engine.runs, 2, reason: 'direct task 在边界后单独开新 loop');
      expect(engine.runInputs, <String>['一', '二']);
      expect(engine.hopInputs.first, isEmpty, reason: 'task 不注入旧 loop');
    });
  });
}

/// 只记录、不发送的 hub。
class _RecordingHub extends WsHub {
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];

  @override
  void broadcast(Map<String, dynamic> frame) => frames.add(frame);
}
