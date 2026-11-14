/// **Agent 记忆**：把跨会话的长期记忆存进该 agent 的私有状态目录。
///
/// 记忆文件落在 `<工作空间>/.tree/<agent_id>/.self/memory.md`（见 [privateSelfDir]），
/// 与系统提示词、活动日志同属"这个 agent 自己的东西"，不与其他成员共享。
///
/// 记忆逻辑**只在 tree.agent 存一份**：生产线等调用方经自建执行站命令
/// `agent.memory.get` / `agent.memory.record` 消费，不各自实现一份读写。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../workspace/workspace_io.dart';
import 'private_paths.dart';

/// 记忆文件的固定文件名（相对 [privateSelfDir]）。
const String kMemoryFileName = 'memory.md';

/// 记忆满文件标题（文件不存在时先写这一段）。
const String kMemoryHeader = '# 记忆\n\n';

/// 截断提示行：说明回给调用方的只是最近一段。
const String kMemoryTruncationNotice = '…（已按预算截断，保留最近记忆）';

/// 某个 agent 的长期记忆服务（读写 `.self/memory.md`）。
///
/// [ioFor] 与 `AgentRuntime.workspaceIoFor(agentId, sessionId)` 同签名；
/// 返回 null 或抛异常都按"工作空间不可用"处理（**不向外抛**）。
class MemoryService {
  MemoryService({
    required this.ioFor,
    DateTime Function()? clock,
    this.maxFileChars = 200000,
  }) : _clock = clock ?? DateTime.now;

  final Future<WorkspaceIO?> Function(String agentId, String sessionId) ioFor;
  final DateTime Function() _clock;

  /// 记忆文件的上限（字符）。超出时从最旧的章节开始丢，保留头部与最近记忆。
  final int maxFileChars;

  /// 回给调用方的预算下限 / 上限（与工具参数口径一致）。
  static const int minBudgetChars = 200;
  static const int maxBudgetChars = 20000;

  /// 记忆文件的工作空间相对路径。
  String memoryPath(String agentId) =>
      '${privateSelfDir(agentId)}/$kMemoryFileName';

  /// 读记忆：只保留**最近** [budgetChars] 个字符（最近记忆更重要）。
  ///
  /// 文件不存在 / 读失败 = 空记忆（不是错误）；工作空间不可用才回
  /// `{error, code: memory_unavailable}`。
  Future<Map<String, dynamic>> get({
    required String agentId,
    String sessionId = '',
    String purpose = '',
    int budgetChars = 4000,
  }) async {
    final String path = memoryPath(agentId);
    final WorkspaceIO? io = await _resolve(agentId, sessionId);
    if (io == null) return _unavailable('工作空间不可用（执行站未接线或该 agent 没有工作空间）');
    final String full = await _readOrEmpty(io, path);
    final int budget = budgetChars.clamp(minBudgetChars, maxBudgetChars);
    final bool truncated = full.length > budget;
    final String text = truncated
        ? '$kMemoryTruncationNotice\n${full.substring(full.length - budget)}'
        : full;
    return <String, dynamic>{
      'ok': true,
      'agent_id': agentId,
      'purpose': purpose,
      'path': path,
      'text': text,
      'hash': _sha256(full),
      'chars': text.length,
      'total_chars': full.length,
      'truncated': truncated,
      'sources': <String>[path],
    };
  }

  /// 追加一条记忆摘要（一节一个 `##` 标题 + 稳定 `memory-id` 标记）。
  ///
  /// 幂等：文件里已有同一个 `memory-id` 就只回 `deduplicated: true`，不重复追加。
  Future<Map<String, dynamic>> record({
    required String agentId,
    String sessionId = '',
    required String summary,
    String purpose = '',
    List<String> sources = const <String>[],
    String lineId = '',
    String taskId = '',
  }) async {
    if (summary.trim().isEmpty) {
      return <String, dynamic>{'error': 'summary 不能为空', 'code': 'invalid_arguments'};
    }
    final String path = memoryPath(agentId);
    final WorkspaceIO? io = await _resolve(agentId, sessionId);
    if (io == null) return _unavailable('工作空间不可用（执行站未接线或该 agent 没有工作空间）');
    final String existing = await _readOrEmpty(io, path);
    final String memoryId = _sha256('$purpose|$taskId|$summary');
    if (existing.contains('memory-id: $memoryId')) {
      return <String, dynamic>{
        'ok': true,
        'agent_id': agentId,
        'path': path,
        'hash': _sha256(existing),
        'chars': existing.length,
        'appended': false,
        'deduplicated': true,
      };
    }
    final String next = _appendSection(
      existing,
      _section(
        summary: summary,
        purpose: purpose,
        sources: sources,
        memoryId: memoryId,
      ),
    );
    try {
      await io.writeFile(path, next);
    } catch (error) {
      return _unavailable('写入记忆失败：$error');
    }
    return <String, dynamic>{
      'ok': true,
      'agent_id': agentId,
      'path': path,
      'hash': _sha256(next),
      'chars': next.length,
      'appended': true,
      'deduplicated': false,
    };
  }

  Future<WorkspaceIO?> _resolve(String agentId, String sessionId) async {
    try {
      return await ioFor(agentId, sessionId);
    } catch (_) {
      return null;
    }
  }

  /// 读文件；不存在 / 读失败都当空记忆（记忆是"有则更好"的附加信息）。
  Future<String> _readOrEmpty(WorkspaceIO io, String path) async {
    try {
      final FileContent content = await io.readFile(path);
      return content.text;
    } catch (_) {
      return '';
    }
  }

  String _section({
    required String summary,
    required String purpose,
    required List<String> sources,
    required String memoryId,
  }) {
    final String title = purpose.trim().isEmpty ? 'memory' : purpose.trim();
    final String sourceText = <String>[
      for (final String item in sources)
        if (item.trim().isNotEmpty) item.trim(),
    ].join(', ');
    return '## ${_clock().toIso8601String()} · $title\n'
        '<!-- memory-id: $memoryId -->\n'
        '- 来源: ${sourceText.isEmpty ? 'memory' : sourceText}\n'
        '- $summary';
  }

  String _appendSection(String existing, String section) {
    final String base = existing.isEmpty ? kMemoryHeader : existing;
    final String separator = base.endsWith('\n\n')
        ? ''
        : (base.endsWith('\n') ? '\n' : '\n\n');
    return _trimToLimit('$base$separator$section\n');
  }

  /// 超出 [maxFileChars] 时从最旧的章节开始丢，保留文件头与最近记忆。
  String _trimToLimit(String content) {
    if (content.length <= maxFileChars) return content;
    final int headerEnd = content.startsWith(kMemoryHeader)
        ? kMemoryHeader.length
        : 0;
    final String header = content.substring(0, headerEnd);
    final List<String> sections = content
        .substring(headerEnd)
        .split('\n## ')
        .where((String item) => item.trim().isNotEmpty)
        .toList();
    final List<String> kept = <String>[];
    int length = header.length;
    for (int i = sections.length - 1; i >= 0; i--) {
      final String piece = '## ${sections[i]}';
      if (kept.isNotEmpty && length + piece.length > maxFileChars) break;
      kept.insert(0, piece);
      length += piece.length + 1;
    }
    return '$header${kept.join('\n')}\n';
  }

  static Map<String, dynamic> _unavailable(String message) =>
      <String, dynamic>{'error': message, 'code': 'memory_unavailable'};
}

String _sha256(String text) =>
    sha256.convert(utf8.encode(text)).toString();
