/// 稳定性控制面的纯函数（SG-05 / SG-06）：
/// 换模型黄金任务的契约形状校验，以及恢复 / blocked / retry 指标。
library;

import 'models.dart';
import 'store.dart';

/// 门控结果（`gate.json`）的固定契约：缺任一键即 `model_swap_regression`。
const List<String> kGateContractKeys = <String>[
  'version',
  'run_id',
  'runner_id',
  'fencing',
  'started_at',
  'finished_at',
  'ok',
  'commands',
  'checklist',
  'evidence_hashes',
];

/// 默认恢复 SLO（ms）；`line.yaml.limits.recovery_slo_ms` 可覆盖。
const int kDefaultRecoverySloMs = 60000;

/// 黄金任务报告：只验证固定契约，不猜模型内容。
///
/// 两次不同 `modelId` 的报告拿 `gate_shape` 对比即可；形状不一致（缺键）⇒
/// `model_swap_regression`。`ok` 同时要求黄金任务本身通过且门控通过。
Map<String, Object?> goldenTaskReport({
  required String modelId,
  required Map<String, Object?> gate,
  required bool ok,
  required Map<String, Object?> result,
}) {
  final List<String> shape = gate.keys.toList()..sort();
  final List<String> missing = <String>[
    for (final String key in kGateContractKeys)
      if (!gate.containsKey(key)) key,
  ];
  final bool gateOk = gate['ok'] == true;
  final bool passed = ok && gateOk && missing.isEmpty;
  return <String, Object?>{
    'model_id': modelId,
    'ok': passed,
    if (!passed) 'code': 'model_swap_regression',
    'missing': missing,
    'gate_ok': gateOk,
    'gate_shape': shape,
    'result': plainMap(result),
  };
}

/// 从 runs + task.yaml 统计稳定性指标；恢复耗时 P95 超 SLO ⇒
/// `ok:false, code:'recovery_slo_missed'`。
Map<String, Object?> sloMetrics(ProductionStore store, String lineId) {
  final LineRecord line = store.getLine(lineId);
  final List<Map<String, Object?>> runs = store.listRuns(lineId);
  final List<TaskRecord> tasks = store.listTasks(lineId);
  final int sloMs = intOf(
    plainMap(line.data['limits'])['recovery_slo_ms'],
    kDefaultRecoverySloMs,
  );

  final List<int> recoveryTimes = <int>[];
  int recoveryCount = 0;
  for (final Map<String, Object?> run in runs) {
    final bool interrupted = textOf(run['status']) == 'interrupted';
    final bool hasRecovery = run['recovery_ms'] != null;
    if (!interrupted && !hasRecovery) continue;
    if (interrupted) recoveryCount += 1;
    recoveryTimes.add(
      intOf(run['recovery_ms'], intOf(run['elapsed_ms'], 0)),
    );
  }
  recoveryTimes.sort();
  final int p95 = recoveryTimes.isEmpty
      ? 0
      : recoveryTimes[((recoveryTimes.length - 1) * 0.95).floor()];

  int blockedCount = 0;
  int retryCount = 0;
  for (final TaskRecord task in tasks) {
    if (task.status == TaskStatus.blocked) blockedCount += 1;
    retryCount += intOf(task.data['gate_attempts'], 0);
    retryCount += task.loopAttempts;
  }

  final int totalRuns = runs.length;
  final bool ok = p95 <= sloMs;
  return <String, Object?>{
    'line_id': lineId,
    'ok': ok,
    if (!ok) 'code': 'recovery_slo_missed',
    'recovery_count': recoveryCount,
    'recovery_ms_p95': p95,
    'recovery_slo_ms': sloMs,
    'blocked_count': blockedCount,
    'retry_count': retryCount,
    'rate': totalRuns == 0 ? 0.0 : recoveryCount / totalRuns,
    'runs': totalRuns,
  };
}
