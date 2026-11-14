/// 项目结构整理（LG-01 / TG-06）的扫描、报告落盘与命令门面。
///
/// - `production.structure.get`：只读；返回报告 + 当前就绪判定（含 stale）；
/// - `production.structure.reevaluate`：确定性扫描工作空间，生成并落盘
///   `<line>/structure.json`，按结果推进/回退 `line.phase`；
/// - `production.structure.waive`：逐项豁免 high finding（owner/原因/到期），
///   没有全局跳过 / force 参数；
/// - `requireStructureReady` / `requireStructureAllowsTasks`：organizing 阶段的
///   命令门禁（非 cleanup 一律 `structure_not_ready`）。
///
/// 扫描边界（best-effort，报告 `notes` 会写明）：
/// - 包 = 含 `pubspec.yaml` 的目录（跳过依赖 / 构建 / 缓存目录、`.input`、
///   以及产线自己的项目资产目录）；
/// - 包职责取 `pubspec.yaml.description`，缺失即 high `missing_responsibility`；
/// - 公共 API 只解析入口文件 + 相对 `export`（最多 50 个文件），解析不到时
///   回退到 `lib/**/*.dart` 顶层公开声明（最多 500 个文件）；`package:` 形式的
///   `export` 不展开；
/// - 依赖边来自 `lib/**/*.dart` 的 `package:<name>/...` 导入 / 导出，不猜
///   `dependency_overrides` / workspace 解析；
/// - 分层判据：`packages/*` 不得反向依赖 `plugins/*`。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'audit.dart';
import 'models.dart';
import 'structure.dart';
import 'store.dart';

/// 结构整理的对外开放命令（挂在现有 `production` 执行站下）。
const List<String> kStructureCommands = <String>[
  'production.structure.get',
  'production.structure.reevaluate',
  'production.structure.waive',
];

/// 扫描时额外跳过的目录（审计的口径 + 附件落点）。
const Set<String> _kSkipDirs = <String>{...kAuditSkipDirs, '.input'};

/// 公共 API 回退扫描的文件上限（防止巨型仓库把一次请求拖成长任务）。
const int _kMaxApiFiles = 500;

/// 入口 + 相对 export 链的展开上限。
const int _kMaxExportFiles = 50;

/// 单个包参与依赖分析 / API 扫描的 Dart 文件上限。
const int _kMaxDartFilesPerPackage = 5000;

/// TODO findings 的路径上限（每文件一条 low）。
const int _kMaxTodoFindings = 100;

final RegExp _packageDirective = RegExp(
  r'''^\s*(?:import|export)\s+['"]package:([^/'"]+)''',
  multiLine: true,
);
final RegExp _exportDirective = RegExp(
  r'''^\s*export\s+['"]([^'"]+)['"]''',
  multiLine: true,
);
final RegExp _declaration = RegExp(
  r'^\s*(?:(?:abstract|final|sealed|base|interface)\s+)*'
  r'(?:class|mixin|enum|extension|typedef)\s+([A-Za-z_][A-Za-z0-9_]*)',
  multiLine: true,
);

DateTime _nowOf(ProductionStore store) =>
    DateTime.tryParse(store.nowText()) ?? DateTime.now();

/// 结构状态（命令回包与门禁共用）。
class StructureStatus {
  const StructureStatus({
    required this.lineId,
    required this.phase,
    required this.workspace,
    required this.fingerprint,
    required this.report,
    required this.readiness,
    required this.now,
  });

  final String lineId;
  final String phase;
  final String workspace;
  final String fingerprint;
  final StructureReport? report;
  final StructureReadiness readiness;
  final DateTime now;

  bool get ready => readiness.ready;
  List<String> get missing => readiness.missing;

  Map<String, Object?> toJson() => <String, Object?>{
    'line_id': lineId,
    'phase': phase,
    'workspace': workspace,
    'ready': ready,
    'missing': missing,
    'summary': structureSummary(
      report,
      now: now,
      stale: readiness.stale,
    ),
    'readiness': readiness.toJson(),
    'report': report?.toJson(),
  };
}

/// 读报告 + 重算指纹 + 判定就绪；不写盘。
StructureStatus structureStatusOf(ProductionStore store, String lineId) {
  final LineRecord line = store.getLine(lineId);
  final String workspace = line.workspaceDir;
  final StructureReport? report = StructureReport.fromJson(
    store.readStructure(lineId),
  );
  final DateTime now = _nowOf(store);
  final String fingerprint = _workspaceFingerprint(line, workspace);
  final StructureReadiness readiness = evaluateStructureReadiness(
    report: report,
    workspace: workspace,
    currentFingerprint: fingerprint,
    now: now,
  );
  return StructureStatus(
    lineId: lineId,
    phase: line.effectivePhase,
    workspace: workspace,
    fingerprint: fingerprint,
    report: report,
    readiness: readiness,
    now: now,
  );
}

/// 命令入口（由 `ProductionService.handle` 委派）。
Map<String, Object?> handleStructureCommand(
  ProductionStore store,
  String command,
  Map<String, Object?> arguments,
) {
  switch (command) {
    case 'production.structure.get':
      return structureStatusOf(
        store,
        _argument(arguments, 'line_id'),
      ).toJson();
    case 'production.structure.reevaluate':
      return _reevaluate(store, arguments);
    case 'production.structure.waive':
      return _waive(store, arguments);
    default:
      throw ProductionFailure(
        '未知结构整理命令：$command',
        code: 'unknown_command',
      );
  }
}

/// 结构门禁：非 cleanup 任务在报告未通过（含 stale）时一律拒绝。
///
/// 不按 `phase` 提前放行：结构报告一旦因为代码改动变 stale，即使产线已经
/// 推进到 `normalizing` / `ready`，非 cleanup 任务也必须先重跑结构报告。
void requireStructureReady(
  ProductionStore store,
  LineRecord line, {
  String taskType = 'code',
}) {
  if (taskType == 'cleanup') return;
  final StructureStatus status = structureStatusOf(store, line.id);
  if (status.ready) return;
  throw ProductionFailure(
    '项目结构未整理（phase=${line.effectivePhase}）：只能创建 / 派发 cleanup 任务；'
    '先修 high findings 或逐项豁免，再 production.structure.reevaluate',
    code: 'structure_not_ready',
    missing: status.missing,
  );
}

/// 批量命令（queue.dispatch / tick）：只要涉及非 cleanup 任务就过结构门。
///
/// 只看“可推进”的任务（queued / blocked / 在途）：旧产线里已经 done 的常规
/// 任务、停在 draft / aligning 的准备工作不参与判定，避免历史任务把清理卡死。
/// 与 [requireStructureReady] 一样不看 `phase`：报告 stale 时同样拒绝。
void requireStructureAllowsTasks(
  ProductionStore store,
  LineRecord line,
  Iterable<TaskRecord> tasks,
) {
  final List<TaskRecord> list = <TaskRecord>[
    for (final TaskRecord task in tasks)
      if (_structureGateRelevant(task.status)) task,
  ];
  if (list.every((TaskRecord task) => task.isCleanup)) return;
  final StructureStatus status = structureStatusOf(store, line.id);
  if (status.ready) return;
  final List<String> pending = <String>[
    for (final TaskRecord task in list)
      if (!task.isCleanup) '${task.id}:${task.taskType}',
  ];
  throw ProductionFailure(
    '项目结构未整理（phase=${line.effectivePhase}）：非 cleanup 任务不得派发 / 推进',
    code: 'structure_not_ready',
    missing: <String>[...status.missing, ...pending],
  );
}

/// 会触发结构门的任务状态：排队 / 阻塞 / 在途（其余状态不推进、不派发）。
bool _structureGateRelevant(TaskStatus status) =>
    status == TaskStatus.queued ||
    status == TaskStatus.blocked ||
    status.isInFlight;

// ── 命令实现 ──────────────────────────────────────────────────────

Map<String, Object?> _reevaluate(
  ProductionStore store,
  Map<String, Object?> arguments,
) {
  final String lineId = _argument(arguments, 'line_id');
  final LineRecord line = store.getLine(lineId);
  final String workspace = line.workspaceDir;
  if (workspace.isEmpty) {
    throw ProductionFailure(
      '产线未配置 workspace_dir：无法生成结构报告',
      code: 'workspace_required',
      missing: const <String>['workspace_dir'],
    );
  }
  if (!Directory(workspace).existsSync()) {
    throw ProductionFailure(
      '产线工作空间不存在：$workspace',
      code: 'workspace_unavailable',
      missing: const <String>['workspace_unavailable'],
    );
  }
  final StructureReport? previous = StructureReport.fromJson(
    store.readStructure(lineId),
  );
  final StructureReport report = _scanWorkspace(
    store,
    line,
    workspace,
    previous: previous,
  );
  store.writeStructure(lineId, report.toJson());
  final StructureReadiness readiness = evaluateStructureReadiness(
    report: report,
    workspace: workspace,
    currentFingerprint: report.fingerprint,
    now: _nowOf(store),
  );
  final String phase = _syncPhase(store, lineId, readiness.ready);
  return <String, Object?>{
    'line_id': lineId,
    'phase': phase,
    'ready': readiness.ready,
    'missing': readiness.missing,
    'evaluated': true,
    'summary': structureSummary(
      report,
      now: _nowOf(store),
      stale: readiness.stale,
    ),
    'readiness': readiness.toJson(),
    'report': report.toJson(),
  };
}

Map<String, Object?> _waive(
  ProductionStore store,
  Map<String, Object?> arguments,
) {
  final String lineId = _argument(arguments, 'line_id');
  final String findingId = _argument(arguments, 'finding_id');
  final String owner = textOf(arguments['owner']);
  final String reason = textOf(arguments['reason']);
  final String expiresAt = textOf(arguments['expires_at']);
  if (owner.isEmpty) {
    throw ProductionFailure(
      '豁免必须给 owner（谁承担这个风险）',
      code: 'invalid_arguments',
      missing: const <String>['owner'],
    );
  }
  if (reason.isEmpty) {
    throw ProductionFailure(
      '豁免必须给 reason（为什么可以暂不修）',
      code: 'invalid_arguments',
      missing: const <String>['reason'],
    );
  }
  if (expiresAt.isEmpty) {
    throw ProductionFailure(
      '豁免必须给 expires_at（到期自动失效，没有永久豁免）',
      code: 'invalid_arguments',
      missing: const <String>['expires_at'],
    );
  }
  if (structureInstant(expiresAt) == null) {
    throw ProductionFailure(
      'expires_at 不是合法的 ISO-8601 日期 / 时间：$expiresAt',
      code: 'invalid_arguments',
      missing: const <String>['expires_at'],
    );
  }
  final StructureReport? report = StructureReport.fromJson(
    store.readStructure(lineId),
  );
  if (report == null) {
    throw ProductionFailure(
      '结构报告不存在或不可读：先 production.structure.reevaluate',
      code: 'structure_report_missing',
      missing: const <String>['structure_report'],
    );
  }
  StructureFinding? target;
  for (final StructureFinding finding in report.findings) {
    if (finding.id == findingId) {
      target = finding;
      break;
    }
  }
  if (target == null) {
    throw ProductionFailure(
      '结构报告里没有 finding：$findingId（先重跑 reevaluate）',
      code: 'not_found',
      missing: <String>[findingId],
    );
  }
  if (!target.isHigh) {
    throw ProductionFailure(
      '只允许逐项豁免 high finding；${target.severity} 不阻断门禁，无需豁免',
      code: 'waiver_not_allowed',
      missing: <String>[findingId],
    );
  }
  final StructureWaiver waiver = StructureWaiver(
    findingId: findingId,
    owner: owner,
    reason: reason,
    expiresAt: expiresAt,
    createdAt: store.nowText(),
  );
  final List<StructureWaiver> waivers = <StructureWaiver>[
    for (final StructureWaiver item in report.waivers)
      if (item.findingId != findingId) item,
    waiver,
  ]..sort(
    (StructureWaiver a, StructureWaiver b) =>
        a.findingId.compareTo(b.findingId),
  );
  final StructureReport updated = StructureReport(
    version: report.version,
    lineId: report.lineId,
    workspace: report.workspace,
    generatedAt: report.generatedAt,
    fingerprint: report.fingerprint,
    packages: report.packages,
    findings: report.findings,
    waivers: waivers,
    cycles: report.cycles,
    layeringViolations: report.layeringViolations,
    notes: report.notes,
  );
  store.writeStructure(lineId, updated.toJson());
  final LineRecord line = store.getLine(lineId);
  final DateTime now = _nowOf(store);
  final StructureReadiness readiness = evaluateStructureReadiness(
    report: updated,
    workspace: line.workspaceDir,
    currentFingerprint: _workspaceFingerprint(line, line.workspaceDir),
    now: now,
  );
  final String phase = _syncPhase(store, lineId, readiness.ready);
  return <String, Object?>{
    'line_id': lineId,
    'phase': phase,
    'ready': readiness.ready,
    'missing': readiness.missing,
    'summary': structureSummary(updated, now: now, stale: readiness.stale),
    'waiver': waiver.toJson(),
    'readiness': readiness.toJson(),
  };
}

/// 结构通过 ⇒ 从 organizing 推进到 normalizing；不通过 ⇒ 回退到 organizing。
///
/// 只是阶段投影，不自动把产线标成 `ready`（复合就绪门在后续切片）。
String _syncPhase(ProductionStore store, String lineId, bool ready) {
  final LineRecord line = store.getLine(lineId);
  final String current = line.effectivePhase;
  if (ready && current == 'organizing') {
    store.setLinePhase(lineId, 'normalizing');
    return 'normalizing';
  }
  if (!ready && current != 'organizing') {
    store.setLinePhase(lineId, 'organizing');
    return 'organizing';
  }
  return current;
}

// ── 扫描 ──────────────────────────────────────────────────────────

StructureReport _scanWorkspace(
  ProductionStore store,
  LineRecord line,
  String workspace, {
  StructureReport? previous,
}) {
  final List<String> notes = <String>[];
  final String exclude = _assetExclude(line);
  final ({List<String> files, bool capped}) collected = _collectFiles(
    workspace,
    exclude,
  );
  if (collected.capped) {
    notes.add('候选文件达到上限 $kAuditMaxFiles，结构报告可能不完整。');
  }

  final Map<String, _ScanEntry> entries = <String, _ScanEntry>{};
  final Map<String, String> dartTexts = <String, String>{};
  final Map<String, String> pubspecTexts = <String, String>{};
  int skippedFiles = 0;
  for (final String relative in collected.files) {
    final File file = File(_join(workspace, relative));
    FileStat stat;
    try {
      stat = file.statSync();
    } catch (_) {
      continue;
    }
    if (stat.type != FileSystemEntityType.file) continue;
    final int size = stat.size;
    final int mtime = stat.modified.millisecondsSinceEpoch;
    final bool oversized = size > kAuditMaxFileBytes;
    String digest = '';
    List<Map<String, Object?>> todos = const <Map<String, Object?>>[];
    if (!oversized) {
      List<int> bytes;
      try {
        bytes = file.readAsBytesSync();
      } catch (_) {
        entries[relative] = _ScanEntry(
          size: size,
          mtime: mtime,
          skipped: true,
          large: size >= kAuditLargeFileBytes ? size : 0,
        );
        skippedFiles += 1;
        continue;
      }
      if (size >= kAuditDuplicateMinBytes) digest = auditDigest(bytes);
      final String text = utf8.decode(bytes, allowMalformed: true);
      todos = <Map<String, Object?>>[
        for (final AuditTodo todo in auditTodosOf(relative, text))
          todo.toJson(),
      ];
      final String base = p.basename(relative);
      if (base == 'pubspec.yaml') pubspecTexts[relative] = text;
      if (relative.endsWith('.dart') &&
          dartTexts.length < _kMaxDartFilesPerPackage * 8) {
        dartTexts[relative] = text;
      }
    } else {
      skippedFiles += 1;
    }
    entries[relative] = _ScanEntry(
      size: size,
      mtime: mtime,
      skipped: oversized,
      digest: digest,
      todos: todos,
      large: size >= kAuditLargeFileBytes ? size : 0,
    );
  }
  if (skippedFiles > 0) {
    notes.add('$skippedFiles 个文件超过 $kAuditMaxFileBytes 字节或不可读，已跳过内容扫描'
        '（超限文件仍计入 large_file 候选）。');
  }

  // 包：一个 pubspec.yaml 一个包；职责取 description。
  final List<_Pkg> packages = <_Pkg>[];
  for (final String relative in pubspecTexts.keys.toList()..sort()) {
    final String dir = p.url.dirname(relative) == '.'
        ? ''
        : p.url.dirname(relative);
    final Object? decoded;
    try {
      decoded = loadYaml(pubspecTexts[relative]!);
    } catch (error) {
      notes.add('包 `$dir` 的 pubspec.yaml 无法解析（$error），已跳过。');
      continue;
    }
    final Map<String, Object?> yaml = plainMap(decoded);
    final String name = textOf(yaml['name']).isEmpty
        ? (dir.isEmpty ? p.basename(workspace) : p.url.basename(dir))
        : textOf(yaml['name']);
    packages.add(
      _Pkg(
        dir: dir,
        id: name,
        responsibility: textOf(yaml['description']),
        pubspecPath: relative,
      ),
    );
  }
  packages.sort((_Pkg a, _Pkg b) {
    final int byId = a.id.compareTo(b.id);
    return byId != 0 ? byId : a.dir.compareTo(b.dir);
  });
  if (packages.isEmpty) {
    notes.add('未检测到 pubspec.yaml：本次结构报告没有包记录。');
  }

  // Dart 文件存在但没有任何包：说明扫描口径 / 仓库结构有问题，不能当“干净”。
  final List<String> dartPaths = <String>[
    for (final String path in entries.keys)
      if (path.endsWith('.dart')) path,
  ]..sort();

  // Dart 文件归属：取最长前缀的包目录（根包兜底）。
  for (final String relative in dartTexts.keys) {
    final _Pkg? owner = _ownerOf(relative, packages);
    if (owner == null) continue;
    if (owner.dartFiles.length < _kMaxDartFilesPerPackage) {
      owner.dartFiles.add(relative);
    }
  }
  for (final _Pkg pkg in packages) {
    pkg.dartFiles.sort();
    pkg.entry = _entryOf(pkg);
  }

  // 公共 API（best-effort）。
  for (final _Pkg pkg in packages) {
    pkg.publicApi = _publicApiOf(pkg, dartTexts, notes);
  }
  notes.add(
    '公共 API 为 best-effort：入口 + 相对 export 链（≤ $_kMaxExportFiles 个文件），'
    '解析不到时回退到 lib 顶层声明（≤ $_kMaxApiFiles 个文件）；package: 形式'
    '的 export 不展开。',
  );

  // 依赖边：package: 导入 / 导出。
  final Set<String> ids = <String>{
    for (final _Pkg pkg in packages) pkg.id,
  };
  for (final _Pkg pkg in packages) {
    for (final String relative in pkg.dartFiles) {
      final String? text = dartTexts[relative];
      if (text == null) continue;
      for (final RegExpMatch match in _packageDirective.allMatches(text)) {
        final String dependency = match.group(1)!;
        if (dependency == pkg.id || !ids.contains(dependency)) continue;
        pkg.dependsOn.add(dependency);
      }
    }
    pkg.dependsOn.sort();
  }
  final Map<String, Set<String>> edges = <String, Set<String>>{
    for (final _Pkg pkg in packages)
      pkg.id: <String>{for (final String item in pkg.dependsOn) item},
  };
  final List<List<String>> cycles = _dependencyCycles(edges);
  final List<Map<String, Object?>> layering = _layeringViolations(packages);

  // findings。
  final List<StructureFinding> findings = <StructureFinding>[];
  void addFinding(
    String severity,
    String kind,
    List<String> targets,
    String suggestion,
  ) {
    final List<String> sorted = List<String>.of(targets)..sort();
    final String id = stableStructureFindingId(kind, sorted);
    if (findings.any((StructureFinding item) => item.id == id)) return;
    findings.add(
      StructureFinding(
        id: id,
        severity: severity,
        kind: kind,
        targets: sorted,
        suggestion: suggestion,
      ),
    );
  }

  final Map<String, List<String>> byId = <String, List<String>>{};
  for (final _Pkg pkg in packages) {
    byId.putIfAbsent(pkg.id, () => <String>[]).add(pkg.dir);
    if (pkg.responsibility.isEmpty) {
      addFinding(
        'high',
        'missing_responsibility',
        <String>[pkg.id],
        '在 ${pkg.pubspecPath} 补 description，或登记该包的主职责（一个包一个主职责）',
      );
    }
    if (pkg.entry.isEmpty) {
      addFinding(
        'low',
        'entry_missing',
        <String>[pkg.id],
        '补 lib/${pkg.id}.dart 入口，或确认该包只作为工具/资源包',
      );
    }
  }
  for (final MapEntry<String, List<String>> entry in byId.entries) {
    if (entry.value.length > 1) {
      addFinding(
        'high',
        'duplicate_package_id',
        entry.value,
        '包名 `${entry.key}` 重复：依赖边无法唯一解析，先改名或合并',
      );
    }
  }
  if (packages.isEmpty && dartPaths.isNotEmpty) {
    addFinding(
      'high',
      'missing_packages',
      dartPaths.take(10).toList(),
      '检测到 ${dartPaths.length} 个 .dart 文件但没有 pubspec.yaml：补包清单'
      '（或确认扫描根目录 / docs.asset_dir 配置），否则依赖与 API 无法归类',
    );
  }
  for (final List<String> cycle in cycles) {
    addFinding(
      'high',
      'dependency_cycle',
      cycle,
      '打断环：抽公共包 / 反转依赖 / 用接口下沉',
    );
  }
  for (final Map<String, Object?> violation in layering) {
    addFinding(
      'high',
      'layering_violation',
      <String>[
        textOf(violation['from']),
        textOf(violation['to']),
      ],
      'packages/* 不得依赖 plugins/*：把共享能力下沉到 packages，或反转依赖',
    );
  }

  // 既有 audit 数据：重复 / 超大 / 文档缺口 / TODO。
  final Map<String, List<String>> digestPaths = <String, List<String>>{};
  final Map<String, int> digestSize = <String, int>{};
  final Map<String, int> largeFiles = <String, int>{};
  final Map<String, int> todoCount = <String, int>{};
  final Map<String, String> todoFirst = <String, String>{};
  for (final MapEntry<String, _ScanEntry> entry in entries.entries) {
    final _ScanEntry item = entry.value;
    if (item.digest.isNotEmpty) {
      digestPaths.putIfAbsent(item.digest, () => <String>[]).add(entry.key);
      digestSize.putIfAbsent(item.digest, () => item.size);
    }
    if (item.large > 0) largeFiles[entry.key] = item.large;
    if (item.todos.isNotEmpty) {
      todoCount[entry.key] = item.todos.length;
      todoFirst[entry.key] = textOf(item.todos.first['text']);
    }
  }
  for (final AuditDuplicate duplicate in auditDuplicatesOf(
    digestPaths,
    digestSize,
  )) {
    addFinding(
      'medium',
      'duplicate_code',
      duplicate.paths,
      '${duplicate.size} 字节内容重复：合并或抽取共享实现',
    );
  }
  for (final Map<String, Object?> item in auditLargeFilesOf(largeFiles)) {
    final String path = textOf(item['path']);
    addFinding(
      'low',
      'large_file',
      <String>[path],
      '${intOf(item['size'], 0)} 字节：评估拆分 / 收束',
    );
  }
  final List<String> manifest = stringsOf(
    plainMap(line.data['docs'])['memory_manifest'],
  );
  if (manifest.isEmpty) {
    notes.add('产线未配置 docs.memory_manifest：文档缺口未检查。');
  } else {
    for (final String relative in manifest) {
      if (File(_join(workspace, relative)).existsSync()) continue;
      addFinding(
        'low',
        'docs_gap',
        <String>[relative],
        '缺项目记忆文档：补上或从 docs.memory_manifest 移除',
      );
    }
  }
  final List<String> todoPaths = todoCount.keys.toList()..sort();
  for (final String path in todoPaths.take(_kMaxTodoFindings)) {
    addFinding(
      'low',
      'todo_open',
      <String>[path],
      '${todoCount[path]} 处 TODO / FIXME：逐条分类（本迭代 / 下迭代 / 删除）'
      '${todoFirst[path]!.isEmpty ? '' : '；首条：${todoFirst[path]}'}',
    );
  }
  if (todoPaths.length > _kMaxTodoFindings) {
    notes.add('TODO 台账超过 $_kMaxTodoFindings 个文件，已截断。');
  }
  findings.sort((StructureFinding a, StructureFinding b) {
    final int bySeverity = kStructureSeverities
        .indexOf(a.severity)
        .compareTo(kStructureSeverities.indexOf(b.severity));
    if (bySeverity != 0) return bySeverity;
    final int byKind = a.kind.compareTo(b.kind);
    if (byKind != 0) return byKind;
    return a.targets.join('|').compareTo(b.targets.join('|'));
  });

  final List<StructureWaiver> waivers = <StructureWaiver>[
    for (final StructureWaiver waiver
        in previous?.waivers ?? const <StructureWaiver>[])
      waiver,
  ]..sort(
    (StructureWaiver a, StructureWaiver b) =>
        a.findingId.compareTo(b.findingId),
  );

  return StructureReport(
    lineId: line.id,
    workspace: workspace,
    generatedAt: store.nowText(),
    fingerprint: _fingerprintOf(workspace, entries),
    packages: <StructurePackage>[
      for (final _Pkg pkg in packages)
        StructurePackage(
          id: pkg.id,
          responsibility: pkg.responsibility,
          entry: pkg.entry,
          publicApi: pkg.publicApi,
          dependsOn: pkg.dependsOn,
          path: pkg.dir,
        ),
    ],
    findings: findings,
    waivers: waivers,
    cycles: cycles,
    layeringViolations: layering,
    notes: notes,
  );
}

/// 收集候选文件（跳过依赖 / 构建 / 缓存 / `.input` / 产线资产目录）。
({List<String> files, bool capped}) _collectFiles(
  String workspace,
  String exclude,
) {
  final List<String> files = <String>[];
  bool capped = false;
  final List<Directory> stack = <Directory>[Directory(workspace)];
  while (stack.isNotEmpty) {
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
      if (entity is Directory) {
        final String name = p.basename(entity.path);
        if (_kSkipDirs.contains(name)) continue;
        if (_excluded(entity.path, workspace, exclude)) continue;
        stack.add(entity);
        continue;
      }
      if (entity is! File) continue;
      final String extension = p
          .extension(entity.path)
          .replaceFirst('.', '')
          .toLowerCase();
      if (!kAuditExtensions.contains(extension)) continue;
      if (_excluded(entity.path, workspace, exclude)) continue;
      files.add(_relative(entity.path, workspace));
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

bool _excluded(String path, String workspace, String exclude) {
  if (exclude.isEmpty) return false;
  final String relative = _relative(path, workspace);
  return relative == exclude || relative.startsWith('$exclude/');
}

String _assetExclude(LineRecord line) {
  final Map<String, Object?> docs = plainMap(line.data['docs']);
  final String assetDir = textOf(docs['asset_dir']).isEmpty
      ? 'docs/production_lines'
      : textOf(docs['asset_dir']);
  final String joined = p.posix.normalize(
    '${assetDir.replaceAll('\\', '/')}/${line.id}',
  );
  return joined == '.' ? '' : joined;
}

String _relative(String path, String root) =>
    p.relative(path, from: root).replaceAll('\\', '/');

String _join(String workspace, String relative) =>
    p.joinAll(<String>[workspace, ...relative.split('/')]);

String _fingerprintOf(String workspace, Map<String, _ScanEntry> entries) {
  final StringBuffer buffer = StringBuffer(workspace);
  final List<String> paths = entries.keys.toList()..sort();
  for (final String path in paths) {
    final _ScanEntry entry = entries[path]!;
    buffer.writeln('$path|${entry.size}|${entry.mtime}');
  }
  return auditDigest(utf8Bytes(buffer.toString()));
}

String _workspaceFingerprint(LineRecord line, String workspace) {
  if (workspace.isEmpty || !Directory(workspace).existsSync()) return '';
  final ({List<String> files, bool capped}) collected = _collectFiles(
    workspace,
    _assetExclude(line),
  );
  final Map<String, _ScanEntry> entries = <String, _ScanEntry>{};
  for (final String relative in collected.files) {
    try {
      final FileStat stat = File(_join(workspace, relative)).statSync();
      if (stat.type != FileSystemEntityType.file) continue;
      entries[relative] = _ScanEntry(
        size: stat.size,
        mtime: stat.modified.millisecondsSinceEpoch,
        skipped: false,
      );
    } catch (_) {
      continue;
    }
  }
  return _fingerprintOf(workspace, entries);
}

_Pkg? _ownerOf(String relative, List<_Pkg> packages) {
  _Pkg? best;
  for (final _Pkg pkg in packages) {
    if (pkg.dir.isEmpty) {
      best ??= pkg;
      continue;
    }
    if (relative == pkg.dir || relative.startsWith('${pkg.dir}/')) {
      if (best == null || pkg.dir.length > best.dir.length) best = pkg;
    }
  }
  return best;
}

String _entryOf(_Pkg pkg) {
  final String base = pkg.dir.isEmpty ? '' : '${pkg.dir}/';
  final String candidate = '${base}lib/${pkg.id}.dart';
  return pkg.dartFiles.contains(candidate) ? candidate : '';
}

List<String> _publicApiOf(
  _Pkg pkg,
  Map<String, String> dartTexts,
  List<String> notes,
) {
  final Set<String> api = <String>{};
  if (pkg.entry.isNotEmpty && dartTexts.containsKey(pkg.entry)) {
    final Set<String> visited = <String>{};
    final List<String> queue = <String>[pkg.entry];
    while (queue.isNotEmpty && visited.length < _kMaxExportFiles) {
      final String relative = queue.removeAt(0);
      if (!visited.add(relative)) continue;
      final String? text = dartTexts[relative];
      if (text == null) continue;
      for (final RegExpMatch match in _exportDirective.allMatches(text)) {
        final String? target = _resolveRelativeDart(
          relative,
          match.group(1)!,
        );
        if (target != null && dartTexts.containsKey(target)) queue.add(target);
      }
      api.addAll(_declarationsOf(text));
    }
  }
  if (api.isEmpty) {
    final String prefix = pkg.dir.isEmpty ? 'lib/' : '${pkg.dir}/lib/';
    int scanned = 0;
    for (final String relative in pkg.dartFiles) {
      if (!relative.startsWith(prefix)) continue;
      if (scanned >= _kMaxApiFiles) {
        notes.add('包 `${pkg.id}` 的公共 API 回退扫描达到 $_kMaxApiFiles 个文件，已截断。');
        break;
      }
      scanned += 1;
      api.addAll(_declarationsOf(dartTexts[relative] ?? ''));
    }
  }
  final List<String> out = api.toList()..sort();
  return out;
}

String? _resolveRelativeDart(String fromRelative, String uri) {
  if (uri.startsWith('dart:') || uri.startsWith('package:')) return null;
  if (uri.startsWith('/')) return null;
  final String dir = p.url.dirname(fromRelative);
  final String joined = p.url.normalize(
    dir == '.' ? uri : '$dir/$uri',
  );
  if (joined.startsWith('..')) return null;
  return joined;
}

List<String> _declarationsOf(String text) => <String>[
  for (final RegExpMatch match in _declaration.allMatches(text))
    if (!match.group(1)!.startsWith('_')) match.group(1)!,
];

/// Tarjan SCC：返回所有环（含自依赖）。
List<List<String>> _dependencyCycles(Map<String, Set<String>> edges) {
  final List<String> ids = edges.keys.toList()..sort();
  final Map<String, int> index = <String, int>{};
  final Map<String, int> low = <String, int>{};
  final Set<String> onStack = <String>{};
  final List<String> stack = <String>[];
  final List<List<String>> components = <List<String>>[];
  int next = 0;

  void strongConnect(String node) {
    index[node] = next;
    low[node] = next;
    next += 1;
    stack.add(node);
    onStack.add(node);
    final List<String> targets = (edges[node] ?? const <String>{})
        .toList()
      ..sort();
    for (final String target in targets) {
      if (!edges.containsKey(target)) continue;
      if (!index.containsKey(target)) {
        strongConnect(target);
        low[node] = math.min(low[node]!, low[target]!);
      } else if (onStack.contains(target)) {
        low[node] = math.min(low[node]!, index[target]!);
      }
    }
    if (low[node] == index[node]) {
      final List<String> component = <String>[];
      while (stack.isNotEmpty) {
        final String item = stack.removeLast();
        onStack.remove(item);
        component.add(item);
        if (item == node) break;
      }
      component.sort();
      final bool selfLoop =
          component.length == 1 &&
          (edges[component.first]?.contains(component.first) ?? false);
      if (component.length > 1 || selfLoop) components.add(component);
    }
  }

  for (final String id in ids) {
    if (!index.containsKey(id)) strongConnect(id);
  }
  components.sort(
    (List<String> a, List<String> b) => a.first.compareTo(b.first),
  );
  return components;
}

/// `packages/*` 反向依赖 `plugins/*` ⇒ 分层违规。
List<Map<String, Object?>> _layeringViolations(List<_Pkg> packages) {
  final Map<String, _Pkg> byId = <String, _Pkg>{
    for (final _Pkg pkg in packages) pkg.id: pkg,
  };
  final List<Map<String, Object?>> out = <Map<String, Object?>>[];
  for (final _Pkg pkg in packages) {
    for (final String dependency in pkg.dependsOn) {
      final _Pkg? target = byId[dependency];
      if (target == null) continue;
      if (_layerOf(pkg.dir) == 'library' && _layerOf(target.dir) == 'app') {
        out.add(<String, Object?>{
          'from': pkg.id,
          'to': target.id,
          'from_path': pkg.dir,
          'to_path': target.dir,
        });
      }
    }
  }
  out.sort(
    (Map<String, Object?> a, Map<String, Object?> b) =>
        '${a['from']}->${a['to']}'.compareTo('${b['from']}->${b['to']}'),
  );
  return out;
}

String _layerOf(String dir) {
  final String path = dir.replaceAll('\\', '/');
  if (path == 'packages' || path.startsWith('packages/')) return 'library';
  if (path == 'plugins' || path.startsWith('plugins/')) return 'app';
  return '';
}

String _argument(Map<String, Object?> arguments, String key) {
  final String value = textOf(arguments[key]);
  if (value.isEmpty) {
    throw ProductionFailure('缺少 $key', code: 'invalid_arguments');
  }
  return value;
}

class _ScanEntry {
  const _ScanEntry({
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
}

class _Pkg {
  _Pkg({
    required this.dir,
    required this.id,
    required this.responsibility,
    required this.pubspecPath,
  });

  final String dir;
  final String id;
  final String responsibility;
  final String pubspecPath;
  final List<String> dartFiles = <String>[];
  final List<String> dependsOn = <String>[];
  String entry = '';
  List<String> publicApi = const <String>[];
}
