import 'dart:async';

import 'package:test/test.dart';
import 'package:tree_agent_loop/src/llm/llm_relay.dart';

import 'fake_transport.dart';
import 'ported_core.dart';

/// AC-4：LLM 三步中转（前置 / 请求体自动修复 / 后置）的契约与 fail-open。
void main() {
  LlmSession session(
    FakeTransport transport, {
    LlmRelayHook? relay,
    Duration timeout = const Duration(seconds: 30),
    ToolRunner? tools,
  }) => LlmSession(
    transport: transport,
    model: 'demo',
    toolRunner: tools ?? const EmptyToolRunner(),
    llmRelay: relay,
    relayTimeout: timeout,
  );

  LlmRelayHook replyWith(Map<String, Map<String, dynamic>?> replies) =>
      ({
        required String point,
        required Map<String, dynamic> data,
        required String agentId,
        required String sessionId,
        required int turn,
      }) async {
        final Map<String, dynamic>? reply = replies[point];
        return reply == null
            ? const LlmRelayReply()
            : LlmRelayReply(handled: true, data: reply);
      };

  Future<List<AgentEvent>> run(LlmSession loop) => loop
      .run(
        messages: <LlmMessage>[const LlmMessage.user('hi')],
        agentId: 'agt',
        sessionId: 'ses',
        isCancelled: () => false,
      )
      .toList();

  List<String> textOf(List<AgentEvent> events) => <String>[
    for (final AgentEvent event in events)
      if (event is AgentText) event.delta,
  ];

  test('点位 id 使用下划线名段（核心自建站不允许点号）', () {
    expect(LlmRelayPoints.preName, 'llm_pre');
    expect(LlmRelayPoints.repairName, 'llm_repair');
    expect(LlmRelayPoints.postName, 'llm_post');
    expect(LlmRelayPoints.all, hasLength(3));
    expect(LlmRelayPoints.pointOfName('llm_pre'), LlmRelayPoints.pre);
  });

  group('前置 / 修复', () {
    test('无订阅者（handled:false）⇒ 原请求照发', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('答复'),
      ]);
      final List<String> points = <String>[];
      final List<AgentEvent> events = await run(
        session(
          transport,
          relay:
              ({
                required String point,
                required Map<String, dynamic> data,
                required String agentId,
                required String sessionId,
                required int turn,
              }) async {
                points.add(point);
                return const LlmRelayReply();
              },
        ),
      );
      expect(textOf(events).join(), '答复');
      expect(transport.turnsUsed, 1);
      expect(points, containsAll(<String>['llm.pre', 'llm.repair', 'llm.post']));
    });

    test('前置改写请求体：改写后的温度进入实际请求', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('答复'),
      ]);
      final List<AgentEvent> events = await run(
        session(
          transport,
          relay:
              ({
                required String point,
                required Map<String, dynamic> data,
                required String agentId,
                required String sessionId,
                required int turn,
              }) async {
                if (point != LlmRelayPoints.pre) {
                  return const LlmRelayReply();
                }
                return LlmRelayReply(
                  handled: true,
                  data: <String, dynamic>{
                    'request': <String, dynamic>{
                      ...data,
                      'temperature': 0.25,
                    },
                  },
                );
              },
        ),
      );
      expect(textOf(events).join(), '答复');
      expect(transport.requests.single.temperature, 0.25);
    });

    test('显式 error ⇒ AgentError + 终止，不发出请求', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('不应到达'),
      ]);
      final List<AgentEvent> events = await run(
        session(
          transport,
          relay: replyWith(<String, Map<String, dynamic>?>{
            LlmRelayPoints.pre: <String, dynamic>{
              'error': true,
              'error_reason': '前置拒绝',
            },
          }),
        ),
      );
      final AgentError error = events.whereType<AgentError>().single;
      expect(error.message, '前置拒绝');
      expect(events.last, isA<AgentDone>());
      expect(transport.turnsUsed, 0);
      expect(textOf(events).join(), isNot(contains('不应到达')));
    });

    test('异常 / 超时 / 非法回包 ⇒ fail-open，原请求照发', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('一'),
        textScript('二'),
        textScript('三'),
      ]);
      // 1) 抛异常
      await run(
        session(
          transport,
          relay:
              ({
                required String point,
                required Map<String, dynamic> data,
                required String agentId,
                required String sessionId,
                required int turn,
              }) async {
                if (point == LlmRelayPoints.pre) throw StateError('炸了');
                return const LlmRelayReply();
              },
        ),
      );
      // 2) 超时
      await run(
        session(
          transport,
          timeout: const Duration(milliseconds: 10),
          relay:
              ({
                required String point,
                required Map<String, dynamic> data,
                required String agentId,
                required String sessionId,
                required int turn,
              }) {
                if (point == LlmRelayPoints.repair) {
                  return Completer<LlmRelayReply>().future;
                }
                return Future<LlmRelayReply>.value(const LlmRelayReply());
              },
        ),
      );
      // 3) 非法回包
      await run(
        session(
          transport,
          relay: replyWith(<String, Map<String, dynamic>?>{
            LlmRelayPoints.repair: <String, dynamic>{'request': 123},
          }),
        ),
      );
      expect(transport.turnsUsed, 3, reason: '三次都应按原请求发出');
    });
  });

  group('后置', () {
    test('改写 content 只影响下一跳上下文，已下发增量不回滚', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        <LlmStreamEvent>[
          const LlmTextDelta('原文'),
          const LlmToolCallDelta(index: 0, id: 'c1', name: 'echo'),
          const LlmToolCallDelta(index: 0, argumentsDelta: '{}'),
          const LlmFinishEvent('tool_calls'),
        ],
        textScript('完成'),
      ]);
      final FakeToolRunner tools = FakeToolRunner(
        specs: const <ToolSpec>[ToolSpec(name: 'echo', description: 'echo')],
      );
      final List<AgentEvent> events = await run(
        session(
          transport,
          tools: tools,
          relay:
              ({
                required String point,
                required Map<String, dynamic> data,
                required String agentId,
                required String sessionId,
                required int turn,
              }) async {
                if (point != LlmRelayPoints.post || turn != 0) {
                  return const LlmRelayReply();
                }
                return LlmRelayReply(
                  handled: true,
                  data: <String, dynamic>{
                    'content': '改后',
                    'tool_calls': data['tool_calls'],
                  },
                );
              },
        ),
      );

      expect(textOf(events).join(), contains('原文'), reason: '已下发增量不回滚');
      final LlmMessage assistant = transport.requests[1].messages.firstWhere(
        (LlmMessage m) => m.role == LlmRole.assistant,
      );
      expect(assistant.content, '改后', reason: '下一跳上下文用后置结果');
    });

    test('改写 tool_calls ⇒ 执行与事件都用改写后的调用', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        toolCallScript(name: 'a', arguments: '{}'),
        textScript('完成'),
      ]);
      final FakeToolRunner tools = FakeToolRunner(
        specs: const <ToolSpec>[
          ToolSpec(name: 'a', description: 'a'),
          ToolSpec(name: 'b', description: 'b'),
        ],
      );
      final List<AgentEvent> events = await run(
        session(
          transport,
          tools: tools,
          relay:
              ({
                required String point,
                required Map<String, dynamic> data,
                required String agentId,
                required String sessionId,
                required int turn,
              }) async {
                if (point != LlmRelayPoints.post || turn != 0) {
                  return const LlmRelayReply();
                }
                return LlmRelayReply(
                  handled: true,
                  data: <String, dynamic>{
                    'tool_calls': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'id': 'c1',
                        'type': 'function',
                        'function': <String, dynamic>{
                          'name': 'b',
                          'arguments': '{}',
                        },
                      },
                    ],
                  },
                );
              },
        ),
      );

      expect(tools.invocations.single.name, 'b');
      final AgentToolStart start = events.whereType<AgentToolStart>().single;
      expect(start.name, 'b');
    });

    test('显式 error ⇒ AgentError + 终止，不执行工具', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        toolCallScript(name: 'a', arguments: '{}'),
        textScript('不应到达'),
      ]);
      final FakeToolRunner tools = FakeToolRunner(
        specs: const <ToolSpec>[ToolSpec(name: 'a', description: 'a')],
      );
      final List<AgentEvent> events = await run(
        session(
          transport,
          tools: tools,
          relay: replyWith(<String, Map<String, dynamic>?>{
            LlmRelayPoints.post: <String, dynamic>{
              'error': true,
              'error_reason': '后置拒绝',
            },
          }),
        ),
      );
      expect(events.whereType<AgentError>().single.message, '后置拒绝');
      expect(events.last, isA<AgentDone>());
      expect(tools.invocations, isEmpty);
      expect(transport.turnsUsed, 1);
    });
  });
}
