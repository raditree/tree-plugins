import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

/// P3 准备阶段的命令门面：侦查 → 追问 → 窗口 → 落档（含读取预算与 fail-closed）。
void main() {
  late Directory temp;
  late Directory workspace;
  late DateTime tick;
  late int limit;
  late int llmCalls;
  late int docCalls;
  late Map<String, Object?> reconJson;
  late Map<String, Object?> scopeJson;
  late PreparationService service;

  DateTime clock() => tick = tick.add(const Duration(minutes: 1));

  Map<String, Object?> question(int index) => <String, Object?>{
    'text': '问题 $index',
    'default': '默认 $index',
    'recommended': '推荐 $index',
    'consequence': '后果 $index',
  };

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_pl_prepare_');
    workspace = Directory(p.join(temp.path, 'ws'))..createSync(recursive: true);
    tick = DateTime(2026, 11, 9, 10);
    limit = 0;
    llmCalls = 0;
    docCalls = 0;
    reconJson = <String, Object?>{
      'regular': <Object?>[
        <String, Object?>{'text': '改列表', 'landing': 'lib/ui/agent_list.dart'},
      ],
      'special': <Object?>[
        <String, Object?>{'text': '要本地模型', 'why': '云端太慢'},
      ],
      'questions': <Object?>[for (int i = 1; i <= 5; i++) question(i)],
      'fallbacks': <Object?>['退回云端'],
      'notes': <Object?>['数据库不可动'],
      'flags': <String>['lib/ui/agent_list.dart'],
    };
    scopeJson = <String, Object?>{
      'in': <String>['列表过滤'],
      'out': <String>['不动数据库'],
      'not_doing': <String>['不做搜索'],
      'tasks': <Object?>[
        <String, Object?>{
          'id': 'T1',
          'title': '改列表',
          'acceptance': <String>['用例全绿'],
          'write_scope': <String>['lib/ui/agent_list.dart'],
        },
        <String, Object?>{
          'id': 'T2',
          'title': '补测试',
          'depends_on': <String>['T1'],
          'acceptance': <String>['新用例覆盖过滤'],
        },
      ],
    };
    service = PreparationService(
      environment: const <String, String>{},
      clock: clock,
      llm: (
        String point,
        String system,
        String prompt,
        Map<String, Object?> scope,
      ) async {
        llmCalls += 1;
        return point == 'production.recon' ? reconJson : scopeJson;
      },
      docQuery: (String repo, String question, Map<String, Object?> scope) async {
        docCalls += 1;
        expect(repo, workspace.path);
        expect(scope['team_id'], 'team_a');
        return <String, Object?>{
          'mode': 'lexical',
          'results': <Object?>[
            <String, Object?>{
              'doc': 'docs/project-status.md',
              'heading': 'H 车道',
              'snippet': '生产线 P1/P2 已完成',
            },
          ],
        };
      },
      limitReader: (Map<String, Object?> scope) async => limit == 0 ? null : limit,
    );
    final ProductionStore store = ProductionStore(
      dataRoot: temp.path,
      teamId: 'team_a',
      clock: clock,
    );
    store.createLine(<String, Object?>{
      'id': 'pl_demo',
      'name': '标准开发流',
      'workspace_dir': workspace.path,
    });
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
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

  Future<Map<String, Object?>> intake() => call(
    'production.prepare.intake',
    <String, Object?>{
      'line_id': 'pl_demo',
      'task': <String, Object?>{
        'id': 'T0',
        'title': '列表过滤',
        'intake': <String, Object?>{
          'goal': '会话列表能按项目过滤',
          'current': '只有 flat 列表',
          'acceptance': '选中项目后只剩该项目会话；有测试',
          'forbidden': '不动数据库结构',
          'deadline': '今天窗口内',
        },
      },
    },
  );

  Future<Map<String, Object?>> recon() => call(
    'production.prepare.recon',
    <String, Object?>{'line_id': 'pl_demo', 'task_id': 'T0'},
  );

  Future<Map<String, Object?>> answerAll(List<String> qids) => call(
    'production.prepare.answer',
    <String, Object?>{
      'line_id': 'pl_demo',
      'task_id': 'T0',
      'answers': <Map<String, Object?>>[
        for (final String qid in qids)
          <String, Object?>{'qid': qid, 'value': '按 $qid 的答复'},
      ],
    },
  );

  Future<Map<String, Object?>> finalize({Map<String, Object?>? extra}) => call(
    'production.prepare.finalize',
    <String, Object?>{'line_id': 'pl_demo', 'task_id': 'T0', ...?extra},
  );

  String asset(String relative) =>
      p.join(workspace.path, 'docs', 'production_lines', 'pl_demo', relative);

  test('侦查：上限读 line.yaml、四节落档、提问进入台账', () async {
    await intake();
    final Map<String, Object?> reply = await recon();
    expect((reply['task'] as Map)['status'], 'aligning');
    expect(reply['open'], 3, reason: 'line.yaml 默认上限 3');
    expect(reply['dropped'], 2);
    expect(docCalls, 1);
    expect(llmCalls, 1);

    final File reconFile = File(asset('recon.md'));
    expect(reconFile.existsSync(), isTrue);
    final String md = reconFile.readAsStringSync();
    expect(md.indexOf('## 1. 常规要求'), lessThan(md.indexOf('## 2. 特殊要求')));
    expect(md.indexOf('## 2. 特殊要求'), lessThan(md.indexOf('## 3. 疑惑与待拍板')));
    expect(md.indexOf('## 3. 疑惑与待拍板'), lessThan(md.indexOf('## 4. 回退选项与注意事项')));
    expect(md, contains('**Q1** 问题 1'));
    expect(md, contains('**Q3** 问题 3'));
    expect(md, isNot(contains('**Q4**')), reason: '超限问题不进文档');
    expect(File(asset('decisions.md')).existsSync(), isTrue);

    final Map<String, Object?> questions = await call(
      'production.prepare.questions',
      <String, Object?>{'line_id': 'pl_demo', 'task_id': 'T0'},
    );
    expect((questions['open'] as List<dynamic>), hasLength(3));
    expect(
      (questions['questions'] as List<dynamic>)
          .map((dynamic q) => (q as Map)['qid'])
          .toList(),
      <String>['Q1', 'Q2', 'Q3'],
    );
  });

  test('未答不实施：关窗转 awaiting_user、finalize 被拒、次日续答', () async {
    await intake();
    await recon();
    final String reconBefore = File(asset('recon.md')).readAsStringSync();

    final Map<String, Object?> closed = await call(
      'production.prepare.window.close',
      <String, Object?>{'line_id': 'pl_demo'},
    );
    expect(closed['awaiting'], <String>['T0']);
    final Map<String, Object?> status = await call(
      'production.prepare.status',
      <String, Object?>{'line_id': 'pl_demo'},
    );
    expect((status['tasks'] as List<dynamic>).first, containsPair('status', 'awaiting_user'));

    await expectLater(
      finalize(extra: <String, Object?>{'plan': <Object?>[]}),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure e) => e.code,
          'code',
          'questions_open',
        ),
      ),
    );
    // 草稿与未答问题原样保留。
    expect(File(asset('recon.md')).readAsStringSync(), reconBefore);

    final Map<String, Object?> opened = await call(
      'production.prepare.window.open',
      <String, Object?>{'line_id': 'pl_demo'},
    );
    expect(opened['resumed'], <String>['T0']);
    final Map<String, Object?> answered = await answerAll(<String>['Q1', 'Q2', 'Q3']);
    expect(answered['open'], 0);
    expect(answered['ready'], isTrue, reason: '答完即可落档（scoped 由 finalize 触发）');
    expect((answered['task'] as Map)['status'], 'aligning');

    // 原编号 / 原选项保留。
    final Map<String, Object?> questions = await call(
      'production.prepare.questions',
      <String, Object?>{'line_id': 'pl_demo', 'task_id': 'T0'},
    );
    final List<dynamic> all = questions['questions'] as List<dynamic>;
    expect(all.map((dynamic q) => (q as Map)['qid']).toList(), <String>['Q1', 'Q2', 'Q3']);
    expect(all.map((dynamic q) => (q as Map)['text']).toList(), <String>['问题 1', '问题 2', '问题 3']);
    expect(
      (all.first as Map)['answer'],
      '按 Q1 的答复',
    );
  });

  test('落档：scope/plan/acceptance + 建 queued 任务 + 分发摘要', () async {
    await intake();
    await recon();
    await call('production.prepare.answer', <String, Object?>{
      'line_id': 'pl_demo',
      'task_id': 'T0',
      'answers': <Map<String, Object?>>[
        <String, Object?>{'qid': 'Q1', 'value': 'a'},
        <String, Object?>{'qid': 'Q2', 'value': 'b'},
        <String, Object?>{'qid': 'Q3', 'value': 'c'},
      ],
    });
    final int llmBefore = llmCalls;
    final Map<String, Object?> reply = await finalize(
      extra: <String, Object?>{
        'in': <String>['列表过滤'],
        'out': <String>['不动数据库'],
        'not_doing': <String>['不做搜索'],
        'plan': <Object?>[
          <String, Object?>{
            'id': 'T1',
            'title': '改列表',
            'acceptance': <String>['用例全绿'],
            'write_scope': <String>['lib/ui/agent_list.dart'],
          },
          <String, Object?>{
            'id': 'T2',
            'title': '补测试',
            'depends_on': <String>['T1'],
            'acceptance': <String>['新用例覆盖过滤'],
          },
        ],
      },
    );
    expect(llmCalls, llmBefore, reason: '显式 plan 不再调模型');
    expect((reply['task'] as Map)['status'], 'scoped');
    expect(
      (reply['created_tasks'] as List<dynamic>)
          .map((dynamic t) => (t as Map)['id'])
          .toList(),
      <String>['T1', 'T2'],
    );
    expect(File(asset('scope.md')).existsSync(), isTrue);
    expect(File(asset('plan.md')).readAsStringSync(), contains('T1 → T2'));
    expect(File(asset('tasks/T1/acceptance.md')).readAsStringSync(), contains('- [ ] 用例全绿'));
    expect(File(asset('tasks/T2/acceptance.md')).existsSync(), isTrue);

    expect(
      reply['queue'],
      containsAll(<String>['T1', 'T2']),
      reason: '落档后两条任务都在队列里（依赖派发由 P1 队列负责）',
    );
    expect((reply['summary'] as List<dynamic>).first, '任务 2 个（常规 2 / 特殊 0）');
  });

  test('全部按推荐：必须显式调用；无推荐且无默认 ⇒ 报错', () async {
    await intake();
    await recon();
    final Map<String, Object?> reply = await call(
      'production.prepare.all_recommended',
      <String, Object?>{'line_id': 'pl_demo', 'task_id': 'T0'},
    );
    expect(reply['open'], 0);
    expect(reply['ready'], isTrue);
    expect((reply['task'] as Map)['status'], 'aligning');
    final String decisions = File(asset('decisions.md')).readAsStringSync();
    expect(decisions, contains('按推荐拍板'));
    expect(decisions, contains('推荐 1'));
  });

  test('读取预算：文件 ≤ 8、grep ≤ 2 轮', () async {
    await intake();
    File(p.join(workspace.path, 'a.md')).writeAsStringSync('hello grep\n');
    for (int i = 1; i <= 8; i++) {
      final Map<String, Object?> reply = await call(
        'production.prepare.read',
        <String, Object?>{
          'line_id': 'pl_demo',
          'task_id': 'T0',
          'path': 'a.md',
        },
      );
      expect((reply['budget'] as Map)['files'], i);
    }
    await expectLater(
      call('production.prepare.read', <String, Object?>{
        'line_id': 'pl_demo',
        'task_id': 'T0',
        'path': 'a.md',
      }),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure e) => e.code,
          'code',
          'budget_exceeded',
        ),
      ),
    );
    for (int i = 1; i <= 2; i++) {
      final Map<String, Object?> reply = await call(
        'production.prepare.read',
        <String, Object?>{
          'line_id': 'pl_demo',
          'task_id': 'T0',
          'pattern': 'grep',
        },
      );
      expect((reply['budget'] as Map)['grep_rounds'], i);
      expect((reply['matches'] as List<dynamic>), isNotEmpty);
    }
    await expectLater(
      call('production.prepare.read', <String, Object?>{
        'line_id': 'pl_demo',
        'task_id': 'T0',
        'pattern': 'grep',
      }),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure e) => e.code,
          'code',
          'budget_exceeded',
        ),
      ),
    );
  });

  test('追问上限读设置（1–10 夹取）且下一轮才影响新问题', () async {
    await intake();
    limit = 5;
    final Map<String, Object?> five = await recon();
    expect(five['open'], 5);
    expect(five['limit'], 5);
    expect(five['dropped'], 0);

    limit = 99;
    final Map<String, Object?> clamped = await recon();
    expect(clamped['limit'], 10);
  });

  test('fail-closed：缺 docnorm / 缺 llm 都拒绝凭空侦查', () async {
    final PreparationService withoutDocs = PreparationService(
      environment: const <String, String>{},
      clock: clock,
      llm: (String point, String system, String prompt, Map<String, Object?> scope) async =>
          <String, Object?>{},
    );
    await intake();
    await expectLater(
      withoutDocs.handle(
        'production.prepare.recon',
        <String, Object?>{'line_id': 'pl_demo', 'task_id': 'T0'},
        <String, Object?>{'data_dir': temp.path},
        <String, Object?>{'team_id': 'team_a'},
      ),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure e) => e.code,
          'code',
          'docnorm_unavailable',
        ),
      ),
    );

    final PreparationService withoutLlm = PreparationService(
      environment: const <String, String>{},
      clock: clock,
      docQuery: (String repo, String question, Map<String, Object?> scope) async =>
          <String, Object?>{'results': <Object?>[]},
    );
    await expectLater(
      withoutLlm.handle(
        'production.prepare.recon',
        <String, Object?>{'line_id': 'pl_demo', 'task_id': 'T0'},
        <String, Object?>{'data_dir': temp.path},
        <String, Object?>{'team_id': 'team_a'},
      ),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure e) => e.code,
          'code',
          'llm_unavailable',
        ),
      ),
    );
  });

  test('没有追问时可直接落档（模型拆任务）', () async {
    reconJson = <String, Object?>{
      'regular': <Object?>['改列表'],
      'special': <Object?>[],
      'questions': <Object?>[],
      'fallbacks': <Object?>[],
      'notes': <Object?>[],
      'flags': <String>[],
    };
    await intake();
    final Map<String, Object?> reconReply = await recon();
    expect(reconReply['open'], 0);
    final Map<String, Object?> reply = await finalize();
    expect((reply['created_tasks'] as List<dynamic>), hasLength(2));
    expect((reply['task'] as Map)['status'], 'scoped');
  });
}
