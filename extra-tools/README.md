# extra-tools（扩展工具插件）

> 状态：**0.2.0**。独立插件，向 tree.agent 的工具收集站贡献五个工具：
> `set_todo_list` / `ask_user_question` / `subagent` / `team` / `message`。

## 工作方式

1. 上线后订阅 tree.agent 自建的收集站
   `plugin.tree.agent.collect.tools`；
2. 收到采集请求时回 `{tools:[...]}` 五个工具定义；
3. 模型调用这些工具时，核心经 `plugin.toolCall` 转到本插件的 `tools/call`；
4. 本插件把调用翻译成 tree.agent 自建领域执行站
   `plugin.tree.agent.execute.agent_tools` 的命令：
   `todo.*` / `question.ask` / `subagent.run` / `team.run` / `message.run`；
5. tree.agent 用自身的待办、提问、临时员工、团队与消息服务执行，结果原路返回。

插件本身不碰数据根、不 import 任何核心包或 tree_agent_loop；只做
**工具定义 + 命令翻译 + 结果文本化**。

## 工具定义（与 tree_agent_loop 的 ToolSpec 对齐）

五个工具的参数与取值表逐字段对齐参考实现（team / message / subagent 见
`plugins/tree.agent/lib/src/tool/*.dart`；todo / question 见
`packages/tree_core/lib/src/tool/builtin_tools.dart`，也就是 tree.agent
`agent_tools` 执行站的同口径语义）：

| 工具 | 参数 |
| --- | --- |
| `set_todo_list` | `action`（set/update/clear/get）、`todos[{id,content,status,progress}]` |
| `ask_user_question` | `questions[{question,options}]`（1~10 道）、`question`/`options` 单问简写 |
| `subagent` | `task`（必填）、`name`、`subagent_id`、`background` |
| `team` | `action`（8 值）、`member_name`、`target_member_id`、`cascade`、`name`、`role`、`duty`、`can_lead_team`、`review_status`、`approve`、`work_status`、`level`、`comment`、`system_prompt`、`scores{quality,efficiency,collaboration,accuracy}` |
| `message` | `action`（5 值）、`target_member_id`、`target_ids`、`target_member_ids`、`message`、`files`、`dest_dir`、`session_id` |

命令翻译：

| 工具调用 | agent_tools 命令 |
| --- | --- |
| `set_todo_list` | `todo.<action>`（缺省 `todo.get`） |
| `ask_user_question` | `question.ask` |
| `subagent` | `subagent.run` |
| `team` | `team.run` |
| `message` | `message.run` |

## 自检与测试

```
cd plugins/extra-tools
dart run extra-tools_plugin.dart --selftest   # 假核心 + 假站全链路（装机自检同一套）
dart test                                     # 工具定义 / 命令翻译 / 端到端
dart analyze
```

`--selftest` 在同一个进程里用 `_kit` 的 `FakeCore` 跑真读循环，假
agent_tools 站按命令回包并记录命令。覆盖：

- hello / ping / tools/list / 未知方法；
- 订阅收集站 → 收集站申报（回包就是 `toolSpecs()` 那一份）；
- 五个工具的九次 `tools/call`（todo 四个 action + 缺省 get）翻译成
  `todo.*` / `question.ask` / `subagent.run` / `team.run` / `message.run`；
- 参数原样透传、scope（agent/session/team）带到执行站、结果文本化；
- 未知工具、执行站拒绝两条错误路径。

## 未覆盖项

- 真核心的 `plugin.toolCall` 路由与 tree.agent 的真实服务执行不在本插件范围内
  （由 tree.agent 用例与装机 e2e 覆盖）；本插件只验证到「命令 + 参数 + scope」
  这一段契约。
- `tools/list` 为空是刻意的：工具经收集站贡献，不在插件自身工具表里重复申报。
