import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_docnorm/tree_docnorm.dart';

/// DN-10 检索：BM25 / cosine / local / global / hybrid / lexical 降级。
void main() {
  late Directory temp;
  late MemoryStorage storage;
  late FakeEmbed embed;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_docnorm_query_');
    storage = MemoryStorage();
    embed = FakeEmbed();
    seed(storage, temp.path);
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<Map<String, Object?>> query(
    String question, {
    String mode = 'auto',
    bool withEmbed = true,
  }) => runQuery(
    temp.path,
    storage: storage.call,
    question: question,
    mode: mode,
    embed: withEmbed ? embed.call : null,
  );

  test('lexical：纯 BM25，不调用 embedding', () async {
    final Map<String, Object?> result = await query(
      '网关 分层',
      mode: 'lexical',
      withEmbed: false,
    );
    expect(result['mode'], 'lexical');
    final List<dynamic> results = result['results'] as List<dynamic>;
    expect(results, isNotEmpty);
    expect(
      (results.first as Map<String, Object?>)['doc'],
      'docs/architecture.md',
    );
    expect(embed.calls, 0);
    expect(storage.writes, 0);
  });

  test('basic：BM25 + cosine', () async {
    final Map<String, Object?> result = await query('SSE 流式', mode: 'basic');
    expect(result['mode'], 'basic');
    final List<dynamic> results = result['results'] as List<dynamic>;
    expect((results.first as Map<String, Object?>)['doc'], 'docs/api.md');
  });

  test('local：实体链接命中并输出 seeds', () async {
    final Map<String, Object?> result = await query('网关怎么分层', mode: 'local');
    expect(result['mode'], 'local');
    expect(result['entities'], isNotEmpty);
    final List<dynamic> results = result['results'] as List<dynamic>;
    final Set<String> docs = <String>{
      for (final Object? item in results)
        if (item is Map) '${item['doc']}',
    };
    expect(docs, contains('docs/architecture.md'));
  });

  test('global：社区报告参与 reduce', () async {
    final Map<String, Object?> result = await query('SSE 接口', mode: 'global');
    expect(result['mode'], 'global');
    expect(result['reports'], isNotEmpty);
    final List<dynamic> results = result['results'] as List<dynamic>;
    final Set<String> docs = <String>{
      for (final Object? item in results)
        if (item is Map) '${item['doc']}',
    };
    expect(
      docs.intersection(<String>{'docs/api.md', 'docs/glossary.md'}),
      isNotEmpty,
    );
  });

  test('auto：有向量走 hybrid', () async {
    final Map<String, Object?> result = await query('网关分层');
    expect(result['mode'], 'hybrid');
  });

  test('无向量：auto 降级 lexical 并标记 degraded', () async {
    storage.db.remove('graph_vectors');
    final Map<String, Object?> result = await query('网关分层');
    expect(result['mode'], 'lexical');
    expect(result['degraded'], true);
  });

  test('图索引缺失 ⇒ graph_required', () async {
    storage.db.clear();
    try {
      await query('网关');
      fail('应当 fail-closed');
    } on BaselineFailure catch (error) {
      expect(error.code, 'graph_required');
    }
  });

  test('非法 mode ⇒ invalid_arguments', () async {
    try {
      await query('网关', mode: 'magic');
      fail('应当拒绝');
    } on BaselineFailure catch (error) {
      expect(error.code, 'invalid_arguments');
    }
  });
}

class MemoryStorage {
  final Map<String, Map<String, Map<String, Object?>>> db =
      <String, Map<String, Map<String, Object?>>>{};
  int writes = 0;

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
      case 'storage.tx':
        writes += 1;
        return <String, dynamic>{'committed': true};
      default:
        throw StateError('未知存储命令：$command');
    }
  }
}

class FakeEmbed {
  int calls = 0;

  Future<RagEmbedReply> call(RagEmbedRequest request) async {
    calls += 1;
    if (request.inputs.isEmpty) {
      return const RagEmbedReply(model: 'emb', dimensions: 8);
    }
    return RagEmbedReply(
      model: 'emb',
      dimensions: 8,
      vectors: <List<double>>[vectorFor(request.inputs.first)],
    );
  }
}

const Map<String, int> _terms = <String, int>{
  '网关': 0,
  '分层': 1,
  '服务': 2,
  '路由': 3,
  'sse': 4,
  '流式': 4,
  '限流': 5,
  '回滚': 6,
  '术语': 7,
  '轮询': 7,
};

List<double> vectorFor(String text) {
  final String lower = text.toLowerCase();
  final List<double> vector = List<double>.filled(8, 0, growable: false);
  for (final MapEntry<String, int> entry in _terms.entries) {
    if (lower.contains(entry.key)) vector[entry.value] = 1;
  }
  if (vector.every((double value) => value == 0)) vector[0] = 1;
  return vector;
}

void seed(MemoryStorage storage, String root) {
  final String repoKey = repoKeyOf(root);
  final Map<String, String> docs = <String, String>{
    'docs/architecture.md':
        '# 架构\n\n网关负责分层：网关层、服务层、存储层；路由从网关进入。\n\n'
        '服务层包含核心模块与 UI 模块，模块之间通过接口通信。\n',
    'docs/api.md': '# API\n\nHTTP 路由与 SSE 流式接口；鉴权在网关完成。\n',
    'docs/operations.md': '# 运维\n\n限流与配置在部署时生效，回滚需要旧版本包。\n',
    'docs/glossary.md': '# 术语\n\nSSE 是流式协议；网关是入口；租约是写权限。\n',
    'docs/legacy.md': '# 旧方案\n\n旧方案使用轮询，已废弃，不再同步。\n',
  };
  final List<DocChunk> chunks = chunkDocuments(docs);
  final Map<String, Map<String, Object?>> chunkRecords =
      <String, Map<String, Object?>>{};
  final Map<String, Map<String, Object?>> vectorRecords =
      <String, Map<String, Object?>>{};
  for (final DocChunk chunk in chunks) {
    chunkRecords['$repoKey#chunk:${chunk.id}'] = <String, Object?>{
      ...chunk.toJson(repoKey),
      'extraction': const <String, Object?>{'entities': [], 'relations': []},
    };
    vectorRecords['$repoKey#vector:${chunk.id}'] = <String, Object?>{
      'schema': 1,
      'repo': repoKey,
      'id': chunk.id,
      'chunk': chunk.id,
      'doc': chunk.doc,
      'hash': chunk.hash,
      'model': 'emb',
      'dimensions': 8,
      'vector': vectorFor('${chunk.heading} ${chunk.text}'),
    };
  }
  final Map<String, Map<String, Object?>> nodes =
      <String, Map<String, Object?>>{
        '$repoKey#node:doc:docs/architecture.md': <String, Object?>{
          'id': 'doc:docs/architecture.md',
          'kind': 'doc',
          'label': 'architecture.md',
        },
        '$repoKey#node:doc:docs/api.md': <String, Object?>{
          'id': 'doc:docs/api.md',
          'kind': 'doc',
          'label': 'api.md',
        },
        '$repoKey#node:doc:docs/glossary.md': <String, Object?>{
          'id': 'doc:docs/glossary.md',
          'kind': 'doc',
          'label': 'glossary.md',
        },
        '$repoKey#node:pkg:core': <String, Object?>{
          'id': 'pkg:core',
          'kind': 'package',
          'label': 'core',
        },
        '$repoKey#node:ent:concept:网关': <String, Object?>{
          'id': 'ent:concept:网关',
          'kind': 'concept',
          'label': '网关',
        },
        '$repoKey#node:ent:concept:sse': <String, Object?>{
          'id': 'ent:concept:sse',
          'kind': 'concept',
          'label': 'SSE',
        },
      };
  final Map<String, Map<String, Object?>> edges =
      <String, Map<String, Object?>>{
        for (final String doc in <String>[
          'docs/architecture.md',
          'docs/api.md',
          'docs/glossary.md',
        ])
          '$repoKey#edge:belongs:$doc': <String, Object?>{
            'id': 'e-belongs:$doc',
            'kind': 'belongs_to',
            'from': 'doc:$doc',
            'to': 'pkg:core',
          },
        '$repoKey#edge:documents:arch': <String, Object?>{
          'id': 'e-documents:arch',
          'kind': 'documents',
          'from': 'doc:docs/architecture.md',
          'to': 'ent:concept:网关',
        },
        '$repoKey#edge:documents:api': <String, Object?>{
          'id': 'e-documents:api',
          'kind': 'documents',
          'from': 'doc:docs/api.md',
          'to': 'ent:concept:sse',
        },
      };
  final Map<String, Map<String, Object?>> reports =
      <String, Map<String, Object?>>{
        '$repoKey#report:r1': <String, Object?>{
          'id': 'r1',
          'title': '分层与网关',
          'summary': '网关分层、服务层与模块边界。',
          'members': <String>['doc:docs/architecture.md', 'ent:concept:网关'],
        },
        '$repoKey#report:r2': <String, Object?>{
          'id': 'r2',
          'title': 'SSE 接口',
          'summary': 'SSE 流式路由与鉴权。',
          'members': <String>[
            'doc:docs/api.md',
            'doc:docs/glossary.md',
            'ent:concept:sse',
          ],
        },
      };
  storage.db
    ..['graph_chunks'] = chunkRecords
    ..['graph_vectors'] = vectorRecords
    ..['graph_nodes'] = nodes
    ..['graph_edges'] = edges
    ..['graph_reports'] = reports;
}
