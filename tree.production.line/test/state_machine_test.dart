import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

void main() {
  group('任务状态机（§7.3）', () {
    test('主链 draft → recon → aligning → scoped → queued → packing → packed → running → gating → done', () {
      const List<TaskStatus> chain = <TaskStatus>[
        TaskStatus.draft,
        TaskStatus.recon,
        TaskStatus.aligning,
        TaskStatus.scoped,
        TaskStatus.queued,
        TaskStatus.packing,
        TaskStatus.packed,
        TaskStatus.running,
        TaskStatus.gating,
        TaskStatus.done,
      ];
      for (int index = 0; index + 1 < chain.length; index++) {
        final TaskStatus from = chain[index];
        final TaskStatus to = chain[index + 1];
        expect(
          canTransition(from, to),
          isTrue,
          reason: '${from.wire} → ${to.wire}',
        );
      }
    });

    test('aligning ↔ awaiting_user 可往返（跨日窗口续答）', () {
      expect(canTransition(TaskStatus.aligning, TaskStatus.awaitingUser), isTrue);
      expect(canTransition(TaskStatus.awaitingUser, TaskStatus.aligning), isTrue);
    });

    test('门控失败可回 packed 重试，packed 可回 packing 重打包', () {
      expect(canTransition(TaskStatus.gating, TaskStatus.packed), isTrue);
      expect(canTransition(TaskStatus.packed, TaskStatus.packing), isTrue);
    });

    test('done 只能由 gating 进入', () {
      for (final TaskStatus status in TaskStatus.values) {
        expect(
          canTransition(status, TaskStatus.done),
          status == TaskStatus.gating,
          reason: '${status.wire} → done',
        );
      }
    });

    test('cancelled 可从任意非终态进入，终态不再迁移', () {
      for (final TaskStatus status in TaskStatus.values) {
        if (status.isTerminal) {
          expect(
            kTaskTransitions[status],
            isEmpty,
            reason: '${status.wire} 是终态',
          );
          continue;
        }
        expect(
          canTransition(status, TaskStatus.cancelled),
          isTrue,
          reason: '${status.wire} → cancelled',
        );
      }
    });

    test('blocked 只能回到 awaiting_user / queued / cancelled', () {
      expect(
        allowedTransitions(TaskStatus.blocked),
        <TaskStatus>{
          TaskStatus.awaitingUser,
          TaskStatus.queued,
          TaskStatus.cancelled,
        },
      );
    });

    test('in-flight 恰好是恢复时要回 queued 的四个状态', () {
      expect(
        <TaskStatus>[
          for (final TaskStatus status in TaskStatus.values)
            if (status.isInFlight) status,
        ],
        <TaskStatus>[
          TaskStatus.packing,
          TaskStatus.packed,
          TaskStatus.running,
          TaskStatus.gating,
        ],
      );
    });

    test('未知状态给出可读错误（含允许值）', () {
      expect(
        () => taskStatusOf('nope'),
        throwsA(
          isA<ProductionFailure>()
              .having((ProductionFailure error) => error.code, 'code',
                  'invalid_arguments')
              .having((ProductionFailure error) => error.message, 'message',
                  contains('draft')),
        ),
      );
    });
  });
}
