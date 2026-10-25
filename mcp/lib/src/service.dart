import 'dart:async';

import 'config.dart';
import 'config_store.dart';
import 'protocol.dart';
import 'tool_surface.dart';

/// 插件内的 **MCP 服务管理器**（从核心 `McpService` 的语义平移，去掉核心依赖）。
///
/// 职责：配置（文件 + 环境变量）→ 连接缓存 → 工具聚合 → 注册/删除。
/// 传输由 [McpProtocolClient] 承担（stdio）；HTTP 配置本版只持久化/展示，
/// 连接时以可读错误留痕（见 README「限制」）。
///
/// 连接策略与核心旧实现一致：启动 / 首次委派时全量补齐；注册时只连它自己；
/// 连接失败按 [connectRetryDelay] 退避，避免死服务在每次 GET 时被反复拉起。
class McpService {
  McpService({McpConfigStore? store, this.connector, this.log})
    : store = store ?? McpConfigStore(log: log);

  final McpConfigStore store;

  /// 连接工厂（测试可注入；生产走 [McpProtocolClient.connect]）。
  final Future<McpProtocolClient> Function(McpServerConfig config)? connector;

  final void Function(String message)? log;

  /// 已连接的客户端（工具贡献 / 上下文工具直接读它）。
  final Map<String, McpProtocolClient> clients = <String, McpProtocolClient>{};

  /// 各服务最近一次连接 / 调用的可读错误（UI 的 `errors` 字段与工具报错共用）。
  final Map<String, String> errors = <String, String>{};

  final Map<String, Future<McpProtocolClient?>> _connecting =
      <String, Future<McpProtocolClient?>>{};
  final Map<String, DateTime> _lastAttemptAt = <String, DateTime>{};

  /// 连接失败后的重试退避窗口（注册/显式改动不受限，失败才产生）。
  static const Duration connectRetryDelay = Duration(seconds: 30);

  /// HTTP 传输的限制文案（集中一处，README、GET errors、工具报错同源）。
  static const String httpUnsupported =
      'Streamable HTTP 传输尚未在 mcp 插件内实现（配置已保存；请改用 stdio）';

  /// 全部服务（文件 + TREE_MCP_SERVERS 合并）。
  List<McpServerConfig> servers() => store.servers;

  /// 按名称取配置（文件优先；不存在返回 null）。
  McpServerConfig? server(String name) => store.server(name);

  /// 读取并替换 `TREE_MCP_SERVERS`（JSON 数组；不落盘）。
  void loadEnvServers(String raw) {
    store.setEnvServers(parseMcpServersEnv(raw, log: log));
  }

  /// 绑定数据根；数据根变化时断开旧连接，避免把 A 数据根的服务接到 B 上。
  Future<void> attach(String dataDir) async {
    final bool changed = store.bindDataDir(dataDir);
    if (!changed) return;
    for (final String name in clients.keys.toList(growable: false)) {
      await _disconnect(name);
    }
    errors.clear();
    _lastAttemptAt.clear();
  }

  /// 让连接缓存与当前配置对齐：删除/禁用即断开；启用且未连接的补齐。
  ///
  /// 只做一次全量并发尝试；失败项进 [errors]，后续 GET 由退避窗口拦住。
  Future<void> syncConnections() async {
    final List<McpServerConfig> configs = store.servers;
    final Set<String> names = <String>{
      for (final McpServerConfig config in configs) config.name,
    };
    for (final String name in clients.keys.toList(growable: false)) {
      if (!names.contains(name)) await _disconnect(name);
    }
    for (final String name in errors.keys.toList(growable: false)) {
      if (!names.contains(name)) errors.remove(name);
    }
    // 手改配置把 enabled 改成 false 时，运行中的连接也要断开（与核心旧实现同口径）。
    for (final McpServerConfig config in configs) {
      if (config.enabled) continue;
      await _disconnect(config.name);
      errors.remove(config.name);
    }
    await Future.wait(<Future<void>>[
      for (final McpServerConfig config in configs)
        if (config.enabled) ensureConnected(config.name).then((_) {}),
    ]);
  }

  /// 懒连接**只连这一家**（已连直接返回；同名并发去重；失败带退避）。
  Future<McpProtocolClient?> ensureConnected(String name) async {
    final McpServerConfig? config = store.server(name);
    if (config == null) return null;
    if (!config.enabled) return null;
    if (config.isHttp) {
      errors[name] = httpUnsupported;
      return null;
    }
    if (config.command.trim().isEmpty) {
      errors[name] = 'MCP 服务 $name 未配置 command';
      return null;
    }
    final McpProtocolClient? existing = clients[name];
    if (existing != null && !existing.isClosed) return existing;
    final Future<McpProtocolClient?>? inFlight = _connecting[name];
    if (inFlight != null) return inFlight;
    final DateTime? last = _lastAttemptAt[name];
    if (last != null && DateTime.now().difference(last) < connectRetryDelay) {
      log?.call(
        'MCP 服务 $name 在重试退避窗口内'
        '（${connectRetryDelay.inSeconds}s），跳过本次连接尝试',
      );
      return null;
    }
    final Future<McpProtocolClient?> task = _connect(config);
    _connecting[name] = task;
    try {
      return await task;
    } finally {
      _connecting.remove(name);
    }
  }

  Future<McpProtocolClient?> _connect(McpServerConfig config) async {
    try {
      final McpProtocolClient client =
          await (connector ?? McpProtocolClient.connect)(config);
      clients[config.name] = client;
      errors.remove(config.name);
      _lastAttemptAt.remove(config.name);
      log?.call('MCP 服务 ${config.name} 就绪（${client.tools.length} 个工具）');
      return client;
    } catch (error) {
      errors[config.name] = '$error';
      _lastAttemptAt[config.name] = DateTime.now();
      log?.call('MCP 服务 ${config.name} 不可用：$error');
      await _disconnect(config.name);
      return null;
    }
  }

  /// 注册（或覆盖）一个服务；返回 `{success, service, tools}` 或 `{error}`。
  ///
  /// 与核心旧实现一致：注册立即落盘、只连它自己；连接失败不回滚注册，
  /// 而是把原因放进 `error_detail`（注册成功 ≠ 服务当前可用）。
  Future<Map<String, dynamic>> register(Map<String, dynamic> body) async {
    final String name = (body['name'] ?? '').toString().trim();
    final McpServerConfigParse parsed = parseMcpServerConfig(
      body,
      existing: name.isEmpty ? null : store.server(name),
    );
    final String? error = parsed.error;
    if (error != null) return <String, dynamic>{'error': error};
    final McpServerConfig config = parsed.config!;
    await store.upsert(config);
    await _disconnect(config.name);
    errors.remove(config.name);
    _lastAttemptAt.remove(config.name);
    if (config.enabled) await ensureConnected(config.name);
    final McpProtocolClient? client = clients[config.name];
    return <String, dynamic>{
      'success': true,
      'service': config.toApiJson(),
      'tools': <String>[
        for (final McpToolInfo tool in client?.tools ?? const <McpToolInfo>[])
          tool.name,
      ],
      if (errors[config.name] != null) 'error_detail': errors[config.name],
    };
  }

  /// 删除一个服务；内置服务、TREE_MCP_SERVERS 注入项拒绝删除（可读原因）。
  Future<Map<String, dynamic>> remove(String name) async {
    final McpServerConfig? config = store.server(name);
    if (config == null) {
      return <String, dynamic>{'error': 'MCP 服务不存在: $name'};
    }
    if (config.builtin) {
      return <String, dynamic>{'error': '内置 MCP 服务不可删除（可改为 enabled: false）'};
    }
    if (store.isEnvOnly(name)) {
      return <String, dynamic>{
        'error': '服务 $name 由 TREE_MCP_SERVERS 提供，不能通过接口删除（请改环境变量）',
      };
    }
    if (!await store.removeFileServer(name)) {
      return <String, dynamic>{'error': 'MCP 服务不存在: $name'};
    }
    await _disconnect(name);
    errors.remove(name);
    _lastAttemptAt.remove(name);
    return <String, dynamic>{'success': true, 'name': name};
  }

  /// `GET /api/mcp/services` 的响应体（形状与核心旧实现逐字一致）。
  Map<String, dynamic> listPayload() {
    final List<Map<String, dynamic>> tools = <Map<String, dynamic>>[];
    for (final McpServerConfig config in store.servers) {
      if (!config.enabled) continue;
      final McpProtocolClient? client = clients[config.name];
      if (client == null) continue;
      for (final McpToolInfo tool in client.tools) {
        tools.add(<String, dynamic>{
          'service': config.name,
          'name': tool.name,
          'mcp_name': mcpNamespacedToolName(config.name, tool.name),
          'description': tool.description,
        });
      }
    }
    return <String, dynamic>{
      'services': <Map<String, dynamic>>[
        for (final McpServerConfig config in store.servers) config.toApiJson(),
      ],
      'tools': tools,
      'errors': <String, String>{...errors},
    };
  }

  /// 某服务最近一次错误（无则 null）。
  String? errorOf(String name) => errors[name];

  /// 是否已连接（关闭视为未连接）。
  bool isConnected(String name) {
    final McpProtocolClient? client = clients[name];
    return client != null && !client.isClosed;
  }

  /// 关闭全部连接（幂等）。
  Future<void> close() async {
    for (final String name in clients.keys.toList(growable: false)) {
      await _disconnect(name);
    }
  }

  Future<void> _disconnect(String name) async {
    final McpProtocolClient? client = clients.remove(name);
    if (client == null) return;
    try {
      await client.close();
    } catch (error) {
      log?.call('关闭 MCP 服务 $name 失败：$error');
    }
  }
}
