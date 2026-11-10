/// 预算与软停（§9.6）：单任务 token / 时长上限的纯函数。
///
/// 口径：
/// - `max_tokens_per_task` 统计**输入 + 输出** token 总量；0 = 不设上限；
/// - `max_minutes_per_task` 统计该任务所有员工调用的墙钟时长总和；0 = 不设；
/// - 用到上限即**软停**：保留当前产出（`pack.json` / 已改文件）→ 任务标
///   `budget_exceeded` 并转 `blocked`，**不静默继续**下一次调用。
library;

import 'models.dart';

/// 产线级的单任务预算（来自 `line.yaml.limits`）。
class TaskBudget {
  const TaskBudget({this.maxTokens = 0, this.maxMinutes = 0});

  final int maxTokens;
  final int maxMinutes;

  bool get unlimited => maxTokens <= 0 && maxMinutes <= 0;
}

/// 任务已累计的预算用量（来自 `task.yaml.usage`）。
class BudgetUsage {
  const BudgetUsage({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.elapsedMs = 0,
    this.runs = 0,
  });

  final int promptTokens;
  final int completionTokens;
  final int elapsedMs;
  final int runs;

  int get tokens => promptTokens + completionTokens;

  double get minutes => elapsedMs / 60000;
}

/// 一次预算判定结果。
class BudgetState {
  const BudgetState({
    required this.budget,
    required this.usage,
    required this.reasons,
  });

  final TaskBudget budget;
  final BudgetUsage usage;

  /// 超限原因（空 = 未超限）。
  final List<String> reasons;

  bool get exceeded => reasons.isNotEmpty;
}

/// 读产线预算（`line.yaml.limits`）。
TaskBudget budgetOf(Map<String, Object?> limits) => TaskBudget(
  maxTokens: intOf(limits['max_tokens_per_task'], 0),
  maxMinutes: intOf(limits['max_minutes_per_task'], 0),
);

/// 读任务已累计用量；旧任务缺 `usage` ⇒ 全 0。
BudgetUsage usageOf(TaskRecord task) {
  final Map<String, Object?> usage = plainMap(task.data['usage']);
  return BudgetUsage(
    promptTokens: intOf(usage['prompt_tokens'], 0),
    completionTokens: intOf(usage['completion_tokens'], 0),
    elapsedMs: intOf(usage['elapsed_ms'], 0),
    runs: intOf(usage['runs'], 0),
  );
}

/// 累加一次员工调用；返回可直接写回 `task.yaml` 的 `usage` 映射。
Map<String, Object?> addUsage(
  TaskRecord task, {
  required int promptTokens,
  required int completionTokens,
  required int elapsedMs,
}) {
  final BudgetUsage current = usageOf(task);
  return <String, Object?>{
    'prompt_tokens': current.promptTokens + (promptTokens < 0 ? 0 : promptTokens),
    'completion_tokens':
        current.completionTokens + (completionTokens < 0 ? 0 : completionTokens),
    'elapsed_ms': current.elapsedMs + (elapsedMs < 0 ? 0 : elapsedMs),
    'runs': current.runs + 1,
  };
}

/// 判定预算是否到点（`>=` 上限即超限：到点就停，不赌下一次）。
BudgetState budgetStateOf(TaskBudget budget, BudgetUsage usage) {
  final List<String> reasons = <String>[];
  if (budget.maxTokens > 0 && usage.tokens >= budget.maxTokens) {
    reasons.add('token 已用 ${usage.tokens} / 上限 ${budget.maxTokens}');
  }
  if (budget.maxMinutes > 0 && usage.minutes >= budget.maxMinutes) {
    reasons.add(
      '时长已用 ${usage.minutes.toStringAsFixed(1)} 分钟 / 上限 ${budget.maxMinutes}',
    );
  }
  return BudgetState(budget: budget, usage: usage, reasons: reasons);
}

/// 前端 / 台账统一形态。
Map<String, Object?> renderBudgetState(BudgetState state) => <String, Object?>{
  'limits': <String, Object?>{
    'max_tokens_per_task': state.budget.maxTokens,
    'max_minutes_per_task': state.budget.maxMinutes,
  },
  'usage': <String, Object?>{
    'prompt_tokens': state.usage.promptTokens,
    'completion_tokens': state.usage.completionTokens,
    'tokens': state.usage.tokens,
    'elapsed_ms': state.usage.elapsedMs,
    'minutes': double.parse(state.usage.minutes.toStringAsFixed(2)),
    'runs': state.usage.runs,
  },
  'remaining_tokens': state.budget.maxTokens > 0
      ? (state.budget.maxTokens - state.usage.tokens < 0
            ? 0
            : state.budget.maxTokens - state.usage.tokens)
      : null,
  'remaining_minutes': state.budget.maxMinutes > 0
      ? (state.budget.maxMinutes - state.usage.minutes < 0
            ? 0
            : double.parse(
                (state.budget.maxMinutes - state.usage.minutes)
                    .toStringAsFixed(2),
              ))
      : null,
  'exceeded': state.exceeded,
  'reasons': state.reasons,
};
