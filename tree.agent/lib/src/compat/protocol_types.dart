/// 旧下行帧名/序号的最小兼容层（从 `tree_protocol` 抄值）。
///
/// 为什么插件包不直接依赖 `tree_protocol`：插件是独立仓库、只允许 pub.dev 依赖；
/// 而生成循环目前仍以"旧下行帧 + 站内广播"的形态工作（A4 再统一到 station bus）。
/// 这里只保留**实际用到的协议常量与取值逻辑**，值与协议包逐字一致；等 A4 接线时
/// 由站内主题替换。
abstract final class WsOutboundType {
  /// 文本/思考段开始。
  static const String msgStart = 'msg_start';

  /// 段内容增量。
  static const String msgChunk = 'msg_chunk';

  /// 段结束。
  static const String msgEnd = 'msg_end';

  /// 段/轮次的 token 用量。
  static const String msgUsage = 'msg_usage';

  /// 工具调用开始（含参数）。
  static const String toolStart = 'tool_start';

  /// 工具调用结束（含结果）。
  static const String toolEnd = 'tool_end';

  /// agent 工作状态（working/idle/...）。
  static const String agentStatus = 'agent_status';

  /// 会话被创建。
  static const String sessionCreated = 'session_created';

  /// 会话被重命名。
  static const String sessionRenamed = 'session_renamed';

  /// todo 列表更新。
  static const String todoUpdate = 'todo_update';

  /// 提问卡片推送。
  static const String askUserQuestion = 'ask_user_question';

  /// 提问已收尾（作答/取消/超时）。
  static const String askUserQuestionResolved = 'ask_user_question_resolved';

  /// 通用文本消息。
  static const String message = 'message';

  /// 错误提示（`data.message` 携带可读文案）。
  static const String error = 'error';
}

/// 流式增量帧（`msg_chunk`）的单调序号（与协议包 `WsStreamSeq` 逐字一致）。
///
/// 序号只在同一个 `message id` 内有效；缺失/非法一律返回 null（= 未知，退回
/// id 级判据），绝不把缺字段当成 0。
abstract final class WsStreamSeq {
  /// 帧字段名。
  static const String field = 'seq';

  /// 序号起点（含）。
  static const int firstSeq = 0;

  /// 从帧里读序号：只接受非负 `int`，其它形态当未知。
  static int? of(Map<String, dynamic> frame) {
    final Object? raw = frame[field];
    if (raw is int && raw >= firstSeq) return raw;
    return null;
  }
}
