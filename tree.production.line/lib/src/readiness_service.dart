/// L0 复合就绪门命令：`production.readiness.get`（LG-02~07）。
///
/// 判定原则（`docs/pluginization/production-line-gates.md` §3.2 / §0）：
/// - **fail-closed**：docnorm / 去重状态拿不到、指纹一致不了、产物缺失，一律未就绪；
///   绝不把"没查到"当"没问题"，也不接受调用方传 `ready=true`；
/// - LG-01 复用结构门；LG-02/03 来自 `docnorm.baseline`（dry-run）；
///   LG-04 来自 `docnorm.graph.build`（dry-run）；LG-05 来自
///   `production.dedup.status`；LG-06 由工作空间的 `lib/ ↔ test/` 确定性映射生成；
/// - 前置门未过时后续门标 `blocked`（不探测、不假装通过）；
/// - 结论与证据落 `<line>/ready.json`；命令门禁只读这份快照并核对新鲜度。
library;

import 'dart:io';

import 'models.dart';
import 'normalization.dart';
import 'readiness.dart';
import 'service.dart';
import 'store.dart';
import 'structure_service.dart';

/// 就绪门对外开放的命令。
const List<String> kReadinessCommands = <String>['production.readiness.get'];

class ProductionReadinessService {
  ProductionReadinessService({
    Map<String, String>? environment,
    DateTime Function()? clock,
    this.docnorm,
    this.dedupStatus,
  }) : _environment = environment ?? Platform.environment,
       _clock = clock ?? DateTime.now;

  final Map<String, String> _environment;
  final DateTime Function() _clock;

  /// docnorm 站命令（缺失 ⇒ LG-02/03/04 明确未就绪）。
  final DocnormProbe? docnorm;

  /// 逻辑去重状态（缺失 ⇒ LG-05 明确未就绪）。
  final DedupStatusProbe? dedupStatus;

  /// 最近一次探测失败原因（每次探测后立即取走，避免串味）。
  String _probeError = '';

  Future<Map<String, Object?>> handle(
    String command,
    Map<String, Object?> arguments,
    Map<String, Object?> meta,
    Map<String, Object?> scope,
  ) async {
    if (command != 'production.readiness.get') {
      throw ProductionFailure(
        '未知就绪门命令：$command',
        code: 'unknown_command',
      );
    }
    final ProductionTarget target = resolveProductionTarget(
      meta,
      scope,
      _environment,
    );
    final ProductionStore store = ProductionStore(
      dataRoot: target.dataRoot,
      clock: _clock,
    );
    return _evaluate(store, _argument(arguments, 'line_id'), meta, scope);
  }

  Future<Map<String, Object?>> _evaluate(
    ProductionStore store,
    String lineId,
    Map<String, Object?> meta,
    Map<String, Object?> scope,
  ) async {
    LineRecord line = store.getLine(lineId);
    final String workspace = line.workspaceDir;
    final List<Map<String, Object?>> checks = <Map<String, Object?>>[];

    // ── LG-01 结构（stale 则先确定性重审；不伪造结果）────────────────
    String structureError = '';
    StructureStatus? status;
    try {
      final StructureStatus before = structureStatusOf(store, lineId);
      if (before.report == null || before.readiness.stale) {
        handleStructureCommand(
          store,
          'production.structure.reevaluate',
          <String, Object?>{'line_id': lineId},
        );
      }
      status = structureStatusOf(store, lineId);
    } catch (error) {
      structureError = '$error';
    }
    final bool lg01 = status?.ready == true;
    checks.add(
      _check(
        'LG-01',
        '项目结构',
        pass: lg01,
        code: 'structure_not_ready',
        message: lg01
            ? ''
            : (structureError.isNotEmpty
                  ? structureError
                  : '结构报告未通过：${status?.missing.join('、') ?? ''}'),
        missing: lg01 ? const <String>[] : (status?.missing ?? const <String>[]),
        evidence: const <Map<String, Object?>>[
          <String, Object?>{'kind': 'json', 'path': 'structure.json'},
        ],
      ),
    );

    Map<String, Object?>? baseline;
    Map<String, Object?>? graph;
    Map<String, Object?>? dedup;
    TestMap? testMap;
    String baselineError = '';
    String graphError = '';
    String dedupError = '';
    String testMapError = '';

    bool lg02 = false;
    bool lg03 = false;
    bool lg04 = false;
    bool lg05 = false;
    bool lg06 = false;

    if (!lg01) {
      for (final List<String> gate in const <List<String>>[
        <String>['LG-02', '文档归一化'],
        <String>['LG-03', '包图'],
        <String>['LG-04', '文档图'],
        <String>['LG-05', '代码索引'],
        <String>['LG-06', '测试映射'],
      ]) {
        checks.add(
          _check(
            gate[0],
            gate[1],
            pass: false,
            status: 'blocked',
            message: '前置门 LG-01 未通过：跳过探测',
            missing: const <String>['LG-01'],
          ),
        );
      }
    } else {
      baseline = await _probeBaseline(workspace, scope);
      baselineError = baseline == null ? _probeError : '';
      if (baseline != null) {
        graph = await _probeGraph(workspace, scope);
        graphError = graph == null ? _probeError : '';
      } else {
        graphError = '前置 doc_state 未取到：跳过文档图探测';
      }
      dedup = await _probeDedup(lineId, meta, scope);
      dedupError = dedup == null ? _probeError : '';
      try {
        testMap = buildTestMap(workspace);
      } catch (error) {
        testMapError = '测试映射生成失败：$error';
      }

      final Map<String, Object?> docState = plainMap(baseline?['doc_state']);
      final Map<String, Object?> contract = plainMap(baseline?['contract']);
      final Map<String, Object?> packages = plainMap(baseline?['packages']);
      final String baselineHead = textOf(plainMap(baseline?['git'])['head']);
      final int docsTotal = intOf(
        contract['docs'],
        docState['documents'] is Map
            ? (docState['documents'] as Map<Object?, Object?>).length
            : 0,
      );
      final int docStateDocs = docState['documents'] is Map
          ? (docState['documents'] as Map<Object?, Object?>).length
          : 0;
      final bool baselineOk = baseline != null;
      final bool noDocs = baselineOk && docsTotal == 0 && docStateDocs == 0;
      final NormalizationManifest? manifest = latestNormalizationManifest(
        store,
        lineId,
        committedOnly: true,
      );
      final bool committed = manifest != null && manifest.state == 'applied';

      // ── LG-02 文档归一化 ───────────────────────────────────────────
      lg02 = baselineOk && (noDocs || (docStateDocs > 0 && committed));
      final List<String> lg02Missing = <String>[
        if (!baselineOk) 'docnorm',
        if (baselineOk && !noDocs && docStateDocs == 0) 'doc_state',
        if (baselineOk && !noDocs && !committed) 'normalization_commit',
      ];
      checks.add(
        _check(
          'LG-02',
          '文档归一化',
          pass: lg02,
          code: 'docnorm_not_ready',
          message: lg02
              ? (noDocs
                    ? 'no_docs：仓库没有需要归一化的文档'
                    : 'doc_state 已生成，归一化产物已落盘')
              : (baselineError.isNotEmpty
                    ? baselineError
                    : 'docnorm 状态未就绪：${lg02Missing.join('、')}'),
          missing: lg02Missing,
          evidence: <Map<String, Object?>>[
            <String, Object?>{'kind': 'json', 'path': 'docnorm/state.json'},
            if (manifest != null)
              <String, Object?>{
                'kind': 'json',
                'path': normalizationManifestRelativePath(manifest.runId),
              },
          ],
        ),
      );

      // ── LG-03 包图 ─────────────────────────────────────────────────
      final int pkgTotal = intOf(packages['total'], 0);
      final bool pkgDegraded = packages['degraded'] == true;
      final Map<String, Object?> packageStates = plainMap(
        docState['packages'],
      );
      final bool packageStale = packageStates.values.any(
        (Object? item) => item is Map && item['stale'] == true,
      );
      lg03 = baselineOk && !pkgDegraded && !packageStale;
      final List<String> lg03Missing = <String>[
        if (!baselineOk) 'pkg_index',
        if (baselineOk && pkgDegraded) 'pkg_index_degraded',
        if (baselineOk && packageStale) 'pkg_index_stale',
      ];
      checks.add(
        _check(
          'LG-03',
          '包图',
          pass: lg03,
          code: 'index_not_ready',
          message: lg03
              ? (pkgTotal == 0
                    ? 'no_code：没有可索引的包'
                    : 'pkg_index 就绪，stale=false')
              : 'pkg_index 未就绪：${lg03Missing.join('、')}',
          missing: lg03Missing,
          evidence: const <Map<String, Object?>>[
            <String, Object?>{'kind': 'json', 'path': 'graph/pkg_index.json'},
          ],
        ),
      );

      // ── LG-04 文档图 ───────────────────────────────────────────────
      final Map<String, Object?> graphCounts = plainMap(graph?['counts']);
      final String graphHead = textOf(plainMap(graph?['git'])['head']);
      final int graphNodes = intOf(graphCounts['nodes'], 0);
      final int graphDocs = intOf(graphCounts['docs'], docsTotal);
      final int graphPackages = intOf(graphCounts['packages'], pkgTotal);
      final bool graphHeadOk =
          graph != null &&
          (baselineHead.isEmpty ||
              graphHead.isEmpty ||
              graphHead == baselineHead);
      final bool graphHasNodes =
          graphNodes > 0 || (graphDocs == 0 && graphPackages == 0);
      lg04 = baselineOk && graph != null && graphHeadOk && graphHasNodes;
      final List<String> lg04Missing = <String>[
        if (!baselineOk) 'doc_state',
        if (baselineOk && graph == null) 'graph',
        if (baselineOk && graph != null && !graphHeadOk)
          'graph_fingerprint_mismatch',
        if (baselineOk && graph != null && graphHeadOk && !graphHasNodes)
          'graph_nodes',
      ];
      checks.add(
        _check(
          'LG-04',
          '文档图',
          pass: lg04,
          code: 'index_not_ready',
          message: lg04
              ? (graphNodes == 0
                    ? 'no_docs：文档图为空且与 doc_state 指纹一致'
                    : 'graph_* 与 doc_state 指纹一致')
              : (graphError.isNotEmpty
                    ? graphError
                    : '文档图未就绪：${lg04Missing.join('、')}'),
          missing: lg04Missing,
          evidence: const <Map<String, Object?>>[
            <String, Object?>{'kind': 'json', 'path': 'graph/graph_meta.json'},
          ],
        ),
      );

      // ── LG-05 代码索引 / 去重 ──────────────────────────────────────
      final Map<String, Object?> dedupRun = plainMap(dedup?['run']);
      final Map<String, Object?> dedupCounts = plainMap(dedupRun['counts']);
      final int chunks = intOf(dedupCounts['chunks'], 0);
      final int vectors = intOf(dedupCounts['vectors'], 0);
      final String dedupMode = textOf(dedupRun['mode']);
      final bool dedupDegraded =
          dedupRun['degraded'] == true || dedup?['degraded'] == true;
      final String dedupHead = textOf(dedupRun['head_sha']).isNotEmpty
          ? textOf(dedupRun['head_sha'])
          : textOf(dedupRun['base_sha']);
      final bool dedupHeadOk =
          baselineHead.isEmpty ||
          dedupHead.isEmpty ||
          dedupHead == baselineHead;
      lg05 =
          baselineOk &&
          dedup != null &&
          chunks > 0 &&
          (vectors > 0 || dedupMode == 'lexical') &&
          !dedupDegraded &&
          dedupHeadOk;
      final List<String> lg05Missing = <String>[
        if (!baselineOk) 'dedup_index',
        if (baselineOk && dedup == null) 'dedup_index',
        if (dedup != null && chunks == 0) 'dedup_chunks',
        if (dedup != null &&
            chunks > 0 &&
            vectors == 0 &&
            dedupMode != 'lexical')
          'dedup_vectors',
        if (dedup != null && !dedupHeadOk) 'dedup_stale',
        if (dedup != null && dedupDegraded) 'dedup_degraded',
      ];
      checks.add(
        _check(
          'LG-05',
          '代码索引',
          pass: lg05,
          code: 'index_not_ready',
          message: lg05
              ? 'dedup_chunks / dedup_vectors 与基线一致（$chunks 块 / $vectors 向量）'
              : (dedupError.isNotEmpty
                    ? dedupError
                    : '代码索引未就绪：${lg05Missing.join('、')}'),
          missing: lg05Missing,
          evidence: const <Map<String, Object?>>[
            <String, Object?>{'kind': 'json', 'path': 'dedup/index_meta.json'},
          ],
        ),
      );

      // ── LG-06 测试映射 ─────────────────────────────────────────────
      lg06 = testMap != null;
      checks.add(
        _check(
          'LG-06',
          '测试映射',
          pass: lg06,
          code: 'index_not_ready',
          message: lg06
              ? 'test/ ↔ lib/ 映射已生成（${testMap.mapped}/${testMap.libFiles}）'
              : (testMapError.isNotEmpty ? testMapError : '测试映射未生成'),
          missing: lg06 ? const <String>[] : const <String>['test_map'],
          evidence: <Map<String, Object?>>[
            <String, Object?>{
              'kind': 'generated',
              'path': 'graph/test_map.json',
              if (testMap != null) 'counts': testMap.toJson(),
            },
          ],
        ),
      );
    }

    final bool ready = checks.every(
      (Map<String, Object?> check) => check['status'] == 'pass',
    );
    final String graphVersion = status == null
        ? ''
        : '${status.fingerprint}|${normalizationVersionOf(store, lineId)}';
    final List<String> missing = <String>[];
    void addMissing(String value) {
      if (value.isNotEmpty && !missing.contains(value)) missing.add(value);
    }

    for (final Map<String, Object?> check in checks) {
      if (check['status'] == 'pass') continue;
      addMissing(textOf(check['id']));
      for (final String item in stringsOf(check['missing'])) {
        addMissing(item);
      }
    }
    if (graphVersion.isEmpty) addMissing('graph_version');

    // ── LG-07 复合就绪 ───────────────────────────────────────────────
    final bool lg07 = ready && graphVersion.isNotEmpty;
    checks.add(
      _check(
        'LG-07',
        '复合就绪',
        pass: lg07,
        code: 'line_not_ready',
        message: lg07
            ? 'LG-01~06 全过，graph_version 已固定'
            : 'LG-01~06 未全过或 graph_version 缺失',
        missing: lg07 ? const <String>[] : <String>[...missing],
        evidence: const <Map<String, Object?>>[
          <String, Object?>{'kind': 'json', 'path': 'ready.json'},
        ],
      ),
    );

    final bool finalReady = checks.every(
      (Map<String, Object?> check) => check['status'] == 'pass',
    );
    if (!finalReady && !missing.contains('LG-07')) missing.add('LG-07');

    String phase;
    if (!lg01) {
      phase = 'organizing';
    } else if (finalReady) {
      phase = 'ready';
    } else if (lg02) {
      phase = 'indexing';
    } else {
      phase = 'normalizing';
    }
    if (line.effectivePhase != phase) {
      line = store.setLinePhase(lineId, phase);
    }

    final Map<String, Object?> docState = plainMap(baseline?['doc_state']);
    final Map<String, Object?> packages = plainMap(baseline?['packages']);
    final String baselineHead = textOf(plainMap(baseline?['git'])['head']);
    final Map<String, Object?> graphCounts = plainMap(graph?['counts']);
    final Map<String, Object?> dedupRun = plainMap(dedup?['run']);
    final Map<String, Object?> dedupCounts = plainMap(dedupRun['counts']);
    final NormalizationManifest? manifest = latestNormalizationManifest(
      store,
      lineId,
      committedOnly: true,
    );
    final Map<String, Object?> snapshot = <String, Object?>{
      'version': kReadinessVersion,
      'kind': 'line_readiness',
      'line_id': lineId,
      'checked_at': _clock().toIso8601String(),
      'workspace': workspace,
      'phase': phase,
      'ready': finalReady,
      'missing': missing,
      'graph_version': graphVersion,
      'checks': checks,
      'evidence': <String, Object?>{
        'structure': status?.readiness.toJson(),
        'normalization': <String, Object?>{
          'run_id': manifest?.runId ?? '',
          'state': manifest?.state ?? 'none',
          'docs': docState['documents'] is Map
              ? (docState['documents'] as Map<Object?, Object?>).length
              : 0,
        },
        'docnorm': <String, Object?>{
          'code_fingerprint': textOf(baseline?['code_fingerprint']),
          'head': baselineHead,
          'packages': intOf(packages['total'], 0),
          'degraded': packages['degraded'] == true,
        },
        'graph': <String, Object?>{
          'head': textOf(plainMap(graph?['git'])['head']),
          'nodes': intOf(graphCounts['nodes'], 0),
          'edges': intOf(graphCounts['edges'], 0),
        },
        'dedup': <String, Object?>{
          'run_id': textOf(dedupRun['run_id']),
          'chunks': intOf(dedupCounts['chunks'], 0),
          'vectors': intOf(dedupCounts['vectors'], 0),
          'mode': textOf(dedupRun['mode']),
          'head': textOf(dedupRun['head_sha']).isNotEmpty
              ? textOf(dedupRun['head_sha'])
              : textOf(dedupRun['base_sha']),
        },
        'test_map': testMap?.toJson(),
      },
    };
    store.writeReady(lineId, snapshot);
    final List<TaskRecord> tasks = store.listTasks(lineId);
    return <String, Object?>{
      ...snapshot,
      'command': 'production.readiness.get',
      'line': <String, Object?>{
        ...line.toJson(),
        'phase': line.effectivePhase,
        'status': projectLineStatus(line, tasks),
        'ready': finalReady,
      },
    };
  }

  Future<Map<String, Object?>?> _probeBaseline(
    String workspace,
    Map<String, Object?> scope,
  ) async {
    final DocnormProbe? probe = docnorm;
    if (probe == null) {
      _probeError = 'docnorm 通道未接线：无法核对 doc_state';
      return null;
    }
    try {
      return await probe('docnorm.baseline', <String, Object?>{
        'repo': workspace,
        'commit': false,
        'sections': const <Map<String, Object?>>[],
        'indexes': const <Map<String, Object?>>[],
        'rewrite_allowlist': const <String>[],
      }, scope);
    } catch (error) {
      _probeError = 'docnorm.baseline 失败：$error';
      return null;
    }
  }

  Future<Map<String, Object?>?> _probeGraph(
    String workspace,
    Map<String, Object?> scope,
  ) async {
    final DocnormProbe? probe = docnorm;
    if (probe == null) {
      _probeError = 'docnorm 通道未接线：无法核对文档图';
      return null;
    }
    try {
      return await probe('docnorm.graph.build', <String, Object?>{
        'repo': workspace,
        'commit': false,
        'rag': false,
      }, scope);
    } catch (error) {
      _probeError = 'docnorm.graph.build 失败：$error';
      return null;
    }
  }

  Future<Map<String, Object?>?> _probeDedup(
    String lineId,
    Map<String, Object?> meta,
    Map<String, Object?> scope,
  ) async {
    final DedupStatusProbe? probe = dedupStatus;
    if (probe == null) {
      _probeError = '逻辑去重状态通道未接线：无法核对 dedup_chunks / dedup_vectors';
      return null;
    }
    try {
      return await probe(lineId, meta, scope);
    } catch (error) {
      _probeError = 'production.dedup.status 失败：$error';
      return null;
    }
  }

  Map<String, Object?> _check(
    String id,
    String gate, {
    required bool pass,
    String status = '',
    String code = '',
    String message = '',
    List<String> missing = const <String>[],
    List<Map<String, Object?>> evidence = const <Map<String, Object?>>[],
  }) => <String, Object?>{
    'id': id,
    'gate': gate,
    'status': status.isNotEmpty ? status : (pass ? 'pass' : 'fail'),
    'code': pass ? '' : code,
    'message': message,
    'missing': missing,
    'evidence': evidence,
    'checked_at': _clock().toIso8601String(),
  };

  String _argument(Map<String, Object?> arguments, String key) {
    final String value = textOf(arguments[key]);
    if (value.isEmpty) {
      throw ProductionFailure('缺少 $key', code: 'invalid_arguments');
    }
    return value;
  }
}
