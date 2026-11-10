/// 圆角尺子（用户 2026-11-10 定稿：2 / 6 / 8 / 16 / 999）。
///
/// 为什么单独一个文件：组件层只依赖这几个常量，不必为了一个半径把
/// `theme_service` / Material 主题拖进 30 多个 widget；改档只改这里。
///
/// 口径：
/// - [xxs] 2：栏级表面（侧栏列底、条底、终端底、文件 tab 条）只收边；
/// - [xs] 6：微件（关闭键、小徽标、行 hover）；
/// - [sm] 8：控件（输入框、按钮、菜单、工具行、代码块、面板 chip）；
/// - [md] 16：容器（卡片、对话框、picker 格、附件卡、气泡、composer）；
/// - [pill] 999：胶囊（状态徽标、pill、进度条、滚动条、开关）。
class AppRadius {
  const AppRadius._();

  /// 栏级表面：只做 2px 收边，不切内容。
  static const double xxs = 2;

  /// 微件：关闭键、小徽标、行 hover。
  static const double xs = 6;

  /// 控件：输入框、按钮、菜单、工具行、代码块、面板 chip。
  static const double sm = 8;

  /// 容器：卡片、对话框、picker 格、附件卡、气泡、composer。
  static const double md = 16;

  /// 胶囊：状态徽标、pill、进度条、滚动条、开关。
  static const double pill = 999;
}
