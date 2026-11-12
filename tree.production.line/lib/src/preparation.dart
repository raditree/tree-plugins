/// 准备阶段（P3）的纯领域逻辑：需求模板、侦查四块、追问台账、范围与计划、
/// 读取预算、文档渲染。
///
/// 口径（docs/pluginization/production-line-recon.md §8）：
/// - 侦查四节顺序固定，编号 `R/S/Q/F/N` 由渲染层统一重排（模型给的行序即编号）；
/// - 追问上限 N 读设置（默认 3，夹到 1–10）；**上一轮未答问题保留、不占新额度**；
/// - 未答问题绝不按默认实施（由调用方在 finalize 前检查 [openQuestionsOf]）；
/// - 对齐阶段默认只读文档；点状读取按会话计预算（文件 ≤ 8、`grep` ≤ 2 轮）。
library;

import 'models.dart';

// ── 需求模板（§8.2）────────────────────────────────────────────────

/// 五栏的键（与 `task.yaml` 的 `intake` 逐字一致）。
const List<String> kIntakeKeys = <String>[
  'goal',
  'current',
  'acceptance',
  'forbidden',
  'deadline',
];

const Map<String, String> kIntakeLabels = <String, String>{
  'goal': '目标',
  'current': '现状',
  'acceptance': '验收',
  'forbidden': '禁区',
  'deadline': '期限',
};

/// 空泛词 → 改写建议（§8.2：命中给一次可点选的改写建议）。
const Map<String, String> kVagueHints = <String, String>{
  '优化': '写成「哪个指标、从多少到多少」',
  '重构': '写成「重构哪一层、哪些外部行为必须不变」',
  '差不多': '写成「差多少算通过」',
  '尽快': '写成「哪一天、哪个窗口内」',
  '你懂的': '把「我懂的」写成一句验收判据',
  '好用了就行': '把「好用」写成一条可验证的判据',
};

/// 一次需求模板校验的结果。
class IntakeResult {
  const IntakeResult({
    required this.values,
    required this.warnings,
    required this.blocking,
  });

  /// 五栏原文（缺失 = 空串，不猜默认值）。
  final Map<String, String> values;

  /// 不阻断保存的提示（空泛词 / 过长）。
  final List<String> warnings;

  /// 阻断项（目标 / 验收为空 ⇒ 不许进入侦查）。
  final List<String> blocking;

  bool get ok => blocking.isEmpty;
}

/// 校验需求模板：目标与验收必须非空；其余栏可空；空泛词只提示不阻断。
IntakeResult normalizeIntake(Map<String, Object?> raw) {
  final Map<String, String> values = <String, String>{
    for (final String key in kIntakeKeys) key: textOf(raw[key]),
  };
  final List<String> blocking = <String>[];
  if (values['goal']!.isEmpty) blocking.add('「目标」不能为空');
  if (values['acceptance']!.isEmpty) {
    blocking.add('「验收」不能为空（必须是可验证的判据）');
  }
  final List<String> warnings = <String>[];
  for (final String key in kIntakeKeys) {
    final String value = values[key]!;
    if (value.isEmpty) continue;
    for (final MapEntry<String, String> hint in kVagueHints.entries) {
      if (value.contains(hint.key)) {
        warnings.add('「${kIntakeLabels[key]}」含空泛词「${hint.key}」：${hint.value}');
      }
    }
    if (value.length > 300) {
      warnings.add('「${kIntakeLabels[key]}」超过 300 字，建议压到一句话');
    }
  }
  return IntakeResult(values: values, warnings: warnings, blocking: blocking);
}

// ── 追问上限（§8.4）────────────────────────────────────────────────

/// 追问上限：非法值回默认 3，并**夹到 1–10**（设置项与 `line.yaml` 共用）。
int clampQuestionLimit(Object? raw) {
  final int value = intOf(raw, 3);
  if (value < 1) return 1;
  if (value > 10) return 10;
  return value;
}

// ── 侦查四块（§8.3）────────────────────────────────────────────────

/// 侦查里的一条（`R/S/F/N` 共用）：正文 + 附加说明（落点 / 为什么 / 风险）。
class ReconPoint {
  const ReconPoint({required this.text, this.note = ''});

  final String text;
  final String note;

  Map<String, Object?> toJson() => <String, Object?>{
    'text': text,
    if (note.isNotEmpty) 'note': note,
  };
}

/// 一条待拍板问题（Q）。
class ReconQuestionSpec {
  const ReconQuestionSpec({
    required this.text,
    required this.defaultValue,
    required this.recommended,
    required this.consequence,
  });

  final String text;

  /// 用户不回答时系统**不会采用**它——只用于展示「如果按默认会怎样」。
  final String defaultValue;
  final String recommended;

  /// 不选后果（一句话）。
  final String consequence;

  Map<String, Object?> toJson() => <String, Object?>{
    'text': text,
    'default': defaultValue,
    'recommended': recommended,
    'consequence': consequence,
  };
}

/// 一次侦查的结构化产物。
class ReconDraft {
  const ReconDraft({
    required this.regular,
    required this.special,
    required this.questions,
    required this.fallbacks,
    required this.notes,
    required this.flags,
    required this.droppedQuestions,
  });

  final List<ReconPoint> regular;
  final List<ReconPoint> special;
  final List<ReconQuestionSpec> questions;
  final List<ReconPoint> fallbacks;
  final List<ReconPoint> notes;

  /// 需要**点状读取**的代码文件（每会话 ≤ 8）。
  final List<String> flags;

  /// 超出本轮额度的提问数（被截断，不静默：回包里要告诉调用方）。
  final int droppedQuestions;

  Map<String, Object?> toJson() => <String, Object?>{
    'regular': <Map<String, Object?>>[
      for (final ReconPoint point in regular) point.toJson(),
    ],
    'special': <Map<String, Object?>>[
      for (final ReconPoint point in special) point.toJson(),
    ],
    'questions': <Map<String, Object?>>[
      for (final ReconQuestionSpec question in questions) question.toJson(),
    ],
    'fallbacks': <Map<String, Object?>>[
      for (final ReconPoint point in fallbacks) point.toJson(),
    ],
    'notes': <Map<String, Object?>>[
      for (final ReconPoint point in notes) point.toJson(),
    ],
    'flags': flags,
    'dropped_questions': droppedQuestions,
  };
}

List<ReconPoint> _pointsOf(Object? raw, {String textKey = 'text'}) {
  final List<Object?> list = raw is List ? raw : const <Object?>[];
  final List<ReconPoint> out = <ReconPoint>[];
  for (final Object? item in list) {
    if (item is Map) {
      final Map<String, Object?> map = plainMap(item);
      final String text = textOf(map[textKey]);
      if (text.isEmpty) continue;
      final String note = textOf(map['note']).isNotEmpty
          ? textOf(map['note'])
          : (<String>[
              textOf(map['landing']),
              textOf(map['why']),
              textOf(map['risk']),
            ].firstWhere((String value) => value.isNotEmpty, orElse: () => ''));
      out.add(ReconPoint(text: text, note: note));
    } else {
      final String text = textOf(item);
      if (text.isNotEmpty) out.add(ReconPoint(text: text));
    }
  }
  return out;
}

/// 解析模型的侦查 JSON；**行序即编号**，渲染时统一重排为 R1…/S1…/Q1…/F1…/N1…
///
/// 提问超过 [maxQuestions] 时截断并记入 [ReconDraft.droppedQuestions]
/// （调用方把这个数字回给 UI，让"被截断"可见）。
ReconDraft parseReconJson(
  Map<String, Object?> json, {
  required int maxQuestions,
}) {
  final List<ReconPoint> regular = _pointsOf(json['regular']);
  if (regular.isEmpty) {
    throw ProductionFailure(
      '侦查结果缺少「常规要求」（模型没给 regular 或全为空）',
      code: 'recon_empty',
    );
  }
  final List<ReconQuestionSpec> questions = <ReconQuestionSpec>[];
  final Object? rawQuestions = json['questions'];
  if (rawQuestions is List) {
    for (final Object? item in rawQuestions) {
      if (item is! Map) continue;
      final Map<String, Object?> map = plainMap(item);
      final String text = textOf(map['text']);
      if (text.isEmpty) continue;
      questions.add(
        ReconQuestionSpec(
          text: text,
          defaultValue: textOf(map['default']),
          recommended: textOf(map['recommended']),
          consequence: textOf(map['consequence']),
        ),
      );
    }
  }
  final int limit = clampQuestionLimit(maxQuestions);
  final int dropped = questions.length > limit ? questions.length - limit : 0;
  return ReconDraft(
    regular: regular,
    special: _pointsOf(json['special']),
    questions: questions.take(limit).toList(),
    fallbacks: _pointsOf(json['fallbacks']),
    notes: _pointsOf(json['notes']),
    flags: <String>[
      for (final String flag in stringsOf(json['flags']).take(8)) flag,
    ],
    droppedQuestions: dropped,
  );
}

/// 计算「本轮可以新提的问题」：
///
/// - 已有**未答**问题原样保留（原编号 / 原选项），不占新额度（§8.4 规则 6）；
/// - 模型重复提出的同一问题（正文与已有相同）不重复登记；
/// - 新问题按剩余额度（`limit - 未答数`）截断，被截断的数量回给调用方。
({List<ReconQuestionSpec> added, int dropped}) planNewQuestions({
  required List<ReconQuestionSpec> incoming,
  required List<QuestionState> existing,
  required int limit,
}) {
  final int open = openQuestionsOf(existing).length;
  final int budget = limit - open < 0 ? 0 : limit - open;
  final Set<String> seen = <String>{
    for (final QuestionState question in existing) question.text.trim(),
  };
  final List<ReconQuestionSpec> candidates = <ReconQuestionSpec>[];
  for (final ReconQuestionSpec question in incoming) {
    final String text = question.text.trim();
    if (text.isEmpty || !seen.add(text)) continue;
    candidates.add(question);
  }
  final List<ReconQuestionSpec> added = candidates.take(budget).toList();
  return (added: added, dropped: candidates.length - added.length);
}

/// 下一个问题编号（接在已有最大编号之后）。
String nextQuestionId(Iterable<String> existingIds) {
  int maxNumber = 0;
  for (final String id in existingIds) {
    final int number = int.tryParse(id.replaceFirst('Q', '')) ?? 0;
    if (number > maxNumber) maxNumber = number;
  }
  return 'Q${maxNumber + 1}';
}

// ── 范围与计划（§8.5）──────────────────────────────────────────────

/// 计划里的一个任务（`plan.md` 一行）。
class PlanTaskSpec {
  const PlanTaskSpec({
    required this.id,
    required this.title,
    required this.kind,
    required this.dependsOn,
    required this.readScope,
    required this.writeScope,
    required this.acceptance,
    required this.estimatedFiles,
  });

  final String id;
  final String title;
  final String kind;
  final List<String> dependsOn;
  final List<String> readScope;
  final List<String> writeScope;
  final List<String> acceptance;
  final int estimatedFiles;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'kind': kind,
    'depends_on': dependsOn,
    'read_scope': readScope,
    'write_scope': writeScope,
    'acceptance': acceptance,
    'estimated_files': estimatedFiles,
  };
}

/// 一次范围 / 计划拆解。
class ScopePlan {
  const ScopePlan({
    required this.inScope,
    required this.outOfScope,
    required this.notDoing,
    required this.tasks,
  });

  final List<String> inScope;
  final List<String> outOfScope;
  final List<String> notDoing;
  final List<PlanTaskSpec> tasks;

  Map<String, Object?> toJson() => <String, Object?>{
    'in': inScope,
    'out': outOfScope,
    'not_doing': notDoing,
    'tasks': <Map<String, Object?>>[
      for (final PlanTaskSpec task in tasks) task.toJson(),
    ],
  };
}

/// 解析模型的计划 JSON：
///
/// - `id` 缺失按行序补 `T1…`；不允许重复；
/// - `kind` 只认 `conventional` / `special`（非法回 `conventional`）；
/// - 每个任务**必须**有验收判据（没有 ⇒ `plan_incomplete`，不替他编）。
ScopePlan parseScopeJson(Map<String, Object?> json) {
  final List<Object?> rawTasks = json['tasks'] is List
      ? json['tasks'] as List<Object?>
      : const <Object?>[];
  if (rawTasks.isEmpty) {
    throw ProductionFailure('计划里没有任何任务（tasks 为空）', code: 'plan_empty');
  }
  final List<PlanTaskSpec> tasks = <PlanTaskSpec>[];
  final Set<String> ids = <String>{};
  int index = 0;
  for (final Object? item in rawTasks) {
    index += 1;
    if (item is! Map) continue;
    final Map<String, Object?> map = plainMap(item);
    final String title = textOf(map['title']);
    if (title.isEmpty) {
      throw ProductionFailure(
        '计划第 $index 个任务缺 title',
        code: 'plan_incomplete',
      );
    }
    String id = textOf(map['id']);
    if (id.isEmpty) id = 'T$index';
    if (!ids.add(id)) {
      throw ProductionFailure('计划任务 id 重复：$id', code: 'plan_incomplete');
    }
    final List<String> acceptance = stringsOf(map['acceptance']);
    if (acceptance.isEmpty) {
      throw ProductionFailure(
        '计划任务 $id 缺验收判据（acceptance）',
        code: 'plan_incomplete',
      );
    }
    final String kind = textOf(map['kind']) == 'special'
        ? 'special'
        : 'conventional';
    tasks.add(
      PlanTaskSpec(
        id: id,
        title: title,
        kind: kind,
        dependsOn: stringsOf(map['depends_on']),
        readScope: stringsOf(map['read_scope']),
        writeScope: stringsOf(map['write_scope']),
        acceptance: acceptance,
        estimatedFiles: intOf(map['estimated_files'], 1),
      ),
    );
  }
  if (tasks.isEmpty) {
    throw ProductionFailure('计划里没有任何有效任务', code: 'plan_empty');
  }
  return ScopePlan(
    inScope: stringsOf(json['in']),
    outOfScope: stringsOf(json['out']),
    notDoing: stringsOf(json['not_doing']),
    tasks: tasks,
  );
}

// ── 追问台账（inbox.jsonl 重放）────────────────────────────────────

/// 一条问题的当前状态（由 `inbox.jsonl` 的 question / answer 事件重放得到）。
class QuestionState {
  QuestionState({
    required this.taskId,
    required this.qid,
    required this.text,
    required this.defaultValue,
    required this.recommended,
    required this.consequence,
    required this.round,
    required this.windowId,
    required this.askedAt,
  });

  /// 所属准备任务（同一个 `decisions.md` 里可能有多条任务的 Q）。
  final String taskId;
  final String qid;
  final String text;
  final String defaultValue;
  final String recommended;
  final String consequence;
  final int round;
  final String windowId;
  final String askedAt;

  bool answered = false;
  String answer = '';
  String source = '';
  String answeredAt = '';

  Map<String, Object?> toJson() => <String, Object?>{
    'task_id': taskId,
    'qid': qid,
    'text': text,
    'default': defaultValue,
    'recommended': recommended,
    'consequence': consequence,
    'round': round,
    'window_id': windowId,
    'asked_at': askedAt,
    'status': answered ? 'answered' : 'open',
    'answer': answer,
    'source': source,
    'answered_at': answeredAt,
  };
}

/// 重放问题台账；[taskId] 非空时只取该任务。
///
/// 只认 `type=question|answer` 两类事件，其它（window 等）忽略；坏条目跳过，
/// 不让一行脏数据毁掉整份台账。
List<QuestionState> replayQuestions(
  List<Map<String, Object?>> inbox, {
  String taskId = '',
}) {
  final Map<String, QuestionState> byId = <String, QuestionState>{};
  for (final Map<String, Object?> entry in inbox) {
    if (taskId.isNotEmpty && textOf(entry['task_id']) != taskId) continue;
    final String type = textOf(entry['type']);
    final String qid = textOf(entry['qid']);
    final String owner = textOf(entry['task_id']);
    if (qid.isEmpty) continue;
    // 不同任务的编号都从 Q1 起：内部键必须带任务前缀，否则会串号。
    final String key = '$owner|$qid';
    if (type == 'question') {
      byId.putIfAbsent(
        key,
        () => QuestionState(
          taskId: owner,
          qid: qid,
          text: textOf(entry['text']),
          defaultValue: textOf(entry['default']),
          recommended: textOf(entry['recommended']),
          consequence: textOf(entry['consequence']),
          round: intOf(entry['round'], 1),
          windowId: textOf(entry['window_id']),
          askedAt: textOf(entry['asked_at']),
        ),
      );
    } else if (type == 'answer') {
      QuestionState? question = byId[key];
      if (question == null) {
        for (final QuestionState item in byId.values) {
          if (item.qid == qid) {
            question = item;
            break;
          }
        }
      }
      if (question == null) continue;
      question
        ..answered = true
        ..answer = textOf(entry['value'])
        ..source = textOf(entry['source'])
        ..answeredAt = textOf(entry['answered_at']);
    }
  }
  final List<QuestionState> out = byId.values.toList()
    ..sort((QuestionState a, QuestionState b) {
      final int byTask = a.taskId.compareTo(b.taskId);
      if (byTask != 0) return byTask;
      final int na = int.tryParse(a.qid.replaceFirst('Q', '')) ?? 0;
      final int nb = int.tryParse(b.qid.replaceFirst('Q', '')) ?? 0;
      return na.compareTo(nb);
    });
  return out;
}

/// 未答问题（含"回答为空"的也算未答）。
List<QuestionState> openQuestionsOf(List<QuestionState> questions) => <QuestionState>[
  for (final QuestionState question in questions)
    if (!question.answered || question.answer.trim().isEmpty) question,
];

// ── 读取预算（§8.1）────────────────────────────────────────────────

/// 点状读取预算：每会话文件 ≤ [maxFiles]、`grep` ≤ [maxGrepRounds] 轮。
class ReadBudget {
  ReadBudget({
    this.files = 0,
    this.grepRounds = 0,
    this.maxFiles = 8,
    this.maxGrepRounds = 2,
  });

  int files;
  int grepRounds;
  final int maxFiles;
  final int maxGrepRounds;

  bool get canReadFile => files < maxFiles;
  bool get canGrep => grepRounds < maxGrepRounds;

  Map<String, Object?> toJson() => <String, Object?>{
    'files': files,
    'grep_rounds': grepRounds,
    'max_files': maxFiles,
    'max_grep_rounds': maxGrepRounds,
  };
}

// ── 文档渲染（固定结构）─────────────────────────────────────────────

String _bullets(List<String> lines) =>
    lines.isEmpty ? '（无）' : lines.map((String line) => '- $line').join('\n');

/// `recon.md`：四节顺序固定（§8.3）；元信息块在前，标旗不单开一节。
String renderReconMd({
  required String taskId,
  required String title,
  required Map<String, String> intake,
  required ReconDraft recon,
  required List<QuestionState> questions,
}) {
  final StringBuffer buffer = StringBuffer()
    ..writeln('# 侦查 · $taskId $title')
    ..writeln()
    ..writeln('> 目标：${intake['goal'] ?? ''}')
    ..writeln('> 现状：${intake['current'] ?? ''}')
    ..writeln('> 验收：${intake['acceptance'] ?? ''}')
    ..writeln('> 禁区：${intake['forbidden'] ?? ''}')
    ..writeln('> 期限：${intake['deadline'] ?? ''}')
    ..writeln(
      '> 读取标旗（每会话 ≤ 8 文件）：'
      '${recon.flags.isEmpty ? '无需点状读取' : recon.flags.join('、')}',
    )
    ..writeln()
    ..writeln('## 1. 常规要求')
    ..writeln()
    ..writeln(
      recon.regular.isEmpty
          ? '（无）'
          : <String>[
              for (int i = 0; i < recon.regular.length; i++)
                '- **R${i + 1}** ${recon.regular[i].text}'
                    '${recon.regular[i].note.isEmpty ? '' : '（落点：${recon.regular[i].note}）'}',
            ].join('\n'),
    )
    ..writeln()
    ..writeln('## 2. 特殊要求')
    ..writeln()
    ..writeln(
      recon.special.isEmpty
          ? '（无）'
          : <String>[
              for (int i = 0; i < recon.special.length; i++)
                '- **S${i + 1}** ${recon.special[i].text}'
                    '${recon.special[i].note.isEmpty ? '' : '（为什么常规做不到：${recon.special[i].note}）'}',
            ].join('\n'),
    )
    ..writeln()
    ..writeln('## 3. 疑惑与待拍板')
    ..writeln()
    ..writeln(
      questions.isEmpty
          ? '（无——本轮无需拍板）'
          : <String>[
              for (final QuestionState question in questions)
                '- **${question.qid}** ${question.text}'
                    '（默认：${question.defaultValue.isEmpty ? '无' : question.defaultValue}；'
                    '推荐：${question.recommended.isEmpty ? '无' : question.recommended}；'
                    '不选后果：${question.consequence.isEmpty ? '未说明' : question.consequence}）',
            ].join('\n'),
    )
    ..writeln()
    ..writeln('## 4. 回退选项与注意事项')
    ..writeln()
    ..writeln(
      _bullets(<String>[
        for (int i = 0; i < recon.fallbacks.length; i++)
          '**F${i + 1}** ${recon.fallbacks[i].text}'
              '${recon.fallbacks[i].note.isEmpty ? '' : '（${recon.fallbacks[i].note}）'}',
        for (int i = 0; i < recon.notes.length; i++)
          '**N${i + 1}** ${recon.notes[i].text}'
              '${recon.notes[i].note.isEmpty ? '' : '（${recon.notes[i].note}）'}',
      ]),
    );
  return buffer.toString();
}

/// `scope.md`：in / out / 明确不做（out 也要写，防止越做越大）。
String renderScopeMd({required String taskId, required ScopePlan plan}) {
  final StringBuffer buffer = StringBuffer()
    ..writeln('# 范围 · $taskId')
    ..writeln()
    ..writeln('## 范围内')
    ..writeln()
    ..writeln(_bullets(plan.inScope))
    ..writeln()
    ..writeln('## 范围外')
    ..writeln()
    ..writeln(_bullets(plan.outOfScope))
    ..writeln()
    ..writeln('## 明确不做')
    ..writeln()
    ..writeln(_bullets(plan.notDoing));
  return buffer.toString();
}

/// `plan.md`：任务表 + 依赖关系（DAG 的文本形态）。
String renderPlanMd({
  required String lineName,
  required String taskId,
  required ScopePlan plan,
}) {
  final StringBuffer buffer = StringBuffer()
    ..writeln('# 计划 · ${lineName.isEmpty ? taskId : lineName}')
    ..writeln()
    ..writeln('| 任务 | 标题 | 类型 | 依赖 | 写域 | 预计文件 |')
    ..writeln('| --- | --- | --- | --- | --- | --- |');
  for (final PlanTaskSpec task in plan.tasks) {
    buffer.writeln(
      '| ${task.id} | ${task.title} | ${task.kind} | '
      '${task.dependsOn.isEmpty ? '—' : task.dependsOn.join(', ')} | '
      '${task.writeScope.isEmpty ? '—' : task.writeScope.join(', ')} | '
      '${task.estimatedFiles} |',
    );
  }
  buffer
    ..writeln()
    ..writeln('## 依赖关系')
    ..writeln();
  final List<String> edges = <String>[
    for (final PlanTaskSpec task in plan.tasks)
      for (final String dependency in task.dependsOn) '$dependency → ${task.id}',
  ];
  buffer.writeln(_bullets(edges));
  return buffer.toString();
}

/// `tasks/<task_id>/acceptance.md`：可勾选判据。
String renderAcceptanceMd({
  required String taskId,
  required String title,
  required List<String> acceptance,
}) {
  final StringBuffer buffer = StringBuffer()
    ..writeln('# 验收 · $taskId $title')
    ..writeln();
  for (final String line in acceptance) {
    buffer.writeln('- [ ] $line');
  }
  if (acceptance.isEmpty) buffer.writeln('（无判据——准备阶段不许落档）');
  return buffer.toString();
}

/// `decisions.md`：按窗口分组；未答问题保留为 `open`，并记录覆盖关系。
String renderDecisionsMd({
  required String lineName,
  required List<QuestionState> questions,
  required List<Map<String, Object?>> windows,
  required List<Map<String, Object?>> answers,
}) {
  final Map<String, List<QuestionState>> byWindow = <String, List<QuestionState>>{};
  for (final QuestionState question in questions) {
    final String key = question.windowId.isEmpty ? 'win_unknown' : question.windowId;
    (byWindow[key] ??= <QuestionState>[]).add(question);
  }
  final Map<String, Map<String, Object?>> windowById = <String, Map<String, Object?>>{
    for (final Map<String, Object?> window in windows)
      textOf(window['id']): window,
  };
  // 多条任务的 Q 都从 Q1 起：同一份文档里出现多个任务时加任务前缀，避免歧义。
  final bool multiTask = <String>{
    for (final QuestionState question in questions) question.taskId,
  }.length > 1;
  String label(QuestionState question) =>
      multiTask && question.taskId.isNotEmpty
      ? '${question.taskId}/${question.qid}'
      : question.qid;
  final StringBuffer buffer = StringBuffer()
    ..writeln('# 拍板记录 · ${lineName.isEmpty ? '生产线' : lineName}')
    ..writeln();
  final List<String> keys = byWindow.keys.toList();
  if (keys.isEmpty) buffer.writeln('（还没有待拍板问题）');
  for (final String key in keys) {
    final Map<String, Object?> window =
        windowById[key] ?? const <String, Object?>{};
    final int round = intOf(window['round'], 1);
    final String openedAt = textOf(window['opened_at']);
    buffer
      ..writeln(
        '## 窗口 $key（第 $round 轮${openedAt.isEmpty ? '' : '，$openedAt'}）',
      )
      ..writeln();
    for (final QuestionState question in byWindow[key]!) {
      if (question.answered) {
        buffer.writeln(
          '- **${label(question)}** ${question.text} → ✅ '
          '${question.source.isEmpty ? '用户回答' : question.source}：${question.answer}'
          '${question.answeredAt.isEmpty ? '' : '（${question.answeredAt}）'}',
        );
      } else {
        buffer.writeln(
          '- **${label(question)}** ${question.text} → ⏳ open'
          '（默认：${question.defaultValue.isEmpty ? '无' : question.defaultValue}；'
          '推荐：${question.recommended.isEmpty ? '无' : question.recommended}；'
          '不选后果：${question.consequence.isEmpty ? '未说明' : question.consequence}）',
        );
      }
    }
    buffer.writeln();
  }
  final List<Map<String, Object?>> overrides = <Map<String, Object?>>[
    for (final Map<String, Object?> answer in answers)
      if (textOf(answer['previous']).isNotEmpty) answer,
  ];
  if (overrides.isNotEmpty) {
    buffer
      ..writeln('## 变更（以最新回答为准）')
      ..writeln();
    for (final Map<String, Object?> answer in overrides) {
      buffer.writeln(
        '- ${textOf(answer['qid'])}：「${textOf(answer['previous'])}」→ '
        '「${textOf(answer['value'])}」'
        '${textOf(answer['answered_at']).isEmpty ? '' : '（${textOf(answer['answered_at'])}）'}',
      );
    }
  }
  return buffer.toString();
}

// ── 提示词（模型契约）──────────────────────────────────────────────

String reconSystemPrompt({required int maxQuestions}) =>
    '你是标准开发流的侦查员（只读文档，不读代码）。只输出一个 JSON 对象，不要 Markdown 代码围栏。'
    '结构：{"regular":[{"text","landing"}],"special":[{"text","why"}],'
    '"questions":[{"text","default","recommended","consequence"}],'
    '"fallbacks":[{"text"}],"notes":[{"text"}],"flags":["相对路径"]}。'
    '规则：regular 写成熟技术栈/既有实现能直接解决的要求，landing 写落点文件或目录；'
    'special 写传统方案做不到或代价异常的要求，why 必须写清为什么；'
    'questions 只问影响范围 / 不可逆 / 成本数量级，最多 $maxQuestions 条，每条给默认、推荐、不选后果；'
    'fallbacks 写特殊要求失败时走哪条常规路；notes 写风险 / 兼容 / 数据；'
    'flags 只列确有必要点状读取的代码文件（每会话 ≤ 8），没有就空数组。';

String reconUserPrompt({
  required String lineName,
  required String taskId,
  required String title,
  required Map<String, String> intake,
  required String memory,
  List<String> tools = const <String>[],
}) {
  final StringBuffer buffer = StringBuffer()
    ..writeln('产线：${lineName.isEmpty ? taskId : lineName}')
    ..writeln('任务：$taskId $title')
    ..writeln('目标：${intake['goal'] ?? ''}')
    ..writeln('现状：${intake['current'] ?? ''}')
    ..writeln('验收：${intake['acceptance'] ?? ''}')
    ..writeln('禁区：${intake['forbidden'] ?? ''}')
    ..writeln('期限：${intake['deadline'] ?? ''}')
    ..writeln();
  if (tools.isNotEmpty) {
    buffer
      ..writeln('主控可用工具：${tools.join(', ')}（规划落点必须落在这些能力内）')
      ..writeln();
  }
  buffer
    ..writeln('项目文档检索（docnorm.query 的结果，可能为空）：')
    ..writeln(memory.trim().isEmpty ? '（无）' : memory.trim())
    ..writeln()
    ..writeln('只做文档层侦查；不要读代码、不要跑构建、不要改文件。');
  return buffer.toString();
}

String scopeSystemPrompt() =>
    '你是标准开发流的拆解员。只输出一个 JSON 对象，不要 Markdown 代码围栏。'
    '结构：{"in":["…"],"out":["…"],"not_doing":["…"],"tasks":['
    '{"id","title","kind","depends_on","read_scope","write_scope","acceptance":["…"],"estimated_files"}]}。'
    '规则：in / out / not_doing 各写一句话（out 也要写，防止范围膨胀）；'
    '每个任务必须有可执行的验收判据（acceptance 非空）与写域（write_scope）；'
    'id 用 T1…Tn，depends_on 只能引用本清单里的 id；kind 只能是 conventional 或 special；'
    'write_scope 交叠的任务不要拆成可并行的两条。';

String scopeUserPrompt({
  required String taskId,
  required String title,
  required Map<String, String> intake,
  required String reconText,
  required String decisionsText,
}) =>
    '任务：$taskId $title\n'
    '目标：${intake['goal'] ?? ''}\n'
    '验收：${intake['acceptance'] ?? ''}\n'
    '禁区：${intake['forbidden'] ?? ''}\n'
    '期限：${intake['deadline'] ?? ''}\n\n'
    '侦查（已冻结）：\n$reconText\n\n'
    '拍板记录（没有 assumed，全部由用户回答）：\n$decisionsText\n\n'
    '请给出范围与任务拆分。';

/// 本窗口分发摘要（≤ 10 行，§8.6）。
List<String> distributionSummary({
  required List<PlanTaskSpec> tasks,
  required int openQuestions,
  required int questionLimit,
}) {
  final int special = tasks.where((PlanTaskSpec task) => task.kind == 'special').length;
  final int conventional = tasks.length - special;
  return <String>[
    '任务 ${tasks.length} 个（常规 $conventional / 特殊 $special）',
    '未答问题 $openQuestions 条（本轮上限 $questionLimit）',
    '预计门控：dart analyze；dart test（受影响包）；协议契约；涉及 UI 才跑 flutter',
  ];
}
