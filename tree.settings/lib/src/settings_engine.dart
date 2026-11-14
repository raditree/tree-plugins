import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sembast/sembast_io.dart';

/// 设置失败：人话 [message] + 稳定 [code]（调用方只按 code 分支）。
class SettingsFailure implements Exception {
  SettingsFailure(this.message, {this.code = 'settings_error'});

  final String message;
  final String code;

  @override
  String toString() => message;
}

/// 允许的字段类型（与方案 §4.1 同口径）。
const Set<String> kSettingTypes = <String>{
  'bool',
  'int',
  'double',
  'string',
  'enum',
  'secret',
  'path',
  'string_list',
};

/// 路径 / 名字分段校验（与核心 `TreePaths.safeSegment` 同一口径）。
String safeSegment(Object? raw, {required String what}) {
  final String value = (raw ?? '').toString().trim();
  if (value.isEmpty) {
    throw SettingsFailure('$what 不能为空', code: 'invalid_arguments');
  }
  if (value == '.' || value == '..') {
    throw SettingsFailure('$what 不能是 . 或 ..', code: 'invalid_arguments');
  }
  if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(value)) {
    throw SettingsFailure(
      '$what 只允许 [A-Za-z0-9_.-]（防路径穿越）：$value',
      code: 'invalid_arguments',
    );
  }
  return value;
}

/// 设置库的绑定维度：`team`（默认，按团队隔离）或 `plugin`（插件级全局）。
class SettingsScope {
  const SettingsScope.team(this.teamId) : binding = 'team';

  const SettingsScope.plugin() : binding = 'plugin', teamId = '';

  final String binding;
  final String teamId;

  bool get isPlugin => binding == 'plugin';
}

/// 每个 team 一份设置库：`<dataRoot>/settings/<teamId>/settings.semdb`；
/// plugin 绑定用全局库：`<dataRoot>/plugin_settings/settings.semdb`。
class SettingsEngine {
  SettingsEngine({required this.dataRoot, this.log});

  final String dataRoot;
  final void Function(String message)? log;

  static final StoreRef<String, Map<String, Object?>> _schemas =
      StoreRef<String, Map<String, Object?>>('schemas');
  static final StoreRef<String, Map<String, Object?>> _values =
      StoreRef<String, Map<String, Object?>>('values');
  static final StoreRef<String, Map<String, Object?>> _meta =
      StoreRef<String, Map<String, Object?>>('meta');

  final Map<String, Future<Database>> _databases = <String, Future<Database>>{};

  String databasePath(SettingsScope scope) {
    if (scope.isPlugin) {
      return p.join(dataRoot, 'plugin_settings', 'settings.semdb');
    }
    final String team = safeSegment(scope.teamId, what: 'team_id');
    return p.join(dataRoot, 'settings', team, 'settings.semdb');
  }

  Future<Database> _database(SettingsScope scope) async {
    final String path = databasePath(scope);
    try {
      return await _databases.putIfAbsent(path, () => _open(path));
    } catch (error) {
      _databases.remove(path);
      rethrow;
    }
  }

  Future<Database> _open(String path) async {
    await Directory(p.dirname(path)).create(recursive: true);
    return databaseFactoryIo.openDatabase(path);
  }

  Future<void> close() async {
    final List<Future<Database>> databases = _databases.values.toList();
    _databases.clear();
    for (final Future<Database> database in databases) {
      try {
        await (await database).close();
      } catch (error) {
        log?.call('关闭设置库失败：$error');
      }
    }
  }

  /// 注册 / 升级 schema。同版本同内容幂等；同版本不同内容、或降级 ⇒ 拒绝。
  Future<Map<String, dynamic>> define({
    required SettingsScope scope,
    required String owner,
    required Map<String, dynamic> schema,
  }) async {
    final String ownerId = safeSegment(owner, what: 'owner_plugin_id');
    final Map<String, Object?> normalized = _normalizeSchema(schema);
    final Database db = await _database(scope);
    return db.transaction((Transaction txn) async {
      final Map<String, Object?>? existing = await _schemas
          .record(ownerId)
          .get(txn);
      if (existing != null) {
        final int oldVersion = _int(existing['schema_version'], 1);
        final int newVersion = _int(normalized['schema_version'], 1);
        if (newVersion < oldVersion) {
          throw SettingsFailure(
            'schema_version 不能降级：当前 $oldVersion，收到 $newVersion',
            code: 'schema_version_conflict',
          );
        }
        if (newVersion == oldVersion) {
          final String oldJson = jsonEncode(existing);
          final String newJson = jsonEncode(normalized);
          if (oldJson != newJson) {
            throw SettingsFailure(
              'schema_version 相同但内容不同；升级 schema 必须递增版本',
              code: 'schema_version_conflict',
            );
          }
          return <String, dynamic>{...existing, 'unchanged': true};
        }
      }
      await _schemas.record(ownerId).put(txn, normalized);
      return <String, dynamic>{...normalized, 'unchanged': false};
    });
  }

  /// 读 schema + 覆盖值；secret 只回 `has_value`，不回原文。
  Future<Map<String, dynamic>> list({
    required SettingsScope scope,
    required String owner,
  }) async {
    final String ownerId = safeSegment(owner, what: 'owner_plugin_id');
    final Database db = await _database(scope);
    return db.transaction((Transaction txn) async {
      final Map<String, Object?>? schema = await _schemas
          .record(ownerId)
          .get(txn);
      if (schema == null) {
        throw SettingsFailure(
          '$ownerId 尚未注册设置 schema',
          code: 'schema_not_found',
        );
      }
      final Map<String, dynamic> values = <String, dynamic>{};
      for (final Object? raw in _list(schema['fields'])) {
        final Map<String, dynamic> field = _map(raw);
        final String key = _str(field['key']);
        final Map<String, Object?>? stored = await _values
            .record(_valueKey(ownerId, key))
            .get(txn);
        values[key] = _valueView(field, stored);
      }
      return <String, dynamic>{
        'plugin_id': ownerId,
        'schema_version': _int(schema['schema_version'], 1),
        'groups': _list(schema['groups']),
        'fields': _publicFields(schema),
        'values': values,
        'generation': await _generation(txn, ownerId),
      };
    });
  }

  Future<Map<String, dynamic>> get({
    required SettingsScope scope,
    required String owner,
    required String key,
  }) async {
    final String ownerId = safeSegment(owner, what: 'owner_plugin_id');
    final Database db = await _database(scope);
    return db.transaction((Transaction txn) async {
      final Map<String, Object?>? schema = await _schemas
          .record(ownerId)
          .get(txn);
      if (schema == null) {
        throw SettingsFailure(
          '$ownerId 尚未注册设置 schema',
          code: 'schema_not_found',
        );
      }
      final Map<String, dynamic>? field = _fieldOf(schema, key);
      if (field == null) {
        throw SettingsFailure('$ownerId 没有设置项 $key', code: 'unknown_key');
      }
      final Map<String, Object?>? stored = await _values
          .record(_valueKey(ownerId, key))
          .get(txn);
      return <String, dynamic>{
        'plugin_id': ownerId,
        'key': key,
        ..._valueView(field, stored),
      };
    });
  }

  /// 写覆盖值。返回实际写入的 key 与新的 generation。
  Future<Map<String, dynamic>> set({
    required SettingsScope scope,
    required String owner,
    required Map<String, dynamic> values,
  }) async {
    final String ownerId = safeSegment(owner, what: 'owner_plugin_id');
    if (values.length > 100) {
      throw SettingsFailure(
        '一次最多写 100 个设置项，当前 ${values.length}',
        code: 'invalid_arguments',
      );
    }
    if (values.isEmpty) {
      return <String, dynamic>{
        'plugin_id': ownerId,
        'applied': <String>[],
        'generation': await _currentGeneration(scope, ownerId),
      };
    }
    final Database db = await _database(scope);
    return db.transaction((Transaction txn) async {
      final Map<String, Object?>? schema = await _schemas
          .record(ownerId)
          .get(txn);
      if (schema == null) {
        throw SettingsFailure(
          '$ownerId 尚未注册设置 schema',
          code: 'schema_not_found',
        );
      }
      final List<String> applied = <String>[];
      for (final MapEntry<String, dynamic> entry in values.entries) {
        final Map<String, dynamic>? field = _fieldOf(schema, entry.key);
        if (field == null) {
          throw SettingsFailure(
            '$ownerId 没有设置项 ${entry.key}',
            code: 'unknown_key',
          );
        }
        final Object? normalized = _normalizeValue(field, entry.value);
        await _values.record(_valueKey(ownerId, entry.key)).put(
          txn,
          <String, Object?>{
            'value': normalized,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
        );
        applied.add(entry.key);
      }
      final int generation = await _bumpGeneration(txn, ownerId);
      return <String, dynamic>{
        'plugin_id': ownerId,
        'applied': applied,
        'generation': generation,
      };
    });
  }

  /// 删除覆盖值（回到 schema 默认）。
  Future<Map<String, dynamic>> reset({
    required SettingsScope scope,
    required String owner,
    required List<String> keys,
  }) async {
    final String ownerId = safeSegment(owner, what: 'owner_plugin_id');
    if (keys.isEmpty) {
      throw SettingsFailure('keys 不能为空', code: 'invalid_arguments');
    }
    final Database db = await _database(scope);
    return db.transaction((Transaction txn) async {
      final Map<String, Object?>? schema = await _schemas
          .record(ownerId)
          .get(txn);
      if (schema == null) {
        throw SettingsFailure(
          '$ownerId 尚未注册设置 schema',
          code: 'schema_not_found',
        );
      }
      final List<String> reset = <String>[];
      for (final String key in keys) {
        if (_fieldOf(schema, key) == null) {
          throw SettingsFailure('$ownerId 没有设置项 $key', code: 'unknown_key');
        }
        final String? removed = await _values
            .record(_valueKey(ownerId, key))
            .delete(txn);
        if (removed != null) reset.add(key);
      }
      final int generation = reset.isEmpty
          ? await _generation(txn, ownerId)
          : await _bumpGeneration(txn, ownerId);
      return <String, dynamic>{
        'plugin_id': ownerId,
        'reset': reset,
        'generation': generation,
      };
    });
  }

  /// 诊断导出：schema + 脱敏后的值；不提供导入。
  Future<Map<String, dynamic>> export({
    required SettingsScope scope,
    required String owner,
  }) => list(scope: scope, owner: owner);

  /// 所有插件的 schema（UI 首屏用）；不返回值。
  Future<List<Map<String, dynamic>>> listSchemas(SettingsScope scope) async {
    final Database db = await _database(scope);
    return db.transaction((Transaction txn) async {
      final List<RecordSnapshot<String, Map<String, Object?>>> records =
          await _schemas.find(txn);
      final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
      for (final RecordSnapshot<String, Map<String, Object?>> record
          in records) {
        out.add(<String, dynamic>{
          'plugin_id': record.key,
          ...record.value,
          'fields': _publicFields(record.value),
        });
      }
      out.sort(
        (Map<String, dynamic> a, Map<String, dynamic> b) =>
            _str(a['plugin_id']).compareTo(_str(b['plugin_id'])),
      );
      return out;
    });
  }

  Future<int> _currentGeneration(SettingsScope scope, String owner) async {
    final Database db = await _database(scope);
    return db.transaction((Transaction txn) async => _generation(txn, owner));
  }

  Future<int> _generation(Transaction txn, String owner) async {
    final Map<String, Object?>? record = await _meta
        .record('gen|$owner')
        .get(txn);
    return record == null ? 0 : _int(record['generation'], 0);
  }

  Future<int> _bumpGeneration(Transaction txn, String owner) async {
    final int next = await _generation(txn, owner) + 1;
    await _meta.record('gen|$owner').put(txn, <String, Object?>{
      'generation': next,
    });
    return next;
  }

  static String _valueKey(String owner, String key) => '$owner|$key';

  /// 回给 UI 的 schema：secret 的 default 一律清空（即使旧数据里写过）。
  static List<Map<String, dynamic>> _publicFields(Map<String, Object?> schema) {
    return <Map<String, dynamic>>[
      for (final Object? raw in _list(schema['fields']))
        if (_str(_map(raw)['type']) == 'secret')
          <String, dynamic>{..._map(raw), 'default': ''}
        else
          _map(raw),
    ];
  }

  static Map<String, dynamic>? _fieldOf(
    Map<String, Object?> schema,
    String key,
  ) {
    for (final Object? raw in _list(schema['fields'])) {
      final Map<String, dynamic> field = _map(raw);
      if (_str(field['key']) == key) return field;
    }
    return null;
  }

  static Map<String, dynamic> _valueView(
    Map<String, dynamic> field,
    Map<String, Object?>? stored,
  ) {
    final bool isSecret = _str(field['type']) == 'secret';
    final bool hasValue = stored != null;
    return <String, dynamic>{
      'type': _str(field['type']),
      'secret': isSecret,
      'has_value': hasValue,
      // secret 永不回显；未写过时给默认值（默认也只能是空串）。
      'value': isSecret
          ? null
          : (hasValue ? stored['value'] : field['default']),
      'updated_at': hasValue ? stored['updated_at'] : null,
    };
  }

  /// schema 归一化：字段名/类型/枚举/范围/默认值都在这里一次校验。
  Map<String, Object?> _normalizeSchema(Map<String, dynamic> raw) {
    final int version = _int(raw['schema_version'], 1);
    if (version < 1) {
      throw SettingsFailure(
        'schema_version 必须是 >= 1 的整数：$version',
        code: 'invalid_arguments',
      );
    }
    final List<Map<String, Object?>> groups = <Map<String, Object?>>[];
    final Set<String> groupIds = <String>{};
    for (final Object? item in _list(raw['groups'])) {
      final Map<String, dynamic> group = _map(item);
      final String id = safeSegment(group['id'], what: 'group.id');
      if (!groupIds.add(id)) {
        throw SettingsFailure('group.id 重复：$id', code: 'invalid_arguments');
      }
      groups.add(<String, Object?>{
        'id': id,
        'title': _nonEmpty(group['title'], 'group.title'),
        'order': _int(group['order'], groups.length * 10),
      });
    }
    final List<Object?> rawFields = _list(raw['fields']);
    if (rawFields.isEmpty) {
      throw SettingsFailure('fields 不能为空', code: 'invalid_arguments');
    }
    if (rawFields.length > 200) {
      throw SettingsFailure(
        'fields 最多 200 项，当前 ${rawFields.length}',
        code: 'invalid_arguments',
      );
    }
    final Set<String> keys = <String>{};
    final List<Map<String, Object?>> fields = <Map<String, Object?>>[];
    for (final Object? item in rawFields) {
      final Map<String, dynamic> field = _map(item);
      final String key = _str(field['key']);
      if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(key)) {
        throw SettingsFailure(
          '字段 key 只允许字母开头、字母/数字/下划线：$key',
          code: 'invalid_arguments',
        );
      }
      if (!keys.add(key)) {
        throw SettingsFailure('字段 key 重复：$key', code: 'invalid_arguments');
      }
      final String type = _str(field['type']);
      if (!kSettingTypes.contains(type)) {
        throw SettingsFailure(
          '字段 $key 的类型「$type」不在允许集内（${kSettingTypes.join(' / ')}）',
          code: 'invalid_arguments',
        );
      }
      final String group = _str(field['group']);
      if (group.isNotEmpty &&
          groupIds.isNotEmpty &&
          !groupIds.contains(group)) {
        throw SettingsFailure(
          '字段 $key 引用了不存在的 group：$group',
          code: 'invalid_arguments',
        );
      }
      final Map<String, Object?> normalized = <String, Object?>{
        'key': key,
        'title': _nonEmpty(field['title'], '字段 $key 的 title'),
        'type': type,
        if (group.isNotEmpty) 'group': group,
        'default': _defaultOf(field, key, type),
        if (_str(field['help']).isNotEmpty) 'help': _str(field['help']),
        if (field['restart_required'] == true) 'restart_required': true,
      };
      if (type == 'enum') {
        final List<String> options = <String>[];
        for (final Object? option in _list(field['options'])) {
          final String text = _str(option);
          if (text.isEmpty) {
            throw SettingsFailure(
              '字段 $key 的 options 不能含空项',
              code: 'invalid_arguments',
            );
          }
          if (!options.contains(text)) options.add(text);
        }
        if (options.isEmpty) {
          throw SettingsFailure(
            'enum 字段 $key 必须带非空 options',
            code: 'invalid_arguments',
          );
        }
        normalized['options'] = options;
      }
      if (type == 'int' || type == 'double') {
        final num? min = _numOrNull(field['min']);
        final num? max = _numOrNull(field['max']);
        if (min != null && max != null && min > max) {
          throw SettingsFailure(
            '字段 $key 的 min 不能大于 max',
            code: 'invalid_arguments',
          );
        }
        if (min != null) normalized['min'] = min;
        if (max != null) normalized['max'] = max;
      }
      // 默认值也要过一遍类型/枚举/范围校验。
      normalized['default'] = _normalizeValue(
        normalized,
        normalized['default'],
      );
      if (type == 'secret' && _str(normalized['default']).isNotEmpty) {
        // secret 默认值会随 schema 回给 UI；不允许把密钥写进 schema。
        throw SettingsFailure(
          'secret 字段 $key 的 default 必须为空串（密钥只能由用户写入）',
          code: 'invalid_arguments',
        );
      }
      fields.add(normalized);
    }
    return <String, Object?>{
      'schema_version': version,
      'groups': groups,
      'fields': fields,
    };
  }

  Object? _defaultOf(Map<String, dynamic> field, String key, String type) {
    if (field.containsKey('default')) return field['default'];
    switch (type) {
      case 'bool':
        return false;
      case 'int':
        return _numOrNull(field['min'])?.toInt() ?? 0;
      case 'double':
        return _numOrNull(field['min'])?.toDouble() ?? 0.0;
      case 'secret':
        return '';
      case 'string_list':
        return <String>[];
      case 'enum':
        final List<Object?> options = _list(field['options']);
        if (options.isEmpty) {
          throw SettingsFailure(
            'enum 字段 $key 必须带非空 options',
            code: 'invalid_arguments',
          );
        }
        return _str(options.first);
      default:
        return '';
    }
  }

  Object? _normalizeValue(Map<String, dynamic> field, Object? raw) {
    final String key = _str(field['key']);
    final String type = _str(field['type']);
    switch (type) {
      case 'bool':
        if (raw is! bool) {
          throw SettingsFailure(
            '字段 $key 需要 bool，收到 ${raw.runtimeType}',
            code: 'value_type_mismatch',
          );
        }
        return raw;
      case 'int':
        if (raw is! int) {
          throw SettingsFailure(
            '字段 $key 需要 int，收到 ${raw.runtimeType}',
            code: 'value_type_mismatch',
          );
        }
        return _checkRange(field, key, raw);
      case 'double':
        if (raw is! num) {
          throw SettingsFailure(
            '字段 $key 需要 double，收到 ${raw.runtimeType}',
            code: 'value_type_mismatch',
          );
        }
        return _checkRange(field, key, raw.toDouble());
      case 'enum':
        if (raw is! String) {
          throw SettingsFailure(
            '字段 $key 需要 string（enum），收到 ${raw.runtimeType}',
            code: 'value_type_mismatch',
          );
        }
        final String value = raw;
        final List<Object?> options = _list(field['options']);
        if (!options.map(_str).contains(value)) {
          throw SettingsFailure(
            '字段 $key 的取值「$value」不在 options 内',
            code: 'value_out_of_range',
          );
        }
        return value;
      case 'string_list':
        if (raw is! List || raw.any((Object? item) => item is! String)) {
          throw SettingsFailure('字段 $key 需要字符串数组', code: 'value_type_mismatch');
        }
        return raw.map((Object? item) => item as String).toList();
      case 'secret':
      case 'path':
      case 'string':
        if (raw is! String) {
          throw SettingsFailure(
            '字段 $key 需要 string，收到 ${raw.runtimeType}',
            code: 'value_type_mismatch',
          );
        }
        return raw;
      default:
        throw SettingsFailure(
          '字段 $key 的类型「$type」不可写',
          code: 'invalid_arguments',
        );
    }
  }

  Object? _checkRange(Map<String, dynamic> field, String key, num value) {
    final num? min = _numOrNull(field['min']);
    final num? max = _numOrNull(field['max']);
    if (min != null && value < min) {
      throw SettingsFailure(
        '字段 $key 不能小于 $min（收到 $value）',
        code: 'value_out_of_range',
      );
    }
    if (max != null && value > max) {
      throw SettingsFailure(
        '字段 $key 不能大于 $max（收到 $value）',
        code: 'value_out_of_range',
      );
    }
    return value;
  }

  static String _nonEmpty(Object? raw, String what) {
    final String value = _str(raw);
    if (value.isEmpty) {
      throw SettingsFailure('$what 不能为空', code: 'invalid_arguments');
    }
    return value;
  }

  static String _str(Object? raw) => (raw ?? '').toString().trim();

  static int _int(Object? raw, int fallback) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim()) ?? fallback;
    return fallback;
  }

  static num? _numOrNull(Object? raw) =>
      raw is num ? raw : (raw is String ? num.tryParse(raw.trim()) : null);

  static Map<String, dynamic> _map(Object? raw) => raw is Map
      ? raw.map(
          (Object? key, Object? value) =>
              MapEntry<String, dynamic>(key.toString(), value),
        )
      : <String, dynamic>{};

  static List<Object?> _list(Object? raw) => raw is List ? raw : <Object?>[];
}
