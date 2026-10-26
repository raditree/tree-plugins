/// 「激活指定 agent 执行器」执行站。
///
/// 为什么要有它：执行器（`local_executor` / `ssh_executor`）的能力是否"就绪"，
/// 只有拥有 agent → workspace 映射的 `tree.agent` 知道。调用方（其它插件 / 核心）
/// 只需要一条命令，不必自己判断 local 还是 ssh、更不必碰 SSH 凭据。
///
/// 两条路的语义**统一在回包形状**上（`ok / mode / executor / agent_id / device / text`）：
/// - `local`：只做检查（工作空间存在且可写 + 设备基本信息），**不建连接**；
/// - `ssh`：**真激活**——建立到目标机的连接并登记远端租约（`ssh.lease.register`），
///   回传 `ssh_lease_id` / `conn_id` / `root`，后续终端与文件命令可直接复用。
const String kAgentExecutorStationName = 'agent_executor';

/// 站点完整 id（核心拼接规则：`plugin.<plugin_id>.execute.<name>`）。
String agentExecutorStationId(String pluginId) =>
    'plugin.$pluginId.execute.$kAgentExecutorStationName';

/// 唯一命令：`{agent_id}` → 激活该 agent 的执行器。
const String kActivateExecutorCommand = 'executor.activate';

const List<String> kAgentExecutorCommands = <String>[kActivateExecutorCommand];

const String kAgentExecutorReadme =
    '激活某个 agent 的执行器（参数 {agent_id}）。local：检查设备信息与工作空间可写，'
    '回 workspace / device；ssh：真正建立连接并登记远端租约，回 ssh_lease_id / conn_id / root。'
    '回包统一为 {ok, mode, executor, agent_id, device, text, ...}；失败时 ok=false 且带可读 error。'
    '重复激活同一 agent 走缓存（不会重复建连）。';
