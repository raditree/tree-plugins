import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_docnorm/tree_docnorm.dart';

/// P8 golden set：18 条问题 + 5 条边检查期望，产出 recall@5 / recall@10
/// 与边检查 precision；未达阈值即 DN-10 不能接入产线准备阶段。
void main() {
  late Directory temp;
  late MemoryStorage storage;
  late FakeEmbed embed;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_docnorm_golden_');
    storage = MemoryStorage();
    embed = FakeEmbed();
    fixture(temp, storage);
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('P8：recall@5 / recall@10 与边检查 precision 达标', () async {
    final File file = File(
      p.join(Directory.current.path, 'test', 'golden', 'retrieval_golden.json'),
    );
    final Map<String, dynamic> golden =
        (jsonDecode(file.readAsStringSync()) as Map).cast<String, dynamic>();
    final List<dynamic> questions = golden['questions'] as List<dynamic>;
    expect(questions.length, inInclusiveRange(15, 20));

    double sumAt5 = 0;
    double sumAt10 = 0;
    final List<String> misses = <String>[];
    for (final Object? raw in questions) {
      final Map<String, dynamic> item = (raw as Map).cast<String, dynamic>();
      final List<String> expected = <String>[
        for (final Object? doc in item['expect_docs'] as List<dynamic>) '$doc',
      ];
      final Map<String, Object?> result = await runQuery(
        temp.path,
        storage: storage.call,
        question: '${item['question']}',
        mode: 'hybrid',
        embed: embed.call,
      );
      expect(result['mode'], 'hybrid', reason: '${item['id']} 应走 hybrid');
      final List<String> docs = <String>[
        for (final Object? hit in result['results'] as List<dynamic>)
          if (hit is Map) '${hit['doc']}',
      ];
      final Set<String> unique = docs.toSet().toList().cast<String>().toSet();
      final Set<String> at5 = docs.take(5).toSet();
      final int hit5 = expected.where(at5.contains).length;
      final int hit10 = expected.where(unique.contains).length;
      sumAt5 += expected.isEmpty ? 1 : hit5 / expected.length;
      sumAt10 += expected.isEmpty ? 1 : hit10 / expected.length;
      if (hit5 < expected.length) {
        misses.add(
          '${item['id']} 缺 ${expected.where((String d) => !at5.contains(d)).join(', ')}',
        );
      }
    }
    final double recall5 = sumAt5 / questions.length;
    final double recall10 = sumAt10 / questions.length;
    final Map<String, double> thresholds = (golden['thresholds'] as Map)
        .cast<String, double>();
    expect(
      recall5,
      greaterThanOrEqualTo(thresholds['recall_at_5']!),
      reason: 'recall@5=$recall5；${misses.join(' | ')}',
    );
    expect(
      recall10,
      greaterThanOrEqualTo(thresholds['recall_at_10']!),
      reason: 'recall@10=$recall10',
    );

    final DocContract contract = await inspectRepository(temp.path);
    final Map<String, Object?> edges = await runEdgeChecks(
      temp.path,
      storage: storage.call,
      contract: contract,
    );
    final List<dynamic> findings = edges['findings'] as List<dynamic>;
    final List<dynamic> expectations =
        golden['edge_expectations'] as List<dynamic>;
    int matched = 0;
    for (final Object? raw in findings) {
      if (raw is! Map) continue;
      final bool expected = expectations.any((Object? expectedRaw) {
        if (expectedRaw is! Map) return false;
        if ('${expectedRaw['kind']}' != '${raw['kind']}') return false;
        final String doc = '${expectedRaw['doc']}';
        if (doc.isNotEmpty && doc != '${raw['doc']}') return false;
        final String detail = '${expectedRaw['detail_contains']}';
        return detail.isEmpty || '${raw['detail']}'.contains(detail);
      });
      if (expected) matched += 1;
    }
    final double precision = findings.isEmpty ? 1 : matched / findings.length;
    stdout.writeln(
      'P8 golden：recall@5=${recall5.toStringAsFixed(3)} '
      'recall@10=${recall10.toStringAsFixed(3)} '
      'edge_precision=${precision.toStringAsFixed(3)} '
      '($matched / ${findings.length})',
    );
    expect(
      precision,
      greaterThanOrEqualTo(thresholds['edge_precision']!),
      reason:
          'edge precision=$precision（matched=$matched / ${findings.length}）',
    );
    for (final Object? expectedRaw in expectations) {
      if (expectedRaw is! Map) continue;
      final bool found = findings.any((Object? raw) {
        if (raw is! Map) return false;
        if ('${expectedRaw['kind']}' != '${raw['kind']}') return false;
        final String doc = '${expectedRaw['doc']}';
        if (doc.isNotEmpty && doc != '${raw['doc']}') return false;
        final String detail = '${expectedRaw['detail_contains']}';
        return detail.isEmpty || '${raw['detail']}'.contains(detail);
      });
      expect(found, isTrue, reason: '缺少边检查期望：$expectedRaw');
    }
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

class FakeEmbed {
  Future<RagEmbedReply> call(RagEmbedRequest request) async {
    if (request.inputs.isEmpty) {
      return const RagEmbedReply(model: 'emb', dimensions: 16);
    }
    return RagEmbedReply(
      model: 'emb',
      dimensions: 16,
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
  '限流': 5,
  '回滚': 6,
  '租约': 7,
  '术语': 7,
  '轮询': 8,
  '配置': 9,
  '鉴权': 10,
  '迁移': 11,
  '模块': 12,
  '入口': 12,
  '文档': 13,
  '索引': 13,
  '废弃': 14,
  '核心': 15,
};

List<double> vectorFor(String text) {
  final String lower = text.toLowerCase();
  final List<double> vector = List<double>.filled(16, 0, growable: false);
  for (final MapEntry<String, int> entry in _terms.entries) {
    if (lower.contains(entry.key)) vector[entry.value] = 1;
  }
  if (vector.every((double value) => value == 0)) vector[0] = 1;
  return vector;
}

void fixture(Directory dir, MemoryStorage storage) {
  final Map<String, String> docs = <String, String>{
    'README.md':
        '# demo 总览\n\n文档索引：[架构](docs/architecture.md)、[API](docs/api.md)、'
        '[运维](docs/operations.md)。\n\n核心模块见 [core](packages/core/README.md)。\n',
    'docs/architecture.md':
        '# 架构分层\n\n网关层负责路由与鉴权；服务层包含核心模块与 UI 模块；'
        '存储层持久化数据。\n\n模块之间通过接口通信，边界清晰。\n',
    'docs/api.md': '# API 与 SSE\n\nHTTP 路由从网关进入；SSE 用于流式返回；鉴权在网关完成。\n',
    'docs/decisions.md': '# 决策记录\n\n决策：用 SSE 替代轮询，因为轮询延迟高且浪费连接。\n\n旧轮询方案已废弃。\n',
    'docs/operations.md': '# 运维\n\n限流与配置在部署时生效；回滚需要旧版本包。\n',
    'docs/glossary.md': '# 术语\n\nSSE 是流式协议；网关是入口；租约是写权限；轮询是旧方案。\n',
    'docs/legacy.md': '# 旧方案\n\n旧轮询方案已废弃，[迁移记录](missing.md) 没有同步。\n',
    'packages/core/README.md':
        '# core\n\n核心模块职责：会话与模型池；入口是 core.main。\n\n'
        '见 [UI 模块](../../packages/ui/README.md)。\n',
    'packages/ui/README.md': '# ui\n\nUI 模块通过接口与核心模块通信。\n',
    'packages/core/docs/changes.md': '# 迁移记录\n\n从旧轮询迁移到 SSE；引用没有同步的文档需要更新。\n',
  };
  for (final MapEntry<String, String> entry in docs.entries) {
    final File file = File(
      p.joinAll(<String>[dir.path, ...entry.key.split('/')]),
    );
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(entry.value);
  }
  final String repoKey = repoKeyOf(dir.path);
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
      'dimensions': 16,
      'vector': vectorFor('${chunk.heading} ${chunk.text}'),
    };
  }
  Map<String, Object?> node(String id, String kind, String label) =>
      <String, Object?>{'schema': 1, 'id': id, 'kind': kind, 'label': label};
  final List<String> docPaths = <String>[
    'README.md',
    'docs/architecture.md',
    'docs/api.md',
    'docs/decisions.md',
    'docs/operations.md',
    'docs/glossary.md',
    'docs/legacy.md',
    'packages/core/README.md',
    'packages/ui/README.md',
  ];
  final Map<String, Map<String, Object?>> nodes =
      <String, Map<String, Object?>>{
        '$repoKey#node:pkg:core': node('pkg:core', 'package', 'core'),
        '$repoKey#node:pkg:ui': node('pkg:ui', 'package', 'ui'),
        for (final String path in docPaths)
          '$repoKey#node:doc:$path': node('doc:$path', 'doc', p.basename(path)),
        for (final String name in <String>[
          '网关',
          'SSE',
          '限流',
          '回滚',
          '轮询',
          '租约',
          '鉴权',
          '迁移',
        ])
          '$repoKey#node:ent:concept:$name': node(
            'ent:concept:$name',
            'concept',
            name,
          ),
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
  final Map<String, Map<String, Object?>> edges =
      <String, Map<String, Object?>>{
        for (final String path in docPaths)
          '$repoKey#edge:belongs:$path': edge(
            'e-belongs:$path',
            'belongs_to',
            'doc:$path',
            path.startsWith('packages/ui/') ? 'pkg:ui' : 'pkg:core',
          ),
        '$repoKey#edge:documents:网关': edge(
          'e-documents:网关',
          'documents',
          'doc:docs/architecture.md',
          'ent:concept:网关',
        ),
        '$repoKey#edge:documents:SSE': edge(
          'e-documents:SSE',
          'documents',
          'doc:docs/api.md',
          'ent:concept:SSE',
        ),
        '$repoKey#edge:documents:限流': edge(
          'e-documents:限流',
          'documents',
          'doc:docs/operations.md',
          'ent:concept:限流',
        ),
        '$repoKey#edge:documents:回滚': edge(
          'e-documents:回滚',
          'documents',
          'doc:docs/operations.md',
          'ent:concept:回滚',
        ),
        '$repoKey#edge:documents:轮询': edge(
          'e-documents:轮询',
          'documents',
          'doc:docs/legacy.md',
          'ent:concept:轮询',
        ),
        '$repoKey#edge:documents:租约': edge(
          'e-documents:租约',
          'documents',
          'doc:docs/glossary.md',
          'ent:concept:租约',
        ),
        '$repoKey#edge:documents:鉴权': edge(
          'e-documents:鉴权',
          'documents',
          'doc:docs/api.md',
          'ent:concept:鉴权',
        ),
        '$repoKey#edge:documents:迁移': edge(
          'e-documents:迁移',
          'documents',
          'doc:docs/legacy.md',
          'ent:concept:迁移',
        ),
        '$repoKey#edge:documents:租约2': edge(
          'e-documents:租约2',
          'documents',
          'doc:docs/legacy.md',
          'ent:module:租约',
        ),
        '$repoKey#edge:ref1': edge(
          'e-ref1',
          'references',
          'doc:README.md',
          'doc:docs/architecture.md',
        ),
        '$repoKey#edge:ref2': edge(
          'e-ref2',
          'references',
          'doc:docs/architecture.md',
          'doc:docs/api.md',
        ),
        '$repoKey#edge:ref3': edge(
          'e-ref3',
          'references',
          'doc:docs/decisions.md',
          'doc:docs/glossary.md',
        ),
        '$repoKey#edge:ref4': edge(
          'e-ref4',
          'references',
          'doc:packages/core/README.md',
          'doc:packages/ui/README.md',
        ),
        '$repoKey#edge:mention:ghost': edge(
          'e-mention:ghost',
          'mentions',
          'doc:docs/legacy.md',
          'sym:ghost',
        ),
      };
  final Map<String, Map<String, Object?>> reports =
      <String, Map<String, Object?>>{
        '$repoKey#report:r1': <String, Object?>{
          'id': 'r1',
          'title': '分层与网关',
          'summary': '网关分层、服务层、存储层与模块边界。',
          'members': <String>['doc:docs/architecture.md', 'ent:concept:网关'],
        },
        '$repoKey#report:r2': <String, Object?>{
          'id': 'r2',
          'title': 'SSE 接口与决策',
          'summary': 'SSE 流式路由、鉴权与替代轮询的决策。',
          'members': <String>[
            'doc:docs/api.md',
            'doc:docs/decisions.md',
            'doc:docs/glossary.md',
            'ent:concept:SSE',
          ],
        },
        '$repoKey#report:r3': <String, Object?>{
          'id': 'r3',
          'title': '运维配置',
          'summary': '限流、配置与回滚流程。',
          'members': <String>[
            'doc:docs/operations.md',
            'ent:concept:限流',
            'ent:concept:回滚',
          ],
        },
      };
  final Map<String, Map<String, Object?>> states =
      <String, Map<String, Object?>>{
        '$repoKey#doc:docs/operations.md': <String, Object?>{
          'kind': 'doc',
          'doc': 'docs/operations.md',
          'stale': true,
          'updatedAt': '2026-01-01T00:00:00Z',
        },
      };
  storage.db
    ..['graph_chunks'] = chunkRecords
    ..['graph_vectors'] = vectorRecords
    ..['graph_nodes'] = nodes
    ..['graph_edges'] = edges
    ..['graph_reports'] = reports
    ..['doc_state'] = states;
}
