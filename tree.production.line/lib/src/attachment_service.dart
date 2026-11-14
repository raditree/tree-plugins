/// 任务附件落盘（Task 6.2）：`production.task.attach`。
///
/// 口径：
/// - 只接受工作空间内相对路径的 `source`，复制到产线自己的插件数据目录
///   `.input/production_lines/<line>/tasks/<task>/attachments/`；
/// - **不写项目资产、不 base64、不把内容写进 `task.yaml`**；`task.yaml` 只登记
///   元数据（path / sha256 / size / type / kind + name / added_at / readable 等）；
/// - 图片先过文件头探测与边界，拒绝时抛结构化 `ProductionFailure`；
/// - 同内容（sha256 相同）不重复落盘，直接回已有元数据并标 `deduplicated`。
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'attachments.dart';
import 'models.dart';
import 'readiness.dart';
import 'store.dart';
import 'structure_service.dart';

/// 附件命令门面（同步：只做文件复制与元数据登记）。
class ProductionAttachmentService {
  Map<String, Object?> attach(
    ProductionStore store,
    Map<String, Object?> arguments,
  ) {
    final String lineId = _argument(arguments, 'line_id');
    final String taskId = _argument(arguments, 'task_id');
    final LineRecord line = store.getLine(lineId);
    final TaskRecord task = store.getTask(lineId, taskId);
    // LG-01 / LG-07：附件属于任务输入，结构 / 就绪门与建任务同一口径。
    requireStructureReady(store, line, taskType: task.taskType);
    requireLineReady(store, line, taskType: task.taskType);

    final String source = textOf(arguments['source']).replaceAll('\\', '/');
    if (!isSafeRelativeTaskPath(source)) {
      throw ProductionFailure(
        '附件 source 必须是工作空间相对路径（拒绝绝对路径 / ..）：$source',
        code: 'invalid_arguments',
        missing: const <String>['source'],
      );
    }
    final String workspace = store.workspaceDirOf(lineId);
    final File file = File(
      p.joinAll(<String>[workspace, ...source.split('/')]),
    );
    if (!file.existsSync()) {
      throw ProductionFailure(
        '附件源文件不存在：$source',
        code: 'attachment_source_missing',
        missing: const <String>['source'],
      );
    }
    final int size = file.lengthSync();
    if (size > kMaxAttachmentBytes) {
      throw ProductionFailure(
        '附件超过 $kMaxAttachmentBytes 字节：$source（$size 字节）',
        code: 'attachment_too_large',
        missing: const <String>['source'],
      );
    }

    final String type = textOf(arguments['type']).isNotEmpty
        ? textOf(arguments['type'])
        : mimeOfPath(source);
    final List<int> bytes = file.readAsBytesSync();
    final String digest = sha256.convert(bytes).toString();
    final String kind = attachmentKindOf(type, kind: textOf(arguments['kind']));
    final bool isImage = kind == 'image';
    final bool vision = arguments['vision'] == true;
    final List<String> warnings = <String>[];
    if (isImage) {
      final AttachmentProbe probe = probeAttachment(bytes, type);
      final String? rejection = attachmentRejectionOf(
        probe: probe,
        bytesLength: bytes.length,
        isImage: true,
      );
      if (rejection != null) {
        throw ProductionFailure(
          _rejectionMessage(rejection, probe, source),
          code: rejection,
          missing: const <String>['source'],
        );
      }
      warnings.addAll(attachmentWarningsOf(probe: probe, vision: vision));
    }

    final List<Map<String, Object?>> existing = task.attachments;
    if (existing.length >= kMaxAttachmentsPerTask) {
      throw ProductionFailure(
        '任务 $taskId 的附件已达上限 $kMaxAttachmentsPerTask 个',
        code: 'attachment_limit',
        missing: const <String>['attachments'],
      );
    }
    for (final Map<String, Object?> item in existing) {
      if (textOf(item['sha256']).toLowerCase() != digest) continue;
      return <String, Object?>{
        'attachment': item,
        'deduplicated': true,
        'task': task.toJson(),
      };
    }

    final String displayName = textOf(arguments['name']).isNotEmpty
        ? textOf(arguments['name'])
        : p.basename(source);
    final String storedName =
        '${digest.substring(0, 8)}-${_safeFileName(displayName)}';
    final String relativeDir = store.attachmentDir(lineId, taskId);
    final String relativePath = p.posix.join(relativeDir, storedName);
    final Directory targetDir = Directory(
      p.joinAll(<String>[workspace, ...relativeDir.split('/')]),
    )..createSync(recursive: true);
    file.copySync(p.join(targetDir.path, storedName));

    final String knownIssue =
        const <String>{'pdf', 'office', 'binary'}.contains(kind)
        ? 'attachment_store_only'
        : '';
    final Map<String, Object?> attachment = <String, Object?>{
      'path': relativePath,
      'sha256': digest,
      'size': bytes.length,
      'type': type,
      'kind': kind,
      'name': displayName,
      'added_at': store.nowText(),
      'readable': kind == 'text',
      'summary_by': isImage
          ? (vision ? 'vision_model' : 'manual_reference')
          : '',
      'warnings': warnings,
      'known_issue': knownIssue,
    };
    final List<Map<String, Object?>> attachments = normalizeAttachments(
      <Object?>[...existing, attachment],
    );
    final TaskRecord saved = store.putTask(lineId, taskId, <String, Object?>{
      'attachments': attachments,
    });
    final List<String> knownIssues = <String>[
      for (final Map<String, Object?> item in attachments)
        if (textOf(item['known_issue']).isNotEmpty) textOf(item['known_issue']),
    ];
    return <String, Object?>{
      'attachment': attachments.last,
      'task': saved.toJson(),
      'warnings': warnings,
      'deduplicated': false,
      'known_issues': knownIssues,
      if (knownIssue.isNotEmpty) 'note': 'PDF/Office/二进制首版只存不读：已落盘登记，内容不送模型',
    };
  }
}

/// 扩展名 → MIME（只做确定性映射；未知按 octet-stream）。
String mimeOfPath(String path) {
  final String extension = p
      .extension(path)
      .replaceFirst('.', '')
      .toLowerCase();
  switch (extension) {
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'webp':
      return 'image/webp';
    case 'gif':
      return 'image/gif';
    case 'svg':
      return 'image/svg+xml';
    case 'pdf':
      return 'application/pdf';
    case 'docx':
      return 'application/'
          'vnd.openxmlformats-officedocument.wordprocessingml.document';
    case 'xlsx':
      return 'application/'
          'vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    case 'pptx':
      return 'application/'
          'vnd.openxmlformats-officedocument.presentationml.presentation';
    case 'doc':
      return 'application/msword';
    case 'xls':
      return 'application/vnd.ms-excel';
    case 'ppt':
      return 'application/vnd.ms-powerpoint';
    case 'txt':
      return 'text/plain';
    case 'md':
      return 'text/markdown';
    case 'json':
      return 'text/json';
    case 'yaml':
    case 'yml':
      return 'text/yaml';
    case 'csv':
      return 'text/csv';
    default:
      return 'application/octet-stream';
  }
}

/// 落盘文件名：只保留 `[A-Za-z0-9._-]`，其余替换为 `_`；空 / `.` / `..` → `file`。
String _safeFileName(String raw) {
  final String base = p.basename(raw.trim().replaceAll('\\', '/'));
  final StringBuffer buffer = StringBuffer();
  for (final int rune in base.runes) {
    final String char = String.fromCharCode(rune);
    buffer.write(RegExp(r'[A-Za-z0-9._-]').hasMatch(char) ? char : '_');
  }
  final String value = buffer.toString();
  if (value.isEmpty || value == '.' || value == '..') return 'file';
  return value;
}

String _rejectionMessage(String code, AttachmentProbe probe, String source) {
  switch (code) {
    case 'attachment_too_large':
      return '附件超过 $kMaxAttachmentBytes 字节：$source';
    case 'image_corrupt':
      return '图片文件头无法解析（可能已损坏）：$source';
    case 'image_too_large':
      return '图片像素超过上限（${probe.width}×${probe.height} > '
          '$kMaxImagePixels）：$source';
    case 'attachment_unsafe_svg':
      return 'SVG 含脚本 / 事件 / javascript:，拒绝作为附件：$source';
    default:
      return '附件被拒绝（$code）：$source';
  }
}

String _argument(Map<String, Object?> arguments, String key) {
  final String value = textOf(arguments[key]);
  if (value.isEmpty) {
    throw ProductionFailure('缺少 $key', code: 'invalid_arguments');
  }
  return value;
}
