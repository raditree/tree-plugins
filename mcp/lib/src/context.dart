import 'protocol.dart';

/// 一次上下文选择：资源 URI 与提示词引用（按 agent 保存）。
class McpContextSelection {
  McpContextSelection({
    List<McpResourceRef>? resources,
    List<McpPromptRef>? prompts,
  }) : resources = resources ?? <McpResourceRef>[],
       prompts = prompts ?? <McpPromptRef>[];

  final List<McpResourceRef> resources;
  final List<McpPromptRef> prompts;
}

class McpResourceRef {
  const McpResourceRef({required this.server, required this.uri});
  final String server;
  final String uri;
}

class McpPromptRef {
  const McpPromptRef({
    required this.server,
    required this.name,
    this.arguments = const <String, String>{},
  });
  final String server;
  final String name;
  final Map<String, String> arguments;
}

/// 多个 MCP 服务的上下文管理：清单、选择、按 agent 构建上下文。
class McpContextManager {
  McpContextManager(this.clients);

  final Map<String, McpProtocolClient> clients;
  final Map<String, McpContextSelection> _selections =
      <String, McpContextSelection>{};

  /// 全部服务的自发现结果（工具 / 资源 / 模板 / 提示词 / 能力）。
  Map<String, dynamic> inventory() => <String, dynamic>{
    'servers': <Map<String, dynamic>>[
      for (final MapEntry<String, McpProtocolClient> entry in clients.entries)
        <String, dynamic>{
          'server': entry.key,
          'protocol_version': entry.value.protocolVersion,
          'server_info': entry.value.serverInfo,
          'capabilities': entry.value.capabilities.toJson(),
          'tools': <Map<String, dynamic>>[
            for (final McpToolInfo tool in entry.value.tools)
              <String, dynamic>{
                'name': tool.name,
                'description': tool.description,
                'input_schema': tool.inputSchema,
              },
          ],
          'resources': <Map<String, dynamic>>[
            for (final McpResourceInfo resource in entry.value.resources)
              <String, dynamic>{
                'uri': resource.uri,
                'name': resource.name,
                'description': resource.description,
                'mime_type': resource.mimeType,
              },
          ],
          'resource_templates': <Map<String, dynamic>>[
            for (final McpResourceTemplate template in entry.value.resourceTemplates)
              <String, dynamic>{
                'uri_template': template.uriTemplate,
                'name': template.name,
              },
          ],
          'prompts': <Map<String, dynamic>>[
            for (final McpPromptInfo prompt in entry.value.prompts)
              <String, dynamic>{
                'name': prompt.name,
                'description': prompt.description,
                'arguments': prompt.arguments,
              },
          ],
        },
    ],
  };

  McpContextSelection selectionOf(String agentId) =>
      _selections.putIfAbsent(agentId, () => McpContextSelection());

  void select(String agentId, McpContextSelection selection) {
    _selections[agentId] = selection;
  }

  void clear(String agentId) => _selections.remove(agentId);

  /// 按 agent 的选择读取资源、渲染提示词；单个失败只记错误，不整单失败。
  Future<Map<String, dynamic>> build(String agentId) async {
    final McpContextSelection selection = selectionOf(agentId);
    final List<Map<String, dynamic>> resources = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> prompts = <Map<String, dynamic>>[];
    final List<String> errors = <String>[];
    for (final McpResourceRef ref in selection.resources) {
      final McpProtocolClient? client = clients[ref.server];
      if (client == null) {
        errors.add('未知 MCP 服务：${ref.server}');
        continue;
      }
      try {
        final McpReadResult read = await client.readResource(ref.uri);
        resources.add(<String, dynamic>{
          'server': ref.server,
          'uri': ref.uri,
          'contents': read.contents,
          'text': read.text,
        });
      } catch (error) {
        errors.add('${ref.server} 读取 ${ref.uri} 失败：$error');
      }
    }
    for (final McpPromptRef ref in selection.prompts) {
      final McpProtocolClient? client = clients[ref.server];
      if (client == null) {
        errors.add('未知 MCP 服务：${ref.server}');
        continue;
      }
      try {
        final McpPromptResult prompt = await client.getPrompt(
          ref.name,
          ref.arguments.map((String k, String v) => MapEntry(k, v)),
        );
        prompts.add(<String, dynamic>{
          'server': ref.server,
          'name': ref.name,
          'description': prompt.description,
          'messages': prompt.messages,
          'text': prompt.text,
        });
      } catch (error) {
        errors.add('${ref.server} 渲染提示词 ${ref.name} 失败：$error');
      }
    }
    return <String, dynamic>{
      'agent_id': agentId,
      'resources': resources,
      'prompts': prompts,
      'errors': errors,
      'text': renderText(resources, prompts),
    };
  }

  /// 把上下文渲染成可直接拼进系统提示词/消息的文本。
  static String renderText(
    List<Map<String, dynamic>> resources,
    List<Map<String, dynamic>> prompts,
  ) {
    final StringBuffer buffer = StringBuffer();
    for (final Map<String, dynamic> resource in resources) {
      buffer
        ..writeln('[MCP 资源 ${resource['uri']}]')
        ..writeln((resource['text'] ?? '').toString());
    }
    for (final Map<String, dynamic> prompt in prompts) {
      buffer
        ..writeln('[MCP 提示词 ${prompt['name']}]')
        ..writeln((prompt['text'] ?? '').toString());
    }
    return buffer.toString().trimRight();
  }
}