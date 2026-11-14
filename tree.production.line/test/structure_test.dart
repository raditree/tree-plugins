import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

import 'support/structure_fixture.dart';

/// Task 2 的门控验收：LG-01 / TG-06。
///
/// 锁住：
/// 1. 结构报告 schema（packages/findings/waivers/fingerprint）与确定性扫描；
/// 2. organizing 阶段非 cleanup 任务的 create / dispatch / pack / tick 全部
///    `structure_not_ready`，cleanup 放行；
/// 3. 修好或逐项豁免后重审放行；豁免必须 owner / reason / expires_at，到期失效；
/// 4. 旧任务没有 task_type 时按 code 处理。
void main() {
  late Directory temp;
  late Directory workspace;
  late DateTime now;
  late ProductionStore store;
  late ProductionService service;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_production_structure_');
    workspace = Directory(p.join(temp.path, 'ws'))..createSync(recursive: true);
    now = DateTime(2026, 11, 14, 10);
    store = ProductionStore(dataRoot: temp.path, clock: () => now);
    service = ProductionService(
      environment: const <String, String>{},
      clock: () => now,
    );
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Map<String, Object?> call(
    String command,
    Map<String, Object?> arguments,
  ) => service.handle(
    command,
    arguments,
    <String, Object?>{'data_dir': temp.path},
    <String, Object?>{'team_id': 'team_a', 'agent_id': 'agt'},
  );

  Matcher failure(String code) => throwsA(
    isA<ProductionFailure>().having(
      (ProductionFailure error) => error.code,
      'code',
      code,
    ),
  );

  void write(String relative, String content) {
    final File file = File(p.joinAll(<String>[workspace.path, ...relative.split('/')]));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  /// 一个有 high 项的仓库：`a` 缺职责 + `a`/`b` 互相依赖；另有 medium / low。
  void writeBrokenWorkspace() {
    write('packages/a/pubspec.yaml', 'name: a\nversion: 0.1.0\n');
    write('packages/a/lib/a.dart', '''
export 'src/a.dart';

import 'package:b/b.dart';

// TODO: 把 a 的职责写清楚
class A {
  B? b;
}
''');
    write('packages/a/lib/src/a.dart', 'class ADetail {}\n');
    write('packages/b/pubspec.yaml', 'name: b\nversion: 0.1.0\ndescription: B 的职责\n');
    write('packages/b/lib/b.dart', '''
import 'package:a/a.dart';

class B {
  A? a;
}
''');
    write('docs/dup-a.txt', 'x' * 2048);
    write('docs/dup-b.txt', 'x' * 2048);
  }

  LineRecord createBrokenLine({String id = 'pl_s'}) {
    writeBrokenWorkspace();
    final LineRecord line = store.createLine(<String, Object?>{
      'id': id,
      'name': '结构整理',
      'workspace_dir': workspace.path,
      'roles': <String, Object?>{
        'packer': <String, Object?>{'model_id': 'chat/main'},
        'executor': <String, Object?>{'model_id': 'chat/main'},
      },
      'executor': <String, Object?>{'agent_id': 'agt'},
      'docs': <String, Object?>{
        'memory_manifest': <String>['docs/project-status.md'],
      },
    });
    return line;
  }

  /// 一个结构本来就干净的仓库：单包带 description 与入口。
  LineRecord createHealthyLine({String id = 'pl_h'}) {
    write('pubspec.yaml', 'name: root\nversion: 0.1.0\ndescription: 根包\n');
    write('lib/root.dart', 'class Root {}\n');
    return store.createLine(<String, Object?>{
      'id': id,
      'name': '干净仓库',
      'workspace_dir': workspace.path,
    });
  }

  Map<String, Object?> reevaluate(String lineId) => call(
    'production.structure.reevaluate',
    <String, Object?>{'line_id': lineId},
  );

  List<Map<String, Object?>> findingsOf(Map<String, Object?> result) => <Map<String, Object?>>[
    for (final Object? item
        in (plainMap(result['report'])['findings'] as List<Object?>? ?? const []))
      plainMap(item),
  ];

  Map<String, Object?> findingOf(Map<String, Object?> result, String kind) =>
      findingsOf(result).firstWhere(
        (Map<String, Object?> item) => item['kind'] == kind,
      );

  Map<String, Object?> waiver(
    String lineId,
    String findingId, {
    String owner = 'user',
    String reason = '下期拆分',
    String expiresAt = '2026-12-31',
  }) => call('production.structure.waive', <String, Object?>{
    'line_id': lineId,
    'finding_id': findingId,
    'owner': owner,
    'reason': reason,
    'expires_at': expiresAt,
  });

  test('结构报告：包职责 / 公共 API / 依赖环 / 重复与 TODO 分类；medium/low 不阻断', () {
    createBrokenLine();
    final Map<String, Object?> result = reevaluate('pl_s');

    expect(result['ready'], isFalse);
    expect(result['phase'], 'organizing');
    final List<String> missing = stringsOf(result['missing']);
    expect(missing, contains('missing_responsibility'));
    expect(missing, contains('dependency_cycle'));

    final Map<String, Object?> report = plainMap(result['report']);
    expect(report['version'], kStructureReportVersion);
    expect(report['generated_at'], isNotEmpty);
    expect(report['fingerprint'], isNotEmpty);
    final List<Map<String, Object?>> packages = <Map<String, Object?>>[
      for (final Object? item in (report['packages'] as List<Object?>))
        plainMap(item),
    ];
    expect(packages.map((Map<String, Object?> item) => item['id']), <String>['a', 'b']);
    final Map<String, Object?> packageA = packages.first;
    expect(packageA['responsibility'], '');
    expect(packageA['entry'], 'packages/a/lib/a.dart');
    expect(packageA['public_api'], containsAll(<String>['A', 'ADetail']));
    expect(packageA['depends_on'], <String>['b']);

    final Map<String, Object?> cycle = findingOf(result, 'dependency_cycle');
    expect(cycle['severity'], 'high');
    expect(cycle['targets'], <String>['a', 'b']);

    // medium / low：必须列出，但不阻断（missing 只含 high 的 kind）。
    final Map<String, Object?> duplicate = findingOf(result, 'duplicate_code');
    expect(duplicate['severity'], 'medium');
    expect(
      (duplicate['targets'] as List<Object?>).cast<String>(),
      containsAll(<String>['docs/dup-a.txt', 'docs/dup-b.txt']),
    );
    expect(findingOf(result, 'todo_open')['severity'], 'low');
    expect(findingOf(result, 'docs_gap')['severity'], 'low');
    expect(missing, isNot(contains('todo_open')));
    expect(missing, isNot(contains('duplicate_code')));

    // 报告落盘在 <line>/structure.json。
    expect(
      File(p.join(store.lineDir('pl_s'), 'structure.json')).existsSync(),
      isTrue,
    );
  });

  test('freshness：文件变更后报告 stale，structure.get 不给通过', () {
    createBrokenLine();
    reevaluate('pl_s');
    write('packages/b/lib/b.dart', 'class B2 {}\n');
    final Map<String, Object?> status = call(
      'production.structure.get',
      <String, Object?>{'line_id': 'pl_s'},
    );
    expect(status['ready'], isFalse);
    expect(stringsOf(status['missing']), contains('structure_report_stale'));
    expect(plainMap(status['summary'])['stale'], isTrue);
  });

  test('修好后重审放行：phase 从 organizing 推进到 normalizing（不自动 ready）', () {
    createBrokenLine();
    expect(reevaluate('pl_s')['ready'], isFalse);

    // 补职责、去掉反向依赖 ⇒ 两个 high 都消失。
    write(
      'packages/a/pubspec.yaml',
      'name: a\nversion: 0.1.0\ndescription: A 的职责\n',
    );
    write('packages/b/lib/b.dart', 'class B {}\n');
    final Map<String, Object?> fixed = reevaluate('pl_s');
    expect(fixed['ready'], isTrue, reason: '${fixed['missing']}');
    expect(fixed['phase'], 'normalizing');
    expect(store.getLine('pl_s').phase, 'normalizing');
    expect(
      plainMap(fixed['report'])['findings'],
      isNotEmpty,
      reason: 'medium/low 仍要列出',
    );
  });

  test('豁免：必须 owner/reason/expires_at；只允许 high；到期不计；逐项生效', () {
    createBrokenLine();
    final Map<String, Object?> first = reevaluate('pl_s');
    final String responsibilityId = '${findingOf(first, 'missing_responsibility')['id']}';
    final String cycleId = '${findingOf(first, 'dependency_cycle')['id']}';
    final String todoId = '${findingOf(first, 'todo_open')['id']}';

    expect(
      () => waiver('pl_s', responsibilityId, owner: ''),
      failure('invalid_arguments'),
    );
    expect(
      () => waiver('pl_s', responsibilityId, reason: ''),
      failure('invalid_arguments'),
    );
    expect(
      () => waiver('pl_s', responsibilityId, expiresAt: ''),
      failure('invalid_arguments'),
    );
    expect(
      () => waiver('pl_s', responsibilityId, expiresAt: 'not-a-date'),
      failure('invalid_arguments'),
    );
    expect(
      () => waiver('pl_s', todoId),
      failure('waiver_not_allowed'),
      reason: 'low 不阻断，无需豁免',
    );

    // 到期豁免不算。
    final Map<String, Object?> expired = waiver(
      'pl_s',
      responsibilityId,
      expiresAt: '2026-01-01',
    );
    expect(expired['ready'], isFalse);

    final Map<String, Object?> one = waiver('pl_s', responsibilityId);
    expect(one['ready'], isFalse, reason: '环还没豁免');
    expect(stringsOf(one['missing']), contains('dependency_cycle'));
    final Map<String, Object?> two = waiver('pl_s', cycleId);
    expect(two['ready'], isTrue, reason: '${two['missing']}');
    expect(two['phase'], 'normalizing');

    final Map<String, Object?> report = plainMap(
      call(
        'production.structure.get',
        <String, Object?>{'line_id': 'pl_s'},
      )['report'],
    );
    final List<Map<String, Object?>> waivers = <Map<String, Object?>>[
      for (final Object? item in (report['waivers'] as List<Object?>))
        plainMap(item),
    ];
    expect(waivers.length, 2);
    expect(
      waivers.map((Map<String, Object?> item) => item['owner']),
      everyElement('user'),
    );
    expect(
      waivers.map((Map<String, Object?> item) => item['expires_at']),
      everyElement('2026-12-31'),
    );
  });

  test('organizing 门禁：非 cleanup 的 create / dispatch / pack / tick 被拒，cleanup 放行', () async {
    createBrokenLine();
    reevaluate('pl_s');

    expect(
      () => call('production.task.create', <String, Object?>{
        'line_id': 'pl_s',
        'id': 'T1',
        'title': '常规任务',
      }),
      throwsA(
        isA<ProductionFailure>()
            .having((ProductionFailure e) => e.code, 'code', 'structure_not_ready')
            .having((ProductionFailure e) => e.missing, 'missing', isNotEmpty),
      ),
    );

    // cleanup 必须有写域与验收（Task 5 起统一为结构化输入预检）。
    expect(
      () => call('production.task.create', <String, Object?>{
        'line_id': 'pl_s',
        'id': 'C0',
        'title': '缺字段的清理',
        'task_type': 'cleanup',
      }),
      failure('task_input_incomplete'),
    );
    final Map<String, Object?> created = call(
      'production.task.create',
      <String, Object?>{
        'line_id': 'pl_s',
        'id': 'C1',
        'title': '补包职责',
        'task_type': 'cleanup',
        'status': 'queued',
        'write_scope': <String>['packages/a/pubspec.yaml'],
        'acceptance': <String>['重新扫描结构通过'],
      },
    );
    expect(plainMap(created['task'])['task_type'], 'cleanup');

    // 只有 cleanup 时派发计划放行。
    final Map<String, Object?> plan = call(
      'production.queue.dispatch',
      <String, Object?>{'line_id': 'pl_s'},
    );
    expect(plan['batch_ids'], <String>['C1']);

    // 混入非 cleanup ⇒ 拒绝。
    store.createTask('pl_s', <String, Object?>{
      'id': 'T1',
      'title': '常规任务',
      'status': 'queued',
    });
    expect(
      () => call('production.queue.dispatch', <String, Object?>{
        'line_id': 'pl_s',
      }),
      failure('structure_not_ready'),
    );

    // 打包：cleanup 放行，非 cleanup 拒绝。
    final List<WorkerCall> workerCalls = <WorkerCall>[];
    final ProductionExecutionService execution = ProductionExecutionService(
      environment: const <String, String>{},
      clock: () => now,
      workers: (WorkerCall call, Map<String, Object?> scope) async {
        workerCalls.add(call);
        return <String, Object?>{
          'worker_id': 'w',
          'status': 'ok',
          'report': jsonEncode(<String, Object?>{
            'files': <Object?>[
              <String, Object?>{
                'path': 'packages/a/pubspec.yaml',
                'start_line': 1,
                'end_line': 1,
                'content': 'name: a',
              },
            ],
            'baseline': <String>['dart analyze'],
            'risks': <String>[],
            'dependencies': <String>[],
          }),
        };
      },
      commands: (String command, {
        required String workspace,
        required Map<String, Object?> scope,
      }) async => const CommandResult(ok: true, exitCode: 0, output: 'ok'),
    );
    final Map<String, Object?> packed = await execution.handle(
      'production.task.pack',
      <String, Object?>{'line_id': 'pl_s', 'task_id': 'C1'},
      <String, Object?>{'data_dir': temp.path},
      <String, Object?>{'team_id': 'team_a', 'agent_id': 'agt'},
    );
    expect(packed['status'], 'packed');
    expect(workerCalls.single.role, 'packer');
    await expectLater(
      () => execution.handle(
        'production.task.pack',
        <String, Object?>{'line_id': 'pl_s', 'task_id': 'T1'},
        <String, Object?>{'data_dir': temp.path},
        <String, Object?>{'team_id': 'team_a', 'agent_id': 'agt'},
      ),
      failure('structure_not_ready'),
    );

    // tick 也过门：非 cleanup 在整理中不得推进。
    final OrchestratorService orchestrator = OrchestratorService(
      environment: const <String, String>{},
      clock: () => now,
    );
    await expectLater(
      () => orchestrator.handle(
        'production.orchestrator.tick',
        <String, Object?>{'line_id': 'pl_s'},
        <String, Object?>{'data_dir': temp.path},
        <String, Object?>{'team_id': 'team_a'},
      ),
      failure('structure_not_ready'),
    );
  });

  test('空仓库结构通过：phase normalizing 后仍需就绪门；旧任务默认 task_type=code', () async {
    store.createLine(<String, Object?>{
      'id': 'pl_ok',
      'name': '空仓库',
      'workspace_dir': workspace.path,
    });
    final Map<String, Object?> status = call(
      'production.structure.get',
      <String, Object?>{'line_id': 'pl_ok'},
    );
    expect(status['ready'], isFalse);
    expect(stringsOf(status['missing']), contains('structure_report'));

    final Map<String, Object?> evaluated = reevaluate('pl_ok');
    expect(evaluated['ready'], isTrue, reason: '${evaluated['missing']}');
    expect(evaluated['phase'], 'normalizing');

    // LG-07：结构通过但归一化 / 索引未就绪时，非 cleanup 任务仍被拦。
    expect(
      () => call('production.task.create', <String, Object?>{
        'line_id': 'pl_ok',
        'id': 'T0',
        'title': '未就绪',
        'status': 'queued',
      }),
      failure('line_not_ready'),
    );

    await markLineReady(store, 'pl_ok', temp, workspace: workspace.path);
    final Map<String, Object?> created = call(
      'production.task.create',
      <String, Object?>{
        'line_id': 'pl_ok',
        'id': 'T1',
        'title': '常规任务',
        'status': 'queued',
        'brief': '常规改动',
        'acceptance': <String>['测试通过'],
        'write_scope': <String>['lib/root.dart'],
      },
    );
    expect(plainMap(created['task'])['task_type'], 'code');

    // 旧 task.yaml 没有 task_type：读取按 code（不迁移、不报错）。
    store.createTask('pl_ok', <String, Object?>{
      'id': 'OLD',
      'title': '旧任务',
      'status': 'queued',
    });
    expect(store.getTask('pl_ok', 'OLD').taskType, 'code');
    expect(store.getTask('pl_ok', 'OLD').isCleanup, isFalse);
  });

  test('结构通过后源码变更 ⇒ stale 阻断非 cleanup 的 create / dispatch，重审后放行', () async {
    createHealthyLine();
    expect(reevaluate('pl_h')['ready'], isTrue);
    expect(store.getLine('pl_h').phase, 'normalizing');
    await markLineReady(store, 'pl_h', temp, workspace: workspace.path);

    call('production.task.create', <String, Object?>{
      'line_id': 'pl_h',
      'id': 'T1',
      'title': '常规任务',
      'status': 'queued',
      'brief': '常规改动',
      'acceptance': <String>['测试通过'],
      'write_scope': <String>['lib/root.dart'],
    });

    // 通过后改源码：报告不再 fresh，非 cleanup 任务必须重新过门。
    write('lib/root.dart', 'class Root2 {}\n');
    expect(
      () => call('production.task.create', <String, Object?>{
        'line_id': 'pl_h',
        'id': 'T2',
        'title': '变更后的任务',
        'status': 'queued',
      }),
      throwsA(
        isA<ProductionFailure>()
            .having((ProductionFailure e) => e.code, 'code', 'structure_not_ready')
            .having(
              (ProductionFailure e) => e.missing,
              'missing',
              contains('structure_report_stale'),
            ),
      ),
    );
    expect(
      () => call('production.queue.dispatch', <String, Object?>{'line_id': 'pl_h'}),
      throwsA(
        isA<ProductionFailure>()
            .having((ProductionFailure e) => e.code, 'code', 'structure_not_ready')
            .having(
              (ProductionFailure e) => e.missing,
              'missing',
              contains('structure_report_stale'),
            ),
      ),
    );

    // 重审后恢复放行（结构报告 + 就绪快照都要重新生成）。
    expect(reevaluate('pl_h')['ready'], isTrue);
    await markLineReady(store, 'pl_h', temp, workspace: workspace.path);
    final Map<String, Object?> created = call(
      'production.task.create',
      <String, Object?>{
        'line_id': 'pl_h',
        'id': 'T2',
        'title': '变更后的任务',
        'status': 'queued',
        'brief': '变更后的常规改动',
        'acceptance': <String>['测试通过'],
        'write_scope': <String>['lib/root.dart'],
      },
    );
    expect(plainMap(created['task'])['id'], 'T2');
    final Map<String, Object?> plan = call(
      'production.queue.dispatch',
      <String, Object?>{'line_id': 'pl_h'},
    );
    expect(plan['batch_ids'], isNotEmpty);
  });

  test('报告 stale 时 cleanup 任务仍可创建与派发（清理入口不被卡死）', () {
    createHealthyLine();
    expect(reevaluate('pl_h')['ready'], isTrue);
    write('lib/root.dart', 'class Root3 {}\n');

    final Map<String, Object?> created = call(
      'production.task.create',
      <String, Object?>{
        'line_id': 'pl_h',
        'id': 'C1',
        'title': '整理包结构',
        'task_type': 'cleanup',
        'status': 'queued',
        'write_scope': <String>['lib/root.dart'],
        'acceptance': <String>['重新扫描结构通过'],
      },
    );
    expect(plainMap(created['task'])['task_type'], 'cleanup');

    final Map<String, Object?> plan = call(
      'production.queue.dispatch',
      <String, Object?>{'line_id': 'pl_h'},
    );
    expect(plan['batch_ids'], <String>['C1']);
  });

  test('有 .dart 文件但零 pubspec ⇒ high missing_packages，不能放行', () {
    write('lib/a.dart', 'class A {}\n');
    store.createLine(<String, Object?>{
      'id': 'pl_np',
      'name': '缺包清单',
      'workspace_dir': workspace.path,
    });
    final Map<String, Object?> result = reevaluate('pl_np');
    expect(result['ready'], isFalse);
    expect(stringsOf(result['missing']), contains('missing_packages'));
    final Map<String, Object?> finding = findingOf(result, 'missing_packages');
    expect(finding['severity'], 'high');
    expect(
      (finding['targets'] as List<Object?>).cast<String>(),
      contains('lib/a.dart'),
    );
    expect(
      () => call('production.task.create', <String, Object?>{
        'line_id': 'pl_np',
        'id': 'T1',
        'title': '常规任务',
      }),
      failure('structure_not_ready'),
    );
  });
}
