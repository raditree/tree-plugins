/// 项目整理（P6）的执行站门面：只读扫描 + 报告落盘 + 报告落项目资产。
///
/// 口径（docs/pluginization/production-line-recon.md §10.2 / §11 P6）：
/// - 命令 `production.audit.run`：扫描产线工作空间，产出固定 schema 的报告；
/// - **只读**：不改工作空间里的任何文件；唯一写入是
///   `<workspace>/<docs.asset_dir>/<line>/audit.md`（项目资产目录之内）；
/// - `write=false` 时连 `audit.md` 都不写（纯查询，供 UI 预览）；
/// - 缺 data_dir / workspace_dir 一律 fail-closed（team 只是调用方身份，见 §16）。
///
/// **报告缓存**：完成的报告 + 每文件扫描结果落插件数据 `<line>/audit_cache.json`。
/// 普通查询（`refresh=false`）只做目录遍历 + stat 比对：
/// - 无变化 ⇒ 直接回缓存，0 次文件读取；
/// - 有变化 ⇒ 回缓存并标 `stale:true` / `changed:N`，由 UI 决定是否重扫。
/// `refresh=true` 时按缓存做增量：只读新增/变更文件，未变文件复用结果；
/// 首次或缓存失效才全量扫描。
///
/// **分批续扫**：一次请求只处理 `limit` 个待扫文件（默认 [kAuditDefaultBatch]），
/// 进度与累计结果落在 `<line>/audit_scan.json`；下一批从断点继续。
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

/// 完成的报告缓存文件名（插件数据）。
const String kAuditCacheFile = 'audit_cache.json';

/// 断点状态版本（结构变更时递增，旧状态自动丢弃重扫）。
const int kAuditScanStateVersion = 2;

/// 报告缓存版本。
const int kAuditCacheVersion = 1;

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
    final bool refresh = arguments['refresh'] == true;
    final bool write = arguments['write'] != false;
    final List<String> manifest = stringsOf(
      plainMap(line.data['docs'])['memory_manifest'],
    );
    final String lineDir = store.lineDir(lineId);
    final String statePath = p.join(lineDir, kAuditScanStateFile);
    final String cachePath = p.join(lineDir, kAuditCacheFile);
    final String lockPath = '$statePath.lock';
    final Map<String, Object?> docsConfig = plainMap(line.data['docs']);
    final String assetDir = textOf(docsConfig['asset_dir']).isEmpty
        ? 'docs/production_lines'
        : textOf(docsConfig['asset_dir']);
    // 自己的报告产物不算扫描对象，否则写完 audit.md 下一次就判「有变化」。
    final Set<String> excluded = <String>{'$assetDir/$lineId/audit.md'};
    if (!_acquireLock(lockPath)) {
      throw ProductionFailure(
        '整理扫描正在进行中（上一个请求还没结束），稍后再试。',
        code: 'audit_in_progress',
      );
    }

    try {
      _AuditScanState? state = _loadState(statePath, workspace);
      final _AuditCache? cache = _loadCache(cachePath, workspace);

      // 没有进行中的扫描、也没要求刷新：缓存命中就直接回，0 次文件读取。
      if (state == null && !refresh && cache != null) {
        final ({List<String> files, bool capped}) collected =
            await _collectFiles(root, workspace, exclude: excluded);
        final int changed = await _changedCount(
          cache,
          workspace,
          collected.files,
        );
        final bool stale =
            changed > 0 || !_sameStrings(cache.manifest, manifest);
        return _cachedReply(
          cache,
          batch: batch,
          stale: stale,
          changed: stale ? (changed == 0 ? 1 : changed) : 0,
        );
      }

      if (state == null) {
        final ({List<String> files, bool capped}) collected =
            await _collectFiles(root, workspace, exclude: excluded);
        if (refresh && cache != null) {
          final Set<String> changed = await _changedPaths(
            cache,
            workspace,
            collected.files,
          );
          state = _AuditScanState(
            workspace: workspace,
            files: changed.toList()..sort(),
            entries: <String, _AuditFileEntry>{
              for (final String path in collected.files)
                if (!changed.contains(path) && cache.entries[path] != null)
                  path: cache.entries[path]!,
            },
            manifest: manifest,
          )..capped = collected.capped;
        } else {
          state = _AuditScanState(
            workspace: workspace,
            files: collected.files,
            entries: <String, _AuditFileEntry>{},
            manifest: manifest,
          )..capped = collected.capped;
        }
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

      final List<String> notes = <String>[];
      if (state.capped) {
        notes.add('候选文件达到上限 $kAuditMaxFiles，结果可能不完整。');
      }
      if (refresh && total > 0) {
        notes.add('本次增量扫描 $total 个新增/变更文件，其余复用缓存。');
      }
      final int percent = total == 0
          ? 100
          : (state.index * 100 / total).round();
      if (!done) {
        notes.add(
          '本批已处理 ${state.index}/$total 个待扫文件（$percent%）；'
          '点「继续扫描」跑下一批（每批上限 $batch）。',
        );
      }

      final AuditReport report = _buildReport(
        state,
        lineId: lineId,
        taskId: taskId,
        workspace: workspace,
        notes: notes,
      );

      String artifact = '';
      bool written = false;
      if (write && done) {
        store.writeAsset(lineId, 'audit.md', renderAuditMd(report));
        artifact = '$assetDir/$lineId/audit.md';
        written = true;
      } else if (write && !done) {
        notes.add('本批未完成，未写 audit.md；全部批次结束后自动落盘。');
      }

      if (done) {
        _saveCache(
          cachePath,
          _AuditCache(
            workspace: workspace,
            generatedAt: report.generatedAt,
            report: report.toJson(),
            entries: state.entries,
            manifest: state.manifest,
            capped: state.capped,
          ),
        );
      }

      return <String, Object?>{
        'report': report.toJson(),
        'artifact': artifact,
        'written': written,
        'cached': false,
        'stale': false,
        'changed': 0,
        'progress': <String, Object?>{
          'done': done,
          'index': state.index,
          'total': total,
          'percent': percent,
          'batch': batch,
          'scanned': report.scanned,
        },
      };
    } finally {
      _releaseLock(lockPath);
    }
  }

  Map<String, Object?> _cachedReply(
    _AuditCache cache, {
    required int batch,
    required bool stale,
    required int changed,
  }) {
    final Map<String, dynamic> report = cache.report;
    final int scanned = intOf(plainMap(report['files'])['scanned'], 0);
    return <String, Object?>{
      'report': report,
      'artifact': '',
      'written': false,
      'cached': true,
      'stale': stale,
      'changed': changed,
      'cache_generated_at': cache.generatedAt,
      'progress': <String, Object?>{
        'done': true,
        'index': 0,
        'total': 0,
        'percent': 100,
        'batch': batch,
        'scanned': scanned,
      },
    };
  }

  AuditReport _buildReport(
    _AuditScanState state, {
    required String lineId,
    required String taskId,
    required String workspace,
    required List<String> notes,
  }) {
    int scanned = 0;
    int skipped = 0;
    int bytes = 0;
    final List<AuditTodo> todos = <AuditTodo>[];
    final Map<String, _AuditDigest> digests = <String, _AuditDigest>{};
    final Map<String, int> large = <String, int>{};
    final List<String> paths = state.entries.keys.toList()..sort();
    for (final String path in paths) {
      final _AuditFileEntry entry = state.entries[path]!;
      if (entry.skipped) {
        skipped += 1;
        continue;
      }
      scanned += 1;
      bytes += entry.size;
      for (final Map<String, Object?> item in entry.todos) {
        todos.add(
          AuditTodo(
            path: textOf(item['path']),
            line: intOf(item['line'], 0),
            marker: textOf(item['marker']),
            text: textOf(item['text']),
          ),
        );
      }
      if (entry.digest.isNotEmpty) {
        digests
            .putIfAbsent(
              entry.digest,
              () => _AuditDigest(size: entry.size, paths: <String>[]),
            )
            .paths
            .add(path);
      }
      if (entry.large > 0) large[path] = entry.large;
    }

    final List<AuditTodo> ledger = todos.length > kAuditMaxTodos
        ? todos.sublist(0, kAuditMaxTodos)
        : todos;
    if (todos.length > kAuditMaxTodos) {
      notes.add('TODO 台账超过 $kAuditMaxTodos 条，已截断。');
    }

    final List<String> docsChecked = <String>[];
    final List<String> docsMissing = <String>[];
    for (final String relative in state.manifest) {
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
    if (state.manifest.isEmpty) {
      notes.add('产线未配置 docs.memory_manifest：文档审计为空。');
    }

    return AuditReport(
      lineId: lineId,
      taskId: taskId,
      generatedAt: _clock().toIso8601String(),
      workspace: workspace,
      scanned: scanned,
      skipped: skipped,
      totalBytes: bytes,
      docsChecked: docsChecked,
      docsMissing: docsMissing,
      todos: ledger,
      duplicates: auditDuplicatesOf(
        <String, List<String>>{
          for (final MapEntry<String, _AuditDigest> entry in digests.entries)
            entry.key: entry.value.paths,
        },
        <String, int>{
          for (final MapEntry<String, _AuditDigest> entry in digests.entries)
            entry.key: entry.value.size,
        },
      ),
      largeFiles: auditLargeFilesOf(large),
      notes: notes,
    );
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
    String workspace, {
    Set<String> exclude = const <String>{},
  }) async {
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
        final String relative = p
            .relative(entity.path, from: workspace)
            .replaceAll('\\', '/');
        if (exclude.contains(relative)) continue;
        files.add(relative);
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

  /// 缓存比对：只 stat，不读内容；返回新增/变更/删除的文件数。
  Future<int> _changedCount(
    _AuditCache cache,
    String workspace,
    List<String> files,
  ) async {
    final Set<String> current = files.toSet();
    int changed = 0;
    for (final String relative in files) {
      final _AuditFileEntry? entry = cache.entries[relative];
      if (entry == null) {
        changed += 1;
        continue;
      }
      final FileStat stat = await File(
        p.joinAll(<String>[workspace, ...relative.split('/')]),
      ).stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size != entry.size ||
          stat.modified.millisecondsSinceEpoch != entry.mtime) {
        changed += 1;
      }
    }
    for (final String relative in cache.entries.keys) {
      if (!current.contains(relative)) changed += 1;
    }
    return changed;
  }

  /// 刷新用的变更集合（新增 + 变更；删除由缓存过滤处理）。
  Future<Set<String>> _changedPaths(
    _AuditCache cache,
    String workspace,
    List<String> files,
  ) async {
    final Set<String> changed = <String>{};
    for (final String relative in files) {
      final _AuditFileEntry? entry = cache.entries[relative];
      if (entry == null) {
        changed.add(relative);
        continue;
      }
      final FileStat stat = await File(
        p.joinAll(<String>[workspace, ...relative.split('/')]),
      ).stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size != entry.size ||
          stat.modified.millisecondsSinceEpoch != entry.mtime) {
        changed.add(relative);
      }
    }
    return changed;
  }

  /// 扫一个文件：统计 / TODO / 重复摘要 / 超大文件写进条目。
  ///
  /// 读取用异步 API：扫描期间事件循环保持可用，`ping` 与心跳能照常回包。
  Future<void> _scanOne(_AuditScanState state, String workspace) async {
    final String relative = state.files[state.index];
    final File file = File(
      p.joinAll(<String>[workspace, ...relative.split('/')]),
    );
    try {
      final FileStat stat = await file.stat();
      final int mtime = stat.modified.millisecondsSinceEpoch;
      if (stat.type != FileSystemEntityType.file) {
        state.entries[relative] = _AuditFileEntry(
          size: 0,
          mtime: mtime,
          skipped: true,
        );
        return;
      }
      final int size = stat.size;
      if (size > kAuditMaxFileBytes) {
        state.entries[relative] = _AuditFileEntry(
          size: size,
          mtime: mtime,
          skipped: true,
        );
        return;
      }
      final List<int> bytes = await file.readAsBytes();
      final String content = utf8.decode(bytes, allowMalformed: true);
      state.entries[relative] = _AuditFileEntry(
        size: size,
        mtime: mtime,
        skipped: false,
        digest: size >= kAuditDuplicateMinBytes ? auditDigest(bytes) : '',
        todos: <Map<String, Object?>>[
          for (final AuditTodo todo in auditTodosOf(relative, content))
            todo.toJson(),
        ],
        large: size >= kAuditLargeFileBytes ? size : 0,
      );
    } catch (_) {
      state.entries[relative] = _AuditFileEntry(
        size: 0,
        mtime: 0,
        skipped: true,
      );
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
    _writeJson(path, state.toJson());
  }

  _AuditCache? _loadCache(String path, String workspace) {
    final File file = File(path);
    if (!file.existsSync()) return null;
    try {
      final Object? raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map) return null;
      final Map<String, Object?> map = <String, Object?>{
        for (final MapEntry<Object?, Object?> entry in raw.entries)
          '${entry.key}': entry.value,
      };
      if (intOf(map['version'], 0) != kAuditCacheVersion) return null;
      if (textOf(map['workspace']) != workspace) return null;
      final Object? report = map['report'];
      if (report is! Map) return null;
      return _AuditCache(
        workspace: workspace,
        generatedAt: textOf(map['generated_at']),
        report: <String, dynamic>{
          for (final MapEntry<Object?, Object?> entry in report.entries)
            '${entry.key}': entry.value,
        },
        entries: <String, _AuditFileEntry>{
          for (final MapEntry<String, Object?> entry
              in plainMap(map['files']).entries)
            entry.key: _AuditFileEntry.fromJson(plainMap(entry.value)),
        },
        manifest: stringsOf(map['manifest']),
        capped: map['capped'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  void _saveCache(String path, _AuditCache cache) {
    _writeJson(path, <String, Object?>{
      'version': kAuditCacheVersion,
      'workspace': cache.workspace,
      'generated_at': cache.generatedAt,
      'report': cache.report,
      'files': <String, Object?>{
        for (final MapEntry<String, _AuditFileEntry> entry
            in cache.entries.entries)
          entry.key: entry.value.toJson(),
      },
      'manifest': cache.manifest,
      'capped': cache.capped,
    });
  }

  void _writeJson(String path, Map<String, Object?> value) {
    final File file = File(path);
    final File tmp = File('$path.tmp');
    tmp.writeAsStringSync(jsonEncode(value), flush: true);
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

  static bool _sameStrings(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// 一次整理会话的断点状态（唯一写入点：插件数据）。
class _AuditScanState {
  _AuditScanState({
    required this.workspace,
    required this.files,
    required this.entries,
    required this.manifest,
  });

  final String workspace;

  /// 本批待扫文件（全量时=全部候选；增量时=新增/变更）。
  final List<String> files;
  int index = 0;
  bool capped = false;
  final Map<String, _AuditFileEntry> entries;
  final List<String> manifest;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': kAuditScanStateVersion,
    'workspace': workspace,
    'files': files,
    'index': index,
    'capped': capped,
    'entries': <String, Object?>{
      for (final MapEntry<String, _AuditFileEntry> entry in entries.entries)
        entry.key: entry.value.toJson(),
    },
    'manifest': manifest,
  };

  static _AuditScanState fromJson(Map<String, Object?> map) {
    final _AuditScanState state = _AuditScanState(
      workspace: textOf(map['workspace']),
      files: <String>[
        for (final Object? item in (map['files'] as List<Object?>? ?? const []))
          if (item is String) item,
      ],
      entries: <String, _AuditFileEntry>{
        for (final MapEntry<String, Object?> entry
            in plainMap(map['entries']).entries)
          entry.key: _AuditFileEntry.fromJson(plainMap(entry.value)),
      },
      manifest: stringsOf(map['manifest']),
    )
      ..index = intOf(map['index'], 0)
      ..capped = map['capped'] == true;
    return state;
  }
}

/// 单个文件的扫描结果（缓存与断点共用）。
class _AuditFileEntry {
  const _AuditFileEntry({
    required this.size,
    required this.mtime,
    required this.skipped,
    this.digest = '',
    this.todos = const <Map<String, Object?>>[],
    this.large = 0,
  });

  final int size;
  final int mtime;
  final bool skipped;
  final String digest;
  final List<Map<String, Object?>> todos;
  final int large;

  Map<String, Object?> toJson() => <String, Object?>{
    'size': size,
    'mtime': mtime,
    'skipped': skipped,
    if (digest.isNotEmpty) 'digest': digest,
    if (todos.isNotEmpty) 'todos': todos,
    if (large > 0) 'large': large,
  };

  static _AuditFileEntry fromJson(Map<String, Object?> map) =>
      _AuditFileEntry(
        size: intOf(map['size'], 0),
        mtime: intOf(map['mtime'], 0),
        skipped: map['skipped'] == true,
        digest: textOf(map['digest']),
        todos: <Map<String, Object?>>[
          for (final Object? item
              in (map['todos'] as List<Object?>? ?? const []))
            if (item is Map)
              <String, Object?>{
                for (final MapEntry<Object?, Object?> entry in item.entries)
                  '${entry.key}': entry.value,
              },
        ],
        large: intOf(map['large'], 0),
      );
}

class _AuditCache {
  const _AuditCache({
    required this.workspace,
    required this.generatedAt,
    required this.report,
    required this.entries,
    required this.manifest,
    required this.capped,
  });

  final String workspace;
  final String generatedAt;
  final Map<String, dynamic> report;
  final Map<String, _AuditFileEntry> entries;
  final List<String> manifest;
  final bool capped;
}

class _AuditDigest {
  _AuditDigest({required this.size, required this.paths});

  final int size;
  final List<String> paths;

  Map<String, Object?> toJson() => <String, Object?>{'size': size, 'paths': paths};
}
