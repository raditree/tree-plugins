import 'package:flutter/material.dart';

import 'theme_service.dart';

/// 全局主题（用户 2026-11-08：背景中性化——普通 IDE 的黑 / 深灰 / 白，
/// 绿色只留在标志性位置：品牌字标、选中/激活、主操作、焦点与链接、状态语义）。
///
/// 为什么单独抽一层：中性化只动 token，组件全部走 `Theme.of(context)` 取值，
/// 所以这里是"去绿"的唯一主战场；抽出来后可由 `test/theme_neutral_test.dart`
/// 直接断言各 token 的取值，不必启动整个 App。
///
/// 主题色（accent）仍然由 [ThemeService] 派生主色与容器色；但背景 / 表面 /
/// 层次 / 边框 / 正文不再随主题色变化（那是"满屏绿"的根源）。
class AppTheme {
  const AppTheme._();

  // ==================== 深色（VS Code 风格中性灰阶） ====================
  /// 窗口底色
  static const Color neutralBg = Color(0xFF1E1E1E);
  /// 表面（AppBar / 卡片 / 对话框）
  static const Color neutralSurface = Color(0xFF252526);
  /// 抬升面（选中底、路由格、输入区）
  static const Color neutralOverlay = Color(0xFF2D2D2D);
  /// 分割线 / 卡片与对话框描边
  static const Color neutralBorder = Color(0xFF333333);
  /// 默认描边（输入框常态边）
  static const Color neutralOutline = Color(0xFF3C3C3C);
  /// 正文
  static const Color neutralText = Color(0xFFE6E6E6);
  /// 次要文字
  static const Color neutralTextMuted = Color(0xFF9E9E9E);

  // ==================== 浅色（中性白灰阶） ====================
  /// 窗口底色
  static const Color lightBg = Color(0xFFF3F3F3);
  /// 抬升面
  static const Color lightOverlay = Color(0xFFE4E4E4);
  /// 分割线 / 卡片与对话框描边
  static const Color lightBorder = Color(0xFFE0E0E0);
  /// 默认描边（输入框常态边）
  static const Color lightOutline = Color(0xFFD4D4D4);
  /// 正文
  static const Color lightText = Color(0xFF1F1F1F);
  /// 次要文字
  static const Color lightTextMuted = Color(0xFF616161);

  /// 浅色主题：中性白灰底 + 主题色只用于主色 / 选中 / 聚焦。
  ///
  /// [fontFamily] / [fontFamilyFallback] 是运行期字体偏好（字体族）；字重由
  /// `main.dart` 的 `_withUiFont` 落到 textTheme（这里不碰，避免两处各改一半）。
  static ThemeData light(
    Color accent, {
    String? fontFamily,
    List<String>? fontFamilyFallback,
  }) {
    final Color deep = ThemeService.deriveDeep(accent);
    return ThemeData(
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      primaryColor: deep,
      scaffoldBackgroundColor: lightBg,
      cardColor: Colors.white,
      dividerColor: lightBorder,
      dividerTheme: const DividerThemeData(color: lightBorder, thickness: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: deep,
        elevation: 0,
        shape: const Border(
          bottom: BorderSide(color: lightBorder, width: 1),
        ),
      ),
      colorScheme: ColorScheme.light(
        primary: deep,
        onPrimary: Colors.white,
        secondary: deep,
        onSecondary: Colors.white,
        primaryContainer: ThemeService.deriveContainerLight(accent),
        onPrimaryContainer: ThemeService.deriveOnContainerLight(accent),
        secondaryContainer: ThemeService.deriveContainerLight(accent),
        onSecondaryContainer: ThemeService.deriveOnContainerLight(accent),
        surface: Colors.white,
        onSurface: lightText,
        // 显式补充（ColorScheme.light 未传时默认黑色/极端值，会在浅色底上
        // 造成同色不可读或过重描边）：中性灰阶。
        surfaceContainerHighest: lightOverlay,
        onSurfaceVariant: lightTextMuted,
        outline: lightOutline,
      ),
      // 输入框常态中性描边（聚焦时转主题色）
      inputDecorationTheme: InputDecorationTheme(
        enabledBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: lightOutline),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: deep, width: 1.5),
        ),
      ),
      // 卡片 / 对话框：白底 + 中性描边
      cardTheme: CardThemeData(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: lightBorder),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          side: const BorderSide(color: lightBorder),
        ),
      ),
      // 文字选区仍带主题色（属"选中"类），与用户消息块区分开。
      textSelectionTheme: TextSelectionThemeData(
        selectionColor: ThemeService.deriveContainerLight(accent),
        selectionHandleColor: deep,
      ),
      useMaterial3: false,
    );
  }

  /// 深色主题：中性灰阶底 + 主题色只用于主色 / 选中 / 聚焦。
  static ThemeData dark(
    Color accent, {
    String? fontFamily,
    List<String>? fontFamilyFallback,
  }) {
    return ThemeData(
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      brightness: Brightness.dark,
      primaryColor: accent,
      scaffoldBackgroundColor: neutralBg,
      cardColor: neutralSurface,
      dividerColor: neutralBorder,
      dividerTheme: const DividerThemeData(color: neutralBorder, thickness: 1),
      appBarTheme: const AppBarTheme(
        backgroundColor: neutralSurface,
        foregroundColor: neutralText,
        elevation: 0,
        shape: Border(
          bottom: BorderSide(color: neutralBorder, width: 1),
        ),
      ),
      colorScheme: ColorScheme.dark(
        primary: accent,
        onPrimary: ThemeService.deriveOnBright(accent),
        secondary: accent,
        onSecondary: ThemeService.deriveOnBright(accent),
        primaryContainer: ThemeService.deriveContainerDark(accent),
        onPrimaryContainer: ThemeService.deriveOnContainerDark(accent),
        secondaryContainer: ThemeService.deriveContainerDark(accent),
        onSecondaryContainer: ThemeService.deriveOnContainerDark(accent),
        surface: neutralSurface,
        onSurface: neutralText,
        // 显式补充（ColorScheme.dark 未传时默认白色，半透明表层/状态文字
        // 会亮到与深底失去层次，甚至同色不可见）：中性灰阶。
        surfaceContainerHighest: neutralOverlay,
        onSurfaceVariant: neutralTextMuted,
        outline: neutralOutline,
      ),
      inputDecorationTheme: InputDecorationTheme(
        enabledBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: neutralOutline),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: accent, width: 1.5),
        ),
      ),
      cardTheme: CardThemeData(
        color: neutralSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: neutralBorder),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: neutralSurface,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          side: const BorderSide(color: neutralBorder),
        ),
      ),
      // 深色模式下用 cyan 选区，避免与绿色主色/深色背景隐形。
      textSelectionTheme: const TextSelectionThemeData(
        selectionColor: Color(0xFF4DD0E1),
        selectionHandleColor: Color(0xFF00ACC1),
      ),
      useMaterial3: false,
    );
  }
}
