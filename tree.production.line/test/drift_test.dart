import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

DriftReport _run({
  String batchId = 'B1',
  List<String> changedFiles = const <String>[],
  List<String> plannedWriteScope = const <String>['**'],
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
  List<String> docDiffs = const <String>[],
  Map<String, String> fileToTask = const <String, String>{},
}) => runDriftSentinels(
  batchId: batchId,
  changedFiles: changedFiles,
  plannedWriteScope: plannedWriteScope,
  apiBaseline: apiBaseline,
  apiCurrent: apiCurrent,
  apiDecisionApproved: apiDecisionApproved,
  schemaBaseline: schemaBaseline,
  schemaCurrent: schemaCurrent,
  schemaDecisionApproved: schemaDecisionApproved,
  goldenDiffCount: goldenDiffCount,
  goldenTolerance: goldenTolerance,
  newCycles: newCycles,
  layerViolations: layerViolations,
  privateImports: privateImports,
  dataReconciled: dataReconciled,
  docDiffs: docDiffs,
  fileToTask: fileToTask,
);

DriftResult _of(DriftReport report, String id) =>
    report.results.firstWhere((DriftResult result) => result.id == id);

void main() {
  test('BG-01 范围漂移：写域内通过，写域外失败', () {
    final DriftReport pass = _run(
      changedFiles: <String>['lib/a.dart'],
      plannedWriteScope: <String>['lib/'],
      fileToTask: <String, String>{'lib/a.dart': 'T1'},
    );
    expect(_of(pass, 'BG-01').ok, isTrue);
    expect(_of(pass, 'BG-01').code, isEmpty);

    final DriftReport fail = _run(
      changedFiles: <String>['lib/a.dart', 'docs/x.md'],
      plannedWriteScope: <String>['lib/'],
      fileToTask: <String, String>{
        'lib/a.dart': 'T1',
        'docs/x.md': 'T1',
      },
    );
    expect(_of(fail, 'BG-01').ok, isFalse);
    expect(_of(fail, 'BG-01').code, 'drift_scope');
    expect(_of(fail, 'BG-01').message, contains('docs/x.md'));
    expect(fail.code, 'drift_scope');
  });

  test('BG-01 空写域按工作空间根（**）通过', () {
    final DriftReport report = _run(
      changedFiles: <String>['anything/at/all.dart'],
      plannedWriteScope: const <String>[],
      fileToTask: <String, String>{'anything/at/all.dart': 'T1'},
    );
    expect(_of(report, 'BG-01').ok, isTrue);
    expect(report.ok, isTrue);
  });

  test('BG-02 API 漂移：集合相等 / DEC 批准通过，不一致失败', () {
    expect(
      _run(
        apiBaseline: <String>['A', 'B'],
        apiCurrent: <String>['B', 'A'],
      ).ok,
      isTrue,
    );
    expect(
      _run(
        apiBaseline: <String>['A'],
        apiCurrent: <String>['A', 'B'],
        apiDecisionApproved: true,
      ).ok,
      isTrue,
    );
    final DriftReport fail = _run(
      apiBaseline: <String>['A'],
      apiCurrent: <String>['A', 'B'],
    );
    expect(_of(fail, 'BG-02').code, 'drift_api');
    expect(fail.code, 'drift_api');
  });

  test('BG-03 Schema 漂移：checksum 一致 / 迁移单批准通过', () {
    expect(
      _run(schemaBaseline: 'sha-a', schemaCurrent: 'sha-a').ok,
      isTrue,
    );
    expect(_run().ok, isTrue, reason: '两边都空也算一致');
    expect(
      _run(
        schemaBaseline: 'sha-a',
        schemaCurrent: 'sha-b',
        schemaDecisionApproved: true,
      ).ok,
      isTrue,
    );
    expect(
      _of(
        _run(schemaBaseline: 'sha-a', schemaCurrent: 'sha-b'),
        'BG-03',
      ).code,
      'drift_schema',
    );
  });

  test('BG-04 Golden 漂移：diff 在容差内通过，超出失败', () {
    expect(_run(goldenDiffCount: 2, goldenTolerance: 2).ok, isTrue);
    final DriftReport fail = _run(goldenDiffCount: 3, goldenTolerance: 2);
    expect(_of(fail, 'BG-04').code, 'drift_behavior');
    expect(_of(fail, 'BG-04').message, contains('3'));
  });

  test('BG-05 依赖图漂移：无新增环 / 分层违规 / 私有引用才通过', () {
    expect(_run().ok, isTrue);
    expect(
      _of(_run(newCycles: <String>['a → b → a']), 'BG-05').code,
      'drift_dependency',
    );
    expect(
      _of(_run(layerViolations: <String>['packages/x → plugins/y']), 'BG-05').code,
      'drift_dependency',
    );
    expect(
      _of(_run(privateImports: <String>['pkg/src/_private.dart']), 'BG-05').code,
      'drift_dependency',
    );
  });

  test('BG-06 数据漂移：对账通过才通过', () {
    expect(_run(dataReconciled: true).ok, isTrue);
    expect(_of(_run(dataReconciled: false), 'BG-06').code, 'drift_data');
  });

  test('BG-07 文档漂移：doc diff 为空才通过', () {
    expect(_run().ok, isTrue);
    expect(
      _of(_run(docDiffs: <String>['README.md']), 'BG-07').code,
      'drift_doc',
    );
  });

  test('BG-08 追踪完整：每个改动都要能映射到任务', () {
    expect(
      _run(
        changedFiles: <String>['lib/a.dart'],
        fileToTask: <String, String>{'lib/a.dart': 'T1'},
      ).ok,
      isTrue,
    );
    final DriftReport fail = _run(
      changedFiles: <String>['lib/a.dart', 'lib/b.dart'],
      fileToTask: <String, String>{'lib/a.dart': 'T1'},
    );
    expect(_of(fail, 'BG-08').code, 'drift_untraceable');
    expect(_of(fail, 'BG-08').message, contains('lib/b.dart'));
  });

  test('多条同时失败：code 取第一条，证据路径固定', () {
    final DriftReport report = _run(
      batchId: 'B7',
      changedFiles: <String>['lib/a.dart'],
      plannedWriteScope: <String>['lib/'],
      apiBaseline: <String>['A'],
      apiCurrent: <String>['B'],
      goldenDiffCount: 4,
      goldenTolerance: 0,
      docDiffs: <String>['README.md'],
      fileToTask: <String, String>{'lib/a.dart': 'T1'},
    );
    expect(report.ok, isFalse);
    expect(report.code, 'drift_api', reason: 'BG-02 比 BG-04/07 先判');
    expect(
      report.results.map((DriftResult result) => result.id),
      <String>['BG-01', 'BG-02', 'BG-03', 'BG-04', 'BG-05', 'BG-06', 'BG-07', 'BG-08'],
    );
    expect(_of(report, 'BG-02').evidence, 'batches/B7/gates/api.diff');
    expect(_of(report, 'BG-04').evidence, 'batches/B7/gates/golden.diff');
    expect(_of(report, 'BG-08').evidence, 'batches/B7/gates/traceability.json');
    expect(_of(report, 'BG-01').evidence, 'batches/B7/gates/scope.diff');
    expect(_of(report, 'BG-03').evidence, 'batches/B7/gates/schema.sha256');
    expect(_of(report, 'BG-06').evidence, 'batches/B7/gates/data_reconcile.json');
    expect(_of(report, 'BG-07').evidence, 'batches/B7/gates/doc.diff');
  });

  test('toJson：checked_at 留空、结构稳定', () {
    final Map<String, Object?> json = _run(batchId: 'B3').toJson();
    expect(json['ok'], isTrue);
    expect(json['batch_id'], 'B3');
    expect(json['checked_at'], '');
    expect(json['code'], '');
    expect((json['results'] as List<dynamic>).length, 8);
  });
}
