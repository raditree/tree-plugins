// tree.production.line —— 标准开发流生产线（P1：数据模型 + 队列）。
//
// 定位（docs/pluginization/production-line-recon.md §7/§10/§11）：
// - headless 插件，granularity=team；数据只落 `<data_root>/production_lines/<team_id>/`；
// - `task.yaml` 是唯一真值，`state.json` 只是可由它重建的队列索引；
// - 状态机、队列排序、依赖判据、in-flight 崩溃恢复都在领域库，入口只做协议面；
// - 依赖纪律：不得 import 任何核心包。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tree_production_line/tree_production_line.dart';

import '../_kit/plugin_kit.dart';

const String kPluginId = 'tree.production.line';
const String kDisplayName = 'Tree 标准开发流生产线';
const String kVersion = '0.1.0';

const String kStationName = 'production';
const String kStationReadme =
    '生产线 P1：production.line.create/list/get、production.task.create/list/get/'
    'transition、production.queue.next/rebuild/recover、production.run.list。'
    '数据落 `<data_root>/production_lines/<team_id>/<line_id>/`：line.yaml / '
    'tasks/<task_id>/task.yaml / runs/<run_id>.json / state.json；task.yaml 为唯一真值，'
    'state.json 可由它重建。状态机：draft→recon→aligning→scoped→queued→packing→packed→'
    'running→gating→done；aligning↔awaiting_user；gating→packed（重试）；'
    'queued/packing/packed/running/gating→blocked；blocked→awaiting_user|queued；'
    'cancelled 可从任意非终态进入。崩溃恢复：in-flight → queued 并追加一条 '
    'status=interrupted 的 run，重复 recover 0 写。';

final ProductionService _service = ProductionService();

PluginKitServer buildServer({bool exitOnShutdown = true}) => PluginKitServer(
  channel: PluginChannel.stdio(kPluginId),
  pluginId: kPluginId,
  displayName: kDisplayName,
  onReady: _onReady,
  onRequest: handleRequest,
  exitOnShutdown: exitOnShutdown,
);

Future<void> _onReady(PluginKitServer server) async {
  server.channel.log('已上线：v$kVersion（tree.production.line，P1 数据模型 + 队列）');
  try {
    final Map<String, dynamic> result = await server.channel.request(
      M.stationRegister,
      <String, dynamic>{
        'kind': 'execute',
        'name': kStationName,
        'description': '生产线数据模型与队列（production.*）',
        'readme': kStationReadme,
        'commands': kProductionCommands,
      },
    );
    server.channel.log(
      '自建执行站：${result['ok'] == true ? result['station_id'] : result['error']}',
    );
  } catch (error) {
    server.channel.log('自建执行站失败：$error');
  }
}

Future<Map<String, dynamic>?> handleRequest(
  String method,
  Map<String, dynamic> params,
) async {
  if (method != M.stationRequest) return null;
  final Map<String, dynamic> payload = asMap(params['payload']);
  final String command = asString(payload['command']);
  if (!kProductionCommands.contains(command)) return null;
  try {
    final Map<String, Object?> result = _service.handle(
      command,
      asMap(payload['arguments']),
      asMap(params['meta']),
      asMap(params['scope']),
    );
    return <String, dynamic>{
      'reply': <String, dynamic>{'payload': result},
    };
  } on ProductionFailure catch (error) {
    return <String, dynamic>{
      'reply': <String, dynamic>{'error': error.message, 'code': error.code},
    };
  } catch (error) {
    return <String, dynamic>{
      'reply': <String, dynamic>{
        'error': '产线命令执行失败：$error',
        'code': 'production_error',
      },
    };
  }
}

Future<void> main(List<String> args) async {
  if (args.contains('--selftest')) {
    // 自检输出走 stderr："stdout 只有协议帧"这条铁律不因模式而变。
    exitCode = await selfTest();
    return;
  }
  await buildServer().run(stdin);
  try {
    await stdout.flush();
  } catch (_) {
    // 管道已被对端关掉（核心退出）：刷不出去不算错误。
  }
}

/// 假核心自检（同码跑真读循环）：注册面 + fail-closed + 状态机 + 队列 + 恢复 + 重建。
Future<int> selfTest() async {
  final SelfTest check = SelfTest(name: 'tree_production_line_plugin');
  final Directory temp = Directory.systemTemp.createTempSync(
    'tree_production_line_selftest_',
  );
  final FakeCore core = FakeCore(buildServer(exitOnShutdown: false));
  core.onMethod(
    M.stationRegister,
    (Map<String, dynamic> params) => <String, dynamic>{
      'ok': true,
      'station_id': 'production',
    },
  );

  Future<Map<String, dynamic>> call(
    Object id,
    String command,
    Map<String, Object?> arguments, {
    String? team = 'team_a',
    bool withData = true,
  }) async {
    core.ask(id, M.stationRequest, <String, dynamic>{
      'payload': <String, dynamic>{
        'command': command,
        'arguments': arguments,
      },
      'meta': <String, dynamic>{
        'source_plugin_id': kPluginId,
        if (withData) 'data_dir': temp.path,
      },
      'scope': <String, dynamic>{'team_id': ?team},
    });
    final Map<Object?, Map<String, dynamic>> responses = await core.waitFor(
      <Object?>[id],
    );
    final Map<String, dynamic> frame = responses[id] ?? <String, dynamic>{};
    return asMap(asMap(frame['result'])['reply']);
  }

  Map<String, dynamic> payloadOf(Map<String, dynamic> reply) =>
      asMap(reply['payload']);

  final String lineRoot = <String>[
    temp.path,
    'production_lines',
    'team_a',
    'pl_demo',
  ].join(Platform.pathSeparator);

  try {
    unawaited(core.start());
    core.ask('hello', M.hello, <String, dynamic>{'plugin_id': kPluginId});
    await core.waitFor(<Object?>['hello']);

    check.check(
      core.outgoing(M.stationRegister).length,
      1,
      '启动后注册执行站',
    );

    // 数据根 / 团队 fail-closed。
    final Map<String, dynamic> noData = await call(
      'no-data',
      'production.line.list',
      <String, Object?>{},
      withData: false,
    );
    check.check(noData['code'], 'missing_data_dir', '缺 data_dir ⇒ missing_data_dir');
    final Map<String, dynamic> noTeam = await call(
      'no-team',
      'production.line.list',
      <String, Object?>{},
      team: null,
    );
    check.check(noTeam['code'], 'team_required', '缺 team_id ⇒ team_required');

    // 产线：建 / 列 / 查 + 落盘。
    final Map<String, dynamic> created = await call(
      'line-create',
      'production.line.create',
      <String, Object?>{'id': 'pl_demo', 'name': '标准开发流'},
    );
    check.check(asMap(payloadOf(created)['line'])['id'], 'pl_demo', '建产线');
    final Map<String, dynamic> listed = await call(
      'line-list',
      'production.line.list',
      <String, Object?>{},
    );
    check.check(payloadOf(listed)['count'], 1, '产线列表 1 条');
    final Map<String, dynamic> fetched = await call(
      'line-get',
      'production.line.get',
      <String, Object?>{'line_id': 'pl_demo'},
    );
    check.check(
      asMap(payloadOf(fetched)['line'])['name'],
      '标准开发流',
      '产线详情',
    );
    check.that(
      File('$lineRoot${Platform.pathSeparator}line.yaml').existsSync(),
      'line.yaml 落盘',
    );
    check.that(
      File('$lineRoot${Platform.pathSeparator}inbox.jsonl').existsSync(),
      'inbox.jsonl 落盘',
    );
    final Map<String, dynamic> missingLine = await call(
      'line-missing',
      'production.line.get',
      <String, Object?>{'line_id': 'pl_nope'},
    );
    check.check(missingLine['code'], 'not_found', '缺产线 ⇒ not_found');

    // 任务：A(p10) ← B(p50) 依赖 A；C(p50) 独立。
    await call('task-a', 'production.task.create', <String, Object?>{
      'line_id': 'pl_demo',
      'task': <String, Object?>{
        'id': 'A',
        'title': '底座',
        'status': 'queued',
        'priority': 10,
      },
    });
    await call('task-b', 'production.task.create', <String, Object?>{
      'line_id': 'pl_demo',
      'task': <String, Object?>{
        'id': 'B',
        'title': '依赖 A',
        'status': 'queued',
        'priority': 50,
        'depends_on': <String>['A'],
      },
    });
    await call('task-c', 'production.task.create', <String, Object?>{
      'line_id': 'pl_demo',
      'task': <String, Object?>{
        'id': 'C',
        'title': '独立',
        'status': 'queued',
        'priority': 50,
      },
    });
    check.that(
      File(
        '$lineRoot${Platform.pathSeparator}tasks${Platform.pathSeparator}A'
        '${Platform.pathSeparator}task.yaml',
      ).existsSync(),
      'task.yaml 落盘',
    );

    final Map<String, dynamic> nextPayload = payloadOf(
      await call('queue-next', 'production.queue.next', <String, Object?>{
        'line_id': 'pl_demo',
      }),
    );
    check.check(
      asMap((nextPayload['tasks'] as List<dynamic>).first)['id'],
      'C',
      '队列先派无依赖的 C（B 等 A）',
    );
    check.check(
      asMap((nextPayload['skipped'] as List<dynamic>).first)['id'],
      'B',
      'B 因依赖被跳过',
    );
    check.check(
      nextPayload['queue'],
      <String>['B', 'C', 'A'],
      '队列按 priority / created_at / id 排序',
    );

    // 非法迁移与 blocked 理由。
    final Map<String, dynamic> illegal = await call(
      'illegal',
      'production.task.transition',
      <String, Object?>{
        'line_id': 'pl_demo',
        'task_id': 'A',
        'to': 'done',
      },
    );
    check.check(illegal['code'], 'invalid_transition', 'queued → done 非法');
    final Map<String, dynamic> noReason = await call(
      'blocked-no-reason',
      'production.task.transition',
      <String, Object?>{
        'line_id': 'pl_demo',
        'task_id': 'A',
        'to': 'blocked',
      },
    );
    check.check(noReason['code'], 'reason_required', 'blocked 必须带理由');
    await call('blocked', 'production.task.transition', <String, Object?>{
      'line_id': 'pl_demo',
      'task_id': 'A',
      'to': 'blocked',
      'reason': '等拍板',
    });
    await call('unblocked', 'production.task.transition', <String, Object?>{
      'line_id': 'pl_demo',
      'task_id': 'A',
      'to': 'queued',
    });

    // A 走完整链到 done。
    for (final String to in <String>[
      'packing',
      'packed',
      'running',
      'gating',
      'done',
    ]) {
      final Map<String, dynamic> reply = await call(
        'a-$to',
        'production.task.transition',
        <String, Object?>{'line_id': 'pl_demo', 'task_id': 'A', 'to': to},
      );
      check.check(
        asMap(payloadOf(reply)['task'])['status'],
        to,
        'A → $to',
      );
    }
    final Map<String, dynamic> afterDone = payloadOf(
      await call('queue-next-2', 'production.queue.next', <String, Object?>{
        'line_id': 'pl_demo',
      }),
    );
    check.check(
      asMap((afterDone['tasks'] as List<dynamic>).first)['id'],
      'B',
      'A 完成后 B 可派发',
    );

    // 崩溃恢复：C 卡在 packing → 回 queued + 一条 interrupted 台账，重复 0 写。
    await call('c-packing', 'production.task.transition', <String, Object?>{
      'line_id': 'pl_demo',
      'task_id': 'C',
      'to': 'packing',
    });
    final Map<String, dynamic> recovered = payloadOf(
      await call('recover', 'production.queue.recover', <String, Object?>{
        'line_id': 'pl_demo',
      }),
    );
    check.check(recovered['count'], 1, '恢复 1 个 in-flight');
    final Map<String, dynamic> recoveredAgain = payloadOf(
      await call('recover-2', 'production.queue.recover', <String, Object?>{
        'line_id': 'pl_demo',
      }),
    );
    check.check(recoveredAgain['count'], 0, '重复 recover 0 写');
    final Map<String, dynamic> runs = payloadOf(
      await call('runs', 'production.run.list', <String, Object?>{
        'line_id': 'pl_demo',
      }),
    );
    check.check(runs['count'], 1, 'interrupted run 落台账');
    check.check(
      asMap((runs['runs'] as List<dynamic>).first)['status'],
      'interrupted',
      'run 状态 = interrupted',
    );
    final Map<String, dynamic> cTask = payloadOf(
      await call('c-get', 'production.task.get', <String, Object?>{
        'line_id': 'pl_demo',
        'task_id': 'C',
      }),
    );
    check.check(asMap(cTask['task'])['status'], 'queued', 'C 已回 queued');

    // 索引：损坏后重建一次，第二次 0 写。
    final File stateFile = File(
      '$lineRoot${Platform.pathSeparator}state.json',
    );
    stateFile.writeAsStringSync('{"broken": true}');
    final Map<String, dynamic> rebuilt = payloadOf(
      await call('rebuild', 'production.queue.rebuild', <String, Object?>{
        'line_id': 'pl_demo',
      }),
    );
    check.check(rebuilt['changed'], true, '损坏索引被重建');
    final Map<String, dynamic> rebuiltAgain = payloadOf(
      await call('rebuild-2', 'production.queue.rebuild', <String, Object?>{
        'line_id': 'pl_demo',
      }),
    );
    check.check(rebuiltAgain['changed'], false, '重建幂等（第二次 0 写）');
    check.check(
      jsonDecode(stateFile.readAsStringSync())['queue'],
      <String>['B', 'C'],
      'state.queue 与 task.yaml 对齐（A 已 done）',
    );
  } catch (error) {
    check.that(false, '自检过程未抛异常', actual: '$error');
  } finally {
    await core.close();
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  }
  return check.finish(core.logs);
}
