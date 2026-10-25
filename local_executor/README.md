# local_executor（本机执行器，L-24）

> 状态：**0.1.0**。核心执行站的 `system.execute.fs` 与 `system.execute.terminal`
> 由本插件挂载；`tree.agent` 的 read/write/list/grep/terminal 在租约根目录内执行。

## 它做什么

插件上线后调用执行站命令 `plugin.mount`，把两个执行站点位的命令挂到自己：

| 点位 | 命令 |
| --- | --- |
| `system.execute.fs` | `fs.read` / `fs.write` / `fs.list` / `fs.grep` |
| `system.execute.terminal` | `terminal.exec` |

调用方（tree.agent）先发 `workspace/register` 通知登记 `{lease_id, dir}`，
之后每条 `fs.*` / `terminal.exec` 命令都带 `lease_id`。核心把登记目录作为
`root` 注入 arguments 并直送本插件；**核心不解析 agent/team/mode 身份、不碰文件、
不起进程**。

## 安全边界

- `root` 必须是已存在的绝对目录（核心登记时校验，执行器再校验一次）；
- 命令里的 `path` 必须是相对路径，规范化后不得越出 `root`（`..` / 绝对路径直接拒）；
- 终端命令在 `root` 下执行；错误/越界以可读中文回给调用方。

## 限制（后续）

- 只实现 fs.read/write/list/grep 与 terminal.exec；fs.delete、写二进制、PTY、
  后台 hook 任务尚未提供（显式报未实现，不静默）；
- 终端是普通子进程（非 PTY），超时来自调用方参数；
- 核心内置的 fs/terminal 挂载仍保留给不带租约的调用方，A5 再删除。

## 自检

```
cd plugins/local_executor
dart run local_executor_plugin.dart --selftest
```
