import 'dart:convert';
import 'dart:io';

import 'paths.dart';

/// 会话记录（`session.json` 的只读视图）。
class SessionRecord {
  const SessionRecord({
    required this.sessionId,
    required this.agentId,
    required this.title,
    required this.status,
    required this.selectedSpecIds,
    required this.createdAt,
    required this.updatedAt,
  });

  final String sessionId;
  final String agentId;
  final String title;
  final String status;
  final List<String> selectedSpecIds;
  final int createdAt;
  final int updatedAt;
}

/// 扫描某 agent 的会话（`data/<agent>/*/session.json`），按 `updated_at` 降序。
///
/// 与核心 `FileTreeStore._loadAgent` + `sessions()` 同口径：只有目录里存在
/// `session.json` 的才算会话；坏文件跳过；字段默认值同 `CoreSession.fromJson`。
List<SessionRecord> readSessions(AgentDataPaths paths, String agentId) {
  final Directory dir;
  try {
    dir = Directory(paths.agentDataDir(agentId));
  } on ArgumentError {
    return <SessionRecord>[];
  }
  if (!dir.existsSync()) return <SessionRecord>[];
  final List<SessionRecord> out = <SessionRecord>[];
  final int nowMs = DateTime.now().millisecondsSinceEpoch;
  for (final FileSystemEntity entity in dir.listSync()) {
    if (entity is! Directory) continue;
    final File meta = File('${entity.path}/session.json');
    if (!meta.existsSync()) continue;
    try {
      final Object? decoded = jsonDecode(
        utf8.decode(meta.readAsBytesSync(), allowMalformed: true),
      );
      if (decoded is! Map) continue;
      final Map<String, dynamic> json = decoded.map(
        (Object? key, Object? value) => MapEntry(key.toString(), value),
      );
      out.add(_toRecord(json, nowMs));
    } catch (_) {
      // 元数据损坏：核心跳过该会话；这里同样跳过。
    }
  }
  out.sort(
    (SessionRecord a, SessionRecord b) =>
        b.updatedAt.compareTo(a.updatedAt),
  );
  return out;
}

SessionRecord _toRecord(Map<String, dynamic> json, int nowMs) {
  return SessionRecord(
    sessionId: json['session_id'] as String? ?? 'session_default',
    agentId: json['agent_id'] as String? ?? '',
    title: json['title'] as String? ?? '新会话',
    status: json['status'] as String? ?? 'active',
    selectedSpecIds:
        (json['selected_spec_ids'] as List<dynamic>?)
            ?.map((dynamic e) => e.toString())
            .toList() ??
        <String>[],
    createdAt: _decodeTime(json['created_at']) ?? nowMs,
    updatedAt: _decodeTime(json['updated_at']) ?? nowMs,
  );
}

/// 取一个会话；不存在返回 null。
SessionRecord? findSession(
  AgentDataPaths paths,
  String agentId,
  String sessionId,
) {
  for (final SessionRecord session in readSessions(paths, agentId)) {
    if (session.sessionId == sessionId) return session;
  }
  return null;
}

/// 默认会话兜底（与核心 `ensureDefaultSession` 同语义：**只在缺失时创建**）。
///
/// 注意：这是一个"读接口里的写副作用"——核心的 `GET /api/agents/{id}/sessions`
/// 本来就会建默认会话；插件要复刻等价行为，不能悄悄省掉。
SessionRecord ensureDefaultSession(
  AgentDataPaths paths,
  String agentId,
) {
  final SessionRecord? existing = findSession(paths, agentId, 'session_default');
  if (existing != null) return existing;
  final int nowMs = DateTime.now().millisecondsSinceEpoch;
  final SessionRecord created = SessionRecord(
    sessionId: 'session_default',
    agentId: agentId,
    title: '默认会话',
    status: 'active',
    selectedSpecIds: const <String>[],
    createdAt: nowMs,
    updatedAt: nowMs,
  );
  final File file = File(paths.sessionMetaFile(agentId, 'session_default'));
  file.parent.createSync(recursive: true);
  final String tmp = '${file.path}.plugin-tmp';
  File(tmp).writeAsStringSync(
    jsonEncode(<String, dynamic>{
      'session_id': created.sessionId,
      'agent_id': created.agentId,
      'title': created.title,
      'status': created.status,
      'selected_spec_ids': created.selectedSpecIds,
      'compacted_summary': '',
      'compacted_message_count': 0,
      'created_at': _encodeTime(created.createdAt),
      'updated_at': _encodeTime(created.updatedAt),
    }),
  );
  File(tmp).renameSync(file.path);
  return created;
}

/// 会话 API（8 键，顺序与核心 `CoreSession.toApiJson` 一致）。
Map<String, dynamic> sessionApiJson(
  SessionRecord session, {
  required int messageCount,
}) => <String, dynamic>{
  'session_id': session.sessionId,
  'agent_id': session.agentId,
  'title': session.title,
  'status': session.status,
  'selected_spec_ids': session.selectedSpecIds,
  'message_count': messageCount,
  'created_at': session.createdAt,
  'updated_at': session.updatedAt,
};

String _encodeTime(int ms) =>
    DateTime.fromMillisecondsSinceEpoch(ms).toIso8601String();

int? _decodeTime(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toInt();
  if (value is String && value.isNotEmpty) {
    final String text = value.trim();
    if (RegExp(r'^-?\d+$').hasMatch(text)) return int.tryParse(text);
    return DateTime.tryParse(text)?.millisecondsSinceEpoch;
  }
  return null;
}
