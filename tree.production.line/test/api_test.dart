import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

/// 切片 2 / 3：产线 REST 委派（§10.2 的读半边 + 写半边）。
///
/// 锁住：
/// 1. 申报清单覆盖 GET / POST / PATCH / DELETE；
/// 2. 读路由都复用命令门面，不复制业务规则；
/// 3. 写路由映射到已有命令（建 / 改 / 删产线，建 / 改 / 取消任务，决策，派发）；
/// 4. 数据根 / 团队缺失 fail-closed，未知产线 404，状态冲突 409；
/// 5. 产物树在"未配 workspace_dir"时给 200 + 空树 + note，不是失败。
void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('production_api_');
  });

  tearDown(() {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  ProductionStore storeWith({String workspaceDir = ''}) {
    final ProductionStore store = ProductionStore(
      dataRoot: temp.path,
      teamId: 'team_a',
    );
    store.createLine(<String, Object?>{
      'id': 'pl_1',
      'name': '标准开发流',
      'workspace_dir': workspaceDir,
    });
    store.createTask('pl_1', <String, Object?>{
      'id': 'T1',
      'title': '底座',
      'status': 'queued',
      'priority': 10,
    });
    return store;
  }

  Map<String, dynamic> envelope(
    String method,
    String path, {
    Map<String, Object?> query = const <String, Object?>{},
    Map<String, Object?> body = const <String, Object?>{},
    String team = 'team_a',
    String agent = '',
    String? dataDir,
  }) => <String, dynamic>{
    'method': method,
    'path': path,
    'params': <String, dynamic>{},
    'query': query,
    'headers': <String, dynamic>{},
    'scope': <String, dynamic>{
      'team_id': team,
      if (agent.isNotEmpty) 'agent_id': agent,
    },
    'workspace_dir': '',
    'data_dir': dataDir ?? temp.path,
    'agent_id': agent,
    'team_id': team,
    'request_id': 'test-api',
    if (body.isNotEmpty) 'body': jsonEncode(body),
  };

  Future<Map<String, dynamic>> call(
    String method,
    String path, {
    Map<String, Object?> query = const <String, Object?>{},
    Map<String, Object?> body = const <String, Object?>{},
    String team = 'team_a',
    String agent = '',
    String? dataDir,
    ProductionExecutionService? execution,
    bool awaitDispatch = false,
  }) async {
    final Map<String, dynamic> reply = await handleProductionDelegate(
      envelope(
        method,
        path,
        query: query,
        body: body,
        team: team,
        agent: agent,
        dataDir: dataDir,
      ),
      execution: execution,
      awaitDispatch: awaitDispatch,
    );
    return <String, dynamic>{
      'status': reply['status'],
      'json': jsonDecode('${reply['body']}') as Map<String, dynamic>,
    };
  }

  test('申报清单覆盖读写方法', () {
    expect(kDeclaredRoutes, isNotEmpty);
    expect(
      kDeclaredRoutes.map((Map<String, String> route) => route['method']).toSet(),
      <String>{'GET', 'POST', 'PATCH', 'DELETE'},
    );
    expect(
      kDeclaredRoutes.any(
        (Map<String, String> route) =>
            route['method'] == 'POST' && route['pattern'] == linesPattern,
      ),
      isTrue,
    );
  });

  test('读路由：lines / line / tasks / task / runs', () async {
    storeWith();

    final Map<String, dynamic> lines = await call('GET', linesPattern);
    expect(lines['status'], 200);
    expect((lines['json']['lines'] as List<dynamic>).length, 1);

    final Map<String, dynamic> line = await call(
      'GET',
      '/api/production/lines/pl_1',
    );
    expect(line['json']['line']['name'], '标准开发流');

    final Map<String, dynamic> tasks = await call(
      'GET',
      '/api/production/lines/pl_1/tasks',
      query: <String, Object?>{'status': 'queued'},
    );
    expect(tasks['json']['count'], 1);

    final Map<String, dynamic> task = await call(
      'GET',
      '/api/production/lines/pl_1/tasks/T1',
    );
    expect(task['json']['task']['title'], '底座');

    final Map<String, dynamic> runs = await call(
      'GET',
      '/api/production/lines/pl_1/runs',
    );
    expect(runs['json']['count'], 0);
  });

  test('产物树：未配 workspace_dir ⇒ 200 + 空树 + note', () async {
    storeWith();
    final Map<String, dynamic> artifacts = await call(
      'GET',
      '/api/production/lines/pl_1/artifacts',
    );
    expect(artifacts['status'], 200);
    expect(artifacts['json']['count'], 0);
    expect('${artifacts['json']['note']}', contains('workspace_dir'));
  });

  test('项目整理：GET 只出报告，不落 audit.md', () async {
    final Directory workspace = Directory(p.join(temp.path, 'workspace'))
      ..createSync(recursive: true);
    storeWith(workspaceDir: workspace.path);
    final Map<String, dynamic> audit = await call(
      'GET',
      '/api/production/lines/pl_1/audit',
    );
    expect(audit['status'], 200);
    expect(audit['json']['written'], isFalse);
    expect(audit['json']['artifact'], '');
    expect(audit['json']['report'], isA<Map<String, dynamic>>());
  });

  test('写路由：建 / 改 / 删产线', () async {
    storeWith();

    final Map<String, dynamic> created = await call(
      'POST',
      linesPattern,
      body: <String, Object?>{'id': 'pl_new', 'name': '新产线'},
    );
    expect(created['status'], 200);
    expect(created['json']['line']['id'], 'pl_new');

    final Map<String, dynamic> updated = await call(
      'PATCH',
      '/api/production/lines/pl_new',
      body: <String, Object?>{'name': '改名', 'status': 'paused'},
    );
    expect(updated['status'], 200);
    expect(updated['json']['line']['name'], '改名');
    expect(updated['json']['line']['status'], 'paused');

    final Map<String, dynamic> badStatus = await call(
      'PATCH',
      '/api/production/lines/pl_new',
      body: <String, Object?>{'status': 'working_forever'},
    );
    expect(badStatus['status'], 400);

    final Map<String, dynamic> deleted = await call(
      'DELETE',
      '/api/production/lines/pl_new',
    );
    expect(deleted['status'], 200);
    expect(deleted['json']['deleted'], isTrue);
    expect(
      Directory(p.join(temp.path, 'production_lines', 'team_a', 'pl_new'))
          .existsSync(),
      isFalse,
    );
  });

  test('删产线：有在途任务 ⇒ 409 line_busy', () async {
    final ProductionStore store = storeWith();
    store.transition('pl_1', 'T1', to: 'packing');
    final Map<String, dynamic> reply = await call(
      'DELETE',
      '/api/production/lines/pl_1',
    );
    expect(reply['status'], 409);
    expect(reply['json']['code'], 'line_busy');
  });

  test('写路由：建任务 / 改状态 / 取消', () async {
    storeWith();
    final Map<String, dynamic> created = await call(
      'POST',
      '/api/production/lines/pl_1/tasks',
      body: <String, Object?>{
        'id': 'T2',
        'title': '新任务',
        'status': 'queued',
        'write_scope': <String>['lib/a.dart'],
      },
    );
    expect(created['status'], 200);
    expect(created['json']['task']['id'], 'T2');

    final Map<String, dynamic> moved = await call(
      'PATCH',
      '/api/production/lines/pl_1/tasks/T2',
      body: <String, Object?>{'to': 'blocked', 'reason': '等拍板'},
    );
    expect(moved['status'], 200);
    expect(moved['json']['task']['status'], 'blocked');

    final Map<String, dynamic> illegal = await call(
      'PATCH',
      '/api/production/lines/pl_1/tasks/T2',
      body: <String, Object?>{'to': 'done'},
    );
    expect(illegal['status'], 409);
    expect(illegal['json']['code'], 'invalid_transition');

    final Map<String, dynamic> cancelled = await call(
      'POST',
      '/api/production/lines/pl_1/tasks/T2/cancel',
    );
    expect(cancelled['status'], 200);
    expect(cancelled['json']['task']['status'], 'cancelled');

    final Map<String, dynamic> again = await call(
      'POST',
      '/api/production/lines/pl_1/tasks/T2/cancel',
    );
    expect(again['status'], 409);
    expect(again['json']['code'], 'terminal_state');
  });

  test('决策：questions 读待答，decision 回答 / 全部按推荐', () async {
    final Directory workspace = Directory(p.join(temp.path, 'ws'))
      ..createSync(recursive: true);
    final ProductionStore store = storeWith(workspaceDir: workspace.path);
    store.createTask('pl_1', <String, Object?>{
      'id': 'T2',
      'title': '对齐',
      'status': 'draft',
    });
    store.transition('pl_1', 'T2', to: 'recon');
    store.transition('pl_1', 'T2', to: 'aligning');
    for (final String qid in <String>['Q1', 'Q2']) {
      store.appendInbox('pl_1', <String, Object?>{
        'type': 'question',
        'line_id': 'pl_1',
        'task_id': 'T2',
        'qid': qid,
        'text': '$qid 选哪个',
        'default': 'A',
        'recommended': 'A',
      });
    }

    final Map<String, dynamic> questions = await call(
      'GET',
      '/api/production/lines/pl_1/tasks/T2/questions',
    );
    expect(questions['status'], 200);
    expect(questions['json']['open'], isA<List<dynamic>>());
    expect((questions['json']['open'] as List<dynamic>).length, 2);

    final Map<String, dynamic> empty = await call(
      'POST',
      '/api/production/lines/pl_1/tasks/T2/decision',
    );
    expect(empty['status'], 400);

    final Map<String, dynamic> answered = await call(
      'POST',
      '/api/production/lines/pl_1/tasks/T2/decision',
      body: <String, Object?>{
        'answers': <Map<String, String>>[
          <String, String>{'qid': 'Q1', 'value': 'B'},
        ],
      },
    );
    expect(answered['status'], 200);
    expect(answered['json']['open'], 1);

    final Map<String, dynamic> rest = await call(
      'POST',
      '/api/production/lines/pl_1/tasks/T2/decision',
      body: <String, Object?>{'all_recommended': true},
    );
    expect(rest['status'], 200);
    expect(rest['json']['open'], 0);
    expect(rest['json']['ready'], isTrue);
  });

  test('派发：缺身份 400；auto 按状态选 pack / run；未知任务 404', () async {
    final ProductionStore store = storeWith();
    final _FakeExecution execution = _FakeExecution();

    final Map<String, dynamic> noAgent = await call(
      'POST',
      '/api/production/lines/pl_1/tasks/T1/dispatch',
      execution: execution,
    );
    expect(noAgent['status'], 400);
    expect(noAgent['json']['code'], 'agent_required');

    final Map<String, dynamic> packed = await call(
      'POST',
      '/api/production/lines/pl_1/tasks/T1/dispatch',
      agent: 'agt',
      execution: execution,
      awaitDispatch: true,
    );
    expect(packed['status'], 200);
    expect(packed['json']['stage'], 'pack');
    expect(execution.calledCommands, <String>['production.task.pack']);

    store.transition('pl_1', 'T1', to: 'packing');
    store.transition('pl_1', 'T1', to: 'packed');
    final Map<String, dynamic> ran = await call(
      'POST',
      '/api/production/lines/pl_1/tasks/T1/dispatch',
      agent: 'agt',
      execution: execution,
      awaitDispatch: true,
    );
    expect(ran['json']['stage'], 'run');
    expect(execution.calledCommands.last, 'production.task.run');

    final Map<String, dynamic> missing = await call(
      'POST',
      '/api/production/lines/pl_1/tasks/T404/dispatch',
      agent: 'agt',
      execution: execution,
    );
    expect(missing['status'], 404);

    store.transition('pl_1', 'T1', to: 'running');
    final Map<String, dynamic> wrongState = await call(
      'POST',
      '/api/production/lines/pl_1/tasks/T1/dispatch',
      agent: 'agt',
      execution: execution,
    );
    expect(wrongState['status'], 409);
    expect(wrongState['json']['code'], 'execute_state');
  });

  test('fail-closed 与未知路由：team / data_dir / 未知产线 / 未知方法', () async {
    storeWith();

    final Map<String, dynamic> noTeam = await call(
      'GET',
      linesPattern,
      team: '',
    );
    expect(noTeam['status'], 400);

    final Map<String, dynamic> noData = await call(
      'GET',
      linesPattern,
      dataDir: '',
    );
    expect(noData['status'], 500);

    final Map<String, dynamic> missing = await call(
      'GET',
      '/api/production/lines/pl_nope',
    );
    expect(missing['status'], 404);

    final Map<String, dynamic> unsupported = await call(
      'PUT',
      '/api/production/lines/pl_1',
    );
    expect(unsupported['status'], 404);

    final Map<String, dynamic> unknown = await call(
      'GET',
      '/api/production/unknown',
    );
    expect(unknown['status'], 404);
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
