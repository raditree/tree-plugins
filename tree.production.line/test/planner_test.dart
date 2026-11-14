import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

/// PC-3E 任务拆分器：PG-03~07 与确定性修正。
void main() {
  Map<String, Object?> task(
    String id, {
    String type = 'code',
    List<String> deps = const <String>[],
    List<String> write = const <String>[],
    List<String> acceptance = const <String>['可验证的完成判据'],
    Map<String, Object?>? gate,
    int files = 1,
    int lines = 0,
    int packages = 0,
    String reason = '',
  }) => <String, Object?>{
    'id': id,
    'title': '任务 $id',
    'task_type': type,
    'depends_on': deps,
    'write_scope': write,
    'acceptance': acceptance,
    'gate':
        gate ??
        <String, Object?>{
          'commands': <String>['dart test'],
        },
    'estimated_files': files,
    'estimated_lines': lines,
    'estimated_packages': packages,
    'split_reason': reason,
  };

  List<String> ids(PlanValidation validation) => <String>[
    for (final Map<String, Object?> item in validation.tasks)
      textOf(item['id']),
  ];

  group('PG-03 依赖图', () {
    test('缺依赖报 plan_dependency_missing，已存在任务可作依赖', () {
      final PlanValidation missing = validateAndFixPlan(
        tasks: <Map<String, Object?>>[
          task('T1', deps: <String>['T0']),
        ],
        fix: false,
      );
      expect(missing.ok, isFalse);
      expect(missing.code, 'plan_dependency_missing');
      expect(missing.missing, <String>['T1']);

      final PlanValidation allowed = validateAndFixPlan(
        tasks: <Map<String, Object?>>[
          task('T1', deps: <String>['E1']),
        ],
        existingIds: <String>{'E1'},
        fix: false,
      );
      expect(
        allowed.issues.where(
          (PlanIssue issue) => issue.code == 'plan_dependency_missing',
        ),
        isEmpty,
      );
    });

    test('环报 plan_cycle，message 带环路径', () {
      final PlanValidation cycle = validateAndFixPlan(
        tasks: <Map<String, Object?>>[
          task('T1', deps: <String>['T2']),
          task('T2', deps: <String>['T1']),
        ],
        fix: false,
      );
      final PlanIssue issue = cycle.issues.firstWhere(
        (PlanIssue item) => item.code == 'plan_cycle',
      );
      expect(cycle.code, 'plan_cycle');
      expect(issue.message, contains('→'));
      expect(issue.message, contains('T1'));
      expect(issue.message, contains('T2'));
    });

    test('重复依赖与自依赖只告警并去掉', () {
      final PlanValidation validation = validateAndFixPlan(
        tasks: <Map<String, Object?>>[
          task('T1', deps: <String>['E1', 'E1', 'T1']),
        ],
        existingIds: <String>{'E1'},
        fix: true,
      );
      expect(validation.ok, isTrue);
      expect(
        validation.issues.where(
          (PlanIssue issue) => issue.code == 'plan_dependency_duplicate',
        ),
        isNotEmpty,
      );
      expect(
        validation.issues.where(
          (PlanIssue issue) => issue.code == 'plan_self_dependency',
        ),
        isNotEmpty,
      );
      expect(validation.tasks.single['depends_on'], <String>['E1']);
    });
  });

  group('PG-04 任务尺寸', () {
    test('超过 5 个文件自动拆分，片间串行且依赖者指向最后一片', () {
      final PlanValidation validation = validateAndFixPlan(
        tasks: <Map<String, Object?>>[
          task('T1', type: 'chore', files: 7, write: <String>['lib/a']),
          task(
            'T2',
            type: 'chore',
            deps: <String>['T1'],
            write: <String>['lib/b'],
          ),
        ],
      );
      expect(ids(validation), <String>['T1-1', 'T1-2', 'T2']);
      expect(
        validation.ok,
        isTrue,
        reason: <String>[
          for (final PlanIssue issue in validation.issues)
            '${issue.severity} ${issue.code} ${issue.taskId}: ${issue.message}',
        ].join('\n'),
      );
      final Map<String, Object?> first = validation.tasks[0];
      final Map<String, Object?> second = validation.tasks[1];
      final Map<String, Object?> dependent = validation.tasks[2];
      expect(first['estimated_files'], 5);
      expect(second['estimated_files'], 2);
      expect(first['title'], contains('（拆分 1/2）'));
      expect(second['depends_on'], <String>['T1-1']);
      expect(dependent['depends_on'], <String>['T1-2']);
      expect(
        validation.issues.where(
          (PlanIssue issue) => issue.code == 'plan_task_split',
        ),
        isNotEmpty,
      );
    });

    test('超 300 行 / 超 1 包必须给 split_reason', () {
      final PlanValidation missing = validateAndFixPlan(
        tasks: <Map<String, Object?>>[task('T1', lines: 400)],
        fix: false,
      );
      expect(missing.code, 'plan_task_oversize');

      final PlanValidation linesOk = validateAndFixPlan(
        tasks: <Map<String, Object?>>[
          task('T1', lines: 400, reason: '基线迁移必须整包改完'),
        ],
        fix: false,
      );
      expect(linesOk.ok, isTrue);

      final PlanValidation packagesMissing = validateAndFixPlan(
        tasks: <Map<String, Object?>>[task('T1', packages: 2)],
        fix: false,
      );
      expect(packagesMissing.code, 'plan_task_oversize');

      final PlanValidation packagesOk = validateAndFixPlan(
        tasks: <Map<String, Object?>>[
          task('T1', packages: 2, reason: '跨包契约必须一起改'),
        ],
        fix: false,
      );
      expect(packagesOk.ok, isTrue);
    });

    test('fix=false 只报错、不拆分', () {
      final PlanValidation validation = validateAndFixPlan(
        tasks: <Map<String, Object?>>[task('T1', type: 'chore', files: 7)],
        fix: false,
      );
      expect(ids(validation), <String>['T1']);
      expect(validation.tasks.single['estimated_files'], 7);
      expect(validation.code, 'plan_task_oversize');
    });
  });

  group('PG-05 写域交叠', () {
    test('交叠自动串行（fix）并排到后续批次', () {
      final PlanValidation validation = validateAndFixPlan(
        tasks: <Map<String, Object?>>[
          task('T1', type: 'chore', write: <String>['lib/a'], files: 2),
          task('T2', type: 'chore', write: <String>['lib/a'], files: 2),
        ],
        maxParallel: 2,
      );
      expect(validation.ok, isTrue);
      expect(validation.tasks[1]['depends_on'], contains('T1'));
      expect(
        validation.issues.where(
          (PlanIssue issue) => issue.code == 'plan_scope_serialized',
        ),
        isNotEmpty,
      );
      expect(
        <List<String>>[
          for (final PlanBatch batch in validation.batches) batch.taskIds,
        ],
        <List<String>>[
          <String>['T1'],
          <String>['T2'],
        ],
      );
    });

    test('fix=false 交叠且互不可达 ⇒ plan_scope_overlap', () {
      final PlanValidation validation = validateAndFixPlan(
        tasks: <Map<String, Object?>>[
          task('T1', type: 'chore', write: <String>['lib/a'], files: 2),
          task('T2', type: 'chore', write: <String>['lib/a'], files: 2),
        ],
        fix: false,
      );
      expect(validation.ok, isFalse);
      expect(validation.code, 'plan_scope_overlap');
    });

    test('已有可达关系视为串行，不报错', () {
      final PlanValidation validation = validateAndFixPlan(
        tasks: <Map<String, Object?>>[
          task('T1', type: 'chore', write: <String>['lib/a'], files: 2),
          task(
            'T2',
            type: 'chore',
            deps: <String>['T1'],
            write: <String>['lib/a'],
            files: 2,
          ),
        ],
        fix: false,
      );
      expect(validation.ok, isTrue);
    });

    test('同波按 id 升序贪心装填，达到 max_parallel 开新批', () {
      final PlanValidation validation = validateAndFixPlan(
        tasks: <Map<String, Object?>>[
          task('T1', type: 'chore', write: <String>['lib/a']),
          task('T2', type: 'chore', write: <String>['lib/b']),
          task('T3', type: 'chore', write: <String>['lib/c']),
        ],
        maxParallel: 2,
      );
      expect(
        <List<String>>[
          for (final PlanBatch batch in validation.batches) batch.taskIds,
        ],
        <List<String>>[
          <String>['T1', 'T2'],
          <String>['T3'],
        ],
      );
      expect(validation.batches[0].index, 1);
      expect(validation.batches[1].index, 2);
      expect(validation.batches[0].wave, 1);
      expect(validation.batches[1].wave, 1);
    });
  });

  group('PG-06 任务门控', () {
    test('空门控 / 空话清单被拒，命令与具体清单通过', () {
      for (final Map<String, Object?> gate in <Map<String, Object?>>[
        <String, Object?>{},
        <String, Object?>{
          'commands': <String>['通过'],
        },
        <String, Object?>{
          'checklist': <String>['- [ ] 通过'],
        },
        <String, Object?>{
          'checklist': <String>['验收'],
        },
      ]) {
        final PlanValidation validation = validateAndFixPlan(
          tasks: <Map<String, Object?>>[task('T1', gate: gate)],
          fix: false,
        );
        expect(
          validation.issues.where(
            (PlanIssue issue) => issue.code == 'plan_gate_missing',
          ),
          isNotEmpty,
          reason: '门控 $gate 不应通过',
        );
      }

      final PlanValidation commands = validateAndFixPlan(
        tasks: <Map<String, Object?>>[
          task(
            'T1',
            gate: <String, Object?>{
              'commands': <String>['dart analyze'],
            },
          ),
        ],
        fix: false,
      );
      expect(commands.ok, isTrue);

      final PlanValidation checklist = validateAndFixPlan(
        tasks: <Map<String, Object?>>[
          task(
            'T1',
            gate: <String, Object?>{
              'checklist': <String>['- [ ] 打开设置页确认项目过滤生效'],
            },
          ),
        ],
        fix: false,
      );
      expect(checklist.ok, isTrue);
    });
  });

  group('PG-07 集成任务', () {
    test('多个 code 任务缺 integration ⇒ plan_integration_missing', () {
      final PlanValidation validation = validateAndFixPlan(
        tasks: <Map<String, Object?>>[task('T1'), task('T2')],
        fix: false,
      );
      expect(validation.ok, isFalse);
      expect(validation.code, 'plan_integration_missing');
    });

    test('integration 传递依赖覆盖全部 code 任务后通过', () {
      final PlanValidation validation = validateAndFixPlan(
        tasks: <Map<String, Object?>>[
          task('T1'),
          task('T2', deps: <String>['T1']),
          task('T3', type: 'integration', deps: <String>['T2']),
        ],
        fix: false,
      );
      expect(validation.ok, isTrue);
    });
  });

  group('微任务合并与 fix 语义', () {
    test('只依赖 A 的单文件同写域微任务并入 A', () {
      final PlanValidation validation = validateAndFixPlan(
        tasks: <Map<String, Object?>>[
          task(
            'T1',
            write: <String>['lib/a'],
            acceptance: <String>['A 通过'],
            gate: <String, Object?>{
              'commands': <String>['dart test'],
            },
          ),
          task(
            'T2',
            deps: <String>['T1'],
            write: <String>['./lib/a/'],
            acceptance: <String>['B 通过'],
            lines: 10,
            gate: <String, Object?>{
              'commands': <String>['dart analyze'],
            },
          ),
        ],
      );
      expect(ids(validation), <String>['T1']);
      expect(validation.ok, isTrue);
      expect(
        validation.tasks.single['acceptance'],
        containsAll(<String>['A 通过', 'B 通过']),
      );
      final Map<String, Object?> gate = plainMap(
        validation.tasks.single['gate'],
      );
      expect(
        stringsOf(gate['commands']),
        containsAll(<String>['dart test', 'dart analyze']),
      );
      expect(
        validation.issues.where(
          (PlanIssue issue) => issue.code == 'plan_task_merged',
        ),
        isNotEmpty,
      );
    });

    test('A 还有其它依赖者时不合并', () {
      final PlanValidation validation = validateAndFixPlan(
        tasks: <Map<String, Object?>>[
          task('T1', write: <String>['lib/a']),
          task('T2', deps: <String>['T1'], write: <String>['lib/a'], lines: 10),
          task('T3', type: 'chore', deps: <String>['T1']),
        ],
      );
      expect(ids(validation), containsAll(<String>['T1', 'T2', 'T3']));
      expect(
        validation.issues.where(
          (PlanIssue issue) => issue.code == 'plan_task_merged',
        ),
        isEmpty,
      );
    });

    test('fix=false 返回原任务，不补默认字段', () {
      final Map<String, Object?> original = <String, Object?>{
        'id': 'T1',
        'title': '原样',
        'acceptance': <String>['有判据'],
        'gate': <String, Object?>{
          'commands': <String>['dart test'],
        },
        'estimated_files': 7,
      };
      final PlanValidation validation = validateAndFixPlan(
        tasks: <Map<String, Object?>>[original],
        fix: false,
      );
      expect(validation.tasks.single['estimated_files'], 7);
      expect(validation.tasks.single.containsKey('task_type'), isFalse);
      expect(validation.tasks.single.containsKey('estimated_lines'), isFalse);
      expect(validation.code, 'plan_task_oversize');
    });
  });
}
