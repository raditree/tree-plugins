// mcp —— MCP 客户端插件。
//
// MCP 是**能力来源**：本插件连 MCP 服务、自发现 tools/resources/prompts，
// 把工具（含 MCP 元工具/上下文工具）作为普通工具贡献给 tree.agent；
// 执行仍走 plugin.toolCall → 本插件。
//
// D 任务起，本插件还承接核心删除后的三条 REST：
//   GET/POST /api/mcp/services、DELETE /api/mcp/services/{name}
// 路由经 `system.collect.api.routes` 申报，请求由核心转成 `api/delegate`；
// 配置落 `<数据根>/config/mcp.yaml`（数据根来自委派信封的 data_dir）。
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tree_mcp/tree_mcp.dart';

import '../_kit/plugin_kit.dart';

const String kPluginId = 'mcp';
const String kDisplayName = 'MCP 协议客户端';
const String kVersion = '0.4.0';
const String kCollectStation = 'plugin.tree.agent.collect.tools';
const String kMetaTool = 'mcp';
const String kResourcesTool = 'mcp_resources';
const String kPromptsTool = 'mcp_prompts';
const String kContextTool = 'mcp_context';

/// 配置 / 连接管理器（生产在 hello 后创建；自检可替换成绑到临时数据根的实例）。
McpService _service = McpService(log: _logToStderr);

/// 上下文管理器（工具面使用；启动时按 client 表建一次即可）。
McpContextManager? _context;

McpContextManager get _contextManager =>
    _context ??= McpContextManager(_service.clients);

void _logToStderr(String message) => stderr.writeln('[mcp] $message');

PluginKitServer buildServer({bool exitOnShutdown = true}) => PluginKitServer(
  channel: PluginChannel.stdio(kPluginId),
  pluginId: kPluginId,
  displayName: kDisplayName,
  onReady: _onReady,
  onRequest: handleRequest,
  onToolCall: handleToolCall,
  onStop: () => _service.close(),
  exitOnShutdown: exitOnShutdown,
);

Future<void> _onReady(PluginKitServer server) async {
  _service = McpService(log: server.channel.log);
  _context = McpContextManager(_service.clients);
  // 启动时能拿到数据根就先把 config/mcp.yaml 也连上，保证首轮工具表不缺项；
  // 拿不到（核心未注入 TREE_DATA_ROOT）则延迟到第一次委派请求，见 README「限制」。
  final String dataRoot =
      (Platform.environment['TREE_DATA_ROOT'] ??
              Platform.environment['TREE_HOME'] ??
              '')
          .trim();
  if (dataRoot.isNotEmpty) {
    await _service.attach(dataRoot);
    server.channel.log('MCP 配置根：$dataRoot（config/mcp.yaml）');
  } else {
    server.channel.log(
      '未拿到 TREE_DATA_ROOT：config/mcp.yaml 将在首次 /api/mcp/services 请求时'
      '按委派信封的 data_dir 延迟加载',
    );
  }
  // 保持旧插件的环境变量入口：JSON 数组，同名时文件配置优先。
  _service.loadEnvServers(Platform.environment['TREE_MCP_SERVERS'] ?? '');
  await _service.syncConnections();
  for (final McpServerConfig config in _service.servers()) {
    final McpProtocolClient? client = _service.clients[config.name];
    if (client != null && !client.isClosed) {
      server.channel.log(
        'MCP 服务 ${config.name} 已握手：${client.protocolVersion}'
        '（工具 ${client.tools.length} / 资源 ${client.resources.length}'
        ' / 提示词 ${client.prompts.length}）',
      );
    } else if (_service.errorOf(config.name) != null) {
      server.channel.log(
        'MCP 服务 ${config.name} 不可用：${_service.errorOf(config.name)}',
      );
    }
  }
  server.channel.log(
    '已上线：v$kVersion（MCP 客户端；已申报 ${kDeclaredRoutes.length} 条委派路由）',
  );
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

List<Map<String, dynamic>> _toolSpecs() => mcpToolSpecs(_service.clients);

Future<Map<String, dynamic>?> handleRequest(
  String method,
  Map<String, dynamic> params,
) async {
  if (method == M.apiDelegate) {
    // 核心 → 插件：委派一次 HTTP 请求；params 就是信封本体。
    return handleApiDelegate(asMap(params), service: _service);
  }
  if (method == M.stationRequest) {
    final String station = asString(params['station_id']);
    if (station == kCollectStation) {
      return <String, dynamic>{
        'reply': <String, dynamic>{
          'payload': <String, dynamic>{'tools': _toolSpecs()},
        },
      };
    }
    if (station == kApiRoutesStation) {
      // 收集站口径：`{reply: {payload: {routes: [...]}}}`（核心只读 reply.payload）。
      return <String, dynamic>{
        'reply': <String, dynamic>{
          'payload': <String, dynamic>{'routes': kDeclaredRoutes},
        },
      };
    }
  }
  return null;
}

Future<Map<String, dynamic>> handleToolCall(
  String name,
  Map<String, dynamic> arguments,
  Map<String, dynamic> scope,
) async {
  final String native = nativeMcpToolName(name);
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
    final McpProtocolClient? client = await _service.ensureConnected(parts[1]);
    if (client == null) {
      return toolText(
        'MCP 服务 ${parts[1]} 不可用：'
        '${_service.errorOf(parts[1]) ?? '未连接（检查 config/mcp.yaml 或 TREE_MCP_SERVERS）'}',
        isError: true,
      );
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

Future<String> _runMeta(String tool, Map<String, dynamic> args) async {
  if (tool == kMetaTool) {
    final String action = (args['action'] ?? '').toString().trim();
    if (action == 'help') return _helpText();
    if (action != 'call') throw McpException("未知 action，支持 'help' 或 'call'");
    final String name = (args['tool_name'] ?? '').toString().trim();
    final List<String> parts = name.split('__');
    if (parts.length != 3 || parts[0] != 'mcp') {
      throw McpException('tool_name 必须是 mcp__<服务>__<工具>：$name');
    }
    final McpProtocolClient? client = await _service.ensureConnected(parts[1]);
    if (client == null) {
      throw McpException(
        '未知或不可用的 MCP 服务：${parts[1]}'
        '（${_service.errorOf(parts[1]) ?? '未配置'}）',
      );
    }
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
      for (final MapEntry<String, McpProtocolClient> entry
          in _service.clients.entries) {
        for (final McpResourceInfo resource in entry.value.resources) {
          out.write('\n- ${entry.key} :: ${resource.uri} ${resource.name}');
        }
      }
      return out.toString();
    }
    if (action == 'read') {
      final String server = (args['server'] ?? '').toString();
      final McpProtocolClient? client = await _service.ensureConnected(server);
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
      for (final MapEntry<String, McpProtocolClient> entry
          in _service.clients.entries) {
        for (final McpPromptInfo prompt in entry.value.prompts) {
          out.write('\n- ${entry.key} :: ${prompt.name} ${prompt.description}');
        }
      }
      return out.toString();
    }
    if (action == 'get') {
      final String server = (args['server'] ?? '').toString();
      final McpProtocolClient? client = await _service.ensureConnected(server);
      if (client == null) throw McpException('未知 MCP 服务：$server');
      final McpPromptResult prompt = await client.getPrompt(
        (args['name'] ?? '').toString(),
        asMap(args['arguments'])
            .map((String k, dynamic v) => MapEntry(k, v.toString())),
      );
      return prompt.text;
    }
    throw McpException('mcp_prompts 支持 list / get');
  }
  // mcp_context
  final String action = (args['action'] ?? '').toString().trim();
  if (action == 'inventory') return jsonEncode(_contextManager.inventory());
  if (action == 'build') {
    return jsonEncode(
      await _contextManager.build((args['agent_id'] ?? '').toString()),
    );
  }
  if (action == 'select') {
    final String agentId = (args['agent_id'] ?? '').toString();
    _contextManager.select(
      agentId,
      McpContextSelection(
        resources: <McpResourceRef>[
          for (final Object? item
              in (args['resources'] as List<dynamic>? ?? const <dynamic>[]))
            if (item is Map)
              McpResourceRef(
                server: (item['server'] ?? '').toString(),
                uri: (item['uri'] ?? '').toString(),
              ),
        ],
        prompts: <McpPromptRef>[
          for (final Object? item
              in (args['prompts'] as List<dynamic>? ?? const <dynamic>[]))
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
  for (final MapEntry<String, McpProtocolClient> entry
      in _service.clients.entries) {
    for (final McpToolInfo tool in entry.value.tools) {
      lines.add(
        '- mcp__${entry.key}__${tool.name}'
        '${tool.description.isEmpty ? '' : ': ${tool.description}'}',
      );
    }
  }
  if (lines.length == 1) {
    lines
      ..add('当前没有已连接的 MCP 服务。')
      ..add('- stdio 服务配置：<数据根>/config/mcp.yaml，或 TREE_MCP_SERVERS（JSON 数组）。');
    for (final MapEntry<String, String> entry in _service.errors.entries) {
      lines.add('- ${entry.key}: ${entry.value}');
    }
  }
  return lines.join('\n');
}

Future<void> main(List<String> args) async {
  if (args.contains('--selftest')) {
    // 自检输出走 stderr："stdout 只有协议帧"这条铁律不因模式而变。
    exitCode = await selfTest();
    return;
  }
  await buildServer().run(stdin);
  await _service.close();
  try {
    await stdout.flush();
  } catch (_) {}
}

/// 假核心自检：hello / 路由申报 / delegate GET-POST-DELETE / 配置落盘。
///
/// 与生产**共用**同一套 PluginKitServer 读循环和同一套 handleRequest；
/// 注册用 `enabled: false` 避开真子进程，保证装机自检快且不依赖网络。
Future<int> selfTest() async {
  final SelfTest check = SelfTest(name: 'mcp_plugin');
  final Directory temp = Directory.systemTemp.createTempSync('mcp_selftest_');
  _service = McpService(log: _logToStderr);
  final PluginKitServer server = PluginKitServer(
    channel: PluginChannel(logTag: kPluginId),
    pluginId: kPluginId,
    displayName: kDisplayName,
    // 自检不跑启动连接 / 收集站订阅：只验证路由申报与委派分发。
    onReady: (_) async {},
    onRequest: handleRequest,
    exitOnShutdown: false,
  );
  final FakeCore core = FakeCore(server);
  final Future<void> loop = core.start();
  try {
    Map<String, dynamic> envelope(
      String method,
      String path, {
      Map<String, Object?> params = const <String, Object?>{},
      Map<String, Object?>? body,
      String dataDir = '',
    }) => <String, dynamic>{
      'method': method,
      'path': path,
      'params': params,
      'query': <String, dynamic>{},
      'headers': <String, dynamic>{},
      'scope': <String, dynamic>{},
      'workspace_dir': '',
      'data_dir': dataDir,
      'agent_id': '',
      'team_id': '',
      'request_id': 'selftest-${method.toLowerCase()}',
      if (body != null) 'body': jsonEncode(body),
    };

    core.ask(0, M.hello, <String, dynamic>{'plugin_id': kPluginId});
    core.ask(1, M.toolsList);
    core.ask(2, M.stationRequest, <String, dynamic>{
      'station_id': kApiRoutesStation,
      'payload': <String, dynamic>{},
    });
    core.ask(
      3,
      M.apiDelegate,
      envelope('GET', mcpServicesPattern, dataDir: temp.path),
    );
    core.ask(
      4,
      M.apiDelegate,
      envelope(
        'POST',
        mcpServicesPattern,
        dataDir: temp.path,
        body: <String, Object?>{
          'name': 'selftest',
          'transport': 'stdio',
          'command': 'noop',
          'enabled': false,
        },
      ),
    );
    Map<Object?, Map<String, dynamic>> byId = await core.waitFor(<int>[
      0,
      1,
      2,
      3,
      4,
    ]);

    Map<String, dynamic> replyOf(Object id) =>
        (byId[id]?['result'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};

    Map<String, dynamic> bodyOf(Object id) {
      final Object? raw = replyOf(id)['body'];
      if (raw is String && raw.trim().isNotEmpty) {
        final Object? decoded = jsonDecode(raw);
        if (decoded is Map) {
          return decoded.map(
            (Object? k, Object? v) => MapEntry(k.toString(), v),
          );
        }
      }
      return <String, dynamic>{};
    }

    // ── 路由申报：三条，形状 `{routes: [{method, pattern}]}` ─────────
    final Object? stationReply = replyOf(2)['reply'];
    final Object? stationPayload = stationReply is Map
        ? (stationReply['payload'])
        : null;
    final Object? declared = stationPayload is Map
        ? stationPayload['routes']
        : null;
    check.check(declared, kDeclaredRoutes, '路由申报：GET/POST/DELETE 三条');
    check.check(kDeclaredRoutes.length, 3, '路由申报：条数为 3');

    // ── 未连接时：列表空、错误空、工具表 4 个元工具 ─────────────────
    final Map<String, dynamic> emptyList = bodyOf(3);
    check.check(replyOf(3)['status'], 200, 'delegate GET：200');
    check.check(emptyList['services'], <dynamic>[], 'delegate GET：空服务列表');
    check.check(emptyList['tools'], <dynamic>[], 'delegate GET：空工具列表');
    check.check(emptyList['errors'], <String, dynamic>{}, 'delegate GET：错误表');

    // tools/list 由骨架应答构造期固定的 tools 字段；本插件的工具面经 tree.agent
    // 收集站贡献，所以这里直接断言 _toolSpecs() 的 4 个元/上下文工具。
    check.check(_toolSpecs().length, 4, '工具面：无服务时 4 个元/上下文工具');
    check.check(
      nativeMcpToolName('plugin__mcp__mcp__files__read'),
      'mcp__files__read',
      '工具名：命名空间剥离',
    );
    final Set<String> metaNames = <String>{
      for (final Map<String, dynamic> tool in _toolSpecs())
        tool['name'].toString(),
    };
    check.that(metaNames.contains('mcp'), '工具面：含 mcp 元工具');
    check.that(metaNames.contains('mcp_context'), '工具面：含 mcp_context 工具');

    // ── POST 注册（enabled=false，不拉起子进程）→ 落盘 → GET 可见 ────
    final Map<String, dynamic> registered = bodyOf(4);
    check.check(replyOf(4)['status'], 200, 'delegate POST：200');
    check.check(registered['success'], true, 'delegate POST：success');
    final Map<String, dynamic>? service = (registered['service'] as Map?)
        ?.cast<String, dynamic>();
    check.check(service?['name'], 'selftest', 'delegate POST：回服务条目 name');
    check.check(service?['transport'], 'stdio', 'delegate POST：回 transport');
    check.check(service?['enabled'], false, 'delegate POST：回 enabled');
    check.check(registered['tools'], <dynamic>[], 'delegate POST：未连接时工具空');

    final File configFile = File(p.join(temp.path, 'config', 'mcp.yaml'));
    check.that(configFile.existsSync(), '配置落盘：config/mcp.yaml 存在');
    final String configText = configFile.existsSync()
        ? configFile.readAsStringSync()
        : '';
    check.that(
      configText.contains('selftest'),
      '配置落盘：YAML 含刚注册的服务',
      actual: configText,
    );

    // 第二批请求等第一批断言完再发：文件落盘是**中间状态**，一次全发会
    // 被后续 DELETE 覆盖掉，读到的就不是 POST 刚写完的那份。
    core.ask(
      5,
      M.apiDelegate,
      envelope('GET', mcpServicesPattern, dataDir: temp.path),
    );
    core.ask(
      6,
      M.apiDelegate,
      envelope(
        'DELETE',
        mcpServicePattern.replaceFirst('{name}', 'selftest'),
        params: <String, Object?>{'name': 'selftest'},
        dataDir: temp.path,
      ),
    );
    core.ask(
      7,
      M.apiDelegate,
      envelope('GET', mcpServicesPattern, dataDir: temp.path),
    );
    core.ask(
      8,
      M.apiDelegate,
      envelope(
        'POST',
        mcpServicesPattern,
        dataDir: temp.path,
        body: <String, Object?>{'name': 'bad'},
      ),
    );
    core.ask(
      9,
      M.apiDelegate,
      envelope('GET', '/api/mcp/not-implemented', dataDir: temp.path),
    );
    byId = await core.waitFor(<int>[5, 6, 7, 8, 9]);

    final Map<String, dynamic> listed = bodyOf(5);
    final List<dynamic> services =
        listed['services'] as List<dynamic>? ?? const <dynamic>[];
    check.check(services.length, 1, 'delegate GET：注册后一条服务');
    check.check(
      ((services.isEmpty ? null : services.first) as Map?)?['name'],
      'selftest',
      'delegate GET：服务名',
    );

    // ── DELETE → 再 GET 空 → 配置里不再有该服务 ─────────────────────
    final Map<String, dynamic> removed = bodyOf(6);
    check.check(replyOf(6)['status'], 200, 'delegate DELETE：200');
    check.check(removed['success'], true, 'delegate DELETE：success');
    check.check(removed['name'], 'selftest', 'delegate DELETE：回 name');
    check.check(
      (bodyOf(7)['services'] as List<dynamic>? ?? const <dynamic>[]).length,
      0,
      'delegate DELETE：再 GET 为空',
    );
    final String afterText = configFile.existsSync()
        ? configFile.readAsStringSync()
        : '';
    check.that(
      !afterText.contains('selftest'),
      '配置落盘：删除后 YAML 不再含该服务',
      actual: afterText,
    );

    // ── 校验失败 / 未实现路由：可读状态码，不 404 不挂起 ─────────────
    final Map<String, dynamic> bad = bodyOf(8);
    check.check(replyOf(8)['status'], 400, 'delegate POST：缺 command ⇒ 400');
    check.check(bad['detail'], '缺少 command', 'delegate POST：400 错误体');
    check.check(replyOf(9)['status'], 501, '未实现路由 ⇒ 501（不是 404）');
  } finally {
    await core.close();
    await loop.timeout(const Duration(seconds: 2), onTimeout: () {});
    await _service.close();
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  }
  return check.finish(core.logs);
}
