import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

void main() {
  late Directory temp;
  late ProductionStore store;
  final DateTime fixed = DateTime(2026, 11, 9, 10);

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_pl_store_');
    store = ProductionStore(
      dataRoot: temp.path,
      clock: () => fixed,
    );
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  File lineFile(String lineId, [String name = 'line.yaml']) => File(
    <String>[
      temp.path,
      'production_lines',
      'production',
      lineId,
      name,
    ].join(Platform.pathSeparator),
  );

  Matcher failure(String code) => throwsA(
    isA<ProductionFailure>().having(
      (ProductionFailure error) => error.code,
      'code',
      code,
    ),
  );

  group('产线', () {
    test('create 落 line.yaml + tasks/ + runs/ + inbox.jsonl，默认配置可读回', () {
      final LineRecord line = store.createLine(<String, Object?>{
        'id': 'pl_1',
        'name': '标准开发流',
      });
      expect(line.id, 'pl_1');
      expect(line.status, 'idle');
      expect(lineFile('pl_1').existsSync(), isTrue);
      expect(lineFile('pl_1', 'inbox.jsonl').existsSync(), isTrue);
      expect(
        Directory(
          <String>[
            temp.path,
            'production_lines',
            'production',
            'pl_1',
            'tasks',
          ].join(Platform.pathSeparator),
        ).existsSync(),
        isTrue,
      );
      final LineRecord loaded = store.getLine('pl_1');
      expect(loaded.data['limits'], containsPair('max_parallel_tasks', 1));
      expect(loaded.data['limits'], containsPair('max_questions_per_round', 3));
      expect(loaded.data['policy'], containsPair('allow_git_write', false));
      expect(loaded.data['docs'], containsPair('asset_dir', 'docs/production_lines'));
      expect(store.listLines().map((LineRecord item) => item.id), <String>['pl_1']);
    });

    test('executor 随 line.yaml 落盘；PATCH 浅合并；未知键拒绝（§16）', () {
      final LineRecord line = store.createLine(<String, Object?>{
        'id': 'pl_x',
        'name': 'x',
        'executor': <String, Object?>{
          'agent_id': 'agt_a',
          'team_id': 'team_a',
        },
      });
      expect(line.executorAgentId, 'agt_a');
      expect(line.executorTeamId, 'team_a');

      final LineRecord patched = store.updateLine('pl_x', <String, Object?>{
        'executor': <String, Object?>{'agent_id': 'agt_b'},
      });
      expect(patched.executorAgentId, 'agt_b');
      expect(patched.executorTeamId, 'team_a', reason: '没给的键沿用旧值');

      expect(
        () => store.updateLine('pl_x', <String, Object?>{
          'executor': <String, Object?>{'agent': 'agt_b'},
        }),
        failure('invalid_arguments'),
      );
    });

    test('重复 / 缺 name / 非法 id 都 fail-closed', () {
      store.createLine(<String, Object?>{'id': 'pl_1', 'name': 'x'});
      expect(
        () => store.createLine(<String, Object?>{'id': 'pl_1', 'name': 'y'}),
        failure('line_exists'),
      );
      expect(
        () => store.createLine(<String, Object?>{'id': 'pl_2'}),
        failure('invalid_arguments'),
      );
      expect(
        () => store.createLine(<String, Object?>{'id': '../evil', 'name': 'x'}),
        failure('invalid_arguments'),
      );
      expect(() => store.getLine('pl_nope'), failure('not_found'));
    });
  });

  group('任务', () {
    setUp(() {
      store.createLine(<String, Object?>{'id': 'pl_1', 'name': 'x'});
    });

    test('create 只允许 draft / queued，并补齐默认字段', () {
      final TaskRecord task = store.createTask('pl_1', <String, Object?>{
        'id': 'T1',
        'title': '底座',
        'status': 'queued',
        'priority': 10,
      });
      expect(task.status, TaskStatus.queued);
      expect(task.kind, 'conventional');
      expect(task.priority, 10);
      expect(task.dependsOn, isEmpty);
      expect(task.artifacts, isEmpty);
      final TaskRecord loaded = store.getTask('pl_1', 'T1');
      expect(loaded.title, '底座');
      expect(loaded.createdAt, isNotEmpty);
    });

    test('缺 id 自动生成 T<millis>，重复创建不冲突（D1）', () {
      final TaskRecord first = store.createTask('pl_1', <String, Object?>{
        'title': '一',
      });
      final TaskRecord second = store.createTask('pl_1', <String, Object?>{
        'title': '二',
      });
      expect(first.id, startsWith('T'));
      expect(second.id, startsWith('T'));
      expect(second.id, isNot(first.id));
      expect(
        store.listTasks('pl_1').map((TaskRecord task) => task.id),
        containsAll(<String>[first.id, second.id]),
      );
    });

    test('缺 title / 终态 / 自依赖 / 重复 id 都拒绝', () {
      expect(
        () => store.createTask('pl_1', <String, Object?>{'id': 'T1'}),
        failure('invalid_arguments'),
      );
      expect(
        () => store.createTask('pl_1', <String, Object?>{
          'id': 'T1',
          'title': 'x',
          'status': 'done',
        }),
        failure('invalid_arguments'),
      );
      expect(
        () => store.createTask('pl_1', <String, Object?>{
          'id': 'T1',
          'title': 'x',
          'depends_on': <String>['T1'],
        }),
        failure('invalid_arguments'),
      );
      store.createTask('pl_1', <String, Object?>{'id': 'T1', 'title': 'x'});
      expect(
        () => store.createTask('pl_1', <String, Object?>{'id': 'T1', 'title': 'y'}),
        failure('task_exists'),
      );
      expect(() => store.getTask('pl_1', 'T9'), failure('not_found'));
    });
  });

  group('状态迁移', () {
    setUp(() {
      store.createLine(<String, Object?>{'id': 'pl_1', 'name': 'x'});
      store.createTask('pl_1', <String, Object?>{
        'id': 'T1',
        'title': 'x',
        'status': 'queued',
      });
    });

    test('非法迁移 / blocked 缺理由 / 终态不可再动', () {
      expect(
        () => store.transition('pl_1', 'T1', to: 'done'),
        failure('invalid_transition'),
      );
      expect(
        () => store.transition('pl_1', 'T1', to: 'queued'),
        failure('invalid_transition'),
      );
      expect(
        () => store.transition('pl_1', 'T1', to: 'blocked'),
        failure('reason_required'),
      );
      final Map<String, Object?> blocked = store.transition(
        'pl_1',
        'T1',
        to: 'blocked',
        reason: '依赖未就绪',
      );
      expect(blocked['from'], 'queued');
      expect(blocked['to'], 'blocked');
      expect(store.getTask('pl_1', 'T1').blockedReason, '依赖未就绪');
      store.transition('pl_1', 'T1', to: 'queued');
      expect(store.getTask('pl_1', 'T1').blockedReason, isEmpty);
      for (final String to in <String>[
        'packing',
        'packed',
        'running',
        'gating',
        'done',
      ]) {
        store.transition('pl_1', 'T1', to: to);
        expect(store.getTask('pl_1', 'T1').status.wire, to);
      }
      expect(
        () => store.transition('pl_1', 'T1', to: 'cancelled'),
        failure('terminal_state'),
      );
    });

    test('cancelled 保留在任务列表里（可追溯）', () {
      store.transition('pl_1', 'T1', to: 'cancelled');
      expect(
        store.listTasks('pl_1').map((TaskRecord item) => item.id),
        contains('T1'),
      );
    });
  });

  group('队列与索引', () {
    setUp(() {
      store.createLine(<String, Object?>{'id': 'pl_1', 'name': 'x'});
      store.createTask('pl_1', <String, Object?>{
        'id': 'T1',
        'title': '底座',
        'status': 'queued',
        'priority': 10,
      });
      store.createTask('pl_1', <String, Object?>{
        'id': 'T2',
        'title': '依赖 T1',
        'status': 'queued',
        'priority': 50,
        'depends_on': <String>['T1'],
      });
      store.createTask('pl_1', <String, Object?>{
        'id': 'T3',
        'title': '独立',
        'status': 'queued',
        'priority': 50,
      });
    });

    test('next 按 priority / created_at / id 排序并跳过未满足依赖', () {
      final Map<String, Object?> next = store.next('pl_1', limit: 10);
      expect(next['queue'], <String>['T2', 'T3', 'T1']);
      expect(
        (next['tasks'] as List<Object?>)
            .map((Object? item) => (item as Map<String, Object?>)['id']),
        <String>['T3', 'T1'],
      );
      final Map<String, Object?> skipped =
          (next['skipped'] as List<Object?>).first as Map<String, Object?>;
      expect(skipped['id'], 'T2');
      expect(skipped['waiting_on'], <String>['T1']);
    });

    test('state.json 可由 task.yaml 重建，重复 rebuild 0 写', () {
      expect(store.rebuild('pl_1')['changed'], false);
      final File state = lineFile('pl_1', 'state.json');
      final Map<String, dynamic> index =
          jsonDecode(state.readAsStringSync()) as Map<String, dynamic>;
      expect(index['queue'], <String>['T2', 'T3', 'T1']);
      expect(index['dispatchable'], <String>['T3', 'T1']);
      expect(
        (index['tasks'] as List<dynamic>)
            .map((dynamic item) => (item as Map<String, dynamic>)['id']),
        <String>['T1', 'T2', 'T3'],
      );
      state.writeAsStringSync('{"broken": true}');
      expect(store.rebuild('pl_1')['changed'], true);
      expect(store.rebuild('pl_1')['changed'], false);
      final Map<String, dynamic> restored =
          jsonDecode(state.readAsStringSync()) as Map<String, dynamic>;
      expect(restored['queue'], <String>['T2', 'T3', 'T1']);
    });
  });

  group('崩溃恢复', () {
    setUp(() {
      store.createLine(<String, Object?>{'id': 'pl_1', 'name': 'x'});
      store.createTask('pl_1', <String, Object?>{
        'id': 'X',
        'title': 'x',
        'status': 'queued',
      });
      store.createTask('pl_1', <String, Object?>{
        'id': 'Y',
        'title': 'y',
        'status': 'queued',
      });
      store.transition('pl_1', 'X', to: 'packing');
      store.transition('pl_1', 'Y', to: 'packing');
      store.transition('pl_1', 'Y', to: 'packed');
      store.transition('pl_1', 'Y', to: 'running');
    });

    test('in-flight → queued，按阶段记 packer / executor 台账', () {
      final Map<String, Object?> result = store.recover('pl_1');
      expect(result['count'], 2);
      expect(store.getTask('pl_1', 'X').status, TaskStatus.queued);
      expect(store.getTask('pl_1', 'Y').status, TaskStatus.queued);
      final List<Map<String, Object?>> runs = store.listRuns('pl_1');
      expect(runs.length, 2);
      expect(
        runs.map((Map<String, Object?> run) => run['role']).toSet(),
        <String>{'packer', 'executor'},
      );
      expect(
        runs.map((Map<String, Object?> run) => run['status']).toSet(),
        <String>{'interrupted'},
      );
    });

    test('重复 recover 0 写，台账不重复', () {
      store.recover('pl_1');
      final int before = store.listRuns('pl_1').length;
      expect(store.recover('pl_1')['count'], 0);
      expect(store.listRuns('pl_1').length, before);
      expect(store.listRuns('pl_1', taskId: 'X').length, 1);
      expect(store.listRuns('pl_1', taskId: 'Y').length, 1);
    });
  });

  group('P8 派发计划', () {
    setUp(() {
      store.createLine(<String, Object?>{
        'id': 'pl_q',
        'name': '并行',
        'limits': <String, Object?>{'max_parallel_tasks': 2},
      });
    });

    test('limit 截断的批次成员也出现在 skipped（reason=limit）', () {
      for (final String id in <String>['A', 'B']) {
        store.createTask('pl_q', <String, Object?>{
          'id': id,
          'title': id,
          'status': 'queued',
          'write_scope': <String>['lib/$id'],
        });
      }
      final Map<String, Object?> plan = store.dispatch('pl_q', limit: 1);
      expect(plan['batch_ids'], <String>['A']);
      expect(plan['slots_free'], 2, reason: '派发前空闲槽位');
      final List<Map<String, Object?>> skipped = (plan['skipped'] as List<dynamic>)
          .cast<Map<String, Object?>>();
      expect(skipped.single['id'], 'B');
      expect(skipped.single['reason'], 'limit');
    });

    test('写域交叠 / 空写域按工作根参与交叠，且不改状态', () {
      store.createTask('pl_q', <String, Object?>{
        'id': 'A',
        'title': 'A',
        'status': 'queued',
        'write_scope': <String>['lib/a'],
      });
      store.createTask('pl_q', <String, Object?>{
        'id': 'B',
        'title': 'B',
        'status': 'queued',
        'write_scope': <String>['lib/a/x.dart'],
      });
      store.createTask('pl_q', <String, Object?>{
        'id': 'C',
        'title': 'C',
        'status': 'queued',
      });
      expect(store.getTask('pl_q', 'C').effectiveWriteScope, <String>['**']);
      final Map<String, Object?> plan = store.dispatch('pl_q');
      expect(plan['batch_ids'], <String>['A']);
      final List<Map<String, Object?>> skipped = (plan['skipped'] as List<dynamic>)
          .cast<Map<String, Object?>>();
      expect(
        skipped.map((Map<String, Object?> item) => item['reason']),
        <String>['write_scope_overlap', 'write_scope_overlap'],
      );
      expect(store.getTask('pl_q', 'A').status, TaskStatus.queued);
      expect(store.getTask('pl_q', 'B').status, TaskStatus.queued);
    });
  });

  group('§16 存量迁移', () {
    File legacyLine(String scope, String lineId) => File(
      <String>[
        temp.path,
        'production_lines',
        scope,
        lineId,
        'line.yaml',
      ].join(Platform.pathSeparator),
    );

    void writeLegacy(String scope, String lineId) {
      final File file = legacyLine(scope, lineId);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        encodeYaml(<String, Object?>{
          'id': lineId,
          'name': '旧产线',
          'workspace_dir': '',
          'status': 'idle',
          'roles': <String, Object?>{},
          'limits': <String, Object?>{},
          'policy': <String, Object?>{},
          'docs': <String, Object?>{},
          'created_at': '2026-11-01T00:00:00',
          'updated_at': '2026-11-01T00:00:00',
        }),
      );
      final Directory taskDir = Directory(
        <String>[
          file.parent.path,
          'tasks',
          'T1',
        ].join(Platform.pathSeparator),
      )..createSync(recursive: true);
      File(<String>[taskDir.path, 'task.yaml'].join(Platform.pathSeparator))
          .writeAsStringSync(
            encodeYaml(<String, Object?>{
              'id': 'T1',
              'title': '旧任务',
              'status': 'queued',
              'created_at': '2026-11-01T00:00:00',
              'updated_at': '2026-11-01T00:00:00',
            }),
          );
    }

    test('旧团队目录搬进全局作用域：补 executor、保留任务、留快照、幂等', () {
      writeLegacy('team_a', 'pl_old');
      final Map<String, Object?> first = store.migrateLegacy(
        agentId: 'agt_exec',
        teamId: 'team_exec',
      );
      expect(first['migrated_count'], 1);
      expect(legacyLine('team_a', 'pl_old').existsSync(), isFalse);
      expect(lineFile('pl_old').existsSync(), isTrue);
      final LineRecord line = store.getLine('pl_old');
      expect(line.executorAgentId, 'agt_exec');
      expect(line.executorTeamId, 'team_exec');
      expect(store.listTasks('pl_old').single.id, 'T1');
      expect(
        Directory(
          <String>[
            temp.path,
            'production_lines',
            '.snapshots',
          ].join(Platform.pathSeparator),
        ).existsSync(),
        isTrue,
      );
      final Map<String, dynamic> manifest =
          jsonDecode(File('${first['manifest']}').readAsStringSync())
              as Map<String, dynamic>;
      expect((manifest['migrated'] as List<dynamic>).length, 1);

      final Map<String, Object?> again = store.migrateLegacy(
        agentId: 'agt_exec',
      );
      expect(again['migrated_count'], 0);
      expect(again['note'], contains('全局作用域'));
    });

    test('目标已存在同 id ⇒ 冲突只报不覆盖，源目录不动', () {
      writeLegacy('team_a', 'pl_old');
      store.createLine(<String, Object?>{'id': 'pl_old', 'name': '新产线'});
      final Map<String, Object?> result = store.migrateLegacy(
        agentId: 'agt_exec',
      );
      expect(result['migrated_count'], 0);
      expect((result['conflicts'] as List<Object?>).length, 1);
      expect(store.getLine('pl_old').name, '新产线');
      expect(legacyLine('team_a', 'pl_old').existsSync(), isTrue);
    });

    test('dry_run 只预览；缺 agent 且目录名不可推断 ⇒ executor_required', () {
      writeLegacy('team_a', 'pl_old');
      final Map<String, Object?> preview = store.migrateLegacy(
        agentId: 'agt_exec',
        dryRun: true,
      );
      expect(preview['dry_run'], isTrue);
      expect(preview['migrated_count'], 1);
      expect(legacyLine('team_a', 'pl_old').existsSync(), isTrue);
      expect(lineFile('pl_old').existsSync(), isFalse);

      final Map<String, Object?> refused = store.migrateLegacy();
      expect(refused['migrated_count'], 0);
      expect(
        ((refused['skipped'] as List<Object?>).single as Map<String, Object?>)['reason'],
        'executor_required',
      );
    });

    test('旧目录名是 agt_* 时推断执行 Agent', () {
      writeLegacy('agt_infer', 'pl_old');
      final Map<String, Object?> result = store.migrateLegacy();
      expect(result['migrated_count'], 1);
      expect(store.getLine('pl_old').executorAgentId, 'agt_infer');
    });
  });
}
