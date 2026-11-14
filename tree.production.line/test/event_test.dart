import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

/// Task 9.1：`production.task_state` 事件广播。
///
/// 锁住：
/// 1. create / update / transition 成功后同步发出事件（putTask 不发）；
/// 2. `seq` 单调递增、`snapshot_seq == seq`，并持久化在 `state.json.event_seq`；
/// 3. `rebuild` 不冲掉 `event_seq`；
/// 4. 投递失败不抛出、不影响业务落盘；
/// 5. 广播 scope 带非空 team_id 与合法 mode_key。
void main() {
  late Directory temp;
  late ProductionStore store;
  final List<Map<String, Object?>> frames = <Map<String, Object?>>[];
  final List<String> topics = <String>[];
  final List<Map<String, dynamic>> scopes = <Map<String, dynamic>>[];
  String dropReason = '';

  Future<Map<String, dynamic>> fakeTrigger(
    String stationId,
    Object? payload,
    Map<String, dynamic> meta,
    Map<String, dynamic> scope, {
    String? topic,
  }) async {
    frames.add(plainMap(payload));
    if (topic != null) topics.add(topic);
    scopes.add(scope);
    if (dropReason.isNotEmpty) {
      return <String, dynamic>{'ok': false, 'error': dropReason};
    }
    return <String, dynamic>{'ok': true, 'delivered': 1};
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_production_event_');
    frames.clear();
    topics.clear();
    scopes.clear();
    dropReason = '';
    late ProductionStore created;
    created = ProductionStore(
      dataRoot: temp.path,
      clock: () => DateTime(2026, 11, 14, 10),
      onTaskState: (String lineId, TaskRecord task) {
        publishTaskState(
          store: created,
          lineId: lineId,
          task: task,
          trigger: fakeTrigger,
        );
      },
    );
    store = created;
    store.createLine(<String, Object?>{
      'id': 'pl_1',
      'name': '事件',
      'executor': <String, Object?>{
        'agent_id': 'agt_exec',
        'team_id': 'team_exec',
      },
    });
  });

  tearDown(() {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Map<String, Object?> stateJson() {
    final File file = File(
      p.join(temp.path, 'production_lines', 'production', 'pl_1', 'state.json'),
    );
    return plainMap(jsonDecode(file.readAsStringSync()));
  }

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test('create / update / transition 各发一帧，seq 单调递增', () async {
    store.createTask('pl_1', <String, Object?>{
      'id': 'T1',
      'title': '底座',
      'status': 'queued',
    });
    await flush();
    expect(frames.length, 1);
    expect(frames.single['type'], 'production.task_state');
    expect(frames.single['line_id'], 'pl_1');
    expect((frames.single['task'] as Map)['id'], 'T1');
    expect(frames.single['snapshot_seq'], frames.single['seq']);
    expect(frames.single['seq'], 1);
    expect((frames.single['line'] as Map)['phase'], 'organizing');

    store.updateTask('pl_1', 'T1', <String, Object?>{'title': '改名'});
    await flush();
    expect(frames.length, 2);
    expect(frames.last['seq'], 2);

    store.transition('pl_1', 'T1', to: 'packing');
    await flush();
    expect(frames.length, 3);
    expect(frames.last['seq'], 3);
    expect(frames.last['snapshot_seq'], 3);
    expect((frames.last['task'] as Map)['status'], 'packing');

    // putTask 是内部元数据写入：不发事件。
    store.putTask('pl_1', 'T1', <String, Object?>{'last_error': 'x'});
    await flush();
    expect(frames.length, 3);
  });

  test('event_seq 持久化且 rebuild 不冲掉', () async {
    store.createTask('pl_1', <String, Object?>{
      'id': 'T1',
      'title': '底座',
      'status': 'queued',
    });
    store.transition('pl_1', 'T1', to: 'packing');
    await flush();
    expect(store.readEventSeq('pl_1'), 2);
    expect(stateJson()['event_seq'], 2);

    store.rebuild('pl_1');
    expect(store.readEventSeq('pl_1'), 2);
    expect(stateJson()['event_seq'], 2);
  });

  test('投递失败不抛，序号照常推进', () async {
    dropReason = 'no_subscriber';
    expect(
      () => store.createTask('pl_1', <String, Object?>{
        'id': 'T1',
        'title': '底座',
        'status': 'queued',
      }),
      returnsNormally,
    );
    await flush();
    expect(store.readEventSeq('pl_1'), 1);
  });

  test('广播 scope：team_id 非空、mode_key=local、带执行 agent', () async {
    store.createTask('pl_1', <String, Object?>{
      'id': 'T1',
      'title': '底座',
      'status': 'queued',
    });
    await flush();
    expect(scopes.single['team_id'], 'team_exec');
    expect(scopes.single['mode_key'], 'local');
    expect(scopes.single['agent_id'], 'agt_exec');
    expect(topics.single, 'tree.production.line._.task_state');
  });
}
