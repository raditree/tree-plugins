// **内置插件：compact（上下文压缩，Dart）**——把长会话压成"摘要 + 必读文件 + 待办"。
//
// 订阅中转点位 `system.relay.context.compact`，做**全权压缩**：核心把"引擎这一轮真会
// 发的那份请求"（`payload.request`，线形态 `{model, messages, tools, …}`）交给插件，
// 插件回一份新的上下文与覆盖条数。
//
// **原料只有一样：`request.messages`。** 落库全量原文**不再下发**——那份东西既大
// （动辄几 MB）又与"模型真正看到的那份"不同步（冷前缀早已被摘要/列表代表）。
//
// 产出结构（回包 `payload.messages`；引擎只把首条 system 槽位刷成最新提示词）：
//
//     [0]      system  提示词槽位（内容由核心每轮覆盖，插件放快照即可）
//     [1]      system  摘要：背景 / 轨迹 / 改动产出文件
//     [2]      assistant(reasoning_content=固定文案, tool_calls=[read…, set_todo_list])
//     [3..]    tool    一一对应的读取结果（必读文件 + todo 快照）
//     [N..]    …       尾部原文**原样抄自 `request.messages[cut:]`**
//     covered_message_count = total_message_count（尾部已抄进列表，核心不再追加）
//
// **缓存**（长会话省钱的关键）：总结调用把 `request.messages[:cut]` 整段当 messages，
// 末尾只追加一条 **user 指令**——前缀与对话那一轮逐字一致，端点侧已持久化的缓存单元
// 就能整段命中。**三条一起成立才行**（少一条就整段不命中，2026-10-04 真机实测）：
//
// 1. `request.tools` 原样透传（工具定义在聊天模板里渲染在 messages **之前**）；
// 2. **不用** `llm.call` 的 `system` 参数（那会在最前面插一条 system，整体错位）；
// 3. **`response_format` 显式传 `"text"`**：`llm.call` 缺省会硬设 `{"type":"json_object"}`，
//    而实测**端点为 JSON 模式改写了提示词**（同一批 messages 恒定 +22 token）⇒ 前缀整段
//    丢缓存。改走 text 后格式由指令约束；偶发非法 JSON ⇒ 下面的"抢救"三段接住。
//
// 切点（`cut`）在 **wire 坐标**里决定，三条规则：
// 1. 保留最近 `--keep-rounds` 轮 user 及其之后；
// 2. 该区域的工具轮（assistant+tool_calls）超过 `--keep-tool-rounds`（默认 8）时只留最后
//    那么多轮——单轮超长工具轨迹因此**压得动**；
// 3. 切点**不得落在 `tool` 消息上**（否则尾部以孤儿工具结果开头，端点直接 400）。
//
// 失败一律回 `null`（不接管）⇒ 核心回退内置压缩，上下文不会丢；**不接管必须带上原因**
// （回包可选键 `reason`），否则"插件白跑一次、核心悄悄兜底"事后无从诊断。
//
// 左栏面板（`activity` 槽位）：最近 N 次压缩的时间 / 来源 / 覆盖条数 / 耗时 / 降级与
// 未接管原因，外加「立即压缩一次」（执行站 `agent.compact`，与 REST `/compact` 同一入口）。
// 用量行来自核心在载荷里捎的 `recent_usage`（插件读不到数据根），按整行内容去重并入。
//
// 跑起来（**不需要真核心**）：
//     dart run plugins/compact/compact_plugin.dart --selftest
// 编译：`dart run tool/build_plugins.dart --only compact`
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../_kit/plugin_kit.dart';

const String kPluginId = 'compact';
const String kPanelTitle = '上下文压缩';

/// 中转点位（唯一订阅者）：站点已全局化，投过来的 `station_id` 就是它本身。
const String kPointContextCompact = 'system.relay.context.compact';
const String kPointContextCompactAlias = 'context.compact';

/// 面板按钮回调的事件名（判据在 `params.event`，**不是** `params.method`）。
const String kEventUiAction = 'plugin_ui_action';

/// 执行站命令（`station/command` 的命令名，不是 method）。
const String kCommandLlmCall = 'llm.call';
const String kCommandFsRead = 'fs.read';
const String kCommandToolCall = 'tool.call';
const String kCommandAgentCompact = 'agent.compact';

/// 活动栏图标名走前端白名单（未知名回退扩展图标，见 `plugin_ui_slots.dart`）。
const String kPanelIcon = 'chart';

/// 面板列（顺序即展示顺序；面板与自检共用这一份，防止两边漂）。
const List<String> kPanelColumns = <String>[
  '时间',
  '来源',
  '覆盖条数',
  '耗时',
  '降级 / 未接管原因',
];

/// 内部最多留多少条自己的压缩记录 / 用量记录（面板只显示 `panelRecords` 条）。
const int kMaxOwnRecords = 100;
const int kMaxUsageRecords = 200;

/// `ui/manifest` 的整帧字节上限（核心侧同值：超了**整帧被拒**，所以自检要盯着它）。
const int kMaxManifestBytes = 64 * 1024;

/// `usage.jsonl` 的 `source` → 面板"来源"列（照核心 `UsageSource` 的口径）。
/// `turn` 故意不在表里：那是对话自己的跳，不属于这个面板（会被跳过）。
const Map<String, String> kUsageSourceLabels = <String, String>{
  'compact': 'builtin', // 内置压缩（核心 LlmSummarizer 的那次总结）
  'llm.call': 'llm.call', // 压缩插件自己的总结调用走的就是它
  'plugin': 'plugin', // llm.handle 被整体接管的一跳
};

/// 固定的"伪推理"文案（Q6 定稿）：让这条伪造的 assistant 在带 tools 的思考模式端点上
/// 满足"历史 assistant 必须带 reasoning_content"的口径。
const String kReasoningText = '上下文压缩后，我先 read 相关文件，获取 todo 列表';

/// 追加在缓存前缀之后的总结指令（最后一条 user 消息）。
///
/// 四个硬要求：①输出形状写死在指令里（**不**靠 `response_format` 强约束——那会让端点
/// 改写提示词、前缀缓存全丢）；②"只输出一个 json 对象、不要代码块/解释"；③**完整优先，
/// 不要求少写**（这份摘要是后续唯一的背景来源）；④键必须齐全。
///
/// `@@MAX_FILES@@` 由 [CompactPlugin.summaryInstruction] 换成实际值。
/// 这里是 **raw 串**：Python 那份写在 `"""…"""` 里，正文中那个 `` `\n` `` 被转成了真换行
/// （模型看到的是一句断掉的话）；Dart 保住字面 `\n`，这是指令文本的一处**真实变化**，
/// 变更点在 examples/plugins 的迁移说明与 CHANGELOG 里都如实写了。
const String kSummaryInstruction = r'''以上是本次任务到目前为止的完整上下文。请把它压成"继续这个任务所必需"的要点；**力求完整**（宁可写详细，也不要把还在生效的约束、结论、失败尝试丢掉）。

**输出契约（违反即本次压缩作废，请严格照做）**：
1. **只输出一个 json 对象**：第一个字符就是 `{`，最后一个字符就是 `}`；
2. **不要** markdown 代码块（不要 ``` ），**不要**任何解释或前后缀文字；
3. 下面这**四个键全部都要出现**，结构照抄（没有内容就给 `""` 或 `[]`，不要省略键）：

{
  "background": "任务背景与目标、用户的关键约束（尽量完整）",
  "trajectory": "已经做过什么、结论是什么、哪些尝试失败或已被推翻（力求完整、够继续任务）",
  "files_changed": [{"path": "工作空间相对路径", "change": "新增/修改/删除 + 一句话"}],
  "required_files": [{"path": "工作空间相对路径", "start_line": 1, "line_count": 80,
                      "why": "为什么后续必须读它"}]
}

规则：
- **字符串里不要出现裸换行**（要换行就写 `\n`），引号要转义，**不要尾逗号、不要注释**；
- 内容写多没问题，**但一个字都不要落在 json 之外**：写长的代价只是 token，
  写坏（夹解释 / 半截 json / 少引号）的代价是整次压缩作废；
- 路径只允许**工作空间相对路径**（如 `lib/a.dart`、`docs/x.md`），不要绝对路径、不要 `..`；
- `required_files` 不超过 @@MAX_FILES@@ 个，按重要性排序，**精确到行范围**（只给真正要读的那段）；
  优先列：核心文档 / 计划文档（`.self/plan/**`）/ 正在编辑或与任务直接相关的模块；
  不要列目录、不要列日志、不要列你已完整读过且结论已写进 trajectory 的文件；
- `files_changed` 只列**改动或产出的文件**（不是读过的文件）；
- 拿不准的字段宁可留空，**不要编造路径**。
''';

/// 「抢救」契约：**只在总结回包解析失败时**用，最多一次。
///
/// 为什么值得花这第二笔小钱：总结调用是一次**复用对话前缀**的付费调用（现场 734k
/// prompt、≈100% 命中缓存）；它成功返回、只是正文不是合法 json 时，整笔投入都会丢。
/// 而这一步的输入**只有那段原文**（几千 token），便宜三个数量级。
///
/// 三点口径：①"原文是否被截断"由模型判，不由插件猜（也不做本地补全）；②这一次**不发**
/// `response_format`（站点缺省硬设 `json_object`，正好强制 JSON）；③**不设 `max_tokens`**。
const String kRepairInstruction = r'''下面是一次模型调用的**原始输出**：它本应是一个 json 对象，但解析失败了。请只做两件事，且只输出一个 json 对象（不要解释、不要 markdown 代码块）：

1. 判断原文是否**完整**：被截断 / 缺尾部 / 字符串断在半截 ⇒ `complete` 给 false；
   原文完整、只是夹了解释 / 有尾逗号 / 引号没转义这类纯语法问题 ⇒ `complete` 给 true；
2. 把原文修成**严格合法**的 json 放进 `summary`，结构照：
   {"background": 字符串, "trajectory": 字符串, "files_changed": 数组, "required_files": 数组}
   **只允许**使用原文里确实出现过的信息；原文没有的键给 `""` / `[]`，**绝不编造**路径或结论；
   **不要为了短而删要点**：原文写下的信息尽量原样保留（改写可以、省略不行）；
   若原文被截断，就按已有内容补齐缺的键，并在 `reason` 里写明截断位置。

输出形状（三个键都要有）：
{"complete": true, "reason": "", "summary": {"background": "", "trajectory": "", "files_changed": [], "required_files": []}}

以下是原始输出（原样，未做任何处理）：
-----
''';

/// 命令行选项（全部有默认值；内置插件面板启用时不传任何参数）。
class Options {
  int keepRounds = 1;
  int keepToolRounds = 8;
  int maxFiles = 11;
  int maxLinesPerFile = 400;
  int maxCharsTotal = 60000;

  /// 插件自己的观测窗口（秒）：一条命令等这么久没回包就**如实记下**"没回包"。
  double commandTimeoutSeconds = 180.0;
  String reasoningText = kReasoningText;
  bool dryRun = false;
  bool noPanel = false;
  int panelRecords = 10;

  /// 「立即压缩一次」在动作帧没带 `agent_id` 时的兜底目标（空 = 不猜）。
  String agentId = '';

  /// 逐调用用量的**离线回放**路径（开发期把一份账本喂给面板看；正路是载荷里的
  /// `recent_usage`，插件自己读不到数据根）。
  String usageJsonl = '';

  static Options parse(List<String> argv) {
    final Options options = Options();
    for (int i = 0; i < argv.length; i++) {
      final String name = argv[i];
      final String value = i + 1 < argv.length ? argv[i + 1] : '';
      void take(int Function(String) apply) {
        apply(value);
        i++;
      }

      switch (name) {
        case '--keep-rounds':
          take((String v) => options.keepRounds = _positiveInt(v, options.keepRounds));
        case '--keep-tool-rounds':
          take(
            (String v) =>
                options.keepToolRounds = _positiveInt(v, options.keepToolRounds),
          );
        case '--max-files':
          take((String v) => options.maxFiles = _positiveInt(v, options.maxFiles));
        case '--max-lines-per-file':
          take(
            (String v) => options.maxLinesPerFile = _positiveInt(
              v,
              options.maxLinesPerFile,
            ),
          );
        case '--max-chars-total':
          take(
            (String v) =>
                options.maxCharsTotal = _positiveInt(v, options.maxCharsTotal),
          );
        case '--command-timeout':
          take((String v) {
            final double? parsed = double.tryParse(v.trim());
            if (parsed != null) options.commandTimeoutSeconds = parsed;
            return 0;
          });
        case '--reasoning-text':
          take((String v) {
            options.reasoningText = v;
            return 0;
          });
        case '--panel-records':
          take((String v) => options.panelRecords = _positiveInt(v, options.panelRecords));
        case '--agent-id':
          take((String v) {
            options.agentId = v.trim();
            return 0;
          });
        case '--usage-jsonl':
          take((String v) {
            options.usageJsonl = v.trim();
            return 0;
          });
        case '--dry-run':
          options.dryRun = true;
        case '--no-panel':
          options.noPanel = true;
      }
    }
    return options;
  }
}

int _positiveInt(String raw, int fallback) {
  final int? value = int.tryParse(raw.trim());
  if (value == null || value <= 0) return fallback;
  return value;
}

int _nonNegativeInt(Object? raw) {
  if (raw is int) return raw > 0 ? raw : 0;
  if (raw is double) return raw > 0 ? raw.round() : 0;
  final int? parsed = int.tryParse('${raw ?? ''}'.trim());
  return parsed == null || parsed < 0 ? 0 : parsed;
}

String _clip(String text, int limit) =>
    limit <= 0 || text.length <= limit ? text : text.substring(0, limit);

/// 耗时的人话（面板单元格）。
String _durationText(int? milliseconds) {
  if (milliseconds == null) return '—';
  if (milliseconds < 1000) return '$milliseconds ms';
  return '${(milliseconds / 1000).toStringAsFixed(1)} s';
}

/// token 数的人话：>= 1000 用 k（面板列窄，别铺一串数字）。
String _tokenText(Object? value) {
  final int number = _nonNegativeInt(value);
  if (number >= 1000) return '${(number / 1000).toStringAsFixed(1)}k';
  return '$number';
}

/// `usage.jsonl` 的 `at` → epoch 秒；认不出返回 0。
///
/// 容忍三种写法（都来自"用户手改文件"这一既有前提）：ISO 字符串（正路，核心的
/// `JsonTime.encode` 写的是无偏移的本机时区串）、epoch 秒、epoch 毫秒。
double _epochOf(Object? raw) {
  if (raw is bool) return 0; // bool 是 int 的子类（Python 同一条坑），先挡掉
  if (raw is num) {
    final double value = raw.toDouble();
    return value > 100000000000 ? value / 1000.0 : value;
  }
  final String text = asString(raw);
  if (text.isEmpty) return 0;
  try {
    return DateTime.parse(text).millisecondsSinceEpoch / 1000.0;
  } catch (_) {
    return 0;
  }
}

/// 一条 canonical JSON（键排序）：用作用量行的**去重键**。
///
/// 为什么必须去重：`recent_usage` 是滚动窗口，每次压缩请求核心都带最近 N 行，同一行会
/// 被反复送来；不去重几轮之后面板就被同一批记录刷屏。手改过的一行自然算新行。
String canonicalJson(Object? value) {
  if (value is Map) {
    final List<String> keys = value.keys.map((Object? k) => '$k').toList()..sort();
    final buffer = StringBuffer('{');
    for (int i = 0; i < keys.length; i++) {
      if (i > 0) buffer.write(',');
      buffer
        ..write(json.encode(keys[i]))
        ..write(':')
        ..write(canonicalJson(value[keys[i]]));
    }
    return '$buffer}';
  }
  if (value is List) {
    return '[${value.map(canonicalJson).join(',')}]';
  }
  return json.encode(value is String ? value : '$value');
}

/// wire 形态的小工具（只认 `LlmMessage` 的线形状）。
String roleOf(Object? message) => asString(asMap(message)['role']);
bool hasToolCalls(Object? message) {
  final Object? calls = asMap(message)['tool_calls'];
  return calls is List && calls.isNotEmpty;
}
bool isTool(Object? message) => roleOf(message) == 'tool';
bool isUser(Object? message) => roleOf(message) == 'user';

/// 压缩插件本体：所有对外动作都走执行站命令（自检跑的是**真帧面**）。
class CompactPlugin {
  CompactPlugin({required this.channel, required this.options});

  final PluginChannel channel;
  final Options options;
  String pluginId = kPluginId;

  final Map<String, int> counters = <String, int>{
    'requests': 0,
    'taken': 0,
    'declined': 0,
    'salvaged': 0,
    'repaired': 0,
  };

  // ── 面板状态 ────────────────────────────────────────────────────────
  bool get panelEnabled => !options.noPanel;
  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);
  String get slotKey => '$pluginId.activity.1';
  final Map<String, Object?> status = <String, Object?>{
    'subscribed': false,
    'detail': '等待核心握手',
  };
  late final Map<String, String> identity = <String, String>{
    'agent_id': options.agentId,
    'session_id': '',
  };
  List<int>? watermark; // 核心报的水位线：(已覆盖条数, 原文总条数)
  final List<Map<String, Object?>> records = <Map<String, Object?>>[];
  final Map<String, Map<String, Object?>> usageRecords =
      <String, Map<String, Object?>>{};
  String usageFile = '';
  String lastDeclineReason = '';

  /// `hello` 之后：先申报面板（这时 `plugin_id` 才是实例 id），再后台重试订阅。
  Future<void> startup() async {
    declarePanel();
    unawaited(subscribeLoop());
  }

  // ── 命令通路 ─────────────────────────────────────────────────────────

  /// 经执行站下一条命令，并交出**与核心同形状**的结论：`{ok, payload, error, ms}`。
  ///
  /// [scope] 是这一次命令的身份：核心按目标 agent 的**真实归属**解析 team / mode，
  /// `plugins.yaml` 的 scope 只是上限——所以 `scope: {}` 的内置开关形态照样能用。
  Future<Map<String, Object?>> exec(
    String command,
    Map<String, dynamic> arguments,
    Map<String, dynamic> scope,
  ) async {
    final DateTime began = DateTime.now();
    try {
      final Map<String, dynamic> payload = await channel
          .command(command, arguments, '', scope)
          .timeout(
            Duration(milliseconds: (options.commandTimeoutSeconds * 1000).round()),
          );
      return <String, Object?>{
        'ok': true,
        'payload': payload,
        'error': '',
        'ms': DateTime.now().difference(began).inMilliseconds,
      };
    } on TimeoutException {
      return _failed(
        command,
        '等待核心对 $command 的回包超时（${options.commandTimeoutSeconds.toInt()} s）',
        began,
      );
    } on CmdFailureException catch (error) {
      // **失败也带着 payload**：核心的 `llm.call` 在失败时把原文放在那里（known-issues #31），
      // 接不住就等于把已经付费的那次总结扔掉——下面的“抢救三段”就没东西可救。
      return _failed(command, error.message, began, payload: error.payload);
    } catch (error) {
      return _failed(command, '$error', began);
    }
  }

  Map<String, Object?> _failed(
    String command,
    String error,
    DateTime began, {
    Map<String, Object?> payload = const <String, Object?>{},
  }) =>
      <String, Object?>{
        'ok': false,
        'payload': payload,
        'error': error,
        'command': command,
        'ms': DateTime.now().difference(began).inMilliseconds,
      };

  /// 订阅压缩点位（`replace: false`：**绝不抢占别人的订阅**）。
  Future<Map<String, Object?>> subscribeCompactPoint() async {
    try {
      final Map<String, dynamic> result = await channel.request(
        M.stationSubscribe,
        <String, dynamic>{
          'station': 'relay',
          'point': kPointContextCompactAlias,
          'replace': false,
        },
      );
      if (result['ok'] == false) {
        return <String, Object?>{
          'ok': false,
          'error': asString(result['error']).isEmpty ? '被拒' : asString(result['error']),
        };
      }
      return <String, Object?>{'ok': true, 'payload': result};
    } catch (error) {
      return <String, Object?>{'ok': false, 'error': '$error'};
    }
  }

  /// 握手后订阅；失败就有限重试（核心可能还没把站点挂好）。
  ///
  /// 订阅结果**如实投到面板上**：没订上就等于这个插件永远不会被叫到，"为什么没接管"
  /// 的答案就在这一行里（最常见的是已有别的插件占着这个点位）。
  Future<void> subscribeLoop() async {
    String lastError = '';
    setStatus(false, '正在订阅 $kPointContextCompact…');
    for (int attempt = 1; attempt <= 5; attempt++) {
      final Map<String, Object?> result = await subscribeCompactPoint();
      if (result['ok'] == true) {
        channel.log('已订阅 $kPointContextCompact（第 $attempt 次尝试）');
        setStatus(true, '已订阅 $kPointContextCompact');
        return;
      }
      lastError = asString(result['error']).isEmpty ? '未知原因' : asString(result['error']);
      channel.log('订阅失败（第 $attempt 次）：$lastError');
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    channel.log(
      '订阅 $kPointContextCompact 连续失败：本插件不会接管压缩'
      '（若已有别的插件占着这个点位，先停用它）',
    );
    setStatus(false, '未订上点位：$kPointContextCompact（最后错误：$lastError）');
  }

  // ── 站点请求 ─────────────────────────────────────────────────────────

  /// 站点 → 插件的请求。只认真实订阅的那个点位，其余一律"不改动"。
  Future<Map<String, dynamic>> handleStationRequest(
    Map<String, dynamic> params,
  ) async {
    if (asString(params['station_id']) != kPointContextCompact) {
      return <String, dynamic>{'reply': <String, dynamic>{'payload': null}};
    }
    final Object? payload = await handleCompact(params);
    final Map<String, dynamic> reply = <String, dynamic>{'payload': payload};
    // **不接管时把"为什么"一起回给核心**（可选键 `reason`，纯增量）：核心把它写进
    // 日志与会话提示（`relay_skip_reason`）。老核心读不到这个键也不受影响。
    if (payload == null && lastDeclineReason.isNotEmpty) {
      reply['reason'] = lastDeclineReason;
    }
    return <String, dynamic>{'reply': reply};
  }

  String get summaryInstruction =>
      kSummaryInstruction.replaceAll('@@MAX_FILES@@', '${options.maxFiles}');

  /// 中转压缩：返回回包 payload（对象）或 null（不接管）。
  Future<Object?> handleCompact(Map<String, dynamic> params) async {
    final DateTime began = DateTime.now();
    counters['requests'] = (counters['requests'] ?? 0) + 1;
    // 每次请求都先把"上次为什么不接管"清掉：给核心的 reason 必须属于**这一次**。
    lastDeclineReason = '';
    final Map<String, dynamic> payload = asMap(params['payload']);
    if (payload.isEmpty) {
      channel.log('压缩请求缺少 payload 对象：不接管');
      return decline('请求缺少 payload 对象', began, code: 'payload_missing');
    }
    final Map<String, dynamic> scope = asMap(params['scope']);
    final String agentId = asString(
      payload['agent_id'].toString().isNotEmpty
          ? payload['agent_id']
          : scope['agent_id'],
    );
    final String sessionId = asString(
      payload['session_id'].toString().isNotEmpty
          ? payload['session_id']
          : scope['session_id'],
    );
    final Map<String, dynamic> ident = <String, dynamic>{
      'agent_id': agentId,
      'session_id': sessionId,
    };
    rememberIdentity(agentId, sessionId);
    // **逐调用用量**：核心在载荷里捎来最近 N 行。放在每一处"不接管"**之前**——
    // 不接管时面板也要能看到"这次为什么没压"和"最近的调用都花了多少"。
    final int addedUsage = ingestRecentUsage(
      payload['recent_usage'],
      path: asString(payload['usage_file']),
      agentId: agentId,
      sessionId: sessionId,
    );
    if (addedUsage > 0) {
      channel.log('已并入 $addedUsage 条用量记录（账本：${usageFile.isEmpty ? '未提供路径' : usageFile}）');
    }
    final String systemPrompt = asString(payload['system_prompt']);
    final int total = _nonNegativeInt(payload['total_message_count']);
    final int frozen = _nonNegativeInt(payload['compacted_message_count']);
    if (total > 0) watermark = <int>[frozen, total];

    final Map<String, dynamic> request = asMap(payload['request']);
    if (request.isEmpty) {
      channel.log('载荷没有 request（引擎口径的线形请求）：不接管');
      return decline(
        '载荷没有 request（引擎口径的线形请求）',
        began,
        agentId: agentId,
        sessionId: sessionId,
        code: 'request_missing',
      );
    }
    final List<Object?> wire = request['messages'] is List
        ? request['messages'] as List<Object?>
        : <Object?>[];
    if (wire.isEmpty) {
      channel.log('request.messages 不是非空数组：不接管');
      return decline(
        'request.messages 不是非空数组',
        began,
        agentId: agentId,
        sessionId: sessionId,
        code: 'messages_empty',
      );
    }
    final List<Object?> tools = request['tools'] is List
        ? request['tools'] as List<Object?>
        : <Object?>[];

    // 切点。**不做"输入超预算就把 cut 往前推"那种自适应**：那只会多留原文、压得更少，
    // 方向是反的；真撞上窗口上限会由端点报错 ⇒ llm.call 失败 ⇒ 这里回 null ⇒ 核心兜底。
    final int cut = wireCut(wire, options.keepRounds);
    if (cut <= 0) {
      channel.log('没有可压的内容（切点 $cut：整段都要保留）：不接管');
      return decline(
        '没有可压的内容（整段都要保留）',
        began,
        agentId: agentId,
        sessionId: sessionId,
        code: 'nothing_to_compact',
      );
    }

    // 总结调用：**前缀 = wire[:cut]**（与对话逐字一致 ⇒ 命中缓存），末尾只追加一条
    // user 指令；tools 原样透传。**不用 system 参数**（会整体错位）。
    final List<Object?> callMessages = <Object?>[
      ...wire.take(cut),
      <String, dynamic>{'role': 'user', 'content': summaryInstruction},
    ];
    final Map<String, Object?> summaryResult = await exec(
      kCommandLlmCall,
      <String, dynamic>{
        'messages': callMessages,
        'agent_id': agentId,
        'session_id': sessionId,
        // **必须 text**：缺省是站点硬设的 json_object，端点会为它改写提示词
        // ⇒ 辛苦对齐的前缀整段丢缓存（真机对照见文件头"缓存"段）。
        'response_format': 'text',
        if (tools.isNotEmpty) 'tools': tools,
      },
      ident,
    );
    // **钱别白花**：这次调用可能已经跑完并付过费，只是正文不是合法 json。
    final Recovery recovery = await recoverSummary(summaryResult, ident);
    if (recovery.parsed == null) {
      final String detail = asString(summaryResult['error']).trim();
      final String where = recovery.origin == 'llm_call_failed'
          ? '总结调用 $kCommandLlmCall 失败：${detail.isEmpty ? '未知原因' : detail}'
          : '总结回包抢救失败：${recovery.origin}';
      channel.log('总结回包不可用（$where）：不接管');
      return decline(
        '$where；原文 ${recovery.raw.length} 字，前 120 字：${_clip(recovery.raw, 120)}',
        began,
        agentId: agentId,
        sessionId: sessionId,
        code: recovery.origin.split(':').first,
      );
    }
    final Map<String, Object?> resultPayload = asMap(summaryResult['payload']);
    final Map<String, dynamic> usage = asMap(resultPayload['usage']);
    channel.log(
      '摘要完成：模型=${asString(resultPayload['model'])} 前缀 $cut 条 '
      'prompt_tokens=${usage['prompt_tokens']} cached_tokens=${usage['cached_tokens']} '
      '来源=${recovery.origin}',
    );
    Map<String, Object?> parsed = recovery.parsed!;
    if (recovery.origin != 'primary') {
      // 抢救回来的摘要**必须显式标注**（它可能不完整）——标记由 [summaryText] 写进
      // 上下文正文，模型与用户都看得见。
      parsed = <String, Object?>{...parsed, '_recovered_from': recovery.origin};
    }

    // 必读文件 + todo：同一条 assistant，多个 tool_calls（**一一对应**）。
    final List<Map<String, Object?>> entries = requiredFiles(parsed);
    final List<Map<String, dynamic>> toolCalls = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> toolResults = <Map<String, dynamic>>[];
    int budget = options.maxCharsTotal;
    for (int index = 0; index < entries.length; index++) {
      final String callId = 'call_read_${index + 1}';
      final Map<String, Object?> entry = entries[index];
      toolCalls.add(readCall(callId, entry));
      final String text = await readResult(entry, ident, budget);
      budget -= text.length;
      toolResults.add(<String, dynamic>{
        'role': 'tool',
        'tool_call_id': callId,
        'content': text,
      });
    }
    const String todoCallId = 'call_todo_1';
    toolCalls.add(<String, dynamic>{
      'id': todoCallId,
      'type': 'function',
      'function': <String, dynamic>{
        'name': 'set_todo_list',
        'arguments': json.encode(<String, dynamic>{'action': 'get'}),
      },
    });
    toolResults.add(<String, dynamic>{
      'role': 'tool',
      'tool_call_id': todoCallId,
      'content': await todoResult(ident),
    });

    final Map<String, dynamic> assistant = <String, dynamic>{
      'role': 'assistant',
      'content': '',
      'tool_calls': toolCalls,
      if (options.reasoningText.isNotEmpty) 'reasoning_content': options.reasoningText,
    };
    final List<Map<String, dynamic>> outMessages = <Map<String, dynamic>>[
      // ① 提示词槽位：内容由核心每轮用最新提示词覆盖（插件放快照即可）
      <String, dynamic>{'role': 'system', 'content': systemPrompt},
      <String, dynamic>{'role': 'system', 'content': summaryText(parsed)},
      assistant,
      ...toolResults,
      // ④ 尾部原文**原样抄回**（助手工作 / 工具卡都在里面，一个字不改写）：这样
      //    covered = 原文总条数，核心不需要按原文下标继续追加。
      ...wire.skip(cut).map((Object? m) => asMap(m)),
    ];

    counters['taken'] = (counters['taken'] ?? 0) + 1;
    channel.log(
      '接管压缩：前缀 $cut/${wire.length} 条（尾部保留 ${wire.length - cut} 条），'
      '必读 ${entries.length} 个文件 + todo，共 ${outMessages.length} 条上下文，'
      '耗时 ${(DateTime.now().difference(began).inMilliseconds / 1000).toStringAsFixed(1)}s',
    );
    if (options.dryRun) {
      channel.log('--dry-run：拼好了但按「不接管」返回（核心会走内置 compact）');
      return decline(
        '--dry-run：拼好了但按不接管返回',
        began,
        agentId: agentId,
        sessionId: sessionId,
        code: 'dry_run',
      );
    }
    final int covered = total > 0 ? total : frozen;
    // 面板记录：**接管成功也要留痕**（来源 relay + 覆盖条数 + 耗时），否则"压了几次、
    // 每次多大"就只能靠翻服务端账单猜。
    record(
      'relay',
      covered: covered,
      durationMs: DateTime.now().difference(began).inMilliseconds,
      agentId: agentId,
      sessionId: sessionId,
    );
    updatePanel();
    return <String, dynamic>{
      'messages': outMessages,
      'covered_message_count': covered,
    };
  }

  /// 不接管：计数 + 记一条面板记录 + 给核心留一份原因（**三处落点**：面板 / 日志 / 回包）。
  Object? decline(
    String reason,
    DateTime began, {
    String agentId = '',
    String sessionId = '',
    String code = '',
  }) {
    counters['declined'] = (counters['declined'] ?? 0) + 1;
    final String text = reason.isEmpty ? '未知原因' : reason;
    lastDeclineReason = code.isEmpty ? text : '[$code] $text';
    record(
      '',
      durationMs: DateTime.now().difference(began).inMilliseconds,
      note: '未接管：$lastDeclineReason',
      agentId: agentId,
      sessionId: sessionId,
    );
    updatePanel();
    return null;
  }

  // ── 总结回包的三段抢救 ───────────────────────────────────────────────

  /// `(parsed | null, 原文, 来源)`：primary（本来就是合法 json）/ salvage（本地修）/
  /// repair（一次小调用）/ 都不行 ⇒ null + 原因串。**总计最多一次额外调用**。
  Future<Recovery> recoverSummary(
    Map<String, Object?> result,
    Map<String, dynamic> ident,
  ) async {
    final Map<String, Object?> payload = asMap(result['payload']);
    final String raw = asString(payload['text']);
    if (payload['json'] is Map) {
      return Recovery(asMap(payload['json']), raw, 'primary');
    }
    if (result['ok'] != true && raw.isEmpty) {
      return Recovery(null, '', 'llm_call_failed');
    }
    final bool truncated = payload['truncated_suspect'] == true;
    channel.log(
      '总结回包不是合法 json（error_kind=${asString(payload['error_kind'])} '
      '正文 ${raw.length} 字${truncated ? '，疑似被截断' : ''}）：开始抢救',
    );
    final Map<String, Object?>? salvaged = salvageJson(raw);
    if (salvaged != null) {
      counters['salvaged'] = (counters['salvaged'] ?? 0) + 1;
      channel.log('本地修复成功（未额外调用模型）');
      return Recovery(salvaged, raw, 'salvage');
    }
    final RepairOutcome repaired = await repairJson(raw, ident);
    if (repaired.summary != null) {
      counters['repaired'] = (counters['repaired'] ?? 0) + 1;
      channel.log(
        '修复调用成功（原文${truncated ? '疑似被截断，已在摘要里标注' : '疑似纯语法问题'}）',
      );
      return Recovery(repaired.summary, raw, 'repair');
    }
    return Recovery(
      null,
      raw,
      repaired.why.isEmpty ? 'repair_failed' : 'repair_failed:${repaired.why}',
    );
  }

  /// **免费**的本地修复：只清结构噪声，**不猜内容、不补字段**。
  ///
  /// 能救回的典型：json 被包进 ``` 代码块 / 前后带一句解释 / 尾逗号 / 零宽字符 / BOM。
  /// 救不回也不硬救——"是不是被截断、要不要补全"交给一次显式的小调用判断。
  static Map<String, Object?>? salvageJson(String raw) {
    if (raw.trim().isEmpty) return null;
    final String cleaned = raw.replaceAll('\uFEFF', '').replaceAll('\u200B', '');
    final List<String> candidates = <String>[];
    final int start = cleaned.indexOf('{');
    final int end = cleaned.lastIndexOf('}');
    if (start >= 0 && end > start) candidates.add(cleaned.substring(start, end + 1));
    candidates.add(cleaned);
    // 尾逗号：`,}` / `,]` 去掉那个逗号。**必须用 replaceAllMapped**——Dart 的
    // `replaceAll(Pattern, String)` **不展开** `$1`（实测把 `$1` 当字面量插回去，
    // 结果是 `…1$1`：看着像修好了，其实把 json 越修越坏）。
    final RegExp trailing = RegExp(r',\s*([}\]])');
    for (final String candidate in candidates) {
      for (final String variant in <String>[
        candidate,
        candidate.replaceAllMapped(trailing, (Match m) => m.group(1) ?? ''),
      ]) {
        try {
          final Object? decoded = json.decode(variant);
          if (decoded is Map) return asMap(decoded);
        } catch (_) {
          continue;
        }
      }
    }
    return null;
  }

  /// **花小钱**的一次"判断完整性 + 修 json"调用（最多一次）。
  ///
  /// 输入只有那段原文；**不发** `response_format`（站点缺省即强制 JSON）、**不带**
  /// `tools`（没有前缀要对齐）、**不设 `max_tokens`**（设小了自己就是下一次截断）。
  Future<RepairOutcome> repairJson(
    String raw,
    Map<String, dynamic> ident,
  ) async {
    final Map<String, Object?> result = await exec(
      kCommandLlmCall,
      <String, dynamic>{
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'user',
            'content': '$kRepairInstruction$raw',
          },
        ],
        'agent_id': asString(ident['agent_id']),
        'session_id': asString(ident['session_id']),
      },
      ident,
    );
    final Map<String, Object?> payload = asMap(result['payload']);
    if (result['ok'] != true && payload.isEmpty) {
      return RepairOutcome(
        null,
        '修复调用失败：${asString(result['error']).isEmpty ? '未知原因' : result['error']}',
      );
    }
    final Map<String, Object?> parsed = asMap(payload['json']);
    if (parsed.isEmpty) return const RepairOutcome(null, '修复调用也没回 json 对象');
    final Map<String, Object?>? summary = parsed['summary'] is Map
        ? asMap(parsed['summary'])
        : null;
    if (summary == null) {
      return const RepairOutcome(null, '修复结果里没有 summary 对象');
    }
    final Object? complete = parsed['complete'];
    if (complete == false || '$complete'.trim().toLowerCase() == 'false') {
      return RepairOutcome(<String, Object?>{
        ...summary,
        '_incomplete_reason': asString(parsed['reason']).isEmpty
            ? '模型判定原文不完整'
            : asString(parsed['reason']),
      }, '');
    }
    return RepairOutcome(summary, '');
  }

  // ── 切点（wire 坐标）─────────────────────────────────────────────────

  /// `messages[:cut]` 进总结，`messages[cut:]` 原样保留。三条规则顺序执行，
  /// 后一条只可能把切点**往后**推。
  int wireCut(List<Object?> messages, int keepRounds) {
    final int length = messages.length;
    int seen = 0;
    int cut = 0;
    for (int index = length - 1; index >= 0; index--) {
      if (!isUser(messages[index])) continue;
      seen++;
      if (seen >= keepRounds) {
        cut = index;
        break;
      }
    }
    final List<int> toolStarts = <int>[
      for (int index = cut; index < length; index++)
        if (hasToolCalls(messages[index])) index,
    ];
    final int limit = options.keepToolRounds;
    if (toolStarts.length > limit) {
      cut = toolStarts[toolStarts.length - limit];
    }
    // 切点不得落在 tool 消息上：尾部以孤儿工具结果开头，端点直接 400。
    while (cut < length && isTool(messages[cut])) {
      cut++;
    }
    return cut;
  }

  // ── 必读文件 / todo ──────────────────────────────────────────────────

  /// 归一 `required_files`：非法项**保留成失败条目**（模型要看得到原因）。
  List<Map<String, Object?>> requiredFiles(Map<String, Object?> parsed) {
    final Object? raw = parsed['required_files'];
    if (raw is! List) return <Map<String, Object?>>[];
    final List<Map<String, Object?>> entries = <Map<String, Object?>>[];
    for (final Object? item in raw) {
      if (entries.length >= options.maxFiles) break;
      entries.add(normalizeFile(item));
    }
    return entries;
  }

  Map<String, Object?> normalizeFile(Object? item) {
    Object? source = item;
    if (source is String) source = <String, dynamic>{'path': source};
    if (source is! Map) {
      return <String, Object?>{
        'path': '',
        'start_line': 0,
        'line_count': 0,
        'why': '',
        'error': '必读条目必须是对象或字符串',
      };
    }
    final Map<String, Object?> entry = asMap(source);
    String path = asString(entry['path']).replaceAll('\\', '/');
    while (path.startsWith('./')) {
      path = path.substring(2);
    }
    final String why = asString(entry['why']);
    String error = '';
    if (path.isEmpty) {
      error = '缺少 path';
    } else if (path.startsWith('/') ||
        (path.length > 1 && path[1] == ':')) {
      error = '只允许工作空间相对路径（拿到的是绝对路径：$path）';
    } else if (path.split('/').contains('..')) {
      error = '路径不能越出工作空间（含 ..）：$path';
    }
    int lineCount = _nonNegativeInt(entry['line_count']);
    if (lineCount > options.maxLinesPerFile) lineCount = options.maxLinesPerFile;
    return <String, Object?>{
      'path': path,
      'start_line': _nonNegativeInt(entry['start_line']),
      'line_count': lineCount,
      'why': why,
      'error': error,
    };
  }

  static Map<String, dynamic> readCall(String callId, Map<String, Object?> entry) {
    final Map<String, dynamic> arguments = <String, dynamic>{
      'path': asString(entry['path']),
      if (_nonNegativeInt(entry['start_line']) > 0)
        'start_line': _nonNegativeInt(entry['start_line']),
      if (_nonNegativeInt(entry['line_count']) > 0)
        'line_count': _nonNegativeInt(entry['line_count']),
    };
    return <String, dynamic>{
      'id': callId,
      'type': 'function',
      'function': <String, dynamic>{
        'name': 'read',
        'arguments': json.encode(arguments),
      },
    };
  }

  /// 读一个必读文件；**失败也返回可读文本**（tool_calls 与结果必须一一对应）。
  Future<String> readResult(
    Map<String, Object?> entry,
    Map<String, dynamic> ident,
    int budget,
  ) async {
    final String path = asString(entry['path']);
    final String why = asString(entry['why']).isEmpty
        ? ''
        : '（${asString(entry['why'])}）';
    if (asString(entry['error']).isNotEmpty) {
      return '读取失败 $path$why：${asString(entry['error'])}';
    }
    final Map<String, Object?> result = await exec(
      kCommandFsRead,
      <String, dynamic>{
        'path': path,
        'agent_id': asString(ident['agent_id']),
        'session_id': asString(ident['session_id']),
        if (_nonNegativeInt(entry['start_line']) > 0)
          'start_line': _nonNegativeInt(entry['start_line']),
        if (_nonNegativeInt(entry['line_count']) > 0)
          'line_count': _nonNegativeInt(entry['line_count']),
      },
      ident,
    );
    if (result['ok'] != true) {
      return '读取失败 $path$why：'
          '${asString(result['error']).isEmpty ? '未知原因' : result['error']}';
    }
    final Map<String, Object?> data = asMap(result['payload']);
    final String content = asString(data['content']);
    final String header =
        '$path$why（共 ${asString(data['total_lines'])} 行，'
        '本次从第 ${asString(data['start_line'])} 行起）';
    final int allow = budget - header.length - 8;
    final String body = allow > 0
        ? _clip(content, allow)
        : '…（本次必读总量已达上限，未读取）';
    return '$header\n$body';
  }

  /// 待办快照：`tool.call` 调真实的 `set_todo_list get`（真数据、真工具）。
  Future<String> todoResult(Map<String, dynamic> ident) async {
    final Map<String, Object?> result = await exec(
      kCommandToolCall,
      <String, dynamic>{
        'tool': 'set_todo_list',
        'arguments': <String, dynamic>{'action': 'get'},
        'agent_id': asString(ident['agent_id']),
        'session_id': asString(ident['session_id']),
      },
      ident,
    );
    if (result['ok'] != true) {
      return '待办读取失败：'
          '${asString(result['error']).isEmpty ? '未知原因' : result['error']}';
    }
    final Map<String, Object?> data = asMap(result['payload']);
    final String text = asString(data['result']);
    if (data['is_error'] == true) return '待办读取失败：${_clip(text, 400)}';
    return '## 待办（set_todo_list 快照）\n${_clip(text.trim().isEmpty ? '（暂无待办）' : text.trim(), 4000)}';
  }

  /// 摘要正文（写进第二条 system 消息）。
  static String summaryText(Map<String, Object?> parsed) {
    final String background = asString(parsed['background']);
    final String trajectory = asString(parsed['trajectory']);
    final List<String> lines = <String>[];
    // **抢救回来的摘要必须显式标注**：花钱救回来的是"可能不完整"的摘要，绝不能让
    // 下一轮的自己以为它是完整的。
    final String recovered = asString(parsed['_recovered_from']);
    if (recovered.isNotEmpty) {
      final String how = recovered == 'repair'
          ? '由一次 JSON 修复调用补全'
          : '由本地结构修复得到';
      final String incomplete = asString(parsed['_incomplete_reason']);
      lines.addAll(<String>[
        '> ⚠️ 本摘要$how，**可能不完整**'
            '${incomplete.isEmpty ? '' : '：模型判定原文被截断（$incomplete）'}',
        '',
      ]);
    }
    lines.addAll(<String>[
      '## 背景',
      background.isEmpty ? '（无）' : background,
      '',
      '## 轨迹',
      trajectory.isEmpty ? '（无）' : trajectory,
      '',
      '## 改动与产出文件',
    ]);
    final Object? files = parsed['files_changed'];
    if (files is List && files.isNotEmpty) {
      for (final Object? item in files) {
        String path;
        String change;
        if (item is Map) {
          path = asString(asMap(item)['path']);
          change = asString(asMap(item)['change']);
        } else {
          path = '$item'.trim();
          change = '';
        }
        if (path.isEmpty && change.isEmpty) continue;
        lines.add('- $path${change.isEmpty ? '' : '：$change'}');
      }
    } else {
      lines.add('- （本次没有改动/产出文件）');
    }
    return lines.join('\n');
  }

  // ── 左栏面板（activity 槽位：活动栏图标 + 左栏整页）────────────────

  /// 发一次 `ui/manifest`：声明**一条** `activity` 槽位。**发一次就够**：前端断连
  /// 重连时核心按缓存（`PluginUiCache`）补发，之后的刷新走 `ui/update`。
  void declarePanel() {
    if (!panelEnabled) {
      channel.log('--no-panel：不申报左栏面板');
      return;
    }
    channel.notify(Ui.manifest, <String, dynamic>{
      'slots': <Map<String, dynamic>>[
        <String, dynamic>{
          'slot_key': slotKey,
          'slot': 'activity',
          'title': kPanelTitle,
          'icon': kPanelIcon,
          'order': 20,
          'view': panelView(),
        },
      ],
    });
    channel.log('已声明左栏面板槽位 $slotKey（activity：活动栏图标 + 左栏整页）');
  }

  /// 发 `ui/update`：按 slot_key **整块替换**视图（不做 diff）。[force] 绕过节流。
  void updatePanel({bool force = false}) {
    if (!panelEnabled) return;
    final DateTime now = DateTime.now();
    if (!force &&
        now.difference(_lastPush) < const Duration(milliseconds: 500)) {
      return;
    }
    _lastPush = now;
    channel.notify(Ui.update, <String, dynamic>{
      'slot_key': slotKey,
      'view': panelView(),
    });
  }

  /// 更新"点位订阅"那一行并刷面板（订阅没订上必须看得见）。
  void setStatus(bool subscribed, String detail) {
    // 按键更新而不是整体替换：同一时刻可能有别的提示挂在状态里（如"正在压缩…"）。
    status['subscribed'] = subscribed;
    status['detail'] = detail;
    updatePanel(force: true);
  }

  /// 记住"最近一次见到的会话"：动作帧没带 `agent_id` 时按钮靠它找到目标。
  void rememberIdentity(Object? agentId, [Object? sessionId]) {
    if (asString(agentId).isNotEmpty) identity['agent_id'] = asString(agentId);
    if (asString(sessionId).isNotEmpty) {
      identity['session_id'] = asString(sessionId);
    }
  }

  /// 追加一条面板记录（**唯一**的写入点；字段表见 [collectRecords]）。
  void record(
    String source, {
    int? covered,
    int? durationMs,
    String note = '',
    String agentId = '',
    String sessionId = '',
  }) {
    records.add(<String, Object?>{
      'at': DateTime.now().millisecondsSinceEpoch / 1000.0,
      'source': source,
      'covered': covered,
      'duration_ms': durationMs,
      'note': note,
      'agent_id': agentId,
      'session_id': sessionId,
      'model': '',
      'kind': 'own',
    });
    if (records.length > kMaxOwnRecords) {
      records.removeRange(0, records.length - kMaxOwnRecords);
    }
  }

  /// **面板的数据源**：两类记录并成一张表（都按时间倒序）：
  /// ① 本插件**自己经手**的（接管 / 不接管含原因与耗时、「立即压缩一次」的核心回执）；
  /// ② 核心在压缩载荷里捣来的**逐调用用量**（`recent_usage`）。
  ///
  /// ⚠ "拿不到就留白"是硬口径：没有 `recent_usage` 时这里就只有 ①，来源列不会凭空
  /// 多出 `builtin`；账本里没有"覆盖条数"这一说，用量行的那一列就是"—"。
  List<Map<String, Object?>> collectRecords() {
    if (options.usageJsonl.isNotEmpty) {
      ingestRecentUsage(usageLines(options.usageJsonl));
    }
    final List<Map<String, Object?>> all = <Map<String, Object?>>[
      ...records,
      ...usageRecords.values,
    ]..sort(
      (Map<String, Object?> a, Map<String, Object?> b) =>
          (b['at'] as num? ?? 0).compareTo(a['at'] as num? ?? 0),
    );
    return all;
  }

  /// 把核心捣来的"最近用量行"并进面板；返回本次**新增**的条数（去重 = 整行 canonical JSON）。
  int ingestRecentUsage(
    Object? lines, {
    String path = '',
    String agentId = '',
    String sessionId = '',
  }) {
    if (lines is! List) return 0;
    int added = 0;
    if (path.isNotEmpty) usageFile = path;
    for (final Object? line in lines) {
      if (line is! Map) continue;
      final Map<String, Object?> item = asMap(line);
      final String key = canonicalJson(item);
      if (usageRecords.containsKey(key)) continue;
      final Map<String, Object?>? record = recordFromUsageLine(
        item,
        agentId: agentId,
        sessionId: sessionId,
      );
      if (record == null) continue; // `turn` 行 / 形状不认识：不是本面板的事
      usageRecords[key] = record;
      added++;
    }
    if (usageRecords.length > kMaxUsageRecords) {
      final List<String> keys = usageRecords.keys.toList();
      for (final String key in keys.take(keys.length - kMaxUsageRecords).toList()) {
        usageRecords.remove(key);
      }
    }
    return added;
  }

  Map<String, dynamic> panelView() {
    final List<Map<String, Object?>> collected = collectRecords();
    final int limit = options.panelRecords < 1 ? 1 : options.panelRecords;
    final List<Map<String, Object?>> shown = collected
        .take(limit)
        .toList(growable: false);
    final List<Map<String, dynamic>> children = <Map<String, dynamic>>[
      <String, dynamic>{'type': 'text', 'text': kPanelTitle, 'style': 'title'},
      <String, dynamic>{
        'type': 'text',
        'text': panelSummary(collected),
        'style': 'caption',
      },
    ];
    final List<int>? mark = watermark;
    if (mark != null) {
      final int covered = mark[0];
      final int total = mark[1];
      children.add(<String, dynamic>{
        'type': 'progress',
        'value': total > 0
            ? (covered / total).clamp(0.0, 1.0)
            : 0.0,
        'label': '已覆盖原文条数（核心报的水位线）',
        'detail': '$covered / $total',
      });
    }
    if (shown.isEmpty) {
      children.add(<String, dynamic>{
        'type': 'text',
        'text':
            '还没有压缩记录：点下面「立即压缩一次」，或者等上下文到阈值时自动压一次'
            '（核心内置兜底的那几次也会记在下面，来源显示 `builtin`）。',
        'style': 'body',
      });
    }
    // 表格**一直渲染**（没记录时给一行占位）：列名先亮出来，用户一眼知道这里会记什么；
    // 空表格配一句指引，比整块消失更不像"插件坏了"。
    children.add(<String, dynamic>{
      'type': 'table',
      'columns': kPanelColumns,
      'rows': <List<String>>[
        ...shown.map(panelRow),
        if (shown.isEmpty)
          <String>['—', '—', '—', '—', '（还没有压缩记录）'],
      ],
      'caption':
          '最近 ${shown.length} 次（最新在最上面；来源未知 = 本插件没经手；'
          '带「用量」的行来自核心捣来的 usage.jsonl）',
    });
    children.add(<String, dynamic>{
      'type': 'actions',
      'buttons': <Map<String, dynamic>>[
        <String, dynamic>{
          'action_id': 'compact_now',
          'label': '立即压缩一次',
          'style': 'primary',
        },
        <String, dynamic>{'action_id': 'refresh', 'label': '刷新'},
      ],
    });
    return <String, dynamic>{
      'type': 'column',
      'gap': 6,
      'children': children,
    };
  }

  /// 面板头部那一行：订阅状态 + 经手统计 + 用量条数 + 最近一次"为什么没成"。
  String panelSummary(List<Map<String, Object?>> collected) {
    final List<String> parts = <String>[
      '点位订阅：${asString(status['detail']).isEmpty ? '未知' : status['detail']}',
      '经手 ${counters['requests']} 次'
          '（接管 ${counters['taken']} / 未接管 ${counters['declined']}）',
      if (usageRecords.isNotEmpty) '用量记录 ${usageRecords.length} 条',
    ];
    final String agentId = identity['agent_id'] ?? '';
    final String sessionId = identity['session_id'] ?? '';
    parts.add(
      agentId.isNotEmpty || sessionId.isNotEmpty
          ? '最近会话：${agentId.isEmpty ? '(无 agent)' : agentId}'
              '${sessionId.isEmpty ? '' : '/$sessionId'}'
          : '最近会话：未知（等一次压缩 / 工具事件）',
    );
    // 只要"本插件这一次为什么没成"（用量行的说明里是 token 账，不是原因）。
    for (final Map<String, Object?> record in collected) {
      if (record['kind'] != 'usage' && asString(record['note']).isNotEmpty) {
        parts.add('最近原因：${_clip(asString(record['note']), 160)}');
        break;
      }
    }
    final String manual = asString(status['manual']);
    if (manual.isNotEmpty) parts.add(manual);
    return parts.join(' · ');
  }

  /// 一条记录 → 表格的一行（单元格只放标量文本，表格渲染器只认标量）。
  static List<String> panelRow(Map<String, Object?> record) {
    final double at = (record['at'] as num? ?? 0).toDouble();
    final String when = at <= 0 ? '—' : _clock(DateTime.fromMillisecondsSinceEpoch((at * 1000).round()));
    final String source = asString(record['source']);
    final Object? covered = record['covered'];
    return <String>[
      when,
      source.isEmpty ? '未知' : source,
      covered == null ? '—' : '$covered',
      _durationText((record['duration_ms'] as num?)?.toInt()),
      asString(record['note']).isEmpty ? '—' : asString(record['note']),
    ];
  }

  // ── 面板交互（前端按钮 → 核心 → 插件）─────────────────────────────

  void handleUiAction(Map<String, dynamic> params) {
    final String actionId = asString(params['action_id']);
    channel.log('面板交互：slot=${asString(params['slot_key'])} action=$actionId');
    switch (actionId) {
      case 'compact_now':
        startManualCompact(params);
      case 'refresh':
        updatePanel(force: true);
      default:
        // 未知 action：显式记下来（不静默），但不算错误。
        channel.log('未知的面板动作（忽略）：$actionId');
    }
  }

  /// 「立即压缩一次」：不在读循环里死等（回包也从同一条 stdin 进来）。
  void startManualCompact(Map<String, dynamic> params) {
    final Map<String, dynamic> payload = asMap(params['payload']);
    String agentId = asString(params['agent_id']).isNotEmpty
        ? asString(params['agent_id'])
        : asString(payload['agent_id']);
    String sessionId = asString(params['session_id']).isNotEmpty
        ? asString(params['session_id'])
        : asString(payload['session_id']);
    rememberIdentity(agentId, sessionId);
    if (agentId.isEmpty) agentId = identity['agent_id'] ?? '';
    if (sessionId.isEmpty) sessionId = identity['session_id'] ?? '';
    if (agentId.isEmpty) {
      // **不猜目标**：没有身份就如实写进面板。
      record(
        '',
        note: '立即压缩未发出：不知道目标 agent（先让它发生一次压缩 / 工具调用，'
            '或用 --agent-id 指定）',
      );
      updatePanel(force: true);
      return;
    }
    status['manual'] = '正在压缩…';
    updatePanel(force: true);
    unawaited(compactNow(agentId, sessionId));
  }

  /// 经执行站 `agent.compact` 手动压一次，并把回执记进面板。
  ///
  /// 核心侧这条命令与 REST `/compact` 是**同一个入口**：它会拒绝"正在生成"的 agent
  /// （压缩改写上下文，与生成并发读写不安全），所以失败信息要原样留痕。
  Future<void> compactNow(String agentId, String sessionId) async {
    final DateTime began = DateTime.now();
    final Map<String, dynamic> ident = <String, dynamic>{
      'agent_id': agentId,
      'session_id': sessionId,
    };
    final Map<String, Object?> result = await exec(
      kCommandAgentCompact,
      <String, dynamic>{...ident},
      ident,
    );
    final int ms = DateTime.now().difference(began).inMilliseconds;
    if (result['ok'] != true) {
      final String note = '立即压缩失败：'
          '${asString(result['error']).isEmpty ? '未知原因' : result['error']}';
      record('', durationMs: ms, note: note, agentId: agentId, sessionId: sessionId);
      finishManual(agentId, sessionId);
      return;
    }
    final Map<String, Object?> payload = asMap(result['payload']);
    final String source = asString(payload['source']).toLowerCase();
    final Object? covered = payload['summarized_messages'];
    String note = '';
    if (payload['compressed'] != true) {
      note = '未压缩：${asString(payload['reason']).isEmpty ? '未知原因' : payload['reason']}';
    } else if (payload['degraded'] == true) {
      note = '降级：${asString(payload['degraded_reason']).isEmpty ? '总结失败' : payload['degraded_reason']}';
    } else if (asString(payload['relay_skip_reason']).isNotEmpty) {
      // 可选键：中转站没接管的可读原因（没有它就只剩"降级/成功"两种观感）。
      note = '中转未接管：${payload['relay_skip_reason']}';
    }
    channel.log(
      '手动压缩：compressed=${payload['compressed']} source=${source.isEmpty ? '(未知)' : source} '
      '覆盖=${asString(covered)} 耗时=${_durationText(ms)} note=${note.isEmpty ? '-' : note}',
    );
    record(
      source,
      covered: covered is int ? covered : null,
      durationMs: ms,
      note: note,
      agentId: agentId,
      sessionId: sessionId,
    );
    finishManual(agentId, sessionId);
  }

  void finishManual(String agentId, String sessionId) {
    status.remove('manual');
    rememberIdentity(agentId, sessionId);
    updatePanel(force: true);
  }

  /// 开发期离线回放：读一份 `usage.jsonl`（**可选**数据源：读不到 / 行坏了 ⇒ 跳过，
  /// 它的问题不该让面板变空）。
  static List<Map<String, Object?>> usageLines(String path) {
    if (path.isEmpty) return <Map<String, Object?>>[];
    final List<Map<String, Object?>> out = <Map<String, Object?>>[];
    try {
      for (final String line in File(path).readAsLinesSync()) {
        final String text = line.trim();
        if (text.isEmpty) continue;
        final Map<String, dynamic> decoded = asJson(text);
        if (decoded.isNotEmpty) out.add(asMap(decoded));
      }
    } catch (_) {
      return <Map<String, Object?>>[];
    }
    return out;
  }

  /// 用量行 → 面板记录；与压缩无关的行返回 null（字段表就是契约，改动只在这一处）。
  static Map<String, Object?>? recordFromUsageLine(
    Map<String, Object?> item, {
    String agentId = '',
    String sessionId = '',
  }) {
    final String? label = kUsageSourceLabels[asString(item['source']).toLowerCase()];
    if (label == null) return null;
    final double at = _epochOf(item['at']);
    if (at <= 0) {
      // 连时间都读不出来的行不显示：面板按时间排序，它会沉到最底下且时间列是"—"，
      // 除了让人怀疑面板坏了没有任何价值。
      return null;
    }
    return <String, Object?>{
      'at': at,
      'source': label,
      // 账本里没有"覆盖条数"这一说（那是压缩的产物，不是调用的账）⇒ 留白不猜。
      'covered': null,
      'duration_ms': item['duration_ms'] is num
          ? (item['duration_ms'] as num).toInt()
          : null,
      'note': usageNote(item),
      'agent_id': agentId.isNotEmpty
          ? agentId
          : asString(item['agent_id']),
      'session_id': sessionId.isNotEmpty
          ? sessionId
          : asString(item['session_id']),
      'model': asString(item['model']),
      'kind': 'usage',
    };
  }

  /// 用量行在"说明"列里的样子：模型 + 输入/缓存/输出（+ 估算）。
  ///
  /// `cached_tokens = null` **不显示成 0**（核心的口径就是"null = 端点没给这个字段"），
  /// `estimated = true` 必须看得见（那是本地估算，不能当计费依据）。
  static String usageNote(Map<String, Object?> item) {
    final List<String> parts = <String>[
      if (asString(item['model']).isNotEmpty) _clip(asString(item['model']), 24),
      '输入 ${_tokenText(item['prompt_tokens'])}',
      if ((item['cached_tokens'] is int) && (item['cached_tokens'] as int) > 0)
        '缓存 ${_tokenText(item['cached_tokens'])}',
      '输出 ${_tokenText(item['completion_tokens'])}',
    ];
    return '用量 ${parts.join(' · ')}${item['estimated'] == true ? '（估算）' : ''}';
  }
}

String _clock(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}:'
    '${at.second.toString().padLeft(2, '0')}';

/// 抢救结果三元组。
class Recovery {
  const Recovery(this.parsed, this.raw, this.origin);
  final Map<String, Object?>? parsed;
  final String raw;
  final String origin;
}

/// 修复调用的结果（`summary == null` 时 [why] 必须有话）。
class RepairOutcome {
  const RepairOutcome(this.summary, this.why);
  final Map<String, Object?>? summary;
  final String why;
}

// ── 装配与入口 ──────────────────────────────────────────────────────────

/// 把业务接到骨架上：返回 `(server, plugin)`。
///
/// 两个都给出是因为**自检与生产必须同码**：`main` 只要 server，自检还要读插件内部的
/// 计数 / 面板记录 / 身份，而这些都只能从同一个 [CompactPlugin] 实例上拿。
(PluginKitServer server, CompactPlugin plugin) build({
  Options? options,
  PluginChannel? channel,
}) {
  final Options given = options ?? Options();
  final PluginChannel wire = channel ?? PluginChannel.stdio(kPluginId);
  final CompactPlugin plugin = CompactPlugin(channel: wire, options: given);
  final PluginKitServer server = PluginKitServer(
    channel: wire,
    pluginId: kPluginId,
    displayName: kPanelTitle,
    capabilities: const <String>['stations'],
    // 本插件不申报工具：它只订压缩点位 + 下执行站命令 + 推左栏面板。
    onRequest: (String method, Map<String, dynamic> params) async {
      if (method != M.stationRequest) return null;
      return plugin.handleStationRequest(params);
    },
    onNotify: (String method, Map<String, dynamic> params) {
      if (method == M.event) {
        if (asString(params['event']) == kEventUiAction) {
          plugin.handleUiAction(params);
          return;
        }
        // 非 UI 事件**一帧都不发**（压缩不靠事件驱动），但它是「最近会话」的可靠来源：
        // 面板那个按钮得知道该压谁，而核心不会替插件记住这件事。
        plugin.rememberIdentity(params['agent_id'], params['session_id']);
        return;
      }
      // 裸 method 形态（老核心 / 直连测试）也收下，否则按钮会永远没反应。
      if (method == kEventUiAction) plugin.handleUiAction(params);
    },
    onReady: (PluginKitServer server) {
      // `hello` 之后 `plugin_id` 才是核心认定的实例 id：槽位键必须用它拼，否则同目录
      // 起两个实例时两个面板会抢同一个 slot_key。
      final String given = server.effectivePluginId;
      plugin.pluginId = given.isEmpty ? kPluginId : given;
      return plugin.startup();
    },
  );
  return (server, plugin);
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

// ── 自检的公共零件（真帧面 + fixture）──────────────────────────────────

Map<String, dynamic> frameParams(Map<String, dynamic> frame) =>
    asMap(frame['params']);

String frameCommand(Map<String, dynamic> params) =>
    asString(params['command']);

Map<String, dynamic> frameArguments(Map<String, dynamic> params) =>
    asMap(params['arguments']);

/// 站点回包里的 payload（`null` = 不接管，与核心约定一致）。
Object? payloadOf(Map<String, dynamic> result) => asMap(result['reply'])['payload'];

/// 不接管时给核心的可读原因（可选键）。
String reasonOf(Map<String, dynamic> result) => asString(asMap(result['reply'])['reason']);

List<String> rolesOf(List<Object?> messages) =>
    messages.map(roleOf).toList(growable: false);

/// 结构合法性（端点 400 的根因都在那两条上）：
/// ① 每条 `tool` 必须有**前置**且 id 配对的 `assistant(tool_calls)`（否则孤儿）；
/// ② 每条带 `tool_calls` 的 `assistant` 必须被紧随的 `tool` 配平，中间不得插入别的
///    角色（否则悬空）。
List<String> structureProblems(List<Object?> messages) {
  final List<String> problems = <String>[];
  List<String> pending = <String>[];
  for (int index = 0; index < messages.length; index++) {
    final Object? message = messages[index];
    final String role = roleOf(message);
    if (role == 'assistant') {
      if (pending.isNotEmpty) {
        problems.add('第 $index 条 assistant 打断了未配对的 tool_calls：$pending');
        pending = <String>[];
      }
      if (hasToolCalls(message)) {
        pending = (asMap(message)['tool_calls'] as List<Object?>)
            .map((Object? call) => asString(asMap(call)['id']))
            .toList();
      }
      continue;
    }
    if (role == 'tool') {
      final String callId = asString(asMap(message)['tool_call_id']);
      if (!pending.contains(callId)) {
        problems.add('第 $index 条 tool 没有配对的前置 tool_calls：$callId');
      } else {
        pending = pending.where((String id) => id != callId).toList();
      }
      continue;
    }
    if (pending.isNotEmpty) {
      problems.add('第 $index 条 $role 打断了未配对的 tool_calls：$pending');
      pending = <String>[];
    }
  }
  if (pending.isNotEmpty) problems.add('结尾仍有未配对的 tool_calls：$pending');
  return problems;
}

/// 引擎口径的一段 wire 上下文：system×2 + 两轮历史 + `rounds` 个工具轮 + 收尾 user。
List<Map<String, dynamic>> wireFixture({int rounds = 1, String tailUser = '第三轮要求'}) {
  final List<Map<String, dynamic>> messages = <Map<String, dynamic>>[
    <String, dynamic>{'role': 'system', 'content': '你是助手（引擎拼装的提示词）'},
    <String, dynamic>{'role': 'system', 'content': '【上一次压缩的摘要】'},
    <String, dynamic>{'role': 'user', 'content': '第一轮要求'},
    <String, dynamic>{'role': 'assistant', 'content': '第一轮回答'},
  ];
  for (int index = 0; index < rounds; index++) {
    messages.add(<String, dynamic>{'role': 'user', 'content': '第 ${index + 2} 轮要求'});
    messages.add(<String, dynamic>{
      'role': 'assistant',
      'content': '',
      'reasoning_content': '先读一下文件',
      'tool_calls': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'c$index',
          'type': 'function',
          'function': <String, dynamic>{
            'name': 'read',
            'arguments': '{"path": "lib/a.dart"}',
          },
        },
      ],
    });
    messages.add(<String, dynamic>{
      'role': 'tool',
      'tool_call_id': 'c$index',
      'content': 'class A {}',
    });
    messages.add(<String, dynamic>{
      'role': 'assistant',
      'content': '第 ${index + 2} 轮回答',
    });
  }
  messages.add(<String, dynamic>{'role': 'user', 'content': tailUser});
  messages.add(<String, dynamic>{'role': 'assistant', 'content': '最后一轮回答'});
  return messages;
}

/// **单轮超长工具轨迹**：一条 user 后面跟 `rounds` 个工具轮——「keep 死保整轮」压不动
/// 的那种形态，切点必须在轮**内部**往前挪。
List<Map<String, dynamic>> singleTurnFixture(int rounds) {
  final List<Map<String, dynamic>> messages = <Map<String, dynamic>>[
    <String, dynamic>{'role': 'system', 'content': '你是助手（引擎拼装的提示词）'},
    <String, dynamic>{'role': 'user', 'content': '把整个仓库扫一遍并修掉所有 TODO'},
  ];
  for (int index = 0; index < rounds; index++) {
    messages.add(<String, dynamic>{
      'role': 'assistant',
      'content': '',
      'reasoning_content': '继续扫',
      'tool_calls': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 's$index',
          'type': 'function',
          'function': <String, dynamic>{
            'name': 'grep',
            'arguments': '{"q": "TODO", "page": $index}',
          },
        },
      ],
    });
    messages.add(<String, dynamic>{
      'role': 'tool',
      'tool_call_id': 's$index',
      'content': '第 ${index + 1} 轮工具结果',
    });
  }
  messages.add(<String, dynamic>{'role': 'assistant', 'content': '扫完了，共 10 处'});
  return messages;
}

/// 摘要 fixture：5 条必读里混着**合法 / 缺行范围 / 绝对路径 / 越界 / 读不到**五种，
/// 为的是让「非法项也留可读结果」这条硬要求无处可藏。
Map<String, Object?> summaryFixture() => <String, Object?>{
  'background': '用户要求把登录改成 JWT。',
  'trajectory': '已定位 auth 模块为 session 实现。',
  'files_changed': <Object?>[
    <String, Object?>{'path': 'lib/auth.dart', 'change': '修改：改为 JWT 校验'},
  ],
  'required_files': <Object?>[
    <String, Object?>{
      'path': 'lib/auth.dart',
      'start_line': 1,
      'line_count': 60,
      'why': '正在改的模块',
    },
    <String, Object?>{'path': 'docs/plan.md', 'why': '计划文档'},
    <String, Object?>{'path': 'E:/abs/path.md', 'why': '非法：绝对路径'},
    <String, Object?>{'path': '../escape.md', 'why': '非法：越界'},
    <String, Object?>{'path': 'missing.md', 'why': '读失败'},
  ],
};

/// `usage.jsonl` 的样本行（字段表 = 核心 `UsageCall.toJson()`）：三种要显示的来源 +
/// 一种**必须被跳过**的（`turn`），外加 `cached_tokens=null` / `estimated=true` /
/// 耗时超 1 秒三类边界。
List<Map<String, Object?>> usageFixture() => <Map<String, Object?>>[
  <String, Object?>{
    'at': '2026-10-03T16:31:55.000000',
    'source': 'compact',
    'model': 'demo-model',
    'prompt_tokens': 1200,
    'cached_tokens': 900,
    'completion_tokens': 120,
    'estimated': false,
    'duration_ms': 1800,
  },
  <String, Object?>{
    'at': '2026-10-03T16:38:02.500000',
    'source': 'llm.call',
    'model': 'demo-model',
    'prompt_tokens': 800,
    'cached_tokens': null,
    'completion_tokens': 60,
    'estimated': true,
    'duration_ms': 700,
  },
  <String, Object?>{
    'at': '2026-10-03T16:39:10.000000',
    'source': 'plugin',
    'model': 'demo-model',
    'prompt_tokens': 300,
    'cached_tokens': 0,
    'completion_tokens': 30,
    'estimated': false,
    'duration_ms': 260,
  },
  // 对话自己的跳：**不属于压缩面板**，必须被跳过。
  <String, Object?>{
    'at': '2026-10-03T16:40:00.000000',
    'source': 'turn',
    'model': 'demo-model',
    'prompt_tokens': 10,
    'cached_tokens': null,
    'completion_tokens': 5,
    'estimated': false,
    'duration_ms': 90,
  },
];

/// 核心投给插件的 `station/request` params（与 `_stationCompact` 的载荷同形状）。
///
/// `total_message_count` 固定 12：它是**会话原文**的条数，与这里那段 wire 的条数无关
/// （插件只照抄核心给的数，绝不按 wire 长度自己算——算出来的是另一个口径）。
Map<String, dynamic> stationParams(Object? messages, {int frozen = 0}) {
  return <String, dynamic>{
    'station_id': kPointContextCompact,
    'scope': <String, dynamic>{
      'team_id': 't1',
      'agent_id': 'agt_1',
      'session_id': 'ses_1',
    },
    'payload': <String, dynamic>{
      'agent_id': 'agt_1',
      'session_id': 'ses_1',
      'system_prompt': '你是助手（压缩时快照）',
      'total_message_count': 12,
      'compacted_message_count': frozen,
      'existing_summary': '',
      'compacted': false,
      'request': <String, dynamic>{
        'model': 'demo-model',
        'messages': messages,
        'tools': <Object?>[
          <String, dynamic>{
            'type': 'function',
            'function': <String, dynamic>{
              'name': 'read',
              'description': '读文件',
              'parameters': <String, dynamic>{'type': 'object'},
            },
          },
        ],
        'stream': false,
      },
    },
  };
}

/// 自检用的选项：命令观测窗口压到 5 秒（用例的假核心都按脚本回包，绝不该真等到超时）。
Options testOptions({
  bool dryRun = false,
  bool noPanel = false,
  String usageJsonl = '',
  int maxFiles = 11,
}) => Options()
  ..commandTimeoutSeconds = 5
  ..dryRun = dryRun
  ..noPanel = noPanel
  ..usageJsonl = usageJsonl
  ..maxFiles = maxFiles;

/// 一条自检用的假核心：按命令名回**与核心同形状**的执行站信封。
///
/// 走的是真帧面（编码、id 关联、读循环），不是把 `command()` 换成假函数：“能算对切点”
/// 与“能把帧发对”在两处都会错，而后者只在真帧上看得见（身份写错位置这类错误尤其明显）。
class _Harness {
  _Harness(
    Options options, {
    Map<String, Object?>? summary,
    Set<String> failCommands = const <String>{},
    Map<String, Object?>? compactResult,
    List<Map<String, dynamic>>? llmSeq,
    bool refuseSubscribe = false,
  }) {
    final PluginChannel channel = PluginChannel(logTag: kPluginId);
    final (PluginKitServer built, CompactPlugin builtPlugin) = build(
      options: options,
      channel: channel,
    );
    server = built;
    plugin = builtPlugin;
    core = FakeCore(built);
    final Map<String, Object?> summaryJson = summary ?? summaryFixture();
    final List<Map<String, dynamic>> queue = <Map<String, dynamic>>[
      ...?llmSeq,
    ];
    core.onMethod(M.stationSubscribe, (Map<String, dynamic> params) {
      if (refuseSubscribe) {
        return <String, dynamic>{'ok': false, 'error': '该点位已有订阅者（replace=false 不抢占）'};
      }
      // 站点已全局化：回来的 station_id 就是点位常量本身（不含 @team@mode）。
      return <String, dynamic>{
        'ok': true,
        'station_id': kPointContextCompact,
        'subscriber_count': 1,
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
        case kCommandLlmCall:
          if (queue.isNotEmpty) return queue.removeAt(0);
          return _envelope(command, <String, dynamic>{
            'ok': true,
            'json': summaryJson,
            'text': json.encode(summaryJson),
            'model': 'demo-model',
            'usage': <String, dynamic>{
              'prompt_tokens': 1200,
              'cached_tokens': 1100,
            },
          });
        case kCommandFsRead:
          final String path = asString(args['path']);
          if (path == 'missing.md') return _reject(command, '文件不存在');
          // 骨架的失败判据得**两条都认**：核心回 `ok:false` 却没写原因（挂载实现漏了
          // error 那一句）也必须算失败。只认 error 的结局是把失败当成功、把 payload
          // 原样交回，而下面这些调用方会拿着“空 payload”继续算。
          if (path == 'no_reason.md') {
            return <String, dynamic>{
              'command': command,
              'ok': false,
              'mount_id': 'harness',
              'payload': null,
            };
          }
          return _envelope(command, <String, dynamic>{
            'path': path,
            'content': '// $path 的内容',
            'total_lines': 120,
            'start_line': args['start_line'] ?? 1,
            'truncated': false,
          });
        case kCommandToolCall:
          return _envelope(command, <String, dynamic>{
            'tool': 'set_todo_list',
            'is_error': false,
            'result': '- [~] t1 | status=in_progress progress=50 | 改 JWT',
          });
        case kCommandAgentCompact:
          // 核心 `_stationCompact` 的回执形状 = CompactionResult.toJson()。
          return _envelope(command, compactResult ?? <String, Object?>{
            'success': true,
            'compressed': true,
            'context_size': 9,
            'summarized_messages': 6,
            'source': 'builtin',
            'session_id': 'ses_1',
          });
      }
      return _reject(command, '未知命令 $command');
    });
    unawaited(core.start());
  }

  late final CompactPlugin plugin;
  late final PluginKitServer server;
  late final FakeCore core;

  /// 插件发过的每一条执行站命令（就是帧上的 params，**包含身份那一层**）。
  final List<Map<String, dynamic>> calls = <Map<String, dynamic>>[];

  int _seq = 0;

  static Map<String, dynamic> _envelope(
    String command,
    Map<String, Object?> payload,
  ) => <String, dynamic>{
    'command': command,
    'ok': true,
    'mount_id': 'harness',
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

  /// 把总结回包换成“调用失败、但**失败也带着原文**”（真核心的形状：
  /// `StationCommandOutcome.failedWith(error, payload)`，抢救路径的入口）。
  static Map<String, dynamic> badText(String text, {bool truncated = false}) =>
      <String, dynamic>{
        'command': kCommandLlmCall,
        'ok': false,
        'mount_id': 'harness',
        'error': '模型正文不是合法 JSON（本次按 text 形态发送）',
        'payload': <String, dynamic>{
          'ok': false,
          'error': '模型正文不是合法 JSON（text 形态）',
          'error_kind': 'json_parse',
          'text': text,
          'text_length': text.length,
          'truncated_suspect': truncated,
        },
      };

  /// 修复调用的成功回包（站点缺省就是 json_object，所以这里给 `json`）。
  /// [parsed] 是修复契约的那三元组：`{complete, reason, summary}`。
  static Map<String, dynamic> repaired(Map<String, Object?> parsed) =>
      _envelope(kCommandLlmCall, <String, dynamic>{
        'ok': true,
        'json': parsed,
        'text': json.encode(parsed),
        'model': 'demo-model',
        'usage': <String, dynamic>{'prompt_tokens': 300, 'cached_tokens': 0},
      });

  /// `hello`（握手）：骨架在这里把 plugin_id 定下来，面板申报与订阅都仍在那之后。
  Future<void> hello() async {
    core.ask('hello', M.hello, <String, dynamic>{'plugin_id': kPluginId});
    await core.waitFor(<Object?>['hello']);
  }

  /// 真帧面问一次压缩：返回 `result`（空表 = 回包没来）。
  Future<Map<String, dynamic>> driveParams(Map<String, dynamic> params) async {
    final String id = 'st-${++_seq}';
    core.ask(id, M.stationRequest, params);
    final Map<Object?, Map<String, dynamic>> got = await core.waitFor(
      <Object?>[id],
      timeout: const Duration(seconds: 12),
    );
    final Map<String, dynamic>? frame = got[id];
    if (frame == null) return <String, dynamic>{};
    return asMap(frame['result']);
  }

  Future<Map<String, dynamic>> drive(Object? messages, {int frozen = 0}) =>
      driveParams(stationParams(messages, frozen: frozen));

  /// 插件为某个面板动作发一条 event 通知（核心把前端动作包成这个样子）。
  Future<void> uiAction(Map<String, dynamic> params, {bool bare = false}) async {
    core.notify(bare ? kEventUiAction : M.event, params);
    await settle();
  }

  List<Map<String, dynamic>> commands([String? command]) => calls
      .where((Map<String, dynamic> params) =>
          command == null || frameCommand(params) == command)
      .toList(growable: false);

  Map<String, dynamic> lastView(String method) {
    final List<Map<String, dynamic>> hits = core.outgoing(method);
    if (hits.isEmpty) return <String, dynamic>{};
    return asMap(frameParams(hits.last)['view']);
  }

  Map<String, dynamic> firstSlot() {
    final List<Map<String, dynamic>> hits = core.outgoing(Ui.manifest);
    if (hits.isEmpty) return <String, dynamic>{};
    final Object? slots = frameParams(hits.last)['slots'];
    if (slots is! List || slots.isEmpty) return <String, dynamic>{};
    return asMap(slots.first);
  }

  bool get uiQuiet =>
      core.outgoing(Ui.manifest).isEmpty && core.outgoing(Ui.update).isEmpty;

  Future<bool> waitFrames(
    String method, {
    int atLeast = 1,
    int ms = 6000,
  }) async {
    final DateTime deadline = DateTime.now().add(Duration(milliseconds: ms));
    while (DateTime.now().isBefore(deadline)) {
      if (core.outgoing(method).length >= atLeast) return true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return core.outgoing(method).length >= atLeast;
  }

  Future<bool> waitCommands(String command, {int atLeast = 1, int ms = 6000}) async {
    final DateTime deadline = DateTime.now().add(Duration(milliseconds: ms));
    while (DateTime.now().isBefore(deadline)) {
      if (commands(command).length >= atLeast) return true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return commands(command).length >= atLeast;
  }

  Future<bool> waitRecords(int atLeast, {int ms = 6000}) async {
    final DateTime deadline = DateTime.now().add(Duration(milliseconds: ms));
    while (DateTime.now().isBefore(deadline)) {
      if (plugin.records.length >= atLeast) return true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return plugin.records.length >= atLeast;
  }

  /// 等面板上真的出现那句话（订阅重试的最后一行落在**最后一次失败之后**，
  /// 只数帧数会读到旧视图）。
  Future<bool> waitViewText(String method, String needle, {int ms = 12000}) async {
    final DateTime deadline = DateTime.now().add(Duration(milliseconds: ms));
    while (DateTime.now().isBefore(deadline)) {
      if (rendered(lastView(method)).contains(needle)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return rendered(lastView(method)).contains(needle);
  }

  /// 断言“不发帧”之前得先给它机会发完（通知是不 await 地丢给业务层的）。
  Future<void> settle([int ms = 200]) =>
      Future<void>.delayed(Duration(milliseconds: ms));
}

/// 总结调用那一拍的 arguments（取第一条 `llm.call`）。
Map<String, dynamic> _summaryArguments(_Harness h) {
  final List<Map<String, dynamic>> hits = h.commands(kCommandLlmCall);
  if (hits.isEmpty) return <String, dynamic>{};
  return frameArguments(hits.first);
}

/// 总结调用的输入 messages。
List<Object?> _summaryMessages(_Harness h) {
  final Object? messages = _summaryArguments(h)['messages'];
  return messages is List ? messages : <Object?>[];
}

String rendered(Object? value) => json.encode(value);

/// 纯函数用例用的“裸插件”（不接通道：只问切点 / 归一 / 抢救这些不看帧的判断）。
CompactPlugin bare({Options? options}) => CompactPlugin(
  channel: PluginChannel(logTag: 'bare'),
  options: options ?? Options(),
);

/// 取 [stationParams] 里那个**可变的** payload。
///
/// 为什么不能直接 `asMap(params['payload'])` 再改：`asMap` 返回的是**拷贝**（`Map.map`
/// 出一个新表），往它上面 remove / 赋值等于改了个影子——用例看着像生效、插件收到的还是
/// 原样（不接管、没用量这类“应该少东西”的用例因此变成假绿）。
Map<String, dynamic> mutablePayload(Map<String, dynamic> params) =>
    params['payload'] as Map<String, dynamic>;

// ── 自检（假核心走**真帧面**：订阅、下命令、推面板都是真帧）─────────────

Future<int> selfTest() async {
  final SelfTest check = SelfTest(name: 'compact_plugin');
  final List<String> logs = <String>[];
  await _checkTakeover(check, logs);
  await _checkCacheShape(check, logs);
  await _checkReadsAndIdentity(check, logs);
  await _checkToolRoundCap(check, logs);
  await _checkCutNeverOnTool(check, logs);
  await _checkDeclines(check, logs);
  await _checkStructureAcrossFixtures(check, logs);
  await _checkHugeInput(check, logs);
  await _checkMaxFiles(check, logs);
  await _checkOtherPoint(check, logs);
  await _checkDryRun(check, logs);
  await _checkInstructionText(check, logs);
  await _checkPanelDeclare(check, logs);
  await _checkSilentPanel(check, logs);
  await _checkPanelAfterWork(check, logs);
  await _checkUiActionShapes(check, logs);
  await _checkManualCompact(check, logs);
  await _checkManualNotes(check, logs);
  await _checkUsageFeed(check, logs);
  await _checkUsageBulkAndOffline(check, logs);
  await _checkStatusOnPanel(check, logs);
  await _checkSubscribeFailureVisible(check, logs);
  await _checkRecoveryPaths(check, logs);
  return check.finish(logs);
}

/// ① 接管结构与 covered：产出形状就是核心的读取合同，改一位就得同步改核心。
Future<void> _checkTakeover(SelfTest check, List<String> logs) async {
  final List<Map<String, dynamic>> wire = wireFixture();
  final _Harness h = _Harness(testOptions());
  final Map<String, dynamic> result = await h.drive(wire);
  check.that(
    result.containsKey('reply'),
    'station/request 必须回 reply 信封（不接管也要回，不能让核心悬着）',
    actual: rendered(result.keys.toList()),
  );
  final Object? payload = payloadOf(result);
  check.that(payload is Map, '正常 wire 应被接管（payload 是对象）', actual: rendered(payload));
  logs.addAll(h.core.logs);
  if (payload is! Map) return;
  final Map<String, Object?> body = asMap(payload);
  check.check(
    body['covered_message_count'],
    12,
    'covered = 核心报的原文总条数（插件不按 wire 长度自己算：那是另一个口径）',
  );
  final List<Object?> out = body['messages'] is List
      ? body['messages'] as List<Object?>
      : <Object?>[];
  final CompactPlugin judge = bare();
  final int cut = judge.wireCut(wire, judge.options.keepRounds);
  final List<String> wantRoles = <String>[
    'system',
    'system',
    'assistant',
    ...List<String>.filled(6, 'tool'),
    ...rolesOf(wire.sublist(cut)),
  ];
  check.check(rolesOf(out), wantRoles, '回包角色序列 = 槽位 + 摘要 + 伪工具轮 + 尾部原样');
  check.check(
    asString(asMap(out[0])['content']),
    '你是助手（压缩时快照）',
    '首条是提示词槽位（内容由核心每轮覆盖，插件放快照即可）',
  );
  check.that(
    asString(asMap(out[1])['content']).contains('## 背景'),
    '第二条是摘要（背景 / 轨迹 / 改动）',
    actual: _clip(asString(asMap(out[1])['content']), 80),
  );
  final Map<String, Object?> assistant = asMap(out[2]);
  check.check(
    assistant['reasoning_content'],
    kReasoningText,
    '伪推理必须带上（带 tools 的思考端点会拒“历史 assistant 没 reasoning_content”）',
  );
  final List<Object?> toolCalls = assistant['tool_calls'] is List
      ? assistant['tool_calls'] as List<Object?>
      : <Object?>[];
  final List<Object?> toolResults = out.where(isTool).toList();
  check.check(toolCalls.length, 6, 'tool_calls = 5 读 + 1 todo');
  check.check(
    toolResults.map((Object? m) => asString(asMap(m)['tool_call_id'])).toList(),
    toolCalls.map((Object? c) => asString(asMap(c)['id'])).toList(),
    'tool_calls 与 tool 结果按 id 一一配对（顺序也得一致）',
  );
  check.check(
    asString(asMap(asMap(toolCalls.last)['function'])['name']),
    'set_todo_list',
    '最后一个 tool_call 是待办快照',
  );
  check.check(
    out.sublist(out.length - (wire.length - cut)),
    wire.sublist(cut),
    '尾部原样抄回（助手工作 / 工具卡都在里面，插件一个字都不改写）',
  );
  final List<String> problems = structureProblems(out);
  check.that(
    problems.isEmpty,
    '回包结构合法（无孤儿 tool / 无悬空 tool_calls）',
    actual: rendered(problems),
  );
  check.that(h.plugin.counters['taken'] == 1, '接管计数进 counters（面板那一行靠它）');
}

/// ② 缓存三条件（少一条就整段不命中，2026-10-04 真机实测）。
Future<void> _checkCacheShape(SelfTest check, List<String> logs) async {
  final List<Map<String, dynamic>> wire = wireFixture();
  final _Harness h = _Harness(testOptions());
  await h.drive(wire);
  final List<Map<String, dynamic>> llm = h.commands(kCommandLlmCall);
  check.check(llm.length, 1, '总结恰好 1 次 llm.call（多了就是在重复花钱）');
  logs.addAll(h.core.logs);
  if (llm.length != 1) return;
  final Map<String, dynamic> args = frameArguments(llm.first);
  final List<Object?> sent = _summaryMessages(h);
  final CompactPlugin judge = bare();
  final int cut = judge.wireCut(wire, judge.options.keepRounds);
  check.check(
    sent.sublist(0, sent.length - 1),
    wire.sublist(0, cut),
    '前缀与对话那一轮逐字一致（缓存的地基：端点只认逐字前缀）',
  );
  final Map<String, Object?> last = asMap(sent.isEmpty ? null : sent.last);
  check.check(last['role'], 'user', '前缀之后只追加一条 user 指令');
  check.that(
    asString(last['content']).contains('json'),
    '指令里写死了输出形状（text 形态下格式全靠指令兑）',
    actual: _clip(asString(last['content']), 60),
  );
  check.that(
    !args.containsKey('system'),
    '不用 llm.call 的 system 参数（那会在最前面插一条 system，前缀整体错位）',
  );
  check.that(
    args['tools'] is List && (args['tools'] as List).isNotEmpty,
    'tools 原样透传（工具定义在聊天模板里渲染在 messages 之前）',
  );
  check.check(
    args['response_format'],
    'text',
    'response_format 必须显式 text（缺省 json_object 会让端点改写提示词、前缀整段丢缓存）',
  );
  check.that(
    !rendered(sent).contains('最后一轮回答'),
    'keep 段不进总结输入（它本来就在尾部，抄回去就行，不该重复花钱）',
  );
  check.check(asString(llm.first['agent_id']), 'agt_1', '身份写在 params 顶层');
  check.check(asString(llm.first['session_id']), 'ses_1', '会话身份也在 params 顶层');
}

/// ③ 必读文件与身份：行范围透传、非法项**保留成可读失败条目**、预算内读取。
Future<void> _checkReadsAndIdentity(SelfTest check, List<String> logs) async {
  final List<Map<String, dynamic>> wire = wireFixture();
  final _Harness h = _Harness(testOptions());
  final Map<String, dynamic> result = await h.drive(wire);
  final String body = rendered(payloadOf(result));
  final List<Map<String, dynamic>> reads = h.commands(kCommandFsRead);
  check.check(
    reads.length,
    3,
    '5 条必读里只有 3 条真的发读取：绝对路径 / 越界那两条**不能递到 fs.read**',
  );
  logs.addAll(h.core.logs);
  if (reads.isEmpty) return;
  final Map<String, dynamic> first = frameArguments(reads.first);
  check.check(first['start_line'], 1, '行范围 start_line 透传');
  check.check(first['line_count'], 60, '行范围 line_count 透传');
  check.check(asString(reads.first['agent_id']), 'agt_1', 'fs.read 没带 agent 就拿不到工作空间');
  check.check(asString(reads.first['session_id']), 'ses_1', 'fs.read 的 session 在 params 顶层');
  for (final String must in <String>[
    '只允许工作空间相对路径',
    '含 ..',
    '文件不存在',
    '正在改的模块',
    '## 待办',
  ]) {
    check.that(body.contains(must), '回包里的必读 / todo 要能看到：$must');
  }
  check.that(
    h.commands(kCommandToolCall).length == 1,
    '待办走 tool.call（真工具真数据，不是插件自己编的）',
    actual: '${h.commands(kCommandToolCall).length}',
  );
  final Map<String, dynamic> todo = frameArguments(h.commands(kCommandToolCall).first);
  check.check(todo['tool'], 'set_todo_list', '待办快照调的就是 set_todo_list');
  check.check(asMap(todo['arguments'])['action'], 'get', '取快照用 action=get（不能顺手改掉用户的待办）');
}

/// ④ 工具轮上限：**单轮**里 10 个工具轮 ⇒ 只保留最后 8 轮（单轮超长轨迹因此压得动）。
Future<void> _checkToolRoundCap(SelfTest check, List<String> logs) async {
  final List<Map<String, dynamic>> single = singleTurnFixture(10);
  final _Harness h = _Harness(testOptions());
  final Map<String, dynamic> result = await h.drive(single);
  check.that(payloadOf(result) is Map, '工具轮上限用例应接管', actual: rendered(reasonOf(result)));
  logs.addAll(h.core.logs);
  final CompactPlugin judge = bare();
  final int cut = judge.wireCut(single, judge.options.keepRounds);
  final List<Object?> kept = single.sublist(cut);
  final int roundsKept = kept.where(hasToolCalls).length;
  check.check(
    roundsKept,
    judge.options.keepToolRounds,
    '保留了最后 8 轮工具轨迹（而不是整轮死保：那就压不动了）',
  );
  check.that(!isTool(kept.first), '切点没落在 tool 上（尾部以孤儿工具结果开头 = 端点 400）');
  check.that(
    rendered(_summaryMessages(h)).contains('第 1 轮工具结果'),
    '被挤出去的早期工具轮进了总结输入（内容不会丢，它进摘要）',
  );
}

/// ⑤ 切点**永不落在** `tool` 消息上（三种 fixture × 三种 keep-rounds）。
Future<void> _checkCutNeverOnTool(SelfTest check, List<String> logs) async {
  final Map<String, List<Map<String, dynamic>>> cases =
      <String, List<Map<String, dynamic>>>{
        '单轮 10 轮工具': singleTurnFixture(10),
        '多轮 3 轮工具': wireFixture(rounds: 3),
        '首条就是 tool': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'tool', 'tool_call_id': 'c', 'content': 'x'},
          <String, dynamic>{'role': 'user', 'content': '要求'},
        ],
      };
  final CompactPlugin judge = bare();
  for (final MapEntry<String, List<Map<String, dynamic>>> entry in cases.entries) {
    final List<Object?> fixture = entry.value;
    final List<String> bad = <String>[];
    for (final int rounds in <int>[1, 2, 5]) {
      final int cut = judge.wireCut(fixture, rounds);
      if (cut > 0 && cut < fixture.length && isTool(fixture[cut])) {
        bad.add('keep=$rounds 切点=$cut');
      }
    }
    check.that(
      bad.isEmpty,
      '孤儿保护生效（${entry.key}）',
      actual: bad.join(', '),
    );
  }
  final int moved = judge.wireCut(cases['首条就是 tool']!, 1);
  check.check(moved, 1, '首条就是 tool 时切点必须挖到非 tool 那一条');
}

/// ⑥ 不接管的各种情形：回 null + **把原因也回给核心**（可选键 reason）。
Future<void> _checkDeclines(SelfTest check, List<String> logs) async {
  final List<Map<String, dynamic>> wire = wireFixture();
  // a) 载荷没 payload
  final _Harness noPayload = _Harness(testOptions());
  final Map<String, dynamic> a = await noPayload.driveParams(<String, dynamic>{
    'station_id': kPointContextCompact,
  });
  check.that(payloadOf(a) == null, '没 payload 时应回 null', actual: rendered(payloadOf(a)));
  check.that(reasonOf(a).contains('[payload_missing]'), '不接管必须带原因码', actual: reasonOf(a));
  // b) 没 request
  final _Harness noRequest = _Harness(testOptions());
  final Map<String, dynamic> params = stationParams(wire);
  mutablePayload(params).remove('request');
  final Map<String, dynamic> b = await noRequest.driveParams(params);
  check.that(payloadOf(b) == null, '没有 request 时应回 null');
  check.that(reasonOf(b).contains('[request_missing]'), '缺 request 的原因要可读', actual: reasonOf(b));
  // c) 没可压内容
  final _Harness nothing = _Harness(testOptions());
  final Map<String, dynamic> c = await nothing.drive(<Map<String, dynamic>>[
    <String, dynamic>{'role': 'user', 'content': '刚开的新会话'},
  ]);
  check.that(payloadOf(c) == null, '没有可压内容时应回 null');
  check.that(reasonOf(c).contains('[nothing_to_compact]'), '整段都要保留也是一种可读的不接管', actual: reasonOf(c));
  // d) 总结调用失败
  final _Harness failing = _Harness(
    testOptions(),
    failCommands: const <String>{kCommandLlmCall},
  );
  final Map<String, dynamic> d = await failing.drive(wire);
  check.that(payloadOf(d) == null, 'llm.call 失败时应回 null（核心内置兑底）');
  check.that(
    reasonOf(d).contains('llm_call_failed'),
    '调用失败与“回包坏了”必须是两个原因码',
    actual: reasonOf(d),
  );
  check.check(
    failing.plugin.counters['declined'],
    1,
    '不接管计入 counters（面板与日志同一口径）',
  );
  logs.addAll(<String>[...noPayload.core.logs, ...noRequest.core.logs, ...nothing.core.logs, ...failing.core.logs]);
}

/// ⑦/⑧b 三种 fixture × 默认配置：总结输入与回包**都必须结构合法**（端点 400 的机器化防线）。
Future<void> _checkStructureAcrossFixtures(SelfTest check, List<String> logs) async {
  final Map<String, List<Map<String, dynamic>>> cases =
      <String, List<Map<String, dynamic>>>{
        '多轮 1 轮工具': wireFixture(rounds: 1),
        '多轮 3 轮工具': wireFixture(rounds: 3),
        '单轮 12 轮工具': singleTurnFixture(12),
      };
  for (final MapEntry<String, List<Map<String, dynamic>>> entry in cases.entries) {
    final _Harness h = _Harness(testOptions());
    final Map<String, dynamic> result = await h.drive(entry.value);
    final Object? payload = payloadOf(result);
    if (payload is! Map) {
      check.that(false, '${entry.key}：应接管', actual: reasonOf(result));
      logs.addAll(h.core.logs);
      continue;
    }
    check.that(true, '${entry.key}：接管成功');
    final List<Object?> sent = _summaryMessages(h);
    final List<Object?> out = payload['messages'] is List
        ? payload['messages'] as List<Object?>
        : <Object?>[];
    check.that(
      structureProblems(sent).isEmpty,
      '${entry.key}：总结输入结构合法',
      actual: rendered(structureProblems(sent)),
    );
    check.that(
      structureProblems(out).isEmpty,
      '${entry.key}：回包上下文结构合法',
      actual: rendered(structureProblems(out)),
    );
    check.that(
      asMap(sent.isEmpty ? null : sent.last)['role'] == 'user',
      '${entry.key}：总结输入末端是 user 指令',
    );
    check.check(payload['covered_message_count'], 12, '${entry.key}：covered = 原文总条数');
    logs.addAll(h.core.logs);
  }
}

/// ⑧c **超大输入照样接管**：这里刻意不设“输入太大就少压一点”的自适应。
Future<void> _checkHugeInput(SelfTest check, List<String> logs) async {
  final List<Map<String, dynamic>> huge = wireFixture(rounds: 2);
  huge.insert(
    2,
    <String, dynamic>{'role': 'user', 'content': '粘了一整份日志：${'x' * 300000}'},
  );
  final _Harness h = _Harness(testOptions());
  final Map<String, dynamic> result = await h.drive(huge);
  final Object? payload = payloadOf(result);
  check.that(
    payload is Map,
    '超大输入应照常接管（自适应只会多留原文、压得更少，方向是反的）',
    actual: reasonOf(result),
  );
  final CompactPlugin judge = bare();
  final int cut = judge.wireCut(huge, judge.options.keepRounds);
  check.check(_summaryMessages(h).length, cut + 1, '总结输入只到切点（不超发一个字）');
  if (payload is Map) {
    final List<Object?> out = payload['messages'] is List
        ? payload['messages'] as List<Object?>
        : <Object?>[];
    check.that(
      structureProblems(out).isEmpty,
      '超大输入的回包结构仍合法',
      actual: rendered(structureProblems(out)),
    );
  }
  logs.addAll(h.core.logs);
}

/// ⑧ 必读上限：`max_files` 卡在读取**之前**（不是读完再丢）。
Future<void> _checkMaxFiles(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(testOptions(maxFiles: 2));
  final Map<String, dynamic> result = await h.drive(wireFixture());
  check.that(payloadOf(result) is Map, 'max_files=2 仍应接管', actual: reasonOf(result));
  check.check(h.commands(kCommandFsRead).length, 2, 'max_files=2 就只读 2 个文件');
  logs.addAll(h.core.logs);
}

/// ⑨ 非本点位：一律“不改动”（不接管也不花一分钱）。
Future<void> _checkOtherPoint(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(testOptions());
  final Map<String, dynamic> result = await h.driveParams(<String, dynamic>{
    'station_id': 'system.relay.prompt.system',
    'payload': <String, dynamic>{'request': <String, dynamic>{'messages': wireFixture()}},
  });
  check.that(payloadOf(result) == null, '非本点位请求不该回填');
  check.check(h.commands().length, 0, '非本点位一个命令都不下（误接会让提示词点位没响应）');
  check.check(h.plugin.counters['requests'], 0, '非本点位不计入经手次数');
  logs.addAll(h.core.logs);
}

/// ⑪ `--dry-run`：拼好了但按不接管返回（面板要留下痕，核心走内置）。
Future<void> _checkDryRun(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(testOptions(dryRun: true));
  final Map<String, dynamic> result = await h.drive(wireFixture());
  check.that(payloadOf(result) == null, '--dry-run 应回 null');
  check.that(reasonOf(result).contains('[dry_run]'), '--dry-run 的原因要能看出是故意不接管', actual: reasonOf(result));
  check.check(h.commands(kCommandLlmCall).length, 1, '--dry-run 照样花一次总结调用（验的就是真链路）');
  logs.addAll(h.core.logs);
}

/// 面板视图里那张表格节点（没有就空表）。
Map<String, dynamic> panelTable(Map<String, Object?> view) {
  final Object? children = view['children'];
  if (children is! List) return <String, dynamic>{};
  for (final Object? child in children) {
    if (child is Map && asString(asMap(child)['type']) == 'table') return asMap(child);
  }
  return <String, dynamic>{};
}

/// ⑩ 面板申报：`ui/manifest` 只发一次、只有一条 **activity** 槽位（活动栏图标 + 左栏
/// 整页），视图只能用受限控件集，而且不能超核心那个 64 KB 整帧上限。
Future<void> _checkPanelDeclare(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(testOptions());
  await h.hello();
  check.that(
    await h.waitFrames(Ui.manifest),
    'hello 之后立刻申报面板（不等第一次压缩：装机就能看见这个图标）',
  );
  check.check(h.core.outgoing(Ui.manifest).length, 1, 'ui/manifest 只发一次（前端重连由核心按缓存补发）');
  final Map<String, dynamic> slot = h.firstSlot();
  check.check(slot['slot'], 'activity', '槽位类型 = activity（活动栏图标与左栏整页是同一个槽位）');
  check.check(slot['slot_key'], 'compact.activity.1', 'slot_key 用核心给的 plugin_id 拼');
  check.that(
    asString(slot['title']).isNotEmpty && asString(slot['icon']).isNotEmpty,
    '槽位必须有 title / icon（图标名走前端白名单，未知名会回退扩展图标）',
  );
  final List<String> problems = validateUiView(slot['view']);
  check.that(problems.isEmpty, '面板视图只用受限控件集（没有 webview、不执行插件 JS）', actual: rendered(problems));
  check.that(
    rendered(slot['view']).contains('compact_now'),
    '面板有「立即压缩一次」按钮（action_id=compact_now）',
  );
  final int bytes = utf8.encode(json.encode(slot)).length;
  check.that(
    bytes <= kMaxManifestBytes,
    '单槽位声明不能超 64 KB（超了核心整帧拒收，面板直接没内容）',
    actual: '$bytes bytes',
  );
  final String declared = rendered(slot['view']);
  check.that(
    declared.contains('还没有压缩记录'),
    '空态要说清接下来怎么办（对着空表格用户只会以为插件坏了）',
  );
  final Map<String, dynamic> table = panelTable(asMap(slot['view']));
  check.check(table['columns'], kPanelColumns, '列名与面板共用这一份真源（防两边漂）');
  final Object? rows = table['rows'];
  check.that(rows is List && rows.length == 1, '没记录时表格仍渲染一行占位（列名先亮出来）');
  check.check(h.plugin.records, <Object?>[], '刚起来的插件不该有压缩记录');
  check.check(h.plugin.usageRecords.length, 0, '刚起来时用量表为空（不凭空造记录）');
  // 订阅也走真帧面：这三处写错就是“插件一直在跑但永远不被叫到”。
  final List<Map<String, dynamic>> subs = h.core.outgoing(M.stationSubscribe);
  check.check(subs.length, 1, '握手后恰好一次订阅（成功就不重试）');
  if (subs.isNotEmpty) {
    final Map<String, dynamic> sub = frameParams(subs.first);
    check.check(sub['point'], kPointContextCompactAlias, '订阅用点位别名（核心按别名解析）');
    check.check(sub['replace'], false, 'replace:false —— 绝不抢占别人的订阅');
    check.check(sub['station'], 'relay', '订阅而不是注册：中转点是核心的，插件只加入');
  }
  check.that(await h.waitFrames(Ui.update), '订阅结果刷进面板（“为什么没接管”的答案常在这一行）');
  check.that(
    rendered(h.lastView(Ui.update)).contains('已订阅'),
    '订上了就写「已订阅」',
    actual: _clip(rendered(h.lastView(Ui.update)), 200),
  );
  logs.addAll(h.core.logs);
}

/// ⑩b `--no-panel`：一帧 UI 都不发（只想后台跑压缩时用）。
Future<void> _checkSilentPanel(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(testOptions(noPanel: true));
  await h.hello();
  check.that(await h.waitFrames(M.stationSubscribe), '--no-panel 不影响订阅');
  await h.settle();
  check.that(h.uiQuiet, '--no-panel 时一帧 UI 都不发');
  final Map<String, dynamic> result = await h.drive(wireFixture());
  check.that(payloadOf(result) is Map, '--no-panel 不影响压缩本身', actual: reasonOf(result));
  await h.settle();
  check.that(h.uiQuiet, '接管了也不因 --no-panel 发 UI 帧');
  logs.addAll(h.core.logs);
}

/// ⑪ 压缩之后面板要如实刷新；⑧b **不接管也要留痕**。
Future<void> _checkPanelAfterWork(SelfTest check, List<String> logs) async {
  final _Harness taken = _Harness(testOptions());
  await taken.drive(wireFixture());
  check.that(await taken.waitFrames(Ui.update), '接管一次压缩后应发一帧 ui/update 刷新面板');
  final Map<String, dynamic> update = frameParams(taken.core.outgoing(Ui.update).last);
  check.check(update['slot_key'], 'compact.activity.1', 'ui/update 按 slot_key 整块替换那一个槽位');
  final Map<String, Object?> view = asMap(update['view']);
  check.that(validateUiView(view).isEmpty, '刷新后的面板视图仍合法', actual: rendered(validateUiView(view)));
  final String text = rendered(view);
  for (final String must in <String>['relay', '"12"', 'ms']) {
    check.that(text.contains(must), '接管后面板表里要能看到 $must', actual: _clip(text, 200));
  }
  check.that(
    text.contains('接管 1'),
    '概览里能看到本插件接管了几次（不只是“最近一条”）',
    actual: _clip(text, 200),
  );
  final _Harness declined = _Harness(testOptions());
  final Map<String, dynamic> params = stationParams(wireFixture());
  mutablePayload(params).remove('request');
  await declined.driveParams(params);
  check.that(declined.plugin.records.isNotEmpty, '不接管也必须记进面板');
  if (declined.plugin.records.isNotEmpty) {
    check.that(
      asString(declined.plugin.records.first['note']).contains('未接管'),
      '不接管的 note 里要能看到原因（用户踩到的正是这个）',
      actual: asString(declined.plugin.records.first['note']),
    );
  }
  check.that(
    validateUiView(declined.lastView(Ui.update)).isEmpty,
    '不接管后的面板视图也合法',
    actual: rendered(validateUiView(declined.lastView(Ui.update))),
  );
  logs.addAll(<String>[...taken.core.logs, ...declined.core.logs]);
}

/// ⑫ 面板动作回传：核心发的是 **event 通知**（判据在 params.event），同时兼容裸 method。
Future<void> _checkUiActionShapes(SelfTest check, List<String> logs) async {
  final _Harness eventForm = _Harness(testOptions());
  await eventForm.uiAction(<String, dynamic>{
    'event': kEventUiAction,
    'slot_key': 'compact.activity.1',
    'action_id': 'refresh',
    'payload': <String, dynamic>{},
  });
  check.that(
    eventForm.core.outgoing(Ui.update).isNotEmpty,
    'event 形态的面板动作要处理（判 `method == "plugin_ui_action"` 会永远不命中）',
  );
  final _Harness bareForm = _Harness(testOptions());
  await bareForm.uiAction(<String, dynamic>{'action_id': 'refresh'}, bare: true);
  check.that(
    bareForm.core.outgoing(Ui.update).isNotEmpty,
    '裸 method=plugin_ui_action 形态也兼容（老核心 / 直连测试点按钮不能没反应）',
  );
  final _Harness noise = _Harness(testOptions());
  noise.core.notify(M.event, <String, dynamic>{
    'event': 'agent.tool_call',
    'agent_id': 'agt_9',
    'session_id': 'ses_9',
  });
  await noise.settle();
  check.that(noise.uiQuiet, '非 UI 事件一帧 UI 都不造（压缩不靠事件驱动）');
  check.check(noise.plugin.records, <Object?>[], '非 UI 事件不该产生压缩记录');
  check.check(noise.plugin.identity['agent_id'], 'agt_9', 'agent 事件用来学「最近会话」（按钮没身份时靠它）');
  check.check(noise.plugin.identity['session_id'], 'ses_9', '会话 id 也一起学');
  final _Harness unknown = _Harness(testOptions());
  await unknown.uiAction(<String, dynamic>{'event': kEventUiAction, 'action_id': 'nope'});
  check.that(
    unknown.core.logs.any((String line) => line.contains('未知的面板动作')),
    '未知 action 必须留一行日志（不静默），但不算错误',
  );
  check.that(unknown.core.outgoing(Ui.update).isEmpty, '未知 action 不刷面板');
  logs.addAll(<String>[...eventForm.core.logs, ...bareForm.core.logs, ...noise.core.logs, ...unknown.core.logs]);
}

/// ⑬ 「立即压缩一次」：经执行站 `agent.compact`，回执要落进面板。
Future<void> _checkManualCompact(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(testOptions());
  await h.hello();
  h.plugin.startManualCompact(<String, dynamic>{
    'agent_id': 'agt_1',
    'session_id': 'ses_1',
    'payload': <String, dynamic>{},
  });
  check.that(await h.waitCommands(kCommandAgentCompact), '「立即压缩一次」经执行站 agent.compact');
  check.check(h.commands(kCommandAgentCompact).length, 1, '一次点击只发一条 agent.compact');
  final Map<String, dynamic> call = h.commands(kCommandAgentCompact).first;
  check.check(frameArguments(call)['agent_id'], 'agt_1', 'agent.compact 的 arguments 带身份');
  check.check(call['session_id'], 'ses_1', 'params 顶层也带（核心按它解析 team / mode）');
  check.that(await h.waitRecords(1), '核心回执要落进面板');
  if (h.plugin.records.isNotEmpty) {
    final Map<String, Object?> record = h.plugin.records.first;
    check.check(record['source'], 'builtin', '回执来源 builtin（那是核心那一跳的账，不是插件自己压的）');
    check.check(record['covered'], 6, 'summarized_messages 进「覆盖条数」列');
  }
  check.that(
    rendered(h.lastView(Ui.update)).contains('builtin'),
    '手动压缩后面板刷新出 builtin 来源',
    actual: _clip(rendered(h.lastView(Ui.update)), 200),
  );
  check.that(
    !h.plugin.status.containsKey('manual'),
    '收尾要把「正在压缩…」摘掉（不然那一行会永远挂在面板上）',
    actual: rendered(h.plugin.status),
  );
  logs.addAll(h.core.logs);
}

/// ⑬b 降级 / 未压缩 / 中转未接管 / 命令失败：四种“不顺利”都必须在面板上有原因。
Future<void> _checkManualNotes(SelfTest check, List<String> logs) async {
  final List<Map<String, Object?>> cases = <Map<String, Object?>>[
    <String, Object?>{
      'label': '降级',
      'must': '限流',
      'compactResult': <String, Object?>{
        'success': true,
        'compressed': true,
        'degraded': true,
        'degraded_reason': '端点 429：限流',
        'summarized_messages': 30,
        'source': 'builtin',
      },
    },
    <String, Object?>{
      'label': '未压缩',
      'must': 'too_few_messages',
      'compactResult': <String, Object?>{
        'success': true,
        'compressed': false,
        'reason': 'too_few_messages',
      },
    },
    <String, Object?>{
      'label': '中转未接管（可选键 relay_skip_reason）',
      'must': '没订上',
      'compactResult': <String, Object?>{
        'success': true,
        'compressed': true,
        'source': 'builtin',
        'summarized_messages': 8,
        'relay_skip_reason': '中转站没订上 compact 点位',
      },
    },
    <String, Object?>{'label': '命令失败', 'must': '失败', 'fail': true},
  ];
  for (final Map<String, Object?> item in cases) {
    final bool fail = item['fail'] == true;
    final _Harness h = _Harness(
      testOptions(),
      compactResult: item['compactResult'] is Map
          ? asMap(item['compactResult'])
          : null,
      failCommands: fail ? const <String>{kCommandAgentCompact} : const <String>{},
    );
    h.plugin.startManualCompact(<String, dynamic>{
      'agent_id': 'agt_1',
      'session_id': 'ses_1',
      'payload': <String, dynamic>{},
    });
    await h.waitRecords(1);
    final String note = h.plugin.records.isEmpty ? '' : asString(h.plugin.records.first['note']);
    check.that(
      note.contains(asString(item['must'])),
      '${item['label']}的原因必须出现在面板记录里',
      actual: _clip(note, 140),
    );
    logs.addAll(h.core.logs);
  }
  // ⑬c 没有 agent 就不猜：如实写进面板，不静默。
  final _Harness blind = _Harness(testOptions());
  await blind.uiAction(<String, dynamic>{
    'event': kEventUiAction,
    'action_id': 'compact_now',
    'payload': <String, dynamic>{},
  });
  check.check(blind.commands(kCommandAgentCompact).length, 0, '没有 agent 时不该猜一个目标去压缩');
  check.that(
    blind.plugin.records.isNotEmpty &&
        asString(blind.plugin.records.first['note']).contains('不知道目标 agent'),
    '没有 agent 必须如实写进面板',
    actual: blind.plugin.records.isEmpty
        ? '一条记录都没有'
        : asString(blind.plugin.records.first['note']),
  );
  // 动作帧带了身份就该照做（前端按当前上下文填的）。
  final _Harness identified = _Harness(testOptions());
  await identified.uiAction(<String, dynamic>{
    'event': kEventUiAction,
    'action_id': 'compact_now',
    'agent_id': 'agt_7',
    'session_id': 'ses_7',
    'payload': <String, dynamic>{},
  });
  check.that(
    identified.commands(kCommandAgentCompact).isNotEmpty,
    '动作帧带身份时「立即压缩一次」应真的发出命令',
  );
  if (identified.commands(kCommandAgentCompact).isNotEmpty) {
    check.check(
      asString(identified.commands(kCommandAgentCompact).first['agent_id']),
      'agt_7',
      '按钮带的身份直接进 params 顶层',
    );
  }
  logs.addAll(<String>[...blind.core.logs, ...identified.core.logs]);
  // ⑬d **`ok:false` 没带原因也算失败**（骨架的 command() 判据有两道，不只看 error）：
  // 漏了这一条的现场是“插件以为命令成功了”，而 payload 里什么也没有。
  final _Harness noReason = _Harness(testOptions());
  final Map<String, Object?> silent = await noReason.plugin.exec(
    kCommandFsRead,
    <String, dynamic>{'path': 'no_reason.md'},
    <String, dynamic>{'agent_id': 'agt_1', 'session_id': 'ses_1'},
  );
  check.check(silent['ok'], false, 'ok:false 且没写 error，也必须判成失败');
  check.that(
    asString(silent['error']).contains('ok:false'),
    '补出来的原因要说得出“核心回 ok:false 且没有给出原因”（不许抛一个空消息）',
    actual: asString(silent['error']),
  );
  logs.addAll(noReason.core.logs);
}

/// ⑫ 指令文本：占位已换、那个字面 `\n` 真的保住了（Python 版把它变成了真换行）。
Future<void> _checkInstructionText(SelfTest check, List<String> logs) async {
  final CompactPlugin judge = bare();
  final String instruction = judge.summaryInstruction;
  check.that(instruction.contains('不超过 11 个'), '@@MAX_FILES@@ 已换成实际上限');
  check.that(!instruction.contains('@@MAX_FILES@@'), '不许把占位符原样发给模型');
  check.that(
    instruction.contains(r'\n`）'),
    '指令里“要换行就写 \\n”那个字面量保住了（Python 在 `"""…"""` 里把它变成了真换行）',
  );
  check.that(
    instruction.contains('只输出一个 json 对象'),
    '输出形状写死在指令里（text 形态下没有 response_format 强约束）',
  );
  check.that(
    !kRepairInstruction.contains('max_tokens'),
    '修复指令里不提 max_tokens（设小了就是下一次截断）',
  );
}

/// ⑭ **核心捣来的用量**（`recent_usage`）：来源 / 耗时 / token 都要对，且重复喂同一批
/// （滚动窗口每次请求都会重发）不能刷屏。⑭b 没捣用量时面板照常工作、**不凭空造记录**。
Future<void> _checkUsageFeed(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(testOptions());
  final Map<String, dynamic> params = stationParams(wireFixture());
  mutablePayload(params)['usage_file'] = 'E:/data/agt_1/ses_1/usage.jsonl';
  mutablePayload(params)['recent_usage'] = usageFixture();
  await h.driveParams(params);
  final List<String> labels = h
      .plugin
      .collectRecords()
      .map((Map<String, Object?> r) => asString(r['source']))
      .toList();
  for (final String want in <String>['relay', 'builtin', 'llm.call', 'plugin']) {
    check.check(
      labels.where((String l) => l == want).length,
      1,
      '面板来源列恰好一条 $want（relay=本插件接管，其余来自账本）',
    );
  }
  check.that(!labels.contains('turn'), '对话自己的跳（source=turn）不进压缩面板');
  check.that(
    h.plugin.usageFile.endsWith('usage.jsonl'),
    '载荷里的 usage_file 要记住（排障时要知道去哪翻账）',
    actual: h.plugin.usageFile,
  );
  final String view = rendered(h.plugin.panelView());
  for (final String must in <String>[
    '1.2k',
    '缓存 900',
    '输出 120',
    '1.8 s',
    '16:31:55',
    '（估算）',
  ]) {
    check.that(view.contains(must), '面板视图里要能看到 $must', actual: _clip(view, 200));
  }
  check.that(
    !view.contains('缓存 0'),
    'cached_tokens=null 不能显示成 0（核心的口径：null = 端点没给这个字段）',
  );
  check.that(
    !view.contains('最近原因：用量'),
    '概览的「最近原因」不该拿用量行的说明充当原因（那是 token 账，不是原因）',
  );
  final int before = h.plugin.usageRecords.length;
  check.check(
    h.plugin.ingestRecentUsage(usageFixture()),
    0,
    '滚动窗口重发同一批必须全部去重（不然几轮之后面板被同一批记录刷屏）',
  );
  check.check(h.plugin.usageRecords.length, before, '去重后条数不变');
  logs.addAll(h.core.logs);

  // ⑭b 核心没捣用量（未接线 / 账本还不存在）
  final _Harness plain = _Harness(testOptions());
  await plain.drive(wireFixture());
  check.check(
    plain
        .plugin
        .collectRecords()
        .map((Map<String, Object?> r) => asString(r['source']))
        .toList(),
    <String>['relay'],
    '没有 recent_usage 时不该多出记录（来源列不会凭空多出 builtin）',
  );
  check.that(
    !rendered(plain.plugin.panelView()).contains('用量记录'),
    '没有用量时概览里不该提用量条数',
  );
  logs.addAll(plain.core.logs);
}

/// ⑭c 上限（账本可能很长）与 ⑭d 离线回放（`--usage-jsonl`）。
Future<void> _checkUsageBulkAndOffline(SelfTest check, List<String> logs) async {
  final List<Map<String, Object?>> bulk = <Map<String, Object?>>[
    for (int index = 0; index < 300; index++)
      <String, Object?>{
        'at':
            '2026-10-03T${(4 + index ~/ 60).toString().padLeft(2, '0')}:'
            '${(index % 60).toString().padLeft(2, '0')}:00.000000',
        'source': 'compact',
        'model': 'demo-model',
        'prompt_tokens': index,
        'cached_tokens': null,
        'completion_tokens': 1,
        'estimated': false,
        'duration_ms': 10,
      },
  ];
  final _Harness h = _Harness(testOptions());
  final Map<String, dynamic> params = stationParams(wireFixture());
  mutablePayload(params)['recent_usage'] = bulk;
  await h.driveParams(params);
  check.that(
    h.plugin.usageRecords.length <= kMaxUsageRecords,
    '内部用量记录有界（面板只要几行，不能拿插件当账本使）',
    actual: '${h.plugin.usageRecords.length} 条',
  );
  final Object? rows = panelTable(h.plugin.panelView())['rows'];
  check.check(
    rows is List ? rows.length : -1,
    h.plugin.options.panelRecords,
    '面板只显 panel_records 条（列窄，多了只是闪）',
  );
  logs.addAll(h.core.logs);

  // ⑭d 离线回放：按同一张字段表归一；坏行 / 缺时间字段的行都不能漏进面板。
  final Directory dir = Directory.systemTemp.createTempSync('compact_selftest_');
  try {
    final File file = File(
      '${dir.path}${Platform.pathSeparator}usage.jsonl',
    );
    file.writeAsStringSync(
      <String>[
        ...usageFixture().map((Map<String, Object?> item) => json.encode(item)),
        '这不是 JSON',
        '{"source": "compact"}', // 缺 at：连时间都读不出来 ⇒ 不显示
      ].join('\n'),
      encoding: utf8,
    );
    final _Harness offline = _Harness(testOptions(usageJsonl: file.path));
    final List<String> labels =
        offline
            .plugin
            .collectRecords()
            .map((Map<String, Object?> r) => asString(r['source']))
            .toList()
          ..sort();
    check.check(
      labels,
      <String>['builtin', 'llm.call', 'plugin'],
      '离线回放的来源列（turn / 坏行 / 缺时间都被丢掉）',
    );
    final Object? offlineRows = panelTable(offline.plugin.panelView())['rows'];
    check.check(
      offlineRows is List ? offlineRows.length : -1,
      3,
      '离线回放只渲染三行（坏行不能把面板弄崩）',
    );
    check.that(
      !rendered(offline.plugin.panelView()).contains('这不是 JSON'),
      '非 JSON 的行不能出现在面板上',
    );
    logs.addAll(offline.core.logs);
  } finally {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // 临时目录删不掉不算自检失败（用例本身已经跑完）。
    }
  }
  final _Harness missing = _Harness(
    testOptions(usageJsonl: '不存在的目录${Platform.pathSeparator}usage.jsonl'),
  );
  check.check(
    missing.plugin.collectRecords(),
    <Object?>[],
    'usage.jsonl 不存在时静默返回空（它的问题不该让面板报错）',
  );
}

/// ⑮ 状态行与节流：订阅结果必须看得见，但左栏不能刷成录频。
Future<void> _checkStatusOnPanel(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(testOptions());
  h.plugin.setStatus(false, '未订上点位：$kPointContextCompact');
  final String text = rendered(h.lastView(Ui.update));
  check.that(text.contains('未订上点位'), '订阅失败必须显示到面板上', actual: _clip(text, 200));
  check.check(h.plugin.records, <Object?>[], '状态刷新不该凭空造出一条压缩记录');
  final int before = h.core.outgoing(Ui.update).length;
  h.plugin.updatePanel();
  h.plugin.updatePanel();
  check.check(
    h.core.outgoing(Ui.update).length,
    before,
    '500ms 内的连续刷新要节流（压缩可能连着触发，左栏整块重建只是闪）',
  );
  h.plugin.updatePanel(force: true);
  check.check(
    h.core.outgoing(Ui.update).length,
    before + 1,
    'force 能绕过节流（按钮点下去必须立刻看见反应）',
  );
  logs.addAll(h.core.logs);
}

/// ⑮b 订阅一直失败：重试有上限，最后那一行必须落到面板上。
Future<void> _checkSubscribeFailureVisible(SelfTest check, List<String> logs) async {
  final _Harness h = _Harness(testOptions(), refuseSubscribe: true);
  await h.hello();
  check.that(
    await h.waitFrames(M.stationSubscribe, atLeast: 5, ms: 12000),
    '订阅失败要有限重试（核心可能还没把站点挂好），而且**不会无限重试**',
    actual: '${h.core.outgoing(M.stationSubscribe).length} 次',
  );
  check.that(
    await h.waitViewText(Ui.update, '未订上点位', ms: 15000),
    '连续失败后面板写「未订上点位」（“为什么没接管”的答案就在这一行）',
    actual: _clip(rendered(h.lastView(Ui.update)), 200),
  );
  check.check(h.plugin.records, <Object?>[], '订阅失败不造压缩记录');
  logs.addAll(h.core.logs);
}

/// ⑯ **钱别白花**：总结回包坏掉时的三段抢救（本地修 → 一次修 json → 放弃）。
Future<void> _checkRecoveryPaths(SelfTest check, List<String> logs) async {
  const String badText =
      '好的，以下是压缩结果：\n'
      '{"background": "背景", "trajectory": "轨迹", '
      '"files_changed": [], "required_files": [],}\n（完）';
  final _Harness salvage = _Harness(
    testOptions(),
    llmSeq: <Map<String, dynamic>>[_Harness.badText(badText)],
  );
  final Map<String, dynamic> a = await salvage.drive(wireFixture());
  final Object? ap = payloadOf(a);
  check.that(
    ap is Map,
    '⑯a 本地能修好的回包应接管（不然整笔前缀调用白花钱）',
    actual: reasonOf(a),
  );
  check.that(
    ap is Map && rendered(ap).contains('由本地结构修复得到'),
    '⑯a 抢救回来的摘要必须显式标注（不能让下一轮以为它完整）',
  );
  check.check(salvage.commands(kCommandLlmCall).length, 1, '⑯a 本地能修好就不该再调模型');
  check.check(salvage.plugin.counters['salvaged'], 1, '⑯a salvage 计数进 counters');
  check.that(
    salvage.core.logs.any((String line) => line.contains('正文 ${badText.length} 字')),
    '⑯a “调用失败”回包里的原文必须走到插件（known-issues #31：报“原文 0 字”就是丢了 payload）',
    actual: salvage.core.logs
        .where((String line) => line.contains('正文'))
        .join(' | '),
  );
  logs.addAll(salvage.core.logs);

  const String truncatedText = '{"background": "背景", "trajectory": "轨迹被截断在';
  final _Harness repair = _Harness(
    testOptions(),
    llmSeq: <Map<String, dynamic>>[
      _Harness.badText(truncatedText, truncated: true),
      _Harness.repaired(<String, Object?>{
        'complete': false,
        'reason': '在 trajectory 中途截断',
        'summary': <String, Object?>{
          'background': '背景',
          'trajectory': '轨迹',
          'files_changed': <Object?>[],
          'required_files': <Object?>[],
        },
      }),
    ],
  );
  final Map<String, dynamic> b = await repair.drive(wireFixture());
  final String body = rendered(payloadOf(b));
  check.that(payloadOf(b) is Map, '⑯b 修复调用成功后应接管', actual: reasonOf(b));
  check.that(
    body.contains('由一次 JSON 修复调用补全'),
    '⑯b 修复得到的摘要要标注来源',
    actual: _clip(body, 200),
  );
  check.that(
    body.contains('不完整') && body.contains('在 trajectory 中途截断'),
    '⑯b 模型判定的截断原因要进摘要（只写“可能不完整”等于没说）',
  );
  check.check(repair.commands(kCommandLlmCall).length, 2, '⑯b 恰好 2 次 llm.call（总结 + 修复，最多一次）');
  check.check(repair.plugin.counters['repaired'], 1, '⑯b repair 计数进 counters');
  final List<Map<String, dynamic>> llmCalls = repair.commands(kCommandLlmCall);
  if (llmCalls.length >= 2) {
    final Map<String, dynamic> repairArgs = frameArguments(llmCalls.last);
    check.that(
      !repairArgs.containsKey('response_format'),
      '⑯b 修复调用不发 response_format（站点缺省硬设 json_object，正好强制 JSON）',
    );
    check.that(
      !repairArgs.containsKey('tools'),
      '⑯b 修复调用不透传 tools（这里没有前缀要对齐）',
    );
    check.that(
      !repairArgs.containsKey('max_tokens'),
      '⑯b 修复调用不设 max_tokens（设小了就是下一次截断、钱又白花）',
    );
    final List<Object?> repairMessages = repairArgs['messages'] is List
        ? repairArgs['messages'] as List<Object?>
        : <Object?>[];
    check.that(
      repairMessages.length == 1 &&
          asString(asMap(repairMessages.first)['content']).contains(truncatedText),
      '⑯b 修复调用把原文原样带上（判完整性靠的就是它）',
      actual: '${repairMessages.length} 条消息',
    );
  }
  logs.addAll(repair.core.logs);

  final _Harness giveup = _Harness(
    testOptions(),
    llmSeq: <Map<String, dynamic>>[
      _Harness.badText(truncatedText, truncated: true),
      <String, dynamic>{
        'command': kCommandLlmCall,
        'ok': false,
        'mount_id': 'harness',
        'payload': null,
        'error': '端点 429：限流',
      },
    ],
  );
  final Map<String, dynamic> c = await giveup.drive(wireFixture());
  check.that(payloadOf(c) == null, '⑯c 抢救失败时应不接管（核心内置兑底，上下文不会丢）');
  check.that(
    reasonOf(c).contains('repair_failed'),
    '⑯c 不接管的回包要带可读原因（核心据此写日志与会话提示）',
    actual: reasonOf(c),
  );
  check.that(
    giveup.plugin.records.isNotEmpty &&
        asString(giveup.plugin.records.first['note']).contains('repair_failed'),
    '⑯c 同一个原因也进面板（三处落点：面板 / 日志 / 回包）',
    actual: giveup.plugin.records.isEmpty
        ? '一条记录都没有'
        : asString(giveup.plugin.records.first['note']),
  );
  logs.addAll(giveup.core.logs);

  // 本地修复这一段的能力边界：只清结构噪声，**不猜内容**。
  check.that(CompactPlugin.salvageJson('{"a": 1,}') != null, '本地修复能吃掉尾逗号');
  check.that(
    CompactPlugin.salvageJson('这是说明：{"background": "b"}以上') != null,
    '本地修复能从夹了解释的正文里截出 json',
  );
  check.that(
    CompactPlugin.salvageJson('﻿{"a": 1}\u200b') != null,
    '本地修复能清 BOM / 零宽字符',
  );
  check.that(
    CompactPlugin.salvageJson('{"a": ') == null,
    '半截 json **不硬救**：“是不是被截断、要不要补全”交给一次显式的小调用判断',
  );
}
