import 'dart:io';

import 'storage_engine.dart';

/// 执行站命令族（**ST-1 只注册已实现的那几条**；ST-2/ST-3 按方案文档追加）。
const List<String> kStorageCommands = <String>[
  'storage.ensure',
  'storage.put',
  'storage.get',
  'storage.delete',
  'storage.query',
];

/// 执行站入口：身份 → 数据根 → 团队 → 命名空间 → 命令。
///
/// 访问口径（方案 §4/§5.3）：
/// - 调用方身份只认核心透传的 `meta.source_plugin_id`，不认 payload 自报；
///   核心没带身份 ⇒ fail-closed（不猜调用方）；
/// - `team_id` 只从核心解析的 `scope` 取（实例粒度 = team），取不到 ⇒ 拒绝；
/// - `namespace` 缺省 = 调用方 plugin_id；ST-1 尚无跨插件白名单，填别人 namespace
///   一律拒绝（白名单与审计在 ST-4 接）；
/// - 数据根只认 `meta.data_dir`（meta 缺失时回退环境变量 `TREE_DATA_ROOT`）。
class StorageService {
  StorageService({Map<String, String>? environment, this.log})
    : _environment = environment ?? Platform.environment;

  final Map<String, String> _environment;

  final void Function(String message)? log;

  final Map<String, StorageEngine> _engines = <String, StorageEngine>{};

  Future<Map<String, dynamic>> handle(
    String command,
    Map<String, dynamic> arguments,
    Map<String, dynamic> meta,
    Map<String, dynamic> scope,
  ) async {
    final String caller = _str(meta['source_plugin_id']);
    if (caller.isEmpty) {
      throw StorageFailure(
        '核心未在站请求的 meta 里带 source_plugin_id，拒绝猜测调用方',
        code: 'identity_required',
      );
    }
    final String teamId = _str(scope['team_id']);
    if (teamId.isEmpty) {
      throw StorageFailure(
        '核心未在站请求的 scope 里带 team_id，拒绝落到公共库',
        code: 'team_required',
      );
    }
    final String dataRoot = _dataRoot(meta);
    if (dataRoot.isEmpty) {
      throw StorageFailure(
        '缺少 data_dir（核心未在站请求的 meta 里带数据根，环境变量 TREE_DATA_ROOT 也未设置）',
        code: 'missing_data_dir',
      );
    }
    final String requestedNamespace = _str(arguments['namespace']);
    final String namespace = requestedNamespace.isEmpty
        ? caller
        : requestedNamespace;
    if (namespace != caller) {
      throw StorageFailure(
        '命名空间 $namespace 不属于调用方 $caller（跨插件白名单在 ST-4 接）',
        code: 'namespace_denied',
      );
    }
    final StorageEngine engine = _engineOf(dataRoot);
    switch (command) {
      case 'storage.ensure':
        return engine.ensure(
          teamId: teamId,
          namespace: namespace,
          collection: _str(arguments['collection']),
          schemaVersion: _int(arguments['schema_version'], 1),
        );
      case 'storage.put':
        return engine.put(
          teamId: teamId,
          namespace: namespace,
          collection: _str(arguments['collection']),
          key: _str(arguments['key']),
          value: _requireMap(arguments['value']),
        );
      case 'storage.get':
        return engine.get(
          teamId: teamId,
          namespace: namespace,
          collection: _str(arguments['collection']),
          key: _str(arguments['key']),
        );
      case 'storage.delete':
        return engine.delete(
          teamId: teamId,
          namespace: namespace,
          collection: _str(arguments['collection']),
          key: _str(arguments['key']),
        );
      case 'storage.query':
        return engine.query(
          teamId: teamId,
          namespace: namespace,
          collection: _str(arguments['collection']),
          filter: _map(arguments['filter']),
          sort: _str(arguments['sort']),
          descending: arguments['descending'] == true,
          limit: _int(arguments['limit'], 100),
        );
      default:
        throw StorageFailure('未知存储命令：$command', code: 'unknown_command');
    }
  }

  Future<void> close() async {
    for (final StorageEngine engine in _engines.values) {
      await engine.close();
    }
    _engines.clear();
  }

  StorageEngine _engineOf(String dataRoot) => _engines.putIfAbsent(
    dataRoot,
    () => StorageEngine(dataRoot: dataRoot, log: log),
  );

  String _dataRoot(Map<String, dynamic> meta) {
    final String fromMeta = _str(meta['data_dir']);
    if (fromMeta.isNotEmpty) return fromMeta;
    return _str(_environment['TREE_DATA_ROOT']);
  }

  static String _str(Object? raw) => (raw ?? '').toString().trim();

  static Map<String, dynamic> _map(Object? raw) => raw is Map
      ? raw.map(
          (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
        )
      : <String, dynamic>{};

  /// `put` 的 value 必须是 JSON 对象（数组 / 标量一律拒绝，不悄悄包一层）。
  static Map<String, dynamic> _requireMap(Object? raw) {
    if (raw is Map) return _map(raw);
    throw StorageFailure('value 必须是 JSON 对象', code: 'invalid_arguments');
  }

  static int _int(Object? raw, int fallback) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim()) ?? fallback;
    return fallback;
  }
}
