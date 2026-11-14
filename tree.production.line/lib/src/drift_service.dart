/// 批次漂移哨兵命令（PC-3F / BG-01~08）：读计划写域、跑纯函数、落证据、停下一批。
///
/// 口径见 `docs/pluginization/production-line-gates.md` §6：
/// - 每批任务完成后（进入下一批前）跑一次；任一哨兵 fail ⇒ 停止派发下一批；
/// - 任务转 `blocked`，首屏显示原因与证据；
/// - 证据落 `<line>/batches/<batchId>/gates/`，最近一次报告落 `<line>/drift.json`。
///
/// 漂移失败**不是命令异常**：`run` 正常返回 `ok:false`（HTTP 200），由 UI
/// 读 `code` / `results` 展示原因；只有参数缺失 / 产线不存在才抛
/// [ProductionFailure]。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'drift.dart';
import 'models.dart';
import 'store.dart';

class ProductionDriftService {
  ProductionDriftService({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// 跑 BG-01~08 并落证据；任一 fail ⇒ 本批 `queued` 任务全部 `blocked`。
  Map<String, Object?> run(
    ProductionStore store,
    Map<String, Object?> arguments,
  ) {
    final String lineId = _argument(arguments, 'line_id');
    store.getLine(lineId);
    final String batchId = textOf(arguments['batch_id']).isEmpty
        ? 'B1'
        : textOf(arguments['batch_id']);
    final List<String> changedFiles = stringsOf(arguments['changed_files']);
    final List<String> plannedWriteScope = _plannedWriteScope(store, lineId);
    final DriftReport report = runDriftSentinels(
      batchId: batchId,
      changedFiles: changedFiles,
      plannedWriteScope: plannedWriteScope,
      apiBaseline: stringsOf(arguments['api_baseline']),
      apiCurrent: stringsOf(arguments['api_current']),
      apiDecisionApproved: arguments['api_decision_approved'] == true,
      schemaBaseline: textOf(arguments['schema_baseline']),
      schemaCurrent: textOf(arguments['schema_current']),
      schemaDecisionApproved: arguments['schema_decision_approved'] == true,
      goldenDiffCount: intOf(arguments['golden_diff_count'], 0),
      goldenTolerance: intOf(arguments['golden_tolerance'], 0),
      newCycles: stringsOf(arguments['new_cycles']),
      layerViolations: stringsOf(arguments['layer_violations']),
      privateImports: stringsOf(arguments['private_imports']),
      dataReconciled: arguments['data_reconciled'] != false,
      docDiffs: stringsOf(arguments['doc_diffs']),
      fileToTask: <String, String>{
        for (final MapEntry<String, Object?> entry
            in plainMap(arguments['file_to_task']).entries)
          entry.key: textOf(entry.value),
      },
    );

    final String checkedAt = store.nowText();
    final Map<String, Object?> snapshot = <String, Object?>{
      ...report.toJson(),
      'line_id': lineId,
      'changed_files': changedFiles,
      'planned_write_scope': plannedWriteScope,
      'checked_at': checkedAt,
    };
    final Map<String, Object?> payloads = <String, Object?>{
      'BG-01': <String, Object?>{
        'changed_files': changedFiles,
        'planned_write_scope': plannedWriteScope,
      },
      'BG-02': <String, Object?>{
        'baseline': stringsOf(arguments['api_baseline']),
        'current': stringsOf(arguments['api_current']),
        'decision_approved': arguments['api_decision_approved'] == true,
      },
      'BG-03': <String, Object?>{
        'baseline': textOf(arguments['schema_baseline']),
        'current': textOf(arguments['schema_current']),
        'decision_approved': arguments['schema_decision_approved'] == true,
      },
      'BG-04': <String, Object?>{
        'diff_count': intOf(arguments['golden_diff_count'], 0),
        'tolerance': intOf(arguments['golden_tolerance'], 0),
      },
      'BG-05': <String, Object?>{
        'new_cycles': stringsOf(arguments['new_cycles']),
        'layer_violations': stringsOf(arguments['layer_violations']),
        'private_imports': stringsOf(arguments['private_imports']),
      },
      'BG-06': <String, Object?>{
        'reconciled': arguments['data_reconciled'] != false,
      },
      'BG-07': <String, Object?>{'doc_diffs': stringsOf(arguments['doc_diffs'])},
      'BG-08': <String, Object?>{
        'changed_files': changedFiles,
        'file_to_task': plainMap(arguments['file_to_task']),
      },
    };
    _writeEvidence(store, lineId, batchId, report, payloads);
    store.writeDrift(lineId, snapshot);

    final List<String> blocked = <String>[];
    if (!report.ok) {
      final String reason = '${report.code}：${_firstMessage(report)}';
      for (final TaskRecord task in store.listTasks(lineId)) {
        if (task.status != TaskStatus.queued) continue;
        store.transition(lineId, task.id, to: TaskStatus.blocked.wire, reason: reason);
        blocked.add(task.id);
      }
    }
    return <String, Object?>{
      'ok': report.ok,
      'code': report.code,
      'results': <Map<String, Object?>>[
        for (final DriftResult result in report.results) result.toJson(),
      ],
      'blocked': blocked,
      'batch_id': batchId,
      'checked_at': checkedAt,
    };
  }

  /// 读最近一次批次门报告；没有记录 ⇒ 明确提示，不伪造通过。
  Map<String, Object?> get(
    ProductionStore store,
    Map<String, Object?> arguments,
  ) {
    final String lineId = _argument(arguments, 'line_id');
    store.getLine(lineId);
    final Map<String, Object?> report = store.readDrift(lineId);
    if (report.isEmpty) {
      return <String, Object?>{
        'ok': true,
        'code': '',
        'results': <Object?>[],
        'batch_id': '',
        'note': '还没有批次门记录',
      };
    }
    return report;
  }

  /// 计划写域并集：取最新 `plans/plan-vN/plan.json` 的 `tasks[].write_scope`。
  /// 没有计划 ⇒ 工作空间根（`**`，与 D2 一致）。
  List<String> _plannedWriteScope(ProductionStore store, String lineId) {
    final List<Map<String, Object?>> versions = store.listPlanVersions(lineId);
    if (versions.isEmpty) return <String>['**'];
    final int version = intOf(versions.last['version'], 0);
    if (version < 1) return <String>['**'];
    final Map<String, Object?> plan = store.readPlanVersion(lineId, version);
    final Object? tasks = plan['tasks'];
    if (tasks is! List) return <String>['**'];
    final List<String> scope = <String>[];
    for (final Object? item in tasks) {
      if (item is! Map) continue;
      for (final String entry in stringsOf(plainMap(item)['write_scope'])) {
        if (!scope.contains(entry)) scope.add(entry);
      }
    }
    return scope.isEmpty ? <String>['**'] : scope;
  }

  void _writeEvidence(
    ProductionStore store,
    String lineId,
    String batchId,
    DriftReport report,
    Map<String, Object?> payloads,
  ) {
    final Directory dir = Directory(store.batchGatesDir(lineId, batchId));
    dir.createSync(recursive: true);
    for (final DriftResult result in report.results) {
      _writeJson(
        File(p.join(dir.path, p.posix.basename(result.evidence))),
        <String, Object?>{
          'id': result.id,
          'ok': result.ok,
          'code': result.code,
          'message': result.message,
          'payload': plainValue(payloads[result.id]) ?? <String, Object?>{},
        },
      );
    }
    _writeJson(
      File(p.join(dir.path, 'drift.json')),
      <String, Object?>{...report.toJson(), 'checked_at': store.nowText()},
    );
  }

  void _writeJson(File file, Map<String, Object?> data) {
    final String content =
        '${const JsonEncoder.withIndent('  ').convert(plainMap(data))}\n';
    final File temp = File(
      '${file.path}.tmp-${_clock().microsecondsSinceEpoch}',
    );
    temp.writeAsStringSync(content, flush: true);
    if (file.existsSync()) file.deleteSync();
    temp.renameSync(file.path);
  }

  String _firstMessage(DriftReport report) {
    for (final DriftResult result in report.results) {
      if (!result.ok) return result.message;
    }
    return '';
  }

  String _argument(Map<String, Object?> arguments, String key) {
    final String value = textOf(arguments[key]);
    if (value.isEmpty) {
      throw ProductionFailure('缺少 $key', code: 'invalid_arguments');
    }
    return value;
  }
}
