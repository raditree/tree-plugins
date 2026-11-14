/// 确定性全链路 E2E：结构 → 归一化 → 就绪 → 准备 → 打包 → 执行 → 漂移。
///
/// 不依赖真模型：docnorm / llm / worker / command 全部用确定性假实现；
/// 真实走的是插件的命令门面、状态机与落盘路径。真模型路径见
/// `tool/e2e_real_model.md`（手动运行）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

import 'support/structure_fixture.dart';

const Map<String, Object?> _testRoles = <String, Object?>{
  'orchestrator': <String, Object?>{'model_id': 'chat/main'},
  'packer': <String, Object?>{'model_id': 'chat/main'},
  'executor': <String, Object?>{'model_id': 'chat/main'},
  'expert': <String, Object?>{'model_id': 'chat/main'},
};

/// 假员工：打包返回片段 JSON，执行返回改动报告。
class _Workers {
  final List<WorkerCall> calls = <WorkerCall>[];
  String packReport = '';
  String runReport = '已修改 lib/a.dart';

  Future<Map<String, Object?>> run(
    WorkerCall call,
    Map<String, Object?> scope,
  ) async {
    calls.add(call);
    return <String, Object?>{
      'worker_id': 'sub_${call.role}',
      'status': 'ok',
      'report': call.role == 'packer' ? packReport : runReport,
      'error': '',
      'tokens': <String, Object?>{'prompt': 10, 'completion': 5},
    };
  }
}

/// 假命令：`git status` 前干净后改动；门控命令按 [gateOk] 返回。
class _Commands {
  String after = ' M lib/a.dart';
  bool gateOk = true;
  int gitCalls = 0;
  final List<String> ran = <String>[];

  Future<CommandResult> run(
    String command, {
    required String workspace,
    required Map<String, Object?> scope,
  }) async {
    ran.add(command);
    if (command.contains('git status')) {
      gitCalls += 1;
      return CommandResult(ok: true, output: gitCalls.isOdd ? '' : after);
    }
    return CommandResult(
      ok: gateOk,
      exitCode: gateOk ? 0 : 1,
      output: gateOk ? 'ok' : 'gate failed',
    );
  }
}

void main() {
  late Directory temp;
  late String workspace;
  late ProductionStore store;
  late _Workers workers;
  late _Commands commands;
  late FixtureDocnorm docnorm;
  late ProductionNormalizationService normalization;
  late ProductionReadinessService readiness;
  late PreparationService preparation;
  late ProductionExecutionService execution;
  late ProductionService service;

  const String lineId = 'pl_e2e';
  final Map<String, Object?> meta = <String, Object?>{};
  const Map<String, Object?> scope = <String, Object?>{
    'agent_id': 'agt_caller',
  };

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_pl_e2e_');
    workspace = p.join(temp.path, 'ws');
    Directory(workspace).createSync(recursive: true);
    File(p.join(workspace, 'pubspec.yaml')).writeAsStringSync(
      'name: demo_project\ndescription: 全链路确定性演示工程\n',
    );
    File(p.join(workspace, 'README.md')).writeAsStringSync('# demo_project\n');
    Directory(p.join(workspace, 'lib')).createSync(recursive: true);
    File(p.join(workspace, 'lib', 'a.dart')).writeAsStringSync(
      'class A {\n  String hello() => "hi";\n}\n',
    );
    meta['data_dir'] = temp.path;

    store = ProductionStore(dataRoot: temp.path);
    store.createLine(<String, Object?>{
      'id': lineId,
      'name': '全链路产线',
      'workspace_dir': workspace,
      'executor': <String, Object?>{
        'agent_id': 'agt_line',
        'team_id': 'team_line',
      },
      'roles': _testRoles,
      'limits': <String, Object?>{
        'retries': 1,
        'max_parallel_tasks': 1,
      },
    });
    workers = _Workers()
      ..packReport = jsonEncode(<String, Object?>{
        'files': <Object?>[
          <String, Object?>{
            'path': 'lib/a.dart',
            'start_line': 1,
            'end_line': 3,
            'content': 'class A {}',
          },
        ],
        'baseline': <Object?>['dart analyze'],
        'risks': <String>[],
        'dependencies': <String>[],
      });
    commands = _Commands();
    docnorm = FixtureDocnorm(workspace);
    normalization = ProductionNormalizationService(
      environment: const <String, String>{},
      docnorm: docnorm.call,
    );
    readiness = ProductionReadinessService(
      environment: const <String, String>{},
      docnorm: docnorm.call,
      dedupStatus: docnorm.dedupStatus,
    );
    preparation = PreparationService(
      environment: const <String, String>{},
      llm:
          (
            String point,
            String system,
            String prompt,
            Map<String, Object?> scope,
            String modelId,
          ) async {
            if (point == 'production.digest') {
              return <String, Object?>{
                'requirement_summary': '让 A 的 hello 返回项目名',
                'keywords': <String, Object?>{
                  'terms': <String>['hello', '项目名'],
                  'files': <String>['lib/a.dart'],
                },
              };
            }
            if (point == 'production.recon') {
              return <String, Object?>{
                'regular': <Object?>[
                  <String, Object?>{
                    'text': 'lib/a.dart 里已有 A.hello',
                    'evidence_ids': <String>['E1'],
                    'landing': 'lib/a.dart',
                  },
                ],
                'special': <Object?>[],
                'questions': <Object?>[
                  <String, Object?>{
                    'text': '是否保留旧 hello 行为？',
                    'default': '保留',
                    'recommended': '保留',
                    'consequence': '不保留会有回归风险',
                    'evidence_ids': <String>['E1'],
                  },
                ],
                'fallbacks': <Object?>[],
                'notes': <Object?>[],
                'flags': <String>['lib/a.dart'],
              };
            }
            throw StateError('显式 plan 不应调用模型：$point');
          },
      docQuery:
          (String repo, String question, Map<String, Object?> scope) async =>
              <String, Object?>{
                'mode': 'lexical',
                'results': <Object?>[
                  <String, Object?>{
                    'doc': 'docs/project-status.md',
                    'heading': 'A 的现状',
                    'snippet': 'lib/a.dart 提供 A.hello',
                  },
                ],
              },
    );
    execution = ProductionExecutionService(
      environment: const <String, String>{},
      workers: workers.run,
      commands: commands.run,
    );
    service = ProductionService(environment: const <String, String>{});
  });

  tearDown(() {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 真实命令路径：结构重审 → 归一化 plan/apply → 复合就绪快照。
  Future<Map<String, Object?>> markReady() async {
    final Map<String, Object?> structure = service.handle(
      'production.structure.reevaluate',
      <String, Object?>{'line_id': lineId},
      meta,
      scope,
    );
    expect(structure['ready'], isTrue, reason: '${structure['missing']}');
    await normalization.handle(
      'production.normalize.plan',
      <String, Object?>{
        'line_id': lineId,
        'sections': <Object?>[],
        'indexes': <Object?>[],
      },
      meta,
      scope,
    );
    await normalization.handle(
      'production.normalize.apply',
      <String, Object?>{'line_id': lineId},
      meta,
      scope,
    );
    final Map<String, Object?> ready = await readiness.handle(
      'production.readiness.get',
      <String, Object?>{'line_id': lineId},
      meta,
      scope,
    );
    expect(ready['ready'], isTrue, reason: '${ready['missing']}');
    return ready;
  }

  Future<Map<String, Object?>> createQueued(
    String id, {
    String title = '改 lib/a.dart',
    List<String> dependsOn = const <String>[],
    bool withBrief = true,
    bool withAcceptance = true,
  }) => Future<Map<String, Object?>>.value(
    service.handle(
      'production.task.create',
      <String, Object?>{
        'line_id': lineId,
        'task': <String, Object?>{
          'id': id,
          'title': title,
          'status': 'queued',
          'task_type': 'code',
          'depends_on': dependsOn,
          'read_scope': <String>['lib/'],
          'write_scope': <String>['lib/a.dart'],
          if (withBrief) 'brief': '把 hello 改成返回项目名',
          if (withAcceptance) 'acceptance': <String>['dart analyze 通过'],
          'gate': <String, Object?>{
            'commands': <String>['dart analyze'],
          },
        },
      },
      meta,
      scope,
    ),
  );

  test('全链路：结构 → 归一化 → 就绪 → 准备 → 打包 → 执行 → 漂移', () async {
    final Map<String, Object?> ready = await markReady();
    expect((ready['line'] as Map<String, Object?>?)?['ready'], isTrue);
    expect(isLineReady(store, store.getLine(lineId)), isTrue);

    // 准备：intake → recon（假模型带 evidence）→ 全部按推荐 → 显式计划落档。
    final Map<String, Object?> intake = await preparation.handle(
      'production.prepare.intake',
      <String, Object?>{
        'line_id': lineId,
        'task': <String, Object?>{
          'id': 'T0',
          'title': '让 hello 返回项目名',
          'intake': <String, Object?>{
            'goal': '让 A.hello 返回项目名',
            'current': '固定返回 hi',
            'acceptance': 'hello 返回 demo_project；dart analyze 通过',
            'forbidden': '不动 README 之外的文件',
            'deadline': '本批次',
          },
        },
      },
      meta,
      scope,
    );
    expect((intake['task'] as Map<String, Object?>)['status'], 'draft');

    final Map<String, Object?> recon = await preparation.handle(
      'production.prepare.recon',
      <String, Object?>{'line_id': lineId, 'task_id': 'T0'},
      meta,
      scope,
    );
    expect((recon['evidence'] as List<dynamic>), isNotEmpty);
    expect(recon['open'], 1);
    expect((recon['task'] as Map<String, Object?>)['status'], 'aligning');

    final Map<String, Object?> decided = await preparation.handle(
      'production.prepare.all_recommended',
      <String, Object?>{'line_id': lineId, 'task_id': 'T0'},
      meta,
      scope,
    );
    expect(decided['open'], 0);

    final Map<String, Object?> finalized = await preparation.handle(
      'production.prepare.finalize',
      <String, Object?>{
        'line_id': lineId,
        'task_id': 'T0',
        'in': <String>['hello 使用项目名'],
        'out': <String>['不改依赖'],
        'not_doing': <String>['不动其他接口'],
        'plan': <Object?>[
          <String, Object?>{
            'id': 'T1',
            'title': '改 lib/a.dart 的 hello',
            'task_type': 'code',
            'acceptance': <String>['dart analyze 通过', 'README 与实现一致'],
            'read_scope': <String>['lib/'],
            'write_scope': <String>['lib/a.dart'],
            'estimated_files': 1,
            'estimated_lines': 10,
            'gate': <String, Object?>{
              'commands': <String>['dart analyze'],
              'checklist': <Object?>[
                <String, Object?>{
                  'text': '- [ ] README 与实现一致',
                  'evidence': 'README.md',
                },
              ],
            },
          },
        ],
      },
      meta,
      scope,
    );
    expect((finalized['task'] as Map<String, Object?>)['status'], 'scoped');
    expect(
      (finalized['created_tasks'] as List<dynamic>)
          .map((dynamic item) => (item as Map)['id'])
          .toList(),
      <String>['T1'],
    );
    expect(store.getTask(lineId, 'T1').status, TaskStatus.queued);

    // 打包 → 执行 → 门控 → done。
    final Map<String, Object?> packed = await execution.handle(
      'production.task.pack',
      <String, Object?>{'line_id': lineId, 'task_id': 'T1'},
      meta,
      scope,
    );
    expect(packed['status'], 'packed');

    final Map<String, Object?> ran = await execution.handle(
      'production.task.run',
      <String, Object?>{'line_id': lineId, 'task_id': 'T1'},
      meta,
      scope,
    );
    expect(ran['status'], 'done');
    final Map<String, Object?> run = plainMap(ran['run']);
    final String runId = textOf(run['gate_run_id']);
    expect(runId, isNotEmpty);
    expect(File(store.gateFile(lineId, 'T1', runId)).existsSync(), isTrue);
    expect(store.readGate(lineId, 'T1', runId)['ok'], isTrue);
    expect(
      run.containsKey('memory_hash') || run['memory_unavailable'] == true,
      isTrue,
      reason: '记忆未接线时必须显式标记 memory_unavailable',
    );

    final List<Map<String, Object?>> runs = store.listRuns(
      lineId,
      taskId: 'T1',
    );
    expect(runs.map((Map<String, Object?> item) => item['role']).toSet(), <String>{
      'packer',
      'executor',
    });
    expect(
      File(p.join(store.plansDir(lineId), 'plan-v1', 'plan.json')).existsSync(),
      isTrue,
    );
    expect(store.readPlanVersion(lineId, 1)['tasks'], isNotEmpty);
    expect(store.getTask(lineId, 'T1').status, TaskStatus.done);

    // 漂移：改动全部落在计划写域内。
    final Map<String, Object?> drift = service.handle(
      'production.drift.run',
      <String, Object?>{
        'line_id': lineId,
        'batch_id': 'B1',
        'changed_files': <String>['lib/a.dart'],
        'file_to_task': <String, Object?>{'lib/a.dart': 'T1'},
      },
      meta,
      scope,
    );
    expect(drift['ok'], isTrue, reason: '${drift['code']}');
    expect(drift['blocked'], isEmpty);
  });

  test('异常 1：缺 brief 建 queued ⇒ task_input_incomplete', () async {
    await markReady();
    await expectLater(
      () => createQueued(
        'T-missing',
        withBrief: false,
        withAcceptance: false,
      ),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure error) => error.code,
          'code',
          'task_input_incomplete',
        ),
      ),
    );
  });

  test('异常 2：依赖未满足 ⇒ queue.next 的 skipped 含 depends_on', () async {
    await markReady();
    await createQueued('A');
    await createQueued('B', dependsOn: <String>['A']);
    final Map<String, Object?> next = service.handle(
      'production.queue.next',
      <String, Object?>{'line_id': lineId, 'limit': 1},
      meta,
      scope,
    );
    final List<Map<String, Object?>> skipped = <Map<String, Object?>>[
      for (final Object? item in (next['skipped'] as List<dynamic>))
        if (item is Map) plainMap(item),
    ];
    expect(
      skipped.any(
        (Map<String, Object?> item) =>
            textOf(item['id']) == 'B' && textOf(item['reason']) == 'depends_on',
      ),
      isTrue,
      reason: '$skipped',
    );
  });

  test('异常 3：门控失败重试后 blocked', () async {
    await markReady();
    await createQueued('G1');
    await execution.handle(
      'production.task.pack',
      <String, Object?>{'line_id': lineId, 'task_id': 'G1'},
      meta,
      scope,
    );
    commands.gateOk = false;

    final Map<String, Object?> first = await execution.handle(
      'production.task.run',
      <String, Object?>{'line_id': lineId, 'task_id': 'G1'},
      meta,
      scope,
    );
    expect(first['status'], 'retry');
    expect(store.getTask(lineId, 'G1').status, TaskStatus.packed);

    final Map<String, Object?> second = await execution.handle(
      'production.task.run',
      <String, Object?>{'line_id': lineId, 'task_id': 'G1'},
      meta,
      scope,
    );
    expect(second['status'], 'blocked');
    expect(store.getTask(lineId, 'G1').status, TaskStatus.blocked);
  });

  test('异常 4：漂移失败 ⇒ queued 任务 blocked', () async {
    await markReady();
    await createQueued('D1');
    final Map<String, Object?> drift = service.handle(
      'production.drift.run',
      <String, Object?>{
        'line_id': lineId,
        'batch_id': 'B2',
        'changed_files': <String>['lib/a.dart'],
        'new_cycles': <String>['pkg_a→pkg_b'],
      },
      meta,
      scope,
    );
    expect(drift['ok'], isFalse);
    expect(drift['code'], 'drift_dependency');
    expect(drift['blocked'], contains('D1'));
    expect(store.getTask(lineId, 'D1').status, TaskStatus.blocked);
  });

  test('异常 5：崩溃恢复 ⇒ running 回 queued + interrupted 台账', () async {
    await markReady();
    await createQueued('R1');
    store.putTask(lineId, 'R1', <String, Object?>{'status': 'running'});
    expect(store.getTask(lineId, 'R1').status, TaskStatus.running);

    final Map<String, Object?> recovered = service.handle(
      'production.queue.recover',
      <String, Object?>{'line_id': lineId},
      meta,
      scope,
    );
    expect(recovered['count'], 1);
    expect(store.getTask(lineId, 'R1').status, TaskStatus.queued);
    final List<Map<String, Object?>> runs = store.listRuns(
      lineId,
      taskId: 'R1',
    );
    expect(
      runs.any((Map<String, Object?> run) => run['status'] == 'interrupted'),
      isTrue,
    );
  });
}
