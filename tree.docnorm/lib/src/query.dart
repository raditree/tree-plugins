import 'dart:math' as math;

import 'baseline.dart';
import 'bm25.dart';
import 'policy.dart';
import 'rag.dart';
import 'scan.dart';

/// `docnorm.query --mode local|global|basic|hybrid|lexical`（DN-10）：
/// 只读检索，供产线准备阶段消费；默认 `auto`（有向量走 hybrid，否则 lexical）。
///
/// 检索口径（doc-normalization-recon §4.6）：
/// - basic：BM25 + cosine（余弦按归一化向量点积）；
/// - local：实体链接 → 1~2 跳扩展 → 候选文档内 BM25 + cosine；
/// - global：BM25 选社区报告（默认 8）→ 报告成员文档内 reduce；
/// - hybrid：local + global + basic 加权合并；
/// - 无可用 embedding / 查询向量时降级 lexical（纯 BM25），并显式标 `mode`。
Future<Map<String, Object?>> runQuery(
  String repo, {
  required StorageCall storage,
  required String question,
  String mode = 'auto',
  int topK = 0,
  RagEmbedCall? embed,
  String embeddingModel = '',
}) async {
  final String asked = question.trim();
  if (asked.isEmpty) {
    throw BaselineFailure(
      'docnorm.query 需要 question',
      code: 'invalid_arguments',
    );
  }
  final String requested = _validateMode(mode);
  final RepoIndex index = await RepoIndex.load(repo);
  final DocPolicy policy = DocPolicy.resolve(index);
  final Map<String, int> thresholds = policy.thresholds;
  final int k = topK > 0 ? math.min(topK, 20) : (thresholds['query_k'] ?? 10);
  final int hops = thresholds['query_local_hop'] ?? 2;
  final int globalReports = thresholds['query_global_reports'] ?? 8;

  final DocStore store = DocStore(storage);
  final String repoKey = repoKeyOf(index.root);
  final List<StoredRecord> chunkRecords = await store.listAll(
    'graph_chunks',
    '$repoKey#',
  );
  if (chunkRecords.isEmpty) {
    throw BaselineFailure(
      '没有文档分块索引：先运行 docnorm.graph.build rag=true --commit（D24）',
      code: 'graph_required',
    );
  }
  final Map<String, _Chunk> chunks = <String, _Chunk>{};
  for (final StoredRecord record in chunkRecords) {
    final Map<String, Object?> value = record.value;
    final String id = '${value['id'] ?? ''}';
    final String doc = '${value['doc'] ?? ''}';
    final String text = '${value['text'] ?? ''}';
    if (id.isEmpty || doc.isEmpty) continue;
    chunks[id] = _Chunk(
      id: id,
      doc: doc,
      heading: '${value['heading'] ?? ''}',
      text: text,
    );
  }
  if (chunks.isEmpty) {
    throw BaselineFailure(
      'graph_chunks 里没有可用记录：请确认 rag=true 且 --commit 成功',
      code: 'graph_required',
    );
  }

  final Map<String, Map<String, Object?>> nodes = await _loadMap(
    store,
    'graph_nodes',
    repoKey,
  );
  final List<Map<String, Object?>> edges = <Map<String, Object?>>[
    for (final StoredRecord record in await store.listAll(
      'graph_edges',
      '$repoKey#',
    ))
      record.value,
  ];
  final List<Map<String, Object?>> reports = <Map<String, Object?>>[
    for (final StoredRecord record in await store.listAll(
      'graph_reports',
      '$repoKey#',
    ))
      record.value,
  ];
  final Map<String, List<double>> vectors = <String, List<double>>{};
  for (final StoredRecord record in await store.listAll(
    'graph_vectors',
    '$repoKey#',
  )) {
    final String chunkId =
        '${record.value['chunk'] ?? record.value['id'] ?? ''}';
    final Object? raw = record.value['vector'];
    if (chunkId.isEmpty || raw is! List) continue;
    final List<double> vector = <double>[
      for (final Object? value in raw)
        if (value is num) value.toDouble(),
    ];
    if (vector.isNotEmpty) vectors[chunkId] = vector;
  }

  final Bm25Index bm25 = Bm25Index.build(<Bm25Document>[
    for (final _Chunk chunk in chunks.values)
      Bm25Document(id: chunk.id, text: '${chunk.heading}\n${chunk.text}'),
  ]);
  final Map<String, double> bm25Raw = bm25.score(asked);
  final Map<String, double> bm25Score = _normalize(bm25Raw);

  List<double>? queryVector;
  final List<String> reasons = <String>[];
  if (embed != null && requested != 'lexical') {
    final RagEmbedReply reply = await embed(
      RagEmbedRequest(inputs: <String>[asked], model: embeddingModel),
    );
    if (reply.ok && reply.vectors.length == 1) {
      queryVector = reply.vectors.first;
    } else if (reply.error.isNotEmpty && reply.code != 'no_embedding_model') {
      reasons.add('查询向量失败：${reply.error}');
    }
  }
  final bool vectorReady =
      queryVector != null &&
      vectors.isNotEmpty &&
      _dimensionsMatch(queryVector, vectors);

  String effective;
  if (requested == 'lexical') {
    effective = 'lexical';
  } else if (!vectorReady) {
    effective = 'lexical';
    if (requested != 'auto') {
      reasons.add('没有可用的查询向量 / 向量索引：$requested → lexical');
    } else {
      reasons.add('没有可用的 embedding 向量：检索降级 lexical');
    }
  } else {
    effective = requested == 'auto' ? 'hybrid' : requested;
  }

  final Map<String, double> cosine = _normalize(
    _cosineScores(asked, queryVector, vectors),
  );
  final _Ranking basic = _rankBasic(
    score: bm25Score,
    cosine: cosine,
    hasCosine: vectorReady,
  );
  final _Entities seeds = _linkEntities(asked, nodes);
  _Ranking local = _Ranking.empty();
  _Ranking global = _Ranking.empty();
  List<Map<String, Object?>> usedReports = <Map<String, Object?>>[];
  if (effective == 'local' || effective == 'hybrid') {
    if (seeds.ids.isEmpty) {
      reasons.add('实体链接未命中：local 退化为 basic');
      local = basic;
    } else {
      local = _rankLocal(
        question: asked,
        seeds: seeds,
        nodes: nodes,
        edges: edges,
        chunks: chunks,
        bm25Score: bm25Score,
        cosine: cosine,
        hasCosine: vectorReady,
        hops: hops,
        limit: k,
      );
    }
    if (local.scores.isEmpty) {
      reasons.add('local 候选为空：退化为 basic');
      local = basic;
    }
  }
  if (effective == 'global' || effective == 'hybrid') {
    if (reports.isEmpty) {
      reasons.add('没有社区报告：global 退化为 basic');
      global = basic;
    } else {
      final _GlobalRanking result = _rankGlobal(
        question: asked,
        reports: reports,
        chunks: chunks,
        bm25Score: bm25Score,
        cosine: cosine,
        hasCosine: vectorReady,
        reportLimit: globalReports,
        limit: k,
      );
      global = result.ranking;
      usedReports = result.reports;
    }
    if (global.scores.isEmpty) {
      reasons.add('global 候选为空：退化为 basic');
      global = basic;
    }
  }

  final _Ranking ranking;
  switch (effective) {
    case 'basic':
      ranking = basic;
    case 'local':
      ranking = _merge(<_Ranking>[local, basic], <double>[0.8, 0.2], k);
    case 'global':
      ranking = _merge(<_Ranking>[global, basic], <double>[0.8, 0.2], k);
    case 'hybrid':
      ranking = _merge(
        <_Ranking>[local, global, basic],
        <double>[0.45, 0.30, 0.25],
        k,
      );
    default:
      ranking = basic;
  }

  final List<Map<String, Object?>> results = <Map<String, Object?>>[
    for (final _Scored scored in ranking.top(k))
      if (chunks[scored.id] != null)
        <String, Object?>{
          'doc': chunks[scored.id]!.doc,
          'chunk_id': scored.id,
          'heading': chunks[scored.id]!.heading,
          'score': _round(scored.score),
          'sources': scored.sources.toList()..sort(),
          'snippet': _snippet(chunks[scored.id]!.text),
        },
  ];

  return <String, Object?>{
    'command': 'docnorm.query',
    'repo': index.root,
    'repo_key': repoKey,
    'question': asked,
    'requested_mode': requested,
    'mode': effective,
    'top_k': k,
    'results': results,
    'entities': <Map<String, Object?>>[
      for (final String id in seeds.ids)
        <String, Object?>{
          'id': id,
          'label': nodes[id]?['label'] ?? id,
          'kind': nodes[id]?['kind'] ?? '',
        },
    ],
    'reports': usedReports,
    'counts': <String, Object?>{
      'chunks': chunks.length,
      'vectors': vectors.length,
      'reports': reports.length,
      'nodes': nodes.length,
      'edges': edges.length,
      'seeds': seeds.ids.length,
      'results': results.length,
    },
    'degraded': effective == 'lexical' && requested != 'lexical',
    'reasons': reasons,
    'notes': const <String>[
      '只读检索：不写存储、不调用 LLM（embedding 只发一条查询向量）',
      'mode 为生效值；requested_mode 记录调用方请求，降级原因见 reasons',
      'basic=BM25+cosine；local=实体链接 1~2 跳；global=社区报告 reduce；hybrid=三者合并',
    ],
  };
}

String _validateMode(String raw) {
  final String mode = raw.trim().toLowerCase().isEmpty
      ? 'auto'
      : raw.trim().toLowerCase();
  const Set<String> allowed = <String>{
    'auto',
    'hybrid',
    'local',
    'global',
    'basic',
    'lexical',
  };
  if (!allowed.contains(mode)) {
    throw BaselineFailure(
      'mode 只能是 ${allowed.join(' / ')}：$raw',
      code: 'invalid_arguments',
    );
  }
  return mode;
}

class _Chunk {
  const _Chunk({
    required this.id,
    required this.doc,
    required this.heading,
    required this.text,
  });

  final String id;
  final String doc;
  final String heading;
  final String text;
}

class _Entities {
  const _Entities(this.ids);

  final List<String> ids;
}

class _Scored {
  _Scored(this.id, this.score, this.sources);

  final String id;
  double score;
  final Set<String> sources;
}

class _Ranking {
  _Ranking(this.scores, this.sources);

  _Ranking.empty()
    : scores = <String, double>{},
      sources = <String, Set<String>>{};

  final Map<String, double> scores;
  final Map<String, Set<String>> sources;

  List<_Scored> top(int k) {
    final List<String> ids = scores.keys.toList()
      ..sort((String a, String b) {
        final int byScore = scores[b]!.compareTo(scores[a]!);
        return byScore != 0 ? byScore : a.compareTo(b);
      });
    return <_Scored>[
      for (final String id in ids.take(k))
        _Scored(id, scores[id]!, sources[id] ?? <String>{}),
    ];
  }
}

_Ranking _rankBasic({
  required Map<String, double> score,
  required Map<String, double> cosine,
  required bool hasCosine,
}) {
  final _Ranking ranking = _Ranking.empty();
  final Set<String> ids = <String>{
    ...score.keys,
    if (hasCosine) ...cosine.keys,
  };
  for (final String id in ids) {
    final double value = hasCosine
        ? 0.6 * (score[id] ?? 0) + 0.4 * (cosine[id] ?? 0)
        : (score[id] ?? 0);
    if (value <= 0) continue;
    ranking.scores[id] = value;
    ranking.sources[id] = <String>{'basic'};
  }
  return ranking;
}

_Entities _linkEntities(
  String question,
  Map<String, Map<String, Object?>> nodes,
) {
  final String lower = question.toLowerCase();
  final List<String> queryTokens = tokenize(question).toSet().toList();
  final List<({String id, int weight})> hits = <({String id, int weight})>[];
  for (final MapEntry<String, Map<String, Object?>> entry in nodes.entries) {
    final String kind = '${entry.value['kind'] ?? ''}';
    if (kind == 'subpackage') continue;
    final String label = '${entry.value['label'] ?? ''}'.trim();
    if (label.length < 2) continue;
    final String labelLower = label.toLowerCase();
    int weight = 0;
    if (lower.contains(labelLower)) {
      weight = labelLower.length * 2;
    } else {
      final Set<String> labelTokens = tokenize(label).toSet();
      final int overlap = labelTokens.where(queryTokens.contains).length;
      if (overlap >= 2) weight = overlap;
    }
    if (weight > 0) hits.add((id: entry.key, weight: weight));
  }
  hits.sort((({String id, int weight}) a, ({String id, int weight}) b) {
    final int byWeight = b.weight.compareTo(a.weight);
    return byWeight != 0 ? byWeight : a.id.compareTo(b.id);
  });
  return _Entities(<String>[for (final hit in hits.take(8)) hit.id]);
}

_Ranking _rankLocal({
  required String question,
  required _Entities seeds,
  required Map<String, Map<String, Object?>> nodes,
  required List<Map<String, Object?>> edges,
  required Map<String, _Chunk> chunks,
  required Map<String, double> bm25Score,
  required Map<String, double> cosine,
  required bool hasCosine,
  required int hops,
  required int limit,
}) {
  final Map<String, List<String>> adjacency = <String, List<String>>{};
  for (final Map<String, Object?> edge in edges) {
    final String from = '${edge['from'] ?? ''}';
    final String to = '${edge['to'] ?? ''}';
    if (from.isEmpty || to.isEmpty) continue;
    adjacency.putIfAbsent(from, () => <String>[]).add(to);
    adjacency.putIfAbsent(to, () => <String>[]).add(from);
  }
  final Map<String, int> distance = <String, int>{};
  final List<String> frontier = <String>[];
  for (final String seed in seeds.ids) {
    if (nodes[seed] == null) continue;
    distance[seed] = 0;
    frontier.add(seed);
  }
  for (int hop = 1; hop <= hops; hop++) {
    final List<String> next = <String>[];
    for (final String node in frontier) {
      for (final String neighbor in adjacency[node] ?? const <String>[]) {
        if (distance.containsKey(neighbor)) continue;
        distance[neighbor] = hop;
        next.add(neighbor);
      }
    }
    frontier
      ..clear()
      ..addAll(next);
    if (frontier.isEmpty) break;
  }
  final Set<String> docs = <String>{
    for (final MapEntry<String, int> entry in distance.entries)
      if (entry.key.startsWith('doc:')) entry.key.substring(4),
  };
  final _Ranking ranking = _Ranking.empty();
  if (docs.isEmpty) return ranking;
  for (final _Chunk chunk in chunks.values) {
    if (!docs.contains(chunk.doc)) continue;
    final int docDistance = distance['doc:${chunk.doc}'] ?? hops + 1;
    final double bonus = docDistance > hops
        ? 0.0
        : 0.35 * (hops - docDistance + 1) / hops;
    final double base = hasCosine
        ? 0.6 * (bm25Score[chunk.id] ?? 0) + 0.4 * (cosine[chunk.id] ?? 0)
        : (bm25Score[chunk.id] ?? 0);
    final double score = base + bonus;
    if (score <= 0) continue;
    ranking.scores[chunk.id] = score;
    ranking.sources[chunk.id] = <String>{'local'};
  }
  return _merge(<_Ranking>[ranking], <double>[1.0], limit);
}

class _GlobalRanking {
  const _GlobalRanking({required this.ranking, required this.reports});

  final _Ranking ranking;
  final List<Map<String, Object?>> reports;
}

_GlobalRanking _rankGlobal({
  required String question,
  required List<Map<String, Object?>> reports,
  required Map<String, _Chunk> chunks,
  required Map<String, double> bm25Score,
  required Map<String, double> cosine,
  required bool hasCosine,
  required int reportLimit,
  required int limit,
}) {
  final Bm25Index index = Bm25Index.build(<Bm25Document>[
    for (final Map<String, Object?> report in reports)
      Bm25Document(
        id: '${report['id'] ?? ''}',
        text: '${report['title'] ?? ''}\n${report['summary'] ?? ''}',
      ),
  ]);
  final Map<String, double> reportScores = _normalize(index.score(question));
  if (reportScores.isEmpty) {
    return _GlobalRanking(
      ranking: _Ranking.empty(),
      reports: const <Map<String, Object?>>[],
    );
  }
  final List<String> reportIds =
      <String>[
        for (final MapEntry<String, double> entry in reportScores.entries)
          entry.key,
      ]..sort((String a, String b) {
        final int byScore = reportScores[b]!.compareTo(reportScores[a]!);
        return byScore != 0 ? byScore : a.compareTo(b);
      });
  final Map<String, List<_Chunk>> chunkByDoc = <String, List<_Chunk>>{};
  for (final _Chunk chunk in chunks.values) {
    chunkByDoc.putIfAbsent(chunk.doc, () => <_Chunk>[]).add(chunk);
  }
  final _Ranking ranking = _Ranking.empty();
  final List<Map<String, Object?>> used = <Map<String, Object?>>[];
  for (final String reportId in reportIds.take(reportLimit)) {
    final Map<String, Object?> report = reports.firstWhere(
      (Map<String, Object?> item) => '${item['id'] ?? ''}' == reportId,
      orElse: () => const <String, Object?>{},
    );
    final List<String> members = <String>[
      for (final Object? item
          in (report['members'] as List<dynamic>? ?? const <dynamic>[]))
        '$item',
    ];
    final Set<String> docs = <String>{
      for (final String member in members)
        if (member.startsWith('doc:')) member.substring(4),
    };
    int added = 0;
    for (final String doc in docs) {
      for (final _Chunk chunk in chunkByDoc[doc] ?? const <_Chunk>[]) {
        final double base = hasCosine
            ? 0.6 * (bm25Score[chunk.id] ?? 0) + 0.4 * (cosine[chunk.id] ?? 0)
            : (bm25Score[chunk.id] ?? 0);
        final double score = 0.6 * (reportScores[reportId] ?? 0) + 0.4 * base;
        if (score <= 0) continue;
        ranking.scores[chunk.id] = score;
        ranking.sources[chunk.id] = <String>{'global'};
        added += 1;
      }
    }
    if (added > 0) {
      used.add(<String, Object?>{
        'id': reportId,
        'title': report['title'] ?? '',
        'score': _round(reportScores[reportId] ?? 0),
      });
    }
  }
  return _GlobalRanking(
    ranking: _merge(<_Ranking>[ranking], <double>[1.0], limit),
    reports: used,
  );
}

_Ranking _merge(List<_Ranking> rankings, List<double> weights, int limit) {
  final Map<String, double> scores = <String, double>{};
  final Map<String, Set<String>> sources = <String, Set<String>>{};
  for (int i = 0; i < rankings.length; i++) {
    final double weight = i < weights.length ? weights[i] : 1.0;
    for (final MapEntry<String, double> entry in rankings[i].scores.entries) {
      scores[entry.key] = (scores[entry.key] ?? 0) + entry.value * weight;
      sources
          .putIfAbsent(entry.key, () => <String>{})
          .addAll(rankings[i].sources[entry.key] ?? const <String>{});
    }
  }
  final List<String> ids = scores.keys.toList()
    ..sort((String a, String b) {
      final int byScore = scores[b]!.compareTo(scores[a]!);
      return byScore != 0 ? byScore : a.compareTo(b);
    });
  final _Ranking out = _Ranking.empty();
  for (final String id in ids.take(limit)) {
    out.scores[id] = scores[id]!;
    out.sources[id] = sources[id] ?? <String>{};
  }
  return out;
}

Future<Map<String, Map<String, Object?>>> _loadMap(
  DocStore store,
  String collection,
  String repoKey,
) async {
  final Map<String, Map<String, Object?>> out =
      <String, Map<String, Object?>>{};
  for (final StoredRecord record in await store.listAll(
    collection,
    '$repoKey#',
  )) {
    final String id = '${record.value['id'] ?? ''}';
    if (id.isNotEmpty) out[id] = record.value;
  }
  return out;
}

Map<String, double> _cosineScores(
  String query,
  List<double>? queryVector,
  Map<String, List<double>> vectors,
) {
  if (queryVector == null) return <String, double>{};
  final Map<String, double> out = <String, double>{};
  for (final MapEntry<String, List<double>> entry in vectors.entries) {
    final List<double> vector = entry.value;
    if (vector.length != queryVector.length) continue;
    double dot = 0;
    double norm = 0;
    for (int i = 0; i < vector.length; i++) {
      dot += vector[i] * queryVector[i];
      norm += vector[i] * vector[i];
    }
    if (norm == 0) continue;
    out[entry.key] = dot / math.sqrt(norm);
  }
  return out;
}

bool _dimensionsMatch(List<double> query, Map<String, List<double>> vectors) {
  for (final List<double> vector in vectors.values) {
    if (vector.length == query.length) return true;
  }
  return false;
}

Map<String, double> _normalize(Map<String, double> scores) {
  if (scores.isEmpty) return <String, double>{};
  final double max = scores.values.reduce(math.max);
  if (max <= 0) return <String, double>{};
  return <String, double>{
    for (final MapEntry<String, double> entry in scores.entries)
      entry.key: entry.value / max,
  };
}

String _snippet(String text) {
  final String collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return collapsed.length <= 240
      ? collapsed
      : '${collapsed.substring(0, 240)}…';
}

double _round(double value) => double.parse(value.toStringAsFixed(6));
