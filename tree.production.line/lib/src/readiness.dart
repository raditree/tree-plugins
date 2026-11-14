/// L0 复合就绪门（LG-07）的同步判定：读 `<line>/ready.json` 快照并核对新鲜度。
///
/// 判定口径（`docs/pluginization/production-line-gates.md` §3.2）：
/// - LG-02~07 的证据由 `production.readiness.get` 生成并落 `<line>/ready.json`；
/// - 命令门禁（create / dispatch / pack / run / tick）只读快照，不重复探测模型 / 索引；
/// - 新鲜度指纹 = `structure 工作空间指纹 | normalization <runId>:<state>`：
///   工作空间或归一化版本一变，旧快照立即失效（fail-closed，绝不返回"假 ready"）。
///
/// 这一层不调外部通道，供同步命令门面使用。
library;

import 'models.dart';
import 'normalization.dart';
import 'store.dart';
import 'structure_service.dart';

/// `ready.json` schema 版本。
const int kReadinessVersion = 1;

/// `<line>/ready.json` 的只读投影。
class LineReadinessSnapshot {
  const LineReadinessSnapshot({
    required this.exists,
    required this.ready,
    required this.missing,
    required this.graphVersion,
    required this.phase,
    required this.data,
  });

  final bool exists;
  final bool ready;
  final List<String> missing;
  final String graphVersion;
  final String phase;
  final Map<String, Object?> data;
}

/// 当前就绪指纹：结构工作空间指纹 + 归一化 run/state。
String lineReadinessVersionOf(ProductionStore store, LineRecord line) {
  final StructureStatus status = structureStatusOf(store, line.id);
  final String normalization = normalizationVersionOf(store, line.id);
  return '${status.fingerprint}|$normalization';
}

/// 读快照 + 判新鲜度；不写盘、不探测。
LineReadinessSnapshot readLineReadiness(
  ProductionStore store,
  String lineId,
) {
  final LineRecord line = store.getLine(lineId);
  final Map<String, Object?> raw = store.readReady(lineId);
  if (raw.isEmpty || intOf(raw['version'], 0) != kReadinessVersion) {
    return LineReadinessSnapshot(
      exists: false,
      ready: false,
      missing: const <String>['LG-07', 'line_ready_snapshot'],
      graphVersion: '',
      phase: line.effectivePhase,
      data: const <String, Object?>{},
    );
  }
  final List<String> missing = <String>[];
  final bool sameLine = textOf(raw['line_id']) == lineId;
  if (!sameLine) missing.add('readiness_line_mismatch');
  final String current = lineReadinessVersionOf(store, line);
  final bool stale = textOf(raw['graph_version']) != current;
  if (stale) missing.add('readiness_stale');
  if (line.effectivePhase != 'ready') {
    missing.add('line_phase_${line.effectivePhase}');
  }
  for (final String item in stringsOf(raw['missing'])) {
    if (!missing.contains(item)) missing.add(item);
  }
  final bool ready =
      raw['ready'] == true &&
      sameLine &&
      !stale &&
      line.effectivePhase == 'ready';
  return LineReadinessSnapshot(
    exists: true,
    ready: ready,
    missing: missing,
    graphVersion: textOf(raw['graph_version']),
    phase: line.effectivePhase,
    data: raw,
  );
}

/// 产线是否就绪（供 `line.ready` 投影；失败按未就绪处理）。
bool isLineReady(ProductionStore store, LineRecord line) {
  try {
    return readLineReadiness(store, line.id).ready;
  } catch (_) {
    return false;
  }
}

/// 单任务门禁：`cleanup` 在结构整理期间豁免（organizing 或结构报告未通过 /
/// stale），其余一律要 `line.ready`。
void requireLineReady(
  ProductionStore store,
  LineRecord line, {
  String taskType = 'code',
}) {
  if (taskType == 'cleanup' && _cleanupExempt(store, line)) return;
  final LineReadinessSnapshot snapshot = readLineReadiness(store, line.id);
  if (snapshot.ready) return;
  throw ProductionFailure(
    '产线未就绪（phase=${line.effectivePhase}）：文档归一化与索引构建未通过；'
    '先 production.normalize.plan / apply，再 production.readiness.get',
    code: 'line_not_ready',
    missing: snapshot.missing,
  );
}

/// 批量命令门禁（dispatch / tick）：只要涉及非 cleanup 或已离开 organizing
/// 的 cleanup，就要求 `line.ready`。
void requireLineAllowsTasks(
  ProductionStore store,
  LineRecord line,
  Iterable<TaskRecord> tasks,
) {
  final List<TaskRecord> relevant = <TaskRecord>[
    for (final TaskRecord task in tasks)
      if (_lineGateRelevant(task.status)) task,
  ];
  if (relevant.isEmpty) return;
  final bool cleanupOnly = relevant.every(
    (TaskRecord task) => task.isCleanup,
  );
  if (cleanupOnly && _cleanupExempt(store, line)) return;
  requireLineReady(
    store,
    line,
    taskType: cleanupOnly ? 'cleanup' : 'code',
  );
}

/// cleanup 的豁免口径：仍在整理（organizing）或结构报告未通过 / stale。
///
/// 结构门本身对 cleanup 无条件放行；这里保持同一语义——结构没理干净时
/// cleanup 是唯一入口，不能被复合就绪门反向卡死。
bool _cleanupExempt(ProductionStore store, LineRecord line) {
  if (line.effectivePhase == 'organizing') return true;
  try {
    return !structureStatusOf(store, line.id).ready;
  } catch (_) {
    return true;
  }
}

bool _lineGateRelevant(TaskStatus status) =>
    status == TaskStatus.queued ||
    status == TaskStatus.blocked ||
    status.isInFlight;
