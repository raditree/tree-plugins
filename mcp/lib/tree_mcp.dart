/// tree_mcp —— MCP 客户端与 REST 承接的领域库（插件仓内包）。
///
/// 依赖纪律（与 tree.agent 同口径）：只允许 pub.dev 依赖与插件仓自带的
/// `_kit`，不 import 核心包（tree_core / tree_protocol）。
library;

export 'src/config.dart';
export 'src/config_store.dart';
export 'src/context.dart';
export 'src/delegate.dart';
export 'src/methods.dart';
export 'src/protocol.dart';
export 'src/routes.dart';
export 'src/service.dart';
export 'src/tool_surface.dart';
export 'src/yaml_codec.dart';
