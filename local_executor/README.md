# local_executor（本机执行器，L-24）

> 状态：**0.2.0**。插件**自建执行站** `plugin.local_executor.execute.local`，
> 命令 `file.*` / `exec.command`；核心只登记租约与路由，不碰文件、不起进程。

## 它做什么

上线后向核心 `station/register` 注册**自建执行站**：

| 命令 | 作用 |
| --- | --- |
| `file.read` | 读文本/二进制（二进制回 base64） |
| `file.write` | 写文本（自动建父目录） |
| `file.list` | 列目录（可限深度/条数） |
| `file.grep` | 正则/字面搜索 |
| `file.delete` | 删文件或目录（目录需 recursive） |
| `file.mkdir` | 建目录 |
| `file.writeBytes` | 写二进制（base64） |
| `exec.command` | 在租约根目录执行命令 |

调用方（tree.agent）先发 `workspace/register` 登记 `{lease_id, dir}`，之后每条
命令带 `lease_id`。核心把登记目录作为 `root` 注入 arguments 并路由到本插件；
**核心不解析 agent/team/mode 身份、不碰文件、不起进程**。

## 安全边界

- `root` 必须是已存在的绝对目录；`path` 必须是相对路径，规范化后不得越界；
- 终端命令在 `root` 下执行；错误/越界以可读中文回给调用方。

## 限制

- 无 PTY（普通子进程，非交互终端）；后台 hook 已支持（start/status/cancel + 日志）；
- SSH 远端执行不在本插件（归 ssh_executor，未接租约）；
- 核心内置 fs.* 命令仍保留给无租约旧调用方，A5 删除。

## 自检

```
cd plugins/local_executor
dart run local_executor_plugin.dart --selftest
```
