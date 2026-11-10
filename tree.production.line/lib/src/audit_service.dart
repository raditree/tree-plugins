/// 项目整理（P6）的执行站门面：只读扫描 + 报告落项目资产。
///
/// 口径（docs/pluginization/production-line-recon.md §10.2 / §11 P6）：
/// - 命令 `production.audit.run`：扫描产线工作空间，产出固定 schema 的报告；
/// - **只读**：不改工作空间里的任何文件；唯一写入是
///   `<workspace>/<docs.asset_dir>/<line>/audit.md`（项目资产目录之内）；
/// - `write=false` 时连 `audit.md` 都不写（纯查询，供 UI 预览）；
/// - 缺 data_dir / team_id / workspace_dir 一律 fail-closed。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'audit.dart';
import 'models.dart';
import 'service.dart';
import 'store.dart';

/// P6 对外开放的命令族（同一个执行站 `production`）。
const List<String> kAuditCommands = <String>['production.audit.run'];

class ProductionAuditService {
  ProductionAuditService({
    Map<String, String>? environment,
    DateTime Function()? clock,
  }) : _environment = environment ?? Platform.environment,
       _clock = clock ?? DateTime.now;

  final Map<String, String> _environment;
  final DateTime Function() _clock;

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
      teamId: target.teamId,
      clock: _clock,
    );
    switch (command) {
      case 'production.audit.run':
        return _run(store, arguments);
      default:
        throw ProductionFailure(
          '未知项目整理命令：$command',
          code: 'unknown_command',
        );
    }
  }

  Map<String, Object?> _run(
    ProductionStore store,
    Map<String, Object?> arguments,
  ) {
    final String lineId = _argument(arguments, 'line_id');
    final LineRecord line = store.getLine(lineId);
    final String taskId = textOf(arguments['task_id']);
    if (taskId.isNotEmpty) {
      // 显式给了 task_id 就必须存在（拼错不静默）。
      store.getTask(lineId, taskId);
    }
    final String workspace = store.workspaceDirOf(lineId);
    final Directory root = Directory(workspace);
    if (!root.existsSync()) {
      throw ProductionFailure(
        '产线工作空间不存在：$workspace',
        code: 'workspace_unavailable',
      );
    }

    final List<String> notes = <String>[];
    final List<AuditTodo> todos = <AuditTodo>[];
    final Map<String, List<String>> pathsByDigest = <String, List<String>>{};
    final Map<String, int> sizeByDigest = <String, int>{};
    final Map<String, int> sizeByPath = <String, int>{};
    int scanned = 0;
    int skipped = 0;
    int totalBytes = 0;

    void walk(Directory dir) {
      if (scanned >= kAuditMaxFiles) return;
      final List<FileSystemEntity> entries = dir.listSync()
        ..sort(
          (FileSystemEntity a, FileSystemEntity b) => a.path.compareTo(b.path),
        );
      for (final FileSystemEntity entity in entries) {
        if (scanned >= kAuditMaxFiles) return;
        if (entity is Directory) {
          if (kAuditSkipDirs.contains(p.basename(entity.path))) continue;
          walk(entity);
          continue;
        }
        if (entity is! File) continue;
        final String extension = p
            .extension(entity.path)
            .replaceFirst('.', '')
            .toLowerCase();
        if (!kAuditExtensions.contains(extension)) {
          skipped += 1;
          continue;
        }
        final int size = entity.lengthSync();
        if (size > kAuditMaxFileBytes) {
          skipped += 1;
          continue;
        }
        final List<int> bytes;
        try {
          bytes = entity.readAsBytesSync();
        } catch (_) {
          skipped += 1;
          continue;
        }
        final String relative = p
            .relative(entity.path, from: workspace)
            .replaceAll('\\', '/');
        scanned += 1;
        totalBytes += size;
        sizeByPath[relative] = size;
        todos.addAll(
          auditTodosOf(
            relative,
            utf8.decode(bytes, allowMalformed: true),
          ),
        );
        if (size >= kAuditDuplicateMinBytes) {
          final String digest = auditDigest(bytes);
          pathsByDigest.putIfAbsent(digest, () => <String>[]).add(relative);
          sizeByDigest[digest] = size;
        }
      }
    }

    walk(root);
    if (scanned >= kAuditMaxFiles) {
      notes.add('扫描达到上限 $kAuditMaxFiles 个文件，结果可能不完整。');
    }
    final List<AuditTodo> ledger = todos.length > kAuditMaxTodos
        ? todos.sublist(0, kAuditMaxTodos)
        : todos;
    if (todos.length > kAuditMaxTodos) {
      notes.add('TODO 台账超过 $kAuditMaxTodos 条，已截断。');
    }

    final List<String> manifest = stringsOf(
      plainMap(line.data['docs'])['memory_manifest'],
    );
    final List<String> docsChecked = <String>[];
    final List<String> docsMissing = <String>[];
    for (final String relative in manifest) {
      final String path = p.joinAll(<String>[
        workspace,
        ...relative.split('/'),
      ]);
      if (File(path).existsSync()) {
        docsChecked.add(relative);
      } else {
        docsMissing.add(relative);
      }
    }
    if (manifest.isEmpty) {
      notes.add('产线未配置 docs.memory_manifest：文档审计为空。');
    }

    final AuditReport report = AuditReport(
      lineId: lineId,
      taskId: taskId,
      generatedAt: _clock().toIso8601String(),
      workspace: workspace,
      scanned: scanned,
      skipped: skipped,
      totalBytes: totalBytes,
      docsChecked: docsChecked,
      docsMissing: docsMissing,
      todos: ledger,
      duplicates: auditDuplicatesOf(pathsByDigest, sizeByDigest),
      largeFiles: auditLargeFilesOf(sizeByPath),
      notes: notes,
    );

    // 只写项目资产目录里的 audit.md；write=false 时纯查询。
    final bool write = arguments['write'] != false;
    String artifact = '';
    if (write) {
      store.writeAsset(lineId, 'audit.md', renderAuditMd(report));
      final Map<String, Object?> docs = plainMap(line.data['docs']);
      final String assetDir = textOf(docs['asset_dir']).isEmpty
          ? 'docs/production_lines'
          : textOf(docs['asset_dir']);
      artifact = '$assetDir/$lineId/audit.md';
    }
    return <String, Object?>{
      'report': report.toJson(),
      'artifact': artifact,
      'written': write,
    };
  }

  String _argument(Map<String, Object?> arguments, String key) {
    final String value = textOf(arguments[key]);
    if (value.isEmpty) {
      throw ProductionFailure('缺少 $key', code: 'invalid_arguments');
    }
    return value;
  }
}
