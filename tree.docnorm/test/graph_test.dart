import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_docnorm/tree_docnorm.dart';

void main() {
  final bool gitAvailable = () {
    try {
      return Process.runSync('git', <String>['--version']).exitCode == 0;
    } catch (_) {
      return false;
    }
  }();

  late Directory temp;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tree_docnorm_graph_');
    if (!gitAvailable) return;
    await _git(temp, <String>['init', '--quiet']);
    await _git(temp, <String>['config', 'user.name', 'test']);
    await _git(temp, <String>['config', 'user.email', 'test@local']);
    await _git(temp, <String>['config', 'commit.gpgsign', 'false']);
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  void write(String path, String content) {
    final File file = File('${temp.path}${Platform.pathSeparator}$path');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  Future<void> commitAll() async {
    await _git(temp, <String>['add', '-A']);
    await _git(temp, <String>['commit', '--quiet', '-m', 'fixture']);
  }

  void fixture() {
    write('pubspec.yaml', 'name: demo_pkg\n');
    write('lib/a.dart', 'class Alpha {}\nclass Shared {}\n');
    write(
      'README.md',
      '# demo\n\n## 职责\n提供 Alpha 示例。\n\n## 入口\nlib/a.dart 的 Alpha。\n\n'
      '另见 [子文档](docs/a.md)。\n',
    );
    write('docs/README.md', '- [a.md](a.md)\n');
    write('docs/a.md', '# A\n\n[返回](../README.md)\n');
    write('docnorm.yaml', '''
version: 1
required_docs:
  - README.md
indexes:
  - dir: docs
    index: docs/README.md
mentions:
  - doc: README.md
    symbols:
      - Alpha
''');
  }

  test('三类确定性边：belongs_to / references / mentions（dry-run）', () async {
    if (!gitAvailable) {
      markTestSkipped('git 不可用');
      return;
    }
    fixture();
    await commitAll();

    final FakeStorage storage = FakeStorage();
    final Map<String, Object?> result = await runGraphBuild(
      temp.path,
      storage: storage.call,
    );
    expect(result['mode'], 'deterministic');
    expect(result['dry_run'], true);
    expect(
      (result['storage'] as Map<String, Object?>)['applied'],
      false,
      reason: 'dry-run 不写存储',
    );
    expect(storage.writes, 0);

    final Map<String, Object?> counts =
        result['counts'] as Map<String, Object?>;
    final Map<String, Object?> nodeKinds =
        counts['by_node_kind'] as Map<String, Object?>;
    final Map<String, Object?> edgeKinds =
        counts['by_edge_kind'] as Map<String, Object?>;
    expect(nodeKinds['doc'], 3, reason: 'README + docs/README + docs/a');
    expect(nodeKinds['package'], 1);
    expect(edgeKinds['belongs_to'], 3);
    expect(
      edgeKinds['references'],
      3,
      reason: 'README→docs/a、docs/README→docs/a、docs/a→README',
    );
    expect(edgeKinds['mentions'], 1, reason: '策略点名 Alpha');

    final List<dynamic> edges = result['edges'] as List<dynamic>;
    final Map<String, Object?> reference = edges
        .cast<Map<String, Object?>>()
        .firstWhere((Map<String, Object?> edge) => edge['kind'] == 'references');
    expect(reference['from'], startsWith('doc:'));
    expect(reference['to'], startsWith('doc:'));
  }, skip: gitAvailable ? false : 'git 不可用');

  test('commit 写 graph_nodes / graph_edges；重复运行 0 写', () async {
    if (!gitAvailable) {
      markTestSkipped('git 不可用');
      return;
    }
    fixture();
    await commitAll();

    final FakeStorage storage = FakeStorage();
    final Map<String, Object?> first = await runGraphBuild(
      temp.path,
      storage: storage.call,
      commit: true,
    );
    expect((first['storage'] as Map<String, Object?>)['applied'], true);
    expect(storage.db['graph_nodes'], isNotEmpty);
    expect(storage.db['graph_edges'], isNotEmpty);
    final int writes = storage.writes;

    final Map<String, Object?> again = await runGraphBuild(
      temp.path,
      storage: storage.call,
      commit: true,
    );
    expect(
      (again['storage'] as Map<String, Object?>)['ops'],
      0,
      reason: '同一事实重复运行 0 写',
    );
    expect(storage.writes, writes);
  }, skip: gitAvailable ? false : 'git 不可用');

  test('文档删除后旧节点与边按前缀清理', () async {
    if (!gitAvailable) {
      markTestSkipped('git 不可用');
      return;
    }
    fixture();
    await commitAll();

    final FakeStorage storage = FakeStorage();
    await runGraphBuild(temp.path, storage: storage.call, commit: true);
    final Map<String, Map<String, Object?>> nodes =
        storage.db['graph_nodes']!;
    final Map<String, Map<String, Object?>> edges =
        storage.db['graph_edges']!;
    expect(
      nodes.keys.any((String key) => key.contains('doc:docs/a.md')),
      true,
    );
    final int before = nodes.length;

    File('${temp.path}${Platform.pathSeparator}docs${Platform.pathSeparator}a.md')
        .deleteSync();
    final Map<String, Object?> result = await runGraphBuild(
      temp.path,
      storage: storage.call,
      commit: true,
    );
    expect(
      (result['writes'] as List<dynamic>).any(
        (dynamic write) => (write as Map<String, Object?>)['op'] == 'delete',
      ),
      true,
    );
    expect(
      nodes.keys.any((String key) => key.contains('doc:docs/a.md')),
      false,
    );
    expect(nodes.length, before - 1);
    expect(
      edges.values.any(
        (Map<String, Object?> edge) =>
            '${edge['from']}'.contains('docs/a.md') ||
            '${edge['to']}'.contains('docs/a.md'),
      ),
      false,
    );
  }, skip: gitAvailable ? false : 'git 不可用');
}

class FakeStorage {
  final Map<String, Map<String, Map<String, Object?>>> db =
      <String, Map<String, Map<String, Object?>>>{};
  int writes = 0;

  Map<String, Map<String, Object?>> _collection(String name) =>
      db.putIfAbsent(name, () => <String, Map<String, Object?>>{});

  Future<Map<String, dynamic>> call(
    String command,
    Map<String, dynamic> arguments,
  ) async {
    final String collection = '${arguments['collection'] ?? ''}';
    final Map<String, Map<String, Object?>> records = _collection(collection);
    switch (command) {
      case 'storage.ensure':
        writes += 1;
        return <String, dynamic>{
          'collection': collection,
          'schema_version': arguments['schema_version'] ?? 1,
        };
      case 'storage.scan':
        final String prefix = '${arguments['prefix'] ?? ''}';
        final List<Map<String, Object?>> values = <Map<String, Object?>>[
          for (final MapEntry<String, Map<String, Object?>> entry
              in records.entries)
            if (entry.key.startsWith(prefix))
              <String, Object?>{'key': entry.key, 'value': entry.value, 'rev': 1},
        ];
        return <String, dynamic>{'values': values, 'count': values.length};
      case 'storage.tx':
        writes += 1;
        final List<dynamic> ops = arguments['ops'] is List
            ? arguments['ops'] as List<dynamic>
            : <dynamic>[];
        for (final Object? raw in ops) {
          if (raw is! Map) continue;
          final Map<String, dynamic> op = Map<String, dynamic>.from(raw);
          final Map<String, Map<String, Object?>> target = _collection(
            '${op['collection']}',
          );
          final String key = '${op['key']}';
          if (op['op'] == 'delete') {
            target.remove(key);
          } else {
            target[key] = Map<String, Object?>.from(
              (op['value'] as Map).cast<String, Object?>(),
            );
          }
        }
        return <String, dynamic>{'committed': true, 'count': ops.length};
      default:
        throw StateError('未知存储命令：$command');
    }
  }
}

Future<void> _git(Directory directory, List<String> args) async {
  final ProcessResult result = await Process.run(
    'git',
    args,
    workingDirectory: directory.path,
  );
  if (result.exitCode != 0) {
    throw StateError('git ${args.join(' ')} 失败：${result.stderr}');
  }
}
