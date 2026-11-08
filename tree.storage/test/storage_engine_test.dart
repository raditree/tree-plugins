import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_storage/tree_storage.dart';

/// ST-1：单库 CRUD 引擎（ensure / put / get / delete / query + safeSegment）。
///
/// 路径口径：`<data_root>/storage/<team_id>/<namespace>/data.semdb`
/// （实例粒度 team，多团队不得撞同一个库文件）。
void main() {
  const String team = 'team_a';
  late Directory temp;
  late StorageEngine engine;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_storage_engine_');
    engine = StorageEngine(dataRoot: temp.path);
  });

  tearDown(() async {
    await engine.close();
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('建库路径：每团队 × 每命名空间一个库，目录与文件名按 safeSegment', () {
    expect(
      engine.databasePath(teamId: team, namespace: 'tree.docnorm'),
      p.join(temp.path, 'storage', team, 'tree.docnorm', 'data.semdb'),
    );
    expect(
      engine.databasePath(teamId: 'team_b', namespace: 'tree.docnorm'),
      isNot(engine.databasePath(teamId: team, namespace: 'tree.docnorm')),
    );
    expect(
      () => engine.databasePath(teamId: '', namespace: 'ns'),
      throwsA(isA<StorageFailure>()),
    );
  });

  test('CRUD 往返：rev 单调、删除幂等、不存在取回 null', () async {
    Map<String, dynamic> result = await engine.put(
      teamId: team,
      namespace: 'ns',
      collection: 'items',
      key: 'k1',
      value: <String, dynamic>{'name': '一', 'n': 1},
    );
    expect(result['rev'], 1);
    result = await engine.put(
      teamId: team,
      namespace: 'ns',
      collection: 'items',
      key: 'k1',
      value: <String, dynamic>{'name': '一（改）', 'n': 2},
    );
    expect(result['rev'], 2);

    final Map<String, dynamic> got = await engine.get(
      teamId: team,
      namespace: 'ns',
      collection: 'items',
      key: 'k1',
    );
    expect(got['value'], <String, dynamic>{'name': '一（改）', 'n': 2});
    expect(got['rev'], 2);

    expect(
      (await engine.get(
        teamId: team,
        namespace: 'ns',
        collection: 'items',
        key: 'none',
      ))['value'],
      isNull,
    );
    expect(
      (await engine.delete(
        teamId: team,
        namespace: 'ns',
        collection: 'items',
        key: 'none',
      ))['deleted'],
      isFalse,
    );
    expect(
      (await engine.delete(
        teamId: team,
        namespace: 'ns',
        collection: 'items',
        key: 'k1',
      ))['deleted'],
      isTrue,
    );
    expect(
      (await engine.get(
        teamId: team,
        namespace: 'ns',
        collection: 'items',
        key: 'k1',
      ))['value'],
      isNull,
    );
  });

  test('ensure：更高版本可升、降级拒绝、同版本幂等', () async {
    expect(
      (await engine.ensure(
        teamId: team,
        namespace: 'ns',
        collection: 'docs',
        schemaVersion: 2,
      ))['schema_version'],
      2,
    );
    await expectLater(
      engine.ensure(
        teamId: team,
        namespace: 'ns',
        collection: 'docs',
        schemaVersion: 1,
      ),
      throwsA(
        isA<StorageFailure>().having(
          (StorageFailure e) => e.code,
          'code',
          'schema_version_conflict',
        ),
      ),
    );
    expect(
      (await engine.ensure(
        teamId: team,
        namespace: 'ns',
        collection: 'docs',
        schemaVersion: 2,
      ))['schema_version'],
      2,
    );
    await expectLater(
      engine.ensure(
        teamId: team,
        namespace: 'ns',
        collection: 'docs',
        schemaVersion: 0,
      ),
      throwsA(
        isA<StorageFailure>().having(
          (StorageFailure e) => e.code,
          'code',
          'invalid_arguments',
        ),
      ),
    );
  });

  test('query：等值过滤 + 排序 + 分页 + limit 上限', () async {
    for (final (String key, String tag, int n) in <(String, String, int)>[
      ('a', 'reuse', 1),
      ('b', 'reuse', 3),
      ('c', 'split', 2),
    ]) {
      await engine.put(
        teamId: team,
        namespace: 'ns',
        collection: 'items',
        key: key,
        value: <String, dynamic>{'tag': tag, 'n': n},
      );
    }
    final Map<String, dynamic> page = await engine.query(
      teamId: team,
      namespace: 'ns',
      collection: 'items',
      filter: <String, dynamic>{'tag': 'reuse'},
      sort: 'n',
      descending: true,
      limit: 1,
    );
    expect(page['count'], 1);
    expect(keysOf(page), <String>['b']);

    final Map<String, dynamic> capped = await engine.query(
      teamId: team,
      namespace: 'ns',
      collection: 'items',
      limit: 9999,
    );
    expect(capped['limit'], 500);
    expect(capped['count'], 3);

    final Map<String, dynamic> empty = await engine.query(
      teamId: team,
      namespace: 'ns',
      collection: 'anything',
    );
    expect(empty['count'], 0);
  });

  test('命名空间隔离：同团队内两个 namespace 各自一库，互不可见', () async {
    await engine.put(
      teamId: team,
      namespace: 'ns_a',
      collection: 'items',
      key: 'same',
      value: <String, dynamic>{'who': 'a'},
    );
    await engine.put(
      teamId: team,
      namespace: 'ns_b',
      collection: 'items',
      key: 'same',
      value: <String, dynamic>{'who': 'b'},
    );
    expect(
      (await engine.get(
        teamId: team,
        namespace: 'ns_a',
        collection: 'items',
        key: 'same',
      ))['value'],
      <String, dynamic>{'who': 'a'},
    );
    expect(
      (await engine.get(
        teamId: team,
        namespace: 'ns_b',
        collection: 'items',
        key: 'same',
      ))['value'],
      <String, dynamic>{'who': 'b'},
    );
    expect(
      File(engine.databasePath(teamId: team, namespace: 'ns_a')).existsSync(),
      isTrue,
    );
    expect(
      File(engine.databasePath(teamId: team, namespace: 'ns_b')).existsSync(),
      isTrue,
    );
  });

  test('TC-ST-13：两个团队各写各的库文件（同 namespace 不互相覆盖）', () async {
    await engine.put(
      teamId: 'team_a',
      namespace: 'ns',
      collection: 'items',
      key: 'same',
      value: <String, dynamic>{'who': 'a'},
    );
    await engine.put(
      teamId: 'team_b',
      namespace: 'ns',
      collection: 'items',
      key: 'same',
      value: <String, dynamic>{'who': 'b'},
    );
    expect(
      (await engine.get(
        teamId: 'team_a',
        namespace: 'ns',
        collection: 'items',
        key: 'same',
      ))['value'],
      <String, dynamic>{'who': 'a'},
    );
    expect(
      (await engine.get(
        teamId: 'team_b',
        namespace: 'ns',
        collection: 'items',
        key: 'same',
      ))['value'],
      <String, dynamic>{'who': 'b'},
    );

    final String a = engine.databasePath(teamId: 'team_a', namespace: 'ns');
    final String b = engine.databasePath(teamId: 'team_b', namespace: 'ns');
    expect(a, isNot(b));
    expect(File(a).existsSync(), isTrue);
    expect(File(b).existsSync(), isTrue);
  });

  test('持久化：关闭后重开，已提交数据可读', () async {
    await engine.put(
      teamId: team,
      namespace: 'ns',
      collection: 'items',
      key: 'k1',
      value: <String, dynamic>{'v': 1},
    );
    await engine.close();
    final StorageEngine reopened = StorageEngine(dataRoot: temp.path);
    try {
      final Map<String, dynamic> got = await reopened.get(
        teamId: team,
        namespace: 'ns',
        collection: 'items',
        key: 'k1',
      );
      expect(got['value'], <String, dynamic>{'v': 1});
      expect(got['rev'], 1);
    } finally {
      await reopened.close();
    }
  });

  test('非法名：空 / . / .. / 路径穿越字符 / 保留前缀 __ 全部拒绝', () async {
    for (final String collection in <String>[
      '',
      '.',
      '..',
      'a/b',
      'a b',
      '__meta',
    ]) {
      await expectLater(
        engine.ensure(teamId: team, namespace: 'ns', collection: collection),
        throwsA(
          isA<StorageFailure>().having(
            (StorageFailure e) => e.code,
            'code',
            'invalid_arguments',
          ),
        ),
        reason: 'collection=$collection',
      );
    }
    await expectLater(
      engine.put(
        teamId: team,
        namespace: 'ns',
        collection: 'items',
        key: '  ',
        value: <String, dynamic>{},
      ),
      throwsA(isA<StorageFailure>()),
    );
  });

  test('safeSegment 与核心同口径', () {
    expect(safeSegment('tree.docnorm', what: 'namespace'), 'tree.docnorm');
    expect(safeSegment('a-b_c.1', what: 'namespace'), 'a-b_c.1');
    for (final String bad in <String>['', '.', '..', 'a/b', 'a b', 'a\\b']) {
      expect(
        () => safeSegment(bad, what: 'namespace'),
        throwsA(isA<StorageFailure>()),
        reason: 'segment=$bad',
      );
    }
  });
}

/// 从 query 回包里取 key 列表（断言用）。
List<String> keysOf(Map<String, dynamic> page) => <String>[
  for (final Object? item in (page['values'] as List<dynamic>? ?? <dynamic>[]))
    '${(item as Map<dynamic, dynamic>)['key']}',
];
