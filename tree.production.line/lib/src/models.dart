/// 产线 P1 的数据模型：状态机 + 任务 / 产线记录的薄包装。
///
/// 口径（docs/pluginization/production-line-recon.md §7.3）：
/// - `task.yaml` 是**唯一真值**，`state.json` 只是可由它重建的索引；
/// - `done` 只能由 `gating` 进入，`cancelled` 可从任意非终态进入且保留在列表里；
/// - `blocked` 必须带 `blocked_reason`。
library;

/// 产线插件的可读失败；`code` 直接进执行站回包，供 UI / 调用方分支。
class ProductionFailure implements Exception {
  ProductionFailure(this.message, {this.code = 'production_error'});

  final String message;
  final String code;

  @override
  String toString() => message;
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

/// `task.yaml` 的只读视图（保留原始键，未知键在写回时不丢）。
class TaskRecord {
  TaskRecord(this.data);

  final Map<String, Object?> data;

  String get id => textOf(data['id']);
  String get title => textOf(data['title']);
  String get kind => textOf(data['kind']).isEmpty ? 'conventional' : textOf(data['kind']);
  TaskStatus get status => taskStatusOf(data['status']);
  int get priority => intOf(data['priority'], 50);
  List<String> get dependsOn => stringsOf(data['depends_on']);
  String get createdAt => textOf(data['created_at']);
  String get updatedAt => textOf(data['updated_at']);
  String get blockedReason => textOf(data['blocked_reason']);
  Map<String, Object?> get artifacts => plainMap(data['artifacts']);

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
  String get createdAt => textOf(data['created_at']);

  Map<String, Object?> toJson() => plainMap(data);
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
  final Map<String, Object?> data = <String, Object?>{
    'id': id,
    'name': textOf(input['name']),
    'workspace_dir': textOf(input['workspace_dir']),
    'status': status,
    'roles': <String, Object?>{
      'orchestrator': <String, Object?>{
        'model_id': 'lfm3',
        'tools': <String>['read', 'grep', 'message'],
      },
      'packer': <String, Object?>{
        'model_id': 'lfm3',
        'tools': <String>['read', 'list', 'grep', 'terminal', 'message'],
      },
      'executor': <String, Object?>{
        'model_id': 'lfm3',
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
        'model_id': 'lfm3',
        'tools': <String>['read', 'grep'],
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
    'created_at': now,
    'updated_at': now,
  };
  for (final String section in const <String>[
    'roles',
    'limits',
    'policy',
    'docs',
  ]) {
    final Map<String, Object?> override = plainMap(input[section]);
    if (override.isEmpty) continue;
    data[section] = <String, Object?>{
      ...plainMap(data[section]),
      ...override,
    };
  }
  return data;
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
  final List<String> dependsOn = stringsOf(input['depends_on']);
  if (dependsOn.contains(id)) {
    throw ProductionFailure('任务不能依赖自己：$id', code: 'invalid_arguments');
  }
  return <String, Object?>{
    'id': id,
    'title': title,
    'kind': kind,
    'status': status.wire,
    'priority': intOf(input['priority'], 50),
    'depends_on': dependsOn,
    'write_scope': stringsOf(input['write_scope']),
    'read_scope': stringsOf(input['read_scope']),
    'acceptance': stringsOf(input['acceptance']),
    'artifacts': plainMap(input['artifacts']),
    'created_at': now,
    'updated_at': now,
  };
}
