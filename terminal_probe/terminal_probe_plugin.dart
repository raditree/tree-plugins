// **终端钩子稳定性探针（Dart）**：起一个 3 小时的 terminal 后台任务，逐拍量它。
//
// 核心执行站的 terminal 通路有三段，任一段不稳定，长任务就成了黑盒：
//
//   1. **启动**：`station/command` 下 `terminal.exec` + `command` + `hook: true`
//      （★ 后台模式的入口键是 `hook`，不是 `background`——后者核心不认）；
//   2. **hooks 轮询**：`terminal.exec` + `hook_action=status` / `cancel` + `task_id`
//      （`status` 回的是写给模型看的**散文**；要行就用 `terminal.listRuns`，
//      但那条不是"钩子还活着没"的直接问口，所以本探针仍然量 `hook_action`）；
//   3. **工具运行超时广播**：广播站点位 `system.tool.timeout`（一次运行跨过阈值
//      **只广播一条**；本探针**不取消、只记它什么时候响**——"该响没响"也是稳定性）。
//
// 于是这里做的事就是：`hello` → 订超时广播 → 发一条零成本 canary 学 `shell=` →
// 按 shell 家族生成那条长跑命令并转后台 → 每 `--interval` 秒问一拍 → 到期或用户点
// 「提前结束」收尾。全程把 `(时刻, 事件, 详情)` 记成时间线，推成左栏 `activity` 面板。
//
// **为什么值得 3 小时**：那是工具超时阈值的几十倍，也是上下文缓存持久化窗口的若干倍。
// 只要有一处心跳丢了、有一拍回报晚了、有一次超时广播该来没来，这张表上就能看出它在
// 哪一段、从什么时候开始不老实。
//
// 跑起来（**不需要真核心**）：
//     dart run plugins/terminal_probe/terminal_probe_plugin.dart --selftest
// 接进真核心（`plugins.yaml`；`--agent-id` 必填，否则它如实记下"没启动"而不是猜一个）：
//     plugins:
//       - id: terminal_probe
//         command: "./plugins/tree_terminal_probe.exe"
//         args: ["--hours", "3", "--interval", "30", "--agent-id", "agt_xxx"]
//         enabled: true
//         scope: {}
//
// 它**不声明** `suspension: keep`：热重启时核心只会把本世拍掉，而这条 3 小时任务
// 的句柄在重启窗口里能不能接着用并非插件能保证的（骨架只会交 `dumpState` 里那份）。
// 宁可冷启动重发一条，也不交一份"看起来能续"的快照——那是骗下一世。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../_kit/plugin_kit.dart';

const String kPluginId = 'terminal_probe';
const String kPanelTitle = '终端稳定性探针';

/// 执行站命令名（terminal 通路的唯一入口）。
const String kCommandTerminalExec = 'terminal.exec';

/// 广播站点位（工具运行超时）：订阅时可以用别名 `tool.timeout`。
const String kPointToolTimeout = 'system.tool.timeout';
const String kPointToolTimeoutAlias = 'tool.timeout';

/// 面板按钮回调的事件名（判据在 `params.event` 上，**不是** `params.method`）。
const String kEventUiAction = 'plugin_ui_action';

/// 时间线上限（面板只显示最近 [kMaxPanelRows] 条）。
const int kMaxTimeline = 800;
const int kMaxPanelRows = 25;

/// 面板刷新节流：视图是**整块替换**，刷太勤只是闪。
const Duration kPanelMinGap = Duration(milliseconds: 500);

/// 从 terminal 回包文本里认 `shell=xxx`（比插件自己猜平台可靠得多）。
final RegExp _shellPattern = RegExp(
  r'shell\s*=\s*([A-Za-z0-9_.\-]+)',
  caseSensitive: false,
);
final RegExp _taskIdPattern = RegExp(r'task_id\s*[:：]\s*(\S+)');

const Set<String> _posixShells = <String>{
  'sh',
  'bash',
  'zsh',
  'dash',
  'ksh',
  'ssh',
  'linux',
  'unix',
  'posix',
};
const Set<String> _cmdShells = <String>{'cmd', 'cmd.exe', 'windows', 'bat'};
const Set<String> _powershellShells = <String>{
  'powershell',
  'pwsh',
  'powershell.exe',
};

/// 命令行选项（全部有默认值：不带参数 = 起 3 小时探针，面板打开）。
class Options {
  double hours = 3.0;
  double intervalSeconds = 30.0;

  /// 目标身份（留空 ⇒ 如实记下"没启动"，**不猜**一个 agent）。
  String agentId = '';
  String sessionId = '';

  /// 长跑命令（留空 = 按 shell 家族生成 sleep）。
  String command = '';
  String outputFile = '';

  /// 后台任务模式（`hook: true`）；`--foreground` 关掉。
  bool background = true;

  /// shell 家族：`auto`（从回包学）/ posix / cmd / powershell。
  String shell = 'auto';

  /// 探针模式：`auto`（先 canary 再决定）/ `hook`（后台句柄轮询）/ `echo`（只量通路存活）。
  String mode = 'auto';

  bool noProbe = false;
  bool noPanel = false;

  /// **插件自己的观测窗口**（秒）：这一拍没回包就在时间线上写"没回来"。
  ///
  /// 与 D8 不冲突：D8 说的是**核心**不拿时长当判死依据；这里没有判死任何人，
  /// 只是"我发的问一句都没回"这个事实得有个说法——不然面板上就是永久"等核心回包…"。
  double commandTimeoutSeconds = 60.0;

  static Options parse(List<String> argv) {
    final Options options = Options();
    for (int i = 0; i < argv.length; i++) {
      final String name = argv[i];
      final String value = i + 1 < argv.length ? argv[i + 1] : '';
      void take(void Function(String) apply) {
        apply(value);
        i++;
      }

      switch (name) {
        case '--hours':
          take((String v) => options.hours = _positive(v, options.hours));
        case '--interval':
          take(
            (String v) => options.intervalSeconds = _positive(v, options.hours),
          );
        case '--command-timeout':
          take(
            (String v) => options.commandTimeoutSeconds = _positive(
              v,
              options.commandTimeoutSeconds,
            ),
          );
        case '--agent-id':
          take((String v) => options.agentId = v.trim());
        case '--session-id':
          take((String v) => options.sessionId = v.trim());
        case '--command':
          take((String v) => options.command = v);
        case '--output-file':
          take((String v) => options.outputFile = v);
        case '--shell':
          take(
            (String v) => options.shell = v.trim().isEmpty
                ? 'auto'
                : v.trim().toLowerCase(),
          );
        case '--mode':
          take(
            (String v) => options.mode = v.trim().isEmpty
                ? 'auto'
                : v.trim().toLowerCase(),
          );
        case '--foreground':
          options.background = false;
        case '--no-probe':
          options.noProbe = true;
        case '--no-panel':
          options.noPanel = true;
      }
    }
    return options;
  }

  static double _positive(String raw, double fallback) =>
      double.tryParse(raw.trim()) ?? (fallback);
}

/// 一条时间线记录（面板的数据源）。
class TimelineEntry {
  TimelineEntry(this.at, this.kind, this.text);
  final DateTime at;
  final String kind;
  final String text;
}

/// 探针本体：所有对外动作都走 [channel]（自检跑的是**真协议面**，不是假命令通道）。
class Probe {
  Probe({
    required this.channel,
    required this.options,
    this.pluginId = kPluginId,
  });

  final PluginChannel channel;
  final Options options;
  String pluginId;

  // ── 探针状态 ────────────────────────────────────────────────────────
  final List<TimelineEntry> timeline = <TimelineEntry>[];
  int pollCount = 0;
  int pollErrors = 0;
  int timeoutBroadcasts = 0;
  String taskId = '';
  String lastStatusText = '';
  String learnedShell = '';
  bool degraded = false;
  bool started = false;
  bool done = false;
  DateTime? startAt;
  bool stopRequested = false;

  bool _panelDeclared = false;
  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);

  /// 槽位键带实例 id：同一份成品配成两个插件实例时互不覆盖。
  String get slotKey => '$pluginId.activity.1';

  // ── 开工 ────────────────────────────────────────────────────────────

  /// `hello` 之后的动作：先申报面板与订阅（这两条要等回包，但读循环不受影响），
  /// 再把探针循环**不 await** 地甩出去。
  Future<void> startup() async {
    declarePanel();
    await subscribeTimeout();
    if (options.noProbe) {
      addTimeline('info', '未启动探针（--no-probe）');
      updatePanel(force: true);
      return;
    }
    if (options.agentId.isEmpty) {
      // 命令按目标 agent 的真实归属解析；没有身份就只能如实说"没启动"。
      addTimeline('error', '缺少 --agent-id，未启动探针');
      updatePanel(force: true);
      return;
    }
    unawaited(runLoop());
  }

  /// 订超时广播：**订不上也要看得见**，没有它"该响没响"就成了不可观测。
  Future<void> subscribeTimeout() async {
    try {
      final Map<String, dynamic> result = await channel.request(
        M.stationSubscribe,
        <String, dynamic>{
          'station': 'broadcast',
          'point': kPointToolTimeoutAlias,
          'replace': false,
        },
      );
      if (result['ok'] == false) {
        final String why = asString(result['error']);
        addTimeline('subscribe_error', '订阅 $kPointToolTimeout 失败：$why');
        channel.log('订阅 $kPointToolTimeout 失败：$why');
      } else {
        addTimeline('subscribe', '已订阅 $kPointToolTimeout（工具运行超时广播）');
      }
    } catch (error) {
      addTimeline('subscribe_error', '订阅 $kPointToolTimeout 失败：$error');
    }
    updatePanel(force: true);
  }

  // ── shell 家族 ───────────────────────────────────────────────────────

  /// 从回包文本里学 `shell=`（口径变了必须在时间线上看得见）。
  void learnShell(Object? text) {
    final RegExpMatch? match = _shellPattern.firstMatch('${text ?? ''}');
    if (match == null) return;
    String value = match.group(1)!.trim().toLowerCase();
    if (value == 'cmd.exe') value = 'cmd';
    if (value == 'powershell.exe') value = 'powershell';
    if (value.isEmpty || value == learnedShell) return;
    learnedShell = value;
    addTimeline('shell', '学到 shell=$value');
  }

  /// `posix` / `cmd` / `powershell`：`--shell` 优先，其次学到的，最后按插件本机平台兜底。
  String get shellKind {
    if (const <String>['posix', 'cmd', 'powershell'].contains(options.shell)) {
      return options.shell;
    }
    if (_posixShells.contains(learnedShell)) return 'posix';
    if (_cmdShells.contains(learnedShell)) return 'cmd';
    if (_powershellShells.contains(learnedShell)) return 'powershell';
    return Platform.isWindows ? 'cmd' : 'posix';
  }

  static String _sleepCommand(String kind, int seconds) {
    final int safe = math.max(1, seconds);
    switch (kind) {
      case 'powershell':
        return 'Start-Sleep -Seconds $safe';
      case 'cmd':
        return 'ping -n $safe 127.0.0.1 > nul';
      default:
        return 'sleep $safe';
    }
  }

  /// 零成本命令：三种 shell 家族都认 `echo`。
  static String _echoCommand(String text) => 'echo $text';

  /// 回包文本像"前台已经跑完"（而不是"后台已启动"）——降级时要说清为什么。
  static bool _looksFinished(String text) =>
      text.contains('退出码') ||
      text.toLowerCase().contains('exit code') ||
      text.contains('--- stderr ---');

  /// 从启动回包里挖 `task_id`：顶层字段与 text 正文两路都认（核心把它写进正文）。
  static String extractTaskId(Map<String, dynamic> payload) {
    for (final String key in <String>['task_id', 'taskId', 'id', 'handle']) {
      final Object? value = payload[key];
      if (value is String && value.isNotEmpty) return value;
    }
    final RegExpMatch? match = _taskIdPattern.firstMatch(
      asString(payload['text']),
    );
    return match?.group(1) ?? '';
  }

  // ── 命令通路 ─────────────────────────────────────────────────────────

  /// 这一次命令的身份（写进 params 顶层；空字段不写）。
  Map<String, dynamic> get scope => <String, dynamic>{
    if (options.agentId.isNotEmpty) 'agent_id': options.agentId,
    if (options.sessionId.isNotEmpty) 'session_id': options.sessionId,
  };

  /// 下 `terminal.exec` 并**按插件自己的观测窗口**等回包。
  ///
  /// 回不来不是异常而是**观测结果**（这一拍的结论就是"没回包"），所以它进时间线、
  /// 进计数，而不进栈。
  Future<Map<String, dynamic>> _terminal(
    Map<String, dynamic> arguments,
    String what,
  ) async {
    final DateTime began = DateTime.now();
    try {
      final Map<String, dynamic> payload = await channel
          .command(kCommandTerminalExec, arguments, '', scope)
          .timeout(
            Duration(
              milliseconds: (options.commandTimeoutSeconds * 1000).round(),
            ),
          );
      return <String, dynamic>{
        'ok': true,
        'payload': payload,
        'ms': DateTime.now().difference(began).inMilliseconds,
      };
    } on TimeoutException {
      return <String, dynamic>{
        'ok': false,
        'error': '$what 没回包（等了 ${options.commandTimeoutSeconds.toInt()} s）',
        'ms': DateTime.now().difference(began).inMilliseconds,
      };
    } on CmdFailureException catch (error) {
      return <String, dynamic>{
        'ok': false,
        'error': error.message,
        'ms': DateTime.now().difference(began).inMilliseconds,
      };
    } catch (error) {
      return <String, dynamic>{
        'ok': false,
        'error': '$error',
        'ms': DateTime.now().difference(began).inMilliseconds,
      };
    }
  }

  /// 零成本 canary：学 `shell=`，顺带验证 terminal 通路本身通不通。
  Future<bool> canary() async {
    final Map<String, dynamic> result = await _terminal(<String, dynamic>{
      'command': _echoCommand('terminal-probe-canary'),
    }, 'canary');
    final int ms = result['ms'] as int? ?? 0;
    if (result['ok'] != true) {
      addTimeline('error', 'canary 失败（$ms ms）：${result['error'] ?? '未知原因'}');
      return false;
    }
    learnShell(asMap(result['payload'])['text']);
    addTimeline(
      'canary',
      'terminal 通路可用（$ms ms，shell=${learnedShell.isEmpty ? '未知' : learnedShell}）',
    );
    return true;
  }

  /// 发起后台命令。返回 false = 这条路走不通（已经如实记进时间线）。
  Future<bool> startProbe() async {
    if (options.mode != 'echo' && !await canary()) {
      done = true;
      updatePanel(force: true);
      return false;
    }
    final String command = options.command.isNotEmpty
        ? options.command
        : _sleepCommand(shellKind, (options.hours * 3600).round());
    startAt = DateTime.now();
    started = true;
    addTimeline('start', '启动 terminal 命令：$command');
    channel.log(
      '启动探针：command=$command 时长=${options.hours} 小时 '
      '轮询间隔=${options.intervalSeconds} 秒 background=${options.background}',
    );
    updatePanel(force: true);

    final Map<String, dynamic> result = await _terminal(<String, dynamic>{
      'command': command,
      // ★ 核心认的键是 `hook`（`background` 文档里没有、核心也不认）。
      if (options.background) 'hook': true,
      if (options.outputFile.isNotEmpty) 'output_file': options.outputFile,
    }, '启动命令');
    if (result['ok'] != true) {
      final String error = '${result['error'] ?? '未知原因'}';
      addTimeline('error', '启动失败：$error');
      channel.log('启动失败：$error');
      done = true;
      updatePanel(force: true);
      return false;
    }
    final Map<String, dynamic> payload = asMap(result['payload']);
    taskId = extractTaskId(payload);
    lastStatusText = _short(asString(payload['text']));
    // 把回包的**键名**原样记下来：值太长不展开，但"核心给了哪些字段"正是排障要的。
    addTimeline(
      'start_payload',
      '启动回包键名=${payload.keys.toList()..sort()} text=${_short(lastStatusText)}',
    );
    addTimeline(
      'start',
      '已启动：task_id=${taskId.isEmpty ? '(无)' : taskId} text=$_shortStatus',
    );
    if (taskId.isEmpty) {
      degraded = true;
      final String note = _looksFinished(lastStatusText)
          ? '回包里没有后台句柄，且文本像是**前台跑完**的输出（核心可能不认 hook: true）'
          : '回包里没有后台句柄（task_id / handle）';
      addTimeline('warn', '$note ⇒ 降级为「通路存活探针」（每拍 echo，量耗时与成败）');
    }
    updatePanel(force: true);
    return true;
  }

  String get _shortStatus => _short(lastStatusText, 120);

  /// 主循环：立即拍一次（否则面板上"轮询 0"会持续整个 interval，像卡死），
  /// 之后每拍问一次，直到期 / 用户叫停。
  Future<void> runLoop() async {
    if (!await startProbe()) return;
    if (degraded || options.mode == 'echo') {
      await _loop(echoOnce);
    } else {
      // **启动立即拍一次**：否则前 interval 秒里面板上没有钩子存活证据，
      // "轮询 0"会持续整个间隔，看起来像卡死。
      await pollOnce();
      await _loop(pollOnce);
    }
    finish(stopRequested ? '用户提前结束' : '周期到达（${options.hours} 小时）');
  }

  Future<void> _loop(Future<void> Function() beat) async {
    final int intervalMs = (options.intervalSeconds * 1000).round();
    while (!stopRequested) {
      final DateTime? began = startAt;
      if (began == null) break;
      final DateTime until = began.add(
        Duration(seconds: (options.hours * 3600).round()),
      );
      final int leftMs = until.difference(DateTime.now()).inMilliseconds;
      if (leftMs <= 0) break;
      // 用户点「提前结束」时要**立刻**醒，所以一次只睡一小段。
      final bool woken = await _nap(
        Duration(milliseconds: math.min(intervalMs, leftMs)),
      );
      if (woken) break;
      await beat();
    }
  }

  /// 睡 [want]，期间被叫停就提前返回 true。
  Future<bool> _nap(Duration want) async {
    int slept = 0;
    final int total = want.inMilliseconds;
    while (slept < total) {
      if (stopRequested) return true;
      final int slice = math.min(200, total - slept);
      await Future<void>.delayed(Duration(milliseconds: slice));
      slept += slice;
    }
    return stopRequested;
  }

  /// 一拍 `hook_action=status`：量钩子这一拍还活着没。
  Future<void> pollOnce() async {
    if (taskId.isEmpty) return; // 没有句柄时 startProbe 已经记过 warn
    // **先计数、先留痕**，再发命令：命令一旦阻塞，面板上至少能看到"第 N 拍发出去了"，
    // 否则"没发出去"与"发出去了没回来"永远分不开。
    pollCount++;
    final int sequence = pollCount;
    addTimeline('poll_send', '轮询 #$sequence 已发出，等核心回包…');
    updatePanel(force: true);
    final Map<String, dynamic> result = await _terminal(<String, dynamic>{
      'hook_action': 'status',
      'task_id': taskId,
    }, '轮询 #$sequence');
    final int ms = result['ms'] as int? ?? 0;
    if (result['ok'] != true) {
      pollErrors++;
      final String error = '${result['error'] ?? '未知原因'}';
      addTimeline(
        'poll_error',
        '轮询 #$sequence 失败（$ms ms，累计 $pollErrors 次）：${_short(error, 160)}',
      );
      channel.log('轮询 #$sequence 失败（$ms ms）：$error');
      updatePanel();
      return;
    }
    final Map<String, dynamic> payload = asMap(result['payload']);
    final String text = asString(payload['text']);
    lastStatusText = text;
    if (payload['is_error'] == true) {
      pollErrors++;
      addTimeline(
        'poll_error',
        '轮询 #$sequence 返回 is_error（$ms ms，累计 $pollErrors 次）：${_short(text, 160)}',
      );
    } else {
      addTimeline('poll', '轮询 #$sequence 成功（$ms ms）：${_short(text, 160)}');
    }
    updatePanel();
  }

  /// 降级模式的一拍：发一条短 `echo`，量它的耗时与成败（通路会不会中途变慢/变红）。
  Future<void> echoOnce() async {
    pollCount++;
    final int sequence = pollCount;
    final Map<String, dynamic> result = await _terminal(<String, dynamic>{
      'command': _echoCommand('probe-$sequence'),
    }, '通路探测 #$sequence');
    final int ms = result['ms'] as int? ?? 0;
    if (result['ok'] != true) {
      pollErrors++;
      addTimeline(
        'poll_error',
        '通路探测 #$sequence 失败（$ms ms，累计 $pollErrors 次）：'
            '${_short('${result['error'] ?? ''}', 160)}',
      );
      updatePanel();
      return;
    }
    final Map<String, dynamic> payload = asMap(result['payload']);
    final String text = asString(payload['text']);
    learnShell(text); // shell 中途变了也要看得见
    lastStatusText = text;
    if (payload['is_error'] == true) {
      pollErrors++;
      addTimeline(
        'poll_error',
        '通路探测 #$sequence 返回 is_error（$ms ms，累计 $pollErrors 次）：${_short(text, 160)}',
      );
    } else {
      addTimeline('poll', '通路探测 #$sequence 成功（$ms ms）');
    }
    updatePanel();
  }

  /// 「提前结束」：发 `hook_action=cancel`，然后收尾。**重复点不该重复发**。
  Future<void> cancelProbe() async {
    if (done) return;
    if (taskId.isEmpty) {
      addTimeline('cancel', '无 task_id，跳过 cancel（只结束本地循环）');
    } else {
      final Map<String, dynamic> result = await _terminal(<String, dynamic>{
        'hook_action': 'cancel',
        'task_id': taskId,
      }, 'cancel');
      if (result['ok'] == true) {
        final String text = _short(
          asString(asMap(result['payload'])['text']),
          120,
        );
        addTimeline('cancel', '已发送 cancel：$text');
        channel.log('已发送 cancel：$text');
      } else {
        final String error = '${result['error'] ?? '未知原因'}';
        addTimeline('cancel_error', 'cancel 失败：$error');
        channel.log('cancel 失败：$error');
      }
    }
    stopRequested = true;
    finish('用户手动取消');
  }

  void finish(String reason) {
    if (done) return;
    done = true;
    final Duration elapsed = startAt == null
        ? Duration.zero
        : DateTime.now().difference(startAt!);
    addTimeline('end', '探针结束（$reason，已运行 ${_duration(elapsed)}）');
    channel.log('探针结束：$reason（已运行 ${_duration(elapsed)}）');
    updatePanel(force: true);
  }

  // ── 站点请求（只订了工具超时广播这一条）───────────────────────────────

  /// `station/request`：站点投过来的请求。只认真实订阅的那个点位，其余一律"不改动"。
  Map<String, dynamic> handleStationRequest(Map<String, dynamic> params) {
    final String point = asString(params['station_id']);
    if (point != kPointToolTimeout) {
      // 非本点位：不改动。`null` 与"空集合"不是一回事（见 §5.2）。
      return <String, dynamic>{
        'reply': <String, dynamic>{'payload': null},
      };
    }
    final Map<String, dynamic> payload = asMap(params['payload']);
    timeoutBroadcasts++;
    final String line =
        '核心判定超时 #$timeoutBroadcasts：tool=${_orEmpty(payload['tool'])} '
        'handle=${_orEmpty(payload['handle'])} elapsed=${payload['elapsed_ms']} ms';
    addTimeline('timeout', line);
    channel.log(line);
    // 广播也要回一条（核心在等送达确认；这里**不取消**——本探针就是要看它该响没响）。
    updatePanel();
    return <String, dynamic>{
      'reply': <String, dynamic>{'payload': null},
    };
  }

  // ── 面板 ────────────────────────────────────────────────────────────
  //
  // 站点实例 id 的口径（记在这里免得后人又去"剥 @"）：站点已**全局化**（定稿：id 不含
  // team / mode，team 是每次交互携带的信封），所以投过来的 `station_id` 就是点位常量
  // 本身；自建站 id 是 `plugin.<id>.<kind>.<name>`，永远不会撞上它。

  /// 发一次 `ui/manifest`（**声明一次就够**：前端重连由核心按缓存补发）。
  void declarePanel() {
    if (options.noPanel || _panelDeclared) return;
    channel.notify(Ui.manifest, <String, dynamic>{
      'slots': <Map<String, dynamic>>[
        <String, dynamic>{
          'slot_key': slotKey,
          'slot': 'activity',
          'title': kPanelTitle,
          'icon': 'terminal',
          'order': 25,
          'view': panelView(),
        },
      ],
    });
    _panelDeclared = true;
    channel.log('已声明左栏面板槽位 $slotKey（activity：活动栏图标 + 左栏整页）');
  }

  /// 发 `ui/update`：按 slot_key **整块替换**视图。[force] 绕过节流。
  void updatePanel({bool force = false}) {
    if (options.noPanel) return;
    final DateTime now = DateTime.now();
    if (!force && now.difference(_lastPush) < kPanelMinGap) return;
    _lastPush = now;
    channel.notify(Ui.update, <String, dynamic>{
      'slot_key': slotKey,
      'view': panelView(),
    });
  }

  /// 面板动作回传（判据在 `params.event`，别判 `method`）。
  void handleUiAction(Map<String, dynamic> params) {
    final String actionId = asString(params['action_id']);
    channel.log('面板交互：slot=${asString(params['slot_key'])} action=$actionId');
    switch (actionId) {
      case 'cancel':
        unawaited(cancelProbe());
      case 'refresh':
        updatePanel(force: true);
      default:
        channel.log('未知的面板动作（忽略）：$actionId');
    }
  }

  /// 视图（受限控件集）：概览一行 + 进度 + 最近 N 条时间线 + 按钮组。
  Map<String, dynamic> panelView() {
    final DateTime? began = startAt;
    final Duration elapsed = began == null
        ? Duration.zero
        : DateTime.now().difference(began);
    final Duration total = Duration(seconds: (options.hours * 3600).round());
    final double ratio = total.inMilliseconds <= 0
        ? 1.0
        : (elapsed.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    final String status = done
        ? '已结束'
        : began == null
        ? '未启动'
        : '运行中（剩余 ${_duration(total - elapsed)}）';
    final List<String> summary = <String>[
      '状态：$status',
      '模式：${degraded || options.mode == 'echo' ? '降级（量通路存活）' : '后台钩子'}',
      'task_id=${taskId.isEmpty ? '—' : taskId}',
      '轮询 $pollCount（失败 $pollErrors）',
      'interval=${options.intervalSeconds.round()}s',
      if (timeoutBroadcasts > 0) '超时广播 $timeoutBroadcasts 次',
      if (lastStatusText.isNotEmpty) '最近：${_short(lastStatusText, 80)}',
    ];
    final List<TimelineEntry> recent = timeline
        .skip(math.max(0, timeline.length - kMaxPanelRows))
        .toList()
        .reversed
        .toList();
    final List<List<String>> rows = <List<String>>[
      ...recent.map(
        (TimelineEntry e) => <String>[
          _clock(e.at),
          e.kind,
          _short(e.text, 200),
        ],
      ),
      if (recent.isEmpty) <String>['—', '—', '（还没有事件）'],
    ];
    return <String, dynamic>{
      'type': 'column',
      'gap': 6,
      'children': <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'text',
          'text': kPanelTitle,
          'style': 'title',
        },
        <String, dynamic>{
          'type': 'text',
          'text': summary.join(' · '),
          'style': 'caption',
        },
        <String, dynamic>{
          'type': 'progress',
          'value': ratio,
          'label': '探针周期（${options.hours} 小时）',
          'detail': '${_duration(elapsed)} / ${_duration(total)}',
        },
        <String, dynamic>{
          'type': 'table',
          'columns': <String>['时间', '事件', '详情'],
          'rows': rows,
          'caption':
              '最近 ${rows.length} 条事件（最新在最上面；kind: canary=通路预检 / '
              'shell=学到 shell / start=启动 / poll=状态查询 / poll_error=查询失败 / '
              'timeout=核心判定超时 / cancel=已发取消）',
        },
        <String, dynamic>{
          'type': 'actions',
          'buttons': <Map<String, dynamic>>[
            if (!done)
              <String, dynamic>{
                'action_id': 'cancel',
                'label': '提前结束',
                'style': 'primary',
              },
            <String, dynamic>{'action_id': 'refresh', 'label': '刷新'},
          ],
        },
      ],
    };
  }

  // ── 时间线与格式化 ───────────────────────────────────────────────────

  /// 加一条时间线（超上限就**丢最旧的**：探针要跑三小时，内存不能无上限长）。
  void addTimeline(String kind, String text) {
    timeline.add(TimelineEntry(DateTime.now(), kind, text));
    if (timeline.length > kMaxTimeline) {
      timeline.removeRange(0, timeline.length - kMaxTimeline);
    }
  }

  static String _duration(Duration span) {
    final int seconds = math.max(0, span.inSeconds);
    if (seconds < 60) return '$seconds s';
    if (seconds < 3600) return '${seconds ~/ 60} m ${seconds % 60} s';
    return '${seconds ~/ 3600} h ${(seconds % 3600) ~/ 60} m';
  }

  static String _clock(DateTime at) =>
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}:'
      '${at.second.toString().padLeft(2, '0')}';

  static String _orEmpty(Object? value) {
    final String text = asString(value);
    return text.isEmpty ? '(空)' : text;
  }
}

String _short(Object? value, [int limit = 120]) {
  final String text = value == null ? '' : '$value';
  if (limit <= 0 || text.length <= limit) return text;
  return '${text.substring(0, limit)}…';
}

/// 造一个插件服务与它的探针（自检注入 [channel]，生产走 stdio）。
///
/// 两者共用同一段接线：`station/request` 只认工具超时那个点位，面板动作只认
/// `plugin_ui_action`——自检另写一套 mock 就等于"自检绿了真核心照样能挂"。
(PluginKitServer server, Probe probe) build({
  Options? options,
  PluginChannel? channel,
}) {
  final Options given = options ?? Options();
  final PluginChannel wire = channel ?? PluginChannel.stdio('terminal_probe');
  final Probe probe = Probe(channel: wire, options: given);
  final PluginKitServer server = PluginKitServer(
    channel: wire,
    pluginId: kPluginId,
    displayName: kPanelTitle,
    capabilities: const <String>['stations'],
    // 本插件不申报工具：它只订广播点位 + 下 terminal 命令。
    onRequest: (String method, Map<String, dynamic> params) async {
      if (method != M.stationRequest) return null;
      return probe.handleStationRequest(params);
    },
    onNotify: (String method, Map<String, dynamic> params) {
      if (method == M.event) {
        if (asString(params['event']) == kEventUiAction) {
          probe.handleUiAction(params);
        }
        return;
      }
      // 裸 method 形态（老核心 / 直连测试）也收下，否则按钮会永远没反应。
      if (method == kEventUiAction) probe.handleUiAction(params);
    },
    onReady: (PluginKitServer server) => probe.startup(),
  );
  return (server, probe);
}

Future<void> main(List<String> args) async {
  if (args.contains('--selftest')) {
    exitCode = await selfTest();
    return;
  }
  final (PluginKitServer server, _) = build(options: Options.parse(args));
  await server.run(stdin);
  try {
    await stdout.flush();
  } catch (_) {
    // 管道已被对端关掉：刷不出去不算错误。
  }
}

// ── 自检（假核心走**真协议面**：订阅、下命令、推面板都是真帧）─────────────

/// 帧读取（避免每处都写一长串 asMap 嵌套）。
Map<String, dynamic> frameParams(Map<String, dynamic> frame) =>
    asMap(frame['params']);

Object? frameArgument(Map<String, dynamic> frame, String key) =>
    asMap(frameParams(frame)['arguments'])[key];

String frameCommand(Map<String, dynamic> frame) =>
    asString(frameParams(frame)['command']);

/// 一条自检用的假核心：按请求内容回**与核心同形状**的执行站信封。
///
/// 走的是真协议面（帧编码、id 关联、读循环），不是假命令通道："能调到 terminal"
/// 与"能把帧发对"在两处都会错，而后者只在真帧面上看得见。
class _Harness {
  _Harness(
    Options options, {
    Map<String, dynamic>? startPayload,
    String statusText = 'still running',
    String canaryText = 'terminal-probe-canary\nshell=bash',
  }) {
    final PluginChannel channel = PluginChannel(logTag: 'terminal_probe');
    final (PluginKitServer built, Probe builtProbe) = build(
      options: options,
      channel: channel,
    );
    server = built;
    probe = builtProbe;
    core = FakeCore(built);
    core.onMethod(
      M.stationSubscribe,
      (Map<String, dynamic> params) => <String, dynamic>{
        'ok': true,
        // 站点已全局化：实例 id 就是点位常量本身（不含 @team@mode），与核心一致。
        'station_id': kPointToolTimeout,
        'subscriber_count': 1,
      },
    );
    core.onMethod(M.stationCommand, (Map<String, dynamic> params) {
      final Map<String, dynamic> args = asMap(params['arguments']);
      final String hook = asString(args['hook_action']).toLowerCase();
      final String command = asString(args['command']);
      if (hook == 'status') {
        return _envelope(<String, dynamic>{
          'text': statusText,
          'is_error': false,
        });
      }
      if (hook == 'cancel') {
        return _envelope(<String, dynamic>{
          'text': 'cancelled',
          'is_error': false,
        });
      }
      if (command.contains('canary')) {
        return _envelope(<String, dynamic>{
          'text': canaryText,
          'is_error': false,
        });
      }
      return _envelope(
        startPayload ??
            <String, dynamic>{
              'task_id': 'task-1',
              'text': 'started (background)',
              'is_error': false,
            },
      );
    });
    unawaited(core.start());
  }

  late final Probe probe;
  late final PluginKitServer server;
  late final FakeCore core;

  static Map<String, dynamic> _envelope(Map<String, dynamic> payload) =>
      <String, dynamic>{
        'command': kCommandTerminalExec,
        'ok': true,
        'mount_id': 'harness',
        'payload': payload,
        'error': '',
      };

  /// 换成"命令一律被拒"的回包（测失败那一拍）。
  void armFailure(String reason) {
    core.onMethod(
      M.stationCommand,
      (Map<String, dynamic> params) => <String, dynamic>{
        'command': kCommandTerminalExec,
        'ok': false,
        'mount_id': 'harness',
        'payload': null,
        'error': reason,
      },
    );
  }

  /// 插件发过的 `terminal.exec` 帧（按到达顺序）。
  List<Map<String, dynamic>> execFrames() => core
      .outgoing(M.stationCommand)
      .where(
        (Map<String, dynamic> frame) =>
            frameCommand(frame) == kCommandTerminalExec,
      )
      .toList();

  /// 等"至少 [count] 条 terminal.exec 帧"（探针内部是异步任务，只能轮询）。
  Future<bool> waitExecFrames(
    int count, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (execFrames().length >= count) return true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return execFrames().length >= count;
  }

  Future<bool> waitUiFrames(String method, {int atLeast = 1}) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 6));
    while (DateTime.now().isBefore(deadline)) {
      if (core.outgoing(method).length >= atLeast) return true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return core.outgoing(method).length >= atLeast;
  }
}

/// 自检用的选项（目标身份固定写死，**不带真 agent**：这里验的是形状不是环境）。
Options _probeOptions({
  double hours = 3.0,
  double interval = 30.0,
  bool noProbe = false,
  bool noPanel = false,
  String mode = 'auto',
}) => Options()
  ..hours = hours
  ..intervalSeconds = interval
  ..agentId = 'agt_test'
  ..sessionId = 'ses_test'
  ..commandTimeoutSeconds = 5
  ..noProbe = noProbe
  ..noPanel = noPanel
  ..mode = mode;

bool _hasKind(Probe probe, String kind) =>
    probe.timeline.any((TimelineEntry entry) => entry.kind == kind);

String _kindText(Probe probe, String kind) => probe.timeline
    .where((TimelineEntry entry) => entry.kind == kind)
    .map((TimelineEntry entry) => entry.text)
    .join(' | ');

Map<String, dynamic> _firstSlot(Map<String, dynamic> manifestFrame) {
  final Object? slots = frameParams(manifestFrame)['slots'];
  if (slots is! List || slots.isEmpty) return <String, dynamic>{};
  return asMap(slots.first);
}

Map<String, dynamic> _replyOf(Map<String, dynamic>? frame) =>
    asMap(asMap(frame == null ? null : frame['result'])['reply']);

/// 假核心自检：11 组各自一个 harness（互不串帧），断言的都是**数得出来的东西**。
///
/// 与 Python 版最大的不同：那一份是把 `command()` 换成假函数跑**编排**，这一份走
/// **真帧面**——订阅、面板声明、执行站命令都在帧上断言。旧版那个"站点 id 整串相等"
/// 的 bug 就是被假命令通道遮住的（真核心给的 id 带 `@team@mode`）。
Future<int> selfTest() async {
  final SelfTest check = SelfTest(name: 'terminal_probe_plugin');
  final List<String> logs = <String>[];
  await _checkStartupShape(check, logs);
  await _checkPollBeat(check, logs);
  await _checkPollFailure(check, logs);
  await _checkTimeoutBroadcast(check, logs);
  await _checkCancelIdempotence(check, logs);
  await _checkHelloSequence(check, logs);
  await _checkPanelContent(check, logs);
  await _checkLoopAndHeartbeat(check, logs);
  await _checkUiActionShapes(check, logs);
  await _checkSilentPanel(check, logs);
  await _checkDegradedPaths(check, logs);
  return check.finish(logs);
}

/// ① 启动形状：canary 在前、`hook: true` 在启动那条上、身份在 params 顶层。
Future<void> _checkStartupShape(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(_probeOptions());
  logs.addAll(h.core.logs);
  final bool ok = await h.probe.startProbe();
  check.that(ok, 'startProbe 成功（假通道给了 task_id）');
  final List<Map<String, dynamic>> exec = h.execFrames();
  check.that(
    exec.length == 2,
    '两条 terminal.exec：canary 在前、启动在后',
    actual: '${exec.length}',
  );
  if (exec.length < 2) return;
  check.that(
    asString(frameArgument(exec[0], 'command'))
        .contains('echo terminal-probe-canary'),
    '第一拍是零成本 canary（先学 shell，再谈长跑）',
  );
  final Map<String, dynamic> startArgs = asMap(
    frameParams(exec[1])['arguments'],
  );
  check.that(startArgs['hook'] == true, '默认必须请求后台模式（入口键是 hook）');
  check.that(
    !startArgs.containsKey('background'),
    '不许发核心不认的 background 键（写了等于没写，长任务会变前台阻塞）',
  );
  check.check(
    frameParams(exec[1])['agent_id'],
    'agt_test',
    '身份写在 params 顶层（核心按目标 agent 的真实归属解析）',
  );
  check.check(
    frameParams(exec[1])['session_id'],
    'ses_test',
    'session_id 也在 params 顶层',
  );
  check.that(
    !startArgs.containsKey('agent_id') && !startArgs.containsKey('session_id'),
    '身份不许**同时**写进 arguments（旧示例就是两边都写，两份真相一定漂）',
    actual: '$startArgs',
  );
  check.check(h.probe.taskId, 'task-1', 'task_id 从回包顶层字段拿到了');
  check.check(h.probe.learnedShell, 'bash', 'canary 回包里的 shell= 学到了');
  check.check(h.probe.shellKind, 'posix', 'bash ⇒ posix 家族');
  check.that(
    asString(startArgs['command']).startsWith('sleep '),
    'posix 家族的长跑命令是 sleep（不是 Start-Sleep）',
    actual: asString(startArgs['command']),
  );
  check.that(
    _hasKind(h.probe, 'start_payload'),
    '启动回包的**键名**要留在时间线上（排障要看核心给了哪些字段）',
  );
  await h.core.close();
}

/// ② 一拍轮询：`hook_action=status` + task_id，且先留痕再发。
Future<void> _checkPollBeat(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(_probeOptions());
  logs.addAll(h.core.logs);
  await h.probe.startProbe();
  final int before = h.execFrames().length;
  await h.probe.pollOnce();
  final List<Map<String, dynamic>> exec = h.execFrames();
  check.that(
    exec.length == before + 1,
    '轮询恰好多发一条 terminal.exec',
    actual: '${exec.length - before}',
  );
  final Map<String, dynamic> args = asMap(frameParams(exec.last)['arguments']);
  check.check(args['hook_action'], 'status', '轮询发的是 hook_action=status');
  check.check(args['task_id'], 'task-1', '轮询带上 task_id（没它核心查不到句柄）');
  check.check(h.probe.pollCount, 1, '轮询计数 = 1');
  check.check(h.probe.pollErrors, 0, '成功的一拍不许计入失败');
  check.that(_hasKind(h.probe, 'poll'), '成功的一拍记进时间线');
  check.that(_hasKind(h.probe, 'poll_send'), '发之前就先留痕（"没发出去"与"发出去没回来"必须分得开）');
  await h.core.close();
}

/// ③ 失败的一拍：计数 + 上时间线 + **不把探针判死**。
Future<void> _checkPollFailure(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(_probeOptions());
  await h.probe.startProbe();
  h.armFailure('假装的钩子故障');
  await h.probe.pollOnce();
  logs.addAll(h.core.logs);
  check.check(h.probe.pollErrors, 1, '失败的一拍要计数');
  check.that(
    _hasKind(h.probe, 'poll_error'),
    '轮询失败必须记进时间线（不静默）',
    actual: _kindText(h.probe, 'poll_error'),
  );
  check.that(!h.probe.done, '一拍失败不许把探针判死（D8：不拿时长与失败次数当判据）');
  check.that(
    h.core.logs.any((String line) => line.contains('轮询 #1 失败')),
    '失败也要走日志面（面板只显示最近几条）',
    actual: h.core.logs.join(' | '),
  );
  await h.core.close();
}

/// ④⑤ 工具超时广播：计数、留痕、回"不改动"；非本点位也不许改动。
Future<void> _checkTimeoutBroadcast(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(_probeOptions());
  logs.addAll(h.core.logs);
  h.core.ask(7, M.stationRequest, <String, dynamic>{
    'request_id': 'r-1',
    'station_id': kPointToolTimeout,
    'kind': 'broadcast',
    'payload': <String, dynamic>{
      'handle': 'h-1',
      'tool': 'terminal.exec',
      'elapsed_ms': 120000,
    },
  });
  final Map<Object?, Map<String, dynamic>> got = await h.core.waitFor(<int>[7]);
  final Map<String, dynamic> reply = _replyOf(got[7]);
  check.that(
    reply.containsKey('payload') && reply['payload'] == null,
    '超时广播要回 {reply:{payload:null}}（不改动；null 与"没这个键"不是一回事）',
    actual: '${got[7]}',
  );
  check.check(h.probe.timeoutBroadcasts, 1, '超时广播要计数');
  check.that(
    _hasKind(h.probe, 'timeout'),
    '超时广播记进时间线',
    actual: _kindText(h.probe, 'timeout'),
  );
  check.that(
    _kindText(h.probe, 'timeout').contains('elapsed=120000 ms'),
    '详情里要带核心给的 elapsed（"什么时候开始不老实"就靠它）',
  );
  // 非本插件订的点位：不改动，也不许把计数加上去。
  h.core.ask(8, M.stationRequest, <String, dynamic>{
    'request_id': 'r-2',
    'station_id': 'system.relay.llm.handle',
    'kind': 'relay',
    'payload': <String, dynamic>{'messages': <Object>[]},
  });
  final Map<Object?, Map<String, dynamic>> other = await h.core.waitFor(<int>[
    8,
  ]);
  final Map<String, dynamic> otherReply = _replyOf(other[8]);
  check.that(
    otherReply.containsKey('payload') && otherReply['payload'] == null,
    '非本点位一律"不改动"（不许接管不属于自己的一跳）',
    actual: '${other[8]}',
  );
  check.check(h.probe.timeoutBroadcasts, 1, '非本点位不许动超时计数');
  check.that(
    h.execFrames().isEmpty,
    '看到超时广播**不取消**（本探针就是要看它该响没响）',
    actual: '${h.execFrames()}',
  );
  await h.core.close();
}

/// ⑥ 取消：恰好一条 cancel、幂等、结束留痕。
Future<void> _checkCancelIdempotence(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(_probeOptions());
  logs.addAll(h.core.logs);
  await h.probe.startProbe();
  await h.probe.cancelProbe();
  final List<Map<String, dynamic>> cancels = h
      .execFrames()
      .where(
        (Map<String, dynamic> frame) =>
            asString(frameArgument(frame, 'hook_action')) == 'cancel',
      )
      .toList();
  check.that(
    cancels.length == 1,
    '「提前结束」恰好发一条 cancel',
    actual: '${cancels.length}',
  );
  if (cancels.isNotEmpty) {
    check.check(
      asString(frameArgument(cancels.first, 'task_id')),
      'task-1',
      'cancel 带上 task_id',
    );
  }
  check.that(h.probe.done, '取消后探针标记结束');
  check.that(_hasKind(h.probe, 'end'), '取消要记进时间线（end）');
  final int frames = h.execFrames().length;
  await h.probe.cancelProbe();
  check.that(
    h.execFrames().length == frames,
    '重复点「提前结束」不许再发命令（已结束的探针不能二次取消）',
    actual: '${h.execFrames().length} vs $frames',
  );
  await h.core.close();
}

/// ⑦ hello 之后的帧序：面板声明 + 订阅（都走真帧），而 --no-probe 不许下命令。
Future<void> _checkHelloSequence(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(_probeOptions(noProbe: true));
  logs.addAll(h.core.logs);
  h.core.ask(0, M.hello, <String, dynamic>{'plugin_id': kPluginId});
  final Map<Object?, Map<String, dynamic>> byId = await h.core.waitFor(<int>[
    0,
  ]);
  check.check(
    asMap(byId[0]?['result'])['plugin_id'],
    kPluginId,
    'hello 回带 plugin_id（核心给的优先）',
  );
  check.check(asMap(byId[0]?['result'])['capabilities'], <String>[
    'stations',
  ], '能力只报 stations（本插件不报工具）');
  final List<Map<String, dynamic>> subscribes = h.core.outgoing(
    M.stationSubscribe,
  );
  check.that(
    subscribes.length == 1,
    'hello 之后恰好一次 station/subscribe',
    actual: '${subscribes.length}',
  );
  if (subscribes.isEmpty) return;
  final Map<String, dynamic> sub = frameParams(subscribes.first);
  check.check(sub['station'], 'broadcast', '按类型订广播站（不写 station_id）');
  check.check(
    sub['point'],
    kPointToolTimeoutAlias,
    '点位用别名 tool.timeout（点位表里写的那一条）',
  );
  final List<Map<String, dynamic>> manifests = h.core.outgoing(Ui.manifest);
  check.that(
    manifests.length == 1,
    'ui/manifest 恰好一次（声明一次就够：重连由核心按缓存补发）',
    actual: '${manifests.length}',
  );
  final Map<String, dynamic> slot = _firstSlot(manifests.first);
  check.check(slot['slot'], 'activity', '槽位类型是 activity（左栏整页）');
  check.check(slot['slot_key'], h.probe.slotKey, 'slot_key 带实例 id（两个实例互不覆盖）');
  check.that(
    asString(slot['title']).isNotEmpty && asString(slot['icon']).isNotEmpty,
    '槽位得有 title 与 icon',
    actual: '$slot',
  );
  final List<String> problems = validateUiView(slot['view']);
  check.that(
    problems.isEmpty,
    '声明里的视图必须过受限控件集（非法 = 核心整帧拒发，而插件以为成功了）',
    actual: problems.join('；'),
  );
  final String rendered = json.encode(slot);
  check.that(
    rendered.contains('cancel') && rendered.contains('refresh'),
    '面板得有「提前结束」与「刷新」两个按钮',
    actual: _short(rendered, 200),
  );
  check.that(
    h.execFrames().isEmpty,
    '--no-probe 只声明面板，不许下任何 terminal 命令',
    actual: '${h.execFrames()}',
  );
  check.that(_hasKind(h.probe, 'info'), '未启动探针也要在时间线上说一句');
  // 上面那堆事是在 hello 的处理里做的；心跳因此**必须**还能进来。
  h.core.ask(1, M.ping);
  check.that(
    (await h.core.waitFor(<int>[
      1,
    ], timeout: const Duration(seconds: 2))).containsKey(1),
    '开工动作做完之后 ping 仍然答得上（铁律 2）',
  );
  await h.core.close();
}

/// ⑧ 面板内容：跑过几拍之后，视图里得看得到那些事实。
Future<void> _checkPanelContent(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(_probeOptions());
  logs.addAll(h.core.logs);
  await h.probe.startProbe();
  await h.probe.pollOnce();
  h.probe.handleStationRequest(<String, dynamic>{
    'station_id': kPointToolTimeout,
    'kind': 'broadcast',
    'payload': <String, dynamic>{'tool': 'terminal.exec', 'elapsed_ms': 120000},
  });
  final String text = json.encode(h.probe.panelView());
  for (final String must in <String>[
    'task-1',
    'start',
    'poll',
    'timeout',
    kPanelTitle,
    '轮询 1（失败 0）',
  ]) {
    check.that(
      text.contains(must),
      '面板视图里要能看到「$must」',
      actual: _short(text, 200),
    );
  }
  final List<String> problems = validateUiView(h.probe.panelView());
  check.that(problems.isEmpty, '跑过几拍之后的视图仍然合法', actual: problems.join('；'));
  await h.core.close();
}

/// ⑨ 循环：极小周期能自己退出，而且跑着的时候心跳照答。
Future<void> _checkLoopAndHeartbeat(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(_probeOptions(hours: 0.0003, interval: 0.05));
  final DateTime began = DateTime.now();
  unawaited(h.probe.runLoop());
  await Future<void>.delayed(const Duration(milliseconds: 200));
  h.core.ask(9, M.ping);
  final Map<Object?, Map<String, dynamic>> pong = await h.core.waitFor(<int>[
    9,
  ], timeout: const Duration(seconds: 2));
  check.that(pong.containsKey(9), '探针循环跑着的时候 ping 仍然答得上（读循环不被轮询压住）');
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!h.probe.done && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  logs.addAll(h.core.logs);
  check.that(h.probe.done, '周期到达 ⇒ 循环自己退出（不许永远挂着）');
  check.that(
    h.probe.pollCount >= 2,
    '这一轮真的问过好几拍',
    actual: '${h.probe.pollCount}',
  );
  check.that(_hasKind(h.probe, 'end'), '结束要记一条 end');
  check.that(
    DateTime.now().difference(began) < const Duration(seconds: 8),
    '循环没有拖过预算',
    actual: '${DateTime.now().difference(began)}',
  );
  await h.core.close();
}

/// ⑩ 面板动作回传：`event` 形态与裸 method 形态都要认，未知动作要留一行。
Future<void> _checkUiActionShapes(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(_probeOptions());
  await h.probe.startProbe();
  final int before = h.execFrames().length;
  h.core.notify(M.event, <String, dynamic>{
    'event': kEventUiAction,
    'slot_key': h.probe.slotKey,
    'action_id': 'cancel',
    'payload': <String, dynamic>{},
  });
  check.that(
    await h.waitExecFrames(before + 1, timeout: const Duration(seconds: 3)),
    'event 形态的面板动作要真的发出去（判据在 params.event，别判 method）',
  );
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!h.probe.done && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  check.that(h.probe.done, '「提前结束」得把探针标记结束');

  // 裸 method 形态（老核心 / 直连测试）：refresh 要推一帧 ui/update。
  final _Harness legacy = _Harness(_probeOptions());
  await legacy.probe.startProbe();
  final int updates = legacy.core.outgoing(Ui.update).length;
  legacy.core.notify(kEventUiAction, <String, dynamic>{
    'action_id': 'refresh',
    'slot_key': legacy.probe.slotKey,
  });
  check.that(
    await legacy.waitUiFrames(Ui.update, atLeast: updates + 1),
    '裸 method=plugin_ui_action 的 refresh 也要刷面板',
    actual: '${legacy.core.outgoing(Ui.update).length} vs $updates',
  );
  legacy.core.notify(kEventUiAction, <String, dynamic>{'action_id': 'nope'});
  await Future<void>.delayed(const Duration(milliseconds: 60));
  check.that(
    legacy.core.logs.any((String line) => line.contains('未知的面板动作')),
    '未知动作不许静默吞掉',
    actual: legacy.core.logs.join(' | '),
  );
  logs.addAll(h.core.logs);
  logs.addAll(legacy.core.logs);
  await h.core.close();
  await legacy.core.close();
}

/// ⑪ --no-panel：一帧 UI 都不发。
Future<void> _checkSilentPanel(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(_probeOptions(noPanel: true, noProbe: true));
  h.probe.declarePanel();
  h.probe.updatePanel(force: true);
  logs.addAll(h.core.logs);
  check.that(
    h.core.outgoing(Ui.manifest).isEmpty && h.core.outgoing(Ui.update).isEmpty,
    '--no-panel 时一帧 UI 都不发（面板不是后台探针的代价）',
    actual: '${h.core.outgoing()}',
  );
  await h.core.close();
}

/// ⑫ 拿不到句柄的两种形状：都像"前台跑完了"与"就是没句柄"，都得降级且留痕。
Future<void> _checkDegradedPaths(SelfTest check, List<String> logs) async {
  final _Harness noId = _Harness(
    _probeOptions(),
    startPayload: <String, dynamic>{
      'text': 'started (no id)',
      'is_error': false,
    },
  );
  final bool started = await noId.probe.startProbe();
  logs.addAll(noId.core.logs);
  check.that(started, '没有 task_id 的启动回包也算启动成功（降级不是失败）');
  check.that(noId.probe.degraded, '拿不到句柄 ⇒ 标记降级');
  check.that(_hasKind(noId.probe, 'warn'), '没有句柄必须记一条 warn（不许静默改用别的探针）');
  check.that(
    _kindText(noId.probe, 'warn').contains('没有后台句柄'),
    'warn 要如实说"没有句柄"',
    actual: _kindText(noId.probe, 'warn'),
  );
  check.that(
    !_kindText(noId.probe, 'warn').contains('前台跑完'),
    '文本不像跑完时，不许把"没句柄"说成"前台跑完了"（两种现场后续查法不同）',
    actual: _kindText(noId.probe, 'warn'),
  );
  final int frames = noId.execFrames().length;
  await noId.probe.pollOnce();
  check.that(
    noId.execFrames().length == frames,
    '没有 task_id 时不许发 hook_action=status（核心只会回一句缺 task_id）',
  );

  // 降级循环走 echo 拍（量的就是"通路一直可用吗"）。周期刻意给到极短，
  // 并且**由 runLoop 自己启动一次**：在这里重复 start 会把长跑任务起两遍。
  final _Harness loop = _Harness(
    _probeOptions(hours: 0.0003, interval: 0.05),
    startPayload: <String, dynamic>{
      'text': 'started (no id)',
      'is_error': false,
    },
  );
  await loop.probe.runLoop();
  logs.addAll(loop.core.logs);
  final List<Map<String, dynamic>> beats = loop
      .execFrames()
      .where(
        (Map<String, dynamic> frame) =>
            asString(frameArgument(frame, 'command')).startsWith('echo probe-'),
      )
      .toList();
  check.that(
    beats.isNotEmpty,
    '降级模式每一拍发的是 echo probe-N',
    actual: '${beats.length}',
  );
  check.that(
    loop.execFrames().every(
      (Map<String, dynamic> frame) =>
          frameArgument(frame, 'hook_action') == null,
    ),
    '降级后不许再发 hook_action（没句柄可查，发了就是假装有）',
  );
  check.that(loop.probe.done, '降级循环到期也要自己收尾');

  final _Harness foreground = _Harness(
    _probeOptions(),
    startPayload: <String, dynamic>{'text': '命令已完成，退出码 0', 'is_error': false},
  );
  await foreground.probe.startProbe();
  logs.addAll(foreground.core.logs);
  check.that(
    _kindText(foreground.probe, 'warn').contains('前台跑完'),
    '回包像"前台跑完"时，warn 要说得出这个区别（否则现场分不开）',
    actual: _kindText(foreground.probe, 'warn'),
  );
  await noId.core.close();
  await loop.core.close();
  await foreground.core.close();
}
