import 'dart:typed_data';

/// 向核心执行站下一条命令（`station/command`）的窄契约。
typedef StationCommandClient =
    Future<Map<String, dynamic>> Function(
      String command,
      Map<String, dynamic> arguments,
      Map<String, dynamic> scope,
    );

/// 工作空间 IO 的窄契约（与 `workspace_io.dart` 的 `WorkspaceIO` 对齐）。
abstract interface class StationWorkspace {
  String get root;

  Future<StationFileContent> readFile(String path, {int? startLine, int? lineCount});

  Future<int> writeFile(String path, String content);

  Future<List<String>> listFiles({String path = '.', int maxDepth = 2, int maxEntries = 500});

  Future<Uint8List> readBytes(String path);
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