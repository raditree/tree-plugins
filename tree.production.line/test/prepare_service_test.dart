import 'dart:convert';
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
  late List<String> llmModelIds;
  late List<String> llmPrompts;
  late Map<String, Object?> digestJson;
  late Map<String, Object?> reconJson;
  late Map<String, Object?> scopeJson;
  late List<String> cycles;
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
    llmModelIds = <String>[];
    llmPrompts = <String>[];
    digestJson = <String, Object?>{
      'requirement_summary': '让会话列表按项目过滤',
      'keywords': <String, Object?>{
        'terms': <String>['会话列表', '项目过滤'],
        'synonyms': <String>['session list'],
        'entities': <String>['AgentList'],
        'files': <String>['lib/ui/agent_list.dart'],
        'apis': <String>['SessionFilter'],
      },
      'constraints': <String>['不动数据库'],
      'attachment_summaries': <Object?>[],
      'ambiguities': <String>['过滤状态是否持久化未说明'],
    };
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
          'task_type': 'code',
          'acceptance': <String>['用例全绿'],
          'write_scope': <String>['lib/ui/agent_list.dart'],
          'gate': <String, Object?>{
            'commands': <String>['dart test'],
          },
        },
        <String, Object?>{
          'id': 'T2',
          'title': '补测试',
          'task_type': 'test',
          'depends_on': <String>['T1'],
          'acceptance': <String>['新用例覆盖过滤'],
          'gate': <String, Object?>{
            'commands': <String>['dart test'],
          },
        },
      ],
    };
    cycles = <String>[];
    service = PreparationService(
      environment: const <String, String>{},
      clock: clock,
      onCycle:
          (
            String lineId,
            Map<String, Object?> meta,
            Map<String, Object?> scope,
          ) async {
            cycles.add(lineId);
          },
      llm:
          (
            String point,
            String system,
            String prompt,
            Map<String, Object?> scope,
            String modelId,
          ) async {
            llmCalls += 1;
            llmModelIds.add(modelId);
            llmPrompts.add(prompt);
            if (point == 'production.digest') return digestJson;
            return point == 'production.recon' ? reconJson : scopeJson;
          },
      docQuery:
          (String repo, String question, Map<String, Object?> scope) async {
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
      limitReader: (Map<String, Object?> scope) async =>
          limit == 0 ? null : limit,
    );
    final ProductionStore store = ProductionStore(
      dataRoot: temp.path,
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

  Future<Map<String, Object?>> intake() =>
      call('production.prepare.intake', <String, Object?>{
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
      });

  Future<Map<String, Object?>> recon() => call(
    'production.prepare.recon',
    <String, Object?>{'line_id': 'pl_demo', 'task_id': 'T0'},
  );

  Future<Map<String, Object?>> answerAll(List<String> qids) =>
      call('production.prepare.answer', <String, Object?>{
        'line_id': 'pl_demo',
        'task_id': 'T0',
        'answers': <Map<String, Object?>>[
          for (final String qid in qids)
            <String, Object?>{'qid': qid, 'value': '按 $qid 的答复'},
        ],
      });

  Future<Map<String, Object?>> finalize({Map<String, Object?>? extra}) => call(
    'production.prepare.finalize',
    <String, Object?>{'line_id': 'pl_demo', 'task_id': 'T0', ...?extra},
  );

  String asset(String relative) =>
      p.join(workspace.path, 'docs', 'production_lines', 'pl_demo', relative);

  /// PC-3F 的完整 7 块计划（可改坏 traceability 等块做多轮测试）。
  Map<String, Object?> structuredPlan() {
    const String gateText = '- [ ] dart analyze 退出码 0';
    return <String, Object?>{
      'requirements': <Object?>[
        <String, Object?>{
          'id': 'REQ-01',
          'text': '会话列表能按项目过滤',
          'source': 'intake.goal',
        },
      ],
      'design': <String, Object?>{
        'current': '只有 flat 列表',
        'target': '按项目过滤',
        'architecture': 'adapter + 过滤层',
        'data_flow': 'UI → filter → list',
        'migration': '无需迁移，仅新增过滤路径',
        'compatibility': '旧列表行为不变',
        'rollback': '回滚本次提交',
        'rejected_alternatives': <Object?>[],
        'baseline': 'baseline-v1',
        'baseline_tasks': <String>['T1'],
        'migration_strategy': 'adapter',
        'rollback_tasks': <String>['T1'],
        'behavior_split': '纯新增过滤分支：没有需要行为保持的迁移任务',
      },
      'invariants': <Object?>[
        <String, Object?>{
          'id': 'INV-01',
          'statement': '公共 API 不变',
          'owner': 'owner',
          'check': 'dart analyze',
          'kind': 'api',
        },
      ],
      'tasks': <Object?>[
        <String, Object?>{
          'id': 'T1',
          'title': '改列表',
          'task_type': 'code',
          'acceptance': <String>['用例全绿'],
          'write_scope': <String>['lib/ui/agent_list.dart'],
          'estimated_files': 1,
          'requirements': <String>['REQ-01'],
          'behavior': 'change',
          'preserves': <String>[],
          'changes': <String>['新增按项目过滤'],
          'gate': <String, Object?>{
            'commands': <String>['dart test'],
          },
        },
      ],
      'gates': <String, Object?>{
        'T1': <Object?>[
          <String, Object?>{
            'text': gateText,
            'evidence': 'plans/plan-v1/gates/T1/analyze.log',
          },
        ],
      },
      'traceability': <Object?>[
        <String, Object?>{
          'req': 'REQ-01',
          'tasks': <String>['T1'],
          'gates': <String>[gateText],
          'evidence': <String>['plans/plan-v1/gates/T1/analyze.log'],
        },
      ],
      'risks': <Object?>[
        <String, Object?>{
          'id': 'RISK-01',
          'level': 'low',
          'statement': '过滤后列表为空',
          'mitigation': '空态提示',
        },
      ],
      'change_control': <String, Object?>{
        'plan_version': 'plan-v1',
        'decision_template': 'DEC-xx：原因 / 影响 / 回滚',
        'rollback_points': <String>['S0 基线'],
      },
      'decisions': <Object?>[],
      'findings': <Object?>[],
      'rounds': 1,
    };
  }

  test('主控角色：准备阶段消费 roles.orchestrator 的模型与工具（D6）', () async {
    final ProductionStore store = ProductionStore(
      dataRoot: temp.path,
      clock: clock,
    );
    store.createLine(<String, Object?>{
      'id': 'pl_orch',
      'name': '带主控的产线',
      'workspace_dir': workspace.path,
      'roles': <String, Object?>{
        'orchestrator': <String, Object?>{
          'model_id': 'prov/m1',
          'tools': <String>['read', 'grep'],
        },
      },
    });
    await call('production.prepare.intake', <String, Object?>{
      'line_id': 'pl_orch',
      'task': <String, Object?>{
        'id': 'T0',
        'title': '列表过滤',
        'intake': <String, Object?>{
          'goal': '按项目过滤会话',
          'acceptance': '选中项目后只剩该项目会话；有测试',
        },
      },
    });
    await call('production.prepare.recon', <String, Object?>{
      'line_id': 'pl_orch',
      'task_id': 'T0',
    });
    expect(llmModelIds, contains('prov/m1'));
    expect(
      llmPrompts.any((String text) => text.contains('主控可用工具：read, grep')),
      isTrue,
    );
  });

  test('侦查：上限读 line.yaml、四节落档、提问进入台账', () async {
    await intake();
    final Map<String, Object?> reply = await recon();
    expect((reply['task'] as Map)['status'], 'aligning');
    expect(reply['open'], 3, reason: 'line.yaml 默认上限 3');
    expect(reply['dropped'], 2);
    expect(docCalls, 2, reason: '原文 + 关键词两次查询');
    expect(llmCalls, 2, reason: 'LLM #1 摘要 + LLM #2 理解');

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
    expect(
      (status['tasks'] as List<dynamic>).first,
      containsPair('status', 'awaiting_user'),
    );

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
    final Map<String, Object?> answered = await answerAll(<String>[
      'Q1',
      'Q2',
      'Q3',
    ]);
    expect(answered['open'], 0);
    expect(answered['ready'], isTrue, reason: '答完即可落档（scoped 由 finalize 触发）');
    expect((answered['task'] as Map)['status'], 'aligning');

    // 原编号 / 原选项保留。
    final Map<String, Object?> questions = await call(
      'production.prepare.questions',
      <String, Object?>{'line_id': 'pl_demo', 'task_id': 'T0'},
    );
    final List<dynamic> all = questions['questions'] as List<dynamic>;
    expect(all.map((dynamic q) => (q as Map)['qid']).toList(), <String>[
      'Q1',
      'Q2',
      'Q3',
    ]);
    expect(all.map((dynamic q) => (q as Map)['text']).toList(), <String>[
      '问题 1',
      '问题 2',
      '问题 3',
    ]);
    expect((all.first as Map)['answer'], '按 Q1 的答复');
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
    expect(cycles, isEmpty, reason: '落档前不触发执行 tick');
    final Map<String, Object?> reply = await finalize(
      extra: <String, Object?>{
        'in': <String>['列表过滤'],
        'out': <String>['不动数据库'],
        'not_doing': <String>['不做搜索'],
        'plan': <Object?>[
          <String, Object?>{
            'id': 'T1',
            'title': '改列表',
            'task_type': 'code',
            'acceptance': <String>['用例全绿'],
            'write_scope': <String>['lib/ui/agent_list.dart'],
            'gate': <String, Object?>{
              'commands': <String>['dart test'],
            },
          },
          <String, Object?>{
            'id': 'T2',
            'title': '补测试',
            'task_type': 'test',
            'depends_on': <String>['T1'],
            'acceptance': <String>['新用例覆盖过滤'],
            'gate': <String, Object?>{
              'commands': <String>['dart test'],
            },
          },
        ],
      },
    );
    expect(llmCalls, llmBefore, reason: '显式 plan 不再调模型');
    expect(cycles, <String>['pl_demo'], reason: '落档建出 queued 任务后触发一次 tick');
    expect((reply['task'] as Map)['status'], 'scoped');
    expect(
      (reply['created_tasks'] as List<dynamic>)
          .map((dynamic t) => (t as Map)['id'])
          .toList(),
      <String>['T1', 'T2'],
    );
    expect(File(asset('scope.md')).existsSync(), isTrue);
    expect(File(asset('plan.md')).readAsStringSync(), contains('T1 → T2'));
    expect(
      File(asset('tasks/T1/acceptance.md')).readAsStringSync(),
      contains('- [ ] 用例全绿'),
    );
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
      llm: (
        String point,
        String system,
        String prompt,
        Map<String, Object?> scope,
        String modelId,
      ) async => <String, Object?>{},
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
      docQuery: (
        String repo,
        String question,
        Map<String, Object?> scope,
      ) async => <String, Object?>{'results': <Object?>[]},
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

  test('双查询：A/B 并行、RRF 证据、LLM #2 带摘要/证据、阶段耗时落盘', () async {
    final List<String> queries = <String>[];
    final List<String> prompts = <String>[];
    int reconCalls = 0;
    service = PreparationService(
      environment: const <String, String>{},
      clock: clock,
      queryTimeout: const Duration(milliseconds: 500),
      retrievalDeadline: const Duration(seconds: 2),
      llm:
          (
            String point,
            String system,
            String prompt,
            Map<String, Object?> scope,
            String modelId,
          ) async {
            prompts.add(prompt);
            if (point == 'production.digest') return digestJson;
            reconCalls += 1;
            return <String, Object?>{
              'regular': <Object?>[
                <String, Object?>{
                  'text': '改列表',
                  'landing': 'lib/ui/agent_list.dart',
                  'evidence_ids': <String>['E1'],
                },
                <String, Object?>{'text': '新增缓存'},
              ],
              'special': <Object?>[],
              'questions': <Object?>[
                <String, Object?>{
                  'text': '要不要分页',
                  'default': '不',
                  'recommended': '是',
                  'consequence': '不分页会更慢',
                  'evidence_ids': <String>['E2'],
                },
              ],
              'fallbacks': <Object?>[],
              'notes': <Object?>[],
              'flags': <String>[],
            };
          },
      docQuery:
          (String repo, String question, Map<String, Object?> scope) async {
            queries.add(question);
            if (question.contains('验收：')) {
              return <String, Object?>{
                'results': <Object?>[
                  <String, Object?>{
                    'doc': 'docs/a.md',
                    'heading': 'A',
                    'snippet': '原文命中',
                  },
                ],
              };
            }
            return <String, Object?>{
              'results': <Object?>[
                <String, Object?>{
                  'doc': 'docs/a.md',
                  'heading': 'A',
                  'snippet': '原文命中',
                },
                <String, Object?>{
                  'doc': 'lib/b.dart',
                  'heading': 'B',
                  'snippet': '关键词命中',
                },
              ],
            };
          },
    );
    await intake();
    final Map<String, Object?> reply = await recon();
    expect(queries, hasLength(2), reason: '双查询，不补第三轮');
    expect(queries.first, contains('目标：会话列表能按项目过滤'));
    expect(queries.last, contains('AgentList'));
    expect(reconCalls, 1, reason: 'LLM #2 只调一次');
    expect(reply['degraded'], '');
    expect(reply['partial'], isFalse);
    expect(reply['recall_gap'], isFalse);

    final List<dynamic> evidence = reply['evidence'] as List<dynamic>;
    expect(evidence, hasLength(2));
    expect((evidence.first as Map)['id'], 'E1');
    expect((evidence.first as Map)['queries'], containsAll(<String>['A', 'B']));

    // LLM #2 的提示词必须包含摘要与带 evidence_id 的证据。
    expect(prompts.last, contains('需求摘要（LLM #1）'));
    expect(prompts.last, contains('让会话列表按项目过滤'));
    expect(prompts.last, contains('[E1]'));
    expect(prompts.last, contains('原文命中'));

    final Map<String, Object?> reconJsonReply =
        reply['recon'] as Map<String, Object?>;
    final List<dynamic> regular = reconJsonReply['regular'] as List<dynamic>;
    expect((regular.first as Map)['evidence_ids'], <String>['E1']);
    expect((regular.last as Map)['unknown'], isTrue);
    final List<dynamic> questions =
        reconJsonReply['questions'] as List<dynamic>;
    expect((questions.single as Map)['evidence_ids'], <String>['E2']);

    for (final String key in <String>[
      'digest_ms',
      'retrieve_ms',
      'llm_ms',
      'total_ms',
    ]) {
      expect(reply[key], isA<int>(), reason: key);
      expect(reply[key] as int, greaterThanOrEqualTo(0), reason: key);
    }
    final Map<String, Object?> task = reply['task'] as Map<String, Object?>;
    final Map<String, Object?> reconData =
        task['recon'] as Map<String, Object?>;
    expect(reconData['total_ms'], isA<int>());
    expect(reconData['partial'], isFalse);
    expect(reconData['degraded'], '');
    expect((reconData['evidence'] as List<dynamic>), hasLength(2));
    expect((reconData['digest'] as Map)['requirement_summary'], '让会话列表按项目过滤');
    expect(File(asset('recon.json')).existsSync(), isTrue);
  });

  test('单查询超时：degraded single_query，继续用另一路，不补第三次', () async {
    final List<String> queries = <String>[];
    int reconCalls = 0;
    service = PreparationService(
      environment: const <String, String>{},
      clock: clock,
      queryTimeout: const Duration(milliseconds: 40),
      retrievalDeadline: const Duration(seconds: 1),
      llm:
          (
            String point,
            String system,
            String prompt,
            Map<String, Object?> scope,
            String modelId,
          ) async {
            if (point == 'production.digest') return digestJson;
            reconCalls += 1;
            return <String, Object?>{
              'regular': <Object?>[
                <String, Object?>{
                  'text': '改列表',
                  'evidence_ids': <String>['E1'],
                },
              ],
              'questions': <Object?>[],
              'fallbacks': <Object?>[],
              'notes': <Object?>[],
              'flags': <String>[],
            };
          },
      docQuery:
          (String repo, String question, Map<String, Object?> scope) async {
            queries.add(question);
            if (question.contains('验收：')) {
              await Future<void>.delayed(const Duration(milliseconds: 200));
              return <String, Object?>{
                'results': <Object?>[
                  <String, Object?>{
                    'doc': 'docs/slow.md',
                    'heading': 'S',
                    'snippet': '慢查询',
                  },
                ],
              };
            }
            return <String, Object?>{
              'results': <Object?>[
                <String, Object?>{
                  'doc': 'docs/ok.md',
                  'heading': 'OK',
                  'snippet': '快查询',
                },
              ],
            };
          },
    );
    await intake();
    final Map<String, Object?> reply = await recon();
    expect(queries, hasLength(2), reason: '超时后不补第三次查询');
    expect(reply['degraded'], 'single_query');
    expect(reply['partial'], isFalse);
    expect((reply['evidence'] as List<dynamic>), hasLength(1));
    expect(reconCalls, 1, reason: '检索降级仍只调一次 LLM #2');
  });

  test('1 分钟总时限：LLM #2 超时回 partial/timeout，不流转、不伪造侦查', () async {
    service = PreparationService(
      environment: const <String, String>{},
      clock: clock,
      totalDeadline: const Duration(milliseconds: 60),
      queryTimeout: const Duration(milliseconds: 200),
      retrievalDeadline: const Duration(seconds: 1),
      llm:
          (
            String point,
            String system,
            String prompt,
            Map<String, Object?> scope,
            String modelId,
          ) async {
            if (point == 'production.digest') return digestJson;
            // LLM #2 慢于总时限：应被 timeout 截断，而不是拖过 1 分钟。
            await Future<void>.delayed(const Duration(milliseconds: 300));
            return reconJson;
          },
      docQuery:
          (String repo, String question, Map<String, Object?> scope) async {
            return <String, Object?>{
              'results': <Object?>[
                <String, Object?>{
                  'doc': 'docs/project-status.md',
                  'heading': 'H',
                  'snippet': '生产线已完成',
                },
              ],
            };
          },
    );
    await intake();
    final Map<String, Object?> reply = await recon();

    expect(reply['partial'], isTrue);
    expect(reply['timeout'], isTrue);
    expect(reply['deadline_ms'], 60);
    expect(reply.containsKey('recon'), isFalse, reason: '到点不伪造侦查结论');
    expect((reply['task'] as Map)['status'], 'draft', reason: '到点不流转状态');
    expect(reply['open'], 0, reason: '到点不新增问题');
    expect(File(asset('recon.md')).existsSync(), isFalse);
    expect((reply['digest'] as Map)['requirement_summary'], '让会话列表按项目过滤');
    expect((reply['evidence'] as List<dynamic>), hasLength(1));
    for (final String key in <String>[
      'digest_ms',
      'retrieve_ms',
      'llm_ms',
      'total_ms',
    ]) {
      expect(reply[key], isA<int>(), reason: key);
      expect(reply[key] as int, greaterThanOrEqualTo(0), reason: key);
    }

    final Map<String, Object?> stored =
        (reply['task'] as Map<String, Object?>)['recon']
            as Map<String, Object?>;
    expect(stored['partial'], isTrue);
    expect(stored['timeout'], isTrue);
    expect(stored['deadline_ms'], 60);
    expect((stored['digest'] as Map)['requirement_summary'], '让会话列表按项目过滤');
    expect((stored['evidence'] as List<dynamic>), hasLength(1));
    expect(stored['total_ms'], isA<int>());
  });

  test('1 分钟总时限：正常完成 partial=false、timeout=false 且照常流转', () async {
    service = PreparationService(
      environment: const <String, String>{},
      clock: clock,
      totalDeadline: const Duration(seconds: 2),
      llm:
          (
            String point,
            String system,
            String prompt,
            Map<String, Object?> scope,
            String modelId,
          ) async {
            if (point == 'production.digest') return digestJson;
            return <String, Object?>{
              'regular': <Object?>['改列表'],
              'questions': <Object?>[],
              'fallbacks': <Object?>[],
              'notes': <Object?>[],
              'flags': <String>[],
            };
          },
      docQuery:
          (String repo, String question, Map<String, Object?> scope) async =>
              <String, Object?>{
                'results': <Object?>[
                  <String, Object?>{
                    'doc': 'docs/project-status.md',
                    'heading': 'H',
                    'snippet': '生产线已完成',
                  },
                ],
              },
    );
    await intake();
    final Map<String, Object?> reply = await recon();

    expect(reply['partial'], isFalse);
    expect(reply['timeout'], isFalse);
    expect(reply['deadline_ms'], 2000);
    expect((reply['task'] as Map)['status'], 'aligning');
    final Map<String, Object?> stored =
        (reply['task'] as Map<String, Object?>)['recon']
            as Map<String, Object?>;
    expect(stored['partial'], isFalse);
    expect(stored['timeout'], isFalse);
    expect(stored['deadline_ms'], 2000);
  });

  test('检索阶段 10s 门控：超 deadline 用部分结果并标 partial/recall_gap', () async {
    int reconCalls = 0;
    service = PreparationService(
      environment: const <String, String>{},
      clock: clock,
      queryTimeout: const Duration(milliseconds: 500),
      retrievalDeadline: const Duration(milliseconds: 20),
      llm:
          (
            String point,
            String system,
            String prompt,
            Map<String, Object?> scope,
            String modelId,
          ) async {
            if (point == 'production.digest') return digestJson;
            reconCalls += 1;
            return <String, Object?>{
              'regular': <Object?>['改列表'],
              'questions': <Object?>[],
              'fallbacks': <Object?>[],
              'notes': <Object?>[],
              'flags': <String>[],
            };
          },
      docQuery:
          (String repo, String question, Map<String, Object?> scope) async {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            return <String, Object?>{'results': <Object?>[]};
          },
    );
    await intake();
    final Map<String, Object?> reply = await recon();
    expect(reply['partial'], isTrue);
    expect(reply['degraded'], 'single_query');
    expect(reply['recall_gap'], isTrue);
    expect((reply['evidence'] as List<dynamic>), isEmpty);
    expect(reconCalls, 1, reason: '超时也只调一次 LLM #2');
  });

  test('侦查读取 agent 记忆：只落元数据，正文只进摘要提示词', () async {
    const String memoryHash =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    ProductionStore(dataRoot: temp.path, clock: clock).updateLine(
      'pl_demo',
      <String, Object?>{
        'executor': <String, Object?>{'agent_id': 'agt_exec'},
      },
    );
    String? gotAgent;
    String? gotPurpose;
    final List<String> prompts = <String>[];
    service = PreparationService(
      environment: const <String, String>{},
      clock: clock,
      memory: MemoryPort(
        get:
            (
              String agentId,
              String purpose,
              int budgetChars,
              Map<String, Object?> scope,
            ) async {
              gotAgent = agentId;
              gotPurpose = purpose;
              return <String, Object?>{
                'ok': true,
                'agent_id': agentId,
                'purpose': purpose,
                'path': '.self/memory.md',
                'text': '上次拍板：不动数据库',
                'hash': memoryHash,
                'chars': 12,
                'total_chars': 12,
                'truncated': false,
                'sources': <String>['line/pl_demo/task/T1'],
              };
            },
      ),
      llm:
          (
            String point,
            String system,
            String prompt,
            Map<String, Object?> scope,
            String modelId,
          ) async {
            prompts.add(prompt);
            if (point == 'production.digest') return digestJson;
            return reconJson;
          },
      docQuery: (
        String repo,
        String question,
        Map<String, Object?> scope,
      ) async => <String, Object?>{'results': <Object?>[]},
    );
    await intake();
    final Map<String, Object?> reply = await recon();

    expect(gotAgent, 'agt_exec', reason: '取 line.yaml.executor.agent_id');
    expect(gotPurpose, 'production.prepare.recon');
    expect(prompts.first, contains('项目记忆（来自 agent memory'));
    expect(prompts.first, contains('上次拍板：不动数据库'));

    final Map<String, Object?> stored =
        (reply['task'] as Map<String, Object?>)['recon']
            as Map<String, Object?>;
    expect(stored['memory_hash'], memoryHash);
    expect(stored['memory_sources'], <String>['line/pl_demo/task/T1']);
    expect(stored['memory_unavailable'], isFalse);

    final String reconJsonText = File(asset('recon.json')).readAsStringSync();
    expect(reconJsonText, contains(memoryHash));
    expect(reconJsonText, isNot(contains('上次拍板：不动数据库')), reason: '记忆正文不落盘');
  });

  test('视觉摘要：vision_model 图片送 visionLlm，只记数量不落 base64', () async {
    final List<String> visionPoints = <String>[];
    final List<Map<String, Object?>> visionImages = <Map<String, Object?>>[];
    int textDigestCalls = 0;
    service = PreparationService(
      environment: const <String, String>{},
      clock: clock,
      visionLlm:
          (
            String point,
            String system,
            String prompt,
            List<Map<String, Object?>> images,
            Map<String, Object?> scope,
            String modelId,
          ) async {
            visionPoints.add(point);
            visionImages.addAll(images);
            return digestJson;
          },
      llm:
          (
            String point,
            String system,
            String prompt,
            Map<String, Object?> scope,
            String modelId,
          ) async {
            if (point == 'production.digest') textDigestCalls += 1;
            return point == 'production.digest' ? digestJson : reconJson;
          },
      docQuery:
          (String repo, String question, Map<String, Object?> scope) async =>
              <String, Object?>{
                'results': <Object?>[
                  <String, Object?>{
                    'doc': 'docs/a.md',
                    'heading': 'A',
                    'snippet': '命中',
                  },
                ],
              },
    );
    await intake();
    final List<int> bytes = List<int>.generate(48, (int i) => i);
    File(p.join(workspace.path, 'shots', 'screen.png'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    ProductionStore(dataRoot: temp.path, clock: clock).putTask(
      'pl_demo',
      'T0',
      <String, Object?>{
        'attachments': <Object?>[
          <String, Object?>{
            'path': 'shots/screen.png',
            'name': 'screen.png',
            'type': 'image/png',
            'kind': 'image',
            'size': bytes.length,
            'summary_by': 'vision_model',
          },
        ],
      },
    );

    final Map<String, Object?> reply = await recon();
    expect(visionPoints, <String>['production.digest']);
    expect(textDigestCalls, 0, reason: '有图时不走纯文本摘要');
    expect(visionImages, hasLength(1));
    final Map<String, Object?> image = visionImages.single;
    expect(image['name'], 'screen.png');
    expect(image['mime'], 'image/png');
    expect(image['base64'], base64Encode(bytes));
    expect((reply['task'] as Map)['status'], 'aligning');

    final Map<String, Object?> stored =
        (reply['task'] as Map<String, Object?>)['recon']
            as Map<String, Object?>;
    expect(stored['digest_images'], 1);
    final String reconJsonText = File(asset('recon.json')).readAsStringSync();
    expect(reconJsonText, contains('"digest_images": 1'));
    expect(
      reconJsonText,
      isNot(contains(base64Encode(bytes))),
      reason: 'base64 不落盘',
    );
  });

  test('manual_reference 图片不送视觉模型，退回文本摘要', () async {
    final List<String> visionPoints = <String>[];
    int digestCalls = 0;
    service = PreparationService(
      environment: const <String, String>{},
      clock: clock,
      visionLlm:
          (
            String point,
            String system,
            String prompt,
            List<Map<String, Object?>> images,
            Map<String, Object?> scope,
            String modelId,
          ) async {
            visionPoints.add(point);
            return digestJson;
          },
      llm:
          (
            String point,
            String system,
            String prompt,
            Map<String, Object?> scope,
            String modelId,
          ) async {
            if (point == 'production.digest') digestCalls += 1;
            return point == 'production.digest' ? digestJson : reconJson;
          },
      docQuery:
          (String repo, String question, Map<String, Object?> scope) async =>
              <String, Object?>{
                'results': <Object?>[
                  <String, Object?>{
                    'doc': 'docs/a.md',
                    'heading': 'A',
                    'snippet': '命中',
                  },
                ],
              },
    );
    await intake();
    final List<int> bytes = List<int>.generate(48, (int i) => i);
    File(p.join(workspace.path, 'shots', 'manual.png'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    ProductionStore(dataRoot: temp.path, clock: clock).putTask(
      'pl_demo',
      'T0',
      <String, Object?>{
        'attachments': <Object?>[
          <String, Object?>{
            'path': 'shots/manual.png',
            'name': 'manual.png',
            'type': 'image/png',
            'kind': 'image',
            'size': bytes.length,
            'summary_by': 'manual_reference',
          },
        ],
      },
    );

    final Map<String, Object?> reply = await recon();
    expect(visionPoints, isEmpty, reason: 'manual_reference 不送视觉模型');
    expect(digestCalls, 1, reason: '退回文本摘要');
    final Map<String, Object?> stored =
        (reply['task'] as Map<String, Object?>)['recon']
            as Map<String, Object?>;
    expect(stored['digest_images'], 0);
  });

  test('落档写计划版本 plan-v1，任务与准备任务都带 plan_version', () async {
    await intake();
    await recon();
    await answerAll(<String>['Q1', 'Q2', 'Q3']);
    final Map<String, Object?> reply = await finalize(
      extra: <String, Object?>{
        'plan': <Object?>[
          <String, Object?>{
            'id': 'T1',
            'title': '改列表',
            'task_type': 'code',
            'acceptance': <String>['用例全绿'],
            'write_scope': <String>['lib/ui/agent_list.dart'],
            'gate': <String, Object?>{
              'commands': <String>['dart test'],
            },
          },
          <String, Object?>{
            'id': 'T2',
            'title': '补测试',
            'task_type': 'test',
            'depends_on': <String>['T1'],
            'acceptance': <String>['新用例覆盖过滤'],
            'gate': <String, Object?>{
              'commands': <String>['dart test'],
            },
          },
        ],
      },
    );
    expect((reply['created_tasks'] as List<dynamic>), hasLength(2));

    final ProductionStore store = ProductionStore(
      dataRoot: temp.path,
      clock: clock,
    );
    final String planPath = p.join(
      store.plansDir('pl_demo'),
      'plan-v1',
      'plan.json',
    );
    expect(File(planPath).existsSync(), isTrue);
    final Map<String, dynamic> planJson =
        json.decode(File(planPath).readAsStringSync()) as Map<String, dynamic>;
    expect((planJson['tasks'] as List<dynamic>), hasLength(2));
    expect(planJson['saved_at'], isNotEmpty);
    final String validationPath = p.join(
      store.plansDir('pl_demo'),
      'plan-v1',
      'validation.json',
    );
    expect(File(validationPath).existsSync(), isTrue);
    final Map<String, dynamic> validation = json.decode(
      File(validationPath).readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(validation['batches'], isA<List<dynamic>>());
    expect(validation['dag'], isA<Map<dynamic, dynamic>>());

    expect(store.getTask('pl_demo', 'T1').data['plan_version'], 'plan-v1');
    expect(store.getTask('pl_demo', 'T2').data['plan_version'], 'plan-v1');
    final Map<String, Object?> scopeData =
        store.getTask('pl_demo', 'T0').data['scope'] as Map<String, Object?>;
    expect(scopeData['plan_version'], 'plan-v1');
    expect(
      store
          .listPlanVersions('pl_demo')
          .map((Map<String, Object?> item) => item['version']),
      <int>[1],
    );
  });

  test('计划有环时 finalize 报 plan_cycle，不建任务也不写资产', () async {
    await intake();
    await recon();
    await answerAll(<String>['Q1', 'Q2', 'Q3']);
    await expectLater(
      finalize(
        extra: <String, Object?>{
          'plan': <Object?>[
            <String, Object?>{
              'id': 'T1',
              'title': 'A',
              'task_type': 'chore',
              'depends_on': <String>['T2'],
              'acceptance': <String>['A 完成'],
              'gate': <String, Object?>{
                'commands': <String>['dart test'],
              },
            },
            <String, Object?>{
              'id': 'T2',
              'title': 'B',
              'task_type': 'chore',
              'depends_on': <String>['T1'],
              'acceptance': <String>['B 完成'],
              'gate': <String, Object?>{
                'commands': <String>['dart test'],
              },
            },
          ],
        },
      ),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure error) => error.code,
          'code',
          'plan_cycle',
        ),
      ),
    );
    final ProductionStore store = ProductionStore(
      dataRoot: temp.path,
      clock: clock,
    );
    expect(
      store.listTasks('pl_demo').map((TaskRecord task) => task.id),
      <String>['T0'],
    );
    expect(store.getTask('pl_demo', 'T0').status, TaskStatus.aligning);
    expect(File(asset('scope.md')).existsSync(), isFalse);
    expect(File(asset('plan.md')).existsSync(), isFalse);
    expect(Directory(store.plansDir('pl_demo')).existsSync(), isFalse);
  });

  test('计划多轮：缺追踪→批判/修正→落档写 7 块与 findings', () async {
    reconJson = <String, Object?>{
      'regular': <Object?>['改列表'],
      'special': <Object?>[],
      'questions': <Object?>[],
      'fallbacks': <Object?>[],
      'notes': <Object?>[],
      'flags': <String>[],
    };
    await intake();
    await recon();
    final Map<String, Object?> draft = structuredPlan()
      ..['traceability'] = <Object?>[];
    final Map<String, Object?> fixed = structuredPlan();
    final List<String> points = <String>[];
    service = PreparationService(
      environment: const <String, String>{},
      clock: clock,
      llm:
          (
            String point,
            String system,
            String prompt,
            Map<String, Object?> scope,
            String modelId,
          ) async {
            points.add(point);
            if (point == 'production.digest') return digestJson;
            if (point == 'production.recon') return reconJson;
            if (point == 'production.plan') return draft;
            if (point == 'production.plan.critic') {
              return <String, Object?>{'findings': <Object?>[]};
            }
            if (point == 'production.plan.fix') return fixed;
            return <String, Object?>{};
          },
    );
    final Map<String, Object?> reply = await finalize();
    expect(points, contains('production.plan'));
    expect(points, contains('production.plan.critic'));
    expect(points, contains('production.plan.fix'));
    expect(
      (reply['created_tasks'] as List<dynamic>)
          .map((dynamic task) => (task as Map)['id'])
          .toList(),
      <String>['T1'],
    );
    final ProductionStore store = ProductionStore(
      dataRoot: temp.path,
      clock: clock,
    );
    final File planFile = File(
      p.join(store.plansDir('pl_demo'), 'plan-v1', 'plan.json'),
    );
    expect(planFile.existsSync(), isTrue);
    final Map<String, dynamic> plan =
        json.decode(planFile.readAsStringSync()) as Map<String, dynamic>;
    expect((plan['requirements'] as List<dynamic>), isNotEmpty);
    expect((plan['traceability'] as List<dynamic>), isNotEmpty);
    expect(plan.containsKey('findings'), isTrue);
    expect(plan['saved_at'], isNotEmpty);
    expect(
      File(p.join(store.plansDir('pl_demo'), 'plan-v1', 'findings.json'))
          .existsSync(),
      isTrue,
    );
  });

  test('三轮仍失败：open high → plan_critic_open_high 且不建任务', () async {
    reconJson = <String, Object?>{
      'regular': <Object?>['改列表'],
      'special': <Object?>[],
      'questions': <Object?>[],
      'fallbacks': <Object?>[],
      'notes': <Object?>[],
      'flags': <String>[],
    };
    await intake();
    await recon();
    final Map<String, Object?> plan = structuredPlan();
    final List<String> points = <String>[];
    service = PreparationService(
      environment: const <String, String>{},
      clock: clock,
      llm:
          (
            String point,
            String system,
            String prompt,
            Map<String, Object?> scope,
            String modelId,
          ) async {
            points.add(point);
            if (point == 'production.digest') return digestJson;
            if (point == 'production.recon') return reconJson;
            if (point == 'production.plan') return plan;
            if (point == 'production.plan.critic') {
              return <String, Object?>{
                'findings': <Object?>[
                  <String, Object?>{
                    'id': 'F-01',
                    'severity': 'high',
                    'task_id': 'T1',
                    'message': '缺回滚演练',
                  },
                ],
              };
            }
            if (point == 'production.plan.fix') return plan;
            return <String, Object?>{};
          },
    );
    await expectLater(
      finalize(),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure error) => error.code,
          'code',
          'plan_critic_open_high',
        ),
      ),
    );
    expect(
      points.where((String point) => point == 'production.plan.critic'),
      hasLength(2),
    );
    final ProductionStore store = ProductionStore(
      dataRoot: temp.path,
      clock: clock,
    );
    expect(
      store.listTasks('pl_demo').map((TaskRecord task) => task.id),
      <String>['T0'],
    );
    expect(store.getTask('pl_demo', 'T0').status, TaskStatus.aligning);
    expect(Directory(store.plansDir('pl_demo')).existsSync(), isFalse);
  });
}
