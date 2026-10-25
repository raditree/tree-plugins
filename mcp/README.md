# mcp（MCP 协议客户端插件）

> 状态：**0.1.0**。stdio JSON-RPC MCP 客户端：能力协商、自发现、上下文管理与工具贡献。

## 协议面

| 阶段 | 已实现 |
| --- | --- |
| 握手 | `initialize`（protocolVersion / capabilities / clientInfo）→ `notifications/initialized` |
| 能力 | 解析 tools / resources(subscribe,listChanged) / prompts / logging |
| 自发现 | `tools/list`、`resources/list`、`resources/templates/list`、`prompts/list`，支持 `nextCursor` 分页 |
| 变更 | `notifications/tools/list_changed` / `resources/list_changed` / `prompts/list_changed` 自动重拉 |
| 上下文 | `resources/read`、`prompts/get`、按 agent 的 `select_context` / `build_context` |
| 兜底调用 | `call_tool` 上下文命令 + tree.agent 的 `mcp` 元工具（help/call） |
| 反向请求 | `roots/list`、`ping` |
| 工具 | 把 MCP 工具以 `mcp__<server>__<tool>` 贡献给 tree.agent；`tools/call` 经本插件执行 |

配置：环境变量 `TREE_MCP_SERVERS`（JSON 数组）：
```json
[{"name":"files","command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","/tmp"]}]
```

上下文执行站：`plugin.mcp.execute.context`，命令
`inventory` / `read_resource` / `get_prompt` / `build_context` / `select_context`。

## 测试

`dart test`：5 条协议测试用真子进程假服务钉住
initialize 能力协商、分页自发现、list_changed 刷新、resources/read、prompts/get、
roots/list 与上下文构建。

## 未覆盖

- 仅 stdio 传输；Streamable HTTP/SSE 未搬；
- sampling / elicitation / completions、resources/subscribe 未接；
- 无 MCP 服务时插件正常上线但零工具。
