import 'dart:convert';

import 'baseline.dart';
import 'plan.dart';
import 'policy.dart';
import 'scan.dart';
import 'summary.dart';

/// `docnorm.audit`：产四类建议并补全 `pkg_index` 的收束事实（DN-7）。
///
/// - 只读扫描 + 只读存储；默认 dry-run，`commit` 才写 `suggestions` / `pkg_index`；
/// - 建议四类：`reuse` / `split_size` / `split_function` / `api_boundary`；
/// - 阈值全部读仓库策略（`thresholds`，D31），引擎不硬编码；
/// - 只持建议事实与 `lastTaskId`，**不建任务、不执行改造**（D20/D21）。
Future<Map<String, Object?>> runAudit(
  String repo, {
  required StorageCall storage,
  bool commit = false,
  String runId = '',
}) async {
  final GitRepository git = await GitRepository.open(repo);
  final RepoIndex index = await RepoIndex.load(repo);
  final DocStore store = DocStore(storage);
  final String repoKey = repoKeyOf(index.root);
  final DocPolicy policy = DocPolicy.resolve(index);
  final ScanResult scan = await scanIndex(index);
  final GitChanges changes = await git.changedFiles();

  final Map<String, Map<String, Object?>> existingPackages =
      <String, Map<String, Object?>>{};
  for (final StoredRecord record in await store.scan(
    'pkg_index',
    '$repoKey#',
  )) {
    existingPackages[record.key] = record.value;
  }
  final Map<String, Map<String, Object?>> existingStates =
      <String, Map<String, Object?>>{};
  for (final StoredRecord record in await store.scan('doc_state', '$repoKey#')) {
    existingStates[record.key] = record.value;
  }
  final Map<String, Map<String, Object?>> existingSuggestions =
      <String, Map<String, Object?>>{};
  for (final StoredRecord record in await store.scan(
    'suggestions',
    '$repoKey#',
  )) {
    existingSuggestions[record.key] = record.value;
  }

  // 包指纹与 baseline 同口径（只排文档），用于把「文档与代码已不同步」标成 stale。
  final Map<String, String> hashes = await git.hashPaths(<String>{
    for (final PackageUnit unit in scan.packages)
      ...fingerprintPathsIn(index.files, unit.root),
  });
  final Map<String, String> fingerprints = <String, String>{};
  for (final PackageUnit unit in scan.packages) {
    final Map<String, String> subset = <String, String>{};
    for (final String path in fingerprintPathsIn(index.files, unit.root)) {
      final String? hash = hashes[path];
      if (hash != null) subset[path] = hash;
    }
    fingerprints[unit.id] = await git.fingerprint(subset);
  }

  final List<Map<String, Object?>> packages = <Map<String, Object?>>[];
  final Map<String, PackageSummary> summaries = <String, PackageSummary>{};
  final Map<String, bool> staleById = <String, bool>{};
  final Map<String, List<RepoFile>> bigFiles = <String, List<RepoFile>>{};
  final int fileLimit = policy.thresholds['file_lines'] ?? 1000;
  int staleCount = 0;
  int emptyQuality = 0;
  for (final PackageUnit unit in scan.packages) {
    final PackageSummary summary = summarizePackage(
      index,
      unit,
      policy.thresholds,
    );
    summaries[unit.id] = summary;
    final List<RepoFile> oversized = packageSourceFiles(index, unit.root)
        .where((RepoFile file) => file.lines > fileLimit)
        .toList()
      ..sort((RepoFile a, RepoFile b) => b.lines.compareTo(a.lines));
    bigFiles[unit.id] = oversized;

    final Map<String, Object?>? state =
        existingStates['$repoKey#pkg:${unit.id}'];
    final String stored = (state?['codeFingerprint'] ?? '').toString().trim();
    final bool stale =
        stored.isNotEmpty && stored != (fingerprints[unit.id] ?? '');
    staleById[unit.id] = stale;
    if (stale) staleCount += 1;
    if (summary.quality == 'empty') emptyQuality += 1;

    packages.add(<String, Object?>{
      'id': unit.id,
      'root': unit.root,
      'language': unit.language,
      'lines': summary.lines,
      'max_file_lines': summary.maxFileLines,
      'api_count': unit.api.count,
      'declaration_count': summary.declarationCount,
      'subpackage_count': summary.subpackageCount,
      'quality': summary.quality,
      'stale': stale,
      'one_liner': summary.oneLiner,
      'entry': summary.entry,
      'boundaries': summary.boundaries,
      'readme': summary.readme,
      'degraded': unit.degraded,
    });
  }

  final List<Map<String, Object?>> suggestions = _buildSuggestions(
    repoKey: repoKey,
    packages: scan.packages,
    summaries: summaries,
    bigFiles: bigFiles,
    thresholds: policy.thresholds,
    existing: existingSuggestions,
  );

  final Map<String, Map<String, Object?>> desiredPackages =
      <String, Map<String, Object?>>{};
  for (final PackageUnit unit in scan.packages) {
    final String key = '$repoKey#pkg:${unit.id}';
    final Map<String, Object?> value = <String, Object?>{
      ...?existingPackages[key],
      'schema': 1,
      'repo': repoKey,
      'package': unit.toJson(),
      'summary': summaries[unit.id]!.toJson(),
      'quality': summaries[unit.id]!.quality,
      'stale': staleById[unit.id] ?? false,
    };
    desiredPackages[key] = value;
  }
  final Map<String, Map<String, Object?>> desiredSuggestions =
      <String, Map<String, Object?>>{
        for (final Map<String, Object?> suggestion in suggestions)
          '$repoKey#sug:${suggestion['id']}': suggestion,
      };

  final List<Map<String, Object?>> writes = <Map<String, Object?>>[];
  for (final MapEntry<String, Map<String, Object?>> entry
      in desiredSuggestions.entries) {
    if (_sameJson(existingSuggestions[entry.key], entry.value)) continue;
    writes.add(<String, Object?>{
      'op': 'put',
      'collection': 'suggestions',
      'key': entry.key,
    });
  }
  for (final String key in existingSuggestions.keys) {
    if (desiredSuggestions.containsKey(key)) continue;
    writes.add(<String, Object?>{
      'op': 'delete',
      'collection': 'suggestions',
      'key': key,
    });
  }
  for (final MapEntry<String, Map<String, Object?>> entry
      in desiredPackages.entries) {
    if (_sameJson(existingPackages[entry.key], entry.value)) continue;
    writes.add(<String, Object?>{
      'op': 'put',
      'collection': 'pkg_index',
      'key': entry.key,
    });
  }

  bool applied = false;
  if (commit && writes.isNotEmpty) {
    await store.ensureAll();
    final List<Map<String, Object?>> ops = <Map<String, Object?>>[
      for (final Map<String, Object?> write in writes)
        <String, Object?>{
          'op': write['op'],
          'collection': write['collection'],
          'key': write['key'],
          if (write['op'] == 'put')
            'value': write['collection'] == 'suggestions'
                ? desiredSuggestions[write['key']]
                : desiredPackages[write['key']],
        },
    ];
    await store.tx(ops);
    applied = true;
  }

  final Map<String, int> byKind = <String, int>{};
  for (final Map<String, Object?> suggestion in suggestions) {
    final String kind = '${suggestion['kind']}';
    byKind[kind] = (byKind[kind] ?? 0) + 1;
  }

  return <String, Object?>{
    'command': 'docnorm.audit',
    'repo': index.root,
    'repo_key': repoKey,
    'run_id': runId.trim().isEmpty
        ? 'audit-${_fnv1a(fingerprints.entries.map((MapEntry<String, String> e) => '${e.key}\t${e.value}').join('\n'))}'
        : runId.trim(),
    'dry_run': !commit,
    'committed': commit,
    'git': changes.toJson(),
    'thresholds': policy.thresholds,
    'baseline_required': existingPackages.isEmpty,
    'packages': packages,
    'suggestions': suggestions,
    'counts': <String, Object?>{
      'packages': packages.length,
      'suggestions': suggestions.length,
      'by_kind': byKind,
      'stale': staleCount,
      'quality_empty': emptyQuality,
    },
    'writes': writes,
    'storage': <String, Object?>{'applied': applied, 'ops': writes.length},
    'degraded': scan.packages.any((PackageUnit unit) => unit.degraded),
    'notes': <String>[
      '建议只产事实（kind/detail/targets/confidence/risk/plan/acceptance）+ lastTaskId，不建任务、不执行改造',
      '阈值全部读仓库策略 thresholds（D31），默认 5000 / 1000 / 20 / 60 / 12 / 60 / 8',
      'quality 只报告（empty / thin / suspect / ok），不改写 README；stale 由代码指纹与 doc_state 对比得出',
      '默认 dry-run；--commit 才写 suggestions 与 pkg_index（建议 id 稳定，重复运行 0 写）',
    ],
  };
}

const Map<String, String> _kindPlans = <String, String>{
  'reuse': '核对同名导出是否为重复实现：能复用则抽公共模块，不能复用则改名以避免语义混淆。',
  'split_size': '按目录 / 职责拆分超过阈值的包或文件；先加 barrel 保持导出面，再搬实现。',
  'split_function': '按职责边界划分子包，收敛单一入口与对外声明。',
  'api_boundary': '收窄 API 面：合并同类端点或拆出独立适配层，保持既有路径兼容。',
};

List<Map<String, Object?>> _buildSuggestions({
  required String repoKey,
  required List<PackageUnit> packages,
  required Map<String, PackageSummary> summaries,
  required Map<String, List<RepoFile>> bigFiles,
  required Map<String, int> thresholds,
  required Map<String, Map<String, Object?>> existing,
}) {
  final int packageLimit = thresholds['package_lines'] ?? 5000;
  final int fileLimit = thresholds['file_lines'] ?? 1000;
  final int apiLimit = thresholds['api_count'] ?? 20;
  final int declarationLimit = thresholds['declaration_count'] ?? 60;
  final int subpackageLimit = thresholds['subpackage_count'] ?? 12;
  final List<Map<String, Object?>> out = <Map<String, Object?>>[];

  Map<String, Object?>? build({
    required String kind,
    required PackageUnit unit,
    required String detail,
    required List<String> targets,
    required List<String> evidence,
    required double confidence,
    required String risk,
  }) {
    final String id = 'sug-${_fnv1a('$kind|${unit.root}|${targets.join("|")}')}';
    final Map<String, Object?> record = <String, Object?>{
      'schema': 1,
      'id': id,
      'kind': kind,
      'detail': detail,
      'repo': repoKey,
      'package': unit.root,
      'targets': targets,
      'evidence': evidence,
      'confidence': confidence,
      'risk': risk,
      'plan': _kindPlans[kind],
      'acceptance': _acceptanceOf(unit),
      'lastTaskId': existing['$repoKey#sug:$id']?['lastTaskId'],
    };
    out.add(record);
    return record;
  }

  for (final PackageUnit unit in packages) {
    final PackageSummary summary = summaries[unit.id]!;
    final List<RepoFile> oversized = bigFiles[unit.id] ?? const <RepoFile>[];

    if (summary.lines > packageLimit || oversized.isNotEmpty) {
      final List<String> targets = oversized.isEmpty
          ? <String>[unit.root]
          : <String>[
              for (final RepoFile file in oversized.take(5)) file.path,
            ];
      final List<String> parts = <String>[
        if (summary.lines > packageLimit)
          '包 ${summary.lines} 行 > $packageLimit',
        if (oversized.isNotEmpty)
          '单文件 ${oversized.first.lines} 行 > $fileLimit',
      ];
      build(
        kind: 'split_size',
        unit: unit,
        detail: parts.join('；'),
        targets: targets,
        evidence: <String>[
          'lines=${summary.lines}',
          'max_file_lines=${summary.maxFileLines}',
          ...oversized.take(5).map(
            (RepoFile file) => '${file.path}:${file.lines}',
          ),
        ],
        confidence: oversized.isNotEmpty && summary.lines > packageLimit
            ? 0.9
            : 0.75,
        risk: summary.lines > packageLimit * 2 ? 'high' : 'medium',
      );
    }

    if (summary.declarationCount > declarationLimit ||
        summary.subpackageCount > subpackageLimit) {
      final List<String> targets = unit.subpackages.isEmpty
          ? <String>[unit.root]
          : <String>[
              for (final SubUnit sub in unit.subpackages.take(5)) sub.path,
            ];
      build(
        kind: 'split_function',
        unit: unit,
        detail: <String>[
          if (summary.declarationCount > declarationLimit)
            '公开声明 ${summary.declarationCount} > $declarationLimit',
          if (summary.subpackageCount > subpackageLimit)
            '子包 ${summary.subpackageCount} > $subpackageLimit',
        ].join('；'),
        targets: targets,
        evidence: <String>[
          'declaration_count=${summary.declarationCount}',
          'subpackage_count=${summary.subpackageCount}',
        ],
        confidence: 0.6,
        risk: 'medium',
      );
    }

    if (unit.api.count > apiLimit) {
      final List<String> endpoints = <String>[
        for (final ApiEndpoint endpoint in unit.api.endpoints.take(5))
          '${endpoint.method} ${endpoint.path}',
      ];
      build(
        kind: 'api_boundary',
        unit: unit,
        detail: 'API 端点 ${unit.api.count} > $apiLimit',
        targets: endpoints.isEmpty ? <String>[unit.root] : endpoints,
        evidence: <String>[
          'api_count=${unit.api.count}',
          'api_source=${unit.api.source}',
        ],
        confidence: 0.7,
        risk: unit.api.count > apiLimit * 2 ? 'high' : 'medium',
      );
    }
  }

  // reuse：跨包同名公开声明（符号级，不走向量；P4 只报线索）。
  final Map<String, List<PackageUnit>> bySymbol = <String, List<PackageUnit>>{};
  for (final PackageUnit unit in packages) {
    for (final String symbol in unit.exports) {
      final String name = symbol.trim();
      if (name.length < 3) continue;
      bySymbol.putIfAbsent(name, () => <PackageUnit>[]).add(unit);
    }
  }
  final List<String> symbols = bySymbol.keys.toList()..sort();
  for (final String symbol in symbols) {
    final List<PackageUnit> owners = bySymbol[symbol]!;
    if (owners.length < 2) continue;
    final List<String> uniqueRoots = <String>[];
    for (final PackageUnit unit in owners) {
      if (!uniqueRoots.contains(unit.root)) uniqueRoots.add(unit.root);
    }
    if (uniqueRoots.length < 2) continue;
    final String id = 'sug-${_fnv1a('reuse|$symbol|${uniqueRoots.join("|")}')}';
    out.add(<String, Object?>{
      'schema': 1,
      'id': id,
      'kind': 'reuse',
      'detail': '同名公开声明「$symbol」出现在 ${uniqueRoots.join(' / ')}',
      'repo': repoKey,
      'package': uniqueRoots.first,
      'targets': uniqueRoots,
      'evidence': <String>['symbol=$symbol', ...uniqueRoots],
      'confidence': 0.5,
      'risk': 'low',
      'plan': _kindPlans['reuse'],
      'acceptance': _acceptanceOf(owners.first),
      'lastTaskId': existing['$repoKey#sug:$id']?['lastTaskId'],
    });
  }

  out.sort((Map<String, Object?> a, Map<String, Object?> b) {
    final String left = '${a['kind']}|${a['package']}|${a['id']}';
    final String right = '${b['kind']}|${b['package']}|${b['id']}';
    return left.compareTo(right);
  });
  return out;
}

List<String> _acceptanceOf(PackageUnit unit) => unit.language == 'dart'
    ? <String>['dart analyze 0', 'dart test ${unit.root}']
    : <String>['构建通过（${unit.root}）', '相关测试通过'];

/// 稳定短 id（FNV-1a 64 位）；同一 kind / 包 / 目标集合恒定。
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
