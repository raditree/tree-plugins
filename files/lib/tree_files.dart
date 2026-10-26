/// tree_files —— 文件面板 REST 领域库（插件仓内包）。
///
/// 依赖纪律（与 tree.agent 同口径）：只允许 pub.dev 依赖与插件仓自带的
/// `_kit`，不 import 核心包（tree_core / tree_protocol）。
library;

export 'src/delegate.dart';
export 'src/errors.dart';
export 'src/local_files.dart';
export 'src/remote_files.dart';
export 'src/routes.dart';
export 'src/service.dart';
export 'src/workspace.dart';
