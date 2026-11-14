import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree_ui_default/io/api_service.dart';
import 'package:tree_ui_default/io/protocol_contract.dart';
import 'package:tree_ui_default/ui/widgets/production_line_workbench.dart';

import 'production_ui_fakes.dart';

void main() {
  late ProductionFakeCore core;

  setUp(() async {
    HttpOverrides.global = null;
    core = await ProductionFakeCore.start();
    ApiService.baseUrl = core.baseUrl;
    ApiService.setToken('test-token');
    final DateTime now = DateTime.now();
    core.tasks = <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'T1',
        'title': '拍板任务',
        'status': 'aligning',
        'write_scope': <String>['lib/'],
      },
      <String, dynamic>{
        'id': 'T2',
        'title': '冲突任务',
        'status': 'blocked',
        'blocked_reason': 'write_scope_overlap with T9',
        'write_scope': <String>['lib/'],
      },
      <String, dynamic>{'id': 'T3', 'title': '跑着的任务', 'status': 'running'},
      <String, dynamic>{
        'id': 'T4',
        'title': '刚完成的任务',
        'status': 'done',
        'updated_at': now.toIso8601String(),
      },
      <String, dynamic>{
        'id': 'T5',
        'title': '昨天的任务',
        'status': 'done',
        'updated_at': now
            .subtract(const Duration(days: 2))
            .toIso8601String(),
      },
      <String, dynamic>{'id': 'T7', 'title': '草稿任务', 'status': 'draft'},
    ];
  });

  tearDown(() async {
    await core.close();
    ApiService.setToken(null);
    ApiService.baseUrl = 'http://127.0.0.1:0';
  });

  Future<void> flyIO(WidgetTester tester, {int rounds = 8}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
  }

  Widget harness() => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 1000,
        height: 720,
        child: ProductionLineWorkbench(
          line: <String, dynamic>{
            'id': 'pl_1',
            'name': '标准开发流',
            'status': 'working',
            'workspace_dir': 'E:/work/demo',
          },
          teamId: 'team_a',
          deliveries: const Stream<StationDelivery>.empty(),
          pollInterval: const Duration(days: 1),
        ),
      ),
    ),
  );

  testWidgets('四入口切换；今日只显示待决定/需处理/正在跑/刚完成', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await flyIO(tester);

    expect(find.text('决策收件箱（1）'), findsOneWidget);
    expect(find.text('任务队列（1）'), findsOneWidget);
    expect(find.text('正在跑（1）'), findsOneWidget);
    expect(find.text('刚完成（1）'), findsOneWidget);
    expect(find.textContaining('待决定 ·'), findsOneWidget);
    expect(find.textContaining('需处理 ·'), findsOneWidget);

    // 昨日完成 / 草稿不在今日。
    expect(find.textContaining('T5'), findsNothing);
    expect(find.textContaining('草稿任务'), findsNothing);

    // blocked 文案人话化：显示原因与下一步，不直接摊英文错误码。
    expect(find.textContaining('写域'), findsWidgets);
    expect(find.textContaining('下一步：'), findsWidgets);
    expect(find.textContaining('write_scope_overlap'), findsNothing);

    // 准备：draft / aligning 才出现。
    await tester.tap(find.byKey(const Key('production-tab-prepare')));
    await tester.pump();
    expect(find.byKey(const Key('production-prepare-tab')), findsOneWidget);
    expect(find.textContaining('拍板任务'), findsOneWidget);
    expect(find.textContaining('草稿任务'), findsOneWidget);
    expect(find.byKey(const Key('production-prepare-open-T1')), findsOneWidget);

    // 执行：running 任务 + 批量派发入口。
    await tester.tap(find.byKey(const Key('production-tab-execution')));
    await flyIO(tester);
    expect(find.byKey(const Key('production-execution-tab')), findsOneWidget);
    expect(find.textContaining('T3'), findsWidgets);
    expect(
      find.byKey(const Key('production-bulk-dry-pl_1')),
      findsOneWidget,
    );

    // 工具：结构 / 归一化 / 计划审查 / 漂移 / 配置 / 迁移都在。
    await tester.tap(find.byKey(const Key('production-tab-tools')));
    await flyIO(tester);
    expect(find.byKey(const Key('production-tools-tab')), findsOneWidget);
    expect(find.text('结构整理'), findsWidgets);
    expect(find.text('文档归一化'), findsWidgets);
    expect(find.text('计划审查'), findsOneWidget);
    expect(find.text('漂移报告'), findsOneWidget);
    expect(find.text('存量迁移'), findsOneWidget);
  });
}
