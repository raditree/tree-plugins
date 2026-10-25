// mcp —— MCP 客户端插件。
//
// MCP 是**能力来源**：本插件连 MCP 服务、自发现 tools/resources/prompts，
// 把工具（含 MCP 元工具/上下文工具）作为普通工具贡献给 tree.agent；
// 执行仍走 plugin.toolCall → 本插件。插件不注册任何中转/执行站。
import 'dart:convert';
import 'dart:io';

import 'package:tree_mcp/tree_mcp.dart';

import '../_kit/plugin_kit.dart';

const String kPluginId = 'mcp';
const String kDisplayName = 'MCP 协议客户端';
const String kVersion = '0.3.0';
const String kCollectStation = 'plugin.tree.agent.collect.tools';
const String kMetaTool = 'mcp';
const String kResourcesTool = 'mcp_resources';
const String kPromptsTool = 'mcp_prompts';
const String kContextTool = 'mcp_context';

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
  for (final McpServerConfig config in _loadConfigs()) {
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
    final Map<String, dynamic> result = await server.channel.request(
      M.stationSubscribe,
      <String, dynamic>{'station_id': kCollectStation},
    );
    server.channel.log(
      '订阅 tree.agent 收集站：${result['ok'] == true ? '成功' : result['error']}',
    );
  } catch (error) {
    server.channel.log('订阅收集站失败：$error');
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
  <String, dynamic>{
    'name': kMetaTool,
    'description': '[MCP] 查看与调用 MCP 工具（help/call）。',
    'parameters': <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'action': <String, dynamic>{'type': 'string', 'enum': <String>['help', 'call']},
        'tool_name': <String, dynamic>{'type': 'string'},
        'arguments': <String, dynamic>{'type': 'object'},
      },
      'required': <String>['action'],
    },
  },
  <String, dynamic>{
    'name': kResourcesTool,
    'description': '[MCP] 列出/读取资源（list/read），用于上下文注入。',
    'parameters': <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'action': <String, dynamic>{'type': 'string', 'enum': <String>['list', 'read']},
        'server': <String, dynamic>{'type': 'string'},
        'uri': <String, dynamic>{'type': 'string'},
      },
      'required': <String>['action'],
    },
  },
  <String, dynamic>{
    'name': kPromptsTool,
    'description': '[MCP] 列出/渲染提示词（list/get）。',
    'parameters': <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'action': <String, dynamic>{'type': 'string', 'enum': <String>['list', 'get']},
        'server': <String, dynamic>{'type': 'string'},
        'name': <String, dynamic>{'type': 'string'},
        'arguments': <String, dynamic>{'type': 'object'},
      },
      'required': <String>['action'],
    },
  },
  <String, dynamic>{
    'name': kContextTool,
    'description': '[MCP] 上下文管理：inventory / select / build。',
    'parameters': <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'action': <String, dynamic>{
          'type': 'string',
          'enum': <String>['inventory', 'select', 'build'],
        },
        'agent_id': <String, dynamic>{'type': 'string'},
        'resources': <String, dynamic>{'type': 'array'},
        'prompts': <String, dynamic>{'type': 'array'},
      },
      'required': <String>['action'],
    },
  },
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
  if (method == M.stationRequest &&
      asString(params['station_id']) == kCollectStation) {
    return <String, dynamic>{
      'reply': <String, dynamic>{
        'payload': <String, dynamic>{'tools': _toolSpecs()},
      },
    };
  }
  return null;
}

String _nativeName(String name) => name.startsWith('plugin__mcp__')
    ? name.substring('plugin__mcp__'.length)
    : name;

Future<Map<String, dynamic>> handleToolCall(
  String name,
  Map<String, dynamic> arguments,
  Map<String, dynamic> scope,
) async {
  final String native = _nativeName(name);
  try {
    if (native == kMetaTool ||
        native == kResourcesTool ||
        native == kPromptsTool ||
        native == kContextTool) {
      return toolText(await _runMeta(native, arguments));
    }
    final List<String> parts = native.split('__');
    if (parts.length != 3 || parts[0] != 'mcp') {
      return toolText('未知 MCP 工具：$name', isError: true);
    }
    final McpProtocolClient? client = _clients[parts[1]];
    if (client == null) {
      return toolText('未知 MCP 服务：${parts[1]}', isError: true);
    }
    final McpCallResult result = await client.callTool(parts[2], arguments);
    return toolText(
      result.text.isEmpty ? '（MCP 工具没有返回内容）' : result.text,
      isError: result.isError,
    );
  } catch (error) {
    return toolText('MCP 调用失败：$error', isError: true);
  }
}

Future<String> _runMeta(
  String tool,
  Map<String, dynamic> args,
) async {
  if (tool == kMetaTool) {
    final String action = (args['action'] ?? '').toString().trim();
    if (action == 'help') return _helpText();
    if (action != 'call') throw McpException("未知 action，支持 'help' 或 'call'");
    final String name = (args['tool_name'] ?? '').toString().trim();
    final List<String> parts = name.split('__');
    if (parts.length != 3 || parts[0] != 'mcp') {
      throw McpException('tool_name 必须是 mcp__<服务>__<工具>：$name');
    }
    final McpProtocolClient? client = _clients[parts[1]];
    if (client == null) throw McpException('未知 MCP 服务：${parts[1]}');
    final McpCallResult result = await client.callTool(
      parts[2],
      asMap(args['arguments']),
    );
    return result.text.isEmpty ? '（MCP 工具没有返回内容）' : result.text;
  }
  if (tool == kResourcesTool) {
    final String action = (args['action'] ?? '').toString().trim();
    if (action == 'list') {
      final StringBuffer out = StringBuffer('MCP 资源：');
      for (final MapEntry<String, McpProtocolClient> entry in _clients.entries) {
        for (final McpResourceInfo resource in entry.value.resources) {
          out.write('\n- ${entry.key} :: ${resource.uri} ${resource.name}');
        }
      }
      return out.toString();
    }
    if (action == 'read') {
      final String server = (args['server'] ?? '').toString();
      final McpProtocolClient? client = _clients[server];
      if (client == null) throw McpException('未知 MCP 服务：$server');
      final McpReadResult read = await client.readResource(
        (args['uri'] ?? '').toString(),
      );
      return read.text.isEmpty ? '（资源为空）' : read.text;
    }
    throw McpException('mcp_resources 支持 list / read');
  }
  if (tool == kPromptsTool) {
    final String action = (args['action'] ?? '').toString().trim();
    if (action == 'list') {
      final StringBuffer out = StringBuffer('MCP 提示词：');
      for (final MapEntry<String, McpProtocolClient> entry in _clients.entries) {
        for (final McpPromptInfo prompt in entry.value.prompts) {
          out.write('\n- ${entry.key} :: ${prompt.name} ${prompt.description}');
        }
      }
      return out.toString();
    }
    if (action == 'get') {
      final String server = (args['server'] ?? '').toString();
      final McpProtocolClient? client = _clients[server];
      if (client == null) throw McpException('未知 MCP 服务：$server');
      final McpPromptResult prompt = await client.getPrompt(
        (args['name'] ?? '').toString(),
        asMap(args['arguments']).map(
          (String k, dynamic v) => MapEntry(k, v.toString()),
        ),
      );
      return prompt.text;
    }
    throw McpException('mcp_prompts 支持 list / get');
  }
  // mcp_context
  final String action = (args['action'] ?? '').toString().trim();
  if (action == 'inventory') return jsonEncode(_context.inventory());
  if (action == 'build') {
    return jsonEncode(_context.build((args['agent_id'] ?? '').toString()));
  }
  if (action == 'select') {
    final String agentId = (args['agent_id'] ?? '').toString();
    _context.select(
      agentId,
      McpContextSelection(
        resources: <McpResourceRef>[
          for (final Object? item in (args['resources'] as List<dynamic>? ?? const <dynamic>[]))
            if (item is Map)
              McpResourceRef(
                server: (item['server'] ?? '').toString(),
                uri: (item['uri'] ?? '').toString(),
              ),
        ],
        prompts: <McpPromptRef>[
          for (final Object? item in (args['prompts'] as List<dynamic>? ?? const <dynamic>[]))
            if (item is Map)
              McpPromptRef(
                server: (item['server'] ?? '').toString(),
                name: (item['name'] ?? '').toString(),
              ),
        ],
      ),
    );
    return '已为 $agentId 选择 MCP 上下文';
  }
  throw McpException('mcp_context 支持 inventory / select / build');
}

String _helpText() {
  final List<String> lines = <String>['可用 MCP 工具列表:'];
  for (final MapEntry<String, McpProtocolClient> entry in _clients.entries) {
    for (final McpToolInfo tool in entry.value.tools) {
      lines.add(
        '- mcp__${entry.key}__${tool.name}${tool.description.isEmpty ? '' : ': ${tool.description}'}',
      );
    }
  }
  if (lines.length == 1) lines.add('当前没有可用的 MCP 工具（检查 TREE_MCP_SERVERS）。');
  return lines.join('\n');
}

Future<void> main(List<String> args) async {
  if (args.contains('--selftest')) {
    final List<String> errors = <String>[];
    if (_toolSpecs().length != 4) errors.add('无服务时应只有 4 个元/上下文工具');
    if (_nativeName('plugin__mcp__mcp__files__read') != 'mcp__files__read') {
      errors.add('命名空间剥离错误');
    }
    if (!_toolSpecs().any((Map<String, dynamic> tool) => tool['name'] == 'mcp')) {
      errors.add('缺少 mcp 元工具');
    }
    if (!_toolSpecs().any((Map<String, dynamic> tool) => tool['name'] == 'mcp_context')) {
      errors.add('缺少 mcp_context 工具');
    }
    for (final String error in errors) {
      stderr.writeln('[FAIL] $error');
    }
    stderr.writeln(errors.isEmpty ? 'mcp_plugin 自检：全部通过' : 'mcp_plugin 自检：失败');
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