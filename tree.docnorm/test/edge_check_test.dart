import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_docnorm/tree_docnorm.dart';

/// DN-10 关联边检查：断链 / 孤儿 / 过期引用 / 未解析提及 / 跨包引用 / 术语冲突。
void main() {
  late Directory temp;
  late MemoryStorage storage;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_docnorm_edges_');
    storage = MemoryStorage();
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  void write(String path, String content) {
    final File file = File(p.joinAll(<String>[temp.path, ...path.split('/')]));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  void fixture() {
    write('README.md', '# demo\n');
    write('docs/a.md', '# A\n\n[缺失](missing.md)\n');
    write('docs/b.md', '# B\n\n见 [core](../packages/core/README.md)。\n');
    write(
      'packages/core/README.md',
      '# core\n\n见 [ui](../../packages/ui/README.md)。\n',
    );
    write('packages/ui/README.md', '# ui\n');
    final String repoKey = repoKeyOf(temp.path);
    Map<String, Object?> node(String id, String kind, String label) =>
        <String, Object?>{'schema': 1, 'id': id, 'kind': kind, 'label': label};
    storage.db['graph_nodes'] = <String, Map<String, Object?>>{
      '$repoKey#node:doc:docs/a.md': node('doc:docs/a.md', 'doc', 'a.md'),
      '$repoKey#node:doc:docs/b.md': node('doc:docs/b.md', 'doc', 'b.md'),
      '$repoKey#node:doc:packages/core/README.md': node(
        'doc:packages/core/README.md',
        'doc',
        'README.md',
      ),
      '$repoKey#node:doc:packages/ui/README.md': node(
        'doc:packages/ui/README.md',
        'doc',
        'README.md',
      ),
      '$repoKey#node:pkg:core': node('pkg:core', 'package', 'core'),
      '$repoKey#node:pkg:ui': node('pkg:ui', 'package', 'ui'),
      '$repoKey#node:ent:concept:租约': node('ent:concept:租约', 'concept', '租约'),
      '$repoKey#node:ent:module:租约': node('ent:module:租约', 'module', '租约'),
    };
    Map<String, Object?> edge(String id, String kind, String from, String to) =>
        <String, Object?>{
          'schema': 1,
          'id': id,
          'kind': kind,
          'from': from,
          'to': to,
        };
    storage.db['graph_edges'] = <String, Map<String, Object?>>{
      '$repoKey#edge:e1': edge('e1', 'belongs_to', 'doc:docs/a.md', 'pkg:core'),
      '$repoKey#edge:e2': edge('e2', 'belongs_to', 'doc:docs/b.md', 'pkg:core'),
      '$repoKey#edge:e3': edge(
        'e3',
        'belongs_to',
        'doc:packages/core/README.md',
        'pkg:core',
      ),
      '$repoKey#edge:e4': edge(
        'e4',
        'belongs_to',
        'doc:packages/ui/README.md',
        'pkg:ui',
      ),
      '$repoKey#edge:e5': edge(
        'e5',
        'references',
        'doc:packages/core/README.md',
        'doc:packages/ui/README.md',
      ),
      '$repoKey#edge:e6': edge(
        'e6',
        'documents',
        'doc:docs/a.md',
        'ent:concept:租约',
      ),
      '$repoKey#edge:e7': edge(
        'e7',
        'documents',
        'doc:docs/b.md',
        'ent:module:租约',
      ),
      '$repoKey#edge:e8': edge('e8', 'mentions', 'doc:docs/a.md', 'sym:ghost'),
    };
    storage.db['doc_state'] = <String, Map<String, Object?>>{
      '$repoKey#doc:docs/b.md': <String, Object?>{
        'kind': 'doc',
        'doc': 'docs/b.md',
        'stale': true,
        'updatedAt': '2026-01-01T00:00:00Z',
      },
    };
  }

  Future<Map<String, Object?>> run() async {
    final DocContract contract = await inspectRepository(temp.path);
    return runEdgeChecks(temp.path, storage: storage.call, contract: contract);
  }

  test('六类检查：找出断链 / stale / 未解析提及 / 跨包引用 / 术语冲突', () async {
    fixture();
    final Map<String, Object?> result = await run();
    expect(result['ok'], false, reason: '断链是 error');
    final List<dynamic> findings = result['findings'] as List<dynamic>;
    final Map<String, int> byKind = <String, int>{};
    for (final Object? item in findings) {
      if (item is! Map) continue;
      byKind['${item['kind']}'] = (byKind['${item['kind']}'] ?? 0) + 1;
    }
    expect(byKind['broken_link'], 1);
    expect(byKind['stale_reference'], 1);
    expect(byKind['unresolved_mention'], 1);
    expect(byKind['cross_package_reference'], 1);
    expect(byKind['term_conflict'], 1);
    expect(byKind['orphan'], isNull, reason: '夹具里所有节点都有边');
  });

  test('图缺失 ⇒ graph_required', () async {
    fixture();
    storage.db.clear();
    final Map<String, Object?> result = await run();
    expect(result['code'], 'graph_required');
    expect(result['ok'], false);
  });
}

class MemoryStorage {
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
