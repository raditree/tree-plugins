/// 执行站命令门面：身份 / 数据根 fail-closed → 产线 / 任务 / 队列 / 台账。
library;

import 'dart:io';

import 'attachment_service.dart';
import 'drift_service.dart';
import 'models.dart';
import 'queue.dart';
import 'readiness.dart';
import 'stability.dart';
import 'store.dart';
import 'structure_service.dart';
import 'task_input.dart';

/// P1 对外开放的命令族（执行站 `production`）。
const List<String> kProductionCommands = <String>[
  'production.line.create',
  'production.line.list',
  'production.line.get',
  'production.line.migrate',
  'production.task.create',
  'production.task.update',
  'production.task.list',
  'production.task.get',
  'production.task.transition',
  'production.task.attach',
  'production.queue.next',
  'production.queue.plan',
  'production.queue.dispatch',
  'production.queue.rebuild',
  'production.queue.recover',
  'production.queue.reconcile',
  'production.run.list',
  'production.structure.get',
  'production.structure.reevaluate',
  'production.structure.waive',
  'production.drift.run',
  'production.drift.get',
  'production.stability.golden',
  'production.stability.metrics',
];

/// 一次站请求的落点：数据根（缺则 fail-closed）。
///
/// §16 起产线数据落全局作用域，`team_id` 只作为调用方身份透传（可空），
/// 不再决定数据目录。
class ProductionTarget {
  const ProductionTarget({required this.dataRoot, this.teamId = ''});

  final String dataRoot;
  final String teamId;
}

/// 解析站请求的落点；P1 与 P3 两条门面共用同一口径。
ProductionTarget resolveProductionTarget(
  Map<String, Object?> meta,
  Map<String, Object?> scope,
  Map<String, String> environment,
) {
  final String fromMeta = textOf(meta['data_dir']);
  final String dataRoot = fromMeta.isNotEmpty
      ? fromMeta
      : textOf(environment['TREE_DATA_ROOT']);
  if (dataRoot.isEmpty) {
    throw ProductionFailure(
      '缺少 data_dir（核心未在站请求的 meta 里带数据根，环境变量 TREE_DATA_ROOT 也未设置）',
      code: 'missing_data_dir',
    );
  }
  return ProductionTarget(dataRoot: dataRoot, teamId: textOf(scope['team_id']));
}

class ProductionService {
  ProductionService({
    Map<String, String>? environment,
    DateTime Function()? clock,
    this.onTaskState,
  }) : _environment = environment ?? Platform.environment,
       _clock = clock ?? DateTime.now;

  final Map<String, String> _environment;
  final DateTime Function() _clock;

  /// 任务状态变化的事件监听（Task 9.1；旁路，失败不影响业务）。
  final TaskStateListener? onTaskState;

  Map<String, Object?> handle(
    String command,
    Map<String, Object?> arguments,
    Map<String, Object?> meta,
    Map<String, Object?> scope,
  ) {
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
      case 'production.line.create':
        return <String, Object?>{'line': store.createLine(arguments).toJson()};
      case 'production.line.migrate':
        return store.migrateLegacy(
          agentId: textOf(arguments['agent_id']),
          teamId: textOf(arguments['team_id']),
          dryRun: arguments['dry_run'] == true,
        );
      case 'production.line.list':
        {
          final List<LineRecord> lines = store.listLines();
          return <String, Object?>{
            'lines': <Map<String, Object?>>[
              for (final LineRecord line in lines) _lineJson(store, line),
            ],
            'count': lines.length,
          };
        }
      case 'production.line.get':
        {
          final LineRecord line = store.getLine(
            _argument(arguments, 'line_id'),
          );
          return <String, Object?>{'line': _lineJson(store, line)};
        }
      case 'production.task.create':
        {
          final String lineId = _argument(arguments, 'line_id');
          final Map<String, Object?> input = arguments['task'] is Map
              ? plainMap(arguments['task'])
              : (<String, Object?>{...arguments}..remove('line_id'));
          // LG-01 / TG-06：organizing 阶段只有 cleanup 任务可以落盘。
          final LineRecord line = store.getLine(lineId);
          final String taskType = taskTypeOf(input['task_type']);
          requireStructureReady(store, line, taskType: taskType);
          // LG-07 / TG-05：文档归一化与索引未就绪前，除 organizing 的 cleanup
          // 外一律拒绝（`409 line_not_ready`，带 missing[]）。
          requireLineReady(store, line, taskType: taskType);
          // TG-01 / AG-05：创建前预检（内容/验收、附件元数据、依赖、写域、
          // 文档边界）。旧任务读取不经过这里，保持兼容。
          final TaskStatus createStatus = textOf(input['status']).isEmpty
              ? TaskStatus.draft
              : taskStatusOf(input['status']);
          final TaskInputCheck inputCheck = checkTaskInputMap(
            input,
            statuses: <String, TaskStatus>{
              for (final TaskRecord item in store.listTasks(lineId))
                item.id: item.status,
            },
            requireContent: createStatus == TaskStatus.queued,
            selfId: textOf(input['id']),
          );
          if (!inputCheck.ok) throw inputCheck.toFailure();
          return <String, Object?>{
            'task': store.createTask(lineId, input).toJson(),
          };
        }
      case 'production.task.update':
        {
          final String lineId = _argument(arguments, 'line_id');
          final String taskId = _argument(arguments, 'task_id');
          final Map<String, Object?> patch = arguments['patch'] is Map
              ? plainMap(arguments['patch'])
              : (<String, Object?>{...arguments}
                  ..remove('line_id')
                  ..remove('task_id'));
          return _updateTask(store, lineId, taskId, patch);
        }
      case 'production.task.list':
        {
          final String lineId = _argument(arguments, 'line_id');
          List<TaskRecord> tasks = store.listTasks(lineId);
          final String statusFilter = textOf(arguments['status']);
          if (statusFilter.isNotEmpty) {
            final TaskStatus wanted = taskStatusOf(statusFilter);
            tasks = <TaskRecord>[
              for (final TaskRecord task in tasks)
                if (task.status == wanted) task,
            ];
          }
          return <String, Object?>{
            'tasks': <Map<String, Object?>>[
              for (final TaskRecord task in tasks) task.toJson(),
            ],
            'count': tasks.length,
          };
        }
      case 'production.task.get':
        {
          final String lineId = _argument(arguments, 'line_id');
          final String taskId = _argument(arguments, 'task_id');
          return <String, Object?>{
            'task': store.getTask(lineId, taskId).toJson(),
          };
        }
      case 'production.task.transition':
        {
          final String lineId = _argument(arguments, 'line_id');
          final String taskId = _argument(arguments, 'task_id');
          final String to = _argument(arguments, 'to');
          _requireGateForDone(store, lineId, taskId, to);
          return store.transition(
            lineId,
            taskId,
            to: to,
            reason: textOf(arguments['reason']),
          );
        }
      case 'production.task.attach':
        return ProductionAttachmentService().attach(store, arguments);
      case 'production.queue.next':
        return store.next(
          _argument(arguments, 'line_id'),
          limit: intOf(arguments['limit'], 1),
        );
      case 'production.queue.plan':
        return _queuePlan(
          store,
          _argument(arguments, 'line_id'),
          limit: intOf(arguments['limit'], 0),
        );
      case 'production.queue.dispatch':
        {
          final String lineId = _argument(arguments, 'line_id');
          final LineRecord line = store.getLine(lineId);
          // 结构未通过时只允许 cleanup 任务进入派发计划。
          final List<TaskRecord> tasks = store.listTasks(lineId);
          requireStructureAllowsTasks(store, line, tasks);
          // LG-07 / TG-05：归一化与索引就绪前不得派发非 cleanup 任务。
          requireLineAllowsTasks(store, line, tasks);
          return store.dispatch(lineId, limit: intOf(arguments['limit'], 0));
        }
      case 'production.queue.rebuild':
        return store.rebuild(_argument(arguments, 'line_id'));
      case 'production.queue.recover':
        return store.recover(_argument(arguments, 'line_id'));
      case 'production.queue.reconcile':
        return store.reconcile(_argument(arguments, 'line_id'));
      case 'production.stability.golden':
        {
          final String lineId = textOf(arguments['line_id']);
          if (lineId.isNotEmpty) store.getLine(lineId);
          return goldenTaskReport(
            modelId: _argument(arguments, 'model_id'),
            gate: plainMap(arguments['gate']),
            ok: arguments['ok'] != false,
            result: plainMap(arguments['result']),
          );
        }
      case 'production.stability.metrics':
        return sloMetrics(store, _argument(arguments, 'line_id'));
      case 'production.structure.get':
      case 'production.structure.reevaluate':
      case 'production.structure.waive':
        return handleStructureCommand(store, command, arguments);
      case 'production.drift.run':
        return ProductionDriftService(clock: _clock).run(store, arguments);
      case 'production.drift.get':
        return ProductionDriftService(clock: _clock).get(store, arguments);
      case 'production.run.list':
        {
          final String lineId = _argument(arguments, 'line_id');
          store.getLine(lineId);
          final List<Map<String, Object?>> runs = store.listRuns(
            lineId,
            taskId: textOf(arguments['task_id']),
          );
          return <String, Object?>{'runs': runs, 'count': runs.length};
        }
      default:
        throw ProductionFailure('未知产线命令：$command', code: 'unknown_command');
    }
  }

  /// 编辑任务（`production.task.update`）：白名单 + 状态边界 + 输入预检。
  ///
  /// 状态边界（产品形态 §6.0.7）：
  /// - `done / cancelled`：拒绝（`terminal_state`）；
  /// - `packing / running / gating`：只能改 `priority / depends_on`；
  /// - `packed`：可改，保存后回到 `queued` 并删除旧 `pack.json`；
  /// - 其余非终态：可改，按本次改动字段做输入预检。
  Map<String, Object?> _updateTask(
    ProductionStore store,
    String lineId,
    String taskId,
    Map<String, Object?> patch,
  ) {
    if (patch.isEmpty) {
      throw ProductionFailure(
        '没有可改字段（允许：${kTaskEditFields.join(' / ')}）',
        code: 'invalid_arguments',
      );
    }
    final List<String> unknown = <String>[
      for (final String key in patch.keys)
        if (!kTaskEditFields.contains(key)) key,
    ]..sort();
    if (unknown.isNotEmpty) {
      throw ProductionFailure(
        '任务不支持改这些键：${unknown.join('、')}（允许：${kTaskEditFields.join(' / ')}）',
        code: 'invalid_arguments',
        missing: unknown,
      );
    }
    final TaskRecord task = store.getTask(lineId, taskId);
    final TaskStatus from = task.status;
    if (from.isTerminal) {
      throw ProductionFailure(
        '任务已处于终态 ${from.wire}，不可再编辑',
        code: 'terminal_state',
      );
    }
    final bool inFlight =
        from == TaskStatus.packing ||
        from == TaskStatus.running ||
        from == TaskStatus.gating;
    if (inFlight) {
      final List<String> forbidden = <String>[
        for (final String key in patch.keys)
          if (!kInFlightEditFields.contains(key)) key,
      ]..sort();
      if (forbidden.isNotEmpty) {
        throw ProductionFailure(
          '任务 ${from.wire} 时只能改 priority / depends_on；'
          '这些字段要等任务结束：${forbidden.join('、')}',
          code: 'task_edit_forbidden',
          missing: forbidden,
        );
      }
    }
    // packed 编辑 ⇒ 旧包失效，任务回 queued（不静默复用旧包）。
    final TaskStatus to = from == TaskStatus.packed ? TaskStatus.queued : from;
    final TaskInputCheck check = checkTaskInputMap(
      <String, Object?>{...task.data, ...patch},
      statuses: <String, TaskStatus>{
        for (final TaskRecord item in store.listTasks(lineId))
          item.id: item.status,
      },
      requireContent: to == TaskStatus.queued,
      selfId: taskId,
      fields: patch.keys.toSet(),
    );
    if (!check.ok) throw check.toFailure();
    final Map<String, Object?> normalized = normalizeTaskEdit(patch);
    if (normalized.containsKey('references') ||
        normalized.containsKey('read_scope')) {
      final List<String> references = normalized.containsKey('references')
          ? stringsOf(normalized['references'])
          : task.references;
      final List<String> readScope = normalized.containsKey('read_scope')
          ? stringsOf(normalized['read_scope'])
          : task.readScope;
      normalized['read_scope'] = mergeReadScope(readScope, references);
    }
    if (to != from) normalized['status'] = to.wire;
    final TaskRecord saved = store.updateTask(lineId, taskId, normalized);
    final bool packInvalidated = from == TaskStatus.packed
        ? store.deletePack(lineId, taskId)
        : false;
    final List<String> changed = patch.keys.toList()..sort();
    return <String, Object?>{
      'task': saved.toJson(),
      'from': from.wire,
      'to': saved.status.wire,
      'changed': changed,
      if (packInvalidated) 'pack_invalidated': true,
      if (from == TaskStatus.packed) 'note': '已回到 queued：旧打包结果失效，需要重新打包',
    };
  }

  /// 队列派发计划（只读）：依赖 / 写域 / 槽位 + 结构/就绪门 + 输入预检。
  ///
  /// 不写盘、不改状态；拒绝以 `skipped[].reason` 返回，不提供 force / skip。
  Map<String, Object?> _queuePlan(
    ProductionStore store,
    String lineId, {
    int limit = 0,
  }) {
    final LineRecord line = store.getLine(lineId);
    final List<TaskRecord> tasks = store.listTasks(lineId);
    final Map<String, TaskStatus> statuses = <String, TaskStatus>{
      for (final TaskRecord task in tasks) task.id: task.status,
    };
    final Map<String, Object?> limits = plainMap(line.data['limits']);
    final int maxParallel = intOf(limits['max_parallel_tasks'], 1);

    StructureStatus? structure;
    List<String> structureMissing = const <String>[];
    try {
      structure = structureStatusOf(store, lineId);
    } on ProductionFailure catch (error) {
      structureMissing = error.missing;
    }
    final bool structureReady = structure?.ready ?? false;
    LineReadinessSnapshot? readiness;
    try {
      readiness = readLineReadiness(store, lineId);
    } on ProductionFailure {
      // 读不到快照 ⇒ 按未就绪处理（fail-closed）。
    }
    final bool lineReady = readiness?.ready ?? false;
    final List<String> readinessMissing =
        readiness?.missing ?? const <String>['line_ready_snapshot'];
    final bool cleanupExempt =
        line.effectivePhase == 'organizing' || !structureReady;

    final List<TaskRecord> eligible = <TaskRecord>[];
    final List<Map<String, Object?>> skipped = <Map<String, Object?>>[];
    for (final TaskRecord task in tasks) {
      if (task.status != TaskStatus.queued) {
        // 非 queued 任务只作为依赖状态 / 在途占位参与 planDispatch。
        eligible.add(task);
        continue;
      }
      if (!task.isCleanup && !structureReady) {
        skipped.add(<String, Object?>{
          'id': task.id,
          'reason': 'structure_not_ready',
          'missing': structureMissing.isEmpty
              ? const <String>['LG-01']
              : structureMissing,
        });
        continue;
      }
      final bool lineAllowed = lineReady || (task.isCleanup && cleanupExempt);
      if (!lineAllowed) {
        skipped.add(<String, Object?>{
          'id': task.id,
          'reason': 'line_not_ready',
          'missing': readinessMissing,
        });
        continue;
      }
      final TaskInputCheck check = checkTaskInputMap(
        task.data,
        statuses: statuses,
        requireContent: true,
        selfId: task.id,
      );
      if (!check.ok) {
        skipped.add(<String, Object?>{
          'id': task.id,
          'reason': check.code,
          'missing': check.missing,
          'issues': check.toJson(),
        });
        continue;
      }
      eligible.add(task);
    }

    final DispatchPlan plan = planDispatch(eligible, maxParallel: maxParallel);
    final List<TaskRecord> batch = limit > 0 && limit < plan.batch.length
        ? plan.batch.take(limit).toList()
        : plan.batch;
    final List<Map<String, Object?>> mergedSkipped = <Map<String, Object?>>[
      ...skipped,
      ...plan.skipped,
      if (limit > 0 && limit < plan.batch.length)
        for (final TaskRecord task in plan.batch.skip(limit))
          <String, Object?>{'id': task.id, 'reason': 'limit', 'limit': limit},
    ];
    return <String, Object?>{
      'line_id': lineId,
      'phase': line.effectivePhase,
      'structure_ready': structureReady,
      'line_ready': lineReady,
      'max_parallel_tasks': plan.maxParallel,
      'slots_used': plan.slotsUsed,
      'slots_free': plan.slotsFree,
      'batch': <Map<String, Object?>>[
        for (final TaskRecord task in batch) task.toJson(),
      ],
      'batch_ids': <String>[for (final TaskRecord task in batch) task.id],
      'running': <String>[for (final TaskRecord task in plan.running) task.id],
      'skipped': mergedSkipped,
      'count': batch.length,
    };
  }

  /// 产线 JSON + 后端投影的 `status`（idle / working / paused，wire 值不变）。
  /// `phase` 缺键时投影为 `organizing`（旧产线在结构报告通过前一律整理中）；
  /// `ready` 是复合就绪门（LG-07）的只读投影，UI 不能覆盖。
  Map<String, Object?> _lineJson(ProductionStore store, LineRecord line) =>
      <String, Object?>{
        ...line.toJson(),
        'phase': line.effectivePhase,
        'status': projectLineStatus(line, store.listTasks(line.id)),
        'ready': isLineReady(store, line),
      };

  /// SG-04：有 `plan_version` 的任务转 `done` 必须有独立 runner 的通过门控。
  ///
  /// 旧任务没有 `plan_version`，保持兼容（不检查）。执行阶段自己写 gate.json 后
  /// 直接迁移，不走这里；这里只拦外部直接 `production.task.transition`。
  void _requireGateForDone(
    ProductionStore store,
    String lineId,
    String taskId,
    String to,
  ) {
    if (to != TaskStatus.done.wire) return;
    final TaskRecord task = store.getTask(lineId, taskId);
    if (textOf(task.data['plan_version']).isEmpty) return;
    final String runId = textOf(task.data['last_run_id']);
    final Map<String, Object?> gate = store.readGate(lineId, taskId, runId);
    if (gate.isEmpty || gate['ok'] != true) {
      throw ProductionFailure(
        '任务 $taskId 转 done 需要独立门控 runner 的通过结果'
        '（tasks/$taskId/gates/${runId.isEmpty ? '<run_id>' : runId}/gate.json）：'
        '先跑 production.gate.run 或 production.task.run',
        code: 'gate_missing',
        missing: <String>[taskId],
      );
    }
  }

  String _argument(Map<String, Object?> arguments, String key) {
    final String value = textOf(arguments[key]);
    if (value.isEmpty) {
      throw ProductionFailure('缺少 $key', code: 'invalid_arguments');
    }
    return value;
  }
}
