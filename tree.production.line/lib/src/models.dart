/// 产线 P1 的数据模型：状态机 + 任务 / 产线记录的薄包装。
///
/// 口径（docs/pluginization/production-line-recon.md §7.3）：
/// - `task.yaml` 是**唯一真值**，`state.json` 只是可由它重建的索引；
/// - `done` 只能由 `gating` 进入，`cancelled` 可从任意非终态进入且保留在列表里；
/// - `blocked` 必须带 `blocked_reason`。
library;

/// 产线插件的可读失败；`code` 直接进执行站回包，供 UI / 调用方分支。
///
/// [missing] 是门控拒绝时缺的项（依赖 id / 占用槽位的任务 / 预算原因等），
/// 与 `docs/pluginization/production-line-gates.md` §2 的 `{code,message,missing}`
/// 回包口径一致；不提供 force / skip 参数。
class ProductionFailure implements Exception {
  ProductionFailure(
    this.message, {
    this.code = 'production_error',
    this.missing = const <String>[],
  });

  final String message;
  final String code;
  final List<String> missing;

  @override
  String toString() => message;
}

/// 任务跑完 / 准备落档后触发一次主控 tick（插件层接事件驱动；单测注入记录器）。
typedef ProductionCycleTrigger =
    Future<void> Function(
      String lineId,
      Map<String, Object?> meta,
      Map<String, Object?> scope,
    );

/// 主控（执行期决策循环）的默认配置（D6-O §4.1）。
///
/// `line.yaml.orchestrator` 缺键即取这里的值；显式配置做浅合并，不批量改写旧文件。
const Map<String, Object?> kOrchestratorDefaults = <String, Object?>{
  'enabled': true,
  'tick_interval_seconds': 5,
  'auto_retry': true,
  'max_asks_per_task': 3,
  'stop_on_budget': true,
  'max_ticks_per_minute': 12,
};

/// `task.yaml.loop` 的默认值（D6-O §4.2）；缺键即取这里的值。
const Map<String, Object?> kTaskLoopDefaults = <String, Object?>{
  'attempts': 0,
  'ask_count': 0,
  'last_action': '',
  'last_decision_at': '',
  'stop_reason': '',
  'pending_question': '',
};

/// 任务类型（`task.yaml.task_type`）。
///
/// 旧任务没有这个键，读取时一律按 `code` 处理（不迁移、不报错）。
/// `cleanup` 是结构整理阶段的唯一放行类型（LG-01 / TG-06）。
const List<String> kTaskTypes = <String>[
  'code',
  'test',
  'docs',
  'spike',
  'integration',
  'chore',
  'cleanup',
];

/// 任务的有效类型：缺键 ⇒ `code`。
String taskTypeOf(Object? raw) {
  final String value = textOf(raw);
  return value.isEmpty ? 'code' : value;
}

/// 产线阶段（`line.yaml.phase`）：organizing → normalizing → indexing → ready。
///
/// 旧产线没有 `phase` 键，读取时按 `organizing` 处理；结构报告通过后
/// `production.structure.reevaluate` 会把它推进到 `normalizing`。
const List<String> kLinePhases = <String>[
  'organizing',
  'normalizing',
  'indexing',
  'ready',
];

/// 产线的有效阶段：缺键 / 空值 ⇒ `organizing`。
String linePhaseOf(Object? raw) {
  final String value = textOf(raw);
  return value.isEmpty ? 'organizing' : value;
}

/// 附件元数据种类（`task.yaml.attachments[].kind`）。
const List<String> kAttachmentKinds = <String>[
  'text',
  'image',
  'pdf',
  'office',
  'binary',
];

/// 任务风险等级（`task.yaml.risk`）。
const List<String> kTaskRisks = <String>['low', 'medium', 'high'];

final RegExp _sha256Pattern = RegExp(r'^[a-fA-F0-9]{64}$');
final RegExp _attachmentTypePattern =
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9.+-]*(/[A-Za-z0-9.+-]+)?$');

/// 安全的工作空间相对路径（拒绝绝对路径、盘符、`..` 与空段）。
bool isSafeRelativeTaskPath(String path) {
  final String value = path.trim().replaceAll('\\', '/');
  if (value.isEmpty) return false;
  if (value.startsWith('/')) return false;
  if (RegExp(r'^[A-Za-z]:').hasMatch(value)) return false;
  for (final String segment in value.split('/')) {
    if (segment.isEmpty || segment == '.' || segment == '..') return false;
  }
  return true;
}

/// 附件种类：显式 `kind` 优先，否则按 `type` 推断（只做确定性归类，不猜内容）。
String attachmentKindOf(String type, {String kind = ''}) {
  if (kind.isNotEmpty && kAttachmentKinds.contains(kind)) return kind;
  final String value = type.toLowerCase();
  if (value.startsWith('image/') ||
      const <String>{'png', 'jpg', 'jpeg', 'webp', 'gif'}.contains(value)) {
    return 'image';
  }
  if (value == 'pdf' || value == 'application/pdf') return 'pdf';
  if (value.contains('officedocument') ||
      value.contains('msword') ||
      value.contains('ms-excel') ||
      value.contains('ms-powerpoint') ||
      const <String>{
        'docx',
        'xlsx',
        'pptx',
        'doc',
        'xls',
        'ppt',
      }.contains(value)) {
    return 'office';
  }
  if (value.startsWith('text/') ||
      const <String>{
        'md',
        'markdown',
        'txt',
        'json',
        'yaml',
        'yml',
        'csv',
        'dart',
        'py',
        'ts',
        'js',
      }.contains(value)) {
    return 'text';
  }
  return 'binary';
}

/// 规范化并校验附件元数据（只登记，不读写附件文件；文件通道在 Task 6）。
///
/// 元数据固定包含 `path / sha256 / size / type / kind`；未知键（如 `name` /
/// `added_at`）原样保留，便于后续切片扩展。任一项不合法即 `attachment_invalid`。
List<Map<String, Object?>> normalizeAttachments(Object? raw) {
  if (raw == null) return const <Map<String, Object?>>[];
  if (raw is! List) {
    throw ProductionFailure(
      'attachments 必须是数组（[{path,sha256,size,type,kind}]）',
      code: 'attachment_invalid',
      missing: const <String>['attachments'],
    );
  }
  final List<Map<String, Object?>> out = <Map<String, Object?>>[];
  final Set<String> paths = <String>{};
  for (int i = 0; i < raw.length; i++) {
    final Object? item = raw[i];
    final String field = 'attachments[$i]';
    if (item is! Map) {
      throw ProductionFailure(
        '附件元数据必须是对象：$field',
        code: 'attachment_invalid',
        missing: <String>[field],
      );
    }
    final Map<String, Object?> map = plainMap(item);
    final String path = textOf(map['path']).replaceAll('\\', '/');
    final String sha256 = textOf(map['sha256']).toLowerCase();
    final Object? rawSize = map['size'];
    final int? size = rawSize is num
        ? rawSize.toInt()
        : int.tryParse(textOf(rawSize));
    final String type = textOf(map['type']);
    final String kind = textOf(map['kind']);
    String? problem;
    if (!isSafeRelativeTaskPath(path)) {
      problem = '附件 path 必须是工作空间相对路径（拒绝绝对路径 / ..）：$path';
    } else if (!_sha256Pattern.hasMatch(sha256)) {
      problem = '附件 sha256 必须是 64 位十六进制：$sha256';
    } else if (size == null || size < 0) {
      problem = '附件 size 必须是非负整数：${rawSize ?? ''}';
    } else if (type.isEmpty || !_attachmentTypePattern.hasMatch(type)) {
      problem = '附件 type 必须是扩展名或 MIME：$type';
    } else if (kind.isNotEmpty && !kAttachmentKinds.contains(kind)) {
      problem = '附件 kind 只能是 ${kAttachmentKinds.join(' / ')}：$kind';
    } else if (!paths.add(path)) {
      problem = '附件 path 重复：$path';
    }
    if (problem != null) {
      throw ProductionFailure(
        problem,
        code: 'attachment_invalid',
        missing: <String>[field],
      );
    }
    out.add(<String, Object?>{
      ...map,
      'path': path,
      'sha256': sha256,
      'size': size,
      'type': type,
      'kind': attachmentKindOf(type, kind: kind),
    });
  }
  return out;
}

/// 任务状态（`wire` 与 `task.yaml` 的 `status` 逐字一致）。
enum TaskStatus {
  draft('draft'),
  recon('recon'),
  aligning('aligning'),
  awaitingUser('awaiting_user'),
  scoped('scoped'),
  queued('queued'),
  packing('packing'),
  packed('packed'),
  running('running'),
  gating('gating'),
  done('done'),
  blocked('blocked'),
  cancelled('cancelled');

  const TaskStatus(this.wire);

  final String wire;

  /// 终态：不再接受任何迁移（`cancelled` 仍留在队列里可追溯）。
  bool get isTerminal => this == TaskStatus.done || this == TaskStatus.cancelled;

  /// 进程重启时视为“在途”的状态：恢复时一律回 `queued`。
  bool get isInFlight =>
      this == TaskStatus.packing ||
      this == TaskStatus.packed ||
      this == TaskStatus.running ||
      this == TaskStatus.gating;
}

/// 合法迁移表（§7.3）。
///
/// `gating → packed` 是门控失败后的重试回退；`packed → packing` 是重打包；
/// `blocked → awaiting_user | queued` 是等用户回答或依赖补全后回队列。
const Map<TaskStatus, Set<TaskStatus>> kTaskTransitions =
    <TaskStatus, Set<TaskStatus>>{
      TaskStatus.draft: <TaskStatus>{TaskStatus.recon, TaskStatus.cancelled},
      TaskStatus.recon: <TaskStatus>{TaskStatus.aligning, TaskStatus.cancelled},
      TaskStatus.aligning: <TaskStatus>{
        TaskStatus.awaitingUser,
        TaskStatus.scoped,
        TaskStatus.cancelled,
      },
      TaskStatus.awaitingUser: <TaskStatus>{
        TaskStatus.aligning,
        TaskStatus.cancelled,
      },
      TaskStatus.scoped: <TaskStatus>{TaskStatus.queued, TaskStatus.cancelled},
      TaskStatus.queued: <TaskStatus>{
        TaskStatus.packing,
        TaskStatus.blocked,
        TaskStatus.cancelled,
      },
      TaskStatus.packing: <TaskStatus>{
        TaskStatus.packed,
        TaskStatus.blocked,
        TaskStatus.cancelled,
      },
      TaskStatus.packed: <TaskStatus>{
        TaskStatus.running,
        TaskStatus.packing,
        TaskStatus.blocked,
        TaskStatus.cancelled,
      },
      TaskStatus.running: <TaskStatus>{
        TaskStatus.gating,
        TaskStatus.blocked,
        TaskStatus.cancelled,
      },
      TaskStatus.gating: <TaskStatus>{
        TaskStatus.done,
        TaskStatus.packed,
        TaskStatus.blocked,
        TaskStatus.cancelled,
      },
      TaskStatus.blocked: <TaskStatus>{
        TaskStatus.awaitingUser,
        TaskStatus.queued,
        TaskStatus.cancelled,
      },
      TaskStatus.done: <TaskStatus>{},
      TaskStatus.cancelled: <TaskStatus>{},
    };

/// 宽松读字符串并 trim（缺失 / null → 空串，**不猜默认值**）。
String textOf(Object? value) => (value ?? '').toString().trim();

/// 宽松读整数（数字或数字字符串；其它 → [fallback]）。
int intOf(Object? value, int fallback) {
  if (value is num) return value.toInt();
  return int.tryParse(textOf(value)) ?? fallback;
}

/// 宽松读字符串列表（非列表 / 空项直接丢掉）。
List<String> stringsOf(Object? value) {
  if (value is! List) return const <String>[];
  final List<String> out = <String>[];
  for (final Object? item in value) {
    final String text = textOf(item);
    if (text.isNotEmpty) out.add(text);
  }
  return out;
}

/// YAML 解出来的 `YamlMap` 不是 `Map<String, Object?>`，统一剥成普通 Map。
Map<String, Object?> plainMap(Object? value) {
  if (value is! Map) return <String, Object?>{};
  final Map<String, Object?> out = <String, Object?>{};
  for (final MapEntry<Object?, Object?> entry in value.entries) {
    out[textOf(entry.key)] = plainValue(entry.value);
  }
  return out;
}

/// 递归剥掉 `YamlMap` / `YamlList`，让结果能直接 `json.encode`。
Object? plainValue(Object? value) {
  if (value is Map) return plainMap(value);
  if (value is List) {
    return <Object?>[for (final Object? item in value) plainValue(item)];
  }
  return value;
}

TaskStatus? tryTaskStatus(Object? raw) {
  final String value = textOf(raw);
  for (final TaskStatus status in TaskStatus.values) {
    if (status.wire == value) return status;
  }
  return null;
}

/// 读状态；未知值给出可读错误（含允许值），不静默回退。
TaskStatus taskStatusOf(Object? raw) {
  final TaskStatus? status = tryTaskStatus(raw);
  if (status != null) return status;
  throw ProductionFailure(
    '未知任务状态「${textOf(raw)}」；允许：'
    '${TaskStatus.values.map((TaskStatus item) => item.wire).join(' / ')}',
    code: 'invalid_arguments',
  );
}

bool canTransition(TaskStatus from, TaskStatus to) =>
    kTaskTransitions[from]?.contains(to) ?? false;

Set<TaskStatus> allowedTransitions(TaskStatus from) =>
    kTaskTransitions[from] ?? const <TaskStatus>{};

/// 空写域 = 整个工作空间（D2 拍板）。
///
/// 用 `**` 表达：现有 [matchesWriteScope] / [writeScopesOverlap] 的 glob
/// 语义可直接覆盖“任意路径”，且与任何具体写域都判交叠 ⇒ 这类任务天然串行。
const List<String> kRootWriteScope = <String>['**'];

/// 任务的有效写域：配置为空时归一为工作空间根。
List<String> resolveWriteScope(Object? raw) {
  final List<String> scope = stringsOf(raw);
  return scope.isEmpty ? List<String>.of(kRootWriteScope) : scope;
}

/// `task.yaml` 的只读视图（保留原始键，未知键在写回时不丢）。
class TaskRecord {
  TaskRecord(this.data);

  final Map<String, Object?> data;

  String get id => textOf(data['id']);
  String get title => textOf(data['title']);
  String get kind => textOf(data['kind']).isEmpty ? 'conventional' : textOf(data['kind']);
  /// 任务类型（缺键 ⇒ `code`，旧任务兼容）。
  String get taskType => taskTypeOf(data['task_type']);
  /// 结构整理阶段的唯一放行类型。
  bool get isCleanup => taskType == 'cleanup';
  /// 出口门控（`task.yaml.gate`，当前只做透传；门控 runner 在后续切片）。
  Map<String, Object?> get gate => plainMap(data['gate']);

  /// 任务内容（Markdown）；旧任务缺键 ⇒ 空串。
  String get brief => textOf(data['brief']);
  /// `brief` 或准备阶段 `intake.goal` 是否非空（TG-01 判据）。
  bool get hasBrief =>
      brief.isNotEmpty || textOf(plainMap(data['intake'])['goal']).isNotEmpty;
  /// 工作空间内已有文件引用（不复制）。
  List<String> get references => stringsOf(data['references']);
  /// 附件元数据（只读输入；文件通道在 Task 6）。
  List<Map<String, Object?>> get attachments => <Map<String, Object?>>[
    for (final Object? item
        in (data['attachments'] is List
            ? data['attachments'] as List
            : const <Object?>[]))
      if (item is Map) plainMap(item),
  ];
  /// 软冲突：不能并行但不必有依赖。
  List<String> get conflictsWith => stringsOf(data['conflicts_with']);
  String get serialGroup => textOf(data['serial_group']);
  /// 拆分预算估算（旧任务缺键 ⇒ 1，与准备阶段口径一致）。
  int get estimatedFiles => intOf(data['estimated_files'], 1);
  /// `low / medium / high`；旧任务缺省为空。
  String get risk => textOf(data['risk']);
  /// 输入/输出/接口/不变量；允许字符串或对象。
  Object? get contract => plainValue(data['contract']);
  /// 为什么这样拆（引用理解卡 evidence_id）。
  String get rationale => textOf(data['rationale']);

  TaskStatus get status => taskStatusOf(data['status']);
  int get priority => intOf(data['priority'], 50);
  List<String> get dependsOn => stringsOf(data['depends_on']);
  /// 写域：并行判据（§9.6）与执行边界（§9.2）共用。
  List<String> get writeScope => stringsOf(data['write_scope']);
  /// 参考范围；`references` 会自动并入。
  List<String> get readScope => stringsOf(data['read_scope']);
  /// 有效写域：空 = 工作空间根（D2）。
  List<String> get effectiveWriteScope => resolveWriteScope(data['write_scope']);
  String get createdAt => textOf(data['created_at']);
  String get updatedAt => textOf(data['updated_at']);
  String get blockedReason => textOf(data['blocked_reason']);
  Map<String, Object?> get artifacts => plainMap(data['artifacts']);

  /// 主控循环游标（D6-O §4.2）；旧任务缺键时返回空表（读取方给默认值）。
  Map<String, Object?> get loop => plainMap(data['loop']);
  /// 主控重试次数（与门控 `gate_attempts` 分开计）。
  int get loopAttempts => intOf(loop['attempts'], 0);
  int get askCount => intOf(loop['ask_count'], 0);
  String get lastAction => textOf(loop['last_action']);
  String get pendingQuestion => textOf(loop['pending_question']);
  String get stopReason => textOf(loop['stop_reason']);

  Map<String, Object?> toJson() => plainMap(data);
}

/// `line.yaml` 的只读视图。
class LineRecord {
  LineRecord(this.data);

  final Map<String, Object?> data;

  String get id => textOf(data['id']);
  String get name => textOf(data['name']);
  String get workspaceDir => textOf(data['workspace_dir']);
  String get status => textOf(data['status']).isEmpty ? 'idle' : textOf(data['status']);
  /// 存储的阶段键（旧产线为空，读取方用 [effectivePhase]）。
  String get phase => linePhaseOf(data['phase']);
  /// 有效阶段：缺键 / 空值 ⇒ `organizing`（旧产线在结构报告通过前一律按整理中）。
  String get effectivePhase => linePhaseOf(data['phase']);
  String get createdAt => textOf(data['created_at']);

  /// 执行身份（§16）：产线与 Agent 并列，打包 / 执行 / 专家都用这条身份，
  /// 不再依赖「谁点了一下派发」。
  Map<String, Object?> get executor => plainMap(data['executor']);
  String get executorAgentId => textOf(executor['agent_id']);
  String get executorTeamId => textOf(executor['team_id']);

  /// 主控配置（`line.yaml.orchestrator`）；缺键时返回空表，读取方按默认值处理。
  Map<String, Object?> get orchestrator => plainMap(data['orchestrator']);

  Map<String, Object?> toJson() => plainMap(data);
}

/// 产线运行态投影（后端唯一口径，UI 不再自行推断）。
///
/// - `paused`：`line.yaml.status=paused`（人工暂停 / 连续失败暂停）优先；
/// - `working`：存在在途（packing / packed / running / gating）或 `queued` 任务；
/// - `idle`：其余。
///
/// 只读投影，不改 `line.yaml.status`，也不引入新的 wire 值。
String projectLineStatus(LineRecord line, Iterable<TaskRecord> tasks) {
  if (line.status == 'paused') return 'paused';
  for (final TaskRecord task in tasks) {
    if (task.status.isInFlight || task.status == TaskStatus.queued) {
      return 'working';
    }
  }
  return 'idle';
}

/// 新建产线的默认配置（§7.2）；调用方显式传入的段做浅合并。
Map<String, Object?> buildLineMap(
  Map<String, Object?> input, {
  required String id,
  required String now,
}) {
  const Set<String> statuses = <String>{'idle', 'working', 'paused'};
  final String status = textOf(input['status']).isEmpty
      ? 'idle'
      : textOf(input['status']);
  if (!statuses.contains(status)) {
    throw ProductionFailure(
      '产线 status 只能是 idle / working / paused：$status',
      code: 'invalid_arguments',
    );
  }
  final String phase = linePhaseOf(input['phase']);
  if (!kLinePhases.contains(phase)) {
    throw ProductionFailure(
      '产线 phase 只能是 ${kLinePhases.join(' / ')}：$phase',
      code: 'invalid_arguments',
    );
  }
  final Map<String, Object?> data = <String, Object?>{
    'id': id,
    'name': textOf(input['name']),
    'workspace_dir': textOf(input['workspace_dir']),
    'status': status,
    // L0 阶段：新产线一律从整理中开始；phase 只由后端结构判定推进，
    // 不接受调用方传 ready=true 之类的覆盖。
    'phase': 'organizing',
    'roles': <String, Object?>{
      'orchestrator': <String, Object?>{
        'model_id': '',
        'tools': <String>['read', 'grep', 'message'],
      },
      'packer': <String, Object?>{
        'model_id': '',
        'tools': <String>['read', 'list', 'grep', 'terminal', 'message'],
      },
      'executor': <String, Object?>{
        'model_id': '',
        'tools': <String>[
          'read',
          'write',
          'edit',
          'terminal',
          'message',
          'spec',
        ],
      },
      'expert': <String, Object?>{
        'model_id': '',
        'tools': <String>['read', 'grep'],
        // Q3 / §9.4：默认不能召专家，模型配置页勾选后才置 true。
        'enabled': false,
        'max_per_task': 3,
      },
    },
    'limits': <String, Object?>{
      'max_parallel_tasks': 1,
      'max_tokens_per_task': 0,
      'max_minutes_per_task': 0,
      'retries': 2,
      'max_questions_per_round': 3,
    },
    'policy': <String, Object?>{
      'allow_spawn': false,
      'allow_git_write': false,
      'deny_globs': <String>['.env', '**/*_key*', '**/id_rsa*'],
    },
    'docs': <String, Object?>{
      'asset_dir': 'docs/production_lines',
      'memory_manifest': <String>[
        'docs/project-status.md',
        'docs/work-log.md',
        'docs/known-issues.md',
        'docs/handover.md',
      ],
    },
    // §16：产线自己的执行身份（与「谁发起派发」无关）。
    'executor': <String, Object?>{
      'agent_id': '',
      'team_id': '',
    },
    // D6-O §4.1：执行期主控配置；缺省即默认（enabled=true / 5s tick）。
    'orchestrator': <String, Object?>{...kOrchestratorDefaults},
    'created_at': now,
    'updated_at': now,
  };
  final Map<String, Object?> executor = normalizeExecutor(input['executor']);
  if (executor.isNotEmpty) {
    data['executor'] = <String, Object?>{
      ...plainMap(data['executor']),
      ...executor,
    };
  }
  for (final String section in const <String>[
    'roles',
    'limits',
    'policy',
    'docs',
    'orchestrator',
  ]) {
    if (section == 'orchestrator') {
      final Map<String, Object?> override = normalizeOrchestrator(
        input['orchestrator'],
      );
      if (override.isEmpty) continue;
      data[section] = <String, Object?>{
        ...plainMap(data[section]),
        ...override,
      };
      continue;
    }
    final Map<String, Object?> override = plainMap(input[section]);
    if (override.isEmpty) continue;
    data[section] = <String, Object?>{
      ...plainMap(data[section]),
      ...override,
    };
  }
  return data;
}

/// 规范化 `line.yaml.executor`（§16）：只认 `agent_id` / `team_id` 两个字符串键。
///
/// 允许为空（新建产线时还没选执行 Agent），但**不接受未知键或非对象**——
/// 配置页写错键要当场报错，而不是静默存下一份不生效的配置。
Map<String, Object?> normalizeExecutor(Object? raw) {
  if (raw == null) return const <String, Object?>{};
  if (raw is! Map) {
    throw ProductionFailure(
      'executor 必须是对象：{agent_id, team_id}',
      code: 'invalid_arguments',
    );
  }
  final Map<String, Object?> data = plainMap(raw);
  final List<String> unknown = <String>[
    for (final String key in data.keys)
      if (key != 'agent_id' && key != 'team_id') key,
  ];
  if (unknown.isNotEmpty) {
    throw ProductionFailure(
      'executor 不支持这些键：${unknown.join('、')}（只认 agent_id / team_id）',
      code: 'invalid_arguments',
    );
  }
  return <String, Object?>{
    if (data.containsKey('agent_id')) 'agent_id': textOf(data['agent_id']),
    if (data.containsKey('team_id')) 'team_id': textOf(data['team_id']),
  };
}

/// 规范化 `line.yaml.orchestrator`（D6-O §4.1）：只接受对象，键保留做浅合并。
///
/// 不在这里校验取值范围：读配置时按默认值兜底（旧文件缺键 / 空值都能跑）。
Map<String, Object?> normalizeOrchestrator(Object? raw) {
  if (raw == null) return const <String, Object?>{};
  if (raw is! Map) {
    throw ProductionFailure(
      'orchestrator 必须是对象：{enabled, tick_interval_seconds, auto_retry, '
      'max_asks_per_task, stop_on_budget, max_ticks_per_minute}',
      code: 'invalid_arguments',
    );
  }
  return plainMap(raw);
}

/// 新建任务的最小校验（§7.3）：只允许以 `draft` / `queued` 落盘。
Map<String, Object?> buildTaskMap(
  Map<String, Object?> input, {
  required String id,
  required String now,
}) {
  final String title = textOf(input['title']);
  if (title.isEmpty) {
    throw ProductionFailure('任务缺 title', code: 'invalid_arguments');
  }
  final String kind = textOf(input['kind']).isEmpty
      ? 'conventional'
      : textOf(input['kind']);
  if (kind != 'conventional' && kind != 'special') {
    throw ProductionFailure(
      '任务 kind 只能是 conventional / special：$kind',
      code: 'invalid_arguments',
    );
  }
  final String rawStatus = textOf(input['status']);
  final TaskStatus status = rawStatus.isEmpty
      ? TaskStatus.draft
      : taskStatusOf(rawStatus);
  if (status != TaskStatus.draft && status != TaskStatus.queued) {
    throw ProductionFailure(
      '新建任务只能以 draft / queued 落盘（当前：${status.wire}）',
      code: 'invalid_arguments',
    );
  }
  final String taskType = taskTypeOf(input['task_type']);
  if (!kTaskTypes.contains(taskType)) {
    throw ProductionFailure(
      '任务 task_type 只能是 ${kTaskTypes.join(' / ')}：$taskType',
      code: 'invalid_arguments',
    );
  }
  // cleanup 是结构整理阶段唯一放行的任务：必须有写域与验收（回滚/门控
  // 在当前模型里作为可选键透传，完整门控 runner 在后续切片）。
  if (taskType == 'cleanup') {
    if (stringsOf(input['write_scope']).isEmpty) {
      throw ProductionFailure(
        'cleanup 任务必须显式给出 write_scope',
        code: 'invalid_arguments',
      );
    }
    if (stringsOf(input['acceptance']).isEmpty) {
      throw ProductionFailure(
        'cleanup 任务必须给出至少一条 acceptance',
        code: 'invalid_arguments',
      );
    }
  }
  final List<String> dependsOn = stringsOf(input['depends_on']);
  if (dependsOn.contains(id)) {
    throw ProductionFailure('任务不能依赖自己：$id', code: 'invalid_arguments');
  }
  final String brief = textOf(input['brief']);
  final List<String> references = stringsOf(input['references']);
  final List<Map<String, Object?>> attachments = normalizeAttachments(
    input['attachments'],
  );
  final List<String> conflictsWith = stringsOf(input['conflicts_with']);
  final String serialGroup = textOf(input['serial_group']);
  final String risk = textOf(input['risk']);
  final String rationale = textOf(input['rationale']);
  // `references` 自动并入 `read_scope`（产品形态 §6.0.1）。
  final List<String> readScope = <String>[...stringsOf(input['read_scope'])];
  for (final String reference in references) {
    if (!readScope.contains(reference)) readScope.add(reference);
  }
  return <String, Object?>{
    'id': id,
    'title': title,
    'kind': kind,
    'task_type': taskType,
    'status': status.wire,
    // 需求模板是任务的组成部分（准备阶段读取），随 task.yaml 落盘。
    if (plainMap(input['intake']).isNotEmpty) 'intake': plainMap(input['intake']),
    if (plainMap(input['gate']).isNotEmpty) 'gate': plainMap(input['gate']),
    if (brief.isNotEmpty) 'brief': brief,
    if (references.isNotEmpty) 'references': references,
    if (attachments.isNotEmpty) 'attachments': attachments,
    if (conflictsWith.isNotEmpty) 'conflicts_with': conflictsWith,
    if (serialGroup.isNotEmpty) 'serial_group': serialGroup,
    if (input.containsKey('estimated_files'))
      'estimated_files': intOf(input['estimated_files'], 1),
    if (risk.isNotEmpty) 'risk': risk,
    if (input.containsKey('contract') && input['contract'] != null)
      'contract': plainValue(input['contract']),
    if (rationale.isNotEmpty) 'rationale': rationale,
    'priority': intOf(input['priority'], 50),
    'depends_on': dependsOn,
    'write_scope': resolveWriteScope(input['write_scope']),
    'read_scope': readScope,
    'acceptance': stringsOf(input['acceptance']),
    'artifacts': plainMap(input['artifacts']),
    'created_at': now,
    'updated_at': now,
  };
}
