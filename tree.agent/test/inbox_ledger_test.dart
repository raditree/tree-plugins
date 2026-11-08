import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_agent_loop/src/message/inbox_ledger.dart';

/// AC-1 收件箱台账：追加、状态合并、崩溃恢复、坏行容忍。
void main() {
  late Directory temp;
  late String path;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_inbox_');
    path = p.join(temp.path, 'data', 'agt', 'ses_a', 'inbox.jsonl');
  });

  tearDown(() {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {
      // Windows 偶发占用：临时目录交给系统清理。
    }
  });

  Map<String, dynamic> envelope(String id, {String content = '你好'}) =>
      <String, dynamic>{
        'message_id': id,
        'type': 'common_message',
        'subtype': 'task',
        'inject_mode': 'direct',
        'source': <String, dynamic>{
          'team_id': 'inner',
          'agent_id': 'user',
          'session_id': 'main',
        },
        'target': <String, dynamic>{
          'team_id': 'agt',
          'agent_id': 'agt',
          'session_id': 'ses_a',
        },
        'content': content,
      };

  test('appendPending：回执前落盘，envelope 原样保留', () async {
    final MessageInbox inbox = MessageInbox(path: path);
    await inbox.appendPending(envelope('m1'));

    expect(File(path).existsSync(), isTrue);
    final List<InboxEntry> entries = await inbox.readAll();
    expect(entries, hasLength(1));
    expect(entries.single.messageId, 'm1');
    expect(entries.single.status, InboxStatus.pending);
    expect(entries.single.attempts, 0);
    expect(entries.single.envelope['content'], '你好');
    expect(
      (entries.single.envelope['source'] as Map<String, dynamic>)['agent_id'],
      'user',
    );
  });

  test('inflight → recover 回到 pending，attempts 保留', () async {
    final MessageInbox inbox = MessageInbox(path: path);
    await inbox.appendPending(envelope('m1'));
    await inbox.markInflight('m1');

    final InboxEntry inflight = (await inbox.readAll()).single;
    expect(inflight.status, InboxStatus.inflight);
    expect(inflight.attempts, 1);

    expect(await inbox.recover(), 1);
    final InboxEntry recovered = (await inbox.readAll()).single;
    expect(recovered.status, InboxStatus.pending);
    expect(recovered.attempts, 1);

    // 幂等：再恢复一次没有改动。
    expect(await inbox.recover(), 0);
  });

  test('done / failed / cancelled：后写覆盖先写，pending 只剩未处理项', () async {
    final MessageInbox inbox = MessageInbox(path: path);
    await inbox.appendPending(envelope('m1'));
    await inbox.appendPending(envelope('m2'));
    await inbox.appendPending(envelope('m3'));

    await inbox.markDone('m1');
    await inbox.markFailed('m2', '模型超时');
    await inbox.markCancelled('m3', reason: '用户停止');

    final List<InboxEntry> all = await inbox.readAll();
    final Map<String, InboxEntry> byId = <String, InboxEntry>{
      for (final InboxEntry entry in all) entry.messageId: entry,
    };
    expect(byId['m1']!.status, InboxStatus.done);
    expect(byId['m2']!.status, InboxStatus.failed);
    expect(byId['m2']!.error, '模型超时');
    expect(byId['m3']!.status, InboxStatus.cancelled);
    expect(byId['m3']!.error, '用户停止');
    expect(await inbox.pending(), isEmpty);
  });

  test('坏行与孤儿增量被跳过，不影响其它消息', () async {
    final MessageInbox inbox = MessageInbox(path: path);
    await inbox.appendPending(envelope('m1'));
    await inbox.flush();

    File(path).writeAsStringSync(
      '{"message_id":"orphan","status":"done"}\n'
      '{{{ 半截 JSON\n',
      mode: FileMode.append,
      flush: true,
    );

    final List<InboxEntry> entries = await inbox.readAll();
    expect(entries.map((InboxEntry e) => e.messageId), <String>['m1']);
    expect(entries.single.status, InboxStatus.pending);
  });

  test('按 enqueued_at 稳定排序（同刻按 message_id）', () async {
    int now = 1000;
    final MessageInbox inbox = MessageInbox(
      path: path,
      clock: () => DateTime.fromMillisecondsSinceEpoch(now++),
    );
    await inbox.appendPending(envelope('m2'));
    await inbox.appendPending(envelope('m1'));

    final List<InboxEntry> entries = await inbox.readAll();
    expect(entries.map((InboxEntry e) => e.messageId), <String>['m2', 'm1']);
  });

  test('appendPending 缺 message_id 直接拒绝，不写坏行', () async {
    final MessageInbox inbox = MessageInbox(path: path);
    await expectLater(
      inbox.appendPending(<String, dynamic>{'content': '没有 id'}),
      throwsArgumentError,
    );
    expect(File(path).existsSync(), isFalse);
  });

  test('jsonl 一行一条：状态增量不重写 envelope', () async {
    final MessageInbox inbox = MessageInbox(path: path);
    await inbox.appendPending(envelope('m1'));
    await inbox.markInflight('m1');
    await inbox.markDone('m1');

    final List<String> lines = File(path)
        .readAsLinesSync()
        .where((String line) => line.trim().isNotEmpty)
        .toList();
    expect(lines, hasLength(3));
    final Map<String, dynamic> first =
        jsonDecode(lines.first) as Map<String, dynamic>;
    expect(first['envelope'], isA<Map<String, dynamic>>());
    final Map<String, dynamic> second =
        jsonDecode(lines[1]) as Map<String, dynamic>;
    expect(second.containsKey('envelope'), isFalse);
  });
}
