/// Task 5：任务输入预检、编辑边界、队列计划 / 批量派发、文档边界。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

import 'support/structure_fixture.dart';

void main() {
  late Directory temp;
  late ProductionService service;
  final DateTime fixed = DateTime(2026, 11, 9, 10);

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_pl_task_input_');
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

  ProductionStore newStore() =>
      ProductionStore(dataRoot: temp.path, clock: () => fixed);

  Map<String, Object?> call(
    String command,
    Map<String, Object?> arguments,
  ) => service.handle(
    command,
    arguments,
    <String, Object?>{'data_dir': temp.path},
    <String, Object?>{'team_id': 'team_a'},
  );

  Future<ProductionStore> readyLine({
    String id = 'pl',
    int maxParallel = 1,
  }) async {
    final ProductionStore store = newStore();
    store.createLine(<String, Object?>{
      'id': id,
      'name': '生产线',
      'limits': <String, Object?>{'max_parallel_tasks': maxParallel},
    });
    await markLineReady(store, id, temp);
    return store;
  }

  Future<Map<String, dynamic>> rest(
    String method,
    String path, {
    Map<String, Object?> body = const <String, Object?>{},
    ProductionExecutionService? execution,
    bool awaitDispatch = false,
  }) async {
    final Map<String, dynamic> reply = await handleProductionDelegate(
      <String, dynamic>{
        'method': method,
        'path': path,
        'params': <String, dynamic>{},
        'query': <String, dynamic>{},
        'headers': <String, dynamic>{},
        'scope': <String, dynamic>{'team_id': 'team_a'},
        'workspace_dir': '',
        'data_dir': temp.path,
        'agent_id': '',
        'team_id': 'team_a',
        'request_id': 'task-input-test',
        if (body.isNotEmpty) 'body': jsonEncode(body),
      },
      execution: execution,
      awaitDispatch: awaitDispatch,
    );
    return <String, dynamic>{
      'status': reply['status'],
      'json': jsonDecode('${reply['body']}') as Map<String, dynamic>,
    };
  }

  Map<String, Object?> queuedTask(
    String id, {
    String? writeScope = 'lib/a',
    String type = 'code',
    String brief = '实现一个可验证的改动',
    List<String> acceptance = const <String>['dart analyze 通过'],
  }) => <String, Object?>{
    'id': id,
    'title': id,
    'status': 'queued',
    'task_type': type,
    'brief': brief,
    'acceptance': acceptance,
    if (writeScope != null) 'write_scope': <String>[writeScope],
  };

  group('旧任务兼容与字段持久化', () {
    test('旧 task.yaml 缺新字段时读取为默认值，不报错', () {
      final ProductionStore store = newStore();
      store.createLine(<String, Object?>{'id': 'pl', 'name': '线'});
      final Directory dir = Directory(
        p.join(store.lineDir('pl'), 'tasks', 'T1'),
      )..createSync(recursive: true);
      File(p.join(dir.path, 'task.yaml')).writeAsStringSync(
        encodeYaml(<String, Object?>{
          'id': 'T1',
          'title': '旧任务',
          'status': 'queued',
          'priority': 50,
          'depends_on': <String>[],
          'write_scope': <String>['lib/a'],
          'acceptance': <String>['旧验收'],
          'created_at': '2026-11-01T00:00:00',
          'updated_at': '2026-11-01T00:00:00',
        }),
      );
      final TaskRecord task = store.getTask('pl', 'T1');
      expect(task.taskType, 'code');
      expect(task.brief, '');
      expect(task.references, isEmpty);
      expect(task.attachments, isEmpty);
      expect(task.conflictsWith, isEmpty);
      expect(task.serialGroup, '');
      expect(task.estimatedFiles, 1);
      expect(task.risk, '');
      expect(task.contract, isNull);
      expect(task.rationale, '');
    });

    test('新字段落盘：brief / references / attachments / 范围与拆分字段', () async {
      await readyLine();
      final String sha = 'a' * 64;
      call('production.task.create', <String, Object?>{
        'line_id': 'pl',
        ...queuedTask('T1'),
        'references': <String>['docs/design.md', 'lib/a.dart'],
        'attachments': <Map<String, Object?>>[
          <String, Object?>{
            'path': '.input/production_lines/pl/tasks/T1/attachments/design.png',
            'sha256': sha,
            'size': 245760,
            'type': 'image/png',
          },
        ],
        'conflicts_with': <String>['T9'],
        'serial_group': 'registry',
        'estimated_files': 3,
        'risk': 'medium',
        'contract': 'in: brief; out: patch',
        'rationale': 'REQ-1',
      });
      final Map<String, Object?> saved =
          call('production.task.get', <String, Object?>{
                'line_id': 'pl',
                'task_id': 'T1',
              })['task']
              as Map<String, Object?>;
      expect(saved['brief'], '实现一个可验证的改动');
      expect(saved['references'], <String>['docs/design.md', 'lib/a.dart']);
      expect(saved['read_scope'], containsAll(<String>['docs/design.md', 'lib/a.dart']));
      expect(saved['conflicts_with'], <String>['T9']);
      expect(saved['serial_group'], 'registry');
      expect(saved['estimated_files'], 3);
      expect(saved['risk'], 'medium');
      expect(saved['contract'], 'in: brief; out: patch');
      expect(saved['rationale'], 'REQ-1');
      final List<Object?> attachments = saved['attachments'] as List<Object?>;
      expect(attachments, hasLength(1));
      final Map<String, Object?> attachment =
          attachments.single as Map<String, Object?>;
      expect(attachment['sha256'], sha);
      expect(attachment['size'], 245760);
      expect(attachment['type'], 'image/png');
      expect(attachment['kind'], 'image');
    });
  });

  group('创建 / 编辑预检', () {
    test('queued 任务缺 brief / acceptance 被拒；草稿允许先存', () async {
      await readyLine();
      expect(
        () => call(
          'production.task.create',
          <String, Object?>{
            'line_id': 'pl',
            'id': 'T1',
            'title': '只有标题',
            'status': 'queued',
            'write_scope': <String>['lib/a'],
          },
        ),
        failure('task_input_incomplete'),
      );

      final Map<String, Object?> draft = call(
        'production.task.create',
        <String, Object?>{
          'line_id': 'pl',
          'id': 'T2',
          'title': '草稿',
          'status': 'draft',
        },
      );
      expect(
        (draft['task'] as Map<String, Object?>)['status'],
        'draft',
      );
    });

    test('附件元数据 / 依赖 / 显式 null 写域被拒', () async {
      await readyLine();
      expect(
        () => call('production.task.create', <String, Object?>{
          'line_id': 'pl',
          'id': 'T1',
          'title': '坏附件',
          'status': 'queued',
          'brief': 'x',
          'acceptance': <String>['ok'],
          'write_scope': <String>['lib/a'],
          'attachments': <Map<String, Object?>>[
            <String, Object?>{
              'path': '.input/a.png',
              'sha256': 'not-a-hash',
              'size': 1,
              'type': 'png',
            },
          ],
        }),
        failure('attachment_invalid'),
      );
      expect(
        () => call('production.task.create', <String, Object?>{
          'line_id': 'pl',
          'id': 'T2',
          'title': '坏依赖',
          'status': 'queued',
          'brief': 'x',
          'acceptance': <String>['ok'],
          'write_scope': <String>['lib/b'],
          'depends_on': <String>['T404'],
        }),
        failure('task_dependency_missing'),
      );
      expect(
        () => call('production.task.create', <String, Object?>{
          'line_id': 'pl',
          'id': 'T3',
          'title': '空写域',
          'status': 'queued',
          'brief': 'x',
          'acceptance': <String>['ok'],
          'write_scope': null,
        }),
        failure('task_input_incomplete'),
      );
    });

    test('编辑：清空验收被拒；packed 编辑回 queued 并失效旧包', () async {
      final ProductionStore store = await readyLine();
      call('production.task.create', <String, Object?>{
        'line_id': 'pl',
        ...queuedTask('T1'),
      });
      expect(
        () => call('production.task.update', <String, Object?>{
          'line_id': 'pl',
          'task_id': 'T1',
          'patch': <String, Object?>{'acceptance': <String>[]},
        }),
        failure('task_input_incomplete'),
      );

      call('production.task.create', <String, Object?>{
        'line_id': 'pl',
        ...queuedTask('T2', writeScope: 'lib/b'),
      });
      store.transition('pl', 'T2', to: 'packing');
      store.transition('pl', 'T2', to: 'packed');
      store.writePack('pl', 'T2', <String, Object?>{'version': 1, 'files': <Object?>[]});
      final Map<String, Object?> updated = call(
        'production.task.update',
        <String, Object?>{
          'line_id': 'pl',
          'task_id': 'T2',
          'patch': <String, Object?>{'brief': '改内容'},
        },
      );
      expect(updated['to'], 'queued');
      expect(updated['pack_invalidated'], true);
      expect(
        File(p.join(store.lineDir('pl'), 'tasks', 'T2', 'pack.json'))
            .existsSync(),
        isFalse,
      );
      expect(store.getTask('pl', 'T2').status, TaskStatus.queued);
    });

    test('在途只允许 priority / depends_on；终态只读', () async {
      final ProductionStore store = await readyLine();
      call('production.task.create', <String, Object?>{
        'line_id': 'pl',
        ...queuedTask('T1'),
      });
      call('production.task.create', <String, Object?>{
        'line_id': 'pl',
        ...queuedTask('T2', writeScope: 'lib/b'),
      });
      store.transition('pl', 'T2', to: 'packing');
      store.transition('pl', 'T2', to: 'packed');
      store.transition('pl', 'T2', to: 'running');
      expect(
        () => call('production.task.update', <String, Object?>{
          'line_id': 'pl',
          'task_id': 'T2',
          'patch': <String, Object?>{'brief': '在途改内容'},
        }),
        failure('task_edit_forbidden'),
      );
      final Map<String, Object?> priority = call(
        'production.task.update',
        <String, Object?>{
          'line_id': 'pl',
          'task_id': 'T2',
          'patch': <String, Object?>{'priority': 5},
        },
      );
      expect(
        (priority['task'] as Map<String, Object?>)['priority'],
        5,
      );

      call('production.task.create', <String, Object?>{
        'line_id': 'pl',
        ...queuedTask('T3', writeScope: 'lib/c'),
      });
      for (final String to in <String>['packing', 'packed', 'running', 'gating', 'done']) {
        store.transition('pl', 'T3', to: to);
      }
      expect(
        () => call('production.task.update', <String, Object?>{
          'line_id': 'pl',
          'task_id': 'T3',
          'patch': <String, Object?>{'priority': 1},
        }),
        failure('terminal_state'),
      );
    });

    test('旧 queued 任务只改 priority 不被历史缺字段卡住', () async {
      final ProductionStore store = await readyLine();
      store.createTask('pl', <String, Object?>{
        'id': 'OLD',
        'title': '旧任务',
        'status': 'queued',
      });
      final Map<String, Object?> updated = call(
        'production.task.update',
        <String, Object?>{
          'line_id': 'pl',
          'task_id': 'OLD',
          'patch': <String, Object?>{'priority': 7},
        },
      );
      expect(
        (updated['task'] as Map<String, Object?>)['priority'],
        7,
      );
    });
  });

  group('文档边界（AG-05）', () {
    test('code 任务写 docs/** 被拒；docs 任务必须显式且只含文档', () async {
      await readyLine();
      expect(
        () => call('production.task.create', <String, Object?>{
          'line_id': 'pl',
          ...queuedTask('C1', writeScope: 'docs/design.md'),
        }),
        failure('docs_scope_forbidden'),
      );
      expect(
        () => call('production.task.create', <String, Object?>{
          'line_id': 'pl',
          ...queuedTask('D1', type: 'docs', writeScope: null),
        }),
        failure('docs_scope_required'),
      );
      expect(
        () => call('production.task.create', <String, Object?>{
          'line_id': 'pl',
          ...queuedTask('D2', type: 'docs', writeScope: '**'),
        }),
        failure('docs_scope_forbidden'),
      );
      expect(
        () => call('production.task.create', <String, Object?>{
          'line_id': 'pl',
          ...queuedTask('D3', type: 'docs', writeScope: 'lib/a.dart'),
        }),
        failure('docs_scope_forbidden'),
      );
      call('production.task.create', <String, Object?>{
        'line_id': 'pl',
        ...queuedTask('D4', type: 'docs', writeScope: 'docs/**'),
      });
      call('production.task.create', <String, Object?>{
        'line_id': 'pl',
        ...queuedTask('D5', type: 'docs', writeScope: 'README.md'),
      });
      expect(newStore().getTask('pl', 'D4').taskType, 'docs');
      expect(newStore().getTask('pl', 'D5').writeScope, <String>['README.md']);
    });

    test('同文档的两个 docs 任务不能同批（写域交叠）', () async {
      await readyLine(id: 'pl_docs', maxParallel: 4);
      call('production.task.create', <String, Object?>{
        'line_id': 'pl_docs',
        ...queuedTask('D1', type: 'docs', writeScope: 'docs/spec.md'),
      });
      call('production.task.create', <String, Object?>{
        'line_id': 'pl_docs',
        ...queuedTask('D2', type: 'docs', writeScope: 'docs/spec.md'),
      });
      final Map<String, Object?> plan = call(
        'production.queue.plan',
        <String, Object?>{'line_id': 'pl_docs'},
      );
      expect(plan['batch_ids'], <String>['D1']);
      final Map<String, Object?> skipped =
          (plan['skipped'] as List<Object?>).single as Map<String, Object?>;
      expect(skipped['id'], 'D2');
      expect(skipped['reason'], 'write_scope_overlap');
    });
  });

  group('队列计划与批量派发', () {
    test('plan 只读：依赖 / 写域 / 槽位原因，且不改状态', () async {
      final ProductionStore store = await readyLine(maxParallel: 2);
      call('production.task.create', <String, Object?>{
        'line_id': 'pl',
        ...queuedTask('T1', writeScope: 'lib/a'),
      });
      call('production.task.create', <String, Object?>{
        'line_id': 'pl',
        ...queuedTask('T2', writeScope: 'lib/b'),
      });
      call('production.task.create', <String, Object?>{
        'line_id': 'pl',
        ...queuedTask('T3', writeScope: 'lib/a'),
      });
      final Map<String, Object?> plan = call(
        'production.queue.plan',
        <String, Object?>{'line_id': 'pl'},
      );
      expect(plan['batch_ids'], <String>['T1', 'T2']);
      expect(plan['slots_free'], 2);
      final Map<String, Object?> overlap = (plan['skipped'] as List<Object?>)
          .cast<Map<String, Object?>>()
          .firstWhere((Map<String, Object?> item) => item['id'] == 'T3');
      expect(overlap['reason'], 'write_scope_overlap');
      expect(overlap['with_task'], 'T1');
      expect(store.getTask('pl', 'T1').status, TaskStatus.queued);
      expect(store.getTask('pl', 'T2').status, TaskStatus.queued);
    });

    test('REST 批量派发：默认 dry_run；run=true 才真正派发', () async {
      final ProductionStore store = await readyLine(maxParallel: 2);
      call('production.task.create', <String, Object?>{
        'line_id': 'pl',
        ...queuedTask('T1', writeScope: 'lib/a'),
      });
      call('production.task.create', <String, Object?>{
        'line_id': 'pl',
        ...queuedTask('T2', writeScope: 'lib/b'),
      });
      final Map<String, dynamic> dry = await rest(
        'POST',
        '/api/production/lines/pl/dispatch',
      );
      expect(dry['status'], 200);
      expect(dry['json']['dry_run'], true);
      expect(dry['json']['batch_ids'], <String>['T1', 'T2']);
      expect(store.getTask('pl', 'T1').status, TaskStatus.queued);

      final _FakeExecution execution = _FakeExecution();
      final Map<String, dynamic> run = await rest(
        'POST',
        '/api/production/lines/pl/dispatch',
        body: <String, Object?>{'run': true},
        execution: execution,
        awaitDispatch: true,
      );
      expect(run['status'], 200);
      expect(run['json']['dry_run'], false);
      expect(run['json']['dispatched_count'], 2);
      expect(run['json']['failed_count'], 0);
      expect(execution.calledCommands, <String>[
        'production.task.pack',
        'production.task.pack',
      ]);
    });

    test('结构未整理：plan / 批量派发都给原因且不派发', () async {
      final ProductionStore store = newStore();
      store.createLine(<String, Object?>{'id': 'pl_org', 'name': '未整理'});
      store.createTask('pl_org', queuedTask('T1'));
      final Map<String, Object?> plan = call(
        'production.queue.plan',
        <String, Object?>{'line_id': 'pl_org'},
      );
      expect(plan['structure_ready'], false);
      expect(plan['batch'], isEmpty);
      final Map<String, Object?> skipped =
          (plan['skipped'] as List<Object?>).single as Map<String, Object?>;
      expect(skipped['reason'], 'structure_not_ready');

      final _FakeExecution execution = _FakeExecution();
      final Map<String, dynamic> run = await rest(
        'POST',
        '/api/production/lines/pl_org/dispatch',
        body: <String, Object?>{'run': true},
        execution: execution,
        awaitDispatch: true,
      );
      expect(run['status'], 200);
      expect(run['json']['dispatched_count'], 0);
      expect(execution.calledCommands, isEmpty);
    });
  });
}

/// 假的执行门面：记录派发命令，不做真打包 / 执行。
class _FakeExecution extends ProductionExecutionService {
  _FakeExecution() : super(environment: const <String, String>{});

  final List<String> calledCommands = <String>[];

  @override
  Future<Map<String, Object?>> handle(
    String command,
    Map<String, Object?> arguments,
    Map<String, Object?> meta,
    Map<String, Object?> scope,
  ) async {
    calledCommands.add(command);
    return <String, Object?>{
      'status': 'ok',
      'command': command,
      'task_id': arguments['task_id'],
    };
  }
}
