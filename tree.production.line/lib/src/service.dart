/// 执行站命令门面：身份 / 数据根 fail-closed → 产线 / 任务 / 队列 / 台账。
library;

import 'dart:io';

import 'models.dart';
import 'store.dart';

/// P1 对外开放的命令族（执行站 `production`）。
const List<String> kProductionCommands = <String>[
  'production.line.create',
  'production.line.list',
  'production.line.get',
  'production.task.create',
  'production.task.list',
  'production.task.get',
  'production.task.transition',
  'production.queue.next',
  'production.queue.rebuild',
  'production.queue.recover',
  'production.run.list',
];

class ProductionService {
  ProductionService({
    Map<String, String>? environment,
    DateTime Function()? clock,
  }) : _environment = environment ?? Platform.environment,
       _clock = clock ?? DateTime.now;

  final Map<String, String> _environment;
  final DateTime Function() _clock;

  Map<String, Object?> handle(
    String command,
    Map<String, Object?> arguments,
    Map<String, Object?> meta,
    Map<String, Object?> scope,
  ) {
    final String dataRoot = _dataRoot(meta);
    if (dataRoot.isEmpty) {
      throw ProductionFailure(
        '缺少 data_dir（核心未在站请求的 meta 里带数据根，环境变量 TREE_DATA_ROOT 也未设置）',
        code: 'missing_data_dir',
      );
    }
    final String teamId = textOf(scope['team_id']);
    if (teamId.isEmpty) {
      throw ProductionFailure(
        '核心未在站请求的 scope 里带 team_id，拒绝落到公共库',
        code: 'team_required',
      );
    }
    final ProductionStore store = ProductionStore(
      dataRoot: dataRoot,
      teamId: teamId,
      clock: _clock,
    );
    switch (command) {
      case 'production.line.create':
        return <String, Object?>{'line': store.createLine(arguments).toJson()};
      case 'production.line.list':
        {
          final List<LineRecord> lines = store.listLines();
          return <String, Object?>{
            'lines': <Map<String, Object?>>[
              for (final LineRecord line in lines) line.toJson(),
            ],
            'count': lines.length,
          };
        }
      case 'production.line.get':
        return <String, Object?>{
          'line': store.getLine(_argument(arguments, 'line_id')).toJson(),
        };
      case 'production.task.create':
        {
          final String lineId = _argument(arguments, 'line_id');
          final Map<String, Object?> input = arguments['task'] is Map
              ? plainMap(arguments['task'])
              : (<String, Object?>{...arguments}..remove('line_id'));
          return <String, Object?>{
            'task': store.createTask(lineId, input).toJson(),
          };
        }
      case 'production.task.list':
        {
          final String lineId = _argument(arguments, 'line_id');
          List<TaskRecord> tasks = store.listTasks(lineId);
          final String statusFilter = textOf(arguments['status']);
          if (statusFilter.isNotEmpty) {
            final TaskStatus wanted = taskStatusOf(statusFilter);
            tasks = <TaskRecord>[
              for (final TaskRecord task in tasks)
                if (task.status == wanted) task,
            ];
          }
          return <String, Object?>{
            'tasks': <Map<String, Object?>>[
              for (final TaskRecord task in tasks) task.toJson(),
            ],
            'count': tasks.length,
          };
        }
      case 'production.task.get':
        {
          final String lineId = _argument(arguments, 'line_id');
          final String taskId = _argument(arguments, 'task_id');
          return <String, Object?>{
            'task': store.getTask(lineId, taskId).toJson(),
          };
        }
      case 'production.task.transition':
        {
          final String lineId = _argument(arguments, 'line_id');
          final String taskId = _argument(arguments, 'task_id');
          final String to = _argument(arguments, 'to');
          return store.transition(
            lineId,
            taskId,
            to: to,
            reason: textOf(arguments['reason']),
          );
        }
      case 'production.queue.next':
        return store.next(
          _argument(arguments, 'line_id'),
          limit: intOf(arguments['limit'], 1),
        );
      case 'production.queue.rebuild':
        return store.rebuild(_argument(arguments, 'line_id'));
      case 'production.queue.recover':
        return store.recover(_argument(arguments, 'line_id'));
      case 'production.run.list':
        {
          final String lineId = _argument(arguments, 'line_id');
          store.getLine(lineId);
          final List<Map<String, Object?>> runs = store.listRuns(
            lineId,
            taskId: textOf(arguments['task_id']),
          );
          return <String, Object?>{'runs': runs, 'count': runs.length};
        }
      default:
        throw ProductionFailure('未知产线命令：$command', code: 'unknown_command');
    }
  }

  String _argument(Map<String, Object?> arguments, String key) {
    final String value = textOf(arguments[key]);
    if (value.isEmpty) {
      throw ProductionFailure('缺少 $key', code: 'invalid_arguments');
    }
    return value;
  }

  String _dataRoot(Map<String, Object?> meta) {
    final String fromMeta = textOf(meta['data_dir']);
    if (fromMeta.isNotEmpty) return fromMeta;
    return textOf(_environment['TREE_DATA_ROOT']);
  }
}
