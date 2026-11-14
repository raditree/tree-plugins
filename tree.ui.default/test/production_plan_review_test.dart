import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree_ui_default/io/api_service.dart';
import 'package:tree_ui_default/ui/widgets/production_plan_review.dart';

import 'production_ui_fakes.dart';

void main() {
  late ProductionFakeCore core;

  setUp(() async {
    HttpOverrides.global = null;
    core = await ProductionFakeCore.start();
    ApiService.baseUrl = core.baseUrl;
    ApiService.setToken('test-token');
  });

  tearDown(() async {
    await core.close();
    ApiService.setToken(null);
    ApiService.baseUrl = 'http://127.0.0.1:0';
  });

  Future<void> flyIO(WidgetTester tester, {int rounds = 10}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
  }

  Widget harness({Future<void> Function()? onFinalize}) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 900,
        height: 700,
        child: ProductionPlanReview(
          lineId: 'pl_1',
          teamId: 'team_a',
          onFinalize: onFinalize,
        ),
      ),
    ),
  );

  testWidgets('7 块渲染 + open high 阻止落档 + 追踪断链标红 + 批次 / diff', (
    WidgetTester tester,
  ) async {
    core.planV2 = planFixture(openHigh: true, brokenTrace: true);
    core.planV1 = <String, dynamic>{
      'requirements': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'REQ-1', 'text': '旧需求'},
      ],
      'design': <String, dynamic>{'summary': '旧设计'},
      'invariants': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'INV-1', 'text': '旧行为保持'},
      ],
      'tasks': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'T0', 'title': '已删除任务'},
        <String, dynamic>{'id': 'T1', 'title': '旧标题'},
      ],
      'gates': <String, dynamic>{
        'T0': <Map<String, dynamic>>[
          <String, dynamic>{'text': '- [ ] 旧门控', 'evidence': 'old.log'},
        ],
        'T1': <Map<String, dynamic>>[
          <String, dynamic>{'text': '- [ ] dart test 通过', 'evidence': 'runs/T1/test.log'},
        ],
      },
      'traceability': <Map<String, dynamic>>[
        <String, dynamic>{
          'req': 'REQ-1',
          'tasks': <String>['T1'],
          'gates': <Map<String, dynamic>>[
            <String, dynamic>{'task': 'T1', 'text': 'dart test 通过'},
          ],
        },
      ],
      'risks': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'R1', 'text': '旧风险'},
      ],
      'change_control': <String, dynamic>{'plan_version': 'plan-v1'},
      'findings': <Object?>[],
      'rounds': 1,
    };

    var finalized = false;
    await tester.pumpWidget(harness(onFinalize: () async => finalized = true));
    await flyIO(tester);

    for (final String block in <String>[
      '① 方案设计',
      '② 不变量账本',
      '③ 任务 DAG',
      '④ 出口门禁',
      '⑤ 追踪矩阵',
      '⑥ 风险与未知',
      '⑦ 变更控制',
    ]) {
      expect(find.text(block), findsOneWidget, reason: '7 块必须都在');
    }
    expect(find.textContaining('findings · high（1）'), findsOneWidget);
    expect(find.textContaining('写域交叠未解决'), findsOneWidget);
    expect(find.byKey(const Key('production-plan-open-high')), findsOneWidget);

    // 追踪断链：banner + 行标红。
    expect(find.byKey(const Key('production-plan-broken')), findsOneWidget);
    final Text brokenRow = tester.widget<Text>(
      find.textContaining('REQ-2 →'),
    );
    final Color error = Theme.of(
      tester.element(find.byKey(const Key('production-plan-broken'))),
    ).colorScheme.error;
    expect(brokenRow.style?.color, error);
    expect(find.textContaining('断链'), findsWidgets);

    // 批次 / diff。
    expect(find.textContaining('批次 1：'), findsOneWidget);
    expect(find.textContaining('新增任务：T2、T3'), findsOneWidget);
    expect(find.textContaining('删除任务：T0'), findsOneWidget);
    expect(find.textContaining('修改任务：T1'), findsOneWidget);
    expect(find.textContaining('追踪变化：'), findsOneWidget);

    // open high → 落档禁用。
    final FilledButton finalize = tester.widget<FilledButton>(
      find.byKey(const Key('production-plan-finalize')),
    );
    expect(finalize.onPressed, isNull, reason: 'high 未关闭不能落档');
    expect(finalized, isFalse);
  });

  testWidgets('计划干净：落档可用', (WidgetTester tester) async {
    core.planV2 = planFixture();
    core.planV1 = planFixture();
    var finalized = false;
    await tester.pumpWidget(harness(onFinalize: () async => finalized = true));
    await flyIO(tester);

    final FilledButton finalize = tester.widget<FilledButton>(
      find.byKey(const Key('production-plan-finalize')),
    );
    expect(finalize.onPressed, isNotNull);
    await tester.ensureVisible(
      find.byKey(const Key('production-plan-finalize')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('production-plan-finalize')));
    await flyIO(tester);
    expect(finalized, isTrue);
  });
}
