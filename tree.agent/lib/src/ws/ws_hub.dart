/// 下行帧出口（A3 阶段的 **WsHub 兼容壳**）。
///
/// 核心的 `WsHub` 是完整的 WS 服务器；插件运行期的帧出口将来是站内总线（A4）。
/// 从核心平移的 `ConversationService` 只调用 `hub.broadcast(frame)`，因此这里先提供
/// 最小同形接口：把帧交给注入的回调（测试里可收集，运行期可接站内主题/事件）。
///
/// **不要**在这个类里长回 HTTP/WS 逻辑——那属于核心平台层。
class WsHub {
  WsHub({this.onBroadcast});

  /// 收到一帧下行消息时的回调；null = 丢弃（未接线，行为与核心"没有前端连接"一致）。
  void Function(Map<String, dynamic> frame)? onBroadcast;

  /// 广播一帧（与核心 `WsHub.broadcast` 同签名的最小实现）。
  void broadcast(Map<String, dynamic> frame) => onBroadcast?.call(frame);

  /// 关停（无资源可释放；保持与核心同形，便于平移代码直接调用）。
  Future<void> close() async {}
}
