/// 逻辑去重的 storage 封装：统一 `binding: plugin`，按 `<repoKey>#` 前缀归属。
///
/// 与 `tree.docnorm` 的 `DocStore` 同口径：scan 单页 5000；超出时改用
/// `query sort:'id'` 500/页翻页；tx 按 200 条切片。集合 schema 版本都是 1。
library;

import 'models.dart';

/// 下站的 storage 调用（由插件接线注入；测试可换假实现）。
typedef DedupStorageCall =
    Future<Map<String, dynamic>> Function(
      String command,
      Map<String, dynamic> arguments,
    );

const List<String> kDedupCollections = <String>[
  'dedup_files',
  'dedup_chunks',
  'dedup_vectors',
  'dedup_results',
  'dedup_meta',
];

const int _kScanLimit = 5000;
const int _kQueryLimit = 500;
const int _kTxOps = 200;

class StoredRecord {
  const StoredRecord(this.key, this.value);

  final String key;
  final Map<String, Object?> value;
}

class DedupStore {
  DedupStore(this.call);

  final DedupStorageCall call;

  Future<void> ensureAll() async {
    for (final String collection in kDedupCollections) {
      await _invoke('storage.ensure', <String, dynamic>{
        'collection': collection,
        'schema_version': 1,
      });
    }
  }

  /// 按 key 前缀读全量（scan 5000 + query 翻页兜底）。
  Future<List<StoredRecord>> listAll(String collection, String prefix) async {
    final Map<String, StoredRecord> records = <String, StoredRecord>{};
    final Map<String, dynamic> first = await _invoke('storage.scan', <String, dynamic>{
      'collection': collection,
      'prefix': prefix,
      'limit': _kScanLimit,
    });
    _collect(first, prefix, records);
    if (first['has_more'] == true) {
      String cursor = '';
      do {
        final Map<String, dynamic> page = await _invoke(
          'storage.query',
          <String, dynamic>{
            'collection': collection,
            'sort': 'id',
            'limit': _kQueryLimit,
            if (cursor.isNotEmpty) 'cursor': cursor,
          },
        );
        _collect(page, prefix, records);
        cursor = '${page['cursor'] ?? ''}';
        if (page['has_more'] != true) break;
      } while (cursor.isNotEmpty);
    }
    final List<StoredRecord> out = records.values.toList()
      ..sort((StoredRecord a, StoredRecord b) => a.key.compareTo(b.key));
    return out;
  }

  Future<void> put(String collection, String key, Map<String, Object?> value) {
    return _invoke('storage.put', <String, dynamic>{
      'collection': collection,
      'key': key,
      'value': value,
    });
  }

  Future<Map<String, Object?>?> get(String collection, String key) async {
    final Map<String, dynamic> result = await _invoke('storage.get', <String, dynamic>{
      'collection': collection,
      'key': key,
    });
    final Object? value = result['value'];
    if (value is! Map) return null;
    return value.map(
      (Object? k, Object? v) => MapEntry<String, Object?>('$k', v),
    );
  }

  Future<void> delete(String collection, String key) {
    return _invoke('storage.delete', <String, dynamic>{
      'collection': collection,
      'key': key,
    });
  }

  /// tx 按 200 条切片；调用方保证每条 value ≤ 1 MiB。
  Future<void> tx(List<Map<String, Object?>> ops) async {
    for (int start = 0; start < ops.length; start += _kTxOps) {
      final int end = start + _kTxOps > ops.length ? ops.length : start + _kTxOps;
      await _invoke('storage.tx', <String, dynamic>{
        'ops': ops.sublist(start, end),
      });
    }
  }

  /// 前缀删除（重建 / 清理用）：先读全量，再按 tx 分批 delete。
  Future<int> deletePrefix(String collection, String prefix) async {
    final List<StoredRecord> records = await listAll(collection, prefix);
    if (records.isEmpty) return 0;
    await tx(<Map<String, Object?>>[
      for (final StoredRecord record in records)
        <String, Object?>{
          'op': 'delete',
          'collection': collection,
          'key': record.key,
        },
    ]);
    return records.length;
  }

  Future<Map<String, dynamic>> _invoke(
    String command,
    Map<String, dynamic> arguments,
  ) async {
    try {
      final Map<String, dynamic> result = await call(command, <String, dynamic>{
        ...arguments,
        'binding': 'plugin',
      });
      if (result['ok'] == false || result['error'] != null) {
        throw ProductionFailure(
          '${result['error'] ?? '存储命令失败：$command'}',
          code: '${result['code'] ?? 'storage_error'}',
        );
      }
      return result;
    } catch (error) {
      if (error is ProductionFailure) rethrow;
      throw ProductionFailure('存储通道不可用：$error', code: 'storage_unavailable');
    }
  }

  static void _collect(
    Map<String, dynamic> page,
    String prefix,
    Map<String, StoredRecord> out,
  ) {
    for (final Object? raw in (page['values'] as List<dynamic>? ?? const [])) {
      if (raw is! Map) continue;
      final String key = '${raw['key'] ?? ''}';
      if (key.isEmpty || !key.startsWith(prefix)) continue;
      final Object? value = raw['value'];
      if (value is! Map) continue;
      out[key] = StoredRecord(
        key,
        value.map(
          (Object? k, Object? v) => MapEntry<String, Object?>('$k', v),
        ),
      );
    }
  }
}
