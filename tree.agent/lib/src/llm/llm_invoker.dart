import 'llm_transport.dart';
import 'llm_types.dart';

/// **LLM 调用边界**（AC-6）：把"这一跳的流是怎么产生的"从会话再抬一层。
///
/// 本期只抽接口、不新建跨插件流式协议：
/// - 默认实现 [TransportLlmInvoker] 只是把请求原样转给 [LlmTransport]，
///   请求字节与接线前**完全一致**；
/// - 后续 LLM 插件可以替换这个接口来接管真实调用，而工具循环、上下文装配、
///   用量累计与中转站位点都不需要改；
/// - 会话只依赖 [invoke]，不关心底层是 HTTP/SSE、本地进程还是别的实现。
abstract interface class LlmInvoker {
  /// 发起一次流式调用。[isCancelled] 在每帧后被检查，为真时尽快中断。
  Stream<LlmStreamEvent> invoke(
    LlmRequest request, {
    bool Function()? isCancelled,
  });
}

/// 默认调用边界：直接走 [LlmTransport]（不额外加任何包装/改写）。
class TransportLlmInvoker implements LlmInvoker {
  const TransportLlmInvoker(this.transport);

  final LlmTransport transport;

  @override
  Stream<LlmStreamEvent> invoke(
    LlmRequest request, {
    bool Function()? isCancelled,
  }) => transport.stream(request, isCancelled: isCancelled);
}
