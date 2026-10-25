# extra-tools（扩展工具插件）

> 状态：**0.1.0**。独立插件，向 tree.agent 的工具收集站贡献五个工具：
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

## 自检

```
cd plugins/extra-tools
dart run extra-tools_plugin.dart --selftest
```
