# local_executor（本机执行器，L-24）

> 状态：**0.5.0**。插件**自建执行站** `plugin.local_executor.execute.local`，
> 命令 `local.file.*` / `local.exec.command`（与 `ssh_executor` 的 `ssh.*` 逐字对称）；
> 核心只登记路由，**不碰文件、不起进程、不认租约**。

## 它做什么

上线后向核心申报自建执行站，命令表 10 条：

| 命令 | 作用 |
| --- | --- |
| `local.lease.register` | 登记本机工作空间（`{dir, local_lease_id?}`）→ `{lease_id, root}` |
| `local.file.read` | 读文本/二进制（二进制回 base64；`raw/offset/length` 分块） |
| `local.file.write` | 写文本（自动建父目录） |
| `local.file.list` | 列目录（可限深度/条数，另回 `details`） |
| `local.file.grep` | 正则/字面搜索 |
| `local.file.delete` | 删文件或目录（目录需 recursive） |
| `local.file.mkdir` | 建目录 |
| `local.file.writeBytes` | 写二进制（base64，支持 `append`） |
| `local.file.rename` | 改名（目标存在即拒） |
| `local.exec.command` | 在租约根目录执行命令（含后台 hook） |

调用方（tree.agent）**先发 `local.lease.register` 登记 `{dir}`**，之后每条命令带
`local_lease_id`。**`root` 只来自插件自己的租约表**：arguments 里塞进来的
`root` / `workspace_root` 一律忽略（自检里有一条钉子专门注入假 `root` 证明它不生效）。

命令名带 `local.` 前缀是**必须的**：核心 `station/command` 按命令名**全局**查执行站，
`ssh_executor` 用同后缀的 `ssh.*`，无前缀的同名会被核心拒绝。

## 安全边界

- `dir` 必须是已存在的绝对目录；`path` 必须是相对路径，规范化后不得越界；
- 终端命令在 `root` 下执行；错误/越界以可读中文回给调用方；
- **租约归属 fail-closed**：租约记住登记方（`meta.source_plugin_id`），别的插件拿同一个
  `local_lease_id` 来问 ⇒ `lease_denied`，不去猜、不静默回退；租约表里没有 ⇒
  `local_lease_unknown`（调用方据此重登记并只重试一次）。

## 限制

- 无 PTY（普通子进程，非交互终端）；后台 hook 已支持（start/status/cancel + 日志）；同步命令超过 timeout_seconds 会软超时转后台（不杀进程）。
- SSH 远端执行不在本插件（归 ssh_executor 的 `ssh.*`）。

## 自检

```
cd plugins/local_executor
dart run local_executor_plugin.dart --selftest
```
