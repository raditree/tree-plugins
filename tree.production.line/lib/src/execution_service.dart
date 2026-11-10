/// 执行阶段（P4）的执行站命令门面：打包 → 执行 → 门控 → done / 重试 / blocked。
///
/// 与 P1 / P3 门面共用同一套 [ProductionStore]（`task.yaml` 仍是唯一真值）：
/// - 打包走 `agent.worker.run`（role=packer），产物落 `tasks/<id>/pack.json`；
/// - 执行走 `agent.worker.run`（role=executor），改完先判**写域**再跑**门控**；
/// - 门控失败按 `limits.retries` 回 `packed`，超限转 `blocked`；
/// - `done` 只能由门控通过触发（模型自报完成一律不算）。
library;

import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'execution.dart';
import 'expert.dart';
import 'preparation.dart';
import 'service.dart';
import 'store.dart';

/// P4 / P5 对外开放的命令族（同一个执行站 `production`）。
const List<String> kExecutionCommands = <String>[
  'production.task.pack',
  'production.task.run',
  'production.task.expert',
  'production.task.message',
  'production.task.messages',
];

/// 角色默认工具（与 recon §9.1 / §9.2 / §9.4 一致；插件间不互相 import）。
const Map<String, List<String>> kRoleDefaultTools = <String, List<String>>{
  'packer': <String>['read', 'list', 'grep', 'terminal', 'message'],
  'executor': <String>['read', 'write', 'edit', 'terminal', 'message', 'spec'],
  'expert': <String>['read', 'grep'],
};

/// 一次员工调用（插件层接 `agent.worker.run`；单测注入假实现）。
class WorkerCall {
  const WorkerCall({
    required this.role,
    required this.task,
    required this.tools,
    required this.modelId,
    this.reuse = '',
  });

  final String role;
  final String task;
  final List<String> tools;
  final String modelId;
  final String reuse;

  Map<String, Object?> toArguments() => <String, Object?>{
    'role': role,
    'task': task,
    'tools': tools,
    if (modelId.isNotEmpty) 'model_id': modelId,
    if (reuse.isNotEmpty) 'reuse': reuse,
  };
}

typedef WorkerRunner =
    Future<Map<String, Object?>> Function(
      WorkerCall call,
      Map<String, Object?> scope,
    );

/// 一条命令的结果（门控 / `git status` 共用）。
class CommandResult {
  const CommandResult({required this.ok, this.exitCode = 0, this.output = ''});

  final bool ok;
  final int exitCode;
  final String output;
}

typedef CommandRunner =
    Future<CommandResult> Function(
      String command, {
      required String workspace,
      required Map<String, Object?> scope,
    });

class ProductionExecutionService {
  ProductionExecutionService({
    Map<String, String>? environment,
    DateTime Function()? clock,
    this.workers,
    this.commands,
  }) : _environment = environment ?? Platform.environment,
       _clock = clock ?? DateTime.now;

  final Map<String, String> _environment;
  final DateTime Function() _clock;

  /// 员工运行器；null = 未接线（打包 / 执行 fail-closed）。
  final WorkerRunner? workers;

  /// 命令执行器（`git status` + 门控）；null = 未接线（门控 fail-closed）。
  final CommandRunner? commands;

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
      case 'production.task.pack':
        return _pack(store, arguments, scope);
      case 'production.task.run':
        return _run(store, arguments, scope);
      case 'production.task.expert':
        return _expert(store, arguments, scope);
      case 'production.task.message':
        return _message(store, arguments);
      case 'production.task.messages':
        return _messages(store, arguments);
      default:
        throw ProductionFailure(
          '未知执行阶段命令：$command',
          code: 'unknown_command',
        );
    }
  }

  // ── 打包（§9.1）───────────────────────────────────────────────────

  Future<Map<String, Object?>> _pack(
    ProductionStore store,
    Map<String, Object?> arguments,
    Map<String, Object?> scope,
  ) async {
    final String lineId = _arg(arguments, 'line_id');
    final String taskId = _arg(arguments, 'task_id');
    final LineRecord line = store.getLine(lineId);
    TaskRecord task = store.getTask(lineId, taskId);
    if (task.status != TaskStatus.queued &&
        task.status != TaskStatus.packing) {
      throw ProductionFailure(
        '只有 queued / packing 可以打包（当前 ${task.status.wire}）',
        code: 'execute_state',
      );
    }
    final List<String> writeScope = stringsOf(task.data['write_scope']);
    if (writeScope.isEmpty) {
      throw ProductionFailure(
        '任务没有 write_scope：无法判定执行边界（先补计划再打包）',
        code: 'write_scope_required',
      );
    }
    final WorkerRunner? runner = workers;
    if (runner == null) {
      throw ProductionFailure(
        '执行阶段需要 agent.worker.run 通道，当前未接线',
        code: 'worker_unavailable',
      );
    }
    final String agentId = _agentOf(scope);
    final String modelId = _modelOf(line, 'packer');
    if (modelId.isEmpty) {
      throw ProductionFailure(
        '产线没有给 packer 配模型（line.yaml.roles.packer.model_id）',
        code: 'model_required',
      );
    }
    if (task.status == TaskStatus.queued) {
      store.transition(lineId, taskId, to: TaskStatus.packing.wire);
    }
    final int attempt = intOf(task.data['pack_attempts'], 0) + 1;
    task = store.putTask(lineId, taskId, <String, Object?>{'pack_attempts': attempt});
    final String startedAt = _now;
    final int startedMs = _clock().millisecondsSinceEpoch;
    Map<String, Object?> result;
    try {
      result = await runner(
        WorkerCall(
          role: 'packer',
          task: packerUserPrompt(
            lineName: line.name,
            taskId: taskId,
            title: task.title,
            intake: _intakeText(task),
            plan: _readAsset(store, lineId, task, 'plan'),
            memory: _memoryText(store, lineId, line),
            readScope: stringsOf(task.data['read_scope']),
            writeScope: writeScope,
          ),
          tools: _toolsOf(line, 'packer'),
          modelId: modelId,
        ),
        _workerScope(scope, agentId, lineId, taskId),
      );
    } catch (error) {
      result = <String, Object?>{
        'status': 'failed',
        'error': '员工运行异常：$error',
      };
    }
    final int elapsed = _clock().millisecondsSinceEpoch - startedMs;
    final String workerError = _workerErrorOf(result);
    final String report = textOf(result['report']);
    Map<String, Object?> run = _runMap(
      runId: store.nextRunId(taskId, 'packer'),
      taskId: taskId,
      role: 'packer',
      modelId: modelId,
      startedAt: startedAt,
      elapsedMs: elapsed,
      status: 'failed',
      error: workerError,
      worker: result,
    );
    if (workerError.isNotEmpty) {
      return _failPack(store, lineId, taskId, run, workerError);
    }
    final Map<String, Object?>? json = jsonObjectFromText(report);
    if (json == null) {
      return _failPack(
        store,
        lineId,
        taskId,
        run,
        '打包模型没有返回 JSON：${_clip(report, 300)}',
      );
    }
    final PackSpec pack;
    try {
      pack = parsePackJson(json);
      _validatePackScope(
        pack,
        stringsOf(task.data['read_scope']),
        stringsOf(plainMap(line.data['policy'])['deny_globs']),
      );
    } on ProductionFailure catch (error) {
      return _failPack(store, lineId, taskId, run, error.message);
    }
    store.writePack(lineId, taskId, pack.toJson());
    final String packAsset = 'tasks/$taskId/pack.md';
    store.writeAsset(
      lineId,
      packAsset,
      renderPackMd(taskId: taskId, title: task.title, pack: pack),
    );
    final Map<String, Object?> artifacts = <String, Object?>{
      ...task.artifacts,
      'pack': '${_assetDir(lineId, line)}/$packAsset',
    };
    task = store.putTask(lineId, taskId, <String, Object?>{
      'pack': <String, Object?>{
        'path': 'tasks/$taskId/pack.json',
        'files': pack.files.length,
        'baseline': <String>[
          for (final PackCommand command in pack.baseline) command.command,
        ],
        'risks': pack.risks.length,
        'attempt': attempt,
        'packed_at': _now,
      },
      'artifacts': artifacts,
    });
    store.transition(lineId, taskId, to: TaskStatus.packed.wire);
    run = <String, Object?>{
      ...run,
      'status': 'ok',
      'artifacts': <String>['tasks/$taskId/pack.json', packAsset],
    };
    store.writeRun(lineId, run);
    return <String, Object?>{
      'task': store.getTask(lineId, taskId).toJson(),
      'pack': pack.toJson(),
      'run': run,
      'status': 'packed',
    };
  }

  Map<String, Object?> _failPack(
    ProductionStore store,
    String lineId,
    String taskId,
    Map<String, Object?> run,
    String error,
  ) {
    final Map<String, Object?> failed = <String, Object?>{
      ...run,
      'status': 'failed',
      'error': error,
    };
    store.writeRun(lineId, failed);
    final TaskRecord current = store.getTask(lineId, taskId);
    if (canTransition(current.status, TaskStatus.blocked)) {
      store.transition(
        lineId,
        taskId,
        to: TaskStatus.blocked.wire,
        reason: '打包失败：$error',
      );
    }
    store.putTask(lineId, taskId, <String, Object?>{
      'last_error': {'stage': 'pack', 'error': error, 'at': _now},
    });
    return <String, Object?>{
      'task': store.getTask(lineId, taskId).toJson(),
      'run': failed,
      'status': 'failed',
      'error': error,
    };
  }

  // ── 执行 + 门控（§9.2）───────────────────────────────────────────

  Future<Map<String, Object?>> _run(
    ProductionStore store,
    Map<String, Object?> arguments,
    Map<String, Object?> scope,
  ) async {
    final String lineId = _arg(arguments, 'line_id');
    final String taskId = _arg(arguments, 'task_id');
    final LineRecord line = store.getLine(lineId);
    TaskRecord task = store.getTask(lineId, taskId);
    if (task.status != TaskStatus.packed) {
      throw ProductionFailure(
        '只有 packed 可以执行（当前 ${task.status.wire}）：先 production.task.pack',
        code: 'execute_state',
      );
    }
    final Map<String, Object?> pack = store.readPack(lineId, taskId);
    if (pack.isEmpty) {
      throw ProductionFailure(
        '任务 $taskId 没有 pack.json：先 production.task.pack',
        code: 'pack_required',
      );
    }
    final List<String> writeScope = stringsOf(task.data['write_scope']);
    if (writeScope.isEmpty) {
      throw ProductionFailure(
        '任务没有 write_scope：无法判定执行边界',
        code: 'write_scope_required',
      );
    }
    final WorkerRunner? runner = workers;
    if (runner == null) {
      throw ProductionFailure(
        '执行阶段需要 agent.worker.run 通道，当前未接线',
        code: 'worker_unavailable',
      );
    }
    final CommandRunner? commandRunner = commands;
    if (commandRunner == null) {
      throw ProductionFailure(
        '门控需要命令执行通道（local.exec.command），当前未接线',
        code: 'command_unavailable',
      );
    }
    final String agentId = _agentOf(scope);
    final String workspace = store.workspaceDirOf(lineId);
    final String modelId = _modelOf(line, 'executor');
    if (modelId.isEmpty) {
      throw ProductionFailure(
        '产线没有给 executor 配模型（line.yaml.roles.executor.model_id）',
        code: 'model_required',
      );
    }
    final Map<String, Object?> workerScope = _workerScope(
      scope,
      agentId,
      lineId,
      taskId,
    );
    // 写域判据的基线：执行前的改动集合（无法读取就 fail-closed，绝不动文件）。
    final CommandResult before = await _command(
      commandRunner,
      'git status --porcelain',
      workspace: workspace,
      scope: workerScope,
    );
    if (!before.ok) {
      throw ProductionFailure(
        '无法读取工作空间变更（git status 失败）：${_clip(before.output, 300)}',
        code: 'workspace_vcs_unavailable',
      );
    }
    final Set<String> beforeFiles = parseChangedFiles(before.output).toSet();

    store.transition(lineId, taskId, to: TaskStatus.running.wire);
    task = store.putTask(lineId, taskId, <String, Object?>{
      'run_attempts': intOf(task.data['run_attempts'], 0) + 1,
    });
    final String startedAt = _now;
    final int startedMs = _clock().millisecondsSinceEpoch;
    Map<String, Object?> result;
    try {
      result = await runner(
        WorkerCall(
          role: 'executor',
          task: executorUserPrompt(
            taskId: taskId,
            title: task.title,
            packJson: const JsonEncoder.withIndent('  ').convert(pack),
            writeScope: writeScope,
            acceptance: stringsOf(task.data['acceptance']),
            acceptanceDoc: _readAsset(store, lineId, task, 'acceptance'),
          ),
          tools: _toolsOf(line, 'executor'),
          modelId: modelId,
        ),
        workerScope,
      );
    } catch (error) {
      result = <String, Object?>{
        'status': 'failed',
        'error': '员工运行异常：$error',
      };
    }
    final int elapsed = _clock().millisecondsSinceEpoch - startedMs;
    final String workerError = _workerErrorOf(result);
    Map<String, Object?> run = _runMap(
      runId: store.nextRunId(taskId, 'executor'),
      taskId: taskId,
      role: 'executor',
      modelId: modelId,
      startedAt: startedAt,
      elapsedMs: elapsed,
      status: 'failed',
      error: workerError,
      worker: result,
    );
    if (workerError.isNotEmpty) {
      return _blockRun(
        store: store,
        lineId: lineId,
        taskId: taskId,
        run: run,
        reason: '执行模型失败：$workerError',
        status: 'blocked',
      );
    }
    // 写域判据：执行前后的改动差集必须全部落在 write_scope 内，且不命中禁区。
    final CommandResult after = await _command(
      commandRunner,
      'git status --porcelain',
      workspace: workspace,
      scope: workerScope,
    );
    if (!after.ok) {
      return _blockRun(
        store: store,
        lineId: lineId,
        taskId: taskId,
        run: run,
        reason: '无法读取执行后的改动（git status 失败）：${_clip(after.output, 300)}',
        status: 'blocked',
      );
    }
    final List<String> changed = <String>[
      for (final String path in parseChangedFiles(after.output))
        if (!beforeFiles.contains(path)) path,
    ];
    final List<String> violations = writeScopeViolations(changed, writeScope);
    final List<String> denied = denyGlobViolations(
      changed,
      stringsOf(plainMap(line.data['policy'])['deny_globs']),
    );
    if (violations.isNotEmpty || denied.isNotEmpty) {
      final String reason = <String>[
        if (violations.isNotEmpty) '写域越界：${violations.take(8).join('、')}',
        if (denied.isNotEmpty) '命中禁区：${denied.take(8).join('、')}',
      ].join('；');
      store.putTask(lineId, taskId, <String, Object?>{
        'violations': <String>[...violations, ...denied],
        'changed_files': changed,
      });
      return _blockRun(
        store: store,
        lineId: lineId,
        taskId: taskId,
        run: run,
        reason: reason,
        status: 'write_scope_violation',
      );
    }
    store.putTask(lineId, taskId, <String, Object?>{'changed_files': changed});
    store.transition(lineId, taskId, to: TaskStatus.gating.wire);

    // 门控：任何一条失败都不得进 done。
    final List<String> gate = gateCommandsOf(
      arguments['gate'],
      <String>[
        for (final Object? item in (pack['baseline'] as List<dynamic>? ??
            const <dynamic>[]))
          if (item is Map) textOf(plainMap(item)['command']),
      ],
    );
    final List<Map<String, Object?>> gateResults = <Map<String, Object?>>[];
    bool gateFailed = false;
    for (final String command in gate) {
      if (command.trim().isEmpty) continue;
      final CommandResult result = await _command(
        commandRunner,
        command,
        workspace: workspace,
        scope: workerScope,
      );
      gateResults.add(<String, Object?>{
        'command': command,
        'ok': result.ok,
        'exit_code': result.exitCode,
        'output': _clip(result.output, 4000),
      });
      if (!result.ok) {
        gateFailed = true;
        break;
      }
    }
    run = <String, Object?>{
      ...run,
      'status': gateFailed ? 'failed' : 'ok',
      'changed_files': changed,
      'gate': gateResults,
      'artifacts': <String>['tasks/$taskId/pack.json'],
    };
    if (gateFailed) {
      final int attempts = intOf(task.data['gate_attempts'], 0) + 1;
      final int maxRetries = intOf(plainMap(line.data['limits'])['retries'], 2);
      final String summary = <String>[
        for (final Map<String, Object?> item in gateResults)
          if (item['ok'] != true)
            '${item['command']}：${_clip(textOf(item['output']), 300)}',
      ].join('；');
      store.writeRun(lineId, run);
      store.putTask(lineId, taskId, <String, Object?>{
        'gate_attempts': attempts,
        'last_gate': <String, Object?>{
          'attempt': attempts,
          'commands': gateResults,
          'at': _now,
        },
      });
      if (attempts <= maxRetries) {
        store.transition(lineId, taskId, to: TaskStatus.packed.wire);
        return <String, Object?>{
          'task': store.getTask(lineId, taskId).toJson(),
          'run': run,
          'status': 'retry',
          'attempts': attempts,
          'max_retries': maxRetries,
          'gate': gateResults,
          'error': summary,
        };
      }
      return _blockRun(
        store: store,
        lineId: lineId,
        taskId: taskId,
        run: run,
        reason: '门控失败（已重试 $maxRetries 次）：$summary',
        status: 'blocked',
        extra: <String, Object?>{'gate': gateResults, 'attempts': attempts},
      );
    }
    store.writeRun(lineId, run);
    store.transition(lineId, taskId, to: TaskStatus.done.wire);
    store.putTask(lineId, taskId, <String, Object?>{
      'gate_attempts': 0,
      'gate': gateResults,
      'done_at': _now,
    });
    return <String, Object?>{
      'task': store.getTask(lineId, taskId).toJson(),
      'run': run,
      'status': 'done',
      'gate': gateResults,
      'changed_files': changed,
    };
  }

  Map<String, Object?> _blockRun({
    required ProductionStore store,
    required String lineId,
    required String taskId,
    required Map<String, Object?> run,
    required String reason,
    required String status,
    Map<String, Object?> extra = const <String, Object?>{},
  }) {
    final Map<String, Object?> failed = <String, Object?>{
      ...run,
      'status': 'failed',
      'error': reason,
    };
    store.writeRun(lineId, failed);
    final TaskRecord current = store.getTask(lineId, taskId);
    if (canTransition(current.status, TaskStatus.blocked)) {
      store.transition(
        lineId,
        taskId,
        to: TaskStatus.blocked.wire,
        reason: reason,
      );
    }
    store.putTask(lineId, taskId, <String, Object?>{
      'last_error': {'stage': 'run', 'error': reason, 'at': _now},
    });
    return <String, Object?>{
      'task': store.getTask(lineId, taskId).toJson(),
      'run': failed,
      'status': status,
      'error': reason,
      ...extra,
    };
  }

  // ── 专家工具（§9.4）────────────────────────────────────────────────

  Future<Map<String, Object?>> _expert(
    ProductionStore store,
    Map<String, Object?> arguments,
    Map<String, Object?> scope,
  ) async {
    final String lineId = _arg(arguments, 'line_id');
    final String taskId = _arg(arguments, 'task_id');
    final LineRecord line = store.getLine(lineId);
    final TaskRecord task = store.getTask(lineId, taskId);
    final ExpertRequest request = parseExpertArguments(arguments);
    final Map<String, Object?> expertRole = _expertRole(line);
    if (expertRole['enabled'] != true) {
      throw ProductionFailure(
        '专家未启用：line.yaml.roles.expert.enabled=false（默认关闭，模型配置页勾选后才允许）',
        code: 'expert_disabled',
      );
    }
    // 只有打包 / 执行可以召专家：专家不能再召专家，用户也不能绕过产线直接问。
    if (request.role.isNotEmpty &&
        request.role != 'packer' &&
        request.role != 'executor') {
      throw ProductionFailure(
        '只有打包 / 执行可以召专家（当前：${request.role}；专家不能再召专家）',
        code: 'expert_not_allowed',
      );
    }
    // 单任务次数上限（台账按 role=expert 计数，失败也算一次）。
    final int max = intOf(expertRole['max_per_task'], kExpertMaxPerTask);
    final List<Map<String, Object?>> runs = store.listRuns(
      lineId,
      taskId: taskId,
    );
    final int used = runs
        .where((Map<String, Object?> run) => textOf(run['role']) == 'expert')
        .length;
    if (max <= 0 || used >= max) {
      throw ProductionFailure(
        '专家调用已达上限（$used/$max）：单任务上限读 roles.expert.max_per_task',
        code: 'expert_limit_exceeded',
      );
    }
    // 专家不落盘：工具表里出现 write / edit / 再召 / 建团队一律拒绝。
    final List<String> tools = expertToolsOf(expertRole['tools']);
    final List<String> violations = expertToolViolations(tools);
    if (violations.isNotEmpty) {
      throw ProductionFailure(
        '专家工具表含写入 / 再召工具：${violations.join('、')}（专家只读、不落盘）',
        code: 'expert_tools_invalid',
      );
    }
    final WorkerRunner? runner = workers;
    if (runner == null) {
      throw ProductionFailure(
        '专家调用需要 agent.worker.run 通道，当前未接线',
        code: 'worker_unavailable',
      );
    }
    final String agentId = _agentOf(scope);
    final String configuredModel = textOf(expertRole['model_id']);
    final Map<String, Object?> workerScope = _workerScope(
      scope,
      agentId,
      lineId,
      taskId,
    );
    final String startedAt = _now;
    final int startedMs = _clock().millisecondsSinceEpoch;
    Map<String, Object?> result;
    try {
      result = await runner(
        WorkerCall(
          role: 'expert',
          task: expertUserPrompt(
            taskId: taskId,
            title: task.title,
            request: request,
          ),
          tools: tools,
          modelId: configuredModel,
        ),
        workerScope,
      );
    } catch (error) {
      result = <String, Object?>{
        'status': 'failed',
        'error': '专家运行异常：$error',
      };
    }
    final int elapsed = _clock().millisecondsSinceEpoch - startedMs;
    final String workerModel = textOf(result['model_id']).isEmpty
        ? configuredModel
        : textOf(result['model_id']);
    final String workerError = _workerErrorOf(result);
    final Map<String, Object?> run = _runMap(
      runId: store.nextRunId(taskId, 'expert'),
      taskId: taskId,
      role: 'expert',
      modelId: workerModel,
      startedAt: startedAt,
      elapsedMs: elapsed,
      status: 'failed',
      error: workerError,
      worker: result,
    );
    Map<String, Object?> withQuestion(Map<String, Object?> value) =>
        <String, Object?>{
          ...value,
          'asked_by': request.role,
          'question': _clip(request.question, 2000),
        };
    if (workerError.isNotEmpty) {
      final Map<String, Object?> failed = withQuestion(run);
      store.writeRun(lineId, failed);
      return <String, Object?>{
        'status': 'failed',
        'error': workerError,
        'run': failed,
        'used': used,
        'max_per_task': max,
        // 失败也落台账，所以这一次同样计数。
        'remaining': max - used - 1,
        'task_id': taskId,
      };
    }
    final ExpertAnswer answer;
    try {
      answer = parseExpertAnswer(
        jsonObjectFromText(textOf(result['report'])),
      );
    } on ProductionFailure catch (error) {
      final Map<String, Object?> failed = <String, Object?>{
        ...withQuestion(run),
        'error': error.message,
      };
      store.writeRun(lineId, failed);
      return <String, Object?>{
        'status': 'failed',
        'error': error.message,
        'run': failed,
        'used': used,
        'max_per_task': max,
        'remaining': max - used - 1,
        'task_id': taskId,
      };
    }
    final Map<String, Object?> okRun = <String, Object?>{
      ...withQuestion(run),
      'status': 'ok',
      'answer': answer.toJson(),
    };
    store.writeRun(lineId, okRun);
    return <String, Object?>{
      'status': 'ok',
      'answer': answer.toJson(),
      'text': renderExpertAnswer(answer),
      'run': okRun,
      'used': used + 1,
      'max_per_task': max,
      'remaining': max - used - 1,
      'task_id': taskId,
    };
  }

  // ── 任务内 message 线程（§9.3）──────────────────────────────────

  Map<String, Object?> _message(
    ProductionStore store,
    Map<String, Object?> arguments,
  ) {
    final String lineId = _arg(arguments, 'line_id');
    final String taskId = _arg(arguments, 'task_id');
    final TaskRecord task = store.getTask(lineId, taskId);
    final String text = textOf(arguments['text']).isEmpty
        ? textOf(arguments['body'])
        : textOf(arguments['text']);
    if (text.isEmpty) {
      throw ProductionFailure(
        'production.task.message 需要 text',
        code: 'invalid_arguments',
      );
    }
    final String from = textOf(arguments['from']).isEmpty
        ? 'user'
        : textOf(arguments['from']);
    final String kind = textOf(arguments['kind']).isEmpty
        ? 'note'
        : textOf(arguments['kind']);
    final Map<String, Object?> message = store.appendMessage(
      lineId,
      taskId,
      <String, Object?>{
        'from': from,
        'to': textOf(arguments['to']),
        'kind': kind,
        'text': text,
      },
    );
    final List<Map<String, Object?>> thread = store.readMessages(lineId, taskId);
    final int questions = thread
        .where((Map<String, Object?> item) => textOf(item['kind']) == 'question')
        .length;
    bool blocked = false;
    // §9.3：打回超过 3 次 ⇒ 自动 blocked，避免无限来回烧 token。
    if (questions > 3 &&
        !task.status.isTerminal &&
        canTransition(task.status, TaskStatus.blocked)) {
      store.transition(
        lineId,
        taskId,
        to: TaskStatus.blocked.wire,
        reason: '任务内打回超过 3 次（$questions 条问题）：需要用户拍板',
      );
      blocked = true;
    }
    return <String, Object?>{
      'message': message,
      'count': thread.length,
      'questions': questions,
      'blocked': blocked,
      'task': store.getTask(lineId, taskId).toJson(),
    };
  }

  Map<String, Object?> _messages(
    ProductionStore store,
    Map<String, Object?> arguments,
  ) {
    final String lineId = _arg(arguments, 'line_id');
    final String taskId = _arg(arguments, 'task_id');
    store.getTask(lineId, taskId);
    final List<Map<String, Object?>> thread = store.readMessages(lineId, taskId);
    return <String, Object?>{
      'messages': thread,
      'count': thread.length,
      'task_id': taskId,
    };
  }

  // ── 内部工具 ─────────────────────────────────────────────────────

  String _agentOf(Map<String, Object?> scope) {
    final String agentId = textOf(scope['agent_id']);
    if (agentId.isEmpty) {
      throw ProductionFailure(
        '执行阶段需要发起者身份（scope.agent_id）：员工按它继承工作空间与团队',
        code: 'agent_required',
      );
    }
    return agentId;
  }

  Map<String, Object?> _workerScope(
    Map<String, Object?> scope,
    String agentId,
    String lineId,
    String taskId,
  ) => <String, Object?>{
    ...scope,
    'agent_id': agentId,
    // 员工历史按任务分栏：复用同一条线程，重启后仍能接着聊。
    'session_id': 'pl_${lineId}_$taskId',
  };

  Map<String, Object?> _roleMap(LineRecord line, String role) =>
      plainMap(plainMap(line.data['roles'])[role]);

  /// `roles.expert`（默认关闭；老产线缺键也按关闭处理）。
  Map<String, Object?> _expertRole(LineRecord line) => _roleMap(line, 'expert');

  String _modelOf(LineRecord line, String role) =>
      textOf(_roleMap(line, role)['model_id']);

  List<String> _toolsOf(LineRecord line, String role) {
    final List<String> configured = stringsOf(_roleMap(line, role)['tools']);
    final List<String> tools = List<String>.of(
      configured.isEmpty
          ? (kRoleDefaultTools[role] ?? const <String>[])
          : configured,
    );
    // P5：产线启用专家后，ask_expert 进入打包 / 执行的工具表（未启用不出现）。
    if ((role == 'packer' || role == 'executor') &&
        _expertRole(line)['enabled'] == true &&
        !tools.contains(kAskExpertTool)) {
      tools.add(kAskExpertTool);
    }
    return tools;
  }

  String _intakeText(TaskRecord task) {
    final Map<String, Object?> intake = plainMap(task.data['intake']);
    if (intake.isEmpty) return '（无需求模板：按任务标题与验收判据执行）';
    return <String>[
      for (final String key in kIntakeKeys)
        if (textOf(intake[key]).isNotEmpty)
          '${kIntakeLabels[key]}：${textOf(intake[key])}',
      '标题：${task.title}',
      if (stringsOf(task.data['acceptance']).isNotEmpty)
        '验收：${stringsOf(task.data['acceptance']).join('；')}',
    ].join('\n');
  }

  /// 读任务引用的项目资产（`artifacts.<key>`），缺失 / 越界返回空串。
  String _readAsset(
    ProductionStore store,
    String lineId,
    TaskRecord task,
    String key,
  ) {
    String relative = textOf(task.artifacts[key]);
    final int hash = relative.indexOf('#');
    if (hash >= 0) relative = relative.substring(0, hash);
    if (relative.isEmpty) return '';
    try {
      return store.readWorkspaceFile(lineId, relative);
    } catch (_) {
      return '';
    }
  }

  /// 「项目记忆」= line.yaml.docs.memory_manifest 里的几份文档（缺失跳过）。
  String _memoryText(
    ProductionStore store,
    String lineId,
    LineRecord line,
  ) {
    final List<String> manifest = stringsOf(
      plainMap(line.data['docs'])['memory_manifest'],
    );
    final StringBuffer buffer = StringBuffer();
    for (final String relative in manifest) {
      try {
        final String text = store.readWorkspaceFile(lineId, relative);
        buffer
          ..writeln('### $relative')
          ..writeln(_clip(text, 4000))
          ..writeln();
      } catch (_) {
        // 清单里的文档不存在：跳过，不阻断打包。
      }
    }
    return buffer.toString();
  }

  String _assetDir(String lineId, LineRecord line) {
    final Map<String, Object?> docs = plainMap(line.data['docs']);
    final String base = textOf(docs['asset_dir']).isEmpty
        ? 'docs/production_lines'
        : textOf(docs['asset_dir']);
    return '$base/$lineId';
  }

  void _validatePackScope(
    PackSpec pack,
    List<String> readScope,
    List<String> denyGlobs,
  ) {
    if (readScope.isNotEmpty) {
      final List<String> outside = <String>[
        for (final PackFile file in pack.files)
          if (!readScope.any((String scope) => matchesWriteScope(file.path, scope)))
            file.path,
      ];
      if (outside.isNotEmpty) {
        throw ProductionFailure(
          '打包片段越出读域：${outside.take(8).join('、')}',
          code: 'pack_out_of_scope',
        );
      }
    }
    final List<String> denied = denyGlobViolations(
      pack.files.map((PackFile file) => file.path),
      denyGlobs,
    );
    if (denied.isNotEmpty) {
      throw ProductionFailure(
        '打包片段命中禁区：${denied.take(8).join('、')}',
        code: 'pack_denied_glob',
      );
    }
  }

  Future<CommandResult> _command(
    CommandRunner runner,
    String command, {
    required String workspace,
    required Map<String, Object?> scope,
  }) async {
    try {
      return await runner(command, workspace: workspace, scope: scope);
    } catch (error) {
      return CommandResult(ok: false, exitCode: -1, output: '执行器异常：$error');
    }
  }

  String _workerErrorOf(Map<String, Object?> result) {
    final String error = textOf(result['error']);
    if (error.isNotEmpty) return error;
    final String status = textOf(result['status']);
    if (status == 'ok') return '';
    return status == 'empty'
        ? '员工跑完但没有文本产出（无法解析打包结果 / 改动报告）'
        : '员工运行失败（status=${status.isEmpty ? '未知' : status}）';
  }

  Map<String, Object?> _runMap({
    required String runId,
    required String taskId,
    required String role,
    required String modelId,
    required String startedAt,
    required int elapsedMs,
    required String status,
    required String error,
    Map<String, Object?> worker = const <String, Object?>{},
  }) {
    final Map<String, Object?> tokens = plainMap(worker['tokens']);
    final List<Object?> toolCalls = worker['tool_calls'] is List
        ? List<Object?>.of(worker['tool_calls'] as List<dynamic>)
        : <Object?>[];
    return <String, Object?>{
      'run_id': runId,
      'task_id': taskId,
      'role': role,
      'model_id': modelId,
      if (textOf(worker['worker_id']).isNotEmpty)
        'worker_id': textOf(worker['worker_id']),
      'status': status,
      'started_at': startedAt,
      'elapsed_ms': elapsedMs,
      'tokens': <String, Object?>{
        'prompt': intOf(tokens['prompt'], 0),
        'completion': intOf(tokens['completion'], 0),
      },
      'tool_calls': toolCalls,
      'gate': <Object?>[],
      'error': error,
      'artifacts': <Object?>[],
    };
  }

  static String _clip(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}…';

  String _arg(Map<String, Object?> arguments, String key) {
    final String value = textOf(arguments[key]);
    if (value.isEmpty) {
      throw ProductionFailure('缺少 $key', code: 'invalid_arguments');
    }
    return value;
  }
}
