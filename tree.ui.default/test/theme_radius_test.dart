import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree_ui_default/ui/app_radius.dart';
import 'package:tree_ui_default/ui/app_theme.dart';

/// 圆角尺子（用户 2026-11-10：更多圆角化，2 / 6 / 8 / 16 / 999）。
///
/// 锁住三件事：
/// 1. 五档数值不许漂移；
/// 2. 深浅两套主题的所有圆角入口都等于对应常量（防"只改深色"）；
/// 3. `FilledButton` 与 `Chip` 保持自带胶囊形态，不被控件档改方。
void main() {
  const Color accent = Color(0xFF00FF8C);

  BorderRadius? radiusOf(ShapeBorder? shape) {
    if (shape is RoundedRectangleBorder) {
      return shape.borderRadius as BorderRadius?;
    }
    return null;
  }

  void expectRadius(ShapeBorder? shape, double expected, String reason) {
    final BorderRadius? radius = radiusOf(shape);
    expect(radius, isNotNull, reason: '$reason 应是圆角矩形');
    expect(radius!.topLeft.x, expected, reason: reason);
  }

  test('五档数值固定', () {
    expect(AppRadius.xxs, 2);
    expect(AppRadius.xs, 6);
    expect(AppRadius.sm, 8);
    expect(AppRadius.md, 16);
    expect(AppRadius.pill, 999);
  });

  for (final (String name, ThemeData theme) in <(String, ThemeData)>[
    ('深色', AppTheme.dark(accent)),
    ('浅色', AppTheme.light(accent)),
  ]) {
    group('$name主题圆角', () {
      test('卡片 / 对话框走容器档', () {
        expectRadius(theme.cardTheme.shape, AppRadius.md, '卡片');
        expectRadius(theme.dialogTheme.shape, AppRadius.md, '对话框');
      });

      test('输入框常态与聚焦都是控件档', () {
        final OutlineInputBorder enabled =
            theme.inputDecorationTheme.enabledBorder! as OutlineInputBorder;
        final OutlineInputBorder focused =
            theme.inputDecorationTheme.focusedBorder! as OutlineInputBorder;
        expect(enabled.borderRadius.topLeft.x, AppRadius.sm);
        expect(focused.borderRadius.topLeft.x, AppRadius.sm);
      });

      test('三翼按钮 / 菜单 / SnackBar / 复选框 / 滚动条', () {
        final Set<WidgetState> states = <WidgetState>{};
        expectRadius(
          theme.elevatedButtonTheme.style?.shape?.resolve(states),
          AppRadius.sm,
          'ElevatedButton',
        );
        expectRadius(
          theme.outlinedButtonTheme.style?.shape?.resolve(states),
          AppRadius.sm,
          'OutlinedButton',
        );
        expectRadius(
          theme.textButtonTheme.style?.shape?.resolve(states),
          AppRadius.sm,
          'TextButton',
        );
        expectRadius(theme.popupMenuTheme.shape, AppRadius.sm, 'PopupMenu');
        expectRadius(theme.snackBarTheme.shape, AppRadius.sm, 'SnackBar');
        expectRadius(theme.checkboxTheme.shape, AppRadius.xs, 'Checkbox');
        expect(
          theme.scrollbarTheme.radius,
          const Radius.circular(AppRadius.pill),
        );
      });

      test('FilledButton 与 Chip 保持胶囊', () {
        expect(theme.filledButtonTheme.style, isNull, reason: '不覆盖自带形状');
        expect(theme.chipTheme.shape, isA<StadiumBorder>());
      });
    });
  }
}
