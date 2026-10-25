import 'dart:convert';

import 'agent_config.dart';
import 'agent_store.dart';
import 'model_catalog.dart';
import 'paths.dart';
import 'subagent_store.dart';
import 'todo_store.dart';

/// A2 已搬的只读路由（`G-1 对照表` 的编号见注释）。
const String todosPattern = '/api/agents/{agentId}/todos'; // agent 定义 #7
const String subagentsPattern = '/api/agents/{agentId}/subagents'; // 子 agent #8
const String agentsPattern = '/api/agents'; // agent 列表 #1
const String modelsPattern = '/api/models'; // 模型池 #14
const String agentModelsInfoPattern =
    '/api/agents/{agentId}/models-info'; // agent 定义 #6

/// 处理一次 `api/delegate`（核心 → 插件）。
///
/// 信封字段（固定，缺任何一个都视为契约不完整）：`method / path / params / query /
/// headers / scope / workspace_dir / data_dir / agent_id / team_id / request_id`，
/// 小 JSON 带 `body`、大体积带 `body_path`。
///
/// 回包固定为 `{status, headers?, body? | result_path?}`，**body 是字符串**（核心按
/// Content-Type 原样写回 HTTP）。未实现的路由回 501 + 可读原因——委派语义里
/// 404 表示"核心没有这个接口"，而这里是"插件还没搬"。
Future<Map<String, dynamic>> handleApiDelegate(
  Map<String, dynamic> envelope,
) async {
  final String method = _str(envelope['method']).toUpperCase();
  final String path = _str(envelope['path']);
  final String dataDir = _str(envelope['data_dir']);
  final Map<String, dynamic> params = _map(envelope['params']);
  final Map<String, dynamic> query = _map(envelope['query']);
  if (dataDir.isEmpty) {
    return _jsonReply(500, <String, dynamic>{
      'detail': '委派信封缺少 data_dir（核心契约不完整）',
    });
  }
  final AgentDataPaths paths = AgentDataPaths(dataDir);

  // 全局只读：agent 列表（22 键 + 预览 + 待处理成员数，按 updatedAt 降序）。
  if (method == 'GET' && _matches(agentsPattern, path)) {
    final List<AgentRecord> records = readAgentRecords(paths)
      ..sort(
        (AgentRecord a, AgentRecord b) =>
            b.updatedAt.compareTo(a.updatedAt),
      );
    final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
    for (final AgentRecord record in records) {
      final TextPreview? preview = lastTextPreview(paths, record.id);
      items.add(
        agentApiJson(
          record,
          lastMessage: preview?.content ?? '',
          lastMessageTime: preview?.timestamp,
          pendingMemberCount: pendingMemberCountOf(records, record),
        ),
      );
    }
    return _jsonReply(200, <String, dynamic>{'agents': items});
  }

  // 全局只读：模型池（不需要 agent）。
  if (method == 'GET' && _matches(modelsPattern, path)) {
    return _jsonReply(200, <String, dynamic>{'models': readModels(paths)});
  }

  if (method == 'GET' &&
      (_matches(todosPattern, path) ||
          _matches(subagentsPattern, path) ||
          _matches(agentModelsInfoPattern, path))) {
    final String agentId = _str(params['agentId']);
    final String sessionId = _sessionOf(query);
    final AgentConfigView? agent;
    try {
      agent = readAgentConfig(paths, agentId);
    } on ArgumentError {
      // 非法 id（含路径分隔符等）：按"agent 不存在"fail-closed，不回显路径规则。
      return _jsonReply(404, <String, dynamic>{'detail': 'agent 不存在'});
    }
    if (agent == null) {
      return _jsonReply(404, <String, dynamic>{'detail': 'agent 不存在'});
    }
    if (_matches(todosPattern, path)) {
      final List<TodoItem> todos = readTodos(paths, agentId, sessionId);
      return _jsonReply(200, <String, dynamic>{
        'todos': todos.map((TodoItem todo) => todo.toApiJson()).toList(),
        'session_id': sessionId,
      });
    }
    if (_matches(subagentsPattern, path)) {
      final List<Map<String, dynamic>> roster = readSubagentRoster(
        paths,
        agentId,
        sessionId,
      );
      return _jsonReply(200, <String, dynamic>{
        'agent_id': agentId,
        'session_id': sessionId,
        'total': roster.length,
        'subagents': roster,
      });
    }
    // models-info：agent 三键 + 模型池 + 真正设置过的覆盖项。
    return _jsonReply(200, <String, dynamic>{
      'agent': <String, dynamic>{
        'id': agent.id,
        'model_id': agent.modelId,
        'system_prompt': agent.systemPrompt,
      },
      'models': readModels(paths),
      'overrides': memberOverridesOf(agent),
    });
  }

  return _jsonReply(501, <String, dynamic>{
    'detail': 'tree.agent 尚未实现该路由：$method $path',
  });
}

/// 路径模板匹配（`{name}` 段匹配任意非空段；其余段逐字相等）。
bool _matches(String pattern, String path) {
  final List<String> want = pattern.split('/');
  final List<String> got = path.split('/');
  if (want.length != got.length) return false;
  for (int i = 0; i < want.length; i++) {
    final String segment = want[i];
    if (segment.length >= 2 &&
        segment.startsWith('{') &&
        segment.endsWith('}')) {
      if (got[i].isEmpty) return false;
      continue;
    }
    if (segment != got[i]) return false;
  }
  return true;
}

Map<String, dynamic> _jsonReply(int status, Map<String, dynamic> body) =>
    <String, dynamic>{
      'status': status,
      'headers': <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
      'body': jsonEncode(body),
    };

/// 会话 id：缺省/空 ⇒ `session_default`（与核心 `TreeStore.defaultSessionId` 同值）。
String _sessionOf(Map<String, dynamic> query) {
  final String raw = _str(query['session_id']);
  return raw.isEmpty ? 'session_default' : raw;
}

String _str(Object? value) => (value ?? '').toString().trim();

Map<String, dynamic> _map(Object? value) => value is Map
    ? value.map(
        (Object? key, Object? item) => MapEntry(key.toString(), item),
      )
    : <String, dynamic>{};
