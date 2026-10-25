import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_mcp/tree_mcp.dart';

/// D 任务：mcp 插件承接 `/api/mcp/services` 三条路由。
///
/// 覆盖：路由申报、配置加载 / 优先级、delegate GET/POST/DELETE 的状态码与
/// 响应形状、校验失败与未实现路由、以及一次真子进程的 stdio 注册→工具可见。
void main() {
  group('路由申报', () {
    test('三条与 UI 原 REST 路径一致（方法 + 模式）', () {
      expect(kDeclaredRoutes, <Map<String, String>>[
        <String, String>{'method': 'GET', 'pattern': '/api/mcp/services'},
        <String, String>{'method': 'POST', 'pattern': '/api/mcp/services'},
        <String, String>{
          'method': 'DELETE',
          'pattern': '/api/mcp/services/{name}',
        },
      ]);
    });

    test('申报形状是 {method, pattern} 且方法合法', () {
      for (final Map<String, String> route in kDeclaredRoutes) {
        expect(route.keys.toSet(), <String>{'method', 'pattern'});
        expect(<String>['GET', 'POST', 'DELETE'], contains(route['method']));
        expect(route['pattern'], startsWith('/api/mcp/services'));
      }
    });
  });

  group('配置加载与合并', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('mcp_config_');
    });

    tearDown(() {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('config/mcp.yaml：stdio 与 http 字段完整，README 承诺的键恒定出现', () {
      final File file = File(p.join(temp.path, 'config', 'mcp.yaml'));
      file.createSync(recursive: true);
      file.writeAsStringSync('''
servers:
  - name: files
    command: npx
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
    env:
      API_KEY: secret
    enabled: true
    builtin: true
    scope: local
  - name: remote
    transport: http
    url: "https://example.com/mcp"
    headers:
      Authorization: "Bearer x"
    enabled: false
''');
      final McpConfigStore store = McpConfigStore();
      expect(store.bindDataDir(temp.path), isTrue);
      final List<McpServerConfig> servers = store.servers;
      expect(servers, hasLength(2));

      final McpServerConfig files = servers[0];
      expect(files.name, 'files');
      expect(files.transport, 'stdio');
      expect(files.isHttp, isFalse);
      expect(files.command, 'npx');
      expect(files.args, contains('/tmp'));
      expect(files.env['API_KEY'], 'secret');
      expect(files.enabled, isTrue);
      expect(files.builtin, isTrue);
      expect(files.scope, 'local');

      final McpServerConfig remote = servers[1];
      expect(remote.name, 'remote');
      expect(remote.isHttp, isTrue);
      expect(remote.url, 'https://example.com/mcp');
      expect(remote.headers['Authorization'], 'Bearer x');
      expect(remote.enabled, isFalse);

      expect(remote.toApiJson().keys.toSet(), <String>{
        'name',
        'transport',
        'command',
        'args',
        'url',
        'headers',
        'builtin',
        'enabled',
        'scope',
      });
    });

    test('TREE_MCP_SERVERS 兼容老形状：name/command/args，缺省 stdio + enabled', () {
      final List<McpServerConfig> configs = parseMcpServersEnv(
        jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'files',
            'command': 'npx',
            'args': <String>['-y', 'pkg'],
          },
        ]),
      );
      expect(configs, hasLength(1));
      expect(configs.single.name, 'files');
      expect(configs.single.transport, 'stdio');
      expect(configs.single.command, 'npx');
      expect(configs.single.args, <String>['-y', 'pkg']);
      expect(configs.single.enabled, isTrue);
      expect(parseMcpServersEnv('not-json'), isEmpty);
      expect(parseMcpServersEnv(''), isEmpty);
    });

    test('Windows 路径 / 空格 / 多行经 YAML 往返不丢（写盘后重读）', () async {
      final McpConfigStore store = McpConfigStore();
      store.bindDataDir(temp.path);
      await store.upsert(
        McpServerConfig(
          name: 'win',
          command: r'C:\Program Files\node.exe',
          args: <String>[r'C:\tmp', r'--flag=a b'],
          env: <String, String>{'API_KEY': 'a b\nc'},
          scope: 'local',
        ),
      );
      final McpConfigStore reloaded = McpConfigStore();
      reloaded.bindDataDir(temp.path);
      final McpServerConfig? got = reloaded.server('win');
      expect(got, isNotNull);
      expect(got!.command, r'C:\Program Files\node.exe');
      expect(got.args, <String>[r'C:\tmp', r'--flag=a b']);
      expect(got.env['API_KEY'], 'a b\nc');
      expect(got.scope, 'local');
      expect(got.transport, 'stdio');
    });

    test('同名时文件配置优先；TREE_MCP_SERVERS 注入项不可删除', () async {
      final File file = File(p.join(temp.path, 'config', 'mcp.yaml'));
      file.createSync(recursive: true);
      file.writeAsStringSync('''
servers:
  - name: files
    command: npx
    enabled: false
''');
      final McpService service = McpService();
      addTearDown(service.close);
      service.loadEnvServers(
        jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{'name': 'files', 'command': 'from-env'},
          <String, dynamic>{'name': 'envonly', 'command': 'from-env'},
        ]),
      );
      await service.attach(temp.path);

      expect(service.servers().map((McpServerConfig c) => c.name), <String>[
        'files',
        'envonly',
      ]);
      expect(service.servers().first.command, 'npx', reason: '文件同名优先');

      final Map<String, dynamic> removed = await service.remove('envonly');
      expect(removed['error'], contains('TREE_MCP_SERVERS'));
      expect(service.server('envonly'), isNotNull, reason: '环境注入项删不掉');
    });
  });

  group('api/delegate', () {
    late Directory temp;
    late McpService service;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('mcp_delegate_');
      service = McpService();
    });

    tearDown(() async {
      await service.close();
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<Map<String, dynamic>> fire(
      String method,
      String path, {
      Map<String, Object?> params = const <String, Object?>{},
      Map<String, Object?> body = const <String, Object?>{},
      String? dataDir,
    }) => handleApiDelegate(<String, dynamic>{
      'method': method,
      'path': path,
      'params': params,
      'query': <String, dynamic>{},
      'headers': <String, dynamic>{},
      'scope': <String, dynamic>{},
      'workspace_dir': '',
      'data_dir': dataDir ?? temp.path,
      'agent_id': '',
      'team_id': '',
      'request_id': 'test-${method.toLowerCase()}',
      if (body.isNotEmpty) 'body': jsonEncode(body),
    }, service: service);

    Map<String, dynamic> bodyOf(Map<String, dynamic> reply) {
      final Object? raw = reply['body'];
      if (raw is! String || raw.isEmpty) return <String, dynamic>{};
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    }

    test(
      'GET → POST → GET → DELETE → GET 全链路形状（enabled=false，不拉子进程）',
      () async {
        final Map<String, dynamic> before = await fire(
          'GET',
          mcpServicesPattern,
        );
        expect(before['status'], 200);
        expect(bodyOf(before)['services'], isEmpty);
        expect(bodyOf(before)['tools'], isEmpty);
        expect(bodyOf(before)['errors'], <String, dynamic>{});

        final Map<String, dynamic> registered = await fire(
          'POST',
          mcpServicesPattern,
          body: <String, Object?>{
            'name': 'demo',
            'transport': 'stdio',
            'command': 'noop',
            'args': <String>['--x'],
            'env': <String, String>{'K': 'V'},
            'scope': 'local',
            'enabled': false,
          },
        );
        expect(registered['status'], 200);
        final Map<String, dynamic> postBody = bodyOf(registered);
        expect(postBody['success'], isTrue);
        final Map<String, dynamic> entry = (postBody['service'] as Map)
            .cast<String, dynamic>();
        expect(entry['name'], 'demo');
        expect(entry['transport'], 'stdio');
        expect(entry['command'], 'noop');
        expect(entry['args'], <String>['--x']);
        expect(entry['scope'], 'local');
        expect(entry['enabled'], isFalse);
        expect(postBody['tools'], isEmpty, reason: 'enabled=false 不连接');
        expect(postBody.containsKey('error_detail'), isFalse);

        final File configFile = File(p.join(temp.path, 'config', 'mcp.yaml'));
        expect(configFile.existsSync(), isTrue);
        final String yaml = configFile.readAsStringSync();
        expect(yaml, contains('demo'));
        expect(yaml, contains('transport: stdio'));
        expect(yaml, contains('/api/mcp/services'));

        final Map<String, dynamic> listed = await fire(
          'GET',
          mcpServicesPattern,
        );
        expect(listed['status'], 200);
        final Map<String, dynamic> listedBody = bodyOf(listed);
        expect(listedBody['services'], hasLength(1));
        expect(((listedBody['services'] as List).first as Map)['name'], 'demo');

        final Map<String, dynamic> deleted = await fire(
          'DELETE',
          mcpServicePattern.replaceFirst('{name}', 'demo'),
          params: <String, Object?>{'name': 'demo'},
        );
        expect(deleted['status'], 200);
        expect(bodyOf(deleted)['success'], isTrue);
        expect(bodyOf(deleted)['name'], 'demo');

        final Map<String, dynamic> after = await fire(
          'GET',
          mcpServicesPattern,
        );
        expect(bodyOf(after)['services'], isEmpty);
        expect(
          configFile.existsSync() ? configFile.readAsStringSync() : '',
          isNot(contains('demo')),
        );
      },
    );

    test(
      'POST 校验：缺 command / 非法 name / http 缺 url ⇒ 400 + 可读 detail',
      () async {
        final Map<String, dynamic> noCommand = await fire(
          'POST',
          mcpServicesPattern,
          body: <String, Object?>{'name': 'x'},
        );
        expect(noCommand['status'], 400);
        expect(bodyOf(noCommand)['detail'], '缺少 command');

        final Map<String, dynamic> badName = await fire(
          'POST',
          mcpServicesPattern,
          body: <String, Object?>{'name': 'bad/name', 'command': 'x'},
        );
        expect(badName['status'], 400);
        expect(bodyOf(badName)['detail'], contains('name 只允许'));

        final Map<String, dynamic> badHttp = await fire(
          'POST',
          mcpServicesPattern,
          body: <String, Object?>{
            'name': 'web',
            'transport': 'http',
            'url': '',
          },
        );
        expect(badHttp['status'], 400);
        expect(bodyOf(badHttp)['detail'], contains('合法 url'));
        expect(
          File(p.join(temp.path, 'config', 'mcp.yaml')).existsSync(),
          isFalse,
          reason: '校验失败不落盘',
        );
      },
    );

    test('http 配置可注册/持久化，但连接给出明确限制（error_detail）', () async {
      final Map<String, dynamic> res = await fire(
        'POST',
        mcpServicesPattern,
        body: <String, Object?>{
          'name': 'web',
          'transport': 'http',
          'url': 'https://example.com/mcp',
          'headers': <String, String>{'Authorization': 'Bearer x'},
        },
      );
      expect(res['status'], 200);
      final Map<String, dynamic> body = bodyOf(res);
      expect(body['success'], isTrue);
      expect(
        (body['service'] as Map)['transport'],
        'http',
        reason: 'transport 是既有 UI 需要字段',
      );
      expect(body['error_detail'], contains('HTTP 传输尚未在 mcp 插件内实现'));
      expect(
        File(p.join(temp.path, 'config', 'mcp.yaml')).readAsStringSync(),
        contains('transport: http'),
      );
    });

    test('DELETE：不存在 404；内置 404；缺 data_dir 500；未知路由 501', () async {
      final Map<String, dynamic> missing = await fire(
        'DELETE',
        mcpServicePattern.replaceFirst('{name}', 'ghost'),
        params: <String, Object?>{'name': 'ghost'},
      );
      expect(missing['status'], 404);
      expect(bodyOf(missing)['detail'], 'MCP 服务不存在: ghost');

      final File configFile = File(p.join(temp.path, 'config', 'mcp.yaml'));
      configFile.createSync(recursive: true);
      configFile.writeAsStringSync('''
servers:
  - name: builtin_one
    command: npx
    builtin: true
    enabled: false
''');
      await service.attach('');

      final Map<String, dynamic> builtin = await fire(
        'DELETE',
        mcpServicePattern.replaceFirst('{name}', 'builtin_one'),
        params: <String, Object?>{'name': 'builtin_one'},
      );
      expect(builtin['status'], 404);
      expect(bodyOf(builtin)['detail'], contains('内置 MCP 服务不可删除'));

      final Map<String, dynamic> noDataDir = await fire(
        'GET',
        mcpServicesPattern,
        dataDir: '',
      );
      expect(noDataDir['status'], 500);
      expect(bodyOf(noDataDir)['detail'], contains('data_dir'));

      final Map<String, dynamic> unknown = await fire(
        'GET',
        '/api/mcp/unknown',
      );
      expect(unknown['status'], 501);
      expect(bodyOf(unknown)['detail'], contains('尚未实现'));
    });
  });

  group('stdio 真子进程', () {
    test('注册后 GET 列出工具（mcp__<服务>__<工具>），DELETE 断开并移除', () async {
      final Directory temp = Directory.systemTemp.createTempSync('mcp_stdio_');
      final McpService service = McpService();
      final String script = p.join(
        Directory.current.path,
        'test',
        'fixtures',
        'fake_full_mcp_server.dart',
      );
      try {
        Future<Map<String, dynamic>> fire(
          String method,
          String path, {
          Map<String, Object?> params = const <String, Object?>{},
          Map<String, Object?> body = const <String, Object?>{},
        }) => handleApiDelegate(<String, dynamic>{
          'method': method,
          'path': path,
          'params': params,
          'query': <String, dynamic>{},
          'headers': <String, dynamic>{},
          'scope': <String, dynamic>{},
          'workspace_dir': '',
          'data_dir': temp.path,
          'agent_id': '',
          'team_id': '',
          'request_id': 'stdio-test',
          if (body.isNotEmpty) 'body': jsonEncode(body),
        }, service: service);

        final Map<String, dynamic> res = await fire(
          'POST',
          mcpServicesPattern,
          body: <String, Object?>{
            'name': 'fake',
            'command': Platform.resolvedExecutable,
            'args': <String>[script],
          },
        );
        expect(res['status'], 200);
        final Map<String, dynamic> registered =
            (jsonDecode(res['body'] as String) as Map).cast<String, dynamic>();
        expect(registered['success'], isTrue);
        expect(registered['tools'], contains('echo'));
        expect(registered.containsKey('error_detail'), isFalse);

        final Map<String, dynamic> listed = await fire(
          'GET',
          mcpServicesPattern,
        );
        final Map<String, dynamic> listedBody = (jsonDecode(
          listed['body'] as String,
        ) as Map).cast<String, dynamic>();
        final List<dynamic> tools = listedBody['tools'] as List<dynamic>;
        expect(
          tools.any(
            (dynamic item) =>
                (item as Map)['mcp_name'] == 'mcp__fake__echo' &&
                item['service'] == 'fake',
          ),
          isTrue,
        );
        expect((listedBody['errors'] as Map).containsKey('fake'), isFalse);

        final Map<String, dynamic> deleted = await fire(
          'DELETE',
          mcpServicePattern.replaceFirst('{name}', 'fake'),
          params: <String, Object?>{'name': 'fake'},
        );
        expect(deleted['status'], 200);
        expect(service.isConnected('fake'), isFalse);
        expect(service.server('fake'), isNull);
      } finally {
        await service.close();
        try {
          if (temp.existsSync()) temp.deleteSync(recursive: true);
        } catch (_) {}
      }
    });
  });
}
