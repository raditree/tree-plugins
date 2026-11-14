/// 产线 ↔ `tree.agent` 记忆通道的窄端口（冻结方案 Task 6.4）。
///
/// 纪律：**产线不读 `.self/memory.md`、不存记忆正文**。
/// - 正文只交给提示词（`MemoryView.text`），随本次调用消失；
/// - 可落盘的只有 `hash` / `sources` / `unavailable` 这些元数据；
/// - 通道缺失 / 抛异常 / 回包带 `error` / `code=memory_unavailable` / `ok=false`
///   一律降级为「不可用」，**绝不抛**，也绝不因此阻断准备或执行。
library;

import 'models.dart';

/// `agent.memory.get(agent_id, purpose, budget_chars)`；单测注入假实现。
typedef MemoryGet =
    Future<Map<String, Object?>> Function(
      String agentId,
      String purpose,
      int budgetChars,
      Map<String, Object?> scope,
    );

/// `agent.memory.record(entry)`；单测注入假实现。
typedef MemoryRecord =
    Future<Map<String, Object?>> Function(
      Map<String, Object?> entry,
      Map<String, Object?> scope,
    );

/// 一次读取的结果：只有 [text] 用于提示词，其余都是可落盘的元数据。
class MemoryView {
  const MemoryView({
    this.text = '',
    this.hash = '',
    this.sources = const <String>[],
    this.chars = 0,
    this.unavailable = false,
    this.truncated = false,
    this.code = '',
  });

  /// 记忆正文（只进提示词，不落盘）。
  final String text;

  /// 记忆文件的内容指纹（64 位十六进制；缺失 / 非法 = 空串）。
  final String hash;

  /// 该记忆由哪些来源汇总而来（稳定路径，可直接落盘）。
  final List<String> sources;

  /// 正文实际字符数（由 agent 侧统计）。
  final int chars;

  /// 通道不可用 / 未接线 / 降级：调用方据此只写 `memory_unavailable`。
  final bool unavailable;

  /// 正文是否被 [MemoryPort.read] 的预算截断。
  final bool truncated;

  /// 降级原因码（正常时为空串）。
  final String code;
}

/// 一次写入的结果（成功时只回 hash；不可用时 `unavailable=true`）。
class MemoryWrite {
  const MemoryWrite({
    this.ok = false,
    this.unavailable = false,
    this.hash = '',
    this.sources = const <String>[],
    this.code = '',
  });

  final bool ok;
  final bool unavailable;

  /// 写入后记忆文件的内容指纹（64 位十六进制；非法 = 空串）。
  final String hash;

  /// 本次写入声明的来源（回包不带时沿用请求里的那份）。
  final List<String> sources;
  final String code;
}

/// 记忆端口：读一次 → 只把 hash / sources 往上交；写一次 → 只回 hash。
class MemoryPort {
  factory MemoryPort({MemoryGet? get, MemoryRecord? record}) =>
      MemoryPort._(get, record);

  MemoryPort._(this._get, this._record);

  final MemoryGet? _get;
  final MemoryRecord? _record;

  /// 读一次记忆；**任何失败都返回 `unavailable: true`，不抛**。
  Future<MemoryView> read({
    required String agentId,
    required String purpose,
    int budgetChars = 4000,
    Map<String, Object?> scope = const <String, Object?>{},
  }) async {
    final MemoryGet? reader = _get;
    if (reader == null || agentId.trim().isEmpty) return _unavailableView();
    Map<String, Object?> reply;
    try {
      reply = await reader(agentId, purpose, budgetChars, scope);
    } catch (_) {
      return _unavailableView();
    }
    final String code = textOf(reply['code']);
    if (reply['error'] != null ||
        code == 'memory_unavailable' ||
        reply['ok'] == false) {
      return _unavailableView(code: code.isEmpty ? 'memory_unavailable' : code);
    }
    return MemoryView(
      text: textOf(reply['text']),
      hash: _hashOf(reply['hash']),
      sources: stringsOf(reply['sources']),
      chars: intOf(reply['chars'], 0),
      truncated: reply['truncated'] == true,
    );
  }

  /// 写一条记忆；**任何失败都返回 `unavailable: true`，不抛**。
  Future<MemoryWrite> record({
    required String agentId,
    required String purpose,
    required String summary,
    List<String> sources = const <String>[],
    String lineId = '',
    String taskId = '',
    Map<String, Object?> scope = const <String, Object?>{},
  }) async {
    final MemoryRecord? writer = _record;
    if (writer == null || agentId.trim().isEmpty || summary.trim().isEmpty) {
      return MemoryWrite(unavailable: true, code: 'memory_unavailable');
    }
    Map<String, Object?> reply;
    try {
      reply = await writer(<String, Object?>{
        'agent_id': agentId,
        'purpose': purpose,
        'summary': summary,
        'sources': sources,
        if (lineId.isNotEmpty) 'line_id': lineId,
        if (taskId.isNotEmpty) 'task_id': taskId,
      }, scope);
    } catch (_) {
      return MemoryWrite(unavailable: true, code: 'memory_unavailable');
    }
    final String code = textOf(reply['code']);
    if (reply['error'] != null ||
        code == 'memory_unavailable' ||
        reply['ok'] == false) {
      return MemoryWrite(
        unavailable: true,
        code: code.isEmpty ? 'memory_unavailable' : code,
      );
    }
    return MemoryWrite(
      ok: true,
      hash: _hashOf(reply['hash']),
      sources: sources,
    );
  }

  MemoryView _unavailableView({String code = 'memory_unavailable'}) =>
      MemoryView(unavailable: true, code: code);

  /// 只认 64 位十六进制指纹；其它（缺键 / 非法）统一回空串。
  String _hashOf(Object? value) {
    final String hash = textOf(value);
    return RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hash) ? hash : '';
  }
}
