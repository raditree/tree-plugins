// **内置插件：sample（示例插件，Dart）**——四站 + 插件布局的全链路参考实现。
//
// 一句话：**它把核心发来的每一次工具调用都数一遍；某个 (agent, session) 超过阈值，
// 就经执行站发 `agent.stop` 停掉这一轮**——这正是 Q8「核心不设工具轮次上限，限制交给
// 插件做」的参考实现。同时把当前计数推成前端消息流里的一张卡片（插件布局）。
//
// 四件事（与本文件内的四段实现一一对应）：
//
// 1. **收集站**（[SamplePlugin.handleStationRequest]）：核心按站点 schema 来收集工具
//    定义，本插件申报 echo / rounds / read_probe 三个工具，于是模型能调到
//    `plugin__<插件id>__echo`（插件 id 取 plugins.yaml 的 id；id: sample 时为
//    `plugin__sample__echo`）。`tools/call` 时返回结果。
// 2. **广播 / 事件订阅**（[SamplePlugin.onEvent] + [SamplePlugin.doStop]）：接收
//    `agent.tool_call` 事件，按 (agent_id, session_id) 计数；**超过阈值（默认 200）**
//    就经 station/command 发 `agent.stop`；发完**重置计数**并打一条可见日志（避免反复停）。
//    事件派发只看 scope 里限定的维度，空 scope = 收全部事件，所以计数与 team 声明无关。
// 3. **执行站**（[SamplePlugin.fsRead] / [SamplePlugin.startup]）：插件**主动**下
//    `fs.read` 命令读工作空间里的小文件，把结果打进日志（关键结论另发 log 通知，前端可见）。
// 4. **插件布局**（[SamplePlugin.declarePanel] / [SamplePlugin.pushCard]）：
//    `ui/manifest` 申报三个槽位（activity 左侧活动栏 + panel 右栏 Tab + **card 消息流
//    卡片**），之后用 `ui/update` 与 `ui.push` 刷新它们，内容 = 当前计数 / 阈值 / 进度。
//    ⚠ card 槽位必须先在 manifest 里申报：`ui.push` 只发 update 帧、不建槽位，
//    没申报过的 slot_key 会被前端静默忽略（卡片永远不出现，且没有任何报错）。
//
// 5. **点位化的新能力**（全部**默认关闭**、各自一个开关）——这些是"新协议怎么用"的
//    可运行答案：
//
//    | 开关 | 演示的点位 / 命令 | 落点 |
//    |---|---|---|
//    | `--relay-llm <关键词>` | 中转点位 `system.relay.llm.handle`：**流式接管**（thinking + text 分片 + 可选 tool_call），末条 user 消息不含关键词就回 `null` 不接管 | [SamplePlugin.handleLlmHandle] / [SamplePlugin.streamWorker] |
//    | `--relay-llm-tool-call` | 流式接管里**多推一段 `tool_call`**（默认不推：它会真的触发一次工具调用，干扰其它演示） | [SamplePlugin.streamWorker] |
//    | `--relay-prompt` | 中转点位 `system.relay.prompt.system`：在 `default` 后面追加一行 | [SamplePlugin.handlePromptSystem] |
//    | `--llm-call <prompt>` | 执行站 `llm.call`：站点处硬设 `response_format=json_object`，打印回来的 `json` | [SamplePlugin.doLlmCall] |
//    | `--tool-call <tool> <json-args>` | 执行站 `tool.call`：默认**绕开**工具中转 / 广播（`relay:false`） | [SamplePlugin.doToolCall] |
//    | `--rename-session` | 执行站 `session.rename`：把当前会话改成带时间戳的标题 | [SamplePlugin.doRenameSession] |
//    | `--watch-tools` | 广播点位 `system.broadcast.tool.pre` + `.tool.post`：统计"看到了 N 次工具调用"并推到面板 | [SamplePlugin.handleToolBroadcast] |
//    | `--self-station` | 插件**自建站**：`station/register` → 用核心返回的 id 订自己 | [SamplePlugin.registerOwnStation] |
//
//    三条**流式硬约束**（不看会踩，都在 [SamplePlugin.streamWorker] 里体现）：
//    - **回包先发、增量后台推**：`station/request` 的回包与之后的 `station/stream`
//      增量是同一根 stdout。骨架的读循环从不 await 业务（铁律 2），所以这里回包立刻
//      发（声明 `{"stream": true}`），增量挂在后台任务上——推流期间 `ping` 照样答得出。
//    - **开流后不可回退**：说了 `stream:true` 就必须 `done` 或 `error` 收尾；收到
//      `station/cancel`（下行通知）要停流，之后**不要再**推 `done`（核心已经收尾）。
//    - **`request_id` 必须原样带回**：每个 `station/stream` 都从请求的
//      `params.request_id` 取（⚠ 它在 **params 顶层**，不在 payload 里，也不是
//      JSON-RPC 的报文 id）。自己编一个 id 的后果是核心把整条流丢掉，而插件这边
//      看上去"全都发出去了"。
//
// ── 协议（行分隔 JSON-RPC 2.0；读循环、异常收敛、stdout/stderr 分面都在 `_kit`）──
//
// 核心 → 插件：hello（握手，params 带 plugin_id）/ tools/list / tools/call /
//   station/request（站点请求：收集站采集 / 中转站拦截 / 广播站通知）/ ping（心跳）
//   是**请求**；event（总线事件：**面板动作也走它**——判据在 `params.event` 上，
//   别判 `method`）/ station/cancel（下行：我接管的 LLM 流该收了）/ shutdown 是**通知**。
//
// 插件 → 核心按**报文形状**分三类（顺序即优先级）：响应（有 id 无 method）/
//   请求（method + id，核心必回一条：`station/command`、`station/subscribe`、
//   `station/register`）/ 通知（无 id：`log`、`ui/manifest`、`ui/update`、
//   `station/stream`）。错误码 -32601 未知方法 / -32602 参数 / -32603 处理器异常 /
//   -32001 scope 不满足。
//
// ── 边界情况（踩过的坑，务必保留）──────────────────────────────────────────
//
// * **stdout 只允许 JSON-RPC**：任何日志走 stderr（骨架已经把两面分开了）。
// * **绝不在读循环里同步等回包**：处理 `tools/call` 时本插件还要「主动问核心」
//   （read_probe 要等 `fs.read` 的回包），而回包同样从 stdin 进来——Python 版为此
//   显式开线程，Dart 版由骨架的 unawaited 任务承担（单线程事件循环，因此**不需要锁**：
//   计数与判定都在同步段做完，只有等回包的那一段在后台）。
// * **插件主动请求带 method + id**：id 由骨架生成（`plugin-req-N`），核心用
//   "有没有 method"区分响应与请求。
// * **station/request 回包形状** = `{reply: {payload: {...}}}`；**不要**回带 scope——
//   回带了就必须与请求四元组**精确相等**，否则整条回包被判跨 scope 拒绝。
// * **收集站 schema 是严格校验**：根对象只允许 `tools` 一个键（多一个键即报"未声明的
//   字段"）；每个工具定义含 tool_name / description / parameters / execution。
// * **阈值触发后重置计数**：否则每一次后续调用都会再发一次 `agent.stop`（反复停）。
// * **空 scope = 通配（作用于所有 team）**：plugins.yaml 不写 `scope.team_id` 也能
//   `station/subscribe`（空 team 收所有 team 的消息、空 mode 收 local 与 ssh），
//   `ui.push` 的帧带空 team_id（前端在任何 team 下都呈现）。仍然 fail-closed 的只有
//   **消息信封**（中转 / 广播 / 收集的数据面必须能证明 team）与**执行类命令的落地**
//   （挂载位置解析不出目标 agent 的 team / 工作面就拒绝执行）。
//   本插件对"订阅被拒"仍留一层防御性兜底（旧核心）：等第一个事件给出 `agent_id` 后
//   补订一次、`ui.push` 带上该身份。新核心里这条路径不会被触发。
// * **命令身份只写在 params 顶层**（`agent_id` / `session_id` / `team_id` /
//   `mode_key`）：核心两处都读（`_resolveCommandScope` 先看 params 再看 arguments），
//   但**两份真相写同一个东西一定漂**，所以这里只写顶层。
// * **命令失败也带着 payload**：核心对 `llm.call` 的口径是"失败也把 `text` /
//   `error_kind` / `truncated_suspect` 放进 payload 递回来"，只留一句 error 就等于
//   把已经付过费的那次调用丢掉（known-issues #31）。
//
// 跑起来（**不需要真核心**）：
//     dart run plugins/sample/sample_plugin.dart --selftest
// 编译：`dart run tool/build_plugins.dart --only sample`
// 命令行参数与同名环境变量见 [helpText]（`--help` 打到 **stderr**，不打 stdout）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../_kit/plugin_kit.dart';

const String kPluginId = 'sample';
const String kPluginName = '示例插件';

// ── 事件名 / 点位 id / 命令名（点位化：每个接入点是一个**独立站点实例**）────
const String kEventToolCall = 'agent.tool_call';

/// **面板按钮回调的事件名**。判据在 `params.event` 上（核心把前端动作包成
/// `method:"event"` 的通知，与 `agent.tool_call` 同一范式）——判 `method` 会永远不命中。
const String kEventUiAction = 'plugin_ui_action';

const String kPhaseStart = 'start';
const String kPhaseEnd = 'end';

const String kPointRelayToolPre = 'system.relay.tool.pre';
const String kPointRelayToolPost = 'system.relay.tool.post';
const String kPointRelayLlmHandle = 'system.relay.llm.handle';
const String kPointRelayPromptSystem = 'system.relay.prompt.system';
const String kPointBroadcastToolPre = 'system.broadcast.tool.pre';
const String kPointBroadcastToolPost = 'system.broadcast.tool.post';

/// 收集站：核心按类型找插件收集工具定义（不是点位，按 `kind: collect` 认）。
const String kPointToolDefine = 'plugin.tool.define';

// 命令名（执行站按命令族分点位；对插件透明，仍然只带 command）
const String kCommandFsRead = 'fs.read';
const String kCommandUiPush = 'ui.push';
const String kCommandAgentStop = 'agent.stop';
const String kCommandLlmCall = 'llm.call';
const String kCommandToolCall = 'tool.call';
const String kCommandSessionRename = 'session.rename';

const int kDefaultThreshold = 200;
const String kDefaultSlotKey = 'sample.card.tool_rounds';

/// 流式接管的默认触发关键词（只有"最后一条 user 消息含它"才接管）。
const String kDefaultRelayLlmKeyword = '示例插件接管';

/// `--relay-prompt` 追加的那一行：这段提示词被插件动过的**可见证据**。
const String kPromptMarker = '（本提示词由示例插件改写）';

/// 单槽位声明的上限（与核心 `kMaxManifestBytes` 同一条）：超了整份 manifest 会被拒。
const int kMaxSlotBytes = 64 * 1024;

// ── 环境变量名（命令行 > 环境变量 > 默认值）───────────────────────────────
const String kEnvThreshold = 'SAMPLE_PLUGIN_TOOL_ROUND_LIMIT';
const String kEnvAgentId = 'SAMPLE_PLUGIN_AGENT_ID';
const String kEnvReadPath = 'SAMPLE_PLUGIN_READ_PATH';
const String kEnvTeamId = 'SAMPLE_PLUGIN_TEAM_ID';
const String kEnvSlotKey = 'SAMPLE_PLUGIN_SLOT_KEY';
const String kEnvCardInterval = 'SAMPLE_PLUGIN_CARD_INTERVAL';
const String kEnvCascade = 'SAMPLE_PLUGIN_STOP_CASCADE';
const String kEnvRelayLlm = 'SAMPLE_PLUGIN_RELAY_LLM';
const String kEnvLlmCall = 'SAMPLE_PLUGIN_LLM_CALL';
const String kEnvToolCall = 'SAMPLE_PLUGIN_TOOL_CALL';
const String kEnvToolCallArgs = 'SAMPLE_PLUGIN_TOOL_CALL_ARGS';

/// 真值写法（环境变量开关）：大小写都认，与 Python 版那四个字符串同集合。
const Set<String> _truthy = <String>{'1', 'true', 'yes'};

/// 运行参数：命令行 > 环境变量 > 默认值。
class Options {
  int threshold = kDefaultThreshold;

  /// 执行站命令的目标 agent（留空 ⇒ 用事件 / 站点请求里见过的第一个；都没有就不发）。
  String agentId = '';

  /// 启动自检要读的工作空间文件（相对路径）。
  String readPath = 'README.md';

  /// 仅用于日志/卡片文案；**作用域以 plugins.yaml 为准**。
  String teamId = '';

  String slotKey = kDefaultSlotKey;

  /// 卡片周期刷新秒数（0 = 不起周期任务，自检用）。
  double cardInterval = 5.0;

  /// 事件密集时的最小推送间隔（秒）：节流，避免刷屏。
  double cardMinInterval = 1.0;

  /// `agent.stop` 是否级联停整棵团队树（默认只停该 agent）。
  bool cascade = false;

  bool fsDemo = true;

  /// 中转站订阅：工具调用前/后各来一次（pre / post），插件决定改不改。
  bool relay = true;

  /// 声明左侧活动栏 / 右栏面板 / 消息流卡片槽位（ui/manifest；card 必须先申报）。
  bool panel = true;

  /// 自建站点演示（`station/register` + 按 station_id 订阅）。
  bool selfStation = false;

  // ── 点位化新增演示：**全部默认关闭**（既有默认行为一个字不变）────────────
  String relayLlm = '';
  bool relayLlmToolCall = false;
  bool relayPrompt = false;
  String llmCall = '';
  String toolCall = '';
  Map<String, dynamic> toolCallArgs = const <String, dynamic>{};
  bool renameSession = false;
  bool watchTools = false;
  bool selftest = false;

  /// **自检用**：把推流的片间隔调小（默认 250ms 是给真人看的"逐字到达"，
  /// 自检断言的是形状不是观感）。不影响任何协议字段。
  int streamChunkPauseMs = 250;
}

/// 用法文本。**必须走 stderr**：stdout 是协议通道，`--help` 也不能污染它。
String helpText() =>
    '''
sample_plugin（Dart，随包二进制）—— tree_core 示例插件
命令行参数（同名环境变量见括号）：
  --threshold N        工具轮次阈值，超过即发 agent.stop（默认 $kDefaultThreshold）（$kEnvThreshold）
  --agent-id ID        执行站命令的目标 agent（默认取事件里的 agent）（$kEnvAgentId）
  --read-path PATH     启动自检要读的工作空间文件，相对路径（默认 README.md）（$kEnvReadPath）
  --team-id TEAM       仅用于日志/卡片文案；作用域以 plugins.yaml 为准（$kEnvTeamId）
  --slot-key KEY       卡片槽位键（默认 $kDefaultSlotKey）（$kEnvSlotKey）
  --card-interval SEC  卡片周期刷新秒数（默认 5）（$kEnvCardInterval）
  --stop-cascade       agent.stop 级联停整棵团队树（默认只停该 agent）（$kEnvCascade=1）
  --no-relay           不订阅中转站（默认订阅：工具调用前/后各一次）
  --self-station       自建一个广播站并订阅它（演示插件自建站点：站点全局唯一 +
                       每个点位只有一个订阅者，需按 team 分流时由插件自己建站分发）
  --no-panel           不声明插件面板槽位（默认声明 activity + panel + card）
  --no-fs-demo         不做启动 fs.read 自检
  --relay-llm KEYWORD  订阅 system.relay.llm.handle，最后一条 user 消息含 KEYWORD 时
                       **流式接管**这一跳（thinking + 分片正文 + done；不含则回 null）
                       （$kEnvRelayLlm）
  --relay-llm-tool-call 流式接管里多推一段 tool_call（默认不推：会真的触发一次工具
                       调用，干扰别的演示）
  --relay-prompt       订阅 system.relay.prompt.system，在 default 后面追加一行
                       「$kPromptMarker」
  --llm-call PROMPT    启动后发一次执行站 llm.call（站点处硬设 response_format=
                       json_object），把 json 打进日志（$kEnvLlmCall）
  --tool-call TOOL JSON 启动后发一次执行站 tool.call，打印 result / is_error。
                       JSON 是 arguments 对象，如 '{}'（$kEnvToolCall / $kEnvToolCallArgs）
  --rename-session     用 session.rename 把当前会话改成带时间戳的标题
  --watch-tools        订阅 system.broadcast.tool.pre / .tool.post，统计并在面板显示
                       「看到了 N 次工具调用」
  --selftest           用**假核心**跑一遍协议自检（不连真核心，无需参数）
  -h, --help           本帮助（打到 stderr；注意 stdout 是协议通道）
''';

/// 一次解析的结果：[code] 非 0 = 参数非法（写 stderr、退 2）；[help] = 只要了用法。
class Parsed {
  Parsed._(this.options, this.code, this.message, this.help);

  factory Parsed.ok(Options options) => Parsed._(options, 0, '', false);

  factory Parsed.usage(Options options) =>
      Parsed._(options, 0, helpText(), true);

  /// 参数非法退 **2**（与 Python 版一致）。缺失取值、JSON 不是对象、未知参数都走这里；
  /// 数字写坏也走这里（Python 版会抛 ValueError  traceback 退 1 —— 那是"插件自己
  /// 崩了"而不是"你的参数不对"，这里把它改成一句人话）。
  factory Parsed.bad(String message) => Parsed._(Options(), 2, message, false);

  final Options options;
  final int code;
  final String message;
  final bool help;
}

/// 手写解析（不用 arg 包：要保证 --help / 报错都不写 stdout）。
///
/// [env] 是测试注入点（默认取 `Platform.environment`）：解释器进程里改不了自己的
/// 环境表，不注入就没有一条用例能证明"环境变量兜底"这条路真的读到了值。
Parsed parseOptions(List<String> argv, {Map<String, String>? env}) {
  final Map<String, String> environment = env ?? Platform.environment;
  String fromEnv(String name) => (environment[name] ?? '').trim();
  final Options options = Options();

  // ── 环境变量兜底 ─────────────────────────────────────────────────────
  final String thresholdEnv = fromEnv(kEnvThreshold);
  if (thresholdEnv.isNotEmpty) {
    final int? number = int.tryParse(thresholdEnv);
    if (number == null) {
      return Parsed.bad('环境变量 $kEnvThreshold 需要整数，收到：$thresholdEnv');
    }
    options.threshold = number;
  }
  final String cardEnv = fromEnv(kEnvCardInterval);
  if (cardEnv.isNotEmpty) {
    final double? seconds = double.tryParse(cardEnv);
    if (seconds == null) {
      return Parsed.bad('环境变量 $kEnvCardInterval 需要秒数，收到：$cardEnv');
    }
    options.cardInterval = seconds;
  }
  if (_truthy.contains(fromEnv(kEnvCascade).toLowerCase())) {
    options.cascade = true;
  }
  options.agentId = _or(fromEnv(kEnvAgentId), options.agentId);
  options.readPath = _or(fromEnv(kEnvReadPath), options.readPath);
  options.teamId = _or(fromEnv(kEnvTeamId), options.teamId);
  options.slotKey = _or(fromEnv(kEnvSlotKey), options.slotKey);
  options.relayLlm = _or(fromEnv(kEnvRelayLlm), options.relayLlm);
  options.llmCall = _or(fromEnv(kEnvLlmCall), options.llmCall);
  options.toolCall = _or(fromEnv(kEnvToolCall), options.toolCall);
  final String toolArgsEnv = fromEnv(kEnvToolCallArgs);
  if (toolArgsEnv.isNotEmpty) {
    final (Map<String, dynamic>? value, String error) = _jsonObject(
      toolArgsEnv,
      kEnvToolCallArgs,
    );
    if (value == null) return Parsed.bad(error);
    options.toolCallArgs = value;
  }

  // ── 命令行 ───────────────────────────────────────────────────────────
  int index = 0;
  while (index < argv.length) {
    final String token = argv[index];
    if (token == '-h' || token == '--help') return Parsed.usage(options);
    if (token == '--selftest') {
      options.selftest = true;
      index++;
      continue;
    }
    if (token == '--no-fs-demo') {
      options.fsDemo = false;
      index++;
      continue;
    }
    if (token == '--no-relay') {
      options.relay = false;
      index++;
      continue;
    }
    if (token == '--no-panel') {
      options.panel = false;
      index++;
      continue;
    }
    if (token == '--self-station') {
      options.selfStation = true;
      index++;
      continue;
    }
    if (token == '--stop-cascade') {
      options.cascade = true;
      index++;
      continue;
    }
    if (token == '--relay-llm-tool-call') {
      options.relayLlmToolCall = true;
      index++;
      continue;
    }
    if (token == '--relay-prompt') {
      options.relayPrompt = true;
      index++;
      continue;
    }
    if (token == '--rename-session') {
      options.renameSession = true;
      index++;
      continue;
    }
    if (token == '--watch-tools') {
      options.watchTools = true;
      index++;
      continue;
    }
    // `--tool-call` 要两个取值（工具名 + arguments 的 JSON 对象），单独解析。
    // 少给一个不是"参数没生效"，是**用法错**：静默吞掉会让人以为演示已经跑了。
    if (token == '--tool-call') {
      if (index + 2 >= argv.length) {
        return Parsed.bad(
          '参数 --tool-call 需要两个取值：工具名 与 arguments 的 JSON 对象'
          '（例如 --tool-call read \'{"path": "a.txt"}\'）',
        );
      }
      final (Map<String, dynamic>? value, String error) = _jsonObject(
        argv[index + 2],
        '--tool-call',
      );
      if (value == null) return Parsed.bad(error);
      options.toolCall = argv[index + 1];
      options.toolCallArgs = value;
      index += 3;
      continue;
    }
    if (token == '--threshold') {
      final String? raw = _peek(argv, index);
      if (raw == null) return Parsed.bad('参数 $token 缺少取值');
      final int? number = int.tryParse(raw.trim());
      if (number == null) return Parsed.bad('参数 --threshold 需要整数，收到：$raw');
      options.threshold = number;
      index += 2;
      continue;
    }
    if (token == '--card-interval') {
      final String? raw = _peek(argv, index);
      if (raw == null) return Parsed.bad('参数 $token 缺少取值');
      final double? seconds = double.tryParse(raw.trim());
      if (seconds == null) {
        return Parsed.bad('参数 --card-interval 需要秒数，收到：$raw');
      }
      options.cardInterval = seconds;
      index += 2;
      continue;
    }
    switch (token) {
      case '--agent-id':
        options.agentId = _value(argv, index) ?? options.agentId;
      case '--read-path':
        options.readPath = _value(argv, index) ?? options.readPath;
      case '--team-id':
        options.teamId = _value(argv, index) ?? options.teamId;
      case '--slot-key':
        options.slotKey = _value(argv, index) ?? options.slotKey;
      case '--relay-llm':
        options.relayLlm = (_value(argv, index) ?? '').trim();
      case '--llm-call':
        options.llmCall = (_value(argv, index) ?? '').trim();
      default:
        return Parsed.bad('未知参数：$token（用 --help 看用法；注意 stdout 是协议通道）');
    }
    index += 2;
  }
  return Parsed.ok(options);
}

String _or(String value, String fallback) => value.isEmpty ? fallback : value;

/// 下一个 token（没有 = null，表示"参数缺少取值"）。
String? _peek(List<String> argv, int index) =>
    index + 1 < argv.length ? argv[index + 1] : null;

String? _value(List<String> argv, int index) => _peek(argv, index);

/// 把一段 JSON **对象**解析出来（**只接受对象**）；失败时返回 (null, 可读原因)。
(Map<String, dynamic>?, String) _jsonObject(String raw, String source) {
  if (raw.trim().isEmpty) {
    return (null, '$source 需要 JSON **对象**（如 {"path": "a.txt"}），收到：空');
  }
  Object? decoded;
  try {
    decoded = json.decode(raw);
  } catch (error) {
    return (null, '$source 的 JSON 解析失败：$error（收到：$raw）');
  }
  if (decoded is! Map) {
    return (null, '$source 需要 JSON **对象**（如 {"path": "a.txt"}），收到：$raw');
  }
  return (asMap(decoded), '');
}

/// 带秒位的时钟（日志前缀；只在失败回放时有用，不参与任何判定）。
String _clock(DateTime now) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
}

/// 截断长文本（日志与面板里不能塞下一整个文件；留原文头部就够定位）。
String _clip(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max)}…';

/// 一次执行站命令的结果：**与核心的信封同形**（`{command, ok, mount_id, payload, error}`）。
///
/// 为什么不用骨架的 `channel.command()`（它成功只给 payload、失败只抛原因）：这份示例
/// 要演示的就是"信封看得见"——`agent.stop` 的回包里有 `mount_id`（命令落在哪个点位），
/// `fs.read` 的 payload 里有 `truncated`。把信封拍平成 payload 之后，那些字段就在
/// 插件这一侧永久消失了，而排障时最需要问的正是"你那条命令到底落在哪"。
class CommandOutcome {
  CommandOutcome({
    required this.ok,
    required this.payload,
    this.error = '',
    this.mountId = '',
    this.command = '',
  });

  final bool ok;
  final Map<String, dynamic> payload;
  final String error;
  final String mountId;
  final String command;
}

/// 一路在途的流式接管（`request_id` → 状态）。
///
/// 为什么只一个 `cancelled` 旗：`station/cancel` 是**下行通知**（无 id），读循环把它
/// 挂到后台任务上，而推流在自己的任务里——两边唯一的通信就是这个旗。取消之后核心已经
/// 收尾，迟到 / 之后的增量都会被丢弃（不报错），所以推流侧只需逐片检查它。
class StreamState {
  bool cancelled = false;
  String reason = '';
}

/// 插件主体：入站三类判别 + 四站演示。
class SamplePlugin {
  SamplePlugin({
    required this.channel,
    required this.options,
    this.pluginId = kPluginId,
  }) {
    // 启动后要发的执行站演示命令（**入队不阻塞**：等回包会死锁，见文件头边界情况）。
    if (options.llmCall.isNotEmpty) startupCommands.add('llm_call');
    if (options.toolCall.isNotEmpty) startupCommands.add('tool_call');
    if (options.renameSession) startupCommands.add('rename_session');
  }

  final PluginChannel channel;
  final Options options;

  /// 插件 id：**以核心 hello 里的 plugin_id 为准**（= plugins.yaml 的 id）；
  /// 工具在模型眼里的名字是 `plugin__<插件id>__<工具名>`，由核心按来源路由。
  String pluginId;

  // ── 计数状态（只数 phase=start）─────────────────────────────────────────
  final Map<String, int> counts = <String, int>{};

  /// `agent|session|call_id` → 开始时刻（end 事件用来算耗时）。
  final Map<String, DateTime> startedAt = <String, DateTime>{};
  int totalStarted = 0;
  int stopCount = 0;
  int? lastDurationMs;
  String firstAgentSeen = '';

  /// 事件里见过的第一个 session（懒订阅中转站 / 卡片按 agent 下发时补全身份用）。
  String firstSessionSeen = '';

  /// 中转站是否已订阅成功（懒订阅：没声明 team 时只能等事件告诉我们 agent）。
  bool relaySubscribed = false;

  /// 启动时订中转站被拒（多半缺 team）⇒ 等第一个事件给出 `agent_id` 后再试一次。
  bool relayLazyPending = false;

  /// 本插件处理过的中转请求数（pre / post 各算一次）。
  int relayHandled = 0;

  // ── 点位化状态 ──────────────────────────────────────────────────────────
  int llmHandleSeen = 0;
  int llmHandleTaken = 0;
  int promptRewrites = 0;
  int toolBroadcastTotal = 0;
  int toolBroadcastPre = 0;
  int toolBroadcastPost = 0;
  String toolBroadcastLast = '';

  /// `request_id` → 流状态（推流任务逐片检查 `cancelled`）。
  final Map<String, StreamState> streams = <String, StreamState>{};

  /// 最近一次 `station/request` 的 `request_id`：**流式增量必须原样带回它**。
  String streamRequestId = '';

  final List<String> startupCommands = <String>[];

  DateTime _lastCardAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _cardTimer;

  String get activitySlotKey => '$pluginId.activity.1';

  String get panelSlotKey => '$pluginId.panel.1';

  // ── 日志面（协议面由骨架的 [PluginChannel.send] 独占）─────────────────

  /// 日志：**永远写 stderr**；`notify = true` 时另发一条 `log` 通知（前端 plugin_event）。
  void log(String message, {bool notify = false, String level = 'info'}) {
    channel.log('[${_clock(DateTime.now())}] $message');
    if (!notify) return;
    // 发不出去不算错误（核心已关通道）——骨架的 [PluginChannel.logNotify] 走通知面、
    // 不等回包，这里不能因为日志把业务带崩。
    channel.logNotify(message, level: level);
  }

  // ── ③ 执行站：插件主动下命令 ────────────────────────────────────────────

  /// 经**执行站**下一条命令。
  ///
  /// [scope] 是**这一次命令的身份**（`agent_id` / `session_id` / `team_id` /
  /// `mode_key`）：写进 params 顶层，不是 `arguments` 里。原因是核心的口径就是
  /// “单实例 + 每条消息带身份”，team / mode 由它按目标 agent 的**真实归属**解析
  /// （插件声明只是上限）；不带 agent 的团队级命令（`ui.push`）在没声明
  /// `scope.team_id` 时本来定不出作用域，带上 agent_id 后**空 scope 的配置也能推卡片**。
  Future<CommandOutcome> command(
    String command, {
    Map<String, dynamic> arguments = const <String, dynamic>{},
    Map<String, dynamic> scope = const <String, dynamic>{},
  }) async {
    final Map<String, dynamic> params = <String, dynamic>{
      'command': command,
      'arguments': arguments,
      // 空值不写：写了 `agent_id: ''` 在核心那边是“声明了一个不存在的 agent”。
      for (final MapEntry<String, dynamic> entry in scope.entries)
        if ('${entry.value}'.trim().isNotEmpty) entry.key: entry.value,
    };
    try {
      final Map<String, dynamic> envelope = await channel.request(
        M.stationCommand,
        params,
      );
      final String error = asString(envelope['error']);
      final Map<String, dynamic> payload = asMap(envelope['payload']);
      final String mountId = asString(envelope['mount_id']);
      if (error.isNotEmpty || envelope['ok'] == false) {
        return CommandOutcome(
          ok: false,
          payload: payload,
          mountId: mountId,
          command: command,
          // ok:false 又不给原因 = 核心那边也有 bug，这里得替它说一句人话。
          error: error.isEmpty ? '核心回 ok:false 且没有给出原因' : error,
        );
      }
      return CommandOutcome(
        ok: true,
        payload: payload,
        mountId: mountId,
        command: command,
      );
    } on CmdFailureException catch (failure) {
      // JSON-RPC 层就被拒（未知方法 / 参数非法 / 处理器异常 / scope 不满足 -32001）：
      // **显式**记下来并推到前端，不静默。payload 一起留着（能拿到就还能读现场）。
      log('station/command $command 被核心拒绝：${failure.message}', notify: true);
      return CommandOutcome(
        ok: false,
        payload: failure.payload,
        error: failure.message,
        command: command,
      );
    }
  }

  /// **订阅站点**（协议方法 `station/subscribe`）。
  ///
  /// 三种寻址方式（互斥）：
  /// - [station]：按**类型**订内置站——`relay` / `broadcast`；
  /// - [station] + [point]：按**点位别名**订某一个接入点（比完整 id 抗改名），
  ///   例如 `point: 'llm.handle'` / `'prompt.system'` / `'tool.pre'`；
  /// - [stationId]：按**实例 id** 直接订（自建站的消费入口）。
  ///
  /// ⚠ **点位化语义**（最容易踩的一条）：`station: 'relay'` **不带 point** = 一次订
  /// **工具调用前 + 工具调用后两个点位**（与点位化之前“一个实例收两段”行为等价）；
  /// 回包结构也从单条变成
  /// `{ok, station_id, station_ids:[…], subscriptions:[{station_id, ok, replaced, error}, …]}`
  /// ——**旧字段 `station_id` 仍在**（= 第一个点位），但“订上没订上”要看
  /// `station_ids` / `subscriptions` 或聚合的 `ok`（全部成功才为 true）。
  /// `broadcast` 不带 point **只订通用主题**（`system.broadcast`），与 relay 那条糖
  /// **不对称**：要订两个工具点位就得订两次。
  Future<Map<String, dynamic>> subscribeStation(
    String station, {
    bool replace = false,
    String stationId = '',
    Map<String, dynamic> scope = const <String, dynamic>{},
    String point = '',
  }) async {
    final Map<String, dynamic> params;
    final String label;
    if (stationId.isNotEmpty) {
      params = <String, dynamic>{'station_id': stationId};
      label = stationId;
    } else {
      params = <String, dynamic>{'station': station};
      if (point.isNotEmpty) params['point'] = point;
      label = point.isEmpty ? station : '$station/$point';
    }
    params['replace'] = replace;
    if (scope.isNotEmpty) {
      params['scope'] = <String, dynamic>{
        for (final MapEntry<String, dynamic> entry in scope.entries)
          if ('${entry.value}'.trim().isNotEmpty) entry.key: entry.value,
      };
    }
    final Map<String, dynamic> result;
    try {
      result = await channel.request(M.stationSubscribe, params);
    } on CmdFailureException catch (failure) {
      // 一律回“可判定的结果”（含传输层失败）：调用方据此决定要不要推迟重订。
      log('订阅 $label 站点失败：${failure.message}', notify: true);
      return <String, dynamic>{'ok': false, 'error': failure.message};
    }
    final Object? ids =
        result['station_ids'] ??
        <String>[
          if (asString(result['station_id']).isNotEmpty)
            asString(result['station_id']),
        ];
    if (result['ok'] == true) {
      log('已订阅 $label 站点：station_ids=$ids scope=${result['scope']}');
    } else {
      // 部分成功：逐条结果是唯一能看出“哪个点位没订上”的地方，别只看聚合 ok。
      log(
        '订阅 $label 站点被拒：${result['error']}（逐条：${result['subscriptions']}）',
        notify: true,
      );
    }
    return result;
  }

  /// **自建站点并订阅**（`station/register` → `station/subscribe`）。
  ///
  /// 为什么需要它（用户定稿语义）：站点全局唯一、**每个点位只有一个订阅者**。
  /// 插件要按 team / agent 分开处理时，不能“每个 team 订一份”，而应由一个
  /// 转发型订阅者接管内置站，再**自己建站**做分发——建站必须经核心，否则下游
  /// 没有回包通道与等待链。
  ///
  /// 要点：**id 由核心拼**（`plugin.<插件id>.<类型>.<name>`），插件不能自选 id；
  /// 所以这里只给 [kind] + [name]，并用返回的 `station_id` 去订阅。
  ///
  /// [readme] 是**必填**的（用户定稿：每个插件内置站点都必须有介绍）：站是插件建的，
  /// “它干什么、什么时候被触发、订阅者该怎么回”只有建站的插件说得清；面板的站点
  /// 详情页直接展示它，共享站点时它是别人唯一能读到的说明书。
  Future<String> registerOwnStation({
    String kind = 'broadcast',
    String name = 'team_fanout',
    bool shared = false,
  }) async {
    final Map<String, dynamic> result;
    try {
      result = await channel.request(M.stationRegister, <String, dynamic>{
        'kind': kind,
        'name': name,
        'description': '示例插件自建站：按 team 再分发',
        'readme':
            '示例插件的自建${kind == 'broadcast' ? '广播站' : kind}：收到内置站的公告后，'
            '按 team / agent 再分发给本站的订阅者。触发时机由建站的插件决定（它自己调 '
            'station/trigger）；订阅者回 {reply:{payload:null}} 表示收到不改动，'
            '带 payload 表示附带再分发数据。',
        'shared': shared,
      });
    } on CmdFailureException catch (failure) {
      log('自建站点失败：${failure.message}', notify: true);
      return '';
    }
    if (result['ok'] != true) {
      log('自建站点被拒：${result['error']}', notify: true);
      return '';
    }
    final String stationId = asString(result['station_id']);
    log('已自建站点：$stationId（id 由核心按插件身份拼装）');
    // 建完就订阅自己（转发型订阅者的第一步）；别的插件订不到别人的站。
    await subscribeStation('', stationId: stationId);
    return stationId;
  }

  // ── 工具定义（收集站申报 + tools/list 共用一份，避免两处写歪）─────────

  /// 收集站形状：`tool_name` / `description` / `parameters` / `execution`。
  static List<Map<String, dynamic>> toolDefinitions() => <Map<String, dynamic>>[
    <String, dynamic>{
      'tool_name': 'echo',
      'description': '回显输入（示例插件的收集站申报工具）',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'text': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['text'],
      },
      'execution': <String, dynamic>{'method': 'tools/call', 'name': 'echo'},
    },
    <String, dynamic>{
      'tool_name': 'rounds',
      'description': '查看示例插件统计的工具调用轮次（计数 / 阈值 / 已停次数）',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
      },
      'execution': <String, dynamic>{'method': 'tools/call', 'name': 'rounds'},
    },
    <String, dynamic>{
      'tool_name': 'read_probe',
      'description': '经执行站 fs.read 读一个工作空间文件（演示插件主动下命令）',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'path': <String, dynamic>{'type': 'string'},
        },
      },
      'execution': <String, dynamic>{
        'method': 'tools/call',
        'name': 'read_probe',
      },
    },
  ];

  /// `tools/list` 的形状（**未声明 team** 的插件走这条老路径，工具仍可用）。
  ///
  /// 注意与收集站那套名字**不同**：这里是 `name` / `inputSchema`，那里是
  /// `tool_name` / `parameters`（站点 schema 自己定的）。共用一份定义、两处各自
  /// 包装，就不会出现“改了收集站忘了 tools/list”。
  static List<Map<String, dynamic>> toolsList() => <Map<String, dynamic>>[
    for (final Map<String, dynamic> definition in toolDefinitions())
      <String, dynamic>{
        'name': definition['tool_name'],
        'description': definition['description'],
        'inputSchema': definition['parameters'],
      },
  ];

  /// 工具执行。`read_probe` **要等执行站回包**，所以这条是异步的（骨架已改成
  /// [FutureOr]；同步签名只能先回一句“请稍后”，那条演示路径就白写了）。
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> arguments,
    Map<String, dynamic> scope,
  ) async {
    switch (name) {
      case 'echo':
        return toolText('plugin-echo: ${arguments['text'] ?? ''}');
      case 'rounds':
        return toolText(
          json.encode(<String, dynamic>{
            'plugin_id': pluginId,
            'threshold': options.threshold,
            'total_started': totalStarted,
            'stop_count': stopCount,
            'last_duration_ms': lastDurationMs,
            'counts': <String, int>{...counts},
            // 点位化新增：流式接管次数与广播看到的工具调用次数。
            'llm_handle_taken': llmHandleTaken,
            'tool_broadcast_seen': toolBroadcastTotal,
          }),
        );
      case 'read_probe':
        // 目标 agent 优先取**这一次调用的身份**（骨架从 `tools/call` 的 scope 里递下来），
        // 没有才退回 `--agent-id` / 事件里见过的那个：核心按目标 agent 的**真实归属**
        // 解析作用域，多 team / 空 scope 的配置下“猜第一个见到的 agent”就是错的，
        // 错的结局是 fail-closed 拒绝而不是“帮你执行”。
        final String caller = asString(scope['agent_id']);
        if (caller.isNotEmpty) {
          // 顺手把这份身份记下来（卡片与懒订阅靠它）：用户可能先点了工具、
          // 一条事件都还没跑过。
          learnIdentity(
            agentId: caller,
            sessionId: asString(scope['session_id']),
          );
        }
        final String? summary = await fsRead(
          path: asString(arguments['path']),
          reason: 'read_probe 工具调用',
          agentId: caller,
        );
        if (summary == null) {
          return toolText('fs.read 失败（详见插件 stderr 日志）', isError: true);
        }
        return toolText(summary);
    }
    return toolText('未知工具 $name', isError: true);
  }

  // ── ① 收集站 + 中转站 + 广播站：`station/request` 的完整分派 ───────────

  /// 站点 → 插件的请求（收集站 / 中转站 / 广播站共用这条 `station/request`）。
  ///
  /// 判据是 `params.station_id`（点位化之后**每个点位是一个独立站点实例**，
  /// 所以“哪个点位”看 id 就够；`kind` 仍可用于粗分类）：
  ///
  /// - `system.relay.tool.pre|post`（中转）：核心把**完整 tool_call 报文**放在
  ///   payload 里（`payload.phase` = pre | post）。返回改过的报文 = 改写生效；
  ///   返回 `null` = 什么都不改（放行原数据）；非法类型 = 核心 fail-open 放行。
  ///   这里 pre 给参数补 `_relay_seen` 标记、post 给结果加一行统计。
  /// - `system.relay.llm.handle`（中转，**接管**）：回 `{"payload": null}` = 不接管
  ///   （照走系统 LLM），回 `{"payload": {"stream": true}}` = **流式接管**。
  /// - `system.relay.prompt.system`（中转）：回字符串 = 最终 system prompt。
  /// - `system.broadcast.tool.pre|post`（广播，**单向通知**）：语义是通知，但仍要
  ///   回一条（核心在等回包，只是通知方不等它阻塞工具执行）。
  /// - `plugin.tool.define`（收集站）：回包 payload 必须严格符合站点 schema
  ///   （根对象只允许 `tools` 一个键）。
  Future<Map<String, dynamic>> handleStationRequest(
    Map<String, dynamic> params,
  ) async {
    final String stationId = asString(params['station_id']);
    // 最近一次请求的 request_id：流式增量必须原样带回它（核心靠它关联在途流）。
    streamRequestId = asString(params['request_id']);
    // 站点请求也携带身份（payload.agent_id / params.scope.agent_id）：这是**不动
    // 事件通路**也能学到目标 agent 的地方（`--llm-call` 之类启动命令要用）。
    final Object? rawPayload = params['payload'];
    final bool payloadIsMap = rawPayload is Map;
    final Map<String, dynamic> payload = asMap(rawPayload);
    final Map<String, dynamic> scope = asMap(params['scope']);
    learnIdentity(
      agentId: asString(payload['agent_id']).isNotEmpty
          ? asString(payload['agent_id'])
          : asString(scope['agent_id']),
      sessionId: asString(payload['session_id']).isNotEmpty
          ? asString(payload['session_id'])
          : asString(scope['session_id']),
    );
    switch (stationId) {
      case kPointRelayLlmHandle:
        return handleLlmHandle(params);
      case kPointRelayPromptSystem:
        return handlePromptSystem(params);
      case kPointBroadcastToolPre:
      case kPointBroadcastToolPost:
        return handleToolBroadcast(stationId, params);
    }
    final String kind = asString(params['kind']);
    if (kind == 'relay') {
      if (!payloadIsMap) {
        // 返回 None 表示“不改动”，但这里参数形态不列，显式说明更好排查。
        return <String, dynamic>{
          'reply': <String, dynamic>{'error': '中转请求的 payload 必须是对象'},
        };
      }
      relayHandled++;
      final int relayCount = relayHandled;
      final String phase = asString(payload['phase']);
      if (phase == 'pre') {
        // 演示“插件自己决定改不改”：只加一个标记键，不动业务参数。
        final Map<String, dynamic> arguments = asMap(payload['arguments']);
        return <String, dynamic>{
          'reply': <String, dynamic>{
            'payload': <String, dynamic>{
              ...payload,
              'arguments': <String, dynamic>{
                ...arguments,
                '_relay_seen': relayCount,
              },
            },
          },
        };
      }
      if (phase == 'post') {
        final Object? rawResult = payload['result'];
        final String text = rawResult is String ? rawResult : '$rawResult';
        if (options.panel) updatePanel();
        return <String, dynamic>{
          'reply': <String, dynamic>{
            'payload': <String, dynamic>{
              ...payload,
              'result': '$text\n[示例插件] 本次工具调用已经过中转（第 $relayCount 次）',
            },
          },
        };
      }
      // 未知 phase：不改动（显式返回 None = 放行原数据）。
      return <String, dynamic>{
        'reply': <String, dynamic>{'payload': null},
      };
    }
    if (kind == 'broadcast') {
      // 通用广播主题（system.broadcast）：收到了，没有附言。
      log('收到广播（topic=${asMap(params['meta'])['topic']}）：$stationId');
      return <String, dynamic>{
        'reply': <String, dynamic>{'payload': null},
      };
    }
    if (kind != 'collect') {
      // 其余站点类型显式拒绝（不静默）：本插件只订上面那几个点位。
      return <String, dynamic>{
        'reply': <String, dynamic>{
          'error': '示例插件不响应该点位的请求：station_id=$stationId kind=$kind',
        },
      };
    }
    final Map<String, dynamic> schema = asMap(params['schema']);
    final Object? rawFields = schema['fields'];
    final List<Object?> fields = <Object?>[
      if (rawFields is List)
        for (final Object? field in rawFields) asMap(field)['name'],
    ];
    if (fields.isNotEmpty && !fields.contains('tools')) {
      return <String, dynamic>{
        'reply': <String, dynamic>{'error': '站点 schema 未声明 tools 字段：$fields'},
      };
    }
    final List<Map<String, dynamic>> definitions = toolDefinitions();
    log(
      '收集站请求：申报 ${definitions.length} 个工具（'
      '${definitions.map((Map<String, dynamic> d) => asString(d['tool_name'])).join(', ')}）',
    );
    return <String, dynamic>{
      'reply': <String, dynamic>{
        'payload': <String, dynamic>{'tools': definitions},
      },
    };
  }

  // ── 点位化 ①：中转站 `system.relay.llm.handle`（流式接管）───────────────

  /// 把一条消息的 content 归一成纯文本（string 或 `[{type:text, text:…}]` 都认）。
  static String messageText(Object? message) {
    if (message is! Map) return '';
    final Object? content = message['content'];
    if (content is String) return content;
    if (content is List) {
      final List<String> parts = <String>[
        for (final Object? item in content)
          if (item is Map && item['text'] is String) '${item['text']}',
      ];
      return parts.join('\n');
    }
    return '';
  }

  /// 最后一条 `role=user` 消息的正文（没有就空串）。
  static String lastUserText(Object? messages) {
    if (messages is! List) return '';
    for (int index = messages.length - 1; index >= 0; index--) {
      final Object? message = messages[index];
      if (message is Map && message['role'] == 'user') {
        return messageText(message);
      }
    }
    return '';
  }

  /// `system.relay.llm.handle`：决定**接管**还是放行（三选一）。
  ///
  /// 回包形态（`reply.payload`）：
  /// - `null` = 不接管 ⇒ 核心走系统 LLM；
  /// - `{…完整响应…}` = 一次性接管；
  /// - `{"stream": true}` = **流式接管**（本插件用这条），之后必须用
  ///   `station/stream` 通知推增量并以 `done` / `error` 收尾。
  ///
  /// 回包必须**马上**发（骨架在请求处理里直接回），推流挂在后台任务上——推流期间
  /// 读循环还得应答 `ping`（硬约束）。
  Map<String, dynamic> handleLlmHandle(Map<String, dynamic> params) {
    final Map<String, dynamic> payload = asMap(params['payload']);
    final Map<String, dynamic> request = asMap(payload['request']);
    // ⚠ request_id 在 **params 顶层**（与 payload 平级），不在 payload 里。
    // 兜底用“最近一次站点请求的 request_id”：并发多路时那是**尽力而为**的猜测，
    // 真核心里每条请求都带自己的 request_id，所以正常路径永远走前者。
    final String requestId = asString(params['request_id']).isNotEmpty
        ? asString(params['request_id'])
        : streamRequestId;
    llmHandleSeen++;
    final String keyword = options.relayLlm;
    if (keyword.isEmpty) {
      // 防御：没开开关却订上了这个点位（不可能由本文件造成）⇒ 一律不接管。
      return <String, dynamic>{
        'reply': <String, dynamic>{'payload': null},
      };
    }
    if (requestId.isEmpty) {
      log('llm.handle 请求没有 request_id：无法推流，按不接管处理', notify: true);
      return <String, dynamic>{
        'reply': <String, dynamic>{'payload': null},
      };
    }
    final String userText = lastUserText(request['messages']);
    if (!userText.contains(keyword)) {
      log('LLM 处理点位：最后一条 user 消息不含关键词「$keyword」⇒ 不接管（走系统 LLM）');
      return <String, dynamic>{
        'reply': <String, dynamic>{'payload': null},
      };
    }
    llmHandleTaken++;
    streams[requestId] = StreamState();
    log(
      'LLM 处理点位：命中关键词「$keyword」⇒ **流式接管**第 ${payload['turn']} 跳'
      '（request_id=$requestId）',
      notify: true,
    );
    unawaited(streamWorker(requestId, keyword, userText));
    // 声明接管的回包：**必须在推第一条增量之前**送到核心（否则增量会被丢弃）。
    return <String, dynamic>{
      'reply': <String, dynamic>{
        'payload': <String, dynamic>{'stream': true},
      },
    };
  }

  bool streamCancelled(String requestId) =>
      streams[requestId]?.cancelled ?? false;

  /// 片与片之间稍等：既让界面看得出“逐字到达”，也留出收到 cancel 的窗口。
  /// 返回“已经取消”（每小段都查一次旗，不是睡完才发现）。
  Future<bool> _waitOrCancelled(String requestId) async {
    final int step = (options.streamChunkPauseMs / 5).round();
    for (int i = 0; i < 5; i++) {
      if (streamCancelled(requestId)) return true;
      await Future<void>.delayed(Duration(milliseconds: step <= 0 ? 1 : step));
    }
    return streamCancelled(requestId);
  }

  /// （后台任务）推 `station/stream` 增量，最后 `done` 收尾。
  ///
  /// 三条硬约束都在这个函数里体现：开流后不可回退（必须 done / error 收尾）；
  /// 推流期间继续应答 `ping`（它在自己的任务里跑，不占读循环）；收到
  /// `station/cancel` 就停，**不再推 done**（核心已收尾）。
  Future<void> streamWorker(
    String requestId,
    String keyword,
    String userText,
  ) async {
    final List<(String, String)> chunks = <(String, String)>[
      ('thinking', '示例插件正在接管这一跳：先复述关键词「$keyword」。'),
      ('text', '【示例插件已接管本轮 LLM】'),
      ('text', '你的问题是：「${_clip(userText.trim(), 80)}」'),
      ('text', '这段文字由插件用 station/stream 分片推给你，'),
      ('text', '核心没有调用任何真模型。'),
    ];
    if (options.relayLlmToolCall) {
      // tool_call 增量会**真的**触发一次工具调用，干扰别的演示，所以默认不推。
      chunks.add(('tool_call', ''));
    }
    try {
      for (final (String kind, String text) in chunks) {
        if (await _waitOrCancelled(requestId)) {
          log('流式接管：request_id=$requestId 已被取消，停止推流（不再发 done）');
          return;
        }
        if (kind == 'tool_call') {
          // 分片参数用 arguments_delta（与核心的流式 tool_call 形状一致）。
          channel.notify(M.stationStream, <String, dynamic>{
            'request_id': requestId,
            'delta': <String, dynamic>{
              'kind': 'tool_call',
              'index': 0,
              'id': 'call_demo_1',
              'name': 'read',
              'arguments_delta': '{"file_path": "README.md"}',
            },
          });
          continue;
        }
        channel.notify(M.stationStream, <String, dynamic>{
          'request_id': requestId,
          'delta': <String, dynamic>{'kind': kind, 'text': text},
        });
      }
      if (streamCancelled(requestId)) return;
      // 收尾：done + finish_reason + usage（缺了它这一轮会一直等）。
      channel.notify(M.stationStream, <String, dynamic>{
        'request_id': requestId,
        'done': true,
        'finish_reason': 'stop',
        'usage': <String, dynamic>{
          'prompt_tokens': 12,
          'completion_tokens': 34,
        },
      });
      log(
        '流式接管完成：request_id=$requestId 已发 done（finish_reason=stop）',
        notify: true,
      );
    } catch (error) {
      // 推流异常也必须给核心一个交代：开流后不回退，这一轮不能空悬着。
      log('流式接管异常（改为 error 收尾）：$error');
      channel.notify(M.stationStream, <String, dynamic>{
        'request_id': requestId,
        'error': <String, dynamic>{'message': '示例插件推流异常：$error'},
      });
    } finally {
      streams.remove(requestId);
      if (options.panel) updatePanel();
    }
  }

  /// **下行通知** `station/cancel`：用户按了停止，别再把算力烧在推流上。
  ///
  /// 只标状态、不阻塞：推流任务每片检查一次，自己收尾（核心已把这条流关掉，
  /// 迟到 / 之后的增量都会被丢弃，不会报错）。
  void onStationCancel(Map<String, dynamic> params) {
    final String requestId = asString(params['request_id']);
    final String reason = asString(params['reason']);
    final StreamState? state = streams[requestId];
    if (state == null) {
      log('收到 station/cancel（request_id=$requestId）但该流不在途（已收尾 / 非本插件）');
      return;
    }
    state.cancelled = true;
    state.reason = reason;
    log(
      '收到 station/cancel：request_id=$requestId '
      'reason=${reason.isEmpty ? '（核心未给原因）' : reason} ⇒ 停止推流',
      notify: true,
    );
  }

  // ── 点位化 ②：中转站 `system.relay.prompt.system`（改写系统提示词）──────

  /// `system.relay.prompt.system`：回**最终 system prompt**。
  ///
  /// payload = `{default, agent_id, session_id}`（`default` = 核心构造好的完整
  /// system prompt）。回 `null` = 用 `default`；回空串 = **明确不要**系统提示词
  /// （与“不改”是两种语义，别混）；回字符串 = 用你的。本插件演示后者：在
  /// `default` 后面追加一行，作为“这段提示词被插件动过”的可见证据。
  Map<String, dynamic> handlePromptSystem(Map<String, dynamic> params) {
    final Map<String, dynamic> payload = asMap(params['payload']);
    final Object? rawDefault = payload['default'];
    final String defaultPrompt = rawDefault == null
        ? ''
        : (rawDefault is String ? rawDefault : '$rawDefault');
    promptRewrites++;
    final int count = promptRewrites;
    log(
      '系统提示词点位：第 $count 次改写（agent=${payload['agent_id']}，'
      '原长 ${defaultPrompt.length} 字符）',
    );
    if (options.panel) updatePanel();
    final String rewritten = defaultPrompt.isEmpty
        ? kPromptMarker
        : '${defaultPrompt.trimRight()}\n$kPromptMarker';
    return <String, dynamic>{
      'reply': <String, dynamic>{'payload': rewritten},
    };
  }

  // ── 点位化 ③：广播站 `system.broadcast.tool.pre|post`（单向通知）──────

  /// 工具调用广播：统计“看到了 N 次工具调用”并推到面板。
  ///
  /// 广播语义是**单向通知**（`origin` = agent | plugin、`tool`、`call_id`、`round`、
  /// `arguments` / `result` / `is_error`），但它仍是一条 `station/request`——核心在等
  /// 这一条回包（只是通知方不等它阻塞工具执行），所以照回
  /// `{"payload": null}`（没有附言），别不回。
  Map<String, dynamic> handleToolBroadcast(
    String stationId,
    Map<String, dynamic> params,
  ) {
    final Map<String, dynamic> payload = asMap(params['payload']);
    final String phase = asString(payload['phase']);
    final String tool = asString(payload['tool']);
    final String origin = asString(payload['origin']);
    final bool isPost = stationId == kPointBroadcastToolPost || phase == 'post';
    toolBroadcastTotal++;
    if (isPost) {
      toolBroadcastPost++;
    } else {
      toolBroadcastPre++;
    }
    final int total = toolBroadcastTotal;
    toolBroadcastLast =
        '${isPost ? '结束' : '开始'} $tool（origin=$origin '
        'call_id=${payload['call_id']} round=${payload['round']}）';
    if (isPost) {
      log(
        '工具广播（第 $total 次）：$toolBroadcastLast '
        'result=${_clip('${payload['result']}', 60)} is_error=${payload['is_error']}',
      );
    } else {
      log('工具广播（第 $total 次）：$toolBroadcastLast');
    }
    if (options.panel) updatePanel();
    return <String, dynamic>{
      'reply': <String, dynamic>{'payload': null},
    };
  }

  // ── ② 事件订阅：数轮次，超阈值就发停止信号 ───────────────────────

  /// 记下事件/站点请求里出现的第一个身份（卡片与懒订阅都靠它）。
  ///
  /// `tools/call` 带下来的那份也走这里（见 [callTool] 的 `read_probe`）：用户完全可能
  /// 先点一次工具、还一条事件都没跑过，那时卡片与懒订阅也需要一个能用的归属。
  void learnIdentity({required String agentId, required String sessionId}) {
    if (agentId.isNotEmpty && firstAgentSeen.isEmpty) firstAgentSeen = agentId;
    if (sessionId.isNotEmpty && firstSessionSeen.isEmpty) {
      firstSessionSeen = sessionId;
    }
  }

  void onEvent(Map<String, dynamic> params) {
    if (asString(params['event']) != kEventToolCall) {
      // 订阅是 scope 通配的（plugins.yaml 里 scope 为空即收全部事件），
      // 其它事件只记 stderr，不做任何动作。
      log('收到非 tool_call 事件（忽略）：${params['event']}');
      return;
    }
    final String agentId = asString(params['agent_id']);
    final String sessionId = asString(params['session_id']);
    final String callId = asString(params['call_id']);
    final String phase = asString(params['phase']);
    learnIdentity(agentId: agentId, sessionId: sessionId);
    // 懒订阅中转站：启动时没订上（多半是没声明 scope.team_id ⇒ 缺 team），
    // 现在事件把 agent 告诉我们了——**只入队**，给回包留给读循环去收。
    final bool lazyRelay =
        options.relay &&
        !relaySubscribed &&
        relayLazyPending &&
        agentId.isNotEmpty;
    if (lazyRelay) {
      relayLazyPending = false; // 只试一次，失败也不再重排。
      unawaited(doSubscribeRelay(agentId, sessionId));
    }
    if (phase == kPhaseEnd) {
      // 结束事件：统计耗时（插件契约里 end 就是为了这个）。
      final DateTime? started = startedAt.remove('$agentId|$sessionId|$callId');
      if (started != null) {
        lastDurationMs = DateTime.now().difference(started).inMilliseconds;
      }
      return;
    }
    if (phase != kPhaseStart) return;
    final String key = '$agentId|$sessionId';
    final int count = (counts[key] ?? 0) + 1;
    counts[key] = count;
    totalStarted++;
    startedAt['$key|$callId'] = DateTime.now();
    if (count > options.threshold) {
      // **发完就重置**：否则后续每一次调用都会再发一次停止信号（反复停）。
      counts[key] = 0;
      log(
        '⚠ 工具轮次超限：agent=$agentId session=$sessionId 本任务已调用 $count 次'
        ' > 阈值 ${options.threshold} ⇒ 经执行站发 agent.stop，计数已重置',
        notify: true,
      );
      // 读循环里**只入队**：等回包会死锁（回包也从同一条 stdin 进来）。
      unawaited(doStop(key, count));
    } else {
      unawaited(pushCard());
    }
  }

  /// （后台任务）懒订阅中转站：用事件里的 agent 身份订。
  ///
  /// 为什么能成：plugins.yaml 的 scope 是**作用域上限**，请求里带 agent 时核心按该
  /// agent 的**真实归属**解析 team —— 所以 `scope: {}` 的插件同样订得上。
  ///
  /// 为什么只订一次：**每个点位只有一个订阅者**（中转站尤其）。订第二个 team 要用
  /// `replace: true` 抢点位，那会把前一个 team 的拦截丢掉；要按 team 分流，正解是
  /// 自建站点再分发（见 `--self-station`）。
  Future<void> doSubscribeRelay(String agentId, String sessionId) async {
    final Map<String, dynamic> result = await subscribeStation(
      'relay',
      replace: true,
      scope: <String, dynamic>{'agent_id': agentId, 'session_id': sessionId},
    );
    if (result['ok'] == true) {
      relaySubscribed = true;
      log(
        '中转站已按事件身份订上：agent=$agentId session=$sessionId'
        '（此后工具调用前/后各一次）',
        notify: true,
      );
    } else {
      log(
        '中转站懒订阅仍失败（不重试）：${asString(result['error']).isEmpty ? '未知原因' : result['error']}',
        notify: true,
      );
    }
  }

  /// 发停止信号：执行站 `agent.stop`（默认只停该 agent，`--stop-cascade` 停整棵树）。
  Future<void> doStop(String key, int count) async {
    final List<String> parts = key.split('|');
    final String agentId = parts.isEmpty ? '' : parts.first;
    final String sessionId = parts.length > 1 ? parts[1] : '';
    final CommandOutcome outcome = await command(
      kCommandAgentStop,
      arguments: <String, dynamic>{'cascade': options.cascade},
      scope: <String, dynamic>{'agent_id': agentId, 'session_id': sessionId},
    );
    stopCount++;
    log(
      'agent.stop（第 $stopCount 次）：ok=${outcome.ok} '
      'mount_id=${outcome.mountId} error=${outcome.error}',
      notify: true,
    );
    await pushCard(force: true);
  }

  // ── ③ 执行站的四条演示命令（fs.read / llm.call / tool.call / session.rename）──

  /// 解析“这次演示命令打给哪个 agent”；解析不出来返回空串。
  ///
  /// 取法（优先级就这三层）：**本次调用/请求带下来的身份**（[urgent]，由调用方递）>
  /// `--agent-id` / 环境变量 > 事件 / 站点请求里见过的第一个 agent。
  /// **为什么不能猜**：核心按目标 agent 的**真实归属**（team / mode）解析命令作用
  /// 域，猜错的后果是 fail-closed 拒绝（有可读原因），而不是“帮你去执行”。
  String resolveDemoAgent(String what, {String urgent = ''}) {
    if (urgent.trim().isNotEmpty) return urgent.trim();
    final String target = options.agentId.isNotEmpty
        ? options.agentId
        : firstAgentSeen;
    if (target.isEmpty) {
      log(
        '跳过 $what 演示：没有目标 agent（用 --agent-id 指定，'
        '或先让该 agent 发生一次工具调用 / 站点请求）',
        notify: true,
      );
    }
    return target;
  }

  /// 下一条 `fs.read`，把结果打进日志；返回可读摘要（失败返回 null）。
  ///
  /// [agentId] = **这次读取该打给谁**（`read_probe` 用它传本次调用的身份）；
  /// 留空则走 [resolveDemoAgent] 那三层取法。
  Future<String?> fsRead({
    String path = '',
    String reason = '启动自检',
    String agentId = '',
  }) async {
    final String target = resolveDemoAgent('fs.read', urgent: agentId);
    final String targetPath = path.isNotEmpty ? path : options.readPath;
    if (target.isEmpty) return null;
    final CommandOutcome outcome = await command(
      kCommandFsRead,
      arguments: <String, dynamic>{'path': targetPath, 'line_count': 20},
      scope: <String, dynamic>{'agent_id': target},
    );
    if (!outcome.ok) {
      log(
        'fs.read 演示失败（$reason）：agent=$target path=$targetPath '
        'error=${outcome.error}',
        notify: true,
      );
      return null;
    }
    final List<String> lines = const LineSplitter().convert(
      asString(outcome.payload['content']),
    );
    final String summary =
        'fs.read 成功（$reason）：agent=$target '
        'path=${outcome.payload['path']} total_lines=${outcome.payload['total_lines']} '
        'truncated=${outcome.payload['truncated']}\n${lines.take(8).join('\n')}';
    log(summary, notify: true);
    return summary;
  }

  /// `llm.call`：借**目标 agent 的模型**发一次 JSON 调用。
  ///
  /// 站点处**缺省硬设** `response_format=json_object`，所以回包里的 `json` 是端点
  /// 已经解析好的对象；`text` 是原始文本（端点没按 JSON 回时 `json` 为空，插件应看
  /// `text` 与服务端的 `ok`）。要**复用对话前缀缓存**的调用（如压缩插件的总结调用）
  /// 必须显式传 `"response_format": "text"`——`json_object` 会让端点改写提示词。
  /// 失败一律 `ok:false` + **可读 error**（例如“该 agent 尚未指定模型”）——不崩。
  Future<void> doLlmCall() async {
    final String prompt = options.llmCall;
    final String target = resolveDemoAgent('llm.call');
    if (target.isEmpty) return;
    log('经执行站发 llm.call（agent=$target prompt=${_clip(prompt, 60)}）');
    final CommandOutcome outcome = await command(
      kCommandLlmCall,
      arguments: <String, dynamic>{
        'prompt': prompt,
        'system': '你是示例插件的 JSON 助手：只回一个 JSON 对象。',
      },
      scope: <String, dynamic>{'agent_id': target},
    );
    if (!outcome.ok) {
      log('llm.call 失败：${outcome.error}', notify: true);
      return;
    }
    log(
      'llm.call 成功：model=${outcome.payload['model']} usage=${outcome.payload['usage']}\n'
      'json=${json.encode(outcome.payload['json'])}\ntext=${_clip('${outcome.payload['text']}', 200)}',
      notify: true,
    );
  }

  /// `tool.call`：执行**任意工具**（内置 / MCP / 插件工具同一入口）。
  ///
  /// 两点口径（与“命令失败”分得很开）：命令本身成功 = `ok:true`；**工具自己**
  /// 失败体现在 `is_error:true` + `result` 文本里（模型会看到那种可读原因，插件也一样
  /// 读得到）。默认**绕开**工具中转 / 广播（`relay:false`）：插件既订了 tool.pre 又
  /// tool.call 时，绕开才不会自锁；要审计自己的调用就传 `"relay": true`。
  Future<void> doToolCall() async {
    final String tool = options.toolCall;
    final String target = resolveDemoAgent('tool.call');
    if (target.isEmpty) return;
    log(
      '经执行站发 tool.call（tool=$tool arguments=${json.encode(options.toolCallArgs)} relay=False）',
    );
    final CommandOutcome outcome = await command(
      kCommandToolCall,
      arguments: <String, dynamic>{
        'tool': tool,
        'arguments': <String, dynamic>{...options.toolCallArgs},
        // 演示“默认绕开”：这里显式写 false，等价于不传。
        'relay': false,
      },
      scope: <String, dynamic>{'agent_id': target},
    );
    if (!outcome.ok) {
      log('tool.call 失败（命令没跑起来）：${outcome.error}', notify: true);
      return;
    }
    log(
      'tool.call 结果：tool=${outcome.payload['tool']} is_error=${outcome.payload['is_error']} '
      'relayed=${outcome.payload['relayed']}\nresult=${_clip('${outcome.payload['result']}', 400)}',
      notify: true,
    );
  }

  /// `session.rename`：把当前会话改成带时间戳的标题。
  ///
  /// `title` 必填（空标题会被执行站显式拒绝——store 层“空标题 = 不改名”不能在
  /// 命令层静默成功）；`session_id` 缺省 = 目标 agent 的默认会话。
  Future<void> doRenameSession() async {
    final String target = resolveDemoAgent('session.rename');
    if (target.isEmpty) return;
    final DateTime now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final String title =
        '示例插件改名 ${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
    final CommandOutcome outcome = await command(
      kCommandSessionRename,
      arguments: <String, dynamic>{
        'title': title,
        if (firstSessionSeen.isNotEmpty) 'session_id': firstSessionSeen,
      },
      scope: <String, dynamic>{'agent_id': target},
    );
    if (!outcome.ok) {
      log('session.rename 失败：${outcome.error}', notify: true);
      return;
    }
    log(
      'session.rename 成功：renamed=${outcome.payload['renamed']} '
      'title=${outcome.payload['title']} session_id=${outcome.payload['session_id']}',
      notify: true,
    );
  }

  // ── 开工：hello 之后的订阅 / 申报 / 启动命令 ────────────────────────

  /// hello 之后的开工动作。
  ///
  /// 顺序与 Python 版一致：订阅中转 → 点位化订阅 → 自建站 → 申报面板 → fs 自检
  /// → 启动命令 → 推一张卡片。骨架把这一段挂在后台任务里（`hello` 的回包已经先发了），
  /// 所以这里可以放心 await；但**周期推流与命令本身**仍旧 `unawaited`。
  Future<void> startup() async {
    log(
      '已就绪：插件 id=$pluginId 阈值=${options.threshold} 槽位=${options.slotKey}'
      '（作用域见 plugins.yaml，请求参数改不了作用域）',
      notify: true,
    );
    // **订阅中转站**：此后每次工具调用的前/后，核心都会把完整 tool_call 报文
    // 发过来（station/request，kind=relay），本插件决定改什么 / 不改。
    // 空 scope 也是合法声明（通配：作用于所有 team），所以正常情况下这里一次就成。
    // 只在**被拒**时（旧核心的 fail-closed / 点位已被别的插件占用）才退到兜底：
    // 推迟到第一个事件之后按事件里的 agent_id 补订。
    if (options.relay) {
      final Map<String, dynamic> result = await subscribeStation(
        'relay',
        replace: true,
      );
      if (result['ok'] == true) {
        relaySubscribed = true;
      } else {
        relayLazyPending = true;
        log(
          '中转站订阅推迟到第一个事件之后（本次被拒：'
          '${asString(result['error']).isEmpty ? '见上一条日志' : result['error']}）',
          notify: true,
        );
      }
    }
    // **点位化：LLM 接管点位**。它和工具前/后**不是**一个实例：每个点位各自
    // “唯一订阅者”，所以这里单独按 `point` 订，不会顶掉上面那次订阅。
    if (options.relayLlm.isNotEmpty) {
      await subscribeStation('relay', point: 'llm.handle', replace: true);
    }
    if (options.relayPrompt) {
      await subscribeStation('relay', point: 'prompt.system', replace: true);
    }
    // **工具广播**：两个主题族是**两个点位**，所以要订两次（`station=broadcast`
    // 不带 point 只订通用主题，与中转站那条糖**规则不同**）。
    if (options.watchTools) {
      await subscribeStation('broadcast', point: 'tool.pre');
      await subscribeStation('broadcast', point: 'tool.post');
    }
    if (options.selfStation) await registerOwnStation();
    if (options.panel) declarePanel();
    if (options.fsDemo) unawaited(fsRead());
    // 三条新执行站命令的演示：**入队不阻塞**（等回包会死锁，见文件头边界情况）。
    if (startupCommands.isNotEmpty) unawaited(_runStartupCommands());
    // 卡片是“声明式布局”的演示：**没声明槽位就别推**。
    if (options.panel) unawaited(pushCard(force: true));
    startCardTimer();
  }

  Future<void> _runStartupCommands() async {
    for (final String job in startupCommands) {
      try {
        switch (job) {
          case 'llm_call':
            await doLlmCall();
          case 'tool_call':
            await doToolCall();
          case 'rename_session':
            await doRenameSession();
        }
      } catch (error) {
        // 后台任务异常不影响协议循环（与 Python 版的 worker 同口径）。
        log('启动命令 $job 异常（已忽略）：$error');
      }
    }
  }

  /// 周期刷新卡片（Python 版靠 timer 线程；这里一个 periodic Timer）。
  void startCardTimer() {
    if (!options.panel || options.cardInterval <= 0) return;
    final int ms = (options.cardInterval * 1000).round();
    _cardTimer?.cancel();
    _cardTimer = Timer.periodic(
      Duration(milliseconds: ms < 1000 ? 1000 : ms),
      // 周期拍走的是**节流**那条（事件密集时不刷屏），手动按钮才 force。
      (Timer _) => unawaited(pushCard()),
    );
  }

  /// 收尾：关掉周期任务（stdin 关闭 / shutdown / suspend 都会走到这里）。
  Future<void> stop() async {
    _cardTimer?.cancel();
    _cardTimer = null;
  }

  // ── ④ 插件布局：申报槽位 + 刷面板 + 推卡片 ──────────────────────

  /// 发一条 `ui/manifest` **通知**（无 id）：声明本插件在该 team 上的全部槽位。
  ///
  /// - `activity` = 左侧活动栏项（和「Agent 列表 / 插件 / 下载」并列）；
  /// - `panel` = 右栏 Tab；
  /// - `card` = **消息流内联卡片**（[pushCard] 的落点）；
  /// - 视图是**声明式受限控件集**（text / list / table / form / progress / actions
  ///   与 row / column 容器）——**没有 webview、不执行插件 JS**；
  /// - `plugin_id` / `team_id` 一律由**核心按实例与 plugins.yaml 声明**填充，
  ///   插件自述的这两个字段不会被采信（防越权）。
  ///
  /// ⚠ **card 槽位必须在这里申报一次**：`ui.push` 只发 `plugin_ui_update` 帧、
  /// **不建槽位**——前端的注册表要求“槽位先由 manifest 存在，update 才生效”，
  /// 没申报过的 slot_key 会被直接忽略（表现为“卡片永远不出现”，而没有任何报错）。
  void declarePanel() {
    final List<Map<String, dynamic>> slots = <Map<String, dynamic>>[
      <String, dynamic>{
        'slot_key': activitySlotKey,
        'slot': 'activity',
        'title': kPluginName,
        'icon': 'extension',
        'order': 10,
        'view': <String, dynamic>{
          'type': 'column',
          'gap': 6,
          'children': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'text',
              'text': '$kPluginName · 面板',
              'style': 'title',
            },
            <String, dynamic>{
              'type': 'text',
              'text': '工具轮次计数与中转处理次数都在这里刷新',
              'style': 'caption',
            },
            <String, dynamic>{
              'type': 'actions',
              'buttons': <Map<String, dynamic>>[
                <String, dynamic>{
                  'action_id': 'refresh',
                  'label': '刷新',
                  'style': 'primary',
                },
                <String, dynamic>{'action_id': 'push_card', 'label': '推一张卡片'},
              ],
            },
          ],
        },
      },
      <String, dynamic>{
        'slot_key': panelSlotKey,
        'slot': 'panel',
        'title': kPluginName,
        'view': cardView(),
      },
      <String, dynamic>{
        // 消息流内联卡片：**必须在这里申报**，pushCard 的 ui.push 才能生效。
        'slot_key': options.slotKey,
        'slot': 'card',
        'title': '$kPluginName · 工具轮次监视',
        'order': 10,
        'view': cardView(),
      },
    ];
    channel.notify(Ui.manifest, <String, dynamic>{'slots': slots});
    log('已声明插件面板槽位 ${slots.length} 个（activity + panel + card）');
  }

  /// 左侧活动栏视图：中转计数 + 工具轮次进度 + 点位化演示的计数。
  Map<String, dynamic> activityView() {
    final int threshold = options.threshold < 1 ? 1 : options.threshold;
    return <String, dynamic>{
      'type': 'column',
      'gap': 6,
      'children': <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'text',
          'text': '$kPluginName · 面板',
          'style': 'title',
        },
        <String, dynamic>{
          'type': 'text',
          'text': '已处理中转 $relayHandled 次',
          'style': 'body',
        },
        <String, dynamic>{
          'type': 'progress',
          'value': totalStarted / threshold > 1.0
              ? 1.0
              : totalStarted / threshold,
          'label': '工具轮次 / 阈值',
          'detail': '$totalStarted / ${options.threshold}',
        },
        <String, dynamic>{
          'type': 'text',
          'text': pointsSummary(),
          'style': 'caption',
        },
        <String, dynamic>{
          'type': 'actions',
          'buttons': <Map<String, dynamic>>[
            <String, dynamic>{'action_id': 'refresh', 'label': '刷新'},
          ],
        },
      ],
    };
  }

  /// 点位化演示（默认关闭）的当前计数，一行说清“哪些开关开着、看到多少”。
  String pointsSummary() {
    final List<String> parts = <String>[
      'LLM 接管 $llmHandleTaken/$llmHandleSeen 次',
    ];
    if (options.relayPrompt) parts.add('提示词改写 $promptRewrites 次');
    if (options.watchTools) {
      parts.add(
        '看到了 $toolBroadcastTotal 次工具调用（pre $toolBroadcastPre / post $toolBroadcastPost）',
      );
    }
    return parts.join(' · ');
  }

  /// 声明式视图模型（受限控件集）：column 容器 + text / progress / table。
  Map<String, dynamic> cardView() {
    final List<MapEntry<String, int>> ranked = counts.entries.toList()
      ..sort(
        (MapEntry<String, int> a, MapEntry<String, int> b) =>
            b.value.compareTo(a.value),
      );
    final List<MapEntry<String, int>> top = ranked.take(5).toList();
    final int highest = top.isEmpty ? 0 : top.first.value;
    final int threshold = options.threshold < 1 ? 1 : options.threshold;
    final List<List<Object?>> rows = <List<Object?>>[
      for (final MapEntry<String, int> entry in top)
        <Object?>[
          _or(entry.key.split('|').first, '(空)'),
          _or(
            entry.key.split('|').length > 1 ? entry.key.split('|')[1] : '',
            '(空)',
          ),
          '${entry.value}',
          // 与 Python 版一致：耗时是**全局最近一次**，不在表里逐行呈现
          //（要逐行就得按 key 存时长，那是新行为，不在这个示例里顺手发明）。
          '—',
        ],
    ];
    if (rows.isEmpty) rows.add(<Object?>['—', '—', '0', '—']);
    final String durationText = lastDurationMs == null
        ? '—'
        : '$lastDurationMs ms';
    final List<Map<String, dynamic>> children = <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'text',
        'text': '$kPluginName · 工具轮次监视',
        'style': 'title',
      },
      <String, dynamic>{
        'type': 'text',
        'text':
            '阈值 ${options.threshold} 次 · 已计数 $totalStarted 次 · '
            '已发停止 $stopCount 次 · 最近一次耗时 $durationText',
        'style': 'body',
      },
    ];
    if (options.watchTools) {
      // 点位化演示：广播点位看到的工具调用次数（`--watch-tools`）。
      children.add(<String, dynamic>{
        'type': 'text',
        'text':
            '广播点位：看到了 $toolBroadcastTotal 次工具调用'
            '（开始 $toolBroadcastPre / 结束 $toolBroadcastPost）'
            '最近：${_or(toolBroadcastLast, '—')}',
        'style': 'caption',
      });
    }
    children.addAll(<Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'progress',
        'value': highest / threshold > 1.0 ? 1.0 : highest / threshold,
        'label': '当前最高计数 / 阈值',
        'detail': '$highest / ${options.threshold}',
      },
      <String, dynamic>{
        'type': 'table',
        'columns': <String>['agent', 'session', '计数', '最近耗时'],
        'rows': rows,
      },
    ]);
    return <String, dynamic>{'type': 'column', 'gap': 6, 'children': children};
  }

  /// 发 `ui/update`：按 slot_key **整块替换**某槽位视图（不做 diff）。
  ///
  /// `view` 缺省 / 为 null = 注销该槽位。
  ///
  /// **两个槽位一起刷**（activity + panel）：manifest 只在 hello 时发一次，之后的
  /// 每一次刷新都走 ui/update。只刷 activity 会让右栏 Tab 永远停在启动那一刻的
  /// 「已计数 0 次」——看起来像插件没生效，实际是那个视图从来没被更新过。
  void updatePanel() {
    channel.notify(Ui.update, <String, dynamic>{
      'slot_key': activitySlotKey,
      'view': activityView(),
    });
    channel.notify(Ui.update, <String, dynamic>{
      'slot_key': panelSlotKey,
      'view': cardView(),
    });
  }

  /// `ui.push`：**复用 4.1 的 card 槽位帧**（核心内置挂载位置 core.frontend.card，
  /// 帧类型 plugin_ui_update，带 team_id）。
  ///
  /// 槽位本身由 [declarePanel] 的 `ui/manifest` 申报（`ui.push` 只更新、不建槽位）。
  /// 刷新时**顺带把面板也刷一遍**：三个视图同源，只刷一个会出现“卡片在跳、
  /// 面板停在 0”的错位观感。
  ///
  /// 命令身份：见过事件之后一律带 `agent_id` / `session_id`（`--agent-id` 显式指定
  /// 时以它为准），这样**没声明 `scope.team_id` 的配置也能把卡片推出去**。
  ///
  /// `--no-panel`（没声明槽位）时**直接不推**：`ui.push` 只更新、不建槽位，推给
  /// 不存在的 slot_key 前端会静默忽略——白等一次回包，还平白多一条失败日志。
  Future<void> pushCard({bool force = false}) async {
    if (!options.panel) return;
    final DateTime now = DateTime.now();
    final int minMs = (options.cardMinInterval * 1000).round();
    if (!force && now.difference(_lastCardAt).inMilliseconds < minMs) {
      return; // 事件密集时节流，避免刷屏
    }
    _lastCardAt = now;
    updatePanel();
    // **带上事件里学到的身份**：ui.push 是不带 agent 的团队级命令，没声明
    // `scope.team_id` 时定不出作用域会被拒；带 agent_id 后核心按该 agent 的真实
    // 归属解析 —— 空 scope 的配置因此也能推卡片（启动时还没有 agent，则只按声明）。
    final Map<String, dynamic> scope =
        options.agentId.isEmpty && firstAgentSeen.isNotEmpty
        ? <String, dynamic>{
            'agent_id': firstAgentSeen,
            'session_id': firstSessionSeen,
          }
        : const <String, dynamic>{};
    final CommandOutcome outcome = await command(
      kCommandUiPush,
      arguments: <String, dynamic>{
        'slot_key': options.slotKey,
        'view': cardView(),
      },
      scope: scope,
    );
    if (outcome.ok) {
      log('卡片已推送：slot_key=${options.slotKey}');
    } else if (firstAgentSeen.isEmpty && options.agentId.isEmpty) {
      // 启动那一刻还没见过任何事件 ⇒ 既没有声明 team 也借不到 agent 身份：
      // 这次推不出去是**预期内**的，等第一个事件到了就会带上 agent 重推。
      log(
        '卡片暂未推送（还没有身份可用）：等第一个工具调用事件之后会带 agent_id 重推；'
        '若一直失败，检查 plugins.yaml 的 scope.team_id',
      );
    } else {
      log(
        '卡片推送失败（检查 plugins.yaml 是否声明了 scope.team_id，'
        '以及前端通道是否可用）：${outcome.error}',
        notify: true,
      );
    }
  }

  /// 面板交互回调：刷新面板 / 推卡片。
  ///
  /// 核心只透传 slot_key / action_id / payload，语义由插件自己解释；惯例是
  /// **再推一帧 ui/update** 把槽位刷新。
  void handleUiAction(Map<String, dynamic> params) {
    final String actionId = asString(params['action_id']);
    final String slotKey = asString(params['slot_key']);
    log('面板交互：slot=$slotKey action=$actionId');
    if (actionId == 'refresh') {
      updatePanel();
      return;
    }
    if (actionId == 'push_card') {
      unawaited(pushCard(force: true));
      return;
    }
    // 未知 action：显式记下来（不静默），但不算错误。**走 log 通知**：
    // 前端能看见——否则用户点了没反应、日志也没人看（这条链路以前就是这么“静默”的）。
    log('未知的面板动作（忽略）：$actionId', notify: true);
  }
}

// ── 组装：骨架接业务 ────────────────────────────────────────────

/// 把插件接到骨架上（骨架负责读循环 / 握手 / 心跳 / 异常收敛）。
///
/// 判据只有一条：**面板动作的 `event` 通知与工具调用事件同一范式**，所以
/// `onNotify` 里先判 `params.event`，再转 [SamplePlugin.onEvent]——反过来写就会
/// 被它当“非 tool_call 事件”丢掉，面板按钮就成了“点了没反应”。
(PluginKitServer, SamplePlugin) build({
  Options? options,
  PluginChannel? channel,
}) {
  final PluginChannel io = channel ?? PluginChannel.stdio('sample');
  final SamplePlugin plugin = SamplePlugin(
    channel: io,
    options: options ?? Options(),
  );
  final PluginKitServer server = PluginKitServer(
    channel: io,
    pluginId: kPluginId,
    displayName: kPluginName,
    capabilities: const <String>['tools', 'events', 'stations'],
    tools: SamplePlugin.toolsList(),
    onToolCall: (String name, Map<String, dynamic> arguments,
            Map<String, dynamic> scope) =>
        plugin.callTool(name, arguments, scope),
    onRequest: (String method, Map<String, dynamic> params) async {
      if (method == M.stationRequest) {
        return plugin.handleStationRequest(params);
      }
      return null;
    },
    onNotify: (String method, Map<String, dynamic> params) {
      if (method == M.event) {
        if (asString(params['event']) == kEventUiAction) {
          plugin.handleUiAction(params);
          return;
        }
        plugin.onEvent(params);
        return;
      }
      // **下行通知**：我接管的 LLM 流该收了（只标状态，推流任务自己停）。
      if (method == M.stationCancel) {
        plugin.onStationCancel(params);
        return;
      }
      // 裸 `method == "plugin_ui_action"` 的形态（老核心 / 直连测试）：
      // 兼容留着——否则老核心配新插件时按钮依然是“点了没反应”。
      if (method == kEventUiAction) plugin.handleUiAction(params);
    },
    onReady: (PluginKitServer server) async {
      // 核心才是实例归属的权威：槽位键与工具前缀都得用它给的那个 id。
      plugin.pluginId = server.effectivePluginId;
      await plugin.startup();
    },
    onStop: () => plugin.stop(),
  );
  return (server, plugin);
}

Future<void> main(List<String> args) async {
  final Parsed parsed = parseOptions(args);
  if (parsed.help) {
    // 帮助一律走 stderr：stdout 是协议通道，--help 也不能污染它。
    stderr.write(parsed.message);
    return;
  }
  if (parsed.code != 0) {
    stderr.writeln(parsed.message);
    exitCode = parsed.code;
    return;
  }
  if (parsed.options.selftest || args.contains('--selftest')) {
    exitCode = await selfTest();
    return;
  }
  final (PluginKitServer server, _) = build(options: parsed.options);
  await server.run(stdin);
  try {
    await stdout.flush();
  } catch (_) {
    // 管道已被对端关掉：刷不出去不算错误。
  }
}

// ── 自检 ──────────────────────────────────────────────────────────────────

/// 一帧的 params（帧是 `{jsonrpc, id?, method?, params?, result?}`）。
Map<String, dynamic> frameParams(Map<String, dynamic> frame) =>
    asMap(frame['params']);

/// `station/command` 帧上的命令名。
String frameCommand(Map<String, dynamic> params) => asString(params['command']);

/// `station/command` 帧上的 arguments（**不含身份那一层**：本插件把身份写在 params 顶层）。
Map<String, dynamic> frameArguments(Map<String, dynamic> params) =>
    asMap(params['arguments']);

/// 断言消息里的实际值（Map / List 直接打引用地址看不出来，必须序列化）。
String rendered(Object? value) => json.encode(value);

/// 自检用参数：**走真命令行解析**（顺带证明这些开关解析得出来），再把推流片间隔压小。
///
/// `env` 给空表：这台机器上若残留 `SAMPLE_PLUGIN_*`，自检读的就不再是命令行那份参数了
/// （参数优先级是「命令行 > 环境变量 > 默认值」，注入空表才能把环境变量这条路关掉）。
Options selfOptions(List<String> argv) {
  final Parsed parsed = parseOptions(argv, env: const <String, String>{});
  if (parsed.code != 0) {
    throw StateError('自检参数不合法：${parsed.message}');
  }
  // 默认 250ms 的片间隔是给人看「逐字到达」的观感，自检断言的是形状。
  parsed.options.streamChunkPauseMs = 20;
  return parsed.options;
}

/// 假核心侧**复刻真核心的点位解析**（订阅回包用）。
///
/// 为什么不能给一个固定的两点位形状：真核心里「带 point / 给 station_id」只订一个点位，
/// 只有「不带 point 的 relay」才是一次订 tool.pre + tool.post。假核心固定回两点位，自检
/// 就会锁住一条**真核心永远不会返回**的合同。
List<String> subscribedPoints(Map<String, dynamic> params) {
  final String explicit = asString(params['station_id']);
  if (explicit.isNotEmpty) return <String>[explicit];
  final String kind = asString(params['station']);
  final String point = asString(params['point']);
  const Map<String, String> relayPoints = <String, String>{
    'tool.pre': kPointRelayToolPre,
    'tool.post': kPointRelayToolPost,
    'llm.handle': kPointRelayLlmHandle,
    'prompt.system': kPointRelayPromptSystem,
  };
  const Map<String, String> broadcastPoints = <String, String>{
    'tool.pre': kPointBroadcastToolPre,
    'tool.post': kPointBroadcastToolPost,
  };
  if (kind == 'relay') {
    if (point.isNotEmpty) {
      return <String>[relayPoints[point] ?? 'system.relay.$point'];
    }
    // 不带 point 的 relay = 一次订工具前 + 工具后（点位化的兼容糖）。
    return const <String>[kPointRelayToolPre, kPointRelayToolPost];
  }
  if (kind == 'broadcast') {
    if (point.isNotEmpty) {
      return <String>[broadcastPoints[point] ?? 'system.broadcast.$point'];
    }
    // 不带 point 的 broadcast = 只订通用主题（与 relay 那条糖**不对称**）。
    return const <String>['system.broadcast'];
  }
  return const <String>[kPointToolDefine];
}

/// 自检假核心：真协议面（字节流两端在同进程接起来）+ 按命令名现算的执行站回包。
class _Harness {
  _Harness(
    Options options, {
    bool refuseSubscribe = false,
    Set<String> failCommands = const <String>{},
  }) {
    final PluginChannel channel = PluginChannel(logTag: kPluginId);
    final (PluginKitServer built, SamplePlugin builtPlugin) = build(
      options: options,
      channel: channel,
    );
    plugin = builtPlugin;
    core = FakeCore(built);
    core.onMethod(M.stationSubscribe, (Map<String, dynamic> params) {
      if (refuseSubscribe) {
        return <String, dynamic>{
          'ok': false,
          'error': '该点位已有订阅者（replace=false 不抢占）',
        };
      }
      final List<String> points = subscribedPoints(params);
      return <String, dynamic>{
        'ok': true,
        // 旧字段仍在（= 第一个点位），但「订上没订上」要看 station_ids / subscriptions。
        'station_id': points.first,
        'station_ids': points,
        'kind': asString(params['station']),
        'scope': <String, dynamic>{'team_id': 'team-1'},
        'replaced': asString(params['replace']) == 'true' ? points.first : '',
        'error': '',
        'subscriptions': <Map<String, dynamic>>[
          for (final String id in points)
            <String, dynamic>{
              'station_id': id,
              'ok': true,
              'replaced': '',
              'error': '',
            },
        ],
      };
    });
    core.onMethod(M.stationRegister, (Map<String, dynamic> params) {
      registers.add(params);
      // id 由核心拼（`plugin.<插件id>.<类型>.<name>`），插件不能自选。
      return <String, dynamic>{
        'ok': true,
        'station_id':
            'plugin.${plugin.pluginId}.${asString(params['kind'])}.${asString(params['name'])}',
        'created': true,
        'shared': false,
      };
    });
    core.onMethod(M.stationCommand, (Map<String, dynamic> params) {
      calls.add(params);
      final String command = frameCommand(params);
      if (failCommands.contains(command)) {
        return _reject(command, '$command 被用例置为失败');
      }
      final Map<String, dynamic> args = frameArguments(params);
      switch (command) {
        case kCommandFsRead:
          return _envelope(command, <String, dynamic>{
            'path': args['path'],
            'content': fsFixture,
            'total_lines': 30,
            'truncated': true,
          }, mountId: 'core.workspace.fs');
        case kCommandUiPush:
          return _envelope(command, <String, dynamic>{
            'slot_key': args['slot_key'],
            'delivered': true,
          }, mountId: 'core.frontend.card');
        case kCommandAgentStop:
          return _envelope(command, <String, dynamic>{
            'stopped': true,
            'cascade': args['cascade'],
            'session_id': 'ses_demo',
          }, mountId: 'core.agent.stop');
        case kCommandLlmCall:
          return _envelope(command, <String, dynamic>{
            'model': 'selftest-model',
            'usage': <String, dynamic>{
              'prompt_tokens': 1,
              'completion_tokens': 1,
            },
            'json': <String, dynamic>{'ok': true},
            'text': '{"ok": true}',
          }, mountId: 'core.llm.call');
        case kCommandToolCall:
          return _envelope(command, <String, dynamic>{
            'tool': args['tool'],
            'is_error': false,
            'relayed': args['relay'] == true,
            'result': 'A 的内容',
          }, mountId: 'core.tool.call');
        case kCommandSessionRename:
          return _envelope(command, <String, dynamic>{
            'renamed': true,
            'title': args['title'],
            'session_id': asString(params['session_id']).isEmpty
                ? 'ses_demo'
                : asString(params['session_id']),
          }, mountId: 'core.session.rename');
      }
      return _reject(command, '未知命令 $command');
    });
    unawaited(core.start());
  }

  late final SamplePlugin plugin;
  late final FakeCore core;

  /// 插件发过的每一条执行站命令（就是帧上的 params，**含身份那一层**）。
  final List<Map<String, dynamic>> calls = <Map<String, dynamic>>[];

  /// 插件发过的每一条 `station/register`。
  final List<Map<String, dynamic>> registers = <Map<String, dynamic>>[];

  int _seq = 0;

  /// 三份 fs.read 内容里的行样本（够看 `total_lines` / `truncated` 的断言就行）。
  static const String fsFixture =
      '第 1 行\n第 2 行\n第 3 行\n第 4 行\n第 5 行\n第 6 行\n第 7 行\n第 8 行\n第 9 行\n第 10 行';

  static Map<String, dynamic> _envelope(
    String command,
    Map<String, Object?> payload, {
    String mountId = 'harness',
  }) => <String, dynamic>{
    'command': command,
    'ok': true,
    'mount_id': mountId,
    'payload': payload,
    'error': '',
  };

  static Map<String, dynamic> _reject(String command, String error) =>
      <String, dynamic>{
        'command': command,
        'ok': false,
        'mount_id': 'harness',
        'payload': null,
        'error': error,
      };

  /// 握手：骨架在这里定下 plugin_id，申报面板与订阅都排在它后面。
  Future<void> hello() async {
    core.ask('hello', M.hello, <String, dynamic>{'plugin_id': kPluginId});
    await core.waitFor(<Object?>['hello']);
  }

  /// 核心 → 插件一条 `station/request`，返回它的 `result`（空表 = 回包没来）。
  Future<Map<String, dynamic>> drive(Map<String, dynamic> params) async {
    final String id = 'st-${++_seq}';
    core.ask(id, M.stationRequest, params);
    final Map<Object?, Map<String, dynamic>> got = await core.waitFor(<Object?>[
      id,
    ], timeout: const Duration(seconds: 12));
    final Map<String, dynamic>? frame = got[id];
    if (frame == null) return <String, dynamic>{};
    return asMap(frame['result']);
  }

  /// 回包里的 `reply.payload`（**原样返回**：可能是 null、字符串或对象，三种语义各不同）。
  static Object? replyPayload(Map<String, dynamic> result) =>
      asMap(result['reply'])['payload'];

  /// 一条 `llm.handle` 的站点请求参数（照真核心那条报文搭）。
  ///
  /// ⚠ `params.request_id`（关联 `station/stream`）与 JSON-RPC 的 `id`（关联回包）是
  /// 两个不同的东西：这里故意取可预测的值，好断言「插件原样带回」。
  static Map<String, dynamic> llmHandleParams(String text, String streamId) {
    return <String, dynamic>{
      'request_id': streamId,
      'station_id': kPointRelayLlmHandle,
      'kind': 'relay',
      'scope': <String, dynamic>{
        'team_id': 'team-1',
        'agent_id': 'agt_demo',
        'session_id': 'ses_demo',
        'mode_key': 'local',
      },
      'payload': <String, dynamic>{
        'point': kPointRelayLlmHandle,
        'turn': 1,
        'agent_id': 'agt_demo',
        'session_id': 'ses_demo',
        'request': <String, dynamic>{
          'model': 'selftest-model',
          'stream': true,
          'messages': <Map<String, dynamic>>[
            <String, dynamic>{'role': 'system', 'content': '你是助手'},
            <String, dynamic>{'role': 'user', 'content': text},
          ],
        },
      },
      'meta': <String, dynamic>{'purpose': 'llm.handle', 'turn': 1},
    };
  }

  /// 发一条 llm.handle 并等回包；[streamId] 缺省自动编号（记进 [lastStreamId]）。
  Future<Map<String, dynamic>> askLlmHandle(
    String text, {
    String? streamId,
  }) async {
    final String sid = streamId ?? 'relay-selftest-${++_seq}';
    lastStreamId = sid;
    return drive(llmHandleParams(text, sid));
  }

  /// 我方最近一次 llm.handle 请求里带的 `request_id`。
  String lastStreamId = '';

  /// 某条流推过的增量（按 request_id 精确取；**不匹配的那条必须看不见**）。
  List<Map<String, dynamic>> streamsOf(String requestId) => core
      .outgoing(M.stationStream)
      .where(
        (Map<String, dynamic> frame) =>
            asString(frameParams(frame)['request_id']) == requestId,
      )
      .toList(growable: false);

  /// 等这条流以 done / error 收尾（开流后不可回退，这一条是「有没有交代」的判据）。
  Future<Map<String, dynamic>?> waitStreamSettled(
    String requestId, {
    int ms = 8000,
  }) async {
    final DateTime deadline = DateTime.now().add(Duration(milliseconds: ms));
    while (DateTime.now().isBefore(deadline)) {
      for (final Map<String, dynamic> frame in streamsOf(requestId)) {
        final Map<String, dynamic> params = frameParams(frame);
        if (params['done'] == true || params['error'] != null) return params;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return null;
  }

  /// 插件主动发的订阅帧 params（按点位断言用）。
  List<Map<String, dynamic>> subscribes() => core
      .outgoing(M.stationSubscribe)
      .map(frameParams)
      .toList(growable: false);

  Map<String, dynamic>? subscribeFor(
    bool Function(Map<String, dynamic> params) test,
  ) {
    for (final Map<String, dynamic> params in subscribes()) {
      if (test(params)) return params;
    }
    return null;
  }

  /// 等启动流程里的订阅发够数（hello 之后那一段是后台任务，直接读会读到空）。
  Future<bool> waitSubscribes(int atLeast, {int ms = 6000}) async {
    final DateTime deadline = DateTime.now().add(Duration(milliseconds: ms));
    while (DateTime.now().isBefore(deadline)) {
      if (subscribes().length >= atLeast) return true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return subscribes().length >= atLeast;
  }

  /// 某 method 已发出的帧数（作「动作前的刻度」用，断言不发帧 / 只发一帧都靠它）。
  int mark([String? method]) => core.outgoing(method).length;

  /// 等插件**发出**一条该 method 的帧（刻度之后第一条）；超时返回 null。
  ///
  /// [since] 必须传「动作发生前的 [mark]」：旧帧不该被算成本次的结果，否则用例会
  /// 在「插件其实没反应」时假通过。
  Future<Map<String, dynamic>?> waitNotification(
    String method,
    int since, {
    int ms = 3000,
  }) async {
    final DateTime deadline = DateTime.now().add(Duration(milliseconds: ms));
    while (DateTime.now().isBefore(deadline)) {
      final List<Map<String, dynamic>> hits = core.outgoing(method);
      if (hits.length > since) return hits[since];
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return null;
  }

  /// 断言「这段时间没发帧」之前得先给它机会发完（通知是不 await 地丢给业务层的）。
  Future<bool> quietSince(String method, int since, {int ms = 600}) async {
    await settle(ms);
    return core.outgoing(method).length == since;
  }

  /// 等一条插件日志出现（「处理过」这件事有时只体现在可读原因上）。
  Future<bool> waitLog(String needle, {int ms = 6000}) async {
    final DateTime deadline = DateTime.now().add(Duration(milliseconds: ms));
    while (DateTime.now().isBefore(deadline)) {
      if (hasLog(needle)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return hasLog(needle);
  }

  bool hasLog(String needle) =>
      core.logs.any((String line) => line.contains(needle));

  /// 心跳：核心在等流的同时也看心跳，所以推流期间必须还能答上。
  Future<bool> ping({String id = 'ping'}) async {
    core.ask(id, M.ping, <String, dynamic>{});
    final Map<Object?, Map<String, dynamic>> got = await core.waitFor(<Object?>[
      id,
    ], timeout: const Duration(seconds: 6));
    return got.containsKey(id);
  }

  /// 等插件发出的一条 `station/command`（按命令名），返回它的 params。
  Future<Map<String, dynamic>?> waitCommand(
    String command, {
    int atLeast = 1,
    int ms = 6000,
  }) async {
    final DateTime deadline = DateTime.now().add(Duration(milliseconds: ms));
    while (DateTime.now().isBefore(deadline)) {
      if (commands(command).length >= atLeast) return commands(command).last;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return commands(command).isEmpty ? null : commands(command).last;
  }

  List<Map<String, dynamic>> commands([String? command]) => calls
      .where(
        (Map<String, dynamic> params) =>
            command == null || frameCommand(params) == command,
      )
      .toList(growable: false);

  /// 某槽位最近一帧的 view（面板断言都读这里，不看插件内部状态）。
  Map<String, dynamic> lastView(String method) {
    final List<Map<String, dynamic>> hits = core.outgoing(method);
    if (hits.isEmpty) return <String, dynamic>{};
    return asMap(frameParams(hits.last)['view']);
  }

  /// `ui/manifest` 里的槽位列表。
  List<Object?> manifestSlots() {
    final List<Map<String, dynamic>> hits = core.outgoing(Ui.manifest);
    if (hits.isEmpty) return const <Object?>[];
    final Object? slots = frameParams(hits.last)['slots'];
    return slots is List ? slots : const <Object?>[];
  }

  /// 日志尾部（失败时只看头几行没用：出事的那一行总在最后）。
  String tail([int n = 6]) {
    final List<String> lines = core.logs;
    return rendered(
      lines.length <= n ? lines : lines.sublist(lines.length - n),
    );
  }

  Future<void> settle([int ms = 200]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  /// 收尾：通知 shutdown（骨架会关掉周期任务并退出读循环），避免用例之间留活任务。
  Future<void> close() async {
    core.notify(M.shutdown, <String, dynamic>{});
    await settle(120);
  }
}

/// 一条 `agent.tool_call` 事件的通知 params。
Map<String, dynamic> toolCallEvent({
  required String agentId,
  required String sessionId,
  required String callId,
  required String phase,
  String tool = 'read',
  int round = 1,
}) => <String, dynamic>{
  'event': kEventToolCall,
  'agent_id': agentId,
  'session_id': sessionId,
  'call_id': callId,
  'tool': tool,
  'phase': phase,
  'round': round,
};

/// 一条广播 / 中转请求的通用外壳（`station_id` + `kind` + `scope` + `payload`）。
Map<String, dynamic> stationParams({
  required String stationId,
  required String kind,
  required Map<String, dynamic> payload,
  String requestId = '',
  Map<String, dynamic> meta = const <String, dynamic>{},
}) => <String, dynamic>{
  if (requestId.isNotEmpty) 'request_id': requestId,
  'station_id': stationId,
  'kind': kind,
  'scope': <String, dynamic>{
    'team_id': 'team-1',
    'agent_id': 'agt_demo',
    'session_id': 'ses_demo',
    'mode_key': 'local',
  },
  'payload': <String, dynamic>{
    'point': stationId,
    'agent_id': 'agt_demo',
    'session_id': 'ses_demo',
    ...payload,
  },
  if (meta.isNotEmpty) 'meta': meta,
};

// ── 自检用例 ────────────────────────────────────────────────────

Future<int> selfTest() async {
  final SelfTest check = SelfTest(name: 'sample_plugin');
  final List<String> logs = <String>[];
  await _checkSubscribeShapes(check, logs);
  await _checkStreamTakeover(check, logs);
  await _checkStreamCancel(check, logs);
  await _checkNoTakeover(check, logs);
  await _checkLlmCallShape(check, logs);
  await _checkToolCallShape(check, logs);
  await _checkRenameShape(check, logs);
  await _checkPromptRewrite(check, logs);
  await _checkToolBroadcast(check, logs);
  await _checkUiActionShapes(check, logs);
  await _checkThresholdStop(check, logs);
  await _checkCollectStation(check, logs);
  await _checkToolCallFromModel(check, logs);
  await _checkRelayRewrite(check, logs);
  await _checkPanelSlots(check, logs);
  await _checkSelfStation(check, logs);
  await _checkUsageTextAndOptions(check, logs);
  return check.finish(logs);
}

/// ① 订阅形状：按点位别名订 + 「不带 point 的 relay」那条糖 + `station_ids` 读法。
///
/// 断言落在**插件自己打的那行日志**上：它是「插件真的按回包里的 station_ids 理解厂」
/// 唯一的外部证据（假核心返的形状本身不是被验对象）。
Future<void> _checkSubscribeShapes(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(
    selfOptions(<String>[
      '--no-fs-demo',
      '--no-panel',
      '--relay-llm',
      kDefaultRelayLlmKeyword,
    ]),
  );
  await h.hello();
  check.that(
    await h.waitSubscribes(2),
    'hello 之后必须发出两次订阅（relay 糖 + llm.handle 点位）',
    actual: rendered(h.subscribes()),
  );
  final Map<String, dynamic>? llm = h.subscribeFor(
    (Map<String, dynamic> params) => params['point'] == 'llm.handle',
  );
  check.that(
    llm != null,
    '没发出 llm.handle 的订阅请求（--relay-llm 没生效？）',
    actual: rendered(h.subscribes()),
  );
  if (llm != null) {
    check.check(llm['station'], 'relay', '按**点位别名**订（比写完整 id 抗改名）');
    check.check(llm['replace'], true, '接管语义靠 replace（必须显式写，不能靠默认）');
  }
  // 旧字段 station_id 仍在（= 第一个点位），但“订上没订上”得看 station_ids。
  check.that(
    await h.waitLog(
      '已订阅 relay/llm.handle 站点：station_ids=[system.relay.llm.handle]',
    ),
    '带 point 的订阅只订一个点位（插件读的是 station_ids，不是旧的 station_id）',
    actual: h.tail(),
  );
  // 糖：不带 point 的 relay = 一次订工具前 + 工具后两个点位。
  check.that(
    h.subscribeFor(
          (Map<String, dynamic> params) =>
              params['station'] == 'relay' && params['point'] == null,
        ) !=
        null,
    '默认必须订 relay 那条糖（工具前 + 工具后一次订上）',
    actual: rendered(h.subscribes()),
  );
  check.that(
    await h.waitLog(
      '已订阅 relay 站点：station_ids=[system.relay.tool.pre, system.relay.tool.post]',
    ),
    '糖的回包有两个点位时，插件必须把两个都读成已订上',
    actual: h.tail(),
  );
  check.check(
    h.plugin.relaySubscribed,
    true,
    '糖那次订阅的成功要记进 relaySubscribed（懒订阅靠它不再抢）',
  );
  await h.settle(300);
  check.that(
    h.mark(Ui.manifest) == 0,
    '--no-panel 就不该声明槽位（没申报的 slot_key 会被前端静默忽略）',
    actual: '${h.mark(Ui.manifest)} 帧 manifest',
  );
  logs.addAll(h.core.logs);
  await h.close();
}

/// ② 流式接管：回包先发、增量带原 request_id、收尾带 finish_reason 与 usage。
Future<void> _checkStreamTakeover(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(
    selfOptions(<String>[
      '--no-fs-demo',
      '--no-panel',
      '--no-relay',
      '--relay-llm',
      kDefaultRelayLlmKeyword,
    ]),
  );
  await h.hello();
  await h.settle();
  final Map<String, dynamic> result = await h.askLlmHandle('请用示例插件接管：你好');
  final Object? payload = _Harness.replyPayload(result);
  check.that(
    payload is Map && payload['stream'] == true,
    '命中关键词时应回 {stream: true}（声明了就不能回退）',
    actual: rendered(payload),
  );
  check.check(h.plugin.llmHandleSeen, 1, 'seen 计数只看请求本身（不管接不接管）');
  check.check(h.plugin.llmHandleTaken, 1, 'taken 计数只看真接管了的那几条');
  final Map<String, dynamic>? settled = await h.waitStreamSettled(
    h.lastStreamId,
  );
  check.that(settled != null, '没等到 done / error 收尾（这一轮核心会一直等）');
  if (settled != null) {
    check.check(settled['done'], true, '收尾必须是 done（不是只靠 error）');
    check.check(settled['finish_reason'], 'stop', 'done 得带 finish_reason');
    check.that(
      asMap(settled['usage']).isNotEmpty,
      'done 得带 usage（前端那一行没它就没法记账）',
      actual: rendered(settled['usage']),
    );
  }
  final List<Map<String, dynamic>> notes = h.streamsOf(h.lastStreamId);
  check.that(
    notes.length >= 4,
    '增量太少（应 3~5 片 + done）',
    actual: '${notes.length} 条',
  );
  // **最关键的一条**：每一条增量都带请求里那个 request_id，不能自己编。
  check.that(
    notes.every(
      (Map<String, dynamic> frame) =>
          asString(frameParams(frame)['request_id']) == h.lastStreamId,
    ),
    'station/stream 的 request_id 与请求不一致（核心会丢弃整条流）',
    actual: rendered(notes.map((f) => frameParams(f)['request_id']).toList()),
  );
  final List<String> kinds = <String>[
    for (final Map<String, dynamic> frame in notes)
      if (frameParams(frame)['delta'] != null)
        asString(asMap(frameParams(frame)['delta'])['kind']),
  ];
  check.that(
    kinds.contains('thinking'),
    '没有 thinking 增量',
    actual: rendered(kinds),
  );
  check.that(
    kinds.where((String kind) => kind == 'text').length >= 3,
    '正文不足 3 片（分片推的意义就在于看得出逐字到达）',
    actual: rendered(kinds),
  );
  final String text = <String>[
    for (final Map<String, dynamic> frame in notes)
      if (asString(asMap(frameParams(frame)['delta'])['kind']) == 'text')
        asString(asMap(frameParams(frame)['delta'])['text']),
  ].join();
  check.that(
    text.contains('示例插件已接管本轮 LLM'),
    '正文分片拼不出预期内容',
    actual: _clip(text, 80),
  );
  // 推流期间读循环不能被占住：否则核心的心跳判活会把插件当死进程。
  check.that(await h.ping(id: 'ping-during-stream'), '推流期间 ping 没被应答（心跳会丢）');
  logs.addAll(h.core.logs);
  await h.close();
}

/// ③ `station/cancel`：停流、不崩、之后仍应答 ping、不再推 done，且第二条流照常接管。
Future<void> _checkStreamCancel(SelfTest check, List<String> logs) async {
  final Options options = selfOptions(<String>[
    '--no-fs-demo',
    '--no-panel',
    '--no-relay',
    '--relay-llm',
    kDefaultRelayLlmKeyword,
  ]);
  // 这一条把片间隔改回默认量级：取消是**逐片检查**的，太快推完就看不出“真的停了”。
  options.streamChunkPauseMs = 200;
  final _Harness h = _Harness(options);
  await h.hello();
  await h.settle();
  const String pid = 'relay-selftest-cancel';
  final Object? payload = _Harness.replyPayload(
    await h.askLlmHandle('请用示例插件接管：会被取消', streamId: pid),
  );
  check.that(
    payload is Map && payload['stream'] == true,
    '命中关键词应回 {stream: true}',
    actual: rendered(payload),
  );
  // 声明接管之后**立刻**取消（不等 done）。
  h.core.notify(M.stationCancel, <String, dynamic>{
    'request_id': pid,
    'reason': '用户已停止本轮生成',
  });
  check.that(
    await h.waitLog('停止推流'),
    '插件没报告收到 station/cancel 并停流',
    actual: h.tail(),
  );
  check.that(
    await h.ping(id: 'ping-after-cancel'),
    '取消之后插件不再应答 ping（读循环被推流占住了？）',
  );
  await h.settle(900); // 留出“没真的停就会继续推片”的时间窗
  final List<Map<String, dynamic>> notes = h.streamsOf(pid);
  check.that(
    notes.every(
      (Map<String, dynamic> frame) => frameParams(frame)['done'] != true,
    ),
    '取消之后仍推了 done（核心已收尾，会记无效 id）',
  );
  final int deltas = notes
      .where(
        (Map<String, dynamic> frame) => frameParams(frame)['delta'] != null,
      )
      .length;
  check.that(deltas <= 1, '取消之后还在推增量（说明没真的停流）', actual: '$deltas 条');
  check.check(
    h.plugin.streams.containsKey(pid),
    false,
    '流状态必须清掉（否则下一路同 id 的流会被当成已取消）',
  );
  // 取消不能把读循环 / 后台任务弄坏：第二条流必须照常接管并收尾。
  const String again = 'relay-selftest-after-cancel';
  final Object? second = _Harness.replyPayload(
    await h.askLlmHandle('请用示例插件接管：取消之后再来一次', streamId: again),
  );
  check.that(
    second is Map && second['stream'] == true,
    '取消之后无法再接管',
    actual: rendered(second),
  );
  check.that(await h.waitStreamSettled(again) != null, '取消之后的第二条流没能在超时内收尾');
  logs.addAll(h.core.logs);
  await h.close();
}

/// ④ 关键词不命中 ⇒ 回 `{reply:{payload:null}}`（不接管，照走系统 LLM）。
Future<void> _checkNoTakeover(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(
    selfOptions(<String>[
      '--no-fs-demo',
      '--no-panel',
      '--no-relay',
      '--relay-llm',
      kDefaultRelayLlmKeyword,
    ]),
  );
  await h.hello();
  await h.settle();
  final Map<String, dynamic> result = await h.askLlmHandle('这是一条普通消息，没有关键词');
  check.that(
    result.containsKey('reply'),
    '不接管也必须回包（回包缺席 = 核心整条生成悬着）',
    actual: rendered(result.keys.toList()),
  );
  check.check(
    _Harness.replyPayload(result),
    null,
    '不命中时应回 {reply:{payload:null}}（null 是“交给系统 LLM”的唯一写法）',
  );
  await h.settle(300);
  check.that(
    h.streamsOf(h.lastStreamId).isEmpty,
    '不接管却推了 station/stream 增量',
    actual: '${h.streamsOf(h.lastStreamId).length} 条',
  );
  check.check(h.plugin.llmHandleTaken, 0, '没接管就不能记进 taken（面板那行靠它）');
  check.that(h.hasLog('不含关键词'), '不接管必须留一行可读原因（否则用户只看到“插件怎么没反应”）');
  logs.addAll(h.core.logs);
  await h.close();
}

/// ⑤ `llm.call` 的请求构造（命令名在 params.command、参数在 arguments、身份在顶层）。
Future<void> _checkLlmCallShape(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(
    selfOptions(<String>[
      '--no-fs-demo',
      '--no-panel',
      '--no-relay',
      '--agent-id',
      'agt_demo',
      '--llm-call',
      '回一个 JSON：{"ok":true}',
    ]),
  );
  await h.hello();
  final Map<String, dynamic>? params = await h.waitCommand(kCommandLlmCall);
  check.that(
    params != null,
    '没有发出 llm.call 命令',
    actual: rendered(h.commands()),
  );
  if (params == null) return;
  check.check(frameCommand(params), kCommandLlmCall, '命令名写在 params.command');
  check.that(
    params['agent_id'] == 'agt_demo',
    '身份写在 params 顶层（核心两处都读，写两处一定漂）',
    actual: rendered(params.keys.toList()),
  );
  final Map<String, dynamic> args = frameArguments(params);
  check.check(args['prompt'], '回一个 JSON：{"ok":true}', 'prompt 得原样带上');
  check.that(args['system'] != null, 'system 提示词要带上（站点把它当 system 消息）');
  check.that(
    args['agent_id'] == null,
    'arguments 里不再写一份 agent_id（两份真相写同一个东西一定漂）',
    actual: rendered(args.keys.toList()),
  );
  check.that(
    await h.waitLog('llm.call 成功'),
    'llm.call 回包没被解析成可读日志',
    actual: h.tail(),
  );
  check.that(
    h.hasLog('json={"ok":true}'),
    '站点已经解析好的 json 必须打出来（只看 text 就浪费了一个字段）',
    actual: h.tail(),
  );
  logs.addAll(h.core.logs);
  await h.close();
}

/// ⑥ `tool.call` 的请求构造（默认**绕开**工具中转 / 广播）。
Future<void> _checkToolCallShape(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(
    selfOptions(<String>[
      '--no-fs-demo',
      '--no-panel',
      '--no-relay',
      '--agent-id',
      'agt_demo',
      '--tool-call',
      'read',
      '{"file_path": "README.md"}',
    ]),
  );
  await h.hello();
  final Map<String, dynamic>? params = await h.waitCommand(kCommandToolCall);
  check.that(
    params != null,
    '没有发出 tool.call 命令',
    actual: rendered(h.commands()),
  );
  if (params == null) return;
  final Map<String, dynamic> args = frameArguments(params);
  check.check(args['tool'], 'read', 'tool 名');
  check.check(args['arguments'], <String, dynamic>{
    'file_path': 'README.md',
  }, '工具自己的 arguments 得原样带上（命令行那段 JSON 不经加加工）');
  check.check(
    args['relay'],
    false,
    '默认必须绕开工具中转 / 广播（既订 tool.pre 又发 tool.call 时，不绕开就是自锁）',
  );
  check.check(params['agent_id'], 'agt_demo', '身份写在 params 顶层');
  check.that(
    await h.waitLog('tool.call 结果'),
    'tool.call 回包没被解析',
    actual: h.tail(),
  );
  check.that(
    h.hasLog('relayed=false'),
    'relay=false 就得真看到“没绕道”（回包里的 relayed 是唯一证据）',
    actual: h.tail(),
  );
  logs.addAll(h.core.logs);
  await h.close();
}

/// ⑦ `session.rename` 的请求构造（title 必填、带时间戳）。
Future<void> _checkRenameShape(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(
    selfOptions(<String>[
      '--no-fs-demo',
      '--no-panel',
      '--no-relay',
      '--agent-id',
      'agt_demo',
      '--rename-session',
    ]),
  );
  await h.hello();
  final Map<String, dynamic>? params = await h.waitCommand(
    kCommandSessionRename,
  );
  check.that(
    params != null,
    '没有发出 session.rename 命令',
    actual: rendered(h.commands()),
  );
  if (params == null) return;
  final Map<String, dynamic> args = frameArguments(params);
  final String title = asString(args['title']);
  check.that(
    title.trim().isNotEmpty,
    'title 为空会被执行站拒（写一个空标题等于发一条注定失败的命令）',
    actual: rendered(args),
  );
  check.that(
    title.startsWith('$kPluginName改名 '),
    'title 不像本插件的命名',
    actual: title,
  );
  check.that(
    title.length > '$kPluginName改名 '.length + 10,
    'title 没带时间戳（改名不看时间就分不出是哪一次）',
    actual: title,
  );
  check.check(params['agent_id'], 'agt_demo', '身份写在 params 顶层');
  check.that(
    !args.containsKey('session_id'),
    '没见过事件就不该塞一个空 session_id（空值不写）',
    actual: rendered(args.keys.toList()),
  );
  check.that(
    await h.waitLog('session.rename 成功'),
    'session.rename 回包没被解析',
    actual: h.tail(),
  );
  logs.addAll(h.core.logs);
  await h.close();
}

/// ⑧ `--relay-prompt`：订 prompt.system 点位，并在 default 后面追加一行。
Future<void> _checkPromptRewrite(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(
    selfOptions(<String>[
      '--no-fs-demo',
      '--no-panel',
      '--no-relay',
      '--relay-prompt',
    ]),
  );
  await h.hello();
  check.that(
    await h.waitLog(
      '已订阅 relay/prompt.system 站点：station_ids=[system.relay.prompt.system]',
    ),
    '没订上 prompt.system 点位（--relay-prompt 没生效？）',
    actual: h.tail(),
  );
  final Map<String, dynamic> result = await h.drive(
    stationParams(
      stationId: kPointRelayPromptSystem,
      kind: 'relay',
      requestId: 'relay-selftest-prompt',
      payload: <String, dynamic>{'default': '你是 Tree 的助手。'},
    ),
  );
  final Object? payload = _Harness.replyPayload(result);
  check.that(
    payload is String,
    '改写后的提示词必须回字符串（回对象核心不认）',
    actual: rendered(payload),
  );
  final String text = payload == null ? '' : '$payload';
  check.that(
    text.startsWith('你是 Tree 的助手。'),
    '必须保留 default 原文（改写不是覆盖）',
    actual: _clip(text, 80),
  );
  check.that(
    text.contains(kPromptMarker),
    '改写标记没加上（这段提示词被动过要留得出来）',
    actual: _clip(text, 80),
  );
  check.check(h.plugin.promptRewrites, 1, '改写次数得进计数（面板那一行靠它）');
  // default 缺席（核心没构出提示词）：不能回 null 假装没接管，得留下标记。
  final Map<String, dynamic> bare = await h.drive(
    stationParams(
      stationId: kPointRelayPromptSystem,
      kind: 'relay',
      requestId: 'relay-selftest-prompt-bare',
      payload: <String, dynamic>{},
    ),
  );
  check.check(
    _Harness.replyPayload(bare),
    kPromptMarker,
    'default 缺席时也只回标记（回空串 = 明确不要系统提示词，与“不改”是两种语义）',
  );
  check.check(h.plugin.promptRewrites, 2, '两次改写都得计数');
  logs.addAll(h.core.logs);
  await h.close();
}

/// ⑨ `--watch-tools`：两个广播点位都订上、收到通知照常回包、计数分开走。
Future<void> _checkToolBroadcast(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(
    selfOptions(<String>[
      '--no-fs-demo',
      '--no-panel',
      '--no-relay',
      '--watch-tools',
    ]),
  );
  await h.hello();
  await h.waitSubscribes(2);
  final Set<String> points = <String>{
    for (final Map<String, dynamic> params in h.subscribes())
      if (params['station'] == 'broadcast') '${params['point']}',
  };
  check.check(points, <String>{
    'tool.pre',
    'tool.post',
  }, '两个工具广播点位必须都订上（广播站不带 point 只订通用主题，与 relay 那条糖不对称）');
  for (final (String phase, String point) in <(String, String)>[
    ('pre', kPointBroadcastToolPre),
    ('post', kPointBroadcastToolPost),
  ]) {
    final Map<String, dynamic> result = await h.drive(
      stationParams(
        stationId: point,
        kind: 'broadcast',
        requestId: 'broadcast-$phase',
        payload: <String, dynamic>{
          'phase': phase,
          'origin': 'agent',
          'tool': 'read',
          'call_id': 'call_b1',
          'round': 1,
          'arguments': <String, dynamic>{'file_path': 'a.txt'},
          'result': 'A 的内容',
          'is_error': false,
        },
        meta: <String, dynamic>{'topic': 'tool.$phase'},
      ),
    );
    check.that(
      result.containsKey('reply'),
      '广播也得回包（核心在等这一条，只是通知方不等它阻塞工具执行）',
      actual: rendered(result.keys.toList()),
    );
    check.check(
      _Harness.replyPayload(result),
      null,
      '广播回包应是 {reply:{payload:null}}（没有附言）',
    );
  }
  check.check(h.plugin.toolBroadcastTotal, 2, '广播总数');
  check.check(h.plugin.toolBroadcastPre, 1, 'pre 计数（不能全算进总数而不分段）');
  check.check(h.plugin.toolBroadcastPost, 1, 'post 计数');
  check.that(h.hasLog('工具广播（第 2 次）'), '广播得留一条可读日志');
  // 不认识的站点类型显式拒绝（不静默）：本插件只订上面那几个点位。
  final Map<String, dynamic> other = await h.drive(
    stationParams(
      stationId: 'system.unknown.thing',
      kind: 'collect2',
      payload: <String, dynamic>{},
    ),
  );
  check.that(
    asString(asMap(other['reply'])['error']).isNotEmpty,
    '不响应的点位必须回一条可读 error（静默回 null 会被当成“处理过了”）',
    actual: rendered(other),
  );
  logs.addAll(h.core.logs);
  await h.close();
}

/// ⑩ 面板按钮回传：核心发的是 **event 通知**（判据在 `params.event`，不是 method）。
///
/// 这条链路以前是断的：当时判 `method == "plugin_ui_action"`，而核心实际发
/// `{"method":"event","params":{"event":"plugin_ui_action",…}}` ⇒ 面板按钮“点了没
/// 反应”（而它的兄弟分支还会把这个事件当“非 tool_call 事件”丢掉）。所以两种形态都喂。
Future<void> _checkUiActionShapes(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(
    selfOptions(<String>['--no-fs-demo', '--card-interval', '0']),
  );
  await h.hello();
  await h.settle(200);
  final String slot = h.plugin.activitySlotKey;
  // ① 线上真实形状：event 通知 + params.event == plugin_ui_action。
  final int since = h.mark(Ui.update);
  final int frameSince = h.core.frames.length;
  h.core.notify(M.event, <String, dynamic>{
    'event': kEventUiAction,
    'plugin_id': kPluginId,
    'team_id': 'team-1',
    'agent_id': 'agt_demo',
    'session_id': 'ses_demo',
    'slot_key': slot,
    'action_id': 'refresh',
    'payload': <String, dynamic>{},
  });
  final Map<String, dynamic>? update = await h.waitNotification(
    Ui.update,
    since,
  );
  check.that(
    update != null,
    'event 形态的面板动作没被处理（判据必须是 params.event，不是 method）',
    actual: h.tail(),
  );
  if (update != null) {
    final Map<String, dynamic> params = frameParams(update);
    check.check(params['slot_key'], slot, '刷新的必须是活动栏那个槽位');
    check.that(
      params['view'] is Map,
      'ui/update 得带 view（整块替换没视图就无法替换）',
      actual: rendered(params.keys.toList()),
    );
    check.check(validateUiView(params['view']), <String>[], '刷新的视图必须合受限控件集');
  }
  // 两个槽位一起刷：只刷 activity 会让右栏 Tab 永远停在启动那一刻的“已计数 0 次”。
  final List<Map<String, dynamic>> updates = h.core.outgoing(Ui.update);
  check.check(
    updates.length >= since + 2
        ? <Object?>[
            frameParams(updates[since])['slot_key'],
            frameParams(updates[since + 1])['slot_key'],
          ]
        : <Object?>[],
    <Object?>[slot, h.plugin.panelSlotKey],
    'activity + panel 两个槽位必须成对刷新',
  );
  // ② 老核心 / 直连测试的形状：裸 method=plugin_ui_action 同样要处理。
  final int since2 = h.mark(Ui.update);
  h.core.notify(kEventUiAction, <String, dynamic>{
    'action_id': 'refresh',
    'slot_key': '',
  });
  check.that(
    await h.waitNotification(Ui.update, since2) != null,
    '裸 method=plugin_ui_action 的形状没兼容（老核心点按钮会没反应）',
    actual: h.tail(),
  );
  // ③ 无关事件不该被误当成面板动作（判据放宽不能宽到把 tool_call 也吃进去）。
  final int since3 = h.mark(Ui.update);
  h.core.notify(
    M.event,
    toolCallEvent(
      agentId: 'agt_demo',
      sessionId: 'ses_demo',
      callId: 'call_x',
      phase: kPhaseEnd,
    ),
  );
  check.that(
    await h.quietSince(Ui.update, since3),
    '非面板事件不该触发面板刷新',
    actual: '${h.mark(Ui.update) - since3} 帧',
  );
  // 未知 action 不刷面板、但要留在日志里（不静默）。
  final int since4 = h.mark(Ui.update);
  h.core.notify(M.event, <String, dynamic>{
    'event': kEventUiAction,
    'action_id': '不存在的动作',
    'slot_key': slot,
    'payload': <String, dynamic>{},
  });
  check.that(
    await h.quietSince(Ui.update, since4),
    '未知 action 不该刷新面板',
    actual: '${h.mark(Ui.update) - since4} 帧',
  );
  check.that(
    h.hasLog('不存在的动作'),
    '未知 action 必须留日志（不静默：否则用户只会觉得按钮坏了）',
    actual: h.tail(),
  );
  // 按钮回调是**单向**的：全程不该吾出响应报文（核心没发请求过来）。
  final List<Map<String, dynamic>> responses = h.core.frames
      .sublist(frameSince)
      .where(
        (Map<String, dynamic> frame) =>
            frame['id'] != null && frame['method'] == null,
      )
      .toList(growable: false);
  check.that(
    responses.isEmpty,
    '面板动作是通知：插件不该回响应',
    actual: rendered(responses.length),
  );
  logs.addAll(h.core.logs);
  await h.close();
}

/// ⑪ 本插件的主打功能：超阈值就经执行站发 `agent.stop`，**发完重置计数**。
Future<void> _checkThresholdStop(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(
    selfOptions(<String>[
      '--no-fs-demo',
      '--no-panel',
      '--no-relay',
      '--card-interval',
      '0',
      '--threshold',
      '2',
    ]),
  );
  await h.hello();
  await h.settle(150);
  for (final String callId in <String>['c1', 'c2', 'c3']) {
    h.core.notify(
      M.event,
      toolCallEvent(
        agentId: 'agt_x',
        sessionId: 'ses_x',
        callId: callId,
        phase: kPhaseStart,
      ),
    );
  }
  final Map<String, dynamic>? stop = await h.waitCommand(kCommandAgentStop);
  check.that(stop != null, '超阈值没发 agent.stop（Q8 的主线就丢了）', actual: h.tail());
  if (stop != null) {
    check.check(stop['agent_id'], 'agt_x', '停的是那个超限的 agent（身份写在 params 顶层）');
    check.check(
      stop['session_id'],
      'ses_x',
      'session 身份也得带上（同一 agent 多个会话不能全停）',
    );
    check.check(
      frameArguments(stop)['cascade'],
      false,
      '默认只停该 agent（要停整棵团队树得显式开 --stop-cascade）',
    );
  }
  check.check(
    h.commands(kCommandAgentStop).length,
    1,
    '发完必须重置计数（否则后续每一次调用都再发一次停）',
  );
  check.check(h.plugin.counts['agt_x|ses_x'], 0, '计数重置回 0（不能只发信号不清账）');
  check.check(h.plugin.totalStarted, 3, 'total 是全局累计，不随重置清掉');
  check.check(h.plugin.stopCount, 1, '停止次数得进计数（卡片那一行靠它）');
  check.that(h.hasLog('计数已重置'), '超限与重置都要留可读日志（前端能看见）');
  // 重置后的两轮不该再停（阈值 2：count 1/2 都没超），第三轮才停。
  h.core.notify(
    M.event,
    toolCallEvent(
      agentId: 'agt_x',
      sessionId: 'ses_x',
      callId: 'c4',
      phase: kPhaseStart,
    ),
  );
  h.core.notify(
    M.event,
    toolCallEvent(
      agentId: 'agt_x',
      sessionId: 'ses_x',
      callId: 'c5',
      phase: kPhaseStart,
    ),
  );
  await h.settle(300);
  check.check(h.commands(kCommandAgentStop).length, 1, '重置后未超阈值不该再停');
  h.core.notify(
    M.event,
    toolCallEvent(
      agentId: 'agt_x',
      sessionId: 'ses_x',
      callId: 'c6',
      phase: kPhaseStart,
    ),
  );
  check.that(
    await h.waitCommand(kCommandAgentStop, atLeast: 2) != null,
    '重置后再次超限必须能再停一次',
    actual: '${h.commands(kCommandAgentStop).length} 条',
  );
  // 另一条 agent 线单独计数（共用一张表就是串了）。
  h.core.notify(
    M.event,
    toolCallEvent(
      agentId: 'agt_y',
      sessionId: 'ses_y',
      callId: 'c7',
      phase: kPhaseStart,
    ),
  );
  await h.settle(200);
  check.check(h.plugin.counts['agt_y|ses_y'], 1, '新 (agent, session) 从 0 开始数');
  // end 事件专门用来算耗时（只看 start 就报不出“一轮多久”）。
  h.core.notify(
    M.event,
    toolCallEvent(
      agentId: 'agt_y',
      sessionId: 'ses_y',
      callId: 'c7',
      phase: kPhaseEnd,
    ),
  );
  await h.settle(200);
  check.that(
    h.plugin.lastDurationMs != null,
    'start→end 得算出耗时（卡片那一行靠它）',
    actual: '${h.plugin.lastDurationMs}',
  );
  // 其它事件（不是 tool_call）只记 stderr、不动作：先发给它一条，再看那行日志在不在。
  h.core.notify(M.event, <String, dynamic>{
    'event': 'agent.phase',
    'phase': 'end',
  });
  await h.settle(200);
  check.that(
    h.hasLog('收到非 tool_call 事件'),
    '其它事件必须留一行 stderr（不静默无痕：查问题时就靠它看出事件确实进来了）',
    actual: h.tail(),
  );
  logs.addAll(h.core.logs);
  await h.close();
  // 级联开关：同一个参数得真的穿到命令里（否则 --stop-cascade 只是个摆设）。
  final _Harness cascade = _Harness(
    selfOptions(<String>[
      '--no-fs-demo',
      '--no-panel',
      '--no-relay',
      '--card-interval',
      '0',
      '--threshold',
      '0',
      '--stop-cascade',
    ]),
  );
  await cascade.hello();
  cascade.core.notify(
    M.event,
    toolCallEvent(
      agentId: 'agt_z',
      sessionId: 'ses_z',
      callId: 'c1',
      phase: kPhaseStart,
    ),
  );
  final Map<String, dynamic>? stop2 = await cascade.waitCommand(
    kCommandAgentStop,
  );
  check.that(stop2 != null, '阈值为 0 时第一条就该停', actual: cascade.tail());
  check.check(
    stop2 == null ? null : asMap(frameArguments(stop2))['cascade'],
    true,
    '--stop-cascade 得真的写进 arguments.cascade',
  );
  logs.addAll(cascade.core.logs);
  await cascade.close();
}

/// ⑫ 收集站：回包根对象**只允许 tools 一个键**，两套形状（收集站 / tools/list）同一份定义。
Future<void> _checkCollectStation(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(
    selfOptions(<String>[
      '--no-fs-demo',
      '--no-panel',
      '--no-relay',
      '--card-interval',
      '0',
    ]),
  );
  await h.hello();
  await h.settle(150);
  final Map<String, dynamic> result = await h.drive(<String, dynamic>{
    'request_id': 'collect-1',
    'station_id': kPointToolDefine,
    'kind': 'collect',
    'scope': <String, dynamic>{'team_id': 'team-1', 'agent_id': 'agt_demo'},
    'schema': <String, dynamic>{
      'fields': <Map<String, dynamic>>[
        <String, dynamic>{'name': 'tools', 'type': 'array'},
      ],
    },
    'payload': <String, dynamic>{},
  });
  final Object? payload = _Harness.replyPayload(result);
  check.that(
    payload is Map,
    '收集站必须回一个对象 payload（不接管也要回，不能让核心悬着）',
    actual: rendered(payload),
  );
  if (payload is! Map) return;
  // 多一个键就是“未声明的字段”：核心会整条拒掉，插件自己看不出来。
  check.check(payload.keys.toList(), <String>[
    'tools',
  ], '回包根对象只允许 tools 一个键（站点 schema 严格校验）');
  final List<Object?> tools = payload['tools'] is List
      ? payload['tools'] as List<Object?>
      : <Object?>[];
  check.check(
    tools.map((Object? t) => asString(asMap(t)['tool_name'])).toList(),
    <String>['echo', 'rounds', 'read_probe'],
    '申报的三个工具（名字与顺序都得稳）',
  );
  for (final Object? tool in tools) {
    final Map<String, dynamic> item = asMap(tool);
    final String name = asString(item['tool_name']);
    check.check(
      asString(asMap(item['execution'])['method']),
      M.toolsCall,
      'execution.method 得是 tools/call（$name）',
    );
    check.check(
      asString(asMap(item['execution'])['name']),
      name,
      'execution.name 得与 tool_name 对得上（模型调的那一个）',
    );
    check.that(
      asString(item['description']).isNotEmpty,
      '每个工具都得有可读描述（$name）',
      actual: rendered(item.keys.toList()),
    );
    check.check(
      asString(asMap(item['parameters'])['type']),
      'object',
      'parameters 必须是 object schema（$name）',
    );
  }
  check.check(asMap(asMap(tools.first)['parameters'])['required'], <String>[
    'text',
  ], 'echo 的 text 得标 required（不标模型会空参调过来）');
  // schema 里没有 tools ⇒ 插件不能假装收集到了东西。
  final Map<String, dynamic> noTools = await h.drive(<String, dynamic>{
    'request_id': 'collect-2',
    'station_id': kPointToolDefine,
    'kind': 'collect',
    'schema': <String, dynamic>{
      'fields': <Map<String, dynamic>>[
        <String, dynamic>{'name': 'something_else'},
      ],
    },
    'payload': <String, dynamic>{},
  });
  check.that(
    asString(asMap(noTools['reply'])['error']).contains('未声明 tools 字段'),
    '站点 schema 没 tools 字段时要回可读错误（空回包会被当成“没有工具”）',
    actual: rendered(noTools),
  );
  // tools/list 是另一套名字（name / inputSchema），与收集站共用一份定义。
  h.core.ask('tools-list', M.toolsList, <String, dynamic>{});
  final Map<Object?, Map<String, dynamic>> got = await h.core.waitFor(<Object?>[
    'tools-list',
  ]);
  final List<Object?> listed = asList(
    got['tools-list'] == null
        ? null
        : asMap(got['tools-list']!['result'])['tools'],
  );
  check.check(
    listed.map((Object? t) => asString(asMap(t)['name'])).toList(),
    <String>['echo', 'rounds', 'read_probe'],
    'tools/list 与收集站共用的那份定义不能两处写歪',
  );
  check.that(
    listed.every(
      (Object? t) =>
          asMap(t).containsKey('inputSchema') &&
          !asMap(t).containsKey('tool_name'),
    ),
    'tools/list 那套用 name / inputSchema（不是收集站的 tool_name / parameters）',
    actual: rendered(listed.isEmpty ? null : asMap(listed.first).keys.toList()),
  );
  check.that(h.hasLog('收集站请求：申报 3 个工具'), '收集站那一眼得留日志（申报了什么）');
  logs.addAll(h.core.logs);
  await h.close();
}

/// ⑬ 模型真的调工具：echo / rounds / read_probe（最后这个**要等执行站回包**）。
Future<void> _checkToolCallFromModel(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(
    selfOptions(<String>[
      '--no-fs-demo',
      '--no-panel',
      '--no-relay',
      '--card-interval',
      '0',
      '--agent-id',
      'agt_demo',
    ]),
  );
  await h.hello();
  await h.settle(150);
  final Map<String, dynamic> echo = await _askCore(
    h.core,
    'tc-echo',
    M.toolsCall,
    <String, dynamic>{
      'name': 'echo',
      'arguments': <String, dynamic>{'text': 'hi'},
    },
  );
  check.check(
    toolTextOf(echo),
    'plugin-echo: hi',
    'echo 回显（工具结果形状 = content[].text）',
  );
  check.check(echo['isError'], false, 'echo 不该报错');
  final Map<String, dynamic> rounds = await _askCore(
    h.core,
    'tc-rounds',
    M.toolsCall,
    <String, dynamic>{'name': 'rounds', 'arguments': <String, dynamic>{}},
  );
  final Object? counted = json.decode(toolTextOf(rounds));
  check.check(
    asMap(counted)['plugin_id'],
    kPluginId,
    'rounds 得把插件 id 报回去（核心按来源路由工具名）',
  );
  for (final String key in <String>[
    'threshold',
    'total_started',
    'stop_count',
    'llm_handle_taken',
    'tool_broadcast_seen',
  ]) {
    check.that(
      asMap(counted).containsKey(key),
      'rounds 的 JSON 摘要得带 $key（演示与排障都只看这一行）',
      actual: rendered(asMap(counted).keys.toList()),
    );
  }
  // read_probe：**工具里也能主动下命令**（骨架的 onToolCall 因此得是异步的）。
  final Map<String, dynamic> probe = await _askCore(
    h.core,
    'tc-probe',
    M.toolsCall,
    <String, dynamic>{
      'name': 'read_probe',
      'arguments': <String, dynamic>{'path': 'a.txt'},
    },
  );
  final String probeText = toolTextOf(probe);
  check.that(
    probeText.contains('fs.read 成功'),
    'read_probe 必须等到执行站回包才能回答（同步签名就只能先回一句“请稍后”）',
    actual: _clip(probeText, 80),
  );
  check.that(
    probeText.contains('第 1 行') && probeText.contains('truncated=true'),
    '读到的前几行与 total_lines / truncated 都得在摘要里',
    actual: _clip(probeText, 120),
  );
  final Map<String, dynamic>? read = h.commands(kCommandFsRead).isEmpty
      ? null
      : h.commands(kCommandFsRead).last;
  check.check(
    read == null ? null : frameArguments(read)['path'],
    'a.txt',
    'arguments.path 得原样传给 fs.read',
  );
  check.check(
    read == null ? null : frameArguments(read)['line_count'],
    20,
    '只读前 20 行（示例摘要不能塞下一整个文件）',
  );
  check.check(
    read == null ? null : read['agent_id'],
    'agt_demo',
    '工具里的命令也得带身份（params 顶层）',
  );
  // **本次调用的身份压过 `--agent-id`**：骨架把 `tools/call` 的 scope 递下来，为的就是这一条。
  // 不递的话，本例只会拿配置里写死的那个 agent——多 team / 空 scope 下那就是错的，
  // 而核心按目标 agent 的真实归属解析作用域，错的结局是 fail-closed 拒绝。
  final Map<String, dynamic> probe2 = await _askCore(
    h.core,
    'tc-probe2',
    M.toolsCall,
    <String, dynamic>{
      'name': 'read_probe',
      'arguments': <String, dynamic>{'path': 'b.txt'},
      'scope': <String, dynamic>{
        'agent_id': 'agt_caller',
        'session_id': 'ses_caller',
      },
    },
  );
  final List<Map<String, dynamic>> reads = h.commands(kCommandFsRead);
  final Map<String, dynamic> read2 = reads.isEmpty ? <String, dynamic>{} : reads.last;
  check.check(
    read2['agent_id'],
    'agt_caller',
    'fs.read 必须打给**这次调用的** agent（不是 --agent-id 里那个兜底）',
  );
  check.check(
    frameArguments(read2)['path'],
    'b.txt',
    '第二次调用的 path 得跟着走（身份换了不能还拿着上一次的参数）',
  );
  check.that(
    toolTextOf(probe2).contains('agent=agt_caller'),
    '回给模型的摘要要说得出打给了谁（排障时靠这一行分辨“猜的”还是“跟着调用的”）',
    actual: _clip(toolTextOf(probe2), 120),
  );
  // 未知工具：回可读原因 + isError（不能抛异常，否则整条工具调用变成协议错误）。
  final Map<String, dynamic> unknown = await _askCore(
    h.core,
    'tc-unknown',
    M.toolsCall,
    <String, dynamic>{'name': 'nope', 'arguments': <String, dynamic>{}},
  );
  check.check(unknown['isError'], true, '未知工具要回 isError');
  check.that(
    toolTextOf(unknown).contains('未知工具 nope'),
    '未知工具的可读原因得说出是哪个工具',
    actual: toolTextOf(unknown),
  );
  // 缺 name 是参数非法（-32602），不能塞进工具结果里冒充“某个工具失败了”。
  h.core.ask('tc-noname', M.toolsCall, <String, dynamic>{});
  final Map<Object?, Map<String, dynamic>> noname = await h.core.waitFor(
    <Object?>['tc-noname'],
  );
  check.that(
    asMap(asMap(noname['tc-noname'])['error'])['code'] == -32602,
    'tools/call 缺 name = -32602（与“工具自己失败”分得很开）',
    actual: rendered(noname['tc-noname']),
  );
  logs.addAll(h.core.logs);
  await h.close();
  // 没目标 agent 时 read_probe 的失败路径（不崩、给模型一句可读原因）。
  final _Harness bare = _Harness(
    selfOptions(<String>[
      '--no-fs-demo',
      '--no-panel',
      '--no-relay',
      '--card-interval',
      '0',
    ]),
  );
  await bare.hello();
  await bare.settle(150);
  final Map<String, dynamic> miss = await _askCore(
    bare.core,
    'tc-miss',
    M.toolsCall,
    <String, dynamic>{
      'name': 'read_probe',
      'arguments': <String, dynamic>{'path': 'a.txt'},
    },
  );
  check.check(
    miss['isError'],
    true,
    '没有目标 agent 时 read_probe 要回 isError（不能假报成功）',
  );
  check.that(
    bare.commands(kCommandFsRead).isEmpty,
    '解析不出 agent 就不该把命令发出去（发出去也只会被核心 fail-closed 拒掉）',
    actual: rendered(bare.commands()),
  );
  check.that(
    bare.hasLog('没有目标 agent'),
    '跳过演示必须留可读原因（否则用户只看到工具没反呺）',
    actual: bare.tail(),
  );
  logs.addAll(bare.core.logs);
  await bare.close();
}

/// 核心 → 插件一条请求，等它的 `result`（错误响应返回空表）。
Future<Map<String, dynamic>> _askCore(
  FakeCore core,
  String id,
  String method,
  Map<String, dynamic> params,
) async {
  core.ask(id, method, params);
  final Map<Object?, Map<String, dynamic>> got = await core.waitFor(<Object?>[
    id,
  ], timeout: const Duration(seconds: 10));
  return asMap(asMap(got[id])['result']);
}

/// 把 `toolText` 形状里的正文取出来。
String toolTextOf(Map<String, dynamic> result) {
  final List<Object?> content = asList(result['content']);
  if (content.isEmpty) return '';
  return asString(asMap(content.first)['text']);
}

/// 把可能是 null / 不是 List 的字段当成空列表看。
List<Object?> asList(Object? value) => value is List ? value : <Object?>[];

/// ⑭ 中转站 pre / post：插件自己决定改不改（改的地方都带可回溯的标记）。
Future<void> _checkRelayRewrite(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(
    selfOptions(<String>['--no-fs-demo', '--no-panel', '--card-interval', '0']),
  );
  await h.hello();
  await h.settle(150);
  final Map<String, dynamic> pre = await h.drive(
    stationParams(
      stationId: kPointRelayToolPre,
      kind: 'relay',
      requestId: 'relay-pre-1',
      payload: <String, dynamic>{
        'phase': 'pre',
        'tool': 'read',
        'arguments': <String, dynamic>{'file_path': 'a.txt'},
      },
    ),
  );
  final Map<String, dynamic> prePayload = asMap(_Harness.replyPayload(pre));
  check.check(
    asMap(prePayload['arguments'])['_relay_seen'],
    1,
    'pre 只加一个标记键（不动业务参数）：_relay_seen = 第 1 次',
  );
  check.check(
    asMap(prePayload['arguments'])['file_path'],
    'a.txt',
    '原参数必须原样带回去（改写了就不是“没改”了）',
  );
  check.check(prePayload['tool'], 'read', 'payload 其它字段得原样透回（不能只回改过的那几个）');
  final Map<String, dynamic> post = await h.drive(
    stationParams(
      stationId: kPointRelayToolPost,
      kind: 'relay',
      requestId: 'relay-post-1',
      payload: <String, dynamic>{
        'phase': 'post',
        'tool': 'read',
        'result': 'A 的内容',
        'is_error': false,
      },
    ),
  );
  final String postResult = asString(
    asMap(_Harness.replyPayload(post))['result'],
  );
  check.that(
    postResult.startsWith('A 的内容'),
    'post 得把原结果留在头部（追加不能变成覆盖）',
    actual: _clip(postResult, 80),
  );
  check.that(
    postResult.contains('已经过中转（第 2 次）'),
    'post 的附言要能数得出次数',
    actual: _clip(postResult, 120),
  );
  check.check(h.plugin.relayHandled, 2, 'pre / post 各算一次中转处理');
  // 未知 phase：显式放行（回 payload:null = 不改，与“出错”两回事）。
  final Map<String, dynamic> odd = await h.drive(
    stationParams(
      stationId: kPointRelayToolPre,
      kind: 'relay',
      requestId: 'relay-odd-1',
      payload: <String, dynamic>{'phase': 'middle', 'tool': 'read'},
    ),
  );
  check.check(
    _Harness.replyPayload(odd),
    null,
    '看不懂的 phase 就什么都不改（回 null 放行原数据）',
  );
  check.check(h.plugin.relayHandled, 3, '看不懂的请求也进了处理次数（核心等的是回包，不是内容）');
  // payload 不是对象：要回可读错误，不能静默放行。
  final Map<String, dynamic> bad = await h.drive(<String, dynamic>{
    'request_id': 'relay-bad-payload',
    'station_id': kPointRelayToolPre,
    'kind': 'relay',
    'scope': <String, dynamic>{'team_id': 'team-1'},
    'payload': '这不是对象',
  });
  check.that(
    asString(asMap(bad['reply'])['error']).contains('payload 必须是对象'),
    'payload 形态不对时要说出原因（而不是当“不改动”混过去）',
    actual: rendered(bad),
  );
  logs.addAll(h.core.logs);
  await h.close();
}

/// ⑮ 插件布局：三个槽位都得申报，而 card 那一个不申报就永远出不来。
Future<void> _checkPanelSlots(SelfTest check, List<String> logs) async {
  final Options options = selfOptions(<String>[
    '--no-fs-demo',
    '--card-interval',
    '0',
    '--threshold',
    '2',
  ]);
  // 节流拉到一小时：本用例要断言“事件密集时只推一次”，等不了真节流窗。
  options.cardMinInterval = 3600;
  final _Harness h = _Harness(options);
  await h.hello();
  check.that(
    h.mark(Ui.manifest) >= 1,
    'hello 之后必须发一帧 ui/manifest（槽位只在这里申报）',
    actual: h.tail(),
  );
  final List<Object?> slots = h.manifestSlots();
  check.check(
    slots.map((Object? s) => asString(asMap(s)['slot'])).toList(),
    <String>['activity', 'panel', 'card'],
    '三个槽位齐报：活动栏 + 右栏 Tab + 消息流卡片（card 不报就永远出不来）',
  );
  for (final Object? slot in slots) {
    final Map<String, dynamic> item = asMap(slot);
    final String key = asString(item['slot_key']);
    check.that(
      key.isNotEmpty,
      '每个槽位都要有 slot_key',
      actual: rendered(item.keys.toList()),
    );
    check.that(
      !key.contains('..'),
      'slot_key 不能拼出空段（插件 id 没到位时会拼成 ..activity.1）',
      actual: key,
    );
    check.check(validateUiView(item['view']), <String>[], '申报视图必须合受限控件集（$key）');
    check.that(
      json.encode(item).length <= kMaxSlotBytes,
      '单槽位声明不得超上限（超了整份 manifest 会被拒）',
      actual: '${json.encode(item).length} 字节',
    );
    // plugin_id / team_id 由核心填：插件自述的那两个字段不会被采信。
    check.that(
      !item.containsKey('plugin_id') && !item.containsKey('team_id'),
      '申报里不该自带 plugin_id / team_id（防越权：核心按实例与 plugins.yaml 填）',
      actual: rendered(item.keys.toList()),
    );
  }
  final Map<String, dynamic> card = asMap(
    slots.firstWhere((Object? s) => asMap(s)['slot'] == 'card'),
  );
  check.check(
    card['slot_key'],
    h.plugin.options.slotKey,
    'card 槽位用的就是 --slot-key',
  );
  final Map<String, dynamic> activity = asMap(slots.first);
  check.check(
    activity['slot_key'],
    'sample.activity.1',
    '活动栏槽位用核心认定的那个插件 id 拼',
  );
  check.check(activity['icon'], 'extension', '活动栏图标（受限集里只给图标名）');
  // 卡片真的推出去了（ui.push 只更新、不建槽位）。
  final Map<String, dynamic>? push = await h.waitCommand(kCommandUiPush);
  check.that(push != null, '启动就得推一张卡片（面板与卡片同源，不能等事件才亮）', actual: h.tail());
  if (push != null) {
    check.check(
      frameArguments(push)['slot_key'],
      h.plugin.options.slotKey,
      '推的就是申报过的那个 slot_key',
    );
    check.check(
      validateUiView(asMap(frameArguments(push))['view']),
      <String>[],
      '卡片视图也得合受限控件集',
    );
    check.that(
      push['agent_id'] == null,
      '还没见过事件 ⇒ 卡片命令不带身份（空值不写，而不是写一个空 agent_id）',
      actual: rendered(push.keys.toList()),
    );
  }
  check.that(h.hasLog('卡片已推送'), '推送成功得留日志（失败时那行可读原因才有得对比）', actual: h.tail());
  // 节流：事件密集时一小时只推那一张（手动按钮才 force）。
  final int pushes = h.commands(kCommandUiPush).length;
  h.core.notify(
    M.event,
    toolCallEvent(
      agentId: 'agt_x',
      sessionId: 'ses_x',
      callId: 'c1',
      phase: kPhaseStart,
    ),
  );
  await h.settle(400);
  check.that(
    h.commands(kCommandUiPush).length == pushes,
    '未超节流窗就不该再推（事件一来就推一帧会把前端刷屏）',
    actual: '${h.commands(kCommandUiPush).length - pushes} 帧新增',
  );
  // 面板按钮（push_card）走 force：必须真推。
  h.core.notify(M.event, <String, dynamic>{
    'event': kEventUiAction,
    'action_id': 'push_card',
    'slot_key': 'sample.activity.1',
    'payload': <String, dynamic>{},
  });
  check.that(
    await h.waitCommand(kCommandUiPush, atLeast: pushes + 1) != null,
    '手动“推一张卡片”必须绕过节流',
    actual: '${h.commands(kCommandUiPush).length} 条',
  );
  check.that(
    h.plugin.counts['agt_x|ses_x'] == 1,
    '卡片推了就得真数到那次调用（推送与计数不能两张皮）',
    actual: rendered(h.plugin.counts),
  );
  logs.addAll(h.core.logs);
  await h.close();
}

/// ⑯ 自建站演示：id 由核心拼，插件只给 kind + name；readme 必填。
Future<void> _checkSelfStation(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(
    selfOptions(<String>[
      '--no-fs-demo',
      '--no-panel',
      '--no-relay',
      '--card-interval',
      '0',
      '--self-station',
    ]),
  );
  await h.hello();
  check.that(
    await h.waitLog('已自建站点：plugin.sample.broadcast.team_fanout'),
    '自建站回包的 station_id 必须是核心拼的那一个（插件不能自选 id）',
    actual: h.tail(),
  );
  check.check(h.registers.length, 1, '一次开工只建一次站');
  if (h.registers.isNotEmpty) {
    final Map<String, dynamic> params = h.registers.first;
    check.check(params['kind'], 'broadcast', '建站得给类型');
    check.check(params['name'], 'team_fanout', '建站得给名字（id 由核心拿它拼）');
    check.that(
      asString(params['readme']).isNotEmpty,
      'readme 必填：站是插件建的，只有它说清得干什么',
      actual: rendered(params.keys.toList()),
    );
    check.that(
      asString(params['readme']).contains('station/trigger'),
      'readme 得告诉别人“什么时候被触发、该怎么回”',
      actual: _clip(asString(params['readme']), 80),
    );
    check.check(params['shared'], false, '默认不共享（共享得显式开）');
  }
  // 建完就订阅自己（按实例 id 寻址，不再带 station 类型）。
  final Map<String, dynamic>? own = h.subscribeFor(
    (Map<String, dynamic> params) =>
        asString(params['station_id']) == 'plugin.sample.broadcast.team_fanout',
  );
  check.that(
    own != null,
    '建完站必须订阅它（否则下游没有回包通道与等待链）',
    actual: rendered(h.subscribes()),
  );
  if (own != null) {
    check.that(
      own['station'] == null,
      '按实例 id 订时不再带 station 类型（两种寻址互斥）',
      actual: rendered(own.keys.toList()),
    );
  }
  logs.addAll(h.core.logs);
  await h.close();
}

/// ⑰ 参数面：优先级、报错退 2、--help 走 stderr，以及两个静态文本解析。
Future<void> _checkUsageTextAndOptions(
  SelfTest check,
  List<String> logs,
) async {
  final Parsed shortTool = parseOptions(<String>[
    '--tool-call',
    'read',
  ], env: const <String, String>{});
  check.check(shortTool.code, 2, '--tool-call 少一个取值 = 用法错（退 2，不是默默跳过）');
  check.that(
    shortTool.message.contains('需要两个取值'),
    '报错得说出缺了什么',
    actual: shortTool.message,
  );
  final Parsed unknown = parseOptions(<String>[
    '--nope',
  ], env: const <String, String>{});
  check.check(unknown.code, 2, '未知参数退 2');
  check.that(
    unknown.message.contains('未知参数'),
    '未知参数得在报错里点名',
    actual: unknown.message,
  );
  final Parsed badNumber = parseOptions(<String>[
    '--threshold',
    'abc',
  ], env: const <String, String>{});
  check.check(badNumber.code, 2, '数字写坏 = 参数不对（不是插件自己崩了）');
  check.that(
    badNumber.message.contains('需要整数'),
    '坏数字的可读原因得说出要整数',
    actual: badNumber.message,
  );
  final Parsed badJson = parseOptions(<String>[
    '--tool-call',
    'read',
    '[1,2]',
  ], env: const <String, String>{});
  check.check(badJson.code, 2, 'arguments 不是对象 = 用法错');
  check.that(
    badJson.message.contains('JSON **对象**'),
    '坏 JSON 的可读原因得给出正确写法',
    actual: badJson.message,
  );
  final Parsed help = parseOptions(<String>[
    '-h',
  ], env: const <String, String>{});
  check.that(help.help && help.code == 0, '-h 只要用法、不算错误');
  for (final String needle in <String>[
    '--relay-llm',
    '--watch-tools',
    '--self-station',
    'stdout 是协议通道',
  ]) {
    check.that(
      help.message.contains(needle),
      '用法里得看得到 $needle（新开关忘了写进来，就等于没有这个开关）',
    );
  }
  final Parsed fromEnv = parseOptions(
    <String>[],
    env: const <String, String>{
      kEnvThreshold: '7',
      kEnvCascade: 'TRUE',
      kEnvToolCallArgs: '{"a":1}',
      kEnvSlotKey: 'x.y',
      kEnvRelayLlm: '接管它',
    },
  );
  check.check(fromEnv.options.threshold, 7, '环境变量能拉到阈值');
  check.check(fromEnv.options.cascade, true, '真值写法大小写都认');
  check.check(fromEnv.options.toolCallArgs, <String, dynamic>{
    'a': 1,
  }, 'arguments 的环境变量同样只收对象');
  check.check(fromEnv.options.slotKey, 'x.y', '槽位键能从环境来');
  check.check(fromEnv.options.relayLlm, '接管它', '关键词能从环境来');
  final Parsed overridden = parseOptions(
    <String>['--threshold', '9'],
    env: const <String, String>{kEnvThreshold: '7'},
  );
  check.check(overridden.options.threshold, 9, '命令行 > 环境变量 > 默认值');
  final Parsed envBad = parseOptions(
    <String>[],
    env: const <String, String>{kEnvThreshold: 'many'},
  );
  check.check(envBad.code, 2, '环境变量写坏也是用法错（不能默默回到默认）');
  // 默认值：新协议的那七个开关全关（既有默认行为一个字不能变）。
  final Options fresh = Options();
  check.check(fresh.relayLlm, '', '默认不订 llm.handle');
  check.check(fresh.relayPrompt, false, '默认不改写提示词');
  check.check(fresh.watchTools, false, '默认不订工具广播');
  check.check(fresh.selfStation, false, '默认不自建站');
  check.check(fresh.threshold, kDefaultThreshold, '默认阈值 200（Q8 的参考值）');
  check.check(fresh.slotKey, kDefaultSlotKey, '默认卡片槽位');
  check.check(fresh.relay, true, '中转站默认就订（那是本插件的主线）');
  // 最后一条 user 消息（两种 content 形状）：接管判据只看它。
  check.check(
    SamplePlugin.lastUserText(<Map<String, dynamic>>[
      <String, dynamic>{'role': 'user', 'content': '第一问'},
      <String, dynamic>{'role': 'assistant', 'content': '答一'},
      <String, dynamic>{
        'role': 'user',
        'content': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': '第二问'},
          <String, dynamic>{'type': 'text', 'text': '再补一句'},
        ],
      },
    ]),
    '第二问\n再补一句',
    'content 是分片数组时按行拼回（只看字符串形式会漏接管）',
  );
  check.check(
    SamplePlugin.lastUserText(<Map<String, dynamic>>[
      <String, dynamic>{'role': 'system', 'content': '只是 system'},
    ]),
    '',
    '没有 user 消息就是空串（不能拿 system 正文去匹关键词）',
  );
  check.check(
    SamplePlugin.messageText(<String, dynamic>{
      'content': <Object?>[
        '不是文本片',
        <String, dynamic>{'type': 'text', 'text': '算'},
      ],
    }),
    '算',
    '分片里混进非文本项时只拿文本（不能把对象 toString 塞进提示词）',
  );
}
