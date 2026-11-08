import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_storage/tree_storage.dart';

/// ST-1~ST-5：单库 CRUD / CAS / cursor / tx / 导入导出 / 维护。
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

  test('scan：按 key 排序 + 前缀过滤 + limit；count 与 query 同过滤', () async {
    for (final (String key, String tag) in <(String, String)>[
      ('sug-01', 'reuse'),
      ('sug-02', 'reuse'),
      ('doc-01', 'split'),
    ]) {
      await engine.put(
        teamId: team,
        namespace: 'ns',
        collection: 'items',
        key: key,
        value: <String, dynamic>{'tag': tag},
      );
    }
    final Map<String, dynamic> scanned = await engine.scan(
      teamId: team,
      namespace: 'ns',
      collection: 'items',
      prefix: 'sug-',
      limit: 1,
    );
    expect(keysOf(scanned), <String>['sug-01']);
    expect(scanned['has_more'], true, reason: '前缀下还有 sug-02');

    final Map<String, dynamic> all = await engine.scan(
      teamId: team,
      namespace: 'ns',
      collection: 'items',
    );
    expect(keysOf(all), <String>['doc-01', 'sug-01', 'sug-02']);
    expect(all['has_more'], false);

    final Map<String, dynamic> reuse = await engine.count(
      teamId: team,
      namespace: 'ns',
      collection: 'items',
      filter: <String, dynamic>{'tag': 'reuse'},
    );
    expect(reuse['count'], 2);
    final Map<String, dynamic> split = await engine.count(
      teamId: team,
      namespace: 'ns',
      collection: 'items',
      filter: <String, dynamic>{'tag': 'split'},
    );
    expect(split['count'], 1);
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

  test('TC-ST-02：if_rev 匹配才写，冲突不覆盖且信息带 expected/actual', () async {
    await engine.put(
      teamId: team,
      namespace: 'ns',
      collection: 'items',
      key: 'k',
      value: <String, dynamic>{'v': 1},
    );
    final Map<String, dynamic> updated = await engine.put(
      teamId: team,
      namespace: 'ns',
      collection: 'items',
      key: 'k',
      value: <String, dynamic>{'v': 2},
      ifRev: 1,
    );
    expect(updated['rev'], 2);
    await expectLater(
      engine.put(
        teamId: team,
        namespace: 'ns',
        collection: 'items',
        key: 'k',
        value: <String, dynamic>{'v': 3},
        ifRev: 1,
      ),
      throwsA(
        isA<StorageFailure>()
            .having((StorageFailure e) => e.code, 'code', 'rev_conflict')
            .having(
              (StorageFailure e) => e.message,
              'message',
              allOf(contains('if_rev=1'), contains('rev=2')),
            ),
      ),
    );
    expect(
      (await engine.get(
        teamId: team,
        namespace: 'ns',
        collection: 'items',
        key: 'k',
      ))['value'],
      <String, dynamic>{'v': 2},
    );
    // 不存在的记录 rev=0：if_rev=0 可以新建。
    final Map<String, dynamic> created = await engine.put(
      teamId: team,
      namespace: 'ns',
      collection: 'items',
      key: 'fresh',
      value: <String, dynamic>{'v': 1},
      ifRev: 0,
    );
    expect(created['rev'], 1);
  });

  test('TC-ST-03：tx 任一 op 失败整批回滚；成功时 committed + 逐项结果', () async {
    await expectLater(
      engine.tx(
        teamId: team,
        namespace: 'ns',
        ops: <Map<String, dynamic>>[
          <String, dynamic>{
            'op': 'put',
            'collection': 'items',
            'key': 'ok',
            'value': <String, dynamic>{'v': 1},
          },
          <String, dynamic>{
            'op': 'put',
            'collection': 'items',
            'key': 'bad',
            'value': <String, dynamic>{'v': 2},
            'if_rev': 9,
          },
        ],
      ),
      throwsA(
        isA<StorageFailure>()
            .having((StorageFailure e) => e.code, 'code', 'tx_failed')
            .having(
              (StorageFailure e) => e.message,
              'message',
              contains('第 1 项'),
            ),
      ),
    );
    expect(
      (await engine.get(
        teamId: team,
        namespace: 'ns',
        collection: 'items',
        key: 'ok',
      ))['value'],
      isNull,
      reason: '整批回滚后不应留下半截数据',
    );

    final Map<String, dynamic> committed = await engine.tx(
      teamId: team,
      namespace: 'ns',
      ops: <Map<String, dynamic>>[
        <String, dynamic>{
          'op': 'put',
          'collection': 'items',
          'key': 'a',
          'value': <String, dynamic>{'n': 1},
        },
        <String, dynamic>{
          'op': 'put',
          'collection': 'items',
          'key': 'b',
          'value': <String, dynamic>{'n': 2},
        },
        <String, dynamic>{'op': 'delete', 'collection': 'items', 'key': 'a'},
        <String, dynamic>{'op': 'delete', 'collection': 'items', 'key': 'none'},
      ],
    );
    expect(committed['committed'], isTrue);
    expect((committed['results'] as List<dynamic>).length, 4);
    expect(
      (await engine.get(
        teamId: team,
        namespace: 'ns',
        collection: 'items',
        key: 'b',
      ))['value'],
      <String, dynamic>{'n': 2},
    );
    expect(
      (await engine.get(
        teamId: team,
        namespace: 'ns',
        collection: 'items',
        key: 'a',
      ))['value'],
      isNull,
    );
  });

  test('TC-ST-04：120 条 cursor 翻页无重复无丢条；非法/错配游标有码', () async {
    final List<Map<String, dynamic>> ops = <Map<String, dynamic>>[
      for (int i = 0; i < 120; i++)
        <String, dynamic>{
          'op': 'put',
          'collection': 'pages',
          'key': 'k${i.toString().padLeft(3, '0')}',
          'value': <String, dynamic>{'n': i},
        },
    ];
    await engine.tx(teamId: team, namespace: 'ns', ops: ops);

    final List<String> seen = <String>[];
    String cursor = '';
    int pages = 0;
    do {
      final Map<String, dynamic> page = await engine.query(
        teamId: team,
        namespace: 'ns',
        collection: 'pages',
        limit: 7,
        cursor: cursor,
      );
      seen.addAll(keysOf(page));
      cursor = page['cursor'] as String;
      pages++;
    } while (cursor.isNotEmpty && pages < 100);

    expect(seen.length, 120, reason: '翻页不能丢条');
    expect(seen.toSet().length, 120, reason: '翻页不能重复');
    expect(pages, 18);
    expect(
      (await engine.query(
        teamId: team,
        namespace: 'ns',
        collection: 'pages',
        limit: 500,
      ))['cursor'],
      '',
      reason: '没有下一页时 cursor 为空串',
    );

    await expectLater(
      engine.query(
        teamId: team,
        namespace: 'ns',
        collection: 'pages',
        limit: 7,
        cursor: 'not-a-cursor',
      ),
      throwsA(
        isA<StorageFailure>().having(
          (StorageFailure e) => e.code,
          'code',
          'invalid_cursor',
        ),
      ),
    );

    final Map<String, dynamic> first = await engine.query(
      teamId: team,
      namespace: 'ns',
      collection: 'pages',
      limit: 7,
    );
    await expectLater(
      engine.query(
        teamId: team,
        namespace: 'ns',
        collection: 'pages',
        limit: 7,
        sort: 'n',
        cursor: first['cursor'] as String,
      ),
      throwsA(
        isA<StorageFailure>().having(
          (StorageFailure e) => e.code,
          'code',
          'cursor_mismatch',
        ),
      ),
    );
  });

  test('TC-ST-05：导出后删除再用导出物导入，条数与内容一致（sha256）', () async {
    for (final (String key, int n) in <(String, int)>[
      ('a', 1),
      ('b', 2),
      ('c', 3),
    ]) {
      await engine.put(
        teamId: team,
        namespace: 'ns',
        collection: 'items',
        key: key,
        value: <String, dynamic>{'n': n},
      );
    }
    final Map<String, dynamic> exported = await engine.export(
      teamId: team,
      namespace: 'ns',
      collection: 'items',
    );
    final String path = exported['path'] as String;
    expect(exported['count'], 3);
    expect(File(p.join(path, 'data.ndjson')).existsSync(), isTrue);
    final Map<String, dynamic> manifest =
        (json.decode(
          File(p.join(path, 'manifest.json')).readAsStringSync(),
        ) as Map).map(
          (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
        );
    expect(manifest['sha256'], exported['sha256']);
    expect(manifest['count'], 3);

    for (final String key in <String>['a', 'b', 'c']) {
      await engine.delete(
        teamId: team,
        namespace: 'ns',
        collection: 'items',
        key: key,
      );
    }
    expect(
      (await engine.query(
        teamId: team,
        namespace: 'ns',
        collection: 'items',
      ))['count'],
      0,
    );

    final Map<String, dynamic> imported = await engine.importData(
      teamId: team,
      namespace: 'ns',
      path: path,
    );
    expect(imported['imported'], 3);
    final Map<String, dynamic> got = await engine.get(
      teamId: team,
      namespace: 'ns',
      collection: 'items',
      key: 'b',
    );
    expect(got['value'], <String, dynamic>{'n': 2});
    expect(got['rev'], 1);

    await expectLater(
      engine.importData(teamId: team, namespace: 'ns', path: path),
      throwsA(
        isA<StorageFailure>().having(
          (StorageFailure e) => e.code,
          'code',
          'collection_not_empty',
        ),
      ),
    );
    expect(
      (await engine.importData(
        teamId: team,
        namespace: 'ns',
        path: path,
        replace: true,
      ))['imported'],
      3,
    );
  });

  test('TC-ST-05：篡改 sha256 / 路径穿越 ⇒ 拒绝且不落半截', () async {
    await engine.put(
      teamId: team,
      namespace: 'ns',
      collection: 'items',
      key: 'a',
      value: <String, dynamic>{'n': 1},
    );
    final String path =
        (await engine.export(
              teamId: team,
              namespace: 'ns',
              collection: 'items',
            ))['path']
            as String;
    final Directory tampered = Directory(p.join(temp.path, 'tampered'))
      ..createSync();
    File(p.join(path, 'data.ndjson'))
        .copySync(p.join(tampered.path, 'data.ndjson'));
    File(p.join(path, 'manifest.json'))
        .copySync(p.join(tampered.path, 'manifest.json'));
    File(p.join(tampered.path, 'data.ndjson'))
        .writeAsStringSync('{"key":"x","rev":1,"value":{"n":9}}\n');
    await expectLater(
      engine.importData(
        teamId: team,
        namespace: 'ns',
        path: tampered.path,
        collection: 'items',
        replace: true,
      ),
      throwsA(
        isA<StorageFailure>().having(
          (StorageFailure e) => e.code,
          'code',
          'import_invalid',
        ),
      ),
    );
    expect(
      (await engine.get(
        teamId: team,
        namespace: 'ns',
        collection: 'items',
        key: 'a',
      ))['value'],
      <String, dynamic>{'n': 1},
      reason: '校验失败不能覆盖已有数据',
    );

    await expectLater(
      engine.importData(
        teamId: team,
        namespace: 'ns',
        path: p.join(temp.parent.path, 'outside'),
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

  test('TC-ST-11：单条 >1 MiB / 整批 >8 MiB / >200 ops ⇒ 整批拒绝', () async {
    await expectLater(
      engine.tx(
        teamId: team,
        namespace: 'ns',
        ops: <Map<String, dynamic>>[
          <String, dynamic>{
            'op': 'put',
            'collection': 'big',
            'key': 'a',
            'value': <String, dynamic>{'s': 'x' * (1024 * 1024)},
          },
        ],
      ),
      throwsA(
        isA<StorageFailure>().having(
          (StorageFailure e) => e.code,
          'code',
          'invalid_arguments',
        ),
      ),
    );
    expect(
      (await engine.get(
        teamId: team,
        namespace: 'ns',
        collection: 'big',
        key: 'a',
      ))['value'],
      isNull,
    );

    final String chunk = 'y' * (900 * 1024);
    await expectLater(
      engine.tx(
        teamId: team,
        namespace: 'ns',
        ops: <Map<String, dynamic>>[
          for (int i = 0; i < 10; i++)
            <String, dynamic>{
              'op': 'put',
              'collection': 'big',
              'key': 'k$i',
              'value': <String, dynamic>{'s': chunk},
            },
        ],
      ),
      throwsA(
        isA<StorageFailure>().having(
          (StorageFailure e) => e.code,
          'code',
          'invalid_arguments',
        ),
      ),
    );
    expect(
      (await engine.query(
        teamId: team,
        namespace: 'ns',
        collection: 'big',
      ))['count'],
      0,
    );

    await expectLater(
      engine.tx(
        teamId: team,
        namespace: 'ns',
        ops: <Map<String, dynamic>>[
          for (int i = 0; i < 201; i++)
            <String, dynamic>{
              'op': 'put',
              'collection': 'big',
              'key': 'k$i',
              'value': <String, dynamic>{'n': i},
            },
        ],
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

  test('TC-ST-07：purge 必须确认；确认后只删自己的库，不影响其它 namespace', () async {
    await engine.put(
      teamId: team,
      namespace: 'ns',
      collection: 'items',
      key: 'k',
      value: <String, dynamic>{'v': 1},
    );
    await engine.put(
      teamId: team,
      namespace: 'ns_keep',
      collection: 'items',
      key: 'k',
      value: <String, dynamic>{'v': 2},
    );
    final String path = engine.databasePath(teamId: team, namespace: 'ns');
    final String keep = engine.databasePath(teamId: team, namespace: 'ns_keep');
    expect(File(path).existsSync(), isTrue);

    await expectLater(
      engine.purge(teamId: team, namespace: 'ns', confirm: false),
      throwsA(
        isA<StorageFailure>().having(
          (StorageFailure e) => e.code,
          'code',
          'confirmation_required',
        ),
      ),
    );
    expect(File(path).existsSync(), isTrue);

    final Map<String, dynamic> result = await engine.purge(
      teamId: team,
      namespace: 'ns',
      confirm: true,
    );
    expect(result['purged'], isTrue);
    expect(File(path).existsSync(), isFalse);
    expect(File(keep).existsSync(), isTrue);
    // 后续读不炸（会按需重建空库）。
    expect(
      (await engine.get(
        teamId: team,
        namespace: 'ns',
        collection: 'items',
        key: 'k',
      ))['value'],
      isNull,
    );
  });

  test('ST-5：stats 报集合条目数/版本/文件字节与路径；compact 可重开', () async {
    await engine.ensure(
      teamId: team,
      namespace: 'ns',
      collection: 'docs',
      schemaVersion: 2,
    );
    await engine.put(
      teamId: team,
      namespace: 'ns',
      collection: 'docs',
      key: 'k1',
      value: <String, dynamic>{'v': 1},
    );
    final Map<String, dynamic> stats = await engine.stats(
      teamId: team,
      namespace: 'ns',
    );
    expect(stats['path'], engine.databasePath(teamId: team, namespace: 'ns'));
    expect(stats['bytes'] as int, greaterThan(0));
    final Map<String, dynamic> docs = (stats['collections'] as List<dynamic>)
        .map((Object? entry) => (entry as Map).cast<String, dynamic>())
        .firstWhere(
          (Map<String, dynamic> entry) => entry['collection'] == 'docs',
        );
    expect(docs['count'], 1);
    expect(docs['schema_version'], 2);

    final Map<String, dynamic> compacted = await engine.compact(
      teamId: team,
      namespace: 'ns',
    );
    expect(compacted['compacted'], isTrue);
    expect(
      (await engine.get(
        teamId: team,
        namespace: 'ns',
        collection: 'docs',
        key: 'k1',
      ))['value'],
      <String, dynamic>{'v': 1},
    );
  });
}

/// 从 query 回包里取 key 列表（断言用）。
List<String> keysOf(Map<String, dynamic> page) => <String>[
  for (final Object? item in (page['values'] as List<dynamic>? ?? <dynamic>[]))
    '${(item as Map<dynamic, dynamic>)['key']}',
];
