/// 执行期主控服务（D6-O O3）：一次 tick = 一个短事务。
///
/// 口径（docs/pluginization/production-line-orchestrator-loop-plan.md §5.4 / §6）：
/// - 读一条产线 → 让主控做一个动作 → 落盘 → 返回；**不等**打包 / 执行跑完；
/// - 单线单 tick（进程内锁）：已有 tick 在跑时新触发直接丢弃；
/// - 决策先写 `runs`（`applied=false`）→ 应用副作用 → 回填 `applied`；
/// - 连续 3 次失败 ⇒ `line.status=paused`，等人工恢复。
///
/// 模型与工具仍取 `roles.orchestrator`；决策走显式 `model_id` 的 `llm.call`。
library;

import 'dart:async';

import 'execution_service.dart';
import 'models.dart';
import 'orchestrator.dart';
import 'preparation.dart';
import 'readiness.dart';
import 'service.dart';
import 'store.dart';
import 'structure_service.dart';

/// 主控决策的模型调用（插件层接 `llm.call`；单测注入假实现）。
typedef OrchestratorLlm =
    Future<Map<String, Object?>> Function(
      String point,
      String system,
      String prompt,
      Map<String, Object?> scope,
      String modelId,
    );

/// 决策落地后的派发入口（插件层接后台打包 / 执行；单测注入记录器）。
typedef OrchestratorDispatcher =
    Future<void> Function(
      String lineId,
      String taskId,
      String stage,
      Map<String, Object?> meta,
      Map<String, Object?> scope,
    );

/// 对外开放的命令族（与 P1 / P3 / P4 共用执行站 `production`）。
const List<String> kOrchestratorCommands = <String>[
  'production.orchestrator.tick',
  'production.orchestrator.status',
];

/// 连续失败到这个次数就暂停整条产线（§5.2）。
const int kOrchestratorFailureLimit = 3;

class OrchestratorService {
  OrchestratorService({
    Map<String, String>? environment,
    DateTime Function()? clock,
    this.llm,
    this.dispatcher,
    this.execution,
  }) : _environment = environment ?? const <String, String>{},
       _clock = clock ?? DateTime.now;

  final Map<String, String> _environment;
  final DateTime Function() _clock;
  final OrchestratorLlm? llm;
  final OrchestratorDispatcher? dispatcher;
  final ProductionExecutionService? execution;

  /// 单线单 tick：同一条产线同时最多一个 tick（新触发直接丢弃）。
  final Map<String, Future<Map<String, Object?>>> _inFlight =
      <String, Future<Map<String, Object?>>>{};

  /// 每分钟 tick 时间戳（防模型空转）。
  final Map<String, List<DateTime>> _tickTimes = <String, List<DateTime>>{};

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
    );
    switch (command) {
      case 'production.orchestrator.tick':
        return tick(
          store,
          _arg(arguments, 'line_id'),
          meta: meta,
          scope: scope,
          trigger: textOf(arguments['trigger']).isEmpty
              ? 'manual'
              : textOf(arguments['trigger']),
        );
      case 'production.orchestrator.status':
        return status(store, _arg(arguments, 'line_id'));
      default:
        throw ProductionFailure('未知主控命令：$command', code: 'unknown_command');
    }
  }

  /// 手动 / 事件 / 定时 / 恢复共用的入口（幂等）。
  Future<Map<String, Object?>> tick(
    ProductionStore store,
    String lineId, {
    required Map<String, Object?> meta,
    required Map<String, Object?> scope,
    String trigger = 'manual',
  }) async {
    final LineRecord line = store.getLine(lineId);
    final OrchestratorConfig config = OrchestratorConfig.of(line);
    if (!config.enabled) {
      return _skipped(lineId, 'disabled', trigger);
    }
    if (line.status == 'paused') {
      return _skipped(lineId, 'line_paused', trigger);
    }
    final List<TaskRecord> tasks = store.listTasks(lineId);
    if (tasks.isEmpty) return _skipped(lineId, 'no_tasks', trigger);
    // LG-01 / TG-06：organizing 阶段只有 cleanup 任务可以推进（tick 也过门）。
    requireStructureAllowsTasks(store, line, tasks);
    // LG-07 / TG-05：归一化与索引未就绪前不得推进非 cleanup 任务。
    requireLineAllowsTasks(store, line, tasks);
    if (trigger == 'timer' && !_hasAdvanceableTask(tasks)) {
      // 定时兜底：只有在**确实没活可干**时才跳过（§3.1 / §5.4）；
      // queued / packed / blocked 等可推进任务照样交给主控决策。
      return _skipped(lineId, 'idle', trigger);
    }
    final Future<Map<String, Object?>>? running = _inFlight[lineId];
    if (running != null) {
      return _skipped(lineId, 'tick_in_flight', trigger);
    }
    if (_rateLimited(lineId, config)) {
      return _skipped(lineId, 'rate_limited', trigger);
    }
    _tickTimes.putIfAbsent(lineId, () => <DateTime>[]).add(_clock());
    final Future<Map<String, Object?>> job = _runTick(
      store,
      line,
      tasks,
      meta: meta,
      scope: scope,
      trigger: trigger,
      config: config,
    );
    _inFlight[lineId] = job;
    try {
      return await job;
    } finally {
      _inFlight.remove(lineId);
    }
  }

  Future<Map<String, Object?>> _runTick(
    ProductionStore store,
    LineRecord line,
    List<TaskRecord> tasks, {
    required Map<String, Object?> meta,
    required Map<String, Object?> scope,
    required String trigger,
    required OrchestratorConfig config,
  }) async {
    final String lineId = line.id;
    final Map<String, Object?> state = store.readOrchestratorState(lineId);
    final Map<String, Object?> lastDecision = plainMap(state['last_decision']);
    final OrchestratorSnapshot snapshot = buildOrchestratorSnapshot(
      line: line,
      tasks: tasks,
      runs: store.listRuns(lineId),
      inbox: store.readInbox(lineId),
      lastDecision: lastDecision,
    );
    if (trigger != 'manual' &&
        snapshot.hash == textOf(state['last_snapshot_hash'])) {
      return _skipped(lineId, 'unchanged', trigger);
    }
    final String modelId = textOf(
      plainMap(plainMap(line.data['roles'])['orchestrator'])['model_id'],
    );
    final String runId =
        'run_orch_${lineId}_${_clock().millisecondsSinceEpoch}';
    final String startedAt = _now;
    final int startedMs = _clock().millisecondsSinceEpoch;

    Map<String, Object?> raw;
    try {
      if (llm == null) {
        throw ProductionFailure(
          '主控决策需要 llm.call 通道，当前未接线',
          code: 'llm_unavailable',
        );
      }
      if (modelId.isEmpty) {
        throw ProductionFailure(
          '产线没有给主控配模型（line.yaml.roles.orchestrator.model_id）',
          code: 'model_required',
        );
      }
      raw = await llm!(
        'production.orchestrator.tick',
        orchestratorSystemPrompt(
          config: config,
          limits: plainMap(line.data['limits']),
        ),
        orchestratorUserPrompt(snapshot),
        scope,
        modelId,
      );
    } catch (error) {
      return _fail(
        store,
        lineId,
        state: state,
        runId: runId,
        startedAt: startedAt,
        elapsedMs: _clock().millisecondsSinceEpoch - startedMs,
        modelId: modelId,
        error: '$error',
      );
    }

    final OrchestratorDecision decision;
    try {
      decision = parseOrchestratorDecision(
        raw,
        taskIds: <String>{for (final TaskRecord task in tasks) task.id},
      );
    } on ProductionFailure catch (error) {
      return _fail(
        store,
        lineId,
        state: state,
        runId: runId,
        startedAt: startedAt,
        elapsedMs: _clock().millisecondsSinceEpoch - startedMs,
        modelId: modelId,
        error: error.message,
      );
    }

    final OrchestratorDecision guarded = guardOrchestratorDecision(
      decision,
      config: config,
      line: line,
      tasks: tasks,
      budgetExceeded: snapshot.budgetExceeded,
    );
    final int elapsedMs = _clock().millisecondsSinceEpoch - startedMs;
    final Map<String, Object?> usage = plainMap(raw['_usage']);
    Map<String, Object?> run = _runMap(
      runId: runId,
      modelId: modelId,
      startedAt: startedAt,
      elapsedMs: elapsedMs,
      decision: guarded,
      snapshotHash: snapshot.hash,
      usage: usage,
      status: guarded.applied ? 'ok' : 'guarded',
      error: '',
    );
    // §6.2：先落“已决策未执行”，再应用副作用，最后回填 applied。
    store.writeRun(lineId, run);

    final List<String> applied = <String>[];
    try {
      applied.addAll(
        await _apply(
          store,
          lineId,
          guarded,
          tasks,
          meta: meta,
          scope: scope,
          snapshot: snapshot,
        ),
      );
    } on ProductionFailure catch (error) {
      run = <String, Object?>{
        ...run,
        'status': 'failed',
        'error': error.message,
      };
      store.writeRun(lineId, run);
      return _fail(
        store,
        lineId,
        state: state,
        runId: runId,
        startedAt: startedAt,
        elapsedMs: elapsedMs,
        modelId: modelId,
        error: error.message,
        keepRun: true,
      );
    }
    run = <String, Object?>{...run, 'applied': guarded.applied, 'applied_tasks': applied};
    store.writeRun(lineId, run);
    store.writeOrchestratorState(lineId, <String, Object?>{
      'last_tick_at': _now,
      'last_action': guarded.action,
      'last_decision': guarded.toJson(),
      'last_run_id': runId,
      'last_snapshot_hash': snapshot.hash,
      'last_trigger': trigger,
      'consecutive_failures': 0,
      'last_error': '',
    });
    return <String, Object?>{
      'line_id': lineId,
      'status': guarded.applied ? 'applied' : 'noop',
      'trigger': trigger,
      'action': guarded.action,
      'reason': guarded.reason,
      'task_ids': guarded.taskIds,
      'applied_tasks': applied,
      'applied': guarded.applied,
      if (guarded.guard.isNotEmpty) 'guard': guarded.guard,
      'run_id': runId,
      'snapshot_hash': snapshot.hash,
    };
  }

  /// 应用副作用；返回实际落盘的任务 id（状态可能在快照后被改掉）。
  Future<List<String>> _apply(
    ProductionStore store,
    String lineId,
    OrchestratorDecision decision,
    List<TaskRecord> tasks, {
    required Map<String, Object?> meta,
    required Map<String, Object?> scope,
    required OrchestratorSnapshot snapshot,
  }) async {
    if (!decision.applied) return const <String>[];
    final Map<String, String> byId = <String, String>{
      for (final TaskRecord task in tasks) task.id: task.status.wire,
    };
    switch (decision.action) {
      case 'continue':
        return _applyContinue(store, lineId, decision, byId, meta, scope);
      case 'retry':
        return _applyRetry(store, lineId, decision, byId, meta, scope);
      case 'ask':
        return _applyAsk(store, lineId, decision, byId, meta, scope);
      case 'stop':
        if (decision.stopScope == 'line') {
          store.updateLine(lineId, <String, Object?>{'status': 'paused'});
          return const <String>[];
        }
        return _applyStop(store, lineId, decision, byId);
      default:
        return const <String>[];
    }
  }

  List<String> _applyContinue(
    ProductionStore store,
    String lineId,
    OrchestratorDecision decision,
    Map<String, String> byId,
    Map<String, Object?> meta,
    Map<String, Object?> scope,
  ) {
    final List<String> applied = <String>[];
    for (final String taskId in decision.taskIds) {
      final TaskStatus? status = tryTaskStatus(byId[taskId]);
      if (status == null) continue;
      final String stage = stageOf(status);
      if (stage.isEmpty) continue;
      store.updateLoop(lineId, taskId, <String, Object?>{
        'last_action': 'continue',
        'last_decision_at': _now,
      });
      _dispatch(lineId, taskId, stage, meta, scope);
      applied.add(taskId);
    }
    return applied;
  }

  List<String> _applyRetry(
    ProductionStore store,
    String lineId,
    OrchestratorDecision decision,
    Map<String, String> byId,
    Map<String, Object?> meta,
    Map<String, Object?> scope,
  ) {
    final List<String> applied = <String>[];
    for (final String taskId in decision.taskIds) {
      if (byId[taskId] != TaskStatus.blocked.wire) continue;
      final TaskRecord task = store.getTask(lineId, taskId);
      store.updateLoop(lineId, taskId, <String, Object?>{
        'attempts': task.loopAttempts + 1,
        'last_action': 'retry',
        'last_decision_at': _now,
      });
      store.transition(lineId, taskId, to: TaskStatus.queued.wire);
      _dispatch(lineId, taskId, 'pack', meta, scope);
      applied.add(taskId);
    }
    return applied;
  }

  Future<List<String>> _applyAsk(
    ProductionStore store,
    String lineId,
    OrchestratorDecision decision,
    Map<String, String> byId,
    Map<String, Object?> meta,
    Map<String, Object?> scope,
  ) async {
    final ProductionExecutionService? runner = execution;
    if (runner == null) {
      throw ProductionFailure(
        '主控提问需要执行阶段通道，当前未接线',
        code: 'execution_unavailable',
      );
    }
    final List<String> applied = <String>[];
    for (final String taskId in decision.taskIds) {
      final String status = byId[taskId] ?? '';
      final TaskStatus? parsed = tryTaskStatus(status);
      if (parsed == null || parsed.isTerminal) continue;
      await runner.handle(
        'production.task.question',
        <String, Object?>{
          'line_id': lineId,
          'task_id': taskId,
          'text': decision.question.text,
          'options': decision.question.options,
          'default': decision.question.defaultValue,
          'from': 'orchestrator',
        },
        meta,
        scope,
      );
      applied.add(taskId);
    }
    return applied;
  }

  List<String> _applyStop(
    ProductionStore store,
    String lineId,
    OrchestratorDecision decision,
    Map<String, String> byId,
  ) {
    final List<String> applied = <String>[];
    for (final String taskId in decision.taskIds) {
      final TaskStatus? status = tryTaskStatus(byId[taskId]);
      if (status == null || status.isTerminal) continue;
      store.updateLoop(lineId, taskId, <String, Object?>{
        'last_action': 'stop',
        'last_decision_at': _now,
        'stop_reason': 'orchestrator_stop',
      });
      if (canTransition(status, TaskStatus.blocked)) {
        store.transition(
          lineId,
          taskId,
          to: TaskStatus.blocked.wire,
          reason: 'orchestrator_stop',
        );
      }
      applied.add(taskId);
    }
    return applied;
  }

  void _dispatch(
    String lineId,
    String taskId,
    String stage,
    Map<String, Object?> meta,
    Map<String, Object?> scope,
  ) {
    final OrchestratorDispatcher? runner = dispatcher;
    if (runner == null) return;
    // tick 不等长任务：后台跑，失败已由派发方写进 task.yaml.last_error。
    unawaited(
      runner(lineId, taskId, stage, meta, scope).catchError((Object _) {}),
    );
  }

  /// 主控状态：配置 + 游标 + 最近决策 + 未答运行期问题（只读）。
  Map<String, Object?> status(ProductionStore store, String lineId) {
    final LineRecord line = store.getLine(lineId);
    final List<TaskRecord> tasks = store.listTasks(lineId);
    final Map<String, Object?> state = store.readOrchestratorState(lineId);
    final List<Map<String, Object?>> runs = <Map<String, Object?>>[
      for (final Map<String, Object?> run in store.listRuns(lineId))
        if (textOf(run['role']) == 'orchestrator') run,
    ];
    final List<QuestionState> open = openQuestionsOf(
      executeQuestionsOf(store.readInbox(lineId)),
    );
    return <String, Object?>{
      'line_id': lineId,
      // 后端投影（idle / working / paused）：UI 不再按任务数自行推断。
      'status': projectLineStatus(line, tasks),
      'config': OrchestratorConfig.of(line).toJson(),
      'state': state,
      'last_decision': plainMap(state['last_decision']),
      'last_runs': runs.take(5).toList(),
      'open_questions': <Map<String, Object?>>[
        for (final QuestionState question in open) question.toJson(),
      ],
      'open_question_count': open.length,
    };
  }

  Future<Map<String, Object?>> _fail(
    ProductionStore store,
    String lineId, {
    required Map<String, Object?> state,
    required String runId,
    required String startedAt,
    required int elapsedMs,
    required String modelId,
    required String error,
    bool keepRun = false,
  }) async {
    final int failures = intOf(state['consecutive_failures'], 0) + 1;
    if (!keepRun) {
      store.writeRun(lineId, <String, Object?>{
        'run_id': runId,
        'task_id': '',
        'role': 'orchestrator',
        'model_id': modelId,
        'status': 'failed',
        'started_at': startedAt,
        'elapsed_ms': elapsedMs,
        'tokens': <String, Object?>{'prompt': 0, 'completion': 0},
        'tool_calls': <Object?>[],
        'gate': <Object?>[],
        'error': error,
        'artifacts': <Object?>[],
        'action': '',
        'task_ids': <String>[],
        'applied': false,
      });
    }
    bool paused = false;
    if (failures >= kOrchestratorFailureLimit) {
      store.updateLine(lineId, <String, Object?>{'status': 'paused'});
      paused = true;
    }
    store.writeOrchestratorState(lineId, <String, Object?>{
      'last_tick_at': _now,
      'last_action': 'failed',
      'last_run_id': runId,
      'consecutive_failures': failures,
      'last_error': error,
      if (paused) 'paused_reason': '连续 $failures 次决策失败',
    });
    return <String, Object?>{
      'line_id': lineId,
      'status': 'failed',
      'action': '',
      'reason': error,
      'error': error,
      'consecutive_failures': failures,
      'paused': paused,
      'run_id': runId,
    };
  }

  Map<String, Object?> _runMap({
    required String runId,
    required String modelId,
    required String startedAt,
    required int elapsedMs,
    required OrchestratorDecision decision,
    required String snapshotHash,
    required Map<String, Object?> usage,
    required String status,
    required String error,
  }) => <String, Object?>{
    'run_id': runId,
    'task_id': '',
    'role': 'orchestrator',
    'model_id': modelId,
    'status': status,
    'started_at': startedAt,
    'elapsed_ms': elapsedMs,
    'tokens': <String, Object?>{
      'prompt': intOf(usage['prompt'], 0),
      'completion': intOf(usage['completion'], 0),
    },
    'tool_calls': <Object?>[],
    'gate': <Object?>[],
    'error': error,
    'artifacts': <Object?>[],
    'action': decision.action,
    'reason': decision.reason,
    'task_ids': decision.taskIds,
    'stop_scope': decision.stopScope,
    'applied': false,
    if (decision.guard.isNotEmpty) 'guard': decision.guard,
    'snapshot_hash': snapshotHash,
  };

  /// 定时 tick 的“有活可干”判据：在途 / queued / packed / blocked（可重试 / 可打断）。
  bool _hasAdvanceableTask(List<TaskRecord> tasks) {
    for (final TaskRecord task in tasks) {
      final TaskStatus status = task.status;
      if (status.isInFlight ||
          status == TaskStatus.queued ||
          status == TaskStatus.blocked) {
        return true;
      }
    }
    return false;
  }

  bool _rateLimited(String lineId, OrchestratorConfig config) {
    if (config.maxTicksPerMinute <= 0) return false;
    final List<DateTime> times = _tickTimes.putIfAbsent(
      lineId,
      () => <DateTime>[],
    );
    final DateTime cutoff = _clock().subtract(const Duration(minutes: 1));
    times.removeWhere((DateTime at) => at.isBefore(cutoff));
    return times.length >= config.maxTicksPerMinute;
  }

  Map<String, Object?> _skipped(String lineId, String reason, String trigger) =>
      <String, Object?>{
        'line_id': lineId,
        'status': 'skipped',
        'trigger': trigger,
        'reason': reason,
        'action': '',
        'task_ids': <String>[],
        'applied': false,
      };

  String _arg(Map<String, Object?> arguments, String key) {
    final String value = textOf(arguments[key]);
    if (value.isEmpty) {
      throw ProductionFailure('缺少 $key', code: 'invalid_arguments');
    }
    return value;
  }
}
