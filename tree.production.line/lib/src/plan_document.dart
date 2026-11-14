/// 计划文档（PC-3F）：7 块模型、计划门 PG-00/01/02/08/09/10 与多轮迭代提示词。
///
/// 纯模型 + 纯校验，不读盘；口径见 `docs/pluginization/production-line-gates.md`
/// §4.1 / §4.2 / §4.3：
/// - PG-00 七块完整（设计 / 不变量 / 任务 / 出口门禁 / 追踪矩阵 / 风险 / 变更控制）；
/// - PG-01 原始需求 `REQ-xx` 编号与原文；
/// - PG-02 需求 → 任务 → `- [ ]` 门控不断链；
/// - PG-08 契约变更必须 `DEC-xx` 批准；
/// - PG-09 迁移计划必须先有基线；
/// - PG-10 至少一轮起草→批判→修正，high findings 关闭或显式承担。
///
/// 旧式 tasks-only 计划（没有 `requirements` / `design`）只跑 Task 7 的 PG-03~07，
/// 在这里做兼容，不升级模型。
library;

import 'dart:convert';

import 'models.dart';
import 'planner.dart';
import 'preparation.dart';

// ── 纯模型 ──────────────────────────────────────────────────────────

/// 一份计划文档。顶层未知键与任务内未知键都原样保留（[extra] / 任务 Map 本身）。
class PlanDocument {
  PlanDocument({
    this.requirements = const <Map<String, Object?>>[],
    this.design = const <String, Object?>{},
    this.invariants = const <Map<String, Object?>>[],
    this.tasks = const <Map<String, Object?>>[],
    this.gates = const <String, List<Map<String, Object?>>>{},
    this.traceability = const <Map<String, Object?>>[],
    this.risks = const <Map<String, Object?>>[],
    this.unknowns = const <Map<String, Object?>>[],
    this.changeControl = const <String, Object?>{},
    this.decisions = const <Map<String, Object?>>[],
    this.findings = const <Map<String, Object?>>[],
    this.rounds = 1,
    this.structured = false,
    this.extra = const <String, Object?>{},
  });

  final List<Map<String, Object?>> requirements;
  final Map<String, Object?> design;
  final List<Map<String, Object?>> invariants;
  final List<Map<String, Object?>> tasks;
  final Map<String, List<Map<String, Object?>>> gates;
  final List<Map<String, Object?>> traceability;
  final List<Map<String, Object?>> risks;
  final List<Map<String, Object?>> unknowns;
  final Map<String, Object?> changeControl;
  final List<Map<String, Object?>> decisions;
  final List<Map<String, Object?>> findings;
  final int rounds;

  /// 输入里是否出现 `requirements` 或 `design`；false = 旧式 tasks-only 计划。
  final bool structured;

  /// 未知的顶层键（原样保留，写出时不丢）。
  final Map<String, Object?> extra;

  PlanDocument copyWith({
    List<Map<String, Object?>>? requirements,
    Map<String, Object?>? design,
    List<Map<String, Object?>>? invariants,
    List<Map<String, Object?>>? tasks,
    Map<String, List<Map<String, Object?>>>? gates,
    List<Map<String, Object?>>? traceability,
    List<Map<String, Object?>>? risks,
    List<Map<String, Object?>>? unknowns,
    Map<String, Object?>? changeControl,
    List<Map<String, Object?>>? decisions,
    List<Map<String, Object?>>? findings,
    int? rounds,
    bool? structured,
    Map<String, Object?>? extra,
  }) => PlanDocument(
    requirements: requirements ?? this.requirements,
    design: design ?? this.design,
    invariants: invariants ?? this.invariants,
    tasks: tasks ?? this.tasks,
    gates: gates ?? this.gates,
    traceability: traceability ?? this.traceability,
    risks: risks ?? this.risks,
    unknowns: unknowns ?? this.unknowns,
    changeControl: changeControl ?? this.changeControl,
    decisions: decisions ?? this.decisions,
    findings: findings ?? this.findings,
    rounds: rounds ?? this.rounds,
    structured: structured ?? this.structured,
    extra: extra ?? this.extra,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    ...extra,
    'requirements': requirements,
    'design': design,
    'invariants': invariants,
    'tasks': tasks,
    'gates': gates,
    'traceability': traceability,
    'risks': risks,
    'unknowns': unknowns,
    'change_control': changeControl,
    'decisions': decisions,
    'findings': findings,
    'rounds': rounds,
  };
}

const Set<String> _kKnownKeys = <String>{
  'requirements',
  'design',
  'invariants',
  'tasks',
  'gates',
  'traceability',
  'risks',
  'unknowns',
  'change_control',
  'decisions',
  'findings',
  'rounds',
};

/// 容错解析计划文档；缺失块给空值，不在这里抛“缺块”错误。
PlanDocument parsePlanDocument(Map<String, Object?> json, {int rounds = 1}) {
  final Map<String, Object?> extra = <String, Object?>{
    for (final MapEntry<String, Object?> entry in json.entries)
      if (!_kKnownKeys.contains(entry.key)) entry.key: entry.value,
  };
  final Map<String, Object?> design = plainMap(json['design']);
  final bool structured =
      json.containsKey('requirements') || json.containsKey('design');
  final int parsedRounds = intOf(json['rounds'], rounds);
  return PlanDocument(
    requirements: _rowsOf(json['requirements']),
    design: design,
    invariants: _rowsOf(json['invariants']),
    tasks: _tasksOf(json['tasks']),
    gates: _gatesOf(json['gates']),
    traceability: _rowsOf(json['traceability']),
    risks: _rowsOf(json['risks']),
    unknowns: _rowsOf(json['unknowns']),
    changeControl: plainMap(json['change_control']),
    decisions: _rowsOf(json['decisions']),
    findings: _rowsOf(json['findings']),
    rounds: parsedRounds < 0 ? rounds : parsedRounds,
    structured: structured,
    extra: extra,
  );
}

List<Map<String, Object?>> _rowsOf(Object? raw) => <Map<String, Object?>>[
  if (raw is List)
    for (final Object? item in raw)
      if (item is Map) plainMap(item),
];

/// 任务解析复用 [parseScopeJson]；字段不完整时退回原始 Map（交给后续门控判）。
List<Map<String, Object?>> _tasksOf(Object? raw) {
  if (raw is! List) return const <Map<String, Object?>>[];
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[
    for (final Object? item in raw)
      if (item is Map) plainMap(item),
  ];
  if (rows.isEmpty) return const <Map<String, Object?>>[];
  try {
    final ScopePlan plan = parseScopeJson(<String, Object?>{'tasks': rows});
    return <Map<String, Object?>>[
      for (int i = 0; i < plan.tasks.length; i++)
        <String, Object?>{...rows[i], ...plan.tasks[i].toJson()},
    ];
  } on ProductionFailure {
    return rows;
  }
}

Map<String, List<Map<String, Object?>>> _gatesOf(Object? raw) {
  final Map<String, Object?> map = plainMap(raw);
  return <String, List<Map<String, Object?>>>{
    for (final MapEntry<String, Object?> entry in map.entries)
      entry.key: normalizeGateItems(entry.value),
  };
}

// ── 门控清单解析（机器证据）────────────────────────────────────────

final RegExp _checkboxPattern = RegExp(r'^[-*+]\s*\[[ xX]\]\s*');
final RegExp _bareCheckboxPattern = RegExp(r'^\[[ xX]\]\s*');

/// 一条门控项的可解析文本：统一成 `- [ ] ...`（没有前缀就补）。
String _normalizedGateText(String raw) {
  String text = raw.trim();
  text = text.replaceFirst(_checkboxPattern, '');
  text = text.replaceFirst(_bareCheckboxPattern, '');
  text = text.trim();
  return text.isEmpty ? '' : '- [ ] $text';
}

/// 门控项的匹配键：显式 `id` 优先，否则取 `- [ ]` 之后的正文前 40 字。
String _gateKeyOf(Map<String, Object?> item) {
  final String explicit = textOf(item['id']);
  if (explicit.isNotEmpty) return explicit;
  String text = textOf(item['text']);
  text = text.replaceFirst(_checkboxPattern, '');
  text = text.replaceFirst(_bareCheckboxPattern, '');
  text = text.trim();
  return text.length <= 40 ? text : text.substring(0, 40);
}

/// 把 `gates[taskId]` 的任意输入（字符串 / Map）规范成
/// `{text:'- [ ] ...', evidence:'...', checked:false}`；未知键保留。
List<Map<String, Object?>> normalizeGateItems(Object? raw) {
  if (raw is! List) return const <Map<String, Object?>>[];
  final List<Map<String, Object?>> out = <Map<String, Object?>>[];
  for (final Object? item in raw) {
    if (item is Map) {
      final Map<String, Object?> map = plainMap(item);
      out.add(<String, Object?>{
        ...map,
        'text': _normalizedGateText(textOf(map['text'])),
        'evidence': textOf(map['evidence']),
        'checked': false,
      });
    } else {
      final String text = textOf(item);
      if (text.isEmpty) continue;
      out.add(<String, Object?>{
        'text': _normalizedGateText(text),
        'evidence': '',
        'checked': false,
      });
    }
  }
  return out;
}

bool _isPlaceholderEvidence(String value) {
  final String text = value.trim().toLowerCase();
  return text.isEmpty ||
      text == '-' ||
      text == '—' ||
      text == '无' ||
      text == 'todo' ||
      text == 'tbd';
}

// ── 校验 ────────────────────────────────────────────────────────────

/// 一次计划文档校验的结果。
class PlanDocValidation {
  const PlanDocValidation({
    required this.ok,
    required this.issues,
    required this.doc,
  });

  final bool ok;
  final List<PlanIssue> issues;
  final PlanDocument doc;

  String get code {
    for (final PlanIssue issue in issues) {
      if (issue.severity == 'error') return issue.code;
    }
    return '';
  }

  String get message {
    for (final PlanIssue issue in issues) {
      if (issue.severity == 'error') return issue.message;
    }
    return '';
  }

  List<String> get missing {
    for (final PlanIssue issue in issues) {
      if (issue.severity == 'error') {
        return issue.taskId.isEmpty ? const <String>[] : <String>[issue.taskId];
      }
    }
    return const <String>[];
  }
}

const List<String> _kDesignKeys = <String>[
  'current',
  'target',
  'architecture',
  'data_flow',
  'migration',
  'compatibility',
  'rollback',
];

/// 迁移策略（PG-09）：只认这六种，避免模型自创“逐步迁移”之类无法校验的写法。
const Set<String> _kMigrationStrategies = <String>{
  'strangler',
  'adapter',
  'flag',
  'parallel',
  'shadow',
  'dual_write',
};

/// 任务的行为分类（迁移计划的防漂移口径）。
const Set<String> _kBehaviors = <String>{'preserve', 'change'};

final RegExp _requirementIdPattern = RegExp(r'^REQ-\d+$');
final RegExp _decisionIdPattern = RegExp(r'^DEC-\d+$');
final RegExp _approverSeparatorPattern = RegExp(r'[,，、;；]');

/// 校验并修正计划文档。
///
/// 先跑 Task 7 的 [validateAndFixPlan]（PG-03~07），任务 / gates 同步：
/// 拆出的新任务继承原任务的 gates。`structured == false` 时只回 Task 7 结果；
/// structured 时追加 PG-00 / PG-01 / PG-02 / PG-08 / PG-09 / PG-10。
PlanDocValidation validatePlanDocument(
  PlanDocument doc, {
  required Set<String> existingIds,
  int maxParallel = 1,
  bool fixTasks = true,
}) {
  final Map<String, List<Map<String, Object?>>> gates =
      <String, List<Map<String, Object?>>>{
        for (final MapEntry<String, List<Map<String, Object?>>> entry
            in doc.gates.entries)
          entry.key: normalizeGateItems(entry.value),
      };
  final List<String> originalIds = <String>[
    for (final Map<String, Object?> task in doc.tasks) textOf(task['id']),
  ];
  final PlanValidation base = validateAndFixPlan(
    tasks: doc.tasks,
    existingIds: existingIds,
    maxParallel: maxParallel,
    fix: fixTasks,
  );
  // 拆出的新任务继承原任务的 gates（原 id 前缀匹配）。
  for (final Map<String, Object?> task in base.tasks) {
    final String id = textOf(task['id']);
    if (id.isEmpty || gates.containsKey(id)) continue;
    for (final String original in originalIds) {
      if (original.isEmpty || !id.startsWith('$original-')) continue;
      final List<Map<String, Object?>>? inherited = gates[original];
      if (inherited == null) continue;
      gates[id] = <Map<String, Object?>>[
        for (final Map<String, Object?> item in inherited)
          <String, Object?>{...item},
      ];
      break;
    }
  }
  PlanDocument updated = doc.copyWith(tasks: base.tasks, gates: gates);
  final List<PlanIssue> issues = <PlanIssue>[...base.issues];

  if (!doc.structured) {
    return PlanDocValidation(
      ok: !issues.any((PlanIssue issue) => issue.severity == 'error'),
      issues: issues,
      doc: updated,
    );
  }

  void report(String code, String taskId, String message) {
    issues.add(PlanIssue(code: code, taskId: taskId, message: message));
  }

  final Map<String, Object?> design = updated.design;
  final List<Map<String, Object?>> tasks = updated.tasks;
  final Set<String> taskIds = <String>{
    for (final Map<String, Object?> task in tasks)
      if (textOf(task['id']).isNotEmpty) textOf(task['id']),
  };

  // PG-00：7 块完整。
  final List<String> missingDesign = <String>[
    for (final String key in _kDesignKeys)
      if (textOf(design[key]).isEmpty) key,
  ];
  if (design.isEmpty || missingDesign.isNotEmpty) {
    report(
      'plan_design_missing',
      '',
      '方案设计缺少非空字段：${missingDesign.isEmpty ? 'design 为空' : missingDesign.join('、')}',
    );
  } else if (!design.containsKey('rejected_alternatives')) {
    report('plan_design_missing', '', '方案设计缺少 rejected_alternatives（可为空数组）');
  }
  if (updated.invariants.isEmpty) {
    report('plan_invariants_missing', '', '不变量账本为空');
  } else {
    for (final Map<String, Object?> invariant in updated.invariants) {
      final String id = textOf(invariant['id']);
      final String statement = textOf(invariant['statement']);
      final String owner = textOf(invariant['owner']);
      final String check = textOf(invariant['check']);
      if (statement.isEmpty || owner.isEmpty || check.isEmpty) {
        report(
          'plan_invariants_missing',
          '',
          '不变量 ${id.isEmpty ? '（无 id）' : id} 缺 statement / owner / check',
        );
      }
    }
  }
  if (tasks.isEmpty) {
    report('plan_tasks_missing', '', '计划里没有任何任务');
  }
  if (updated.gates.isEmpty ||
      !updated.gates.values.any(
        (List<Map<String, Object?>> list) => list.isNotEmpty,
      )) {
    report('plan_gate_missing', '', '计划没有出口门禁清单（gates 为空）');
  }
  if (updated.traceability.isEmpty) {
    report('plan_traceability_gap', '', '追踪矩阵为空');
  }
  if (updated.risks.isEmpty && updated.unknowns.isEmpty) {
    report('plan_risk_missing', '', '风险与未知：risks / unknowns 都为空');
  }
  for (final String key in const <String>[
    'plan_version',
    'decision_template',
    'rollback_points',
  ]) {
    if (!updated.changeControl.containsKey(key)) {
      report('plan_change_control_missing', '', '变更控制缺少 $key');
    }
  }

  // PG-01：原始需求编号与原文。
  final Map<String, Map<String, Object?>> requirements =
      <String, Map<String, Object?>>{};
  if (updated.requirements.isEmpty) {
    report('plan_requirement_missing', '', '没有任何原始需求（requirements 为空）');
  }
  for (final Map<String, Object?> requirement in updated.requirements) {
    final String id = textOf(requirement['id']);
    final String text = textOf(requirement['text']);
    if (!_requirementIdPattern.hasMatch(id)) {
      report(
        'plan_requirement_missing',
        '',
        '需求编号非法：${id.isEmpty ? '（空）' : id}（必须 REQ-xx）',
      );
      continue;
    }
    if (text.isEmpty) {
      report('plan_requirement_missing', '', '需求 $id 缺原文（text）');
    }
    if (requirements.containsKey(id)) {
      report('plan_requirement_missing', '', '需求编号重复：$id');
      continue;
    }
    requirements[id] = requirement;
  }

  // 门控清单逐项解析：文本必须是 `- [ ] ...`，evidence 非空且非占位符。
  for (final MapEntry<String, List<Map<String, Object?>>> entry
      in updated.gates.entries) {
    final String taskId = entry.key;
    for (final Map<String, Object?> item in entry.value) {
      final String text = textOf(item['text']);
      final String evidence = textOf(item['evidence']);
      if (text.isEmpty) {
        report('plan_gate_missing', taskId, '任务 $taskId 有空的出口门控项');
      }
      if (_isPlaceholderEvidence(evidence)) {
        report(
          'plan_gate_missing',
          taskId,
          '任务 $taskId 的门控「${text.isEmpty ? '（空）' : text}」缺 evidence',
        );
      }
    }
  }

  // PG-02：REQ → 任务 → 门控。
  final Map<String, Map<String, Object?>> traceRows =
      <String, Map<String, Object?>>{};
  for (final Map<String, Object?> row in updated.traceability) {
    final String req = textOf(row['req']);
    if (req.isEmpty) {
      report('plan_traceability_gap', '', '追踪矩阵有一条缺 req');
      continue;
    }
    if (!requirements.containsKey(req)) {
      report('plan_traceability_gap', '', '追踪矩阵引用了不存在的需求 $req');
      continue;
    }
    traceRows[req] = row;
  }
  for (final String req in requirements.keys) {
    final Map<String, Object?>? row = traceRows[req];
    if (row == null) {
      report('plan_traceability_gap', '', '需求 $req 在追踪矩阵里没有条目');
      continue;
    }
    final List<String> mappedTasks = stringsOf(row['tasks']);
    if (mappedTasks.isEmpty) {
      report('plan_traceability_gap', '', '需求 $req 没有映射任何任务');
    }
    for (final String taskId in mappedTasks) {
      if (!taskIds.contains(taskId)) {
        report('plan_traceability_gap', taskId, '需求 $req 映射到不存在的任务 $taskId');
      }
    }
    final List<Object?> gateRefs = row['gates'] is List
        ? row['gates'] as List<Object?>
        : const <Object?>[];
    if (gateRefs.isEmpty) {
      report('plan_traceability_gap', '', '需求 $req 没有映射任何门控');
      continue;
    }
    final List<String> scopeTasks = mappedTasks.isEmpty
        ? taskIds.toList()
        : mappedTasks;
    for (final Object? rawGate in gateRefs) {
      final Map<String, Object?> gateRef = rawGate is Map
          ? plainMap(rawGate)
          : <String, Object?>{'text': textOf(rawGate)};
      final String wantedTask = textOf(gateRef['task'] ?? gateRef['task_id']);
      final String wantedKey = _gateKeyOf(gateRef);
      final List<String> candidates = wantedTask.isNotEmpty
          ? <String>[wantedTask]
          : scopeTasks;
      bool found = false;
      for (final String taskId in candidates) {
        final List<Map<String, Object?>> list =
            updated.gates[taskId] ?? const <Map<String, Object?>>[];
        if (list.any(
          (Map<String, Object?> item) => _gateKeyOf(item) == wantedKey,
        )) {
          found = true;
          break;
        }
      }
      if (!found) {
        report(
          'plan_traceability_gap',
          mappedTasks.isEmpty ? '' : mappedTasks.first,
          '需求 $req 的门控「${wantedKey.isEmpty ? '（空）' : wantedKey}」在任务门控里不存在',
        );
      }
    }
  }
  for (final Map<String, Object?> task in tasks) {
    final String taskId = textOf(task['id']);
    for (final String req in stringsOf(task['requirements'])) {
      if (!requirements.containsKey(req)) {
        report('plan_traceability_gap', taskId, '任务 $taskId 声明了不存在的需求 $req');
      }
    }
  }

  // PG-08：契约变更必须有双人确认的已批准 DEC-xx。
  for (final Map<String, Object?> task in tasks) {
    final String taskId = textOf(task['id']);
    if (!_hasContractChange(task)) continue;
    if (!_hasDoubleApprovedDecision(updated.decisions, taskId)) {
      report(
        'plan_contract_change_unauthorized',
        taskId,
        '任务 $taskId 改了契约（contract.changes / contract_change）但没有已批准的 DEC-xx'
        '（status=approved 且 approved_by 至少 2 个不同的人）',
      );
    }
  }

  // PG-09：迁移计划的防漂移要求（基线 / 策略 / 回滚 / 行为分类）。
  final bool migrationRequired =
      textOf(design['migration']).isNotEmpty ||
      design['migration_required'] == true;
  if (migrationRequired) {
    final String baseline = textOf(design['baseline']);
    final List<String> baselineTasks = stringsOf(design['baseline_tasks']);
    if (baseline.isEmpty || baselineTasks.isEmpty) {
      report(
        'plan_baseline_missing',
        '',
        '迁移计划缺 design.baseline / design.baseline_tasks',
      );
    } else {
      for (final String id in baselineTasks) {
        if (!taskIds.contains(id) && !existingIds.contains(id)) {
          report('plan_baseline_missing', '', '基线任务 $id 既不在本次计划也不是已存在任务');
        }
      }
    }
    final String strategy = textOf(design['migration_strategy']);
    if (!_kMigrationStrategies.contains(strategy)) {
      report(
        'plan_design_missing',
        '',
        '迁移计划缺合法的 design.migration_strategy（只能是 '
        '${_kMigrationStrategies.join(' / ')}）：${strategy.isEmpty ? '（空）' : strategy}',
      );
    }
    final String rollback = textOf(design['rollback']);
    final List<String> rollbackTasks = stringsOf(design['rollback_tasks']);
    if (rollback.isEmpty || rollbackTasks.isEmpty) {
      report(
        'plan_design_missing',
        '',
        '迁移计划缺 design.rollback / design.rollback_tasks',
      );
    } else {
      for (final String id in rollbackTasks) {
        if (!taskIds.contains(id) && !existingIds.contains(id)) {
          report('plan_design_missing', '', '回滚任务 $id 既不在本次计划也不是已存在任务');
        }
      }
    }
    // 行为保持 / 行为改变必须分属不同任务，且都带 preserves / changes 两个数组键。
    final List<String> preserveTasks = <String>[];
    final List<String> changeTasks = <String>[];
    for (final Map<String, Object?> task in tasks) {
      final String taskId = textOf(task['id']);
      final Object? rawBehavior = task['behavior'];
      String behavior = '';
      bool mixed = false;
      if (rawBehavior is String) {
        behavior = rawBehavior.trim();
      } else if (rawBehavior is List) {
        final Set<String> values = <String>{
          for (final String item in stringsOf(rawBehavior)) item,
        };
        if (values.length == 1 && _kBehaviors.contains(values.first)) {
          behavior = values.first;
        } else {
          mixed = values.containsAll(_kBehaviors);
        }
      }
      if (!_kBehaviors.contains(behavior)) {
        report(
          'plan_design_missing',
          taskId,
          mixed
              ? '任务 $taskId 同时声明了 preserve 与 change：一个任务只能有一个 behavior'
              : '任务 $taskId 缺 behavior（迁移计划里只能是 preserve / change）',
        );
      } else if (behavior == 'preserve') {
        preserveTasks.add(taskId);
      } else {
        changeTasks.add(taskId);
      }
      for (final String key in const <String>['preserves', 'changes']) {
        if (!task.containsKey(key)) {
          report(
            'plan_invariants_missing',
            taskId,
            '任务 $taskId 缺 $key 数组键（可为空数组）',
          );
        } else if (task[key] != null && task[key] is! List) {
          report(
            'plan_invariants_missing',
            taskId,
            '任务 $taskId 的 $key 必须是数组',
          );
        }
      }
    }
    // 两类行为至少各有一个任务；某一类确实不需要时，在 design 里显式说明。
    final String behaviorSplit = textOf(design['behavior_split']);
    if (preserveTasks.isEmpty && behaviorSplit.isEmpty) {
      report(
        'plan_design_missing',
        '',
        '迁移计划没有行为保持任务（behavior=preserve），且 design.behavior_split 未说明不需要',
      );
    }
    if (changeTasks.isEmpty && behaviorSplit.isEmpty) {
      report(
        'plan_design_missing',
        '',
        '迁移计划没有行为改变任务（behavior=change），且 design.behavior_split 未说明不需要',
      );
    }
  }

  // PG-10：迭代闭环，high findings 必须关闭或被显式承担。
  if (updated.rounds < 1) {
    report('plan_critic_open_high', '', '计划还没有经历起草→批判→修正（rounds < 1）');
  }
  for (final Map<String, Object?> finding in updated.findings) {
    if (textOf(finding['severity']) != 'high') continue;
    if (textOf(finding['status']) == 'closed') continue;
    final String findingId = textOf(finding['id']);
    final bool accepted = updated.decisions.any(
      (Map<String, Object?> decision) =>
          textOf(decision['type']) == 'accept_high_finding' &&
          findingId.isNotEmpty &&
          textOf(decision['finding_id']) == findingId,
    );
    if (!accepted) {
      report(
        'plan_critic_open_high',
        textOf(finding['task_id']),
        'high finding ${findingId.isEmpty ? '（无 id）' : findingId} 未关闭也没有 accept_high_finding DEC',
      );
    }
  }

  return PlanDocValidation(
    ok: !issues.any((PlanIssue issue) => issue.severity == 'error'),
    issues: issues,
    doc: updated,
  );
}

bool _hasContractChange(Map<String, Object?> task) {
  if (task['contract_change'] == true) return true;
  final Map<String, Object?> contract = plainMap(task['contract']);
  final Object? changes = contract['changes'];
  if (changes is List) return changes.isNotEmpty;
  if (changes is Map) return changes.isNotEmpty;
  final String text = textOf(changes);
  return text.isNotEmpty && text != '[]' && text != '{}';
}

/// PG-08 双人确认：只认 `DEC-xx`、`status=approved`、且 `approved_by`
/// 至少 2 个不同的人（逗号 / 顿号 / 分号分隔），并作用于该任务。
bool _hasDoubleApprovedDecision(
  List<Map<String, Object?>> decisions,
  String taskId,
) {
  for (final Map<String, Object?> decision in decisions) {
    if (!_decisionIdPattern.hasMatch(textOf(decision['id']))) continue;
    if (textOf(decision['status']) != 'approved') continue;
    if (_distinctApprovers(decision['approved_by']).length < 2) continue;
    final Object? scope = decision['scope'];
    final Set<String> scopeIds = <String>{
      if (scope is List) ...stringsOf(scope),
      if (scope is! List)
        for (final String item in textOf(scope).split(RegExp(r'[,，、;；\s]+')))
          if (item.isNotEmpty) item,
    };
    if (scopeIds.contains(taskId) || textOf(decision['task_id']) == taskId) {
      return true;
    }
  }
  return false;
}

List<String> _distinctApprovers(Object? raw) {
  final List<String> out = <String>[];
  for (final String part in textOf(raw).split(_approverSeparatorPattern)) {
    final String name = part.trim();
    if (name.isEmpty || out.contains(name)) continue;
    out.add(name);
  }
  return out;
}

/// 把一条校验问题转成 finding（error → high、warning → medium，默认 open）。
///
/// `id` 带轮次与 code，保证同轮同一问题的 id 稳定、可追踪；`source=validation`
/// 供多轮循环把已消失的校验项标 closed。
Map<String, Object?> findingOf(PlanIssue issue, int round) {
  final String suffix = issue.taskId.isEmpty ? '' : '@${issue.taskId}';
  return <String, Object?>{
    'id': 'F-$round-${issue.code}$suffix',
    'severity': issue.severity == 'warning' ? 'medium' : 'high',
    'status': 'open',
    'task_id': issue.taskId,
    'message': issue.message,
    'round': round,
    'code': issue.code,
    'source': 'validation',
  };
}

// ── 提示词（模型契约）──────────────────────────────────────────────

/// 计划起草：只输出一个 JSON，键固定为 7 块 + decisions/findings/rounds。
String planDocumentSystemPrompt() =>
    '你是标准开发流的计划起草员。只输出一个 JSON 对象，不要 Markdown 代码围栏、'
    '不要解释、不要调用工具。键固定为：'
    '{"requirements":[{"id":"REQ-01","text":"需求原文","source":"intake.goal"}],'
    '"design":{"current":"","target":"","architecture":"","data_flow":"","migration":"",'
    '"compatibility":"","rollback":"","rejected_alternatives":[],"baseline":"","baseline_tasks":[],'
    '"migration_strategy":"adapter","rollback_tasks":[],"behavior_split":""},'
    '"invariants":[{"id":"INV-01","statement":"","owner":"","check":"","kind":"behavior"}],'
    '"tasks":[{"id":"T1","title":"","task_type":"code","depends_on":[],"read_scope":[],'
    '"write_scope":[],"acceptance":["可验证判据"],"estimated_files":1,"estimated_lines":0,'
    '"estimated_packages":0,"risk":"low","contract":{},"rationale":"",'
    '"behavior":"change","preserves":[],"changes":["改了哪条行为"],'
    '"requirements":["REQ-01"],"gate":{"commands":["dart test"],"checklist":["- [ ] ..."]}}],'
    '"gates":{"T1":[{"text":"- [ ] ...","evidence":"相对证据路径"}]},'
    '"traceability":[{"req":"REQ-01","tasks":["T1"],"gates":["- [ ] ..."],"evidence":["..."]}],'
    '"risks":[{"id":"RISK-01","level":"low","statement":"","mitigation":""}],'
    '"change_control":{"plan_version":"plan-v1","decision_template":"DEC-xx ...",'
    '"rollback_points":["S0 基线"]},'
    '"decisions":[{"id":"DEC-01","status":"proposed","approved_by":"","scope":["T1"],'
    '"task_id":"T1","type":"contract_change","finding_id":"","statement":""}],'
    '"findings":[],"rounds":1}。'
    '约束：requirements 每条必须有 REQ-xx 编号并保留原文，且被至少一个任务与一个 '
    '- [ ] 门控承接；任务 1–5 个文件、≤300 改动行、≤1 个包；多代码任务必须有 '
    'integration 任务依赖全部 code 任务；gates[taskId] 每项必须写成 "- [ ] ..." 且 '
    'evidence 指向真实证据路径（不许 "-"/"无"/"todo"/"TBD"）；方案设计的 current/target/'
    'architecture/data_flow/migration/compatibility/rollback 全部非空，rejected_alternatives '
    '键必须存在；迁移计划（migration 非空或 migration_required=true）还必须写 '
    'design.migration_strategy（strangler/adapter/flag/parallel/shadow/dual_write 之一）、'
    'design.baseline / baseline_tasks、design.rollback / rollback_tasks（任务 id 必须存在），'
    '且每个任务必须有 behavior（preserve / change，一个任务只能一个）、preserves 与 changes '
    '两个数组键；preserve 与 change 必须是不同任务，某一类确实不需要时在 design.behavior_split '
    '里显式说明；公共 API/schema/权限/UX 契约变更必须给 DEC-xx（status=approved 且 '
    'approved_by 至少 2 个不同的人，scope 含任务 id）；风险写 risks 或 unknowns；'
    'findings 交给批判轮，rounds 记录迭代轮次。';

String planDocumentUserPrompt({
  required String taskId,
  required String title,
  required Map<String, String> intake,
  required String reconText,
  required String decisionsText,
  String? memory,
  int round = 1,
  List<Map<String, Object?>> findings = const <Map<String, Object?>>[],
}) {
  final StringBuffer buffer = StringBuffer()
    ..writeln('任务：$taskId $title')
    ..writeln('目标：${intake['goal'] ?? ''}')
    ..writeln('现状：${intake['current'] ?? ''}')
    ..writeln('验收：${intake['acceptance'] ?? ''}')
    ..writeln('禁区：${intake['forbidden'] ?? ''}')
    ..writeln('期限：${intake['deadline'] ?? ''}')
    ..writeln()
    ..writeln('侦查（已冻结）：')
    ..writeln(reconText)
    ..writeln()
    ..writeln('拍板记录（没有 assumed，全部由用户回答）：')
    ..writeln(decisionsText)
    ..writeln();
  if (memory != null && memory.trim().isNotEmpty) {
    buffer
      ..writeln('项目记忆（只是背景，不得当作需求证据）：')
      ..writeln(clipProjectMemory(memory.trim()))
      ..writeln();
  }
  buffer.writeln('当前轮次：第 $round 轮（最多 3 轮起草→批判→修正）。');
  if (findings.isNotEmpty) {
    buffer
      ..writeln('上一轮未解决 findings：')
      ..writeln(jsonEncode(findings))
      ..writeln();
  }
  buffer.writeln('请输出完整计划文档（严格 JSON）。');
  return buffer.toString();
}

/// 批判者：只出 findings，不改稿。
String planCriticSystemPrompt() =>
    '你是独立计划批判者。只输出一个 JSON 对象，不要 Markdown 代码围栏、不要解释。'
    '结构：{"findings":[{"id":"F-01","severity":"low|medium|high","task_id":"T1",'
    '"message":"问题","suggestion":"修复建议"}]}。'
    '只找问题，不重写计划；每条 finding 必须有 severity 与具体 message；'
    '没有问题就输出 {"findings":[]}。检查点：需求是否都有任务与门控承接、不变量是否有检查、'
    '任务是否超尺寸/写域交叠/伪依赖、迁移是否可回滚且先有基线、集成任务是否覆盖端到端、'
    '门控是否可执行且有 evidence、未决问题是否显式。';

String planCriticUserPrompt(PlanDocument doc) =>
    '请批判下面这份计划，只输出 findings（JSON）：\n'
    '${jsonEncode(doc.toJson())}';

/// 修正者：只打补丁，保留已确认内容。
String planFixSystemPrompt() =>
    '你是计划修正者。按 findings 给现有计划打补丁，只输出完整计划 JSON（结构同起草），'
    '不要 Markdown 代码围栏、不要解释。硬约束：不得删除已确认的 requirements id 集合、'
    '不得清空 design 已填写的键、不得丢失原任务 id；只能补充/修改字段；'
    'findings 可把已修复项标 status=closed；rounds 写当前轮次。';

String planFixUserPrompt(
  PlanDocument doc,
  List<Map<String, Object?>> findings,
) =>
    '现有计划：\n${jsonEncode(doc.toJson())}\n\n'
    '需要修正的 findings：\n${jsonEncode(findings)}\n\n'
    '只打补丁：保留 requirements id、design 已填键与原任务 id，输出完整计划 JSON。';

/// 容错解析批判者 / 修正者回包里的 findings；缺 id 补 `F-<round>-<n>`。
List<Map<String, Object?>> parseFindingsJson(
  Map<String, Object?> json, {
  int round = 1,
}) {
  final Object? raw = json['findings'];
  final List<Object?> rows = raw is List
      ? raw
      : (json.containsKey('severity') || json.containsKey('message')
            ? <Object?>[json]
            : const <Object?>[]);
  final List<Map<String, Object?>> out = <Map<String, Object?>>[];
  int index = 0;
  for (final Object? item in rows) {
    if (item is! Map) continue;
    index += 1;
    final Map<String, Object?> map = plainMap(item);
    String severity = textOf(map['severity']).toLowerCase();
    if (severity != 'low' && severity != 'medium' && severity != 'high') {
      severity = 'medium';
    }
    final String status = textOf(map['status']) == 'closed' ? 'closed' : 'open';
    out.add(<String, Object?>{
      ...map,
      'id': textOf(map['id']).isEmpty ? 'F-$round-$index' : textOf(map['id']),
      'severity': severity,
      'status': status,
      'task_id': textOf(map['task_id']),
      'message': textOf(map['message']),
      'round': round,
    });
  }
  return out;
}
