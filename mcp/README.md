# mcp（MCP 协议客户端插件）

> 状态：**0.3.0**。MCP 是**能力来源**：插件连服务、自发现，工具化贡献给 tree.agent；
> 不注册任何中转/执行站，tree.agent 也不认识 MCP 命令或元工具。

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
全部经 tree.agent 的工具收集站贡献，执行走 `plugin.toolCall` → 本插件；
没有 MCP 专用执行站、没有 tree.agent 内硬编码的 MCP 分支。

**MCP 插件未启动时，这些工具不会出现在工具表**——没有 core 兜底，也不存在
`mcp help/call` 的可读错误（只有“工具表里没有它”）。核心仍保留旧的
`/api/mcp/*` 与 `McpService`（A5 待删），那是另一条路径。

配置：`TREE_MCP_SERVERS`（JSON 数组）：
```json
[{"name":"files","command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","/tmp"]}]
```

## 测试

5 条真子进程协议测试：initialize 能力协商、分页自发现、list_changed 刷新、
resources/read、prompts/get、roots/list、上下文构建。

## 未覆盖

- 仅 stdio；Streamable HTTP/SSE 未搬；
- sampling / elicitation / completions、resources/subscribe 未接；
- 核心仍保留 `tree_core/lib/src/mcp` 与 `/api/mcp/*`（A5 删除，UI 面板尚未迁到本插件）。
