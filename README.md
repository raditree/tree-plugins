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
├── _kit/
│   └── plugin_kit.dart          # **不是插件**：共用的读循环 / 帧收发 / 假核心自检
├── hello_panel/                 # 一个目录 = 一个插件
│   ├── plugin.json              # 开发期元数据（字段见下）
│   └── hello_panel_plugin.dart    # 插件本体（入口，名字是**约定**）
└── <plugin_id>/
    ├── plugin.json
    └── <plugin_id>_plugin.dart
```

- 顶层目录才是一个插件；子目录、点开头的目录（`.git`）、没有 `plugin.json` 的目录
  一律当"不是插件"跳过。
- 只放源与要随包分发的成品文件：不放构建中间物、不放 `.dart_tool/`、不放依赖目录。

## Dart 插件的四条约定

为什么有 `_kit`：五个示例以前各自抄一份"读循环 + 帧收发 + 自检"，那五份副本各自漂
（心跳漏答、异常不收敛、stdout 混日志在不同示例里表现不同，而**协议本身没有不同**）。
现在一个插件一个文件、管道只一份：插件里只剩"这个插件干什么"。

1. **入口名字是约定**：`<id>_plugin.dart`。构建脚本按它找入口，找不到就是**错误**不是跳过
   （静默跳过在面板上只会变成"这个插件没得上"）。
2. **不依赖核心**：`binary` 型示例插件只用 `dart:` SDK，谁都不 `import package:tree_core` /
   `package:tree_protocol`——否则第三方拿到这个仓编不出来。代价是插件侧要自带一张方法名
   常量表（`_kit` 里的 `M`），所以桌面仓有一条用例把这张表逐个对回 `PluginRpcMethods`（漂了当场红）。
   **例外（见下面「两种形状」）**：`ssh_executor` / `self_updater` 是 package 型，它们可以依赖
   `dartssh2` 这类第三方运行时库与协议包 `tree_tunnel_protocol`，但**仍然不许依赖 tree_core /
   tree_protocol**——“不反向依赖核心”是那条纪律的本体，“只用 dart:”只是它的形状之一。
3. **必须带 `--selftest`**：假核心在**同一个进程里**跑真读循环（不连真核心、不起副作用）。
   它是装机后端到端验证读退出码的那一条，所以自检与生产**必须同码**。
4. **`suspend` / 转储由骨架接手**：声明 `suspension: keep` 的插件只需交一份 payload，
   递 `plugin.stateDump` 的命令、新一世 `plugin.stateFetch` 取回都在骨架里。

## 两种形状（同一个入口约定）

`plugin.json` 形状不区分它，构建脚本按**目录里有没有 `pubspec.yaml`** 判：

| 形状 | 判据 | 编译方式 | 现有插件 |
| --- | --- | --- | --- |
| **单文件型** | 无 `pubspec.yaml` | 以**桌面仓根**为工作目录 `dart compile exe <id>_plugin.dart` | `minimal` / `suspendable` / `terminal_probe` / `compact` / `sample` |
| **package 型** | 有 `pubspec.yaml` | 先在该目录 `dart pub get`，再以**该目录**为工作目录编译 | `ssh_executor` / `self_updater` |

package 型的依赖里有 `path: ../../packages/tree_tunnel_protocol` ⇒ **本仓必须 clone 在桌面仓的
`plugins/` 下才能编出这两条**。这不是意外，是取舍：“协议帧形状只住一处”比“本仓能独立编”值钱——
两边各抄一份帧形状的代价是装机后“某个请求突然不认”，而原因分在两个仓里。代价也要说清：
单独 clone 本仓的人，`dart run tool/build_plugins.dart --only ssh_executor` 会直接报路径不存在（
而桌面仓的 `build_plugins.dart` 在插件仓未 clone 时直接退 2，不静默产出空索引）。

## 构建与发布

构建住在**桌面仓**（那边才有工具链与门禁），一个脚本负责整仓：

```
dart run tool/build_plugins.dart            # 逐个编译 + 产物自检 + 写出 build/plugins/plugin-index.json
dart run tool/build_plugins.dart --only minimal
```

它读本仓的 `plugins/*/plugin.json`（所以新增插件不需要改任何构建脚本），产出：

- `build/plugins/<command 文件名>`——成品可执行文件；
- `build/plugins/plugin-index.json`——**发布合同本体**（`bytes` 是真实字节数）。

发布时把索引与资产一起上传：

```
gh release create v1.0.4 build/plugins/plugin-index.json build/plugins/tree_minimal.exe …
```

**桌面安装包不读这份索引、也不带任何插件成品**（2026-10-18 的口径变化，用户指令）：
成品只有本仓的 release 这一个出处，装机端在面板「从发布仓库更新」里把它装进
`<exeDir>/plugins/`。桌面打包链反而自检“包里不许出现插件成品”
（`tool/package_windows.dart` 的 `_assertNoBundledPluginBinaries`，多拷就拒绝出包）——
因为那个目录里随包一份会被装机端当成“核心自带的那一份”保护起来，把用户从本仓装的那版
锁在旧版上。

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
| `app_version_define` | | **开发期字段，不进索引**：声明“把仓根 pubspec 的 `x.y.z` 注进哪个 `String.fromEnvironment` 键”（如 `kAgentVersion` / `kSelfUpdaterVersion`）。给了它就变成 `-D<这个名字>=<版本>` 注入产物，所以必须是合法 Dart 标识符；**且源码里必须真的读同名键**（否则“看上去注入了”而插件拿着 `defaultValue` 自报一个假版本，而目标机驻留目录按版本命名 ⇒ 每次装都当新版重推）——键名必须在这条插件自己的源码里出现过，这件事由 `plugin_repo_contract_test.dart` 钉；而“注对了”由**产物自检**核（`ssh_executor --selftest` 第 7 条：自报版本不等于兜底值） |

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
- `files[].target` **也不许撞上核心随包的文件名**（`sample_plugin.py`、`compact_plugin.py`、
  `tree_ssh_executor[.exe]`、`tree_self_updater[.exe]`）：`plugins/` 里那些是插件源码与随包
  成品，发布仓库只装自己的成品。撞上 ⇒ 整条在**列清单时**就被跳过并写下原因（不必等用户
  点安装才失败）；内置 id 那一道在更前（在核心写下 400，任何磁盘动作之前）。
- `runtime` 只能 `binary` / `python`；`python` 条目在装机端要先探到解释器
  （与内置插件同一套探测口径），探不到就**拒绝安装**而不是写一条注定起不来的配置。
- `suspension` 只能留空或 `keep`；`granularity` 只能 `team` / `agent` / `session`。

发布动作（索引由 `dart run tool/build_plugins.dart` 产出，**不手写**——`bytes` 要等于真实字节数）：

```
gh release create v0.1.0 build/plugins/plugin-index.json <每个资产文件>
```

本仓 `release/plugin-index.json` 是**字段形状的参考模板**（装机端读的那一份永远是构建出来的），
两者字段必须同源：改合同就同时改 `plugin_downloader.dart` 的校验与这份模板。
只改索引不传文件、或只传文件不改索引，都会被判成"发布与索引不同版"并给出可读原因。

## 装机端装上一条插件时会发生什么（顺序不是随便排的）

1. 先把两道内置防线走完（都在核心那边，见下）：**内置 id 不给装**、**随包文件名不给盖**；
2. 资产下载到 `<数据根>/plugins_release/<id>/<version>/`（临时名 + 原子改名；
   字节数不符就**不落地**）。缓存目录与 `plugins/` 分开：半成品不该出现在插件查找路径里。
3. 复制到「可执行文件同级的 `plugins/`」**之前**必须先过闸门：该插件的旧进程**已确认退出**。
   Windows 上正在运行的 exe 删不掉，"先换文件再重启"在这台机器上不成立。
4. 复制到同目录的临时名（`.part-<随机>`），全部复制成功后再逐个**原子改名**覆盖。
5. 写/更新一条 `plugins.yaml` 条目并热应用（等价于面板上打开开关那条路），条目上留
   `source: release` 与 `repo_version`（只给面板显示；行为一律不读它们）。

任何一步失败 ⇒ 旧文件保持原样 + 清掉临时名 + 回一句人话。核心**不会**为了换文件而杀进程：
显式强杀只有用户在面板上按「强制停止」那一条路（框架不变量，见
`docs/plugin-development.md` §6.7）。

## 怎么加一个插件

1. 建目录 + 写 `plugin.json`（字段见上）与 `<id>_plugin.dart`（Dart 插件的四条约定见上）；
2. 本地验证：`dart run plugins/<id>/<id>_plugin.dart --selftest` 退 0，再到桌面仓跑
   `dart run tool/build_plugins.dart --only <id>`（它会把编译 + 产物自检 + 写索引一次做完）；
3. 提 PR（源和随包成品一起，构建中间物不要提）；
4. 合并后由发布方按上面「发布合同」产出一版 release —— **面板能看到它，前提是这一版
   release 带上了 `plugin-index.json`**。
