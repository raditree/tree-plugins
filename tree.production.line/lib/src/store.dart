/// 产线数据根的单写者：`<data_root>/production_lines/<team_id>/<line_id>/`。
///
/// 布局（§7.1）：
/// ```text
/// line.yaml
/// tasks/<task_id>/task.yaml       # 唯一真值
/// runs/<run_id>.json              # 运行台账
/// inbox.jsonl                     # 决策台账（P1 只建空文件）
/// state.json                      # 队列索引快照（可由 task.yaml 重建）
/// ```
///
/// 所有写入走“临时文件 + 改名”；`state.json` 内容未变时不写盘（rebuild 幂等）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'models.dart';
import 'queue.dart';
import 'yaml_codec.dart';

class ProductionStore {
  ProductionStore({
    required this.dataRoot,
    required this.teamId,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final String dataRoot;
  final String teamId;
  final DateTime Function() _clock;

  static int _tempSeq = 0;
  static final RegExp _segmentPattern = RegExp(r'^[A-Za-z0-9_.-]+$');

  String get teamDir =>
      p.join(dataRoot, 'production_lines', _segment(teamId, 'team_id'));

  String lineDir(String lineId) =>
      p.join(teamDir, _segment(lineId, 'line_id'));

  String _lineFile(String lineId) => p.join(lineDir(lineId), 'line.yaml');
  String _stateFile(String lineId) => p.join(lineDir(lineId), 'state.json');
  String _tasksDir(String lineId) => p.join(lineDir(lineId), 'tasks');
  String _runsDir(String lineId) => p.join(lineDir(lineId), 'runs');

  String _taskFile(String lineId, String taskId) => p.join(
    _tasksDir(lineId),
    _segment(taskId, 'task_id'),
    'task.yaml',
  );

  String nowText() => _clock().toIso8601String();

  // ── 产线 ──────────────────────────────────────────────────────────

  LineRecord createLine(Map<String, Object?> input) {
    final String now = nowText();
    final String rawId = textOf(input['id']);
    final String id = rawId.isEmpty
        ? 'pl_${_clock().millisecondsSinceEpoch}'
        : _segment(rawId, 'line_id');
    if (textOf(input['name']).isEmpty) {
      throw ProductionFailure(
        'production.line.create 需要 name',
        code: 'invalid_arguments',
      );
    }
    if (File(_lineFile(id)).existsSync()) {
      throw ProductionFailure('产线已存在：$id', code: 'line_exists');
    }
    final Map<String, Object?> data = buildLineMap(input, id: id, now: now);
    _writeText(File(_lineFile(id)), encodeYaml(data));
    Directory(_tasksDir(id)).createSync(recursive: true);
    Directory(_runsDir(id)).createSync(recursive: true);
    final File inbox = File(p.join(lineDir(id), 'inbox.jsonl'));
    if (!inbox.existsSync()) _writeText(inbox, '');
    rebuild(id);
    return LineRecord(data);
  }

  List<LineRecord> listLines() {
    final Directory dir = Directory(teamDir);
    if (!dir.existsSync()) return <LineRecord>[];
    final List<LineRecord> lines = <LineRecord>[];
    for (final FileSystemEntity entity in dir.listSync()) {
      if (entity is! Directory) continue;
      final File file = File(p.join(entity.path, 'line.yaml'));
      if (!file.existsSync()) continue;
      lines.add(LineRecord(_readYaml(file, 'line.yaml')));
    }
    lines.sort((LineRecord a, LineRecord b) {
      final int byCreated = a.createdAt.compareTo(b.createdAt);
      return byCreated != 0 ? byCreated : a.id.compareTo(b.id);
    });
    return lines;
  }

  LineRecord getLine(String lineId) {
    final File file = File(_lineFile(lineId));
    if (!file.existsSync()) {
      throw ProductionFailure('产线不存在：$lineId', code: 'not_found');
    }
    return LineRecord(_readYaml(file, 'line.yaml'));
  }

  // ── 任务 ──────────────────────────────────────────────────────────

  TaskRecord createTask(String lineId, Map<String, Object?> input) {
    getLine(lineId);
    final String id = _segment(textOf(input['id']), 'task_id');
    final File file = File(_taskFile(lineId, id));
    if (file.existsSync()) {
      throw ProductionFailure('任务已存在：$id', code: 'task_exists');
    }
    final Map<String, Object?> data = buildTaskMap(
      input,
      id: id,
      now: nowText(),
    );
    _writeText(file, encodeYaml(data));
    rebuild(lineId);
    return TaskRecord(data);
  }

  List<TaskRecord> listTasks(String lineId) {
    final Directory dir = Directory(_tasksDir(lineId));
    if (!dir.existsSync()) return <TaskRecord>[];
    final List<TaskRecord> tasks = <TaskRecord>[];
    for (final FileSystemEntity entity in dir.listSync()) {
      if (entity is! Directory) continue;
      final File file = File(p.join(entity.path, 'task.yaml'));
      if (!file.existsSync()) continue;
      final Map<String, Object?> data = _readYaml(file, 'task.yaml');
      if (textOf(data['id']).isEmpty) data['id'] = p.basename(entity.path);
      tasks.add(TaskRecord(data));
    }
    tasks.sort((TaskRecord a, TaskRecord b) {
      final int byCreated = a.createdAt.compareTo(b.createdAt);
      return byCreated != 0 ? byCreated : a.id.compareTo(b.id);
    });
    return tasks;
  }

  TaskRecord getTask(String lineId, String taskId) {
    final File file = File(_taskFile(lineId, taskId));
    if (!file.existsSync()) {
      throw ProductionFailure('任务不存在：$taskId', code: 'not_found');
    }
    return TaskRecord(_readYaml(file, 'task.yaml'));
  }

  /// 有限状态迁移：查表 → 校验 blocked 理由 → 写 `task.yaml` → 刷新索引。
  Map<String, Object?> transition(
    String lineId,
    String taskId, {
    required String to,
    String reason = '',
  }) {
    final TaskRecord task = getTask(lineId, taskId);
    final TaskStatus from = task.status;
    final TaskStatus target = taskStatusOf(to);
    if (from.isTerminal) {
      throw ProductionFailure(
        '任务已处于终态 ${from.wire}，不可再迁移',
        code: 'terminal_state',
      );
    }
    if (from == target) {
      throw ProductionFailure(
        '任务已经处于 ${target.wire}',
        code: 'invalid_transition',
      );
    }
    if (!canTransition(from, target)) {
      final List<String> allowed = allowedTransitions(
        from,
      ).map((TaskStatus status) => status.wire).toList()..sort();
      throw ProductionFailure(
        '非法状态迁移 ${from.wire} → ${target.wire}；'
        '允许：${allowed.isEmpty ? '无（终态）' : allowed.join(' / ')}',
        code: 'invalid_transition',
      );
    }
    final String blockedReason = reason.trim();
    if (target == TaskStatus.blocked && blockedReason.isEmpty) {
      throw ProductionFailure(
        '转 blocked 必须带 blocked_reason',
        code: 'reason_required',
      );
    }
    final Map<String, Object?> data = <String, Object?>{
      ...task.data,
      'status': target.wire,
      'updated_at': nowText(),
    };
    if (target == TaskStatus.blocked) {
      data['blocked_reason'] = blockedReason;
    } else {
      data.remove('blocked_reason');
    }
    _writeText(File(_taskFile(lineId, taskId)), encodeYaml(data));
    rebuild(lineId);
    return <String, Object?>{
      'task': plainMap(data),
      'from': from.wire,
      'to': target.wire,
    };
  }

  // ── 队列 ──────────────────────────────────────────────────────────

  /// 下一批可派发任务：`queued` 中依赖已 `done` 的，按队列口径取前 [limit] 条。
  Map<String, Object?> next(String lineId, {int limit = 1}) {
    getLine(lineId);
    final List<TaskRecord> tasks = listTasks(lineId);
    final List<TaskRecord> ordered = queuedInOrder(tasks);
    final Map<String, TaskStatus> statuses = <String, TaskStatus>{
      for (final TaskRecord task in tasks) task.id: task.status,
    };
    final List<Map<String, Object?>> ready = <Map<String, Object?>>[];
    final List<Map<String, Object?>> skipped = <Map<String, Object?>>[];
    for (final TaskRecord task in ordered) {
      final List<String> waiting = missingDependencies(task, statuses);
      if (waiting.isEmpty) {
        ready.add(task.toJson());
      } else {
        skipped.add(<String, Object?>{
          'id': task.id,
          'reason': 'depends_on',
          'waiting_on': waiting,
        });
      }
    }
    final int take = limit <= 0 ? ready.length : (limit > 50 ? 50 : limit);
    return <String, Object?>{
      'line_id': lineId,
      'queue': <String>[for (final TaskRecord task in ordered) task.id],
      'tasks': ready.take(take).toList(),
      'skipped': skipped,
      'count': ready.length,
    };
  }

  /// 从 `task.yaml` 重建 `state.json`；内容未变时**不写盘**。
  Map<String, Object?> rebuild(String lineId) {
    getLine(lineId);
    final List<TaskRecord> tasks = listTasks(lineId);
    final List<TaskRecord> ordered = queuedInOrder(tasks);
    final Map<String, TaskStatus> statuses = <String, TaskStatus>{
      for (final TaskRecord task in tasks) task.id: task.status,
    };
    final List<Map<String, Object?>> indexTasks = <Map<String, Object?>>[
      for (final TaskRecord task in tasks)
        <String, Object?>{
          'id': task.id,
          'status': task.status.wire,
          'priority': task.priority,
          'depends_on': task.dependsOn,
          'created_at': task.createdAt,
          'updated_at': task.updatedAt,
        },
    ];
    final List<String> queue = <String>[
      for (final TaskRecord task in ordered) task.id,
    ];
    final List<String> dispatchable = <String>[
      for (final TaskRecord task in ordered)
        if (missingDependencies(task, statuses).isEmpty) task.id,
    ];
    final File file = File(_stateFile(lineId));
    final Map<String, Object?> previous = file.existsSync()
        ? _tryReadJson(file)
        : const <String, Object?>{};
    final bool same =
        textOf(previous['line_id']) == lineId &&
        textOf(previous['team_id']) == teamId &&
        previous['version'] == 1 &&
        jsonEncode(previous['tasks']) == jsonEncode(indexTasks) &&
        jsonEncode(previous['queue']) == jsonEncode(queue) &&
        jsonEncode(previous['dispatchable']) == jsonEncode(dispatchable);
    final Map<String, Object?> result = <String, Object?>{
      'line_id': lineId,
      'changed': !same,
      'queue': queue,
      'dispatchable': dispatchable,
      'count': tasks.length,
    };
    if (same) return result;
    final Map<String, Object?> index = <String, Object?>{
      'version': 1,
      'line_id': lineId,
      'team_id': teamId,
      'rebuilt_at': nowText(),
      'tasks': indexTasks,
      'queue': queue,
      'dispatchable': dispatchable,
    };
    _writeText(
      file,
      '${const JsonEncoder.withIndent('  ').convert(index)}\n',
    );
    return result;
  }

  /// 崩溃恢复：`packing / packed / running / gating` → `queued`，并追加一条
  /// `status=interrupted` 的运行台账。重复调用（已无在途任务）0 写。
  Map<String, Object?> recover(String lineId) {
    getLine(lineId);
    final List<TaskRecord> tasks = listTasks(lineId);
    final List<Map<String, Object?>> recovered = <Map<String, Object?>>[];
    for (final TaskRecord task in tasks) {
      final TaskStatus status = task.status;
      if (!status.isInFlight) continue;
      final String role =
          status == TaskStatus.packing || status == TaskStatus.packed
          ? 'packer'
          : 'executor';
      final Map<String, Object?> data = <String, Object?>{
        ...task.data,
        'status': TaskStatus.queued.wire,
        'updated_at': nowText(),
      }..remove('blocked_reason');
      _writeText(File(_taskFile(lineId, task.id)), encodeYaml(data));
      final Map<String, Object?> run = _interruptedRun(task.id, role, status);
      _writeRun(lineId, run);
      recovered.add(<String, Object?>{
        'task_id': task.id,
        'from': status.wire,
        'run_id': run['run_id'],
      });
    }
    if (recovered.isNotEmpty) rebuild(lineId);
    return <String, Object?>{
      'line_id': lineId,
      'recovered': recovered,
      'count': recovered.length,
    };
  }

  // ── 运行台账 ──────────────────────────────────────────────────────

  List<Map<String, Object?>> listRuns(String lineId, {String taskId = ''}) {
    final Directory dir = Directory(_runsDir(lineId));
    if (!dir.existsSync()) return <Map<String, Object?>>[];
    final List<Map<String, Object?>> runs = <Map<String, Object?>>[];
    for (final FileSystemEntity entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final Map<String, Object?> run = _tryReadJson(entity);
      if (run.isEmpty) continue;
      if (taskId.isNotEmpty && textOf(run['task_id']) != taskId) continue;
      if (textOf(run['run_id']).isEmpty) {
        run['run_id'] = p.basenameWithoutExtension(entity.path);
      }
      runs.add(run);
    }
    runs.sort((Map<String, Object?> a, Map<String, Object?> b) {
      final int byTime = textOf(
        b['started_at'],
      ).compareTo(textOf(a['started_at']));
      return byTime != 0
          ? byTime
          : textOf(b['run_id']).compareTo(textOf(a['run_id']));
    });
    return runs;
  }

  Map<String, Object?> _interruptedRun(
    String taskId,
    String role,
    TaskStatus status,
  ) {
    final String startedAt = nowText();
    final Map<String, Object?> run = <String, Object?>{
      'run_id': 'run_${taskId}_${status.wire}_${_clock().millisecondsSinceEpoch}',
      'task_id': taskId,
      'role': role,
      'model_id': '',
      'status': 'interrupted',
      'started_at': startedAt,
      'elapsed_ms': 0,
      'tokens': <String, Object?>{'prompt': 0, 'completion': 0},
      'tool_calls': <Object?>[],
      'gate': <Object?>[],
      'error': '进程重启时任务处于 ${status.wire}，已回 queued（P1 恢复语义）',
      'artifacts': <Object?>[],
    };
    return run;
  }

  void _writeRun(String lineId, Map<String, Object?> run) {
    final String runId = _segment(textOf(run['run_id']), 'run_id');
    _writeText(
      File(p.join(_runsDir(lineId), '$runId.json')),
      '${const JsonEncoder.withIndent('  ').convert(plainMap(run))}\n',
    );
  }

  // ── 读写工具 ──────────────────────────────────────────────────────

  String _segment(String raw, String what) {
    final String value = raw.trim();
    if (value.isEmpty) {
      throw ProductionFailure('$what 不能为空', code: 'invalid_arguments');
    }
    if (value == '.' || value == '..') {
      throw ProductionFailure('$what 不能是 . 或 ..', code: 'invalid_arguments');
    }
    if (!_segmentPattern.hasMatch(value)) {
      throw ProductionFailure(
        '$what 只允许 [A-Za-z0-9_.-]（防路径穿越）：$value',
        code: 'invalid_arguments',
      );
    }
    return value;
  }

  /// 原子写：先写同目录临时文件，再改名覆盖（Windows 上先删旧文件）。
  void _writeText(File file, String content) {
    file.parent.createSync(recursive: true);
    final File temp = File('${file.path}.tmp-${_tempSeq++}');
    temp.writeAsStringSync(content, flush: true);
    if (file.existsSync()) file.deleteSync();
    temp.renameSync(file.path);
  }

  Map<String, Object?> _readYaml(File file, String what) {
    final Object? decoded;
    try {
      decoded = loadYaml(file.readAsStringSync());
    } catch (error) {
      throw ProductionFailure(
        '$what 不是合法 YAML（${file.path}）：$error',
        code: 'invalid_yaml',
      );
    }
    if (decoded is! Map) {
      throw ProductionFailure(
        '$what 顶层必须是对象：${file.path}',
        code: 'invalid_yaml',
      );
    }
    return plainMap(decoded);
  }

  Map<String, Object?> _tryReadJson(File file) {
    try {
      return plainMap(json.decode(file.readAsStringSync()));
    } catch (_) {
      return <String, Object?>{};
    }
  }
}
