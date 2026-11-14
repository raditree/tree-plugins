/// 批次漂移哨兵 BG-01~08（PC-3F）：纯函数，不读盘、不写盘。
///
/// 口径见 `docs/pluginization/production-line-gates.md` §6 与附录 A.4：
/// 每批任务完成后跑一次；任一哨兵 fail 就停止派发下一批，任务转 `blocked`，
/// 首屏显示原因与证据。`evidence` 是相对产线资产目录的证据路径，由
/// `drift_service.dart` 落成真正的 JSON 文件。
library;

import 'execution.dart' show matchesWriteScope, normalizeRelPath;

/// 一条哨兵的判定结果。
class DriftResult {
  const DriftResult({
    required this.id,
    required this.code,
    required this.message,
    required this.evidence,
    required this.ok,
  });

  /// 哨兵编号（BG-01~BG-08）。
  final String id;

  /// 失败码；通过时为空串。
  final String code;

  final String message;

  /// 证据路径（相对产线目录，如 `batches/B1/gates/scope.diff`）。
  final String evidence;

  final bool ok;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'ok': ok,
    'code': code,
    'message': message,
    'evidence': evidence,
  };
}

/// 一次批次门报告。
class DriftReport {
  const DriftReport({required this.batchId, required this.results});

  final String batchId;
  final List<DriftResult> results;

  bool get ok => results.every((DriftResult result) => result.ok);

  /// 第一条 fail 的失败码；全过 ⇒ 空串。
  String get code {
    for (final DriftResult result in results) {
      if (!result.ok) return result.code;
    }
    return '';
  }

  /// `checked_at` 由调用方补（纯函数留空）。
  Map<String, Object?> toJson() => <String, Object?>{
    'ok': ok,
    'batch_id': batchId,
    'code': code,
    'results': <Map<String, Object?>>[
      for (final DriftResult result in results) result.toJson(),
    ],
    'checked_at': '',
  };
}

/// 跑一遍 BG-01~08（顺序固定），返回逐项结果。
///
/// 判据（与 gates.md §6 一致）：
/// - BG-01 范围漂移：`changedFiles ⊆ plannedWriteScope`；空写域按 `**`；
/// - BG-02 API 漂移：公共 API 集合相等，或 `apiDecisionApproved`；
/// - BG-03 Schema 漂移：checksum 相等（都空也算），或 `schemaDecisionApproved`；
/// - BG-04 Golden 漂移：`goldenDiffCount <= goldenTolerance`；
/// - BG-05 依赖图漂移：无新增环 / 分层违规 / 跨包私有引用；
/// - BG-06 数据漂移：对账通过；
/// - BG-07 文档漂移：文档 diff 为空；
/// - BG-08 追踪完整：每个改动都能映射到任务。
DriftReport runDriftSentinels({
  required String batchId,
  required List<String> changedFiles,
  required List<String> plannedWriteScope,
  List<String> apiBaseline = const <String>[],
  List<String> apiCurrent = const <String>[],
  bool apiDecisionApproved = false,
  String schemaBaseline = '',
  String schemaCurrent = '',
  bool schemaDecisionApproved = false,
  int goldenDiffCount = 0,
  int goldenTolerance = 0,
  List<String> newCycles = const <String>[],
  List<String> layerViolations = const <String>[],
  List<String> privateImports = const <String>[],
  bool dataReconciled = true,
  Map<String, Object?> dataReconcile = const <String, Object?>{},
  List<String> docDiffs = const <String>[],
  Map<String, String> fileToTask = const <String, String>{},
}) {
  final List<String> changes = <String>[
    for (final String file in changedFiles)
      if (normalizeRelPath(file).isNotEmpty) normalizeRelPath(file),
  ];
  // D2 口径：空写域 = 工作空间根（`**`），不判失败。
  final List<String> scope = plannedWriteScope.isEmpty
      ? const <String>['**']
      : plannedWriteScope;
  String gate(String name) => 'batches/$batchId/gates/$name';

  final List<DriftResult> results = <DriftResult>[];

  // BG-01 范围漂移
  final List<String> outside = <String>[
    for (final String file in changes)
      if (!scope.any((String rule) => matchesWriteScope(file, rule))) file,
  ];
  results.add(
    DriftResult(
      id: 'BG-01',
      code: outside.isEmpty ? '' : 'drift_scope',
      message: outside.isEmpty
          ? '本批改动全部落在计划写域内（${changes.length} 个文件）'
          : '范围漂移：${outside.take(8).join('、')} 不在计划写域',
      evidence: gate('scope.diff'),
      ok: outside.isEmpty,
    ),
  );

  // BG-02 API 漂移
  final Set<String> apiBefore = _setOf(apiBaseline);
  final Set<String> apiAfter = _setOf(apiCurrent);
  final List<String> apiAdded = apiAfter.difference(apiBefore).toList()..sort();
  final List<String> apiRemoved = apiBefore.difference(apiAfter).toList()
    ..sort();
  final bool apiSame = apiAdded.isEmpty && apiRemoved.isEmpty;
  final bool apiOk = apiSame || apiDecisionApproved;
  results.add(
    DriftResult(
      id: 'BG-02',
      code: apiOk ? '' : 'drift_api',
      message: apiOk
          ? (apiDecisionApproved && !apiSame
                ? '公共 API 有变更，但 DEC 已批准'
                : '公共 API 集合与冻结清单一致')
          : 'API 漂移：新增 ${apiAdded.length} 项、删除 ${apiRemoved.length} 项，且无批准 DEC',
      evidence: gate('api.diff'),
      ok: apiOk,
    ),
  );

  // BG-03 Schema 漂移
  final bool schemaOk = schemaBaseline == schemaCurrent || schemaDecisionApproved;
  results.add(
    DriftResult(
      id: 'BG-03',
      code: schemaOk ? '' : 'drift_schema',
      message: schemaOk
          ? (schemaBaseline == schemaCurrent
                ? 'schema checksum 与基线一致'
                : 'schema 有变更，但迁移单已批准')
          : 'Schema 漂移：checksum 与基线不一致，且无批准迁移单',
      evidence: gate('schema.sha256'),
      ok: schemaOk,
    ),
  );

  // BG-04 Golden 漂移
  final bool goldenOk = goldenDiffCount <= goldenTolerance;
  results.add(
    DriftResult(
      id: 'BG-04',
      code: goldenOk ? '' : 'drift_behavior',
      message: goldenOk
          ? 'golden 输出无差异（diff=$goldenDiffCount，容差=$goldenTolerance）'
          : 'Golden 漂移：diff=$goldenDiffCount 超出容差 $goldenTolerance',
      evidence: gate('golden.diff'),
      ok: goldenOk,
    ),
  );

  // BG-05 依赖图漂移
  final bool dependencyOk = newCycles.isEmpty &&
      layerViolations.isEmpty &&
      privateImports.isEmpty;
  results.add(
    DriftResult(
      id: 'BG-05',
      code: dependencyOk ? '' : 'drift_dependency',
      message: dependencyOk
          ? '依赖图无新增环、无分层违规、无跨包私有引用'
          : '依赖图漂移：新增环 ${newCycles.length}、分层违规 '
                '${layerViolations.length}、跨包私有引用 ${privateImports.length}',
      evidence: gate('dependency.diff'),
      ok: dependencyOk,
    ),
  );

  // BG-06 数据漂移
  results.add(
    DriftResult(
      id: 'BG-06',
      code: dataReconciled ? '' : 'drift_data',
      message: dataReconciled
          ? '迁移前后对账通过'
          : '数据漂移：迁移前后行数 / 校验和 / 不变量对账未通过'
                '${dataReconcile.isEmpty ? '' : '：${dataReconcile.keys.join('、')}'}',
      evidence: gate('data_reconcile.json'),
      ok: dataReconciled,
    ),
  );

  // BG-07 文档漂移
  final bool docOk = docDiffs.isEmpty;
  results.add(
    DriftResult(
      id: 'BG-07',
      code: docOk ? '' : 'drift_doc',
      message: docOk
          ? '契约 / README / 决策记录与代码一致'
          : '文档漂移：${docDiffs.take(8).join('、')}',
      evidence: gate('doc.diff'),
      ok: docOk,
    ),
  );

  // BG-08 追踪完整
  final Set<String> traceable = <String>{
    for (final String path in fileToTask.keys)
      if (normalizeRelPath(path).isNotEmpty) normalizeRelPath(path),
  };
  final List<String> untraceable = <String>[
    for (final String file in changes)
      if (!traceable.contains(file)) file,
  ];
  final bool traceableOk = untraceable.isEmpty;
  results.add(
    DriftResult(
      id: 'BG-08',
      code: traceableOk ? '' : 'drift_untraceable',
      message: traceableOk
          ? '每个改动都能映射到任务（${changes.length} 个文件）'
          : '存在无法追踪的改动：${untraceable.take(8).join('、')}',
      evidence: gate('traceability.json'),
      ok: traceableOk,
    ),
  );

  return DriftReport(batchId: batchId, results: results);
}

Set<String> _setOf(Iterable<String> values) => <String>{
  for (final String value in values)
    if (value.trim().isNotEmpty) value.trim(),
};
