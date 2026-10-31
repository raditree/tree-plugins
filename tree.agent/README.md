# tree.agent（批次 G 的 agent 领域插件）

> 状态：**A3 完成，A4/A5 未开始**（2026-10-25）。G-1 36 条 + spec 2 条共 38 条已全部申报；
> 12 条只读路由与核心同数据根逐字节等价（`verify_agent_equivalence.dart`），其余 26 条仅申报。
> 工具执行走 `local_executor` / `ssh_executor` 自建执行站；日志写入 `/api/logs/plugin:tree.agent`。
> 契约与验收见 `docs/pluginization/agent_pluginization.md` 与 `agent_api_contract.md`。

## 这是什么

核心（`tree_core`）不再认识 agent / 会话 / 提问 / 团队 / 模型。本插件负责把
原核心的 agent 能力整体接过来：

| 阶段 | 内容 | 本仓状态 |
| --- | --- | --- |
| A1 | 骨架：stdio 循环、hello/ping、工具表、收集站申报、日志 | **已完成** |
| A2 | 只读面：agents / models / sessions / todos / subagents / teammates / tools-running | **已完成**：十条只读路由逐字节等价；tools-running 已接 |
| A3 | 写路径与生成：消息、取消、LLM、工具编排、提问、reset/compact、G-1 剩余 4 条 | **已完成**：38 条申报；reset/compact/ssh 重连/团队写路由/4 条 G-1 路由已接；测试 356、自检 186 |
| A4 | 帧迁移：注册广播站，topic 沿用原帧名 | 未开始 |
| A5 | 交接：核心删除 34 条路由 + 2 条上行 + 领域目录 | 未开始 |

## 依赖纪律（硬约束）

- **不得 import `package:tree_core` / `package:tree_protocol`**。
  第三方开发者单独 clone 本仓也要能编；核心能力只能走平台内置站（日志 / 存储 /
  租约）或其它插件的自建执行站。
- 骨架只有插件仓的 `_kit` 一份（入口里 `import '../_kit/plugin_kit.dart'`）；
  领域代码进 `lib/src/`，包名 `tree_agent_loop`。
- `tools/list` 是可选能力：缺失或为空**不阻断上线**。

## 扩展工具（extra-tools）

todo / question / subagent / team / message 五个工具由独立插件 `extra-tools` 贡献：
tree.agent 的收集站采集工具定义，执行时经 `plugin.toolCall` 回到 extra-tools，
再由其调用 tree.agent 自建领域执行站（`todo.*` / `question.ask` / `subagent.run` /
`team.run` / `message.run`）。tree.agent 只提供领域原语，不包工具定义。

## Spec 工具（S1，原生）

`spec` 工具在 tree.agent **原生**声明与执行（不经 extra-tools）：`StationToolRunner`
把它加进模型工具表，执行时按 agent 解析工作空间（本机 / SSH 同一执行站路径）后交给
`SpecService` + `WorkspaceIO`。动作：

| action | 作用 | 读/写 |
| --- | --- | --- |
| `list` | 列出工作空间全部规范 + 本会话已选 id | 读（首次会播种内置副本） |
| `read` | 按 `spec_id` 取规范原文（不挂 hook） | 读 |
| `select` | 选择/取消（空数组）并直接回全文、挂会话 hook | 写会话选择 |
| `create` / `update` | 沉淀/维护自定义规范（内置不可改） | 写工作空间 |
| `reset` | 备份 `.self/spec/*` 后重建内置规范（破坏性） | 写工作空间 |

同一套动作也暴露为自建 `agent_tools` 执行站命令 `spec.list` / `spec.read` /
`spec.select` / `spec.create` / `spec.update` / `spec.reset`（命令参数与工具参数同形），
供 extra-tools 等插件经站调用；站点 readme 与命令表在注册时由
`AgentRuntime.agentToolsReadme` / `agentToolCommands` 统一提供。

## 执行器激活站（`agent_executor`）

命令 `executor.activate {agent_id}`：

- **local**：检查工作空间存在且可写（写探针再删）+ 回报设备基本信息，不建连接；
- **ssh**：**真激活**——经 `ssh.lease.register` 建到目标机的连接并登记远端租约，
  回 `ssh_lease_id` / `conn_id` / `root`（同一 agent + 同一份配置走缓存）。

回包统一为 `{ok, mode, executor, agent_id, device, text, ...}`。同一实现也暴露为 REST
`POST /api/agents/{agentId}/activate`（失败 502 + `detail`），UI 在开终端前调用它——
UI 不碰 SSH 凭据。站点 readme / 命令表见 `lib/src/station/agent_executor.dart`。

## 执行器依赖（L-24）

> **local_executor 是 tree.agent 的必需依赖**（`requires.plugins: local_executor >=0.5.0`）。
> 执行器缺失/被卸载时 tree.agent 不应启动；已运行时卸载执行器，核心会先要求确认，
> 确认后**停用 tree.agent**，不会回退到核心内置执行器。



本机：read / write / edit / list / grep / terminal / tool_runs 由 `local_executor` 自建执行站
（`plugin.local_executor.execute.local`，命令 `local.file.*` / `local.exec.command`）执行；
tree.agent 发一次 `local.lease.register {dir}` 登记工作空间，后续命令只带 `local_lease_id`。
**租约表在执行器那边**（契约 §8.3）：核心不再持有 `workspace/register` 那套簿记，也不再
往 arguments 里注入 `root`。

SSH：tree.agent 在 SSH 模式先向 `ssh_executor` 自建站
（`plugin.ssh_executor.execute.ssh_workspace`）发 `ssh.lease.register` 取远端根，随后
**只换前缀**：`local.file.*` / `local.exec.command` → `ssh.file.*` / `ssh.exec.command`，
句柄键同步换成 `ssh_lease_id`（两侧命令族逐字对称，没有第二张映射表）。执行器
不可用或租约失效会显式失败（`*_lease_unknown` ⇒ 重登记并只重试一次），**不回退本机 IO**。

## 跑

```
# 不连真核心的自检（假核心在同一进程里跑真读循环）
dart run plugins/tree.agent/tree.agent_plugin.dart --selftest

# 编译成发布产物（桌面仓根执行；会顺带跑产物自检）
dart run tool/build_plugins.dart --only tree.agent

# 接进核心（plugins.yaml 片段）
plugins:
  - id: tree.agent
    name: Tree Agent 循环
    command: "<exeDir>/plugins/tree_agent.exe"
    args: []
    granularity: team
    scope: {}
```

## 代码结构

```
tree.agent_plugin.dart     入口：hello/ping/tools-list、收集站、api/delegate 分发、--selftest
lib/tree_agent_loop.dart   身份常量 + 已申报路由表 + 导出
lib/src/paths.dart         数据根布局（与核心 TreePaths 同一串落盘点，含 safeSegment）
lib/src/todo_store.dart    todos.md 解析（与核心 FileTodoStore 同一正则）
lib/src/subagent_store.dart subagents.json 名册解析（与 CoreSubagent.toRosterJson 同口径）
lib/src/agent_config.dart  agents/<id>.yaml 的 models-info 视图 + 覆盖项
lib/src/agent_store.dart   agent 列表/详情：22 键 / 会话预览（32KiB 倒读）/ 待处理成员数 / SSH 非机密视图
lib/src/session_store.dart 会话列表/详情：session.json + 规范化 CoreMessage.toJson + 非工具消息计数
lib/src/question_store.dart  questions.json 视图（叠加提问状态/答案/选项）
lib/src/conversation_store.dart 会话历史分页（limit/before/from/at/all）+ 提问卡片叠加
lib/src/teammates.dart     团队名册（memberView + relation + overrides/effective）
lib/src/agent/             平移：question_store（提问记录）、question_broker（等待/作答/取消回路）
lib/src/tool/              平移：todo_store、question_channel、tool_runner、subagent_tool、
                           tool_run_registry（运行中工具登记）、hook_ledger、tool_runs_tool；
                           spec_tool（S1 原生 spec 工具：list/read/select/create/update/reset）
lib/src/plugin/            平移：agent_events（事件名常量与发布器）
lib/src/compat/            旧下行帧名最小兼容层（提问卡片；A4 接站内主题后替换）
lib/src/llm/               平移：llm_types / openai_codec / sse_parser / llm_transport / llm_session /
                           llm_agent_engine / llm_json_caller / llm_summarizer / vision_files
lib/src/workspace/workspace_io.dart  引擎用到的窄工作空间契约（执行站接线后补全）
lib/src/settings/core_settings.dart  插件侧 CoreSettings 门面（领域设置 + frame_rate，夹取口径同核心）
lib/src/settings/file_settings_sink.dart  模型池 yaml 落盘 + settings.yaml 只更新 token 速率（保留其余键）；L-22 乙方案落地后改落 `config/agent_settings.yaml`，核心退出该键（桌面仓 `docs/pluginization/agent_pluginization.md` §4.8.1）
lib/src/agent/attachment_prompt.dart + tool_result_repair.dart  附件提示词 / 工具卡自动修复文案
lib/src/store/usage_log.dart   会话用量账本（追加 jsonl、坏行容忍、只读尾部）
lib/src/llm/llm_result_gate.dart  超长工具结果重定向/退化口径
lib/src/team/team_workspace.dart 团队共享工作目录 + SSH 跟随 TOP
lib/src/team/team_service.dart  团队域（建队/名册/档案/审核/模型分配/级联）
lib/src/team/team_model.dart    成员视图/覆盖项/日志路径
lib/src/team/team_repair.dart   成员配置修复（备份/内存/幂等）
lib/src/spec/              spec_service（内置/自定义规范、索引、快照、随附文档播种）
lib/src/team/message_dispatcher.dart  团队消息投递（send/wait_for/broadcast、附件）
lib/src/tool/message_tool.dart  message 工具声明
lib/src/util/liveness.dart       心跳活性跟踪/部分结果收口
lib/src/tool/team_tool.dart     team 工具声明
lib/src/tool/tool_runs_scope.dart  运行中工具的作用域（上级可见下级）
lib/src/agent/private_paths.dart  .self 私有目录口径（privateSelfDir / mapPrivatePath / 迁移）
lib/src/agent/workspace_prompt.dart 工作空间软约束段/基础段/Spec 注入
lib/src/agent/compaction_service.dart 上下文压缩（切点/手动/自动/预算/中转点）
lib/src/agent/subagent_service.dart  临时员工编排（召/reuse/阻塞/后台/收尾）
lib/src/agent/conversation_service.dart 会话服务（脚本引擎可跑：分段落库 + WS 帧 + 取消/排队）
lib/src/tool/tool_runner.dart + subagent_tool.dart 工具契约与 subagent 工具
lib/src/ws/ws_hub.dart      A3 阶段最小帧出口（运行期接站内主题；A4 替换）
lib/src/runtime/agent_runtime.dart  单数据根运行时（store/设置/提问/subagent/conversation；
                            C-08 端点落地 + 帧记录）
lib/src/agent/agent_engine.dart + scripted_agent.dart  引擎契约与脚本引擎
lib/src/util/tokens.dart   字符/token 估算（与核心同口径）
lib/src/store/             从核心平移的存储层：FileTreeStore / records / TreePaths / YAML /
                           原子写 / 写队列 / 子 agent 注册表（A3 生成循环复用）
lib/src/util/              ids / json_time / 容错 UTF-8 解码（含 Windows 代码页）
lib/src/settings/          ssh_config（纯数据）+ domain_settings（CoreModelConfig /
                           模型池 / token 速率 / 覆盖与 token_scale 学习）
lib/src/model_catalog.dart config/models/*.yaml → ModelApi（脱敏/排序/默认值）
lib/src/yaml_utils.dart    YAML → 纯 Dart Map（UTF-8 容错）
lib/src/delegate.dart      api/delegate 信封 → 路由分发 → {status, headers, body}
```

## A2 起怎么搬

按 `docs/pluginization/agent_api_contract.md` 的 §1 逐组实现，**先只读、后写**；
每组的请求/回包/失败码/副作用逐字对齐（G-1 决策：等价优先，除两条新增端点外
不改行为）。数据来自核心的数据根（原地接管，不搬迁），通过核心的文档化出口
（执行站命令、`/api/store/tree.agent`、`/api/logs/plugin:tree.agent`）
而不是 import 核心包。

每搬一条路由的验收步骤：

1. 在 `kDeclaredRoutes` 加申报（双跑期核心会标 shadowed、继续自己承接）；
2. 在 `delegate.dart` 加分支（信封里的 `data_dir` 就是数据根，别自行推导）；
3. 在 `--selftest` 加一条**代码推导**的样例断言；
4. 在桌面仓 `packages/tree_core/tool/verify_agent_equivalence.dart` 加同一路由的
   种子 + 请求，跑通「核心 HTTP vs 插件 `api/delegate` 逐字节一致」；
5. 全绿后才允许核心删除对应实现（G-2，不变量 27）。


## 工具贡献收集站（自建）

本插件向核心注册一个**收集站** `plugin.tree.agent.collect.tools`（`shared: true`），
其它插件可以订阅它，把自己的工具加进 agent 的工具表：

1. 订阅：`station/subscribe`，`station_id = plugin.tree.agent.collect.tools`，scope 留空（通配）；
2. 收到 `station/request`（`payload = {action: "list"}`）时按 schema 回：
   `{ok: true, payload: {tools: [{name, description, parameters}]}}`
   （`parameters` 是 JSON Schema 对象）；
3. agent 把工具名改写为 `plugin__<你的插件id>__<name>`，执行时经核心执行站的
   `plugin.toolCall` 转到你的 `tools/call`。**领域身份放 `arguments.scope`，
   顶层 scope 留空**：核心只认 `plugin_id` / `tool`，不解析 agent/team/mode/session。

站点 schema：`{kind: object, fields: [{name: tools, type: array, required: true}]}`；
采集失败不阻断 agent 发消息，工具表退回内置五项。
