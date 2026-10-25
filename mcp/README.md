# mcp（MCP 协议客户端插件）

> 状态：**0.4.0**。MCP 是**能力来源**：插件连服务、自发现，工具化贡献给 tree.agent；
> 同时承接核心删除后的三条 `/api/mcp/services` REST（经委派，不另开端点）。

## 协议面

- `initialize` 能力协商（protocolVersion / capabilities / clientInfo）→ `notifications/initialized`
- tools / resources(subscribe,listChanged) / prompts / logging 能力解析
- `tools/list`、`resources/list`、`resources/templates/list`、`prompts/list`（分页）
- `notifications/tools|resources|prompts/list_changed` 自动刷新
- `resources/read`、`prompts/get`、`roots/list`、`ping`
- 按 agent 的上下文选择与构建（`McpContextManager`）

## 贡献给 tree.agent 的工具

| 工具 | 作用 |
| --- | --- |
| `mcp__<服务>__<工具>` | 每个已发现 MCP 工具的原生入口 |
| `mcp` | help / call 元工具（发现与兜底） |
| `mcp_resources` | list / read 资源（上下文注入） |
| `mcp_prompts` | list / get 提示词 |
| `mcp_context` | inventory / select / build 上下文 |

服务 `initialize` 后 `refreshAll()` 自发现，工具定义由 `mcpToolSpecs()` 生成；
tree.agent 在**每条新消息前**重收一次收集站，因此新连接的 MCP 工具会在下一轮进入工具表。
全部经 tree.agent 的工具收集站贡献，执行走 `plugin.toolCall` → 本插件。

**MCP 插件未启动时，这些工具不会出现在工具表**——没有 core 兜底。

## 承接的 REST 路由（D 任务）

插件启动后经 `system.collect.api.routes` 申报三条（归属表由核心维护）：

| 方法 | 模式 | 语义 |
| --- | --- | --- |
| GET | `/api/mcp/services` | 服务列表 + 已发现工具 + 各服务错误 |
| POST | `/api/mcp/services` | 注册 / 覆盖一个服务，立即落盘并只连它自己 |
| DELETE | `/api/mcp/services/{name}` | 删除（内置/环境变量注入项拒绝） |

核心收到请求后按归属表转成 `api/delegate`（信封字段：`method / path / params /
query / headers / scope / workspace_dir / data_dir / agent_id / team_id / request_id /
body`），插件在 `lib/src/delegate.dart` 按 `method + path` 分发，回
`{status, headers?, body?}`（`body` 是 JSON 字符串）。**UI 仍调原路径**，
`lib/io/api_service.dart` / `lib/ui/widgets/mcp_config_panel.dart` 不感知委派；
返回形状与核心旧实现一致（`services / tools / errors`、`success / service / tools /
error_detail`），因此无需改解析。

## 配置

配置路径：**`<数据根>/config/mcp.yaml`**（与核心旧实现同路径；数据根来自委派信封
`data_dir`，插件不自行推导）。字段：

```yaml
servers:
  - name: filesystem
    transport: stdio
    command: npx
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
    env: {API_KEY: secret}
    enabled: true
    builtin: false
    scope: local
  - name: remote
    transport: http
    url: https://example.com/mcp
    headers: {Authorization: "Bearer xxx"}
    enabled: true
```

- **stdio**：`command / args / env`；**http**：`url / headers`。`transport` 缺省为
  `stdio`（老配置逐字兼容）。
- 启动时若环境里有 `TREE_DATA_ROOT`（兼容旧键 `TREE_HOME`），先绑定数据根并连接
  `config/mcp.yaml` 里的服务；
  没有该变量时，文件配置在**第一次 `/api/mcp/services` 请求**（UI 打开 MCP 配置页）
  时按信封 `data_dir` 延迟加载。此前首轮工具表只含 `TREE_MCP_SERVERS` 的服务。
- `TREE_MCP_SERVERS`（JSON 数组，旧插件入口）继续支持，启动时读取：
  `[{"name":"files","command":"npx","args":["-y","pkg"]}]`。同名时**文件配置优先**；
  环境变量注入项不能通过 `DELETE` 删除（请改环境变量）。
- 注册 / 删除都会原子写回本文件；注册只连它自己，连接失败不回滚注册，而是在
  `POST` 回包的 `error_detail` 与 `GET` 的 `errors` 里给出可读原因。
- `builtin: true` 的服务拒绝删除（只可 `enabled: false`）。

## 传输

- **stdio**：复用插件内 `McpProtocolClient`（子进程 + 逐行 JSON-RPC + initialize
  能力协商 + 分页自发现 + list_changed 刷新）。
- **http（Streamable HTTP）**：**本版只接受配置、持久化与展示**；注册会成功，但
  连接阶段给出「Streamable HTTP 传输尚未在 mcp 插件内实现」的可读错误，不发起网络连接。

## 限制

- Streamable HTTP/SSE 连接未搬（字段已保留，便于后续补齐；见上节）。
- 没有核心的 MCP 心跳判活；为保证委派不悬挂，`initialize` 握手有 20s 上界。
- 拿不到 `TREE_DATA_ROOT` 时，`config/mcp.yaml` 的加载会推迟到第一次 REST 请求
  （首次启动后、UI 打开配置页前的工具表可能缺这些服务）。
- 本插件只承接三条 REST 与配置；核心 MCP 库文件的删除/领域门禁是 A 任务，
  不在本插件内完成。插件不 import 核心包（tree_core / tree_protocol）。
- UI 面板的 `needs_confirmation` 信任确认字段本插件不回（旧核心路由同样不回）。

## 测试

```bash
cd plugins/mcp
dart analyze
dart test
dart run mcp_plugin.dart --selftest
```

覆盖：三条路由申报、委派 GET/POST/DELETE、配置加载与落盘、`TREE_MCP_SERVERS`
兼容、stdio 真子进程注册后发现工具、删除后断开并移除。
