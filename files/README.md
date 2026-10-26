# files（文件面板领域插件）

> 状态：**0.1.0（最小可运行切片）**。承接原核心 **13 条** `/api/files/*` REST
> （经 `system.collect.api.routes` 申报 + `api/delegate`），本机工作空间直接读写；
> SSH 工作空间经 `ssh_executor` 自建执行站。**Git 3 条按用户决定删除，本插件不申报。**

## 承接的 13 条路由

| 方法 | 模式 | 语义 |
| --- | --- | --- |
| GET | `/api/files/{workspaceId}` | 列目录 |
| DELETE | `/api/files/{workspaceId}` | 删除（`?path=&recursive=1`） |
| GET | `/api/files/{workspaceId}/content` | 读内容（图片 base64 / 文本） |
| PUT | `/api/files/{workspaceId}/content` | 按完整文本覆盖写（`if_size` / `force`） |
| GET | `/api/files/{workspaceId}/pdf_info` | PDF 页数/标题/作者（启发式） |
| POST | `/api/files/{workspaceId}/upload_init` | 建立分片上传会话 |
| POST | `/api/files/{workspaceId}/upload_chunk` | 追加分片（base64，按序） |
| POST | `/api/files/{workspaceId}/upload_complete` | 组装并落盘 |
| POST | `/api/files/{workspaceId}/syncToLocal` | 工作空间子树复制到本机目录 |
| POST | `/api/files/{workspaceId}/download` | 单文件原始字节下载 |
| POST | `/api/files/{workspaceId}/download_folder` | 目录打包 tar.gz |
| POST | `/api/files/{workspaceId}/mkdir` | 新建文件夹 |
| POST | `/api/files/{workspaceId}/rename` | 重命名 / 移动 |

请求由核心按归属表转成 `api/delegate`，信封含 `data_dir` / `query` /
`body` 或 `body_path`；插件回 `{status, headers?, body? | result_path?}`。
下载/打包成功写插件数据命名空间 `<数据根>/plugin-data/files/tmp/` 并回
`result_path`（核心校验归属、流式写回并清理）。回包形状与核心旧
`FileService` + 路由层一致：读路径错误 `{detail}`；写路径（PUT content /
mkdir / rename / DELETE）错误 `{error, detail, size?}`。

## 工作空间解析（agents/*.yaml）

- `{workspaceId}` 先按 agent 的 `workspace_id` 匹配，再按 `id` 兜底；
- 成员与团队 TOP 共享工作目录/SSH：沿 `parent_agent_id` 上溯（成环/悬空即停）；
- 根目录：TOP 的 `workspace_dir`，空则 `<数据根>/workspaces/<TOP id>`；
- 有效 SSH：自己没有 `ssh:` 就跟随 TOP；有 SSH ⇒ 走 `ssh_executor` 执行站
  （`ssh.lease.register` + `ssh.file.*` / `ssh.exec.command`）。
  账号不会回显到日志。

## 覆盖与缺口（本切片）

**本机工作空间：13 条全部可用**（列表/内容/读写/PDF/上传/同步/下载/打包/结构改动），
包括路径越界拒绝、二进制/扩展名拒写、`if_size` 409 冲突、目录非空 409、
上传按序校验、`.input/<yyyymmdd>/` 落点、打包排除 `.git`。

**SSH 工作空间：13 条全部可用**（2026-10-25 收口，原「基础 9 类」缺口已清零）：

1. 目录列表带 `size` / `modified`（执行站 `ssh.file.list.details` 直出，与本地同形）。
2. `content` / `download` / `upload_complete` / `download_folder` **不再有 8 MiB 单次上限**：
   读走 `ssh.file.read{raw,offset,length}` 分块（按 `eof` 收口），写走 `ssh.file.writeBytes{append}`
   分块（首块截断重建）。只有 `content` 预览仍按 8 MiB 截断（那是预览口径）。
3. `pdf_info` 大文件按头 64 KiB + 尾 512 KiB 定点读取（与本地同口径），不整文件回传。
4. `syncToLocal` / `download_folder` 已实现：前者按远端 `details` 逐文件分块下载并保留层级；
   后者在远端 `tar` 打包后分块回传，结束清理远端临时包。
5. 重命名走执行站 `ssh.file.rename`（目标机 `fs.rename`，原子；目标存在即拒），不再 shell 拼 `mv`。
6. `ssh.file.list` 的条目是**工作空间根相对路径**（与 `local_executor.file.list` 同形），
   同一操作在本地与 SSH 下的回包前缀一致（L-01 差异 3 的根因）。

**不做的**：Git 3 条（`git-status` / `git/log` / `git/branches`）按用户决定删除；
本插件不声明、不实现。其它路由未声明，核心仍按桩/404 处理。

## 数据与安全边界

- 数据根只来自委派信封 `data_dir`，插件不自行推导；
- 路径一律工作空间内相对路径；绝对路径 / 盘符 / `~` / `..` 逃逸一律 400；
- 根目录永远拒绝删除/重命名/作为新建目标；
- 文本写入上限 4 MiB；图片/PDF/Office/压缩包扩展名与 NUL 头部拒绝按文本写；
- 上传分片暂存在 `<数据根>/plugin-data/files/uploads/<upload_id>/`，会话 30 分钟过期；
- 不 import tree_core / tree_protocol；依赖只有 `path` / `yaml` 与 `_kit`。

## 测试

```bash
cd plugins/files
dart analyze
dart test
dart run files_plugin.dart --selftest
```

- 单测：13 条申报（无 Git）、工作空间解析（workspace_id/agent id、成员跟随 TOP、SSH 跟随）、
  本机 delegate 全链路、分片上传（含 `body_path`）、同步/打包产物、SSH 假执行站的
  列表/内容/写/mkdir/rename/删除/上传，以及未接执行站的 503；
- 插件自检：假核心跑同一套读循环 + 同一套 `handleRequest`，覆盖路由申报与
  本机列表/读写/结构/上传/打包/下载/同步。
