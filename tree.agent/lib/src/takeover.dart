import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'paths.dart';

/// 数据接管的落点标记（`<root>/config/takeover.json`）。
///
/// 语义：**原地接管**（文件位置与格式不变，插件直接读写），首次接管时把
/// `agents/` 与 `data/` 各拍一份快照到 `<root>/backups/takeover-<时间戳>/`，
/// 并写这个标记。标记在 = 已接管，不再重复备份。
const String kTakeoverMarkerName = 'takeover.json';

/// 接管完整性由"标记里的 backup_dir 真实存在"共同保证：只有备份真的落地
/// 才写标记，失败时标记不写、用户数据一个字节都不动。
class TakeoverReport {
  const TakeoverReport({
    required this.ok,
    this.alreadyTakenOver = false,
    this.backupDir = '',
    this.copied = const <String>[],
    this.error = '',
  });

  final bool ok;
  final bool alreadyTakenOver;
  final String backupDir;
  final List<String> copied;
  final String error;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'ok': ok,
    'already_taken_over': alreadyTakenOver,
    'backup_dir': backupDir,
    'copied': copied,
    'error': error,
  };
}

/// 回滚结果：把备份覆盖回 `agents/` 与 `data/`，并删除接管标记（下次启动重新接管）。
class RollbackReport {
  const RollbackReport({
    required this.ok,
    this.restored = const <String>[],
    this.backupDir = '',
    this.error = '',
  });

  final bool ok;
  final List<String> restored;
  final String backupDir;
  final String error;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'ok': ok,
    'restored': restored,
    'backup_dir': backupDir,
    'error': error,
  };
}

String takeoverMarkerPath(AgentDataPaths paths) =>
    p.join(paths.root, 'config', kTakeoverMarkerName);

/// 接管状态快照（`--takeover-status` 与排障用）：标记在不在、备份还在不在。
Map<String, dynamic> takeoverStatus(AgentDataPaths paths) {
  final Map<String, dynamic>? marker = _readMarker(paths);
  final String backupDir =
      marker == null ? '' : (marker['backup_dir'] ?? '').toString();
  final bool backupExists =
      backupDir.isNotEmpty && Directory(backupDir).existsSync();
  return <String, dynamic>{
    'taken_over': marker != null && backupExists,
    'marker': takeoverMarkerPath(paths),
    'taken_over_at': marker?['taken_over_at'] ?? '',
    'backup_dir': backupDir,
    'backup_exists': backupExists,
    'problem': marker == null
        ? ''
        : (backupExists ? '' : '接管标记存在，但备份目录不存在'),
  };
}

/// 是否已经完成接管（标记存在且备份目录还在）。
bool isTakenOver(AgentDataPaths paths) {
  final Map<String, dynamic>? marker = _readMarker(paths);
  if (marker == null) return false;
  final String backupDir = (marker['backup_dir'] ?? '').toString();
  return backupDir.isNotEmpty && Directory(backupDir).existsSync();
}

/// 首次接管：一次性备份 `agents/` + `data/`（**只备份一次**）。
///
/// 顺序：复制到 `.part-<时间戳>` → 改名成正式备份目录 → 写标记。
/// 任一步失败：删掉半成品、不写标记，返回可读原因；用户数据保持原样。
TakeoverReport takeOverData(
  AgentDataPaths paths, {
  DateTime? now,
}) {
  final Map<String, dynamic>? existing = _readMarker(paths);
  if (existing != null) {
    final String backupDir = (existing['backup_dir'] ?? '').toString();
    if (backupDir.isNotEmpty && Directory(backupDir).existsSync()) {
      return TakeoverReport(ok: true, alreadyTakenOver: true, backupDir: backupDir);
    }
    // 标记在、备份却丢了：不覆盖旧标记（它记录了那次备份去哪了），并要求人工介入。
    return TakeoverReport(
      ok: false,
      backupDir: backupDir,
      error: '接管标记已存在，但备份目录不存在：$backupDir（请核对备份后再回滚/重新接管）',
    );
  }
  final DateTime at = now ?? DateTime.now();
  final String stamp = _stamp(at);
  final String backupDir = p.join(paths.root, 'backups', 'takeover-$stamp');
  final String partial = '$backupDir.part';
  final List<String> copied = <String>[];
  try {
    final Directory part = Directory(partial);
    if (part.existsSync()) part.deleteSync(recursive: true);
    part.createSync(recursive: true);
    for (final String name in <String>['agents', 'data']) {
      final Directory source = Directory(p.join(paths.root, name));
      if (!source.existsSync()) continue;
      _copyDir(source, Directory(p.join(partial, name)));
      copied.add(name);
    }
    if (Directory(backupDir).existsSync()) {
      Directory(backupDir).deleteSync(recursive: true);
    }
    part.renameSync(backupDir);
  } catch (error) {
    _deleteQuietly(Directory(partial));
    return TakeoverReport(
      ok: false,
      backupDir: backupDir,
      error: '接装备份失败（用户数据未改动）：$error',
    );
  }
  try {
    final File marker = File(takeoverMarkerPath(paths));
    marker.parent.createSync(recursive: true);
    marker.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
        'schema': 1,
        'taken_over_at': at.toIso8601String(),
        'backup_dir': backupDir,
        'copied': copied,
      }),
      flush: true,
    );
  } catch (error) {
    _deleteQuietly(Directory(backupDir));
    return TakeoverReport(
      ok: false,
      backupDir: backupDir,
      error: '接管标记写入失败，已撤销本次备份（用户数据未改动）：$error',
    );
  }
  return TakeoverReport(ok: true, backupDir: backupDir, copied: copied);
}

/// 回滚：用接管时的备份覆盖回 `agents/` 与 `data/`，然后删标记。
///
/// 覆盖语义（不是"删目录再拷"）：备份里的文件逐个写回；接管之后新建、而备份里
/// 没有的文件**保留**（回滚是恢复旧数据，不是时间倒流）。删标记 = 下次启动按
/// 当前数据重新接管。
RollbackReport rollbackTakeover(AgentDataPaths paths) {
  final Map<String, dynamic>? marker = _readMarker(paths);
  if (marker == null) {
    return const RollbackReport(
      ok: false,
      error: '没有接管记录（config/$kTakeoverMarkerName 不存在）：无可回滚',
    );
  }
  final String backupDir = (marker['backup_dir'] ?? '').toString();
  if (backupDir.isEmpty || !Directory(backupDir).existsSync()) {
    return RollbackReport(
      ok: false,
      backupDir: backupDir,
      error: '接管备份目录不存在：$backupDir（拒绝猜路径）',
    );
  }
  final List<String> restored = <String>[];
  try {
    for (final String name in <String>['agents', 'data']) {
      final Directory source = Directory(p.join(backupDir, name));
      if (!source.existsSync()) continue;
      _copyDir(source, Directory(p.join(paths.root, name)));
      restored.add(name);
    }
  } catch (error) {
    return RollbackReport(
      ok: false,
      backupDir: backupDir,
      restored: restored,
      error: '回滚中途失败（备份仍在，可修好文件系统后重试）：$error',
    );
  }
  try {
    File(takeoverMarkerPath(paths)).deleteSync();
  } catch (error) {
    return RollbackReport(
      ok: false,
      backupDir: backupDir,
      restored: restored,
      error: '数据已还原，但接管标记删除失败（下次启动会提示标记与备份不一致）：$error',
    );
  }
  return RollbackReport(ok: true, backupDir: backupDir, restored: restored);
}

Map<String, dynamic>? _readMarker(AgentDataPaths paths) {
  final File file = File(takeoverMarkerPath(paths));
  if (!file.existsSync()) return null;
  try {
    final Object? decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) return null;
    return decoded.map((Object? k, Object? v) => MapEntry(k.toString(), v));
  } catch (_) {
    return null;
  }
}

/// 递归复制目录（覆盖同名文件）；目标目录按需创建。
void _copyDir(Directory source, Directory target) {
  if (!target.existsSync()) target.createSync(recursive: true);
  for (final FileSystemEntity entity in source.listSync()) {
    final String name = p.basename(entity.path);
    final String destination = p.join(target.path, name);
    if (entity is Directory) {
      _copyDir(entity, Directory(destination));
    } else if (entity is File) {
      final Directory parent = File(destination).parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      entity.copySync(destination);
    }
  }
}

void _deleteQuietly(Directory dir) {
  try {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  } catch (_) {
    // 半成品清不掉不改变结果（标记未写 = 未接管）。
  }
}

String _stamp(DateTime at) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${at.year}${two(at.month)}${two(at.day)}'
      '${two(at.hour)}${two(at.minute)}${two(at.second)}';
}
