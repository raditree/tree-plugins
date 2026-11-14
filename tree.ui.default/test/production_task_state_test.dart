import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree_ui_default/io/api_service.dart';
import 'package:tree_ui_default/io/protocol_contract.dart';
import 'package:tree_ui_default/io/station_client.dart';
import 'package:tree_ui_default/ui/widgets/production_line_workbench.dart';

/// 假核心：每次 GET /tasks 都计数，用来区分「增量更新」与「全量刷新」。
class _FakeCore {
  _FakeCore._(this._http);

  final HttpServer _http;
  String taskStatus = 'queued';
  int tasksCalls = 0;
  final List<String> calls = <String>[];

  static Future<_FakeCore> start() async {
    final HttpServer http = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _FakeCore core = _FakeCore._(http);
    http.listen(core._handle);
    return core;
  }

  String get baseUrl => 'http://127.0.0.1:${_http.port}';

  Future<void> close() => _http.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final String path = request.uri.path;
    calls.add('${request.method} $path');
    await utf8.decoder.bind(request).join();
    Map<String, dynamic> payload = <String, dynamic>{'success': true};
    if (path.endsWith('/tasks')) {
      tasksCalls += 1;
      payload = <String, dynamic>{
        'tasks': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'T1',
            'title': '底座',
            'status': taskStatus,
            'write_scope': <String>['lib/'],
          },
        ],
        'count': 1,
      };
    } else if (path.endsWith('/runs')) {
      payload = <String, dynamic>{'runs': <Object?>[], 'count': 0};
    } else if (path.endsWith('/orchestrator')) {
      payload = <String, dynamic>{
        'config': <String, dynamic>{'enabled': true},
        'state': <String, dynamic>{'last_action': 'continue'},
        'open_questions': <Object?>[],
        'open_question_count': 0,
      };
    } else if (path.endsWith('/readiness')) {
      payload = <String, dynamic>{
        'ready': true,
        'phase': 'ready',
        'checked_at': '2026-11-14T10:00:00',
      };
    }
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(payload));
    await request.response.close();
  }
}

StationDelivery _delivery({
  required int seq,
  required Map<String, dynamic> task,
  String lineId = 'pl_1',
  String phase = 'ready',
}) => StationDelivery(
  stationId: StationClient.productionTaskStateStation,
  point: 'system.broadcast',
  seq: seq,
  payload: <String, dynamic>{
    'type': 'production.task_state',
    'line_id': lineId,
    'seq': seq,
    'snapshot_seq': 0,
    'at': '2026-11-14T10:00:00',
    'task': task,
    'line': <String, dynamic>{
      'id': lineId,
      'phase': phase,
      'status': 'working',
    },
  },
);

Widget _harness(Stream<StationDelivery> deliveries, {Duration? pollInterval}) =>
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 900,
          height: 720,
          child: ProductionLineWorkbench(
            line: <String, dynamic>{
              'id': 'pl_1',
              'name': '标准开发流',
              'status': 'working',
              'workspace_dir': 'E:/work/demo',
            },
            teamId: 'team_a',
            deliveries: deliveries,
            pollInterval: pollInterval ?? const Duration(days: 1),
          ),
        ),
      ),
    );

Future<void> _flyIO(WidgetTester tester, {int rounds = 8}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
}

void main() {
  late _FakeCore core;

  setUp(() async {
    HttpOverrides.global = null;
    core = await _FakeCore.start();
    ApiService.baseUrl = core.baseUrl;
    ApiService.setToken('test-token');
  });

  tearDown(() async {
    await core.close();
    ApiService.setToken(null);
    ApiService.baseUrl = 'http://127.0.0.1:0';
  });

  testWidgets('seq 递增增量更新；重复 seq 忽略；跳号触发全量刷新', (WidgetTester tester) async {
    final StreamController<StationDelivery> controller =
        StreamController<StationDelivery>.broadcast();
    addTearDown(controller.close);
    await tester.pumpWidget(_harness(controller.stream));
    await _flyIO(tester);
    expect(core.tasksCalls, 1);
    expect(find.text('queued'), findsOneWidget);

    // seq == _lastSeq + 1：只改本地任务，不再拉 REST。
    controller.add(
      _delivery(
        seq: 1,
        task: <String, dynamic>{'id': 'T1', 'status': 'running'},
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('running'), findsOneWidget);
    expect(core.tasksCalls, 1, reason: '连续 seq 不应触发全量刷新');

    // 重复 seq：忽略（不把状态改回 done）。
    controller.add(
      _delivery(seq: 1, task: <String, dynamic>{'id': 'T1', 'status': 'done'}),
    );
    await tester.pump();
    expect(find.text('running'), findsOneWidget);
    expect(core.tasksCalls, 1);

    // 跳号 seq=3（漏了 2）：全量刷新一次。
    core.taskStatus = 'done';
    controller.add(
      _delivery(
        seq: 3,
        task: <String, dynamic>{'id': 'T1', 'status': 'packing'},
      ),
    );
    await tester.pump();
    await _flyIO(tester);
    expect(core.tasksCalls, 2, reason: 'gap 必须走全量刷新');
    expect(find.text('done'), findsOneWidget);
  });

  testWidgets('3s 兜底轮询：可见时按注入间隔刷新，隐藏后停止', (WidgetTester tester) async {
    await tester.pumpWidget(
      _harness(
        const Stream<StationDelivery>.empty(),
        pollInterval: const Duration(milliseconds: 50),
      ),
    );
    await _flyIO(tester);
    expect(core.tasksCalls, 1);

    await tester.pump(const Duration(milliseconds: 60));
    await _flyIO(tester);
    expect(core.tasksCalls, 2, reason: '轮询到点必须刷新一次');

    // 页面隐藏 → 取消轮询。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 720,
            child: ProductionLineWorkbench(
              line: <String, dynamic>{
                'id': 'pl_1',
                'name': '标准开发流',
                'status': 'working',
              },
              teamId: 'team_a',
              visible: false,
              deliveries: const Stream<StationDelivery>.empty(),
              pollInterval: const Duration(milliseconds: 50),
            ),
          ),
        ),
      ),
    );
    await _flyIO(tester);
    final int afterHide = core.tasksCalls;
    await tester.pump(const Duration(milliseconds: 120));
    await _flyIO(tester);
    expect(core.tasksCalls, afterHide, reason: '不可见时不能轮询');
  });
}
