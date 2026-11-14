import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree_ui_default/io/api_service.dart';
import 'package:tree_ui_default/io/protocol_contract.dart';
import 'package:tree_ui_default/ui/widgets/production_line_workbench.dart';

/// 假核心：任务 / 台账 / 主控 / 就绪门；就绪门决定头栏与按钮状态。
class _FakeCore {
  _FakeCore._(this._http);

  final HttpServer _http;

  Map<String, dynamic> readiness = <String, dynamic>{
    'ready': false,
    'phase': 'organizing',
    'missing': <String>['文档归一化未完成', '包图未就绪'],
    'gates': <Map<String, dynamic>>[
      <String, dynamic>{
        'key': 'code_index',
        'label': '代码索引',
        'ok': false,
        'reason': '未构建',
      },
    ],
    'checked_at': '2026-11-14T10:00:00',
  };

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

  bool called(String method, String path) => calls.contains('$method $path');

  Future<void> _handle(HttpRequest request) async {
    final String path = request.uri.path;
    calls.add('${request.method} $path');
    await utf8.decoder.bind(request).join();
    Map<String, dynamic> payload = <String, dynamic>{'success': true};
    if (path.endsWith('/readiness')) {
      payload = readiness;
    } else if (path.endsWith('/tasks')) {
      payload = <String, dynamic>{
        'tasks': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'T1',
            'title': '底座',
            'status': 'queued',
            'write_scope': <String>['lib/'],
          },
        ],
        'count': 1,
      };
    } else if (path.endsWith('/runs')) {
      payload = <String, dynamic>{
        'runs': <Map<String, dynamic>>[
          <String, dynamic>{
            'run_id': 'r1',
            'task_id': 'T1',
            'role': 'packer',
            'status': 'done',
          },
        ],
        'count': 1,
      };
    } else if (path.endsWith('/orchestrator')) {
      payload = <String, dynamic>{
        'config': <String, dynamic>{'enabled': true},
        'state': <String, dynamic>{'last_action': 'continue'},
        'open_questions': <Object?>[],
        'open_question_count': 0,
      };
    }
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(payload));
    await request.response.close();
  }
}

Widget _harness() => MaterialApp(
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
        agentId: 'agt_1',
        deliveries: Stream<StationDelivery>.empty(),
        pollInterval: const Duration(days: 1),
      ),
    ),
  ),
);

Future<void> _flyIO(WidgetTester tester, {int rounds = 6}) async {
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

  testWidgets('未就绪：头栏列出缺失项，派发 / 建任务禁用', (WidgetTester tester) async {
    await tester.pumpWidget(_harness());
    await _flyIO(tester);

    expect(
      find.textContaining('未就绪 · 整理中 · 3 项待补齐'),
      findsOneWidget,
    );
    expect(find.textContaining('整理中'), findsWidgets);
    expect(find.textContaining('文档归一化未完成'), findsOneWidget);
    expect(find.textContaining('包图未就绪'), findsOneWidget);
    expect(find.textContaining('代码索引：未构建'), findsOneWidget);

    final IconButton create = tester.widget<IconButton>(
      find.byKey(const Key('production-task-create-pl_1')),
    );
    expect(create.onPressed, isNull, reason: '未就绪时不能建任务');
    expect(create.tooltip, contains('409'));

    await tester.tap(find.byKey(const Key('production-task-menu-T1')));
    await tester.pumpAndSettle();
    final PopupMenuItem<String> pack = tester.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, '打包'),
    );
    expect(pack.enabled, isFalse, reason: '未就绪时不能派发');
  });

  testWidgets('就绪：绿色「就绪」+ 最近检查时间，按钮恢复可用', (WidgetTester tester) async {
    core.readiness = <String, dynamic>{
      'ready': true,
      'phase': 'ready',
      'missing': <Object?>[],
      'gates': <Object?>[],
      'checked_at': '2026-11-14T11:00:00',
    };
    await tester.pumpWidget(_harness());
    await _flyIO(tester);

    expect(find.textContaining('就绪 · 最近检查'), findsOneWidget);
    expect(find.textContaining('最近检查 2026-11-14T11:00:00'), findsOneWidget);
    final IconButton create = tester.widget<IconButton>(
      find.byKey(const Key('production-task-create-pl_1')),
    );
    expect(create.onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('production-task-menu-T1')));
    await tester.pumpAndSettle();
    final PopupMenuItem<String> pack = tester.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, '打包'),
    );
    expect(pack.enabled, isTrue);
  });
}
