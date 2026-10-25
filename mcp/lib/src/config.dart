/// MCP 服务配置模型（与核心 `McpServerConfig` 的持久化 / API 形状逐字对齐）。
///
/// 为什么放在插件自己的领域库里：D 任务把 `/api/mcp/services` 三条路由连同
/// 「配置落盘 + 连接缓存」一起搬到 mcp 插件；插件不能再 import 核心包，
/// 因此这里保留核心旧实现的**字段名与序列化口径**（transport / command /
/// args / env / url / headers / enabled / builtin / scope），让 UI 与手改的
/// `config/mcp.yaml` 都不用变。
library;

import 'dart:convert';

/// stdio 传输（缺省；老配置没有 transport 字段时行为逐字不变）。
const String mcpTransportStdio = 'stdio';

/// Streamable HTTP 单端点传输（本版仅持久化与展示，连接能力见 README「限制」）。
const String mcpTransportHttp = 'http';

/// 一个 MCP 服务配置。
class McpServerConfig {
  McpServerConfig({
    required this.name,
    this.transport = mcpTransportStdio,
    this.command = '',
    List<String>? args,
    Map<String, String>? env,
    this.url = '',
    Map<String, String>? headers,
    this.enabled = true,
    this.builtin = false,
    this.scope = '',
  }) : args = args ?? <String>[],
       env = env ?? <String, String>{},
       headers = headers ?? <String, String>{};

  final String name;

  /// 传输类型：`stdio`（子进程，缺省）或 `http`（Streamable HTTP 单端点）。
  final String transport;

  final String command;
  final List<String> args;
  final Map<String, String> env;

  /// Streamable HTTP 端点（`transport = http` 时必填）。
  final String url;

  /// 自定义请求头（`Authorization` 等；`transport = http` 时用）。
  final Map<String, String> headers;

  final bool enabled;

  /// 是否为内置服务（内置的不可删除，只可禁用）。
  final bool builtin;

  /// 归属范围（前端「按当前会话模式自动落点」用；桌面端只做展示与持久化）。
  final String scope;

  /// 是否走 HTTP 传输（其它取值按 stdio 处理，保持向后兼容）。
  bool get isHttp => transport.trim().toLowerCase() == mcpTransportHttp;

  /// 持久化形状（`config/mcp.yaml` 的 `servers[]` 条目）。
  ///
  /// 空字段不写：手改出来文件才和核心旧实现落盘的内容一致。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'transport': transport,
    if (command.isNotEmpty) 'command': command,
    if (args.isNotEmpty) 'args': args,
    if (env.isNotEmpty) 'env': env,
    if (url.isNotEmpty) 'url': url,
    if (headers.isNotEmpty) 'headers': headers,
    'enabled': enabled,
    'builtin': builtin,
    'scope': scope,
  };

  /// 前端形态（`GET /api/mcp/services`）。
  ///
  /// 字段**恒定出现**（stdio 下 `url` / `headers` 为空），前端不必判 null——
  /// 这是核心旧实现的承诺，UI 面板按它读取。
  Map<String, dynamic> toApiJson() => <String, dynamic>{
    'name': name,
    'transport': transport,
    'command': command,
    'args': args,
    'url': url,
    'headers': headers,
    'builtin': builtin,
    'enabled': enabled,
    'scope': scope,
  };

  static McpServerConfig fromJson(Map<String, dynamic> json) => McpServerConfig(
    name: (json['name'] ?? '').toString(),
    transport: (json['transport'] ?? mcpTransportStdio).toString(),
    command: (json['command'] ?? '').toString(),
    args: _stringList(json['args']),
    env: _stringMap(json['env']),
    url: (json['url'] ?? '').toString(),
    headers: _stringMap(json['headers']),
    enabled: json['enabled'] != false,
    builtin: json['builtin'] == true,
    scope: (json['scope'] ?? '').toString(),
  );

  McpServerConfig copyWith({bool? enabled}) => McpServerConfig(
    name: name,
    transport: transport,
    command: command,
    args: args,
    env: env,
    url: url,
    headers: headers,
    enabled: enabled ?? this.enabled,
    builtin: builtin,
    scope: scope,
  );
}

/// 注册请求的校验结果：成功带配置，失败带**可直接回给前端的中文原因**。
class McpServerConfigParse {
  const McpServerConfigParse.ok(McpServerConfig this.config) : error = null;
  const McpServerConfigParse.failed(String this.error) : config = null;

  final McpServerConfig? config;
  final String? error;
}

/// 把 `POST /api/mcp/services` 的 body 校验成配置（与核心旧实现同一套规则）。
///
/// [existing] 用于保留 `builtin` 标记：覆盖注册一个内置项时不能把它洗成可删。
McpServerConfigParse parseMcpServerConfig(
  Map<String, dynamic> body, {
  McpServerConfig? existing,
}) {
  final String name = (body['name'] ?? '').toString().trim();
  if (name.isEmpty) {
    return const McpServerConfigParse.failed('缺少 name');
  }
  if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(name)) {
    return const McpServerConfigParse.failed('name 只允许 [A-Za-z0-9_.-]（避免配置注入）');
  }
  final String transport = (body['transport'] ?? mcpTransportStdio)
      .toString()
      .trim()
      .toLowerCase();
  if (transport != mcpTransportStdio && transport != mcpTransportHttp) {
    return McpServerConfigParse.failed(
      'transport 只支持 $mcpTransportStdio / $mcpTransportHttp（收到：$transport）',
    );
  }
  final String command = (body['command'] ?? '').toString().trim();
  final String url = (body['url'] ?? '').toString().trim();
  if (transport == mcpTransportStdio && command.isEmpty) {
    return const McpServerConfigParse.failed('缺少 command');
  }
  if (transport == mcpTransportHttp) {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null ||
        !(uri.isScheme('http') || uri.isScheme('https')) ||
        uri.host.isEmpty) {
      return McpServerConfigParse.failed(
        'transport=http 需要合法 url（http/https 绝对地址，收到：${url.isEmpty ? '空' : url}）',
      );
    }
  }
  return McpServerConfigParse.ok(
    McpServerConfig(
      name: name,
      transport: transport,
      command: command,
      args: _stringList(body['args']),
      env: _stringMap(body['env']),
      url: url,
      headers: _stringMap(body['headers']),
      enabled: body['enabled'] != false,
      builtin: existing?.builtin ?? (body['builtin'] == true),
      scope: (body['scope'] ?? '').toString(),
    ),
  );
}

/// `TREE_MCP_SERVERS`（JSON 数组）→ 配置列表。
///
/// 保持旧插件兼容：每项至少 `{"name","command","args"}`；新增的可选字段
/// （transport / env / url / headers / enabled / scope）原样接受。坏项跳过，
/// 一个写坏的服务不该让整组环境变量全部失效。
List<McpServerConfig> parseMcpServersEnv(
  String raw, {
  void Function(String message)? log,
}) {
  final String text = raw.trim();
  if (text.isEmpty) return <McpServerConfig>[];
  try {
    final Object? decoded = jsonDecode(text);
    if (decoded is! List) {
      log?.call('TREE_MCP_SERVERS 必须是 JSON 数组（收到 ${decoded.runtimeType}）');
      return <McpServerConfig>[];
    }
    final List<McpServerConfig> out = <McpServerConfig>[];
    for (final Object? item in decoded) {
      if (item is! Map) continue;
      final McpServerConfig config = McpServerConfig.fromJson(
        item.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
      );
      if (config.name.trim().isEmpty) continue;
      out.add(config);
    }
    return out;
  } catch (error) {
    log?.call('TREE_MCP_SERVERS 解析失败：$error');
    return <McpServerConfig>[];
  }
}

List<String> _stringList(Object? value) {
  if (value is List) {
    return <String>[for (final Object? item in value) item.toString()];
  }
  if (value is String && value.trim().isNotEmpty) {
    return value.trim().split(RegExp(r'\s+'));
  }
  return <String>[];
}

Map<String, String> _stringMap(Object? value) {
  if (value is Map) {
    return <String, String>{
      for (final MapEntry<dynamic, dynamic> entry in value.entries)
        entry.key.toString(): entry.value.toString(),
    };
  }
  return <String, String>{};
}
