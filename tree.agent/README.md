# tree.agent（批次 G 的 agent 领域插件）

> 状态：**A2 进行中**（2026-10-25）。A1 骨架完成；A2 已搬：`api/delegate` 管道 +
> `GET /api/agents`、`GET …/todos`、`GET …/subagents`、`GET /api/models`、`GET …/models-info`
> （与核心同数据根**逐字节等价**，见桌面仓
> `packages/tree_core/tool/verify_agent_equivalence.dart`）。日志写入
> `/api/logs/plugin:tree.agent`。
> 迁移契约与验收见桌面仓：
> - `docs/pluginization/agent_pluginization.md`（迁移计划 / A1~A5）
> - `docs/pluginization/agent_api_contract.md`（36 条逐条契约 + C-01~C-12 决策）

## 这是什么

核心（`tree_core`）不再认识 agent / 会话 / 提问 / 团队 / 模型。本插件负责把
原核心的 agent 能力整体接过来：

| 阶段 | 内容 | 本仓状态 |
| --- | --- | --- |
| A1 | 骨架：stdio 循环、hello/ping、工具表、收集站申报、日志 | **已完成** |
| A2 | 只读面：agents / models / sessions / todos / subagents / teammates / tools-running | **进行中**：agents / todos / subagents / models / models-info 已搬并等价；其余 3 组未开始 |
| A3 | 写路径与生成：消息、取消、LLM、工具编排、提问、reset/compact | 未开始 |
| A4 | 帧迁移：注册广播站，topic 沿用原帧名 | 未开始 |
| A5 | 交接：核心删除 34 条路由 + 2 条上行 + 领域目录 | 未开始 |

## 依赖纪律（硬约束）

- **不得 import `package:tree_core` / `package:tree_protocol`**。
  第三方开发者单独 clone 本仓也要能编；核心能力只能走平台内置站（日志 / 存储 /
  租约）或其它插件的自建执行站。
- 骨架只有插件仓的 `_kit` 一份（入口里 `import '../_kit/plugin_kit.dart'`）；
  领域代码进 `lib/src/`，包名 `tree_agent_loop`。
- `tools/list` 是可选能力：缺失或为空**不阻断上线**。

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
lib/src/agent_store.dart   agent 列表：22 键 / 会话预览（32KiB 倒读）/ 待处理成员数
lib/src/model_catalog.dart config/models/*.yaml → ModelApi（脱敏/排序/默认值）
lib/src/yaml_utils.dart    YAML → 纯 Dart Map（UTF-8 容错）
lib/src/delegate.dart      api/delegate 信封 → 路由分发 → {status, headers, body}
```

## A2 起怎么搬

按 `docs/pluginization/agent_api_contract.md` 的 §1 逐组实现，**先只读、后写**；
每组的请求/回包/失败码/副作用逐字对齐（G-1 决策：等价优先，除两条新增端点外
不改行为）。数据来自核心的数据根（原地接管，不搬迁），通过核心的文档化出口
（`workspace/register` 租约、`/api/store/tree.agent`、`/api/logs/plugin:tree.agent`）
而不是 import 核心包。

每搬一条路由的验收步骤：

1. 在 `kDeclaredRoutes` 加申报（双跑期核心会标 shadowed、继续自己承接）；
2. 在 `delegate.dart` 加分支（信封里的 `data_dir` 就是数据根，别自行推导）；
3. 在 `--selftest` 加一条**代码推导**的样例断言；
4. 在桌面仓 `packages/tree_core/tool/verify_agent_equivalence.dart` 加同一路由的
   种子 + 请求，跑通「核心 HTTP vs 插件 `api/delegate` 逐字节一致」；
5. 全绿后才允许核心删除对应实现（G-2，不变量 27）。
