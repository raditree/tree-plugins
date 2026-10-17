// **可挂起插件（热重启最小参考实现，Dart）**：转储 → 退出 → 新一世取回续跑。
//
// 它只做一件事，就是把 docs/plugin-development.md §6.5 那条时序**跑成真的**：
//
//   1. 核心发 `suspend`（只有 `plugins.yaml` 里声明了 `suspension: keep` 才会收到）；
//   2. 先用 `station/command` 下 `plugin.stateDump` 把状态递进核心的**内存池**，
//      **等它的回包到了**再回 ack —— 顺序反了核心就得靠"等一会儿"碰运气，而核心
//      既不等也不判时长（D8：取消静态时长判死）；
//   3. 回完 ack 就退出（下一世由核心拉起）；
//   4. 新一世的 `hello` 参数里带 `resume_dump_id`；插件下 `plugin.stateFetch` 取回它
//      （**核心没点名就别去取**：`stateFetch` 按 pluginId 认“上一世”，而一份快照只喂
//       一世——多实例插件里先抢到的那一个，会让真正该续的那一世拿到 `has_snapshot:false`）；
//   5. 取不到就按冷启动继续 —— **这不是错误**（`has_snapshot:false` + 可读原因）。
//
// 这两世之间的顺序、以及"先转储后 ack"这一条都在骨架里（`../_kit/plugin_kit.dart`
// 的 `suspend` 分支）；这里只交"这个插件要留什么"。它把"第几世"数给你看：工具 `era`
// 回 `restarts`——**这个数字来自快照本身**，所以只要它跨进程递增，就证明续跑真的
// 发生了（而不是"看起来成功了"）。
//
// 跑起来（**不需要真核心**）：
//     dart run plugins/suspendable/suspendable_plugin.dart --selftest
// 接进真核心（`plugins.yaml`）：
//     plugins:
//       - id: suspendable
//         command: "./plugins/tree_suspendable.exe"
//         args: []
//         enabled: true
//         suspension: keep     # ★ 没有这一行 = 不可挂起，热重启会直接冷启动
//         scope: {team_id: team-1}
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../_kit/plugin_kit.dart';

/// 状态键：这份示例只保一个计数器，真实插件在这里放自己的会话游标 / 缓冲 / 句柄表。
const String kStateKey = 'restarts';

const List<Map<String, dynamic>> kTools = <Map<String, dynamic>>[
  <String, dynamic>{
    'name': 'era',
    'description': '看这个插件现在是第几世、被热重启过几次（证明续跑真的发生了）',
    'inputSchema': <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
  },
];

/// 本世状态（`restarts` = 已经历过几次热重启；从上一世快照 +1 得来）。
class Era {
  Era({this.restarts = 0, this.pid = 0});
  int restarts;
  int pid;

  /// 要留给下一世的东西。**必须是 JSON 对象**（跨进程边界，不是进程内引用）。
  Map<String, dynamic> toDump() => <String, dynamic>{
    kStateKey: restarts,
    'dumped_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
  };
}

PluginKitServer buildServer({
  required PluginChannel channel,
  required Era era,
  bool exitOnSuspend = true,
}) {
  return PluginKitServer(
    channel: channel,
    pluginId: 'suspendable',
    displayName: '可挂起插件（热重启示例）',
    tools: kTools,
    exitOnSuspend: exitOnSuspend,
    dumpState: era.toDump,
    // 就绪后第一件事就是问"有没有我的快照"——没有就冷启动，这不是错误。
    onResume: (PluginKitServer server, Map<String, dynamic> snapshot) {
      final Object? raw = snapshot[kStateKey];
      final int previous = raw is int ? raw : int.tryParse('$raw') ?? 0;
      era.restarts = previous + 1;
      server.channel.log('续跑成功：第 ${era.restarts + 1} 世（上一世 $previous 次）');
    },
    onToolCall: (String name, Map<String, dynamic> arguments) {
      if (name != 'era') return toolText('未知工具 $name', isError: true);
      return toolText(
        json.encode(<String, Object?>{
          'pid': era.pid,
          'restarts': era.restarts,
          'era': era.restarts + 1,
        }),
      );
    },
  );
}

Future<void> main(List<String> args) async {
  if (args.contains('--selftest')) {
    exitCode = await selfTest();
    return;
  }
  final Era era = Era(pid: pid);
  await buildServer(
    channel: PluginChannel.stdio('suspendable_plugin'),
    era: era,
  ).run(stdin);
  try {
    await stdout.flush();
  } catch (_) {
    // 管道已被对端关掉：刷不出去不算错误。
  }
}

/// 假核心自检：只回答 `station/command`，然后按 §6.5 的时序走完**三世**
///（冷启动 → 转储后退出 → 取回续跑 → 取不到时降级）。
///
/// 断言的都是**可数的东西**：没被点名就不下取回、转储请求排在 ack **之前**、
/// 转储还在途时 ack 一句都不发（而且心跳照答）、取回确实带回上一世的载荷、
/// `era` 计数器确实跨"进程"加了一。
Future<int> selfTest() async {
  final SelfTest check = SelfTest(name: 'suspendable_plugin');

  // ── 第一世：冷启动 → 收 suspend → 转储 → ack ──────────────────────────
  final Era first = Era(pid: 111);
  final PluginKitServer firstServer = buildServer(
    channel: PluginChannel(logTag: 'suspendable_plugin/1'),
    era: first,
    exitOnSuspend: false, // 自检里不能真退进程，否则后面的断言跑不到
  );
  final FakeCore core1 = FakeCore(firstServer);
  unawaited(core1.start());
  core1.ask(0, M.hello, <String, dynamic>{'plugin_id': 'suspendable'});
  final Map<Object?, Map<String, dynamic>> hello1 = await core1.waitFor(<int>[
    0,
  ]);
  check.that(
    asMap(hello1[0]?['result'])['plugin_id'] == 'suspendable',
    '第一世握手成功（没带 resume_dump_id ⇒ 不该去取快照）',
    actual: '${hello1[0]}',
  );
  await Future<void>.delayed(const Duration(milliseconds: 60));
  check.that(
    core1.outgoing(M.stationCommand).isEmpty,
    '没有 resume_dump_id 就**不该**下 stateFetch（不许凭空造一次取回）',
    actual: '${core1.outgoing(M.stationCommand)}',
  );

  core1.ask(1, M.toolsCall, <String, dynamic>{'name': 'era'});
  final Map<Object?, Map<String, dynamic>> era1 = await core1.waitFor(<int>[1]);
  final Map<String, dynamic> firstEra = asJson(
    _toolText(asMap(era1[1]?['result'])),
  );
  check.check(firstEra['restarts'], 0, '第一世 restarts=0');

  // 核心发来 suspend（先转储、等回包、再 ack —— 顺序是这段代码的全部要点）。
  core1.ask(2, M.suspend, <String, dynamic>{'reason': 'hot_restart'});
  // ① 先只等"转储请求发出来"，**一句都不回它**：这一拍插件必须还活着。
  final String dumpCommand = Cmd.stateDump;
  int dumpIndex = -1;
  final DateTime dumpDeadline = DateTime.now().add(const Duration(seconds: 6));
  while (DateTime.now().isBefore(dumpDeadline)) {
    dumpIndex = core1.frames.indexWhere(
      (Map<String, dynamic> frame) => _commandOf(frame) == dumpCommand,
    );
    if (dumpIndex >= 0) break;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  check.that(
    dumpIndex >= 0,
    'suspend 期间确实下了 plugin.stateDump',
    actual: '${core1.outgoing(M.stationCommand)}',
  );
  check.that(
    !core1.responses().containsKey(2),
    '转储的回包还没来，ack 就**不许**发出去（核心不等时长，靠的就是这一条）',
    actual: '${core1.responses()[2]}',
  );
  // ② 慢转储在途期间心跳必须照常答（D8：核心按心跳说话，回不来就被判失活）。
  core1.ask(3, M.ping);
  check.that(
    (await core1.waitFor(<int>[
      3,
    ], timeout: const Duration(seconds: 2))).containsKey(3),
    '转储在途时 ping 仍然答得上（铁律 2：读循环不被业务压住）',
  );
  // ③ 现在才答它那句转储 ⇒ ack 应该随后就到，且**排在转储请求之后**。
  core1.answer(M.stationCommand, <String, dynamic>{
    'ok': true,
    'payload': <String, dynamic>{
      'ok': true,
      'dump_id': 'suspendable#1',
      'bytes': 42,
      'generation': 1,
    },
  });
  final Map<Object?, Map<String, dynamic>> acked = await core1.waitFor(<int>[
    2,
  ]);
  check.that(
    acked.containsKey(2),
    '转储回包到达后 ack 才发出去（顺序反了核心只能碰运气）',
    actual: '${acked[2]}',
  );
  final int ackIndex = core1.frames.indexWhere(
    (Map<String, dynamic> frame) => frame['method'] == null && frame['id'] == 2,
  );
  check.that(
    dumpIndex >= 0 && ackIndex > dumpIndex,
    '帧序里转储请求确实排在 ack 之前（时序的可数证据）',
    actual: 'dump=$dumpIndex ack=$ackIndex',
  );
  check.that(
    asMap(acked[2]?['result'])['dumped'] == true,
    'ack 要如实带 dumped:true',
    actual: '${acked[2]}',
  );
  final Map<String, dynamic> dumpArgs = dumpIndex < 0
      ? <String, dynamic>{}
      : asJson(
          asMap(
            asMap(
              asMap(core1.frames[dumpIndex]['params'])['arguments'],
            )['payload'],
          ),
        );
  check.check(dumpArgs[kStateKey], 0, '转储载荷里是这一世的 restarts');
  await core1.close();

  // ── 第二世：hello 带 resume_dump_id → stateFetch 拿回 → 计数器 +1 ──────
  final Era second = Era(pid: 222);
  final PluginKitServer secondServer = buildServer(
    channel: PluginChannel(logTag: 'suspendable_plugin/2'),
    era: second,
    exitOnSuspend: false,
  );
  final FakeCore core2 = FakeCore(secondServer);
  unawaited(core2.start());
  core2.ask(0, M.hello, <String, dynamic>{
    'plugin_id': 'suspendable',
    'resume_dump_id': 'suspendable#1',
  });
  // 插件开局就该下 stateFetch；把第一世那份载荷回给它（`dump_id` 的真形状是
  // `pluginId#generation`，由核心拼，插件报的只做核对——这里拿的就是它还给 suspend 那份）。
  final DateTime fetchDeadline = DateTime.now().add(const Duration(seconds: 6));
  bool answeredFetch = false;
  while (DateTime.now().isBefore(fetchDeadline) && !answeredFetch) {
    final List<Map<String, dynamic>> fetches = core2
        .outgoing(M.stationCommand)
        .where(
          (Map<String, dynamic> frame) => _commandOf(frame) == Cmd.stateFetch,
        )
        .toList();
    if (fetches.isNotEmpty) {
      core2.answer(M.stationCommand, <String, dynamic>{
        'ok': true,
        'payload': <String, dynamic>{
          'ok': true,
          'has_snapshot': true,
          'dump_id': 'suspendable#1',
          'payload': <String, dynamic>{kStateKey: 0},
        },
      });
      answeredFetch = true;
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
  check.that(answeredFetch, '带 resume_dump_id 就要主动下 stateFetch 取回上一世');
  core2.ask(1, M.toolsCall, <String, dynamic>{'name': 'era'});
  final Map<Object?, Map<String, dynamic>> era2 = await core2.waitFor(<int>[1]);
  final Map<String, dynamic> secondEra = asJson(
    _toolText(asMap(era2[1]?['result'])),
  );
  check.check(secondEra['restarts'], 1, '第二世 restarts=1（数字来自快照本身）');
  check.check(secondEra['era'], 2, '第二世 era=2');
  check.that(
    secondServer.resumeDumpId == 'suspendable#1',
    'hello params 里的 resume_dump_id 被记下来了（方向：核心→插件）',
    actual: secondServer.resumeDumpId,
  );

  // 取不到快照 ⇒ 冷启动，而且**必须留一行**（不然"我的上下文呢"查不出来）。
  final Era third = Era(pid: 333);
  final PluginKitServer thirdServer = buildServer(
    channel: PluginChannel(logTag: 'suspendable_plugin/3'),
    era: third,
    exitOnSuspend: false,
  );
  final FakeCore core3 = FakeCore(thirdServer);
  unawaited(core3.start());
  core3.ask(0, M.hello, <String, dynamic>{
    'plugin_id': 'suspendable',
    'resume_dump_id': 'suspendable#0',
  });
  final DateTime coldDeadline = DateTime.now().add(const Duration(seconds: 6));
  bool answeredCold = false;
  while (DateTime.now().isBefore(coldDeadline) && !answeredCold) {
    if (core3
        .outgoing(M.stationCommand)
        .any(
          (Map<String, dynamic> frame) => _commandOf(frame) == Cmd.stateFetch,
        )) {
      core3.answer(M.stationCommand, <String, dynamic>{
        'ok': true,
        'payload': <String, dynamic>{
          'ok': true,
          'has_snapshot': false,
          'reason': '那一份已经喂过一世了（一份只喂一世）⇒ 按冷启动继续',
        },
      });
      answeredCold = true;
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
  core3.ask(1, M.toolsCall, <String, dynamic>{'name': 'era'});
  final Map<String, dynamic> thirdEra = asJson(
    _toolText(asMap((await core3.waitFor(<int>[1]))[1]?['result'])),
  );
  check.check(thirdEra['restarts'], 0, '没有快照 ⇒ 按冷启动继续（restarts 仍为 0）');
  check.that(
    core3.logs.any((String line) => line.contains('冷启动')),
    '取不到快照必须留一行说明（不静默）',
    actual: core3.logs.join(' | '),
  );
  await core3.close();

  // 三世日志全部汇进来：失败时能直接看到当时插件自己怎么说那句活儿的。
  return check.finish(<String>[...core1.logs, ...core2.logs, ...core3.logs]);
}

/// 取 `tools/call` 回包里的正文（`content[0].text`）。
String _toolText(Map<String, dynamic> result) {
  final Object? content = result['content'];
  if (content is! List || content.isEmpty) return '{}';
  return asString(asMap(content.first)['text']);
}

/// 取插件主动发来的 `station/command` 帧里的**命令名**。
///
/// 口径：命令名在 `params` 顶层、参数在 `params.arguments`（核心侧 `handlePluginCommand`
/// 读的就是这两层）——自检把这两层读混过一次，于是"确实下发了"断言假红。
String _commandOf(Map<String, dynamic> frame) =>
    asString(asMap(frame['params'])['command']);
