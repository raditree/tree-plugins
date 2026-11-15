import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree_ui_default/io/api_service.dart';
import 'package:tree_ui_default/ui/widgets/production_normalize_page.dart';

/// 假核心：归一化状态 / 预检 plan / apply / rollback。
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

  static const Map<String, dynamic> _plan = <String, dynamic>{
    'run_id': 'run_preview',
    'files': <Map<String, dynamic>>[
      <String, dynamic>{
        'path': 'docs/README.md',
        'actions': <String>['append_index'],
        'diff': '+ 新增索引行',
      },
      <String, dynamic>{
        'path': 'docs/architecture.md',
        'actions': <String>['rewrite'],
        'diff': '- 旧段落\n+ 新段落',
      },
    ],
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
    if (path.endsWith('/normalize') && method == 'GET') {
      payload = <String, dynamic>{
        'status': 'planned',
        'run_id': 'run_preview',
        'counts': <String, dynamic>{'files': 2, 'skipped': 0},
      };
    } else if (path.endsWith('/normalize/plan')) {
      payload = <String, dynamic>{
        ..._plan,
        // 预检必须 0 写盘（这里记录 commit 供用例断言）。
        'committed': body['commit'] == true,
      };
    } else if (path.endsWith('/normalize/apply')) {
      payload = <String, dynamic>{
        'status': 'applied',
        'run_id': body['run_id'] ?? 'run_preview',
      };
    } else if (path.endsWith('/normalize/rollback')) {
      payload = <String, dynamic>{
        'status': 'rolled_back',
        'run_id': body['run_id'],
      };
    }
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(payload));
    await request.response.close();
  }
}

Widget _harness() => const MaterialApp(
  home: Scaffold(
    body: ProductionNormalizePage(lineId: 'pl_1', teamId: 'team_a'),
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

/// 等到某个条件成立（真 I/O + 帧）。并发跑全量时机器慢，固定轮数的 `_flyIO`
/// 可能还没把页面建出来 ⇒ `tester.widget` 会抛 "No element"（不是断言失败）。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  int rounds = 80,
}) async {
  for (int i = 0; i < rounds; i++) {
    if (done()) return;
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

  testWidgets('预检：GET normalize + POST plan，展示 path / actions / diff', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_harness());
    await _flyIO(tester);

    expect(core.called('GET', '/api/production/lines/pl_1/normalize'), isTrue);
    const String planPath = '/api/production/lines/pl_1/normalize/plan';
    expect(core.called('POST', planPath), isTrue);
    expect(core.bodyOf('POST', planPath)['commit'], isFalse);

    expect(find.text('docs/README.md'), findsOneWidget);
    expect(find.text('docs/architecture.md'), findsOneWidget);
    expect(find.textContaining('动作：append_index'), findsOneWidget);
    expect(find.textContaining('动作：rewrite'), findsOneWidget);
    expect(find.textContaining('+ 新增索引行'), findsOneWidget);
    expect(find.textContaining('不会自动 git commit'), findsOneWidget);
  });

  testWidgets('rewrite 未确认时 apply 禁用；确认 + allowlist 后可调用', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_harness());
    await _flyIO(tester);
    // 并发跑全量时机器慢：等页面把 apply 按钮建出来再读它（见 [_pumpUntil]）
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('production-normalize-apply'))
          .evaluate()
          .isNotEmpty,
    );

    FilledButton apply() => tester.widget<FilledButton>(
      find.byKey(const Key('production-normalize-apply')),
    );
    expect(apply().onPressed, isNull, reason: '含 rewrite 必须先二次确认');

    await tester.tap(
      find.byKey(const Key('production-normalize-confirm-rewrite')),
    );
    await tester.pump();
    expect(apply().onPressed, isNull, reason: '还要填 allowlist');

    await tester.enterText(
      find.byKey(const Key('production-normalize-allowlist')),
      'docs/architecture.md',
    );
    await tester.pump();
    expect(apply().onPressed, isNotNull);

    await tester.ensureVisible(
      find.byKey(const Key('production-normalize-apply')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('production-normalize-apply')));
    await _flyIO(tester);

    const String applyPath = '/api/production/lines/pl_1/normalize/apply';
    expect(core.called('POST', applyPath), isTrue);
    final Map<String, dynamic> body = core.bodyOf('POST', applyPath);
    expect(body['run_id'], 'run_preview');
    expect(body['confirm_rewrite'], isTrue);
    expect(body['rewrite_allowlist'], contains('docs/architecture.md'));
  });
}
