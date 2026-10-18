import 'dart:async';

import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'plugin_loop.dart';
import 'tunnel_config.dart';
import 'ui_panel.dart';

/// 随包自检：在**同一个进程里**装一条脚本化的假核心，走一遍协议面。
///
/// 为什么必须有它（而不是"装了再看面板"）：`tool/build_plugins.dart` 对每个产物都跑
/// `<exe> --selftest` 并以**退出码**判定，装机后端到端验证读的就是这个退出码。
/// "插件起来了、面板没报错"证明不了协议面真的对——历史上出问题的是「编译过了但帧形状错」
/// 与「版本没注入」，两者在界面上只表现为一个不起眼的开关。
///
/// 三条刻意：
/// 1. **绝不建 SSH 连接**：dialer 换成"被调用就抛"——自检只核协议面，网络面由
///    `tree_agent` 的用例与 Docker sshd 的真链路负责（跨层会让失败无法归因）。
/// 2. **方法名全部走常量**（[PluginMethods] / [kUiMethodManifest]），不散落字面量：
///    与 `plugin_loop.dart` 同一条纪律，`tree_protocol` 的门禁用例按这条扫。
/// 3. **核事实不核氛围**：capabilities、protocol、错误码、帧的条数与 id、注入后的版本串。
Future<int> runSelfTest({void Function(String line)? emit}) async {
  final void Function(String) say = emit ?? ((String line) {});
  final List<String> failures = <String>[];

  void check(String name, bool ok, [String detail = '']) {
    if (!ok) failures.add('$name${detail.isEmpty ? '' : '（$detail）'}');
    say('${ok ? 'PASS' : 'FAIL'}  $name${detail.isEmpty ? '' : '  → $detail'}');
  }

  final StreamController<List<int>> coreIn = StreamController<List<int>>();
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];

  final PluginLoop loop = PluginLoop(
    // 自检里没有任何一步该建 SSH：真建了就是形状错了，直接抛出来让它成为一条失败。
    dialer: (TunnelConfig config) async =>
        throw UnsupportedError('自检不该建 SSH 连接'),
    send: frames.add,
    log: (String message) => say('  [log] $message'),
  );
  // 读循环在后台跑；`run` 只在 stdin 关闭或收到 shutdown 时返回。
  final Future<int> exitCode = loop.run(coreIn.stream);

  void ask(int id, String method, [Map<String, dynamic>? params]) {
    coreIn.add(encodeFrame(rpcRequest(id, method, params)));
  }

  /// 等到某 id 的回包；超时回 null —— 让调用方把它写成一条 FAIL，而不是抛异常炸掉自检。
  Future<Map<String, dynamic>?> reply(int id) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      for (final Map<String, dynamic> frame in frames) {
        if (frame['id'] == id) return frame;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return null;
  }

  // ── 1. hello：核心判"有没有中转站"的唯一判据 ────────────────────────────
  ask(1, PluginMethods.hello, <String, dynamic>{'protocol': 1});
  final Object? helloResult = (await reply(1))?['result'];
  check(
    'hello 回 capabilities=[ssh-executor] 且 protocol 与协议常量一致',
    helloResult is Map &&
        helloResult['capabilities'] is List &&
        (helloResult['capabilities'] as List).single == kCapabilitySshExecutor &&
        helloResult['protocol'] == kTunnelProtocolVersion,
    '实际回：$helloResult',
  );

  // ── 2. 心跳必答（被慢活堵住的插件在真机上的表现是被判 degraded）────────
  ask(2, PluginMethods.ping);
  final Object? pingResult = (await reply(2))?['result'];
  check(
    'ping 回 {ok: true}',
    pingResult is Map && pingResult['ok'] == true,
    '实际回：$pingResult',
  );

  // ── 3. tools/list：本插件不申报 agent tool，空表必须是**合法的空** ───────
  ask(3, PluginMethods.toolsList);
  final Object? toolsResult = (await reply(3))?['result'];
  check(
    'tools/list 回一张表（缺键 / null 都不算合法的空集）',
    toolsResult is Map && toolsResult['tools'] is List,
    '实际回：$toolsResult',
  );

  // ── 4. 未知方法回 -32601，不静默 ───────────────────────────────────────
  ask(4, 'selftest.unknown.method');
  final Object? unknownError = (await reply(4))?['error'];
  check(
    '未知方法回 -32601（methodNotFound）',
    unknownError is Map && unknownError['code'] == RpcCodes.methodNotFound,
    '实际回：$unknownError',
  );

  // ── 5. 一次塞四帧必须逐条回 ────────────────────────────────────────────
  // 回归钉子（真机必现过）：stdout 每帧 flush 会把 sink 标成 bound，同一批解出的多帧
  // 再 add 就抛 `Bad state: StreamSink is bound to a stream`。它只在**编译产物 + 管道
  // stdin** 上出现，跑源码级单测看不见，所以必须进产物自检。
  coreIn.add(<int>[
    ...encodeFrame(rpcRequest(11, PluginMethods.ping)),
    ...encodeFrame(rpcRequest(12, PluginMethods.ping)),
    ...encodeFrame(rpcRequest(13, PluginMethods.ping)),
    ...encodeFrame(rpcRequest(14, PluginMethods.ping)),
  ]);
  final Set<Object?> batchSeen = <Object?>{};
  final DateTime batchDeadline = DateTime.now().add(
    const Duration(seconds: 10),
  );
  while (DateTime.now().isBefore(batchDeadline)) {
    batchSeen
      ..clear()
      ..addAll(
        frames
            .map((Map<String, dynamic> frame) => frame['id'])
            .where((Object? id) => id != null),
      );
    if (batchSeen.containsAll(<Object?>[11, 12, 13, 14])) break;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  check(
    '一次塞 4 帧也逐条回（每帧 flush 会炸 sink，这是历史真炸过的那条）',
    batchSeen.containsAll(<Object?>[11, 12, 13, 14]),
    '只收到：${batchSeen.join('、')}',
  );

  // ── 6. 一起来就申报左栏面板 ────────────────────────────────────────────
  Map<String, dynamic>? manifest;
  for (final Map<String, dynamic> frame in frames) {
    if (frame['method'] == kUiMethodManifest) {
      manifest = frame;
      break;
    }
  }
  check(
    '启动即发 ui/manifest 且带 params（没这条 = 面板上不会出现左栏）',
    manifest != null && manifest['params'] is Map,
    '帧里没有 ui/manifest',
  );

  // ── 7. 版本注入：产物自报的版本必须来自 -DkAgentVersion ─────────────────
  // 兜底值是 '0.0.0-dev'（tree_tunnel_protocol 的 constants.dart）。停在兜底值意味着
  // "release 产物说自己叫 0.0.0-dev"：目标机驻留目录按版本命名 ⇒ 每次装都当新版本重推，
  // 而面板上那一行版本号也是假的。
  check(
    'kAgentVersion 由构建时注入（不是兜底值 0.0.0-dev）',
    kAgentVersion.isNotEmpty && kAgentVersion != '0.0.0-dev',
    '自报版本=$kAgentVersion —— 编译时没带 -DkAgentVersion=<版本>',
  );
  say('  自报 agent 版本：$kAgentVersion');

  // ── 8. shutdown 后自己退出，退出码 0 ───────────────────────────────────
  coreIn.add(encodeFrame(rpcNotification(PluginMethods.shutdown)));
  final int code = await exitCode.timeout(
    const Duration(seconds: 10),
    onTimeout: () => -999,
  );
  check('收到 shutdown 后自行退出且 exit=0', code == 0, 'exit=$code');
  await coreIn.close();

  if (failures.isEmpty) {
    say('自检全绿：ssh_executor 协议面 8 条');
    return 0;
  }
  say('自检失败 ${failures.length} 条：${failures.join('；')}');
  return 1;
}
