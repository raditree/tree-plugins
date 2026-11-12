/// 执行期主控的纯领域逻辑（D6-O §3 / §4 / §5）。
///
/// 口径（docs/pluginization/production-line-orchestrator-loop-plan.md）：
/// - 一次 tick 只做一个决策：`continue / retry / ask / stop`；
/// - 输入是**有界快照**（task.yaml / runs / inbox 的投影），不是对话历史；
/// - 模型输出严格 JSON，未知动作 / 缺理由 / 池外任务一律整条作废；
/// - 护栏优先级 `stop > ask > retry > continue`：越界只能降级为 stop / ask。
///
/// 这一层不读盘、不调模型：快照组装、动作解析、护栏与提示词都是纯函数，
/// 单测可以给同一快照断言同一类动作。
library;

import 'dart:convert';

import 'budget.dart';
import 'models.dart';
import 'preparation.dart' show QuestionState, openQuestionsOf, replayQuestions;
import 'queue.dart';

// ── 配置（§4.1）────────────────────────────────────────────────────

/// `line.yaml.orchestrator` 的强类型视图；缺键即默认值。
class OrchestratorConfig {
  const OrchestratorConfig({
    this.enabled = true,
    this.tickIntervalSeconds = 5,
    this.autoRetry = true,
    this.maxAsksPerTask = 3,
    this.stopOnBudget = true,
    this.maxTicksPerMinute = 12,
  });

  final bool enabled;

  /// 有在途任务时的定时 tick 间隔；0 = 只靠事件。
  final int tickIntervalSeconds;
  final bool autoRetry;
  final int maxAsksPerTask;
  final bool stopOnBudget;

  /// 防抖硬上限：超过就跳过本 tick（不调模型）。
  final int maxTicksPerMinute;

  factory OrchestratorConfig.of(LineRecord line) {
    final Map<String, Object?> raw = line.orchestrator;
    return OrchestratorConfig(
      enabled: _boolOf(raw['enabled'], true),
      tickIntervalSeconds: _intOf(raw['tick_interval_seconds'], 5, min: 0),
      autoRetry: _boolOf(raw['auto_retry'], true),
      maxAsksPerTask: _intOf(raw['max_asks_per_task'], 3, min: 0),
      stopOnBudget: _boolOf(raw['stop_on_budget'], true),
      maxTicksPerMinute: _intOf(raw['max_ticks_per_minute'], 12, min: 0),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    'tick_interval_seconds': tickIntervalSeconds,
    'auto_retry': autoRetry,
    'max_asks_per_task': maxAsksPerTask,
    'stop_on_budget': stopOnBudget,
    'max_ticks_per_minute': maxTicksPerMinute,
  };
}

bool _boolOf(Object? value, bool fallback) {
  if (value is bool) return value;
  final String text = textOf(value).toLowerCase();
  if (text.isEmpty) return fallback;
  if (text == 'true' || text == '1' || text == 'yes') return true;
  if (text == 'false' || text == '0' || text == 'no') return false;
  return fallback;
}

int _intOf(Object? value, int fallback, {required int min}) {
  if (value == null || textOf(value).isEmpty) return fallback;
  final int parsed = intOf(value, fallback);
  return parsed < min ? min : parsed;
}

// ── 快照（§5.1）────────────────────────────────────────────────────

/// 一次决策的输入快照（有界、可哈希）。
class OrchestratorSnapshot {
  const OrchestratorSnapshot({required this.json, required this.hash});

  /// 交给模型与台账的 JSON（键顺序稳定）。
  final Map<String, Object?> json;

  /// 快照哈希：只由事实字段算出（不含 `last_decision`）。
  final String hash;

  int get availableSlots => intOf(json['available_slots'], 0);
  bool get budgetExceeded => plainMap(json['budget'])['exceeded'] == true;
}

/// 组装快照（D6-O §5.1）：插件拼，不交给模型自己查。
///
/// [runs] 按 `store.listRuns` 的口径（新的在前）；[inbox] 是 `inbox.jsonl` 全量。
OrchestratorSnapshot buildOrchestratorSnapshot({
  required LineRecord line,
  required List<TaskRecord> tasks,
  required List<Map<String, Object?>> runs,
  required List<Map<String, Object?>> inbox,
  Map<String, Object?> lastDecision = const <String, Object?>{},
}) {
  final Map<String, Object?> limits = plainMap(line.data['limits']);
  final int maxParallel = intOf(limits['max_parallel_tasks'], 1);
  final DispatchPlan plan = planDispatch(tasks, maxParallel: maxParallel);
  final TaskBudget budget = budgetOf(limits);

  final List<TaskRecord> ordered = List<TaskRecord>.of(tasks)
    ..sort((TaskRecord a, TaskRecord b) => a.id.compareTo(b.id));

  int usedTokens = 0;
  final List<String> budgetReasons = <String>[];
  final List<Map<String, Object?>> taskRows = <Map<String, Object?>>[];
  for (final TaskRecord task in ordered) {
    final BudgetUsage usage = usageOf(task);
    usedTokens += usage.tokens;
    if (!task.status.isTerminal) {
      final BudgetState state = budgetStateOf(budget, usage);
      if (state.exceeded) {
        budgetReasons.addAll(state.reasons);
      }
    }
    taskRows.add(<String, Object?>{
      'id': task.id,
      'title': _clip(task.title, 120),
      'status': task.status.wire,
      'depends_on': task.dependsOn,
      'write_scope': task.effectiveWriteScope,
      'attempts': task.loopAttempts,
      'ask_count': task.askCount,
      'gate_attempts': intOf(task.data['gate_attempts'], 0),
      'blocked_reason': task.blockedReason,
      'stop_reason': task.stopReason,
      'pending_question': task.pendingQuestion,
      'budget_exceeded': task.data['budget_exceeded'] == true,
    });
  }

  final Map<String, Object?>? lastRun = _lastRunOf(runs);
  final QuestionState? pendingQuestion = _openExecuteQuestion(inbox);

  final Map<String, Object?> facts = <String, Object?>{
    'line': <String, Object?>{
      'id': line.id,
      'name': line.name,
      'status': line.status,
      'limits': limits,
    },
    'budget': <String, Object?>{
      'exceeded': budgetReasons.isNotEmpty,
      'used_tokens': usedTokens,
      'reasons': budgetReasons,
    },
    'tasks': taskRows,
    'last_run': lastRun,
    'pending_question': pendingQuestion == null
        ? null
        : <String, Object?>{
            'task_id': pendingQuestion.taskId,
            'qid': pendingQuestion.qid,
            'text': _clip(pendingQuestion.text, 500),
          },
    'available_slots': plan.slotsFree,
    'slots_used': plan.slotsUsed,
    'max_parallel_tasks': plan.maxParallel,
    'dispatchable': <String>[
      for (final TaskRecord task in plan.batch) task.id,
    ],
  };
  final Map<String, Object?> json = <String, Object?>{
    ...facts,
    if (lastDecision.isNotEmpty) 'last_decision': lastDecision,
  };
  return OrchestratorSnapshot(json: json, hash: snapshotHashOf(facts));
}

Map<String, Object?>? _lastRunOf(List<Map<String, Object?>> runs) {
  for (final Map<String, Object?> run in runs) {
    final String taskId = textOf(run['task_id']);
    if (taskId.isEmpty) continue;
    return <String, Object?>{
      'task_id': taskId,
      'role': textOf(run['role']),
      'status': textOf(run['status']),
      'error': _clip(textOf(run['error']), 300),
      'started_at': textOf(run['started_at']),
    };
  }
  return null;
}

/// 运行期未答问题（`stage=execute`）；准备阶段的问题不参与执行决策。
QuestionState? _openExecuteQuestion(List<Map<String, Object?>> inbox) {
  final List<Map<String, Object?>> execute = <Map<String, Object?>>[
    for (final Map<String, Object?> entry in inbox)
      if (textOf(entry['stage']) == 'execute') entry,
  ];
  final List<QuestionState> open = openQuestionsOf(
    replayQuestions(execute, stage: 'execute'),
  );
  return open.isEmpty ? null : open.first;
}

/// 运行期问题（只看 `stage=execute` 的台账事件）。
List<QuestionState> executeQuestionsOf(
  List<Map<String, Object?>> inbox, {
  String taskId = '',
}) {
  final List<Map<String, Object?>> execute = <Map<String, Object?>>[
    for (final Map<String, Object?> entry in inbox)
      if (textOf(entry['stage']) == 'execute' &&
          (taskId.isEmpty || textOf(entry['task_id']) == taskId))
        entry,
  ];
  return replayQuestions(execute, taskId: taskId, stage: 'execute');
}

/// 快照哈希：递归按键排序后 FNV-1a 32 位（稳定、无依赖）。
String snapshotHashOf(Map<String, Object?> facts) =>
    _hashOf(_canonicalJson(facts));

String _canonicalJson(Object? value) {
  if (value is Map) {
    final List<String> keys = <String>[
      for (final Object? key in value.keys) textOf(key),
    ]..sort();
    return '{${<String>[
      for (final String key in keys) '${json.encode(key)}:${_canonicalJson(value[key])}',
    ].join(',')}}';
  }
  if (value is List) {
    return '[${<String>[for (final Object? item in value) _canonicalJson(item)].join(',')}]';
  }
  return json.encode(value);
}

String _hashOf(String text) {
  int hash = 0x811c9dc5;
  for (final int byte in utf8.encode(text)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

// ── 决策（§5.2）────────────────────────────────────────────────────

const List<String> kOrchestratorActions = <String>[
  'continue',
  'retry',
  'ask',
  'stop',
];

/// 模型给出的一个问题（`action=ask` 时必填 text）。
class OrchestratorQuestion {
  const OrchestratorQuestion({
    this.text = '',
    this.options = const <String>[],
    this.defaultValue = '',
  });

  final String text;
  final List<String> options;
  final String defaultValue;

  Map<String, Object?> toJson() => <String, Object?>{
    'text': text,
    'options': options,
    'default': defaultValue,
  };
}

/// 一次主控决策（含护栏后的最终动作）。
class OrchestratorDecision {
  const OrchestratorDecision({
    required this.action,
    required this.reason,
    this.taskIds = const <String>[],
    this.stage = 'auto',
    this.question = const OrchestratorQuestion(),
    this.stopScope = 'task',
    this.applied = true,
    this.guard = '',
  });

  final String action;
  final String reason;
  final List<String> taskIds;
  final String stage;
  final OrchestratorQuestion question;

  /// `task`（停单个任务）或 `line`（整线暂停）。
  final String stopScope;

  /// 护栏是否允许真正落盘；false 时只记台账、不改状态。
  final bool applied;

  /// 被护栏降级 / 拒绝的原因（空 = 未降级）。
  final String guard;

  OrchestratorDecision copyWith({
    String? action,
    String? reason,
    List<String>? taskIds,
    String? stage,
    OrchestratorQuestion? question,
    String? stopScope,
    bool? applied,
    String? guard,
  }) => OrchestratorDecision(
    action: action ?? this.action,
    reason: reason ?? this.reason,
    taskIds: taskIds ?? this.taskIds,
    stage: stage ?? this.stage,
    question: question ?? this.question,
    stopScope: stopScope ?? this.stopScope,
    applied: applied ?? this.applied,
    guard: guard ?? this.guard,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'action': action,
    'reason': reason,
    'task_ids': taskIds,
    'stage': stage,
    'question': question.toJson(),
    'stop_scope': stopScope,
    'applied': applied,
    if (guard.isNotEmpty) 'guard': guard,
  };
}

/// 严格解析模型回包（D6-O §5.2）。
///
/// 任何不合契约的输入都抛 [ProductionFailure]（code=`orchestrator_bad_action` /
/// `orchestrator_bad_reason` / `orchestrator_unknown_task` / `orchestrator_bad_question`），
/// 由调用方走「整条作废 + 连续失败计数」的失败路径。
OrchestratorDecision parseOrchestratorDecision(
  Object? raw, {
  required Set<String> taskIds,
}) {
  if (raw is! Map) {
    throw ProductionFailure(
      '主控回包不是 JSON 对象：${_clip('$raw', 200)}',
      code: 'orchestrator_bad_action',
    );
  }
  final Map<String, Object?> json = plainMap(raw);
  final String action = textOf(json['action']);
  if (!kOrchestratorActions.contains(action)) {
    throw ProductionFailure(
      '主控动作非法「${action.isEmpty ? '空' : action}」；允许：'
      '${kOrchestratorActions.join(' / ')}',
      code: 'orchestrator_bad_action',
    );
  }
  final String reason = textOf(json['reason']);
  if (reason.isEmpty) {
    throw ProductionFailure(
      '主控决策缺 reason（必须一句话说明为什么）',
      code: 'orchestrator_bad_reason',
    );
  }
  final List<String> targets = stringsOf(json['task_ids']);
  final List<String> unknown = <String>[
    for (final String id in targets)
      if (!taskIds.contains(id)) id,
  ];
  if (unknown.isNotEmpty) {
    throw ProductionFailure(
      '主控给的任务不在任务池内：${unknown.join('、')}',
      code: 'orchestrator_unknown_task',
    );
  }
  final String stage = textOf(json['stage']).isEmpty
      ? 'auto'
      : textOf(json['stage']);
  if (!const <String>{'auto', 'pack', 'run'}.contains(stage)) {
    throw ProductionFailure(
      '主控 stage 只能是 auto / pack / run：$stage',
      code: 'orchestrator_bad_action',
    );
  }
  final String stopScope = textOf(json['stop_scope']).isEmpty
      ? 'task'
      : textOf(json['stop_scope']);
  if (!const <String>{'task', 'line'}.contains(stopScope)) {
    throw ProductionFailure(
      '主控 stop_scope 只能是 task / line：$stopScope',
      code: 'orchestrator_bad_action',
    );
  }
  final Map<String, Object?> questionJson = plainMap(json['question']);
  final OrchestratorQuestion question = OrchestratorQuestion(
    text: textOf(questionJson['text']),
    options: stringsOf(questionJson['options']),
    defaultValue: textOf(questionJson['default']),
  );
  if (action == 'ask' && question.text.isEmpty) {
    throw ProductionFailure(
      '主控要提问但 question.text 为空',
      code: 'orchestrator_bad_question',
    );
  }
  if (action != 'stop' && action != 'continue' && targets.isEmpty) {
    throw ProductionFailure(
      '主控动作 $action 需要至少一个 task_ids',
      code: 'orchestrator_bad_action',
    );
  }
  if (action == 'stop' && stopScope == 'task' && targets.isEmpty) {
    throw ProductionFailure(
      '主控要停任务但 task_ids 为空（整线停止请用 stop_scope=line）',
      code: 'orchestrator_bad_action',
    );
  }
  return OrchestratorDecision(
    action: action,
    reason: reason,
    taskIds: targets,
    stage: stage,
    question: question,
    stopScope: stopScope,
  );
}

// ── 护栏（§3.3）───────────────────────────────────────────────────

/// 把模型动作收进硬护栏；越界时降级或整条不生效。
///
/// 返回的 [OrchestratorDecision.applied] = false 时**不得改任何状态**，只落台账。
OrchestratorDecision guardOrchestratorDecision(
  OrchestratorDecision decision, {
  required OrchestratorConfig config,
  required LineRecord line,
  required List<TaskRecord> tasks,
  required bool budgetExceeded,
}) {
  if (line.status == 'paused') {
    return decision.copyWith(applied: false, guard: 'line_paused');
  }
  final Map<String, TaskRecord> byId = <String, TaskRecord>{
    for (final TaskRecord task in tasks) task.id: task,
  };
  final List<TaskRecord> targets = <TaskRecord>[
    for (final String id in decision.taskIds)
      if (byId[id] != null) byId[id]!,
  ];

  // 预算到点：continue / retry 一律降级为 stop（§3.3-2）。
  if (budgetExceeded &&
      (decision.action == 'continue' || decision.action == 'retry')) {
    if (!config.stopOnBudget) {
      return decision.copyWith(applied: false, guard: 'budget_exceeded');
    }
    final List<TaskRecord> stopTargets = targets.isEmpty
        ? <TaskRecord>[
            for (final TaskRecord task in tasks)
              if (!task.status.isTerminal) task,
          ]
        : targets;
    return decision.copyWith(
      action: 'stop',
      reason: '预算到点：停止继续/重试（${decision.reason}）',
      taskIds: <String>[for (final TaskRecord task in stopTargets) task.id],
      stopScope: 'task',
      guard: 'budget_exceeded',
    );
  }

  switch (decision.action) {
    case 'continue':
      return _guardContinue(decision, tasks: tasks, line: line);
    case 'retry':
      return _guardRetry(decision, targets: targets, line: line, config: config);
    case 'ask':
      return _guardAsk(decision, targets: targets, config: config);
    case 'stop':
      if (decision.stopScope == 'line') return decision;
      final List<TaskRecord> stoppable = <TaskRecord>[
        for (final TaskRecord task in targets)
          if (!task.status.isTerminal) task,
      ];
      if (stoppable.isEmpty) {
        return decision.copyWith(applied: false, guard: 'no_target');
      }
      return decision.copyWith(
        taskIds: <String>[for (final TaskRecord task in stoppable) task.id],
      );
    default:
      return decision.copyWith(applied: false, guard: 'unknown_action');
  }
}

OrchestratorDecision _guardContinue(
  OrchestratorDecision decision, {
  required List<TaskRecord> tasks,
  required LineRecord line,
}) {
  final Map<String, Object?> limits = plainMap(line.data['limits']);
  final DispatchPlan plan = planDispatch(
    tasks,
    maxParallel: intOf(limits['max_parallel_tasks'], 1),
  );
  final Set<String> allowed = <String>{
    for (final TaskRecord task in plan.batch) task.id,
    // packed 已在途（占着槽位），继续执行不额外占槽位（§3.2）。
    for (final TaskRecord task in tasks)
      if (task.status == TaskStatus.packed) task.id,
  };
  final List<String> ids = <String>[
    for (final String id in decision.taskIds)
      if (allowed.contains(id)) id,
  ];
  if (ids.isEmpty) {
    return decision.copyWith(
      applied: false,
      guard: _skipReasonOf(decision.taskIds, plan, tasks),
    );
  }
  return decision.copyWith(taskIds: ids);
}

String _skipReasonOf(
  List<String> ids,
  DispatchPlan plan,
  List<TaskRecord> tasks,
) {
  final Map<String, TaskRecord> byId = <String, TaskRecord>{
    for (final TaskRecord task in tasks) task.id: task,
  };
  for (final Map<String, Object?> skipped in plan.skipped) {
    if (ids.contains(textOf(skipped['id']))) {
      return textOf(skipped['reason']).isEmpty
          ? 'not_dispatchable'
          : textOf(skipped['reason']);
    }
  }
  for (final String id in ids) {
    final TaskRecord? task = byId[id];
    if (task == null) return 'unknown_task';
    if (task.status.isTerminal) return 'terminal_state';
    if (task.status == TaskStatus.blocked) return 'blocked';
    if (task.status != TaskStatus.queued && task.status != TaskStatus.packed) {
      return 'not_dispatchable';
    }
  }
  return 'not_dispatchable';
}

OrchestratorDecision _guardRetry(
  OrchestratorDecision decision, {
  required List<TaskRecord> targets,
  required LineRecord line,
  required OrchestratorConfig config,
}) {
  final int maxRetries = intOf(plainMap(line.data['limits'])['retries'], 2);
  final List<String> ids = <String>[
    for (final TaskRecord task in targets)
      if (!task.status.isTerminal &&
          task.status == TaskStatus.blocked &&
          task.loopAttempts < maxRetries &&
          task.stopReason.isEmpty &&
          task.data['budget_exceeded'] != true)
        task.id,
  ];
  if (ids.isEmpty) {
    if (!config.autoRetry) {
      return decision.copyWith(applied: false, guard: 'auto_retry_disabled');
    }
    return decision.copyWith(
      applied: false,
      guard: _retrySkipReason(targets, maxRetries),
    );
  }
  if (!config.autoRetry) {
    return decision.copyWith(applied: false, guard: 'auto_retry_disabled');
  }
  return decision.copyWith(taskIds: ids);
}

String _retrySkipReason(List<TaskRecord> targets, int maxRetries) {
  for (final TaskRecord task in targets) {
    if (task.status.isTerminal) return 'terminal_state';
    if (task.stopReason.isNotEmpty) return 'user_stopped';
    if (task.data['budget_exceeded'] == true) return 'budget_exceeded';
    if (task.loopAttempts >= maxRetries) return 'retry_limit';
    if (task.status != TaskStatus.blocked) return 'not_blocked';
  }
  return 'no_target';
}

OrchestratorDecision _guardAsk(
  OrchestratorDecision decision, {
  required List<TaskRecord> targets,
  required OrchestratorConfig config,
}) {
  final List<TaskRecord> askable = <TaskRecord>[
    for (final TaskRecord task in targets)
      if (!task.status.isTerminal &&
          canTransition(task.status, TaskStatus.blocked))
        task,
  ];
  if (askable.isEmpty) {
    return decision.copyWith(applied: false, guard: 'no_target');
  }
  final List<TaskRecord> underLimit = <TaskRecord>[
    for (final TaskRecord task in askable)
      if (task.askCount < config.maxAsksPerTask) task,
  ];
  if (underLimit.isEmpty) {
    // 每个任务都问满了：只能停（§3.3-3）。
    return decision.copyWith(
      action: 'stop',
      reason: '提问次数已达上限（${config.maxAsksPerTask}）：改为停止（${decision.reason}）',
      taskIds: <String>[for (final TaskRecord task in askable) task.id],
      stopScope: 'task',
      guard: 'ask_limit',
    );
  }
  return decision.copyWith(
    taskIds: <String>[for (final TaskRecord task in underLimit) task.id],
  );
}

// ── 提示词（§5.3）──────────────────────────────────────────────────

/// 系统提示词：角色 / 事实 / 边界 / 输出契约四段固定。
String orchestratorSystemPrompt({
  required OrchestratorConfig config,
  required Map<String, Object?> limits,
}) {
  final int retries = intOf(limits['retries'], 2);
  final int maxParallel = intOf(limits['max_parallel_tasks'], 1);
  return <String>[
    '角色：你是产线的执行期主控（orchestrator）。你只做一个决策，不执行任务、不改代码、不新建或删除任务。',
    '事实：用户消息里的快照来自磁盘真值（task.yaml / runs / inbox.jsonl），是唯一可信来源；不要臆造任务或状态。',
    '边界：',
    '1. continue 不能越过 max_parallel_tasks=$maxParallel、任务依赖与写域（空写域=工作空间根，与任何任务串行）。',
    '2. retry 不能越过 limits.retries=$retries；任务被用户停止（stop_reason 非空）或预算停止时不可重试。',
    '3. ask 每个任务最多 ${config.maxAsksPerTask} 次；问满后只能 stop。',
    '4. 预算到点（budget.exceeded=true）只能 stop 或 ask（让用户加预算），不能 continue / retry。',
    '5. line.status=paused 时任何动作都不执行；done / cancelled 不再决策。',
    '6. 只能在 task_ids 里使用快照 tasks 中出现的 id。',
    '优先级：stop > ask > retry > continue；每 tick 只做一个决策。',
    '输出契约：严格 JSON，不要代码围栏，不要额外解释：',
    '{"action":"continue|retry|ask|stop","reason":"一句话","task_ids":["T1"],'
        '"stage":"auto","question":{"text":"","options":[],"default":""},"stop_scope":"task"}',
  ].join('\n');
}

/// 用户提示词：快照 JSON + 上一条决策（避免同一动作反复触发）。
String orchestratorUserPrompt(OrchestratorSnapshot snapshot) {
  final Map<String, Object?> lastDecision = plainMap(
    snapshot.json['last_decision'],
  );
  return <String>[
    '当前快照：',
    const JsonEncoder.withIndent('  ').convert(snapshot.json),
    if (lastDecision.isNotEmpty)
      '上一条决策：${const JsonEncoder.withIndent('  ').convert(lastDecision)}',
    '请只回一个 JSON 决策对象。',
  ].join('\n');
}

// ── 小工具 ────────────────────────────────────────────────────────

/// 任务当前阶段对应的派发动作：`queued → pack`，`packed → run`，其余空。
String stageOf(TaskStatus status) {
  if (status == TaskStatus.queued) return 'pack';
  if (status == TaskStatus.packed) return 'run';
  return '';
}

String _clip(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max)}…';
