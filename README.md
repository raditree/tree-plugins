# tree-plugins

Tree 桌面端的**插件源码仓库**。这里放的是给人改的东西：每个插件一个目录，目录里是
源码与随包分发的文件。

**装机端的插件管理不读这个仓库的源码，只读它的 GitHub Release 资产。**
（用户 2026-10-16 定稿：「plugins 里是插件代码，插件管理只拉 release」。）

为什么两边要分开：把"能拉到源码"当成"能装上"会在用户机器上再造一条没人审的路——
源目录的形状、构建产物在不在、谁负责编译，全都要在装机现场猜。发布方一次性把成品
备好，`release/plugin-index.json` 就是那张合同，装机端只核合同。

- 解析那份合同的实现：`packages/tree_core/lib/src/plugin/plugin_downloader.dart`
- 面板上的入口与 REST：`GET/POST /api/plugin/release*`（见 `docs/plugin-development.md` §6.8）

改了合同必须**同时**改装机端的校验：两边各说各话的结局是"面板列不出来"或"装上去起不来"。

## 目录形状（源码侧）

```
tree-plugins/
├── README.md                    # 本文件
├── release/
│   └── plugin-index.json        # 发布索引模板（发布时按它生成真正的索引）
├── hello_panel/                 # 一个目录 = 一个插件
│   ├── plugin.json              # 开发期元数据（字段见下）
│   └── hello_panel_plugin.py    # 插件本体（脚本或二进制）
└── <plugin_id>/
    ├── plugin.json
    └── ...
```

- 顶层目录才是一个插件；子目录、点开头的目录（`.git`）、没有 `plugin.json` 的目录
  一律当"不是插件"跳过。
- 只放源与要随包分发的成品文件：不放构建中间物、不放 `.dart_tool/`、不放依赖目录。

### `plugin.json`（开发期元数据）

| 键 | 必需 | 语义 |
|---|---|---|
| `id` | ✅ | **必须等于目录名**；字符集 `[A-Za-z0-9_.-]`，不能是 `.` / `..`（与核心 `PluginConfigStore` 的 id 校验同一条，防路径穿越） |
| `name` | ✅ | 展示名（面板与详情页读它） |
| `version` | ✅ | 三段数字 `x.y.z`（装机端比大小只用它判断"有没有更新"） |
| `description` | | 一句话说明 |
| `runtime` | | `binary`（缺省，随包可执行文件）/ `python`（脚本，需要解释器） |
| `files` | ✅ | 要放进装机端 `plugins/` 的文件名（相对本目录，至少一个） |
| `command` | ✅ | 装完后用来拉起它的那个文件名（必须在 `files` 里） |
| `args` | | 启动参数数组（字符串） |
| `suspension` | | `keep` = 声明可挂起（热重启先转储、新一世取回续跑）；留空 = 不可挂起。值域只有这两种 |
| `granularity` | | `team`（缺省）/ `agent` / `session` |
| `scope` | | 实例归属（键白名单 `team_id` / `agent_id` / `session_id` / `mode_key`；留空 = 不限定） |

## 发布合同（装机端唯一读的那一份）

发一版 = 建一个 **GitHub Release**，并把下面这些**一起传成该 release 的资产**：

```
plugin-index.json          # 必需：合同本体（schema=1）
tree_hello_panel.exe       # files[].asset 里出现的每一个名字都要有对应资产
hello_panel_plugin.py
...
```

`release/plugin-index.json` 的形状（模板已在本仓库里）：

```json
{
  "schema": 1,
  "plugins": [
    {
      "id": "hello_panel",
      "name": "示例面板插件",
      "version": "0.1.0",
      "description": "演示 stdio 握手 + 一个工具 + 一个左栏面板",
      "runtime": "binary",
      "command": "tree_hello_panel.exe",
      "args": [],
      "files": [
        { "asset": "tree_hello_panel.exe", "target": "tree_hello_panel.exe", "bytes": 8123904 }
      ],
      "suspension": "keep",
      "granularity": "team",
      "scope": {}
    }
  ]
}
```

字段纪律（缺一样就会被装机端**当场**拒，并且面板上写下为什么）：

- `schema` 必须是装机端认的那一版（现在 = `1`）。不认的一律拒并说"不猜新字段的含义"——
  猜错的表现是"装上去起不来"，比"没得上"难查得多。
- `plugins[]` 里**坏条目只跳过自己**，不带走整份清单；每条的跳过原因都会显示在面板上。
- `files[].asset` = release 上的资产名，`files[].target` = 落到装机端 `plugins/` 的文件名。
  两者都**必须是纯文件名**（不许含路径分隔符、`..`、绝对路径）。
- `files[].bytes` 建议填：装机端拿它核对下载完整性。填了就必须等于真实字节数，
  不符 ⇒ 按"没拿到"处理，**不缓存半截文件**，旧文件一字不动。
- `command` 必须出现在 `files[].target` 里（否则装完不知道拉哪个）。
- `runtime` 只能 `binary` / `python`；`python` 条目在装机端要先探到解释器
  （与内置插件同一套探测口径），探不到就**拒绝安装**而不是写一条注定起不来的配置。
- `suspension` 只能留空或 `keep`；`granularity` 只能 `team` / `agent` / `session`。

发布动作（在本仓库根目录）：

```
gh release create v0.1.0 release/plugin-index.json <每个资产文件>
```

只改索引不传文件、或只传文件不改索引，都会被判成"发布与索引不同版"并给出可读原因。

## 装机端装上一条插件时会发生什么（顺序不是随便排的）

1. 资产下载到 `<数据根>/plugins_release/<id>/<version>/`（临时名 + 原子改名；
   字节数不符就**不落地**）。缓存目录与 `plugins/` 分开：半成品不该出现在插件查找路径里。
2. 复制到「可执行文件同级的 `plugins/`」**之前**必须先过闸门：该插件的旧进程**已确认退出**。
   Windows 上正在运行的 exe 删不掉，"先换文件再重启"在这台机器上不成立。
3. 复制到同目录的临时名（`.part-<随机>`），全部复制成功后再逐个**原子改名**覆盖。
4. 写/更新一条 `plugins.yaml` 条目并热应用（等价于面板上打开开关那条路），条目上留
   `source: release` 与 `repo_version`（只给面板显示；行为一律不读它们）。

任何一步失败 ⇒ 旧文件保持原样 + 清掉临时名 + 回一句人话。核心**不会**为了换文件而杀进程：
显式强杀只有用户在面板上按「强制停止」那一条路（框架不变量，见
`docs/plugin-development.md` §6.7）。

## 怎么加一个插件

1. 建目录 + 写 `plugin.json`（字段见上）与源码；
2. 本地验证：`dart analyze` / 自带用例跑通，并确认 `command` 指向的文件真能产出；
3. 提 PR（源和随包成品一起，构建中间物不要提）；
4. 合并后由发布方按上面「发布合同」产出一版 release —— **面板能看到它，前提是这一版
   release 带上了 `plugin-index.json`**。
