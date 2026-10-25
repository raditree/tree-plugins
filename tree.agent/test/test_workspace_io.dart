import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'package:tree_agent_loop/src/agent/private_paths.dart';
import 'package:tree_agent_loop/src/workspace/workspace_io.dart';

/// 测试用工作空间：直接落在临时目录（与核心 LocalWorkspaceIO 的文本语义一致）。
class TestWorkspaceIO implements WorkspaceIO, WorkspaceFiles {
  TestWorkspaceIO(this.root);

  @override
  final String root;

  String _abs(String relative) => p.join(root, p.normalize(relative));

  @override
  Future<FileContent> readFile(
    String relativePath, {
    int? startLine,
    int? lineCount,
    int? maxBytes,
  }) async {
    final File file = File(_abs(relativePath));
    if (!file.existsSync()) {
      throw WorkspaceIoException('文件不存在：$relativePath');
    }
    final String text = await file.readAsString();
    return FileContent(path: relativePath, text: text);
  }

  @override
  Future<int> writeFile(String relativePath, String content) async {
    final File file = File(_abs(relativePath));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    return content.length;
  }

  @override
  Future<bool> deleteFile(String relativePath) async {
    final File file = File(_abs(relativePath));
    if (!file.existsSync()) return false;
    await file.delete();
    return true;
  }

  @override
  Future<List<String>> listFiles({
    String relativePath = '.',
    int maxDepth = 2,
    int maxEntries = 500,
  }) async {
    final Directory dir = Directory(_abs(relativePath));
    if (!dir.existsSync()) return <String>[];
    final List<String> out = <String>[];
    for (final FileSystemEntity entity in dir.listSync()) {
      final String name = p.basename(entity.path);
      if (entity is Directory) {
        out.add('$name/');
      } else {
        out.add(name);
      }
      if (out.length >= maxEntries) break;
    }
    out.sort();
    return out;
  }

  @override
  Future<Uint8List> readBytes(String relativePath) async =>
      Uint8List.fromList(await File(_abs(relativePath)).readAsBytes());

  @override
  Future<void> writeBytes(String relativePath, List<int> bytes) async {
    final File file = File(_abs(relativePath));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  }

  @override
  Future<int> sizeOf(String relativePath) async =>
      File(_abs(relativePath)).lengthSync();

  @override
  Future<void> makeDirectory(String relativePath) async {
    await Directory(_abs(relativePath)).create(recursive: true);
  }
}

/// 把 `.self/…` 映射到 `.tree/<agent>/.self/…` 的测试装饰器（与核心 PrivateWorkspaceIO 同口径）。
class TestPrivateWorkspaceIO implements WorkspaceIO, WorkspaceFiles {
  TestPrivateWorkspaceIO(this.inner, this.agentId);

  final TestWorkspaceIO inner;
  final String agentId;

  String _map(String relativePath) => mapPrivatePath(relativePath, agentId);

  @override
  String get root => inner.root;

  @override
  Future<FileContent> readFile(
    String relativePath, {
    int? startLine,
    int? lineCount,
    int? maxBytes,
  }) => inner.readFile(
    _map(relativePath),
    startLine: startLine,
    lineCount: lineCount,
    maxBytes: maxBytes,
  );

  @override
  Future<int> writeFile(String relativePath, String content) =>
      inner.writeFile(_map(relativePath), content);

  @override
  Future<bool> deleteFile(String relativePath) =>
      inner.deleteFile(_map(relativePath));

  @override
  Future<List<String>> listFiles({
    String relativePath = '.',
    int maxDepth = 2,
    int maxEntries = 500,
  }) => inner.listFiles(
    relativePath: _map(relativePath),
    maxDepth: maxDepth,
    maxEntries: maxEntries,
  );

  @override
  Future<Uint8List> readBytes(String relativePath) =>
      inner.readBytes(_map(relativePath));

  @override
  Future<void> writeBytes(String relativePath, List<int> bytes) =>
      inner.writeBytes(_map(relativePath), bytes);

  @override
  Future<int> sizeOf(String relativePath) => inner.sizeOf(_map(relativePath));

  @override
  Future<void> makeDirectory(String relativePath) =>
      inner.makeDirectory(_map(relativePath));
}
