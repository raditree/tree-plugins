import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'contract.dart';
import 'policy.dart';
import 'scan.dart';

/// 基线 / 重算失败：稳定 [code] + 人话 [message]。
class BaselineFailure implements Exception {
  BaselineFailure(this.message, {this.code = 'baseline_failed'});

  final String message;
  final String code;

  @override
  String toString() => message;
}

/// 存储调用：生产走核心中转的执行站命令，自检 / 单测走内存实现。
///
/// 入参是 `storage.*` 命令与 arguments，返回值是**已剥掉执行站信封的 payload**。
typedef StorageCall = Future<Map<String, dynamic>> Function(
  String command,
  Map<String, dynamic> arguments,
);

/// `doc_state` / `doc_contract` / `pkg_index` 三条集合的读写封装。
///
/// 任何存储错误都收敛成 [BaselineFailure]（`storage_unavailable`）——DN-6 的
/// TC-ST-10 要求缺存储时 fail-closed，而不是假装基线已经建好。
class DocStore {
  DocStore(this._call);

  final StorageCall _call;

  static const List<String> collections = <String>[
    'doc_contract',
    'pkg_index',
    'doc_state',
  ];

  Future<Map<String, dynamic>> call(
    String command,
    Map<String, dynamic> arguments,
  ) async {
    try {
      return await _call(command, arguments);
    } catch (error) {
      throw BaselineFailure(
        '存储不可用（$command）：$error',
        code: 'storage_unavailable',
      );
    }
  }

  Future<void> ensureAll() async {
    for (final String collection in collections) {
      await call('storage.ensure', <String, dynamic>{
        'collection': collection,
        'schema_version': 1,
      });
    }
  }

  /// 按 key 前缀读（`storage.scan` 只读，不写盘）。
  Future<List<StoredRecord>> scan(String collection, String prefix) async {
    final Map<String, dynamic> result = await call(
      'storage.scan',
      <String, dynamic>{
        'collection': collection,
        'prefix': prefix,
        'limit': 5000,
      },
    );
    final Object? raw = result['values'];
    if (raw is! List) return const <StoredRecord>[];
    final List<StoredRecord> out = <StoredRecord>[];
    for (final Object? item in raw) {
      if (item is! Map) continue;
      final Map<String, dynamic> record = _map(item);
      out.add(
        StoredRecord(key: _str(record['key']), value: _map(record['value'])),
      );
    }
    return out;
  }

  Future<void> tx(List<Map<String, Object?>> ops) async {
    if (ops.isEmpty) return;
    for (int start = 0; start < ops.length; start += 200) {
      final int end = start + 200 > ops.length ? ops.length : start + 200;
      await call('storage.tx', <String, dynamic>{
        'ops': ops.sublist(start, end),
      });
    }
  }
}

/// 一条已存记录（`scan` / `get` 的形状）。
class StoredRecord {
  const StoredRecord({required this.key, required this.value});

  final String key;
  final Map<String, Object?> value;
}

/// 只读 git：指纹用 blob id，变更用 `git diff`（不读 `git status`）。
class GitRepository {
  GitRepository(this.root);

  final String root;

  static Future<GitRepository> open(String repo) async {
    final Directory dir = Directory(repo);
    if (!await dir.exists()) {
      throw BaselineFailure('仓库目录不存在：$repo', code: 'repo_not_found');
    }
    final ProcessResult probe = await _run(repo, <String>[
      'rev-parse',
      '--is-inside-work-tree',
    ]);
    if (probe.exitCode != 0 || _text(probe.stdout) != 'true') {
      throw BaselineFailure(
        'docnorm.baseline / reanalyze 需要 git 仓库（只读 git、默认禁网）：$repo',
        code: 'git_required',
      );
    }
    return GitRepository(p.normalize(repo));
  }

  Future<bool> hasHead() async =>
      (await _run(root, <String>['rev-parse', '--verify', 'HEAD'])).exitCode ==
      0;

  Future<String> headSha() async {
    final ProcessResult result = await _run(root, <String>[
      'rev-parse',
      'HEAD',
    ]);
    return result.exitCode == 0 ? _text(result.stdout) : '';
  }

  /// `git diff`（tracked）+ `git ls-files --others`（显式纳入的新文件）。
  Future<GitChanges> changedFiles() async {
    final bool head = await hasHead();
    final List<String> tracked = head
        ? await _lines(
            _run(root, <String>['diff', '--name-only', 'HEAD', '--']),
          )
        : await _lines(_run(root, <String>['ls-files']));
    final List<String> untracked = await _lines(
      _run(root, <String>['ls-files', '--others', '--exclude-standard']),
    );
    final Set<String> trackedSet = tracked
        .where((String line) => line.isNotEmpty)
        .toSet();
    final Set<String> untrackedSet =
        untracked.where((String line) => line.isNotEmpty).toSet()
          ..removeAll(trackedSet);
    final List<String> sortedTracked = trackedSet.toList()..sort();
    final List<String> sortedUntracked = untrackedSet.toList()..sort();
    return GitChanges(
      tracked: sortedTracked,
      untracked: sortedUntracked,
      head: head ? await headSha() : '',
    );
  }

  /// 工作树文件的 blob id（一次进程算一批；路径按 `/` 相对仓库根）。
  Future<Map<String, String>> hashPaths(Iterable<String> paths) async {
    final List<String> sorted = paths.toSet().toList()..sort();
    if (sorted.isEmpty) return <String, String>{};
    final ProcessResult result = await _runWithInput(<String>[
      'hash-object',
      '--stdin-paths',
    ], '${sorted.join('\n')}\n');
    if (result.exitCode != 0) {
      throw BaselineFailure(
        'git hash-object 失败：${_text(result.stderr)}',
        code: 'git_error',
      );
    }
    final List<String> hashes = _text(result.stdout).split('\n');
    if (hashes.length != sorted.length) {
      throw BaselineFailure(
        'git hash-object 输出行数不符：${hashes.length} != ${sorted.length}',
        code: 'git_error',
      );
    }
    return <String, String>{
      for (int index = 0; index < sorted.length; index++)
        sorted[index]: hashes[index],
    };
  }

  /// 把 `path\tblob` 有序清单再哈希一次（D4：指纹 = git blob id 的有序哈希）。
  Future<String> fingerprint(Map<String, String> hashes) async {
    final List<String> paths = hashes.keys.toList()..sort();
    final String manifest = <String>[
      for (final String path in paths) '$path\t${hashes[path]}',
    ].join('\n');
    return hashText(manifest);
  }

  Future<String> hashText(String text) async {
    final ProcessResult result = await _runWithInput(<String>[
      'hash-object',
      '--stdin',
    ], text);
    if (result.exitCode != 0) {
      throw BaselineFailure(
        'git hash-object 失败：${_text(result.stderr)}',
        code: 'git_error',
      );
    }
    return _text(result.stdout);
  }

  static Future<ProcessResult> _run(String cwd, List<String> args) =>
      Process.run('git', args, workingDirectory: cwd);

  Future<ProcessResult> _runWithInput(List<String> args, String input) async {
    final Process process = await Process.start(
      'git',
      args,
      workingDirectory: root,
    );
    process.stdin.write(input);
    await process.stdin.close();
    final String out = await process.stdout.transform(utf8.decoder).join();
    final String err = await process.stderr.transform(utf8.decoder).join();
    final int code = await process.exitCode;
    return ProcessResult(process.pid, code, out, err);
  }

  static Future<List<String>> _lines(Future<ProcessResult> result) async {
    final ProcessResult value = await result;
    if (value.exitCode != 0) return const <String>[];
    return _text(value.stdout)
        .split('\n')
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .toList();
  }
}

/// 一次变更归集结果。
class GitChanges {
  const GitChanges({
    required this.tracked,
    required this.untracked,
    required this.head,
  });

  final List<String> tracked;
  final List<String> untracked;
  final String head;

  List<String> get all => <String>[...tracked, ...untracked]..sort();

  Map<String, Object?> toJson() => <String, Object?>{
    'head': head,
    'tracked': tracked,
    'untracked': untracked,
    'total': tracked.length + untracked.length,
  };
}

/// `docnorm.baseline [--commit]`：一次建齐 L0（契约 / 包索引 / 状态），
/// 并按传入的章节提案只追加缺章节；默认 dry-run。
///
/// 传 `sections` / `indexes` 才产生 L1 写入（正文由 DN-5 生成后交进来）；
/// 不传时只出计划、缺口与 L0 状态，绝不凭空写占位章节。
Future<Map<String, Object?>> runBaseline(
  String repo, {
  required StorageCall storage,
  bool commit = false,
  List<Map<String, Object?>> sections = const <Map<String, Object?>>[],
  List<Map<String, Object?>> indexes = const <Map<String, Object?>>[],
  List<String> rewriteAllowlist = const <String>[],
  String runId = '',
}) async {
  final GitRepository git = await GitRepository.open(repo);
  final RepoIndex index = await RepoIndex.load(repo);
  final DocStore store = DocStore(storage);
  final String repoKey = repoKeyOf(index.root);

  // 先读存储：缺存储 / 缺身份 / 缺 team 一律在写任何文件前 fail-closed。
  final _Existing existing = await _loadExisting(store, repoKey);
  final GitChanges changes = await git.changedFiles();

  final DocPolicy policy = DocPolicy.resolve(index);
  final DocContract contract = inspectIndex(index, policy);
  final ScanResult scan = await scanIndex(index);
  final Map<String, String> hashes = await git.hashPaths(
    _sourcePaths(index.files, '.'),
  );
  final String repoFingerprint = await git.fingerprint(hashes);
  final Map<String, String> packageFingerprints = <String, String>{};
  for (final PackageUnit unit in scan.packages) {
    final Map<String, String> subset = <String, String>{};
    for (final String path in _sourcePaths(index.files, unit.root)) {
      final String? hash = hashes[path];
      if (hash != null) subset[path] = hash;
    }
    packageFingerprints[unit.id] = await git.fingerprint(subset);
  }

  final _Plan plan = _buildPlan(
    index: index,
    sections: sections,
    indexes: indexes,
    rewriteAllowlist: rewriteAllowlist,
  );

  final String now = _nowIso();
  final String id = runId.trim().isNotEmpty
      ? runId.trim()
      : 'run-${repoFingerprint.substring(0, 12)}';

  final Map<String, Map<String, Object?>> desiredPackages =
      <String, Map<String, Object?>>{
        for (final PackageUnit unit in scan.packages)
          '$repoKey#pkg:${unit.id}': <String, Object?>{
            'schema': 1,
            'repo': repoKey,
            'package': unit.toJson(),
          },
      };
  final Map<String, Map<String, Object?>> desiredStates =
      <String, Map<String, Object?>>{};
  for (final PackageUnit unit in scan.packages) {
    final String key = '$repoKey#pkg:${unit.id}';
    final Map<String, Object?> state = _pkgState(
      repoKey: repoKey,
      packageId: unit.id,
      fingerprint: packageFingerprints[unit.id] ?? '',
      now: now,
    );
    if (!_sameState(existing.states[key], state)) {
      desiredStates[key] = state;
    }
  }
  for (final String doc in plan.touchedDocs) {
    final String? owner = _ownerId(doc, scan.packages);
    final String fingerprint = owner == null
        ? repoFingerprint
        : (packageFingerprints[owner] ?? repoFingerprint);
    final String key = '$repoKey#doc:$doc';
    final Set<String> added = <String>{
      ..._stringList(existing.states[key]?['addedSections']),
      ...(plan.addedSectionsByDoc[doc] ?? const <String>{}),
    };
    final List<String> sorted = added.toList()..sort();
    final Map<String, Object?> state = _docState(
      repoKey: repoKey,
      doc: doc,
      addedSections: sorted,
      fingerprint: fingerprint,
      now: now,
    );
    if (!_sameState(existing.states[key], state)) {
      desiredStates[key] = state;
    }
  }

  final List<String> wouldWrite =
      plan.writes.map((_PlannedFile file) => file.path).toList()..sort();
  final List<String> written = commit
      ? _applyWrites(index.root, plan)
      : const <String>[];

  // 落盘后重新读契约：库里的 doc_contract 必须描述**写完之后**的仓库状态，
  // 否则下一次运行会因 sections 多了一个标题而重复写库（破坏“重复运行 0 写盘”）。
  DocContract storedContract = contract;
  if (written.isNotEmpty) {
    final RepoIndex reloaded = await RepoIndex.load(repo);
    storedContract = inspectIndex(reloaded, DocPolicy.resolve(reloaded));
  }
  final Map<String, Map<String, Object?>> desiredContracts =
      <String, Map<String, Object?>>{
        '$repoKey#contract': <String, Object?>{
          'schema': 1,
          'repo': repoKey,
          'repo_root': index.root,
          'head': changes.head,
          'code_fingerprint': repoFingerprint,
          'contract': storedContract.toJson(),
        },
      };

  final List<Map<String, Object?>> writes = <Map<String, Object?>>[];
  for (final MapEntry<String, Map<String, Object?>> entry
      in desiredContracts.entries) {
    if (_sameJson(existing.contracts[entry.key], entry.value)) continue;
    writes.add(<String, Object?>{
      'op': 'put',
      'collection': 'doc_contract',
      'key': entry.key,
      'value': entry.value,
    });
  }
  for (final MapEntry<String, Map<String, Object?>> entry
      in desiredPackages.entries) {
    if (_sameJson(existing.packages[entry.key], entry.value)) continue;
    writes.add(<String, Object?>{
      'op': 'put',
      'collection': 'pkg_index',
      'key': entry.key,
      'value': entry.value,
    });
  }
  for (final MapEntry<String, Map<String, Object?>> entry
      in desiredStates.entries) {
    writes.add(<String, Object?>{
      'op': 'put',
      'collection': 'doc_state',
      'key': entry.key,
      'value': entry.value,
    });
  }
  // 包被删 / 改名后，旧索引与旧状态必须一起清掉（只动本仓自己的前缀）。
  for (final String key in existing.packages.keys) {
    if (desiredPackages.containsKey(key)) continue;
    writes.add(<String, Object?>{
      'op': 'delete',
      'collection': 'pkg_index',
      'key': key,
    });
  }
  for (final String key in existing.states.keys) {
    if (!key.contains('#pkg:')) continue;
    if (desiredStates.containsKey(key)) continue;
    if (scan.packages.any(
      (PackageUnit unit) => key.endsWith('#pkg:${unit.id}'),
    )) {
      // 状态没变（desiredStates 里没有）但包还在：保留。
      continue;
    }
    writes.add(<String, Object?>{
      'op': 'delete',
      'collection': 'doc_state',
      'key': key,
    });
  }

  bool storageApplied = false;
  if (commit && writes.isNotEmpty) {
    await store.ensureAll();
    await store.tx(_opsOf(writes));
    storageApplied = true;
  }

  return <String, Object?>{
    'command': 'docnorm.baseline',
    'repo': index.root,
    'repo_key': repoKey,
    'run_id': id,
    'dry_run': !commit,
    'committed': commit,
    'code_fingerprint': repoFingerprint,
    'git': changes.toJson(),
    'contract': <String, Object?>{
      'ok': contract.ok,
      'docs': contract.docs.length,
      'violations': contract.violations.length,
      'degraded': contract.degraded,
      'unknown': contract.unknown,
    },
    'packages': <String, Object?>{
      'total': scan.packages.length,
      'ids': scan.packages.map((PackageUnit unit) => unit.id).toList(),
      'degraded': scan.degraded,
    },
    'plan': plan.toJson(),
    'gaps': _gaps(contract),
    'would_write': wouldWrite,
    'written': written,
    'doc_state': <String, Object?>{
      'updated': desiredStates.keys.toList()..sort(),
      'documents': <String, Object?>{
        for (final MapEntry<String, Map<String, Object?>> entry
            in desiredStates.entries)
          if (entry.key.contains('#doc:'))
            entry.key.substring(entry.key.indexOf('#doc:') + 5): entry.value,
      },
      'packages': <String, Object?>{
        for (final MapEntry<String, Map<String, Object?>> entry
            in desiredStates.entries)
          if (entry.key.contains('#pkg:'))
            entry.key.substring(entry.key.indexOf('#pkg:') + 5): entry.value,
      },
    },
    'storage': <String, Object?>{
      'ok': true,
      'namespace': 'tree.docnorm',
      'collections': DocStore.collections,
      'writes': writes,
      'applied': storageApplied,
    },
    'notes': <String>[
      'baseline 默认 dry-run；--commit 才写盘并写入 tree.storage',
      'L1 章节由 sections/indexes 提案驱动；正文生成属 DN-5，本命令只做只追加落盘',
      '门禁命令只列不跑（D30）；提交批次由 DN-8 的 docnorm.commit 负责',
    ],
  };
}

/// `docnorm.reanalyze --changed`：只重算受影响包的 L0 事实，并把状态写回。
///
/// 没有 `pkg_index` 基线 ⇒ `baseline_required`（D24）；没有变更 ⇒ 0 写盘。
Future<Map<String, Object?>> runReanalyze(
  String repo, {
  required StorageCall storage,
  required bool changed,
  bool commit = false,
  List<Map<String, Object?>> sections = const <Map<String, Object?>>[],
  List<Map<String, Object?>> indexes = const <Map<String, Object?>>[],
  List<String> rewriteAllowlist = const <String>[],
  String runId = '',
}) async {
  if (!changed) {
    throw BaselineFailure(
      'docnorm.reanalyze 需要 changed=true（只重算受影响包，不做全仓重扫）',
      code: 'changed_required',
    );
  }
  final GitRepository git = await GitRepository.open(repo);
  final DocStore store = DocStore(storage);
  final RepoIndex index = await RepoIndex.load(repo);
  final String repoKey = repoKeyOf(index.root);

  final _Existing existing = await _loadExisting(store, repoKey);
  if (existing.packages.isEmpty) {
    throw BaselineFailure(
      '没有 pkg_index：先运行 docnorm.baseline --commit 建立基线（D24）',
      code: 'baseline_required',
    );
  }
  final Map<String, String> storedRoots = <String, String>{};
  for (final Map<String, Object?> record in existing.packages.values) {
    final Map<String, dynamic> package = _map(record['package']);
    final String id = _str(package['id']);
    final String root = _str(package['root']);
    if (id.isNotEmpty && root.isNotEmpty) storedRoots[id] = root;
  }

  final GitChanges changes = await git.changedFiles();
  final Set<String> affected = <String>{};
  final List<String> unmatched = <String>[];
  for (final String path in changes.all) {
    final List<String> owners = _ownersRoot(path, storedRoots);
    if (owners.isEmpty) {
      unmatched.add(path);
      continue;
    }
    affected.addAll(owners);
  }

  final _Plan plan = _buildPlan(
    index: index,
    sections: sections,
    indexes: indexes,
    rewriteAllowlist: rewriteAllowlist,
  );
  final String now = _nowIso();
  final String id = runId.trim().isNotEmpty
      ? runId.trim()
      : 'run-${(await git.hashText(changes.all.join('\n'))).substring(0, 12)}';

  if (affected.isEmpty) {
    return <String, Object?>{
      'command': 'docnorm.reanalyze',
      'repo': index.root,
      'repo_key': repoKey,
      'run_id': id,
      'dry_run': !commit,
      'committed': commit,
      'changed': changes.toJson(),
      'affected_packages': <String>[],
      'recomputed': <String>[],
      'removed': <String>[],
      'unmatched': unmatched,
      'plan': plan.toJson(),
      'written': <String>[],
      'storage': <String, Object?>{
        'ok': true,
        'writes': <Object?>[],
        'applied': false,
      },
      'notes': const <String>['没有命中任何已索引包：不重算、不写盘'],
    };
  }

  final Set<String> affectedRoots = <String>{
    for (final String packageId in affected)
      if (storedRoots[packageId] != null) storedRoots[packageId]!,
  };
  final RepoIndex subset = RepoIndex(
    root: index.root,
    files: index.files
        .where(
          (RepoFile file) =>
              affectedRoots.any((String root) => _under(file.path, root)),
        )
        .toList(),
    truncated: false,
    skippedFiles: 0,
  );
  final ScanResult rescanned = await scanIndex(subset);
  final Map<String, PackageUnit> rescannedById = <String, PackageUnit>{
    for (final PackageUnit unit in rescanned.packages) unit.id: unit,
  };

  final Map<String, String> hashes = await git.hashPaths(
    rescanned.packages.expand(
      (PackageUnit unit) => _sourcePaths(subset.files, unit.root),
    ),
  );
  final Map<String, String> fingerprints = <String, String>{};
  for (final PackageUnit unit in rescanned.packages) {
    final Map<String, String> subsetHashes = <String, String>{};
    for (final String path in _sourcePaths(subset.files, unit.root)) {
      final String? hash = hashes[path];
      if (hash != null) subsetHashes[path] = hash;
    }
    fingerprints[unit.id] = await git.fingerprint(subsetHashes);
  }

  final Map<String, Map<String, Object?>> desiredPackages =
      <String, Map<String, Object?>>{};
  final Map<String, Map<String, Object?>> desiredStates =
      <String, Map<String, Object?>>{};
  final List<String> recomputed = <String>[];
  final List<String> removed = <String>[];
  for (final String packageId in affected.toList()..sort()) {
    final PackageUnit? unit = rescannedById[packageId];
    if (unit == null) {
      removed.add(packageId);
      continue;
    }
    recomputed.add(packageId);
    final String key = '$repoKey#pkg:${unit.id}';
    desiredPackages[key] = <String, Object?>{
      'schema': 1,
      'repo': repoKey,
      'package': unit.toJson(),
    };
    final Map<String, Object?> state = _pkgState(
      repoKey: repoKey,
      packageId: unit.id,
      fingerprint: fingerprints[unit.id] ?? '',
      now: now,
    );
    if (!_sameState(existing.states[key], state)) desiredStates[key] = state;
  }
  for (final String doc in plan.touchedDocs) {
    final String key = '$repoKey#doc:$doc';
    final String? owner = _ownerId(doc, rescanned.packages);
    final String fingerprint = owner == null ? '' : (fingerprints[owner] ?? '');
    final Set<String> added = <String>{
      ..._stringList(existing.states[key]?['addedSections']),
      ...(plan.addedSectionsByDoc[doc] ?? const <String>{}),
    };
    final Map<String, Object?> state = _docState(
      repoKey: repoKey,
      doc: doc,
      addedSections: (added.toList()..sort()),
      fingerprint: fingerprint,
      now: now,
    );
    if (!_sameState(existing.states[key], state)) desiredStates[key] = state;
  }

  final List<Map<String, Object?>> writes = <Map<String, Object?>>[];
  for (final MapEntry<String, Map<String, Object?>> entry
      in desiredPackages.entries) {
    if (_sameJson(existing.packages[entry.key], entry.value)) continue;
    writes.add(<String, Object?>{
      'op': 'put',
      'collection': 'pkg_index',
      'key': entry.key,
      'value': entry.value,
    });
  }
  for (final MapEntry<String, Map<String, Object?>> entry
      in desiredStates.entries) {
    writes.add(<String, Object?>{
      'op': 'put',
      'collection': 'doc_state',
      'key': entry.key,
      'value': entry.value,
    });
  }
  for (final String packageId in removed) {
    writes.add(<String, Object?>{
      'op': 'delete',
      'collection': 'pkg_index',
      'key': '$repoKey#pkg:$packageId',
    });
    writes.add(<String, Object?>{
      'op': 'delete',
      'collection': 'doc_state',
      'key': '$repoKey#pkg:$packageId',
    });
  }

  final List<String> wouldWrite =
      plan.writes.map((_PlannedFile file) => file.path).toList()..sort();
  final List<String> written = commit
      ? _applyWrites(index.root, plan)
      : const <String>[];

  bool storageApplied = false;
  if (commit && writes.isNotEmpty) {
    await store.ensureAll();
    await store.tx(_opsOf(writes));
    storageApplied = true;
  }

  return <String, Object?>{
    'command': 'docnorm.reanalyze',
    'repo': index.root,
    'repo_key': repoKey,
    'run_id': id,
    'dry_run': !commit,
    'committed': commit,
    'changed': changes.toJson(),
    'affected_packages': affected.toList()..sort(),
    'recomputed': recomputed,
    'removed': removed,
    'unmatched': unmatched,
    'fingerprints': fingerprints,
    'plan': plan.toJson(),
    'would_write': wouldWrite,
    'written': written,
    'doc_state': <String, Object?>{
      'updated': desiredStates.keys.toList()..sort(),
    },
    'storage': <String, Object?>{
      'ok': true,
      'writes': writes,
      'applied': storageApplied,
    },
    'notes': const <String>[
      '只重算受影响包（包内文件全量），不全仓重扫（D23）',
      '没有 pkg_index 基线时 fail-closed（D24）',
    ],
  };
}

/// 仓库身份（存储 key 前缀）：用规范化绝对路径，避免同名仓互相覆盖。
String repoKeyOf(String repo) {
  final String normalized = p.normalize(p.absolute(repo)).replaceAll(r'\', '/');
  if (normalized.length <= 400) return normalized;
  return p.basename(normalized);
}

/// 把变更文件映射到**最具体**的已索引包；同根多生态（root `.`）全部命中。
List<String> _ownersRoot(String path, Map<String, String> roots) {
  int bestLength = -1;
  final List<String> best = <String>[];
  for (final MapEntry<String, String> entry in roots.entries) {
    final String root = entry.value;
    if (root == '.' || path == root || path.startsWith('$root/')) {
      final int length = root == '.' ? 0 : root.length;
      if (length > bestLength) {
        bestLength = length;
        best
          ..clear()
          ..add(entry.key);
      } else if (length == bestLength) {
        best.add(entry.key);
      }
    }
  }
  return best;
}

String? _ownerId(String path, List<PackageUnit> packages) {
  String? best;
  int bestLength = -1;
  for (final PackageUnit unit in packages) {
    final String root = unit.root;
    if (root == '.' || path == root || path.startsWith('$root/')) {
      final int length = root == '.' ? 0 : root.length;
      if (length > bestLength) {
        bestLength = length;
        best = unit.id;
      }
    }
  }
  return best;
}

bool _under(String path, String root) =>
    root == '.' || path == root || path.startsWith('$root/');

/// 参与指纹的源码：排除 Markdown（文档改动不该让代码指纹变化）。
Set<String> _sourcePaths(Iterable<RepoFile> files, String root) => <String>{
  for (final RepoFile file in files)
    if (_under(file.path, root) && !_isDoc(file.path)) file.path,
};

bool _isDoc(String path) {
  final String lower = path.toLowerCase();
  return lower.endsWith('.md') || lower.endsWith('.markdown');
}

class _Existing {
  _Existing({
    required this.contracts,
    required this.packages,
    required this.states,
  });

  final Map<String, Map<String, Object?>> contracts;
  final Map<String, Map<String, Object?>> packages;
  final Map<String, Map<String, Object?>> states;
}

Future<_Existing> _loadExisting(DocStore store, String repoKey) async {
  final String prefix = '$repoKey#';
  final Map<String, Map<String, Object?>> contracts =
      <String, Map<String, Object?>>{};
  final Map<String, Map<String, Object?>> packages =
      <String, Map<String, Object?>>{};
  final Map<String, Map<String, Object?>> states =
      <String, Map<String, Object?>>{};
  for (final StoredRecord record in await store.scan('doc_contract', prefix)) {
    contracts[record.key] = record.value;
  }
  for (final StoredRecord record in await store.scan('pkg_index', prefix)) {
    packages[record.key] = record.value;
  }
  for (final StoredRecord record in await store.scan('doc_state', prefix)) {
    states[record.key] = record.value;
  }
  return _Existing(contracts: contracts, packages: packages, states: states);
}

Map<String, Object?> _pkgState({
  required String repoKey,
  required String packageId,
  required String fingerprint,
  required String now,
}) => <String, Object?>{
  'schema': 1,
  'repo': repoKey,
  'kind': 'package',
  'package': packageId,
  'codeFingerprint': fingerprint,
  'addedSections': <String>[],
  'updatedAt': now,
  'stale': false,
};

Map<String, Object?> _docState({
  required String repoKey,
  required String doc,
  required List<String> addedSections,
  required String fingerprint,
  required String now,
}) => <String, Object?>{
  'schema': 1,
  'repo': repoKey,
  'kind': 'doc',
  'doc': doc,
  'codeFingerprint': fingerprint,
  'addedSections': addedSections,
  'updatedAt': now,
  'stale': false,
};

/// 状态比较忽略 `updatedAt`：同一指纹 + 同一新增章节 ⇒ 0 写盘。
bool _sameState(Map<String, Object?>? previous, Map<String, Object?> next) {
  if (previous == null) return false;
  final Map<String, Object?> left = Map<String, Object?>.from(previous)
    ..remove('updatedAt');
  final Map<String, Object?> right = Map<String, Object?>.from(next)
    ..remove('updatedAt');
  return _sameJson(left, right);
}

List<Map<String, Object?>> _opsOf(List<Map<String, Object?>> writes) =>
    <Map<String, Object?>>[
      for (final Map<String, Object?> write in writes)
        <String, Object?>{
          'op': write['op'],
          'collection': write['collection'],
          'key': write['key'],
          if (write['value'] != null) 'value': write['value'],
        },
    ];

/// 基线缺口：策略要求但文档里还没命中的章节（只报告，不凭空写占位）。
List<Map<String, Object?>> _gaps(DocContract contract) =>
    <Map<String, Object?>>[
      for (final DocViolation item in contract.violations)
        if (item.kind == 'required_sections' || item.kind == 'required_docs')
          <String, Object?>{
            'kind': item.kind,
            'doc': item.doc,
            'detail': item.detail,
          },
    ];

class _Plan {
  _Plan({
    required this.writes,
    required this.skipped,
    required this.rejected,
    required this.addedSectionsByDoc,
    required this.rewriteAllowlist,
  });

  final List<_PlannedFile> writes;
  final List<Map<String, Object?>> skipped;
  final List<Map<String, Object?>> rejected;
  final Map<String, Set<String>> addedSectionsByDoc;
  final List<String> rewriteAllowlist;

  Set<String> get touchedDocs => addedSectionsByDoc.keys.toSet();

  Map<String, Object?> toJson() => <String, Object?>{
    'files': <Map<String, Object?>>[
      for (final _PlannedFile file in writes)
        <String, Object?>{
          'path': file.path,
          'actions': file.actions,
          'changed': file.before != file.after,
          'diff': file.diff,
        },
    ],
    'skipped': skipped,
    'rejected': rejected,
    'rewrite_allowlist': rewriteAllowlist,
  };
}

class _PlannedFile {
  _PlannedFile({
    required this.path,
    required this.actions,
    required this.before,
    required this.after,
  });

  final String path;
  final List<String> actions;
  final String before;
  final String after;

  String get diff => _unifiedDiff(path, before, after);
}

/// 只做两种写入：**追加章节**与**索引追加行**；整篇改写必须进 `rewrite_allowlist`。
_Plan _buildPlan({
  required RepoIndex index,
  required List<Map<String, Object?>> sections,
  required List<Map<String, Object?>> indexes,
  required List<String> rewriteAllowlist,
}) {
  final List<String> allowlist = <String>[
    for (final String item in rewriteAllowlist)
      if (_cleanPath(item).isNotEmpty) _cleanPath(item),
  ];
  final Map<String, String> working = <String, String>{};
  final Map<String, List<String>> actions = <String, List<String>>{};
  final Map<String, Set<String>> added = <String, Set<String>>{};
  final List<Map<String, Object?>> skipped = <Map<String, Object?>>[];
  final List<Map<String, Object?>> rejected = <Map<String, Object?>>[];

  String? contentOf(String path) {
    final String? cached = working[path];
    if (cached != null) return cached;
    final RepoFile? file = _fileOf(index, path);
    if (file == null) return null;
    working[path] = file.content;
    return file.content;
  }

  void mark(String path, String action) {
    actions.putIfAbsent(path, () => <String>[]).add(action);
  }

  for (final Map<String, Object?> proposal in sections) {
    final String doc = _cleanPath(_str(proposal['doc']));
    final String mode = _str(proposal['mode'], fallback: 'append');
    if (doc.isEmpty) {
      rejected.add(<String, Object?>{
        'path': '',
        'reason': 'sections[].doc 非法',
      });
      continue;
    }
    final String? before = contentOf(doc);
    if (before == null) {
      rejected.add(<String, Object?>{
        'path': doc,
        'reason': '文档不存在（只追加既有文档，不凭空新建）',
      });
      continue;
    }
    if (mode == 'rewrite' || proposal['content'] != null) {
      if (!allowlist.contains(doc)) {
        rejected.add(<String, Object?>{
          'path': doc,
          'reason': '整篇改写不在 rewrite_allowlist（D29）',
        });
        continue;
      }
      final String after = proposal['content']?.toString() ?? '';
      if (after == before) {
        skipped.add(<String, Object?>{'path': doc, 'reason': '内容未变化'});
        continue;
      }
      working[doc] = after;
      mark(doc, 'rewrite');
      continue;
    }
    final String heading = _headingOf(_str(proposal['heading']));
    if (heading.isEmpty) {
      rejected.add(<String, Object?>{'path': doc, 'reason': '章节 heading 为空'});
      continue;
    }
    if (before.contains(heading)) {
      skipped.add(<String, Object?>{'path': doc, 'reason': '已存在：$heading'});
      continue;
    }
    final String body = _str(proposal['body']);
    final String block = body.isEmpty ? heading : '$heading\n\n$body';
    working[doc] = _appendBlock(before, block);
    added.putIfAbsent(doc, () => <String>{}).add(heading);
    mark(doc, 'append_section');
  }

  for (final Map<String, Object?> proposal in indexes) {
    final String target = _cleanPath(_str(proposal['index']));
    final String line = _str(proposal['line']);
    if (target.isEmpty || line.isEmpty) {
      rejected.add(<String, Object?>{
        'path': target,
        'reason': 'indexes[] 需要 index 与 line',
      });
      continue;
    }
    final String? before = contentOf(target);
    if (before == null) {
      rejected.add(<String, Object?>{
        'path': target,
        'reason': '索引文件不存在（不凭空新建）',
      });
      continue;
    }
    if (before.split('\n').any((String item) => item.trim() == line)) {
      skipped.add(<String, Object?>{'path': target, 'reason': '索引已有该行'});
      continue;
    }
    final String group = _str(proposal['group']);
    working[target] = group.isEmpty
        ? _appendBlock(before, line)
        : _insertAtGroupEnd(before, line, group);
    mark(target, group.isEmpty ? 'append_index' : 'insert_index_group');
  }

  final List<_PlannedFile> writes = <_PlannedFile>[];
  for (final MapEntry<String, String> entry in working.entries) {
    final RepoFile? file = _fileOf(index, entry.key);
    if (file == null) continue;
    if (file.content == entry.value) continue;
    writes.add(
      _PlannedFile(
        path: entry.key,
        actions: actions[entry.key] ?? const <String>[],
        before: file.content,
        after: entry.value,
      ),
    );
  }
  writes.sort((_PlannedFile a, _PlannedFile b) => a.path.compareTo(b.path));
  return _Plan(
    writes: writes,
    skipped: skipped,
    rejected: rejected,
    addedSectionsByDoc: added,
    rewriteAllowlist: allowlist,
  );
}

List<String> _applyWrites(String root, _Plan plan) {
  final List<String> written = <String>[];
  for (final _PlannedFile file in plan.writes) {
    if (file.before == file.after) continue;
    final String full = p.joinAll(<String>[root, ...file.path.split('/')]);
    final File target = File(full);
    target.parent.createSync(recursive: true);
    target.writeAsStringSync(file.after);
    written.add(file.path);
  }
  written.sort();
  return written;
}

/// 章节识别沿用契约口径：已存在就不写；只追加，绝不改既有行。
String _headingOf(String raw) {
  final String text = raw.trim();
  if (text.isEmpty) return '';
  return RegExp(r'^#{1,6}\s').hasMatch(text) ? text : '## $text';
}

String _appendBlock(String content, String block) {
  final StringBuffer buffer = StringBuffer(content);
  if (content.isNotEmpty && !content.endsWith('\n')) buffer.write('\n');
  if (content.isNotEmpty && !content.endsWith('\n\n')) buffer.write('\n');
  buffer.write(block);
  if (!block.endsWith('\n')) buffer.write('\n');
  return buffer.toString();
}

/// 追加式插入：找到分组标题，把新行插到该分组末尾（下一条同级/更高级标题之前）。
/// 既有行的相对顺序与内容一个字节都不动。
String _insertAtGroupEnd(String content, String line, String group) {
  final List<String> lines = content.split('\n');
  int groupIndex = -1;
  int groupLevel = 6;
  for (int index = 0; index < lines.length; index++) {
    final RegExpMatch? match = RegExp(r'^(#{1,6})\s+(.*)$')
        .firstMatch(lines[index]);
    if (match == null) continue;
    if (match.group(2)!.trim().contains(group)) {
      groupIndex = index;
      groupLevel = match.group(1)!.length;
      break;
    }
  }
  if (groupIndex < 0) return _appendBlock(content, line);
  int insertAt = lines.length;
  for (int index = groupIndex + 1; index < lines.length; index++) {
    final RegExpMatch? match = RegExp(r'^(#{1,6})\s+').firstMatch(lines[index]);
    if (match != null && match.group(1)!.length <= groupLevel) {
      insertAt = index;
      break;
    }
  }
  // 插到分组内容的末尾（下一标题前的空行之前），不把新行挤到分隔空行下面。
  while (insertAt > groupIndex + 1 && lines[insertAt - 1].trim().isEmpty) {
    insertAt--;
  }
  lines.insert(insertAt, line);
  final String joined = lines.join('\n');
  return joined.endsWith('\n') ? joined : '$joined\n';
}

String _unifiedDiff(String path, String before, String after) {
  if (before == after) return '';
  final List<String> left = before.split('\n');
  final List<String> right = after.split('\n');
  int prefix = 0;
  while (prefix < left.length &&
      prefix < right.length &&
      left[prefix] == right[prefix]) {
    prefix++;
  }
  int suffix = 0;
  while (suffix < left.length - prefix &&
      suffix < right.length - prefix &&
      left[left.length - 1 - suffix] == right[right.length - 1 - suffix]) {
    suffix++;
  }
  final List<String> context = prefix >= 3
      ? left.sublist(prefix - 3, prefix)
      : left.sublist(0, prefix);
  final List<String> removed = left.sublist(prefix, left.length - suffix);
  final List<String> added = right.sublist(prefix, right.length - suffix);
  final StringBuffer buffer = StringBuffer()
    ..writeln('--- a/$path')
    ..writeln('+++ b/$path');
  if (context.isNotEmpty) {
    for (final String line in context) {
      buffer.writeln(' $line');
    }
  }
  for (final String line in removed) {
    buffer.writeln('-$line');
  }
  for (final String line in added) {
    buffer.writeln('+$line');
  }
  return buffer.toString();
}

String _cleanPath(String raw) {
  String text = raw.trim().replaceAll(r'\', '/');
  while (text.startsWith('./')) {
    text = text.substring(2);
  }
  if (text.isEmpty || text.startsWith('/') || text.contains(':')) return '';
  final List<String> parts = text.split('/');
  if (parts.any((String part) => part.isEmpty || part == '..')) return '';
  return parts.join('/');
}

RepoFile? _fileOf(RepoIndex index, String path) {
  for (final RepoFile file in index.files) {
    if (file.path == path) return file;
  }
  return null;
}

Map<String, dynamic> _map(Object? value) => value is Map
    ? value.map(
        (Object? key, Object? item) =>
            MapEntry<String, dynamic>(key.toString(), item),
      )
    : <String, dynamic>{};

String _str(Object? value, {String fallback = ''}) {
  final String text = (value ?? '').toString().trim();
  return text.isEmpty ? fallback : text;
}

String _text(Object? value) => (value ?? '').toString().trim();

List<String> _stringList(Object? value) => value is List
    ? value
          .map((Object? item) => item.toString().trim())
          .where((String item) => item.isNotEmpty)
          .toList()
    : const <String>[];

/// 稳定比较（Map 键排序后再编码，避免存储往返造成的键序差异）。
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
  if (value is List) {
    return value.map(_canonical).toList();
  }
  return value;
}

String _nowIso() => DateTime.now().toUtc().toIso8601String();
