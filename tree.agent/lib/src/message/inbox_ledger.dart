import 'dart:async';
import 'dart:convert';

import '../store/atomic_file.dart';
import '../store/write_queue.dart';

/// 收件箱消息状态（`inbox.jsonl` 的 `status` 字段）。
///
/// 口径见 `docs/pluginization/agent-loop-restructure-recon.md` §3.5：
/// `pending` 未开始、`inflight` 已开始、`done` 已注入、`failed` 处理失败、
/// `cancelled` 被 stop 显式作废。崩溃恢复只把 `inflight` 改回 `pending`。
enum InboxStatus {
  pending('pending'),
  inflight('inflight'),
  done('done'),
  failed('failed'),
  cancelled('cancelled');

  const InboxStatus(this.wire);

  /// 落盘字符串。
  final String wire;

  /// 宽容解析：无法识别返回 null（调用方决定按 `pending` 兜底还是跳过）。
  static InboxStatus? tryParse(Object? raw) {
    final String value = (raw ?? '').toString().trim();
    for (final InboxStatus status in InboxStatus.values) {
      if (status.wire == value) return status;
    }
    return null;
  }
}

/// 一条收件箱记录（由多行追加日志合并出的**当前状态**）。
class InboxEntry {
  const InboxEntry({
    required this.messageId,
    required this.envelope,
    required this.status,
    required this.attempts,
    required this.enqueuedAt,
    required this.updatedAt,
    this.error = '',
  });

  /// 发起者给出的稳定消息 id（幂等键）。
  final String messageId;

  /// 完整消息信封（形状见 recon §3.1）。
  final Map<String, dynamic> envelope;

  /// 当前状态。
  final InboxStatus status;

  /// 已尝试处理次数。
  final int attempts;

  /// 入队时间（毫秒）。
  final int enqueuedAt;

  /// 最近状态变更时间（毫秒）。
  final int updatedAt;

  /// 失败原因（`failed` 时非空）。
  final String error;

  /// 是否还需要处理（崩溃恢复后 `inflight` 也会变成 `pending`）。
  bool get isRunnable => status == InboxStatus.pending;

  /// 序列化（完整快照；测试与排障用）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'message_id': messageId,
    'envelope': envelope,
    'status': status.wire,
    'attempts': attempts,
    'enqueued_at': enqueuedAt,
    'updated_at': updatedAt,
    if (error.isNotEmpty) 'error': error,
  };
}

/// 会话级收件箱台账（AC-1 的零丢失基础）。
///
/// 设计要点：
/// - **追加写**：每条记录一行 JSON；状态变更只追加 `{message_id, status, ...}` 增量行，
///   不重写整个文件。读取时按 `message_id` 合并，后出现的状态覆盖先出现的。
/// - **回执前落盘**：[appendPending] 返回时该行已 flush；调用方随后才向发起者回执。
/// - **崩溃恢复**：[recover] 把 `inflight` 改回 `pending`；重放方靠 `messageId` 去重。
/// - **坏行容忍**：半行/非法 JSON 跳过，不让一条坏记录拖垮整个收件箱。
///
/// 本类**不**决定消息如何注入上下文；那是消息机（AC-2）的职责。
class MessageInbox {
  MessageInbox({required this.path, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// `inbox.jsonl` 的绝对路径（来自 `AgentDataPaths.inboxFile`）。
  final String path;

  final DateTime Function() _clock;

  /// 同一文件的追加写串行化（不同文件本类实例各自独立）。
  final WriteQueue _writes = WriteQueue();

  /// 追加一条 `pending` 消息并等待落盘（返回即已 flush）。
  ///
  /// [envelope] 必须带非空 `message_id`；其余字段原样保存，台账不解释语义。
  Future<void> appendPending(Map<String, dynamic> envelope) async {
    final String messageId = (envelope['message_id'] ?? '').toString().trim();
    if (messageId.isEmpty) {
      throw ArgumentError.value(
        envelope['message_id'],
        'envelope.message_id',
        '入站消息必须带非空 message_id',
      );
    }
    final int now = _now();
    await _append(<String, dynamic>{
      'message_id': messageId,
      'envelope': envelope,
      'status': InboxStatus.pending.wire,
      'attempts': 0,
      'enqueued_at': now,
      'updated_at': now,
    });
  }

  /// 标记开始处理（`inflight`）；同时把尝试次数 +1。
  Future<void> markInflight(String messageId) async {
    final List<InboxEntry> entries = await readAll();
    final InboxEntry? current = _find(entries, messageId);
    final int attempts = (current?.attempts ?? 0) + 1;
    await _append(<String, dynamic>{
      'message_id': messageId,
      'status': InboxStatus.inflight.wire,
      'attempts': attempts,
      'updated_at': _now(),
    });
  }

  /// 标记已注入完成。
  Future<void> markDone(String messageId) =>
      _appendStatus(messageId, InboxStatus.done);

  /// 标记处理失败（原因写入增量行）。
  Future<void> markFailed(String messageId, String error) =>
      _appendStatus(messageId, InboxStatus.failed, error: error);

  /// 标记被 stop 显式作废。
  Future<void> markCancelled(String messageId, {String reason = ''}) =>
      _appendStatus(messageId, InboxStatus.cancelled, error: reason);

  /// 崩溃恢复：把所有 `inflight` 改回 `pending`，返回被恢复的条数。
  ///
  /// 幂等：没有 `inflight` 时返回 0，不写任何行。
  Future<int> recover() async {
    final List<InboxEntry> entries = await readAll();
    final List<InboxEntry> inflight = entries
        .where((InboxEntry e) => e.status == InboxStatus.inflight)
        .toList(growable: false);
    for (final InboxEntry entry in inflight) {
      await _appendStatus(entry.messageId, InboxStatus.pending);
    }
    return inflight.length;
  }

  /// 读取全部记录（按 `message_id` 合并增量行，按入队时间稳定排序）。
  Future<List<InboxEntry>> readAll() async {
    await _writes.drain(path);
    final String? text = await AtomicFile.readStringOrNull(path);
    if (text == null || text.trim().isEmpty) return const <InboxEntry>[];

    final List<Map<String, dynamic>> records = AtomicFile.decodeJsonl(text).records;
    // 第一遍：找每条消息的初始记录（带 envelope 的那一行）。
    final Map<String, Map<String, dynamic>> merged = <String, Map<String, dynamic>>{};
    for (final Map<String, dynamic> record in records) {
      final String id = (record['message_id'] ?? '').toString().trim();
      final Object? envelope = record['envelope'];
      if (id.isEmpty || envelope is! Map) continue;
      if (merged.containsKey(id)) continue;
      merged[id] = <String, dynamic>{
        'message_id': id,
        'envelope': Map<String, dynamic>.from(envelope),
        'status': record['status'] ?? InboxStatus.pending.wire,
        'attempts': record['attempts'] ?? 0,
        'enqueued_at': record['enqueued_at'] ?? 0,
        'updated_at': record['updated_at'] ?? 0,
        'error': record['error'] ?? '',
      };
    }
    // 第二遍：按文件顺序应用状态增量（后写覆盖先写）。
    for (final Map<String, dynamic> record in records) {
      final String id = (record['message_id'] ?? '').toString().trim();
      final Map<String, dynamic>? target = merged[id];
      if (target == null) continue;
      for (final String key in <String>[
        'status',
        'attempts',
        'updated_at',
        'error',
        'enqueued_at',
      ]) {
        if (record.containsKey(key)) target[key] = record[key];
      }
    }

    final List<InboxEntry> entries = <InboxEntry>[
      for (final Map<String, dynamic> raw in merged.values)
        InboxEntry(
          messageId: '${raw['message_id'] ?? ''}',
          envelope: Map<String, dynamic>.from(raw['envelope'] as Map),
          // 无法识别的状态按 pending 兜底：宁可重放一次，也不静默丢消息。
          status:
              InboxStatus.tryParse(raw['status']) ?? InboxStatus.pending,
          attempts: (raw['attempts'] as num?)?.toInt() ?? 0,
          enqueuedAt: (raw['enqueued_at'] as num?)?.toInt() ?? 0,
          updatedAt: (raw['updated_at'] as num?)?.toInt() ?? 0,
          error: '${raw['error'] ?? ''}',
        ),
    ];
    entries.sort((InboxEntry a, InboxEntry b) {
      final int byTime = a.enqueuedAt.compareTo(b.enqueuedAt);
      return byTime != 0 ? byTime : a.messageId.compareTo(b.messageId);
    });
    return entries;
  }

  /// 尚未处理的消息（`pending`；调用前通常先 [recover]）。
  Future<List<InboxEntry>> pending() async {
    final List<InboxEntry> entries = await readAll();
    return entries
        .where((InboxEntry e) => e.status == InboxStatus.pending)
        .toList(growable: false);
  }

  /// 等待全部在途写入完成（关停与测试必须调用）。
  Future<void> flush() => _writes.flush();

  Future<void> _appendStatus(
    String messageId,
    InboxStatus status, {
    String error = '',
  }) {
    return _append(<String, dynamic>{
      'message_id': messageId,
      'status': status.wire,
      'updated_at': _now(),
      if (error.isNotEmpty) 'error': error,
    });
  }

  Future<void> _append(Map<String, dynamic> record) {
    final Completer<void> done = Completer<void>();
    _writes.enqueue(path, () async {
      try {
        await AtomicFile.appendLine(path, jsonEncode(record));
        if (!done.isCompleted) done.complete();
      } catch (error, stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      }
    });
    return done.future;
  }

  int _now() => _clock().millisecondsSinceEpoch;

  static InboxEntry? _find(List<InboxEntry> entries, String messageId) {
    for (final InboxEntry entry in entries) {
      if (entry.messageId == messageId) return entry;
    }
    return null;
  }
}
