import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_docnorm/tree_docnorm.dart';

/// DN-9：`docnorm.export` JSONL 快照（排序、幂等、可 diff）。
void main() {
  late Directory temp;
  late FakeStorage storage;
  late String repoKey;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_docnorm_export_');
    storage = FakeStorage();
    repoKey = repoKeyOf(temp.path);
    storage.db['pkg_index'] = <String, Map<String, Object?>>{
      '$repoKey#pkg:b': <String, Object?>{'schema': 1, 'zeta': 1, 'alpha': 2},
      '$repoKey#pkg:a': <String, Object?>{'schema': 1, 'beta': 2, 'alpha': 1},
    };
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  File exportFile(String collection) =>
      File(p.join(temp.path, '.docnorm', 'export', '$collection.jsonl'));

  test('dry-run 只报计划；commit 写排序后的 JSONL；重复运行 0 写', () async {
    final Map<String, Object?> dry = await runExport(
      temp.path,
      storage: storage.call,
    );
    expect(dry['dry_run'], true);
    expect(
      (dry['would_write'] as List<dynamic>).cast<String>(),
      contains('.docnorm/export/pkg_index.jsonl'),
    );
    expect(exportFile('pkg_index').existsSync(), false);

    final Map<String, Object?> commit = await runExport(
      temp.path,
      storage: storage.call,
      commit: true,
    );
    expect(
      (commit['written'] as List<dynamic>).cast<String>(),
      contains('.docnorm/export/pkg_index.jsonl'),
    );
    final List<String> lines = exportFile('pkg_index')
        .readAsLinesSync()
        .where((String line) => line.isNotEmpty)
        .toList();
    expect(lines.length, 2);
    expect(
      lines.first,
      jsonEncode(<String, Object?>{'alpha': 1, 'beta': 2, 'schema': 1}),
      reason: '按 key 排序 + Map 键排序 ⇒ 可直接 diff',
    );
    expect(exportFile('doc_contract').existsSync(), false, reason: '空集合不落文件');

    final Map<String, Object?> again = await runExport(
      temp.path,
      storage: storage.call,
      commit: true,
    );
    expect((again['written'] as List<dynamic>), isEmpty);
    expect(
      (again['collections'] as Map<String, Object?>)['pkg_index'],
      containsPair('status', 'unchanged'),
    );
  });

  test('内容变化后标记 changed 并覆盖写', () async {
    await runExport(temp.path, storage: storage.call, commit: true);
    storage.db['pkg_index']!['$repoKey#pkg:a'] = <String, Object?>{
      'schema': 1,
      'beta': 3,
      'alpha': 1,
    };
    final Map<String, Object?> changed = await runExport(
      temp.path,
      storage: storage.call,
    );
    expect(
      (changed['collections'] as Map<String, Object?>)['pkg_index'],
      containsPair('status', 'changed'),
    );
    await runExport(temp.path, storage: storage.call, commit: true);
    expect(exportFile('pkg_index').readAsStringSync(), contains('"beta":3'));
  });

  test('仓库不存在 ⇒ repo_not_found', () async {
    try {
      await runExport(p.join(temp.path, 'missing'), storage: storage.call);
      fail('应当 fail-closed');
    } on BaselineFailure catch (error) {
      expect(error.code, 'repo_not_found');
    }
  });
}

class FakeStorage {
  final Map<String, Map<String, Map<String, Object?>>> db =
      <String, Map<String, Map<String, Object?>>>{};

  Future<Map<String, dynamic>> call(
    String command,
    Map<String, dynamic> arguments,
  ) async {
    final String collection = '${arguments['collection'] ?? ''}';
    final Map<String, Map<String, Object?>> records =
        db[collection] ?? <String, Map<String, Object?>>{};
    switch (command) {
      case 'storage.scan':
        final String prefix = '${arguments['prefix'] ?? ''}';
        final List<Map<String, Object?>> values = <Map<String, Object?>>[
          for (final MapEntry<String, Map<String, Object?>> entry
              in records.entries)
            if (entry.key.startsWith(prefix))
              <String, Object?>{
                'key': entry.key,
                'value': entry.value,
                'rev': 1,
              },
        ];
        return <String, dynamic>{'values': values, 'count': values.length};
      default:
        throw StateError('未知存储命令：$command');
    }
  }
}
