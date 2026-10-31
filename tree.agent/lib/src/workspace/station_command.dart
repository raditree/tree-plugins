import 'dart:typed_data';

/// 向核心执行站下一条命令（`station/command`）的窄契约。
typedef StationCommandClient =
    Future<Map<String, dynamic>> Function(
      String command,
      Map<String, dynamic> arguments,
      Map<String, dynamic> scope,
    );

/// 执行站命令失败（**插件侧**的异常形状：可读原因 + 稳定错误码 + 失败载荷）。
///
/// 为什么要有它而不直接用骨架的 `CmdFailureException`：本仓 `lib/` 与
/// `package:tree_agent_loop` 都在包边界内，**不能** import 包外的 `../_kit`；
/// 所以入口（`tree.agent_plugin.dart`，它 import 了 kit）把骨架异常翻译成这个
/// 类型，领域库只认这里。
///
/// 错误码逐字对齐 `tree_protocol` 的 `ExecStationErrorCodes`（契约 §4.2）。
class StationCommandFailure implements Exception {
  const StationCommandFailure(
    this.message, {
    this.code = 'unknown',
    this.payload = const <String, dynamic>{},
  });

  /// 可读原因（给模型/用户看的那句话）。
  final String message;

  /// 稳定错误码；**只有 `lease_unknown` 表示"确定未执行、可安全重发"**。
  final String code;

  /// 失败载荷（核心把插件回包的 `payload` 一起带回来；`llm.call` 已付费正文
  /// 不能丢，见 docs/known-issues.md #31）。
  final Map<String, dynamic> payload;

  @override
  String toString() => message;
}

/// 工作空间 IO 的窄契约（与 `workspace_io.dart` 的 `WorkspaceIO` 对齐）。
abstract interface class StationWorkspace {
  String get root;

  Future<StationFileContent> readFile(String path, {int? startLine, int? lineCount});

  Future<int> writeFile(String path, String content);

  Future<List<String>> listFiles({String path = '.', int maxDepth = 2, int maxEntries = 500});

  Future<Uint8List> readBytes(String path);

  Future<void> deleteFile(String path, {bool recursive = false});

  Future<int> writeBytes(String path, List<int> bytes);

  Future<void> makeDirectory(String path);
}

/// 执行站返回的读取结果（字段与核心 FileContent 对齐）。
class StationFileContent {
  const StationFileContent({
    required this.text,
    this.totalLines = 0,
    this.startLine = 1,
    this.truncated = false,
    this.base64,
  });

  final String text;
  final int totalLines;
  final int startLine;
  final bool truncated;
  final String? base64;
}