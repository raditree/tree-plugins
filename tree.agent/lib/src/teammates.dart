import 'agent_store.dart';
import 'model_catalog.dart';
import 'paths.dart';

/// 模型没配 max_seqlen 时的兜底上下文长度（与核心 `CoreSettings.fallbackMaxSeqlen` 同值）。
const int kFallbackMaxSeqlen = 128000;

/// `GET /api/agents/{agentId}/teammates` 的响应体（与核心 `TeamService.teammatesPayload` 同口径）。
///
/// - **名册 = 这个 agent 自己的下属**（TOP ⇒ 整队、成员 ⇒ 后代），不含自己/兄弟/上级；
/// - 未知道 agent ⇒ `self:null` 的空名册（核心不 404）；
/// - `work_status` / `live_status` 在插件侧当前恒为 `idle`：运行期状态在生成循环
///   （A3）搬进来之前没有可信来源；双跑期 HTTP 仍由核心承接，不影响线上。
Map<String, dynamic> teammatesPayload(
  AgentDataPaths paths,
  List<AgentRecord> records,
  String agentId,
) {
  final Map<String, AgentRecord> byId = <String, AgentRecord>{
    for (final AgentRecord record in records) record.id: record,
  };
  final AgentRecord? self = byId[agentId];
  if (self == null) {
    return <String, dynamic>{
      'agent_id': agentId,
      'members': <Map<String, dynamic>>[],
      'pending_member_count': 0,
      'self': null,
    };
  }
  final Map<String, Map<String, dynamic>> models = <String, Map<String, dynamic>>{
    for (final Map<String, dynamic> model in readModels(paths))
      model['model_id'] as String: model,
  };
  final List<AgentRecord> roster = rosterOf(records, self);
  int pending = 0;
  final List<Map<String, dynamic>> members = <Map<String, dynamic>>[];
  for (final AgentRecord member in roster) {
    if (member.reviewStatus == 'pending_model' ||
        member.reviewStatus == 'pending_review') {
      pending++;
    }
    final AgentRecord? leader = byId[member.parentAgentId];
    members.add(<String, dynamic>{
      'id': member.id,
      'name': member.name,
      'role': member.role,
      'duty': member.duty,
      'model_id': member.modelId,
      'level': member.level,
      'can_lead_team': member.canLeadTeam,
      'parent_agent_id': member.parentAgentId,
      'leader_name': leader?.name ?? '',
      'relation': _relation(self, member),
      'work_status': 'idle',
      'review_status': member.reviewStatus,
      'log_path': '.tree/${member.id}/.self/activity.log',
      'created_at': member.createdAt,
      'workspace_id': member.workspaceId,
      'overrides': overridesOf(member),
      'effective': _effective(member, models),
      'live_status': 'idle',
    });
  }
  final String topId = self.teamId.isEmpty ? '' : self.teamId;
  return <String, dynamic>{
    'agent_id': agentId,
    'members': members,
    'pending_member_count': pending,
    'self': <String, dynamic>{
      'id': self.id,
      'name': self.name,
      'level': self.level,
      'is_member': self.teamId.isNotEmpty,
      'top_agent_id': topId,
      'top_agent_name': topId.isEmpty ? '' : (byId[topId]?.name ?? ''),
    },
  };
}

String _relation(AgentRecord self, AgentRecord member) {
  if (member.id == self.id) return 'team_leader';
  if (member.parentAgentId == self.id) return 'direct';
  if (member.parentAgentId == self.parentAgentId &&
      member.parentAgentId.isNotEmpty) {
    return 'peer';
  }
  return 'indirect';
}

/// 有效模型参数（模型默认值 + 成员覆盖；顺序与核心 `_effective` 一致）。
Map<String, Object?> _effective(
  AgentRecord member,
  Map<String, Map<String, dynamic>> models,
) {
  final Map<String, dynamic>? model = models[member.modelId];
  final int modelMaxSeqlen =
      (model?['max_seqlen'] as num?)?.toInt() ?? 0;
  final Object? maxSeqlen = member.maxSeqlenOverride > 0
      ? member.maxSeqlenOverride
      : (model == null
            ? null
            : (modelMaxSeqlen > 0 ? modelMaxSeqlen : kFallbackMaxSeqlen));
  return <String, Object?>{
    'reasoning_effort': member.reasoningEffort.trim().isNotEmpty
        ? member.reasoningEffort
        : (model?['reasoning_effort'] as String? ?? ''),
    'max_seqlen': maxSeqlen,
    'max_output_tokens': member.maxOutputTokens > 0
        ? member.maxOutputTokens
        : ((model?['max_output_tokens'] as num?)?.toInt() ?? 0),
    'thinking':
        member.thinkingOverride ?? ((model?['thinking'] as bool?) ?? false),
  };
}
