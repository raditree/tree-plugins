import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

import 'support/structure_fixture.dart';

void main() {
  late Directory temp;
  late ProductionService service;
  final DateTime fixed = DateTime(2026, 11, 9, 10);

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_pl_service_');
    service = ProductionService(
      environment: const <String, String>{},
      clock: () => fixed,
    );
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Matcher failure(String code) => throwsA(
    isA<ProductionFailure>().having(
      (ProductionFailure error) => error.code,
      'code',
      code,
    ),
  );

  Map<String, Object?> call(
    String command,
    Map<String, Object?> arguments, {
    Map<String, Object?>? meta,
    Map<String, Object?>? scope,
  }) => service.handle(
    command,
    arguments,
    meta ?? <String, Object?>{'data_dir': temp.path},
    scope ?? <String, Object?>{'team_id': 'team_a'},
  );

  group('fail-closed', () {
    test('缺 data_dir ⇒ missing_data_dir', () {
      expect(
        () => service.handle(
          'production.line.list',
          <String, Object?>{},
          <String, Object?>{},
          <String, Object?>{'team_id': 'team_a'},
        ),
        failure('missing_data_dir'),
      );
    });

    test('缺 team_id 不再失败：产线数据落全局作用域（§16）', () {
      final Map<String, Object?> result = call(
        'production.line.list',
        <String, Object?>{},
        scope: <String, Object?>{},
      );
      expect(result['count'], 0);
    });

    test('未知命令 ⇒ unknown_command', () {
      expect(
        () => call('production.nope', <String, Object?>{}),
        failure('unknown_command'),
      );
    });

    test('缺参数 / 非法 id ⇒ invalid_arguments', () {
      expect(
        () => call('production.line.get', <String, Object?>{}),
        failure('invalid_arguments'),
      );
      expect(
        () => call('production.line.get', <String, Object?>{
          'line_id': '../x',
        }),
        failure('invalid_arguments'),
      );
      expect(
        () => call('production.line.create', <String, Object?>{
          'id': 'pl_1',
        }),
        failure('invalid_arguments'),
      );
    });
  });

  test('命令门面走通建线 → 建任务 → 迁移 → 队列 → 恢复 → 台账', () async {
    final Map<String, Object?> line = call(
      'production.line.create',
      <String, Object?>{'id': 'pl_1', 'name': '标准开发流'},
    );
    expect((line['line'] as Map<String, Object?>)['id'], 'pl_1');
    await markLineReady(
      ProductionStore(dataRoot: temp.path, clock: () => fixed),
      'pl_1',
      temp,
    );

    // 扁平参数与 `task` 子对象都接受。
    call('production.task.create', <String, Object?>{
      'line_id': 'pl_1',
      'id': 'T1',
      'title': '底座',
      'status': 'queued',
      'brief': '搭底座',
      'acceptance': <String>['dart analyze 通过'],
      'write_scope': <String>['lib/a'],
    });
    call('production.task.create', <String, Object?>{
      'line_id': 'pl_1',
      'task': <String, Object?>{
        'id': 'T2',
        'title': '后续',
        'status': 'queued',
        'brief': '接后续',
        'acceptance': <String>['测试全绿'],
        'write_scope': <String>['lib/b'],
        'depends_on': <String>['T1'],
      },
    });
    final Map<String, Object?> tasks = call(
      'production.task.list',
      <String, Object?>{'line_id': 'pl_1', 'status': 'queued'},
    );
    expect(tasks['count'], 2);

    final Map<String, Object?> next = call(
      'production.queue.next',
      <String, Object?>{'line_id': 'pl_1'},
    );
    expect(
      ((next['tasks'] as List<Object?>).first as Map<String, Object?>)['id'],
      'T1',
    );
    expect(next['skipped'], hasLength(1));

    call('production.task.transition', <String, Object?>{
      'line_id': 'pl_1',
      'task_id': 'T1',
      'to': 'packing',
    });
    final Map<String, Object?> recovered = call(
      'production.queue.recover',
      <String, Object?>{'line_id': 'pl_1'},
    );
    expect(recovered['count'], 1);
    final Map<String, Object?> runs = call(
      'production.run.list',
      <String, Object?>{'line_id': 'pl_1'},
    );
    expect(runs['count'], 1);
    expect(
      (runs['runs'] as List<Object?>)
          .map((Object? item) => (item as Map<String, Object?>)['status']),
      <String>['interrupted'],
    );

    final Map<String, Object?> rebuilt = call(
      'production.queue.rebuild',
      <String, Object?>{'line_id': 'pl_1'},
    );
    expect(rebuilt['changed'], false);
    expect(rebuilt['queue'], <String>['T1', 'T2']);
  });
}
