import 'dart:convert';
import 'dart:io';

import 'paths.dart';
import 'yaml_utils.dart';

/// agent 记录（`agents/<id>.yaml` 的只读视图；`GET /api/agents` 的字段来源）。
///
/// 只解析列表接口需要的键；`CoreAgent.fromJson` 里那些与列表无关的字段
/// （max_level / scores / ssh 细节……）故意不读。正常文件不受影响；"无关字段写坏"
/// 时核心可能跳过该文件、本视图仍能返回，属于可接受的退化差异。
class AgentRecord {
  const AgentRecord({
    required this.id,
    required this.name,
    required this.systemPrompt,
    required this.modelId,
    required this.workspaceId,
    required this.workspaceDir,
    required this.hasSsh,
    required this.sshView,
    required this.teamId,
    required this.parentAgentId,
    required this.level,
    required this.role,
    required this.duty,
    required this.canLeadTeam,
    required this.reviewStatus,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String systemPrompt;
  final String modelId;
  final String workspaceId;
  final String workspaceDir;
  final bool hasSsh;

  /// SSH 配置的前端形态（`SshConfig.redacted()` + `key_path`）；无配置 = null。
  final Map<String, dynamic>? sshView;

  final String teamId;
  final String parentAgentId;
  final int level;
  final String role;
  final String duty;
  final bool canLeadTeam;
  final String reviewStatus;
  final int createdAt;
  final int updatedAt;
}

/// 扫描 `agents/*.yaml`。
///
/// 与核心 `FileTreeStore._scanAgents` 同口径：只认 `.yaml`、解析失败/缺 id 跳过、
/// **按文件里的 `id`** 建表（不是文件名）、同 id 后读覆盖先读。
///
/// 排序由调用方做：核心 `agents()` 按 `updatedAt` 降序；本函数保持扫描顺序，
/// 让调用方用同一比较器得到与核心相同的顺序（Dart sort 对相同输入是确定的）。
List<AgentRecord> readAgentRecords(AgentDataPaths paths) {
  final Directory dir = Directory(paths.agentsDir);
  if (!dir.existsSync()) return <AgentRecord>[];
  final Map<String, AgentRecord> byId = <String, AgentRecord>{};
  final int nowMs = DateTime.now().millisecondsSinceEpoch;
  for (final FileSystemEntity entity in dir.listSync()) {
    if (entity is! File || !entity.path.endsWith('.yaml')) continue;
    final Map<String, dynamic>? json = readYamlMap(entity);
    if (json == null) continue;
    try {
      final AgentRecord? record = _toRecord(json, nowMs);
      if (record == null) continue;
      byId[record.id] = record;
    } catch (_) {
      continue; // 字段类型不符：与核心同一取舍（跳过该文件）
    }
  }
  return byId.values.toList();
}

/// 读单个 agent（按文件路径，不看文件名与 id 是否一致；与 `store.agent(id)` 同口径）。
///
/// 文件不存在 / 解析失败 / 字段类型不符 ⇒ null（端点按"agent 不存在"处理）。
AgentRecord? readAgentRecord(AgentDataPaths paths, String agentId) {
  final Map<String, dynamic>? json;
  try {
    json = readYamlMap(File(paths.agentFile(agentId)));
  } on ArgumentError {
    return null; // 非法 id：fail-closed
  }
  if (json == null) return null;
  try {
    return _toRecord(json, DateTime.now().millisecondsSinceEpoch);
  } catch (_) {
    return null;
  }
}

/// `SshConfig.redacted()` + `key_path` 的同一形态；`host` 为空 ⇒ null（与 `parse` 一致）。
Map<String, dynamic>? _sshViewOf(Object? raw) {
  if (raw is! Map) return null;
  final Map<String, dynamic> map = raw.map(
    (Object? key, Object? value) => MapEntry(key.toString(), value),
  );
  final String host = (map['host'] ?? '').toString().trim();
  if (host.isEmpty) return null;
  final String username = (map['username'] ?? map['user'] ?? '')
      .toString()
      .trim();
  final String password = (map['password'] ?? '').toString();
  final String keyPath =
      (map['key_path'] ??
              map['keyPath'] ??
              map['private_key_path'] ??
              map['privateKeyPath'] ??
              '')
          .toString()
          .trim();
  final String root =
      (map['root'] ??
              map['remote_root'] ??
              map['remoteRoot'] ??
              map['dir'] ??
              map['remote_base_dir'] ??
              '')
          .toString()
          .trim();
  final Object? loginShellRaw = map['login_shell'] ?? map['loginShell'];
  final Object? loginShell = loginShellRaw == null
      ? null
      : (loginShellRaw is bool
            ? (loginShellRaw ? null : '')
            : loginShellRaw.toString().trim());
  return <String, dynamic>{
    'host': host,
    'port': _sshPort(map['port']),
    'username': username,
    'auth': password.isNotEmpty
        ? 'password'
        : (keyPath.isNotEmpty ? 'key' : 'none'),
    if (root.isNotEmpty) 'root': root,
    'login_shell': ?loginShell,
    if (keyPath.isNotEmpty) 'key_path': keyPath,
  };
}

int _sshPort(Object? raw) {
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw.trim()) ?? 22;
  return 22;
}

AgentRecord? _toRecord(Map<String, dynamic> json, int nowMs) {
  final String id = json['id'] as String? ?? '';
  if (id.isEmpty) return null; // 核心会生成新 id；本视图无法复刻随机值，跳过（正常文件都带 id）
  final Map<String, dynamic>? sshView = _sshViewOf(json['ssh']);
  return AgentRecord(
    id: id,
    name: json['name'] as String? ?? '',
    systemPrompt: json['system_prompt'] as String? ?? '',
    modelId: json['model_id'] as String? ?? '',
    workspaceId: json['workspace_id'] as String? ?? '',
    workspaceDir: json['workspace_dir'] as String? ?? '',
    hasSsh: sshView != null,
    sshView: sshView,
    teamId: json['team_id'] as String? ?? '',
    parentAgentId: json['parent_agent_id'] as String? ?? '',
    level: (json['level'] as num?)?.toInt() ?? 0,
    role: json['role'] as String? ?? '',
    duty: json['duty'] as String? ?? '',
    canLeadTeam: json['can_lead_team'] as bool? ?? true,
    reviewStatus: json['review_status'] as String? ?? '',
    createdAt: _decodeTime(json['created_at']) ?? nowMs,
    updatedAt: _decodeTime(json['updated_at']) ?? nowMs,
  );
}

/// 前端形态（`AgentApi` 22 键，顺序与核心 `CoreAgent.toApiJson` 一致）。
Map<String, dynamic> agentApiJson(
  AgentRecord agent, {
  required String lastMessage,
  required int? lastMessageTime,
  required int pendingMemberCount,
}) => <String, dynamic>{
  'id': agent.id,
  'name': agent.name,
  'type': 'normal',
  'system_prompt': agent.systemPrompt,
  'model_id': agent.modelId,
  'workspace_id': agent.workspaceId,
  'workspace_dir': agent.workspaceDir,
  'has_ssh': agent.hasSsh,
  'last_message': lastMessage,
  'last_message_time': lastMessageTime,
  'unread_count': 0,
  'avatar_url': null,
  'pending_member_count': pendingMemberCount,
  'team_id': agent.teamId,
  'parent_agent_id': agent.parentAgentId,
  'level': agent.level,
  'role': agent.role,
  'duty': agent.duty,
  'can_lead_team': agent.canLeadTeam,
  'review_status': agent.reviewStatus,
  'created_at': agent.createdAt,
  'updated_at': agent.updatedAt,
};

/// 预览：最后一条 **agent 文本消息**（与核心 `FileTreeStore.lastTextMessage` 同口径）。
class TextPreview {
  const TextPreview(this.content, this.timestamp);

  final String content;
  final int timestamp;
}

/// 与核心 `_previewTailBytes` 同值：每份 messages.jsonl 只倒读最后 32 KiB。
const int kPreviewTailBytes = 32 * 1024;

/// 跨会话取"最新会话里最后一条 agent 文本消息"。
///
/// 会话按 `session.json` 的 `updated_at` 降序；逐会话倒读消息尾部，跳过
/// `kind == 'tool'`、非 `role == 'agent'`、以及临时员工的消息（`subagent_id` 非空）。
TextPreview? lastTextPreview(AgentDataPaths paths, String agentId) {
  for (final String sessionId in _sessionsByUpdated(paths, agentId)) {
    final TextPreview? preview = _previewOf(paths, agentId, sessionId);
    if (preview != null) return preview;
  }
  return null;
}

List<String> _sessionsByUpdated(AgentDataPaths paths, String agentId) {
  final Directory dir;
  try {
    dir = Directory(paths.agentDataDir(agentId));
  } on ArgumentError {
    return <String>[];
  }
  if (!dir.existsSync()) return <String>[];
  final List<({String id, int updatedAt})> rows =
      <({String id, int updatedAt})>[];
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
      final Map<String, dynamic> json = plainMap(decoded);
      final String sessionId =
          json['session_id'] as String? ?? 'session_default';
      if (sessionId.isEmpty) continue;
      rows.add((
        id: sessionId,
        updatedAt: _decodeTime(json['updated_at']) ?? nowMs,
      ));
    } catch (_) {
      // 会话元数据损坏：核心跳过该会话；这里同样跳过。
    }
  }
  rows.sort(
    (({String id, int updatedAt}) a, ({String id, int updatedAt}) b) =>
        b.updatedAt.compareTo(a.updatedAt),
  );
  return <String>[for (final ({String id, int updatedAt}) row in rows) row.id];
}

TextPreview? _previewOf(
  AgentDataPaths paths,
  String agentId,
  String sessionId,
) {
  final String? text = _readTailOrNull(paths.messagesFile(agentId, sessionId));
  if (text == null || text.isEmpty) return null;
  final List<Map<String, dynamic>> records = _decodeJsonl(text);
  for (final Map<String, dynamic> json in records.reversed) {
    final String role = json['role'] as String? ?? 'agent';
    final String kind = json['kind'] as String? ?? 'text';
    final String subagentId = json['subagent_id'] as String? ?? '';
    if (kind == 'tool' || role != 'agent' || subagentId.isNotEmpty) continue;
    return TextPreview(
      json['content'] as String? ?? '',
      _decodeTime(json['timestamp']) ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }
  return null;
}

/// 与 `AtomicFile.readTailOrNullSync` 同口径：读最后 32 KiB；从中间截断时丢掉
/// 第一段半行（否则那半行会被当成损坏行，而它本来就不该参与解析）。
String? _readTailOrNull(String path) {
  final File file = File(path);
  if (!file.existsSync()) return null;
  final int length = file.lengthSync();
  if (length == 0) return '';
  final int start = length > kPreviewTailBytes ? length - kPreviewTailBytes : 0;
  final RandomAccessFile handle = file.openSync();
  try {
    handle.setPositionSync(start);
    final List<int> bytes = handle.readSync(length - start);
    String text = utf8.decode(bytes, allowMalformed: true);
    if (start > 0) {
      final int firstBreak = text.indexOf('\n');
      text = firstBreak < 0 ? '' : text.substring(firstBreak + 1);
    }
    return text;
  } finally {
    handle.closeSync();
  }
}

List<Map<String, dynamic>> _decodeJsonl(String text) {
  final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
  for (final String raw in const LineSplitter().convert(text)) {
    final String line = raw.trim();
    if (line.isEmpty) continue;
    try {
      final Object? decoded = jsonDecode(line);
      if (decoded is Map<String, dynamic>) out.add(decoded);
    } catch (_) {
      // 损坏行跳过（与核心 `decodeJsonl` 同口径）。
    }
  }
  return out;
}

/// `pending_member_count`：**自己的下属**里 `review_status ∈ {pending_model, pending_review}`。
///
/// 与 `TeamService.pendingMemberCountFor` 同口径：TOP（`team_id` 空）⇒ 整队成员；
/// 成员 ⇒ 自己的后代（BFS）。名册顺序按 `created_at` 升序、同刻按 id（与核心
/// `TreeStore.members` 一致），计数本身与顺序无关。
int pendingMemberCountOf(List<AgentRecord> records, AgentRecord self) {
  final List<AgentRecord> members;
  if (self.teamId.isEmpty) {
    members = _membersOf(records, self.id);
  } else {
    final Map<String, List<AgentRecord>> children =
        <String, List<AgentRecord>>{};
    for (final AgentRecord member in _membersOf(records, self.teamId)) {
      children.putIfAbsent(member.parentAgentId, () => <AgentRecord>[]).add(
        member,
      );
    }
    members = <AgentRecord>[];
    final List<AgentRecord> cursor = <AgentRecord>[self];
    for (int i = 0; i < cursor.length; i++) {
      final List<AgentRecord> kids =
          children[cursor[i].id] ?? const <AgentRecord>[];
      members.addAll(kids);
      cursor.addAll(kids);
    }
  }
  int pending = 0;
  for (final AgentRecord member in members) {
    if (member.reviewStatus == 'pending_model' ||
        member.reviewStatus == 'pending_review') {
      pending++;
    }
  }
  return pending;
}

List<AgentRecord> _membersOf(List<AgentRecord> records, String teamId) {
  final List<AgentRecord> list = records
      .where((AgentRecord record) => record.teamId == teamId)
      .toList()
    ..sort(
      (AgentRecord a, AgentRecord b) => a.createdAt == b.createdAt
          ? a.id.compareTo(b.id)
          : a.createdAt.compareTo(b.createdAt),
    );
  return list;
}

/// 核心 `JsonTime.decode` 的同一口径。
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
