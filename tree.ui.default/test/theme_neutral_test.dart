import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree_ui_default/ui/app_theme.dart';
import 'package:tree_ui_default/ui/theme_service.dart';

/// 中性化主题（用户 2026-11-08：「背景改为普通 IDE 的黑色、深灰色或者白色，
/// 只有一些标志性的地方以及一些特殊文字用绿色」）。
///
/// 锁住三件事：
/// 1. 背景 / 表面 / 层次 / 分割线 / 描边 / 正文全部中性（三通道几乎相等，不带绿）；
/// 2. 分割线不再由主题色派生（换主题色不该把背景和边线一起染色）；
/// 3. 主题色仍然只用于主色与输入框聚焦环（标志性位置不被中性化吃掉）。
void main() {
  const Color accent = Color(0xFF00FF8C);
  const Color customAccent = Color(0xFF3B82F6);

  /// 中性 = 三通道几乎相等（容差 2：深色表面取 VS Code 的 `#252526`，
  /// 蓝通道高 1 个值，肉眼与 `#252525` 不可分）。
  bool isNeutral(Color color) {
    final int r = (color.r * 255).round();
    final int g = (color.g * 255).round();
    final int b = (color.b * 255).round();
    final int max = <int>[r, g, b].reduce((int a, int b) => a > b ? a : b);
    final int min = <int>[r, g, b].reduce((int a, int b) => a < b ? a : b);
    return max - min <= 2;
  }

  group('深色：中性灰阶', () {
    final ThemeData theme = AppTheme.dark(accent);
    final ColorScheme cs = theme.colorScheme;

    test('背景 / 表面 / 层次 / 正文都是中性色', () {
      expect(isNeutral(theme.scaffoldBackgroundColor), isTrue, reason: '窗口底色');
      expect(isNeutral(cs.surface), isTrue, reason: '表面');
      expect(isNeutral(theme.cardColor), isTrue, reason: '卡片');
      expect(isNeutral(cs.surfaceContainerHighest), isTrue, reason: '抬升面');
      expect(isNeutral(cs.onSurface), isTrue, reason: '正文');
      expect(isNeutral(cs.onSurfaceVariant), isTrue, reason: '次要文字');
      expect(isNeutral(theme.dividerColor), isTrue, reason: '分割线');
      expect(isNeutral(cs.outline), isTrue, reason: '默认描边');
      expect(isNeutral(theme.appBarTheme.backgroundColor!), isTrue, reason: 'AppBar 底');
      expect(
        isNeutral(theme.appBarTheme.foregroundColor!),
        isTrue,
        reason: 'AppBar 前景',
      );
    });

    test('分割线不再由主题色派生', () {
      expect(theme.dividerColor, isNot(ThemeService.deriveDivider(accent)));
      expect(cs.outline, isNot(ThemeService.deriveOutlineDark(accent)));
      expect(
        theme.dividerColor,
        isNot(ThemeService.deriveDivider(customAccent)),
        reason: '换主题色也不该改变分割线',
      );
    });

    test('主题色仍只用于主色与聚焦环', () {
      expect(cs.primary, accent);
      final InputBorder? focused = theme.inputDecorationTheme.focusedBorder;
      expect(
        (focused! as OutlineInputBorder).borderSide.color,
        accent,
        reason: '输入框聚焦环跟主题色走',
      );
      final InputBorder? enabled = theme.inputDecorationTheme.enabledBorder;
      expect(
        isNeutral((enabled! as OutlineInputBorder).borderSide.color),
        isTrue,
        reason: '常态边框中性',
      );
    });

    test('换自定义主题色：背景与边框不变，只有主色变', () {
      final ThemeData blue = AppTheme.dark(customAccent);
      expect(blue.colorScheme.primary, customAccent);
      expect(blue.scaffoldBackgroundColor, theme.scaffoldBackgroundColor);
      expect(blue.dividerColor, theme.dividerColor);
      expect(blue.colorScheme.onSurface, cs.onSurface);
    });
  });

  group('浅色：中性白灰阶', () {
    final ThemeData theme = AppTheme.light(accent);
    final ColorScheme cs = theme.colorScheme;

    test('背景 / 层次 / 正文都是中性色', () {
      expect(isNeutral(theme.scaffoldBackgroundColor), isTrue, reason: '窗口底色');
      expect(isNeutral(cs.surface), isTrue, reason: '表面');
      expect(isNeutral(cs.surfaceContainerHighest), isTrue, reason: '抬升面');
      expect(isNeutral(cs.onSurface), isTrue, reason: '正文');
      expect(isNeutral(cs.onSurfaceVariant), isTrue, reason: '次要文字');
      expect(isNeutral(theme.dividerColor), isTrue, reason: '分割线');
      expect(isNeutral(cs.outline), isTrue, reason: '默认描边');
      expect(isNeutral(theme.appBarTheme.backgroundColor!), isTrue, reason: 'AppBar 底');
    });

    test('分割线不再由主题色派生', () {
      expect(theme.dividerColor, isNot(ThemeService.deriveDividerLight(accent)));
      expect(cs.outline, isNot(ThemeService.deriveDivider(accent)));
    });

    test('主题色仍用于主色与聚焦环', () {
      expect(cs.primary, ThemeService.deriveDeep(accent));
      final InputBorder? focused = theme.inputDecorationTheme.focusedBorder;
      expect(
        (focused! as OutlineInputBorder).borderSide.color,
        ThemeService.deriveDeep(accent),
      );
      final InputBorder? enabled = theme.inputDecorationTheme.enabledBorder;
      expect(
        isNeutral((enabled! as OutlineInputBorder).borderSide.color),
        isTrue,
      );
    });
  });
}
