/// 任务输入预检（TG-01 / AG-05）与编辑字段规范化。
///
/// 口径（`docs/pluginization/production-line-gates.md` §5.1 / §8，产品形态 §6.0）：
/// - 非 cleanup 任务派发前必须有 `brief`（或 `intake.goal`）与至少一条 `acceptance`；
/// - 附件只登记元数据（`path/sha256/size/type/kind`），文件通道在 Task 6；
/// - 依赖必须存在；`write_scope` 不能是显式 `null`；
/// - 项目文档默认只读：非 docs / cleanup 任务的写域不得触碰 `docs/**`；
///   docs 任务必须显式给出只包含 `docs/**` 或根 `*.md` / `README*` 的写域，
///   不允许 `**`。
///
/// 这一层只做纯判定，不读盘、不写盘；旧任务读取不经过这里（保持兼容）。
library;

import 'execution.dart' show matchesWriteScope, normalizeRelPath;
import 'models.dart';

/// 可通过 `production.task.update` 编辑的字段（固定白名单）。
const Set<String> kTaskEditFields = <String>{
  'brief',
  'acceptance',
  'references',
  'attachments',
  'depends_on',
  'write_scope',
  'read_scope',
  'conflicts_with',
  'serial_group',
  'priority',
  'estimated_files',
  'risk',
  'contract',
  'rationale',
};

/// `running` / `gating` / `packing` 只允许改这两个字段（其余必须等任务停）。
const Set<String> kInFlightEditFields = <String>{'priority', 'depends_on'};

/// 一条预检问题（字段 + 错误码 + 可读原因）。
class TaskInputIssue {
  const TaskInputIssue(this.code, this.field, this.message);

  final String code;
  final String field;
  final String message;

  Map<String, Object?> toJson() => <String, Object?>{
    'code': code,
    'field': field,
    'message': message,
  };
}

/// 一次任务输入预检的结果。
class TaskInputCheck {
  const TaskInputCheck(this.issues);

  final List<TaskInputIssue> issues;

  bool get ok => issues.isEmpty;
  String get code => issues.isEmpty ? '' : issues.first.code;
  List<String> get missing => <String>[
    for (final TaskInputIssue issue in issues) issue.field,
  ];
  String get message =>
      issues.map((TaskInputIssue issue) => issue.message).join('；');

  ProductionFailure toFailure() => ProductionFailure(
    message,
    code: code,
    missing: missing,
  );

  List<Map<String, Object?>> toJson() => <Map<String, Object?>>[
    for (final TaskInputIssue issue in issues) issue.toJson(),
  ];
}

/// 写域是否可能触碰 `docs/**`（保守判定：拿不准就算触碰）。
bool scopeTouchesDocs(String raw) {
  final String scope = normalizeRelPath(raw);
  if (scope.isEmpty) return false;
  if (scope == 'docs' || scope.startsWith('docs/')) return true;
  // 通配规则：只要它能匹配 docs 目录或 docs 下的探针路径，就算触碰。
  return matchesWriteScope('docs', scope) ||
      matchesWriteScope('docs/probe.md', scope) ||
      matchesWriteScope('docs/probe/nested.md', scope);
}

/// docs 任务允许的写域：`docs/**`（或 docs 下具体路径）、根 `*.md`、根 `README*`。
bool isDocsTaskScope(String raw) {
  final String scope = normalizeRelPath(raw);
  if (scope.isEmpty) return false;
  if (!isSafeRelativeTaskPath(scope)) return false;
  if (scope == '**' || scope == '*') return false;
  if (scope == 'docs' || scope.startsWith('docs/')) return true;
  if (scope == '*.md') return true;
  if (!scope.contains('/') && scope.startsWith('README')) return true;
  return false;
}

/// 预检任务输入。
///
/// [fields] 为 `null` 时检查全部维度（创建任务）；编辑时传 patch 的键，
/// 只检查本次改动的维度（避免旧任务因为历史缺字段而无法改优先级）。
/// [requireContent]：`queued` 任务为 true；草稿 / 准备态为 false（允许先存后补）。
TaskInputCheck checkTaskInputMap(
  Map<String, Object?> data, {
  required Map<String, TaskStatus> statuses,
  bool requireContent = true,
  String selfId = '',
  Set<String>? fields,
}) {
  final bool checkAll = fields == null;
  bool want(String field) => checkAll || fields.contains(field);
  final List<TaskInputIssue> issues = <TaskInputIssue>[];
  void add(String code, String field, String message) =>
      issues.add(TaskInputIssue(code, field, message));

  final String taskType = taskTypeOf(data['task_type']);
  final String title = textOf(data['title']);
  if (title.isEmpty) {
    add('task_input_incomplete', 'title', '任务缺 title');
  }
  if (checkAll && !kTaskTypes.contains(taskType)) {
    add(
      'task_input_incomplete',
      'task_type',
      '任务 task_type 只能是 ${kTaskTypes.join(' / ')}：$taskType',
    );
  }

  // 内容 / 验收：派发前必填；cleanup 也必须至少一条验收。
  if (requireContent && (checkAll || want('brief') || want('acceptance'))) {
    final Map<String, Object?> intake = plainMap(data['intake']);
    final bool hasBrief =
        textOf(data['brief']).isNotEmpty || textOf(intake['goal']).isNotEmpty;
    if (taskType != 'cleanup' && !hasBrief) {
      add(
        'task_input_incomplete',
        'brief',
        '任务还没有内容：brief（或 intake.goal）不能为空',
      );
    }
    if (stringsOf(data['acceptance']).isEmpty) {
      add(
        'task_input_incomplete',
        'acceptance',
        '至少写一条可判定的 acceptance',
      );
    }
  } else if (taskType == 'cleanup' &&
      (checkAll || want('acceptance'))) {
    if (stringsOf(data['acceptance']).isEmpty) {
      add('task_input_incomplete', 'acceptance', 'cleanup 任务必须给出至少一条 acceptance');
    }
  }

  if (checkAll || want('attachments')) {
    try {
      normalizeAttachments(data['attachments']);
    } on ProductionFailure catch (error) {
      add(
        error.code,
        error.missing.isEmpty ? 'attachments' : error.missing.first,
        error.message,
      );
    }
  }

  if (checkAll || want('depends_on')) {
    final Object? raw = data['depends_on'];
    if (raw != null && raw is! List) {
      add('task_input_incomplete', 'depends_on', 'depends_on 必须是数组');
    } else {
      final List<String> deps = stringsOf(raw);
      if (raw is List && deps.length != raw.length) {
        add('task_input_incomplete', 'depends_on', 'depends_on 里有空项');
      }
      final Set<String> seen = <String>{};
      for (final String dependency in deps) {
        if (dependency == selfId) {
          add('task_input_incomplete', 'depends_on', '任务不能依赖自己：$dependency');
          continue;
        }
        if (!seen.add(dependency)) {
          add('task_input_incomplete', 'depends_on', '依赖重复：$dependency');
          continue;
        }
        if (!statuses.containsKey(dependency)) {
          add(
            'task_dependency_missing',
            'depends_on:$dependency',
            '依赖不存在：$dependency（先建它，或从 depends_on 移除）',
          );
        }
      }
    }
  }

  if (checkAll || want('references')) {
    final Object? raw = data['references'];
    if (raw != null && raw is! List) {
      add('task_input_incomplete', 'references', 'references 必须是数组');
    } else if (raw is List) {
      for (final Object? item in raw) {
        final String reference = textOf(item);
        if (!isSafeRelativeTaskPath(reference)) {
          add(
            'task_input_incomplete',
            'references',
            '引用必须是工作空间相对路径：$reference',
          );
        }
      }
    }
  }

  if (checkAll || want('write_scope')) {
    final Object? raw = data['write_scope'];
    final bool required =
        requireContent || taskType == 'docs' || taskType == 'cleanup';
    if (raw == null) {
      if (taskType == 'docs') {
        add(
          'docs_scope_required',
          'write_scope',
          'docs 任务必须显式给出写域，且只能包含 docs/** 或根 *.md / README*',
        );
      } else if (required) {
        add(
          'task_input_incomplete',
          'write_scope',
          'write_scope 不能为 null：请显式给出写域（空写域会被当作工作空间根）',
        );
      }
    } else if (raw is! List) {
      add('task_input_incomplete', 'write_scope', 'write_scope 必须是数组');
    } else {
      final List<String> scopes = stringsOf(raw);
      if (scopes.length != raw.length) {
        add('task_input_incomplete', 'write_scope', 'write_scope 里有空项');
      }
      if (scopes.isEmpty && !required) {
        // 草稿允许先不写范围。
      } else if (taskType == 'docs') {
        if (scopes.isEmpty) {
          add(
            'docs_scope_required',
            'write_scope',
            'docs 任务必须显式给出写域，且只能包含 docs/** 或根 *.md / README*',
          );
        } else {
          for (final String scope in scopes) {
            if (isDocsTaskScope(scope)) continue;
            add(
              'docs_scope_forbidden',
              'write_scope',
              'docs 任务只能写 docs/** 或根 *.md / README*，不允许 $scope',
            );
          }
        }
      } else if (taskType != 'cleanup') {
        for (final String scope in resolveWriteScope(raw)) {
          if (!scopeTouchesDocs(scope)) continue;
          add(
            'docs_scope_forbidden',
            'write_scope',
            '项目文档默认只读：$taskType 任务写域不能触碰 docs/**（$scope）；'
            '需要改文档请单独建 docs 任务',
          );
        }
      }
    }
  }

  if (checkAll || want('estimated_files')) {
    final Object? raw = data['estimated_files'];
    if (raw != null) {
      final int? value = raw is num
          ? raw.toInt()
          : int.tryParse(textOf(raw));
      if (value == null || value < 0) {
        add(
          'task_input_incomplete',
          'estimated_files',
          'estimated_files 必须是非负整数：$raw',
        );
      }
    }
  }

  if (checkAll || want('risk')) {
    final String risk = textOf(data['risk']);
    if (risk.isNotEmpty && !kTaskRisks.contains(risk)) {
      add(
        'task_input_incomplete',
        'risk',
        'risk 只能是 ${kTaskRisks.join(' / ')}：$risk',
      );
    }
  }

  if (checkAll || want('conflicts_with')) {
    final Object? raw = data['conflicts_with'];
    if (raw != null && raw is! List) {
      add('task_input_incomplete', 'conflicts_with', 'conflicts_with 必须是数组');
    } else {
      for (final String conflict in stringsOf(raw)) {
        if (conflict == selfId) {
          add('task_input_incomplete', 'conflicts_with', '任务不能与自己冲突');
        }
      }
    }
  }

  if (checkAll || want('priority')) {
    final Object? raw = data['priority'];
    if (raw != null && raw is! num && int.tryParse(textOf(raw)) == null) {
      add('task_input_incomplete', 'priority', 'priority 必须是整数：$raw');
    }
  }

  return TaskInputCheck(issues);
}

/// 把编辑 patch 规范化成可落盘的 `task.yaml` 字段（未给出的键不产生变更）。
Map<String, Object?> normalizeTaskEdit(Map<String, Object?> patch) {
  final Map<String, Object?> out = <String, Object?>{};
  if (patch.containsKey('brief')) out['brief'] = textOf(patch['brief']);
  if (patch.containsKey('acceptance')) {
    out['acceptance'] = stringsOf(patch['acceptance']);
  }
  if (patch.containsKey('references')) {
    out['references'] = stringsOf(patch['references']);
  }
  if (patch.containsKey('attachments')) {
    out['attachments'] = normalizeAttachments(patch['attachments']);
  }
  if (patch.containsKey('depends_on')) {
    out['depends_on'] = stringsOf(patch['depends_on']);
  }
  if (patch.containsKey('write_scope')) {
    out['write_scope'] = resolveWriteScope(patch['write_scope']);
  }
  if (patch.containsKey('read_scope')) {
    out['read_scope'] = stringsOf(patch['read_scope']);
  }
  if (patch.containsKey('conflicts_with')) {
    out['conflicts_with'] = stringsOf(patch['conflicts_with']);
  }
  if (patch.containsKey('serial_group')) {
    out['serial_group'] = textOf(patch['serial_group']);
  }
  if (patch.containsKey('priority')) {
    out['priority'] = intOf(patch['priority'], 50);
  }
  if (patch.containsKey('estimated_files')) {
    out['estimated_files'] = intOf(patch['estimated_files'], 1);
  }
  if (patch.containsKey('risk')) out['risk'] = textOf(patch['risk']);
  if (patch.containsKey('contract')) {
    out['contract'] = plainValue(patch['contract']);
  }
  if (patch.containsKey('rationale')) {
    out['rationale'] = textOf(patch['rationale']);
  }
  return out;
}

/// 把 `references` 自动并入 `read_scope`（保序去重）。
List<String> mergeReadScope(List<String> readScope, List<String> references) {
  final List<String> merged = <String>[...readScope];
  for (final String reference in references) {
    if (!merged.contains(reference)) merged.add(reference);
  }
  return merged;
}
