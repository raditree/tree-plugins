import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'baseline.dart';

/// `docnorm.export [--commit]`：把 `tree.storage` 里的集合导成
/// `.docnorm/export/<collection>.jsonl` 快照（DN-9）。
///
/// 口径（D9 / §4.6）：
/// - DB 是真源，JSONL 只是快照；不反向导入；
/// - 记录按 key 排序、Map 键排序后编码 ⇒ 同一内容重复导出**字节相同**，可直接 diff；
/// - 默认 dry-run，只报 `new / changed / unchanged`；`--commit` 才写文件；
/// - 只写 `<repo>/.docnorm/export/`，不碰仓内其它路径。
Future<Map<String, Object?>> runExport(
  String repo, {
  required StorageCall storage,
  bool commit = false,
  String runId = '',
  List<String> collections = const <String>[],
}) async {
  final Directory dir = Directory(repo);
  if (!await dir.exists()) {
    throw BaselineFailure('仓库目录不存在：$repo', code: 'repo_not_found');
  }
  final String root = p.normalize(p.absolute(repo));
  final String repoKey = repoKeyOf(root);
  final DocStore store = DocStore(storage);
  final List<String> targets;
  if (collections.isEmpty) {
    targets = List<String>.of(DocStore.collections);
  } else {
    targets = <String>{
      for (final String name in collections)
        if (name.trim().isNotEmpty) name.trim(),
    }.toList()..sort();
  }

  final Map<String, Object?> summary = <String, Object?>{};
  final List<String> wouldWrite = <String>[];
  final List<String> written = <String>[];
  int totalRecords = 0;

  for (final String collection in targets) {
    final List<StoredRecord> records =
        await store.listAll(collection, '$repoKey#')
          ..sort((StoredRecord a, StoredRecord b) => a.key.compareTo(b.key));
    final String path = '.docnorm/export/$collection.jsonl';
    final String content = records.isEmpty
        ? ''
        : '${records.map((StoredRecord record) => jsonEncode(_canonical(record.value))).join('\n')}\n';
    final File file = File(p.joinAll(<String>[root, ...path.split('/')]));
    final bool exists = file.existsSync();
    final String before = exists ? file.readAsStringSync() : '';
    final String status = records.isEmpty && !exists
        ? 'unchanged'
        : (!exists ? 'new' : (before == content ? 'unchanged' : 'changed'));
    totalRecords += records.length;
    if (status != 'unchanged') {
      wouldWrite.add(path);
      if (commit) {
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(content);
        written.add(path);
      }
    }
    summary[collection] = <String, Object?>{
      'path': path,
      'records': records.length,
      'bytes': content.length,
      'status': status,
    };
  }

  wouldWrite.sort();
  written.sort();
  return <String, Object?>{
    'command': 'docnorm.export',
    'repo': root,
    'repo_key': repoKey,
    'run_id': runId.trim(),
    'dry_run': !commit,
    'collections': summary,
    'counts': <String, Object?>{
      'collections': targets.length,
      'records': totalRecords,
      'would_write': wouldWrite.length,
      'written': written.length,
      'unchanged': targets.length - wouldWrite.length,
    },
    'would_write': wouldWrite,
    'written': written,
    'notes': <String>[
      'DB 是真源，JSONL 只是快照；导出不反向导入',
      '记录按 key 排序、Map 键排序 ⇒ 同内容重复导出字节相同，可直接 diff',
      '默认 dry-run；--commit 才写 .docnorm/export/（不碰仓内其它路径）',
    ],
  };
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final List<String> keys =
        value.keys.map((Object? key) => key.toString()).toList()..sort();
    return <String, Object?>{
      for (final String key in keys) key: _canonical(value[key]),
    };
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}
