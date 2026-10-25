import 'dart:convert';
import 'dart:io';

import 'paths.dart';

/// 读某会话的临时员工名册：`data/<agent>/<session>/subagents.json`。
///
/// 与核心 `FileTreeStore._loadSubagents` + `CoreSubagent.toRosterJson` 同一口径：
/// - 文件不存在 / 空 / JSON 坏 / 结构不对 ⇒ 空名册（核心只记日志，不阻断会话）；
/// - 单项字段类型不符 ⇒ **整份名册当空**：核心的 `fromJson` 走 `as` 强转，异常被
///   文件级 catch 吞掉；这里选同样的退化方向（不是逐项跳过）；
/// - 时间字段接受 ISO 串或毫秒整数；缺失/不可解析回 `now`，再按核心
///   `JsonTime.encode` 的本地 ISO 形态写出——正常由核心写出的文件逐字往返。
///
/// `agent`（运行配置快照）**不读**：名册视图（`toRosterJson`）本来就不含它。
/// 代价是"名册文件本身合法、但嵌套的 agent 块字段类型错误"时核心会当空名册，
/// 而这里仍能返回条目——这是刻意接受的退化差异（正常文件不受影响）。
List<Map<String, dynamic>> readSubagentRoster(
  AgentDataPaths paths,
  String agentId,
  String sessionId, {
  DateTime Function()? now,
}) {
  final File file = File(paths.subagentsFile(agentId, sessionId));
  if (!file.existsSync()) return <Map<String, dynamic>>[];
  final String text = utf8.decode(
    file.readAsBytesSync(),
    allowMalformed: true,
  );
  if (text.trim().isEmpty) return <Map<String, dynamic>>[];
  final int nowMs = (now?.call() ?? DateTime.now()).millisecondsSinceEpoch;
  try {
    final Object? decoded = jsonDecode(text);
    final Object? raw = decoded is Map ? decoded['subagents'] : decoded;
    if (raw is! List) return <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (final Object? item in raw) {
      if (item is! Map) continue;
      final Map<String, dynamic> json = item.map(
        (Object? key, Object? value) => MapEntry(key.toString(), value),
      );
      final Map<String, dynamic>? roster = _toRoster(json, nowMs);
      if (roster == null) continue; // id 为空：核心同样跳过
      out.add(roster);
    }
    return out;
  } catch (_) {
    return <Map<String, dynamic>>[];
  }
}

Map<String, dynamic>? _toRoster(Map<String, dynamic> json, int nowMs) {
  final String id = _string(json, 'id') ?? '';
  if (id.isEmpty) return null;
  return <String, dynamic>{
    'id': id,
    'name': _string(json, 'name') ?? '',
    'owner_agent_id': _string(json, 'owner_agent_id') ?? '',
    'session_id': _string(json, 'session_id') ?? '',
    'parent_id': _string(json, 'parent_id') ?? '',
    'level': _int(json, 'level') ?? 1,
    'scope': _string(json, 'scope') ?? '',
    'run_count': _int(json, 'run_count') ?? 0,
    'created_at': _time(json['created_at'], nowMs),
    'updated_at': _time(json['updated_at'], nowMs),
  };
}

/// 与核心 `as String?` 同口径：缺键/null ⇒ null；非字符串 ⇒ 抛（整份名册作废）。
String? _string(Map<String, dynamic> json, String key) {
  final Object? value = json[key];
  if (value == null) return null;
  if (value is String) return value;
  throw const FormatException('字段类型不符');
}

/// 与核心 `as num?` 同口径。
int? _int(Map<String, dynamic> json, String key) {
  final Object? value = json[key];
  if (value == null) return null;
  if (value is num) return value.toInt();
  throw const FormatException('字段类型不符');
}

String _time(Object? value, int nowMs) {
  final int ms = _decodeTime(value) ?? nowMs;
  return DateTime.fromMillisecondsSinceEpoch(ms).toIso8601String();
}

/// 核心 `JsonTime.decode` 的同一口径：ISO 串 / 毫秒整数 / 纯数字字符串。
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
