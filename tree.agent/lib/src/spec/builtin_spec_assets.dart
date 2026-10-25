import 'dart:io';

import 'package:path/path.dart' as p;

import '../workspace/workspace_io.dart';
import 'builtin_specs.dart';

/// 插件开发指南在工作空间里的落点（与核心 `kPluginGuideWorkspacePath` 同值）。
const String kPluginGuideWorkspacePath = '.self/docs/plugin-development.md';

/// 选中内置规范时，把它引用的**随附文档**播种到工作空间。
///
/// 插件侧简化：只处理 `plugin-creator` 的 `plugin-development.md`（不再搬运
/// 核心应用目录里的整套插件文档）；查找顺序 overrideDir → currentDir →
/// executableDir，找不到就如实回报 `missing` + 找过的路径。
Future<List<Map<String, dynamic>>> seedBuiltinSpecAssets(
  WorkspaceIO io,
  List<String> specIds, {
  String? executableDir,
  String? overrideDir,
  String? currentDir,
  void Function(String message)? log,
}) async {
  final List<Map<String, dynamic>> results = <Map<String, dynamic>>[];
  for (final String id in specIds) {
    if (id != kPluginCreatorSpecId) continue;
    final List<String> searched = <String>[];
    String? found;
    for (final String? dir in <String?>[overrideDir, currentDir, executableDir]) {
      if (dir == null || dir.trim().isEmpty) continue;
      final String path = p.join(dir, 'plugin-development.md');
      searched.add(path);
      if (File(path).existsSync()) {
        found = path;
        break;
      }
    }
    if (found == null) {
      log?.call('未找到 plugin-development.md（找过：${searched.join('、')}）');
      results.add(<String, dynamic>{
        'spec_id': id,
        'path': kPluginGuideWorkspacePath,
        'action': 'missing',
        'searched': searched,
      });
      continue;
    }
    final String text = File(found).readAsStringSync();
    String action;
    try {
      final String current = (await io.readFile(kPluginGuideWorkspacePath)).text;
      action = current == text ? 'unchanged' : 'updated';
    } on WorkspaceIoException {
      action = 'created';
    }
    await io.writeFile(kPluginGuideWorkspacePath, text);
    results.add(<String, dynamic>{
      'spec_id': id,
      'path': kPluginGuideWorkspacePath,
      'action': action,
      'source': found,
    });
  }
  return results;
}
