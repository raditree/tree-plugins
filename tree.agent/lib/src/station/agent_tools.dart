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

/// **宿主能力命令**：Q-5 A 让名之后由 tree.agent 认领的五个领域族名。
///
/// 这些名字原来由核心内置实现（A5 起核心不再执行任何领域语义），片 1 把它们从
/// `StationPoints.executes` 摘掉、族名让给真正的实现方（`exec_station_contract.md`
/// §7 Q-5 / Q-7）。承接方之所以是 tree.agent：只有它知道 agent → 工作空间目录的
/// 映射，也有 llm / tool / compaction / session 的现成服务；换任何别人来承接都会
/// 复制一份 `agents/*.yaml` 解析逻辑（Q-7 的 (b) 就是这样被否掉的）。
///
/// 命令名**逐字沿用**旧口径，所以 compact / sample 等调用方一行都不用改。
const List<String> kAgentHostCommands = <String>[
  'llm.call',
  'fs.read',
  'tool.call',
  'agent.compact',
  'session.rename',
];

const String kAgentToolsReadme =
    'tree.agent 的领域工具原语：todo.* / question.ask / subagent.run / team.run / '
    'message.run。extra-tools 插件把模型工具调用转到这里；核心只路由，不实现语义。 '
    '宿主能力：llm.call（复用目标 agent 的模型，缺省 JSON / 显式 text）/ '
    'fs.read（按 agent 工作空间解析后读文件）/ tool.call（内置或贡献工具同一入口）/ '
    'agent.compact（与 REST /compact 同一实现）/ session.rename（改会话标题并广播）。 '
    '失败回包是 {error, payload}：llm.call 的失败也带模型正文原文（可抢救，不白花）。';
