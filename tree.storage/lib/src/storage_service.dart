import 'dart:convert';
import 'dart:io';

import 'storage_engine.dart';

/// 执行站命令族（ST-1~ST-5 全量）。
const List<String> kStorageCommands = <String>[
  'storage.ensure',
  'storage.put',
  'storage.get',
  'storage.delete',
  'storage.query',
  'storage.scan',
  'storage.count',
  'storage.tx',
  'storage.export',
  'storage.import',
  'storage.stats',
  'storage.compact',
  'storage.purge',
];

/// 写命令集合（审计逐条记录；读命令不记）。
const Set<String> _writeCommands = <String>{
  'storage.ensure',
  'storage.put',
  'storage.delete',
  'storage.tx',
  'storage.import',
  'storage.purge',
};

/// 执行站入口：身份 → 数据根 → 团队 → 命名空间 → 命令。
///
/// 访问口径（方案 §4/§5.3）：
/// - 调用方身份只认核心透传的 `meta.source_plugin_id`，不认 payload 自报；
///   核心没带身份 ⇒ fail-closed（不猜调用方）；
/// - `team_id` 只从核心解析的 `scope` 取（实例粒度 = team），取不到 ⇒ 拒绝；
/// - `namespace` 缺省 = 调用方 plugin_id；自己的 namespace 永远允许，访问别人的
///   需要调用方出现在 `TREE_STORAGE_ALLOWED_PLUGINS`（逗号分隔）里，否则
///   `namespace_denied`（`storage.purge` 只允许自己的 namespace）；
/// - 数据根只认 `meta.data_dir`（meta 缺失时回退环境变量 `TREE_DATA_ROOT`）；
/// - 每条写命令在 [log] 上留一行结构化审计。
class StorageService {
  StorageService({Map<String, String>? environment, this.log})
    : _environment = environment ?? Platform.environment;

  final Map<String, String> _environment;

  final void Function(String message)? log;

  final Map<String, StorageEngine> _engines = <String, StorageEngine>{};

  Set<String> get _allowedPlugins =>
      _parseAllowed(_environment['TREE_STORAGE_ALLOWED_PLUGINS']);

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
    final String binding = _bindingOf(arguments);
    final StorageScope storageScope;
    if (binding == 'plugin') {
      storageScope = const StorageScope.plugin();
    } else {
      if (teamId.isEmpty) {
        throw StorageFailure(
          '核心未在站请求的 scope 里带 team_id，拒绝落到公共库（plugin 级存储请传 binding:plugin）',
          code: 'team_required',
        );
      }
      storageScope = StorageScope.team(teamId);
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
    final bool ownNamespace = namespace == caller;
    final bool allowed = ownNamespace || _allowedPlugins.contains(caller);
    if (!allowed) {
      throw StorageFailure(
        '命名空间 $namespace 不属于调用方 $caller，且调用方不在 '
        'TREE_STORAGE_ALLOWED_PLUGINS 白名单里',
        code: 'namespace_denied',
      );
    }
    // 删库是破坏性操作：即使调用方在白名单里，也只能删自己的 namespace。
    if (command == 'storage.purge' && !ownNamespace) {
      throw StorageFailure(
        'storage.purge 只允许删除自己的 namespace（调用方 $caller ≠ $namespace）',
        code: 'namespace_denied',
      );
    }

    final StorageEngine engine = _engineOf(dataRoot);
    if (_writeCommands.contains(command)) {
      _auditCommand(
        caller: caller,
        binding: binding,
        namespace: namespace,
        command: command,
        arguments: arguments,
      );
    }
    switch (command) {
      case 'storage.ensure':
        return engine.ensure(
          scope: storageScope,
          namespace: namespace,
          collection: _str(arguments['collection']),
          schemaVersion: _int(arguments['schema_version'], 1),
        );
      case 'storage.put':
        return engine.put(
          scope: storageScope,
          namespace: namespace,
          collection: _str(arguments['collection']),
          key: _str(arguments['key']),
          value: _requireMap(arguments['value']),
          ifRev: _optionalInt(arguments['if_rev'], field: 'if_rev'),
        );
      case 'storage.get':
        return engine.get(
          scope: storageScope,
          namespace: namespace,
          collection: _str(arguments['collection']),
          key: _str(arguments['key']),
        );
      case 'storage.delete':
        return engine.delete(
          scope: storageScope,
          namespace: namespace,
          collection: _str(arguments['collection']),
          key: _str(arguments['key']),
        );
      case 'storage.query':
        return engine.query(
          scope: storageScope,
          namespace: namespace,
          collection: _str(arguments['collection']),
          filter: _map(arguments['filter']),
          sort: _str(arguments['sort']),
          descending: arguments['descending'] == true,
          limit: _int(arguments['limit'], 100),
          cursor: _str(arguments['cursor']),
        );
      case 'storage.scan':
        return engine.scan(
          scope: storageScope,
          namespace: namespace,
          collection: _str(arguments['collection']),
          prefix: _str(arguments['prefix']),
          limit: _int(arguments['limit'], 1000),
        );
      case 'storage.count':
        return engine.count(
          scope: storageScope,
          namespace: namespace,
          collection: _str(arguments['collection']),
          filter: _map(arguments['filter']),
        );
      case 'storage.tx':
        return engine.tx(
          scope: storageScope,
          namespace: namespace,
          ops: _ops(arguments['ops']),
        );
      case 'storage.export':
        return engine.export(
          scope: storageScope,
          namespace: namespace,
          collection: _str(arguments['collection']),
        );
      case 'storage.import':
        return engine.importData(
          scope: storageScope,
          namespace: namespace,
          path: _str(arguments['path']),
          collection: _str(arguments['collection']),
          replace: arguments['replace'] == true,
        );
      case 'storage.stats':
        return engine.stats(scope: storageScope, namespace: namespace);
      case 'storage.compact':
        return engine.compact(scope: storageScope, namespace: namespace);
      case 'storage.purge':
        return engine.purge(
          scope: storageScope,
          namespace: namespace,
          confirm: arguments['confirm'] == true,
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

  /// 解析绑定维度：缺省 team（兼容旧调用），只接受 team / plugin。
  static String _bindingOf(Map<String, dynamic> arguments) {
    final String raw = _str(arguments['binding']).toLowerCase();
    if (raw.isEmpty) return 'team';
    if (raw == 'team' || raw == 'plugin') return raw;
    throw StorageFailure(
      'binding 只能是 team / plugin：$raw',
      code: 'invalid_arguments',
    );
  }

  /// 审计：每条写命令一行结构化信息（caller/binding/namespace/collection/op/key/bytes/at）。
  ///
  /// `storage.tx` 的 collection / key 不在顶层，这里从 ops 里汇总（逗号分隔），
  /// 保证审计行仍能定位到写到了哪些集合与 key。
  void _auditCommand({
    required String caller,
    required String binding,
    required String namespace,
    required String command,
    required Map<String, dynamic> arguments,
  }) {
    String collection = _str(arguments['collection']);
    String key = _str(arguments['key']);
    if (command == 'storage.tx' && arguments['ops'] is List) {
      final Set<String> collections = <String>{};
      final List<String> keys = <String>[];
      for (final Object? op in arguments['ops'] as List<dynamic>) {
        if (op is! Map) continue;
        final String opCollection = _str(op['collection']);
        if (opCollection.isNotEmpty) collections.add(opCollection);
        final String opKey = _str(op['key']);
        if (opKey.isNotEmpty) keys.add(opKey);
      }
      collection = collections.join(',');
      key = keys.join(',');
    }
    _audit(
      caller: caller,
      binding: binding,
      namespace: namespace,
      collection: collection,
      op: command.substring('storage.'.length),
      key: key,
      bytes: _bytesOf(command, arguments),
    );
  }

  void _audit({
    required String caller,
    required String binding,
    required String namespace,
    required String collection,
    required String op,
    required String key,
    required int bytes,
  }) {
    final String at = DateTime.now().toUtc().toIso8601String();
    log?.call(
      'audit caller=$caller binding=$binding namespace=$namespace '
      'collection=$collection op=$op key=$key bytes=$bytes at=$at',
    );
  }

  /// 审计里的字节数：put 看 value，tx 看全部 value，其余为 0。
  static int _bytesOf(String command, Map<String, dynamic> arguments) {
    try {
      switch (command) {
        case 'storage.put':
          return utf8.encode(json.encode(arguments['value'])).length;
        case 'storage.tx':
          final Object? raw = arguments['ops'];
          if (raw is! List) return 0;
          int total = 0;
          for (final Object? op in raw) {
            if (op is Map) {
              final Object? value = op['value'];
              if (value != null) {
                total += utf8.encode(json.encode(value)).length;
              }
            }
          }
          return total;
        default:
          return 0;
      }
    } catch (_) {
      return 0;
    }
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

  static Set<String> _parseAllowed(String? raw) => <String>{
    for (final String part in (raw ?? '').split(','))
      if (part.trim().isNotEmpty) part.trim(),
  };

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

  /// `storage.tx` 的 ops 必须是对象数组（逐项校验在引擎里做）。
  static List<Map<String, dynamic>> _ops(Object? raw) {
    if (raw is! List) {
      throw StorageFailure('ops 必须是数组', code: 'invalid_arguments');
    }
    final List<Map<String, dynamic>> ops = <Map<String, dynamic>>[];
    for (int index = 0; index < raw.length; index++) {
      final Object? op = raw[index];
      if (op is! Map) {
        throw StorageFailure('ops[$index] 必须是对象', code: 'invalid_arguments');
      }
      ops.add(_map(op));
    }
    return ops;
  }

  static int _int(Object? raw, int fallback) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim()) ?? fallback;
    return fallback;
  }

  static int? _optionalInt(Object? raw, {required String field}) {
    if (raw == null) return null;
    if (raw is num) return raw.toInt();
    final String text = raw.toString().trim();
    if (text.isEmpty) return null;
    final int? parsed = int.tryParse(text);
    if (parsed == null) {
      throw StorageFailure('$field 必须是整数：$text', code: 'invalid_arguments');
    }
    return parsed;
  }
}
