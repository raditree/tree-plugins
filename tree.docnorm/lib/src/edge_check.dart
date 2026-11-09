import 'baseline.dart';
import 'contract.dart';
import 'policy.dart';
import 'scan.dart';

/// `docnorm.check --edges`（DN-10）：六类关联边检查，确定性、只读。
///
/// 检查口径（doc-normalization-recon §4.6）：
/// 1. `broken_link`：契约层解析不了的文档链接（error）；
/// 2. `orphan`：图里没有任何边的节点（info）；
/// 3. `stale_reference`：`doc_state.stale` 或引用到已不在契约集合里的文档（warn）；
/// 4. `unresolved_mention`：`mentions` 边的目标节点不存在（warn）；
/// 5. `cross_package_reference`：跨包文档引用（info，不是错误）；
/// 6. `term_conflict`：同名实体挂了不同 kind，或存在 `conflicts_with` 边（warn）。
Future<Map<String, Object?>> runEdgeChecks(
  String repo, {
  required StorageCall storage,
  DocContract? contract,
  int maxFindings = 200,
}) async {
  final RepoIndex index = await RepoIndex.load(repo);
  final DocPolicy policy = DocPolicy.resolve(index);
  final DocContract resolved = contract ?? inspectIndex(index, policy);
  final DocStore store = DocStore(storage);
  final String repoKey = repoKeyOf(index.root);

  final Map<String, Map<String, Object?>> nodes =
      <String, Map<String, Object?>>{};
  for (final StoredRecord record in await store.listAll(
    'graph_nodes',
    '$repoKey#',
  )) {
    final String id = '${record.value['id'] ?? ''}';
    if (id.isNotEmpty) nodes[id] = record.value;
  }
  final List<Map<String, Object?>> edges = <Map<String, Object?>>[
    for (final StoredRecord record in await store.listAll(
      'graph_edges',
      '$repoKey#',
    ))
      record.value,
  ];
  if (nodes.isEmpty && edges.isEmpty) {
    return <String, Object?>{
      'command': 'docnorm.check',
      'repo': index.root,
      'repo_key': repoKey,
      'edges': true,
      'ok': false,
      'code': 'graph_required',
      'findings': const <Map<String, Object?>>[],
      'counts': const <String, Object?>{'total': 0, 'by_kind': <String, int>{}},
      'notes': const <String>['图索引不存在：先运行 docnorm.graph.build --commit'],
    };
  }

  final List<Map<String, Object?>> findings = <Map<String, Object?>>[];
  void add(
    String kind,
    String severity,
    String doc,
    String detail, {
    Map<String, Object?>? ref,
  }) {
    if (findings.length >= maxFindings) return;
    findings.add(<String, Object?>{
      'kind': kind,
      'severity': severity,
      'doc': doc,
      'detail': detail,
      'ref': ?ref,
    });
  }

  // 1. 断链：契约层已经给出 links_resolvable 违规。
  for (final DocViolation violation in resolved.violations) {
    if (violation.kind != 'links_resolvable') continue;
    add('broken_link', 'error', violation.doc, violation.detail);
  }
  final Set<String> docs = resolved.docs.toSet();
  for (final Map<String, Object?> edge in edges) {
    if ('${edge['kind']}' != 'references') continue;
    final String to = '${edge['to'] ?? ''}';
    if (!to.startsWith('doc:')) continue;
    final String target = to.substring(4);
    if (docs.contains(target)) continue;
    add(
      'broken_link',
      'error',
      '${edge['from'] ?? ''}'.replaceFirst('doc:', ''),
      '引用目标已不在文档契约集合：$target',
      ref: <String, Object?>{'edge': edge['id'], 'to': to},
    );
  }

  // 2. 孤儿：没有任何入边/出边的节点（subpackage 只作为归属节点，容易天然孤岛，跳过）。
  final Set<String> connected = <String>{};
  for (final Map<String, Object?> edge in edges) {
    final String from = '${edge['from'] ?? ''}';
    final String to = '${edge['to'] ?? ''}';
    if (from.isNotEmpty) connected.add(from);
    if (to.isNotEmpty) connected.add(to);
  }
  for (final String id in nodes.keys.toList()..sort()) {
    if (connected.contains(id)) continue;
    if (id.startsWith('sub:')) continue;
    add(
      'orphan',
      'info',
      id.startsWith('doc:') ? id.substring(4) : '',
      '节点没有任何边：$id',
      ref: <String, Object?>{'node': id},
    );
  }

  // 3. 过期引用：doc_state.stale 或引用源文档不在契约集合。
  for (final StoredRecord record in await store.listAll(
    'doc_state',
    '$repoKey#',
  )) {
    final Map<String, Object?> value = record.value;
    if (value['stale'] != true) continue;
    final String doc = '${value['doc'] ?? record.key.split('#doc:').last}';
    add('stale_reference', 'warn', doc, 'doc_state 标记 stale，需要 reanalyze');
  }
  for (final Map<String, Object?> edge in edges) {
    if ('${edge['kind']}' != 'references') continue;
    final String from = '${edge['from'] ?? ''}';
    if (!from.startsWith('doc:')) continue;
    final String source = from.substring(4);
    if (docs.contains(source)) continue;
    add('stale_reference', 'warn', source, '来源文档已不在契约集合，但仍存在引用边');
  }

  // 4. 未解析提及：mentions 边目标节点不存在。
  for (final Map<String, Object?> edge in edges) {
    if ('${edge['kind']}' != 'mentions') continue;
    final String to = '${edge['to'] ?? ''}';
    if (nodes.containsKey(to)) continue;
    add(
      'unresolved_mention',
      'warn',
      '${edge['from'] ?? ''}'.replaceFirst('doc:', ''),
      '提及的符号没有对应节点：$to',
      ref: <String, Object?>{'edge': edge['id'], 'to': to},
    );
  }

  // 5. 跨包引用：文档 → 所属包，引用边两侧 owner 不同。
  final Map<String, String> docOwner = <String, String>{};
  for (final Map<String, Object?> edge in edges) {
    if ('${edge['kind']}' != 'belongs_to') continue;
    final String from = '${edge['from'] ?? ''}';
    final String to = '${edge['to'] ?? ''}';
    if (from.startsWith('doc:') && to.startsWith('pkg:')) {
      docOwner[from.substring(4)] = to.substring(4);
    }
  }
  final Set<String> crossSeen = <String>{};
  for (final Map<String, Object?> edge in edges) {
    if ('${edge['kind']}' != 'references') continue;
    final String from = '${edge['from'] ?? ''}'.replaceFirst('doc:', '');
    final String to = '${edge['to'] ?? ''}'.replaceFirst('doc:', '');
    final String? fromOwner = docOwner[from];
    final String? toOwner = docOwner[to];
    if (fromOwner == null || toOwner == null || fromOwner == toOwner) continue;
    final String key = '$from→$to';
    if (!crossSeen.add(key)) continue;
    add(
      'cross_package_reference',
      'info',
      from,
      '$from（$fromOwner）引用 $to（$toOwner）',
      ref: <String, Object?>{'from': from, 'to': to},
    );
  }

  // 6. 术语冲突：同名实体不同 kind，或显式 conflicts_with 边。
  final Map<String, Set<String>> entityKinds = <String, Set<String>>{};
  final Map<String, String> entityLabels = <String, String>{};
  for (final MapEntry<String, Map<String, Object?>> entry in nodes.entries) {
    if (!entry.key.startsWith('ent:')) continue;
    final String label = '${entry.value['label'] ?? ''}'.trim().toLowerCase();
    final String kind = '${entry.value['kind'] ?? ''}';
    if (label.isEmpty) continue;
    entityKinds.putIfAbsent(label, () => <String>{}).add(kind);
    entityLabels.putIfAbsent(label, () => '${entry.value['label'] ?? ''}');
  }
  for (final MapEntry<String, Set<String>> entry in entityKinds.entries) {
    if (entry.value.length <= 1) continue;
    final List<String> kinds = entry.value.toList()..sort();
    add(
      'term_conflict',
      'warn',
      '',
      '同名实体 ${entityLabels[entry.key]} 出现多种 kind：${kinds.join(' / ')}',
      ref: <String, Object?>{'label': entityLabels[entry.key]},
    );
  }
  for (final Map<String, Object?> edge in edges) {
    if ('${edge['kind']}' != 'conflicts_with') continue;
    add(
      'term_conflict',
      'warn',
      '',
      '显式冲突关系：${edge['from']} ↔ ${edge['to']}',
      ref: <String, Object?>{'edge': edge['id']},
    );
  }

  findings.sort((Map<String, Object?> a, Map<String, Object?> b) {
    final int byKind = '${a['kind']}'.compareTo('${b['kind']}');
    if (byKind != 0) return byKind;
    final int byDoc = '${a['doc']}'.compareTo('${b['doc']}');
    return byDoc != 0 ? byDoc : '${a['detail']}'.compareTo('${b['detail']}');
  });
  final Map<String, int> byKind = <String, int>{};
  final Map<String, int> bySeverity = <String, int>{};
  for (final Map<String, Object?> finding in findings) {
    final String kind = '${finding['kind']}';
    final String severity = '${finding['severity']}';
    byKind[kind] = (byKind[kind] ?? 0) + 1;
    bySeverity[severity] = (bySeverity[severity] ?? 0) + 1;
  }
  final bool hasError = findings.any(
    (Map<String, Object?> finding) => finding['severity'] == 'error',
  );

  return <String, Object?>{
    'command': 'docnorm.check',
    'repo': index.root,
    'repo_key': repoKey,
    'edges': true,
    'ok': !hasError,
    'findings': findings,
    'counts': <String, Object?>{
      'total': findings.length,
      'by_kind': byKind,
      'by_severity': bySeverity,
      'nodes': nodes.length,
      'edges': edges.length,
      'truncated': findings.length >= maxFindings,
    },
    'notes': const <String>[
      '六类检查：broken_link / orphan / stale_reference / unresolved_mention / '
          'cross_package_reference / term_conflict',
      '只读：不写存储、不调用 LLM',
      'ok=false 仅表示存在 error 级别（断链）',
    ],
  };
}
