/// 任务拆分器（PC-3E）：计划 DAG 校验 + 确定性修正 + 批次计算。
///
/// 纯函数，不读盘；口径见 `docs/pluginization/production-line-gates.md` §4.2：
/// - PG-03 依赖图：去重 / 去自依赖 / 缺依赖 / 环；
/// - PG-04 任务尺寸：1–5 文件、≤300 行、≤1 包；超限自动拆分或要求拆分理由；
/// - PG-05 写域交叠：交叠且互不可达 ⇒ 串行（fix）或报错；
/// - PG-06 任务门控：至少一个可执行命令或非空话清单项；
/// - PG-07 集成任务：多个 `code` 任务必须有覆盖全部代码任务（含传递依赖）的
///   `integration` 任务。
///
/// 所有修正都按固定顺序与 id 升序进行，保证同一输入得到同一结果。
library;

import 'execution.dart' show normalizeRelPath;
import 'models.dart';
import 'queue.dart';

/// 一条计划问题；[severity] 固定 `error` / `warning`。
class PlanIssue {
  const PlanIssue({
    required this.code,
    required this.taskId,
    required this.message,
    this.severity = 'error',
  });

  final String code;
  final String taskId;
  final String message;
  final String severity;

  Map<String, Object?> toJson() => <String, Object?>{
    'code': code,
    'task_id': taskId,
    'message': message,
    'severity': severity,
  };
}

/// 一个可并行批次；[wave] 是依赖波次（从 1 开始）。
class PlanBatch {
  const PlanBatch({
    required this.index,
    required this.wave,
    required this.taskIds,
  });

  final int index;
  final int wave;
  final List<String> taskIds;

  Map<String, Object?> toJson() => <String, Object?>{
    'index': index,
    'wave': wave,
    'task_ids': taskIds,
  };
}

/// 一次计划校验的结果。[tasks] 是修正后的任务（`fix=false` 时原样返回）。
class PlanValidation {
  const PlanValidation({
    required this.ok,
    required this.issues,
    required this.tasks,
    required this.batches,
    required this.dag,
    required this.size,
  });

  final bool ok;
  final List<PlanIssue> issues;
  final List<Map<String, Object?>> tasks;
  final List<PlanBatch> batches;
  final Map<String, Object?> dag;
  final Map<String, Object?> size;

  /// 第一条 error 的 code（没有 error ⇒ 空串）。
  String get code {
    for (final PlanIssue issue in issues) {
      if (issue.severity == 'error') return issue.code;
    }
    return '';
  }

  /// 第一条 error 的 message（没有 error ⇒ 空串）。
  String get message {
    for (final PlanIssue issue in issues) {
      if (issue.severity == 'error') return issue.message;
    }
    return '';
  }

  /// 第一条 error 的 taskId（没有 error / 空 id ⇒ 空列表）。
  List<String> get missing {
    for (final PlanIssue issue in issues) {
      if (issue.severity == 'error') {
        return issue.taskId.isEmpty ? const <String>[] : <String>[issue.taskId];
      }
    }
    return const <String>[];
  }
}

// ── 门控可执行性（PG-06）────────────────────────────────────────────

const Set<String> _kExecutables = <String>{
  'dart',
  'flutter',
  'npm',
  'pnpm',
  'yarn',
  'node',
  'python',
  'python3',
  'pytest',
  'go',
  'cargo',
  'mvn',
  'gradle',
  'make',
  'git',
  'bash',
  'sh',
  'pwsh',
  'powershell',
};

/// 命令首词是否属于已知可执行入口（允许 `.exe` / 路径前缀）。
bool _isExecutableCommand(String raw) {
  final String text = raw.trim();
  if (text.isEmpty) return false;
  final String first = text.split(RegExp(r'\s+')).first.toLowerCase();
  String name = first.replaceAll('\\', '/').split('/').last;
  name = name.replaceFirst(RegExp(r'\.(exe|cmd|bat|ps1)$'), '');
  return _kExecutables.contains(name);
}

const Set<String> _kHollowChecks = <String>{
  '通过',
  'ok',
  'good',
  'done',
  'check',
  '测试',
  '验收',
};

/// 去掉 `- [ ]` / `[x]` 标记后的可执行清单项（空话 ⇒ 空串）。
String _checklistText(String raw) {
  String text = raw.trim();
  text = text.replaceFirst(RegExp(r'^[-*+]\s*\[[ xX]\]\s*'), '');
  text = text.replaceFirst(RegExp(r'^\[[ xX]\]\s*'), '');
  text = text.trim();
  if (text.length < 3) return '';
  if (_kHollowChecks.contains(text.toLowerCase())) return '';
  return text;
}

bool _hasExecutableGate(Map<String, Object?> gate) {
  for (final String command in stringsOf(gate['commands'])) {
    if (_isExecutableCommand(command)) return true;
  }
  for (final String item in stringsOf(gate['checklist'])) {
    if (_checklistText(item).isNotEmpty) return true;
  }
  return false;
}

// ── 内部任务节点 ────────────────────────────────────────────────────

class _PlanNode {
  _PlanNode(Map<String, Object?> data)
    : data = data,
      id = textOf(data['id']),
      deps = <String>[];

  final Map<String, Object?> data;
  final String id;
  List<String> deps;

  String get title => textOf(data['title']);
  String get kind =>
      textOf(data['kind']).isEmpty ? 'conventional' : textOf(data['kind']);
  String get taskType => taskTypeOf(data['task_type']);
  List<String> get readScope => stringsOf(data['read_scope']);
  List<String> get writeScope => stringsOf(data['write_scope']);
  List<String> get acceptance => stringsOf(data['acceptance']);
  Map<String, Object?> get gate => plainMap(data['gate']);
  int get estimatedFiles => intOf(data['estimated_files'], 1);
  int get estimatedLines => intOf(data['estimated_lines'], 0);
  int get estimatedPackages => intOf(data['estimated_packages'], 0);
  String get risk => textOf(data['risk']);
  Object? get contract => plainValue(data['contract']);
  String get splitReason => textOf(data['split_reason']);
  String get rationale => textOf(data['rationale']);
}

// ── 主入口 ──────────────────────────────────────────────────────────

/// 校验并按 [fix] 做确定性修正；`fix=false` 时只校验、不改任务。
PlanValidation validateAndFixPlan({
  required List<Map<String, Object?>> tasks,
  Set<String> existingIds = const <String>{},
  int maxParallel = 1,
  bool fix = true,
}) {
  final List<Map<String, Object?>> input = <Map<String, Object?>>[
    for (final Map<String, Object?> item in tasks)
      <String, Object?>{...plainMap(item)},
  ];
  final List<_PlanNode> nodes = <_PlanNode>[
    for (final Map<String, Object?> item in input) _PlanNode(item),
  ];
  final List<PlanIssue> issues = <PlanIssue>[];
  final Set<String> mergedIds = <String>{};

  void report(
    String code,
    String taskId,
    String message, {
    String severity = 'error',
  }) {
    issues.add(
      PlanIssue(
        code: code,
        taskId: taskId,
        message: message,
        severity: severity,
      ),
    );
  }

  // 初始依赖：去掉自依赖与重复项；fix=false 时只报告、不改数据。
  for (final _PlanNode node in nodes) {
    final List<String> original = stringsOf(node.data['depends_on']);
    final List<String> unique = <String>[];
    final Set<String> seen = <String>{};
    bool duplicated = false;
    bool self = false;
    for (final String dependency in original) {
      if (dependency == node.id) {
        self = true;
        continue;
      }
      if (!seen.add(dependency)) {
        duplicated = true;
        continue;
      }
      unique.add(dependency);
    }
    if (duplicated) {
      report(
        'plan_dependency_duplicate',
        node.id,
        '任务 ${node.id} 的依赖有重复项，已去重',
        severity: 'warning',
      );
    }
    if (self) {
      report(
        'plan_self_dependency',
        node.id,
        '任务 ${node.id} 依赖自己，已去掉',
        severity: 'warning',
      );
    }
    node.deps = unique;
  }

  final Map<String, _PlanNode> byId = <String, _PlanNode>{
    for (final _PlanNode node in nodes)
      if (node.id.isNotEmpty) node.id: node,
  };

  // PG-03：缺依赖（本次计划或已存在任务都不含 ⇒ error）。
  for (final _PlanNode node in nodes) {
    final List<String> missing = <String>[];
    for (final String dependency in node.deps) {
      if (byId.containsKey(dependency) || existingIds.contains(dependency)) {
        continue;
      }
      missing.add(dependency);
    }
    if (missing.isNotEmpty) {
      report(
        'plan_dependency_missing',
        node.id,
        '任务 ${node.id} 依赖 ${missing.join('、')}，但它既不在本次计划也不是已存在任务',
      );
    }
  }

  // PG-03：环（Kahn + DFS 找一条环路径）。
  final List<String>? cycle = _findCycle(byId);
  if (cycle != null) {
    report('plan_cycle', cycle.first, '计划依赖成环：${cycle.join(' → ')}');
  }

  // PG-04：尺寸检查与自动拆分。
  if (fix) {
    _splitOversize(nodes, byId, report);
  } else {
    for (final _PlanNode node in nodes) {
      if (node.estimatedFiles < 1 || node.estimatedFiles > 5) {
        report(
          'plan_task_oversize',
          node.id,
          '任务 ${node.id} 预计 ${node.estimatedFiles} 个文件，超出 1–5',
        );
      }
      if (node.estimatedLines > 300 && node.splitReason.isEmpty) {
        report(
          'plan_task_oversize',
          node.id,
          '任务 ${node.id} 预计 ${node.estimatedLines} 改动行，超过 300 且没有 split_reason',
        );
      }
      if (node.estimatedPackages > 1 && node.splitReason.isEmpty) {
        report(
          'plan_task_oversize',
          node.id,
          '任务 ${node.id} 预计 ${node.estimatedPackages} 个包，超过 1 且没有 split_reason',
        );
      }
    }
  }

  // 微任务合并（只在 fix 时做；合并后重新检查尺寸）。
  if (fix) {
    _mergeMicroTasks(nodes, byId, report, mergedIds);
    for (final _PlanNode node in nodes) {
      if (!mergedIds.contains(node.id)) continue;
      if (node.estimatedFiles > 5) {
        report(
          'plan_task_oversize',
          node.id,
          '任务 ${node.id} 合并后预计 ${node.estimatedFiles} 个文件，超出 5',
        );
      }
      if (node.estimatedLines > 300 && node.splitReason.isEmpty) {
        report(
          'plan_task_oversize',
          node.id,
          '任务 ${node.id} 合并后预计 ${node.estimatedLines} 改动行，超过 300 且没有 split_reason',
        );
      }
      if (node.estimatedPackages > 1 && node.splitReason.isEmpty) {
        report(
          'plan_task_oversize',
          node.id,
          '任务 ${node.id} 合并后预计 ${node.estimatedPackages} 个包，超过 1 且没有 split_reason',
        );
      }
    }
  }

  // PG-05：写域交叠且互不可达 ⇒ 串行或报错。
  final List<String> sortedIds = byId.keys.toList()..sort();
  for (int i = 0; i < sortedIds.length; i++) {
    for (int j = i + 1; j < sortedIds.length; j++) {
      final _PlanNode first = byId[sortedIds[i]]!;
      final _PlanNode later = byId[sortedIds[j]]!;
      if (!writeScopesOverlap(first.writeScope, later.writeScope)) continue;
      if (_reaches(first.id, later.id, byId) ||
          _reaches(later.id, first.id, byId)) {
        continue;
      }
      if (!fix) {
        report(
          'plan_scope_overlap',
          later.id,
          '任务 ${later.id} 与 ${first.id} 写域交叠，且依赖图上互不可达',
        );
        continue;
      }
      if (!later.deps.contains(first.id)) {
        later.deps = <String>[...later.deps, first.id];
      }
      report(
        'plan_scope_serialized',
        later.id,
        '任务 ${later.id} 与 ${first.id} 写域交叠，已加依赖串行',
        severity: 'warning',
      );
    }
  }

  // PG-06：每任务至少一个可执行门控。
  for (final _PlanNode node in nodes) {
    if (!_hasExecutableGate(node.gate)) {
      report(
        'plan_gate_missing',
        node.id,
        '任务 ${node.id} 没有可执行门控（gate.commands 或非空话 gate.checklist）',
      );
    }
  }

  // PG-07：多个 code 任务必须有覆盖全部代码任务的 integration 任务。
  final List<String> codeIds = <String>[
    for (final _PlanNode node in nodes)
      if (node.taskType == 'code') node.id,
  ];
  if (codeIds.length > 1) {
    final List<_PlanNode> integrations = <_PlanNode>[
      for (final _PlanNode node in nodes)
        if (node.taskType == 'integration') node,
    ];
    bool covered = false;
    for (final _PlanNode integration in integrations) {
      final Set<String> closure = _transitiveDeps(integration.id, byId);
      if (codeIds.every(closure.contains)) {
        covered = true;
        break;
      }
    }
    if (!covered) {
      final List<String> uncovered = <String>[
        for (final String id in codeIds)
          if (!integrations.any(
            (_PlanNode node) => _transitiveDeps(node.id, byId).contains(id),
          ))
            id,
      ];
      report(
        'plan_integration_missing',
        codeIds.first,
        '有 ${codeIds.length} 个 code 任务但缺少覆盖全部代码任务的 integration 任务'
            '${uncovered.isEmpty ? '' : '（未覆盖：${uncovered.join('、')}）'}',
      );
    }
  }

  // 字段合法性：task_type / title / acceptance。
  for (final _PlanNode node in nodes) {
    final String rawType = textOf(node.data['task_type']);
    if (rawType.isNotEmpty && !kTaskTypes.contains(rawType)) {
      report(
        'plan_task_type_invalid',
        node.id,
        '任务 ${node.id} 的 task_type 只能是 ${kTaskTypes.join(' / ')}：$rawType',
      );
    }
    if (node.title.isEmpty) {
      report('plan_incomplete', node.id, '任务 ${node.id} 缺 title');
    }
    if (node.acceptance.isEmpty) {
      report('plan_incomplete', node.id, '任务 ${node.id} 缺验收判据（acceptance）');
    }
  }

  // 写回规范化字段（仅 fix=true）。
  if (fix) {
    for (final _PlanNode node in nodes) {
      node.data['depends_on'] = node.deps;
      node.data['task_type'] = node.taskType;
      node.data['gate'] = node.gate;
      node.data['estimated_files'] = node.estimatedFiles;
      node.data['estimated_lines'] = node.estimatedLines;
      node.data['estimated_packages'] = node.estimatedPackages;
      node.data['risk'] = node.risk;
      node.data['contract'] = node.contract;
      node.data['split_reason'] = node.splitReason;
      node.data['rationale'] = node.rationale;
    }
  }

  final List<Map<String, Object?>> output = <Map<String, Object?>>[
    for (final _PlanNode node in nodes) node.data,
  ];
  final ({List<List<String>> waves, Map<String, Object?> edges}) dag =
      _buildDag(byId);
  final List<PlanBatch> batches = _buildBatches(
    output,
    dag.waves,
    maxParallel: maxParallel,
  );
  final Map<String, Object?> size = <String, Object?>{
    for (final _PlanNode node in nodes)
      node.id: <String, Object?>{
        'files': node.estimatedFiles,
        'lines': node.estimatedLines,
        'packages': node.estimatedPackages,
      },
  };
  return PlanValidation(
    ok: !issues.any((PlanIssue issue) => issue.severity == 'error'),
    issues: issues,
    tasks: output,
    batches: batches,
    dag: <String, Object?>{'waves': dag.waves, 'edges': dag.edges},
    size: size,
  );
}

// ── PG-04 自动拆分 ──────────────────────────────────────────────────

void _splitOversize(
  List<_PlanNode> nodes,
  Map<String, _PlanNode> byId,
  void Function(String code, String taskId, String message, {String severity})
  report,
) {
  for (int index = 0; index < nodes.length; index++) {
    final _PlanNode node = nodes[index];
    final int files = node.estimatedFiles;
    if (files >= 1 && files <= 5) {
      if (node.estimatedLines > 300 && node.splitReason.isEmpty) {
        report(
          'plan_task_oversize',
          node.id,
          '任务 ${node.id} 预计 ${node.estimatedLines} 改动行，超过 300 且没有 split_reason',
        );
      }
      if (node.estimatedPackages > 1 && node.splitReason.isEmpty) {
        report(
          'plan_task_oversize',
          node.id,
          '任务 ${node.id} 预计 ${node.estimatedPackages} 个包，超过 1 且没有 split_reason',
        );
      }
      continue;
    }
    if (files < 1) {
      report(
        'plan_task_oversize',
        node.id,
        '任务 ${node.id} 预计 $files 个文件，超出 1–5',
      );
      continue;
    }
    if (node.estimatedLines > 300 && node.splitReason.isEmpty) {
      report(
        'plan_task_oversize',
        node.id,
        '任务 ${node.id} 预计 ${node.estimatedLines} 改动行，超过 300 且没有 split_reason',
      );
    }
    if (node.estimatedPackages > 1 && node.splitReason.isEmpty) {
      report(
        'plan_task_oversize',
        node.id,
        '任务 ${node.id} 预计 ${node.estimatedPackages} 个包，超过 1 且没有 split_reason',
      );
    }
    final int slices = (files + 4) ~/ 5;
    final List<Map<String, Object?>> split = _splitSlices(node, slices, byId);
    // 原 id 的所有依赖者改依赖最后一片。
    final String lastId = textOf(split.last['id']);
    for (final _PlanNode other in nodes) {
      if (identical(other, node)) continue;
      bool changed = false;
      final List<String> deps = <String>[];
      for (final String dependency in other.deps) {
        if (dependency == node.id) {
          if (!deps.contains(lastId)) deps.add(lastId);
          changed = true;
        } else if (!deps.contains(dependency)) {
          deps.add(dependency);
        }
      }
      if (changed) other.deps = deps;
    }
    final _PlanNode first = _PlanNode(split.first);
    nodes[index] = first;
    byId.remove(node.id);
    byId[first.id] = first;
    for (int i = 1; i < split.length; i++) {
      final _PlanNode extra = _PlanNode(split[i]);
      nodes.insert(index + i, extra);
      byId[extra.id] = extra;
    }
    // 拆分后逐片复核尺寸。
    for (final Map<String, Object?> slice in split) {
      final _PlanNode check = _PlanNode(slice);
      if (check.estimatedFiles < 1 || check.estimatedFiles > 5) {
        report(
          'plan_task_oversize',
          check.id,
          '任务 ${check.id} 拆分后仍预计 ${check.estimatedFiles} 个文件，超出 1–5',
        );
      }
      if (check.estimatedLines > 300) {
        report(
          'plan_task_oversize',
          check.id,
          '任务 ${check.id} 拆分后仍预计 ${check.estimatedLines} 改动行，超过 300',
        );
      }
      if (check.estimatedPackages > 1) {
        report(
          'plan_task_oversize',
          check.id,
          '任务 ${check.id} 拆分后仍预计 ${check.estimatedPackages} 个包，超过 1',
        );
      }
    }
    report(
      'plan_task_split',
      node.id,
      '任务 ${node.id} 预计 $files 个文件，超过 5，已拆为 $slices 片',
      severity: 'warning',
    );
    index += split.length - 1;
  }
}

List<Map<String, Object?>> _splitSlices(
  _PlanNode node,
  int slices,
  Map<String, _PlanNode> byId,
) {
  final List<Map<String, Object?>> out = <Map<String, Object?>>[];
  final Set<String> used = <String>{
    for (final _PlanNode other in byId.values) other.id,
  };
  String idFor(int index) {
    final String base = '${node.id}-$index';
    String candidate = base;
    int suffix = 2;
    while (used.contains(candidate)) {
      candidate = '$base-$suffix';
      suffix++;
    }
    used.add(candidate);
    return candidate;
  }

  final List<String> ids = <String>[for (int i = 1; i <= slices; i++) idFor(i)];
  final int files = node.estimatedFiles;
  final int lines = node.estimatedLines;
  final int packages = node.estimatedPackages;
  for (int i = 0; i < slices; i++) {
    final int takeFiles = i == slices - 1 ? files - 5 * (slices - 1) : 5;
    final int takeLines = lines == 0
        ? 0
        : lines ~/ slices + (i < lines % slices ? 1 : 0);
    final int takePackages = packages == 0
        ? 0
        : packages ~/ slices + (i < packages % slices ? 1 : 0);
    final List<String> deps = i == 0
        ? <String>[...node.deps]
        : <String>[ids[i - 1]];
    out.add(<String, Object?>{
      ...node.data,
      'id': ids[i],
      'title': '${node.title}（拆分 ${i + 1}/$slices）',
      'depends_on': deps,
      'estimated_files': takeFiles,
      'estimated_lines': takeLines,
      'estimated_packages': takePackages,
    });
  }
  return out;
}

// ── 微任务合并 ──────────────────────────────────────────────────────

void _mergeMicroTasks(
  List<_PlanNode> nodes,
  Map<String, _PlanNode> byId,
  void Function(String code, String taskId, String message, {String severity})
  report,
  Set<String> mergedIds,
) {
  bool merged = true;
  while (merged) {
    merged = false;
    final List<String> ids = byId.keys.toList()..sort();
    for (final String bId in ids) {
      final _PlanNode? later = byId[bId];
      if (later == null) continue;
      if (later.deps.length != 1) continue;
      final String aId = later.deps.single;
      final _PlanNode? first = byId[aId];
      if (first == null) continue;
      // A 只被 B 依赖。
      final bool otherDependent = nodes.any(
        (_PlanNode node) => node.id != later.id && node.deps.contains(aId),
      );
      if (otherDependent) continue;
      if (later.estimatedFiles > 1 || later.estimatedLines > 20) continue;
      if (first.taskType != later.taskType) continue;
      if (!_sameScope(first.writeScope, later.writeScope)) continue;

      final List<String> acceptance = <String>[...first.acceptance];
      for (final String item in later.acceptance) {
        if (!acceptance.contains(item)) acceptance.add(item);
      }
      final Map<String, Object?> gate = <String, Object?>{
        ...first.gate,
        'commands': _union(
          stringsOf(first.gate['commands']),
          stringsOf(later.gate['commands']),
        ),
        'checklist': _union(
          stringsOf(first.gate['checklist']),
          stringsOf(later.gate['checklist']),
        ),
      };
      first.data
        ..['acceptance'] = acceptance
        ..['gate'] = gate
        ..['estimated_files'] = first.estimatedFiles + later.estimatedFiles
        ..['estimated_lines'] = first.estimatedLines + later.estimatedLines
        ..['estimated_packages'] =
            first.estimatedPackages + later.estimatedPackages
        ..['depends_on'] = first.deps;
      // B 的依赖者改指 A。
      for (final _PlanNode node in nodes) {
        if (node.id == later.id) continue;
        if (!node.deps.contains(later.id)) continue;
        final List<String> next = <String>[];
        for (final String dependency in node.deps) {
          final String value = dependency == later.id ? aId : dependency;
          if (!next.contains(value)) next.add(value);
        }
        node.deps = next;
      }
      nodes.removeWhere((_PlanNode node) => node.id == later.id);
      byId.remove(later.id);
      mergedIds.add(aId);
      report(
        'plan_task_merged',
        later.id,
        '任务 ${later.id} 是微任务且只依赖 ${first.id}，已并入 ${first.id}',
        severity: 'warning',
      );
      merged = true;
      break;
    }
  }
}

List<String> _union(List<String> a, List<String> b) => <String>[
  ...a,
  for (final String item in b)
    if (!a.contains(item)) item,
];

bool _sameScope(List<String> a, List<String> b) {
  final Set<String> left = <String>{
    for (final String item in a) _normalizeScope(item),
  }..remove('');
  final Set<String> right = <String>{
    for (final String item in b) _normalizeScope(item),
  }..remove('');
  if (left.length != right.length) return false;
  return left.containsAll(right);
}

String _normalizeScope(String value) {
  String text = normalizeRelPath(value);
  while (text.endsWith('/')) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}

// ── DAG 工具 ────────────────────────────────────────────────────────

List<String>? _findCycle(Map<String, _PlanNode> byId) {
  final Map<String, int> state = <String, int>{};
  final List<String> stack = <String>[];
  List<String>? cycle;

  void visit(String id) {
    if (cycle != null) return;
    state[id] = 1;
    stack.add(id);
    final _PlanNode? node = byId[id];
    for (final String dependency in node?.deps ?? const <String>[]) {
      if (!byId.containsKey(dependency)) continue;
      final int mark = state[dependency] ?? 0;
      if (mark == 1) {
        final int start = stack.indexOf(dependency);
        cycle = <String>[...stack.sublist(start), dependency];
        return;
      }
      if (mark == 0) visit(dependency);
      if (cycle != null) return;
    }
    stack.removeLast();
    state[id] = 2;
  }

  final List<String> ids = byId.keys.toList()..sort();
  for (final String id in ids) {
    if ((state[id] ?? 0) == 0) visit(id);
    if (cycle != null) break;
  }
  return cycle;
}

bool _reaches(String from, String target, Map<String, _PlanNode> byId) {
  final Set<String> seen = <String>{};
  final List<String> pending = <String>[from];
  while (pending.isNotEmpty) {
    final String id = pending.removeLast();
    if (id == target) return true;
    if (!seen.add(id)) continue;
    final _PlanNode? node = byId[id];
    for (final String dependency in node?.deps ?? const <String>[]) {
      if (byId.containsKey(dependency)) pending.add(dependency);
    }
  }
  return false;
}

Set<String> _transitiveDeps(String id, Map<String, _PlanNode> byId) {
  final Set<String> out = <String>{};
  final List<String> pending = <String>[
    ...(byId[id]?.deps ?? const <String>[]),
  ];
  while (pending.isNotEmpty) {
    final String dependency = pending.removeLast();
    if (!out.add(dependency)) continue;
    pending.addAll(byId[dependency]?.deps ?? const <String>[]);
  }
  return out;
}

({List<List<String>> waves, Map<String, Object?> edges}) _buildDag(
  Map<String, _PlanNode> byId,
) {
  final Map<String, int> indegree = <String, int>{};
  final Map<String, List<String>> dependents = <String, List<String>>{};
  for (final String id in byId.keys) {
    indegree[id] = 0;
    dependents[id] = <String>[];
  }
  for (final _PlanNode node in byId.values) {
    for (final String dependency in node.deps) {
      if (!byId.containsKey(dependency)) continue;
      indegree[node.id] = (indegree[node.id] ?? 0) + 1;
      dependents[dependency]!.add(node.id);
    }
  }
  final List<List<String>> waves = <List<String>>[];
  final Set<String> done = <String>{};
  while (true) {
    final List<String> wave = <String>[
      for (final MapEntry<String, int> entry in indegree.entries)
        if (!done.contains(entry.key) && entry.value == 0) entry.key,
    ]..sort();
    if (wave.isEmpty) break;
    waves.add(wave);
    for (final String id in wave) {
      done.add(id);
      for (final String dependent in dependents[id] ?? const <String>[]) {
        indegree[dependent] = (indegree[dependent] ?? 1) - 1;
      }
    }
  }
  // 有环时剩余的节点也放进最后一波，保证批次覆盖全部任务。
  final List<String> left = <String>[
    for (final MapEntry<String, int> entry in indegree.entries)
      if (!done.contains(entry.key)) entry.key,
  ]..sort();
  if (left.isNotEmpty) waves.add(left);
  return (
    waves: waves,
    edges: <String, Object?>{
      for (final _PlanNode node in byId.values) node.id: node.deps,
    },
  );
}

List<PlanBatch> _buildBatches(
  List<Map<String, Object?>> tasks,
  List<List<String>> waves, {
  required int maxParallel,
}) {
  final int limit = maxParallel < 1 ? 1 : maxParallel;
  final Map<String, Map<String, Object?>> byId = <String, Map<String, Object?>>{
    for (final Map<String, Object?> task in tasks) textOf(task['id']): task,
  };
  final List<PlanBatch> batches = <PlanBatch>[];
  int index = 0;
  for (int wave = 0; wave < waves.length; wave++) {
    final List<String> ids = List<String>.of(waves[wave])..sort();
    List<String> current = <String>[];
    for (final String id in ids) {
      final Map<String, Object?> task = byId[id] ?? const <String, Object?>{};
      final List<String> scope = stringsOf(task['write_scope']);
      final bool conflict = current.any((String peer) {
        final Map<String, Object?> other =
            byId[peer] ?? const <String, Object?>{};
        return writeScopesOverlap(scope, stringsOf(other['write_scope']));
      });
      if (current.isEmpty || (!conflict && current.length < limit)) {
        current.add(id);
        continue;
      }
      index += 1;
      batches.add(PlanBatch(index: index, wave: wave + 1, taskIds: current));
      current = <String>[id];
    }
    if (current.isNotEmpty) {
      index += 1;
      batches.add(PlanBatch(index: index, wave: wave + 1, taskIds: current));
    }
  }
  return batches;
}
