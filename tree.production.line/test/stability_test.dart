import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

import 'support/structure_fixture.dart';

/// Task 11 / PC-10：稳定性控制面（SG-01~06）。
///
/// 锁住：
/// 1. 租约 + fencing：同 owner 递增、异 owner 冲突、旧 token 失效、执行后释放；
/// 2. 幂等命令：带 key 的重复 pack 只执行一次并回放同一结果；
/// 3. 事件日志 + 对账：create / transition / recovery 行；state.json 被改后按
///    task.yaml 修复；
/// 4. 独立门控 runner：写 gate.json、不同 runner 覆盖被拒、执行者不能传 gate；
/// 5. 换模型黄金任务：契约形状一致、缺字段回 model_swap_regression；
/// 6. SLO：恢复 / blocked / retry 指标可查，超 SLO 回 recovery_slo_missed。
void main() {
  const Map<String, Object?> roles = <String, Object?>{
    'orchestrator': <String, Object?>{'model_id': 'chat/main'},
    'packer': <String, Object?>{'model_id': 'chat/main'},
    'executor': <String, Object?>{'model_id': 'chat/main'},
    'expert': <String, Object?>{'model_id': 'chat/main'},
  };

  late Directory temp;
  late String workspace;
  late ProductionStore store;
  late _Workers workers;
  late _Commands commands;
  late ProductionExecutionService service;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tree_production_stability_');
    workspace = p.join(temp.path, 'ws');
    Directory(workspace).createSync(recursive: true);
    store = ProductionStore(dataRoot: temp.path);
    workers = _Workers()
      ..packReport = jsonEncode(<String, Object?>{
        'files': <Object?>[
          <String, Object?>{
            'path': 'lib/a.dart',
            'start_line': 1,
            'end_line': 2,
            'content': 'class A {}',
          },
        ],
        'baseline': <Object?>['dart analyze'],
        'risks': <String>[],
        'dependencies': <String>[],
      });
    commands = _Commands();
    service = ProductionExecutionService(
      workers: workers.run,
      commands: commands.run,
    );
    store.createLine(<String, Object?>{
      'id': 'pl_t',
      'name': '稳定性',
      'workspace_dir': workspace,
      'limits': <String, Object?>{'retries': 1},
      'roles': roles,
    });
    await markLineReady(store, 'pl_t', temp, workspace: workspace);
  });

  tearDown(() {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<Map<String, Object?>> call(
    String command,
    Map<String, Object?> arguments,
  ) => service.handle(
    command,
    arguments,
    <String, Object?>{'data_dir': temp.path},
    <String, Object?>{'team_id': 'team_a', 'agent_id': 'agt'},
  );

  Map<String, Object?> productionCall(
    String command,
    Map<String, Object?> arguments,
  ) => ProductionService(
    environment: <String, String>{'TREE_DATA_ROOT': temp.path},
  ).handle(
    command,
    arguments,
    <String, Object?>{'data_dir': temp.path},
    <String, Object?>{'team_id': 'team_a', 'agent_id': 'agt'},
  );

  void queuedTask(
    String id, {
    Map<String, Object?>? gate,
    List<String> writeScope = const <String>['lib/a.dart'],
  }) {
    final Map<String, Object?> input = <String, Object?>{
      'id': id,
      'title': '改 $id',
      'status': 'queued',
      'write_scope': writeScope,
      'read_scope': <String>['lib/'],
      'acceptance': <String>['dart analyze 无新增'],
    };
    if (gate != null) input['gate'] = gate;
    store.createTask('pl_t', input);
  }

  String taskPath(String taskId) => p.join(
    temp.path,
    'production_lines',
    'production',
    'pl_t',
    'tasks',
    taskId,
    'task.yaml',
  );

  test('SG-01 租约 + fencing：同 owner 递增、异 owner 冲突、旧 token 失效', () {
    queuedTask('T1');
    final TaskLease first = store.acquireLease(
      'pl_t',
      'T1',
      owner: 'agt',
      runId: 'run_1',
    );
    expect(first.fencing, 1);
    final TaskLease second = store.acquireLease(
      'pl_t',
      'T1',
      owner: 'agt',
      runId: 'run_2',
    );
    expect(second.fencing, 2);
    expect(
      () => store.acquireLease(
        'pl_t',
        'T1',
        owner: 'other',
        runId: 'run_3',
      ),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure error) => error.code,
          'code',
          'duplicate_execution',
        ),
      ),
    );
    expect(
      () => store.assertLease('pl_t', 'T1', first.fencing),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure error) => error.code,
          'code',
          'lease_lost',
        ),
      ),
    );
    store.assertLease('pl_t', 'T1', second.fencing);
    expect(store.releaseLease('pl_t', 'T1', first.fencing), isNull);
    expect(store.releaseLease('pl_t', 'T1', second.fencing)?.fencing, 2);
  });

  test('SG-01 执行期间有租约、pack 完成后释放且 fencing 保留水位', () async {
    Object? during;
    final ProductionExecutionService watching = ProductionExecutionService(
      workers: (WorkerCall call, Map<String, Object?> scope) async {
        if (call.role == 'packer') {
          during = store.getTask('pl_t', 'T1').data['lease'];
        }
        return workers.run(call, scope);
      },
      commands: commands.run,
    );
    queuedTask('T1');
    final Map<String, Object?> result = await watching.handle(
      'production.task.pack',
      <String, Object?>{'line_id': 'pl_t', 'task_id': 'T1'},
      <String, Object?>{'data_dir': temp.path},
      <String, Object?>{'team_id': 'team_a', 'agent_id': 'agt'},
    );
    expect(result['status'], 'packed');
    expect(during, isNotNull);
    expect(plainMap(during)['fencing'], 1);
    final TaskRecord saved = store.getTask('pl_t', 'T1');
    expect(saved.data.containsKey('lease'), isFalse);
    expect(saved.data['lease_fencing'], 1);
  });

  test('SG-02 幂等命令：同一 idempotency_key 的 pack 只执行一次', () async {
    queuedTask('T1');
    final Map<String, Object?> first = await call(
      'production.task.pack',
      <String, Object?>{
        'line_id': 'pl_t',
        'task_id': 'T1',
        'idempotency_key': 'key-1',
      },
    );
    expect(first['status'], 'packed');
    expect(workers.calls.length, 1);
    final Map<String, Object?> second = await call(
      'production.task.pack',
      <String, Object?>{
        'line_id': 'pl_t',
        'task_id': 'T1',
        'idempotency_key': 'key-1',
      },
    );
    expect(second['status'], 'packed');
    expect(workers.calls.length, 1, reason: '重复命令不再执行');
    expect(
      plainMap(second['run'])['run_id'],
      plainMap(first['run'])['run_id'],
    );
  });

  test('SG-03 事件日志：create / transition / recovery 行齐全', () {
    queuedTask('T1');
    store.transition('pl_t', 'T1', to: 'packing');
    final Map<String, Object?> recovered = store.recover('pl_t');
    expect(recovered['count'], 1);
    final List<Map<String, Object?>> events = store.readEvents('pl_t');
    final Set<String> types = <String>{
      for (final Map<String, Object?> event in events)
        textOf(event['type']),
    };
    expect(types, containsAll(<String>['create', 'transition', 'recovery']));
  });

  test('SG-03 对账：task.yaml 被改后按真值修复 state.json，幂等', () async {
    queuedTask('T1');
    final Map<String, Object?> tampered = <String, Object?>{
      ...store.getTask('pl_t', 'T1').data,
      'status': 'blocked',
      'depends_on': <String>['T9'],
    };
    File(taskPath('T1')).writeAsStringSync(encodeYaml(tampered));

    final Map<String, Object?> report = productionCall(
      'production.queue.reconcile',
      <String, Object?>{'line_id': 'pl_t'},
    );
    expect(report['fixed'], isTrue);
    expect(
      (report['mismatches'] as List<dynamic>).map(
        (dynamic item) => plainMap(item)['field'],
      ),
      containsAll(<String>['status', 'depends_on']),
    );

    final Map<String, Object?> state = plainMap(
      jsonDecode(
        File(
          p.join(
            temp.path,
            'production_lines',
            'production',
            'pl_t',
            'state.json',
          ),
        ).readAsStringSync(),
      ),
    );
    final Map<String, Object?> indexed = plainMap(
      (state['tasks'] as List<dynamic>).single,
    );
    expect(indexed['status'], 'blocked');
    expect(indexed['depends_on'], <String>['T9']);

    final Map<String, Object?> again = productionCall(
      'production.queue.reconcile',
      <String, Object?>{'line_id': 'pl_t'},
    );
    expect(again['ok'], isTrue);
    expect(again['mismatches'], isEmpty);
    expect(again['fixed'], isFalse);
  });

  test('SG-04 独立门控 runner：写 gate.json；异 runner 覆盖 ⇒ gate_tampered', () async {
    queuedTask(
      'G1',
      gate: <String, Object?>{
        'commands': <String>['dart analyze'],
      },
    );
    final Map<String, Object?> gate = await call('production.gate.run', {
      'line_id': 'pl_t',
      'task_id': 'G1',
      'run_id': 'grun-1',
    });
    expect(gate['ok'], isTrue);
    expect(gate['runner_id'], 'gate_runner');
    expect(gate['sealed'], isTrue);
    final String gatePath = store.gateFile('pl_t', 'G1', 'grun-1');
    expect(File(gatePath).existsSync(), isTrue);
    expect(store.readGate('pl_t', 'G1', 'grun-1')['ok'], isTrue);

    await expectLater(
      () => call('production.gate.run', {
        'line_id': 'pl_t',
        'task_id': 'G1',
        'run_id': 'grun-1',
        'runner_id': 'attacker',
      }),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure error) => error.code,
          'code',
          'gate_tampered',
        ),
      ),
    );
    expect(store.getTask('pl_t', 'G1').status, TaskStatus.queued);
  });

  test('SG-04 执行者不能传 gate 自签：gate_source_invalid', () async {
    queuedTask('T1');
    await call('production.task.pack', {
      'line_id': 'pl_t',
      'task_id': 'T1',
    });
    await expectLater(
      () => call('production.task.run', {
        'line_id': 'pl_t',
        'task_id': 'T1',
        'gate': <String>['dart analyze'],
      }),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure error) => error.code,
          'code',
          'gate_source_invalid',
        ),
      ),
    );
    expect(store.getTask('pl_t', 'T1').status, TaskStatus.packed);
  });

  test('SG-04 done 必须有通过的门控（plan_version 任务），旧任务不检查', () {
    queuedTask('D1');
    store.putTask('pl_t', 'D1', <String, Object?>{'plan_version': 'plan-v1'});
    for (final String to in <String>[
      'packing',
      'packed',
      'running',
      'gating',
    ]) {
      store.transition('pl_t', 'D1', to: to);
    }
    expect(
      () => productionCall('production.task.transition', <String, Object?>{
        'line_id': 'pl_t',
        'task_id': 'D1',
        'to': 'done',
      }),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure error) => error.code,
          'code',
          'gate_missing',
        ),
      ),
    );
    expect(store.getTask('pl_t', 'D1').status, TaskStatus.gating);
  });

  test('SG-05 黄金任务：两个 modelId 形状一致，缺字段回 model_swap_regression', () async {
    final Map<String, Object?> gate = <String, Object?>{
      'version': 1,
      'run_id': 'r1',
      'runner_id': 'gate_runner',
      'fencing': 1,
      'started_at': '2026-11-14T10:00:00',
      'finished_at': '2026-11-14T10:01:00',
      'ok': true,
      'commands': <Object?>[],
      'checklist': <Object?>[],
      'evidence_hashes': <String, Object?>{},
    };
    final Map<String, Object?> a = productionCall(
      'production.stability.golden',
      <String, Object?>{
        'line_id': 'pl_t',
        'model_id': 'model-a',
        'gate': gate,
        'ok': true,
      },
    );
    final Map<String, Object?> b = productionCall(
      'production.stability.golden',
      <String, Object?>{
        'line_id': 'pl_t',
        'model_id': 'model-b',
        'gate': gate,
        'ok': true,
      },
    );
    expect(a['ok'], isTrue);
    expect(a['gate_shape'], b['gate_shape']);

    final Map<String, Object?> missing = <String, Object?>{
      ...gate,
    }..remove('commands');
    final Map<String, Object?> broken = productionCall(
      'production.stability.golden',
      <String, Object?>{
        'line_id': 'pl_t',
        'model_id': 'model-c',
        'gate': missing,
        'ok': true,
      },
    );
    expect(broken['ok'], isFalse);
    expect(broken['code'], 'model_swap_regression');
    expect(broken['missing'], contains('commands'));
  });

  test('SG-06 SLO：recovery / blocked / retry 计数；超 SLO 回 recovery_slo_missed', () async {
    store.createTask('pl_t', <String, Object?>{
      'id': 'B1',
      'title': '阻塞任务',
      'status': 'queued',
      'write_scope': <String>['lib/a.dart'],
    });
    store.transition('pl_t', 'B1', to: 'blocked', reason: '等拍板');
    store.putTask('pl_t', 'B1', <String, Object?>{'gate_attempts': 2});
    store.writeRun('pl_t', <String, Object?>{
      'run_id': 'run_T1_interrupted',
      'task_id': 'T1',
      'role': 'executor',
      'model_id': '',
      'status': 'interrupted',
      'started_at': '2026-11-14T10:00:00',
      'elapsed_ms': 90000,
      'recovery_ms': 90000,
      'tokens': <String, Object?>{'prompt': 0, 'completion': 0},
      'tool_calls': <Object?>[],
      'gate': <Object?>[],
      'error': '',
      'artifacts': <Object?>[],
    });
    store.writeRun('pl_t', <String, Object?>{
      'run_id': 'run_ok',
      'task_id': 'T2',
      'role': 'executor',
      'model_id': 'chat/main',
      'status': 'ok',
      'started_at': '2026-11-14T10:01:00',
      'elapsed_ms': 1000,
      'tokens': <String, Object?>{'prompt': 0, 'completion': 0},
      'tool_calls': <Object?>[],
      'gate': <Object?>[],
      'error': '',
      'artifacts': <Object?>[],
    });

    final Map<String, Object?> missed = productionCall(
      'production.stability.metrics',
      <String, Object?>{'line_id': 'pl_t'},
    );
    expect(missed['ok'], isFalse);
    expect(missed['code'], 'recovery_slo_missed');
    expect(missed['recovery_count'], 1);
    expect(missed['recovery_ms_p95'], 90000);
    expect(missed['blocked_count'], 1);
    expect(missed['retry_count'], greaterThanOrEqualTo(2));
    expect(missed['recovery_slo_ms'], kDefaultRecoverySloMs);

    store.updateLine('pl_t', <String, Object?>{
      'limits': <String, Object?>{'recovery_slo_ms': 120000},
    });
    final Map<String, Object?> healthy = productionCall(
      'production.stability.metrics',
      <String, Object?>{'line_id': 'pl_t'},
    );
    expect(healthy['ok'], isTrue);
    expect(healthy['recovery_slo_ms'], 120000);
  });
}

class _Workers {
  final List<WorkerCall> calls = <WorkerCall>[];
  String packReport = '';
  String runReport = '已改 lib/a.dart';

  Future<Map<String, Object?>> run(
    WorkerCall call,
    Map<String, Object?> scope,
  ) async {
    calls.add(call);
    if (call.role == 'packer') {
      return <String, Object?>{
        'worker_id': 'sub_packer',
        'status': 'ok',
        'report': packReport,
        'error': '',
        'tokens': const <String, Object?>{},
      };
    }
    return <String, Object?>{
      'worker_id': 'sub_executor',
      'status': 'ok',
      'report': runReport,
      'error': '',
      'tokens': const <String, Object?>{},
    };
  }
}

class _Commands {
  bool gateOk = true;
  String gateOutput = 'ok';
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
      return CommandResult(ok: true, output: '');
    }
    return CommandResult(
      ok: gateOk,
      exitCode: gateOk ? 0 : 1,
      output: gateOutput,
    );
  }
}
