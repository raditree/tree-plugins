import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

import 'support/structure_fixture.dart';

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
    final ProductionStore store = ProductionStore(dataRoot: temp.path);
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
    OrchestratorService? orchestrator,
    ProductionDedupService Function(Map<String, Object?> scope)? dedupFor,
    ProductionNormalizationService? normalization,
    ProductionReadinessService? readiness,
    ProductionService? service,
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
      service: service,
      execution: execution,
      orchestrator: orchestrator,
      dedupFor: dedupFor,
      normalization: normalization,
      readiness: readiness,
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
      kDeclaredRoutes
          .map((Map<String, String> route) => route['method'])
          .toSet(),
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

  test('逻辑去重：GET 只读结果，POST 推进（禁用配置时 skipped）', () async {
    final Directory workspace = Directory(p.join(temp.path, 'workspace'))
      ..createSync(recursive: true);
    storeWith(workspaceDir: workspace.path);
    Future<Map<String, dynamic>> fakeStorage(
      String command,
      Map<String, dynamic> arguments,
    ) async {
      if (command == 'storage.get') {
        return <String, dynamic>{'ok': true, 'value': null};
      }
      if (command == 'storage.scan') {
        return <String, dynamic>{
          'ok': true,
          'values': <Object?>[],
          'has_more': false,
        };
      }
      return <String, dynamic>{'ok': true};
    }

    ProductionDedupService build() => ProductionDedupService(
      environment: const <String, String>{},
      storage: fakeStorage,
      embed: (DedupEmbedRequest request) async =>
          const DedupEmbedReply(error: '不应被调用', code: 'unexpected'),
      settings: () async => DedupConfig.fromValues(<String, Object?>{
        'dedup_enabled': <String, Object?>{'value': false},
      }),
    );

    final Map<String, dynamic> status = await call(
      'GET',
      '/api/production/lines/pl_1/dedup',
      dedupFor: (Map<String, Object?> _) => build(),
    );
    expect(status['status'], 200);
    expect(status['json']['run'], isNull);

    final Map<String, dynamic> run = await call(
      'POST',
      '/api/production/lines/pl_1/dedup',
      body: <String, Object?>{'mode': 'incremental'},
      dedupFor: (Map<String, Object?> _) => build(),
    );
    expect(run['status'], 200);
    expect(run['json']['skipped'], true);
    expect(run['json']['done'], true);
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
      Directory(p.join(temp.path, 'production_lines', 'production', 'pl_new'))
          .existsSync(),
      isFalse,
    );
  });

  test('迁移路由：旧团队目录搬进全局作用域并补执行身份', () async {
    final Directory legacy = Directory(
      p.join(temp.path, 'production_lines', 'team_a', 'pl_old'),
    )..createSync(recursive: true);
    File(p.join(legacy.path, 'line.yaml')).writeAsStringSync(
      encodeYaml(<String, Object?>{
        'id': 'pl_old',
        'name': '旧产线',
        'status': 'idle',
        'created_at': '2026-11-01T00:00:00',
        'updated_at': '2026-11-01T00:00:00',
      }),
    );

    final Map<String, dynamic> migrated = await call(
      'POST',
      migratePattern,
      body: <String, Object?>{'agent_id': 'agt_exec', 'team_id': 'team_exec'},
    );
    expect(migrated['status'], 200);
    expect(migrated['json']['migrated_count'], 1);

    final Map<String, dynamic> line = await call(
      'GET',
      '/api/production/lines/pl_old',
    );
    expect(line['json']['line']['executor']['agent_id'], 'agt_exec');
    expect(line['json']['line']['executor']['team_id'], 'team_exec');
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
    final ProductionStore store = storeWith();
    await markLineReady(store, 'pl_1', temp);
    final Map<String, dynamic> created = await call(
      'POST',
      '/api/production/lines/pl_1/tasks',
      body: <String, Object?>{
        'id': 'T2',
        'title': '新任务',
        'status': 'queued',
        'brief': '做一个新任务',
        'acceptance': <String>['用例全绿'],
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

  test('准备路由：recon / finalize 已开放（状态不符回可读错误，不是 404）', () async {
    storeWith();
    final Map<String, dynamic> recon = await call(
      'POST',
      '/api/production/lines/pl_1/tasks/T1/recon',
    );
    expect(recon['status'], isNot(404));
    expect(recon['json']['code'], 'prepare_state');

    final Map<String, dynamic> finalize = await call(
      'POST',
      '/api/production/lines/pl_1/tasks/T1/finalize',
    );
    expect(finalize['status'], isNot(404));
    expect(finalize['json']['code'], 'prepare_state');
  });

  test('派发：不依赖调用方身份；auto 按状态选 pack / run；未知任务 404', () async {
    final ProductionStore store = storeWith();
    await markLineReady(store, 'pl_1', temp);
    final _FakeExecution execution = _FakeExecution();

    // §16：派发身份取自 line.yaml.executor，REST 层不再要求 query.agent_id。
    final Map<String, dynamic> withoutAgent = await call(
      'POST',
      '/api/production/lines/pl_1/tasks/T1/dispatch',
      execution: execution,
      awaitDispatch: true,
    );
    expect(withoutAgent['status'], 200);
    expect(withoutAgent['json']['stage'], 'pack');
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

  test('手动派发过依赖/并行/写域/预算护栏，拒绝带 code/message/missing', () async {
    final ProductionStore store = storeWith();
    await markLineReady(store, 'pl_1', temp);
    final _FakeExecution execution = _FakeExecution();

    // TG-02 依赖未完成：不进入执行通道。
    store.createTask('pl_1', <String, Object?>{
      'id': 'T2',
      'title': '依赖 T1',
      'status': 'queued',
      'depends_on': <String>['T1'],
    });
    final Map<String, dynamic> dependency = await call(
      'POST',
      '/api/production/lines/pl_1/tasks/T2/dispatch',
      execution: execution,
    );
    expect(dependency['status'], 409);
    expect(dependency['json']['code'], 'task_dependency_open');
    expect(dependency['json']['message'], isNotEmpty);
    expect(dependency['json']['missing'], <String>['T1']);
    expect(execution.calledCommands, isEmpty);

    // TG-03 写域交叠：与在途任务同一目录。
    store.putTask('pl_1', 'T1', <String, Object?>{
      'write_scope': <String>['lib/a'],
    });
    store.transition('pl_1', 'T1', to: 'packing', reason: '夹具');
    store.createTask('pl_1', <String, Object?>{
      'id': 'T3',
      'title': '写同一目录',
      'status': 'queued',
      'write_scope': <String>['lib/a/b.dart'],
    });
    final Map<String, dynamic> scope = await call(
      'POST',
      '/api/production/lines/pl_1/tasks/T3/dispatch',
      execution: execution,
    );
    expect(scope['status'], 409);
    expect(scope['json']['code'], 'task_scope_conflict');
    expect(scope['json']['missing'], <String>['T1']);

    // TG-04 并行槽位：写入域不相交也要等槽位。
    store.createTask('pl_1', <String, Object?>{
      'id': 'T4',
      'title': '并行槽位',
      'status': 'queued',
      'write_scope': <String>['lib/b'],
    });
    final Map<String, dynamic> parallel = await call(
      'POST',
      '/api/production/lines/pl_1/tasks/T4/dispatch',
      execution: execution,
    );
    expect(parallel['status'], 409);
    expect(parallel['json']['code'], 'task_parallel_limit');
    expect(parallel['json']['missing'], <String>['T1']);

    // TG-04 预算到点：不再发起派发。
    for (final String to in <String>['packed', 'running', 'gating', 'done']) {
      store.transition('pl_1', 'T1', to: to, reason: '夹具');
    }
    store.updateLine('pl_1', <String, Object?>{
      'limits': <String, Object?>{'max_tokens_per_task': 10},
    });
    store.createTask('pl_1', <String, Object?>{
      'id': 'T5',
      'title': '预算到点',
      'status': 'queued',
      'write_scope': <String>['lib/c'],
    });
    store.putTask('pl_1', 'T5', <String, Object?>{
      'usage': <String, Object?>{'prompt_tokens': 6, 'completion_tokens': 4},
    });
    final Map<String, dynamic> budget = await call(
      'POST',
      '/api/production/lines/pl_1/tasks/T5/dispatch',
      execution: execution,
    );
    expect(budget['status'], 409);
    expect(budget['json']['code'], 'task_budget_exceeded');
    expect((budget['json']['missing'] as List<dynamic>), isNotEmpty);
    expect(execution.calledCommands, isEmpty);
  });

  test('主控路由：orchestrate / status / pause / resume', () async {
    final ProductionStore store = storeWith();
    await markLineReady(store, 'pl_1', temp);
    store.updateLine('pl_1', <String, Object?>{
      'roles': <String, Object?>{
        'orchestrator': <String, Object?>{'model_id': 'chat/main'},
      },
    });
    final _ApiLlm llm = _ApiLlm()
      ..replies.add(<String, Object?>{
        'action': 'continue',
        'reason': 'T1 可打包',
        'task_ids': <String>['T1'],
      });
    final _ApiDispatcher dispatcher = _ApiDispatcher();
    final OrchestratorService orchestrator = OrchestratorService(
      environment: const <String, String>{},
      llm: llm.call,
      dispatcher: dispatcher.dispatch,
    );

    final Map<String, dynamic> tick = await call(
      'POST',
      '/api/production/lines/pl_1/orchestrate',
      orchestrator: orchestrator,
    );
    expect(tick['status'], 200);
    expect(tick['json']['status'], 'applied');
    expect(tick['json']['action'], 'continue');
    expect(dispatcher.calls, <String>['T1/pack']);

    final Map<String, dynamic> status = await call(
      'GET',
      '/api/production/lines/pl_1/orchestrator',
      orchestrator: orchestrator,
    );
    expect(status['status'], 200);
    expect(status['json']['config']['enabled'], isTrue);
    expect(status['json']['state']['last_action'], 'continue');

    final Map<String, dynamic> paused = await call(
      'POST',
      '/api/production/lines/pl_1/pause',
    );
    expect(paused['status'], 200);
    expect(paused['json']['line']['status'], 'paused');

    llm.replies.add(<String, Object?>{
      'action': 'continue',
      'reason': '恢复后继续',
      'task_ids': <String>['T1'],
    });
    final Map<String, dynamic> resumed = await call(
      'POST',
      '/api/production/lines/pl_1/resume',
      orchestrator: orchestrator,
    );
    expect(resumed['status'], 200);
    expect(resumed['json']['line']['status'], 'working');
    expect(resumed['json']['tick']['status'], 'applied');

    // 未接线主控：503，不是静默成功。
    final Map<String, dynamic> unavailable = await call(
      'POST',
      '/api/production/lines/pl_1/orchestrate',
    );
    expect(unavailable['status'], 503);
  });

  test('运行期问答：questions 增 execute_questions；answer 回 queued', () async {
    final ProductionStore store = storeWith();
    final ProductionExecutionService execution = ProductionExecutionService(
      environment: const <String, String>{},
    );
    await execution.handle(
      'production.task.question',
      <String, Object?>{'line_id': 'pl_1', 'task_id': 'T1', 'text': '旧行为要保留吗？'},
      <String, Object?>{'data_dir': temp.path},
      <String, Object?>{},
    );
    expect(store.getTask('pl_1', 'T1').status, TaskStatus.blocked);

    final Map<String, dynamic> questions = await call(
      'GET',
      '/api/production/lines/pl_1/tasks/T1/questions',
      execution: execution,
    );
    expect(questions['status'], 200);
    expect(questions['json']['execute_open'], 1);
    expect(
      (questions['json']['execute_questions'] as List<dynamic>).single['qid'],
      'X1',
    );

    final Map<String, dynamic> answered = await call(
      'POST',
      '/api/production/lines/pl_1/tasks/T1/answer',
      execution: execution,
      body: <String, Object?>{'value': '保留'},
    );
    expect(answered['status'], 200);
    expect(answered['json']['ready'], isTrue);
    expect(store.getTask('pl_1', 'T1').status, TaskStatus.queued);
  });

  test('全局作用域：缺 team 仍可读写；缺 data_dir / 未知路由照旧 fail-closed', () async {
    storeWith();

    // §16：产线数据全局存放，team_id 只是调用方身份（可空）。
    final Map<String, dynamic> noTeam = await call(
      'GET',
      linesPattern,
      team: '',
    );
    expect(noTeam['status'], 200);
    expect((noTeam['json']['lines'] as List<dynamic>).length, 1);

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

  test('就绪门路由：GET readiness / structure 带 readiness / 未接线 503', () async {
    storeWith();
    final _FakeReadiness readiness = _FakeReadiness(
      reply: <String, Object?>{
        'line_id': 'pl_1',
        'ready': false,
        'missing': <String>['LG-02'],
      },
    );

    final Map<String, dynamic> snapshot = await call(
      'GET',
      '/api/production/lines/pl_1/readiness',
      readiness: readiness,
    );
    expect(snapshot['status'], 200);
    expect(snapshot['json']['ready'], isFalse);
    expect(snapshot['json']['missing'], <String>['LG-02']);

    final Map<String, dynamic> unavailable = await call(
      'GET',
      '/api/production/lines/pl_1/readiness',
    );
    expect(unavailable['status'], 503);
    expect(unavailable['json']['code'], 'readiness_unavailable');

    final Map<String, dynamic> notFound = await call(
      'GET',
      '/api/production/lines/pl_nope/readiness',
      readiness: ProductionReadinessService(
        environment: const <String, String>{},
      ),
    );
    expect(notFound['status'], 404);

    final Map<String, dynamic> structure = await call(
      'GET',
      '/api/production/lines/pl_1/structure',
      readiness: readiness,
    );
    expect(structure['status'], 200);
    expect(structure['json']['structure'], isA<Map<String, dynamic>>());
    expect(structure['json']['readiness']['ready'], isFalse);

    // 就绪探测失败：structure 仍 200，readiness 退化为空表。
    final Map<String, dynamic> degraded = await call(
      'GET',
      '/api/production/lines/pl_1/structure',
      readiness: _FakeReadiness(
        error: ProductionFailure('未就绪', code: 'line_not_ready'),
      ),
    );
    expect(degraded['status'], 200);
    expect(degraded['json']['readiness'], isEmpty);

    final Map<String, dynamic> structureMissing = await call(
      'GET',
      '/api/production/lines/pl_nope/structure',
      readiness: readiness,
    );
    expect(structureMissing['status'], 404);
  });

  test('结构路由：reevaluate 200 / waive 找不到条目 404 / 未知产线 404', () async {
    final Directory workspace = Directory(p.join(temp.path, 'ws'))
      ..createSync(recursive: true);
    storeWith(workspaceDir: workspace.path);

    final Map<String, dynamic> reevaluated = await call(
      'POST',
      '/api/production/lines/pl_1/structure/reevaluate',
    );
    expect(reevaluated['status'], 200);
    expect(reevaluated['json']['ready'], isTrue);

    final Map<String, dynamic> waived = await call(
      'POST',
      '/api/production/lines/pl_1/structure/waive',
      body: <String, Object?>{
        'finding_id': 'F404',
        'owner': 'owner_a',
        'reason': '暂不修',
        'expires_at': '2027-01-01',
      },
    );
    expect(waived['status'], 404);
    expect(waived['json']['code'], 'not_found');

    final Map<String, dynamic> reevaluateMissing = await call(
      'POST',
      '/api/production/lines/pl_nope/structure/reevaluate',
    );
    expect(reevaluateMissing['status'], 404);

    final Map<String, dynamic> waiveMissing = await call(
      'POST',
      '/api/production/lines/pl_nope/structure/waive',
      body: <String, Object?>{
        'finding_id': 'F1',
        'owner': 'a',
        'reason': 'r',
        'expires_at': '2027-01-01',
      },
    );
    expect(waiveMissing['status'], 409);
    expect(waiveMissing['json']['code'], 'structure_report_missing');
  });

  test('归一化路由：status / plan / apply / rollback 透传，未接线 503，计划缺失 409', () async {
    storeWith();
    final _FakeNormalization normalization = _FakeNormalization();

    final Map<String, dynamic> status = await call(
      'GET',
      '/api/production/lines/pl_1/normalize',
      normalization: normalization,
    );
    expect(status['status'], 200);
    expect(normalization.commands.last, 'production.normalize.status');

    final Map<String, dynamic> plan = await call(
      'POST',
      '/api/production/lines/pl_1/normalize/plan',
      normalization: normalization,
      body: <String, Object?>{'sections': <Object?>[], 'indexes': <Object?>[]},
    );
    expect(plan['status'], 200);
    expect(normalization.commands.last, 'production.normalize.plan');
    expect(normalization.arguments.last['commit'], isFalse);
    expect(normalization.arguments.last['line_id'], 'pl_1');

    final Map<String, dynamic> applied = await call(
      'POST',
      '/api/production/lines/pl_1/normalize/apply',
      normalization: normalization,
      body: <String, Object?>{'confirm_rewrite': true},
    );
    expect(applied['status'], 200);
    expect(normalization.commands.last, 'production.normalize.apply');
    expect(normalization.arguments.last['confirm_rewrite'], isTrue);

    final Map<String, dynamic> rolledBack = await call(
      'POST',
      '/api/production/lines/pl_1/normalize/rollback',
      normalization: normalization,
    );
    expect(rolledBack['status'], 200);
    expect(normalization.commands.last, 'production.normalize.rollback');

    final Map<String, dynamic> unavailable = await call(
      'GET',
      '/api/production/lines/pl_1/normalize',
    );
    expect(unavailable['status'], 503);
    expect(unavailable['json']['code'], 'normalization_unavailable');

    final Map<String, dynamic> conflict = await call(
      'POST',
      '/api/production/lines/pl_1/normalize/apply',
      normalization: _FakeNormalization(
        error: ProductionFailure('没有计划', code: 'normalization_plan_missing'),
      ),
    );
    expect(conflict['status'], 409);
    expect(conflict['json']['code'], 'normalization_plan_missing');

    final Map<String, dynamic> notFound = await call(
      'GET',
      '/api/production/lines/pl_nope/normalize',
      normalization: ProductionNormalizationService(
        environment: const <String, String>{},
      ),
    );
    expect(notFound['status'], 404);
  });
}

/// 假就绪门：直接回固定快照或抛固定失败（api 层只验路由与形状）。
class _FakeReadiness extends ProductionReadinessService {
  _FakeReadiness({this.reply = const <String, Object?>{}, this.error});

  final Map<String, Object?> reply;
  final ProductionFailure? error;

  @override
  Future<Map<String, Object?>> handle(
    String command,
    Map<String, Object?> arguments,
    Map<String, Object?> meta,
    Map<String, Object?> scope,
  ) async {
    if (error != null) throw error!;
    return reply;
  }
}

/// 假归一化门面：记录命令与参数，按需抛固定失败。
class _FakeNormalization extends ProductionNormalizationService {
  _FakeNormalization({this.error});

  final ProductionFailure? error;
  final List<String> commands = <String>[];
  final List<Map<String, Object?>> arguments = <Map<String, Object?>>[];

  @override
  Future<Map<String, Object?>> handle(
    String command,
    Map<String, Object?> arguments,
    Map<String, Object?> meta,
    Map<String, Object?> scope,
  ) async {
    commands.add(command);
    this.arguments.add(arguments);
    if (error != null) throw error!;
    return <String, Object?>{'command': command};
  }
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

/// 假主控模型：按顺序回包（api 层只验路由，不验决策质量）。
class _ApiLlm {
  final List<Map<String, Object?>> replies = <Map<String, Object?>>[];

  Future<Map<String, Object?>> call(
    String point,
    String system,
    String prompt,
    Map<String, Object?> scope,
    String modelId,
  ) async => replies.removeAt(0);
}

/// 假派发器：记录 tick 决定的派发动作。
class _ApiDispatcher {
  final List<String> calls = <String>[];

  Future<void> dispatch(
    String lineId,
    String taskId,
    String stage,
    Map<String, Object?> meta,
    Map<String, Object?> scope,
  ) async {
    calls.add('$taskId/$stage');
  }
}
