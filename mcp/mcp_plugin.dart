// mcp —— 完整 MCP 客户端插件。
//
// 负责：initialize 能力协商、tools/resources/prompts 自发现、list_changed 刷新、
// resources/read、prompts/get、roots/list，以及按 agent 选择/构建上下文。
// 工具经 tree.agent 的收集站贡献，执行经 plugin.toolCall 回到本插件。
import 'dart:convert';
import 'dart:io';

import 'package:tree_mcp/tree_mcp.dart';

import '../_kit/plugin_kit.dart';

const String kPluginId = 'mcp';
const String kDisplayName = 'MCP 协议客户端';
const String kVersion = '0.1.0';
const String kCollectStation = 'plugin.tree.agent.collect.tools';
const String kContextStation = 'plugin.mcp.execute.context';
const List<String> kContextCommands = <String>[
  'inventory',
  'read_resource',
  'get_prompt',
  'build_context',
  'select_context',
];

final Map<String, McpProtocolClient> _clients = <String, McpProtocolClient>{};
late McpContextManager _context;

PluginKitServer buildServer({bool exitOnShutdown = true}) => PluginKitServer(
  channel: PluginChannel.stdio(kPluginId),
  pluginId: kPluginId,
  displayName: kDisplayName,
  onReady: _onReady,
  onRequest: handleRequest,
  onToolCall: handleToolCall,
  exitOnShutdown: exitOnShutdown,
);

Future<void> _onReady(PluginKitServer server) async {
  _context = McpContextManager(_clients);
  server.channel.log('已上线：v$kVersion（MCP 客户端）');

  final List<McpServerConfig> configs = _loadConfigs();
  for (final McpServerConfig config in configs) {
    try {
      final McpProtocolClient client = await McpProtocolClient.connect(config);
      client.onChanged = () {
        server.channel.log('MCP 服务 ${config.name} 变更：工具/资源/提示词已刷新');
      };
      _clients[config.name] = client;
      server.channel.log(
        'MCP 服务 ${config.name} 已握手：${client.protocolVersion}（工具 ${client.tools.length} / 资源 ${client.resources.length} / 提示词 ${client.prompts.length}）',
      );
    } catch (error) {
      server.channel.log('MCP 服务 ${config.name} 连接失败：$error');
    }
  }

  try {
    final Map<String, dynamic> subscribed = await server.channel.request(
      M.stationSubscribe,
      <String, dynamic>{'station_id': kCollectStation},
    );
    server.channel.log(
      '订阅 tree.agent 收集站：${subscribed['ok'] == true ? '成功' : (subscribed['error'] ?? '失败').toString()}',
    );
  } catch (error) {
    server.channel.log('订阅收集站失败：$error');
  }

  try {
    final Map<String, dynamic> registered = await server.channel.request(
      M.stationRegister,
      <String, dynamic>{
        'kind': 'execute',
        'name': 'context',
        'description': 'MCP 上下文管理',
        'readme': 'MCP 上下文：inventory / read_resource / get_prompt / build_context / select_context。',
        'commands': kContextCommands,
      },
    );
    server.channel.log(
      '上下文执行站：${registered['ok'] == true
                  ? registered['station_id']
                  : registered['error']}',
    );
  } catch (error) {
    server.channel.log('上下文执行站注册失败：$error');
  }
}

List<McpServerConfig> _loadConfigs() {
  final String raw = Platform.environment['TREE_MCP_SERVERS'] ?? '';
  if (raw.trim().isEmpty) return const <McpServerConfig>[];
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! List) return const <McpServerConfig>[];
    return <McpServerConfig>[
      for (final Object? item in decoded)
        if (item is Map)
          McpServerConfig.fromJson(
            item.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
          ),
    ];
  } catch (error) {
    stderr.writeln('[mcp] TREE_MCP_SERVERS 解析失败：$error');
    return const <McpServerConfig>[];
  }
}

List<Map<String, dynamic>> _toolSpecs() => <Map<String, dynamic>>[
  for (final MapEntry<String, McpProtocolClient> entry in _clients.entries)
    for (final McpToolInfo tool in entry.value.tools)
      <String, dynamic>{
        'name': 'mcp__${entry.key}__${tool.name}',
        'description': '[${entry.key}] ${tool.description}',
        'parameters': tool.inputSchema.isEmpty
            ? <String, dynamic>{'type': 'object', 'properties': <String, dynamic>{}}
            : tool.inputSchema,
      },
];

Future<Map<String, dynamic>?> handleRequest(
  String method,
  Map<String, dynamic> params,
) async {
  if (method != M.stationRequest) return null;
  final String station = asString(params['station_id']);
  if (station == kCollectStation) {
    return <String, dynamic>{
      'reply': <String, dynamic>{
        'payload': <String, dynamic>{'tools': _toolSpecs()},
      },
    };
  }
  if (station != kContextStation) return null;
  final Map<String, dynamic> payload = asMap(params['payload']);
  final String command = asString(payload['command']);
  final Map<String, dynamic> args = asMap(payload['arguments']);
  try {
    final Map<String, dynamic> result = await _runContext(command, args);
    return <String, dynamic>{
      'reply': <String, dynamic>{'payload': result},
    };
  } catch (error) {
    return <String, dynamic>{
      'reply': <String, dynamic>{'error': error.toString()},
    };
  }
}

Future<Map<String, dynamic>> _runContext(
  String command,
  Map<String, dynamic> args,
) async {
  switch (command) {
    case 'inventory':
      return _context.inventory();
    case 'read_resource':
      final String server = (args['server'] ?? '').toString();
      final McpProtocolClient? client = _clients[server];
      if (client == null) throw McpException('未知 MCP 服务：$server');
      final McpReadResult read = await client.readResource(
        (args['uri'] ?? '').toString(),
      );
      return <String, dynamic>{'contents': read.contents, 'text': read.text};
    case 'get_prompt':
      final String server = (args['server'] ?? '').toString();
      final McpProtocolClient? client = _clients[server];
      if (client == null) throw McpException('未知 MCP 服务：$server');
      final Map<String, dynamic> promptArgs = asMap(args['arguments']);
      final McpPromptResult prompt = await client.getPrompt(
        (args['name'] ?? '').toString(),
        promptArgs.map((String k, dynamic v) => MapEntry(k, v.toString())),
      );
      return <String, dynamic>{
        'description': prompt.description,
        'messages': prompt.messages,
        'text': prompt.text,
      };
    case 'build_context':
      return _context.build((args['agent_id'] ?? '').toString());
    case 'select_context':
      final String agentId = (args['agent_id'] ?? '').toString();
      final List<McpResourceRef> resources = <McpResourceRef>[
        for (final Object? item in (args['resources'] as List<dynamic>? ?? const <dynamic>[]))
          if (item is Map)
            McpResourceRef(
              server: (item['server'] ?? '').toString(),
              uri: (item['uri'] ?? '').toString(),
            ),
      ];
      final List<McpPromptRef> prompts = <McpPromptRef>[
        for (final Object? item in (args['prompts'] as List<dynamic>? ?? const <dynamic>[]))
          if (item is Map)
            McpPromptRef(
              server: (item['server'] ?? '').toString(),
              name: (item['name'] ?? '').toString(),
            ),
      ];
      _context.select(
        agentId,
        McpContextSelection(resources: resources, prompts: prompts),
      );
      return <String, dynamic>{'agent_id': agentId, 'ok': true};
    default:
      throw McpException('未知上下文命令：$command');
  }
}

Future<Map<String, dynamic>> handleToolCall(
  String name,
  Map<String, dynamic> arguments,
  Map<String, dynamic> scope,
) async {
  final String native = name.startsWith('plugin__')
      ? name.split('__').last
      : name;
  final List<String> parts = native.split('__');
  if (parts.length != 3 || parts[0] != 'mcp') {
    return toolText('未知 MCP 工具：$name', isError: true);
  }
  final String server = parts[1];
  final String tool = parts[2];
  final McpProtocolClient? client = _clients[server];
  if (client == null) {
    return toolText('未知 MCP 服务：$server', isError: true);
  }
  try {
    final McpCallResult result = await client.callTool(tool, arguments);
    return toolText(result.text, isError: result.isError);
  } catch (error) {
    return toolText('MCP 工具执行失败：$error', isError: true);
  }
}

Future<void> main(List<String> args) async {
  if (args.contains('--selftest')) {
    final List<String> errors = <String>[];
    if (_pluginToolName('s', 't') != 'mcp__s__t') {
      errors.add('工具命名空间错误');
    }
    if (McpContextManager.renderText(
          <Map<String, dynamic>>[
            <String, dynamic>{'uri': 'mem://a', 'text': 'body'},
          ],
          const <Map<String, dynamic>>[],
        ) != '[MCP 资源 mem://a]\nbody') {
      errors.add('上下文渲染错误');
    }
    if (_loadConfigs().isNotEmpty) errors.add('空环境不应有服务');
    for (final String error in errors) {
      stderr.writeln('[FAIL] $error');
    }
    stderr.writeln(
      errors.isEmpty ? 'mcp_plugin 自检：全部通过' : 'mcp_plugin 自检：失败',
    );
    exitCode = errors.isEmpty ? 0 : 1;
    return;
  }
  await buildServer().run(stdin);
  for (final McpProtocolClient client in _clients.values) {
    await client.close();
  }
  try {
    await stdout.flush();
  } catch (_) {}
}

String _pluginToolName(String server, String tool) =>
    'mcp__${server}__$tool';