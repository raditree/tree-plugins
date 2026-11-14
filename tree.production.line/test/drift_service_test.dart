import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

void main() {
  late Directory temp;
  late String workspace;
  late ProductionStore store;
  late ProductionDriftService service;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_pl_drift_');
    workspace = p.join(temp.path, 'ws');
    Directory(workspace).createSync(recursive: true);
    store = ProductionStore(
      dataRoot: temp.path,
      clock: () => DateTime(2026, 11, 14, 10),
    );
    store.createLine(<String, Object?>{
      'id': 'pl_d',
      'name': '漂移产线',
      'workspace_dir': workspace,
    });
    store.createTask('pl_d', <String, Object?>{
      'id': 'T1',
      'title': '改 T1',
      'status': 'queued',
      'write_scope': <String>['lib/'],
      'acceptance': <String>['dart analyze 无新增'],
    });
    store.createTask('pl_d', <String, Object?>{
      'id': 'T2',
      'title': '改 T2',
      'status': 'queued',
      'write_scope': <String>['lib/a.dart'],
      'acceptance': <String>['dart analyze 无新增'],
    });
    service = ProductionDriftService(
      clock: () => DateTime(2026, 11, 14, 11),
    );
  });

  tearDown(() {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  String gatesDir(String batchId) => p.join(
    temp.path,
    'production_lines',
    'production',
    'pl_d',
    'batches',
    batchId,
    'gates',
  );

  test('run 失败：queued 任务全部 blocked，证据与 drift.json 落盘，get 能读回', () {
    // 计划写域来自最新 plan.json（tasks[].write_scope 的并集）。
    store.writePlanVersion('pl_d', 1, <String, Object?>{
      'tasks': <Map<String, Object?>>[
        <String, Object?>{'id': 'T1', 'write_scope': <String>['lib/']},
      ],
    });
    store.createTask('pl_d', <String, Object?>{
      'id': 'T3',
      'title': '已取消',
      'status': 'queued',
      'write_scope': <String>['lib/'],
    });
    store.transition('pl_d', 'T3', to: 'cancelled', reason: '用户取消');

    final Map<String, Object?> result = service.run(store, <String, Object?>{
      'line_id': 'pl_d',
      'batch_id': 'B2',
      'changed_files': <String>['docs/x.md'],
      'file_to_task': <String, Object?>{'docs/x.md': 'T1'},
    });
    expect(result['ok'], isFalse);
    expect(result['code'], 'drift_scope');
    expect(result['batch_id'], 'B2');
    expect(
      (result['blocked'] as List<dynamic>).toSet(),
      <Object?>{'T1', 'T2'},
      reason: '在途 / 终态任务不受影响',
    );
    for (final String id in <String>['T1', 'T2']) {
      final TaskRecord task = store.getTask('pl_d', id);
      expect(task.status, TaskStatus.blocked);
      expect(task.blockedReason, startsWith('drift_scope：'));
    }
    expect(store.getTask('pl_d', 'T3').status, TaskStatus.cancelled);

    // 证据：8 个哨兵文件 + drift.json + 最新的 <line>/drift.json。
    final Directory dir = Directory(gatesDir('B2'));
    expect(dir.existsSync(), isTrue);
    for (final String name in <String>[
      'scope.diff',
      'api.diff',
      'schema.sha256',
      'golden.diff',
      'dependency.diff',
      'data_reconcile.json',
      'doc.diff',
      'traceability.json',
      'drift.json',
    ]) {
      expect(
        File(p.join(dir.path, name)).existsSync(),
        isTrue,
        reason: '缺证据文件 $name',
      );
    }
    final Map<String, Object?> scopeEvidence =
        jsonDecode(
              File(p.join(dir.path, 'scope.diff')).readAsStringSync(),
            )
            as Map<String, Object?>;
    expect(scopeEvidence['id'], 'BG-01');
    expect(scopeEvidence['ok'], isFalse);
    expect(scopeEvidence['code'], 'drift_scope');
    expect(
      (scopeEvidence['payload'] as Map<String, Object?>)['planned_write_scope'],
      <String>['lib/'],
    );

    final Map<String, Object?> drift = store.readDrift('pl_d');
    expect(drift['ok'], isFalse);
    expect(drift['batch_id'], 'B2');
    expect(drift['checked_at'], isNotEmpty);
    expect((drift['results'] as List<dynamic>).length, 8);

    final Map<String, Object?> got = service.get(store, <String, Object?>{
      'line_id': 'pl_d',
    });
    expect(got['ok'], isFalse);
    expect(got['batch_id'], 'B2');
    expect(got['code'], 'drift_scope');
    expect((got['results'] as List<dynamic>).length, 8);
  });

  test('run 全过：任务状态不变，drift.json 记录 ok', () {
    store.writePlanVersion('pl_d', 1, <String, Object?>{
      'tasks': <Map<String, Object?>>[
        <String, Object?>{'id': 'T1', 'write_scope': <String>['lib/']},
      ],
    });
    final Map<String, Object?> result = service.run(store, <String, Object?>{
      'line_id': 'pl_d',
      'batch_id': 'B1',
      'changed_files': <String>['lib/a.dart'],
      'file_to_task': <String, Object?>{'lib/a.dart': 'T1'},
    });
    expect(result['ok'], isTrue);
    expect(result['code'], '');
    expect(result['blocked'], isEmpty);
    expect(store.getTask('pl_d', 'T1').status, TaskStatus.queued);
    expect(store.getTask('pl_d', 'T2').status, TaskStatus.queued);
    expect(store.readDrift('pl_d')['ok'], isTrue);
    expect(service.get(store, <String, Object?>{'line_id': 'pl_d'})['ok'], isTrue);
  });

  test('没有计划 ⇒ 写域按工作空间根（**）', () {
    final Map<String, Object?> result = service.run(store, <String, Object?>{
      'line_id': 'pl_d',
      'changed_files': <String>['anything/x.md'],
      'file_to_task': <String, Object?>{'anything/x.md': 'T1'},
    });
    expect(result['ok'], isTrue);
    expect(
      store.readDrift('pl_d')['planned_write_scope'],
      <String>['**'],
    );
  });

  test('get：还没有批次门记录', () {
    final Map<String, Object?> got = service.get(store, <String, Object?>{
      'line_id': 'pl_d',
    });
    expect(got['ok'], isTrue);
    expect(got['code'], '');
    expect(got['batch_id'], '');
    expect(got['results'], isEmpty);
    expect(got['note'], '还没有批次门记录');
  });
}
