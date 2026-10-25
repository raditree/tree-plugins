import 'dart:typed_data';

import 'station_workspace_io.dart';
import 'workspace_io.dart';

/// 把执行站的 [StationWorkspaceIo] 适配成领域层用的 [WorkspaceIO] / [WorkspaceFiles]。
///
/// 读/写/列表/原始字节走执行站；执行站未提供的能力（删除、写二进制、建目录）
/// 显式抛可读错误，不静默假装成功。
class StationCompatIo implements WorkspaceIO, WorkspaceFiles {
  StationCompatIo(this.station);

  final StationWorkspaceIo station;

  @override
  String get root => station.root;

  @override
  Future<FileContent> readFile(
    String relativePath, {
    int? startLine,
    int? lineCount,
    int? maxBytes,
  }) async {
    final content = await station.readFile(
      relativePath,
      startLine: startLine,
      lineCount: lineCount,
    );
    return FileContent(
      path: relativePath,
      text: content.text,
      base64: content.base64,
      totalLines: content.totalLines,
      startLine: content.startLine,
      truncated: content.truncated,
    );
  }

  @override
  Future<int> writeFile(String relativePath, String content) =>
      station.writeFile(relativePath, content);

  @override
  Future<bool> deleteFile(String relativePath) async {
    try {
      await station.deleteFile(relativePath);
      return true;
    } on Object {
      return false;
    }
  }

  @override
  Future<List<String>> listFiles({
    String relativePath = '.',
    int maxDepth = 2,
    int maxEntries = 500,
  }) => station.listFiles(
    path: relativePath,
    maxDepth: maxDepth,
    maxEntries: maxEntries,
  );

  @override
  Future<Uint8List> readBytes(String relativePath) =>
      station.readBytes(relativePath);

  @override
  Future<void> writeBytes(String relativePath, List<int> bytes) async {
    await station.writeBytes(relativePath, bytes);
  }

  @override
  Future<int> sizeOf(String relativePath) async =>
      (await station.readBytes(relativePath)).length;

  @override
  Future<void> makeDirectory(String relativePath) async {
    await station.makeDirectory(relativePath);
  }
}