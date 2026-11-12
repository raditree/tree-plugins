import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

LineRecord _line({
  String status = 'working',
  int maxParallel = 1,
  int retries = 2,
  Map<String, Object?> orchestrator = const <String, Object?>{},
}) => LineRecord(<String, Object?>{
  'id': 'pl_t',
  'name': '测试产线',
  'status': status,
  'limits': <String, Object?>{
    'max_parallel_tasks': maxParallel,
    'retries': retries,
  },
  'orchestrator': orchestrator,
});

TaskRecord _task(
  String id, {
  String status = 'queued',
  List<String> dependsOn = const <String>[],
  List<String> writeScope = const <String>['lib/a'],
  int attempts = 0,
  int askCount = 0,
  String stopReason = '',
  bool budgetExceeded = false,
  Map<String, Object?> usage = const <String, Object?>{},
}) => TaskRecord(<String, Object?>{
  'id': id,
  'title': id,
  'status': status,
  'depends_on': dependsOn,
  'write_scope': writeScope,
  'loop': <String, Object?>{
    'attempts': attempts,
    'ask_count': askCount,
    if (stopReason.isNotEmpty) 'stop_reason': stopReason,
  },
  if (budgetExceeded) 'budget_exceeded': true,
  if (usage.isNotEmpty) 'usage': usage,
});

void main() {
  group('主控配置（§4.1）', () {
    test('新建产线默认带 orchestrator 段；显式配置浅合并', () {
      final Map<String, Object?> defaults = buildLineMap(
        <String, Object?>{'name': 'x'},
        id: 'pl',
        now: 'now',
      );
      expect(defaults['orchestrator'], <String, Object?>{
        'enabled': true,
        'tick_interval_seconds': 5,
        'auto_retry': true,
        'max_asks_per_task': 3,
        'stop_on_budget': true,
        'max_ticks_per_minute': 12,
      });

      final Map<String, Object?> merged = buildLineMap(
        <String, Object?>{
          'name': 'x',
          'orchestrator': <String, Object?>{
            'enabled': false,
            'tick_interval_seconds': 0,
          },
        },
        id: 'pl',
        now: 'now',
      );
      final Map<String, Object?> orchestrator = plainMap(
        merged['orchestrator'],
      );
      expect(orchestrator['enabled'], isFalse);
      expect(orchestrator['tick_interval_seconds'], 0);
      expect(orchestrator['max_asks_per_task'], 3);
    });

    test('旧 line.yaml 缺 orchestrator ⇒ 默认配置', () {
      final OrchestratorConfig config = OrchestratorConfig.of(_line());
      expect(config.enabled, isTrue);
      expect(config.tickIntervalSeconds, 5);
      expect(config.autoRetry, isTrue);
      expect(config.maxAsksPerTask, 3);
      expect(config.stopOnBudget, isTrue);
      expect(config.maxTicksPerMinute, 12);
    });

    test('orchestrator 不是对象 ⇒ invalid_arguments（新建与 PATCH 同判据）', () {
      expect(
        () => buildLineMap(
          <String, Object?>{'name': 'x', 'orchestrator': true},
          id: 'pl',
          now: 'now',
        ),
        throwsA(
          isA<ProductionFailure>().having(
            (ProductionFailure error) => error.code,
            'code',
            'invalid_arguments',
          ),
        ),
      );
    });

    test('PATCH 接受 orchestrator 段（浅合并，其它键不动）', () {
      final Directory temp = Directory.systemTemp.createTempSync('pl_orch_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final ProductionStore store = ProductionStore(dataRoot: temp.path);
      store.createLine(<String, Object?>{'id': 'pl_t', 'name': '测试产线'});
      final LineRecord patched = store.updateLine('pl_t', <String, Object?>{
        'orchestrator': <String, Object?>{'tick_interval_seconds': 0},
      });
      expect(patched.orchestrator['tick_interval_seconds'], 0);
      expect(patched.orchestrator['enabled'], isTrue);
    });
  });

  group('task.loop（§4.2）', () {
    test('旧任务缺 loop ⇒ 0 / 空串，不猜默认动作', () {
      final TaskRecord task = TaskRecord(<String, Object?>{'id': 'T1'});
      expect(task.loopAttempts, 0);
      expect(task.askCount, 0);
      expect(task.lastAction, isEmpty);
      expect(task.pendingQuestion, isEmpty);
      expect(task.stopReason, isEmpty);
    });

    test('updateLoop 浅合并且保留未知键', () {
      final Directory temp = Directory.systemTemp.createTempSync('pl_loop_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final ProductionStore store = ProductionStore(dataRoot: temp.path);
      store.createLine(<String, Object?>{'id': 'pl_t', 'name': '测试产线'});
      store.createTask('pl_t', <String, Object?>{'title': '任务'});
      final String taskId = store.listTasks('pl_t').single.id;
      store.putTask('pl_t', taskId, <String, Object?>{
        'loop': <String, Object?>{'custom': 'keep'},
      });

      store.updateLoop('pl_t', taskId, <String, Object?>{
        'attempts': 1,
        'last_action': 'retry',
      });
      final TaskRecord task = store.getTask('pl_t', taskId);
      expect(task.loopAttempts, 1);
      expect(task.lastAction, 'retry');
      expect(task.loop['custom'], 'keep');
      // task.yaml 是唯一真值：rebuild 不丢 loop。
      store.rebuild('pl_t');
      expect(store.getTask('pl_t', taskId).loopAttempts, 1);
    });
  });

  group('快照（§5.1）', () {
    test('包含槽位 / 可派发 / 预算；哈希对等价输入稳定、状态变化即变', () {
      final LineRecord line = _line();
      final List<TaskRecord> tasks = <TaskRecord>[
        _task('T1', writeScope: const <String>['lib/a']),
        _task(
          'T2',
          writeScope: const <String>['lib/b'],
          usage: <String, Object?>{'prompt_tokens': 10, 'completion_tokens': 5},
        ),
      ];
      final OrchestratorSnapshot first = buildOrchestratorSnapshot(
        line: line,
        tasks: tasks,
        runs: const <Map<String, Object?>>[],
        inbox: const <Map<String, Object?>>[],
      );
      final OrchestratorSnapshot again = buildOrchestratorSnapshot(
        line: line,
        tasks: List<TaskRecord>.of(tasks.reversed),
        runs: const <Map<String, Object?>>[],
        inbox: const <Map<String, Object?>>[],
      );
      expect(first.hash, again.hash);
      expect(first.availableSlots, 1);
      expect(first.json['dispatchable'], <String>['T1']);
      expect(plainMap(first.json['budget'])['used_tokens'], 15);

      final OrchestratorSnapshot changed = buildOrchestratorSnapshot(
        line: line,
        tasks: <TaskRecord>[_task('T1', status: 'packed')],
        runs: const <Map<String, Object?>>[],
        inbox: const <Map<String, Object?>>[],
      );
      expect(changed.hash, isNot(first.hash));
    });

    test('last_run 只取最新一条并截断错误；pending_question 只认 execute', () {
      final LineRecord line = _line();
      final OrchestratorSnapshot snapshot = buildOrchestratorSnapshot(
        line: line,
        tasks: <TaskRecord>[_task('T1')],
        runs: <Map<String, Object?>>[
          <String, Object?>{
            'task_id': 'T1',
            'role': 'executor',
            'status': 'failed',
            'error': 'x' * 400,
            'started_at': '2026-11-12T00:00:02',
          },
          <String, Object?>{
            'task_id': 'T1',
            'role': 'packer',
            'status': 'ok',
            'started_at': '2026-11-12T00:00:01',
          },
        ],
        inbox: <Map<String, Object?>>[
          <String, Object?>{
            'type': 'question',
            'task_id': 'T1',
            'qid': 'Q1',
            'text': '准备阶段问题',
            'asked_at': '2026-11-12T00:00:00',
          },
          <String, Object?>{
            'type': 'question',
            'stage': 'execute',
            'task_id': 'T1',
            'qid': 'X1',
            'text': '运行期问题',
            'asked_at': '2026-11-12T00:00:01',
          },
        ],
      );
      final Map<String, Object?> lastRun = plainMap(snapshot.json['last_run']);
      expect(lastRun['role'], 'executor');
      expect(textOf(lastRun['error']).length, lessThanOrEqualTo(301));
      expect(plainMap(snapshot.json['pending_question'])['qid'], 'X1');
      expect(executeQuestionsOf(<Map<String, Object?>>[
        <String, Object?>{'type': 'question', 'qid': 'Q1', 'task_id': 'T1'},
      ]), isEmpty);
    });
  });

  group('动作解析（§5.2）', () {
    const Set<String> pool = <String>{'T1', 'T2'};

    test('合法 continue / stop(line) 解析成功', () {
      final OrchestratorDecision decision = parseOrchestratorDecision(
        <String, Object?>{
          'action': 'continue',
          'reason': 'T1 依赖已满足',
          'task_ids': <String>['T1'],
        },
        taskIds: pool,
      );
      expect(decision.action, 'continue');
      expect(decision.taskIds, <String>['T1']);
      expect(decision.applied, isTrue);

      final OrchestratorDecision stop = parseOrchestratorDecision(
        <String, Object?>{
          'action': 'stop',
          'reason': '整线暂停',
          'stop_scope': 'line',
        },
        taskIds: pool,
      );
      expect(stop.stopScope, 'line');
      expect(stop.taskIds, isEmpty);
    });

    test('未知动作 / 缺理由 / 池外任务 / ask 缺问题 整条作废', () {
      void expectCode(Object? raw, String code) {
        expect(
          () => parseOrchestratorDecision(raw, taskIds: pool),
          throwsA(
            isA<ProductionFailure>().having(
              (ProductionFailure error) => error.code,
              'code',
              code,
            ),
          ),
        );
      }

      expectCode(
        <String, Object?>{'action': 'jump', 'reason': 'x'},
        'orchestrator_bad_action',
      );
      expectCode(
        <String, Object?>{'action': 'continue', 'task_ids': <String>['T1']},
        'orchestrator_bad_reason',
      );
      expectCode(
        <String, Object?>{
          'action': 'continue',
          'reason': 'x',
          'task_ids': <String>['T9'],
        },
        'orchestrator_unknown_task',
      );
      expectCode(
        <String, Object?>{
          'action': 'ask',
          'reason': 'x',
          'task_ids': <String>['T1'],
          'question': <String, Object?>{'text': ''},
        },
        'orchestrator_bad_question',
      );
      expectCode(
        <String, Object?>{'action': 'stop', 'reason': 'x'},
        'orchestrator_bad_action',
      );
      expectCode('continue', 'orchestrator_bad_action');
    });
  });

  group('护栏（§3.3）', () {
    OrchestratorDecision guard(
      OrchestratorDecision decision, {
      LineRecord? line,
      List<TaskRecord>? tasks,
      bool budgetExceeded = false,
      OrchestratorConfig config = const OrchestratorConfig(),
    }) => guardOrchestratorDecision(
      decision,
      config: config,
      line: line ?? _line(),
      tasks: tasks ?? <TaskRecord>[_task('T1')],
      budgetExceeded: budgetExceeded,
    );

    OrchestratorDecision decision(
      String action, {
      List<String> taskIds = const <String>['T1'],
      String stopScope = 'task',
    }) => OrchestratorDecision(
      action: action,
      reason: 'r',
      taskIds: taskIds,
      stopScope: stopScope,
    );

    test('整线 paused ⇒ 任何动作都不执行', () {
      final OrchestratorDecision out = guard(
        decision('continue'),
        line: _line(status: 'paused'),
      );
      expect(out.applied, isFalse);
      expect(out.guard, 'line_paused');
    });

    test('预算到点：continue/retry 降级为 stop；stop_on_budget=false 则不生效', () {
      final OrchestratorDecision out = guard(
        decision('continue'),
        budgetExceeded: true,
      );
      expect(out.action, 'stop');
      expect(out.guard, 'budget_exceeded');
      expect(out.applied, isTrue);

      final OrchestratorDecision off = guard(
        decision('retry'),
        budgetExceeded: true,
        config: const OrchestratorConfig(stopOnBudget: false),
      );
      expect(off.applied, isFalse);
      expect(off.guard, 'budget_exceeded');
    });

    test('提问次数问满 ⇒ 只能 stop', () {
      final OrchestratorDecision out = guard(
        decision('ask'),
        tasks: <TaskRecord>[_task('T1', askCount: 3)],
      );
      expect(out.action, 'stop');
      expect(out.guard, 'ask_limit');
    });

    test('retry 超过上限 / auto_retry 关闭 ⇒ 不生效', () {
      final OrchestratorDecision over = guard(
        decision('retry'),
        tasks: <TaskRecord>[
          _task('T1', status: 'blocked', attempts: 2),
        ],
      );
      expect(over.applied, isFalse);
      expect(over.guard, 'retry_limit');

      final OrchestratorDecision off = guard(
        decision('retry'),
        tasks: <TaskRecord>[_task('T1', status: 'blocked')],
        config: const OrchestratorConfig(autoRetry: false),
      );
      expect(off.applied, isFalse);
      expect(off.guard, 'auto_retry_disabled');
    });

    test('continue 不越依赖 / 写域 / 并行槽位；packed 可直接继续执行', () {
      final OrchestratorDecision deps = guard(
        decision('continue', taskIds: const <String>['T2']),
        tasks: <TaskRecord>[
          _task('T1', status: 'running', writeScope: const <String>['lib/a']),
          _task(
            'T2',
            dependsOn: const <String>['T1'],
            writeScope: const <String>['lib/b'],
          ),
        ],
        line: _line(maxParallel: 2),
      );
      expect(deps.applied, isFalse);
      expect(deps.guard, 'depends_on');

      final OrchestratorDecision overlap = guard(
        decision('continue', taskIds: const <String>['T2']),
        tasks: <TaskRecord>[
          _task('T1', status: 'running', writeScope: const <String>['lib/a']),
          _task('T2', writeScope: const <String>['lib/a']),
        ],
        line: _line(maxParallel: 2),
      );
      expect(overlap.applied, isFalse);
      expect(overlap.guard, 'write_scope_overlap');

      final OrchestratorDecision slots = guard(
        decision('continue', taskIds: const <String>['T2']),
        tasks: <TaskRecord>[
          _task('T1', status: 'running', writeScope: const <String>['lib/a']),
          _task('T2', writeScope: const <String>['lib/b']),
        ],
      );
      expect(slots.applied, isFalse);
      expect(slots.guard, 'max_parallel');

      final OrchestratorDecision packed = guard(
        decision('continue'),
        tasks: <TaskRecord>[_task('T1', status: 'packed')],
      );
      expect(packed.applied, isTrue);
      expect(packed.taskIds, <String>['T1']);
    });

    test('stop 终态任务 ⇒ 不生效', () {
      final OrchestratorDecision out = guard(
        decision('stop'),
        tasks: <TaskRecord>[_task('T1', status: 'done')],
      );
      expect(out.applied, isFalse);
      expect(out.guard, 'no_target');
    });
  });

  group('提示词（§5.3）', () {
    test('系统提示词含四段与硬数字；用户提示词带快照 JSON', () {
      final String system = orchestratorSystemPrompt(
        config: const OrchestratorConfig(),
        limits: <String, Object?>{
          'retries': 2,
          'max_parallel_tasks': 1,
        },
      );
      expect(system, contains('角色'));
      expect(system, contains('边界'));
      expect(system, contains('输出契约'));
      expect(system, contains('limits.retries=2'));

      final OrchestratorSnapshot snapshot = buildOrchestratorSnapshot(
        line: _line(),
        tasks: <TaskRecord>[_task('T1')],
        runs: const <Map<String, Object?>>[],
        inbox: const <Map<String, Object?>>[],
      );
      final String user = orchestratorUserPrompt(snapshot);
      expect(user, contains('"available_slots"'));
      expect(user, contains('T1'));
    });
  });
}
