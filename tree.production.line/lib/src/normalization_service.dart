/// 文档归一化命令门面（PC-2C / LG-02）：
/// `production.normalize.plan|apply|rollback|status`。
///
/// 复用 `tree.docnorm` 的 `docnorm.baseline`（`commit=false/true`），不复制
/// 文档改写逻辑；产线只负责：
/// - `plan`：dry-run，0 写盘；把 files/rejected/skipped 落
///   `normalization/<runId>/plan.json`；
/// - `apply`：必须匹配已有计划；写前备份 + `before_sha256`；只追加/索引，
///   整篇改写要 `confirm_rewrite=true` 且路径在 `rewrite_allowlist`；
///   **不执行 git commit**；失败自动恢复备份并标记 `failed`；
/// - `rollback`：按备份恢复并核对 sha256；可重复调用；
/// - `status`：最新 manifest + 状态。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';
import 'normalization.dart';
import 'readiness.dart';
import 'service.dart';
import 'store.dart';

/// 文档归一化对外开放的命令。
const List<String> kNormalizationCommands = <String>[
  'production.normalize.plan',
  'production.normalize.apply',
  'production.normalize.rollback',
  'production.normalize.status',
];

class ProductionNormalizationService {
  ProductionNormalizationService({
    Map<String, String>? environment,
    DateTime Function()? clock,
    this.docnorm,
  }) : _environment = environment ?? Platform.environment,
       _clock = clock ?? DateTime.now;

  final Map<String, String> _environment;
  final DateTime Function() _clock;

  /// docnorm 站命令（缺失 ⇒ plan/apply 明确失败，不假装归一化）。
  final DocnormProbe? docnorm;

  Future<Map<String, Object?>> handle(
    String command,
    Map<String, Object?> arguments,
    Map<String, Object?> meta,
    Map<String, Object?> scope,
  ) async {
    final ProductionTarget target = resolveProductionTarget(
      meta,
      scope,
      _environment,
    );
    final ProductionStore store = ProductionStore(
      dataRoot: target.dataRoot,
      clock: _clock,
    );
    switch (command) {
      case 'production.normalize.plan':
        return _plan(store, arguments, scope);
      case 'production.normalize.apply':
        return _apply(store, arguments, scope);
      case 'production.normalize.rollback':
        return _rollback(store, arguments);
      case 'production.normalize.status':
        return _status(store, arguments);
      default:
        throw ProductionFailure(
          '未知归一化命令：$command',
          code: 'unknown_command',
        );
    }
  }

  String get _now => _clock().toIso8601String();

  // ── plan ──────────────────────────────────────────────────────────

  Future<Map<String, Object?>> _plan(
    ProductionStore store,
    Map<String, Object?> arguments,
    Map<String, Object?> scope,
  ) async {
    final String lineId = _argument(arguments, 'line_id');
    final LineRecord line = store.getLine(lineId);
    final String workspace = _workspace(store, line);
    final String runId = _runId(arguments);
    final List<Map<String, Object?>> sections = _mapsOf(arguments['sections']);
    final List<Map<String, Object?>> indexes = _mapsOf(arguments['indexes']);
    final List<String> allowlist = _cleanPaths(
      _stringsOf(arguments['rewrite_allowlist']),
    );
    final Map<String, Object?> payload = await _probe(
      'docnorm.baseline',
      <String, Object?>{
        'repo': workspace,
        'commit': false,
        'run_id': runId,
        'sections': sections,
        'indexes': indexes,
        'rewrite_allowlist': allowlist,
      },
      scope,
    );

    final Map<String, Object?> plan = plainMap(payload['plan']);
    final List<NormalizationFile> files = <NormalizationFile>[];
    final List<Map<String, Object?>> rejected = <Map<String, Object?>>[
      ..._mapsOf(plan['rejected']),
    ];
    final List<Map<String, Object?>> skipped = <Map<String, Object?>>[
      ..._mapsOf(plan['skipped']),
    ];
    for (final Map<String, Object?> raw in _mapsOf(plan['files'])) {
      final String rawPath = textOf(raw['path']);
      final String? safe = safeWorkspaceRelativePath(workspace, rawPath);
      if (safe == null) {
        rejected.add(<String, Object?>{
          'path': rawPath,
          'reason': 'path_outside_workspace',
        });
        continue;
      }
      final File file = _workspaceFile(workspace, safe);
      if (!file.existsSync()) {
        rejected.add(<String, Object?>{
          'path': safe,
          'reason': 'file_missing（只写既有文件，不新建）',
        });
        continue;
      }
      files.add(
        NormalizationFile(
          path: safe,
          actions: _stringsOf(raw['actions']),
          changed: raw['changed'] != false,
          diff: textOf(raw['diff']),
          beforeSha256: sha256Hex(file.readAsBytesSync()),
        ),
      );
    }
    files.sort(
      (NormalizationFile a, NormalizationFile b) => a.path.compareTo(b.path),
    );

    final NormalizationManifest manifest = NormalizationManifest(
      lineId: lineId,
      runId: runId,
      workspace: workspace,
      createdAt: _now,
      arguments: <String, Object?>{
        'sections': sections,
        'indexes': indexes,
      },
      rewriteAllowlist: allowlist,
      files: files,
      rejected: rejected,
      skipped: skipped,
      docnorm: <String, Object?>{
        'code_fingerprint': textOf(payload['code_fingerprint']),
        'repo_key': textOf(payload['repo_key']),
        'git': plainMap(payload['git']),
        'contract': plainMap(payload['contract']),
        'packages': plainMap(payload['packages']),
      },
    );
    final String manifestPath = writeNormalizationManifest(store, manifest);
    return <String, Object?>{
      'command': 'production.normalize.plan',
      'line_id': lineId,
      'run_id': runId,
      'phase': line.effectivePhase,
      'dry_run': true,
      'writes': 0,
      'files': <Map<String, Object?>>[
        for (final NormalizationFile file in files) file.toJson(),
      ],
      'rejected': rejected,
      'skipped': skipped,
      'rewrite_allowlist': allowlist,
      'summary': <String, Object?>{
        'files': files.length,
        'rewrites': manifest.rewritePaths.length,
        'rejected': rejected.length,
        'skipped': skipped.length,
      },
      'manifest': manifestPath,
      'docnorm': manifest.docnorm,
      'notes': const <String>[
        'plan 复用 docnorm.baseline（commit=false）：0 写盘',
        '计划落项目资产 normalization/<runId>/plan.json；apply 必须匹配它',
      ],
    };
  }

  // ── apply ─────────────────────────────────────────────────────────

  Future<Map<String, Object?>> _apply(
    ProductionStore store,
    Map<String, Object?> arguments,
    Map<String, Object?> scope,
  ) async {
    final String lineId = _argument(arguments, 'line_id');
    LineRecord line = store.getLine(lineId);
    final String workspace = _workspace(store, line);
    final NormalizationManifest? manifest = _resolveManifest(
      store,
      lineId,
      arguments,
    );
    if (manifest == null) {
      throw ProductionFailure(
        '没有可应用的归一化计划：先 production.normalize.plan',
        code: 'normalization_plan_missing',
        missing: const <String>['normalization_plan'],
      );
    }
    if (manifest.state == 'applying') {
      throw ProductionFailure(
        '归一化正在写入中：稍后重试或先 rollback',
        code: 'normalization_in_progress',
      );
    }
    if (manifest.state == 'rolled_back') {
      throw ProductionFailure(
        '计划 ${manifest.runId} 已回滚：重新 plan 后再 apply',
        code: 'normalization_plan_rolled_back',
        missing: <String>[manifest.runId],
      );
    }
    if (!p.equals(p.normalize(manifest.workspace), workspace)) {
      throw ProductionFailure(
        '计划的工作空间与产线不一致：先重新 plan',
        code: 'normalization_plan_stale',
        missing: const <String>['workspace'],
      );
    }

    // 路径重新校验：manifest 是不可信输入（防手改 / 计划漂移）。
    for (final NormalizationFile file in manifest.files) {
      if (safeWorkspaceRelativePath(workspace, file.path) == null) {
        throw ProductionFailure(
          '计划里的路径越出工作空间：${file.path}',
          code: 'path_outside_workspace',
          missing: <String>[file.path],
        );
      }
    }

    final List<String> allowlist = <String>{
      ...manifest.rewriteAllowlist,
      ..._cleanPaths(_stringsOf(arguments['rewrite_allowlist'])),
    }.toList()..sort();
    final List<String> rewrites = manifest.rewritePaths;
    final bool applied = manifest.state == 'applied';
    if (!applied && rewrites.isNotEmpty) {
      if (arguments['confirm_rewrite'] != true) {
        throw ProductionFailure(
          '计划包含整篇改写，必须 confirm_rewrite=true 二次确认：${rewrites.join('、')}',
          code: 'rewrite_confirmation_required',
          missing: rewrites,
        );
      }
      final List<String> notAllowed = <String>[
        for (final String path in rewrites)
          if (!allowlist.contains(path)) path,
      ];
      if (notAllowed.isNotEmpty) {
        throw ProductionFailure(
          '整篇改写不在 rewrite_allowlist：${notAllowed.join('、')}',
          code: 'rewrite_not_allowed',
          missing: notAllowed,
        );
      }
    }

    // 重复 apply：只确认 docnorm 仍然 0 写，不改 manifest。
    if (applied) {
      final Map<String, Object?> payload = await _commit(
        manifest,
        workspace,
        scope,
        rewriteAllowlist: allowlist,
      );
      final List<String> written = _stringsOf(payload['written']);
      return <String, Object?>{
        'command': 'production.normalize.apply',
        'line_id': lineId,
        'run_id': manifest.runId,
        'phase': line.effectivePhase,
        'state': manifest.state,
        'applied': false,
        'idempotent': written.isEmpty,
        'written': written,
        'files': <Map<String, Object?>>[
          for (final NormalizationFile file in manifest.files) file.toJson(),
        ],
        'rewrites': rewrites,
        'manifest': normalizationManifestRelativePath(manifest.runId),
        'notes': const <String>['重复 apply：docnorm 仍 0 写，manifest 保持不变'],
      };
    }

    // 计划过期保护：写前逐文件核对 sha256。
    for (final NormalizationFile file in manifest.files) {
      final File target = _workspaceFile(workspace, file.path);
      final String current = target.existsSync()
          ? sha256Hex(target.readAsBytesSync())
          : '';
      if (current != file.beforeSha256) {
        throw ProductionFailure(
          '计划已过期：${file.path} 的内容在 plan 之后被改过，请重新 plan',
          code: 'normalization_plan_stale',
          missing: <String>[file.path],
        );
      }
    }

    manifest.state = 'applying';
    manifest.error = '';
    writeNormalizationManifest(store, manifest);
    try {
      // 写前备份：每个目标文件一份；备份路径与 sha256 记进 manifest。
      for (final NormalizationFile file in manifest.files) {
        final File target = _workspaceFile(workspace, file.path);
        final List<int> bytes = target.readAsBytesSync();
        final String backupRelative =
            'normalization/${manifest.runId}/before/${file.path}';
        store.writeAsset(
          lineId,
          backupRelative,
          utf8.decode(bytes, allowMalformed: true),
        );
        file.backup = backupRelative;
        file.backupSha256 = sha256Hex(bytes);
      }
      writeNormalizationManifest(store, manifest);

      final Map<String, Object?> payload = await _commit(
        manifest,
        workspace,
        scope,
        rewriteAllowlist: allowlist,
      );
      final List<String> written = _stringsOf(payload['written']);
      final List<String> planned = <String>[
        for (final NormalizationFile file in manifest.files) file.path,
      ];
      final List<String> unexpected = <String>[
        for (final String path in written)
          if (!planned.contains(path)) path,
      ];
      if (unexpected.isNotEmpty) {
        throw ProductionFailure(
          'docnorm 写了计划之外的文件：${unexpected.join('、')}',
          code: 'normalization_apply_failed',
          missing: unexpected,
        );
      }
      for (final NormalizationFile file in manifest.files) {
        final File target = _workspaceFile(workspace, file.path);
        file.afterSha256 = target.existsSync()
            ? sha256Hex(target.readAsBytesSync())
            : '';
      }
      manifest
        ..state = 'applied'
        ..written = written
        ..appliedAt = _now;
      writeNormalizationManifest(store, manifest);
      line = _advancePhase(store, line, 'indexing');
      return <String, Object?>{
        'command': 'production.normalize.apply',
        'line_id': lineId,
        'run_id': manifest.runId,
        'phase': line.effectivePhase,
        'state': manifest.state,
        'applied': written.isNotEmpty,
        'idempotent': written.isEmpty,
        'written': written,
        'files': <Map<String, Object?>>[
          for (final NormalizationFile file in manifest.files) file.toJson(),
        ],
        'rewrites': rewrites,
        'backup_dir': 'normalization/${manifest.runId}/before',
        'manifest': normalizationManifestRelativePath(manifest.runId),
        'notes': const <String>[
          '写入只追加/索引既有文件；默认不执行 git commit',
          'apply 完成后需重建索引并 production.readiness.get 才允许开任务',
        ],
      };
    } catch (error) {
      String restoreError = '';
      List<String> restored = <String>[];
      try {
        restored = _restoreAll(store, lineId, workspace, manifest);
      } catch (restoreFailure) {
        restoreError = '$restoreFailure';
      }
      manifest
        ..state = 'failed'
        ..failedAt = _now
        ..error = restoreError.isEmpty ? '$error' : '$error（恢复失败：$restoreError）';
      manifest.restored = restored;
      writeNormalizationManifest(store, manifest);
      throw ProductionFailure(
        restoreError.isEmpty
            ? '归一化写入失败，已恢复备份：$error'
            : '归一化写入失败，且备份恢复失败：$error；$restoreError',
        code: 'normalization_apply_failed',
        missing: <String>[
          if (restoreError.isEmpty) 'normalization_apply' else 'restore_failed',
        ],
      );
    }
  }

  // ── rollback ──────────────────────────────────────────────────────

  Map<String, Object?> _rollback(
    ProductionStore store,
    Map<String, Object?> arguments,
  ) {
    final String lineId = _argument(arguments, 'line_id');
    LineRecord line = store.getLine(lineId);
    final String workspace = _workspace(store, line);
    final NormalizationManifest? manifest = _resolveManifest(
      store,
      lineId,
      arguments,
    );
    if (manifest == null) {
      throw ProductionFailure(
        '没有可回滚的归一化计划',
        code: 'normalization_plan_missing',
        missing: const <String>['normalization_plan'],
      );
    }
    if (manifest.state == 'applying') {
      throw ProductionFailure(
        '归一化正在写入中：等它结束（成功或自动恢复）后再回滚',
        code: 'normalization_in_progress',
      );
    }
    if (manifest.state == 'rolled_back') {
      return <String, Object?>{
        'command': 'production.normalize.rollback',
        'line_id': lineId,
        'run_id': manifest.runId,
        'phase': line.effectivePhase,
        'state': manifest.state,
        'restored': manifest.restored,
        'idempotent': true,
        'manifest': normalizationManifestRelativePath(manifest.runId),
        'notes': const <String>['已经回滚过：重复调用 0 写'],
      };
    }
    final List<String> restored = _restoreAll(
      store,
      lineId,
      workspace,
      manifest,
    );
    manifest
      ..state = 'rolled_back'
      ..rolledBackAt = _now
      ..restored = restored
      ..error = '';
    writeNormalizationManifest(store, manifest);
    line = _regressPhase(store, line);
    return <String, Object?>{
      'command': 'production.normalize.rollback',
      'line_id': lineId,
      'run_id': manifest.runId,
      'phase': line.effectivePhase,
      'state': manifest.state,
      'restored': restored,
      'idempotent': restored.isEmpty,
      'manifest': normalizationManifestRelativePath(manifest.runId),
      'notes': const <String>[
        '按 before/ 备份恢复并逐个核对 sha256',
        '回滚后产线回到 normalizing，必须重新归一化/建索引才能开任务',
      ],
    };
  }

  // ── status ────────────────────────────────────────────────────────

  Map<String, Object?> _status(
    ProductionStore store,
    Map<String, Object?> arguments,
  ) {
    final String lineId = _argument(arguments, 'line_id');
    final LineRecord line = store.getLine(lineId);
    final NormalizationManifest? manifest = _resolveManifest(
      store,
      lineId,
      arguments,
    );
    final bool ready = isLineReady(store, line);
    if (manifest == null) {
      return <String, Object?>{
        'command': 'production.normalize.status',
        'line_id': lineId,
        'phase': line.effectivePhase,
        'ready': ready,
        'run_id': '',
        'state': 'none',
        'files': const <Map<String, Object?>>[],
        'rejected': const <Map<String, Object?>>[],
        'skipped': const <Map<String, Object?>>[],
      };
    }
    return <String, Object?>{
      'command': 'production.normalize.status',
      'line_id': lineId,
      'phase': line.effectivePhase,
      'ready': ready,
      'run_id': manifest.runId,
      'state': manifest.state,
      'files': <Map<String, Object?>>[
        for (final NormalizationFile file in manifest.files) file.toJson(),
      ],
      'rejected': manifest.rejected,
      'skipped': manifest.skipped,
      'rewrite_allowlist': manifest.rewriteAllowlist,
      'created_at': manifest.createdAt,
      'applied_at': manifest.appliedAt,
      'rolled_back_at': manifest.rolledBackAt,
      'restored': manifest.restored,
      'error': manifest.error,
      'manifest': normalizationManifestRelativePath(manifest.runId),
    };
  }

  // ── 内部工具 ──────────────────────────────────────────────────────

  Future<Map<String, Object?>> _commit(
    NormalizationManifest manifest,
    String workspace,
    Map<String, Object?> scope, {
    required List<String> rewriteAllowlist,
  }) => _probe(
    'docnorm.baseline',
    <String, Object?>{
      'repo': workspace,
      'commit': true,
      'run_id': manifest.runId,
      'sections': _mapsOf(manifest.arguments['sections']),
      'indexes': _mapsOf(manifest.arguments['indexes']),
      'rewrite_allowlist': rewriteAllowlist,
    },
    scope,
  );

  Future<Map<String, Object?>> _probe(
    String command,
    Map<String, Object?> arguments,
    Map<String, Object?> scope,
  ) async {
    final DocnormProbe? probe = docnorm;
    if (probe == null) {
      throw ProductionFailure(
        '插件尚未接线 tree.docnorm：无法执行 $command',
        code: 'docnorm_unavailable',
        missing: const <String>['docnorm'],
      );
    }
    try {
      return await probe(command, arguments, scope);
    } on ProductionFailure {
      rethrow;
    } catch (error) {
      throw ProductionFailure(
        '$command 失败：$error',
        code: 'docnorm_failed',
        missing: const <String>['docnorm'],
      );
    }
  }

  /// 逐个恢复备份并核对 sha256；返回恢复成功的相对路径。
  List<String> _restoreAll(
    ProductionStore store,
    String lineId,
    String workspace,
    NormalizationManifest manifest,
  ) {
    final List<String> restored = <String>[];
    for (final NormalizationFile file in manifest.files) {
      if (file.backup.isEmpty) continue;
      final String? safe = safeWorkspaceRelativePath(workspace, file.path);
      if (safe == null) {
        throw ProductionFailure(
          '回滚路径越出工作空间：${file.path}',
          code: 'normalization_rollback_failed',
          missing: <String>[file.path],
        );
      }
      final String? assetRoot = normalizationAssetRoot(store, lineId);
      if (assetRoot == null) {
        throw ProductionFailure(
          '项目资产根不可用：无法读取备份',
          code: 'normalization_rollback_failed',
          missing: const <String>['asset_root'],
        );
      }
      final File backup = File(
        p.joinAll(<String>[assetRoot, ...file.backup.split('/')]),
      );
      if (!backup.existsSync()) {
        throw ProductionFailure(
          '备份缺失：${file.backup}',
          code: 'normalization_rollback_failed',
          missing: <String>[file.path],
        );
      }
      final List<int> bytes = backup.readAsBytesSync();
      if (sha256Hex(bytes) != file.backupSha256) {
        throw ProductionFailure(
          '备份 sha256 不符：${file.backup}',
          code: 'normalization_rollback_failed',
          missing: <String>[file.path],
        );
      }
      final File target = _workspaceFile(workspace, safe);
      target.parent.createSync(recursive: true);
      target.writeAsBytesSync(bytes, flush: true);
      if (sha256Hex(target.readAsBytesSync()) != file.beforeSha256) {
        throw ProductionFailure(
          '恢复后 sha256 不符：$safe',
          code: 'normalization_rollback_failed',
          missing: <String>[file.path],
        );
      }
      restored.add(file.path);
    }
    return restored;
  }

  /// 写盘成功：normalizing → indexing（只前进，不回退）。
  LineRecord _advancePhase(
    ProductionStore store,
    LineRecord line,
    String phase,
  ) {
    if (line.effectivePhase != 'normalizing') return line;
    return store.setLinePhase(line.id, phase);
  }

  /// 回滚：indexing / ready → normalizing（fail-closed，阻断开任务）。
  LineRecord _regressPhase(ProductionStore store, LineRecord line) {
    if (line.effectivePhase == 'indexing' ||
        line.effectivePhase == 'ready') {
      return store.setLinePhase(line.id, 'normalizing');
    }
    return line;
  }

  NormalizationManifest? _resolveManifest(
    ProductionStore store,
    String lineId,
    Map<String, Object?> arguments,
  ) {
    final String runId = textOf(arguments['run_id']);
    if (runId.isNotEmpty) {
      return readNormalizationManifest(store, lineId, _validateRunId(runId));
    }
    return latestNormalizationManifest(store, lineId);
  }

  String _workspace(ProductionStore store, LineRecord line) {
    final String dir = line.workspaceDir;
    if (dir.isEmpty) {
      throw ProductionFailure(
        '产线未配置 workspace_dir：无法归一化',
        code: 'workspace_required',
        missing: const <String>['workspace_dir'],
      );
    }
    if (!p.isAbsolute(dir)) {
      throw ProductionFailure(
        'workspace_dir 必须是绝对路径：$dir',
        code: 'workspace_required',
        missing: const <String>['workspace_dir'],
      );
    }
    if (!Directory(dir).existsSync()) {
      throw ProductionFailure(
        '产线工作空间不存在：$dir',
        code: 'workspace_unavailable',
        missing: const <String>['workspace_unavailable'],
      );
    }
    return p.normalize(dir);
  }

  String _runId(Map<String, Object?> arguments) {
    final String raw = textOf(arguments['run_id']);
    if (raw.isEmpty) return 'norm-${_clock().millisecondsSinceEpoch}';
    return _validateRunId(raw);
  }

  String _validateRunId(String raw) {
    if (raw == '.' ||
        raw == '..' ||
        !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(raw)) {
      throw ProductionFailure(
        'run_id 只允许 [A-Za-z0-9_.-]（防路径穿越）：$raw',
        code: 'invalid_arguments',
        missing: const <String>['run_id'],
      );
    }
    return raw;
  }

  File _workspaceFile(String workspace, String relative) =>
      File(p.joinAll(<String>[workspace, ...relative.split('/')]));

  /// allowlist 只保留合法的仓内相对路径（整篇改写只能点名既有目标）。
  List<String> _cleanPaths(List<String> raw) {
    final List<String> out = <String>[];
    for (final String item in raw) {
      final String text = item.replaceAll('\\', '/');
      if (text.isEmpty || text.startsWith('/') || text.contains(':')) continue;
      final List<String> parts = text.split('/');
      if (parts.any(
        (String part) => part.isEmpty || part == '.' || part == '..',
      )) {
        continue;
      }
      final String normalized = parts.join('/');
      if (!out.contains(normalized)) out.add(normalized);
    }
    out.sort();
    return out;
  }

  List<Map<String, Object?>> _mapsOf(Object? value) {
    if (value is! List) return const <Map<String, Object?>>[];
    return <Map<String, Object?>>[
      for (final Object? item in value)
        if (item is Map) plainMap(item),
    ];
  }

  List<String> _stringsOf(Object? value) {
    if (value is! List) return const <String>[];
    final List<String> out = <String>[];
    for (final Object? item in value) {
      final String text = textOf(item);
      if (text.isNotEmpty) out.add(text);
    }
    return out;
  }

  String _argument(Map<String, Object?> arguments, String key) {
    final String value = textOf(arguments[key]);
    if (value.isEmpty) {
      throw ProductionFailure('缺少 $key', code: 'invalid_arguments');
    }
    return value;
  }
}
