import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

import 'support/structure_fixture.dart';

/// 假主控模型：按 [replies] 顺序回包；[gate] 非空时先等它放行（并发测试）。
class _Llm {
  final List<Map<String, Object?>> replies = <Map<String, Object?>>[];
  final List<String> prompts = <String>[];
  final List<String> modelIds = <String>[];
  Completer<void>? gate;
  Object? error;

  Future<Map<String, Object?>> call(
    String point,
    String system,
    String prompt,
    Map<String, Object?> scope,
    String modelId,
  ) async {
    prompts.add(prompt);
    modelIds.add(modelId);
    final Completer<void>? waiting = gate;
    if (waiting != null) await waiting.future;
    if (error != null) throw error!;
    if (replies.isEmpty) {
      throw StateError('没有更多假回包');
    }
    return replies.removeAt(0);
  }
}

/// 假派发器：只记录，不改任务状态（幂等 / 锁测试依赖这一点）。
class _Dispatcher {
  final List<String> calls = <String>[];

  Future<void> dispatch(
    String lineId,
    String taskId,
    String stage,
    Map<String, Object?> meta,
    Map<String, Object?> scope,
  ) async {
    calls.add('$lineId/$taskId/$stage');
  }
}

void main() {
  late Directory temp;
  late String workspace;
  late ProductionStore store;
  late _Llm llm;
  late _Dispatcher dispatcher;
  late ProductionExecutionService execution;
  late OrchestratorService orchestrator;
  late DateTime now;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tree_production_orch_');
    workspace = '${temp.path}${Platform.pathSeparator}ws';
    Directory(workspace).createSync(recursive: true);
    store = ProductionStore(dataRoot: temp.path);
    llm = _Llm();
    dispatcher = _Dispatcher();
    now = DateTime.parse('2026-11-12T00:00:00');
    execution = ProductionExecutionService(
      environment: const <String, String>{},
      clock: () => now,
    );
    orchestrator = OrchestratorService(
      environment: const <String, String>{},
      clock: () => now,
      llm: llm.call,
      dispatcher: dispatcher.dispatch,
      execution: execution,
    );
    store.createLine(<String, Object?>{
      'id': 'pl_t',
      'name': '测试产线',
      'workspace_dir': workspace,
      'limits': <String, Object?>{
        'max_parallel_tasks': 1,
        'retries': 2,
      },
      'roles': <String, Object?>{
        'orchestrator': <String, Object?>{'model_id': 'chat/main'},
        'packer': <String, Object?>{'model_id': 'chat/main'},
        'executor': <String, Object?>{'model_id': 'chat/main'},
      },
      'orchestrator': <String, Object?>{
        'max_ticks_per_minute': 100,
      },
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
  ) => orchestrator.handle(
    command,
    arguments,
    <String, Object?>{'data_dir': temp.path},
    <String, Object?>{'team_id': 'team_a', 'agent_id': 'agt'},
  );

  Future<Map<String, Object?>> tick({String trigger = 'manual'}) => call(
    'production.orchestrator.tick',
    <String, Object?>{'line_id': 'pl_t', 'trigger': trigger},
  );

  void task(
    String id, {
    String status = 'queued',
    List<String> writeScope = const <String>['lib/a'],
    int attempts = 0,
    int askCount = 0,
    String stopReason = '',
    Map<String, Object?> usage = const <String, Object?>{},
  }) {
    store.createTask('pl_t', <String, Object?>{
      'id': id,
      'title': id,
      'status': 'queued',
      'write_scope': writeScope,
    });
    if (status != 'queued') {
      const List<String> chain = <String>[
        'packing',
        'packed',
        'running',
        'gating',
        'done',
      ];
      for (final String to in chain) {
        store.transition('pl_t', id, to: to, reason: '夹具');
        if (to == status) break;
      }
      expect(store.getTask('pl_t', id).status.wire, status);
    }
    final Map<String, Object?> patch = <String, Object?>{
      'loop': <String, Object?>{
        'attempts': attempts,
        'ask_count': askCount,
        if (stopReason.isNotEmpty) 'stop_reason': stopReason,
      },
      if (usage.isNotEmpty) 'usage': usage,
    };
    store.putTask('pl_t', id, patch);
  }

  test('continue：按快照派发打包，台账 + 游标都落盘', () async {
    task('T1');
    llm.replies.add(<String, Object?>{
      'action': 'continue',
      'reason': 'T1 可打包',
      'task_ids': <String>['T1'],
    });
    final Map<String, Object?> result = await tick();
    expect(result['status'], 'applied');
    expect(result['action'], 'continue');
    expect(result['applied_tasks'], <String>['T1']);
    expect(dispatcher.calls, <String>['pl_t/T1/pack']);
    expect(store.getTask('pl_t', 'T1').lastAction, 'continue');

    final List<Map<String, Object?>> runs = store.listRuns('pl_t');
    expect(runs.single['role'], 'orchestrator');
    expect(runs.single['action'], 'continue');
    expect(runs.single['applied'], isTrue);
    expect(runs.single['snapshot_hash'], isNotEmpty);

    final Map<String, Object?> state = store.readOrchestratorState('pl_t');
    expect(state['last_action'], 'continue');
    expect(state['consecutive_failures'], 0);

    final Map<String, Object?> status = await call(
      'production.orchestrator.status',
      <String, Object?>{'line_id': 'pl_t'},
    );
    expect(plainMap(status['last_decision'])['action'], 'continue');
    expect((status['last_runs'] as List<dynamic>).length, 1);
  });

  test('定时 tick：快照没变就不调模型；有在途任务才检查', () async {
    task('T1', status: 'packed');
    llm.replies.add(<String, Object?>{
      'action': 'continue',
      'reason': '执行 T1',
      'task_ids': <String>['T1'],
    });
    await tick();
    expect(llm.prompts.length, 1);
    final Map<String, Object?> again = await tick(trigger: 'timer');
    expect(again['status'], 'skipped');
    expect(again['reason'], 'unchanged');
    expect(llm.prompts.length, 1);
    expect(dispatcher.calls, <String>['pl_t/T1/run']);

    // 没有在途任务：定时 tick 直接 idle，不调模型。
    store.transition('pl_t', 'T1', to: 'running', reason: '夹具');
    store.transition('pl_t', 'T1', to: 'gating', reason: '夹具');
    store.transition('pl_t', 'T1', to: 'done', reason: '夹具');
    final Map<String, Object?> idle = await tick(trigger: 'timer');
    expect(idle['reason'], 'idle');
    expect(llm.prompts.length, 1);
  });

  test('定时 tick：有 queued 任务时正常决策（不再因无在途任务跳过）', () async {
    task('T1');
    llm.replies.add(<String, Object?>{
      'action': 'continue',
      'reason': 'T1 可打包',
      'task_ids': <String>['T1'],
    });
    final Map<String, Object?> result = await tick(trigger: 'timer');
    expect(result['status'], 'applied');
    expect(result['trigger'], 'timer');
    expect(result['applied_tasks'], <String>['T1']);
    expect(dispatcher.calls, <String>['pl_t/T1/pack']);
    expect(llm.prompts.length, 1);
  });

  test('产线状态由后端投影：queued/在途=working，paused 优先，空线=idle', () async {
    final ProductionService service = ProductionService(
      environment: const <String, String>{},
      clock: () => now,
    );
    Map<String, Object?> lineGet() => plainMap(
      service.handle(
        'production.line.get',
        <String, Object?>{'line_id': 'pl_t'},
        <String, Object?>{'data_dir': temp.path},
        <String, Object?>{},
      )['line'],
    );

    expect(lineGet()['status'], 'idle', reason: '没有任务 = 空闲');
    task('T1');
    expect(lineGet()['status'], 'working', reason: 'queued 任务 = 执行中');
    final Map<String, Object?> list = service.handle(
      'production.line.list',
      <String, Object?>{},
      <String, Object?>{'data_dir': temp.path},
      <String, Object?>{},
    );
    expect(
      plainMap((list['lines'] as List<dynamic>).single)['status'],
      'working',
    );
    final Map<String, Object?> orchStatus = await call(
      'production.orchestrator.status',
      <String, Object?>{'line_id': 'pl_t'},
    );
    expect(orchStatus['status'], 'working');

    // 走到终态：没有可推进任务 ⇒ idle。
    for (final String to in <String>[
      'packing',
      'packed',
      'running',
      'gating',
      'done',
    ]) {
      store.transition('pl_t', 'T1', to: to, reason: '夹具');
    }
    expect(lineGet()['status'], 'idle');

    // 暂停优先于其它一切。
    store.updateLine('pl_t', <String, Object?>{'status': 'paused'});
    expect(lineGet()['status'], 'paused');
  });

  test('单线单 tick：已有 tick 在跑时新触发直接丢弃', () async {
    task('T1');
    llm.gate = Completer<void>();
    llm.replies.add(<String, Object?>{
      'action': 'continue',
      'reason': 'T1',
      'task_ids': <String>['T1'],
    });
    final Future<Map<String, Object?>> first = tick();
    final Map<String, Object?> second = await tick();
    expect(second['status'], 'skipped');
    expect(second['reason'], 'tick_in_flight');
    llm.gate!.complete();
    final Map<String, Object?> done = await first;
    expect(done['status'], 'applied');
  });

  test('stop：单任务可恢复；整线停止写 line.status=paused', () async {
    task('T1');
    llm.replies.add(<String, Object?>{
      'action': 'stop',
      'reason': '先停 T1',
      'task_ids': <String>['T1'],
      'stop_scope': 'task',
    });
    final Map<String, Object?> stopped = await tick();
    expect(stopped['status'], 'applied');
    final TaskRecord blocked = store.getTask('pl_t', 'T1');
    expect(blocked.status, TaskStatus.blocked);
    expect(blocked.blockedReason, 'orchestrator_stop');
    expect(blocked.stopReason, 'orchestrator_stop');
    // 用户恢复：blocked → queued（状态机既有边）。
    store.transition('pl_t', 'T1', to: 'queued', reason: '用户恢复');

    llm.replies.add(<String, Object?>{
      'action': 'stop',
      'reason': '整线暂停',
      'stop_scope': 'line',
    });
    await tick();
    expect(store.getLine('pl_t').status, 'paused');
    final Map<String, Object?> paused = await tick();
    expect(paused['reason'], 'line_paused');
  });

  test('护栏：continue 越写域 / 并行 ⇒ 整条不生效并记 guard', () async {
    task('T1', status: 'running', writeScope: const <String>['lib/a']);
    task('T2', writeScope: const <String>['lib/a']);
    llm.replies.add(<String, Object?>{
      'action': 'continue',
      'reason': '并行 T2',
      'task_ids': <String>['T2'],
    });
    final Map<String, Object?> result = await tick();
    expect(result['status'], 'noop');
    expect(result['guard'], 'write_scope_overlap');
    expect(dispatcher.calls, isEmpty);
    final List<Map<String, Object?>> runs = store.listRuns('pl_t');
    expect(runs.single['status'], 'guarded');
    expect(runs.single['applied'], isFalse);
    expect(runs.single['guard'], 'write_scope_overlap');
  });

  test('预算到点：continue 降级为 stop，不烧下一次调用', () async {
    store.updateLine('pl_t', <String, Object?>{
      'limits': <String, Object?>{'max_tokens_per_task': 10},
    });
    task('T1', usage: <String, Object?>{
      'prompt_tokens': 6,
      'completion_tokens': 4,
    });
    llm.replies.add(<String, Object?>{
      'action': 'continue',
      'reason': '继续',
      'task_ids': <String>['T1'],
    });
    final Map<String, Object?> result = await tick();
    expect(result['action'], 'stop');
    expect(result['guard'], 'budget_exceeded');
    expect(dispatcher.calls, isEmpty);
    expect(store.getTask('pl_t', 'T1').status, TaskStatus.blocked);
  });

  test('retry：blocked → queued 并重新打包；超过上限不生效', () async {
    task('T1');
    // 走真实失败路径：打包失败 → blocked。
    store.transition('pl_t', 'T1', to: 'packing', reason: '夹具');
    store.transition('pl_t', 'T1', to: 'blocked', reason: '打包失败');
    llm.replies.add(<String, Object?>{
      'action': 'retry',
      'reason': '再试一次',
      'task_ids': <String>['T1'],
    });
    final Map<String, Object?> result = await tick();
    expect(result['status'], 'applied');
    expect(store.getTask('pl_t', 'T1').status, TaskStatus.queued);
    expect(store.getTask('pl_t', 'T1').loopAttempts, 1);
    expect(dispatcher.calls, <String>['pl_t/T1/pack']);

    // 到上限：attempts=2 / retries=2 ⇒ 不再重试。
    store.putTask('pl_t', 'T1', <String, Object?>{
      'loop': <String, Object?>{'attempts': 2},
    });
    store.transition('pl_t', 'T1', to: 'packing', reason: '夹具');
    store.transition('pl_t', 'T1', to: 'blocked', reason: '又失败');
    llm.replies.add(<String, Object?>{
      'action': 'retry',
      'reason': '再试',
      'task_ids': <String>['T1'],
    });
    final Map<String, Object?> over = await tick();
    expect(over['status'], 'noop');
    expect(over['guard'], 'retry_limit');
  });

  test('ask：主控提问 → blocked(question_pending)，回答后回 queued', () async {
    task('T1');
    llm.replies.add(<String, Object?>{
      'action': 'ask',
      'reason': '信息不足',
      'task_ids': <String>['T1'],
      'question': <String, Object?>{
        'text': '旧行为要保留吗？',
        'options': <String>['保留', '改掉'],
      },
    });
    final Map<String, Object?> result = await tick();
    expect(result['status'], 'applied');
    final TaskRecord blocked = store.getTask('pl_t', 'T1');
    expect(blocked.status, TaskStatus.blocked);
    expect(blocked.blockedReason, 'question_pending');
    expect(blocked.pendingQuestion, 'X1');
    expect(blocked.askCount, 1);

    final Map<String, Object?> listed = await execution.handle(
      'production.task.questions',
      <String, Object?>{'line_id': 'pl_t', 'task_id': 'T1'},
      <String, Object?>{'data_dir': temp.path},
      <String, Object?>{},
    );
    expect(listed['open'], 1);
    await execution.handle(
      'production.task.answer',
      <String, Object?>{
        'line_id': 'pl_t',
        'task_id': 'T1',
        'value': '保留',
      },
      <String, Object?>{'data_dir': temp.path},
      <String, Object?>{},
    );
    expect(store.getTask('pl_t', 'T1').status, TaskStatus.queued);
  });

  test('连续 3 次坏回包 ⇒ 暂停产线；不再静默继续', () async {
    task('T1');
    for (int i = 0; i < 3; i++) {
      llm.replies.add(<String, Object?>{
        'action': 'jump',
        'reason': '非法动作',
        'task_ids': <String>['T1'],
      });
      final Map<String, Object?> result = await tick();
      expect(result['status'], 'failed');
      expect(result['consecutive_failures'], i + 1);
    }
    expect(store.getLine('pl_t').status, 'paused');
    final Map<String, Object?> blocked = await tick();
    expect(blocked['reason'], 'line_paused');
  });

  test('模型缺失 / 调用异常走同一失败路径（不降级自动继续）', () async {
    task('T1');
    store.updateLine('pl_t', <String, Object?>{
      'roles': <String, Object?>{
        'orchestrator': <String, Object?>{'model_id': ''},
      },
    });
    final Map<String, Object?> noModel = await tick();
    expect(noModel['status'], 'failed');
    expect(noModel['error'], contains('roles.orchestrator.model_id'));

    store.updateLine('pl_t', <String, Object?>{
      'roles': <String, Object?>{
        'orchestrator': <String, Object?>{'model_id': 'chat/main'},
      },
    });
    llm.error = StateError('上游 502');
    final Map<String, Object?> failed = await tick();
    expect(failed['status'], 'failed');
    expect(failed['consecutive_failures'], 2);
    expect(dispatcher.calls, isEmpty);
  });

  test('enabled=false ⇒ 不决策；max_ticks_per_minute 是硬上限', () async {
    task('T1');
    store.updateLine('pl_t', <String, Object?>{
      'orchestrator': <String, Object?>{'enabled': false},
    });
    final Map<String, Object?> disabled = await tick();
    expect(disabled['reason'], 'disabled');
    expect(llm.prompts, isEmpty);

    store.updateLine('pl_t', <String, Object?>{
      'orchestrator': <String, Object?>{
        'enabled': true,
        'max_ticks_per_minute': 1,
      },
    });
    llm.replies.add(<String, Object?>{
      'action': 'continue',
      'reason': 'T1',
      'task_ids': <String>['T1'],
    });
    final Map<String, Object?> first = await tick();
    expect(first['status'], 'applied');
    final Map<String, Object?> limited = await tick();
    expect(limited['status'], 'skipped');
    expect(limited['reason'], 'rate_limited');
    expect(llm.prompts.length, 1);
  });
}
