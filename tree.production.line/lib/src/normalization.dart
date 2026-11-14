/// 文档归一化（LG-02 / PC-2C）的领域模型：计划清单、manifest 与路径约束。
///
/// 口径（`docs/pluginization/production-line-gates.md` §3.2）：
/// - `production.normalize.plan` 只复用 docnorm 的 dry-run，**0 写盘**；
/// - manifest 落项目资产 `normalization/<runId>/plan.json`，apply 前必须有它；
/// - 写入只允许工作空间内的既有文件；路径必须重新校验（防 `../` / 绝对路径）；
/// - 写前记录 `before_sha256`，备份在同一 run 目录的 `before/` 下；
/// - 状态机：`planned → applying → applied → rolled_back / failed`。
///
/// 这一层只做纯计算与文件读写（不调 docnorm）；命令门面见
/// `normalization_service.dart` / `readiness_service.dart`。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'store.dart';

/// manifest schema 版本（变更时旧计划自动失效）。
const int kNormalizationManifestVersion = 1;

/// 归一化 manifest 的合法状态。
const List<String> kNormalizationStates = <String>[
  'planned',
  'applying',
  'applied',
  'failed',
  'rolled_back',
];

/// 已产生写入结论的状态：计算 `line.ready` 指纹时只看这些。
const Set<String> kNormalizationCommittedStates = <String>{
  'applied',
  'failed',
  'rolled_back',
};

/// docnorm 站命令（插件层接 `tree.docnorm`；单测注入假实现）。
typedef DocnormProbe =
    Future<Map<String, Object?>> Function(
      String command,
      Map<String, Object?> arguments,
      Map<String, Object?> scope,
    );

/// 逻辑去重状态（`production.dedup.status`）的探测口。
typedef DedupStatusProbe =
    Future<Map<String, Object?>> Function(
      String lineId,
      Map<String, Object?> meta,
      Map<String, Object?> scope,
    );

/// 文件字节的 sha256（小写十六进制）。
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// 工作空间内的相对路径校验：绝对路径 / 盘符 / `..` / `.` 一律拒绝。
///
/// 返回规范化后的 `/` 分隔相对路径；非法时返回 `null`（由调用方拒绝或报错）。
String? safeWorkspaceRelativePath(String workspace, Object? raw) {
  final String text = textOf(raw).replaceAll('\\', '/');
  if (text.isEmpty) return null;
  if (text.startsWith('/')) return null;
  if (text.contains(':')) return null;
  final List<String> parts = text.split('/');
  if (parts.any(
    (String part) => part.isEmpty || part == '.' || part == '..',
  )) {
    return null;
  }
  final String root = p.normalize(p.absolute(workspace));
  final String full = p.normalize(p.joinAll(<String>[root, ...parts]));
  final String prefix = root.endsWith(p.separator) ? root : '$root${p.separator}';
  if (full != root && !full.startsWith(prefix)) return null;
  return parts.join('/');
}

/// 计划里的一个文件：动作、diff、写前/写后哈希与备份位置。
class NormalizationFile {
  NormalizationFile({
    required this.path,
    required this.actions,
    this.changed = true,
    this.diff = '',
    this.beforeSha256 = '',
    this.afterSha256 = '',
    this.backup = '',
    this.backupSha256 = '',
  });

  final String path;
  final List<String> actions;
  final bool changed;
  final String diff;

  /// 计划生成时的文件哈希（apply 时先核对，防止计划过期）。
  String beforeSha256;

  /// apply 落盘后的文件哈希（未写入时等于 before）。
  String afterSha256;

  /// 备份相对项目资产根的路径（`normalization/<runId>/before/...`）。
  String backup;
  String backupSha256;

  /// 整篇改写必须二次确认 + allowlist。
  bool get requiresRewrite => actions.contains('rewrite');

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'actions': actions,
    'changed': changed,
    'diff': diff,
    'before_sha256': beforeSha256,
    'after_sha256': afterSha256,
    'backup': backup,
    'backup_sha256': backupSha256,
  };

  static NormalizationFile? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Map<String, Object?> data = plainMap(raw);
    final String path = textOf(data['path']);
    if (path.isEmpty) return null;
    return NormalizationFile(
      path: path,
      actions: stringsOf(data['actions']),
      changed: data['changed'] != false,
      diff: textOf(data['diff']),
      beforeSha256: textOf(data['before_sha256']),
      afterSha256: textOf(data['after_sha256']),
      backup: textOf(data['backup']),
      backupSha256: textOf(data['backup_sha256']),
    );
  }
}

/// 一次归一化运行的计划 / 备份 / 结论。
class NormalizationManifest {
  NormalizationManifest({
    required this.lineId,
    required this.runId,
    required this.workspace,
    required this.createdAt,
    this.state = 'planned',
    this.arguments = const <String, Object?>{},
    this.rewriteAllowlist = const <String>[],
    this.files = const <NormalizationFile>[],
    this.rejected = const <Map<String, Object?>>[],
    this.skipped = const <Map<String, Object?>>[],
    this.docnorm = const <String, Object?>{},
    this.written = const <String>[],
    this.restored = const <String>[],
    this.appliedAt = '',
    this.failedAt = '',
    this.rolledBackAt = '',
    this.error = '',
  });

  final String lineId;
  final String runId;
  final String workspace;
  final String createdAt;
  String state;

  /// 复现 apply 的 docnorm 入参（`sections` / `indexes`）。
  final Map<String, Object?> arguments;
  final List<String> rewriteAllowlist;
  final List<NormalizationFile> files;
  final List<Map<String, Object?>> rejected;
  final List<Map<String, Object?>> skipped;

  /// 计划时的 docnorm 证据摘要（指纹 / git / 契约 / 包）。
  final Map<String, Object?> docnorm;

  List<String> written;
  List<String> restored;
  String appliedAt;
  String failedAt;
  String rolledBackAt;
  String error;

  List<String> get rewritePaths => <String>[
    for (final NormalizationFile file in files)
      if (file.requiresRewrite) file.path,
  ];

  Map<String, Object?> toJson() => <String, Object?>{
    'version': kNormalizationManifestVersion,
    'kind': 'normalization_plan',
    'line_id': lineId,
    'run_id': runId,
    'workspace': workspace,
    'created_at': createdAt,
    'state': state,
    'arguments': arguments,
    'rewrite_allowlist': rewriteAllowlist,
    'files': <Map<String, Object?>>[
      for (final NormalizationFile file in files) file.toJson(),
    ],
    'rejected': rejected,
    'skipped': skipped,
    'docnorm': docnorm,
    'written': written,
    'restored': restored,
    'applied_at': appliedAt,
    'failed_at': failedAt,
    'rolled_back_at': rolledBackAt,
    'error': error,
  };

  static NormalizationManifest? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Map<String, Object?> data = plainMap(raw);
    if (intOf(data['version'], 0) != kNormalizationManifestVersion) return null;
    final String lineId = textOf(data['line_id']);
    final String runId = textOf(data['run_id']);
    if (lineId.isEmpty || runId.isEmpty) return null;
    final List<NormalizationFile> files = <NormalizationFile>[];
    for (final Object? item
        in (data['files'] as List<Object?>? ?? const <Object?>[])) {
      final NormalizationFile? file = NormalizationFile.fromJson(item);
      if (file != null) files.add(file);
    }
    return NormalizationManifest(
      lineId: lineId,
      runId: runId,
      workspace: textOf(data['workspace']),
      createdAt: textOf(data['created_at']),
      state: textOf(data['state']).isEmpty ? 'planned' : textOf(data['state']),
      arguments: plainMap(data['arguments']),
      rewriteAllowlist: stringsOf(data['rewrite_allowlist']),
      files: files,
      rejected: <Map<String, Object?>>[
        for (final Object? item
            in (data['rejected'] as List<Object?>? ?? const <Object?>[]))
          if (item is Map) plainMap(item),
      ],
      skipped: <Map<String, Object?>>[
        for (final Object? item
            in (data['skipped'] as List<Object?>? ?? const <Object?>[]))
          if (item is Map) plainMap(item),
      ],
      docnorm: plainMap(data['docnorm']),
      written: stringsOf(data['written']),
      restored: stringsOf(data['restored']),
      appliedAt: textOf(data['applied_at']),
      failedAt: textOf(data['failed_at']),
      rolledBackAt: textOf(data['rolled_back_at']),
      error: textOf(data['error']),
    );
  }
}

/// 项目资产根（工作空间未配置 / 非绝对路径时返回 `null`）。
String? normalizationAssetRoot(ProductionStore store, String lineId) {
  try {
    return store.assetRoot(lineId);
  } on ProductionFailure {
    return null;
  }
}

String normalizationManifestRelativePath(String runId) =>
    'normalization/$runId/plan.json';

/// 写 `normalization/<runId>/plan.json`；返回资产根下的相对路径。
String writeNormalizationManifest(
  ProductionStore store,
  NormalizationManifest manifest,
) {
  final String relative = normalizationManifestRelativePath(manifest.runId);
  store.writeAsset(
    manifest.lineId,
    relative,
    '${const JsonEncoder.withIndent('  ').convert(manifest.toJson())}\n',
  );
  return relative;
}

/// 读一次运行的 manifest；不存在 / 坏 JSON / 版本不符 ⇒ `null`。
NormalizationManifest? readNormalizationManifest(
  ProductionStore store,
  String lineId,
  String runId,
) {
  final String? root = normalizationAssetRoot(store, lineId);
  if (root == null) return null;
  final File file = File(
    p.joinAll(<String>[root, 'normalization', runId, 'plan.json']),
  );
  if (!file.existsSync()) return null;
  try {
    final Object? decoded = json.decode(file.readAsStringSync());
    return NormalizationManifest.fromJson(decoded);
  } catch (_) {
    return null;
  }
}

/// 全部 manifest（按 `created_at` / `run_id` 升序）。
List<NormalizationManifest> listNormalizationManifests(
  ProductionStore store,
  String lineId,
) {
  final String? root = normalizationAssetRoot(store, lineId);
  if (root == null) return const <NormalizationManifest>[];
  final Directory dir = Directory(p.join(root, 'normalization'));
  if (!dir.existsSync()) return const <NormalizationManifest>[];
  final List<NormalizationManifest> manifests = <NormalizationManifest>[];
  for (final FileSystemEntity entity in dir.listSync()) {
    if (entity is! Directory) continue;
    final NormalizationManifest? manifest = readNormalizationManifest(
      store,
      lineId,
      p.basename(entity.path),
    );
    if (manifest != null) manifests.add(manifest);
  }
  manifests.sort((NormalizationManifest a, NormalizationManifest b) {
    final int byCreated = a.createdAt.compareTo(b.createdAt);
    return byCreated != 0 ? byCreated : a.runId.compareTo(b.runId);
  });
  return manifests;
}

/// 最新一版 manifest；[committedOnly] 只看已产生写入结论的版本。
NormalizationManifest? latestNormalizationManifest(
  ProductionStore store,
  String lineId, {
  bool committedOnly = false,
}) {
  final List<NormalizationManifest> manifests = listNormalizationManifests(
    store,
    lineId,
  );
  NormalizationManifest? latest;
  for (final NormalizationManifest manifest in manifests) {
    if (committedOnly &&
        !kNormalizationCommittedStates.contains(manifest.state)) {
      continue;
    }
    latest = manifest;
  }
  return latest;
}

/// `line.ready` 指纹里的归一化分量：`<runId>:<state>:<docHash>`（无记录 ⇒ `none`）。
///
/// 只忽略 `planned`：新计划是只读的，不该让 ready 失效；而 `applying` 必须
/// 让旧快照立即失效（写入期间禁止开新任务）。
/// `docHash` 是本次归一化涉及文档**内容哈希**的聚合（path + after/before sha256），
/// 不是只取 HEAD：文档被改而 git 未提交时，ready 快照同样会 stale。
String normalizationVersionOf(ProductionStore store, String lineId) {
  NormalizationManifest? latest;
  for (final NormalizationManifest manifest in listNormalizationManifests(
    store,
    lineId,
  )) {
    if (manifest.state == 'planned') continue;
    latest = manifest;
  }
  if (latest == null) return 'none';
  return '${latest.runId}:${latest.state}:${_docContentHash(latest)}';
}

/// 文档内容指纹：文件路径 + 内容 sha256 的稳定聚合（16 位十六进制）。
String _docContentHash(NormalizationManifest manifest) {
  final List<String> rows = <String>[
    for (final NormalizationFile file in manifest.files)
      '${file.path}:'
          '${file.afterSha256.isEmpty ? file.beforeSha256 : file.afterSha256}',
  ]..sort();
  if (rows.isEmpty) return 'nodocs';
  return sha256Hex(utf8.encode(rows.join('\n'))).substring(0, 16);
}

/// `test/ ↔ lib/` 映射（LG-06 的确定性证据）。
class TestMap {
  const TestMap({
    required this.entries,
    required this.libFiles,
    required this.testFiles,
  });

  final List<Map<String, Object?>> entries;
  final int libFiles;
  final int testFiles;

  int get mapped => entries.length;

  Map<String, Object?> toJson() => <String, Object?>{
    'entries': entries,
    'lib_files': libFiles,
    'test_files': testFiles,
    'mapped': mapped,
  };
}

const Set<String> _kTestMapSkipDirs = <String>{
  '.git',
  '.dart_tool',
  'build',
  'node_modules',
  '.input',
  '.idea',
  '.vscode',
};

const int _kMaxTestMapFiles = 20000;

/// 扫描工作空间，生成 `lib/**` ↔ `test/**` 的确定性映射。
///
/// 不做覆盖率判定：只回答"映射是否已生成"；命中数作为证据回包。
TestMap buildTestMap(String workspace) {
  final List<String> libs = <String>[];
  final List<String> tests = <String>[];
  int scanned = 0;
  final List<Directory> stack = <Directory>[Directory(workspace)];
  while (stack.isNotEmpty && scanned < _kMaxTestMapFiles) {
    final Directory dir = stack.removeLast();
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync()
        ..sort(
          (FileSystemEntity a, FileSystemEntity b) =>
              a.path.compareTo(b.path),
        );
    } catch (_) {
      continue;
    }
    for (final FileSystemEntity entity in entries) {
      if (scanned >= _kMaxTestMapFiles) break;
      if (entity is Directory) {
        if (_kTestMapSkipDirs.contains(p.basename(entity.path))) continue;
        stack.add(entity);
        continue;
      }
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      scanned += 1;
      final String relative = p
          .relative(entity.path, from: workspace)
          .replaceAll('\\', '/');
      if (relative.split('/').contains('lib')) libs.add(relative);
      if (relative.endsWith('_test.dart') &&
          relative.split('/').contains('test')) {
        tests.add(relative);
      }
    }
  }
  final List<String> sortedLibs = libs..sort();
  final List<String> sortedTests = tests..sort();
  final List<Map<String, Object?>> entries = <Map<String, Object?>>[];
  for (final String lib in sortedLibs) {
    final String key = _libKeyOf(lib);
    if (key.isEmpty) continue;
    final String base = p.url.basenameWithoutExtension(key);
    final List<String> matches = <String>[
      for (final String test in sortedTests)
        if (_testMatches(test, key, base)) test,
    ];
    if (matches.isEmpty) continue;
    entries.add(<String, Object?>{
      'lib': lib,
      'tests': matches,
    });
  }
  return TestMap(
    entries: entries,
    libFiles: sortedLibs.length,
    testFiles: sortedTests.length,
  );
}

/// `packages/x/lib/src/a.dart` → `src/a`（取第一个 `lib/` 之后的路径）。
String _libKeyOf(String relative) {
  final List<String> parts = relative.split('/');
  final int index = parts.indexOf('lib');
  if (index < 0 || index == parts.length - 1) return '';
  final String inner = parts.sublist(index + 1).join('/');
  return inner.endsWith('.dart')
      ? inner.substring(0, inner.length - '.dart'.length)
      : inner;
}

/// 测试文件是否对应某个 lib key：`test/src/a_test.dart` 或 `test/a_test.dart`。
bool _testMatches(String test, String key, String base) {
  final List<String> parts = test.split('/');
  final int index = parts.lastIndexOf('test');
  if (index < 0 || index == parts.length - 1) return false;
  final String inner = parts.sublist(index + 1).join('/');
  return inner == '${key}_test.dart' || inner == '${base}_test.dart';
}
