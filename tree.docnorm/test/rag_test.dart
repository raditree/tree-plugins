import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_docnorm/tree_docnorm.dart';

/// DN-9：GraphRAG 索引（分块 / 抽取 / Leiden / 报告 / 向量 / 增量 / 降级）。
void main() {
  final bool gitAvailable = () {
    try {
      return Process.runSync('git', <String>['--version']).exitCode == 0;
    } catch (_) {
      return false;
    }
  }();

  late Directory temp;
  late FakeStorage storage;
  late FakeLlm llm;
  late FakeEmbed embed;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tree_docnorm_rag_');
    storage = FakeStorage();
    llm = FakeLlm();
    embed = FakeEmbed();
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
    write('lib/a.dart', 'class Alpha {}\n');
    write(
      'README.md',
      '# demo\n\n## 职责\nAlpha 负责演示。\n\n## 入口\nlib/a.dart 的 Alpha。\n',
    );
    write('docs/README.md', '- [a.md](a.md)\n');
    write('docs/a.md', '# A\n\nAlpha 示例。\n');
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

  Future<Map<String, Object?>> build({bool commit = false, bool rag = true}) =>
      runGraphBuild(
        temp.path,
        storage: storage.call,
        commit: commit,
        rag: rag,
        llm: llm.call,
        embed: embed.call,
      );

  Future<Map<String, Object?>> buildWith({required bool commit}) async {
    fixture();
    await commitAll();
    return build(commit: commit);
  }

  test('dry-run：只分块与探测 embedding，不发 LLM、不写存储', () async {
    if (!gitAvailable) {
      markTestSkipped('git 不可用');
      return;
    }
    final Map<String, Object?> result = await buildWith(commit: false);
    expect(result['mode'], 'hybrid');
    final Map<String, Object?> rag = result['rag'] as Map<String, Object?>;
    expect(rag['vector_mode'], 'planned');
    expect((rag['chunks'] as Map<String, Object?>)['pending'], greaterThan(0));
    expect((rag['vectors'] as Map<String, Object?>)['pending'], greaterThan(0));
    expect(llm.calls, 0, reason: 'dry-run 不烧 token');
    expect(embed.calls, 1, reason: '只探测模型（空 inputs）');
    expect(storage.writes, 0);
  });

  test('commit：chunks / communities / reports / vectors 入库', () async {
    if (!gitAvailable) {
      markTestSkipped('git 不可用');
      return;
    }
    final Map<String, Object?> result = await buildWith(commit: true);
    expect(result['mode'], 'hybrid');
    final Map<String, Object?> rag = result['rag'] as Map<String, Object?>;
    expect(rag['degraded'], false);
    expect(rag['vector_mode'], 'embedding');
    expect(llm.calls, greaterThan(0));
    expect(
      storage.db['graph_chunks'] ?? <String, Map<String, Object?>>{},
      isNotEmpty,
    );
    expect(
      storage.db['graph_communities'] ?? <String, Map<String, Object?>>{},
      isNotEmpty,
    );
    expect(
      storage.db['graph_reports'] ?? <String, Map<String, Object?>>{},
      isNotEmpty,
    );
    final Map<String, Map<String, Object?>> vectors =
        storage.db['graph_vectors'] ?? <String, Map<String, Object?>>{};
    expect(vectors, isNotEmpty);
    final Map<String, Object?> vector = vectors.values.first;
    expect(vector['model'], 'emb');
    expect(vector['dimensions'], 4);
    final List<dynamic> values = vector['vector']! as List<dynamic>;
    expect(values.length, 4);
    expect(values.first, 1.0, reason: '向量写入前做归一化');

    final Map<String, Map<String, Object?>> nodes =
        storage.db['graph_nodes'] ?? <String, Map<String, Object?>>{};
    expect(
      nodes.keys.any((String key) => key.contains('ent:concept:alpha')),
      isTrue,
      reason: 'LLM 抽取的实体进入图节点',
    );
    final Map<String, Map<String, Object?>> edges =
        storage.db['graph_edges'] ?? <String, Map<String, Object?>>{};
    expect(
      edges.values.any(
        (Map<String, Object?> edge) => edge['kind'] == 'documents',
      ),
      isTrue,
      reason: '文档 → 实体 的 documents 边',
    );
    expect(
      edges.values.any(
        (Map<String, Object?> edge) =>
            edge['kind'] == 'references' && edge['extractor'] == 'llm',
      ),
      isTrue,
      reason: '关系端点按文档 label 解析',
    );
  });

  test('重复运行：0 写、0 LLM 调用（报告 / 向量全命中缓存）', () async {
    if (!gitAvailable) {
      markTestSkipped('git 不可用');
      return;
    }
    fixture();
    await commitAll();
    await build(commit: true);
    final int writes = storage.writes;
    final int calls = llm.calls;
    final int embeds = embed.calls;
    final Map<String, Object?> again = await build(commit: true);
    expect((again['storage'] as Map<String, Object?>)['ops'], 0);
    expect(storage.writes, writes);
    expect(llm.calls, calls, reason: '抽取与报告都不再调用');
    expect(embed.calls, embeds + 1, reason: '只重新探测一次模型');
  });

  test('增量：只重算变化 chunk，其余命中缓存', () async {
    if (!gitAvailable) {
      markTestSkipped('git 不可用');
      return;
    }
    fixture();
    await commitAll();
    await build(commit: true);
    final int calls = llm.calls;

    write('docs/a.md', '# A\n\nAlpha 示例（更新）。\n');
    final Map<String, Object?> result = await build(commit: true);
    final Map<String, Object?> rag = result['rag'] as Map<String, Object?>;
    final Map<String, Object?> chunks = rag['chunks'] as Map<String, Object?>;
    expect(chunks['extracted'], 1, reason: '只有 docs/a.md 的 1 个 chunk 变化');
    expect(chunks['cached'], greaterThan(0));
    expect(llm.calls, calls + 1, reason: '报告与其它 chunk 都不重复付费');
  });

  test('无 embedding 模型：跳过向量并标 mode=lexical，清理旧向量', () async {
    if (!gitAvailable) {
      markTestSkipped('git 不可用');
      return;
    }
    fixture();
    await commitAll();
    await build(commit: true);
    expect(
      storage.db['graph_vectors'] ?? <String, Map<String, Object?>>{},
      isNotEmpty,
    );

    embed.available = false;
    final Map<String, Object?> result = await build(commit: true);
    expect(result['mode'], 'lexical');
    expect((result['rag'] as Map<String, Object?>)['vector_mode'], 'lexical');
    expect(
      storage.db['graph_vectors'] ?? <String, Map<String, Object?>>{},
      isEmpty,
      reason: '旧向量按期望集合删除，避免误用',
    );
  });

  test('rag=true 但缺 llm / embed 通道 ⇒ rag_unavailable', () async {
    if (!gitAvailable) {
      markTestSkipped('git 不可用');
      return;
    }
    fixture();
    await commitAll();
    try {
      await runGraphBuild(temp.path, storage: storage.call, rag: true);
      fail('应当 fail-closed');
    } on BaselineFailure catch (error) {
      expect(error.code, 'rag_unavailable');
    }
  });
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
              <String, Object?>{
                'key': entry.key,
                'value': entry.value,
                'rev': 1,
              },
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

class FakeLlm {
  int calls = 0;

  Future<GenerateReply> call(GenerateRequest request) async {
    calls += 1;
    if (request.prompt.contains('知识图谱抽取器')) {
      return const GenerateReply(
        json: <String, Object?>{
          'entities': <Map<String, Object?>>[
            <String, Object?>{'kind': 'concept', 'name': 'Alpha'},
          ],
          'relations': <Map<String, Object?>>[
            <String, Object?>{
              'kind': 'references',
              'from': 'Alpha',
              'to': 'README.md',
            },
          ],
        },
      );
    }
    if (request.prompt.contains('社区摘要')) {
      return const GenerateReply(
        json: <String, Object?>{
          'title': '示例社区',
          'summary': '这个社区围绕 Alpha 展开，包含文档与实体节点，边界清晰可检索。',
        },
      );
    }
    return const GenerateReply(error: '意外的 LLM 调用');
  }
}

class FakeEmbed {
  bool available = true;
  int calls = 0;

  Future<RagEmbedReply> call(RagEmbedRequest request) async {
    calls += 1;
    if (!available) {
      return const RagEmbedReply(
        error: '没有可用的 embedding 模型',
        code: 'no_embedding_model',
      );
    }
    if (request.inputs.isEmpty) {
      return const RagEmbedReply(model: 'emb', dimensions: 4);
    }
    return RagEmbedReply(
      model: 'emb',
      dimensions: 4,
      vectors: <List<double>>[
        for (int i = 0; i < request.inputs.length; i++)
          <double>[1.0, 0.0, 0.0, 0.0],
      ],
    );
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
