import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

TaskRecord task(
  String id, {
  TaskStatus status = TaskStatus.queued,
  int priority = 50,
  String createdAt = '2026-11-09T10:00:00',
  List<String> dependsOn = const <String>[],
}) => TaskRecord(<String, Object?>{
  'id': id,
  'title': id,
  'status': status.wire,
  'priority': priority,
  'created_at': createdAt,
  'depends_on': dependsOn,
});

void main() {
  group('队列排序与依赖', () {
    test('priority 降序 → created_at 升序 → id 升序', () {
      final List<TaskRecord> ordered = queuedInOrder(<TaskRecord>[
        task('low', priority: 10),
        task('b', priority: 50, createdAt: '2026-11-09T10:00:02'),
        task('a', priority: 50, createdAt: '2026-11-09T10:00:02'),
        task('early', priority: 50, createdAt: '2026-11-09T10:00:01'),
      ]);
      expect(
        ordered.map((TaskRecord item) => item.id),
        <String>['early', 'a', 'b', 'low'],
      );
    });

    test('只取 queued（blocked / done / cancelled 不进队列）', () {
      final List<TaskRecord> ordered = queuedInOrder(<TaskRecord>[
        task('q1'),
        task('b1', status: TaskStatus.blocked),
        task('d1', status: TaskStatus.done),
        task('c1', status: TaskStatus.cancelled),
        task('q2', priority: 10),
      ]);
      expect(
        ordered.map((TaskRecord item) => item.id),
        <String>['q1', 'q2'],
      );
    });

    test('依赖未 done（含缺任务）都算未满足', () {
      final Map<String, TaskStatus> statuses = <String, TaskStatus>{
        'A': TaskStatus.done,
        'B': TaskStatus.queued,
      };
      expect(
        missingDependencies(
          task('T', dependsOn: <String>['A']),
          statuses,
        ),
        isEmpty,
      );
      expect(
        missingDependencies(
          task('T', dependsOn: <String>['A', 'B', 'ghost']),
          statuses,
        ),
        <String>['B', 'ghost'],
      );
      expect(missingDependencies(task('T'), statuses), isEmpty);
    });
  });
}
