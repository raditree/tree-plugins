/// tree.agent 的领域库（插件仓内包，包名 `tree_agent_loop`）。
///
/// **依赖纪律**（agent_pluginization.md 不变量 1/13）：本包只允许 pub.dev 依赖与
/// 插件仓自带的 `_kit`，**不得 import tree_core / tree_protocol**。复用核心能力
/// 只能走核心的平台内置站（日志 / 存储 / 租约）或其它插件的自建执行站。
///
/// A1 阶段只有身份常量与空路由表；A2 起按
/// `docs/pluginization/agent_api_contract.md` 把 tree_core 的
/// `agent/`、`llm/`、`team/`、`tool/` 平移进 `lib/src/`（只改 import 与依赖注入）。
library;

/// 插件版本（与 `plugin.json` 的 version 同源；发布时两处一起改）。
const String kTreeAgentVersion = '0.1.0';

/// 收集站 id：插件经它申报自己承担的 `{method, pattern}` 委派路由。
const String kApiRoutesStation = 'system.collect.api.routes';

/// A1 上报的委派路由：**空表**。
///
/// A2 起按 `agent_api_contract.md` 的 §1 逐组填写；在此之前回空表是**如实申报**，
/// 不是占位（核心据此知道"已申报、零条"，不会把它当未响应）。
const List<Map<String, String>> kDeclaredRoutes = <Map<String, String>>[];

/// 一条委派路由声明的形状（`{method, pattern}`），给 A2 的常量表用。
Map<String, String> routeDeclaration(String method, String pattern) =>
    <String, String>{'method': method, 'pattern': pattern};
