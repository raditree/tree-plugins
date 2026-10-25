import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_mcp/tree_mcp.dart';

void main() {
  test('协议方法常量：MCP 方法有独立家，不混入插件 RPC 面', () {
    expect(McpMethods.all, contains(McpMethods.initialize));
    expect(McpMethods.all, contains(McpMethods.resourcesRead));
    expect(McpMethods.all, contains(McpMethods.promptsGet));
    expect(McpMethods.all, contains(McpMethods.rootsList));
    expect(McpMethods.all.length, 16);
  });

  late McpProtocolClient client;

  setUp(() async {
    final String script = p.join(
      Directory.current.path,
      'test',
      'fixtures',
      'fake_full_mcp_server.dart',
    );
    client = await McpProtocolClient.connect(
      McpServerConfig(
        name: 'fake',
        command: Platform.resolvedExecutable,
        args: <String>[script],
      ),
    );
  });

  tearDown(() async {
    await client.close();
  });

  test('工具自动暴露：已发现的 MCP 工具进入工具定义', () {
    final List<Map<String, dynamic>> specs = mcpToolSpecs(
      <String, McpProtocolClient>{'fake': client},
    );
    final Set<String> names = specs
        .map((Map<String, dynamic> spec) => spec['name'].toString())
        .toSet();
    expect(names, contains('mcp'));
    expect(names, contains('mcp_resources'));
    expect(names, contains('mcp_prompts'));
    expect(names, contains('mcp_context'));
    expect(names, contains('mcp__fake__echo'));
    expect(names, contains('mcp__fake__roots'));
    expect(nativeMcpToolName('plugin__mcp__mcp__fake__echo'), 'mcp__fake__echo');
  });

  test('initialize：能力协商 + tools/resources/prompts 自发现（分页拉全）', () {
    expect(client.protocolVersion, '2025-06-18');
    expect(client.serverInfo['name'], 'fake-full-mcp');
    expect(client.capabilities.tools, isTrue);
    expect(client.capabilities.resources, isTrue);
    expect(client.capabilities.prompts, isTrue);
    expect(client.capabilities.logging, isTrue);
    expect(client.tools.map((McpToolInfo t) => t.name), containsAll(
      <String>['echo', 'roots', 'notify_add'],
    ));
    expect(client.resources.single.uri, 'mem://a');
    expect(client.resourceTemplates.single.uriTemplate, 'mem://{id}');
    expect(client.prompts.single.name, 'greet');
  });

  test('tools/call + notifications/tools/list_changed 自动刷新', () async {
    final McpCallResult echo = await client.callTool(
      'echo',
      <String, dynamic>{'text': 'hello'},
    );
    expect(echo.text, 'hello');
    expect(echo.isError, isFalse);

    await client.callTool('notify_add', <String, dynamic>{});
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!client.tools.any((McpToolInfo t) => t.name == 'added') &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(
      client.tools.map((McpToolInfo t) => t.name),
      contains('added'),
      reason: 'list_changed 后必须自动重拉 tools/list',
    );
  });

  test('resources/read 与 prompts/get：上下文内容可读', () async {
    final McpReadResult read = await client.readResource('mem://a');
    expect(read.text, 'resource-body:mem://a');
    expect(read.contents.single['mimeType'], 'text/plain');

    final McpPromptResult prompt = await client.getPrompt(
      'greet',
      <String, dynamic>{'who': 'Tree'},
    );
    expect(prompt.text, contains('prompt-body'));
    expect(prompt.messages.single['role'], 'user');
  });

  test('roots/list：服务端主动问、客户端按当前 roots 回', () async {
    client.setRoots(<McpRoot>[
      const McpRoot(uri: 'file:///work/a', name: 'A'),
    ]);
    final McpCallResult result = await client.callTool(
      'roots',
      <String, dynamic>{},
    );
    expect(result.text, contains('file:///work/a'));
    expect(result.text, contains('A'));
  });

  test('上下文管理：按 agent 选择资源/提示词，build 渲染文本', () async {
    final McpContextManager manager = McpContextManager(
      <String, McpProtocolClient>{'fake': client},
    );
    manager.select(
      'agt',
      McpContextSelection(
        resources: <McpResourceRef>[
          const McpResourceRef(server: 'fake', uri: 'mem://a'),
        ],
        prompts: <McpPromptRef>[
          const McpPromptRef(server: 'fake', name: 'greet'),
        ],
      ),
    );
    final Map<String, dynamic> built = await manager.build('agt');
    expect(built['errors'], isEmpty);
    expect((built['text'] as String), contains('resource-body:mem://a'));
    expect((built['text'] as String), contains('prompt-body'));
    expect(
      (manager.inventory()['servers'] as List<dynamic>).single['server'],
      'fake',
    );
  });
}