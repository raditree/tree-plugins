/// 委派路由申报（核心 `system.collect.api.routes` → 插件）。
///
/// 三条与核心旧实现同键同形；声明必须在插件启动后、核心收集路由时如实给出，
/// 核心据此把命中请求转成 `api/delegate` 发给本插件。
library;

/// 收集站 id：核心请插件申报自己承接的 REST 路由。
const String kApiRoutesStation = 'system.collect.api.routes';

/// `GET/POST /api/mcp/services`（列表 / 注册或覆盖）。
const String mcpServicesPattern = '/api/mcp/services';

/// `DELETE /api/mcp/services/{name}`（删除）。
const String mcpServicePattern = '/api/mcp/services/{name}';

/// 本插件承接的全部委派路由（与 `packages/tree_protocol` 的契约集合对齐）。
const List<Map<String, String>> kDeclaredRoutes = <Map<String, String>>[
  <String, String>{'method': 'GET', 'pattern': mcpServicesPattern},
  <String, String>{'method': 'POST', 'pattern': mcpServicesPattern},
  <String, String>{'method': 'DELETE', 'pattern': mcpServicePattern},
];

/// 一条路由声明的形状（`{method, pattern}`）。
Map<String, String> mcpRouteDeclaration(String method, String pattern) =>
    <String, String>{'method': method, 'pattern': pattern};
