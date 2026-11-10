import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree_ui_default/io/api_service.dart';
import 'package:tree_ui_default/ui/widgets/production_line_panel.dart';

/// 假核心：只实现产线只读 REST（lines / tasks / runs）。
class _FakeCore {
  _FakeCore._(this._http);

  final HttpServer _http;

  /// 非 0 时所有请求按该状态码回 `detail`（模拟插件未安装 / 停用）。
  int failStatus = 0;
  String failDetail = '插件 tree.production.line 未安装';

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
    if (failStatus != 0) {
      request.response.statusCode = failStatus;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(<String, dynamic>{
        'detail': failDetail,
      }));
      await request.response.close();
      return;
    }
    Map<String, dynamic> payload = <String, dynamic>{'success': true};
    if (path == '/api/production/lines') {
      payload = <String, dynamic>{
        'lines': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'pl_1',
            'name': '标准开发流',
            'status': 'working',
          },
        ],
        'count': 1,
      };
    } else if (path.endsWith('/tasks')) {
      payload = <String, dynamic>{
        'tasks': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'T1',
            'title': '底座',
            'status': 'queued',
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
    }
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(payload));
    await request.response.close();
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

  Widget panel({String teamId = 'team_a'}) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 280,
        height: 720,
        child: ProductionLinePanel(teamId: teamId),
      ),
    ),
  );

  Future<void> flyIO(WidgetTester tester, {int rounds = 5}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
  }

  testWidgets('产线列表 → 展开看任务队列与运行台账', (WidgetTester tester) async {
    await tester.pumpWidget(panel());
    await flyIO(tester);

    expect(find.text('标准开发流'), findsOneWidget);
    expect(find.textContaining('pl_1'), findsOneWidget);

    await tester.tap(find.text('标准开发流'));
    await flyIO(tester);
    expect(find.text('任务队列（1）'), findsOneWidget);
    expect(find.textContaining('T1'), findsWidgets);
    expect(find.text('运行台账（1）'), findsOneWidget);
    expect(find.textContaining('packer'), findsOneWidget);
  });

  testWidgets('插件未安装：可读说明 + 重试', (WidgetTester tester) async {
    core.failStatus = 503;
    await tester.pumpWidget(panel());
    await flyIO(tester);

    expect(find.textContaining('未安装 tree.production.line 插件'), findsOneWidget);
    expect(find.byKey(const Key('production-line-retry')), findsOneWidget);

    core.failStatus = 0;
    await tester.tap(find.byKey(const Key('production-line-retry')));
    await flyIO(tester);
    expect(find.text('标准开发流'), findsOneWidget);
    expect(find.textContaining('未安装 tree.production.line 插件'), findsNothing);
  });

  testWidgets('未选团队：提示先选 Agent', (WidgetTester tester) async {
    await tester.pumpWidget(panel(teamId: ''));
    await tester.pump();
    expect(find.textContaining('先在左侧选择一个 Agent'), findsOneWidget);
  });
}
