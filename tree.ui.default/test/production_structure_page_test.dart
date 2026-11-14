import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree_ui_default/io/api_service.dart';
import 'package:tree_ui_default/ui/widgets/production_structure_page.dart';

/// 假核心：结构报告 + 重新评估 + 逐项豁免（记录 body 供断言）。
class _FakeCore {
  _FakeCore._(this._http);

  final HttpServer _http;
  final List<String> calls = <String>[];
  final Map<String, Map<String, dynamic>> bodies =
      <String, Map<String, dynamic>>{};

  Map<String, dynamic> bodyOf(String method, String path) =>
      bodies['$method $path'] ?? <String, dynamic>{};

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

  Map<String, dynamic> get _structure => <String, dynamic>{
    'responsibilities': <Map<String, dynamic>>[
      <String, dynamic>{
        'package': 'tree.ui.default',
        'responsibility': '界面与交互',
      },
    ],
    'public_api': <String>['ApiService.getProductionLines'],
    'cycles': <Map<String, dynamic>>[
      <String, dynamic>{'from': 'a', 'to': 'b', 'reason': '循环依赖'},
    ],
    'layers': <Map<String, dynamic>>[
      <String, dynamic>{'layer': 'ui', 'rule': '只能依赖 lib/io'},
    ],
    'duplicates': <String>['lib/utils.dart ↔ lib/helpers.dart'],
    'size': <String, dynamic>{'files': 120, 'lines': 8000, 'large_files': 2},
    'docs': <String>['docs/README.md 缺索引'],
    'todos': <String>['TODO: 拆分 agent_list.dart'],
    'findings': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'F1',
        'severity': 'high',
        'title': '存在依赖环',
        'detail': 'a 与 b 互相引用',
      },
      <String, dynamic>{'id': 'F2', 'severity': 'medium', 'title': '中等项'},
    ],
  };

  Map<String, dynamic> get _readiness => <String, dynamic>{
    'ready': false,
    'phase': 'organizing',
    'missing': <String>['结构未通过'],
  };

  Future<void> _handle(HttpRequest request) async {
    final String method = request.method;
    final String path = request.uri.path;
    final String raw = await utf8.decoder.bind(request).join();
    calls.add('$method $path');
    Map<String, dynamic> body = <String, dynamic>{};
    if (raw.trim().isNotEmpty) {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) {
        body = decoded.map(
          (Object? key, Object? value) =>
              MapEntry<String, dynamic>('$key', value),
        );
      }
    }
    bodies['$method $path'] = body;
    Map<String, dynamic> payload = <String, dynamic>{'success': true};
    if (path.endsWith('/structure') && method == 'GET') {
      payload = <String, dynamic>{
        'structure': _structure,
        'readiness': _readiness,
      };
    } else if (path.endsWith('/structure/reevaluate')) {
      payload = <String, dynamic>{
        'structure': _structure,
        'readiness': _readiness,
      };
    } else if (path.endsWith('/structure/waive')) {
      payload = <String, dynamic>{'waived': body['finding_id']};
    }
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(payload));
    await request.response.close();
  }
}

Widget _harness({Future<void> Function()? onCleanup}) => MaterialApp(
  home: Scaffold(
    body: ProductionStructurePage(
      lineId: 'pl_1',
      teamId: 'team_a',
      onCreateCleanupTask: onCleanup,
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

  testWidgets('结构报告：包职责 / API / 依赖环 / 重复 / 规模 / 文档 / TODO / finding', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_harness());
    await _flyIO(tester);

    expect(find.textContaining('tree.ui.default：界面与交互'), findsOneWidget);
    expect(
      find.textContaining('ApiService.getProductionLines'),
      findsOneWidget,
    );
    expect(find.textContaining('a → b'), findsOneWidget);
    expect(find.textContaining('只能依赖 lib/io'), findsOneWidget);
    expect(find.textContaining('lib/helpers.dart'), findsOneWidget);
    expect(find.textContaining('files：120'), findsOneWidget);
    expect(find.textContaining('docs/README.md 缺索引'), findsOneWidget);
    expect(find.textContaining('TODO: 拆分 agent_list.dart'), findsOneWidget);
    expect(find.textContaining('F1 · 存在依赖环'), findsOneWidget);
    expect(find.textContaining('F2 · 中等项'), findsNothing, reason: '只列 high');
    expect(find.textContaining('只能建 cleanup 任务'), findsOneWidget);
    expect(
      find.byKey(const Key('production-structure-cleanup')),
      findsOneWidget,
    );
  });

  testWidgets('逐项豁免：owner / 原因 / 到期 → POST structure/waive', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_harness());
    await _flyIO(tester);

    await tester.tap(find.byKey(const Key('production-structure-waive-F1')));
    await tester.pumpAndSettle();
    expect(find.text('豁免 · F1'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('production-structure-waive-owner')),
      'alice',
    );
    await tester.enterText(
      find.byKey(const Key('production-structure-waive-reason')),
      '迁移期暂时接受',
    );
    await tester.enterText(
      find.byKey(const Key('production-structure-waive-expires')),
      '2026-12-31',
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('production-structure-waive-submit')),
    );
    await _flyIO(tester);

    const String path = '/api/production/lines/pl_1/structure/waive';
    expect(core.called('POST', path), isTrue);
    final Map<String, dynamic> body = core.bodyOf('POST', path);
    expect(body['finding_id'], 'F1');
    expect(body['owner'], 'alice');
    expect(body['reason'], '迁移期暂时接受');
    expect(body['expires_at'], '2026-12-31');
  });

  testWidgets('重新评估 → POST structure/reevaluate 并刷新报告', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_harness());
    await _flyIO(tester);

    await tester.tap(find.byKey(const Key('production-structure-reevaluate')));
    await _flyIO(tester);

    expect(
      core.called('POST', '/api/production/lines/pl_1/structure/reevaluate'),
      isTrue,
    );
    expect(find.textContaining('存在依赖环'), findsOneWidget);
  });
}
