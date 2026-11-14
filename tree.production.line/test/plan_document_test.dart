import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

/// PC-3F 计划文档：PG-00 / 01 / 02 / 08 / 09 / 10 与旧式计划兼容。
void main() {
  Map<String, Object?> task(
    String id, {
    String type = 'code',
    List<String> deps = const <String>[],
    List<String> write = const <String>[],
    List<String> requirements = const <String>['REQ-01'],
    Map<String, Object?>? contract,
    bool contractChange = false,
    Object? behavior = 'change',
    Object? preserves = const <String>[],
    Object? changes = const <String>['行为改动'],
  }) => <String, Object?>{
    'id': id,
    'title': '任务 $id',
    'task_type': type,
    'depends_on': deps,
    'read_scope': const <String>[],
    'write_scope': write,
    'acceptance': <String>['可验证判据'],
    'estimated_files': 1,
    'estimated_lines': 0,
    'estimated_packages': 0,
    'risk': 'low',
    'rationale': '按需求拆分',
    'requirements': requirements,
    'contract': ?contract,
    if (contractChange) 'contract_change': true,
    'behavior': ?behavior,
    'preserves': ?preserves,
    'changes': ?changes,
    'gate': <String, Object?>{
      'commands': <String>['dart test'],
    },
  };

  const String gateText = '- [ ] dart analyze 退出码 0';

  Map<String, Object?> goodPlan() => <String, Object?>{
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
      task('T1', write: <String>['lib/ui/agent_list.dart']),
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

  PlanDocValidation check(
    Map<String, Object?> json, {
    Set<String> existingIds = const <String>{'T0'},
    bool fixTasks = true,
  }) => validatePlanDocument(
    parsePlanDocument(json),
    existingIds: existingIds,
    fixTasks: fixTasks,
  );

  Set<String> codes(PlanDocValidation validation) => <String>{
    for (final PlanIssue issue in validation.issues) issue.code,
  };

  group('PG-00 计划 7 块', () {
    test('完整计划通过，缺块分别给出失败码', () {
      expect(check(goodPlan()).ok, isTrue);

      final Map<String, Object?> noDesign = goodPlan()..remove('design');
      expect(codes(check(noDesign)), contains('plan_design_missing'));

      final Map<String, Object?> emptyInvariants = goodPlan()
        ..['invariants'] = <Object?>[];
      expect(
        codes(check(emptyInvariants)),
        contains('plan_invariants_missing'),
      );

      final Map<String, Object?> noTasks = goodPlan()..['tasks'] = <Object?>[];
      expect(codes(check(noTasks)), contains('plan_tasks_missing'));

      final Map<String, Object?> noGates = goodPlan()
        ..['gates'] = <String, Object?>{};
      expect(codes(check(noGates)), contains('plan_gate_missing'));

      final Map<String, Object?> noTrace = goodPlan()
        ..['traceability'] = <Object?>[];
      expect(codes(check(noTrace)), contains('plan_traceability_gap'));

      final Map<String, Object?> noRisks = goodPlan()
        ..['risks'] = <Object?>[]
        ..['unknowns'] = <Object?>[];
      expect(codes(check(noRisks)), contains('plan_risk_missing'));

      final Map<String, Object?> noChangeControl = goodPlan()
        ..['change_control'] = <String, Object?>{'plan_version': 'plan-v1'};
      expect(
        codes(check(noChangeControl)),
        contains('plan_change_control_missing'),
      );
    });

    test('design 必填键为空也报 plan_design_missing', () {
      final Map<String, Object?> json = goodPlan();
      final Map<String, Object?> design = Map<String, Object?>.of(
        json['design'] as Map<String, Object?>,
      )..['rollback'] = '';
      json['design'] = design;
      expect(codes(check(json)), contains('plan_design_missing'));
    });
  });

  group('PG-01 原始需求编号', () {
    test('重复编号 / 缺原文 / 非法编号都报 plan_requirement_missing', () {
      final Map<String, Object?> duplicate = goodPlan();
      duplicate['requirements'] = <Object?>[
        <String, Object?>{'id': 'REQ-01', 'text': 'a'},
        <String, Object?>{'id': 'REQ-01', 'text': 'b'},
      ];
      expect(codes(check(duplicate)), contains('plan_requirement_missing'));

      final Map<String, Object?> noText = goodPlan();
      noText['requirements'] = <Object?>[
        <String, Object?>{'id': 'REQ-01', 'text': ''},
      ];
      expect(codes(check(noText)), contains('plan_requirement_missing'));

      final Map<String, Object?> badId = goodPlan();
      badId['requirements'] = <Object?>[
        <String, Object?>{'id': 'R1', 'text': '原文'},
      ];
      expect(codes(check(badId)), contains('plan_requirement_missing'));
    });
  });

  group('PG-02 需求 → 任务 → 门控', () {
    test('断链阻断，补上追踪后通过', () {
      final Map<String, Object?> broken = goodPlan()
        ..['traceability'] = <Object?>[];
      final PlanDocValidation brokenResult = check(broken);
      expect(brokenResult.ok, isFalse);
      expect(brokenResult.code, 'plan_traceability_gap');

      final Map<String, Object?> missingTask = goodPlan();
      missingTask['traceability'] = <Object?>[
        <String, Object?>{
          'req': 'REQ-01',
          'tasks': <String>['T9'],
          'gates': <String>[gateText],
        },
      ];
      expect(codes(check(missingTask)), contains('plan_traceability_gap'));

      final Map<String, Object?> unknownRequirement = goodPlan();
      unknownRequirement['tasks'] = <Object?>[
        task('T1', requirements: <String>['REQ-99']),
      ];
      expect(
        codes(check(unknownRequirement)),
        contains('plan_traceability_gap'),
      );

      expect(check(goodPlan()).ok, isTrue);
    });

    test('门控缺 evidence 报 plan_gate_missing 并补 - [ ] 前缀', () {
      final Map<String, Object?> json = goodPlan();
      json['gates'] = <String, Object?>{
        'T1': <Object?>[
          <String, Object?>{'text': 'dart test 全绿', 'evidence': '-'},
        ],
      };
      final PlanDocValidation validation = check(json);
      expect(codes(validation), contains('plan_gate_missing'));
      final Map<String, Object?> item = validation.doc.gates['T1']!.single;
      expect(item['text'], '- [ ] dart test 全绿');
      expect(item['checked'], isFalse);
    });
  });

  group('PG-08 契约变更授权', () {
    Map<String, Object?> contractPlan() {
      final Map<String, Object?> json = goodPlan();
      json['tasks'] = <Object?>[
        task(
          'T1',
          contract: <String, Object?>{
            'changes': <String>['POST /api/list 新增 project 参数'],
          },
        ),
      ];
      return json;
    }

    test('无 DEC / 单人批准 / 未批准都阻断，双人批准通过', () {
      final Map<String, Object?> json = contractPlan();
      expect(codes(check(json)), contains('plan_contract_change_unauthorized'));

      json['decisions'] = <Object?>[
        <String, Object?>{
          'id': 'DEC-01',
          'status': 'approved',
          'approved_by': 'user',
          'scope': <String>['T1'],
          'task_id': 'T1',
          'type': 'contract_change',
        },
      ];
      expect(
        codes(check(json)),
        contains('plan_contract_change_unauthorized'),
        reason: '单人批准不算双人确认',
      );

      json['decisions'] = <Object?>[
        <String, Object?>{
          'id': 'DEC-01',
          'status': 'proposed',
          'approved_by': '用户、评审',
          'scope': <String>['T1'],
          'task_id': 'T1',
          'type': 'contract_change',
        },
      ];
      expect(codes(check(json)), contains('plan_contract_change_unauthorized'));

      json['decisions'] = <Object?>[
        <String, Object?>{
          'id': 'DEC-01',
          'status': 'approved',
          'approved_by': '用户、评审',
          'scope': <String>['T1'],
          'task_id': 'T1',
          'type': 'contract_change',
        },
      ];
      expect(check(json).ok, isTrue);
    });
  });

  group('PG-09 迁移基线', () {
    test('迁移计划缺 baseline / baseline_tasks 阻断', () {
      final Map<String, Object?> json = goodPlan();
      final Map<String, Object?> design = Map<String, Object?>.of(
        json['design'] as Map<String, Object?>,
      )..remove('baseline');
      json['design'] = design;
      expect(codes(check(json)), contains('plan_baseline_missing'));

      final Map<String, Object?> unknownBaseline = goodPlan();
      final Map<String, Object?> design2 = Map<String, Object?>.of(
        unknownBaseline['design'] as Map<String, Object?>,
      )..['baseline_tasks'] = <String>['T9'];
      unknownBaseline['design'] = design2;
      expect(codes(check(unknownBaseline)), contains('plan_baseline_missing'));
    });
  });

  group('PG-09 迁移防漂移', () {
    Map<String, Object?> withDesign(Map<String, Object?> json, Map<String, Object?> patch) {
      json['design'] = <String, Object?>{
        ...(json['design'] as Map<String, Object?>),
        ...patch,
      };
      return json;
    }

    test('缺 migration_strategy / rollback_tasks 阻断', () {
      final Map<String, Object?> noStrategy = withDesign(goodPlan(), <String, Object?>{
        'migration_strategy': '',
      });
      expect(codes(check(noStrategy)), contains('plan_design_missing'));

      final Map<String, Object?> badStrategy = withDesign(goodPlan(), <String, Object?>{
        'migration_strategy': 'big_bang',
      });
      expect(codes(check(badStrategy)), contains('plan_design_missing'));

      final Map<String, Object?> noRollbackTasks = withDesign(
        goodPlan(),
        <String, Object?>{'rollback_tasks': <String>[]},
      );
      expect(codes(check(noRollbackTasks)), contains('plan_design_missing'));
    });

    test('任务缺 behavior / preserves / changes 阻断', () {
      Map<String, Object?> onlyTask(Map<String, Object?> only) {
        final Map<String, Object?> json = goodPlan();
        json['tasks'] = <Object?>[only];
        return json;
      }

      expect(
        codes(check(onlyTask(task('T1', behavior: null)))),
        contains('plan_design_missing'),
      );
      expect(
        codes(check(onlyTask(task('T1', preserves: null)))),
        contains('plan_invariants_missing'),
      );
      expect(
        codes(check(onlyTask(task('T1', changes: null)))),
        contains('plan_invariants_missing'),
      );
    });

    test('同一任务同时声明 preserve 与 change 阻断', () {
      final Map<String, Object?> json = goodPlan();
      json['tasks'] = <Object?>[
        task('T1', behavior: <String>['preserve', 'change']),
      ];
      expect(codes(check(json)), contains('plan_design_missing'));
    });

    test('preserve 与 change 分开的完整迁移计划通过', () {
      final Map<String, Object?> json = withDesign(
        goodPlan(),
        <String, Object?>{'behavior_split': ''},
      );
      json['tasks'] = <Object?>[
        task(
          'T1',
          behavior: 'preserve',
          preserves: <String>['旧列表行为不变'],
          changes: <String>[],
        ),
        task(
          'T2',
          type: 'test',
          behavior: 'change',
          preserves: <String>[],
          changes: <String>['新增过滤行为'],
          deps: <String>['T1'],
        ),
      ];
      json['gates'] = <String, Object?>{
        'T1': <Object?>[
          <String, Object?>{
            'text': gateText,
            'evidence': 'plans/plan-v1/gates/T1/analyze.log',
          },
        ],
        'T2': <Object?>[
          <String, Object?>{
            'text': gateText,
            'evidence': 'plans/plan-v1/gates/T2/analyze.log',
          },
        ],
      };
      json['traceability'] = <Object?>[
        <String, Object?>{
          'req': 'REQ-01',
          'tasks': <String>['T1', 'T2'],
          'gates': <String>[gateText],
          'evidence': <String>['plans/plan-v1/gates/T1/analyze.log'],
        },
      ];
      final PlanDocValidation validation = check(json);
      expect(validation.ok, isTrue, reason: '${validation.issues.map((i) => i.message)}');
    });
  });

  group('PG-10 迭代闭环', () {
    test('open high 无 DEC 阻断，accept_high_finding DEC 放行', () {
      final Map<String, Object?> json = goodPlan();
      json['findings'] = <Object?>[
        <String, Object?>{
          'id': 'F-01',
          'severity': 'high',
          'status': 'open',
          'task_id': 'T1',
          'message': '缺回滚演练',
        },
      ];
      expect(codes(check(json)), contains('plan_critic_open_high'));

      json['decisions'] = <Object?>[
        <String, Object?>{
          'id': 'DEC-02',
          'status': 'approved',
          'approved_by': 'user',
          'task_id': 'T1',
          'type': 'accept_high_finding',
          'finding_id': 'F-01',
        },
      ];
      expect(check(json).ok, isTrue);
    });

    test('rounds < 1 视为没有迭代', () {
      final Map<String, Object?> json = goodPlan()..['rounds'] = 0;
      expect(codes(check(json)), contains('plan_critic_open_high'));
    });
  });

  group('旧式 tasks-only 计划兼容', () {
    test('structured=false，只跑 PG-03~07', () {
      final PlanDocument doc = parsePlanDocument(<String, Object?>{
        'tasks': <Object?>[task('T1')],
      });
      expect(doc.structured, isFalse);
      final PlanDocValidation validation = validatePlanDocument(
        doc,
        existingIds: const <String>{'T0'},
      );
      expect(validation.ok, isTrue);
      expect(codes(validation), isNot(contains('plan_design_missing')));
    });

    test('旧式计划仍报 plan_cycle', () {
      final PlanDocValidation validation = check(<String, Object?>{
        'tasks': <Object?>[
          task('T1', deps: <String>['T2']),
          task('T2', deps: <String>['T1']),
        ],
      });
      expect(validation.ok, isFalse);
      expect(codes(validation), contains('plan_cycle'));
      expect(codes(validation), isNot(contains('plan_design_missing')));
    });
  });
}
