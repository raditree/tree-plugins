import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sembast/sembast_io.dart';
import 'package:sembast/utils/database_utils.dart';

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
///
/// 切片：ST-1 单库 CRUD；ST-2 CAS / cursor / tx；ST-3 导出导入；ST-5 维护命令。
class StorageEngine {
  StorageEngine({required this.dataRoot, this.log});

  /// 数据根（核心经站请求 `meta.data_dir` 给出，插件不自行推导）。
  final String dataRoot;

  final void Function(String message)? log;

  /// 内部元数据 store（集合的 `schema_version` 等；调用方不可见）。
  static const String metaStore = '__meta';

  /// 单次 tx 的 ops 上限（方案 §5.2）。
  static const int maxTxOps = 200;

  /// 单条 value 的 UTF-8 上限（1 MiB）。
  static const int maxValueBytes = 1024 * 1024;

  /// 单次 tx 的总字节上限（8 MiB）。
  static const int maxTxBytes = 8 * 1024 * 1024;

  /// query 的 limit 上限。
  static const int maxQueryLimit = 500;

  /// scan（导出/维护）的 limit 上限。
  static const int maxScanLimit = 5000;

  /// 导出格式标识（写进 manifest，导入时校验）。
  static const String exportFormat = 'tree.storage.ndjson';
  static const int exportVersion = 1;

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

  /// 写一条：新记录 `rev=1`，之后每次 `rev` 单调递增。
  ///
  /// [ifRev] 给出时做 CAS：当前 rev 必须等于它（不存在的记录 rev=0），
  /// 不匹配 ⇒ `rev_conflict`（不覆盖）。
  Future<Map<String, dynamic>> put({
    required String teamId,
    required String namespace,
    required String collection,
    required String key,
    required Map<String, dynamic> value,
    int? ifRev,
  }) async {
    final String name = _collectionSegment(collection);
    final String recordKey = _keyOf(key);
    final Database database = await _database(teamId, namespace);
    final StoreRef<String, Map<String, Object?>> store = storeOf(name);
    final int rev = await database.transaction<int>((Transaction txn) async {
      final Map<String, Object?>? existing = await store
          .record(recordKey)
          .get(txn);
      final int current = _asInt(existing?['rev'], 0);
      if (ifRev != null && ifRev != current) {
        throw StorageFailure(
          'rev 冲突：key=$recordKey 期望 if_rev=$ifRev，实际 rev=$current',
          code: 'rev_conflict',
        );
      }
      final int next = current + 1;
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

  /// 条件 + 排序 + 分页（`limit` 上限 500；`cursor` 为不透明游标）。
  ///
  /// 游标 = base64url(JSON `{offset, fingerprint}`)，fingerprint 覆盖
  /// `(collection, filter, sort, descending)`：换条件再用旧游标 ⇒ `cursor_mismatch`。
  Future<Map<String, dynamic>> query({
    required String teamId,
    required String namespace,
    required String collection,
    Map<String, dynamic> filter = const <String, dynamic>{},
    String sort = '',
    bool descending = false,
    int limit = 100,
    String cursor = '',
  }) async {
    final String name = _collectionSegment(collection);
    final String sortField = sort.trim();
    final int capped = limit < 1
        ? 1
        : (limit > maxQueryLimit ? maxQueryLimit : limit);
    final String fingerprint = _queryFingerprint(
      name,
      filter,
      sortField,
      descending,
    );
    final int offset = _offsetFromCursor(cursor, fingerprint);
    final List<Filter> filters = <Filter>[
      for (final MapEntry<String, dynamic> entry in _canonicalFilter(
        filter,
      ).entries)
        Filter.equals('value.${entry.key}', entry.value),
    ];
    final List<SortOrder> orders = <SortOrder>[
      if (sortField.isNotEmpty) SortOrder('value.$sortField', !descending),
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
            offset: offset,
            // 多取一条判断还有没有下一页。
            limit: capped + 1,
          ),
        );
    final bool hasMore = records.length > capped;
    final List<RecordSnapshot<String, Map<String, Object?>>> page = hasMore
        ? records.sublist(0, capped)
        : records;
    final List<Map<String, Object?>> values = <Map<String, Object?>>[
      for (final RecordSnapshot<String, Map<String, Object?>> record in page)
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
      'cursor': hasMore ? _encodeCursor(offset + page.length, fingerprint) : '',
      'has_more': hasMore,
    };
  }

  /// 顺序扫（可按 key 前缀；只给导出/维护，业务读走 [query]）。
  Future<Map<String, dynamic>> scan({
    required String teamId,
    required String namespace,
    required String collection,
    String prefix = '',
    int limit = 1000,
  }) async {
    final String name = _collectionSegment(collection);
    final int capped = limit < 1
        ? 1
        : (limit > maxScanLimit ? maxScanLimit : limit);
    final Database database = await _database(teamId, namespace);
    final List<RecordSnapshot<String, Map<String, Object?>>> records =
        await storeOf(name).find(
          database,
          finder: Finder(sortOrders: <SortOrder>[SortOrder(Field.key)]),
        );
    final List<Map<String, Object?>> values = <Map<String, Object?>>[];
    bool hasMore = false;
    for (final RecordSnapshot<String, Map<String, Object?>> record in records) {
      if (prefix.isNotEmpty && !record.key.startsWith(prefix)) continue;
      if (values.length >= capped) {
        hasMore = true;
        break;
      }
      values.add(<String, Object?>{
        'key': record.key,
        'rev': _asInt(record.value['rev'], 0),
        'value': record.value['value'],
      });
    }
    return <String, dynamic>{
      'ok': true,
      'namespace': namespace,
      'collection': name,
      'values': values,
      'count': values.length,
      'limit': capped,
      'has_more': hasMore,
    };
  }

  /// 计数：与 [query] 同一套等值过滤（不受 limit 影响）。
  Future<Map<String, dynamic>> count({
    required String teamId,
    required String namespace,
    required String collection,
    Map<String, dynamic> filter = const <String, dynamic>{},
  }) async {
    final String name = _collectionSegment(collection);
    final List<Filter> filters = <Filter>[
      for (final MapEntry<String, dynamic> entry in _canonicalFilter(
        filter,
      ).entries)
        Filter.equals('value.${entry.key}', entry.value),
    ];
    final Database database = await _database(teamId, namespace);
    final int total = await storeOf(name).count(
      database,
      filter: filters.isEmpty
          ? null
          : (filters.length == 1 ? filters.first : Filter.and(filters)),
    );
    return <String, dynamic>{
      'ok': true,
      'namespace': namespace,
      'collection': name,
      'count': total,
    };
  }

  /// 批量 ops 原子执行（方案 §5.2 / TC-ST-03 / TC-ST-11）。
  ///
  /// 整个 ops 在一个 Sembast 事务里；任一 op 失败 ⇒ 整批回滚，错误码 `tx_failed`
  /// 并带第几项。写库前先做结构 / 字节上限校验，超限整批拒绝（不落半截）。
  Future<Map<String, dynamic>> tx({
    required String teamId,
    required String namespace,
    required List<Map<String, dynamic>> ops,
  }) async {
    if (ops.isEmpty) {
      throw StorageFailure('ops 不能为空', code: 'invalid_arguments');
    }
    if (ops.length > maxTxOps) {
      throw StorageFailure(
        '单次 tx 最多 $maxTxOps 项，实得 ${ops.length} 项',
        code: 'invalid_arguments',
      );
    }
    final List<_TxOp> parsed = <_TxOp>[];
    int totalBytes = 0;
    for (int index = 0; index < ops.length; index++) {
      final Map<String, dynamic> raw = ops[index];
      final String op = _text(raw['op']);
      if (op != 'put' && op != 'delete') {
        throw StorageFailure(
          'ops[$index].op 必须是 put 或 delete，实得「$op」',
          code: 'invalid_arguments',
        );
      }
      final String collection = _collectionSegment(raw['collection']);
      final String key = _keyOf(raw['key']);
      Map<String, dynamic>? value;
      int bytes = 0;
      if (op == 'put') {
        value = _requireValue(raw['value']);
        bytes = utf8.encode(json.encode(value)).length;
        if (bytes > maxValueBytes) {
          throw StorageFailure(
            'ops[$index].value 超限：$bytes 字节 > $maxValueBytes（1 MiB）',
            code: 'invalid_arguments',
          );
        }
      }
      totalBytes += bytes;
      parsed.add(
        _TxOp(
          index: index,
          op: op,
          collection: collection,
          key: key,
          value: value,
          ifRev: _optionalInt(raw['if_rev'], field: 'ops[$index].if_rev'),
        ),
      );
    }
    if (totalBytes > maxTxBytes) {
      throw StorageFailure(
        '单次 tx 总字节超限：$totalBytes 字节 > $maxTxBytes（8 MiB）',
        code: 'invalid_arguments',
      );
    }

    final Database database = await _database(teamId, namespace);
    List<Map<String, dynamic>> results;
    try {
      results = await database.transaction<List<Map<String, dynamic>>>((
        Transaction txn,
      ) async {
        final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
        for (final _TxOp operation in parsed) {
          try {
            out.add(await _applyTxOp(txn, operation));
          } catch (error) {
            throw _TxOpFailure(operation.index, error);
          }
        }
        return out;
      });
    } on _TxOpFailure catch (failure) {
      throw StorageFailure(
        'storage.tx 第 ${failure.index} 项失败，整批已回滚：${failure.cause}',
        code: 'tx_failed',
      );
    }
    log?.call(
      'tx namespace=$namespace ops=${parsed.length} bytes=$totalBytes committed=true',
    );
    return <String, dynamic>{
      'ok': true,
      'namespace': namespace,
      'count': results.length,
      'committed': true,
      'results': results,
    };
  }

  /// 导出集合为 NDJSON + manifest（原子写；ST-3 / TC-ST-05）。
  Future<Map<String, dynamic>> export({
    required String teamId,
    required String namespace,
    required String collection,
  }) async {
    final String name = _collectionSegment(collection);
    final Database database = await _database(teamId, namespace);
    final List<RecordSnapshot<String, Map<String, Object?>>> records =
        await storeOf(name).find(
          database,
          finder: Finder(sortOrders: <SortOrder>[SortOrder(Field.key)]),
        );
    final StringBuffer buffer = StringBuffer();
    for (final RecordSnapshot<String, Map<String, Object?>> record in records) {
      buffer.writeln(
        json.encode(<String, Object?>{
          'key': record.key,
          'rev': _asInt(record.value['rev'], 0),
          'value': record.value['value'],
        }),
      );
    }
    final List<int> bytes = utf8.encode(buffer.toString());
    final String digest = sha256.convert(bytes).toString();
    final Map<String, Object?>? meta = await _meta.record(name).get(database);
    final DateTime now = DateTime.now().toUtc();
    final String stamp = _stamp(now);
    final String dir = p.join(
      p.dirname(databasePath(teamId: teamId, namespace: namespace)),
      'export',
      name,
      stamp,
    );
    await Directory(dir).create(recursive: true);
    await _atomicWrite(p.join(dir, 'data.ndjson'), bytes);
    final Map<String, dynamic> manifest = <String, dynamic>{
      'format': exportFormat,
      'version': exportVersion,
      'team_id': teamId,
      'namespace': namespace,
      'collection': name,
      'schema_version': meta == null ? 0 : _asInt(meta['schema_version'], 0),
      'count': records.length,
      'sha256': digest,
      'created_at': now.toIso8601String(),
    };
    await _atomicWrite(
      p.join(dir, 'manifest.json'),
      utf8.encode(json.encode(manifest)),
    );
    log?.call(
      'export namespace=$namespace collection=$name count=${records.length} path=$dir',
    );
    return <String, dynamic>{
      'ok': true,
      'namespace': namespace,
      'collection': name,
      'path': dir,
      'count': records.length,
      'sha256': digest,
      'manifest': manifest,
    };
  }

  /// 从导出物导入（单事务；校验失败不落半截；ST-3 / TC-ST-05）。
  Future<Map<String, dynamic>> importData({
    required String teamId,
    required String namespace,
    required String path,
    String collection = '',
    bool replace = false,
  }) async {
    final String root = p.canonicalize(p.absolute(dataRoot));
    final String target = p.canonicalize(p.absolute(path));
    if (!p.isWithin(root, target)) {
      throw StorageFailure(
        'import path 必须位于数据根内（防路径穿越）：$path',
        code: 'invalid_arguments',
      );
    }
    final File manifestFile = File(p.join(target, 'manifest.json'));
    final File dataFile = File(p.join(target, 'data.ndjson'));
    if (!manifestFile.existsSync() || !dataFile.existsSync()) {
      throw StorageFailure(
        '导出物缺少 manifest.json 或 data.ndjson：$target',
        code: 'import_invalid',
      );
    }
    Map<String, dynamic> manifest;
    try {
      final Object? decoded = json.decode(manifestFile.readAsStringSync());
      if (decoded is! Map) throw const FormatException('manifest 不是对象');
      manifest = decoded.map(
        (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
      );
    } catch (error) {
      throw StorageFailure('manifest 无法解析：$error', code: 'import_invalid');
    }
    if (_text(manifest['format']) != exportFormat) {
      throw StorageFailure(
        'manifest.format 不是 $exportFormat：${manifest['format']}',
        code: 'import_invalid',
      );
    }
    if (_asInt(manifest['version'], -1) != exportVersion) {
      throw StorageFailure(
        'manifest.version 不支持：${manifest['version']}',
        code: 'import_invalid',
      );
    }
    final String manifestCollection = _text(manifest['collection']);
    if (manifestCollection.isEmpty) {
      throw StorageFailure('manifest 缺 collection', code: 'import_invalid');
    }
    final String name = _collectionSegment(
      collection.trim().isEmpty ? manifestCollection : collection,
    );

    final List<int> bytes = dataFile.readAsBytesSync();
    final String digest = sha256.convert(bytes).toString();
    if (digest != _text(manifest['sha256'])) {
      throw StorageFailure(
        'sha256 校验失败：manifest=${manifest['sha256']}，实际=$digest',
        code: 'import_invalid',
      );
    }
    final List<_ImportRow> rows = _parseRows(bytes);
    final int expected = _asInt(manifest['count'], -1);
    if (expected != rows.length) {
      throw StorageFailure(
        'manifest.count=$expected 与实际行数 ${rows.length} 不一致',
        code: 'import_invalid',
      );
    }

    final Database database = await _database(teamId, namespace);
    final StoreRef<String, Map<String, Object?>> store = storeOf(name);
    final int existing = await store.count(database);
    if (existing > 0 && !replace) {
      throw StorageFailure(
        '目标集合 $name 非空（$existing 条），如需覆盖请传 replace:true',
        code: 'collection_not_empty',
      );
    }
    await database.transaction<void>((Transaction txn) async {
      if (replace) await store.delete(txn);
      for (final _ImportRow row in rows) {
        await store.record(row.key).put(txn, <String, Object?>{
          'rev': row.rev,
          'value': row.value,
        });
      }
      // 目标集合没有元数据时，按导出物的 schema_version 补一条（已存在不降级）。
      if (await _meta.record(name).get(txn) == null) {
        final String now = DateTime.now().toUtc().toIso8601String();
        await _meta.record(name).put(txn, <String, Object?>{
          'schema_version': _asInt(manifest['schema_version'], 1),
          'created_at': now,
          'updated_at': now,
        });
      }
    });
    log?.call(
      'import namespace=$namespace collection=$name imported=${rows.length} path=$target',
    );
    return <String, dynamic>{
      'ok': true,
      'namespace': namespace,
      'collection': name,
      'imported': rows.length,
      'path': target,
    };
  }

  /// 每个集合的条目数 / schema_version / 库文件字节数与路径（只读）。
  Future<Map<String, dynamic>> stats({
    required String teamId,
    required String namespace,
  }) async {
    final String path = databasePath(teamId: teamId, namespace: namespace);
    final Database database = await _database(teamId, namespace);
    final List<RecordSnapshot<String, Map<String, Object?>>> metas = await _meta
        .find(database);
    final Set<String> names = <String>{
      for (final String name in getNonEmptyStoreNames(database))
        if (name != metaStore) name,
      for (final RecordSnapshot<String, Map<String, Object?>> meta in metas)
        meta.key,
    };
    final List<String> ordered = names.toList()..sort();
    final List<Map<String, dynamic>> collections = <Map<String, dynamic>>[];
    for (final String name in ordered) {
      int schemaVersion = 0;
      for (final RecordSnapshot<String, Map<String, Object?>> meta in metas) {
        if (meta.key != name) continue;
        schemaVersion = _asInt(meta.value['schema_version'], 0);
        break;
      }
      collections.add(<String, dynamic>{
        'collection': name,
        'count': await storeOf(name).count(database),
        'schema_version': schemaVersion,
      });
    }
    final File file = File(path);
    final int bytes = file.existsSync() ? file.lengthSync() : 0;
    return <String, dynamic>{
      'ok': true,
      'namespace': namespace,
      'path': path,
      'bytes': bytes,
      'collections': collections,
    };
  }

  /// 关闭并重开该库触发检查点（失败不影响后续读，错误可读）。
  Future<Map<String, dynamic>> compact({
    required String teamId,
    required String namespace,
  }) async {
    final String path = databasePath(teamId: teamId, namespace: namespace);
    final String key = p.dirname(path);
    final Future<Database>? cached = _databases.remove(key);
    try {
      if (cached != null) await (await cached).close();
      await _database(teamId, namespace);
      final File file = File(path);
      final int bytes = file.existsSync() ? file.lengthSync() : 0;
      log?.call('compact namespace=$namespace path=$path bytes=$bytes');
      return <String, dynamic>{
        'ok': true,
        'namespace': namespace,
        'path': path,
        'compacted': true,
        'bytes': bytes,
      };
    } catch (error) {
      _databases.remove(key);
      log?.call('compact 失败：$error');
      return <String, dynamic>{
        'ok': true,
        'namespace': namespace,
        'path': path,
        'compacted': false,
        'error': '$error',
      };
    }
  }

  /// 删除本命名空间的库文件与空目录（必须 `confirm:true`；ST-5 / TC-ST-07）。
  Future<Map<String, dynamic>> purge({
    required String teamId,
    required String namespace,
    required bool confirm,
  }) async {
    if (!confirm) {
      throw StorageFailure(
        'storage.purge 必须显式传 confirm:true',
        code: 'confirmation_required',
      );
    }
    final String path = databasePath(teamId: teamId, namespace: namespace);
    final String key = p.dirname(path);
    final Future<Database>? cached = _databases.remove(key);
    if (cached != null) {
      try {
        await (await cached).close();
      } catch (error) {
        log?.call('purge 关闭库失败：$error');
      }
    }
    final List<String> removed = <String>[];
    final File file = File(path);
    if (file.existsSync()) {
      await file.delete();
      removed.add(path);
    }
    String dir = p.dirname(path);
    final String storageRoot = p.join(dataRoot, 'storage');
    while (p.isWithin(storageRoot, dir)) {
      final Directory directory = Directory(dir);
      if (!directory.existsSync() || directory.listSync().isNotEmpty) break;
      try {
        directory.deleteSync();
        removed.add(dir);
      } catch (_) {
        break;
      }
      dir = p.dirname(dir);
    }
    log?.call(
      'purge namespace=$namespace path=$path removed=${removed.length}',
    );
    return <String, dynamic>{
      'ok': true,
      'namespace': namespace,
      'path': path,
      'purged': true,
      'removed': removed,
    };
  }

  Future<Map<String, dynamic>> _applyTxOp(
    Transaction txn,
    _TxOp operation,
  ) async {
    final StoreRef<String, Map<String, Object?>> store = storeOf(
      operation.collection,
    );
    final Map<String, Object?>? existing = await store
        .record(operation.key)
        .get(txn);
    final int current = _asInt(existing?['rev'], 0);
    if (operation.ifRev != null && operation.ifRev != current) {
      throw StorageFailure(
        'rev 冲突：key=${operation.key} 期望 if_rev=${operation.ifRev}，实际 rev=$current',
        code: 'rev_conflict',
      );
    }
    if (operation.op == 'delete') {
      if (existing == null) {
        return <String, dynamic>{
          'index': operation.index,
          'op': 'delete',
          'key': operation.key,
          'deleted': false,
        };
      }
      await store.record(operation.key).delete(txn);
      return <String, dynamic>{
        'index': operation.index,
        'op': 'delete',
        'key': operation.key,
        'deleted': true,
      };
    }
    final int next = current + 1;
    await store.record(operation.key).put(txn, <String, Object?>{
      'rev': next,
      'value': operation.value,
    });
    return <String, dynamic>{
      'index': operation.index,
      'op': 'put',
      'key': operation.key,
      'rev': next,
    };
  }

  List<_ImportRow> _parseRows(List<int> bytes) {
    final List<String> lines = utf8.decode(bytes).split('\n');
    // NDJSON 末尾的换行不算一条空行。
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    final List<_ImportRow> rows = <_ImportRow>[];
    for (int index = 0; index < lines.length; index++) {
      final String line = lines[index];
      if (line.trim().isEmpty) {
        throw StorageFailure(
          'data.ndjson 第 ${index + 1} 行为空行',
          code: 'import_invalid',
        );
      }
      try {
        final Object? decoded = json.decode(line);
        if (decoded is! Map) throw const FormatException('行不是对象');
        final Map<String, dynamic> record = decoded.map(
          (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
        );
        rows.add(
          _ImportRow(
            key: _keyOf(record['key']),
            rev: _asInt(record['rev'], 0),
            value: _requireValue(record['value']),
          ),
        );
      } catch (error) {
        throw StorageFailure(
          'data.ndjson 第 ${index + 1} 行非法：$error',
          code: 'import_invalid',
        );
      }
    }
    return rows;
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

  /// 过滤条件规范化：去掉 null 值并按 key 排序（cursor fingerprint 要稳定）。
  static Map<String, dynamic> _canonicalFilter(Map<String, dynamic> filter) {
    final List<String> keys = filter.keys.toList()..sort();
    return <String, dynamic>{
      for (final String key in keys)
        if (filter[key] != null) key: filter[key],
    };
  }

  static String _queryFingerprint(
    String collection,
    Map<String, dynamic> filter,
    String sort,
    bool descending,
  ) {
    final String raw = json.encode(<String, Object?>{
      'collection': collection,
      'filter': _canonicalFilter(filter),
      'sort': sort,
      'descending': descending,
    });
    return sha256.convert(utf8.encode(raw)).toString();
  }

  static String _encodeCursor(int offset, String fingerprint) {
    final String raw = json.encode(<String, Object?>{
      'offset': offset,
      'fingerprint': fingerprint,
    });
    return base64Url.encode(utf8.encode(raw)).replaceAll('=', '');
  }

  static int _offsetFromCursor(String cursor, String fingerprint) {
    if (cursor.trim().isEmpty) return 0;
    Map<String, dynamic> payload;
    try {
      final List<int> bytes = base64Url.decode(base64Url.normalize(cursor));
      final Object? decoded = json.decode(utf8.decode(bytes));
      if (decoded is! Map) throw const FormatException('cursor 不是对象');
      payload = decoded.map(
        (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
      );
    } catch (_) {
      throw StorageFailure('cursor 非法（不是本插件签发的游标）', code: 'invalid_cursor');
    }
    final Object? rawOffset = payload['offset'];
    final Object? rawFingerprint = payload['fingerprint'];
    if (rawOffset is! num || rawFingerprint is! String) {
      throw StorageFailure(
        'cursor 缺少 offset / fingerprint',
        code: 'invalid_cursor',
      );
    }
    final int offset = rawOffset.toInt();
    if (offset < 0) {
      throw StorageFailure(
        'cursor.offset 不能为负：$offset',
        code: 'invalid_cursor',
      );
    }
    if (rawFingerprint != fingerprint) {
      throw StorageFailure(
        'cursor 与本次查询条件不匹配（collection/filter/sort/descending）',
        code: 'cursor_mismatch',
      );
    }
    return offset;
  }

  static Future<void> _atomicWrite(String path, List<int> bytes) async {
    final File temp = File('$path.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    try {
      await temp.rename(path);
    } catch (_) {
      // Windows 上目标已存在时 rename 会失败：先删再改名。
      final File target = File(path);
      if (await target.exists()) await target.delete();
      await temp.rename(path);
    }
  }

  static String _stamp(DateTime utc) =>
      utc.toIso8601String().replaceAll(RegExp(r'[-:.]'), '');

  static String _text(Object? raw) => (raw ?? '').toString().trim();

  static Map<String, dynamic> _requireValue(Object? raw) {
    if (raw is Map) {
      return raw.map(
        (Object? key, Object? value) =>
            MapEntry<String, dynamic>(key.toString(), value),
      );
    }
    throw StorageFailure('value 必须是 JSON 对象', code: 'invalid_arguments');
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

  static int _asInt(Object? raw, int fallback) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim()) ?? fallback;
    return fallback;
  }
}

/// tx 中解析后的一项 op。
class _TxOp {
  const _TxOp({
    required this.index,
    required this.op,
    required this.collection,
    required this.key,
    required this.value,
    required this.ifRev,
  });

  final int index;
  final String op;
  final String collection;
  final String key;
  final Map<String, dynamic>? value;
  final int? ifRev;
}

/// 导入时解析出的一行。
class _ImportRow {
  const _ImportRow({required this.key, required this.rev, required this.value});

  final String key;
  final int rev;
  final Map<String, dynamic> value;
}

/// 事务内部失败：带上第几项，事务回滚后转成 `tx_failed`。
class _TxOpFailure implements Exception {
  _TxOpFailure(this.index, this.cause);

  final int index;
  final Object cause;

  @override
  String toString() => '第 $index 项：$cause';
}
