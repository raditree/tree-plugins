import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

/// 假员工：按角色返回报告（打包 JSON / 执行文本 / 专家四段 JSON）。
class _Workers {
  final List<WorkerCall> calls = <WorkerCall>[];
  final List<Map<String, Object?>> scopes = <Map<String, Object?>>[];
  String packReport = '';
  String runReport = '已改 lib/a.dart';
  String expertReport = '';
  String status = 'ok';
  String error = '';

  /// 员工回包的 token 用量（P8 预算累计）。
  Map<String, Object?> tokens = const <String, Object?>{};

  Future<Map<String, Object?>> run(
    WorkerCall call,
    Map<String, Object?> scope,
  ) async {
    calls.add(call);
    scopes.add(scope);
    if (call.role == 'packer') {
      return <String, Object?>{
        'worker_id': 'sub_packer',
        'status': status,
        'report': packReport,
        'error': error,
        'tokens': tokens,
      };
    }
    if (call.role == 'expert') {
      return <String, Object?>{
        'worker_id': 'sub_expert',
        'role': 'expert',
        'model_id': call.modelId,
        'status': status,
        'report': expertReport,
        'error': error,
        'tokens': tokens,
      };
    }
    return <String, Object?>{
      'worker_id': 'sub_executor',
      'status': status,
      'report': runReport,
      'error': error,
      'tokens': tokens,
    };
  }
}

/// 假命令执行器：git status 按次数交替返回「执行前 / 执行后」。
class _Commands {
  String before = '';
  String after = ' M lib/a.dart';
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
      return CommandResult(
        ok: true,
        output: gitCalls.isOdd ? before : after,
      );
    }
    return CommandResult(
      ok: gateOk,
      exitCode: gateOk ? 0 : 1,
      output: gateOutput,
    );
  }
}

void main() {
  late Directory temp;
  late String workspace;
  late ProductionStore store;
  late _Workers workers;
  late _Commands commands;
  late ProductionExecutionService service;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_production_p4_');
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
      })
      ..expertReport = jsonEncode(<String, Object?>{
        'conclusion': '用 A 的公开 API',
        'evidence': <String>['lib/a.dart:1 — class 定义'],
        'suggestion': '先 read 再 edit',
        'open': <String>['旧版本行为未验证'],
      });
    commands = _Commands();
    service = ProductionExecutionService(workers: workers.run, commands: commands.run);
    store.createLine(<String, Object?>{
      'id': 'pl_t',
      'name': '测试产线',
      'workspace_dir': workspace,
      'limits': <String, Object?>{'retries': 1},
    });
  });

  tearDown(() {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<Map<String, Object?>> call(
    String command,
    Map<String, Object?> arguments, {
    String agent = 'agt',
  }) => service.handle(
    command,
    arguments,
    <String, Object?>{'data_dir': temp.path},
    <String, Object?>{'team_id': 'team_a', 'agent_id': agent},
  );

  void queuedTask(
    String id, {
    List<String> writeScope = const <String>['lib/a.dart'],
    List<String> readScope = const <String>['lib/'],
  }) {
    store.createTask('pl_t', <String, Object?>{
      'id': id,
      'title': '改 $id',
      'status': 'queued',
      'write_scope': writeScope,
      'read_scope': readScope,
      'acceptance': <String>['dart analyze 无新增'],
    });
  }

  test('打包 → 执行 → 门控：端到端 done，pack.json / pack.md / runs 都落盘', () async {
    queuedTask('T1');
    final Map<String, Object?> packed = await call(
      'production.task.pack',
      <String, Object?>{'line_id': 'pl_t', 'task_id': 'T1'},
    );
    expect(packed['status'], 'packed');
    expect((packed['task'] as Map<String, Object?>)['status'], 'packed');
    expect(
      File(
        p.join(
          temp.path,
          'production_lines',
          'production',
          'pl_t',
          'tasks',
          'T1',
          'pack.json',
        ),
      ).existsSync(),
      isTrue,
    );
    expect(
      File(
        p.join(workspace, 'docs', 'production_lines', 'pl_t', 'tasks', 'T1', 'pack.md'),
      ).existsSync(),
      isTrue,
    );
    expect(workers.calls.single.role, 'packer');
    expect(workers.calls.single.tools, contains('read'));
    expect(workers.calls.single.tools, isNot(contains('write')));

    final Map<String, Object?> ran = await call(
      'production.task.run',
      <String, Object?>{'line_id': 'pl_t', 'task_id': 'T1'},
    );
    expect(ran['status'], 'done');
    expect((ran['task'] as Map<String, Object?>)['status'], 'done');
    expect(workers.calls.map((WorkerCall call) => call.role), <String>[
      'packer',
      'executor',
    ]);
    expect((ran['gate'] as List<dynamic>).single['command'], 'dart analyze');
    final List<Map<String, Object?>> runs = store.listRuns('pl_t', taskId: 'T1');
    expect(runs.length, 2);
    expect(runs.map((Map<String, Object?> run) => run['role']).toSet(), <String>{
      'packer',
      'executor',
    });
    expect(runs.firstWhere((Map<String, Object?> r) => r['role'] == 'executor')['status'], 'ok');
  });

  test('身份取自 line.yaml.executor，与调用方 agent 无关（§16）', () async {
    store.updateLine('pl_t', <String, Object?>{
      'executor': <String, Object?>{
        'agent_id': 'agt_line',
        'team_id': 'team_line',
      },
    });
    queuedTask('T1');
    final Map<String, Object?> packed = await call(
      'production.task.pack',
      <String, Object?>{'line_id': 'pl_t', 'task_id': 'T1'},
      agent: 'agt_caller',
    );
    expect(packed['status'], 'packed');
    expect(workers.scopes.single['agent_id'], 'agt_line');
    expect(workers.scopes.single['team_id'], 'team_line');
    expect(workers.scopes.single['session_id'], 'pl_pl_t_T1');

    await call('production.task.run', <String, Object?>{
      'line_id': 'pl_t',
      'task_id': 'T1',
    });
    expect(workers.scopes.last['agent_id'], 'agt_line');
  });

  test('无 executor 且无调用方身份 ⇒ executor_required（不猜 Agent）', () async {
    queuedTask('T1');
    await expectLater(
      () => service.handle(
        'production.task.pack',
        <String, Object?>{'line_id': 'pl_t', 'task_id': 'T1'},
        <String, Object?>{'data_dir': temp.path},
        const <String, Object?>{},
      ),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure error) => error.code,
          'code',
          'executor_required',
        ),
      ),
    );
    expect(workers.calls, isEmpty);
  });

  test('写域越界：不进 done，任务 blocked 且台账记 violations', () async {
    queuedTask('T1');
    await call('production.task.pack', <String, Object?>{
      'line_id': 'pl_t',
      'task_id': 'T1',
    });
    commands.after = ' M lib/other.dart';
    final Map<String, Object?> ran = await call(
      'production.task.run',
      <String, Object?>{'line_id': 'pl_t', 'task_id': 'T1'},
    );
    expect(ran['status'], 'write_scope_violation');
    expect((ran['task'] as Map<String, Object?>)['status'], 'blocked');
    expect(ran['error'], contains('写域越界'));
    expect(store.getTask('pl_t', 'T1').data['violations'], <String>['lib/other.dart']);
    expect(commands.ran.where((String c) => c == 'dart analyze'), isEmpty);
  });

  test('门控失败：第一次回 packed 重试，超限 blocked，绝不进 done', () async {
    queuedTask('T1');
    await call('production.task.pack', <String, Object?>{
      'line_id': 'pl_t',
      'task_id': 'T1',
    });
    commands
      ..before = ' M lib/a.dart'
      ..after = ' M lib/a.dart'
      ..gateOk = false
      ..gateOutput = 'analyze 有新增错误';
    final Map<String, Object?> first = await call(
      'production.task.run',
      <String, Object?>{'line_id': 'pl_t', 'task_id': 'T1'},
    );
    expect(first['status'], 'retry');
    expect(first['attempts'], 1);
    expect((first['task'] as Map<String, Object?>)['status'], 'packed');
    final Map<String, Object?> second = await call(
      'production.task.run',
      <String, Object?>{'line_id': 'pl_t', 'task_id': 'T1'},
    );
    expect(second['status'], 'blocked');
    expect((second['task'] as Map<String, Object?>)['status'], 'blocked');
    expect(second['error'], contains('门控失败'));
    expect(store.getTask('pl_t', 'T1').status, TaskStatus.blocked);
  });

  test('打包失败：空片段 / 越出读域 → blocked，不产生 pack.json', () async {
    queuedTask('T1');
    workers.packReport = jsonEncode(<String, Object?>{'files': <Object?>[]});
    final Map<String, Object?> empty = await call(
      'production.task.pack',
      <String, Object?>{'line_id': 'pl_t', 'task_id': 'T1'},
    );
    expect(empty['status'], 'failed');
    expect((empty['task'] as Map<String, Object?>)['status'], 'blocked');
    expect(
      File(
        p.join(temp.path, 'production_lines', 'production', 'pl_t', 'tasks', 'T1', 'pack.json'),
      ).existsSync(),
      isFalse,
    );

    // 越出读域：read_scope 只有 lib/，片段给 docs/。
    queuedTask('T2', readScope: <String>['lib/']);
    workers.packReport = jsonEncode(<String, Object?>{
      'files': <Object?>[
        <String, Object?>{'path': 'docs/a.md', 'content': 'x'},
      ],
    });
    final Map<String, Object?> outside = await call(
      'production.task.pack',
      <String, Object?>{'line_id': 'pl_t', 'task_id': 'T2'},
    );
    expect(outside['status'], 'failed');
    expect(outside['error'], contains('读域'));
  });

  test('执行前的 git status 失败：fail-closed，任务仍停在 packed', () async {
    queuedTask('T1');
    await call('production.task.pack', <String, Object?>{
      'line_id': 'pl_t',
      'task_id': 'T1',
    });
    final ProductionExecutionService broken = ProductionExecutionService(
      workers: workers.run,
      commands: (String command, {
        required String workspace,
        required Map<String, Object?> scope,
      }) async => const CommandResult(ok: false, output: 'not a git repo'),
    );
    await expectLater(
      broken.handle(
        'production.task.run',
        <String, Object?>{'line_id': 'pl_t', 'task_id': 'T1'},
        <String, Object?>{'data_dir': temp.path},
        <String, Object?>{'team_id': 'team_a', 'agent_id': 'agt'},
      ),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure e) => e.code,
          'code',
          'workspace_vcs_unavailable',
        ),
      ),
    );
    expect(store.getTask('pl_t', 'T1').status, TaskStatus.packed);
  });

  test('状态与执行身份 fail-closed：无 executor / 未打包先执行', () async {
    queuedTask('T1');
    await expectLater(
      call(
        'production.task.pack',
        <String, Object?>{'line_id': 'pl_t', 'task_id': 'T1'},
        agent: '',
      ),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure error) => error.code,
          'code',
          'executor_required',
        ),
      ),
    );
    await expectLater(
      call('production.task.run', <String, Object?>{
        'line_id': 'pl_t',
        'task_id': 'T1',
      }),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure e) => e.code,
          'code',
          'execute_state',
        ),
      ),
    );
  });

  Future<void> expertLine({
    List<String> tools = const <String>['read', 'grep'],
    int max = 2,
  }) async {
    store.createLine(<String, Object?>{
      'id': 'pl_e',
      'name': '专家产线',
      'workspace_dir': workspace,
      'roles': <String, Object?>{
        'expert': <String, Object?>{
          'enabled': true,
          'model_id': 'm1',
          'tools': tools,
          'max_per_task': max,
        },
      },
    });
    store.createTask('pl_e', <String, Object?>{
      'id': 'E1',
      'title': '问专家',
      'status': 'queued',
      'write_scope': <String>['lib/a.dart'],
    });
  }

  test('专家默认关闭：未启用直接拒绝，不调员工', () async {
    queuedTask('T1');
    await expectLater(
      call('production.task.expert', <String, Object?>{
        'line_id': 'pl_t',
        'task_id': 'T1',
        'question': 'X 怎么用？',
      }),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure e) => e.code,
          'code',
          'expert_disabled',
        ),
      ),
    );
    expect(workers.calls, isEmpty);
  });

  test('启用后：四段回答 + expert 台账 + 工具表注入 ask_expert', () async {
    await expertLine();
    final Map<String, Object?> result = await call(
      'production.task.expert',
      <String, Object?>{
        'line_id': 'pl_e',
        'task_id': 'E1',
        'role': 'packer',
        'question': 'X 怎么用？',
        'context': 'lib/a.dart:1 class A {}',
      },
    );
    expect(result['status'], 'ok');
    expect(result['remaining'], 1);
    expect(result['text'], contains('结论：'));
    expect(result['text'], contains('未决：'));
    expect(workers.calls.single.role, 'expert');
    expect(workers.calls.single.tools, <String>['read', 'grep']);
    expect(workers.calls.single.modelId, 'm1');
    final List<Map<String, Object?>> runs = store.listRuns('pl_e', taskId: 'E1');
    expect(runs.single['role'], 'expert');
    expect(runs.single['status'], 'ok');
    expect(runs.single['asked_by'], 'packer');
    expect(
      (runs.single['answer'] as Map<String, Object?>)['conclusion'],
      '用 A 的公开 API',
    );

    // 启用专家后，打包 / 执行的工具表里出现 ask_expert（默认关闭时不出现），
    // 提示词里也带上 line_id / task_id 供工具调用。
    await call('production.task.pack', <String, Object?>{
      'line_id': 'pl_e',
      'task_id': 'E1',
    });
    expect(workers.calls.last.role, 'packer');
    expect(workers.calls.last.tools, contains(kAskExpertTool));
    expect(workers.calls.last.task, contains('ask_expert'));
    expect(workers.calls.last.task, contains('line_id=pl_e'));

    await call('production.task.run', <String, Object?>{
      'line_id': 'pl_e',
      'task_id': 'E1',
    });
    expect(workers.calls.last.role, 'executor');
    expect(workers.calls.last.task, contains('ask_expert'));
  });

  test('次数上限：到点拒绝（单任务 max_per_task）', () async {
    await expertLine(max: 1);
    await call('production.task.expert', <String, Object?>{
      'line_id': 'pl_e',
      'task_id': 'E1',
      'question': '第一个问题',
    });
    await expectLater(
      call('production.task.expert', <String, Object?>{
        'line_id': 'pl_e',
        'task_id': 'E1',
        'question': '第二个问题',
      }),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure e) => e.code,
          'code',
          'expert_limit_exceeded',
        ),
      ),
    );
    expect(workers.calls, hasLength(1));
  });

  test('专家回答不是 JSON：failed，但台账仍记（计入次数）', () async {
    await expertLine(max: 3);
    workers.expertReport = '好的，我查到了';
    final Map<String, Object?> result = await call(
      'production.task.expert',
      <String, Object?>{
        'line_id': 'pl_e',
        'task_id': 'E1',
        'question': 'X 怎么用？',
      },
    );
    expect(result['status'], 'failed');
    expect(result['error'], contains('JSON'));
    expect(result['remaining'], 2);
    final List<Map<String, Object?>> runs = store.listRuns('pl_e', taskId: 'E1');
    expect(runs.single['status'], 'failed');
    expect(runs.single['error'], contains('JSON'));
  });

  test('专家不能再召专家 / 工具表含 write 一律拒绝', () async {
    await expertLine();
    await expectLater(
      call('production.task.expert', <String, Object?>{
        'line_id': 'pl_e',
        'task_id': 'E1',
        'role': 'expert',
        'question': '再问一层',
      }),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure e) => e.code,
          'code',
          'expert_not_allowed',
        ),
      ),
    );

    store.createLine(<String, Object?>{
      'id': 'pl_bad',
      'name': '越界专家',
      'workspace_dir': workspace,
      'roles': <String, Object?>{
        'expert': <String, Object?>{
          'enabled': true,
          'tools': <String>['read', 'write'],
        },
      },
    });
    store.createTask('pl_bad', <String, Object?>{
      'id': 'B1',
      'title': '越界',
      'status': 'queued',
      'write_scope': <String>['lib/a.dart'],
    });
    await expectLater(
      call('production.task.expert', <String, Object?>{
        'line_id': 'pl_bad',
        'task_id': 'B1',
        'question': 'X 怎么用？',
      }),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure e) => e.code,
          'code',
          'expert_tools_invalid',
        ),
      ),
    );
    expect(workers.calls, isEmpty);
  });

  test('任务内 message：落线程；打回超过 3 次自动 blocked', () async {
    queuedTask('T1');
    for (int i = 1; i <= 3; i++) {
      final Map<String, Object?> sent = await call(
        'production.task.message',
        <String, Object?>{
          'line_id': 'pl_t',
          'task_id': 'T1',
          'from': 'executor',
          'to': 'packer',
          'kind': 'question',
          'text': '缺片段 $i',
        },
      );
      expect(sent['questions'], i);
      expect(sent['blocked'], isFalse);
    }
    final Map<String, Object?> fourth = await call(
      'production.task.message',
      <String, Object?>{
        'line_id': 'pl_t',
        'task_id': 'T1',
        'from': 'executor',
        'to': 'packer',
        'kind': 'question',
        'text': '又缺片段',
      },
    );
    expect(fourth['questions'], 4);
    expect(fourth['blocked'], isTrue);
    expect(store.getTask('pl_t', 'T1').status, TaskStatus.blocked);
    final Map<String, Object?> listed = await call(
      'production.task.messages',
      <String, Object?>{'line_id': 'pl_t', 'task_id': 'T1'},
    );
    expect(listed['count'], 4);
    expect(((listed['messages'] as List<dynamic>).first as Map<String, Object?>)['text'], '缺片段 1');
  });

  test('预算到点：打包产出保留但软停 blocked，不静默继续', () async {
    store.createLine(<String, Object?>{
      'id': 'pl_b',
      'name': '预算产线',
      'workspace_dir': workspace,
      'limits': <String, Object?>{'max_tokens_per_task': 10},
    });
    store.createTask('pl_b', <String, Object?>{
      'id': 'B1',
      'title': '预算到点',
      'status': 'queued',
      'write_scope': <String>['lib/a.dart'],
    });
    workers.tokens = <String, Object?>{'prompt': 5, 'completion': 10};
    final Map<String, Object?> packed = await call(
      'production.task.pack',
      <String, Object?>{'line_id': 'pl_b', 'task_id': 'B1'},
    );
    expect(packed['status'], 'budget_exceeded');
    expect((packed['task'] as Map<String, Object?>)['status'], 'blocked');
    expect((packed['budget'] as Map<String, Object?>)['exceeded'], isTrue);
    expect((packed['run'] as Map<String, Object?>)['status'], 'ok');
    expect((packed['run'] as Map<String, Object?>)['budget_exceeded'], isTrue);
    // 当前产出保留：pack.json 已落盘，用量写回 task.yaml。
    expect(
      File(
        p.join(
          temp.path,
          'production_lines',
          'production',
          'pl_b',
          'tasks',
          'B1',
          'pack.json',
        ),
      ).existsSync(),
      isTrue,
    );
    expect(store.getTask('pl_b', 'B1').data['budget_exceeded'], isTrue);

    final Map<String, Object?> report = await call(
      'production.task.budget',
      <String, Object?>{'line_id': 'pl_b', 'task_id': 'B1'},
    );
    expect(report['exceeded'], isTrue);
    expect((report['usage'] as Map<String, Object?>)['tokens'], 15);

    // 不静默继续：blocked 状态不再打包，也不会再调员工。
    final int before = workers.calls.length;
    await expectLater(
      call('production.task.pack', <String, Object?>{
        'line_id': 'pl_b',
        'task_id': 'B1',
      }),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure e) => e.code,
          'code',
          'execute_state',
        ),
      ),
    );
    expect(workers.calls.length, before);

    // 重新入队 = 用户已处理阻塞：旧软停标记清掉（历史仍在 runs 台账）。
    store.transition('pl_b', 'B1', to: 'queued', reason: '用户加预算');
    expect(
      store.getTask('pl_b', 'B1').data.containsKey('budget_exceeded'),
      isFalse,
    );
  });

  test('调用前已超限：不发起员工、不出 pack.json，直接软停 blocked', () async {
    store.createLine(<String, Object?>{
      'id': 'pl_pre',
      'name': '预算前置',
      'workspace_dir': workspace,
      'limits': <String, Object?>{'max_tokens_per_task': 10},
    });
    store.createTask('pl_pre', <String, Object?>{
      'id': 'P1',
      'title': '已用满',
      'status': 'queued',
      'write_scope': <String>['lib/a.dart'],
    });
    // usage 是运行期字段（createTask 不接收），按真实路径写回。
    store.putTask('pl_pre', 'P1', <String, Object?>{
      'usage': <String, Object?>{
        'prompt_tokens': 6,
        'completion_tokens': 4,
      },
    });
    final int before = workers.calls.length;
    final Map<String, Object?> result = await call(
      'production.task.pack',
      <String, Object?>{'line_id': 'pl_pre', 'task_id': 'P1'},
    );
    expect(result['status'], 'budget_exceeded');
    expect((result['task'] as Map<String, Object?>)['status'], 'blocked');
    expect((result['run'] as Map<String, Object?>)['status'], 'budget_exceeded');
    expect(workers.calls.length, before, reason: '到点不再发起员工调用');
    expect(
      File(
        p.join(
          temp.path,
          'production_lines',
          'production',
          'pl_pre',
          'tasks',
          'P1',
          'pack.json',
        ),
      ).existsSync(),
      isFalse,
    );
  });

  test('执行后到点：改动保留但不跑门控，任务 blocked', () async {
    store.createLine(<String, Object?>{
      'id': 'pl_run',
      'name': '执行预算',
      'workspace_dir': workspace,
      'limits': <String, Object?>{'max_tokens_per_task': 10},
    });
    store.createTask('pl_run', <String, Object?>{
      'id': 'R1',
      'title': '执行到点',
      'status': 'queued',
      'write_scope': <String>['lib/a.dart'],
      'read_scope': <String>['lib/'],
    });
    final Map<String, Object?> packed = await call(
      'production.task.pack',
      <String, Object?>{'line_id': 'pl_run', 'task_id': 'R1'},
    );
    expect(packed['status'], 'packed');

    workers.tokens = <String, Object?>{'prompt': 8, 'completion': 8};
    final int ranBefore = commands.ran.length;
    final Map<String, Object?> result = await call(
      'production.task.run',
      <String, Object?>{'line_id': 'pl_run', 'task_id': 'R1'},
    );
    expect(result['status'], 'budget_exceeded');
    expect((result['task'] as Map<String, Object?>)['status'], 'blocked');
    expect(
      (result['run'] as Map<String, Object?>)['changed_files'],
      <String>['lib/a.dart'],
    );
    final List<String> after = commands.ran.skip(ranBefore).toList();
    expect(
      after.where((String command) => !command.contains('git status')),
      isEmpty,
      reason: '预算到点不跑门控',
    );
  });
}
