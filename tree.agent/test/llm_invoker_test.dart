import 'dart:convert';

import 'package:test/test.dart';
import 'package:tree_agent_loop/src/llm/llm_invoker.dart';

import 'fake_transport.dart';
import 'ported_core.dart';

/// AC-6：LLM 调用边界（`LlmInvoker`）——自定义实现可接管调用，默认路径字节不变。
class _ScriptedInvoker implements LlmInvoker {
  _ScriptedInvoker(this.scripts);

  final List<List<LlmStreamEvent>> scripts;
  final List<LlmRequest> requests = <LlmRequest>[];

  @override
  Stream<LlmStreamEvent> invoke(
    LlmRequest request, {
    bool Function()? isCancelled,
  }) async* {
    requests.add(request);
    final List<LlmStreamEvent> events = scripts[requests.length - 1];
    for (final LlmStreamEvent event in events) {
      if (isCancelled?.call() ?? false) return;
      yield event;
      await Future<void>.delayed(Duration.zero);
    }
  }
}

void main() {
  test('自定义 LlmInvoker 驱动工具循环（不碰传输）', () async {
    final _ScriptedInvoker invoker = _ScriptedInvoker(<List<LlmStreamEvent>>[
      toolCallScript(name: 'echo', arguments: '{}'),
      textScript('完成'),
    ]);
    final FakeToolRunner tools = FakeToolRunner(
      specs: const <ToolSpec>[ToolSpec(name: 'echo', description: 'echo')],
    );
    final List<AgentEvent> events = await LlmSession(
      invoker: invoker,
      model: 'demo',
      toolRunner: tools,
    ).run(
      messages: <LlmMessage>[const LlmMessage.user('hi')],
      agentId: 'a',
      sessionId: 's',
      isCancelled: () => false,
    ).toList();

    expect(invoker.requests, hasLength(2), reason: '工具循环照常发第二跳');
    expect(tools.invocations.single.name, 'echo');
    expect(
      events.whereType<AgentText>().map((AgentText e) => e.delta).join(),
      contains('完成'),
    );
    expect(events.last, isA<AgentDone>());
  });

  test('默认路径：TransportLlmInvoker 与直接走传输的请求字节一致', () async {
    Future<String> wireOf({required bool useInvoker}) async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('答复'),
      ]);
      final LlmSession loop = useInvoker
          ? LlmSession(
              invoker: TransportLlmInvoker(transport),
              model: 'demo',
            )
          : LlmSession(transport: transport, model: 'demo');
      await loop.run(
        messages: <LlmMessage>[const LlmMessage.user('hi')],
        agentId: 'a',
        sessionId: 's',
        isCancelled: () => false,
      ).toList();
      return jsonEncode(transport.requests.single.toWire(stream: true));
    }

    expect(await wireOf(useInvoker: true), await wireOf(useInvoker: false));
  });

  test('TransportLlmInvoker 原样转发请求对象', () async {
    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      textScript('答复'),
    ]);
    final LlmRequest request = LlmRequest(
      model: 'demo',
      messages: const <LlmMessage>[LlmMessage.user('原样')],
    );
    await const TransportLlmInvoker(
      _NoopTransport(),
    ).invoke(request).toList();
    await TransportLlmInvoker(transport)
        .invoke(request, isCancelled: () => false)
        .toList();
    expect(identical(transport.requests.single, request), isTrue);
  });

  test('引擎接线：invokerFactory 生效时传输完全不被调用', () async {
    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      textScript('不应到达'),
    ]);
    final _ScriptedInvoker invoker = _ScriptedInvoker(<List<LlmStreamEvent>>[
      textScript('来自自定义边界'),
    ]);
    final LlmAgentEngine engine = LlmAgentEngine(
      resolveModel: (String id) => CoreModelConfig(
        modelId: 'demo',
        name: '演示',
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'sk-test',
        maxSeqlen: 64000,
        maxOutputTokens: 512,
      ),
      transportFactory: (CoreModelConfig c) => transport,
      invokerFactory: (LlmTransport t) => invoker,
    );
    final List<AgentEvent> events = await engine
        .run(
          const AgentRunContext(
            agentId: 'agt',
            sessionId: 'ses',
            modelId: 'demo',
            systemPrompt: '系统',
            userContent: 'hi',
            history: <CoreMessageRef>[
              CoreMessageRef(role: 'user', content: 'hi'),
            ],
          ),
          isCancelled: () => false,
        )
        .toList();

    expect(transport.turnsUsed, 0, reason: '自定义边界接管后不走 HTTP 传输');
    expect(invoker.requests, hasLength(1));
    expect(
      events.whereType<AgentText>().map((AgentText e) => e.delta).join(),
      contains('来自自定义边界'),
    );
  });
}

/// 占位传输：只用于验证 `TransportLlmInvoker` 转发的请求对象。
class _NoopTransport implements LlmTransport {
  const _NoopTransport();

  @override
  Stream<LlmStreamEvent> stream(
    LlmRequest request, {
    bool Function()? isCancelled,
  }) async* {
    yield const LlmFinishEvent('stop');
  }

  @override
  Future<void> close() async {}
}
