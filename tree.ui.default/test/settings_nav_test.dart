import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tree_ui_default/io/api_service.dart';
import 'package:tree_ui_default/ui/pages/settings_page.dart';

/// 设置页左目录改造（用户 2026-11-08：「改成左侧目录栏，右侧才是具体选项」）。
///
/// 断言四件事：
/// 1. 默认落在「外观」，点目录项切换分类，内容区跟着换（不是所有分区堆一列）；
/// 2. 三档响应式：≥620 文字目录（176）/ 420~619 图标栏（44）/ <420 顶部 chip 行；
/// 3. 切分类不销毁内容（切走再切回，自定义色号草稿还在——IndexedStack 常挂）；
/// 4. 引导的 `focusModels` 直接落在「模型」分类（不再靠滚动锚点）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer fakeCore;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 假核心：全部 404，让设置页的 API 调用走兜底分支（本文件只测布局与导航）。
    fakeCore = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    fakeCore.listen((HttpRequest req) async {
      req.response.statusCode = 404;
      req.response.headers.contentType = ContentType.json;
      req.response.write('{"detail":"未知接口"}');
      await req.response.close();
    });
    ApiService.baseUrl = 'http://127.0.0.1:${fakeCore.port}';
  });

  tearDown(() async {
    await fakeCore.close(force: true);
  });

  void useViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  int contentIndex(WidgetTester tester) {
    final IndexedStack stack = tester.widget<IndexedStack>(
      find.byKey(const Key('settings-category-content')),
    );
    return stack.index ?? 0;
  }

  testWidgets('默认「外观」；点目录项切分类', (WidgetTester tester) async {
    useViewport(tester, const Size(1200, 4000));
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();

    // 分类顺序：外观 / 编辑器 / 模型 / 运行与链路 / 插件 / 窗口与托盘 / 关于
    expect(contentIndex(tester), 0);
    expect(find.text('主题管理'), findsOneWidget);
    expect(find.byKey(const Key('settings-nav-appearance')), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-nav-runtime')));
    await tester.pumpAndSettle();
    expect(contentIndex(tester), 3);
    expect(
      find.byKey(const Key('heartbeat-interval-input')).hitTestable(),
      findsOneWidget,
      reason: '切到「运行与链路」后心跳输入应可交互',
    );

    await tester.tap(find.byKey(const Key('settings-nav-about')));
    await tester.pumpAndSettle();
    expect(contentIndex(tester), 6);
    expect(find.byKey(const Key('version-copy')).hitTestable(), findsOneWidget);
  });

  testWidgets('响应式三档：文字目录 176 / 图标栏 44 / 顶部 chip 行', (
    WidgetTester tester,
  ) async {
    useViewport(tester, const Size(1200, 900));
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const Key('settings-nav-appearance'))).width,
      176,
      reason: '≥620：完整 IDE 双栏（文字目录 176）',
    );
    expect(find.text('外观'), findsOneWidget);

    // 420~619：图标栏（无文字、Tooltip 显示名称）
    useViewport(tester, const Size(500, 900));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const Key('settings-nav-appearance'))).width,
      44,
    );
    expect(find.text('外观'), findsNothing);
    expect(
      tester.widget<Tooltip>(
        find
            .descendant(
              of: find.byKey(const Key('settings-nav-appearance')),
              matching: find.byType(Tooltip),
            )
            .first,
      ).message,
      '外观',
    );

    // <420：顶部一行横向 chip
    useViewport(tester, const Size(360, 900));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-nav-appearance')), findsNothing);
    expect(
      find.byKey(const Key('settings-nav-chip-appearance')),
      findsOneWidget,
    );
    // chip 行可横向滚动：往左拖，后面的分类滚进来再点。
    await tester.drag(
      find.byKey(const Key('settings-nav-chips')),
      const Offset(-200, 0),
    );
    await tester.pumpAndSettle();
    final Finder pluginsChip = find.byKey(
      const Key('settings-nav-chip-plugins'),
    );
    expect(pluginsChip, findsOneWidget);
    await tester.tap(pluginsChip);
    await tester.pumpAndSettle();
    expect(contentIndex(tester), 4);
  });

  testWidgets('切分类再切回：自定义色号草稿仍在（内容不重建）', (
    WidgetTester tester,
  ) async {
    useViewport(tester, const Size(1200, 4000));
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('accent-custom-field')),
      '#123456',
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('settings-nav-model')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-nav-appearance')));
    await tester.pumpAndSettle();

    expect(find.text('#123456'), findsOneWidget, reason: '草稿不因切分类被清空');
    expect(
      find.byKey(const Key('accent-custom-field')).hitTestable(),
      findsOneWidget,
    );
  });

  testWidgets('focusModels：直接选中「模型」分类', (WidgetTester tester) async {
    useViewport(tester, const Size(1200, 2000));
    await tester.pumpWidget(
      const MaterialApp(home: SettingsPage(focusModels: true)),
    );
    await tester.pumpAndSettle();

    expect(contentIndex(tester), 2);
    expect(find.text('自定义模型'), findsOneWidget);
  });
}
