/// **UI 自有契约**（零依赖）：从桌面仓协议包手抄的一份子集，**不从核心生成**。
///
/// UI 迁入插件仓后不 import `tree_protocol`（插件仓可单独 clone / 编译）：
/// 这里只保留 UI 实际用到的路径、帧名、终端/站点模型与序号判据。
/// 一致性靠「核心面对外冻结（只增不改）+ 黑盒一致性套件」：
/// `packages/tree_core/test/ui_contract_blackbox_test.dart`（桌面仓）。
///
/// 改动纪律：新增只能加新常量/新帧名；改语义必须升 `uiContractVersion`
/// 并同步核心的 `/api/meta.ui_contract`。
library;

/// UI 与核心共同的契约版本（与核心 `/api/meta.ui_contract` 同串）。
const String uiContractVersion = '1.0';

// ── api_paths.dart ─────────────────────────────────────────────
/// REST 路径（UI 实际调用的 26 条：插件面板 / 发布源 / 终端与会话）。
///
/// 只收 UI 真会调的路径：核心面已收窄（S7 删掉 store / logs / data-collection），
/// 协议包里那些"核心自己有、界面不调"的路径不该跟着 UI 搬进插件仓。
///
/// 纪律：**只增不改**。改名或改语义等于换契约，必须升 [uiContractVersion]
/// 并同步核心的 `/api/meta.ui_contract`。
abstract final class ApiPaths {
  // ── agent（会话消息 / 取消 / 子代理 / SSH 重连）──────────────────────
  static const String agentMessages = '/api/agents/{agentId}/messages';
  static const String agentCancel = '/api/agents/{agentId}/cancel';
  static const String agentSshReconnect = '/api/agents/{agentId}/ssh/reconnect';
  static const String agentSubagents = '/api/agents/{agentId}/subagents';
  static const String agentSubagentTranscript =
      '/api/agents/{agentId}/subagents/{subagentId}/transcript';

  // ── 文件 ──────────────────────────────────────────────────────────────
  static const String files = '/api/files/{workspaceId}';
  static const String fileMkdir = '/api/files/{workspaceId}/mkdir';
  static const String fileRename = '/api/files/{workspaceId}/rename';

  /// 删除与 [files] 是同一条路径（REST 按方法区分），另起名字只为调用点可读。
  static const String fileDelete = files;

  // ── 运行监督 ──────────────────────────────────────────────────────────
  static const String toolsRunning = '/api/tools/running';
  static const String toolsRunningClose = '/api/tools/running/{handle}/close';

  // ── 设置（传输 / 判活 / 插件发布源）───────────────────────────────────
  static const String settingsFrameRate = '/api/settings/frame-rate';
  static const String settingsHeartbeatInterval =
      '/api/settings/heartbeat-interval';
  static const String settingsPluginReleaseSources =
      '/api/settings/plugin-release-sources';
  static const String settingsPluginReleaseSourcesTest =
      '/api/settings/plugin-release-sources/test';

  // ── 插件管理（面板 / 发布仓库 / 本地安装 / 站点详情）──────────────────
  static const String pluginConfigs = '/api/plugin/configs';
  static const String pluginBuiltins = '/api/plugin/builtins';
  static const String pluginRelease = '/api/plugin/release';
  static const String pluginReleaseRefresh = '/api/plugin/release/refresh';
  static const String pluginReleaseInstall =
      '/api/plugin/release/{pluginId}/install';
  static const String pluginReleaseUninstall =
      '/api/plugin/release/{pluginId}/uninstall';
  static const String pluginInstallLocal = '/api/plugin/install/local';
  static const String pluginStation = '/api/plugin/stations/{stationId}';
  static const String pluginStationConfig =
      '/api/plugin/stations/{stationId}/config';
  static const String pluginStationSubscriber =
      '/api/plugin/stations/{stationId}/subscribers/{subscriberKey}';

  // ── 发现面 ────────────────────────────────────────────────────────────
  /// 发现面聚合（核心永久面）：UI 用来确认契约版本与可用路由。
  static const String meta = '/api/meta';
}

// ── ws_frame.dart ─────────────────────────────────────────────
/// WS 传输层分片参数（核心进程与前端共用）。
///
/// 现状 server 侧由 `ws_manager` 的 `_FRAME_*` 常量产出分帧，前端
/// `websocket_service.dart` 负责重组。桌面分支中核心进程成为产出方，
/// 两侧必须使用**同一组阈值**，故上移到协议包作为单一事实来源。
///
/// 分帧三件套的类型名见 [WsOutboundType.frameBegin] /
/// [WsOutboundType.frameChunk] / [WsOutboundType.frameEnd]。

/// 大帧分片阈值（UTF-8 字节）：单帧编码后超过该值即分片传输。
///
/// 取 12 MiB：留出余量覆盖 JSON 转义膨胀，同时显著低于任何合理单帧上限。
const int kWsFrameChunkThresholdBytes = 12 * 1024 * 1024;

/// 单个分片的最大 UTF-8 字节数（按字符边界回退，不切断码点）。
const int kWsFrameChunkPartBytes = 4 * 1024 * 1024;

/// 接收侧在途分片序列的保活时限：超时未收齐即丢弃（防内存泄漏与永久悬挂）。
const Duration kWsFrameChunkTtl = Duration(seconds: 30);

// ── ws_stream_seq.dart ─────────────────────────────────────────────
/// 流式增量帧（`msg_chunk`）的**单调序号**：断线补发帧「重播去重」的精确判据
/// （M9 Wave 3-H 待办 3 的收口，协议侧的单一事实来源）。
///
/// ## 为什么需要序号
/// 核心在链路失活 / 前端断开期间把没送出去的广播帧登记进待补发队列，重连后按保活
/// 节拍**原样重播**（帧没有 TTL）。而 `msg_chunk` 在前端是**追加**语义
/// （`content += chunk`），天然不幂等：同一片段送到两次就渲染两遍。段的 `message id`
/// 在整个流式周期内不变，重播帧与正常帧在 id 上完全一样 —— 所以只按 id 去重
/// **识别不出**"已经渲染过的同一片段又被重播"。
///
/// 加上本字段后判据升级为 `(message id, seq)`：**序号不大于本端已消费水位的增量
/// 一律按重播丢弃**，与"这段帧是不是重播的"这一事实直接对齐，不再依赖时序碰运气。
///
/// ## 语义（核心侧契约，前端按此判重）
/// - **作用域**：序号在**同一个 `message id` 内**有效；跨 id 各自独立计数、互不干扰
///   （同一轮回复里的思考段 / 中间正文段 / 最终回复段各有各的 id，各自从
///   [firstSeq] 开始）；
/// - **严格递增**：同一 id 内每下发一条 `msg_chunk` 消耗一个序号，从 [firstSeq] 起
///   `0, 1, 2, …`。序号是"**第几帧**"（帧计数），**不是**字节偏移 / token 下标；
/// - **一帧一个序号**：核心的攒帧合并（同一帧窗口内的多个增量合成一条 `msg_chunk`）
///   只占**一个**序号 —— 前端只需按帧判重，不必拆帧；
/// - **允许缺口**：严格递增**不保证连续**。补发队列有上限（溢出时丢最老的帧），
///   缺口只说明那几帧没送到；前端**不得**把缺口当协议错误，更不得据此清空/回退正文；
/// - **缺失 = 未知**：老核心不带该字段。前端必须退回"按 message id 去重"的旧判据。
///   **不得**把缺失当成 0 / -1：那会把老核心的第二条起的增量全部判成"重播"，
///   正文只剩第一帧（静默丢正文，比重复渲染更糟）。
///
/// ## 哪些帧带这个字段
/// - [WsOutboundType.msgChunk]：**必带**，值是本帧的序号（见上）；
/// - [WsOutboundType.msgEnd]：**可选**，值是**封口水位** = 本段最后一条增量帧的序号
///   （本段没有下发过增量时省略）。语义是"≤ 该序号的增量核心都已下发完毕"，
///   前端封口时把水位一并推进即可；
/// - [WsOutboundType.msgStart]：**不带**。它的"基线"恒为 [firstSeq]，带上只会与
///   "已消费水位"混淆（基线是"下一个要用的序号"，不是"已经消费到的序号"：
///   前端若拿它记账，第一条增量会被自己丢掉）。判定"本段是否按序号判据"按帧进行：
///   收到带 seq 的 `msg_chunk` 即是新核心，缺字段即是老核心。
///
/// 前端读取一律走 [of]（缺字段 / 非法值 → null = 未知），**不得**直接写 `'seq'`
/// 字面量：协议完备性门禁会拦（见 tree_protocol 的 protocol_completeness_test）。
abstract final class WsStreamSeq {
  /// 帧字段名：`{"type":"msg_chunk","id":"msg_x","chunk":"增量","seq":3}`。
  static const String field = 'seq';

  /// 序号起点（含）：同一 `message id` 的第一条增量帧序号恒为 [firstSeq]。
  static const int firstSeq = 0;

  /// 从帧里读序号：**缺失 / 非法一律返回 null（= 未知，退回 id 级判据）**。
  ///
  /// 只接受非负 `int`。别的形态（`"3"` 字符串、`3.5` 浮点、负数）都当未知：
  /// 未知只会让去重退回旧的 id 级判据（放行 + 靠封口兜底），而**误读**会把一个
  /// 错的数值当成"已消费水位"，让后续合法增量被静默丢弃 —— 宁可少去重，不可丢正文。
  static int? of(Map<String, dynamic> frame) {
    final Object? raw = frame[field];
    if (raw is int && raw >= firstSeq) return raw;
    return null;
  }
}

// ── terminal.dart ─────────────────────────────────────────────
/// 集成终端（Ctrl+J）的 WS 帧。
///
/// 为什么走**已有的那条 WS**而不是新开一个端点：终端是交互式流，需要与心跳、
/// 重连、大帧分片共用同一套传输（新开一条就得再实现一遍重连与保活）。
///
/// 为什么输出用 base64 原始字节：终端输出是**字节流**——ANSI 控制序列、
/// 非 UTF-8 字节（中文代码页）、半截的多字节字符都会出现。JSON 里只能用字符串
/// 传，任何「先解码成 String」的做法都会把控制序列或半个字符改坏，所以按
/// base64 原样搬运，解码与渲染交给前端的 VT 解析器。
abstract final class TerminalFrame {
  /// 会话 id（**前端生成**，随 [TerminalInboundType.open] 带上；核心按它路由）。
  static const String terminalId = 'terminal_id';

  /// agent id：决定在哪个工作区里起 shell（成员跟随 leader，与文件面板同口径）。
  static const String agentId = 'agent_id';

  /// 要执行的命令（空 = 平台默认 shell）
  static const String command = 'command';

  /// 工作目录（核心回显实际使用的工作区根）
  static const String cwd = 'cwd';

  /// 实际起的 shell（核心回显，界面显示用）
  static const String shell = 'shell';

  /// 终端宽度（列）/ 高度（行）
  static const String columns = 'columns';
  static const String rows = 'rows';

  /// 终端输出：**base64 编码的原始字节**
  static const String bytes = 'bytes';

  /// 进程退出码
  static const String exitCode = 'exit_code';

  /// 可读错误文案（terminal_error 帧）
  static const String message = 'message';
}

/// 终端上行帧（前端 → 核心）。[WsInboundType] 里有同名字面量的别名。
abstract final class TerminalInboundType {
  /// 开一个终端会话（带 terminal_id 与 agent_id，可选 command / columns / rows）
  static const String open = 'terminal_open';

  /// 键盘输入（带 terminal_id 与 base64 的 bytes）
  static const String input = 'terminal_input';

  /// 改窗口尺寸（带 terminal_id、columns、rows）
  static const String resize = 'terminal_resize';

  /// 结束会话（带 terminal_id；核心关掉 PTY 并清理）
  static const String close = 'terminal_close';

  static const Set<String> all = <String>{open, input, resize, close};
}

/// 终端下行帧（核心 → 前端）。
abstract final class TerminalOutboundType {
  /// 会话就绪（回 terminal_id + cwd + shell，界面据此显示提示行）
  static const String ready = 'terminal_ready';

  /// 终端输出（terminal_id + base64 的 bytes）
  static const String output = 'terminal_output';

  /// 进程退出（terminal_id + exit_code；之后核心不再发该会话的输出）
  static const String exit = 'terminal_exit';

  /// 出错（terminal_id + message：起不来 / 远端没有可用 IO / PTY 不可用…）
  static const String error = 'terminal_error';

  static const Set<String> all = <String>{ready, output, exit, error};
}

// ── plugin_rpc_methods.dart ─────────────────────────────────────────────
/// 插件 ↔ 核心 JSON-RPC **方法名**的常量家。
///
/// **为什么需要这个文件**（不变量 7 在插件协议这一层的落点）：
/// architecture.md §13 的不变量 7 写的是「协议常量只从 `tree_protocol` 取」，
/// 但插件协议长期**没有**这个家——方法名曾是散在两侧的字面量：核心侧
/// `switch` 直接写 `case 'station/command':`，`'method': 'shutdown'` 硬写在
/// `plugin_host.dart`，插件侧自己再抄一份 `PluginMethods`。这类漂移只在真机上暴露
/// （与不变量 13 对 `tree_tunnel_protocol` 的理由完全同构）。
///
/// **本包不许依赖任何 IO 或平台代码**（纯 Dart，见 `tree_protocol` 的包注释）：
/// 这里只放常量与集合，不放编解码、不放客户端。
///
/// 方向划分是**语义**的，不是装饰：
/// - [coreToPlugin] 的方法由核心**发出**，插件必须实现；
/// - [pluginToCoreRequests] 由插件**发起**、核心必须应答（未知 ⇒ `-32601`，不静默）；
/// - [pluginToCoreNotifications] 由插件**推流**、核心不等应答。
/// 新增方法前先问「它属于哪一面」——放错集合，门禁的方向断言就会失真。
abstract final class PluginRpcMethods {
  // ── 核心 → 插件（下行）──────────────────────────────────────────────

  /// 握手（进程起好后第一件事）。
  static const String hello = 'hello';

  /// 拉取插件工具表（握手后与工具表刷新点都会再来）。
  static const String toolsList = 'tools/list';

  /// 调用插件工具。
  static const String toolsCall = 'tools/call';

  /// 心跳探测：每 `heartbeat_interval` 一次，核心只看"这一拍回了没"。
  static const String ping = 'ping';

  /// 站点请求（订阅者接管一次交互）；流式接管靠 `station/stream` 喂数据。
  static const String stationRequest = 'station/request';

  /// 流式回填的中断信号（通知，不等应答）。
  static const String stationCancel = 'station/cancel';

  /// 总线事件推送（通知）。
  ///
  /// **双向同名**：插件也可以往核心推一条 `event` 通知（见 docs/plugin-development.md
  /// 的插件主动通知）。两侧的历史命名撞在一起，改任何一侧都是破坏兼容，
  /// 因此本表**只列一次**，方向由它出现在哪条通道里决定。
  static const String event = 'event';

  /// 优雅退出通知（通知）。
  ///
  /// **它不是超时**：发出后核心只等"进程真的退出"，不等时长（见
  /// `plugin_host.dart` 的 `close()` 与 `docs/architecture.md` §13 不变量 4）。
  static const String shutdown = 'shutdown';

  /// **优雅挂起**（20261015-hot-restart 阶段 1 新增；本任务唯一新增的 method）。
  ///
  /// 语义：核心请求插件"把可续跑状态转储出来然后退出"。插件回 `{ok: true}` 即
  /// 表示它**接下来会**下 `station/command` 的 `plugin.stateDump`；回错误或不认
  /// 这一条（老插件）⇒ 核心按"不可挂起"处理，走冷启动重启（向后兼容，D3）。
  ///
  /// 为什么方向决定了它必须是 method 而不是站点命令：这是**核心主动下发**给
  /// 特定插件的一问一答，插件无法用它自己订阅的点位表达"核心在问我"。
  /// 反过来，转储与取回是插件主动递送，因此走已有的 `station/command`
  /// （D10：A+B 混合，核心侧那 6 个 `case` 一字不改）。
  static const String suspend = 'suspend';

  /// **委派一次 HTTP 请求**（插件化新增；核心 → 插件，请求/应答）。
  ///
  /// 信封字段固定为 `{method, path, params, query, headers, scope,
  /// workspace_dir, data_dir, agent_id, team_id, body?, body_path?,
  /// request_id}`，插件回 `{status, headers?, body? | result_path?}`。
  /// **只发往普通插件（stdio）**：UI 插件是委派端点的消费者，不走这条通道。
  static const String apiDelegate = 'api/delegate';

  // ── 插件 → 核心（上行请求，必须应答）────────────────────────────────

  /// 下执行站命令（命令名与白名单见 `station_points.dart`）。
  static const String stationCommand = 'station/command';

  /// 订阅内置站点或自建站站点。
  static const String stationSubscribe = 'station/subscribe';

  /// 退订。
  static const String stationUnsubscribe = 'station/unsubscribe';

  /// 注册插件自建站。
  static const String stationRegister = 'station/register';

  /// 注销自建站。
  static const String stationUnregister = 'station/unregister';

  /// 跨插件触发别人的自建站。
  static const String stationTrigger = 'station/trigger';

  // ── 插件 → 核心（上行通知，不等应答）────────────────────────────────

  /// 流式回填的数据面（`request_id` 用**请求 params 里的那个**，不是 JSON-RPC 报文 id）。
  static const String stationStream = 'station/stream';

  /// 插件自报日志（核心不按名字分支，原样转成前端 `plugin_event`）。
  static const String log = 'log';

  /// **已撤除的协议面**（2026-10-31 片 3，契约 §8.3）：工作空间租约登记通知。
  ///
  /// 曾经 `{lease_id, dir}` 在核心登记「字符串 → 本机目录」，核心在
  /// `station/command` 里注入 `root`。租约统一到插件侧之后（本机
  /// `local.lease.register`、远端 `ssh.lease.register`），核心既没有目录表也不
  /// 注入 `root`，这条通知没有承接方。
  ///
  /// 常量留在这里**只为认出旧产物**：收到就记一条日志后丢弃，不静默、也不降级成
  /// `plugin_event`。它**不在** [coreToPlugin] / [pluginToCoreRequests] /
  /// [pluginToCoreNotifications] 里，因此 [all] 与基线增量都不包含它。
  static const String retiredWorkspaceRegister = 'workspace/register';

  // ── 集合与派生读数 ──────────────────────────────────────────────────

  /// 核心 → 插件的全部方法。
  static const Set<String> coreToPlugin = <String>{
    hello,
    toolsList,
    toolsCall,
    ping,
    stationRequest,
    stationCancel,
    event,
    shutdown,
    suspend,
    apiDelegate,
  };

  /// 插件 → 核心的请求（核心必须逐一应答）。
  static const Set<String> pluginToCoreRequests = <String>{
    stationCommand,
    stationSubscribe,
    stationUnsubscribe,
    stationRegister,
    stationUnregister,
    stationTrigger,
  };

  /// 插件 → 核心的通知（不等应答）。
  ///
  /// ⚠ 口径：**按名字分流**的通知目前只有 [stationStream]（进流式回填的数据面）；
  /// [log] 是**约定名**——核心不认它，而是把整条通知原样转成前端 `plugin_event`
  /// （见 `PluginBus._emitPluginEvent` 与 `PluginHost.notifications`）。把它列在本表里
  /// 是为了让门禁能识别它为已登记的协议名，而不是误报成飘的字面量。
  /// （插件也可以推 `event` 通知，那个名字已在 [event] 里登记，不重复列。）
  ///
  /// 2026-10-31 片 3 撤走了 [retiredWorkspaceRegister]（租约搬到执行器插件）：
  /// 通知面因此只剩两条，增量基线断言跟着改。
  static const Set<String> pluginToCoreNotifications = <String>{
    stationStream,
    log,
  };

  /// 全部方法名（门禁用例据此判定"字面量是否已登记"）。
  ///
  /// 三个方向集合**不得有重叠**（否则 const 集合会在此报冲突），
  /// `plugin_rpc_method_gate_test.dart` 因此直接钉总数关系。
  static const Set<String> all = <String>{
    ...coreToPlugin,
    ...pluginToCoreRequests,
    ...pluginToCoreNotifications,
  };

  /// **20261015-hot-restart 之前的基线**（= [all] 去掉 `suspend`）。
  ///
  /// 为什么把基线写成常量：门禁要断言的是「协议面**只允许**按登记的增量长」，
  /// 而不是"看起来方法数差不多"。下一次正式扩协议时，把当时的 `all` 快照成新的
  /// 基线，并同步改 `plugin_rpc_method_gate_test.dart` 的期望计数。
  static const Set<String> baselineBeforeHotRestart = <String>{
    hello,
    toolsList,
    toolsCall,
    ping,
    stationRequest,
    stationCancel,
    event,
    shutdown,
    stationCommand,
    stationSubscribe,
    stationUnsubscribe,
    stationRegister,
    stationUnregister,
    stationTrigger,
    stationStream,
    log,
  };

  /// 相对 [baselineBeforeHotRestart] 的新增方法（门禁据此断言增量受控）。
  static Set<String> addedSinceBaseline() =>
      all.difference(baselineBeforeHotRestart);

  /// **UI 插件化（协议片 A）之前的基线**（= [all] 去掉 [apiDelegate]，
  /// 即热重启任务收尾时的快照）。
  ///
  /// 为什么再钉一份：片 A 只允许新增 [apiDelegate]（`workspace/register` 已于
  /// 2026-10-31 片 3 撤除并移出 [all]，基线快照保留历史、不再引用它）。
  static const Set<String> baselineBeforeUiPluginization = <String>{
    ...baselineBeforeHotRestart,
    suspend,
  };

  /// 相对 [baselineBeforeUiPluginization] 的新增方法（门禁据此断言"片 A 只加了 2 个"）。
  static Set<String> addedSinceUiPluginization() =>
      all.difference(baselineBeforeUiPluginization);
}

/// 扫描到的**不属于插件协议**的方法名字面量的登记表（键 = 字面量，值 = 原因）。
///
/// 形状照 `nonProtocolTypeLiterals`：登记必须写原因，否则等于没门禁。
/// 这些字面量合法地存在于被扫描的源码里，但它们是**别的协议**，
/// 不该被塞进 [PluginRpcMethods]（那会让不变量 7 与 13 的边界糊掉）。
const Map<String, String> nonProtocolPluginMethodLiterals = <String, String>{
  // HTTP 方法：出现在**委派信封**（`api/delegate` 的 `method` 字段）与
  // `system.collect.api.routes` 的路由申报里，属于 REST 协议面，不是 JSON-RPC
  // method。插件实现委派时必然会写这些字面量，塞进 [PluginRpcMethods] 会把
  // "插件↔核心 RPC 面"和"REST 面"混成一张表。
  'GET': '委派信封 / 路由申报里的 HTTP 方法（REST 面），非 JSON-RPC method',
  'POST': '同上',
  'PATCH': '同上',
  'PUT': '同上（files 插件的 PUT content 委派路由字面量）',
  'DELETE': '同上',
  // 执行站命令名：插件经 `station/command` 下达，由核心的 `ExecuteStationMounts`
  // 执行（命令白名单的家在 tree_core 的 `StationPoints`），不是插件↔核心 JSON-RPC
  // method；插件侧实现 WorkspaceIO 时必然会出现这些字面量。
  // 2026-10-31（契约 §8.1）：本机命令族带上了 `local.` 限定词，与 `ssh_executor`
  // 的 `ssh.*` 逐字对称——无前缀的 `file.*` 随内置点位表一起退场。
  'local.file.read': '自建执行站命令（local_executor），非插件↔核心 JSON-RPC 面',
  'local.file.write': '同上',
  'local.file.list': '同上',
  'local.file.delete': '同上',
  'local.file.mkdir': '同上',
  'local.file.writeBytes': '同上',
};

// ── ws_inbound.dart ─────────────────────────────────────────────

/// WebSocket **上行**消息类型（前端 → 核心进程）。
///
/// 对应 `server/ws/endpoints.py::register_ws` 的 `msg_type` 分发链，共 12 种。
/// 桌面分支中这些帧改走本地回环 WS（M1），类型与字段保持不变。
abstract final class WsInboundType {
  /// 心跳保活（前端每 10s 一次；必须小于核心判活窗口 I×N = 30s）。
  static const String heartbeat = 'heartbeat';

  /// 用户消息（顶层 agent 会话入口）。
  static const String userMessage = 'user_message';

  /// 停止当前 agent（含成员级联）。
  static const String stop = 'stop';

  /// 回答提问（ask_user_question 的应答）。
  static const String userAnswer = 'user_answer';

  /// 取消提问。
  static const String cancelQuestion = 'cancel_question';

  // 说明（M7c）：桌面端工具由**核心进程本机执行**，因此原先的
  // `register_*_executor`（注册前端执行能力）与 `tool_exec_response` /
  // `tool_exec_progress`（反向执行结果回报）整套上行帧已删除——它们描述的
  // "前端执行器"不存在了。插件宿主同理（核心自己拉起插件进程）。

  // 片 E：旧 UI 面板协议的动作上行已删除；前端不再有插件槽位，
  // 插件的功能扩展只走调用点 REST / 广播订阅。

  // ── 集成终端（Ctrl+J） ────────────────────────────────────────────────
  // 值复用 [TerminalInboundType.*]（**别名**，不重复字面量），见 terminal.dart。

  /// 开一个终端会话。
  static const String terminalOpen = TerminalInboundType.open;

  /// 键盘输入。
  static const String terminalInput = TerminalInboundType.input;

  /// 改窗口尺寸。
  static const String terminalResize = TerminalInboundType.resize;

  /// 结束会话。
  static const String terminalClose = TerminalInboundType.close;

  // ── UI 插件 · 站点（WS 侧，插件化新增）──────────────────────────────
  // **命名风格**：这六条按设计文档 §3.2 使用「点号 / 斜杠」形态，而不是本文件
  // 历史帧的 snake_case。原因是它们与插件 stdio RPC 的方法名**同名同义**
  // （`PluginRpcMethods.station*`），两侧共用一套叫法才能让 UI 与普通插件看到
  // 同一个协议面；改成 snake_case 等于换协议（旧客户端会静默不认）。
  // 其中五条 `station/*` 直接以 [PluginRpcMethods] 的常量为**别名**，不重复字面量。

  /// UI 连接自我声明：`{plugin_id, version, capabilities[]}`。
  static const String uiHello = 'ui.hello';

  /// 订阅站点（WS 侧只允许广播站，可选 `topics[]`）。
  static const String stationSubscribe = PluginRpcMethods.stationSubscribe;

  /// 退订站点。
  static const String stationUnsubscribe = PluginRpcMethods.stationUnsubscribe;

  /// UI 注册自建站（只允许广播类型）。
  static const String stationRegister = PluginRpcMethods.stationRegister;

  /// 注销自建站。
  static const String stationUnregister = PluginRpcMethods.stationUnregister;

  /// 向**自己注册的**自建广播站发布事件（不得触发收集站 / 执行站）。
  static const String stationTrigger = PluginRpcMethods.stationTrigger;

  /// 全部上行类型（完备性测试与文档用）。
  static const Set<String> all = <String>{
    heartbeat,
    userMessage,
    stop,
    userAnswer,
    cancelQuestion,
    terminalOpen,
    terminalInput,
    terminalResize,
    terminalClose,
    uiHello,
    stationSubscribe,
    stationUnsubscribe,
    stationRegister,
    stationUnregister,
    stationTrigger,
  };
}

// ── ws_outbound.dart ─────────────────────────────────────────────

/// WebSocket **下行**消息类型（核心进程 → 前端）。
///
/// 与现状 server 的下行帧一一对应（`server/agent/chat.py` 流式与状态推送、
/// `server/ws/ws_manager.py` 分帧与心跳、`server/io_/local_executor.py` 反向执行请求、
/// `server/plugin/*` 插件事件）。桌面分支保持帧形状不变，前端 lib/ui 才能零改动。
abstract final class WsOutboundType {
  // ── 流式回复分段（agent 输出） ─────────────────────────────────────────
  /// 文本/思考段开始。
  static const String msgStart = 'msg_start';

  /// 段内容增量。
  ///
  /// 帧形状：`{type, id, chunk, seq, agent_id, session_id}`。[seq] 是**同一 id 内
  /// 严格递增的帧序号**（从 [WsStreamSeq.firstSeq] 起，攒帧合并后一帧一个序号），
  /// 前端据此丢弃"重播的、已经渲染过的增量"；老核心不带该字段，前端退回按 id 去重。
  /// 语义与兼容口径见 [WsStreamSeq]。
  static const String msgChunk = 'msg_chunk';

  /// 段结束。
  ///
  /// 帧形状：`{type, id, usage, cancelled, seq?, agent_id, session_id}`。可选的
  /// [seq] 是**封口水位** = 本段最后一条增量帧的序号（本段没下发过增量时省略）：
  /// 核心保证"≤ 该序号的增量都已下发完毕"，前端封口时把已消费水位一并推进。
  static const String msgEnd = 'msg_end';

  /// 段/轮次的 token 用量（进度条分母为 max_seqlen）。
  static const String msgUsage = 'msg_usage';

  /// 工具调用开始（含参数）。
  static const String toolStart = 'tool_start';

  /// 工具调用结束（含结果）。
  static const String toolEnd = 'tool_end';

  // ── 会话与状态 ────────────────────────────────────────────────────────
  /// agent 工作状态（working/idle/...）。
  static const String agentStatus = 'agent_status';

  /// 会话被创建（成员自动建会话时通知前端刷新）。
  static const String sessionCreated = 'session_created';

  /// 会话被**重命名**（点位化新增：执行站命令 `session.rename` 与将来的其它入口）。
  ///
  /// 帧形状：`{type, data: {agent_id, session_id, title}}`。前端收到后更新会话列表里
  /// 的标题——REST 改名路径是前端自己 `setState`，插件改名没有这条路径，必须靠帧。
  static const String sessionRenamed = 'session_renamed';

  /// todo 列表更新。
  static const String todoUpdate = 'todo_update';

  /// 提问卡片推送。
  static const String askUserQuestion = 'ask_user_question';

  /// 提问已解决（跨端/多窗口同步）。
  static const String askUserQuestionResolved = 'ask_user_question_resolved';

  /// 通用文本消息（`_send_text_as_agent` 路径）。
  static const String message = 'message';

  /// 错误提示（`data.message` 携带可读文案）。
  static const String error = 'error';

  // ── 传输层 ────────────────────────────────────────────────────────────
  /// 心跳。
  ///
  /// 注意：**双向**使用同一字面量——前端定时上报，核心进程也会主动下发
  /// （`ws_manager.py` 保活循环），故同时存在于上行与下行常量中。
  static const String heartbeat = 'heartbeat';

  /// 大帧分片：起始片。
  static const String frameBegin = 'frame_begin';

  /// 大帧分片：中间片。
  static const String frameChunk = 'frame_chunk';

  /// 大帧分片：结束片。
  static const String frameEnd = 'frame_end';

  // 说明（M7c）：执行器注册回执（`register_*_ack` / `registration_lost`）与反向
  // 执行通道（`tool_exec_request` / `tool_exec_cancel`）已删除——桌面端工具由核心
  // 本机执行，不存在"核心委托前端执行"这回事。

  // ── 插件 ──────────────────────────────────────────────────────────────
  /// 插件自定义事件（`plugin_event`）。
  static const String pluginEvent = 'plugin_event';

  /// 插件实例生命周期状态。
  static const String pluginStatus = 'plugin_status';

  /// 插件清单（plugins.yaml）发生变更（核心 → 所有 WS 连接，前端面板据此重拉清单）。
  ///
  /// 帧形状：`{type, data: {plugin_id, enabled?, removed?, source}}`。
  /// 为什么需要这条帧：配置写入过去只落盘、不通知——面板的开关绑在打开那一刻
  /// 拉到的清单快照上，别的窗口 / 别的写入路径（卸载连带停用、重启回滚）改了
  /// `enabled`，界面照样显示启用（2026-11-01「盘上停用、界面启用」不对齐事故）。
  /// `source` 是触发写入的路由名，UI 原样展示即可，不在前端再猜一遍。
  static const String pluginConfigChanged = 'plugin_config_changed';

  /// 站点投递（核心 → WS 订阅者，插件化新增）。
  ///
  /// 帧形状：`{type, station_id, point, topic?, payload, scope, origin_plugin_id,
  /// state, seq?, reason?, from_seq?}`（值对象的家在同包的 `station_ws.dart`）。
  ///
  /// **命名风格**：本帧沿用下行历史帧的 snake_case；设计文档 §3.2 给的就是
  /// `station_delivery`，因此不存在斜杠形式。上行那几条 `station/*` 是 RPC
  /// 风格的方法名（见 `ws_inbound.dart`），两者不是同一套命名习惯。
  static const String stationDelivery = 'station_delivery';

  // ── 集成终端（Ctrl+J） ────────────────────────────────────────────────
  // 值复用 [TerminalOutboundType.*]（**别名**，不重复字面量），见 terminal.dart。

  /// 终端会话就绪（回 cwd / shell）。
  static const String terminalReady = TerminalOutboundType.ready;

  /// 终端输出（base64 原始字节）。
  static const String terminalOutput = TerminalOutboundType.output;

  /// 终端进程退出（带 exit_code）。
  static const String terminalExit = TerminalOutboundType.exit;

  /// 终端出错（可读 message）。
  static const String terminalError = TerminalOutboundType.error;

  /// 全部下行类型（完备性测试与文档用）。
  static const Set<String> all = <String>{
    msgStart,
    msgChunk,
    msgEnd,
    msgUsage,
    toolStart,
    toolEnd,
    agentStatus,
    sessionCreated,
    sessionRenamed,
    todoUpdate,
    askUserQuestion,
    askUserQuestionResolved,
    message,
    error,
    heartbeat,
    frameBegin,
    frameChunk,
    frameEnd,
    pluginEvent,
    pluginStatus,
    pluginConfigChanged,
    stationDelivery,
    terminalReady,
    terminalOutput,
    terminalExit,
    terminalError,
  };

  /// 分帧三件套（server 侧由 `ws_manager._FRAME_*` 常量产出，非字面量，
  /// 完备性测试单独核对）。
  static const Set<String> frameChunking = <String>{
    frameBegin,
    frameChunk,
    frameEnd,
  };
}

// ── station_ws.dart ─────────────────────────────────────────────
/// UI 插件 ⇄ 核心的 **WS 站点协议**（设计见
/// `docs/pluginization/ui-pluginization.md` §3.2 / §6.7）。
///
/// 本文件只放**常量与值对象**（纯 Dart，不依赖 IO / Flutter）：
/// - [StationWsFrames]：WS 侧站点帧名（值复用 `WsInboundType` /
///   `WsOutboundType` 的**别名**，不重复字面量）；
/// - [StationDeliveryState]：`station_delivery.state` 的四态；
/// - [StationDelivery]：`station_delivery` 帧的值对象与编解码；
/// - [StationTopic]：`<plugin_id>.<session_id>.<kind>` 的拼接 / 解析。
///
/// 方向口径（§6.4 总纲）：UI 能做的事只有两类——**订阅广播站**接收推送
/// （[StationWsFrames.subscribe]）与**调用委派端点**做功能调用（REST）。
/// `station/trigger` 在 UI 侧只允许发布自己注册的自建广播站。


/// WS 侧站点帧名。
///
/// 上行六条的值与 `WsInboundType` 完全一致（本类只做「按用途取名」的别名），
/// 下行一条同理。**不要在别处再写字面量**：帧名漂移会让 UI 静默收不到推送。
abstract final class StationWsFrames {
  /// UI 连接自我声明（上行）。
  static const String uiHello = WsInboundType.uiHello;

  /// 订阅站点（上行；仅广播站，可选 `topics[]` 过滤）。
  static const String subscribe = WsInboundType.stationSubscribe;

  /// 退订站点（上行）。
  static const String unsubscribe = WsInboundType.stationUnsubscribe;

  /// 注册自建站（上行；只允许广播类型）。
  static const String register = WsInboundType.stationRegister;

  /// 注销自建站（上行）。
  static const String unregister = WsInboundType.stationUnregister;

  /// 向自己注册的自建广播站发布事件（上行）。
  static const String trigger = WsInboundType.stationTrigger;

  /// 站点投递（下行）。
  static const String delivery = WsOutboundType.stationDelivery;

  /// 全部 WS 站点帧名。
  static const Set<String> all = <String>{
    uiHello,
    subscribe,
    unsubscribe,
    register,
    unregister,
    trigger,
    delivery,
  };

  /// 上行（UI → 核心）。
  static const Set<String> inbound = <String>{
    uiHello,
    subscribe,
    unsubscribe,
    register,
    unregister,
    trigger,
  };

  /// 下行（核心 → UI）。
  static const Set<String> outbound = <String>{delivery};
}

/// `station_delivery.state` 的取值（§6.7 / 不变量 32）。
///
/// 四态各自的事故语义：
/// - [data]：正常增量事件；
/// - [closed]：站点注销或插件下线，**终止订阅**（带 `reason`，不得静默失效）；
/// - [lagged]：单连接队列溢出（带 `from_seq`，UI 需重新拉快照，禁止静默丢帧）；
/// - [reset]：插件重启后 `seq` 归零，UI 需重置本地水位。
enum StationDeliveryState {
  /// 正常增量事件。
  data('data'),

  /// 站点注销 / 插件下线（订阅终止）。
  closed('closed'),

  /// 队列溢出（背压）。
  lagged('lagged'),

  /// 插件重启后序号归零。
  reset('reset');

  const StationDeliveryState(this.wire);

  /// 线格式取值。
  final String wire;

  /// 宽容解析：缺失 / 未知取值返回 null（由调用方决定容错方向）。
  static StationDeliveryState? tryParse(Object? raw) {
    final String value = raw == null ? '' : raw.toString().trim();
    for (final StationDeliveryState state in values) {
      if (state.wire == value) {
        return state;
      }
    }
    return null;
  }

  /// 全部线格式取值（完备性测试与文档用）。
  static Set<String> get all =>
      values.map((StationDeliveryState s) => s.wire).toSet();
}

/// `station_delivery` 帧的值对象（核心 → WS 订阅者）。
///
/// 线格式（设计文档 §3.2，**平铺**在帧顶层，与 `msg_chunk` 等下行帧同构）：
/// ```json
/// {
///   "type": "station_delivery",
///   "station_id": "plugin.tree.agent.download",
///   "point": "system.broadcast",
///   "topic": "tree.agent.s123.chunk",
///   "payload": { "chunks": ["..."] },
///   "scope": { "team_id": "t1", "agent_id": "a1",
///              "session_id": "s123", "mode_key": "local" },
///   "origin_plugin_id": "tree.agent",
///   "state": "data",
///   "seq": 12
/// }
/// ```
/// `closed` 带 `reason`；`lagged` 带 `from_seq`；`reset` 通常带新的起始 `seq`。
/// 未知字段在解析时忽略，`toJson()` 只回吐本协议字段。
class StationDelivery {
  const StationDelivery({
    required this.stationId,
    required this.point,
    this.topic,
    this.payload,
    this.scope = const <String, dynamic>{},
    this.originPluginId = '',
    this.state = StationDeliveryState.data,
    this.seq,
    this.reason,
    this.fromSeq,
  });

  /// 站点全局 id（订阅时用的那个串）。
  final String stationId;

  /// 点位 id / 别名（内置站点由核心点位表给出；自建站可为空）。
  final String point;

  /// 事件 topic（`<plugin_id>.<session_id>.<kind>`，见 [StationTopic]）。
  final String? topic;

  /// 原样透传的载荷（核心不解析、不重组、不缓存语义）。
  final Object? payload;

  /// 消息信封的隔离四元组（原样透传；空字段 = 该维不限定）。
  ///
  /// 协议包不依赖核心的 `StationScope`，因此这里保留线格式 Map。
  final Map<String, dynamic> scope;

  /// 发布方插件 id（同一插件的其他窗口据此判断自环）。
  final String originPluginId;

  /// 投递状态（[StationDeliveryState]）。
  final StationDeliveryState state;

  /// 该 topic 内的单调序号（非 `data` 态可缺省）。
  final int? seq;

  /// 可读原因（`closed` 等终止态必带）。
  final String? reason;

  /// 背压起点：队列溢出时 UI 应从这个序号之后重新拉快照。
  final int? fromSeq;

  /// 从 `data` 载荷解析（缺失字段归一化，未知字段忽略）。
  ///
  /// 未知 `state` **回退为 [StationDeliveryState.data]**：与前端既有
  /// 「未知枚举回退默认」口径一致，避免一个新增状态把整帧丢掉。
  factory StationDelivery.fromJson(Map<String, dynamic> json) {
    final Object? rawTopic = json['topic'];
    final Object? rawScope = json['scope'];
    final Object? rawSeq = json['seq'];
    final Object? rawReason = json['reason'];
    final Object? rawFromSeq = json['from_seq'];
    return StationDelivery(
      stationId: _asString(json['station_id']),
      point: _asString(json['point']),
      topic: rawTopic?.toString(),
      payload: json['payload'],
      scope: rawScope is Map
          ? Map<String, dynamic>.from(rawScope)
          : const <String, dynamic>{},
      originPluginId: _asString(json['origin_plugin_id']),
      state:
          StationDeliveryState.tryParse(json['state']) ??
          StationDeliveryState.data,
      seq: _asInt(rawSeq),
      reason: rawReason?.toString(),
      fromSeq: _asInt(rawFromSeq),
    );
  }

  /// 从完整 WS 帧解析（`type` 不匹配返回 null）。
  ///
  /// 兼容两种承载：帧顶层平铺（本协议采用）与 `data` 包裹（与 `ui.hello`
  /// 等点号帧同风格）；解析只做宽容读取，不影响 [toFrame] 的产出形状。
  static StationDelivery? fromFrame(Map<String, dynamic> frame) {
    if (frame['type'] != StationWsFrames.delivery) {
      return null;
    }
    final Object? data = frame['data'];
    return StationDelivery.fromJson(
      data is Map ? Map<String, dynamic>.from(data) : frame,
    );
  }

  /// 载荷 JSON（可选字段缺省时省略，避免用空串伪造「有值」）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'station_id': stationId,
    'point': point,
    if (topic != null) 'topic': topic,
    'payload': payload,
    'scope': scope,
    'origin_plugin_id': originPluginId,
    'state': state.wire,
    if (seq != null) 'seq': seq,
    if (reason != null) 'reason': reason,
    if (fromSeq != null) 'from_seq': fromSeq,
  };

  /// 完整 WS 帧（平铺，与 `msg_chunk` 等下行帧同构）。
  Map<String, dynamic> toFrame() => <String, dynamic>{
    'type': StationWsFrames.delivery,
    ...toJson(),
  };

  @override
  String toString() =>
      'StationDelivery(${stationId.toString()}, state=${state.wire}, '
      'topic=${topic ?? '-'}, seq=${seq ?? '-'})';
}

/// **topic 约定**：`<plugin_id>.<session_id>.<kind>`（设计文档 §6.7）。
///
/// 例：`tree.agent.s123.chunk`。核心不解析 topic 的语义，只按订阅过滤与
/// 原样透传；本类只提供两侧都要用的拼接口径，避免 UI 与插件各写一套。
///
/// **解析方向刻意从右往左**：`plugin_id` 自身可以带点（`tree.agent`），
/// 因此不能简单按三段落取；约定 `kind` 与 `session_id` 都不含点，
/// 从右侧切两刀后剩下的整体才是 `plugin_id`。
abstract final class StationTopic {
  /// 拼接三段（任一段为空 ⇒ [ArgumentError]，空 topic 无法被订阅匹配）。
  static String join({
    required String pluginId,
    required String sessionId,
    required String kind,
  }) {
    final String p = pluginId.trim();
    final String s = sessionId.trim();
    final String k = kind.trim();
    if (p.isEmpty || s.isEmpty || k.isEmpty) {
      throw ArgumentError.value(
        '$p.$s.$k',
        'topic',
        'plugin_id / session_id / kind 三段都不能为空',
      );
    }
    return '$p.$s.$k';
  }

  /// 解析三段；不足三段或任一段为空返回 null（宽容，调用方跳过该帧）。
  static StationTopicParts? parse(String topic) {
    final List<String> parts = topic.trim().split('.');
    if (parts.length < 3) {
      return null;
    }
    final String kind = parts.last.trim();
    final String sessionId = parts[parts.length - 2].trim();
    final String pluginId = parts.sublist(0, parts.length - 2).join('.').trim();
    if (pluginId.isEmpty || sessionId.isEmpty || kind.isEmpty) {
      return null;
    }
    return StationTopicParts(
      pluginId: pluginId,
      sessionId: sessionId,
      kind: kind,
    );
  }
}

/// [StationTopic.parse] 的结果。
class StationTopicParts {
  const StationTopicParts({
    required this.pluginId,
    required this.sessionId,
    required this.kind,
  });

  /// 发布方插件 id（可含点）。
  final String pluginId;

  /// 会话 id。
  final String sessionId;

  /// 事件种类（如 `chunk` / `tool_start`）。
  final String kind;

  @override
  String toString() => '$pluginId.$sessionId.$kind';
}

/// 字符串归一（缺失 ⇒ 空串）。
String _asString(Object? value) => value == null ? '' : value.toString();

/// 整数归一（非数值 ⇒ null；`0` 是合法序号，不能用真假值判断）。
int? _asInt(Object? value) => value is num ? value.toInt() : null;
