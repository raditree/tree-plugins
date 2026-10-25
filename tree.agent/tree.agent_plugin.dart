// tree.agent —— agent 领域插件（批次 G）的 **A1 骨架**。
//
// A1 的验收（agent_pluginization.md §6）：空插件能被启停；日志出现在
// `/api/logs/plugin:tree.agent`。本文件因此只做四件事：
//   1. hello / ping（骨架统一回答，缺一个就是整条插件不可用）；
//   2. `tools/list`：空表（tools/list 是可选能力，缺失或为空不得阻断上线）；
//   3. `system.collect.api.routes` 收集站：如实回空表（A2 起按对照表逐组填）；
//   4. 上线时写一条 stderr 与一条 log 通知——日志 API 的写入侧就在这两条路上。
//
// **不做**：36 条委派路由、广播 topic、数据接管——那些是 A2~A5，按
// `docs/pluginization/agent_api_contract.md` 与 agent_pluginization.md §6 逐批搬入。
//
// 依赖纪律：本插件不得 import 任何核心包（tree_core / tree_protocol）；
// 骨架与领域库都在本仓内（`../_kit` 与 `package:tree_agent_loop`）。
import 'dart:async';
import 'dart:io';

import 'package:tree_agent_loop/tree_agent_loop.dart';

import '../_kit/plugin_kit.dart';

/// 与 `plugin.json` 的 id 同串；核心以此认身份（自带清单时核心给的优先）。
const String kPluginId = 'tree.agent';

/// 面板展示名。
const String kDisplayName = 'Tree Agent 循环';

/// 建一个服务实例。自检与生产**共用**这个形状，只有退出策略不同。
PluginKitServer buildServer({bool exitOnShutdown = true}) => PluginKitServer(
  channel: PluginChannel.stdio(kPluginId),
  pluginId: kPluginId,
  displayName: kDisplayName,
  onReady: _onReady,
  onRequest: handleRequest,
  exitOnShutdown: exitOnShutdown,
);

Future<void> _onReady(PluginKitServer server) async {
  // **两路日志都主动写一条**：A1 的验收就是"插件自己的日志能从日志 API 查到"。
  // stderr 进 [stderr] 行，log 通知进 [notify:info] 行（见片 F 的 PluginLogSink）。
  server.channel.log('已上线：v$kTreeAgentVersion（A1 骨架，委派路由 0 条）');
  server.channel.logNotify('tree.agent 已上线（v$kTreeAgentVersion，A1 骨架）');
}

/// 骨架不认识的方法（当前只有收集站）。
///
/// 返回 null = 让骨架回 -32601（不静默）；抛异常由骨架收敛成 -32603。
Future<Map<String, dynamic>?> handleRequest(
  String method,
  Map<String, dynamic> params,
) async {
  if (method == M.stationRequest) {
    final String station = asString(params['station_id']);
    if (station == kApiRoutesStation) {
      // 收集站口径：`{reply: {payload: {routes: [...]}}}`（核心只读 reply.payload）。
      return <String, dynamic>{
        'reply': <String, dynamic>{
          'payload': <String, dynamic>{'routes': kDeclaredRoutes},
        },
      };
    }
  }
  return null;
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

/// 假核心自检（**同码**跑真读循环）：A1 的四条上线要件 + 日志通知。
Future<int> selfTest() async {
  final SelfTest check = SelfTest(name: 'tree_agent_plugin');
  final PluginKitServer server = PluginKitServer(
    channel: PluginChannel(logTag: 'tree_agent_plugin'),
    pluginId: kPluginId,
    displayName: kDisplayName,
    onReady: _onReady,
    onRequest: handleRequest,
    // 自检里不许退出进程：否则后续断言都跑不到。
    exitOnShutdown: false,
  );
  final FakeCore core = FakeCore(server);
  unawaited(core.start());

  core.ask(0, M.hello, <String, dynamic>{'plugin_id': kPluginId});
  core.ask(1, M.ping);
  core.ask(2, M.toolsList);
  core.ask(3, M.stationRequest, <String, dynamic>{
    'station_id': kApiRoutesStation,
    'payload': <String, dynamic>{},
  });
  core.ask(4, 'no_such/method');

  final Map<Object?, Map<String, dynamic>> byId = await core.waitFor(<int>[
    0,
    1,
    2,
    3,
    4,
  ]);

  check.that(byId.length == 5, '五条请求都有回包', actual: '${byId.length}');
  check.check(
    byId[0]?['result']?['plugin_id'],
    kPluginId,
    'hello 自报 plugin_id',
  );
  check.check(byId[0]?['result']?['name'], kDisplayName, 'hello 自报展示名');
  check.check(byId[1]?['result']?['ok'], true, 'ping 回 ok');
  check.check(
    byId[2]?['result']?['tools'],
    <dynamic>[],
    'A1 工具表为空（tools/list 可选，不阻断上线）',
  );
  check.that(
    byId[3]?['result']?['reply']?['payload']?['routes'] is List &&
        (byId[3]?['result']?['reply']?['payload']?['routes'] as List).isEmpty,
    '委派路由申报回空表（如实申报、不是未响应）',
    actual: '${byId[3]?['result']}',
  );
  check.that(byId[4]?['error'] != null, '未知方法回错误（不静默丢弃）');

  // 上线通知是异步发的：轮询等它到达（最多 2s）。
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 2));
  while (core.outgoing(M.log).isEmpty && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  final List<Map<String, dynamic>> notifications = core.outgoing(M.log);
  check.that(
    notifications.any(
      (Map<String, dynamic> frame) =>
          '${frame['params']?['message'] ?? ''}'.contains('tree.agent 已上线'),
    ),
    '上线 log 通知已发出（日志 API 写入侧）',
    actual: '${notifications.length} 条',
  );

  await core.close();
  return check.finish(core.logs);
}
