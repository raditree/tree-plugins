import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree_ui_default/io/api_service.dart';
import 'package:tree_ui_default/ui/widgets/production_prepare_page.dart';

import 'production_ui_fakes.dart';

void main() {
  late ProductionFakeCore core;

  Map<String, dynamic> prepareTask() => <String, dynamic>{
    'id': 'T1',
    'title': '会话过滤',
    'status': 'aligning',
    'task_type': 'code',
    'intake': <String, dynamic>{
      'goal': '会话列表按项目过滤',
      'current': '只有 flat 列表',
      'acceptance': '只剩该项目；有测试',
      'constraints': '不改协议',
      'out_of_scope': '不做搜索',
    },
    'recon': <String, dynamic>{
      'digest': <String, dynamic>{
        'requirement_summary': '给会话列表加项目过滤。',
        'keywords': <String>['会话', '过滤', '项目'],
        'constraints': <String>['不改协议'],
        'ambiguities': <String>['空项目怎么显示'],
        'attachment_summaries': <String>['设计稿：过滤下拉'],
      },
      'evidence': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'E1',
          'doc': 'docs/session.md',
          'heading': '会话列表',
          'snippet': '列表当前不分组',
        },
      ],
      'partial': true,
      'degraded': true,
      'recall_gap': true,
      'timeout': false,
      'stale': false,
      'digest_ms': 120,
      'retrieve_ms': 340,
      'llm_ms': 560,
      'total_ms': 1020,
      'questions': 2,
      'open': 1,
    },
  };

  setUp(() async {
    HttpOverrides.global = null;
    core = await ProductionFakeCore.start();
    ApiService.baseUrl = core.baseUrl;
    ApiService.setToken('test-token');
    core.tasks = <Map<String, dynamic>>[prepareTask()];
    core.planV2 = planFixture();
    core.questions = <Map<String, dynamic>>[
      <String, dynamic>{
        'qid': 'Q1',
        'text': '空项目怎么显示？',
        'default': '显示在未分组',
        'recommended': '显示在未分组',
        'consequence': '影响筛选结果',
      },
    ];
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

  Widget harness(Map<String, dynamic> task) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 980,
        height: 720,
        child: ProductionPreparePage(
          lineId: 'pl_1',
          taskId: 'T1',
          task: task,
          teamId: 'team_a',
        ),
      ),
    ),
  );

  testWidgets('四步推进：理解卡分段耗时 + partial 徽标 + 未答禁止落档', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(harness(prepareTask()));
    await flyIO(tester);

    // ① 建需求：五栏可见。
    expect(find.byKey(const Key('production-prepare-intake')), findsOneWidget);
    expect(find.textContaining('会话列表按项目过滤'), findsOneWidget);

    // ② 侦查：分段耗时 / 覆盖 / partial / 证据可点。
    await tester.tap(find.byKey(const Key('production-prepare-step-2')));
    await tester.pump();
    expect(find.byKey(const Key('production-recon-timing')), findsOneWidget);
    expect(find.text('摘要'), findsWidgets);
    expect(find.text('检索'), findsWidgets);
    expect(find.text('模型'), findsWidgets);
    expect(find.byKey(const Key('production-recon-badge-partial')), findsOneWidget);
    expect(find.textContaining('问题 1/2'), findsOneWidget);
    expect(find.textContaining('证据 1'), findsOneWidget);
    expect(find.textContaining('关键词 3'), findsOneWidget);
    expect(find.byKey(const Key('production-evidence-E1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('production-evidence-E1')));
    await tester.pump();
    expect(find.textContaining('已复制证据路径'), findsOneWidget);

    // ③ 拍板：剩余 qid 可见。
    await tester.tap(find.byKey(const Key('production-prepare-step-3')));
    await tester.pump();
    expect(
      find.textContaining('剩余未答：Q1'),
      findsOneWidget,
    );

    // ④ 计划审查：还有未答问题 → 落档禁用。
    await tester.tap(find.byKey(const Key('production-prepare-step-4')));
    await flyIO(tester);
    expect(find.textContaining('先回答剩余问题'), findsOneWidget);
    final FilledButton finalize = tester.widget<FilledButton>(
      find.byKey(const Key('production-prepare-finalize')),
    );
    expect(finalize.onPressed, isNull, reason: '有未答问题时不能落档');
  });

  testWidgets('问题答完且计划干净：落档可用并 POST finalize', (
    WidgetTester tester,
  ) async {
    core.questions = <Map<String, dynamic>>[];
    await tester.pumpWidget(harness(prepareTask()));
    await flyIO(tester);

    await tester.tap(find.byKey(const Key('production-prepare-step-4')));
    await flyIO(tester);

    final FilledButton finalize = tester.widget<FilledButton>(
      find.byKey(const Key('production-prepare-finalize')),
    );
    expect(finalize.onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('production-prepare-finalize')));
    await flyIO(tester);

    expect(
      core.called('POST', '/api/production/lines/pl_1/tasks/T1/finalize'),
      isTrue,
    );
  });
}
