import 'dart:convert';
import 'dart:math' as math;

import 'package:yograph/yograph.dart';

import 'baseline.dart';
import 'chunk.dart';
import 'contract.dart';
import 'generate.dart';
import 'plan.dart';
import 'scan.dart';

/// GraphRAG 索引（DN-9）：分块 → LLM 实体/关系抽取 → Leiden 社区 → 社区报告 →
/// embedding 向量索引，全部落 `tree.storage`；默认 dry-run 只出计划。
///
/// 口径（doc-normalization-recon §4.6）：
/// - 只对**文档**建图，不读代码；分块见 [chunkDocument]；
/// - 抽取每 chunk 一次 `llm.call`，按 `chunkHash` 缓存（同内容不重复付费）；
/// - 社区检测用 `yograph` 的 Leiden（MIT、纯 Dart、带 seed，确定性）；
/// - 报告每社区一份，按成员集合哈希缓存；
/// - 向量索引默认启用（模型池 `kind=embedding`），无可用模型时跳过并标
///   `mode: lexical`；
/// - 重建幂等：未变化 chunk / 社区 / 报告 / 向量一律 0 调用 0 写。
const List<String> kRagEntityKinds = <String>[
  'package',
  'module',
  'route',
  'point',
  'config',
  'concept',
  'decision',
];

const List<String> kRagRelationKinds = <String>[
  'belongs_to',
  'references',
  'implements',
  'supersedes',
  'conflicts_with',
  'documents',
];

const List<String> kRagCollections = <String>[
  'graph_chunks',
  'graph_communities',
  'graph_reports',
  'graph_vectors',
];

const int kRagCommunitySeed = 42;

/// 社区报告上限：避免一次把全图社区都付费摘要（超出部分记入 reasons）。
const int kRagMaxReports = 40;

/// 单次 embedding 批大小（tree.agent 侧上限 64，这里留一半余量）。
const int kRagEmbedBatch = 32;

class RagEmbedRequest {
  const RagEmbedRequest({
    required this.inputs,
    this.model = '',
    this.estimatedTokens = 0,
  });

  final List<String> inputs;
  final String model;
  final int estimatedTokens;
}

class RagEmbedReply {
  const RagEmbedReply({
    this.vectors = const <List<double>>[],
    this.model = '',
    this.dimensions = 0,
    this.error = '',
    this.code = '',
  });

  final List<List<double>> vectors;
  final String model;
  final int dimensions;
  final String error;
  final String code;

  bool get ok => error.trim().isEmpty;
}

typedef RagEmbedCall = Future<RagEmbedReply> Function(RagEmbedRequest request);

/// 一次 RAG 构建的产物：待合并的图节点/边 + 四个集合的期望/现有记录 + 摘要。
class RagBuildResult {
  RagBuildResult({
    required this.nodes,
    required this.edges,
    required this.desired,
    required this.existing,
    required this.summary,
  });

  /// 原始节点 id（如 `ent:concept:x`）→ 节点值（不含 storage key 前缀）。
  final Map<String, Map<String, Object?>> nodes;

  /// 原始边 id（`e-...`）→ 边值。
  final Map<String, Map<String, Object?>> edges;

  /// 集合名 → storage key（`<repoKey>#...`）→ 记录值。
  final Map<String, Map<String, Map<String, Object?>>> desired;

  /// 同上形状的现有记录（供 graph.dart 统一做 diff / 删除）。
  final Map<String, Map<String, Map<String, Object?>>> existing;

  final Map<String, Object?> summary;
}

/// 构建（或预览）GraphRAG 索引。
///
/// `commit=false` 时**不发新的 LLM / embedding 请求**：只复用已缓存的抽取与报告，
/// 统计 `pending`，避免只读预览烧 token。写盘由调用方（graph.build）统一处理。
Future<RagBuildResult> buildRagIndex(
  RepoIndex index, {
  required DocContract contract,
  required String repoKey,
  required DocStore store,
  required DocnormConfig config,
  required LlmCall llm,
  required RagEmbedCall embed,
  required Map<String, Map<String, Object?>> baseNodes,
  required Map<String, Map<String, Object?>> baseEdges,
  required bool commit,
  String embeddingModel = '',
}) async {
  final List<String> reasons = <String>[];
  bool degraded = false;

  final Map<String, Map<String, Object?>> existingChunks = await _existing(
    store,
    'graph_chunks',
    repoKey,
  );
  final Map<String, Map<String, Object?>> existingCommunities = await _existing(
    store,
    'graph_communities',
    repoKey,
  );
  final Map<String, Map<String, Object?>> existingReports = await _existing(
    store,
    'graph_reports',
    repoKey,
  );
  final Map<String, Map<String, Object?>> existingVectors = await _existing(
    store,
    'graph_vectors',
    repoKey,
  );

  final Map<String, String> docs = <String, String>{
    for (final RepoFile file in index.files)
      if (contract.docs.contains(file.path)) file.path: file.content,
  };
  final List<DocChunk> chunks = chunkDocuments(docs);

  // 抽取缓存：同 hash 的 chunk 复用已有抽取结果（跨文档也复用）。
  final Map<String, Map<String, Object?>> extractionByHash =
      <String, Map<String, Object?>>{};
  for (final Map<String, Object?> record in existingChunks.values) {
    final Object? hash = record['hash'];
    final Object? extraction = record['extraction'];
    if (hash is! String || extraction is! Map) continue;
    extractionByHash.putIfAbsent(
      hash,
      () => extraction.map(
        (Object? key, Object? value) =>
            MapEntry<String, Object?>('$key', value),
      ),
    );
  }

  final _RagBudget budget = _RagBudget(config.stageBudget);
  final Map<String, Map<String, Object?>> desiredChunks =
      <String, Map<String, Object?>>{};
  final Map<String, _RagEntityAgg> entities = <String, _RagEntityAgg>{};
  final Map<String, Map<String, Object?>> edges =
      <String, Map<String, Object?>>{};
  int cachedChunks = 0;
  int extractedChunks = 0;
  int pendingExtraction = 0;
  int failedExtraction = 0;
  int rejectedItems = 0;
  bool stopExtraction = false;

  for (final DocChunk chunk in chunks) {
    Map<String, Object?>? extraction = extractionByHash[chunk.hash];
    if (extraction != null) {
      cachedChunks += 1;
    } else if (!commit) {
      pendingExtraction += 1;
      continue;
    } else if (stopExtraction) {
      failedExtraction += 1;
      continue;
    } else {
      final String prompt = _extractionPrompt(chunk);
      final int tokens = estimateTokens(prompt.length, config.tokenScale);
      if (!budget.allows(tokens)) {
        reasons.add(
          'stage_budget 不足（已用 ${budget.spent} / ${config.stageBudget}），'
          '停止抽取新 chunk（已缓存的 chunk 仍写入索引）',
        );
        degraded = true;
        stopExtraction = true;
        failedExtraction += 1;
        continue;
      }
      budget.spent += tokens;
      budget.calls += 1;
      final GenerateReply reply = await llm(
        GenerateRequest(
          unit: chunk.doc,
          prompt: prompt,
          system: _extractionSystem,
          estimatedTokens: tokens,
        ),
      );
      if (!reply.ok) {
        failedExtraction += 1;
        degraded = true;
        _addReason(reasons, 'LLM 抽取失败（${chunk.doc}）：${reply.error}');
        continue;
      }
      final _Extraction? parsed = _parseExtraction(
        reply.json ?? _decodeJson(reply.text),
      );
      if (parsed == null) {
        failedExtraction += 1;
        degraded = true;
        _addReason(reasons, 'LLM 抽取回包不是合法 JSON（${chunk.doc}）');
        continue;
      }
      rejectedItems += parsed.rejected;
      extractedChunks += 1;
      extraction = parsed.toJson();
      extractionByHash[chunk.hash] = extraction;
    }

    desiredChunks['$repoKey#chunk:${chunk.id}'] = <String, Object?>{
      ...chunk.toJson(repoKey),
      'extraction': extraction,
    };
    _collectExtraction(
      chunk: chunk,
      extraction: extraction,
      repoKey: repoKey,
      baseNodes: baseNodes,
      entities: entities,
      edges: edges,
      reasons: reasons,
    );
  }

  // 实体节点（同 id 合并 docs；label 取字典序最小，保证确定性）。
  final Map<String, Map<String, Object?>> ragNodes =
      <String, Map<String, Object?>>{};
  for (final MapEntry<String, _RagEntityAgg> entry in entities.entries) {
    final List<String> docsOf = entry.value.docs.toList()..sort();
    ragNodes[entry.key] = <String, Object?>{
      'schema': 1,
      'repo': repoKey,
      'id': entry.key,
      'kind': entry.value.kind,
      'label': entry.value.label,
      'docs': docsOf,
      'sources': const <String>['llm'],
    };
  }

  final Map<String, Map<String, Object?>> mergedNodes =
      <String, Map<String, Object?>>{...baseNodes, ...ragNodes};
  final Map<String, Map<String, Object?>> mergedEdges =
      <String, Map<String, Object?>>{...baseEdges, ...edges};

  final _Communities communities = _detectCommunities(
    nodes: mergedNodes,
    edges: mergedEdges,
    reasons: reasons,
  );
  if (communities.failed) degraded = true;

  final Map<String, Map<String, Object?>> desiredCommunities =
      <String, Map<String, Object?>>{
        for (final MapEntry<String, List<String>> entry
            in communities.members.entries)
          '$repoKey#community:${entry.key}': <String, Object?>{
            'schema': 1,
            'repo': repoKey,
            'id': entry.key,
            'algorithm': 'leiden',
            'seed': kRagCommunitySeed,
            'size': entry.value.length,
            'members': entry.value,
          },
      };

  // 社区报告：size>=2 才做；按社区 id（成员集合哈希）缓存。
  final Map<String, Map<String, Object?>> desiredReports =
      <String, Map<String, Object?>>{};
  final Map<String, String> labelOf = <String, String>{
    for (final MapEntry<String, Map<String, Object?>> entry
        in mergedNodes.entries)
      entry.key: '${entry.value['label'] ?? entry.key}',
  };
  final List<MapEntry<String, List<String>>> reportTargets =
      <MapEntry<String, List<String>>>[
        for (final MapEntry<String, List<String>> entry
            in communities.members.entries)
          if (entry.value.length >= 2) entry,
      ]..sort((
        MapEntry<String, List<String>> a,
        MapEntry<String, List<String>> b,
      ) {
        final int bySize = b.value.length.compareTo(a.value.length);
        return bySize != 0 ? bySize : a.key.compareTo(b.key);
      });
  int cachedReports = 0;
  int generatedReports = 0;
  int pendingReports = 0;
  int targetIndex = 0;
  for (final MapEntry<String, List<String>> target in reportTargets) {
    final String key = '$repoKey#report:${target.key}';
    final Map<String, Object?>? existing = existingReports[key];
    if (existing != null && existing['community'] == target.key) {
      desiredReports[key] = existing;
      cachedReports += 1;
      continue;
    }
    if (!commit) {
      pendingReports += 1;
      continue;
    }
    if (targetIndex >= kRagMaxReports) {
      _addReason(
        reasons,
        '社区报告超过上限 $kRagMaxReports，其余 ${reportTargets.length - targetIndex} 个跳过',
      );
      degraded = true;
      break;
    }
    targetIndex += 1;
    final String prompt = _reportPrompt(
      community: target.key,
      members: target.value,
      labelOf: labelOf,
    );
    final int tokens = estimateTokens(prompt.length, config.tokenScale);
    if (!budget.allows(tokens)) {
      reasons.add(
        'stage_budget 不足（已用 ${budget.spent} / ${config.stageBudget}），停止社区报告',
      );
      degraded = true;
      break;
    }
    budget.spent += tokens;
    budget.calls += 1;
    final GenerateReply reply = await llm(
      GenerateRequest(
        unit: 'community:${target.key}',
        prompt: prompt,
        system: _reportSystem,
        estimatedTokens: tokens,
      ),
    );
    if (!reply.ok) {
      _addReason(reasons, '社区报告生成失败（${target.key}）：${reply.error}');
      degraded = true;
      continue;
    }
    final Object? decoded = reply.json ?? _decodeJson(reply.text);
    if (decoded is! Map) {
      _addReason(reasons, '社区报告回包不是 JSON 对象（${target.key}）');
      degraded = true;
      continue;
    }
    final String title = _text(decoded['title']);
    final String summary = _text(decoded['summary']);
    if (title.isEmpty || summary.length < 10) {
      _addReason(reasons, '社区报告缺 title / summary 过短（${target.key}）');
      degraded = true;
      continue;
    }
    desiredReports[key] = <String, Object?>{
      'schema': 1,
      'repo': repoKey,
      'id': target.key,
      'community': target.key,
      'size': target.value.length,
      'title': title,
      'summary': summary,
      'members': target.value,
    };
    generatedReports += 1;
  }
  if (reportTargets.length > kRagMaxReports && targetIndex >= kRagMaxReports) {
    degraded = true;
  }

  // 向量索引：先探测 embedding 模型（空 inputs 不发 HTTP）。
  RagEmbedReply probe = const RagEmbedReply();
  if (chunks.isNotEmpty) {
    probe = await embed(
      RagEmbedRequest(inputs: const <String>[], model: embeddingModel),
    );
  }
  final bool embeddingAvailable =
      chunks.isNotEmpty &&
      probe.ok &&
      probe.model.isNotEmpty &&
      probe.dimensions > 0;
  final int dimensions = probe.dimensions;
  final Map<String, Map<String, Object?>> desiredVectors =
      <String, Map<String, Object?>>{};
  int reusedVectors = 0;
  int embeddedVectors = 0;
  int pendingVectors = 0;
  bool partialVectors = false;

  if (chunks.isNotEmpty && !probe.ok) {
    if (probe.code == 'no_embedding_model') {
      _addReason(reasons, '没有可用的 embedding 模型：向量索引跳过，检索降级 lexical');
    } else {
      _addReason(reasons, 'embedding 探测失败：${probe.error}（降级 lexical）');
      degraded = true;
    }
  }

  if (embeddingAvailable) {
    final List<DocChunk> pending = <DocChunk>[];
    for (final DocChunk chunk in chunks) {
      final String key = '$repoKey#vector:${chunk.id}';
      final Map<String, Object?>? existing = existingVectors[key];
      final Object? vector = existing?['vector'];
      // dry-run 没有抽取结果也要报"还需要多少向量"，否则预览会显示 0。
      final bool indexed =
          !commit || desiredChunks.containsKey('$repoKey#chunk:${chunk.id}');
      if (existing != null &&
          existing['hash'] == chunk.hash &&
          existing['model'] == probe.model &&
          (existing['dimensions'] as num?)?.toInt() == dimensions &&
          vector is List &&
          vector.length == dimensions &&
          indexed) {
        desiredVectors[key] = existing;
        reusedVectors += 1;
      } else if (indexed) {
        pending.add(chunk);
      }
    }
    if (!commit) {
      pendingVectors = pending.length;
    } else {
      for (int start = 0; start < pending.length; start += kRagEmbedBatch) {
        final int end = start + kRagEmbedBatch > pending.length
            ? pending.length
            : start + kRagEmbedBatch;
        final List<DocChunk> batch = pending.sublist(start, end);
        final RagEmbedReply reply = await embed(
          RagEmbedRequest(
            inputs: <String>[for (final DocChunk chunk in batch) chunk.text],
            model: probe.model,
          ),
        );
        if (!reply.ok) {
          _addReason(reasons, 'embedding 失败：${reply.error}');
          degraded = true;
          partialVectors = true;
          break;
        }
        if (reply.model.isNotEmpty && reply.model != probe.model) {
          _addReason(
            reasons,
            'embedding 模型在构建中变化（${probe.model} → ${reply.model}），停止写入剩余向量',
          );
          degraded = true;
          partialVectors = true;
          break;
        }
        if (reply.vectors.length != batch.length) {
          _addReason(
            reasons,
            'embedding 回包条数不符：请求 ${batch.length}，返回 ${reply.vectors.length}',
          );
          degraded = true;
          partialVectors = true;
          break;
        }
        bool badDimensions = false;
        for (final List<double> vector in reply.vectors) {
          if (vector.length != dimensions) badDimensions = true;
        }
        if (badDimensions) {
          _addReason(reasons, 'embedding 向量维度与配置不一致（$dimensions）');
          degraded = true;
          partialVectors = true;
          break;
        }
        for (int i = 0; i < batch.length; i++) {
          final DocChunk chunk = batch[i];
          desiredVectors['$repoKey#vector:${chunk.id}'] = <String, Object?>{
            'schema': 1,
            'repo': repoKey,
            'id': chunk.id,
            'chunk': chunk.id,
            'doc': chunk.doc,
            'hash': chunk.hash,
            'model': probe.model,
            'dimensions': dimensions,
            'vector': _normalize(reply.vectors[i]),
          };
          embeddedVectors += 1;
        }
      }
    }
  }

  final int readyVectors = reusedVectors + embeddedVectors;
  final bool allVectors = chunks.isNotEmpty && readyVectors == chunks.length;
  final String mode = embeddingAvailable ? 'hybrid' : 'lexical';
  final String vectorMode;
  if (!embeddingAvailable) {
    vectorMode = 'lexical';
  } else if (!commit) {
    vectorMode = 'planned';
  } else if (partialVectors) {
    vectorMode = 'partial';
  } else if (allVectors) {
    vectorMode = 'embedding';
  } else {
    vectorMode = 'partial';
  }

  final Map<String, Object?> summary = <String, Object?>{
    'mode': mode,
    'vector_mode': vectorMode,
    'embedding_model': embeddingAvailable ? probe.model : '',
    'dimensions': embeddingAvailable ? dimensions : 0,
    'chunks': <String, Object?>{
      'total': chunks.length,
      'cached': cachedChunks,
      'extracted': extractedChunks,
      'pending': pendingExtraction,
      'failed': failedExtraction,
      'rejected_items': rejectedItems,
      'docs': docs.length,
    },
    'communities': <String, Object?>{
      'total': communities.members.length,
      'reports_cached': cachedReports,
      'reports_generated': generatedReports,
      'reports_pending': pendingReports,
    },
    'vectors': <String, Object?>{
      'total': chunks.length,
      'reused': reusedVectors,
      'embedded': embeddedVectors,
      'pending': pendingVectors,
    },
    'budget': <String, Object?>{
      'stage_budget': config.stageBudget,
      'spent_tokens': budget.spent,
      'calls': budget.calls,
      'exhausted': budget.exhausted,
    },
    'degraded': degraded,
    'reasons': reasons,
  };

  return RagBuildResult(
    nodes: ragNodes,
    edges: edges,
    desired: <String, Map<String, Map<String, Object?>>>{
      'graph_chunks': desiredChunks,
      'graph_communities': desiredCommunities,
      'graph_reports': desiredReports,
      'graph_vectors': desiredVectors,
    },
    existing: <String, Map<String, Map<String, Object?>>>{
      'graph_chunks': existingChunks,
      'graph_communities': existingCommunities,
      'graph_reports': existingReports,
      'graph_vectors': existingVectors,
    },
    summary: summary,
  );
}

class _RagBudget {
  _RagBudget(this.stageBudget);

  final int stageBudget;
  int spent = 0;
  int calls = 0;
  bool exhausted = false;

  bool allows(int tokens) {
    if (exhausted) return false;
    if (spent + tokens <= stageBudget) return true;
    exhausted = true;
    return false;
  }
}

class _Extraction {
  const _Extraction({
    required this.entities,
    required this.relations,
    required this.rejected,
  });

  final List<Map<String, Object?>> entities;
  final List<Map<String, Object?>> relations;
  final int rejected;

  Map<String, Object?> toJson() => <String, Object?>{
    'entities': entities,
    'relations': relations,
  };
}

class _RagEntityAgg {
  _RagEntityAgg({required this.kind, required this.label});

  final String kind;
  final String label;
  final Set<String> docs = <String>{};
}

class _Communities {
  _Communities({required this.members, required this.failed});

  /// 社区 id（成员集合哈希）→ 成员节点 id（有序）。
  final Map<String, List<String>> members;
  final bool failed;
}

Future<Map<String, Map<String, Object?>>> _existing(
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
    out[record.key] = record.value;
  }
  return out;
}

String _extractionPrompt(DocChunk chunk) {
  return <String>[
    '你是文档知识图谱抽取器：只从给定文档片段抽取实体与关系。',
    '',
    '实体 kind 只能是：${kRagEntityKinds.join(' / ')}',
    '关系 kind 只能是：${kRagRelationKinds.join(' / ')}',
    '只输出严格 JSON：',
    '{"entities":[{"kind":"concept","name":"名字"}],'
        '"relations":[{"kind":"references","from":"名字","to":"名字"}]}',
    '约束：',
    '- 名字必须逐字出现在片段里或能由片段直接指认，不要编造；',
    '- relation 的 from / to 必须是同一片段里出现过的实体名或包名；',
    '- 没有可抽的就回 {"entities":[],"relations":[]}。',
    '',
    '文档：${chunk.doc}',
    '章节：${chunk.heading}',
    '--- 片段 ---',
    chunk.text,
  ].join('\n');
}

const String _extractionSystem = '你是严谨的中文技术文档知识图谱抽取器：只输出 JSON 对象，不要代码围栏或额外说明。';

String _reportPrompt({
  required String community,
  required List<String> members,
  required Map<String, String> labelOf,
}) {
  final List<String> labels = <String>[
    for (final String id in members.take(40)) '${labelOf[id] ?? id}（$id）',
  ];
  return <String>[
    '下面是文档知识图谱中的一个社区（主题簇）。请写一份可检索的社区摘要。',
    '',
    '社区：$community（${members.length} 个节点）',
    '成员：',
    for (final String label in labels) '- $label',
    if (members.length > labels.length)
      '- …（其余 ${members.length - labels.length} 个省略）',
    '',
    '只输出严格 JSON：{"title":"不超过 30 字","summary":"80~200 字，说明这个簇讲什么、'
        '有哪些入口/决策/约束，以及和哪些概念相连"}',
    '不要编造成员之外的事实；不确定就写得保守。',
  ].join('\n');
}

const String _reportSystem = '你是严谨的中文技术文档摘要助手：只输出 JSON 对象，不要代码围栏或额外说明。';

_Extraction? _parseExtraction(Object? decoded) {
  if (decoded is! Map) return null;
  final Map<String, dynamic> map = decoded.map(
    (Object? key, Object? value) => MapEntry<String, dynamic>('$key', value),
  );
  final bool hasEntities = map.containsKey('entities');
  final bool hasRelations = map.containsKey('relations');
  if (!hasEntities && !hasRelations) return null;

  int rejected = 0;
  final Map<String, Map<String, Object?>> entities =
      <String, Map<String, Object?>>{};
  final Object? rawEntities = map['entities'];
  if (rawEntities is List) {
    for (final Object? item in rawEntities) {
      if (item is! Map) {
        rejected += 1;
        continue;
      }
      final String kind = _text(item['kind']).toLowerCase();
      final String name = _cleanName(item['name']);
      if (!kRagEntityKinds.contains(kind) || name.isEmpty) {
        rejected += 1;
        continue;
      }
      entities.putIfAbsent(
        '$kind|${name.toLowerCase()}',
        () => <String, Object?>{'kind': kind, 'name': name},
      );
      if (entities.length >= 40) break;
    }
  } else if (hasEntities) {
    rejected += 1;
  }

  final Map<String, Map<String, Object?>> relations =
      <String, Map<String, Object?>>{};
  final Object? rawRelations = map['relations'];
  if (rawRelations is List) {
    for (final Object? item in rawRelations) {
      if (item is! Map) {
        rejected += 1;
        continue;
      }
      final String kind = _text(item['kind']).toLowerCase();
      final String from = _cleanName(item['from']);
      final String to = _cleanName(item['to']);
      if (!kRagRelationKinds.contains(kind) ||
          from.isEmpty ||
          to.isEmpty ||
          from.toLowerCase() == to.toLowerCase()) {
        rejected += 1;
        continue;
      }
      relations.putIfAbsent(
        '$kind|${from.toLowerCase()}|${to.toLowerCase()}',
        () => <String, Object?>{'kind': kind, 'from': from, 'to': to},
      );
      if (relations.length >= 60) break;
    }
  } else if (hasRelations) {
    rejected += 1;
  }

  final List<Map<String, Object?>> sortedEntities = entities.values.toList()
    ..sort((Map<String, Object?> a, Map<String, Object?> b) {
      final int byKind = '${a['kind']}'.compareTo('${b['kind']}');
      return byKind != 0 ? byKind : '${a['name']}'.compareTo('${b['name']}');
    });
  final List<Map<String, Object?>> sortedRelations = relations.values.toList()
    ..sort((Map<String, Object?> a, Map<String, Object?> b) {
      final int byKind = '${a['kind']}'.compareTo('${b['kind']}');
      if (byKind != 0) return byKind;
      final int byFrom = '${a['from']}'.compareTo('${b['from']}');
      return byFrom != 0 ? byFrom : '${a['to']}'.compareTo('${b['to']}');
    });
  return _Extraction(
    entities: sortedEntities,
    relations: sortedRelations,
    rejected: rejected,
  );
}

void _collectExtraction({
  required DocChunk chunk,
  required Map<String, Object?> extraction,
  required String repoKey,
  required Map<String, Map<String, Object?>> baseNodes,
  required Map<String, _RagEntityAgg> entities,
  required Map<String, Map<String, Object?>> edges,
  required List<String> reasons,
}) {
  final Map<String, String> byName = <String, String>{};
  final Object? rawEntities = extraction['entities'];
  if (rawEntities is List) {
    for (final Object? item in rawEntities) {
      if (item is! Map) continue;
      final String kind = _text(item['kind']);
      final String name = _cleanName(item['name']);
      if (name.isEmpty || !kRagEntityKinds.contains(kind)) continue;
      final String id = 'ent:$kind:${_slug(name)}';
      byName.putIfAbsent(name.toLowerCase(), () => id);
      final _RagEntityAgg agg = entities.putIfAbsent(
        id,
        () => _RagEntityAgg(kind: kind, label: name),
      );
      agg.docs.add(chunk.doc);
      _addEdge(
        edges,
        kind: 'documents',
        from: 'doc:${chunk.doc}',
        to: id,
        repoKey: repoKey,
        source: chunk.doc,
        confidence: 1.0,
      );
    }
  }

  final Map<String, String> labelIndex = <String, String>{};
  for (final MapEntry<String, Map<String, Object?>> entry
      in baseNodes.entries) {
    final String kind = '${entry.value['kind'] ?? ''}';
    if (kind != 'doc' &&
        kind != 'package' &&
        kind != 'subpackage' &&
        kind != 'symbol') {
      continue;
    }
    final String label = _cleanName(entry.value['label']);
    if (label.isEmpty) continue;
    labelIndex.putIfAbsent(label.toLowerCase(), () => entry.key);
  }

  final Object? rawRelations = extraction['relations'];
  if (rawRelations is! List) return;
  for (final Object? item in rawRelations) {
    if (item is! Map) continue;
    final String kind = _text(item['kind']);
    final String fromName = _cleanName(item['from']);
    final String toName = _cleanName(item['to']);
    if (!kRagRelationKinds.contains(kind) ||
        fromName.isEmpty ||
        toName.isEmpty) {
      continue;
    }
    final String? from =
        byName[fromName.toLowerCase()] ?? labelIndex[fromName.toLowerCase()];
    final String? to =
        byName[toName.toLowerCase()] ?? labelIndex[toName.toLowerCase()];
    if (from == null || to == null || from == to) {
      _addReason(reasons, '关系端点未解析：$fromName -[$kind]-> $toName（${chunk.doc}）');
      continue;
    }
    _addEdge(
      edges,
      kind: kind,
      from: from,
      to: to,
      repoKey: repoKey,
      source: chunk.doc,
      confidence: 0.8,
    );
  }
}

void _addEdge(
  Map<String, Map<String, Object?>> edges, {
  required String kind,
  required String from,
  required String to,
  required String repoKey,
  required String source,
  required double confidence,
}) {
  final String id = 'e-${fnv1aHex('$kind|$from|$to')}';
  edges.putIfAbsent(
    id,
    () => <String, Object?>{
      'schema': 1,
      'repo': repoKey,
      'id': id,
      'kind': kind,
      'from': from,
      'to': to,
      'from_kind': from.split(':').first,
      'to_kind': to.split(':').first,
      'source': source,
      'confidence': confidence,
      'extractor': 'llm',
    },
  );
}

_Communities _detectCommunities({
  required Map<String, Map<String, Object?>> nodes,
  required Map<String, Map<String, Object?>> edges,
  required List<String> reasons,
}) {
  try {
    final List<String> ids = nodes.keys.toList()..sort();
    if (ids.length <= 1) {
      return _Communities(
        members: <String, List<String>>{
          if (ids.isNotEmpty) 'community-${fnv1aHex(ids.first)}': ids,
        },
        failed: false,
      );
    }
    final Map<String, int> indexOf = <String, int>{
      for (int i = 0; i < ids.length; i++) ids[i]: i,
    };
    final Map<String, List<String>> pairKey = <String, List<String>>{};
    for (final Map<String, Object?> edge in edges.values) {
      final String from = '${edge['from'] ?? ''}';
      final String to = '${edge['to'] ?? ''}';
      if (!indexOf.containsKey(from) ||
          !indexOf.containsKey(to) ||
          from == to) {
        continue;
      }
      final String key = from.compareTo(to) <= 0
          ? '$from\u0000$to'
          : '$to\u0000$from';
      pairKey.putIfAbsent(key, () => <String>[from, to]);
    }

    final SimpleGraph<String, double> graph =
        SimpleGraph<String, double>.undirected();
    for (final String id in ids) {
      graph.addNode(indexOf[id]!, data: id);
    }
    for (final List<String> pair in pairKey.values) {
      graph.addEdge(indexOf[pair[0]]!, indexOf[pair[1]]!, data: 1.0);
    }
    final CommunityResult result = Leiden.detect(
      graph,
      seed: kRagCommunitySeed,
    );
    final Map<int, List<String>> grouped = <int, List<String>>{};
    for (final MapEntry<int, int> entry in result.assignments.entries) {
      grouped.putIfAbsent(entry.value, () => <String>[]).add(ids[entry.key]);
    }
    final Map<String, List<String>> members = <String, List<String>>{};
    for (final List<String> group in grouped.values) {
      group.sort();
      final String id = 'community-${fnv1aHex(group.join('\n'))}';
      members.putIfAbsent(id, () => group);
    }
    return _Communities(members: members, failed: false);
  } catch (error) {
    reasons.add('社区检测失败（Leiden）：$error');
    return _Communities(members: <String, List<String>>{}, failed: true);
  }
}

List<double> _normalize(List<double> vector) {
  double norm = 0;
  for (final double value in vector) {
    norm += value * value;
  }
  norm = math.sqrt(norm);
  if (norm == 0) return List<double>.of(vector);
  return <double>[for (final double value in vector) value / norm];
}

String _cleanName(Object? value) {
  final String text = _text(value).replaceAll(RegExp(r'\s+'), ' ').trim();
  return text.length <= 120 ? text : text.substring(0, 120);
}

String _slug(String name) {
  final String lower = name.toLowerCase();
  final StringBuffer buffer = StringBuffer();
  for (final int rune in lower.runes) {
    final String char = String.fromCharCode(rune);
    final bool keep = RegExp(r'[a-z0-9\u4e00-\u9fff._\-]').hasMatch(char);
    if (keep) {
      buffer.write(char);
    } else if (buffer.isNotEmpty && !buffer.toString().endsWith('-')) {
      buffer.write('-');
    }
  }
  String slug = buffer.toString();
  while (slug.endsWith('-')) {
    slug = slug.substring(0, slug.length - 1);
  }
  if (slug.isEmpty) slug = fnv1aHex(lower);
  return slug.length <= 80 ? slug : slug.substring(0, 80);
}

void _addReason(List<String> reasons, String reason) {
  if (reasons.length >= 20) return;
  if (!reasons.contains(reason)) reasons.add(reason);
}

String _text(Object? value) => (value ?? '').toString().trim();

Object? _decodeJson(String text) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  try {
    return jsonDecode(trimmed);
  } on FormatException {
    final RegExpMatch? match = RegExp(r'\{[\s\S]*\}').firstMatch(trimmed);
    if (match == null) return null;
    try {
      return jsonDecode(match.group(0)!);
    } on FormatException {
      return null;
    }
  }
}
