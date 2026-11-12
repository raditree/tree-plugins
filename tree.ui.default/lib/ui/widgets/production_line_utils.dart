import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// 产线左栏列表与中栏工作台共用的纯函数 / 文件选择器。
///
/// 两边看同一份 REST 数据，错误文案、状态配色与状态机可用操作必须**同一口径**，
/// 否则同一条任务在两处会给出不同的按钮。

Map<String, dynamic> productionMap(Object? raw) => raw is Map
    ? raw.map(
        (Object? key, Object? value) =>
            MapEntry<String, dynamic>('$key', value),
      )
    : <String, dynamic>{};

List<Map<String, dynamic>> productionListOf(
  Map<String, dynamic> data,
  String key,
) => (data[key] as List<dynamic>? ?? <dynamic>[])
    .whereType<Map>()
    .map(productionMap)
    .toList();

/// 依赖缺失（插件未安装 / 停用 ⇒ 503）必须给出可读说明，而不是把
/// `HTTP 404` 摊在空列表上。
String productionReadable(Object error, String prefix) {
  String text = '$error'.trim();
  if (text.startsWith('Exception: ')) {
    text = text.substring('Exception: '.length).trim();
  }
  final bool missing =
      (text.contains('tree.production.line') || text.contains('503')) &&
      (text.contains('未安装') ||
          text.contains('未启用') ||
          text.contains('不可用') ||
          text.contains('503'));
  if (missing) {
    return '未安装 tree.production.line 插件（或已停用）：产线是独立插件的能力。'
        '在「插件管理」里安装并启用后重启核心即可出现。';
  }
  if (text.contains('504')) {
    return '插件处理超时（HTTP 504）：核心委派只等 30s，操作可能太重；'
        '稍后重试，或把工作空间指向更小的目录。';
  }
  return text.isEmpty ? prefix : '$prefix：$text';
}

Color productionStatusColor(ColorScheme cs, String status) {
  switch (status) {
    case 'done':
      return cs.primary;
    case 'blocked':
    case 'cancelled':
      return cs.error;
    case 'running':
    case 'gating':
    case 'packing':
      return cs.tertiary;
    case 'queued':
    case 'packed':
      return cs.secondary;
    default:
      return cs.outline;
  }
}

/// 任务可用操作：只给状态机允许的那几条（不把按钮摆出来再让后端 409）。
List<String> productionTaskActions(Map<String, dynamic> task) {
  final String status = '${task['status'] ?? ''}';
  return <String>[
    if (status == 'queued' || status == 'packing') 'pack',
    if (status == 'packed') 'run',
    if (status == 'aligning' || status == 'awaiting_user') 'decide',
    // D6-O：主控 / 门控停下的任务可恢复（blocked → queued）。
    if (status == 'blocked') 'resume',
    if (status != 'done' && status != 'cancelled') 'cancel',
  ];
}

String productionActionLabel(String value) {
  switch (value) {
    case 'pack':
      return '打包';
    case 'run':
      return '执行';
    case 'decide':
      return '拍板';
    case 'resume':
      return '恢复';
    case 'cancel':
      return '取消任务';
    default:
      return value;
  }
}

/// 目录选择（取消 / 平台异常都回 null，不把异常抛给面板）。
Future<String?> pickProductionDirectory(String title) async {
  try {
    return await FilePicker.getDirectoryPath(dialogTitle: title);
  } catch (_) {
    return null;
  }
}

/// 文件多选（file_picker 13：`pickFiles` 即多选；返回绝对路径，取消回空列表）。
Future<List<String>> pickProductionFiles(String title) async {
  try {
    final List<PlatformFile> picked = await FilePicker.pickFiles(
      dialogTitle: title,
    );
    return <String>[
      for (final PlatformFile file in picked)
        if (file.path != null && file.path!.isNotEmpty) file.path!,
    ];
  } catch (_) {
    return <String>[];
  }
}

/// 绝对路径 → 工作空间相对路径（Windows 大小写不敏感）；不在空间内回空串。
String productionRelativeToWorkspace(String workspace, String path) {
  final String root = p.normalize(p.absolute(workspace));
  final String target = p.normalize(p.absolute(path));
  final String rootLower = root.toLowerCase();
  final String targetLower = target.toLowerCase();
  if (targetLower == rootLower) return '.';
  final String prefix = rootLower.endsWith(p.separator)
      ? rootLower
      : '$rootLower${p.separator}';
  if (!targetLower.startsWith(prefix)) return '';
  return p.relative(target, from: root).replaceAll('\\', '/');
}
