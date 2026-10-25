import 'protocol.dart';

const String kMcpMetaTool = 'mcp';
const String kMcpResourcesTool = 'mcp_resources';
const String kMcpPromptsTool = 'mcp_prompts';
const String kMcpContextTool = 'mcp_context';

/// 从已连接 MCP 服务生成工具定义：4 个元/上下文工具 + 每个原生 MCP 工具。
///
/// tree.agent 的收集站会把这些定义注入模型工具表；执行仍走 plugin.toolCall。
List<Map<String, dynamic>> mcpToolSpecs(
  Map<String, McpProtocolClient> clients,
) => <Map<String, dynamic>>[
  <String, dynamic>{
    'name': kMcpMetaTool,
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
    'name': kMcpResourcesTool,
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
    'name': kMcpPromptsTool,
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
    'name': kMcpContextTool,
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
  for (final MapEntry<String, McpProtocolClient> entry in clients.entries)
    for (final McpToolInfo tool in entry.value.tools)
      <String, dynamic>{
        'name': 'mcp__${entry.key}__${tool.name}',
        'description': '[${entry.key}] ${tool.description}',
        'parameters': tool.inputSchema.isEmpty
            ? <String, dynamic>{'type': 'object', 'properties': <String, dynamic>{}}
            : tool.inputSchema,
      },
];

/// MCP 工具的命名空间名（与核心旧实现同口径：`mcp__<服务>__<工具>`）。
String mcpNamespacedToolName(String service, String tool) =>
    'mcp__${service}__$tool';

/// 把核心传回的命名空间工具名还原成 MCP 原生名。
String nativeMcpToolName(String name) => name.startsWith('plugin__mcp__')
    ? name.substring('plugin__mcp__'.length)
    : name;