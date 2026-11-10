import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

TaskRecord task(
  String id, {
  TaskStatus status = TaskStatus.queued,
  int priority = 50,
  String createdAt = '2026-11-09T10:00:00',
  List<String> dependsOn = const <String>[],
  List<String> writeScope = const <String>[],
}) => TaskRecord(<String, Object?>{
  'id': id,
  'title': id,
  'status': status.wire,
  'priority': priority,
  'created_at': createdAt,
  'depends_on': dependsOn,
  'write_scope': writeScope,
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

  group('写域并行判据（P8）', () {
    test('目录语义：上级目录与子文件交叠，兄弟路径不交叠', () {
      expect(writeScopesOverlap(<String>['lib/a'], <String>['lib/a/b.dart']), isTrue);
      expect(writeScopesOverlap(<String>['lib/a/'], <String>['lib/a']), isTrue);
      expect(writeScopesOverlap(<String>['lib/a'], <String>['lib/ab']), isFalse);
      expect(writeScopesOverlap(<String>['lib/a.dart'], <String>['lib/b.dart']), isFalse);
    });

    test('通配规则：`**` 覆盖字面路径，窄通配互不相交', () {
      expect(writeScopesOverlap(<String>['lib/**'], <String>['lib/a.dart']), isTrue);
      expect(writeScopesOverlap(<String>['lib/*.dart'], <String>['lib/a.dart']), isTrue);
      expect(writeScopesOverlap(<String>['lib/*.dart'], <String>['lib/a.md']), isFalse);
      // 两边都是通配：按第一个通配符之前的字面前缀保守判断。
      expect(writeScopesOverlap(<String>['lib/ui/**'], <String>['lib/ui/*.dart']), isTrue);
      expect(writeScopesOverlap(<String>['lib/ui/**'], <String>['lib/io/**']), isFalse);
    });

    test('空写域不参与交叠判断', () {
      expect(writeScopesOverlap(const <String>[], <String>['lib/a']), isFalse);
    });
  });

  group('DAG 派发计划（P8）', () {
    test('依赖未完成的任务不进批次', () {
      final DispatchPlan plan = planDispatch(<TaskRecord>[
        task('A', status: TaskStatus.queued),
        task('B', dependsOn: <String>['A']),
      ], maxParallel: 4);
      expect(plan.batch.map((TaskRecord item) => item.id), <String>['A']);
      expect(
        plan.skipped.single['reason'],
        'depends_on',
      );
    });

    test('写域与在途任务交叠 ⇒ 拒绝并行', () {
      final DispatchPlan plan = planDispatch(<TaskRecord>[
        task('R1', status: TaskStatus.running, writeScope: <String>['lib/a']),
        task('R2', writeScope: <String>['lib/a/b.dart']),
        task('R3', writeScope: <String>['lib/b']),
      ], maxParallel: 4);
      expect(plan.batch.map((TaskRecord item) => item.id), <String>['R3']);
      final Map<String, Object?> skipped = plan.skipped.single;
      expect(skipped['id'], 'R2');
      expect(skipped['reason'], 'write_scope_overlap');
      expect(skipped['with_task'], 'R1');
    });

    test('批次内写域互不相交；槽位用满后其余标 max_parallel', () {
      final DispatchPlan plan = planDispatch(<TaskRecord>[
        task('A', writeScope: <String>['lib/a']),
        task('B', writeScope: <String>['lib/a/x']),
        task('C', writeScope: <String>['lib/c']),
        task('D', writeScope: <String>['lib/d']),
      ], maxParallel: 2);
      expect(plan.batch.map((TaskRecord item) => item.id), <String>['A', 'C']);
      expect(
        plan.skipped.map((Map<String, Object?> item) => item['reason']),
        <String>['write_scope_overlap', 'max_parallel'],
      );
    });

    test('槽位被在途任务占用时不再派发', () {
      final DispatchPlan plan = planDispatch(<TaskRecord>[
        task('X', status: TaskStatus.packed, writeScope: <String>['lib/x']),
        task('Y', writeScope: <String>['lib/y']),
      ], maxParallel: 1);
      expect(plan.batch, isEmpty);
      expect(plan.skipped.single['reason'], 'max_parallel');
      expect(plan.slotsFree, 0);
    });
  });
}
