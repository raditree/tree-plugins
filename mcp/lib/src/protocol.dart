import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// MCP 协议版本（客户端声明；服务端可回自己支持的版本）。
const String kMcpProtocolVersion = '2025-06-18';

class McpException implements Exception {
  McpException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 一个 MCP 服务配置（stdio 传输）。
class McpServerConfig {
  const McpServerConfig({
    required this.name,
    required this.command,
    this.args = const <String>[],
    this.env = const <String, String>{},
  });

  final String name;
  final String command;
  final List<String> args;
  final Map<String, String> env;

  factory McpServerConfig.fromJson(Map<String, dynamic> json) => McpServerConfig(
    name: (json['name'] ?? '').toString(),
    command: (json['command'] ?? '').toString(),
    args: <String>[
      for (final Object? arg in (json['args'] as List<dynamic>? ?? const <dynamic>[]))
        arg.toString(),
    ],
    env: <String, String>{
      for (final MapEntry<dynamic, dynamic> entry
          in (json['env'] as Map<dynamic, dynamic>? ?? const <dynamic, dynamic>{}).entries)
        entry.key.toString(): entry.value.toString(),
    },
  );
}

/// 服务端 initialize 声明的能力。
class McpCapabilities {
  const McpCapabilities({
    this.tools = false,
    this.resources = false,
    this.resourceSubscriptions = false,
    this.prompts = false,
    this.logging = false,
  });

  final bool tools;
  final bool resources;
  final bool resourceSubscriptions;
  final bool prompts;
  final bool logging;

  factory McpCapabilities.fromJson(Map<String, dynamic>? json) {
    final Map<String, dynamic> caps = json ?? <String, dynamic>{};
    final Map<String, dynamic> resources =
        (caps['resources'] as Map<dynamic, dynamic>? ?? const <dynamic, dynamic>{})
            .map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
    return McpCapabilities(
      tools: caps['tools'] != null,
      resources: caps['resources'] != null,
      resourceSubscriptions: resources['subscribe'] == true,
      prompts: caps['prompts'] != null,
      logging: caps['logging'] != null,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (tools) 'tools': <String, dynamic>{},
    if (resources)
      'resources': <String, dynamic>{
        if (resourceSubscriptions) 'subscribe': true,
      },
    if (prompts) 'prompts': <String, dynamic>{},
    if (logging) 'logging': <String, dynamic>{},
  };
}

class McpToolInfo {
  const McpToolInfo({
    required this.name,
    this.description = '',
    this.inputSchema = const <String, dynamic>{},
  });
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  factory McpToolInfo.fromJson(Map<String, dynamic> json) => McpToolInfo(
    name: (json['name'] ?? '').toString(),
    description: (json['description'] ?? '').toString(),
    inputSchema: (json['inputSchema'] as Map<dynamic, dynamic>? ??
            const <dynamic, dynamic>{})
        .map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
  );
}

class McpResourceInfo {
  const McpResourceInfo({
    required this.uri,
    this.name = '',
    this.description = '',
    this.mimeType = '',
  });
  final String uri;
  final String name;
  final String description;
  final String mimeType;
  factory McpResourceInfo.fromJson(Map<String, dynamic> json) => McpResourceInfo(
    uri: (json['uri'] ?? '').toString(),
    name: (json['name'] ?? '').toString(),
    description: (json['description'] ?? '').toString(),
    mimeType: (json['mimeType'] ?? '').toString(),
  );
}

class McpResourceTemplate {
  const McpResourceTemplate({
    required this.uriTemplate,
    this.name = '',
    this.description = '',
    this.mimeType = '',
  });
  final String uriTemplate;
  final String name;
  final String description;
  final String mimeType;
  factory McpResourceTemplate.fromJson(Map<String, dynamic> json) =>
      McpResourceTemplate(
        uriTemplate: (json['uriTemplate'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        description: (json['description'] ?? '').toString(),
        mimeType: (json['mimeType'] ?? '').toString(),
      );
}

class McpPromptInfo {
  const McpPromptInfo({
    required this.name,
    this.description = '',
    this.arguments = const <Map<String, dynamic>>[],
  });
  final String name;
  final String description;
  final List<Map<String, dynamic>> arguments;
  factory McpPromptInfo.fromJson(Map<String, dynamic> json) => McpPromptInfo(
    name: (json['name'] ?? '').toString(),
    description: (json['description'] ?? '').toString(),
    arguments: <Map<String, dynamic>>[
      for (final Object? arg in (json['arguments'] as List<dynamic>? ?? const <dynamic>[]))
        if (arg is Map)
          arg.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
    ],
  );
}

class McpRoot {
  const McpRoot({required this.uri, this.name = ''});
  final String uri;
  final String name;
  Map<String, dynamic> toJson() => <String, dynamic>{'uri': uri, 'name': name};
}

/// 一次 tools/call 的结果（content 拼成模型可读文本）。
class McpCallResult {
  const McpCallResult({required this.text, this.isError = false, this.raw = const <String, dynamic>{}});
  final String text;
  final bool isError;
  final Map<String, dynamic> raw;
}

/// 一次 resources/read 的结果。
class McpReadResult {
  const McpReadResult(this.contents);
  final List<Map<String, dynamic>> contents;
  String get text => <String>[
    for (final Map<String, dynamic> item in contents)
      (item['text'] ?? item['blob'] ?? '').toString(),
  ].where((String value) => value.isNotEmpty).join('\n');
}

/// 一次 prompts/get 的结果。
class McpPromptResult {
  const McpPromptResult({this.description = '', this.messages = const <Map<String, dynamic>>[]});
  final String description;
  final List<Map<String, dynamic>> messages;
  String get text => <String>[
    if (description.isNotEmpty) description,
    for (final Map<String, dynamic> message in messages)
      '[${message['role'] ?? 'user'}] ${_contentText(message['content'])}',
  ].join('\n');
}

String _contentText(Object? content) {
  if (content is String) return content;
  if (content is Map) {
    return (content['text'] ?? content['data'] ?? jsonEncode(content)).toString();
  }
  return content?.toString() ?? '';
}

/// MCP stdio 客户端：JSON-RPC 2.0、逐行传输。
///
/// 覆盖 initialize / initialized、tools/resources/prompts 自发现（分页）、
/// list_changed、resources/read、prompts/get、roots/list 与关闭。
class McpProtocolClient {
  McpProtocolClient._(this.config, this._process) {
    _stdoutSub = _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine);
    _stderrSub = _process.stderr.transform(utf8.decoder).listen((String chunk) {
      _stderr.write(chunk);
      if (_stderr.length > 8192) {
        final String all = _stderr.toString();
        _stderr
          ..clear()
          ..write(all.substring(all.length - 8192));
      }
    });
  }

  final McpServerConfig config;
  final Process? _process;
  late final StreamSubscription<String> _stdoutSub;
  late final StreamSubscription<String> _stderrSub;
  final StringBuffer _stderr = StringBuffer();
  final Map<int, Completer<Map<String, dynamic>>> _pending =
      <int, Completer<Map<String, dynamic>>>{};
  int _nextId = 0;
  bool _closed = false;

  Map<String, dynamic> serverInfo = <String, dynamic>{};
  String protocolVersion = '';
  McpCapabilities capabilities = const McpCapabilities();
  final List<McpToolInfo> tools = <McpToolInfo>[];
  final List<McpResourceInfo> resources = <McpResourceInfo>[];
  final List<McpResourceTemplate> resourceTemplates = <McpResourceTemplate>[];
  final List<McpPromptInfo> prompts = <McpPromptInfo>[];
  List<McpRoot> roots = const <McpRoot>[];
  void Function()? onChanged;
  final List<String> logMessages = <String>[];

  /// 启动服务、握手并完成首轮自发现。
  static Future<McpProtocolClient> connect(McpServerConfig config) async {
    if (config.command.trim().isEmpty) {
      throw McpException('MCP 服务 ${config.name} 未配置 command');
    }
    final Process process;
    try {
      process = await Process.start(
        config.command,
        config.args,
        environment: config.env.isEmpty ? null : config.env,
        runInShell: Platform.isWindows,
      );
    } catch (error) {
      throw McpException('启动 MCP 服务 ${config.name} 失败：$error');
    }
    final McpProtocolClient client = McpProtocolClient._(config, process);
    await client._initialize();
    return client;
  }

  bool get isClosed => _closed;
  String get stderrTail => _stderr.toString();

  Future<void> _initialize() async {
    final Map<String, dynamic> result = await request(
      'initialize',
      <String, dynamic>{
        'protocolVersion': kMcpProtocolVersion,
        'capabilities': <String, dynamic>{
          'roots': <String, dynamic>{'listChanged': true},
        },
        'clientInfo': <String, dynamic>{'name': 'tree-mcp', 'version': '0.1.0'},
      },
    );
    serverInfo = (result['serverInfo'] as Map<dynamic, dynamic>? ??
            const <dynamic, dynamic>{})
        .map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
    protocolVersion = (result['protocolVersion'] ?? '').toString();
    capabilities = McpCapabilities.fromJson(
      (result['capabilities'] as Map<dynamic, dynamic>? ?? const <dynamic, dynamic>{})
          .map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
    );
    notify('notifications/initialized', <String, dynamic>{});
    await refreshAll();
  }

  /// 拉取三类能力清单（服务端声明了才拉；分页一次拉全）。
  Future<void> refreshAll() async {
    if (capabilities.tools) {
      final List<McpToolInfo> next = <McpToolInfo>[];
      for (final Map<String, dynamic> raw in await _listAll('tools/list', 'tools')) {
        next.add(McpToolInfo.fromJson(raw));
      }
      tools
        ..clear()
        ..addAll(next);
    }
    if (capabilities.resources) {
      final List<McpResourceInfo> nextResources = <McpResourceInfo>[];
      for (final Map<String, dynamic> raw
          in await _listAll('resources/list', 'resources')) {
        nextResources.add(McpResourceInfo.fromJson(raw));
      }
      resources
        ..clear()
        ..addAll(nextResources);
      try {
        final List<McpResourceTemplate> nextTemplates = <McpResourceTemplate>[];
        for (final Map<String, dynamic> raw
            in await _listAll('resources/templates/list', 'resourceTemplates')) {
          nextTemplates.add(McpResourceTemplate.fromJson(raw));
        }
        resourceTemplates
          ..clear()
          ..addAll(nextTemplates);
      } on McpException {
        // 老服务端可能没有 templates/list：保留已有清单，不阻断握手。
      }
    }
    if (capabilities.prompts) {
      final List<McpPromptInfo> nextPrompts = <McpPromptInfo>[];
      for (final Map<String, dynamic> raw in await _listAll('prompts/list', 'prompts')) {
        nextPrompts.add(McpPromptInfo.fromJson(raw));
      }
      prompts
        ..clear()
        ..addAll(nextPrompts);
    }
    onChanged?.call();
  }

  Future<List<Map<String, dynamic>>> _listAll(
    String method,
    String key,
  ) async {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    String cursor = '';
    for (int page = 0; page < 32; page++) {
      final Map<String, dynamic> result = await request(
        method,
        <String, dynamic>{if (cursor.isNotEmpty) 'cursor': cursor},
      );
      final Object? items = result[key];
      if (items is List) {
        for (final Object? item in items) {
          if (item is Map) {
            out.add(item.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)));
          }
        }
      }
      cursor = (result['nextCursor'] ?? '').toString();
      if (cursor.isEmpty) break;
    }
    return out;
  }

  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> params, {
    Duration? timeout,
  }) {
    if (_closed) {
      return Future<Map<String, dynamic>>.error(
        McpException('MCP 服务 ${config.name} 已关闭'),
      );
    }
    final int id = ++_nextId;
    final Completer<Map<String, dynamic>> completer =
        Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _write(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    final Future<Map<String, dynamic>> future = completer.future;
    return timeout == null ? future : future.timeout(timeout);
  }

  void notify(String method, Map<String, dynamic> params) {
    if (_closed) return;
    _write(<String, dynamic>{
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    });
  }

  void _write(Map<String, dynamic> message) {
    try {
      _process?.stdin.writeln(jsonEncode(message));
    } catch (error) {
      _failPending('MCP 服务 ${config.name} 写入失败：$error');
    }
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    Map<String, dynamic> message;
    try {
      message = (jsonDecode(line) as Map<dynamic, dynamic>)
          .map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
    } catch (_) {
      return;
    }
    final Object? id = message['id'];
    final String method = (message['method'] ?? '').toString();
    if (method.isNotEmpty) {
      if (id != null) {
        _handleServerRequest(id, method, message['params']);
      } else {
        _handleNotification(method);
      }
      return;
    }
    if (id is int) {
      final Completer<Map<String, dynamic>>? pending = _pending.remove(id);
      if (pending == null || pending.isCompleted) return;
      final Object? error = message['error'];
      if (error is Map) {
        pending.completeError(
          McpException('MCP $method 失败：${error['message'] ?? ''}'),
        );
      } else {
        pending.complete(
          (message['result'] as Map<dynamic, dynamic>? ?? const <dynamic, dynamic>{})
              .map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
        );
      }
    }
  }

  void _handleNotification(String method) {
    switch (method) {
      case 'notifications/tools/list_changed':
        unawaited(_refreshTools());
      case 'notifications/resources/list_changed':
        unawaited(_refreshResources());
      case 'notifications/prompts/list_changed':
        unawaited(_refreshPrompts());
      case 'notifications/message':
        // logging 通知只入队，供上下文/诊断读取。
      default:
        break;
    }
  }

  Future<void> _refreshTools() async {
    if (!capabilities.tools) return;
    final List<McpToolInfo> next = <McpToolInfo>[];
    for (final Map<String, dynamic> raw in await _listAll('tools/list', 'tools')) {
      next.add(McpToolInfo.fromJson(raw));
    }
    tools
      ..clear()
      ..addAll(next);
    onChanged?.call();
  }

  Future<void> _refreshResources() async {
    if (!capabilities.resources) return;
    final List<McpResourceInfo> next = <McpResourceInfo>[];
    for (final Map<String, dynamic> raw in await _listAll('resources/list', 'resources')) {
      next.add(McpResourceInfo.fromJson(raw));
    }
    resources
      ..clear()
      ..addAll(next);
    onChanged?.call();
  }

  Future<void> _refreshPrompts() async {
    if (!capabilities.prompts) return;
    final List<McpPromptInfo> next = <McpPromptInfo>[];
    for (final Map<String, dynamic> raw in await _listAll('prompts/list', 'prompts')) {
      next.add(McpPromptInfo.fromJson(raw));
    }
    prompts
      ..clear()
      ..addAll(next);
    onChanged?.call();
  }

  void _handleServerRequest(Object id, String method, Object? _) {
    switch (method) {
      case 'roots/list':
        _write(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'result': <String, dynamic>{
            'roots': <Map<String, dynamic>>[
              for (final McpRoot root in roots) root.toJson(),
            ],
          },
        });
      case 'ping':
        _write(<String, dynamic>{'jsonrpc': '2.0', 'id': id, 'result': <String, dynamic>{}});
      default:
        _write(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'error': <String, dynamic>{
            'code': -32601,
            'message': '客户端不支持 $method',
          },
        });
    }
  }

  void setRoots(List<McpRoot> next) {
    roots = List<McpRoot>.unmodifiable(next);
    notify('notifications/roots/list_changed', <String, dynamic>{});
  }

  Future<McpCallResult> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final Map<String, dynamic> result = await request('tools/call', <String, dynamic>{
      'name': name,
      'arguments': arguments,
    });
    final Object? content = result['content'];
    final List<String> parts = <String>[];
    if (content is List) {
      for (final Object? item in content) {
        if (item is Map) {
          parts.add((item['text'] ?? item['data'] ?? jsonEncode(item)).toString());
        } else if (item != null) {
          parts.add(item.toString());
        }
      }
    } else if (result['content'] != null) {
      parts.add(result['content'].toString());
    }
    return McpCallResult(
      text: parts.join('\n'),
      isError: result['isError'] == true,
      raw: result,
    );
  }

  Future<McpReadResult> readResource(String uri) async {
    final Map<String, dynamic> result = await request(
      'resources/read',
      <String, dynamic>{'uri': uri},
    );
    final List<Map<String, dynamic>> contents = <Map<String, dynamic>>[
      for (final Object? item in (result['contents'] as List<dynamic>? ?? const <dynamic>[]))
        if (item is Map)
          item.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
    ];
    return McpReadResult(contents);
  }

  Future<McpPromptResult> getPrompt(
    String name, [
    Map<String, dynamic> arguments = const <String, dynamic>{},
  ]) async {
    final Map<String, dynamic> result = await request('prompts/get', <String, dynamic>{
      'name': name,
      'arguments': arguments,
    });
    return McpPromptResult(
      description: (result['description'] ?? '').toString(),
      messages: <Map<String, dynamic>>[
        for (final Object? item in (result['messages'] as List<dynamic>? ?? const <dynamic>[]))
          if (item is Map)
            item.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
      ],
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _failPending('MCP 服务 ${config.name} 已关闭');
    try {
      await _process?.stdin.close();
    } catch (_) {}
    await _stdoutSub.cancel();
    await _stderrSub.cancel();
    _process?.kill();
  }

  void _failPending(String reason) {
    for (final Completer<Map<String, dynamic>> pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(McpException(reason));
    }
    _pending.clear();
  }
}