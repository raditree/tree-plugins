/// 项目整理（P6）的执行站门面：只读扫描 + 报告落项目资产。
///
/// 口径（docs/pluginization/production-line-recon.md §10.2 / §11 P6）：
/// - 命令 `production.audit.run`：扫描产线工作空间，产出固定 schema 的报告；
/// - **只读**：不改工作空间里的任何文件；唯一写入是
///   `<workspace>/<docs.asset_dir>/<line>/audit.md`（项目资产目录之内）；
/// - `write=false` 时连 `audit.md` 都不写（纯查询，供 UI 预览）；
/// - 缺 data_dir / workspace_dir 一律 fail-closed（team 只是调用方身份，见 §16）。
///
/// **分批续扫**：一次请求只处理 `limit` 个文件（默认 [kAuditDefaultBatch]），
/// 进度与累计结果落在插件数据 `<line>/audit_scan.json`；下一批从断点继续。
/// 扫描是异步 IO，事件循环不被占住，插件心跳与 `ping` 照常回——核心侧按
/// 心跳判活而不是墙钟给委派设置死线。
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

/// 断点状态文件名（插件数据，不是项目资产）。
const String kAuditScanStateFile = 'audit_scan.json';

/// 断点状态版本（结构变更时递增，旧状态自动丢弃重扫）。
const int kAuditScanStateVersion = 1;

class ProductionAuditService {
  ProductionAuditService({
    Map<String, String>? environment,
    DateTime Function()? clock,
    this.filesPerRun,
  }) : _environment = environment ?? Platform.environment,
       _clock = clock ?? DateTime.now;

  final Map<String, String> _environment;
  final DateTime Function() _clock;

  /// 测试缝：固定单次处理的文件数（正式调用由 REST 的 `limit` 控制）。
  final int? filesPerRun;

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
      case 'production.audit.run':
        return _run(store, arguments);
      default:
        throw ProductionFailure(
          '未知项目整理命令：$command',
          code: 'unknown_command',
        );
    }
  }

  Future<Map<String, Object?>> _run(
    ProductionStore store,
    Map<String, Object?> arguments,
  ) async {
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

    final int batch = _batchOf(arguments);
    final String lineDir = store.lineDir(lineId);
    final String statePath = p.join(lineDir, kAuditScanStateFile);
    final String lockPath = '$statePath.lock';
    if (!_acquireLock(lockPath)) {
      throw ProductionFailure(
        '整理扫描正在进行中（上一个请求还没结束），稍后再试。',
        code: 'audit_in_progress',
      );
    }

    try {
      final List<String> notes = <String>[];
      _AuditScanState? state = _loadState(statePath, workspace);
      if (state == null) {
        final ({List<String> files, bool capped}) collected =
            await _collectFiles(root, workspace);
        state = _AuditScanState(workspace: workspace, files: collected.files)
          ..capped = collected.capped;
      }
      final int total = state.files.length;
      int processed = 0;
      while (state.index < total && processed < batch) {
        await _scanOne(state, workspace);
        state.index += 1;
        processed += 1;
      }
      final bool done = state.index >= total;
      if (done) {
        _deleteState(statePath);
      } else {
        _saveState(statePath, state);
      }
      if (state.capped) {
        notes.add('候选文件达到上限 $kAuditMaxFiles，结果可能不完整。');
      }

      final List<AuditTodo> todos = <AuditTodo>[
        for (final Map<String, Object?> item in state.todos)
          AuditTodo(
            path: textOf(item['path']),
            line: intOf(item['line'], 0),
            marker: textOf(item['marker']),
            text: textOf(item['text']),
          ),
      ];
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

      final int percent = total == 0
          ? 100
          : (state.index * 100 / total).round();
      if (!done) {
        notes.add(
          '本批已处理 ${state.index}/$total 个文件（$percent%）；'
          '点「继续扫描」跑下一批（每批上限 $batch）。',
        );
      }

      final AuditReport report = AuditReport(
        lineId: lineId,
        taskId: taskId,
        generatedAt: _clock().toIso8601String(),
        workspace: workspace,
        scanned: state.scanned,
        skipped: state.skipped,
        totalBytes: state.bytes,
        docsChecked: docsChecked,
        docsMissing: docsMissing,
        todos: ledger,
        duplicates: auditDuplicatesOf(
          <String, List<String>>{
            for (final MapEntry<String, _AuditDigest> entry
                in state.digests.entries)
              entry.key: entry.value.paths,
          },
          <String, int>{
            for (final MapEntry<String, _AuditDigest> entry
                in state.digests.entries)
              entry.key: entry.value.size,
          },
        ),
        largeFiles: auditLargeFilesOf(state.large),
        notes: notes,
      );

      // 只写项目资产目录里的 audit.md；write=false 时纯查询。
      final bool write = arguments['write'] != false;
      String artifact = '';
      bool written = false;
      if (write && done) {
        store.writeAsset(lineId, 'audit.md', renderAuditMd(report));
        final Map<String, Object?> docs = plainMap(line.data['docs']);
        final String assetDir = textOf(docs['asset_dir']).isEmpty
            ? 'docs/production_lines'
            : textOf(docs['asset_dir']);
        artifact = '$assetDir/$lineId/audit.md';
        written = true;
      } else if (write && !done) {
        notes.add('本批未完成，未写 audit.md；全部批次结束后自动落盘。');
      }
      return <String, Object?>{
        'report': report.toJson(),
        'artifact': artifact,
        'written': written,
        'progress': <String, Object?>{
          'done': done,
          'index': state.index,
          'total': total,
          'percent': percent,
          'batch': batch,
          'scanned': state.scanned,
        },
      };
    } finally {
      _releaseLock(lockPath);
    }
  }

  int _batchOf(Map<String, Object?> arguments) {
    final int raw = filesPerRun ?? intOf(arguments['limit'], kAuditDefaultBatch);
    if (raw < 1) return 1;
    if (raw > kAuditMaxBatch) return kAuditMaxBatch;
    return raw;
  }

  /// 只列候选（不读内容）：跳依赖 / 构建目录，按扩展名过滤，最后排序保证稳定。
  Future<({List<String> files, bool capped})> _collectFiles(
    Directory root,
    String workspace,
  ) async {
    final List<String> files = <String>[];
    bool capped = false;
    final List<Directory> stack = <Directory>[root];
    while (stack.isNotEmpty) {
      final Directory dir = stack.removeLast();
      final List<FileSystemEntity> entries;
      try {
        entries = await dir.list().toList();
      } catch (_) {
        continue;
      }
      entries.sort(
        (FileSystemEntity a, FileSystemEntity b) => a.path.compareTo(b.path),
      );
      for (final FileSystemEntity entity in entries) {
        if (entity is Directory) {
          if (!kAuditSkipDirs.contains(p.basename(entity.path))) {
            stack.add(entity);
          }
          continue;
        }
        if (entity is! File) continue;
        final String extension = p
            .extension(entity.path)
            .replaceFirst('.', '')
            .toLowerCase();
        if (!kAuditExtensions.contains(extension)) continue;
        files.add(
          p.relative(entity.path, from: workspace).replaceAll('\\', '/'),
        );
        if (files.length >= kAuditMaxFiles) {
          capped = true;
          break;
        }
      }
      if (capped) break;
    }
    files.sort();
    return (files: files, capped: capped);
  }

  /// 扫一个文件：统计 / TODO / 重复摘要 / 超大文件都累加进断点状态。
  ///
  /// 读取用异步 API：扫描期间事件循环保持可用，`ping` 与心跳能照常回包。
  Future<void> _scanOne(_AuditScanState state, String workspace) async {
    final String relative = state.files[state.index];
    final File file = File(
      p.joinAll(<String>[workspace, ...relative.split('/')]),
    );
    try {
      final FileStat stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) {
        state.skipped += 1;
        return;
      }
      final int size = stat.size;
      if (size > kAuditMaxFileBytes) {
        state.skipped += 1;
        return;
      }
      final List<int> bytes = await file.readAsBytes();
      state.scanned += 1;
      state.bytes += size;
      for (final AuditTodo todo in auditTodosOf(
        relative,
        utf8.decode(bytes, allowMalformed: true),
      )) {
        state.todos.add(todo.toJson());
      }
      if (size >= kAuditDuplicateMinBytes) {
        final String digest = auditDigest(bytes);
        state.digests
            .putIfAbsent(
              digest,
              () => _AuditDigest(size: size, paths: <String>[]),
            )
            .paths
            .add(relative);
      }
      if (size >= kAuditLargeFileBytes) {
        state.large[relative] = size;
      }
    } catch (_) {
      state.skipped += 1;
    }
  }

  _AuditScanState? _loadState(String path, String workspace) {
    final File file = File(path);
    if (!file.existsSync()) return null;
    try {
      final Object? raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map) return null;
      final Map<String, Object?> map = <String, Object?>{
        for (final MapEntry<Object?, Object?> entry in raw.entries)
          '${entry.key}': entry.value,
      };
      if (intOf(map['version'], 0) != kAuditScanStateVersion) return null;
      if (textOf(map['workspace']) != workspace) return null;
      return _AuditScanState.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  void _saveState(String path, _AuditScanState state) {
    final File file = File(path);
    final File tmp = File('$path.tmp');
    tmp.writeAsStringSync(jsonEncode(state.toJson()), flush: true);
    if (file.existsSync()) file.deleteSync();
    tmp.renameSync(path);
  }

  void _deleteState(String path) {
    final File file = File(path);
    if (file.existsSync()) file.deleteSync();
  }

  /// 断点锁：`File.create(exclusive)` 是原子的，避免两个请求同时推进同一批。
  bool _acquireLock(String path) {
    final File lock = File(path);
    try {
      lock.createSync(exclusive: true);
      return true;
    } on FileSystemException {
      // 进程崩溃留下的锁：超过 10 分钟视为陈旧，清掉重试一次。
      try {
        if (lock.existsSync() &&
            _clock().difference(lock.lastModifiedSync()) >
                const Duration(minutes: 10)) {
          lock.deleteSync();
          lock.createSync(exclusive: true);
          return true;
        }
      } catch (_) {
        // 仍然拿不到 ⇒ 视为进行中。
      }
      return false;
    }
  }

  void _releaseLock(String path) {
    final File lock = File(path);
    try {
      if (lock.existsSync()) lock.deleteSync();
    } catch (_) {
      // 释放失败不影响本次结果；陈旧锁由下次的 10 分钟判定清理。
    }
  }

  String _argument(Map<String, Object?> arguments, String key) {
    final String value = textOf(arguments[key]);
    if (value.isEmpty) {
      throw ProductionFailure('缺少 $key', code: 'invalid_arguments');
    }
    return value;
  }
}

/// 一次整理会话的断点状态（唯一写入点：插件数据）。
class _AuditScanState {
  _AuditScanState({required this.workspace, required this.files});

  final String workspace;
  final List<String> files;
  int index = 0;
  int scanned = 0;
  int skipped = 0;
  int bytes = 0;
  bool capped = false;
  final List<Map<String, Object?>> todos = <Map<String, Object?>>[];
  final Map<String, _AuditDigest> digests = <String, _AuditDigest>{};
  final Map<String, int> large = <String, int>{};

  Map<String, Object?> toJson() => <String, Object?>{
    'version': kAuditScanStateVersion,
    'workspace': workspace,
    'files': files,
    'index': index,
    'scanned': scanned,
    'skipped': skipped,
    'bytes': bytes,
    'capped': capped,
    'todos': todos,
    'digests': <String, Object?>{
      for (final MapEntry<String, _AuditDigest> entry in digests.entries)
        entry.key: entry.value.toJson(),
    },
    'large': large,
  };

  static _AuditScanState fromJson(Map<String, Object?> map) {
    final _AuditScanState state = _AuditScanState(
      workspace: textOf(map['workspace']),
      files: <String>[
        for (final Object? item in (map['files'] as List<Object?>? ?? const []))
          if (item is String) item,
      ],
    )
      ..index = intOf(map['index'], 0)
      ..scanned = intOf(map['scanned'], 0)
      ..skipped = intOf(map['skipped'], 0)
      ..bytes = intOf(map['bytes'], 0)
      ..capped = map['capped'] == true;
    for (final Object? item in (map['todos'] as List<Object?>? ?? const [])) {
      if (item is Map) {
        state.todos.add(<String, Object?>{
          for (final MapEntry<Object?, Object?> entry in item.entries)
            '${entry.key}': entry.value,
        });
      }
    }
    final Map<String, Object?> digests = plainMap(map['digests']);
    for (final MapEntry<String, Object?> entry in digests.entries) {
      final Map<String, Object?> value = plainMap(entry.value);
      state.digests[entry.key] = _AuditDigest(
        size: intOf(value['size'], 0),
        paths: <String>[
          for (final Object? path in (value['paths'] as List<Object?>? ?? const []))
            if (path is String) path,
        ],
      );
    }
    for (final MapEntry<String, Object?> entry in plainMap(map['large']).entries) {
      state.large[entry.key] = intOf(entry.value, 0);
    }
    return state;
  }
}

class _AuditDigest {
  _AuditDigest({required this.size, required this.paths});

  final int size;
  final List<String> paths;

  Map<String, Object?> toJson() => <String, Object?>{'size': size, 'paths': paths};
}
