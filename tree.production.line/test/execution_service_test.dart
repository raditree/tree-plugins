import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

/// 假员工：按角色返回报告（打包 JSON / 执行文本）。
class _Workers {
  final List<WorkerCall> calls = <WorkerCall>[];
  String packReport = '';
  String runReport = '已改 lib/a.dart';
  String status = 'ok';

  Future<Map<String, Object?>> run(
    WorkerCall call,
    Map<String, Object?> scope,
  ) async {
    calls.add(call);
    if (call.role == 'packer') {
      return <String, Object?>{
        'worker_id': 'sub_packer',
        'status': status,
        'report': packReport,
        'error': '',
      };
    }
    return <String, Object?>{
      'worker_id': 'sub_executor',
      'status': status,
      'report': runReport,
      'error': '',
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
    store = ProductionStore(dataRoot: temp.path, teamId: 'team_a');
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
          'team_a',
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
        p.join(temp.path, 'production_lines', 'team_a', 'pl_t', 'tasks', 'T1', 'pack.json'),
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

  test('状态与身份 fail-closed：缺 agent / 未打包先执行', () async {
    queuedTask('T1');
    await expectLater(
      call(
        'production.task.pack',
        <String, Object?>{'line_id': 'pl_t', 'task_id': 'T1'},
        agent: '',
      ),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure e) => e.code,
          'code',
          'agent_required',
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
}
