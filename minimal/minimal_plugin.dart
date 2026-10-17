// **最小可运行插件**（Dart；业务逻辑不到 40 行）：先跑通，再读大示例。
//
// 它只做四件事，别的什么都不做——这四件就是"一个插件能上线"的最小集合：
//
//   1. `hello`：握手，自报名字与能力（核心凭这个判定插件就绪）；
//   2. `ping`：心跳。**不回会被打成 degraded**（中转请求的等待期也靠它续期）；
//   3. `tools/list`：申报工具，这里只有一个 `hello_tool`；
//   4. `tools/call`：执行那个工具（回 `{content:[{type:text,text:…}], isError}`）。
//
// 这四条里 1 / 2 与异常收敛都在骨架（`../_kit/plugin_kit.dart`）里做掉了——**示例
// 不该要求读者重抄一遍管道**，否则读者抄错了也不知道自己抄错了。这里只剩"这个插件
// 干什么"：一张工具表 + 一个执行分支。
//
// 跑起来（**不需要真核心**）：
//     dart run plugins/minimal/minimal_plugin.dart --selftest
//   或编译后：
//     dart compile exe plugins/minimal/minimal_plugin.dart -o build/plugins/tree_minimal.exe
//     build/plugins/tree_minimal.exe --selftest
//
// 接进真核心（`plugins.yaml`，或直接把 plugins/minimal 这条丢进「设置 → 插件」）：
//     plugins:
//       - id: minimal
//         command: "./plugins/tree_minimal.exe"
//         args: []
//         enabled: true
//         scope: {}          # 空 scope = 作用于所有 team
import 'dart:async';
import 'dart:io';

import '../_kit/plugin_kit.dart';

/// 工具的**唯一定义处**：模型看到的名字是 `plugin__<插件id>__hello_tool`（前缀由核心加）。
const List<Map<String, dynamic>> kTools = <Map<String, dynamic>>[
  <String, dynamic>{
    'name': 'hello_tool',
    'description': '回显一句话（最小示例插件的唯一工具）',
    'inputSchema': <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'text': <String, dynamic>{'type': 'string'},
      },
      'required': <String>['text'],
    },
  },
];

/// 工具执行：成功 `isError:false`；失败要把**可读原因**写进 text（模型看得到）。
///
/// 第三个参数 `scope` = **这一次调用的身份**（`agent_id` / `session_id` / `team_id` /
/// `mode_key`，核心随 `tools/call` 下发）。本例不读它（它只会 echo），但**签名要跟骨架
/// 一致**：工具要是打算经执行站下命令（`fs.read` / `agent.stop` / `tool.call`），目标
/// 就得取这里的身份，而不是退回 `plugins.yaml` 里写死的那个 agent（参照
/// `../sample/sample_plugin.dart` 的 `read_probe`，它就把这一位用上了）。
Map<String, dynamic> callTool(
  String name,
  Map<String, dynamic> arguments,
  Map<String, dynamic> scope,
) {
  if (name != 'hello_tool') return toolText('未知工具 $name', isError: true);
  return toolText('hello_tool: ${arguments['text'] ?? ''}');
}

PluginKitServer buildServer() => PluginKitServer(
  channel: PluginChannel.stdio('minimal_plugin'),
  pluginId: 'minimal',
  displayName: '最小示例插件（Dart）',
  tools: kTools,
  onToolCall: callTool,
);

Future<void> main(List<String> args) async {
  if (args.contains('--selftest')) {
    exitCode = await selfTest();
    return;
  }
  await buildServer().run(stdin);
  try {
    await stdout.flush();
  } catch (_) {
    // 管道已被对端关掉：刷不出去不算错误（核心已不听了）。
  }
}

/// 假核心自测：**进程内**把字节流两端接起来，断言四条主路径（不连真核心）。
///
/// 走的是与真进程同一个 `run()`——自检与生产不同码的话，自检绿就没有意义。
Future<int> selfTest() async {
  final SelfTest check = SelfTest(name: 'minimal_plugin');
  final PluginKitServer server = PluginKitServer(
    channel: PluginChannel(logTag: 'minimal_plugin'),
    pluginId: 'minimal',
    displayName: '最小示例插件（Dart）',
    tools: kTools,
    onToolCall: callTool,
    // 自检里不许退出进程：否则后面的断言都跑不到（生产默认是 true）。
    exitOnShutdown: false,
  );
  final FakeCore core = FakeCore(server);
  unawaited(core.start());

  core.ask(0, M.hello, <String, dynamic>{'plugin_id': 'minimal'});
  core.ask(1, M.toolsList);
  core.ask(2, M.toolsCall, <String, dynamic>{
    'name': 'hello_tool',
    'arguments': <String, dynamic>{'text': 'hi'},
  });
  core.ask(3, M.toolsCall, <String, dynamic>{'name': 'nope'});
  core.ask(4, M.ping);
  // 一条骨架不认识的方法：必须回 -32601（**不静默**，插件作者要看得见自己没实现它）。
  core.ask(5, 'no_such/method');
  final Map<Object?, Map<String, dynamic>> byId = await core.waitFor(<int>[
    0,
    1,
    2,
    3,
    4,
    5,
  ]);

  check.that(byId.length == 6, '五条请求 + 一条未知方法都有回包', actual: '${byId.length}');
  check.check(
    asString(asMap(byId[0]?['result'])['name']),
    '最小示例插件（Dart）',
    'hello 自报名字',
  );
  check.check(
    asMap(byId[0]?['result'])['plugin_id'],
    'minimal',
    'hello 回带 plugin_id（核心给的优先）',
  );
  check.check(
    (asMap(byId[1]?['result'])['tools'] as List<dynamic>? ?? <dynamic>[])
        .map((dynamic e) => asString(asMap(e)['name']))
        .toList(),
    <String>['hello_tool'],
    'tools/list 只申报 hello_tool',
  );
  check.check(
    asString(
      ((asMap(byId[2]?['result'])['content'] as List<dynamic>? ?? <dynamic>[])
              .first
          as Map)['text'],
    ),
    'hello_tool: hi',
    'tools/call 回显正文',
  );
  check.that(
    byId[3]?['result'] != null && asMap(byId[3]!['result'])['isError'] == true,
    '未知工具必须 isError:true',
    actual: '${byId[3]}',
  );
  check.that(
    asMap(byId[4]?['result'])['ok'] == true,
    'ping 必须回 ok（不回就被判 degraded）',
    actual: '${byId[4]}',
  );
  check.that(
    asMap(byId[5]?['error'])['code'] == -32601,
    '未知方法必须回 -32601（不许静默吞掉）',
    actual: '${byId[5]}',
  );

  // 心跳不能被子任务的顺序压住：上面五条是并发派发的，ping 有回包即证明读循环
  // 没有被任何一条业务卡住（铁律 2）。这里再补一条"处理中照样能问"的直接形状。
  core.ask(6, M.ping);
  check.that(
    (await core.waitFor(<int>[
      6,
    ], timeout: const Duration(seconds: 2))).containsKey(6),
    '业务之后再来一拍 ping 仍然答得上',
  );

  core.notify(M.shutdown);
  await core.close();
  return check.finish(core.logs);
}
