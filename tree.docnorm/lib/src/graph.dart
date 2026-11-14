import 'dart:convert';

import 'package:path/path.dart' as p;

import 'baseline.dart';
import 'contract.dart';
import 'generate.dart';
import 'plan.dart';
import 'policy.dart';
import 'rag.dart';
import 'scan.dart';

/// `docnorm.graph.build [--commit] [rag]`：建文档图。
///
/// DN-8（默认）：只建**三类确定性边**：
/// - `belongs_to`：文档 → 所属包（按最具体包 root）；
/// - `references`：文档 → 文档（仓内可解析的相对链接，复用契约链接解析与
///   `link_fallbacks`）；
/// - `mentions`：文档 → 符号（策略 `mentions` 点名 + 包公开声明名在文档中出现）。
///
/// DN-9（`rag: true`）：在确定性图之上追加 GraphRAG 索引——分块、LLM 实体/关系
/// 抽取（按 chunkHash 缓存）、Leiden 社区、社区报告、embedding 向量；无 embedding
/// 模型时索引跳过并标 `mode: lexical`。
///
/// 默认 dry-run，`commit` 才写 `graph_nodes` / `graph_edges` 与四个 RAG 集合；
/// 只删本仓前缀内本次不再生成的记录；重复运行 0 写。
Future<Map<String, Object?>> runGraphBuild(
  String repo, {
  required StorageCall storage,
  bool commit = false,
  String runId = '',
  bool rag = false,
  LlmCall? llm,
  RagEmbedCall? embed,
  Map<String, Object?> settings = const <String, Object?>{},
  Map<String, Object?> overrides = const <String, Object?>{},
  Map<String, String>? environment,
  String embeddingModel = '',
}) async {
  final GitRepository git = await GitRepository.open(repo);
  final RepoIndex index = await RepoIndex.load(repo);
  final DocPolicy policy = DocPolicy.resolve(index);
  final DocContract contract = inspectIndex(index, policy);
  final ScanResult scan = await scanIndex(index);
  final DocStore store = DocStore(storage);
  final String repoKey = repoKeyOf(index.root);
  final GitChanges changes = await git.changedFiles();

  final Set<String> docs = contract.docs.toSet();
  final Map<String, RepoFile> files = <String, RepoFile>{
    for (final RepoFile file in index.files) file.path: file,
  };
  final Map<String, Map<String, Object?>> nodes =
      <String, Map<String, Object?>>{};
  final Map<String, Map<String, Object?>> edges =
      <String, Map<String, Object?>>{};

  void addNode(Map<String, Object?> node) {
    final String id = '${node['id']}';
    nodes.putIfAbsent(id, () => node);
  }

  void addEdge(String kind, String from, String to, {String source = ''}) {
    final String id = 'e-${_fnv1a('$kind|$from|$to')}';
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
        if (source.isNotEmpty) 'source': source,
        'confidence': 1.0,
      },
    );
  }

  for (final PackageUnit unit in scan.packages) {
    addNode(<String, Object?>{
      'schema': 1,
      'repo': repoKey,
      'id': 'pkg:${unit.id}',
      'kind': 'package',
      'label': unit.id,
      'root': unit.root,
      'language': unit.language,
      'exports': unit.exports.length,
    });
    for (final SubUnit sub in unit.subpackages) {
      addNode(<String, Object?>{
        'schema': 1,
        'repo': repoKey,
        'id': 'sub:${sub.path}',
        'kind': 'subpackage',
        'label': p.posix.basename(sub.path),
        'root': sub.path,
        'package': unit.id,
      });
    }
  }

  for (final String doc in contract.docs) {
    addNode(<String, Object?>{
      'schema': 1,
      'repo': repoKey,
      'id': 'doc:$doc',
      'kind': 'doc',
      'label': p.posix.basename(doc),
      'path': doc,
      'sections': (contract.sections[doc] ?? const <String>[]).length,
    });
    final PackageUnit? owner = _ownerPackage(doc, scan.packages);
    if (owner != null) {
      addEdge('belongs_to', 'doc:$doc', 'pkg:${owner.id}', source: doc);
    }
  }

  // references：只认仓内可解析、且落点仍在文档集合里的相对链接。
  for (final String doc in contract.docs) {
    final RepoFile? file = files[doc];
    if (file == null) continue;
    final String base = p.posix.dirname(doc);
    final String baseDir = base == '.' ? '' : base;
    bool inFence = false;
    for (final String line in file.content.split('\n')) {
      if (line.trimLeft().startsWith('```')) {
        inFence = !inFence;
        continue;
      }
      if (inFence) continue;
      for (final RegExpMatch match in _mdLink.allMatches(line)) {
        final String? target = _resolveDocLink(
          docs,
          policy,
          baseDir,
          match.group(1) ?? '',
        );
        if (target == null || target == doc) continue;
        addEdge('references', 'doc:$doc', 'doc:$target', source: doc);
      }
    }
  }

  // mentions：策略点名 + 包公开声明名在文档正文中出现（按标识符边界匹配）。
  final Map<String, Set<String>> symbolOwners = <String, Set<String>>{};
  for (final PackageUnit unit in scan.packages) {
    for (final String symbol in unit.exports) {
      symbolOwners.putIfAbsent(symbol, () => <String>{}).add(unit.id);
    }
  }
  for (final MentionRule rule in policy.mentions) {
    final RepoFile? file = files[rule.doc];
    if (file == null || !docs.contains(rule.doc)) continue;
    for (final String symbol in rule.symbols) {
      if (!file.content.contains(symbol)) continue;
      addEdge('mentions', 'doc:${rule.doc}', 'sym:$symbol', source: rule.doc);
      symbolOwners.putIfAbsent(symbol, () => <String>{});
    }
  }
  final List<String> symbols = symbolOwners.keys.toList()..sort();
  for (final String doc in contract.docs) {
    final RepoFile? file = files[doc];
    if (file == null) continue;
    final List<String> mentioned = <String>[];
    for (final String symbol in symbols) {
      if (symbol.length < 2 || !file.content.contains(symbol)) continue;
      if (!_identifierIn(file.content, symbol)) continue;
      mentioned.add(symbol);
    }
    mentioned.sort();
    for (final String symbol in mentioned.take(50)) {
      addEdge('mentions', 'doc:$doc', 'sym:$symbol', source: doc);
    }
  }
  for (final MapEntry<String, Set<String>> entry in symbolOwners.entries) {
    final bool used = edges.values.any(
      (Map<String, Object?> edge) =>
          edge['kind'] == 'mentions' && edge['to'] == 'sym:${entry.key}',
    );
    if (!used) continue;
    addNode(<String, Object?>{
      'schema': 1,
      'repo': repoKey,
      'id': 'sym:${entry.key}',
      'kind': 'symbol',
      'label': entry.key,
      'packages': entry.value.toList()..sort(),
    });
  }

  RagBuildResult? ragResult;
  final Map<String, Map<String, Map<String, Object?>>> ragDesired =
      <String, Map<String, Map<String, Object?>>>{};
  final Map<String, Map<String, Map<String, Object?>>> ragExisting =
      <String, Map<String, Map<String, Object?>>>{};
  if (rag) {
    if (llm == null || embed == null) {
      throw BaselineFailure(
        'graph.build 的 rag=true 需要 llm 与 embed 通道（llm.call / llm.embed）',
        code: 'rag_unavailable',
      );
    }
    final DocnormConfig config = DocnormConfig.load(
      index,
      environment: environment,
      settings: settings,
      overrides: overrides,
    );
    ragResult = await buildRagIndex(
      index,
      contract: contract,
      repoKey: repoKey,
      store: store,
      config: config,
      llm: llm,
      embed: embed,
      baseNodes: nodes,
      baseEdges: edges,
      commit: commit,
      embeddingModel: embeddingModel,
    );
    nodes.addAll(ragResult.nodes);
    edges.addAll(ragResult.edges);
    ragDesired.addAll(ragResult.desired);
    ragExisting.addAll(ragResult.existing);
  }

  final Map<String, Map<String, Object?>> desiredNodes =
      <String, Map<String, Object?>>{
        for (final MapEntry<String, Map<String, Object?>> entry
            in nodes.entries)
          '$repoKey#node:${entry.key}': entry.value,
      };
  final Map<String, Map<String, Object?>> desiredEdges =
      <String, Map<String, Object?>>{
        for (final MapEntry<String, Map<String, Object?>> entry
            in edges.entries)
          '$repoKey#edge:${entry.key}': entry.value,
      };

  final Map<String, Map<String, Object?>> existingNodes =
      <String, Map<String, Object?>>{
        for (final StoredRecord record in await store.listAll(
          'graph_nodes',
          '$repoKey#',
        ))
          record.key: record.value,
      };
  final Map<String, Map<String, Object?>> existingEdges =
      <String, Map<String, Object?>>{
        for (final StoredRecord record in await store.listAll(
          'graph_edges',
          '$repoKey#',
        ))
          record.key: record.value,
      };

  final List<Map<String, Object?>> writes = <Map<String, Object?>>[];
  _collectWrites('graph_nodes', existingNodes, desiredNodes, writes);
  _collectWrites('graph_edges', existingEdges, desiredEdges, writes);
  for (final String collection in kRagCollections) {
    _collectWrites(
      collection,
      ragExisting[collection] ?? <String, Map<String, Object?>>{},
      ragDesired[collection] ?? <String, Map<String, Object?>>{},
      writes,
    );
  }

  bool applied = false;
  if (commit && writes.isNotEmpty) {
    await store.ensureAll();
    await store.tx(<Map<String, Object?>>[
      for (final Map<String, Object?> write in writes)
        <String, Object?>{
          'op': write['op'],
          'collection': write['collection'],
          'key': write['key'],
          if (write['op'] == 'put') 'value': write['value'],
        },
    ]);
    applied = true;
  }

  final Map<String, int> nodeKinds = <String, int>{};
  final List<Map<String, Object?>> nodeList = <Map<String, Object?>>[];
  for (final String id in nodes.keys.toList()..sort()) {
    final Map<String, Object?> node = nodes[id]!;
    final String kind = '${node['kind']}';
    nodeKinds[kind] = (nodeKinds[kind] ?? 0) + 1;
    nodeList.add(<String, Object?>{
      'id': id,
      'kind': kind,
      'label': node['label'],
    });
  }
  final Map<String, int> edgeKinds = <String, int>{};
  final List<Map<String, Object?>> edgeList = <Map<String, Object?>>[];
  for (final String id in edges.keys.toList()..sort()) {
    final Map<String, Object?> edge = edges[id]!;
    final String kind = '${edge['kind']}';
    edgeKinds[kind] = (edgeKinds[kind] ?? 0) + 1;
    edgeList.add(<String, Object?>{
      'id': id,
      'kind': kind,
      'from': edge['from'],
      'to': edge['to'],
    });
  }

  final String digest = _fnv1a((edges.keys.toList()..sort()).join('\n'));
  return <String, Object?>{
    'command': 'docnorm.graph.build',
    'repo': index.root,
    'repo_key': repoKey,
    'run_id': runId.trim().isEmpty ? 'graph-$digest' : runId.trim(),
    'mode': ragResult == null
        ? 'deterministic'
        : '${ragResult.summary['mode'] ?? 'lexical'}',
    'link_mode': 'deterministic',
    'dry_run': !commit,
    'committed': commit,
    'git': changes.toJson(),
    'nodes': nodeList,
    'edges': edgeList,
    'counts': <String, Object?>{
      'nodes': nodeList.length,
      'edges': edgeList.length,
      'by_node_kind': nodeKinds,
      'by_edge_kind': edgeKinds,
      'docs': contract.docs.length,
      'packages': scan.packages.length,
    },
    if (ragResult != null) 'rag': ragResult.summary,
    'writes': writes,
    'storage': <String, Object?>{'applied': applied, 'ops': writes.length},
    'notes': <String>[
      if (ragResult == null)
        '只做三类确定性边：belongs_to / references / mentions；无 LLM、无分块'
      else
        'rag=true：确定性边 + 分块/LLM 抽取/Leiden 社区/报告/embedding 向量',
      'references 只认可解析到文档集合的相对链接（含 link_fallbacks）',
      'mentions 来自策略点名与包公开声明名，按标识符边界匹配，每篇文档最多 50 条',
      '默认 dry-run；--commit 才写图集合，重复运行 0 写',
      if (ragResult == null) 'RAG 默认关闭（避免默认烧 token）：rag=true 才建 GraphRAG 索引',
    ],
  };
}

void _collectWrites(
  String collection,
  Map<String, Map<String, Object?>> existing,
  Map<String, Map<String, Object?>> desired,
  List<Map<String, Object?>> writes,
) {
  for (final MapEntry<String, Map<String, Object?>> entry in desired.entries) {
    if (_sameJson(existing[entry.key], entry.value)) continue;
    writes.add(<String, Object?>{
      'op': 'put',
      'collection': collection,
      'key': entry.key,
      'value': entry.value,
    });
  }
  for (final String key in existing.keys) {
    if (desired.containsKey(key)) continue;
    writes.add(<String, Object?>{
      'op': 'delete',
      'collection': collection,
      'key': key,
    });
  }
}

PackageUnit? _ownerPackage(String path, List<PackageUnit> packages) {
  PackageUnit? best;
  int bestLength = -1;
  for (final PackageUnit unit in packages) {
    final String root = unit.root;
    if (root == '.' || path == root || path.startsWith('$root/')) {
      final int length = root == '.' ? 0 : root.length;
      if (length > bestLength) {
        bestLength = length;
        best = unit;
      }
    }
  }
  return best;
}

/// 把相对链接解析成文档集合里的路径；出仓 / 外链 / 锚点一律不建边。
String? _resolveDocLink(
  Set<String> docs,
  DocPolicy policy,
  String base,
  String raw,
) {
  String target = raw.trim();
  if (target.isEmpty ||
      target.startsWith('<') ||
      target.startsWith('#') ||
      target.startsWith('mailto:') ||
      target.contains('://')) {
    return null;
  }
  final int hash = target.indexOf('#');
  if (hash >= 0) target = target.substring(0, hash);
  if (target.isEmpty) return null;
  try {
    target = Uri.decodeComponent(target);
  } on FormatException {
    // 裸 `%`：按原文解析。
  }
  final String resolved = resolveLinkPath(base, target);
  if (resolved.isEmpty) return null;
  if (docs.contains(resolved)) return resolved;
  for (final LinkFallback fallback in policy.linkFallbacks) {
    if (!fallback.prefixes.any(resolved.startsWith)) continue;
    final String candidate = '${fallback.root}/$resolved';
    if (docs.contains(candidate)) return candidate;
  }
  return null;
}

/// 标识符边界匹配：避免 `Alpha` 命中 `Alphabet`。
bool _identifierIn(String content, String symbol) => RegExp(
  '(^|[^A-Za-z0-9_])${RegExp.escape(symbol)}([^A-Za-z0-9_]|\$)',
  multiLine: true,
).hasMatch(content);

final RegExp _mdLink = RegExp(r'\]\(([^)\s]+)\)');

String _fnv1a(String text) {
  int hash = 0xcbf29ce484222325;
  for (final int byte in utf8.encode(text)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0').substring(0, 12);
}

bool _sameJson(Object? left, Object? right) =>
    jsonEncode(_canonical(left)) == jsonEncode(_canonical(right));

Object? _canonical(Object? value) {
  if (value is Map) {
    final List<String> keys =
        value.keys.map((Object? key) => key.toString()).toList()..sort();
    return <String, Object?>{
      for (final String key in keys) key: _canonical(value[key]),
    };
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}
