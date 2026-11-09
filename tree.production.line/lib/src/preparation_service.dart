/// 准备阶段（P3）的执行站命令门面：需求模板 → 侦查 → 追问 → 范围/拆任务 → 落档。
///
/// 与 P1 的 `ProductionService` 分开：这里要 await 外部通道（`docnorm.query` /
/// `llm.call` / `settings.get`），P1 的门面保持同步、测试零改动。
/// 两条门面共用同一套 [ProductionStore]（`task.yaml` 仍是唯一真值）。
library;

import 'dart:io';

import 'models.dart';
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
];

/// 模型调用（插件层接 `llm.call`；单测注入假实现）。
typedef PreparationLlm =
    Future<Map<String, Object?>> Function(
      String point,
      String system,
      String prompt,
      Map<String, Object?> scope,
    );

/// 文档检索（插件层接 `docnorm.query`；准备阶段**fail-closed**，不许凭空侦查）。
typedef DocQuery =
    Future<Map<String, Object?>> Function(
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
    this.docQuery,
    this.limitReader,
  }) : _environment = environment ?? Platform.environment,
       _clock = clock ?? DateTime.now;

  final Map<String, String> _environment;
  final DateTime Function() _clock;

  /// 模型调用；null = 未接线（准备阶段 fail-closed）。
  final PreparationLlm? llm;
  final DocQuery? docQuery;
  final QuestionLimitReader? limitReader;

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
      teamId: target.teamId,
      clock: _clock,
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
        return await _finalize(store, arguments, scope);
      case 'production.prepare.status':
        return _status(store, arguments);
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
      throw ProductionFailure(intake.blocking.join('；'), code: 'intake_incomplete');
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
    // 工作空间 + 文档检索：**fail-closed**（§10.1 缺 docnorm 不降级为凭空侦查）。
    final String workspace = store.workspaceDirOf(lineId);
    final String memory = _formatDocs(
      await _queryDocs(workspace, intake['goal']!, scope),
    );
    final Map<String, Object?> json = await _callLlm(
      'production.recon',
      reconSystemPrompt(maxQuestions: limit),
      reconUserPrompt(
        lineName: line.name,
        taskId: taskId,
        title: task.title,
        intake: intake,
        memory: memory,
      ),
      scope,
    );
    final ReconDraft draft = parseReconJson(json, maxQuestions: 10);
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
        'asked_at': _now,
        'round': intOf(window['round'], 1),
        'questions': questions.length,
        'open': openQuestionsOf(questions).length,
        'dropped': planned.dropped,
        'flags': draft.flags,
      },
    });
    return <String, Object?>{
      'task': task.toJson(),
      'recon': draft.toJson(),
      'questions': <Map<String, Object?>>[
        for (final QuestionState question in questions) question.toJson(),
      ],
      'open': openQuestionsOf(questions).length,
      'dropped': planned.dropped,
      'limit': limit,
      'window': window,
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
      for (final QuestionState question
          in replayQuestions(store.readInbox(lineId), taskId: taskId))
        question.qid: question,
    };
    for (final Map<String, Object?> answer in answers) {
      final String qid = textOf(answer['qid']);
      final String value = textOf(answer['value']);
      final QuestionState? question = byId[qid];
      if (question == null) {
        throw ProductionFailure('任务 $taskId 没有 ${qid.isEmpty ? '（空 qid）' : qid}', code: 'unknown_question');
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
      'questions': <String, Object?>{
        'total': questions.length,
        'open': open,
      },
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
      'reads': <String, Object?>{
        ...reads,
        taskId: budget.toJson(),
      },
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
    final ScopePlan plan = await _planFor(
      store,
      line,
      task,
      questions,
      arguments,
      scope,
    );
    _validatePlan(store, lineId, taskId, plan);
    // 落档顺序（§8.6）：先写文档，再建任务，最后重建索引。
    final String assetDir = _assetDir(store, lineId);
    store.writeAsset(
      lineId,
      'scope.md',
      renderScopeMd(taskId: taskId, plan: plan),
    );
    store.writeAsset(
      lineId,
      'plan.md',
      renderPlanMd(lineName: line.name, taskId: taskId, plan: plan),
    );
    final List<Map<String, Object?>> created = <Map<String, Object?>>[];
    for (final PlanTaskSpec spec in plan.tasks) {
      store.writeAsset(
        lineId,
        'tasks/${spec.id}/acceptance.md',
        renderAcceptanceMd(
          taskId: spec.id,
          title: spec.title,
          acceptance: spec.acceptance,
        ),
      );
      store.createTask(
        lineId,
        <String, Object?>{
          'id': spec.id,
          'title': spec.title,
          'kind': spec.kind,
          'status': TaskStatus.queued.wire,
          'priority': 50,
          'depends_on': spec.dependsOn,
          'read_scope': spec.readScope,
          'write_scope': spec.writeScope,
          'acceptance': spec.acceptance,
          'artifacts': <String, Object?>{
            'recon': '$assetDir/recon.md#$taskId',
            'acceptance': '$assetDir/tasks/${spec.id}/acceptance.md',
          },
        },
      );
      final TaskRecord saved = store.putTask(lineId, spec.id, <String, Object?>{
        'prepared_by': taskId,
        'estimated_files': spec.estimatedFiles,
      });
      created.add(saved.toJson());
    }
    store.transition(lineId, taskId, to: TaskStatus.scoped.wire);
    task = store.putTask(lineId, taskId, <String, Object?>{
      'scope': plan.toJson(),
      'artifacts': <String, Object?>{
        'recon': '$assetDir/recon.md',
        'scope': '$assetDir/scope.md',
        'plan': '$assetDir/plan.md',
        'decisions': '$assetDir/decisions.md',
      },
    });
    final int limit = await _limitFor(store, line, scope);
    final List<String> summary = distributionSummary(
      tasks: plan.tasks,
      openQuestions: open.length,
      questionLimit: limit,
    );
    return <String, Object?>{
      'task': task.toJson(),
      'scope': plan.toJson(),
      'created_tasks': created,
      'queue': store.next(lineId, limit: 0)['queue'],
      'summary': summary,
    };
  }

  Future<ScopePlan> _planFor(
    ProductionStore store,
    LineRecord line,
    TaskRecord task,
    List<QuestionState> questions,
    Map<String, Object?> arguments,
    Map<String, Object?> scope,
  ) async {
    final Object? planInput = arguments['plan'];
    if (planInput is List && planInput.isNotEmpty) {
      return parseScopeJson(<String, Object?>{
        'in': arguments['in'],
        'out': arguments['out'],
        'not_doing': arguments['not_doing'],
        'tasks': planInput,
      });
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
    final Map<String, Object?> json = await _callLlm(
      'production.scope',
      scopeSystemPrompt(),
      scopeUserPrompt(
        taskId: task.id,
        title: task.title,
        intake: intake,
        reconText: reconText,
        decisionsText: decisionsText,
      ),
      scope,
    );
    return parseScopeJson(json);
  }

  /// 计划校验：任务 id 不与已有任务撞车；依赖只能在本次清单里。
  void _validatePlan(
    ProductionStore store,
    String lineId,
    String prepTaskId,
    ScopePlan plan,
  ) {
    final Set<String> existing = <String>{
      prepTaskId,
      for (final TaskRecord task in store.listTasks(lineId)) task.id,
    };
    final Set<String> planned = <String>{
      for (final PlanTaskSpec task in plan.tasks) task.id,
    };
    for (final PlanTaskSpec task in plan.tasks) {
      for (final String dependency in task.dependsOn) {
        if (!planned.contains(dependency)) {
          throw ProductionFailure(
            '任务 ${task.id} 依赖 $dependency，但它不在本次计划里（跨批次依赖请手工补）',
            code: 'plan_incomplete',
          );
        }
      }
      if (existing.contains(task.id)) {
        throw ProductionFailure(
          '计划任务 id 与已有任务冲突：${task.id}',
          code: 'plan_incomplete',
        );
      }
    }
  }

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
    final Object? fromLine = plainMap(line.data['limits'])['max_questions_per_round'];
    return clampQuestionLimit(fromSettings ?? fromLine);
  }

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
      for (final Object? item in (prepare['windows'] as List<dynamic>? ??
          const <dynamic>[]))
        if (item is Map) plainMap(item),
    ];
    final Map<String, Object?> window = plainMap(prepare['window']);
    if (window.isNotEmpty &&
        !windows.any((Map<String, Object?> w) => textOf(w['id']) == textOf(window['id']))) {
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

  Future<Map<String, Object?>> _queryDocs(
    String repo,
    String question,
    Map<String, Object?> scope,
  ) async {
    final DocQuery? query = docQuery;
    if (query == null) {
      throw ProductionFailure(
        '准备阶段需要 tree.docnorm 检索通道（docnorm.query），当前未接线：拒绝凭空侦查',
        code: 'docnorm_unavailable',
      );
    }
    try {
      return await query(repo, question, scope);
    } catch (error) {
      throw ProductionFailure(
        '文档检索失败（docnorm.query）：$error',
        code: 'docnorm_unavailable',
      );
    }
  }

  String _formatDocs(Map<String, Object?> payload) {
    final List<Object?> results = payload['results'] is List
        ? payload['results'] as List<Object?>
        : const <Object?>[];
    final StringBuffer buffer = StringBuffer();
    for (final Object? item in results.take(8)) {
      if (item is! Map) continue;
      final Map<String, Object?> row = plainMap(item);
      buffer.writeln(
        '- [${textOf(row['doc'])}] ${textOf(row['heading'])}：'
        '${textOf(row['snippet'])}',
      );
    }
    final String mode = textOf(payload['mode']);
    if (mode.isNotEmpty) {
      buffer.writeln('（检索模式：$mode）');
    }
    return buffer.toString();
  }

  Future<Map<String, Object?>> _callLlm(
    String point,
    String system,
    String prompt,
    Map<String, Object?> scope,
  ) async {
    final PreparationLlm? runner = llm;
    if (runner == null) {
      throw ProductionFailure(
        '准备阶段需要 llm.call 通道，当前未接线',
        code: 'llm_unavailable',
      );
    }
    try {
      return await runner(point, system, prompt, scope);
    } on ProductionFailure {
      rethrow;
    } catch (error) {
      throw ProductionFailure('模型调用失败（$point）：$error', code: 'llm_failed');
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
