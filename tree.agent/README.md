# tree.agent（批次 G 的 agent 领域插件）

> 状态：**A1 骨架**（2026-10-25）。空插件可上线、可停用；日志写入
> `/api/logs/plugin:tree.agent`；委派路由如实申报 0 条。
> 迁移契约与验收见桌面仓：
> - `docs/pluginization/agent_pluginization.md`（迁移计划 / A1~A5）
> - `docs/pluginization/agent_api_contract.md`（36 条逐条契约 + C-01~C-12 决策）

## 这是什么

核心（`tree_core`）不再认识 agent / 会话 / 提问 / 团队 / 模型。本插件负责把
原核心的 agent 能力整体接过来：

| 阶段 | 内容 | 本仓状态 |
| --- | --- | --- |
| A1 | 骨架：stdio 循环、hello/ping、工具表、收集站申报、日志 | **已完成** |
| A2 | 只读面：agents / models / sessions / todos / subagents / teammates / tools-running | 未开始 |
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

## A2 起怎么搬

按 `docs/pluginization/agent_api_contract.md` 的 §1 逐组实现，**先只读、后写**；
每组的请求/回包/失败码/副作用逐字对齐（G-1 决策：等价优先，除两条新增端点外
不改行为）。数据来自核心的数据根（原地接管，不搬迁），通过核心的文档化出口
（`workspace/register` 租约、`/api/store/tree.agent`、`/api/logs/plugin:tree.agent`）
而不是 import 核心包。
