import 'dart:async';

import '../workspace/station_command.dart';
import 'tool_runner.dart';

/// 一个后台终端任务（tree.agent 侧台账）。
class HookRun {
  HookRun({
    required this.id,
    required this.agentId,
    required this.sessionId,
    required this.command,
    required this.logRelative,
    required this.startedAt,
    this.running = true,
    this.exitCode,
  });

  final String id;
  final String agentId;
  final String sessionId;
  final String command;
  final String logRelative;
  final DateTime startedAt;
  bool running;
  int? exitCode;

  String describe() =>
      '$id  ${running ? '运行中' : '已结束'}${exitCode == null ? '' : '（exit_code=$exitCode）'}  $command  日志：$logRelative';
}

/// terminal hook 的 tree.agent 侧管理：启动、轮询完成、唤醒、列表、取消。
class TerminalHookManager {
  TerminalHookManager({
    required this.client,
    required this.scopeFor,
    required this.wake,
    this.pollInterval = const Duration(seconds: 2),
  });

  final StationCommandClient client;
  final Map<String, dynamic> Function(String agentId, String sessionId)
  scopeFor;
  final Future<void> Function(String agentId, String sessionId, String notice)
  wake;
  final Duration pollInterval;
  final Map<String, HookRun> _runs = <String, HookRun>{};
  final Set<String> _watching = <String>{};

  List<HookRun> listVisible(String agentId, String sessionId) => _runs.values
      .where(
        (HookRun run) =>
            run.agentId == agentId &&
            (sessionId.isEmpty || run.sessionId == sessionId),
      )
      .toList(growable: false);

  HookRun? find(String taskId) => _runs[taskId];

  Future<ToolOutcome> start(ToolInvocation invocation) async {
    final String command = (invocation.arguments['command'] ?? '')
        .toString()
        .trim();
    if (command.isEmpty) {
      return const ToolOutcome('command 不能为空', isError: true);
    }
    final Map<String, dynamic> scope = scopeFor(
      invocation.agentId,
      invocation.sessionId,
    );
    final Map<String, dynamic> result = await client(
      'exec.command',
      <String, dynamic>{
        'command': command,
        'hook': true,
        if (invocation.arguments['output_file'] != null)
          'output_file': invocation.arguments['output_file'],
      },
      scope,
    );
    final String id = (result['task_id'] ?? '').toString();
    if (id.isEmpty) {
      return ToolOutcome(
        'terminal hook 启动失败：执行器未返回 task_id（${result['text'] ?? ''}）',
        isError: true,
      );
    }
    final HookRun run = HookRun(
      id: id,
      agentId: invocation.agentId,
      sessionId: invocation.sessionId,
      command: command,
      logRelative: (result['log_relative'] ?? '').toString(),
      startedAt: DateTime.now(),
    );
    _runs[id] = run;
    unawaited(_watch(run));
    final String head = (result['text'] ?? '').toString().isEmpty
        ? '[terminal hook] 已在后台启动'
        : (result['text'] ?? '').toString();
    return ToolOutcome('$head\ntask_id: $id');
  }

  /// 同步命令被执行器软超时接管：把已有 task_id 纳入台账并开始轮询。
  Future<ToolOutcome> adopt(
    ToolInvocation invocation,
    Map<String, dynamic> result,
  ) async {
    final String id = (result['task_id'] ?? '').toString();
    if (id.isEmpty) {
      return ToolOutcome((result['text'] ?? '').toString());
    }
    final HookRun run = HookRun(
      id: id,
      agentId: invocation.agentId,
      sessionId: invocation.sessionId,
      command: (invocation.arguments['command'] ?? '').toString(),
      logRelative: (result['log_relative'] ?? '').toString(),
      startedAt: DateTime.now(),
    );
    _runs[id] = run;
    unawaited(_watch(run));
    return ToolOutcome(
      (result['text'] ?? '').toString() +
          (run.logRelative.isEmpty ? '' : '\n日志：${run.logRelative}'),
    );
  }

  Future<ToolOutcome> status(String taskId) async {
    final HookRun? run = _runs[taskId];
    if (run == null) return ToolOutcome('未知 task_id：$taskId', isError: true);
    try {
      final Map<String, dynamic> result = await client(
        'exec.command',
        <String, dynamic>{'hook_action': 'status', 'task_id': taskId},
        scopeFor(run.agentId, run.sessionId),
      );
      _update(run, result);
      return ToolOutcome((result['text'] ?? '').toString());
    } catch (error) {
      return ToolOutcome('查询后台任务失败：$error', isError: true);
    }
  }

  Future<ToolOutcome> cancel(String taskId) async {
    final HookRun? run = _runs[taskId];
    if (run == null) return ToolOutcome('未知 task_id：$taskId', isError: true);
    try {
      final Map<String, dynamic> result = await client(
        'exec.command',
        <String, dynamic>{'hook_action': 'cancel', 'task_id': taskId},
        scopeFor(run.agentId, run.sessionId),
      );
      _update(run, result);
      return ToolOutcome((result['text'] ?? '').toString());
    } catch (error) {
      return ToolOutcome('取消后台任务失败：$error', isError: true);
    }
  }

  void _update(HookRun run, Map<String, dynamic> result) {
    if (result['running'] is bool) run.running = result['running'] as bool;
    if (result['exit_code'] is num) {
      run.exitCode = (result['exit_code'] as num).toInt();
    }
  }

  Future<void> _watch(HookRun run) async {
    if (!_watching.add(run.id)) return;
    try {
      while (run.running) {
        await Future<void>.delayed(pollInterval);
        final ToolOutcome outcome = await status(run.id);
        if (outcome.isError && !run.running) break;
      }
      final String notice = <String>[
        '[terminal hook] 后台任务已结束：${run.id}',
        '命令：${run.command}',
        if (run.exitCode != null) 'exit_code：${run.exitCode}',
        if (run.logRelative.isNotEmpty) '日志：${run.logRelative}',
        '如需结果请 read 日志文件；本轮由这条完成提示唤醒。',
      ].join('\n');
      try {
        await wake(run.agentId, run.sessionId, notice);
      } catch (_) {}
    } finally {
      _watching.remove(run.id);
    }
  }
}
