/// LLM 三步中转点（AC-4）：前置处理 / 请求体自动修复 / 后置处理。
///
/// 三个点位都是**本插件自建的中转站**，id 由核心拼装为
/// `plugin.<插件id>.relay.<name>`。注意核心对自建站名段只允许 `[A-Za-z0-9_-]`
/// （点号会破坏归属前缀判定），所以实际 id 是 `...relay.llm_pre` 这种形态。
library;

/// 点位常量（[point] 是语义名，[name] 是注册用的名段）。
abstract final class LlmRelayPoints {
  /// 前置处理：完整请求 → `{request?, error, error_reason}`。
  static const String pre = 'llm.pre';
  static const String preName = 'llm_pre';

  /// 请求体自动修复：完整请求 → 同 [pre]。
  static const String repair = 'llm.repair';
  static const String repairName = 'llm_repair';

  /// 后置处理：`{thinking, content, tool_calls}` → 同形 + `{error, error_reason}`。
  static const String post = 'llm.post';
  static const String postName = 'llm_post';

  /// 全部点位的 `(语义名, 注册名段)`。
  static const List<(String, String)> all = <(String, String)>[
    (pre, preName),
    (repair, repairName),
    (post, postName),
  ];

  /// 注册名段 → 语义名（用于日志/错误信息）。
  static String pointOfName(String name) => switch (name) {
    preName => pre,
    repairName => repair,
    postName => post,
    _ => name,
  };
}

/// 三个中转点的共同说明书（`station/register` 的 readme 必填）。
const String kLlmRelayReadme =
    'LLM 三步中转点（每个点位唯一订阅者）：llm_pre 在请求发出前拿到完整请求体；'
    'llm_repair 负责请求体自动修复；llm_post 在响应流结束后拿到 thinking/content/'
    'tool_calls。回包统一带 error/error_reason：只有显式 error:true 才终止本轮并用 '
    'error_reason 作为失败原因；无订阅者 / 非法回包 / 异常 / 超时一律走内置路径。';

/// 一次中转调用的结果。
///
/// [handled] = false 表示"没有订阅者 / 未接线 / 调用失败 / 超时"——一律走内置
/// 路径（C9 的 fail-open）。[data] 是订阅者的原始回包，由调用方按点位契约解释
/// （`error` / `error_reason` 的判定在调用方，便于单测直接注入）。
class LlmRelayReply {
  const LlmRelayReply({this.handled = false, this.data});

  /// 是否有订阅者并给出了回包。
  final bool handled;

  /// 订阅者回包（JSON 对象）；null = 视同未处理。
  final Map<String, dynamic>? data;

  bool get hasData => handled && data != null;
}

/// 中转调用入口（由运行时接线到核心 `station/trigger`）。
///
/// [point] 取 [LlmRelayPoints.pre] / [LlmRelayPoints.repair] / [LlmRelayPoints.post]；
/// [data] 是该点位的输入载荷。未接线时返回 `handled:false`。
typedef LlmRelayHook =
    Future<LlmRelayReply> Function({
      required String point,
      required Map<String, dynamic> data,
      required String agentId,
      required String sessionId,
      required int turn,
    });
