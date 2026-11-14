/// 准备阶段（P3）的执行站命令门面：需求模板 → 侦查 → 追问 → 范围/拆任务 → 落档。
///
/// 与 P1 的 `ProductionService` 分开：这里要 await 外部通道（`docnorm.query` /
/// `llm.call` / `settings.get`），P1 的门面保持同步、测试零改动。
/// 两条门面共用同一套 [ProductionStore]（`task.yaml` 仍是唯一真值）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'execution_service.dart';
import 'memory_port.dart';
import 'models.dart';
import 'plan_document.dart';
import 'planner.dart';
import 'preparation.dart';
import 'service.dart';
import 'store.dart';

/// P3 对外开放的命令族（同一个执行站 `production`）。
const List<String> kPreparationCommands = <String>[
  'production.prepare.intake',
  'production.prepare.recon',
  'production.prepare.questions',
  'production.prepare.answer',
  'production.prepare.all_recommended',
  'production.prepare.window.open',
  'production.prepare.window.close',
  'production.prepare.read',
  'production.prepare.finalize',
  'production.prepare.status',
  'production.plan.validate',
  'production.plan.get',
];

/// 模型调用（插件层接 `llm.call`；单测注入假实现）。
///
/// [modelId] = 产线主控（`roles.orchestrator.model_id`）；空表示沿用调用方
/// Agent 的模型（旧产线还没配主控时）。
typedef PreparationLlm = Future<Map<String, Object?>> Function(
  String point,
  String system,
  String prompt,
  Map<String, Object?> scope,
  String modelId,
);

/// 视觉模型调用（多模态 `llm.call`；单测注入假实现）。
///
/// [images] 的每项固定为 `{'name', 'mime', 'base64'}`；base64 只在内存里周转，
/// 不写进任何落盘文件。
typedef PreparationVisionLlm = Future<Map<String, Object?>> Function(
  String point,
  String system,
  String prompt,
  List<Map<String, Object?>> images,
  Map<String, Object?> scope,
  String modelId,
);

/// 文档检索（插件层接 `docnorm.query`；准备阶段**fail-closed**，不许凭空侦查）。
typedef DocQuery = Future<Map<String, Object?>> Function(
  String repo,
  String question,
  Map<String, Object?> scope,
);

/// 追问上限（插件层接 `settings.get`；null = 没配，回退 line.yaml / 默认 3）。
typedef QuestionLimitReader = Future<int?> Function(Map<String, Object?> scope);

class PreparationService {
  PreparationService({
    Map<String, String>? environment,
    DateTime Function()? clock,
    this.llm,
    this.visionLlm,
    this.docQuery,
    this.limitReader,
    this.onCycle,
    this.memory,
    this.onTaskState,
    this.queryTimeout = const Duration(seconds: 5),
    this.retrievalDeadline = const Duration(seconds: 10),
    this.totalDeadline = const Duration(seconds: 60),
  }) : _environment = environment ?? Platform.environment,
       _clock = clock ?? DateTime.now;

  final Map<String, String> _environment;
  final DateTime Function() _clock;

  /// 任务状态变化的事件监听（Task 9.1；旁路，失败不影响业务）。
  final TaskStateListener? onTaskState;

  /// 模型调用；null = 未接线（准备阶段 fail-closed）。
  final PreparationLlm? llm;

  /// 视觉模型调用；null = 不送图（退回纯文本摘要，不阻断侦查）。
  final PreparationVisionLlm? visionLlm;
  final DocQuery? docQuery;
  final QuestionLimitReader? limitReader;

  /// `tree.agent` 记忆端口；null = 不启用（侦查照常，元数据标不可用）。
  final MemoryPort? memory;

  /// 单次检索超时（两次 embed 并行，合计目标 ≤5s）。
  final Duration queryTimeout;

  /// 检索阶段总门控（P95 ≤10s）；超时用已召回部分继续，不补第三轮。
  final Duration retrievalDeadline;

  /// 1 分钟理解总时限（从 `production.prepare.recon` 开始计）；LLM #2 只用剩余时间，
  /// 超时返回 partial 首版卡，不流转状态、不伪造侦查。
  final Duration totalDeadline;

  /// 落档（finalize）完成后触发主控 tick（插件层接事件驱动；null = 不触发）。
  final ProductionCycleTrigger? onCycle;

  String get _now => _clock().toIso8601String();

  Future<Map<String, Object?>> handle(
    String command,
    Map<String, Object?> arguments,
    Map<String, Object?> meta,
    Map<String, Object?> scope,
  ) async {
    final ProductionTarget target = resolveProductionTarget(
      meta,
      scope,
      _environment,
    );
    final ProductionStore store = ProductionStore(
      dataRoot: target.dataRoot,
      clock: _clock,
      onTaskState: onTaskState,
    );
    switch (command) {
      case 'production.prepare.intake':
        return _intake(store, arguments);
      case 'production.prepare.recon':
        return await _recon(store, arguments, scope);
      case 'production.prepare.questions':
        return _questions(store, arguments);
      case 'production.prepare.answer':
        return _answer(store, arguments, source: '用户回答');
      case 'production.prepare.all_recommended':
        return _allRecommended(store, arguments);
      case 'production.prepare.window.open':
        return _windowOpen(store, arguments);
      case 'production.prepare.window.close':
        return _windowClose(store, arguments);
      case 'production.prepare.read':
        return _read(store, arguments);
      case 'production.prepare.finalize':
        {
          final Map<String, Object?> result = await _finalize(
            store,
            arguments,
            scope,
          );
          // 落档建出 queued 任务后补一次主控 tick（插件层 debounce，幂等）。
          await _notifyCycle(arguments, meta, scope);
          return result;
        }
      case 'production.prepare.status':
        return _status(store, arguments);
      case 'production.plan.validate':
        return _planValidate(store, arguments);
      case 'production.plan.get':
        return _planGet(store, arguments);
      default:
        throw ProductionFailure('未知准备阶段命令：$command', code: 'unknown_command');
    }
  }

  // ── 需求模板 ──────────────────────────────────────────────────────

  Map<String, Object?> _intake(
    ProductionStore store,
    Map<String, Object?> arguments,
  ) {
    final String lineId = _arg(arguments, 'line_id');
    store.getLine(lineId);
    final Map<String, Object?> input = arguments['task'] is Map
        ? plainMap(arguments['task'])
        : (<String, Object?>{...arguments}..remove('line_id'));
    final IntakeResult intake = normalizeIntake(
      plainMap(input['intake'] ?? input),
    );
    if (!intake.ok) {
      throw ProductionFailure(
        intake.blocking.join('；'),
        code: 'intake_incomplete',
      );
    }
    final String title = textOf(input['title']).isNotEmpty
        ? textOf(input['title'])
        : intake.values['goal']!;
    final String id = textOf(input['id']).isNotEmpty
        ? textOf(input['id'])
        : 'T${_clock().millisecondsSinceEpoch}';
    final Map<String, Object?> data = buildTaskMap(
      <String, Object?>{
        ...input,
        'title': title,
        'status': TaskStatus.draft.wire,
      },
      id: id,
      now: _now,
    )..['intake'] = intake.values;
    final TaskRecord task = store.createTask(lineId, data);
    return <String, Object?>{
      'task': task.toJson(),
      'intake': intake.values,
      'warnings': intake.warnings,
    };
  }

  // ── 侦查 ──────────────────────────────────────────────────────────

  Future<Map<String, Object?>> _recon(
    ProductionStore store,
    Map<String, Object?> arguments,
    Map<String, Object?> scope,
  ) async {
    // 1 分钟口径从这里开始：摘要 + 双查询 + LLM #2 共用这一份预算。
    final Stopwatch totalWatch = Stopwatch()..start();
    final String lineId = _arg(arguments, 'line_id');
    final String taskId = _arg(arguments, 'task_id');
    final LineRecord line = store.getLine(lineId);
    TaskRecord task = store.getTask(lineId, taskId);
    if (!const <TaskStatus>{
      TaskStatus.draft,
      TaskStatus.recon,
      TaskStatus.aligning,
      TaskStatus.awaitingUser,
    }.contains(task.status)) {
      throw ProductionFailure(
        '任务当前状态 ${task.status.wire} 不能侦查（只允许 draft / recon / aligning / awaiting_user）',
        code: 'prepare_state',
      );
    }
    final Map<String, Object?> intakeMap = plainMap(task.data['intake']);
    if (intakeMap.isEmpty) {
      throw ProductionFailure(
        '任务 $taskId 没有需求模板：先调 production.prepare.intake',
        code: 'intake_required',
      );
    }
    final Map<String, String> intake = <String, String>{
      for (final String key in kIntakeKeys) key: textOf(intakeMap[key]),
    };
    final int limit = await _limitFor(store, line, scope);
    // 工作空间 + 检索通道：**fail-closed**（缺 docnorm / llm 不降级为凭空侦查）。
    final String workspace = store.workspaceDirOf(lineId);
    _requireDocQuery();
    final List<Map<String, Object?>> attachments = _attachmentsOf(task);
    final String modelId = _orchestratorModel(line);
    // 记忆只喂提示词；落盘的只有 hash / sources / unavailable（读失败不阻断）。
    final MemoryView memoryView = await _readMemory(
      textOf(plainMap(line.data['executor'])['agent_id']),
      'production.prepare.recon',
      scope,
    );

    // ① LLM #1：先摘要/关键词；单独计时，不混入检索 10s。
    // 视觉附件（vision_model）走多模态通道，图片本体只在内存里；失败即跳过。
    final Stopwatch digestWatch = Stopwatch()..start();
    final List<Map<String, Object?>> digestImages = _digestImages(
      store,
      lineId,
      attachments,
    );
    final String digestSystem = digestSystemPrompt();
    final String digestPrompt = digestUserPrompt(
      intake: intake,
      attachments: attachments,
      projectMemory: memoryView.text,
    );
    final Map<String, Object?> digestJson =
        visionLlm != null && digestImages.isNotEmpty
        ? await _callVisionLlm(
            'production.digest',
            digestSystem,
            digestPrompt,
            digestImages,
            scope,
            modelId,
          )
        : await _callLlm(
            'production.digest',
            digestSystem,
            digestPrompt,
            scope,
            modelId,
          );
    digestWatch.stop();
    final Digest digest = parseDigestJson(digestJson);

    // ② 双查询并行（原文 + 关键词），各自超时；合计目标 ≤5s。
    final String queryA = requirementSearchQuery(intake);
    final String queryB = digestSearchQuery(digest);
    final _Retrieval retrieval = await _retrieveDocs(
      workspace,
      queryA,
      queryB,
      scope,
    );

    // ③ LLM #2：只读摘要 + evidence；只用 1 分钟预算的剩余时间。
    final Stopwatch llmWatch = Stopwatch()..start();
    final Duration remaining = totalDeadline - totalWatch.elapsed;
    Map<String, Object?>? json;
    if (remaining > Duration.zero) {
      try {
        json = await _callLlm(
          'production.recon',
          reconSystemPrompt(maxQuestions: limit),
          reconUserPrompt(
            lineName: line.name,
            taskId: taskId,
            title: task.title,
            intake: intake,
            tools: _orchestratorTools(line),
            digest: digest,
            evidence: retrieval.evidence,
          ),
          scope,
          modelId,
        ).timeout(remaining);
      } on TimeoutException {
        json = null;
      }
    }
    llmWatch.stop();
    totalWatch.stop();
    if (json == null) {
      // 到点：不抛错、不流转状态、不伪造侦查；落 partial 首版卡供 UI 显示与重试。
      return _partialRecon(
        store: store,
        lineId: lineId,
        taskId: taskId,
        task: task,
        limit: limit,
        digest: digest,
        retrieval: retrieval,
        memoryView: memoryView,
        digestMs: digestWatch.elapsedMilliseconds,
        llmMs: llmWatch.elapsedMilliseconds,
        totalMs: totalWatch.elapsedMilliseconds,
      );
    }
    final Set<String> knownEvidence = <String>{
      for (final ReconEvidence item in retrieval.evidence) item.id,
    };
    final ReconDraft draft = parseReconJson(
      json,
      maxQuestions: 10,
      knownEvidence: knownEvidence,
    );
    final Map<String, Object?> timing = <String, Object?>{
      'digest_ms': digestWatch.elapsedMilliseconds,
      'retrieve_ms': retrieval.retrieveMs,
      'llm_ms': llmWatch.elapsedMilliseconds,
      'total_ms': totalWatch.elapsedMilliseconds,
      'deadline_ms': totalDeadline.inMilliseconds,
    };
    final List<Map<String, Object?>> inbox = store.readInbox(lineId);
    final List<QuestionState> existing = replayQuestions(inbox, taskId: taskId);
    final ({List<ReconQuestionSpec> added, int dropped}) planned =
        planNewQuestions(
          incoming: draft.questions,
          existing: existing,
          limit: limit,
        );
    final Map<String, Object?> window = _ensureWindow(store, lineId);
    final List<String> ids = <String>[
      for (final QuestionState question in existing) question.qid,
    ];
    for (final ReconQuestionSpec question in planned.added) {
      final String qid = nextQuestionId(ids);
      ids.add(qid);
      store.appendInbox(lineId, <String, Object?>{
        'type': 'question',
        'line_id': lineId,
        'task_id': taskId,
        'qid': qid,
        'text': question.text,
        'default': question.defaultValue,
        'recommended': question.recommended,
        'consequence': question.consequence,
        if (question.evidenceIds.isNotEmpty)
          'evidence_ids': question.evidenceIds,
        'round': intOf(window['round'], 1),
        'window_id': textOf(window['id']),
        'asked_at': _now,
      });
    }
    final List<QuestionState> questions = replayQuestions(
      store.readInbox(lineId),
      taskId: taskId,
    );
    final String assetDir = _assetDir(store, lineId);
    final String reconRelative = '$assetDir/recon.md';
    final String reconJsonRelative = '$assetDir/recon.json';
    store.writeAsset(
      lineId,
      'recon.md',
      renderReconMd(
        taskId: taskId,
        title: task.title,
        intake: intake,
        recon: draft,
        questions: questions,
      ),
    );
    store.writeAsset(
      lineId,
      'recon.json',
      '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'version': 1,
        'task_id': taskId,
        'asked_at': _now,
        'intake': intake,
        'digest': digest.toJson(),
        'digest_images': digestImages.length,
        'queries': <String, Object?>{'a': queryA, 'b': queryB},
        'evidence': <Map<String, Object?>>[for (final ReconEvidence item in retrieval.evidence) item.toJson()],
        'timing': timing,
        ..._memoryMeta(memoryView),
        'degraded': retrieval.degraded,
        'partial': retrieval.partial,
        'recall_gap': retrieval.recallGap,
        'recon': draft.toJson(),
        'questions': <Map<String, Object?>>[for (final QuestionState question in questions) question.toJson()],
      })}\n',
    );
    _writeDecisions(store, lineId);
    // 状态推进：draft → recon → aligning（没有问题时同样进 aligning，由用户拍板分发）。
    if (task.status == TaskStatus.draft) {
      store.transition(lineId, taskId, to: TaskStatus.recon.wire);
    }
    if (task.status == TaskStatus.draft || task.status == TaskStatus.recon) {
      store.transition(lineId, taskId, to: TaskStatus.aligning.wire);
    }
    task = store.putTask(lineId, taskId, <String, Object?>{
      'recon': <String, Object?>{
        'path': reconRelative,
        'json': reconJsonRelative,
        'asked_at': _now,
        'round': intOf(window['round'], 1),
        'questions': questions.length,
        'open': openQuestionsOf(questions).length,
        'dropped': planned.dropped,
        'flags': draft.flags,
        ...timing,
        ..._memoryMeta(memoryView),
        'degraded': retrieval.degraded,
        'partial': retrieval.partial,
        'timeout': false,
        'recall_gap': retrieval.recallGap,
        'digest': digest.toJson(),
        'digest_images': digestImages.length,
        'evidence': <Map<String, Object?>>[
          for (final ReconEvidence item in retrieval.evidence) item.toJson(),
        ],
      },
    });
    return <String, Object?>{
      'task': task.toJson(),
      'recon': draft.toJson(),
      'digest': digest.toJson(),
      'evidence': <Map<String, Object?>>[
        for (final ReconEvidence item in retrieval.evidence) item.toJson(),
      ],
      'questions': <Map<String, Object?>>[
        for (final QuestionState question in questions) question.toJson(),
      ],
      'open': openQuestionsOf(questions).length,
      'dropped': planned.dropped,
      'limit': limit,
      'window': window,
      ...timing,
      'degraded': retrieval.degraded,
      'partial': retrieval.partial,
      'timeout': false,
      'recall_gap': retrieval.recallGap,
    };
  }

  /// 1 分钟到点：只回摘要 + 检索证据 + 分段耗时；不写 `recon.md`、不建问题、
  /// 不流转状态，让 UI 先显示 partial 首版卡并给出「重试」。
  Map<String, Object?> _partialRecon({
    required ProductionStore store,
    required String lineId,
    required String taskId,
    required TaskRecord task,
    required int limit,
    required Digest digest,
    required _Retrieval retrieval,
    required MemoryView memoryView,
    required int digestMs,
    required int llmMs,
    required int totalMs,
  }) {
    final int deadlineMs = totalDeadline.inMilliseconds;
    final List<QuestionState> existing = replayQuestions(
      store.readInbox(lineId),
      taskId: taskId,
    );
    final List<Map<String, Object?>> evidence = <Map<String, Object?>>[
      for (final ReconEvidence item in retrieval.evidence) item.toJson(),
    ];
    final TaskRecord saved = store.putTask(lineId, taskId, <String, Object?>{
      'recon': <String, Object?>{
        ...plainMap(task.data['recon']),
        'asked_at': _now,
        'partial': true,
        'timeout': true,
        'deadline_ms': deadlineMs,
        'digest_ms': digestMs,
        'retrieve_ms': retrieval.retrieveMs,
        'llm_ms': llmMs,
        'total_ms': totalMs,
        'degraded': retrieval.degraded,
        'recall_gap': retrieval.recallGap,
        'digest': digest.toJson(),
        'evidence': evidence,
        ..._memoryMeta(memoryView),
      },
    });
    return <String, Object?>{
      'task': saved.toJson(),
      'digest': digest.toJson(),
      'evidence': evidence,
      'questions': <Map<String, Object?>>[
        for (final QuestionState question in existing) question.toJson(),
      ],
      'open': openQuestionsOf(existing).length,
      'dropped': 0,
      'limit': limit,
      'window': _windowOf(store, lineId),
      'digest_ms': digestMs,
      'retrieve_ms': retrieval.retrieveMs,
      'llm_ms': llmMs,
      'total_ms': totalMs,
      'deadline_ms': deadlineMs,
      'degraded': retrieval.degraded,
      'partial': true,
      'timeout': true,
      'recall_gap': retrieval.recallGap,
    };
  }

  // ── 追问 ──────────────────────────────────────────────────────────

  Map<String, Object?> _questions(
    ProductionStore store,
    Map<String, Object?> arguments,
  ) {
    final String lineId = _arg(arguments, 'line_id');
    final LineRecord line = store.getLine(lineId);
    final String taskId = textOf(arguments['task_id']);
    final List<QuestionState> questions = replayQuestions(
      store.readInbox(lineId),
      taskId: taskId,
    );
    final int limit = clampQuestionLimit(
      plainMap(line.data['limits'])['max_questions_per_round'],
    );
    return <String, Object?>{
      'questions': <Map<String, Object?>>[
        for (final QuestionState question in questions) question.toJson(),
      ],
      'open': <Map<String, Object?>>[
        for (final QuestionState question in openQuestionsOf(questions))
          question.toJson(),
      ],
      'limit': limit,
      'window': _windowOf(store, lineId),
    };
  }

  Map<String, Object?> _answer(
    ProductionStore store,
    Map<String, Object?> arguments, {
    required String source,
  }) {
    final String lineId = _arg(arguments, 'line_id');
    final String taskId = _arg(arguments, 'task_id');
    store.getLine(lineId);
    return _applyAnswers(
      store,
      lineId,
      taskId,
      answers: _answersOf(arguments),
      source: source,
    );
  }

  Map<String, Object?> _allRecommended(
    ProductionStore store,
    Map<String, Object?> arguments,
  ) {
    final String lineId = _arg(arguments, 'line_id');
    final String taskId = _arg(arguments, 'task_id');
    store.getLine(lineId);
    final List<QuestionState> open = openQuestionsOf(
      replayQuestions(store.readInbox(lineId), taskId: taskId),
    );
    if (open.isEmpty) {
      throw ProductionFailure('任务 $taskId 没有未答问题', code: 'no_open_questions');
    }
    final List<Map<String, Object?>> answers = <Map<String, Object?>>[];
    for (final QuestionState question in open) {
      final String value = question.recommended.isNotEmpty
          ? question.recommended
          : question.defaultValue;
      if (value.isEmpty) {
        throw ProductionFailure(
          '${question.qid} 没有推荐项也没有默认项，不能「全部按推荐」',
          code: 'no_recommendation',
        );
      }
      answers.add(<String, Object?>{'qid': question.qid, 'value': value});
    }
    return _applyAnswers(
      store,
      lineId,
      taskId,
      answers: answers,
      source: '按推荐拍板',
    );
  }

  Map<String, Object?> _applyAnswers(
    ProductionStore store,
    String lineId,
    String taskId, {
    required List<Map<String, Object?>> answers,
    required String source,
  }) {
    TaskRecord task = store.getTask(lineId, taskId);
    if (!const <TaskStatus>{
      TaskStatus.aligning,
      TaskStatus.awaitingUser,
    }.contains(task.status)) {
      throw ProductionFailure(
        '任务当前状态 ${task.status.wire} 不接受拍板（只允许 aligning / awaiting_user）',
        code: 'prepare_state',
      );
    }
    final Map<String, Object?> window = _ensureWindow(store, lineId);
    final Map<String, QuestionState> byId = <String, QuestionState>{
      for (final QuestionState question in replayQuestions(
        store.readInbox(lineId),
        taskId: taskId,
      ))
        question.qid: question,
    };
    for (final Map<String, Object?> answer in answers) {
      final String qid = textOf(answer['qid']);
      final String value = textOf(answer['value']);
      final QuestionState? question = byId[qid];
      if (question == null) {
        throw ProductionFailure(
          '任务 $taskId 没有 ${qid.isEmpty ? '（空 qid）' : qid}',
          code: 'unknown_question',
        );
      }
      if (value.isEmpty) {
        throw ProductionFailure('$qid 的回答不能为空', code: 'invalid_arguments');
      }
      store.appendInbox(lineId, <String, Object?>{
        'type': 'answer',
        'line_id': lineId,
        'task_id': taskId,
        'qid': qid,
        'value': value,
        'source': source,
        'previous': question.answered ? question.answer : '',
        'round': intOf(window['round'], 1),
        'window_id': textOf(window['id']),
        'answered_at': _now,
      });
    }
    final List<QuestionState> questions = replayQuestions(
      store.readInbox(lineId),
      taskId: taskId,
    );
    final int open = openQuestionsOf(questions).length;
    final bool ready = open == 0;
    // 答完最后一条 = 用户回到了窗口：awaiting_user → aligning（§7.3 只允许这一条边）。
    // 注意**不自动 scoped**：scoped 是「范围与任务已落档」，只能由 finalize 触发。
    if (ready && task.status == TaskStatus.awaitingUser) {
      store.transition(lineId, taskId, to: TaskStatus.aligning.wire);
    }
    task = store.putTask(lineId, taskId, <String, Object?>{
      'questions': <String, Object?>{'total': questions.length, 'open': open},
    });
    _writeDecisions(store, lineId);
    return <String, Object?>{
      'task': task.toJson(),
      'questions': <Map<String, Object?>>[
        for (final QuestionState question in questions) question.toJson(),
      ],
      'open': open,
      'ready': ready,
      'window': window,
    };
  }

  // ── 活跃窗口 ──────────────────────────────────────────────────────

  Map<String, Object?> _windowOpen(
    ProductionStore store,
    Map<String, Object?> arguments,
  ) {
    final String lineId = _arg(arguments, 'line_id');
    final LineRecord line = store.getLine(lineId);
    final Map<String, Object?> window = _ensureWindow(store, lineId);
    final List<String> resumed = <String>[];
    for (final TaskRecord task in store.listTasks(lineId)) {
      if (task.status != TaskStatus.awaitingUser) continue;
      store.transition(lineId, task.id, to: TaskStatus.aligning.wire);
      resumed.add(task.id);
    }
    return <String, Object?>{
      'window': window,
      'resumed': resumed,
      'line': line.toJson(),
    };
  }

  Map<String, Object?> _windowClose(
    ProductionStore store,
    Map<String, Object?> arguments,
  ) {
    final String lineId = _arg(arguments, 'line_id');
    store.getLine(lineId);
    final Map<String, Object?> prepare = store.readPrepare(lineId);
    final Map<String, Object?> window = plainMap(prepare['window']);
    if (textOf(window['id']).isEmpty) {
      throw ProductionFailure('当前没有打开的窗口', code: 'window_not_open');
    }
    final List<String> awaiting = <String>[];
    for (final TaskRecord task in store.listTasks(lineId)) {
      if (task.status != TaskStatus.aligning) continue;
      final List<QuestionState> open = openQuestionsOf(
        replayQuestions(store.readInbox(lineId), taskId: task.id),
      );
      if (open.isEmpty) continue;
      store.transition(lineId, task.id, to: TaskStatus.awaitingUser.wire);
      awaiting.add(task.id);
    }
    final Map<String, Object?> closed = <String, Object?>{
      ...window,
      'closed_at': _now,
    };
    store.writePrepare(lineId, <String, Object?>{
      ...prepare,
      'version': 1,
      'window': closed,
    });
    return <String, Object?>{
      'window': closed,
      'awaiting': awaiting,
      'count': awaiting.length,
    };
  }

  // ── 点状读取（预算：文件 ≤ 8 / grep ≤ 2 轮）───────────────────────

  Map<String, Object?> _read(
    ProductionStore store,
    Map<String, Object?> arguments,
  ) {
    final String lineId = _arg(arguments, 'line_id');
    final String taskId = _arg(arguments, 'task_id');
    final TaskRecord task = store.getTask(lineId, taskId);
    if (task.status.isTerminal) {
      throw ProductionFailure(
        '任务已处于终态 ${task.status.wire}，不再点状读取',
        code: 'prepare_state',
      );
    }
    final Map<String, Object?> prepare = store.readPrepare(lineId);
    final Map<String, Object?> reads = plainMap(prepare['reads']);
    final Map<String, Object?> counters = plainMap(reads[taskId]);
    final ReadBudget budget = ReadBudget(
      files: intOf(counters['files'], 0),
      grepRounds: intOf(counters['grep_rounds'], 0),
    );
    final String path = textOf(arguments['path']);
    final String pattern = textOf(arguments['pattern']);
    Map<String, Object?> reply;
    if (path.isNotEmpty) {
      if (!budget.canReadFile) {
        throw ProductionFailure(
          '本会话点状读取已到上限（${budget.maxFiles} 个文件）：$path',
          code: 'budget_exceeded',
        );
      }
      final String content = store.readWorkspaceFile(lineId, path);
      budget.files += 1;
      reply = <String, Object?>{
        'mode': 'read',
        'path': path,
        'content': content,
      };
    } else if (pattern.isNotEmpty) {
      if (!budget.canGrep) {
        throw ProductionFailure(
          '本会话 grep 已到上限（${budget.maxGrepRounds} 轮）',
          code: 'budget_exceeded',
        );
      }
      final List<Map<String, Object?>> matches = store.grepWorkspace(
        lineId,
        pattern,
        path: textOf(arguments['path_scope']),
        regex: arguments['regex'] == true,
        ignoreCase: arguments['ignore_case'] == true,
      );
      budget.grepRounds += 1;
      reply = <String, Object?>{
        'mode': 'grep',
        'pattern': pattern,
        'matches': matches,
        'count': matches.length,
      };
    } else {
      throw ProductionFailure(
        'production.prepare.read 需要 path 或 pattern',
        code: 'invalid_arguments',
      );
    }
    store.writePrepare(lineId, <String, Object?>{
      ...prepare,
      'version': 1,
      'reads': <String, Object?>{...reads, taskId: budget.toJson()},
    });
    return <String, Object?>{...reply, 'budget': budget.toJson()};
  }

  // ── 定范围 / 拆任务 / 落档 ────────────────────────────────────────

  Future<Map<String, Object?>> _finalize(
    ProductionStore store,
    Map<String, Object?> arguments,
    Map<String, Object?> scope,
  ) async {
    final String lineId = _arg(arguments, 'line_id');
    final String taskId = _arg(arguments, 'task_id');
    final LineRecord line = store.getLine(lineId);
    TaskRecord task = store.getTask(lineId, taskId);
    if (task.status == TaskStatus.scoped) {
      throw ProductionFailure('任务 $taskId 已分发（scoped）', code: 'already_scoped');
    }
    final List<QuestionState> questions = replayQuestions(
      store.readInbox(lineId),
      taskId: taskId,
    );
    final List<QuestionState> open = openQuestionsOf(questions);
    // **未答不实施**优先于状态判据：awaiting_user 时最有信息量的原因是"还有问题没答"。
    if (open.isNotEmpty) {
      throw ProductionFailure(
        '还有 ${open.length} 条未答问题（${open.map((QuestionState q) => q.qid).join(', ')}）：'
        '未答不实施',
        code: 'questions_open',
      );
    }
    if (task.status != TaskStatus.aligning) {
      throw ProductionFailure(
        '只有 aligning 状态可以落档（当前 ${task.status.wire}）',
        code: 'prepare_state',
      );
    }
    final Set<String> existingIds = <String>{
      taskId,
      for (final TaskRecord existing in store.listTasks(lineId)) existing.id,
    };
    final int maxParallel = intOf(
      plainMap(line.data['limits'])['max_parallel_tasks'],
      1,
    );
    final ({PlanDocument doc, PlanDocValidation validation}) planned =
        await _planFor(
          store,
          line,
          task,
          questions,
          arguments,
          scope,
          existingIds: existingIds,
          maxParallel: maxParallel,
        );
    final PlanDocValidation validation = planned.validation;
    final ScopePlan plan = _scopePlanOf(planned.doc);
    final int version = store.nextPlanVersion(lineId);
    final String planVersion = 'plan-v$version';
    store.writePlanVersion(lineId, version, <String, Object?>{
      ...validation.doc.toJson(),
      'saved_at': _now,
    }, validation: _validationJson(validation, existingIds, maxParallel));
    store.writePlanFindings(lineId, version, validation.doc.findings);
    final ScopePlan fixedPlan = _fixedPlan(plan, validation.doc.tasks);
    // 落档顺序（§8.6）：先写文档，再建任务，最后重建索引。
    final String assetDir = _assetDir(store, lineId);
    store.writeAsset(
      lineId,
      'scope.md',
      renderScopeMd(taskId: taskId, plan: fixedPlan),
    );
    store.writeAsset(
      lineId,
      'plan.md',
      renderPlanMd(lineName: line.name, taskId: taskId, plan: fixedPlan),
    );
    final List<Map<String, Object?>> created = <Map<String, Object?>>[];
    for (final Map<String, Object?> spec in validation.doc.tasks) {
      final String id = textOf(spec['id']);
      final List<String> acceptance = stringsOf(spec['acceptance']);
      store.writeAsset(
        lineId,
        'tasks/$id/acceptance.md',
        renderAcceptanceMd(
          taskId: id,
          title: textOf(spec['title']),
          acceptance: acceptance,
        ),
      );
      store.createTask(lineId, <String, Object?>{
        'id': id,
        'title': textOf(spec['title']),
        'kind': textOf(spec['kind']),
        'status': TaskStatus.queued.wire,
        'priority': 50,
        'task_type': textOf(spec['task_type']),
        'depends_on': stringsOf(spec['depends_on']),
        'read_scope': stringsOf(spec['read_scope']),
        'write_scope': stringsOf(spec['write_scope']),
        'acceptance': acceptance,
        'gate': plainMap(spec['gate']),
        'estimated_files': intOf(spec['estimated_files'], 1),
        'risk': textOf(spec['risk']),
        if (spec['contract'] != null) 'contract': plainValue(spec['contract']),
        'rationale': textOf(spec['rationale']),
        'artifacts': <String, Object?>{
          'recon': '$assetDir/recon.md#$taskId',
          'acceptance': '$assetDir/tasks/$id/acceptance.md',
        },
      });
      final TaskRecord saved = store.putTask(lineId, id, <String, Object?>{
        'prepared_by': taskId,
        'plan_version': planVersion,
        'estimated_lines': intOf(spec['estimated_lines'], 0),
        'estimated_packages': intOf(spec['estimated_packages'], 0),
        if (textOf(spec['split_reason']).isNotEmpty)
          'split_reason': textOf(spec['split_reason']),
      });
      created.add(saved.toJson());
    }
    store.transition(lineId, taskId, to: TaskStatus.scoped.wire);
    final Map<String, Object?> scopeData = <String, Object?>{
      ...plan.toJson(),
      'tasks': validation.doc.tasks,
      'plan_version': planVersion,
    };
    task = store.putTask(lineId, taskId, <String, Object?>{
      'scope': scopeData,
      'artifacts': <String, Object?>{
        'recon': '$assetDir/recon.md',
        'scope': '$assetDir/scope.md',
        'plan': '$assetDir/plan.md',
        'decisions': '$assetDir/decisions.md',
      },
    });
    final int limit = await _limitFor(store, line, scope);
    final List<String> summary = distributionSummary(
      tasks: fixedPlan.tasks,
      openQuestions: open.length,
      questionLimit: limit,
    );
    return <String, Object?>{
      'task': task.toJson(),
      'scope': scopeData,
      'created_tasks': created,
      'queue': store.next(lineId, limit: 0)['queue'],
      'summary': summary,
    };
  }

  /// 生成计划文档：显式 `plan` 保持旧行为（只跑 Task 7 校验，不调模型）；
  /// 否则走「起草 → 独立批判 → 打补丁」，最多 3 轮（§4.3）。
  Future<({PlanDocument doc, PlanDocValidation validation})> _planFor(
    ProductionStore store,
    LineRecord line,
    TaskRecord task,
    List<QuestionState> questions,
    Map<String, Object?> arguments,
    Map<String, Object?> scope, {
    required Set<String> existingIds,
    required int maxParallel,
  }) async {
    final Object? planInput = arguments['plan'];
    if (planInput is List && planInput.isNotEmpty) {
      final PlanDocument doc = parsePlanDocument(<String, Object?>{
        'in': arguments['in'],
        'out': arguments['out'],
        'not_doing': arguments['not_doing'],
        'tasks': planInput,
      });
      _validatePlanIds(existingIds, doc.tasks);
      return _validatedPlan(
        doc,
        existingIds: existingIds,
        maxParallel: maxParallel,
      );
    }
    final Map<String, String> intake = <String, String>{
      for (final String key in kIntakeKeys)
        key: textOf(plainMap(task.data['intake'])[key]),
    };
    final String assetDir = _assetDir(store, line.id);
    final String reconText = store.readWorkspaceFile(
      line.id,
      '$assetDir/recon.md',
    );
    final String decisionsText = store.readWorkspaceFile(
      line.id,
      '$assetDir/decisions.md',
    );
    final String modelId = _orchestratorModel(line);
    PlanDocument current = parsePlanDocument(
      await _callLlm(
        'production.plan',
        planDocumentSystemPrompt(),
        planDocumentUserPrompt(
          taskId: task.id,
          title: task.title,
          intake: intake,
          reconText: reconText,
          decisionsText: decisionsText,
          round: 1,
        ),
        scope,
        modelId,
      ),
    );
    // 旧式 tasks-only 计划（模型没给 requirements/design）只跑 Task 7 校验。
    if (!current.structured) {
      final PlanDocValidation legacy = validatePlanDocument(
        current,
        existingIds: existingIds,
        maxParallel: maxParallel,
      );
      if (!legacy.ok) {
        throw ProductionFailure(
          legacy.message,
          code: legacy.code,
          missing: legacy.missing,
        );
      }
      _validatePlanIds(existingIds, legacy.doc.tasks);
      return (doc: legacy.doc, validation: legacy);
    }
    List<Map<String, Object?>> carried = <Map<String, Object?>>[];
    for (int round = 1; round <= 3; round++) {
      final PlanDocValidation roundValidation = validatePlanDocument(
        current,
        existingIds: existingIds,
        maxParallel: maxParallel,
      );
      final List<Map<String, Object?>> roundFindings = <Map<String, Object?>>[
        for (final PlanIssue issue in roundValidation.issues)
          findingOf(issue, round),
      ];
      final List<Map<String, Object?>> merged = _mergeFindings(
        <Map<String, Object?>>[
          for (final Map<String, Object?> finding in carried)
            if (textOf(finding['status']) != 'closed') finding,
        ],
        roundFindings,
      );
      current = current.copyWith(findings: merged);
      final bool openHigh = merged.any(
        (Map<String, Object?> finding) =>
            textOf(finding['severity']) == 'high' &&
            textOf(finding['status']) != 'closed',
      );
      // 至少一轮批判（R1 起草 → R2 批判 → R3 修正），之后无 high 即收敛。
      if (roundValidation.ok && !openHigh && round > 1) break;
      if (round == 3) break;
      final List<Map<String, Object?>> criticFindings = parseFindingsJson(
        await _callLlm(
          'production.plan.critic',
          planCriticSystemPrompt(),
          planCriticUserPrompt(current),
          scope,
          modelId,
        ),
        round: round,
      );
      carried = _mergeFindings(carried, criticFindings);
      final List<Map<String, Object?>> forFix = <Map<String, Object?>>[
        for (final Map<String, Object?> finding in _mergeFindings(
          carried,
          roundFindings,
        ))
          if (textOf(finding['status']) != 'closed') finding,
      ];
      final PlanDocument patched = parsePlanDocument(
        await _callLlm(
          'production.plan.fix',
          planFixSystemPrompt(),
          planFixUserPrompt(current, forFix),
          scope,
          modelId,
        ),
        rounds: round + 1,
      );
      final List<Map<String, Object?>> preservation = _preservationFindings(
        current,
        patched,
        round + 1,
      );
      carried = _mergeFindings(<Map<String, Object?>>[
        ...carried,
        ...preservation,
      ], patched.findings);
      current = patched.copyWith(rounds: round + 1);
    }
    final PlanDocValidation validation = validatePlanDocument(
      current,
      existingIds: existingIds,
      maxParallel: maxParallel,
    );
    if (!validation.ok) {
      throw ProductionFailure(
        validation.message,
        code: validation.code,
        missing: validation.missing,
      );
    }
    final List<Map<String, Object?>> openHigh = <Map<String, Object?>>[
      for (final Map<String, Object?> finding in validation.doc.findings)
        if (textOf(finding['severity']) == 'high' &&
            textOf(finding['status']) != 'closed')
          finding,
    ];
    if (openHigh.isNotEmpty) {
      throw ProductionFailure(
        '计划仍有未解决 high findings：'
        '${openHigh.map((Map<String, Object?> item) => textOf(item['id'])).join('、')}'
        '（最多 3 轮；需修正或给 accept_high_finding DEC）',
        code: 'plan_critic_open_high',
      );
    }
    _validatePlanIds(existingIds, validation.doc.tasks);
    return (doc: validation.doc, validation: validation);
  }

  ({PlanDocument doc, PlanDocValidation validation}) _validatedPlan(
    PlanDocument doc, {
    required Set<String> existingIds,
    required int maxParallel,
  }) {
    final PlanDocValidation validation = validatePlanDocument(
      doc,
      existingIds: existingIds,
      maxParallel: maxParallel,
    );
    if (!validation.ok) {
      throw ProductionFailure(
        validation.message,
        code: validation.code,
        missing: validation.missing,
      );
    }
    return (doc: validation.doc, validation: validation);
  }

  /// 计划校验：任务 id 不与已有任务撞车。
  ///
  /// 跨计划依赖交给 [validateAndFixPlan]（允许指向已存在任务），这里不再重复判。
  void _validatePlanIds(
    Set<String> existingIds,
    List<Map<String, Object?>> tasks,
  ) {
    for (final Map<String, Object?> task in tasks) {
      final String id = textOf(task['id']);
      if (id.isNotEmpty && existingIds.contains(id)) {
        throw ProductionFailure('计划任务 id 与已有任务冲突：$id', code: 'plan_incomplete');
      }
    }
  }

  /// 修正补丁的保留性检查：requirements id / design 已填键 / 原任务 id 不许消失。
  List<Map<String, Object?>> _preservationFindings(
    PlanDocument before,
    PlanDocument after,
    int round,
  ) {
    final List<String> lost = <String>[];
    final Set<String> beforeRequirements = <String>{
      for (final Map<String, Object?> item in before.requirements)
        if (textOf(item['id']).isNotEmpty) textOf(item['id']),
    };
    final Set<String> afterRequirements = <String>{
      for (final Map<String, Object?> item in after.requirements)
        if (textOf(item['id']).isNotEmpty) textOf(item['id']),
    };
    for (final String id in beforeRequirements.difference(afterRequirements)) {
      lost.add('需求 $id');
    }
    for (final MapEntry<String, Object?> entry in before.design.entries) {
      if (!_hasDesignValue(entry.value)) continue;
      if (!_hasDesignValue(after.design[entry.key])) {
        lost.add('design.${entry.key}');
      }
    }
    final Set<String> beforeTasks = <String>{
      for (final Map<String, Object?> item in before.tasks)
        if (textOf(item['id']).isNotEmpty) textOf(item['id']),
    };
    final Set<String> afterTasks = <String>{
      for (final Map<String, Object?> item in after.tasks)
        if (textOf(item['id']).isNotEmpty) textOf(item['id']),
    };
    for (final String id in beforeTasks.difference(afterTasks)) {
      lost.add('任务 $id');
    }
    if (lost.isEmpty) return const <Map<String, Object?>>[];
    return <Map<String, Object?>>[
      <String, Object?>{
        'id': 'F-$round-patch-1',
        'severity': 'high',
        'status': 'open',
        'task_id': '',
        'message': '修正补丁删除了已确认内容：${lost.join('、')}',
        'round': round,
        'code': 'plan_patch_rewrote',
        'source': 'patch',
      },
    ];
  }

  bool _hasDesignValue(Object? value) {
    if (value is List) return value.isNotEmpty;
    if (value is Map) return value.isNotEmpty;
    return textOf(value).isNotEmpty;
  }

  List<Map<String, Object?>> _mergeFindings(
    List<Map<String, Object?>> base,
    List<Map<String, Object?>> incoming,
  ) {
    final Map<String, Map<String, Object?>> byId =
        <String, Map<String, Object?>>{};
    for (final Map<String, Object?> finding in <Map<String, Object?>>[
      ...base,
      ...incoming,
    ]) {
      final String id = textOf(finding['id']);
      if (id.isEmpty) continue;
      byId[id] = <String, Object?>{...?byId[id], ...finding};
    }
    return byId.values.toList();
  }

  /// 校验结果 → `validation.json`（batches/dag/size 由拆分器只读重算）。
  Map<String, Object?> _validationJson(
    PlanDocValidation validation,
    Set<String> existingIds,
    int maxParallel,
  ) {
    final PlanValidation base = validateAndFixPlan(
      tasks: validation.doc.tasks,
      existingIds: existingIds,
      maxParallel: maxParallel,
      fix: false,
    );
    return <String, Object?>{
      'issues': <Map<String, Object?>>[
        for (final PlanIssue issue in validation.issues) issue.toJson(),
      ],
      'batches': <Map<String, Object?>>[
        for (final PlanBatch batch in base.batches) batch.toJson(),
      ],
      'dag': base.dag,
      'size': base.size,
    };
  }

  /// 计划文档的 in/out/not_doing（未知键原样保留在 [PlanDocument.extra]）。
  ScopePlan _scopePlanOf(PlanDocument doc) => ScopePlan(
    inScope: stringsOf(doc.extra['in']),
    outOfScope: stringsOf(doc.extra['out']),
    notDoing: stringsOf(doc.extra['not_doing']),
    tasks: const <PlanTaskSpec>[],
  );

  /// 把拆分器修正后的任务表还原成 `ScopePlan`（只用于文档渲染与摘要）。
  ScopePlan _fixedPlan(ScopePlan plan, List<Map<String, Object?>> tasks) =>
      ScopePlan(
        inScope: plan.inScope,
        outOfScope: plan.outOfScope,
        notDoing: plan.notDoing,
        tasks: <PlanTaskSpec>[
          for (final Map<String, Object?> task in tasks)
            PlanTaskSpec(
              id: textOf(task['id']),
              title: textOf(task['title']),
              kind: textOf(task['kind']).isEmpty
                  ? 'conventional'
                  : textOf(task['kind']),
              dependsOn: stringsOf(task['depends_on']),
              readScope: stringsOf(task['read_scope']),
              writeScope: stringsOf(task['write_scope']),
              acceptance: stringsOf(task['acceptance']),
              estimatedFiles: intOf(task['estimated_files'], 1),
              taskType: taskTypeOf(task['task_type']),
              gate: plainMap(task['gate']),
              estimatedLines: intOf(task['estimated_lines'], 0),
              estimatedPackages: intOf(task['estimated_packages'], 0),
              risk: textOf(task['risk']),
              contract: plainValue(task['contract']),
              splitReason: textOf(task['split_reason']),
              rationale: textOf(task['rationale']),
            ),
        ],
      );

  // ── 状态 ──────────────────────────────────────────────────────────

  Map<String, Object?> _status(
    ProductionStore store,
    Map<String, Object?> arguments,
  ) {
    final String lineId = _arg(arguments, 'line_id');
    final LineRecord line = store.getLine(lineId);
    final List<Map<String, Object?>> tasks = <Map<String, Object?>>[];
    int totalOpen = 0;
    for (final TaskRecord task in store.listTasks(lineId)) {
      final int open = openQuestionsOf(
        replayQuestions(store.readInbox(lineId), taskId: task.id),
      ).length;
      totalOpen += open;
      tasks.add(<String, Object?>{
        'id': task.id,
        'title': task.title,
        'status': task.status.wire,
        'open_questions': open,
      });
    }
    return <String, Object?>{
      'line': line.toJson(),
      'window': _windowOf(store, lineId),
      'tasks': tasks,
      'open_questions': totalOpen,
      'limit': clampQuestionLimit(
        plainMap(line.data['limits'])['max_questions_per_round'],
      ),
    };
  }

  // ── 计划校验（只读）──────────────────────────────────────────────

  /// `production.plan.validate`：只校验 / 修正内存计划，**不写盘**。
  ///
  /// body 带 `requirements` / `design` ⇒ 严格走 [validatePlanDocument]（PG-00~10）；
  /// 否则走旧的任务拆分器（PG-03~07），保持旧调用方兼容。
  Map<String, Object?> _planValidate(
    ProductionStore store,
    Map<String, Object?> arguments,
  ) {
    final String lineId = _arg(arguments, 'line_id');
    store.getLine(lineId);
    final Set<String> existingIds = <String>{
      for (final TaskRecord task in store.listTasks(lineId)) task.id,
    };
    final Map<String, Object?> input = _planInputOf(arguments);
    final bool structured =
        input.containsKey('requirements') || input.containsKey('design');
    if (!structured) {
      final List<Map<String, Object?>> tasks = _planTasks(arguments['plan']);
      final PlanValidation validation = validateAndFixPlan(
        tasks: tasks,
        existingIds: existingIds,
        maxParallel: intOf(arguments['max_parallel'], 1),
        fix: arguments['fix'] != false,
      );
      return <String, Object?>{
        'ok': validation.ok,
        'code': validation.code,
        'message': validation.message,
        'missing': validation.missing,
        'issues': <Map<String, Object?>>[
          for (final PlanIssue issue in validation.issues) issue.toJson(),
        ],
        'tasks': validation.tasks,
        'batches': <Map<String, Object?>>[
          for (final PlanBatch batch in validation.batches) batch.toJson(),
        ],
        'dag': validation.dag,
        'size': validation.size,
        'structured': false,
        'findings': const <Object?>[],
        'traceability': const <Object?>[],
      };
    }
    final int maxParallel = intOf(arguments['max_parallel'], 1);
    final PlanDocument doc = parsePlanDocument(input);
    final PlanDocValidation validation = validatePlanDocument(
      doc,
      existingIds: existingIds,
      maxParallel: maxParallel,
      fixTasks: arguments['fix'] != false,
    );
    final PlanValidation base = validateAndFixPlan(
      tasks: validation.doc.tasks,
      existingIds: existingIds,
      maxParallel: maxParallel,
      fix: false,
    );
    return <String, Object?>{
      'ok': validation.ok,
      'code': validation.code,
      'message': validation.message,
      'missing': validation.missing,
      'issues': <Map<String, Object?>>[
        for (final PlanIssue issue in validation.issues) issue.toJson(),
      ],
      'tasks': validation.doc.tasks,
      'batches': <Map<String, Object?>>[
        for (final PlanBatch batch in base.batches) batch.toJson(),
      ],
      'dag': base.dag,
      'size': base.size,
      'structured': true,
      'findings': validation.doc.findings,
      'traceability': validation.doc.traceability,
    };
  }

  /// `production.plan.get`：只读最新计划版本（`plans/plan-vN/plan.json`）。
  Map<String, Object?> _planGet(
    ProductionStore store,
    Map<String, Object?> arguments,
  ) {
    final String lineId = _arg(arguments, 'line_id');
    store.getLine(lineId);
    final List<Map<String, Object?>> versions = store.listPlanVersions(lineId);
    if (versions.isEmpty) {
      return <String, Object?>{'version': '', 'plan': <String, Object?>{}};
    }
    final int version = intOf(versions.last['version'], 0);
    return <String, Object?>{
      'version': 'plan-v$version',
      'plan': store.readPlanVersion(lineId, version),
      'findings': store.readPlanFindings(lineId, version),
    };
  }

  /// 计划校验入参：`plan` 对象 / 任务数组 + body 上的 7 块字段。
  Map<String, Object?> _planInputOf(Map<String, Object?> arguments) {
    final Map<String, Object?> input = arguments['plan'] is Map
        ? plainMap(arguments['plan'])
        : <String, Object?>{};
    for (final String key in const <String>[
      'requirements',
      'design',
      'invariants',
      'gates',
      'traceability',
      'risks',
      'unknowns',
      'change_control',
      'decisions',
      'findings',
      'rounds',
    ]) {
      if (arguments.containsKey(key) && !input.containsKey(key)) {
        input[key] = arguments[key];
      }
    }
    if (!input.containsKey('tasks')) {
      final Object? raw = arguments['plan'];
      if (raw is List) {
        input['tasks'] = raw;
      } else if (arguments['tasks'] is List) {
        input['tasks'] = arguments['tasks'];
      }
    }
    return input;
  }

  /// 命令入参里的计划：允许任务数组，或含 `tasks` 的计划对象。
  List<Map<String, Object?>> _planTasks(Object? raw) {
    Object? value = raw;
    if (raw is Map) value = plainMap(raw)['tasks'];
    if (value is! List) {
      throw ProductionFailure(
        'production.plan.validate 需要 plan（任务数组或含 tasks 的计划）',
        code: 'invalid_arguments',
      );
    }
    return <Map<String, Object?>>[
      for (final Object? item in value)
        if (item is Map) plainMap(item),
    ];
  }

  // ── 内部工具 ──────────────────────────────────────────────────────

  List<Map<String, Object?>> _answersOf(Map<String, Object?> arguments) {
    final Object? raw = arguments['answers'];
    if (raw is List && raw.isNotEmpty) {
      final List<Map<String, Object?>> out = <Map<String, Object?>>[];
      for (final Object? item in raw) {
        if (item is Map) out.add(plainMap(item));
      }
      return out;
    }
    final String qid = textOf(arguments['qid']);
    if (qid.isEmpty) {
      throw ProductionFailure(
        'production.prepare.answer 需要 answers 或 qid/value',
        code: 'invalid_arguments',
      );
    }
    return <Map<String, Object?>>[
      <String, Object?>{'qid': qid, 'value': textOf(arguments['value'])},
    ];
  }

  Future<int> _limitFor(
    ProductionStore store,
    LineRecord line,
    Map<String, Object?> scope,
  ) async {
    int? fromSettings;
    try {
      fromSettings = await limitReader?.call(scope);
    } catch (_) {
      // 设置服务不可用 ⇒ 回退 line.yaml，不阻断准备阶段。
      fromSettings = null;
    }
    final Object? fromLine = plainMap(
      line.data['limits'],
    )['max_questions_per_round'];
    return clampQuestionLimit(fromSettings ?? fromLine);
  }

  /// 读一次 agent 记忆：未接线 / agent 为空 / 通道失败都按不可用处理，绝不抛。
  Future<MemoryView> _readMemory(
    String agentId,
    String purpose,
    Map<String, Object?> scope,
  ) async {
    final MemoryPort? port = memory;
    if (port == null || agentId.trim().isEmpty) {
      return const MemoryView(unavailable: true, code: 'memory_unavailable');
    }
    return port.read(
      agentId: agentId,
      purpose: purpose,
      budgetChars: 4000,
      scope: scope,
    );
  }

  /// 可落盘的记忆元数据（**不含正文**）。
  Map<String, Object?> _memoryMeta(MemoryView view) => <String, Object?>{
    'memory_hash': view.hash,
    'memory_sources': view.sources,
    'memory_unavailable': view.unavailable,
  };

  Map<String, Object?> _windowOf(ProductionStore store, String lineId) =>
      plainMap(store.readPrepare(lineId)['window']);

  /// 打开（或复用）当前窗口；已关闭 / 不存在 ⇒ 轮次 +1 开新窗口。
  Map<String, Object?> _ensureWindow(ProductionStore store, String lineId) {
    final Map<String, Object?> prepare = store.readPrepare(lineId);
    final Map<String, Object?> window = plainMap(prepare['window']);
    if (textOf(window['id']).isNotEmpty &&
        textOf(window['closed_at']).isEmpty) {
      return window;
    }
    final Map<String, Object?> next = <String, Object?>{
      'id': 'win_${_clock().millisecondsSinceEpoch}',
      'round': intOf(window['round'], 0) + 1,
      'opened_at': _now,
      'closed_at': '',
    };
    // 历史窗口留档（`decisions.md` 要按窗口分组；只留最近 50 个，避免无限增长）。
    final List<Object?> history = prepare['windows'] is List
        ? List<Object?>.of(prepare['windows'] as List<dynamic>)
        : <Object?>[];
    history.add(next);
    store.writePrepare(lineId, <String, Object?>{
      ...prepare,
      'version': 1,
      'window': next,
      'windows': history.length > 50
          ? history.sublist(history.length - 50)
          : history,
    });
    return next;
  }

  /// `task.yaml.artifacts` 用的**仓库相对**路径前缀（`docs/production_lines/<line>`）。
  String _assetDir(ProductionStore store, String lineId) {
    final LineRecord line = store.getLine(lineId);
    final Map<String, Object?> docs = plainMap(line.data['docs']);
    final String base = textOf(docs['asset_dir']).isEmpty
        ? 'docs/production_lines'
        : textOf(docs['asset_dir']);
    return '$base/$lineId';
  }

  void _writeDecisions(ProductionStore store, String lineId) {
    final LineRecord line = store.getLine(lineId);
    final List<Map<String, Object?>> inbox = store.readInbox(lineId);
    final List<QuestionState> questions = replayQuestions(inbox);
    final Map<String, Object?> prepare = store.readPrepare(lineId);
    final List<Map<String, Object?>> windows = <Map<String, Object?>>[
      for (final Object? item
          in (prepare['windows'] as List<dynamic>? ?? const <dynamic>[]))
        if (item is Map) plainMap(item),
    ];
    final Map<String, Object?> window = plainMap(prepare['window']);
    if (window.isNotEmpty &&
        !windows.any(
          (Map<String, Object?> w) => textOf(w['id']) == textOf(window['id']),
        )) {
      windows.add(window);
    }
    store.writeAsset(
      lineId,
      'decisions.md',
      renderDecisionsMd(
        lineName: line.name,
        questions: questions,
        windows: windows,
        answers: <Map<String, Object?>>[
          for (final Map<String, Object?> entry in inbox)
            if (textOf(entry['type']) == 'answer') entry,
        ],
      ),
    );
  }

  /// 检索通道缺失 ⇒ 直接 fail-closed（不把「没查到」当「没问题」）。
  void _requireDocQuery() {
    if (docQuery == null) {
      throw ProductionFailure(
        '准备阶段需要 tree.docnorm 检索通道（docnorm.query），当前未接线：拒绝凭空侦查',
        code: 'docnorm_unavailable',
      );
    }
  }

  /// 任务附件元数据（PC-3A 落盘前缺省为空列表）；正文/图片本体不进入检索。
  List<Map<String, Object?>> _attachmentsOf(TaskRecord task) {
    final Object? raw = task.data['attachments'];
    if (raw is! List) return const <Map<String, Object?>>[];
    return <Map<String, Object?>>[
      for (final Object? item in raw)
        if (item is Map) plainMap(item),
    ];
  }

  /// 可送视觉模型的图片：只取 `vision_model` 归属的 image 附件。
  ///
  /// 上限：最多 4 张、单张 ≤ 4 MiB、累计原始字节 ≤ 8 MiB；读失败 / 超限
  /// 跳过该张，不阻断侦查。返回项固定 `{'name', 'mime', 'base64'}`。
  List<Map<String, Object?>> _digestImages(
    ProductionStore store,
    String lineId,
    List<Map<String, Object?>> attachments,
  ) {
    final List<Map<String, Object?>> images = <Map<String, Object?>>[];
    int totalBytes = 0;
    for (final Map<String, Object?> item in attachments) {
      if (images.length >= 4) break;
      if (textOf(item['kind']) != 'image') continue;
      if (textOf(item['summary_by']) != 'vision_model') continue;
      final String relative = textOf(item['path']);
      if (relative.isEmpty) continue;
      if (intOf(item['size'], 0) > 4 * 1024 * 1024) continue;
      final List<int> bytes;
      try {
        bytes = store.readWorkspaceBytes(
          lineId,
          relative,
          maxBytes: 4 * 1024 * 1024,
        );
      } on ProductionFailure {
        continue;
      }
      if (bytes.isEmpty) continue;
      if (totalBytes + bytes.length > 8 * 1024 * 1024) break;
      totalBytes += bytes.length;
      final String name = textOf(item['name']);
      final String mime = textOf(item['type']);
      images.add(<String, Object?>{
        'name': name.isNotEmpty ? name : relative.split('/').last,
        'mime': mime.isNotEmpty ? mime : 'application/octet-stream',
        'base64': base64Encode(bytes),
      });
    }
    return images;
  }

  List<Map<String, Object?>> _rowsOf(Map<String, Object?> payload) {
    final Object? raw = payload['results'];
    if (raw is! List) return const <Map<String, Object?>>[];
    return <Map<String, Object?>>[
      for (final Object? item in raw)
        if (item is Map) plainMap(item),
    ];
  }

  /// 双查询并行：原文（A）+ 关键词（B），各自 [queryTimeout]；
  /// 总 [retrievalDeadline] 到点用已完成部分继续（partial），**不补第三轮**。
  Future<_Retrieval> _retrieveDocs(
    String repo,
    String queryA,
    String queryB,
    Map<String, Object?> scope,
  ) async {
    final DocQuery query = docQuery!;
    final Stopwatch watch = Stopwatch()..start();
    final Map<String, List<Map<String, Object?>>> results =
        <String, List<Map<String, Object?>>>{
          'A': const <Map<String, Object?>>[],
          'B': const <Map<String, Object?>>[],
        };
    ProductionFailure? fatal;

    Future<void> run(String label, String text) async {
      if (text.trim().isEmpty) return;
      try {
        final Map<String, Object?> payload = await query(
          repo,
          text,
          scope,
        ).timeout(queryTimeout);
        results[label] = _rowsOf(payload);
      } on ProductionFailure catch (error) {
        if (error.code == 'docnorm_unavailable') fatal = error;
        results[label] = const <Map<String, Object?>>[];
      } catch (_) {
        results[label] = const <Map<String, Object?>>[];
      }
    }

    bool timedOut = false;
    try {
      await Future.wait(<Future<void>>[run('A', queryA), run('B', queryB)])
          .timeout(retrievalDeadline);
    } on TimeoutException {
      timedOut = true;
    }
    watch.stop();
    if (fatal != null) throw fatal!;

    final List<Map<String, Object?>> rowsA = List<Map<String, Object?>>.of(
      results['A']!,
    );
    final List<Map<String, Object?>> rowsB = List<Map<String, Object?>>.of(
      results['B']!,
    );
    final List<ReconEvidence> evidence = mergeRetrievalEvidence(
      primary: rowsA,
      secondary: rowsB,
    );
    // 两路都必须有贡献；一路为空/超时 ⇒ degraded，但不静默只用另一路。
    final bool degraded = rowsA.isEmpty || rowsB.isEmpty;
    return _Retrieval(
      evidence: evidence,
      retrieveMs: watch.elapsedMilliseconds,
      degraded: degraded ? 'single_query' : '',
      partial: timedOut,
      recallGap: evidence.isEmpty,
    );
  }

  Future<Map<String, Object?>> _callLlm(
    String point,
    String system,
    String prompt,
    Map<String, Object?> scope,
    String modelId,
  ) async {
    final PreparationLlm? runner = llm;
    if (runner == null) {
      throw ProductionFailure(
        '准备阶段需要 llm.call 通道，当前未接线',
        code: 'llm_unavailable',
      );
    }
    try {
      return await runner(point, system, prompt, scope, modelId);
    } on ProductionFailure {
      rethrow;
    } catch (error) {
      throw ProductionFailure('模型调用失败（$point）：$error', code: 'llm_failed');
    }
  }

  /// 视觉通道（多模态 messages）；未接线 ⇒ fail-closed，由调用方决定是否退回文本。
  Future<Map<String, Object?>> _callVisionLlm(
    String point,
    String system,
    String prompt,
    List<Map<String, Object?>> images,
    Map<String, Object?> scope,
    String modelId,
  ) async {
    final PreparationVisionLlm? runner = visionLlm;
    if (runner == null) {
      throw ProductionFailure('准备阶段需要视觉模型通道，当前未接线', code: 'llm_unavailable');
    }
    try {
      return await runner(point, system, prompt, images, scope, modelId);
    } on ProductionFailure {
      rethrow;
    } catch (error) {
      throw ProductionFailure('视觉模型调用失败（$point）：$error', code: 'llm_failed');
    }
  }

  /// 主控（orchestrator）的模型：准备阶段的侦查与拆解都由它出（D6）。
  String _orchestratorModel(LineRecord line) => textOf(
    plainMap(plainMap(line.data['roles'])['orchestrator'])['model_id'],
  );

  /// 主控可用的工具（写进侦查提示词，规划落点必须落在这些能力内）。
  List<String> _orchestratorTools(LineRecord line) {
    final List<String> configured = stringsOf(
      plainMap(plainMap(line.data['roles'])['orchestrator'])['tools'],
    );
    return configured.isEmpty
        ? (kRoleDefaultTools['orchestrator'] ?? const <String>[])
        : configured;
  }

  /// 触发一次事件 tick；落档结果已写盘，事件通道失败不反过来报错。
  Future<void> _notifyCycle(
    Map<String, Object?> arguments,
    Map<String, Object?> meta,
    Map<String, Object?> scope,
  ) async {
    final ProductionCycleTrigger? hook = onCycle;
    if (hook == null) return;
    final String lineId = textOf(arguments['line_id']);
    if (lineId.isEmpty) return;
    try {
      await hook(lineId, meta, scope);
    } catch (_) {
      // 下一次定时 tick 仍会兜底。
    }
  }

  String _arg(Map<String, Object?> arguments, String key) {
    final String value = textOf(arguments[key]);
    if (value.isEmpty) {
      throw ProductionFailure('缺少 $key', code: 'invalid_arguments');
    }
    return value;
  }
}

/// 一次双查询检索的结果（含降级/部分/召回缺口读数）。
class _Retrieval {
  const _Retrieval({
    required this.evidence,
    required this.retrieveMs,
    required this.degraded,
    required this.partial,
    required this.recallGap,
  });

  final List<ReconEvidence> evidence;
  final int retrieveMs;
  final String degraded;
  final bool partial;
  final bool recallGap;
}
