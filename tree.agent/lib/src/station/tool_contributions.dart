import 'dart:async';

/// 工具贡献收集站：其它插件订阅本插件自建的收集站，把自己的工具登记进来。
///
/// 站点 id 由核心拼装：`plugin.<本插件id>.collect.tools`。订阅者收到的采集请求
/// `payload = {action: list}`，按 schema 回 `{tools: [{name, description, parameters}]}`；
/// 本插件把工具名改写成核心命名空间 `plugin__<pluginId>__<name>`，执行时走核心
/// 执行站的 `tool.call`（核心再转到该插件的 `tools/call`）。
const String kToolCollectName = 'tools';

/// 触发站点（核心 `station/trigger`；收集站回包含 `result.items`）。
///
/// [topic] 只对**广播站**有意义（A4 事件站按 `<plugin>.<session>.<kind>` 分流）；
/// 收集站/中转站不传（核心会按"缺 topic"报可读错误，不会静默丢）。
typedef StationTriggerClient =
    Future<Map<String, dynamic>> Function(
      String stationId,
      Object? payload,
      Map<String, dynamic> meta,
      Map<String, dynamic> scope, {
      String? topic,
    });

/// 本插件自建收集站 id（plugin.tree.agent.collect.tools）。
String toolCollectStationId(String pluginId) =>
    'plugin.$pluginId.collect.$kToolCollectName';

/// 收集站 schema：订阅者回复一个 `tools` 数组。
Map<String, dynamic> toolCollectSchema() => <String, dynamic>{
  'kind': 'object',
  'description': '插件工具贡献：每个订阅者回一个 tools 数组',
  'fields': <Map<String, dynamic>>[
    <String, dynamic>{
      'name': 'tools',
      'type': 'array',
      'required': true,
      'description': '工具数组，元素为 {name, description, parameters}',
    },
  ],
};

/// 站点介绍（核心要求 readme 必填）。
const String kToolCollectReadme =
    '工具贡献收集站：本插件在构建工具表时触发一次采集，所有订阅者按 schema 回'
    ' {tools:[{name,description,parameters}]}。工具名会被改写成核心命名空间'
    ' plugin__<插件id>__<name>，执行经执行站 tool.call 转给贡献插件。';

/// 一条被贡献的工具。
class ContributedTool {
  const ContributedTool({
    required this.pluginId,
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String pluginId;
  final String name;
  final String description;
  final Map<String, dynamic> parameters;

  /// 核心工具命名空间（`plugin__<pluginId>__<name>`）。
  String get coreName => 'plugin__${pluginId}__$name';
}

/// 从收集站触发回包里解析贡献工具；坏条目跳过，不让一个插件拖垮整张表。
List<ContributedTool> parseContributedTools(Map<String, dynamic> response) {
  final Object? result = response['result'];
  if (result is! Map) return const <ContributedTool>[];
  final Object? items = result['items'];
  if (items is! List) return const <ContributedTool>[];
  final List<ContributedTool> out = <ContributedTool>[];
  for (final Object? item in items) {
    if (item is! Map) continue;
    final String pluginId = (item['plugin_id'] ?? '').toString().trim();
    final Object? payload = item['payload'];
    if (pluginId.isEmpty || payload is! Map) continue;
    final Object? tools = payload['tools'];
    if (tools is! List) continue;
    for (final Object? raw in tools) {
      if (raw is! Map) continue;
      final String name = (raw['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final Object? parameters = raw['parameters'];
      out.add(
        ContributedTool(
          pluginId: pluginId,
          name: name,
          description: (raw['description'] ?? '').toString(),
          parameters: parameters is Map
              ? parameters.map(
                  (dynamic k, dynamic v) => MapEntry(k.toString(), v),
                )
              : <String, dynamic>{'type': 'object', 'properties': <String, dynamic>{}},
        ),
      );
    }
  }
  return out;
}