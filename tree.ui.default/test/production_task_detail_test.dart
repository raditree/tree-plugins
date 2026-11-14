import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree_ui_default/io/api_service.dart';
import 'package:tree_ui_default/ui/widgets/production_task_detail_panel.dart';

import 'production_ui_fakes.dart';

void main() {
  late ProductionFakeCore core;

  Map<String, dynamic> detailTask({String evidence = 'runs/T1/test.log'}) =>
      <String, dynamic>{
        'id': 'T1',
        'title': '会话过滤',
        'status': 'gating',
        'task_type': 'code',
        'brief': '给会话列表加项目过滤。',
        'acceptance': <String>['只剩该项目会话', '有测试'],
        'references': <String>['docs/session.md'],
        'attachments': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'design.png',
            'path': '.input/design.png',
            'sha256': 'abcdef1234567890',
            'size': 2048,
            'type': 'image/png',
            'kind': 'image',
            'summary_by': 'manual_reference',
          },
        ],
        'write_scope': <String>['lib/a/'],
        'read_scope': <String>['docs/'],
        'depends_on': <String>[],
        'conflicts_with': <String>[],
        'risk': 'medium',
        'estimated_files': 3,
        'contract': <String, dynamic>{'input': '会话', 'output': '过滤后列表'},
        'changed_files': <String>['lib/a/session.dart'],
        'pack': <String, dynamic>{'role': 'packer', 'files': 1},
        'gate': <String, dynamic>{
          'checklist': <Map<String, dynamic>>[
            <String, dynamic>{
              'text': 'dart test 通过',
              'evidence': evidence,
            },
          ],
        },
        'last_gate': <String, dynamic>{
          'commands': <Map<String, dynamic>>[
            <String, dynamic>{'command': 'dart test', 'ok': true},
          ],
        },
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'expert', 'text': '建议先读再写'},
        ],
      };

  setUp(() async {
    HttpOverrides.global = null;
    core = await ProductionFakeCore.start();
    ApiService.baseUrl = core.baseUrl;
    ApiService.setToken('test-token');
    core.tasks = <Map<String, dynamic>>[detailTask()];
    core.planV2 = planFixture();
    core.runs = <Map<String, dynamic>>[
      <String, dynamic>{
        'run_id': 'r1',
        'task_id': 'T1',
        'role': 'expert',
        'status': 'done',
        'action': 'ask_expert',
        'report': '结论：可以按项目过滤',
      },
      <String, dynamic>{
        'run_id': 'r2',
        'task_id': 'T1',
        'role': 'executor',
        'status': 'done',
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

  Widget harness() => const MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 560,
        height: 720,
        child: ProductionTaskDetailPanel(
          lineId: 'pl_1',
          taskId: 'T1',
          teamId: 'team_a',
        ),
      ),
    ),
  );

  testWidgets('右栏 6 个 Tab；证据可点；门控通过时完成可用', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await flyIO(tester);

    for (final String tab in <String>[
      'production-task-tab-overview',
      'production-task-tab-plan',
      'production-task-tab-pack',
      'production-task-tab-gate',
      'production-task-tab-message',
      'production-task-tab-runs',
    ]) {
      expect(find.byKey(Key(tab)), findsOneWidget, reason: '6 个 Tab 都要在');
    }

    // 概览：内容 / 验收 / 附件 sha256 前缀 / 人工参考警告。
    expect(find.textContaining('会话过滤'), findsOneWidget);
    expect(find.textContaining('给会话列表加项目过滤'), findsOneWidget);
    expect(find.textContaining('只剩该项目会话'), findsOneWidget);
    expect(find.textContaining('sha256 abcdef12'), findsOneWidget);
    expect(find.textContaining('图片需人工参考'), findsOneWidget);

    // 计划。
    await tester.tap(find.byKey(const Key('production-task-tab-plan')));
    await tester.pumpAndSettle();
    expect(find.textContaining('plan-v2'), findsOneWidget);
    expect(find.textContaining('计划任务条目'), findsOneWidget);
    expect(find.textContaining('- [ ] dart test 通过'), findsOneWidget);

    // 打包。
    await tester.tap(find.byKey(const Key('production-task-tab-pack')));
    await tester.pumpAndSettle();
    expect(find.textContaining('pack.json 摘要'), findsOneWidget);
    expect(find.textContaining('lib/a/session.dart'), findsOneWidget);

    // 门控：证据可点 + 完成可用。
    await tester.tap(find.byKey(const Key('production-task-tab-gate')));
    await tester.pumpAndSettle();
    expect(find.textContaining('- [ ] dart test 通过'), findsOneWidget);
    await tester.tap(find.byKey(const Key('production-task-evidence-0')));
    await tester.pump();
    expect(find.textContaining('已复制证据路径'), findsOneWidget);
    final FilledButton done = tester.widget<FilledButton>(
      find.byKey(const Key('production-task-done')),
    );
    expect(done.onPressed, isNotNull);

    // 消息专家 / 台账。
    await tester.tap(find.byKey(const Key('production-task-tab-message')));
    await tester.pumpAndSettle();
    expect(find.textContaining('专家报告'), findsOneWidget);
    expect(find.textContaining('结论：可以按项目过滤'), findsOneWidget);

    await tester.tap(find.byKey(const Key('production-task-tab-runs')));
    await tester.pumpAndSettle();
    expect(find.textContaining('运行台账'), findsOneWidget);
    expect(find.textContaining('r2'), findsOneWidget);
  });

  testWidgets('门控缺 evidence：完成按钮禁用并说明缺什么', (WidgetTester tester) async {
    core.tasks = <Map<String, dynamic>>[detailTask(evidence: '')];
    await tester.pumpWidget(harness());
    await flyIO(tester);

    await tester.tap(find.byKey(const Key('production-task-tab-gate')));
    await tester.pumpAndSettle();
    expect(find.textContaining('缺 evidence'), findsWidgets);

    final FilledButton done = tester.widget<FilledButton>(
      find.byKey(const Key('production-task-done')),
    );
    expect(done.onPressed, isNull, reason: '缺 evidence 不得完成');
  });
}
