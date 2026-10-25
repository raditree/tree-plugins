/// 工作空间 IO 的**最小契约**（A3 插件侧）。
///
/// 核心的这一层来自 `tree_local_exec`（本机 + SSH 两个实现，接口很大）。插件不能依赖
/// 那个包；生成引擎当前只用到"读文件 / 写文件 / 读原始字节 / 根目录"这几项，所以先按
/// **实际用到的成员**声明一个窄接口。执行站（L-24）接线后由站内实现补全/替换。
library;

import 'dart:typed_data';

/// 读取结果（字段与核心 `FileContent` 对齐；插件侧只声明实际用到的部分）。
class FileContent {
  const FileContent({
    required this.path,
    this.text = '',
    this.base64,
    this.totalLines = 0,
    this.startLine = 1,
    this.truncated = false,
    this.language = '',
  });

  final String path;
  final String text;
  final String? base64;
  final int totalLines;
  final int startLine;
  final bool truncated;
  final String language;
}

/// 工作空间 IO 错误（可读文案；与核心 `WorkspaceIoException` 同形）。
class WorkspaceIoException implements Exception {
  WorkspaceIoException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// SSH 链路失活（与核心 `SshLinkStaleException` 同形：可单独分类处理）。
class SshLinkStaleException extends WorkspaceIoException {
  SshLinkStaleException(super.message);
}

/// 工作空间 IO（A3 引擎用到的子集）。
abstract interface class WorkspaceIO {
  /// 工作空间根目录（绝对路径）。
  String get root;

  /// 读取文件（图像等二进制返回 base64）。
  Future<FileContent> readFile(
    String relativePath, {
    int? startLine,
    int? lineCount,
    int? maxBytes,
  });

  /// 写入文件（自动创建父目录），返回写入字节数。
  Future<int> writeFile(String relativePath, String content);

  /// 删除一个文件（不存在返回 false）。
  Future<bool> deleteFile(String relativePath);

  /// 列出目录（相对路径，含目录尾斜杠标记）。
  Future<List<String>> listFiles({
    String relativePath = '.',
    int maxDepth = 2,
    int maxEntries = 500,
  });
}

/// 文件面板/原始字节能力（与 [WorkspaceIO] 并列；本地与 SSH 都实现）。
abstract interface class WorkspaceFiles {
  Future<Uint8List> readBytes(String relativePath);

  Future<void> writeBytes(String relativePath, List<int> bytes);

  Future<int> sizeOf(String relativePath);

  /// 新建一层目录（调用方通常忽略返回细节）。
  Future<void> makeDirectory(String relativePath);
}

/// 能按 agent 解析工作空间 IO 的工具执行器（核心 `WorkspaceToolRunner.ioFor` 的窄契约）。
///
/// 引擎用它把超长工具结果写到与工具**同一份**工作空间；执行站接线后由真正的工具运行器
/// 实现这个接口。
abstract interface class WorkspaceIoProvider {
  Future<WorkspaceIO?> ioFor(String agentId);
}
