/// tree.agent 的领域库（插件仓内包，包名 `tree_agent_loop`）。
///
/// **依赖纪律**（agent_pluginization.md 不变量 1/13）：本包只允许 pub.dev 依赖与
/// 插件仓自带的 `_kit`，**不得 import tree_core / tree_protocol**。复用核心能力
/// 只能走核心的平台内置站（日志 / 存储 / 租约）或其它插件的自建执行站。
///
/// A1 骨架已上线；A2 正在按 `docs/pluginization/agent_api_contract.md`
/// 把 tree_core 的 `agent/`、`llm/`、`team/`、`tool/` 平移进 `lib/src/`
/// （只改 import 与依赖注入）。第一批只读路由见 `src/delegate.dart`。
library;

import 'src/delegate.dart' show todosPattern;

export 'src/delegate.dart';
export 'src/paths.dart';
export 'src/todo_store.dart';

/// 插件版本（与 `plugin.json` 的 version 同源；发布时两处一起改）。
const String kTreeAgentVersion = '0.2.0';

/// 收集站 id：插件经它申报自己承担的 `{method, pattern}` 委派路由。
const String kApiRoutesStation = 'system.collect.api.routes';

/// 已申报的委派路由（**如实申报**：核心据此知道哪些键归本插件）。
///
/// A2 起按 `agent_api_contract.md` §1 逐组追加；双跑期核心仍实现同键时，
/// 核心会把它标注为 shadowed 并继续由核心承接（查表顺序），交接删除后自动生效。
const List<Map<String, String>> kDeclaredRoutes = <Map<String, String>>[
  <String, String>{'method': 'GET', 'pattern': todosPattern},
];

/// 一条委派路由声明的形状（`{method, pattern}`）。
Map<String, String> routeDeclaration(String method, String pattern) =>
    <String, String>{'method': method, 'pattern': pattern};
