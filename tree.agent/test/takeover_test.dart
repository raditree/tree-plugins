import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_agent_loop/src/paths.dart';
import 'package:tree_agent_loop/src/takeover.dart';

/// 数据接管 + 回滚（agent_pluginization.md §4.5 / L-05 / known-issues #39）。
void main() {
  late Directory temp;
  late AgentDataPaths paths;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_agent_takeover_');
    paths = AgentDataPaths(temp.path);
    Directory(p.join(temp.path, 'agents')).createSync(recursive: true);
    File(p.join(temp.path, 'agents', 'agt.yaml'))
        .writeAsStringSync('id: agt\nname: 夹具\n');
    Directory(p.join(temp.path, 'data', 'agt', 's1')).createSync(recursive: true);
    File(p.join(temp.path, 'data', 'agt', 's1', 'messages.jsonl'))
        .writeAsStringSync('{"role":"user","content":"旧消息"}\n');
  });

  tearDown(() {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('首次接管：一次性备份 agents/data 并写标记', () {
    final TakeoverReport report = takeOverData(
      paths,
      now: DateTime(2026, 1, 2, 3, 4, 5),
    );
    expect(report.ok, isTrue);
    expect(report.alreadyTakenOver, isFalse);
    expect(report.copied, containsAll(<String>['agents', 'data']));
    expect(report.backupDir, endsWith('takeover-20260102030405'));

    expect(Directory(report.backupDir).existsSync(), isTrue);
    expect(
      File(p.join(report.backupDir, 'agents', 'agt.yaml')).existsSync(),
      isTrue,
    );
    expect(
      File(
        p.join(report.backupDir, 'data', 'agt', 's1', 'messages.jsonl'),
      ).existsSync(),
      isTrue,
    );

    final Map<String, dynamic> marker =
        jsonDecode(File(takeoverMarkerPath(paths)).readAsStringSync())
            as Map<String, dynamic>;
    expect(marker['schema'], 1);
    expect(marker['backup_dir'], report.backupDir);
    expect(isTakenOver(paths), isTrue);
  });

  test('再次启动不重复备份（标记即幂等键）', () {
    final TakeoverReport first = takeOverData(
      paths,
      now: DateTime(2026, 1, 2, 3, 4, 5),
    );
    expect(first.ok, isTrue);
    final TakeoverReport second = takeOverData(
      paths,
      now: DateTime(2026, 1, 2, 3, 4, 6),
    );
    expect(second.ok, isTrue);
    expect(second.alreadyTakenOver, isTrue);
    expect(second.backupDir, first.backupDir);

    final List<FileSystemEntity> backups = Directory(
      p.join(temp.path, 'backups'),
    ).listSync();
    expect(backups, hasLength(1), reason: '只允许一份接管备份');
  });

  test('回滚：覆盖回旧数据、保留接管后新建文件、删标记', () {
    final TakeoverReport report = takeOverData(
      paths,
      now: DateTime(2026, 1, 2, 3, 4, 5),
    );
    expect(report.ok, isTrue);

    // 接管后：改旧文件内容 + 新建一个备份里没有的文件。
    File(p.join(temp.path, 'agents', 'agt.yaml'))
        .writeAsStringSync('id: agt\nname: 改过的名字\n');
    File(p.join(temp.path, 'data', 'agt', 's1', 'new.jsonl'))
        .writeAsStringSync('{"role":"user","content":"接管后新增"}\n');

    final RollbackReport rollback = rollbackTakeover(paths);
    expect(rollback.ok, isTrue);
    expect(rollback.restored, containsAll(<String>['agents', 'data']));
    expect(
      File(p.join(temp.path, 'agents', 'agt.yaml')).readAsStringSync(),
      'id: agt\nname: 夹具\n',
    );
    // 回滚是恢复旧数据，不是时间倒流：新增文件保留。
    expect(
      File(p.join(temp.path, 'data', 'agt', 's1', 'new.jsonl')).existsSync(),
      isTrue,
    );
    expect(File(takeoverMarkerPath(paths)).existsSync(), isFalse);
    expect(isTakenOver(paths), isFalse);
  });

  test('没有接管记录时回滚失败（不猜路径）', () {
    final RollbackReport rollback = rollbackTakeover(paths);
    expect(rollback.ok, isFalse);
    expect(rollback.error, contains('没有接管记录'));
    expect(
      File(p.join(temp.path, 'agents', 'agt.yaml')).readAsStringSync(),
      'id: agt\nname: 夹具\n',
      reason: '失败的回滚不得改动用户数据',
    );
  });

  test('备份丢失：接管报失败且不覆盖标记；回滚也拒绝', () {
    final TakeoverReport first = takeOverData(
      paths,
      now: DateTime(2026, 1, 2, 3, 4, 5),
    );
    expect(first.ok, isTrue);
    Directory(first.backupDir).deleteSync(recursive: true);

    final TakeoverReport second = takeOverData(paths);
    expect(second.ok, isFalse);
    expect(second.alreadyTakenOver, isFalse);
    expect(second.error, contains('备份目录不存在'));
    expect(
      File(takeoverMarkerPath(paths)).existsSync(),
      isTrue,
      reason: '旧标记记录着那次备份去哪了，不能被覆盖成新的',
    );

    final RollbackReport rollback = rollbackTakeover(paths);
    expect(rollback.ok, isFalse);
    expect(rollback.error, contains('备份目录不存在'));
    expect(File(takeoverMarkerPath(paths)).existsSync(), isTrue);
  });

  test('备份失败（备份目录不可写）时不写标记，用户数据保持原样', () {
    // 把 `<root>/backups` 预建成文件，让 `.part` 目录创建失败。
    Directory(p.join(temp.path, 'backups')).createSync(recursive: true);
    File(p.join(temp.path, 'backups', 'takeover-20260102030405.part'))
        .writeAsStringSync('占位');

    final TakeoverReport report = takeOverData(
      paths,
      now: DateTime(2026, 1, 2, 3, 4, 5),
    );
    expect(report.ok, isFalse);
    expect(report.error, contains('接装备份失败'));
    expect(File(takeoverMarkerPath(paths)).existsSync(), isFalse);
    expect(
      File(p.join(temp.path, 'agents', 'agt.yaml')).readAsStringSync(),
      'id: agt\nname: 夹具\n',
    );
  });

  test('状态快照：未接管时 problem 为空', () {
    final Map<String, dynamic> before = takeoverStatus(paths);
    expect(before['taken_over'], isFalse);
    expect(before['problem'], '');

    final TakeoverReport report = takeOverData(
      paths,
      now: DateTime(2026, 1, 2, 3, 4, 5),
    );
    expect(report.ok, isTrue);
    final Map<String, dynamic> after = takeoverStatus(paths);
    expect(after['taken_over'], isTrue);
    expect(after['taken_over_at'], isNotEmpty);
    expect(after['backup_exists'], isTrue);
  });
}
