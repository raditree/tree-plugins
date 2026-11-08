import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_agent_loop/src/agent/agent_instance.dart';
import 'package:tree_agent_loop/src/message/inbox_ledger.dart';
import 'package:tree_agent_loop/src/message/message_envelope.dart';
import 'package:tree_agent_loop/src/paths.dart';

import 'ported_core.dart';

/// 可控引擎：记录每轮输入与"收尾那一刻是否被取消"，可选闸门阻塞首轮。
class _GatedEngine implements AgentEngine {
  final List<String> prompts = <String>[];
  final List<bool> cancelledAtEnd = <bool>[];
  final List<List<CoreMessageRef>> histories = <List<CoreMessageRef>>[];

  /// 非空时，这一轮在产出任何事件之前等它完成（模拟"正在跑"）。
  Completer<void>? gate;

  @override
  Stream<AgentEvent> run(
    AgentRunContext context, {
    required bool Function() isCancelled,
  }) async* {
    prompts.add(context.userContent);
    histories.add(context.history);
    final Completer<void>? waiting = gate;
    if (waiting != null) await waiting.future;
    yield AgentText('回复:${context.userContent}');
    cancelledAtEnd.add(isCancelled());
    yield const AgentDone(finishReason: 'stop');
  }

  @override
  Future<void> close() async {}
}

void main() {
  group('消息信封校验（AC-2）', () {
    test('缺省值：common_message / task / direct / inner-user-main', () {
      final MessageEnvelope envelope = MessageEnvelope.parse(<String, dynamic>{
        'agent_id': 'agt_1',
        'content': '你好',
      });
      expect(envelope.type, MessageType.commonMessage);
      expect(envelope.subtype, MessageSubtype.task);
      expect(envelope.injectMode, InjectMode.direct);
      expect(envelope.source.teamId, MessageSources.innerTeam);
      expect(envelope.source.agentId, MessageSources.user);
      expect(envelope.source.sessionId, MessageSources.mainSession);
      expect(envelope.targetAgentId, 'agt_1');
      expect(envelope.generatedId, isTrue);
      expect(envelope.wakesLoop, isTrue);
    });

    test('非法 type / subtype / inject_mode 一律拒绝', () {
      Matcher rejected = throwsA(isA<MessageEnvelopeException>());
      expect(
        () => MessageEnvelope.parse(<String, dynamic>{
          'agent_id': 'agt_1',
          'type': 'notice',
        }),
        rejected,
      );
      expect(
        () => MessageEnvelope.parse(<String, dynamic>{
          'agent_id': 'agt_1',
          'subtype': 'interrupt',
        }),
        rejected,
      );
      expect(
        () => MessageEnvelope.parse(<String, dynamic>{
          'agent_id': 'agt_1',
          'inject_mode': 'immediate',
        }),
        rejected,
      );
    });

    test('特殊来源 / 保留坐标不能作为目标', () {
      for (final String target in <String>[
        MessageSources.user,
        MessageSources.system,
        'plugin_tree.agent',
        MessageSources.innerTeam,
      ]) {
        expect(
          () => MessageEnvelope.parse(<String, dynamic>{
            'agent_id': target,
            'content': 'x',
          }),
          throwsA(isA<MessageEnvelopeException>()),
          reason: '目标 $target 必须被拒绝',
        );
      }
      expect(
        () => MessageEnvelope.parse(<String, dynamic>{
          'target': <String, dynamic>{
            'agent_id': 'agt_1',
            'session_id': MessageSources.mainSession,
          },
        }),
        throwsA(isA<MessageEnvelopeException>()),
        reason: '保留会话 main 不能作为真实目标会话',
      );
    });

    test('inner 来源只配特殊身份 + main；真实团队来源必须是真实 agent', () {
      expect(
        () => MessageEnvelope.parse(<String, dynamic>{
          'agent_id': 'agt_1',
          'source': <String, dynamic>{
            'team_id': MessageSources.innerTeam,
            'agent_id': 'agt_sender',
            'session_id': MessageSources.mainSession,
          },
        }),
        throwsA(isA<MessageEnvelopeException>()),
      );
      expect(
        () => MessageEnvelope.parse(<String, dynamic>{
          'agent_id': 'agt_1',
          'source': <String, dynamic>{
            'team_id': MessageSources.innerTeam,
            'agent_id': 'plugin_x',
            'session_id': 'session_default',
          },
        }),
        throwsA(isA<MessageEnvelopeException>()),
      );
      final MessageEnvelope real = MessageEnvelope.parse(<String, dynamic>{
        'agent_id': 'agt_1',
        'source': <String, dynamic>{
          'team_id': 'team_1',
          'agent_id': 'agt_sender',
          'session_id': 'session_a',
        },
      });
      expect(real.source.teamId, 'team_1');
      expect(real.source.agentId, 'agt_sender');
    });

    test('嵌套 / 扁平两种形态都能读；显式 id 不算生成', () {
      final MessageEnvelope nested = MessageEnvelope.parse(<String, dynamic>{
        'message_id': 'msg_1',
        'type': 'system_message',
        'subtype': 'tip',
        'inject_mode': 'queue',
        'source': <String, dynamic>{
          'team_id': 'inner',
          'agent_id': 'plugin_tree.agent',
          'session_id': 'main',
        },
        'target': <String, dynamic>{
          'agent_id': 'agt_1',
          'session_id': 'session_a',
        },
        'content': '上下文',
      });
      expect(nested.messageId, 'msg_1');
      expect(nested.generatedId, isFalse);
      expect(nested.isSystemMessage, isTrue);
      expect(nested.isTip, isTrue);
      expect(nested.wakesLoop, isFalse);

      final MessageEnvelope flat = MessageEnvelope.parse(<String, dynamic>{
        'message_type': 'common_message',
        'message_subtype': 'task',
        'inject_mode': 'queue',
        'source_team_id': 'inner',
        'source_agent_id': 'system',
        'source_session_id': 'main',
        'agent_id': 'agt_2',
        'session_id': 'session_b',
        'content': '干活',
      });
      expect(flat.type, MessageType.commonMessage);
      expect(flat.injectMode, InjectMode.queue);
      expect(flat.targetAgentId, 'agt_2');
      expect(flat.targetSessionId, 'session_b');
    });
  });

  group('消息机（AC-2）', () {
    late Directory temp;
    late AgentInstanceRegistry registry;
    late MemoryStore store;
    late _RecordingHub hub;
    late _GatedEngine engine;
    late ConversationService service;
    late CoreAgent agent;
    const String sessionId = TreeStore.defaultSessionId;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('tree_agent_ac2_');
      registry = AgentInstanceRegistry(paths: AgentDataPaths(temp.path));
      store = MemoryStore();
      hub = _RecordingHub();
      engine = _GatedEngine();
      service = ConversationService(
        store: store,
        hub: hub,
        settings: CoreSettings(),
        engine: engine,
        agentInstances: registry,
        pacingEnabled: false,
      );
      agent = store.createAgent(name: '消息机用例');
    });

    tearDown(() async {
      service.dispose();
      await registry.disposeAll();
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows 上偶发的"文件仍被占用"：测试用临时目录，留给系统清理。
      }
    });

    MessageInbox inbox() => registry.instanceOf(agent.id).inbox(sessionId);

    Future<void> waitUntil(bool Function() predicate, String reason) async {
      for (int i = 0; i < 2000; i++) {
        if (predicate()) return;
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      fail('等待超时：$reason');
    }

    Future<void> waitInboxCount(int count) async {
      for (int i = 0; i < 500; i++) {
        if ((await inbox().readAll()).length >= count) return;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      fail('等待收件箱落盘超时（期望 $count 条）');
    }

    List<String> stateFrames() => <String>[
      for (final Map<String, dynamic> frame in hub.frames)
        if (frame['type'] == WsOutboundType.agentState)
          '${(frame['data'] as Map)['state']}',
    ];

    Map<String, dynamic> task({
      String? id,
      String subtype = 'task',
      String inject = 'direct',
      int createdAt = 0,
      String content = '干活',
      String sourceAgent = 'user',
    }) => <String, dynamic>{
      'message_id': ?id,
      'type': 'common_message',
      'subtype': subtype,
      'inject_mode': inject,
      'source': <String, dynamic>{
        'team_id': 'inner',
        'agent_id': sourceAgent,
        'session_id': 'main',
      },
      'target': <String, dynamic>{
        'agent_id': agent.id,
        'session_id': sessionId,
      },
      'content': content,
      'created_at': createdAt,
    };

    test('tip：落库为 system、不唤醒 loop、状态保持 idle', () async {
      final Map<String, dynamic> result = await service.acceptMessage(
        <String, dynamic>{
          'message_id': 'msg_tip_1',
          'type': 'system_message',
          'subtype': 'tip',
          'source': <String, dynamic>{
            'team_id': 'inner',
            'agent_id': 'plugin_tree.agent',
            'session_id': 'main',
          },
          'target': <String, dynamic>{
            'agent_id': agent.id,
            'session_id': sessionId,
          },
          'content': '这条只是上下文提示',
        },
      );

      expect(result['ok'], isTrue);
      expect(result['woke'], isFalse);
      expect(engine.prompts, isEmpty, reason: 'tip 不能启动 loop');
      expect(registry.instanceOf(agent.id).state, AgentActivityState.idle);
      expect(stateFrames(), isEmpty, reason: 'tip 不动状态，也不广播 agent.state');

      final CoreMessage saved = store.sessionMessages(agent.id, sessionId).last;
      expect(saved.role, 'system');
      expect(saved.messageType, 'system_message');
      expect(saved.messageSubtype, 'tip');
      expect(saved.sourceMessageId, 'msg_tip_1');
      expect(saved.sourceAgentId, 'plugin_tree.agent');

      final List<InboxEntry> entries = await inbox().readAll();
      expect(entries.single.messageId, 'msg_tip_1');
      expect(entries.single.status, InboxStatus.done);

      // 非用户来源的入站消息会推给界面（tip 也看得见）。
      expect(
        hub.frames.where(
          (Map<String, dynamic> f) =>
              f['type'] == WsOutboundType.message &&
              f['id'] == saved.id,
        ),
        isNotEmpty,
      );
    });

    test('task：唤醒一轮，状态 idle→working→idle，台账 done', () async {
      final Map<String, dynamic> result = await service.acceptMessage(
        task(id: 'msg_task_1', content: '做点事', sourceAgent: 'plugin_x'),
      );

      expect(result['ok'], isTrue);
      expect(result['woke'], isTrue);
      expect(engine.prompts, <String>['做点事']);
      expect(stateFrames(), <String>['working', 'idle']);
      expect(registry.instanceOf(agent.id).state, AgentActivityState.idle);

      final List<InboxEntry> entries = await inbox().readAll();
      expect(entries.single.status, InboxStatus.done);
    });

    test('working 时到达的 tip 不打断当前生成', () async {
      engine.gate = Completer<void>();
      final Future<Map<String, dynamic>> first = service.acceptMessage(
        task(id: 'msg_task_a', content: '一', createdAt: 100),
      );
      await waitUntil(() => engine.prompts.length == 1, '首轮启动');

      final Map<String, dynamic> tip = await service.acceptMessage(
        <String, dynamic>{
          'message_id': 'msg_tip_mid',
          'type': 'system_message',
          'subtype': 'tip',
          'source': <String, dynamic>{
            'team_id': 'inner',
            'agent_id': 'system',
            'session_id': 'main',
          },
          'target': <String, dynamic>{
            'agent_id': agent.id,
            'session_id': sessionId,
          },
          'content': '中途提示',
        },
      );
      expect(tip['ok'], isTrue);

      engine.gate!.complete();
      engine.gate = null;
      await first;

      expect(engine.prompts, <String>['一'], reason: 'tip 不能开新的一轮');
      expect(engine.cancelledAtEnd, <bool>[false], reason: '在途轮次不能被打断');

      // 下一轮（新的 task）会读到这条 tip。
      await service.acceptMessage(task(id: 'msg_task_b', content: '二'));
      final List<String> secondHistory = <String>[
        for (final CoreMessageRef ref in engine.histories.last) ref.content,
      ];
      expect(secondHistory, contains('中途提示'));
    });

    test('direct 优先、queue 逐条：在途轮次跑完后按序执行', () async {
      engine.gate = Completer<void>();
      final Future<Map<String, dynamic>> running = service.acceptMessage(
        task(id: 'msg_first', content: '先', createdAt: 100),
      );
      await waitUntil(() => engine.prompts.length == 1, '首轮启动');

      final Future<Map<String, dynamic>> direct1 = service.acceptMessage(
        task(id: 'msg_d1', content: 'D1', createdAt: 101),
      );
      final Future<Map<String, dynamic>> queued = service.acceptMessage(
        task(
          id: 'msg_q1',
          content: 'Q1',
          inject: 'queue',
          createdAt: 102,
        ),
      );
      final Future<Map<String, dynamic>> direct2 = service.acceptMessage(
        task(id: 'msg_d2', content: 'D2', createdAt: 103),
      );
      await waitInboxCount(4);

      engine.gate!.complete();
      engine.gate = null;
      await Future.wait(<Future<Map<String, dynamic>>>[
        running,
        direct1,
        queued,
        direct2,
      ]);

      expect(engine.prompts, <String>['先', 'D1', 'D2', 'Q1']);
      expect(engine.cancelledAtEnd, <bool>[false, false, false, false]);
    });

    test('stop 作废排队的 task；tip 已落库不受影响', () async {
      engine.gate = Completer<void>();
      final Future<Map<String, dynamic>> running = service.acceptMessage(
        task(id: 'msg_run', content: '正在跑', createdAt: 100),
      );
      await waitUntil(() => engine.prompts.length == 1, '首轮启动');

      final Future<Map<String, dynamic>> queued = service.acceptMessage(
        task(id: 'msg_doomed', content: '要被作废', createdAt: 101),
      );
      await service.acceptMessage(<String, dynamic>{
        'message_id': 'msg_tip_keep',
        'type': 'system_message',
        'subtype': 'tip',
        'source': <String, dynamic>{
          'team_id': 'inner',
          'agent_id': 'system',
          'session_id': 'main',
        },
        'target': <String, dynamic>{
          'agent_id': agent.id,
          'session_id': sessionId,
        },
        'content': 'tip 保留',
      });
      await waitInboxCount(3);

      expect(service.cancelAgent(agent.id), isTrue);
      engine.gate!.complete();
      engine.gate = null;
      await Future.wait(<Future<Map<String, dynamic>>>[running, queued]);

      expect(engine.prompts, <String>['正在跑'], reason: '被作废的 task 不再开跑');
      final Map<String, InboxStatus> statuses = <String, InboxStatus>{
        for (final InboxEntry entry in await inbox().readAll())
          entry.messageId: entry.status,
      };
      expect(statuses['msg_doomed'], InboxStatus.cancelled);
      expect(statuses['msg_tip_keep'], InboxStatus.done);
    });

    test('特殊来源不能作为目标：拒绝且不落库', () async {
      final Map<String, dynamic> result = await service.acceptMessage(
        <String, dynamic>{
          'type': 'common_message',
          'subtype': 'task',
          'source': <String, dynamic>{
            'team_id': 'inner',
            'agent_id': 'system',
            'session_id': 'main',
          },
          'target': <String, dynamic>{
            'agent_id': MessageSources.user,
            'session_id': sessionId,
          },
          'content': '伪造目标',
        },
      );
      expect(result['ok'], isFalse);
      expect(engine.prompts, isEmpty);
      expect(store.sessionMessages(agent.id, sessionId), isEmpty);
    });

    test('显式 message_id 幂等：重复投递不重复落库/开跑', () async {
      final Map<String, dynamic> frame = task(
        id: 'msg_same',
        content: '同一句话',
      );
      final Map<String, dynamic> first = await service.acceptMessage(frame);
      final Map<String, dynamic> second = await service.acceptMessage(frame);

      expect(first['duplicate'], isNull);
      expect(second['duplicate'], isTrue);
      expect(engine.prompts, <String>['同一句话']);
      expect(
        store
            .sessionMessages(agent.id, sessionId)
            .where((CoreMessage m) => m.sourceMessageId == 'msg_same')
            .length,
        1,
      );
    });
  });
}

/// 只记录、不发送的 hub（与既有测试同一形态）。
class _RecordingHub extends WsHub {
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];

  @override
  void broadcast(Map<String, dynamic> frame) => frames.add(frame);
}
