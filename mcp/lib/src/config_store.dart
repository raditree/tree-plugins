import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'yaml_codec.dart';

/// 配置文件位置：`<数据根>/config/mcp.yaml`（与核心旧实现同一路径）。
///
/// **为什么沿用核心路径**：用户/运维已经有一份手改的 mcp.yaml；插件接手
/// 三条 REST 后若换路径，UI 面板能列出来但用户手改的那份会被静默忽略。
String mcpConfigPathIn(String dataDir) => p.join(dataDir, 'config', 'mcp.yaml');

/// MCP 服务配置的读 / 写 / 合并（文件 + TREE_MCP_SERVERS）。
///
/// 数据根由委派信封的 `data_dir` 给出（插件不自行推导）；启动时若环境里有
/// `TREE_DATA_ROOT` 则先绑定一次，让首轮工具表也能拿到文件配置。
///
/// **两类来源的优先级**：
/// - `config/mcp.yaml`（可写、用户可手改）排在前面；
/// - `TREE_MCP_SERVERS`（部署方注入，只读）追加在后面；同名时文件配置胜出，
///   因此"先环境变量、后迁移到文件"不会出现双份服务。
class McpConfigStore {
  McpConfigStore({this.log});

  final void Function(String message)? log;

  static const String _header =
      'MCP 服务配置（mcp 插件维护；可直接手改）。\n'
      'transport: stdio（缺省，用 command/args/env 起本机子进程）或 http\n'
      '（Streamable HTTP 单端点，用 url + headers；本版 http 只持久化，不连接）。\n'
      'REST：GET/POST /api/mcp/services、DELETE /api/mcp/services/{name}。';

  String _dataDir = '';
  bool _loaded = false;
  final List<McpServerConfig> _fileServers = <McpServerConfig>[];
  final List<McpServerConfig> _envServers = <McpServerConfig>[];

  String get dataDir => _dataDir;
  bool get hasDataDir => _dataDir.isNotEmpty;
  bool get loaded => _loaded;
  String get configFile => _dataDir.isEmpty ? '' : mcpConfigPathIn(_dataDir);

  /// 文件里持久化的服务（按文件顺序）。
  List<McpServerConfig> get fileServers =>
      List<McpServerConfig>.unmodifiable(_fileServers);

  /// `TREE_MCP_SERVERS` 注入的服务（不落盘）。
  List<McpServerConfig> get envServers =>
      List<McpServerConfig>.unmodifiable(_envServers);

  /// 合并后的全部服务：文件在前、环境变量在后，同名文件优先。
  List<McpServerConfig> get servers {
    final Set<String> fileNames = <String>{
      for (final McpServerConfig config in _fileServers) config.name,
    };
    return List<McpServerConfig>.unmodifiable(<McpServerConfig>[
      ..._fileServers,
      for (final McpServerConfig config in _envServers)
        if (!fileNames.contains(config.name)) config,
    ]);
  }

  /// 按名称取配置（文件优先）。
  McpServerConfig? server(String name) {
    for (final McpServerConfig config in _fileServers) {
      if (config.name == name) return config;
    }
    for (final McpServerConfig config in _envServers) {
      if (config.name == name) return config;
    }
    return null;
  }

  /// 该名字是否只来自 TREE_MCP_SERVERS（不可通过 REST 删除）。
  bool isEnvOnly(String name) {
    if (_fileServers.any((McpServerConfig c) => c.name == name)) return false;
    return _envServers.any((McpServerConfig c) => c.name == name);
  }

  /// 绑定数据根（返回是否发生了变化）。变化会清空已加载的文件配置并重读。
  ///
  /// 同一数据根的重复调用是幂等的——UI 每次 GET 都会带 `data_dir`，
  /// 不能因此把连接缓存或用户刚注册的配置冲掉。
  bool bindDataDir(String dir) {
    final String trimmed = dir.trim();
    final String normalized = trimmed.isEmpty
        ? ''
        : p.normalize(Directory(trimmed).absolute.path);
    if (normalized == _dataDir) return false;
    _dataDir = normalized;
    _loaded = false;
    _fileServers.clear();
    load();
    return true;
  }

  /// 替换环境变量来源（不落盘）。
  void setEnvServers(List<McpServerConfig> servers) {
    _envServers
      ..clear()
      ..addAll(servers);
  }

  /// 读文件配置（幂等；未绑定数据根或文件不存在按空配置）。
  void load() {
    if (_loaded) return;
    _loaded = true;
    if (_dataDir.isEmpty) return;
    final String? text = _readStringOrNull(configFile);
    if (text == null || text.trim().isEmpty) return;
    try {
      final Map<String, dynamic> data = YamlCodec.decode(text);
      final Object? raw = data['servers'];
      if (raw == null) return;
      if (raw is! List) {
        log?.call('MCP 配置的 servers 必须是数组（$configFile）');
        return;
      }
      for (final Object? item in raw) {
        if (item is! Map) continue;
        final McpServerConfig config = McpServerConfig.fromJson(
          item.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
        );
        if (config.name.trim().isEmpty) continue;
        if (_fileServers.any((McpServerConfig c) => c.name == config.name)) {
          log?.call('MCP 配置里有重名服务 ${config.name}，后一条已跳过（$configFile）');
          continue;
        }
        _fileServers.add(config);
      }
    } catch (error) {
      log?.call('MCP 配置解析失败（$configFile）：$error');
    }
  }

  /// 新增或覆盖一条文件配置并立即落盘。
  Future<void> upsert(McpServerConfig config) async {
    final int index = _fileServers.indexWhere(
      (McpServerConfig c) => c.name == config.name,
    );
    if (index >= 0) {
      _fileServers[index] = config;
    } else {
      _fileServers.add(config);
    }
    await persist();
  }

  /// 删除一条文件配置并立即落盘；不存在返回 false。
  Future<bool> removeFileServer(String name) async {
    final int before = _fileServers.length;
    _fileServers.removeWhere((McpServerConfig c) => c.name == name);
    if (_fileServers.length == before) return false;
    await persist();
    return true;
  }

  /// 把当前文件配置整份写回（原子替换，见 [_writeAtomic]）。
  Future<void> persist() async {
    if (_dataDir.isEmpty) {
      throw StateError('未绑定数据根，不能写入 MCP 配置');
    }
    final String text = YamlCodec.encode(<String, dynamic>{
      'servers': <Map<String, dynamic>>[
        for (final McpServerConfig config in _fileServers) config.toJson(),
      ],
    }, header: _header);
    await _writeAtomic(configFile, text);
  }

  String? _readStringOrNull(String path) {
    final File file = File(path);
    if (!file.existsSync()) return null;
    try {
      return utf8.decode(file.readAsBytesSync());
    } on FormatException {
      log?.call('MCP 配置不是合法 UTF-8，已按 U+FFFD 顶替后读取（$path）');
      return utf8.decode(file.readAsBytesSync(), allowMalformed: true);
    }
  }

  /// 写 `<path>.tmp` → flush → 改名覆盖；任何时刻磁盘上都不会是半截文件。
  static Future<void> _writeAtomic(String path, String content) async {
    final File target = File(path);
    await target.parent.create(recursive: true);
    final String tempPath = '$path.tmp';
    final File temp = File(tempPath);
    await temp.writeAsString(content, flush: true);
    try {
      await temp.rename(path);
    } on FileSystemException {
      if (await target.exists()) await target.delete();
      await temp.rename(path);
    }
  }
}
