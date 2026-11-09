/// 任务队列口径（§7.3 / §6.2）：排序与依赖判据都只依赖 `task.yaml`，可重建。
library;

import 'models.dart';

/// 队列排序：`priority` 降序 → `created_at` 升序 → `id` 升序。
int compareQueueOrder(TaskRecord a, TaskRecord b) {
  final int byPriority = b.priority.compareTo(a.priority);
  if (byPriority != 0) return byPriority;
  final int byCreated = a.createdAt.compareTo(b.createdAt);
  if (byCreated != 0) return byCreated;
  return a.id.compareTo(b.id);
}

/// 取 `queued` 状态并按队列口径排序（不判断依赖是否满足）。
List<TaskRecord> queuedInOrder(Iterable<TaskRecord> tasks) {
  final List<TaskRecord> queued = <TaskRecord>[
    for (final TaskRecord task in tasks)
      if (task.status == TaskStatus.queued) task,
  ]..sort(compareQueueOrder);
  return queued;
}

/// 依赖未完成（不存在也算未完成）的 id 列表；空 = 可以派发。
List<String> missingDependencies(
  TaskRecord task,
  Map<String, TaskStatus> statuses,
) => <String>[
  for (final String dependency in task.dependsOn)
    if (statuses[dependency] != TaskStatus.done) dependency,
];
