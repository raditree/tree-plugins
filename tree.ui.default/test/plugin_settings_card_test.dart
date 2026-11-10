import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree_ui_default/io/api_service.dart';
import 'package:tree_ui_default/ui/widgets/plugin_settings_card.dart';

class _FakeSettingsCore {
  _FakeSettingsCore._(this._http);

  final HttpServer _http;
  final List<({String method, String path, Map<String, dynamic> body})>
  requests = <({String method, String path, Map<String, dynamic> body})>[];

  static Future<_FakeSettingsCore> start() async {
    final HttpServer http = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _FakeSettingsCore core = _FakeSettingsCore._(http);
    http.listen(core._handle);
    return core;
  }

  String get baseUrl => 'http://127.0.0.1:${_http.port}';

  Future<void> close() => _http.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final String raw = await utf8.decoder.bind(request).join();
    final Map<String, dynamic> body = raw.trim().isEmpty
        ? <String, dynamic>{}
        : jsonDecode(raw) as Map<String, dynamic>;
    requests.add((method: request.method, path: request.uri.path, body: body));

    if (request.uri.path == '/api/plugin-settings/schema') {
      await _json(request, <String, dynamic>{
        'schemas': <Map<String, dynamic>>[
          <String, dynamic>{
            'plugin_id': 'tree.docnorm',
            'schema_version': 1,
            'groups': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'budget', 'title': '预算'},
            ],
            'fields': <Map<String, dynamic>>[
              <String, dynamic>{
                'key': 'stage_budget',
                'group': 'budget',
                'type': 'int',
                'title': '阶段预算',
                'default': 400000,
                'min': 1000,
                'max': 2000000,
              },
              <String, dynamic>{
                'key': 'api_token',
                'type': 'secret',
                'title': '网关令牌',
              },
            ],
          },
        ],
      });
      return;
    }
    if (request.uri.path == '/api/plugin-settings/values') {
      if (request.method == 'PATCH') {
        await _json(request, <String, dynamic>{
          'plugin_id': body['plugin_id'],
          'applied': (body['values'] as Map<dynamic, dynamic>? ?? <dynamic, dynamic>{})
              .keys
              .map((dynamic key) => key.toString())
              .toList(),
          'generation': 2,
        });
        return;
      }
      await _json(request, <String, dynamic>{
        'plugin_id': 'tree.docnorm',
        'values': <String, dynamic>{
          'stage_budget': <String, dynamic>{
            'value': 400000,
            'has_value': true,
            'secret': false,
          },
          'api_token': <String, dynamic>{
            'value': null,
            'has_value': true,
            'secret': true,
          },
        },
      });
      return;
    }
    if (request.uri.path == '/api/plugin-settings/reset') {
      await _json(request, <String, dynamic>{
        'plugin_id': body['plugin_id'],
        'reset': body['keys'] ?? <String>[],
        'generation': 3,
      });
      return;
    }
    request.response.statusCode = 404;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(<String, dynamic>{'detail': '未知接口'}));
    await request.response.close();
  }

  Future<void> _json(HttpRequest request, Map<String, dynamic> body) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  String reason = '条件',
}) async {
  for (int i = 0; i < 600; i++) {
    if (done()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  fail('等待$reason 超时');
}

void main() {
  late _FakeSettingsCore core;

  setUp(() async {
    HttpOverrides.global = null;
    core = await _FakeSettingsCore.start();
    ApiService.baseUrl = core.baseUrl;
    ApiService.setToken('test-token');
  });

  tearDown(() async {
    ApiService.setToken(null);
    await core.close();
  });

  testWidgets('插件设置按 schema 渲染，secret 只显示已设置，保存只发脏字段', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PluginSettingsCard(teamId: 'team_a'),
          ),
        ),
      ),
    );
    await _pumpUntil(
      tester,
      () => find.text('tree.docnorm').evaluate().isNotEmpty,
      reason: '插件设置加载',
    );

    expect(find.text('阶段预算'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is TextField &&
            widget.decoration?.hintText == '已设置，留空保持原值',
      ),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextFormField).first, '600000');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await _pumpUntil(
      tester,
      () => core.requests.any(
        (({String method, String path, Map<String, dynamic> body}) request) =>
            request.method == 'PATCH' &&
            request.path == '/api/plugin-settings/values',
      ),
      reason: '保存请求',
    );

    final ({String method, String path, Map<String, dynamic> body}) patch =
        core.requests.lastWhere(
          (({String method, String path, Map<String, dynamic> body}) request) =>
              request.method == 'PATCH',
        );
    final Map<String, dynamic> values = Map<String, dynamic>.from(
      patch.body['values'] as Map,
    );
    expect(values['stage_budget'], 600000);
    expect(values.containsKey('api_token'), false);
  });
}
