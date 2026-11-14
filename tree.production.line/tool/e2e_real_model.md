# 真模型 E2E（手动）说明

本文件描述 **PC-8 / Task 12 的真模型端到端联调**，与自动化测试分开：

- `dart test` / `flutter test` 里的全链路 E2E 是**确定性假模型路径**
  （`test/e2e_full_chain_test.dart`：假 docnorm / llm / worker / command），
  不需要任何模型配置，任何机器都能跑。
- 本文这条路径才接真模型，用于验收「准备 → 打包 → 执行 → 门控 → done」
  和异常五路径，必须人工执行并留存证据。

## 1. 前置条件

1. **模型池**：至少配置一个能跑工具调用的 chat 模型，供产线四个角色使用：
   `roles.orchestrator.model_id` / `roles.packer.model_id` /
   `roles.executor.model_id`（专家可选）。三个角色可以指向同一个模型。
2. **手工 E2E 环境变量**（由本地启动脚本或测试终端读取，不是插件运行时依赖）：

   | 变量 | 含义 |
   | --- | --- |
   | `TREE_E2E_MODEL` | 产线角色使用的模型 id（写入 `roles.*.model_id`） |
   | `TREE_E2E_BASE_URL` | 模型服务 base_url（模型池里的 OpenAI 兼容地址） |
   | `TREE_E2E_API_KEY` | 模型服务 api_key |
   | `TREE_E2E_VISION` | `1` = 启用视觉模型；缺省 / `0` = 纯文本 |

   邮箱、密钥等敏感值只放本机环境变量，不写进仓库、不贴进证据截图。
3. **核心与插件**：核心已启动并能加载 `tree.production.line`；
   `tree.docnorm` / `tree.storage` / `tree.agent` 通道可用（真机归一化、
   去重索引、员工调用都依赖它们）。
4. **工作空间**：一个真实 git 仓库，含 `pubspec.yaml`（带 `description`）、
   `README.md` 与可改代码；建议先跑一次结构整理，确保没有未豁免的 high
   finding。

## 2. 运行步骤

1. 启动核心（执行站 + 插件）。
2. 在 UI 建产线：选执行 Agent、四个角色模型、`limits`（建议
   `max_parallel_tasks: 1`、`retries: 1`）、工作空间目录。
3. 在 UI 走四步：
   1. **结构 / 归一化 / 就绪**：`structure.reevaluate` → 修 finding 或逐项豁免
      → `normalize.plan` → `normalize.apply` → `readiness.get`，
      确认 `line.ready=true`；
   2. **准备**：五栏 intake → 侦查（真模型摘要 + 检索证据）→ 逐题回答
      或「全部按推荐」→ 落档（生成 `plan-v1/plan.json` 与 queued 任务）；
   3. **打包 / 执行**：派发第一个任务，观察 pack.json、run 台账、
      `gate.json`，确认任务进入 `done`；
   4. **漂移**：本批结束后跑 `drift.run`，确认 BG-01~08 全过。
4. 额外手动走几条异常路径：缺模型、缺依赖、门控失败、预算超限、
   主控连续失败；每条都要能看到可读原因并恢复。
5. 至少完成一次运行期 `ask/answer` 闭环（任务 blocked → 回答 → queued）。

## 3. 需要留存的证据

- **截图**：四步界面各一张；任务详情（状态 / 改动 / 门控输出）；
  异常路径的拒绝原因；`ask/answer` 前后状态。
- **台账**：`production.run.list` 的 runs（含 packer / executor 两次 run）。
- **门控**：`<data_root>/production_lines/production/<line>/tasks/<task>/gates/<run_id>/gate.json`。
- **计划**：`<line>/plans/plan-v1/plan.json`（7 块 + findings）。
- **漂移**：`<line>/drift.json` 与 `batches/<batch>/gates/` 下的证据 JSON。
- 若启用了记忆：run 里的 `memory_hash`；未接线时应有
  `memory_unavailable: true`，不能伪造成通过。

> 未配置真模型（缺 `TREE_E2E_MODEL` / base_url / api_key）时，不要跑本文
> 路径；直接跑 `dart test` / `flutter test`，它们走的是
> `test/e2e_full_chain_test.dart` 的确定性假模型路径，结论只覆盖插件逻辑，
> 不覆盖模型质量。
