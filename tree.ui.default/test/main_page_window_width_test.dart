import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree_ui_default/io/api_service.dart';
import 'package:tree_ui_default/ui/pages/main_page.dart';
import 'package:tree_ui_default/ui/widgets/message_panel.dart';

/// 右栏窗口**按内容自适应宽度**（用户 2026-11-08：「右栏窗口允许打开时根据具体
/// 的内容调整窗口的大小（如拉大右栏）。但保证用户主动缩小后仍可用」）。
///
/// 口径（方案 D7）：
/// - 用户主动打开 / 聚焦某窗时，右栏按该窗的 `preferredWidth` **只放宽**；
/// - 预算由既有 `_dragCouple` 夹取（中栏保底 360、左栏最低 200），不溢出；
/// - 用户拖过右栏分隔条后，本会话内不再自动放宽；
/// - 中栏折叠（右栏承接空间）时，宽度请求不参与。
///
/// 测试窗口 2000×1000：可用宽 2000，固定占用 60（活动栏 48 + 两个 6px 分隔条），
/// 两栏合计预算 = 1940 - 360 = 1580，断言可算精确值。
void main() {
  const Size desktop = Size(2000, 1000);
  const double centerMin = 360;

  setUp(() {
    ApiService.baseUrl = 'http://127.0.0.1:0';
  });

  double sidebarWidth(WidgetTester tester, String which) =>
      tester.getSize(find.byKey(ValueKey<String>('main-$which-sidebar'))).width;

  double rightWidth(WidgetTester tester) => sidebarWidth(tester, 'right');
  double leftWidth(WidgetTester tester) => sidebarWidth(tester, 'left');

  double centerWidth(WidgetTester tester) =>
      tester.getSize(find.byType(MessagePanel)).width;

  Future<void> pumpMainPage(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: MainPage()));
    await tester.pump();
  }

  /// 点活动栏底部的「设置」入口：外部 openRequest → 宿主 didUpdateWidget →
  /// 帧后回调改宽度（所以要多泵一帧让 post-frame 生效）。
  Future<void> openSettingsFromActivityBar(WidgetTester tester) async {
    await tester.tap(find.byTooltip('设置'));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('从活动栏打开「设置」：右栏放宽到 720，中栏仍 ≥360', (
    WidgetTester tester,
  ) async {
    await pumpMainPage(tester, desktop);
    expect(rightWidth(tester), 340, reason: '初始宽度，且默认窗口不请求放宽');

    await openSettingsFromActivityBar(tester);

    expect(rightWidth(tester), closeTo(720, 1), reason: '设置窗期望宽度 720');
    expect(leftWidth(tester), 260, reason: '中栏还有富余，左栏不动');
    expect(centerWidth(tester), greaterThanOrEqualTo(centerMin - 1));
    expect(tester.takeException(), isNull, reason: '不应有 RenderFlex overflow');
  });

  testWidgets('窗口只有 1100 宽时打开设置：只到预算允许的最大值，不溢出', (
    WidgetTester tester,
  ) async {
    await pumpMainPage(tester, const Size(1100, 900));

    await openSettingsFromActivityBar(tester);

    // 预算：1100 - 60 - 360 = 680；右栏最多 = 680 - 左栏下限 200 = 480
    // （再宽就要压破中栏），中栏正好落在 360 的底线、左栏让到 200。
    expect(rightWidth(tester), closeTo(480, 1));
    expect(centerWidth(tester), greaterThanOrEqualTo(centerMin - 1));
    expect(leftWidth(tester), 200);
    expect(tester.takeException(), isNull);
  });

  testWidgets('用户拖窄过右栏后打开设置：保持用户宽度，设置页降级为 chip 导航', (
    WidgetTester tester,
  ) async {
    await pumpMainPage(tester, desktop);

    // 把右栏拖窄（向右拖 = 变窄）。手势 slop 会吃掉约 20px。
    final Finder divider = find.byType(DraggableDivider).at(1);
    final TestGesture g = await tester.startGesture(tester.getCenter(divider));
    await tester.pump(const Duration(milliseconds: 16));
    for (int i = 0; i < 10; i++) {
      await g.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();
    final double userWidth = rightWidth(tester);
    expect(userWidth, lessThan(420), reason: '已拖到窄态（走 chip 导航的那一档）');

    await openSettingsFromActivityBar(tester);

    expect(rightWidth(tester), userWidth, reason: '用户缩过就保持，不再被拉宽');
    // 窄态下设置页仍可用：顶部 chip 导航在（内容宽 < 420）
    expect(
      find.byKey(const Key('settings-nav-chip-appearance')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('中栏折叠时打开窗口：右栏宽度不被该请求改写', (
    WidgetTester tester,
  ) async {
    await pumpMainPage(tester, desktop);

    await tester.tap(find.byTooltip('折叠中栏'));
    await tester.pumpAndSettle();
    await openSettingsFromActivityBar(tester);

    // 中栏折叠时右栏承接让出的空间（宽度由父级决定），这里只验证"请求没改状态"：
    // 展开中栏后右栏回到原宽度。
    await tester.tap(find.byTooltip('展开中栏'));
    await tester.pumpAndSettle();
    expect(rightWidth(tester), 340);
    expect(tester.takeException(), isNull);
  });
}
