import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

TaskRecord taskWithUsage(Map<String, Object?> usage) => TaskRecord(
  <String, Object?>{
    'id': 'T1',
    'title': '预算',
    'status': 'packing',
    'usage': usage,
  },
);

void main() {
  group('预算与软停（P8）', () {
    test('上限为 0 表示不设；有上限时按累计值判超限', () {
      final TaskBudget unlimited = budgetOf(<String, Object?>{
        'max_tokens_per_task': 0,
        'max_minutes_per_task': 0,
      });
      expect(unlimited.unlimited, isTrue);
      final BudgetState ok = budgetStateOf(
        unlimited,
        const BudgetUsage(promptTokens: 999, completionTokens: 999),
      );
      expect(ok.exceeded, isFalse);

      final TaskBudget budget = budgetOf(<String, Object?>{
        'max_tokens_per_task': 100,
        'max_minutes_per_task': 2,
      });
      final BudgetState overTokens = budgetStateOf(
        budget,
        const BudgetUsage(promptTokens: 60, completionTokens: 40),
      );
      expect(overTokens.exceeded, isTrue, reason: '到点即停（>= 上限）');
      expect(overTokens.reasons.single, contains('token'));

      final BudgetState overMinutes = budgetStateOf(
        budget,
        const BudgetUsage(elapsedMs: 120000),
      );
      expect(overMinutes.exceeded, isTrue);
      expect(overMinutes.reasons.single, contains('时长'));
    });

    test('累加用量：多次调用相加，负数按 0 计', () {
      final TaskRecord first = taskWithUsage(<String, Object?>{});
      final Map<String, Object?> afterFirst = addUsage(
        first,
        promptTokens: 30,
        completionTokens: 20,
        elapsedMs: 1500,
      );
      expect(afterFirst['prompt_tokens'], 30);
      expect(afterFirst['completion_tokens'], 20);
      expect(afterFirst['elapsed_ms'], 1500);
      expect(afterFirst['runs'], 1);

      final TaskRecord second = taskWithUsage(afterFirst);
      final Map<String, Object?> afterSecond = addUsage(
        second,
        promptTokens: -5,
        completionTokens: 10,
        elapsedMs: -100,
      );
      expect(afterSecond['prompt_tokens'], 30);
      expect(afterSecond['completion_tokens'], 30);
      expect(afterSecond['elapsed_ms'], 1500);
      expect(afterSecond['runs'], 2);
    });

    test('报告形态：用量、剩余与原因齐全', () {
      final BudgetState state = budgetStateOf(
        const TaskBudget(maxTokens: 100, maxMinutes: 5),
        const BudgetUsage(promptTokens: 80, completionTokens: 30, elapsedMs: 60000),
      );
      final Map<String, Object?> json = renderBudgetState(state);
      expect(json['exceeded'], isTrue);
      expect((json['usage'] as Map<String, Object?>)['tokens'], 110);
      expect(json['remaining_tokens'], 0);
      expect((json['reasons'] as List<String>).length, 1);
    });
  });
}
