/// 领域工具原语执行站：extra-tools 插件把工具调用转到这里，
/// 真正使用 tree.agent 的提问 / 临时员工 / 团队 / 待办服务。
const String kAgentToolsStationName = 'agent_tools';

String agentToolsStationId(String pluginId) =>
    'plugin.$pluginId.execute.$kAgentToolsStationName';

const List<String> kAgentToolCommands = <String>[
  'todo.get',
  'todo.set',
  'todo.update',
  'todo.clear',
  'question.ask',
  'subagent.run',
  'team.run',
  'message.run',
];

const String kAgentToolsReadme =
    'tree.agent 的领域工具原语：todo.* / question.ask / subagent.run / team.run / '
    'message.run。extra-tools 插件把模型工具调用转到这里；核心只路由，不实现语义。';