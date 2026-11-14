/// 项目结构报告（LG-01）的纯领域模型与就绪判定。
///
/// 口径（docs/pluginization/production-line-gates.md §3.3）：
/// - 报告落插件数据 `<line>/structure.json`，schema 固定 `version: 1`；
/// - `packages` 记录包职责 / 入口 / 公共 API / 依赖；`findings` 记录
///   high / medium / low 三类问题；`waivers` 只允许逐项豁免 high；
/// - **只有 high 会阻断**：`medium` / `low` 必须列出但不拦门；
/// - 豁免必须带 `owner / reason / expires_at`，到期后自动失效；
/// - 报告 `fingerprint` 必须与当前工作空间一致，否则视为 stale（重跑）。
///
/// 这一层只做纯计算（不读盘、不写盘）：扫描与落盘见 `structure_service.dart`。
library;

import 'audit.dart' show auditDigest;
import 'models.dart';

/// 结构报告版本（schema 变更时递增，旧报告自动失效）。
const int kStructureReportVersion = 1;

/// 报告严重级别（顺序即展示优先级）。
const List<String> kStructureSeverities = <String>['high', 'medium', 'low'];

/// 一条包记录（一个 `pubspec.yaml` 对应一个包）。
class StructurePackage {
  const StructurePackage({
    required this.id,
    required this.responsibility,
    required this.entry,
    required this.publicApi,
    required this.dependsOn,
    this.path = '',
    this.publicApiDeclared = true,
  });

  final String id;

  /// 主职责（来自 `pubspec.yaml.description`；空 ⇒ high finding）。
  final String responsibility;

  /// 包入口（`lib/<name>.dart`；找不到时为空，并给 low finding）。
  final String entry;

  /// 公共 API 清单（best-effort：导出的顶层声明；空列表也是有效清单）。
  final List<String> publicApi;

  /// 报告里确实有 `public_api` 键（手写 / 损坏报告缺键 ⇒ 不通过）。
  final bool publicApiDeclared;

  final List<String> dependsOn;

  /// 相对工作空间的包目录（根包为 `''`）。
  final String path;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'responsibility': responsibility,
    'entry': entry,
    'public_api': publicApi,
    'depends_on': dependsOn,
    'path': path,
  };

  static StructurePackage? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Map<String, Object?> data = plainMap(raw);
    final String id = textOf(data['id']);
    if (id.isEmpty) return null;
    return StructurePackage(
      id: id,
      responsibility: textOf(data['responsibility']),
      entry: textOf(data['entry']),
      publicApi: stringsOf(data['public_api']),
      dependsOn: stringsOf(data['depends_on']),
      path: textOf(data['path']),
      publicApiDeclared: data.containsKey('public_api'),
    );
  }
}

/// 一条结构问题。
class StructureFinding {
  const StructureFinding({
    required this.id,
    required this.severity,
    required this.kind,
    required this.targets,
    required this.suggestion,
  });

  /// 稳定 id：由 `kind + targets` 计算 ⇒ 重跑后 id 不变，豁免可持续。
  final String id;
  final String severity;
  final String kind;
  final List<String> targets;
  final String suggestion;

  bool get isHigh => severity == 'high';
  bool get isMedium => severity == 'medium';
  bool get isLow => severity == 'low';

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'severity': severity,
    'kind': kind,
    'targets': targets,
    'suggestion': suggestion,
  };

  static StructureFinding? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Map<String, Object?> data = plainMap(raw);
    final String id = textOf(data['id']);
    final String severity = textOf(data['severity']);
    if (id.isEmpty || !kStructureSeverities.contains(severity)) return null;
    return StructureFinding(
      id: id,
      severity: severity,
      kind: textOf(data['kind']),
      targets: stringsOf(data['targets']),
      suggestion: textOf(data['suggestion']),
    );
  }
}

/// 一条逐项豁免（只允许 high finding）。
class StructureWaiver {
  const StructureWaiver({
    required this.findingId,
    required this.owner,
    required this.reason,
    required this.expiresAt,
    required this.createdAt,
  });

  final String findingId;
  final String owner;
  final String reason;

  /// ISO-8601（日期或日期时间）；日期按当天 23:59:59.999 失效。
  final String expiresAt;
  final String createdAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'finding_id': findingId,
    'owner': owner,
    'reason': reason,
    'expires_at': expiresAt,
    'created_at': createdAt,
  };

  static StructureWaiver? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Map<String, Object?> data = plainMap(raw);
    final String findingId = textOf(data['finding_id']);
    if (findingId.isEmpty) return null;
    return StructureWaiver(
      findingId: findingId,
      owner: textOf(data['owner']),
      reason: textOf(data['reason']),
      expiresAt: textOf(data['expires_at']),
      createdAt: textOf(data['created_at']),
    );
  }
}

/// `<line>/structure.json` 的只读视图。
class StructureReport {
  const StructureReport({
    required this.lineId,
    required this.workspace,
    required this.generatedAt,
    required this.fingerprint,
    required this.packages,
    required this.findings,
    required this.waivers,
    required this.cycles,
    required this.layeringViolations,
    required this.notes,
    this.version = kStructureReportVersion,
  });

  final int version;
  final String lineId;
  final String workspace;
  final String generatedAt;

  /// 扫描时的工作空间指纹（路径 + 大小 + mtime）。
  final String fingerprint;
  final List<StructurePackage> packages;
  final List<StructureFinding> findings;
  final List<StructureWaiver> waivers;

  /// 依赖环（每个元素是一个环上的包 id 列表）。
  final List<List<String>> cycles;

  /// 分层违规（`packages/*` 反向依赖 `plugins/*`）。
  final List<Map<String, Object?>> layeringViolations;
  final List<String> notes;

  List<StructureFinding> get highFindings => <StructureFinding>[
    for (final StructureFinding finding in findings)
      if (finding.isHigh) finding,
  ];

  Map<String, Object?> toJson() => <String, Object?>{
    'version': version,
    'line_id': lineId,
    'workspace': workspace,
    'generated_at': generatedAt,
    'fingerprint': fingerprint,
    'packages': <Map<String, Object?>>[
      for (final StructurePackage item in packages) item.toJson(),
    ],
    'findings': <Map<String, Object?>>[
      for (final StructureFinding item in findings) item.toJson(),
    ],
    'waivers': <Map<String, Object?>>[
      for (final StructureWaiver item in waivers) item.toJson(),
    ],
    'cycles': <List<String>>[for (final List<String> cycle in cycles) cycle],
    'layering_violations': layeringViolations,
    'notes': notes,
  };

  static StructureReport? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Map<String, Object?> data = plainMap(raw);
    if (intOf(data['version'], 0) != kStructureReportVersion) return null;
    final Object? packagesRaw = data['packages'];
    final Object? findingsRaw = data['findings'];
    if (packagesRaw is! List || findingsRaw is! List) return null;
    final List<StructurePackage> packages = <StructurePackage>[];
    for (final Object? item in packagesRaw) {
      final StructurePackage? parsed = StructurePackage.fromJson(item);
      if (parsed == null) return null;
      packages.add(parsed);
    }
    final List<StructureFinding> findings = <StructureFinding>[];
    for (final Object? item in findingsRaw) {
      final StructureFinding? parsed = StructureFinding.fromJson(item);
      if (parsed == null) return null;
      findings.add(parsed);
    }
    final List<StructureWaiver> waivers = <StructureWaiver>[];
    for (final Object? item
        in (data['waivers'] as List<Object?>? ?? const <Object?>[])) {
      final StructureWaiver? parsed = StructureWaiver.fromJson(item);
      if (parsed != null) waivers.add(parsed);
    }
    final List<List<String>> cycles = <List<String>>[
      for (final Object? item
          in (data['cycles'] as List<Object?>? ?? const []))
        if (item is List) stringsOf(item),
    ];
    final List<Map<String, Object?>> layering = <Map<String, Object?>>[
      for (final Object? item
          in (data['layering_violations'] as List<Object?>? ?? const []))
        if (item is Map) plainMap(item),
    ];
    return StructureReport(
      version: intOf(data['version'], 0),
      lineId: textOf(data['line_id']),
      workspace: textOf(data['workspace']),
      generatedAt: textOf(data['generated_at']),
      fingerprint: textOf(data['fingerprint']),
      packages: packages,
      findings: findings,
      waivers: waivers,
      cycles: cycles,
      layeringViolations: layering,
      notes: stringsOf(data['notes']),
    );
  }
}

/// 就绪判定结果（`structure.ready` 的唯一口径）。
class StructureReadiness {
  const StructureReadiness({
    required this.ready,
    required this.missing,
    required this.stale,
    required this.highTotal,
    required this.highUnwaived,
    required this.activeWaivers,
    required this.expiredWaivers,
  });

  final bool ready;

  /// 未通过项（缺报告 / stale / 各类 high 的 kind）。
  final List<String> missing;

  final bool stale;
  final int highTotal;
  final List<StructureFinding> highUnwaived;
  final int activeWaivers;
  final int expiredWaivers;

  Map<String, Object?> toJson() => <String, Object?>{
    'ready': ready,
    'missing': missing,
    'stale': stale,
    'high_total': highTotal,
    'high_unwaived': <Map<String, Object?>>[
      for (final StructureFinding finding in highUnwaived) finding.toJson(),
    ],
    'active_waivers': activeWaivers,
    'expired_waivers': expiredWaivers,
  };
}

/// 解析豁免到期时间。
///
/// 只给日期（`2026-12-31`）时按当天 23:59:59.999 失效；格式非法返回 null
/// （由调用方判 `invalid_arguments`，不把坏值当“永久有效”）。
DateTime? structureInstant(String raw) {
  final String value = raw.trim();
  if (value.isEmpty) return null;
  final DateTime? parsed = DateTime.tryParse(value);
  if (parsed == null) return null;
  if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    return DateTime(parsed.year, parsed.month, parsed.day, 23, 59, 59, 999);
  }
  return parsed;
}

/// 豁免是否已过期（格式非法也按过期处理，fail-closed）。
bool structureWaiverExpired(StructureWaiver waiver, DateTime now) {
  final DateTime? at = structureInstant(waiver.expiresAt);
  if (at == null) return true;
  return !at.isAfter(now);
}

/// 当前生效（未过期）的豁免 finding id 集合。
Set<String> activeWaiverIds(StructureReport report, DateTime now) => <String>{
  for (final StructureWaiver waiver in report.waivers)
    if (!structureWaiverExpired(waiver, now)) waiver.findingId,
};

/// 未豁免的 high findings（阻断项）。
List<StructureFinding> unwaivedHighFindings(
  StructureReport report,
  DateTime now,
) {
  final Set<String> waived = activeWaiverIds(report, now);
  return <StructureFinding>[
    for (final StructureFinding finding in report.highFindings)
      if (!waived.contains(finding.id)) finding,
  ];
}

/// `structure.ready` 的唯一判定入口。
///
/// 门槛：报告存在且版本匹配、workspace 一致、fingerprint 未 stale、无未豁免
/// high、所有包有职责、依赖环 = 0、分层违规 = 0。medium / low 不阻断。
StructureReadiness evaluateStructureReadiness({
  required StructureReport? report,
  required String workspace,
  required String currentFingerprint,
  required DateTime now,
}) {
  if (report == null) {
    return StructureReadiness(
      ready: false,
      missing: <String>[
        'structure_report',
        if (workspace.isEmpty) 'workspace_dir',
      ],
      stale: true,
      highTotal: 0,
      highUnwaived: const <StructureFinding>[],
      activeWaivers: 0,
      expiredWaivers: 0,
    );
  }
  final List<String> missing = <String>[];
  if (workspace.isEmpty) missing.add('workspace_dir');
  if (report.version != kStructureReportVersion) {
    missing.add('structure_report_version');
  }
  if (report.workspace != workspace) missing.add('structure_workspace_mismatch');
  final bool stale = report.fingerprint != currentFingerprint;
  if (stale) missing.add('structure_report_stale');

  final List<StructureFinding> unwaived = unwaivedHighFindings(report, now);
  for (final StructureFinding finding in unwaived) {
    if (finding.kind.isNotEmpty && !missing.contains(finding.kind)) {
      missing.add(finding.kind);
    }
  }
  // 原始条件（环 / 分层 / 职责）也必须被 high finding 覆盖；正常情况下生成器
  // 一定会产出对应 finding，此时由上面的 unwaived 列表统一判定（豁免后不阻断）。
  // 若报告里没有对应 high finding（手写 / 损坏），按 fail-closed 补一项。
  bool highOfKind(String kind) =>
      report.highFindings.any((StructureFinding finding) => finding.kind == kind);
  for (final StructurePackage package in report.packages) {
    if (package.responsibility.isEmpty &&
        !highOfKind('missing_responsibility') &&
        !missing.contains('missing_responsibility')) {
      missing.add('missing_responsibility');
    }
    if (!package.publicApiDeclared && !missing.contains('public_api_missing')) {
      missing.add('public_api_missing');
    }
  }
  if (report.cycles.isNotEmpty &&
      !highOfKind('dependency_cycle') &&
      !missing.contains('dependency_cycle')) {
    missing.add('dependency_cycle');
  }
  if (report.layeringViolations.isNotEmpty &&
      !highOfKind('layering_violation') &&
      !missing.contains('layering_violation')) {
    missing.add('layering_violation');
  }

  final int active = activeWaiverIds(report, now).length;
  final int expired = report.waivers.length - active;
  return StructureReadiness(
    ready: missing.isEmpty,
    missing: missing,
    stale: stale,
    highTotal: report.highFindings.length,
    highUnwaived: unwaived,
    activeWaivers: active,
    expiredWaivers: expired < 0 ? 0 : expired,
  );
}

/// 报告摘要（`structure.get` / `reevaluate` 回包共用）。
Map<String, Object?> structureSummary(
  StructureReport? report, {
  required DateTime now,
  bool stale = false,
}) {
  int high = 0;
  int medium = 0;
  int low = 0;
  int activeWaivers = 0;
  int expiredWaivers = 0;
  if (report != null) {
    for (final StructureFinding finding in report.findings) {
      if (finding.isHigh) {
        high += 1;
      } else if (finding.isMedium) {
        medium += 1;
      } else {
        low += 1;
      }
    }
    activeWaivers = activeWaiverIds(report, now).length;
    expiredWaivers = report.waivers.length - activeWaivers;
  }
  return <String, Object?>{
    'packages': report?.packages.length ?? 0,
    'findings': report?.findings.length ?? 0,
    'high': high,
    'high_unwaived': report == null
        ? 0
        : unwaivedHighFindings(report, now).length,
    'medium': medium,
    'low': low,
    'waivers': activeWaivers,
    'expired_waivers': expiredWaivers < 0 ? 0 : expiredWaivers,
    'cycles': report?.cycles.length ?? 0,
    'layering_violations': report?.layeringViolations.length ?? 0,
    'stale': stale,
  };
}

/// 稳定 finding id：`F-<kind 摘要>-<hash>`。
///
/// 由 `kind + targets` 计算（与文件顺序无关），重跑报告后同一问题仍是同一 id，
/// 已登记的豁免不会因重新扫描而失效。
String stableStructureFindingId(String kind, List<String> targets) {
  final String digest = auditDigest(
    utf8Bytes('$kind|${targets.join('|')}'),
  ).substring(0, 10);
  final String slug = kind
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return 'F-${slug.isEmpty ? 'finding' : slug}-$digest';
}

/// UTF-8 编码（避免为一行工具函数引入 dart:convert 的隐式依赖）。
List<int> utf8Bytes(String text) {
  final List<int> out = <int>[];
  for (final int rune in text.runes) {
    if (rune < 0x80) {
      out.add(rune);
    } else if (rune < 0x800) {
      out.add(0xC0 | (rune >> 6));
      out.add(0x80 | (rune & 0x3F));
    } else if (rune < 0x10000) {
      out.add(0xE0 | (rune >> 12));
      out.add(0x80 | ((rune >> 6) & 0x3F));
      out.add(0x80 | (rune & 0x3F));
    } else {
      out.add(0xF0 | (rune >> 18));
      out.add(0x80 | ((rune >> 12) & 0x3F));
      out.add(0x80 | ((rune >> 6) & 0x3F));
      out.add(0x80 | (rune & 0x3F));
    }
  }
  return out;
}
