import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sembast/sembast_io.dart';

/// 集合存储失败：人话 [message] + 稳定 [code]（调用方只按 code 分支）。
class StorageFailure implements Exception {
  StorageFailure(this.message, {this.code = 'storage_error'});

  final String message;
  final String code;

  @override
  String toString() => message;
}

/// 路径 / 名字分段校验（与核心 `TreePaths.safeSegment` 同一口径）。
///
/// 只允许 `[A-Za-z0-9_.-]`，拒绝空串 / `.` / `..`——命名空间会落成目录名，
/// 集合名会落成库内 store 名，二者都不允许把 `..` 带进路径。
String safeSegment(Object? raw, {required String what}) {
  final String value = (raw ?? '').toString().trim();
  if (value.isEmpty) {
    throw StorageFailure('$what 不能为空', code: 'invalid_arguments');
  }
  if (value == '.' || value == '..') {
    throw StorageFailure('$what 不能是 . 或 ..', code: 'invalid_arguments');
  }
  if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(value)) {
    throw StorageFailure(
      '$what 只允许 [A-Za-z0-9_.-]（防路径穿越）：$value',
      code: 'invalid_arguments',
    );
  }
  return value;
}

/// 单命名空间库：`<dataRoot>/storage/<teamId>/<namespace>/data.semdb`。
///
/// 实例粒度是 `granularity: team`（平台按团队各起一个实例），路径必须带 `team_id`，
/// 否则多团队实例会打开同一个库文件。一个命名空间 = 一个库；不同插件各库独立，
/// 互不影响（一个插件的大扫描不拖垮别人，单库损坏也不全盘失效）。
/// ST-1 只做单库 CRUD，CAS / tx / 导出在 ST-2/ST-3。
class StorageEngine {
  StorageEngine({required this.dataRoot, this.log});

  /// 数据根（核心经站请求 `meta.data_dir` 给出，插件不自行推导）。
  final String dataRoot;

  final void Function(String message)? log;

  /// 内部元数据 store（集合的 `schema_version` 等；调用方不可见）。
  static const String metaStore = '__meta';

  /// 集合 store（key = 业务 key，value = `{rev, value}`）。
  static StoreRef<String, Map<String, Object?>> storeOf(String collection) =>
      StoreRef<String, Map<String, Object?>>(collection);

  static final StoreRef<String, Map<String, Object?>> _meta =
      StoreRef<String, Map<String, Object?>>(metaStore);

  final Map<String, Future<Database>> _databases = <String, Future<Database>>{};

  /// 库文件路径（每团队 × 每插件一个库）。
  String databasePath({required String teamId, required String namespace}) {
    final String team = safeSegment(teamId, what: 'team_id');
    final String space = safeSegment(namespace, what: 'namespace');
    return p.join(dataRoot, 'storage', team, space, 'data.semdb');
  }

  Future<Database> _database(String teamId, String namespace) async {
    final String path = databasePath(teamId: teamId, namespace: namespace);
    final String key = p.dirname(path);
    try {
      return await _databases.putIfAbsent(key, () => _open(path));
    } catch (error) {
      // 打开失败不缓存失败态：下一次调用可以重试。
      _databases.remove(key);
      rethrow;
    }
  }

  Future<Database> _open(String path) async {
    await Directory(p.dirname(path)).create(recursive: true);
    return databaseFactoryIo.openDatabase(path);
  }

  /// 关闭全部已打开的库（插件停止 / 热重启前调用）。
  Future<void> close() async {
    final List<Future<Database>> databases = _databases.values.toList();
    _databases.clear();
    for (final Future<Database> database in databases) {
      try {
        await (await database).close();
      } catch (error) {
        log?.call('关闭库失败：$error');
      }
    }
  }

  /// 建集合 + 声明 `schema_version`。
  ///
  /// 已存在且库里版本更高 ⇒ 拒绝（不隐式降级）；更高版本会记下来（迁移由所有者插件
  /// 自己先做完再调 ensure）。同版本重复调用幂等。
  Future<Map<String, dynamic>> ensure({
    required String teamId,
    required String namespace,
    required String collection,
    int schemaVersion = 1,
  }) async {
    final String name = _collectionSegment(collection);
    if (schemaVersion < 1) {
      throw StorageFailure(
        'schema_version 必须是 >= 1 的整数：$schemaVersion',
        code: 'invalid_arguments',
      );
    }
    final Database database = await _database(teamId, namespace);
    final Map<String, Object?>? existing = await _meta
        .record(name)
        .get(database);
    final String now = DateTime.now().toUtc().toIso8601String();
    if (existing == null) {
      await _meta.record(name).put(database, <String, Object?>{
        'schema_version': schemaVersion,
        'created_at': now,
        'updated_at': now,
      });
    } else {
      final int current = _asInt(existing['schema_version'], 0);
      if (current > schemaVersion) {
        throw StorageFailure(
          '集合 $name 已存在且 schema_version=$current，拒绝降级到 $schemaVersion',
          code: 'schema_version_conflict',
        );
      }
      if (current < schemaVersion) {
        await _meta.record(name).put(database, <String, Object?>{
          ...existing,
          'schema_version': schemaVersion,
          'updated_at': now,
        });
      }
    }
    log?.call('ensure namespace=$namespace collection=$name v=$schemaVersion');
    return <String, dynamic>{
      'ok': true,
      'namespace': namespace,
      'collection': name,
      'schema_version': schemaVersion,
    };
  }

  /// 写一条：新记录 `rev=1`，之后每次 `rev` 单调递增（CAS 在 ST-2）。
  Future<Map<String, dynamic>> put({
    required String teamId,
    required String namespace,
    required String collection,
    required String key,
    required Map<String, dynamic> value,
  }) async {
    final String name = _collectionSegment(collection);
    final String recordKey = _keyOf(key);
    final Database database = await _database(teamId, namespace);
    final StoreRef<String, Map<String, Object?>> store = storeOf(name);
    final int rev = await database.transaction<int>((Transaction txn) async {
      final Map<String, Object?>? existing = await store
          .record(recordKey)
          .get(txn);
      final int next = _asInt(existing?['rev'], 0) + 1;
      await store.record(recordKey).put(txn, <String, Object?>{
        'rev': next,
        'value': value,
      });
      return next;
    });
    log?.call(
      'put namespace=$namespace collection=$name key=$recordKey rev=$rev',
    );
    return <String, dynamic>{
      'ok': true,
      'namespace': namespace,
      'collection': name,
      'key': recordKey,
      'rev': rev,
    };
  }

  /// 按 key 取一条；不存在 ⇒ `value: null`（不是错误）。
  Future<Map<String, dynamic>> get({
    required String teamId,
    required String namespace,
    required String collection,
    required String key,
  }) async {
    final String name = _collectionSegment(collection);
    final String recordKey = _keyOf(key);
    final Database database = await _database(teamId, namespace);
    final Map<String, Object?>? existing = await storeOf(name)
        .record(recordKey)
        .get(database);
    if (existing == null) {
      return <String, dynamic>{
        'ok': true,
        'namespace': namespace,
        'collection': name,
        'key': recordKey,
        'value': null,
        'rev': 0,
      };
    }
    return <String, dynamic>{
      'ok': true,
      'namespace': namespace,
      'collection': name,
      'key': recordKey,
      'value': existing['value'],
      'rev': _asInt(existing['rev'], 0),
    };
  }

  /// 按 key 删一条；不存在 ⇒ `deleted: false`（幂等）。
  Future<Map<String, dynamic>> delete({
    required String teamId,
    required String namespace,
    required String collection,
    required String key,
  }) async {
    final String name = _collectionSegment(collection);
    final String recordKey = _keyOf(key);
    final Database database = await _database(teamId, namespace);
    final StoreRef<String, Map<String, Object?>> store = storeOf(name);
    final bool deleted = await database.transaction<bool>((
      Transaction txn,
    ) async {
      if (await store.record(recordKey).get(txn) == null) return false;
      await store.record(recordKey).delete(txn);
      return true;
    });
    log?.call(
      'delete namespace=$namespace collection=$name key=$recordKey deleted=$deleted',
    );
    return <String, dynamic>{
      'ok': true,
      'namespace': namespace,
      'collection': name,
      'key': recordKey,
      'deleted': deleted,
    };
  }

  /// 条件 + 排序 + 分页（`limit` 上限 500；游标在 ST-2）。
  Future<Map<String, dynamic>> query({
    required String teamId,
    required String namespace,
    required String collection,
    Map<String, dynamic> filter = const <String, dynamic>{},
    String sort = '',
    bool descending = false,
    int limit = 100,
  }) async {
    final String name = _collectionSegment(collection);
    final int capped = limit < 1 ? 1 : (limit > 500 ? 500 : limit);
    final List<Filter> filters = <Filter>[
      for (final MapEntry<String, dynamic> entry in filter.entries)
        if (entry.value != null)
          Filter.equals('value.${entry.key}', entry.value),
    ];
    final List<SortOrder> orders = <SortOrder>[
      if (sort.trim().isNotEmpty)
        SortOrder('value.${sort.trim()}', !descending),
    ];
    final Database database = await _database(teamId, namespace);
    final List<RecordSnapshot<String, Map<String, Object?>>> records =
        await storeOf(name).find(
          database,
          finder: Finder(
            filter: filters.isEmpty
                ? null
                : (filters.length == 1 ? filters.first : Filter.and(filters)),
            sortOrders: orders.isEmpty ? null : orders,
            limit: capped,
          ),
        );
    final List<Map<String, Object?>> values = <Map<String, Object?>>[
      for (final RecordSnapshot<String, Map<String, Object?>> record in records)
        <String, Object?>{
          'key': record.key,
          'rev': _asInt(record.value['rev'], 0),
          'value': record.value['value'],
        },
    ];
    return <String, dynamic>{
      'ok': true,
      'namespace': namespace,
      'collection': name,
      'values': values,
      'count': values.length,
      'limit': capped,
    };
  }

  /// 集合名：safeSegment + 保留 `__` 前缀（内部元数据 store）。
  String _collectionSegment(Object? raw) {
    final String name = safeSegment(raw, what: 'collection');
    if (name.startsWith('__')) {
      throw StorageFailure(
        'collection 不允许使用保留前缀 __：$name',
        code: 'invalid_arguments',
      );
    }
    return name;
  }

  /// 业务 key：只要求非空（不是路径分段，不做字符集限制），上限 512。
  String _keyOf(Object? raw) {
    final String key = (raw ?? '').toString().trim();
    if (key.isEmpty) {
      throw StorageFailure('key 不能为空', code: 'invalid_arguments');
    }
    if (key.length > 512) {
      throw StorageFailure(
        'key 超长（>512）：${key.length}',
        code: 'invalid_arguments',
      );
    }
    return key;
  }

  static int _asInt(Object? raw, int fallback) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim()) ?? fallback;
    return fallback;
  }
}
