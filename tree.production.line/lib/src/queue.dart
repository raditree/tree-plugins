/// 任务队列口径（§7.3 / §6.2 / §9.6）：排序、依赖与并行判据都只依赖
/// `task.yaml`，可重建。
library;

import 'execution.dart' show matchesWriteScope, normalizeRelPath;
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

// ── 写域并行判据（§9.6）─────────────────────────────────────────────

/// 两份写域是否**可能写到同一个文件**（空 = 互不相干，允许并行）。
///
/// 判据刻意保守：拿不准就判"交叠"，宁可少并行，也不让两个写者碰同一文件。
/// - 字面路径按目录语义比较：`lib/a` 与 `lib/a/b.dart` 交叠，`lib/a` 与 `lib/ab` 不交叠；
/// - 带 `*` / `?` 的规则用 [matchesWriteScope] 互测；
/// - 两边都是通配规则时，比较第一个通配符之前的字面前缀。
bool writeScopesOverlap(List<String> a, List<String> b) {
  for (final String left in a) {
    for (final String right in b) {
      if (_scopePairOverlaps(left, right)) return true;
    }
  }
  return false;
}

bool _scopePairOverlaps(String a, String b) {
  final String left = normalizeRelPath(a);
  final String right = normalizeRelPath(b);
  if (left.isEmpty || right.isEmpty) return false;
  if (left == right) return true;
  final bool leftGlob = left.contains('*') || left.contains('?');
  final bool rightGlob = right.contains('*') || right.contains('?');
  if (!leftGlob && !rightGlob) return _prefixOverlaps(left, right);
  if (!leftGlob) return matchesWriteScope(left, right);
  if (!rightGlob) return matchesWriteScope(right, left);
  return _prefixOverlaps(_literalPrefix(left), _literalPrefix(right));
}

/// 目录语义的路径交叠：相等，或一方是另一方的上级目录。
bool _prefixOverlaps(String a, String b) {
  final String left = _trimSlash(a);
  final String right = _trimSlash(b);
  if (left.isEmpty || right.isEmpty) return true;
  if (left == right) return true;
  return left.startsWith('$right/') || right.startsWith('$left/');
}

String _trimSlash(String value) {
  String out = value;
  while (out.endsWith('/')) {
    out = out.substring(0, out.length - 1);
  }
  return out;
}

/// 通配规则第一个通配符之前的字面前缀（去掉尾部 `/`）。
String _literalPrefix(String glob) {
  final int index = glob.indexOf(RegExp(r'[*?]'));
  final String prefix = index <= 0 ? '' : glob.substring(0, index);
  return _trimSlash(prefix);
}

// ── DAG 派发（§9.6）────────────────────────────────────────────────

/// 一次派发计划：可并行的批次 + 被跳过的原因 + 当前在途任务。
class DispatchPlan {
  const DispatchPlan({
    required this.batch,
    required this.skipped,
    required this.running,
    required this.maxParallel,
  });

  /// 本轮可以同时派发的任务（写域两两不相交、依赖已满足）。
  final List<TaskRecord> batch;

  /// 不能派发的任务与原因（`depends_on` / `write_scope_overlap` / `max_parallel`）。
  final List<Map<String, Object?>> skipped;

  /// 已占用并行槽位的在途任务（packing / packed / running / gating）。
  final List<TaskRecord> running;

  final int maxParallel;

  int get slotsUsed => running.length;

  int get slotsFree {
    final int free = maxParallel - running.length;
    return free < 0 ? 0 : free;
  }
}

/// 计划本轮派发：依赖已 `done` + 写域与在途任务（以及已入选批次）不相交 +
/// 并行槽位未满。**只读**：不改状态，真正的迁移仍由 `production.task.pack` 做。
DispatchPlan planDispatch(
  Iterable<TaskRecord> tasks, {
  required int maxParallel,
}) {
  final int limit = maxParallel < 1 ? 1 : maxParallel;
  final List<TaskRecord> all = tasks.toList();
  final Map<String, TaskStatus> statuses = <String, TaskStatus>{
    for (final TaskRecord task in all) task.id: task.status,
  };
  final List<TaskRecord> running = <TaskRecord>[
    for (final TaskRecord task in all)
      if (task.status.isInFlight) task,
  ]..sort(compareQueueOrder);
  final List<TaskRecord> reserved = List<TaskRecord>.of(running);
  final List<TaskRecord> batch = <TaskRecord>[];
  final List<Map<String, Object?>> skipped = <Map<String, Object?>>[];
  int slots = limit - running.length;
  if (slots < 0) slots = 0;
  for (final TaskRecord task in queuedInOrder(all)) {
    final List<String> waiting = missingDependencies(task, statuses);
    if (waiting.isNotEmpty) {
      skipped.add(<String, Object?>{
        'id': task.id,
        'reason': 'depends_on',
        'waiting_on': waiting,
      });
      continue;
    }
    TaskRecord? conflict;
    for (final TaskRecord peer in reserved) {
      if (writeScopesOverlap(task.writeScope, peer.writeScope)) {
        conflict = peer;
        break;
      }
    }
    if (conflict != null) {
      skipped.add(<String, Object?>{
        'id': task.id,
        'reason': 'write_scope_overlap',
        'with_task': conflict.id,
        'scope': task.writeScope,
      });
      continue;
    }
    if (slots <= 0) {
      skipped.add(<String, Object?>{
        'id': task.id,
        'reason': 'max_parallel',
        'max_parallel': limit,
      });
      continue;
    }
    batch.add(task);
    reserved.add(task);
    slots -= 1;
  }
  return DispatchPlan(
    batch: batch,
    skipped: skipped,
    running: running,
    maxParallel: limit,
  );
}
