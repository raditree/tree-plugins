import 'package:test/test.dart';
import 'ported_core.dart';

/// 提问回路（M5a）语义：落盘 + 推帧 + 等待作答 + 取消 + 重启后补答。
void main() {
  late MemoryStore store;
  late MemoryQuestionStore questions;
  late List<Map<String, dynamic>> frames;
  late QuestionBroker broker;
  late CoreAgent agent;

  const String sessionId = TreeStore.defaultSessionId;

  setUp(() {
    store = MemoryStore();
    agent = store.createAgent(name: '主 agent');
    questions = MemoryQuestionStore();
    frames = <Map<String, dynamic>>[];
    broker = QuestionBroker(
      questions: questions,
      transcript: store,
      broadcast: frames.add,
      pollInterval: const Duration(milliseconds: 10),
    );
  });

  AskQuestionRequest request({
    String question = '选哪个方案？',
    List<String> options = const <String>['A', 'B'],
    List<AskedQuestion>? questions,
    bool Function()? isCancelled,
  }) => AskQuestionRequest(
    agentId: agent.id,
    sessionId: sessionId,
    questions:
        questions ??
        <AskedQuestion>[AskedQuestion(question: question, options: options)],
    isCancelled: isCancelled ?? () => false,
  );

  test('ask：先落盘再推帧，并在会话里留下提问卡片', () async {
    final Future<QuestionOutcome> pending = broker.ask(request());
    expect(broker.inFlightCount, 1);

    // 1) 提问记录已落盘（重启后右侧「问题回复」页仍能看到）
    final QuestionRecord record = questions.list().single;
    expect(record.status, QuestionStatus.pending);
    expect(record.question, '选哪个方案？');
    expect(record.options, <String>['A', 'B']);
    expect(record.agentId, agent.id);
    expect(record.sessionId, sessionId);

    // 2) 下行帧：顶层字段（前端 _handleAskUserQuestion 的口径，不包 data）
    final Map<String, dynamic> frame = frames.single;
    expect(frame['type'], WsOutboundType.askUserQuestion);
    expect(frame['id'], record.qid);
    expect(frame['question'], '选哪个方案？');
    expect(frame['options'], <String>['A', 'B']);
    expect(frame['agent_id'], agent.id);
    expect(frame['session_id'], sessionId);
    expect(frame.containsKey('data'), isFalse);

    // 3) 会话里有一条提问卡片消息（重载历史时仍渲染卡片）
    final CoreMessage card = store
        .messages(agent.id, sessionId)
        .singleWhere((CoreMessage m) => m.kind == 'ask_user_question');
    expect(card.id, record.qid, reason: 'qid 即消息 id');
    expect(card.content, '选哪个方案？');
    expect(card.options, <String>['A', 'B']);
    expect(card.answered, isFalse);

    // 4) 作答：等待中的 future 完成，并广播 resolved
    expect(broker.answer(record.qid, <String>['B']), isTrue);
    final QuestionOutcome outcome = await pending;
    expect(outcome.cancelled, isFalse);
    expect(outcome.answer, 'B');
    expect(broker.inFlightCount, 0);
    expect(questions.byId(record.qid)?.status, QuestionStatus.answered);
    expect(frames.last['type'], WsOutboundType.askUserQuestionResolved);
    expect((frames.last['data'] as Map<String, dynamic>)['id'], record.qid);

    // 5) 重复作答被幂等闸门拒绝（并发 WS + REST 只生效一次）
    expect(broker.answer(record.qid, <String>['C']), isFalse);
    expect(questions.byId(record.qid)?.answer, 'B');
  });

  test('多问题：一条记录一张卡片，作答一次交齐（未答项按未作答）', () async {
    final Future<QuestionOutcome> pending = broker.ask(
      request(
        questions: <AskedQuestion>[
          AskedQuestion(question: '部署到哪台？', options: <String>['A 机', 'B 机']),
          AskedQuestion(question: '要不要回滚预案？'),
        ],
      ),
    );
    // 1) 落盘：一条记录、两道题
    final QuestionRecord record = questions.list().single;
    expect(record.isMulti, isTrue);
    expect(record.questions.length, 2);
    expect(record.question, '部署到哪台？', reason: '兼容读法 = 第一问');

    // 2) 下行帧：questions 是完整问题表；question/options 保留为第一问（老前端）
    final Map<String, dynamic> frame = frames.single;
    expect(frame['questions'], <Map<String, dynamic>>[
      <String, dynamic>{
        'question': '部署到哪台？',
        'options': <String>['A 机', 'B 机'],
      },
      <String, dynamic>{'question': '要不要回滚预案？', 'options': <String>[]},
    ]);
    expect(frame['question'], '部署到哪台？');
    expect(frame['options'], <String>['A 机', 'B 机']);

    // 3) 会话里那张卡片同样是两道题（历史重载时按它渲染）
    final CoreMessage card = store
        .messages(agent.id, sessionId)
        .singleWhere((CoreMessage m) => m.kind == 'ask_user_question');
    expect(card.questions?.length, 2);

    // 4) 只答第一题也接受（缺项按未作答），resolved 帧带逐题答案
    expect(broker.answer(record.qid, <String>['B 机']), isTrue);
    final QuestionOutcome outcome = await pending;
    expect(outcome.cancelled, isFalse);
    expect(outcome.answers, <String>['B 机', '']);
    expect(record.answers, <String>['B 机', '']);
    final Map<String, dynamic> resolved =
        frames.last['data'] as Map<String, dynamic>;
    expect(resolved['answers'], <String>['B 机', '']);
    expect(resolved['answer'], contains('第1题（部署到哪台？）：B 机'));
  });

  test('多问题：取消同样立刻收尾（一个 Completer，与题数无关）', () async {
    final Future<QuestionOutcome> pending = broker.ask(
      request(
        questions: <AskedQuestion>[
          AskedQuestion(question: '第一问'),
          AskedQuestion(question: '第二问'),
        ],
      ),
    );
    final String qid = questions.list().single.qid;
    expect(broker.cancel(qid, reason: '用户取消'), isTrue);
    final QuestionOutcome outcome = await pending;
    expect(outcome.cancelled, isTrue);
    expect(outcome.answers, isEmpty);
    expect(questions.byId(qid)?.status, QuestionStatus.cancelled);
    expect(broker.inFlightCount, 0);
  });

  test('多问题：没有在途生成时的补答消息逐题成行', () async {
    final MemoryQuestionStore persisted = MemoryQuestionStore();
    final QuestionBroker restarted = QuestionBroker(
      questions: persisted,
      transcript: store,
      broadcast: frames.add,
    );
    persisted.add(
      QuestionRecord(
        qid: 'q_multi_old',
        agentId: agent.id,
        sessionId: sessionId,
        questions: <AskedQuestion>[
          AskedQuestion(question: '第一问'),
          AskedQuestion(question: '第二问'),
        ],
        createdAt: 1,
      ),
    );
    expect(restarted.answer('q_multi_old', <String>['甲', '乙']), isTrue);
    final CoreMessage answer = store
        .messages(agent.id, sessionId)
        .lastWhere((CoreMessage m) => m.role == 'user');
    expect(answer.content, startsWith('${QuestionBroker.answerPrefix}\n'));
    expect(answer.content, contains('第1题（第一问）：甲'));
    expect(answer.content, contains('第2题（第二问）：乙'));
  });

  test('cancel：等待立刻结束且记录标记为已取消', () async {
    final Future<QuestionOutcome> pending = broker.ask(request());
    final String qid = questions.list().single.qid;
    expect(broker.cancel(qid, reason: '用户取消'), isTrue);
    final QuestionOutcome outcome = await pending;
    expect(outcome.cancelled, isTrue);
    expect(questions.byId(qid)?.status, QuestionStatus.cancelled);
    expect(broker.cancel(qid), isFalse, reason: '重复取消幂等');
  });

  test('stop 语义：isCancelled 轮询与 cancelForAgent 都能收尾', () async {
    bool cancelled = false;
    final Future<QuestionOutcome> polled = broker.ask(
      request(isCancelled: () => cancelled),
    );
    final Future<QuestionOutcome> forced = broker.ask(
      request(question: '第二个问题'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    cancelled = true;
    expect((await polled).cancelled, isTrue, reason: '轮询到 stop 后收尾');

    expect(broker.inFlightCount, 1);
    expect(broker.cancelForAgent(agent.id), 1);
    expect((await forced).cancelled, isTrue);
    expect(broker.pending(), isEmpty);
  });

  test('超时按取消收尾（默认不超时，可显式指定）', () async {
    final QuestionOutcome outcome = await broker.ask(
      request(),
      timeout: const Duration(milliseconds: 30),
    );
    expect(outcome.cancelled, isTrue);
    expect(questions.list().single.status, QuestionStatus.cancelled);
    expect(broker.inFlightCount, 0);
  });

  test('重启后补答：没有在途生成就把答案写进会话，供下一轮续跑', () async {
    // 模拟"重启"：只保留提问记录，broker 是新的（无在途 future）
    final MemoryQuestionStore persisted = MemoryQuestionStore();
    final QuestionBroker restarted = QuestionBroker(
      questions: persisted,
      transcript: store,
      broadcast: frames.add,
    );
    persisted.add(
      QuestionRecord(
        qid: 'q_old',
        agentId: agent.id,
        sessionId: sessionId,
        question: '旧提问',
        createdAt: 1,
      ),
    );
    expect(restarted.answer('q_old', <String>['继续']), isTrue);
    final CoreMessage answer = store
        .messages(agent.id, sessionId)
        .lastWhere((CoreMessage m) => m.role == 'user');
    expect(answer.content, '${QuestionBroker.answerPrefix}继续');
    expect(restarted.inFlightCount, 0);
  });

  test('记录被摘掉（删除 agent）后 cancel 仍收尾在途等待', () async {
    final Future<QuestionOutcome> pending = broker.ask(request());
    final String qid = questions.list().single.qid;
    // 删除 agent 的动作就是把记录直接摘掉（QuestionStore.removeForAgent）
    expect(questions.removeForAgent(agent.id), 1);
    expect(broker.inFlightCount, 1, reason: '摘记录本身不会收尾在途等待');

    // 硬化后的 cancel：记录没了也照样完成 completer（否则那一轮永远挂着）
    expect(broker.cancel(qid, reason: 'agent 已删除'), isTrue);
    expect((await pending).cancelled, isTrue);
    expect(broker.inFlightCount, 0);
    expect(broker.cancel(qid), isFalse, reason: '已经没有可收尾的了');
  });

  test('cancelForAgent 按 store 的 pending 列表遍历：记录摘掉后它救不回来', () async {
    final Future<QuestionOutcome> pending = broker.ask(request());
    questions.removeForAgent(agent.id);
    expect(broker.cancelForAgent(agent.id), 0);
    expect(broker.inFlightCount, 1, reason: '这就是删除路径必须先取消的原因');
    broker.dispose();
    expect((await pending).cancelled, isTrue);
  });

  test('dispose：关停时全部在途等待立刻收尾（不让生成任务挂着）', () async {
    final Future<QuestionOutcome> pending = broker.ask(request());
    broker.dispose();
    expect((await pending).cancelled, isTrue);
    expect(broker.inFlightCount, 0);
  });


  group('提问暂停事件（阶段 6：广播站点位 ask.paused）', () {
    test('只递 qid 与题数；一次提问一条', () async {
      // 发布时机 = 问题**落盘并推帧之后**（那时才证明得了“真的在等人”）。
      // 题面与选项**不进事件**：那是用户与 agent 之间的内容，审计只需要
      // “谁在等、等几道”（插件代答会直接假成“用户说了话”，所以也不递答案）。
      final List<Map<String, dynamic>> events = <Map<String, dynamic>>[];
      final QuestionBroker wired = QuestionBroker(
        questions: questions,
        transcript: store,
        broadcast: frames.add,
        onAskPaused: events.add,
        pollInterval: const Duration(milliseconds: 10),
      );
      final Future<QuestionOutcome> pending = wired.ask(
        request(
          questions: <AskedQuestion>[
            AskedQuestion(
              question: '选哪个方案？',
              options: const <String>['A', 'B'],
            ),
            AskedQuestion(question: '要不要顺手改配置？'),
          ],
        ),
      );
      final QuestionRecord record = questions.list().single;
      expect(
        events,
        hasLength(1),
        reason: '一次提问 = 一条暂停事件（不是每题一条：等的是一次作答）',
      );
      final Map<String, dynamic> event = events.single;
      expect(event['event'], AgentEvents.askPaused);
      expect(event['question_id'], record.qid, reason: '要去 REST / 右栏对得上号');
      expect(event['question_count'], 2);
      expect(event['agent_id'], agent.id);
      expect(event['session_id'], sessionId);
      expect(
        '$event',
        isNot(contains('选哪个方案')),
        reason: '题面与选项不许被复制进插件',
      );
      // 事件发布不能抢占提问本身：照常等到作答
      expect(wired.answer(record.qid, <String>['A', '改']), isTrue);
      final QuestionOutcome outcome = await pending;
      expect(outcome.cancelled, isFalse);
      expect(broker.inFlightCount, 0, reason: '两个 broker 互不干扰');
    });

    test('订阅方抛异常也不影响提问回路（插件侧问题不能让 agent 问不出话）', () async {
      final List<String> logs = <String>[];
      final QuestionBroker wired = QuestionBroker(
        questions: questions,
        transcript: store,
        broadcast: frames.add,
        onAskPaused: (Map<String, dynamic> _) => throw StateError('插件侧炸了'),
        log: logs.add,
        pollInterval: const Duration(milliseconds: 10),
      );
      final Future<QuestionOutcome> pending = wired.ask(request());
      expect(questions.list(), hasLength(1));
      expect(
        logs.any((String line) => line.contains('提问暂停事件发布失败')),
        isTrue,
        reason: '发不出去要查得到（不变量 6），但不能拖死提问',
      );
      final QuestionRecord record = questions.list().single;
      expect(wired.answer(record.qid, <String>['A']), isTrue);
      expect((await pending).answer, 'A');
    });
  });
}
