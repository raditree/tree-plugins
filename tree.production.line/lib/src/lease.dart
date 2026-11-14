/// 任务租约 + fencing token（SG-01）：纯逻辑，不读写盘。
///
/// `ProductionStore` 负责把返回的 [TaskLease] 落到 `task.yaml.lease`；
/// 这里只判断“能不能拿租约 / 当前 token 是否还有效 / 是否该释放”。
///
/// 口径（gates.md §7 SG-01 / §5.2 TG-08）：
/// - 同一任务同时只有一个有效租约；未过期且 owner 不同 ⇒ `duplicate_execution`；
/// - `fencing` 单调递增（跨释放也递增，旧 token 永远无法复活）；
/// - 缺失 / 不匹配 / 已过期 ⇒ `lease_lost`。
library;

import 'models.dart';

/// 一条任务租约。
class TaskLease {
  const TaskLease({
    required this.owner,
    required this.runId,
    required this.fencing,
    required this.expiresAt,
  });

  /// 租约持有者（`line.yaml.executor.agent_id`，缺省 `executor`）。
  final String owner;

  /// 本次运行 id（与 `runs/<run_id>.json`、`gates/<run_id>/gate.json` 对齐）。
  final String runId;

  /// fencing token：每次获取 +1，写入门控 / 台账。
  final int fencing;

  /// 过期时间（ISO8601）。
  final String expiresAt;

  bool expiredAt(DateTime now) {
    final DateTime? at = DateTime.tryParse(expiresAt);
    return at == null || !at.isAfter(now);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'owner': owner,
    'run_id': runId,
    'fencing': fencing,
    'expires_at': expiresAt,
  };

  static TaskLease? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Map<String, Object?> data = plainMap(raw);
    final String owner = textOf(data['owner']);
    if (owner.isEmpty) return null;
    return TaskLease(
      owner: owner,
      runId: textOf(data['run_id']),
      fencing: intOf(data['fencing'], 0),
      expiresAt: textOf(data['expires_at']),
    );
  }
}

/// 获取租约（纯函数）：冲突 ⇒ `duplicate_execution`，否则返回新租约。
///
/// [previousFencing] 是 `task.yaml.lease_fencing` 的历史水位：释放后租约键被
/// 删掉，但水位保留，保证下一次 fencing 仍然递增。
TaskLease acquireTaskLease({
  Object? existing,
  required String owner,
  required String runId,
  required DateTime now,
  required Duration ttl,
  int previousFencing = 0,
}) {
  final TaskLease? current = TaskLease.tryParse(existing);
  if (current != null && !current.expiredAt(now) && current.owner != owner) {
    throw ProductionFailure(
      '任务租约被 ${current.owner} 占用（fencing=${current.fencing}，'
      '到期 ${current.expiresAt}）：同一任务同时只允许一个执行者',
      code: 'duplicate_execution',
    );
  }
  final int base = current != null && current.fencing > previousFencing
      ? current.fencing
      : previousFencing;
  return TaskLease(
    owner: owner,
    runId: runId,
    fencing: base + 1,
    expiresAt: now.add(ttl).toIso8601String(),
  );
}

/// 校验 fencing token（纯函数）：缺失 / 不匹配 / 已过期 ⇒ `lease_lost`。
void assertTaskLease({
  Object? existing,
  required int fencing,
  required DateTime now,
  required String taskId,
}) {
  final TaskLease? current = TaskLease.tryParse(existing);
  if (current == null ||
      current.fencing != fencing ||
      current.expiredAt(now)) {
    final String reason = current == null
        ? '任务没有有效租约'
        : (current.expiredAt(now)
              ? '租约已过期（到期 ${current.expiresAt}）'
              : 'fencing 不匹配（当前 ${current.fencing}，请求 $fencing）');
    throw ProductionFailure(
      '租约校验失败：$reason（任务 $taskId）',
      code: 'lease_lost',
      missing: <String>[taskId],
    );
  }
}

/// 只匹配 fencing 的租约才可释放；不匹配 / 不存在 ⇒ null。
TaskLease? matchTaskLease({Object? existing, required int fencing}) {
  final TaskLease? current = TaskLease.tryParse(existing);
  if (current == null || current.fencing != fencing) return null;
  return current;
}
