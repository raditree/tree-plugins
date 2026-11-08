/// **Agent loop 执行站**（AC-5）：其它插件向某个 agent 发消息、查询状态快照。
///
/// 与 `agent_tools` 分站：这里是"消息机 / 状态机"的站点面，不承载模型工具原语。
const String kAgentLoopStationName = 'agent_loop';

String agentLoopStationId(String pluginId) =>
    'plugin.$pluginId.execute.$kAgentLoopStationName';

/// 命令（契约 §3.7）：
/// - `agent.message.send`：入参 = 消息信封；`source` 由核心 `meta` 强制覆盖；
/// - `agent.state.list`：全部 agent 的状态快照（晚订阅者的权威读法）；
/// - `agent.state.get`：按 `agent_id` / `session_id` 过滤的同一形状。
const List<String> kAgentLoopCommands = <String>[
  'agent.message.send',
  'agent.state.list',
  'agent.state.get',
];

const String kAgentLoopReadme =
    'tree.agent 的 Agent loop 站点面。agent.message.send：入参是消息信封（'
    'message_id/type/subtype/inject_mode/source/target/content），source 由核心 '
    'meta 强制覆盖为 plugin_<调用方插件 id>（伪造无效）；回包 '
    '{ok, message_id, agent_id, session_id, queued, state}。'
    'agent.state.list / agent.state.get：返回 '
    '{agents:[{team_id, agent_id, state, updated_at, sessions:[{session_id, state, '
    'queue_depth, own_running, subagent_running}]}]}，供晚订阅者取权威快照。'
    'scope 必须带确定的 mode_key（local | ssh），否则 fail-closed。';
