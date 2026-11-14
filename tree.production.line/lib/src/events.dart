/// Task 9.1：任务状态广播（`production.task_state`）。
///
/// 帧形状固定（UI 只依赖这些键）：
/// ```json
/// {"type":"production.task_state","line_id":"pl_1","seq":12,"snapshot_seq":12,
///  "at":"ISO8601","task":{...},"line":{"id":"pl_1","phase":"ready","status":"working"}}
/// ```
/// `seq` 单调递增并持久化在 `state.json.event_seq`；`snapshot_seq` 取本次 `seq`
/// （`state.json` 在每次 create / update / transition 后已重建）。事件是旁路：
/// 投递失败只留日志，不影响业务写盘。
library;

import 'dart:async';

import 'models.dart';
import 'store.dart';

/// 广播站名（核心拼成 `plugin.tree.production.line.broadcast.task_state`）。
const String kTaskStateStationName = 'task_state';

/// 广播站完整 id（与核心拼接规则一致，两侧都不得自选）。
const String kTaskStateStationId =
    'plugin.tree.production.line.broadcast.task_state';

/// 广播 topic：`<plugin_id>.<session_id>.<kind>`，没有会话时用 `_` 兜底。
const String kTaskStateTopic = 'tree.production.line._.task_state';

/// 事件帧类型。
const String kTaskStateType = 'production.task_state';

/// 广播站 readme（`station/register` 必填：说清发什么、什么时候发、谁该订）。
const String kTaskStateReadme =
    '生产线任务状态广播站：生产任务 create / update / transition 成功后各发一帧 '
    'production.task_state（type / line_id / seq / snapshot_seq / at / task / line）。'
    'topic = tree.production.line._.task_state；seq 单调递增且持久化在 '
    'state.json.event_seq，UI 可用 snapshot_seq 判断快照水位。';

/// `station/trigger` 的调用面（插件层接 `server.channel.request`；单测注入假实现）。
typedef TaskStateTrigger = Future<Map<String, dynamic>> Function(
  String stationId,
  Object? payload,
  Map<String, dynamic> meta,
  Map<String, dynamic> scope, {
  String? topic,
});

/// 构造一帧任务状态事件。
Map<String, Object?> taskStateFrame({
  required ProductionStore store,
  required String lineId,
  required TaskRecord task,
  required int seq,
}) {
  final LineRecord line = store.getLine(lineId);
  return <String, Object?>{
    'type': kTaskStateType,
    'line_id': lineId,
    'seq': seq,
    'snapshot_seq': seq,
    'at': store.nowText(),
    'task': task.toJson(),
    'line': <String, Object?>{
      'id': lineId,
      'phase': line.effectivePhase,
      'status': line.status,
    },
  };
}

/// 分配序号并发布一帧；投递失败只回调 [log]，不抛出。
///
/// 即使 [trigger] 为空也会推进 `state.json.event_seq`：序号水位与状态变化一一
/// 对应，插件稍后接上广播站时不会倒流。
void publishTaskState({
  required ProductionStore store,
  required String lineId,
  required TaskRecord task,
  required TaskStateTrigger? trigger,
  void Function(String message)? log,
  String stationId = kTaskStateStationId,
}) {
  final int seq = store.nextEventSeq(lineId);
  final Map<String, Object?> frame = taskStateFrame(
    store: store,
    lineId: lineId,
    task: task,
    seq: seq,
  );
  if (trigger == null) return;
  void note(String message) => log?.call(message);
  try {
    final Future<Map<String, dynamic>> delivery = trigger(
      stationId,
      frame,
      <String, dynamic>{'plugin_id': 'tree.production.line'},
      _scopeOf(store.getLine(lineId)),
      topic: kTaskStateTopic,
    );
    unawaited(
      delivery
          .then<void>((Map<String, dynamic> reply) {
            if (reply['ok'] == true) return;
            note(
              '任务状态事件未投递：'
              '${reply['error'] ?? reply['result'] ?? reply['skipped'] ?? 'unknown'}',
            );
          })
          .catchError((Object error) {
            note('任务状态事件投递失败：$error');
          }),
    );
  } catch (error) {
    note('任务状态事件投递失败：$error');
  }
}

/// 广播信封的归属：`team_id` 非空（核心 fail-closed 拒绝空 team），mode 固定 local。
Map<String, dynamic> _scopeOf(LineRecord line) {
  final String teamId = line.executorTeamId.isNotEmpty
      ? line.executorTeamId
      : (line.executorAgentId.isNotEmpty ? line.executorAgentId : 'production');
  return <String, dynamic>{
    'team_id': teamId,
    'mode_key': 'local',
    if (line.executorAgentId.isNotEmpty) 'agent_id': line.executorAgentId,
  };
}
