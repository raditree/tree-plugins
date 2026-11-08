/// 委派路由申报（核心 `system.collect.api.routes` → 插件）。
///
/// 前缀刻意避开核心已占用的 `/api/settings/*`（帧率/心跳/插件发布源），
/// 统一用 `/api/plugin-settings/*`，避免保护壳/归属表撞车。
library;

const String kApiRoutesStation = 'system.collect.api.routes';

const String kSchemaPattern = '/api/plugin-settings/schema';
const String kValuesPattern = '/api/plugin-settings/values';
const String kResetPattern = '/api/plugin-settings/reset';
const String kApplyPattern = '/api/plugin-settings/apply';

/// 本插件承接的全部设置路由。
const List<Map<String, String>> kDeclaredRoutes = <Map<String, String>>[
  <String, String>{'method': 'GET', 'pattern': kSchemaPattern},
  <String, String>{'method': 'GET', 'pattern': kValuesPattern},
  <String, String>{'method': 'PATCH', 'pattern': kValuesPattern},
  <String, String>{'method': 'POST', 'pattern': kResetPattern},
  <String, String>{'method': 'POST', 'pattern': kApplyPattern},
];
