import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_agent_loop/src/conversation_store.dart';
import 'package:tree_agent_loop/src/paths.dart';
import 'package:tree_agent_loop/src/store/conversation_db.dart';
import 'package:tree_agent_loop/src/store/records.dart';
import 'package:tree_agent_loop/src/store/tree_paths.dart';

CoreMessage msg(
  String id, {
  String agentId = 'agt',
  String sessionId = 'ses',
  String role = 'agent',
  String content = '正文',
  String kind = 'text',
  int timestamp = 1000,
  String? toolName,
  Map<String, dynamic>? toolArguments,
  String toolResult = '',
  String subagentId = '',
}) {
  return CoreMessage(
    id: id,
    agentId: agentId,
    sessionId: sessionId,
    role: role,
    content: content,
    timestamp: timestamp,
    kind: kind,
    toolName: toolName,
    toolArguments: toolArguments,
    toolResult: toolResult,
    subagentId: subagentId,
  );
}

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_convdb_');
  });

  tearDown(() async {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<ConversationDb> openDb([String name = 'conv.semdb']) =>
      ConversationDatabase.open(p.join(temp.path, name));

  group('追加与读取', () {
    test('seq 全局单调、displayRows 按 seq 升序、detailRow 回读整份 payload', () async {
      final ConversationDb db = await openDb();
      await db.appendMessage(msg('m1', role: 'user', content: '你好'));
      await db.appendMessage(msg('m2', sessionId: 'ses_b', content: '另一会话'));
      await db.appendMessage(
        msg(
          'm3',
          kind: 'tool',
          toolName: 'edit',
          toolArguments: <String, dynamic>{'file_path': 'a.dart'},
          toolResult: 'ok',
        ),
      );

      final List<Map<String, dynamic>> all = await db.displayRows();
      expect(all.map((Map<String, dynamic> r) => r['seq']), <Object?>[1, 2, 3]);
      expect(all.map((Map<String, dynamic> r) => r['msg_id']), <Object?>[
        'm1',
        'm2',
        'm3',
      ]);

      final Map<String, dynamic>? detail = await db.detailRow('m3');
      expect(detail, isNotNull);
      expect(detail!['seq'], 3);
      expect(detail['session_id'], 'ses');
      final Map<String, dynamic> payload =
          Map<String, dynamic>.from(detail['payload'] as Map);
      expect(payload['tool_result'], 'ok');
      expect(payload['tool_arguments'], <String, dynamic>{'file_path': 'a.dart'});

      // 显示行不带重负载：tool 行 content 置空、preview 带关键值。
      final Map<String, dynamic> toolRow = all.last;
      expect(toolRow['content'], '');
      expect(toolRow['preview'], 'a.dart');

      await db.close();
    });

    test('updateDetailResult 只动 detail payload；不存在返回 false', () async {
      final ConversationDb db = await openDb();
      await db.appendMessage(
        msg('m1', kind: 'tool', toolName: 'terminal', toolResult: ''),
      );
      expect(
        await db.updateDetailResult(
          'm1',
          toolResult: 'done',
          toolResultForModel: 'done',
        ),
        isTrue,
      );
      expect(await db.updateDetailResult('nope', toolResult: '', toolResultForModel: ''), isFalse);
      final Map<String, dynamic>? detail = await db.detailRow('m1');
      final Map<String, dynamic> payload =
          Map<String, dynamic>.from(detail!['payload'] as Map);
      expect(payload['tool_result'], 'done');
      await db.close();
    });

    test('deleteSession 清两 store；其余会话不受影响', () async {
      final ConversationDb db = await openDb();
      await db.appendMessage(msg('m1', sessionId: 'a'));
      await db.appendMessage(msg('m2', sessionId: 'b'));
      await db.deleteSession('a');
      expect(await db.displayCount('a'), 0);
      expect(await db.displayCount('b'), 1);
      expect(await db.detailRow('m1'), isNull);
      expect(await db.detailRow('m2'), isNotNull);
      await db.close();
    });

    test('lastTextDisplayRow 排 tool / 排 user / 排临时员工，取 seq 最大', () async {
      final ConversationDb db = await openDb();
      await db.appendMessage(msg('m1', content: '最早回复'));
      await db.appendMessage(msg('m2', role: 'user', content: '用户'));
      await db.appendMessage(
        msg('m3', kind: 'tool', toolName: 'grep', toolArguments: <String, dynamic>{'pattern': 'x'}),
      );
      await db.appendMessage(msg('m4', content: '最新回复'));
      await db.appendMessage(msg('m5', content: '子员工', subagentId: 'sub1'));
      final Map<String, dynamic>? row = await db.lastTextDisplayRow();
      expect(row?['msg_id'], 'm4');
      await db.close();
    });
  });

  group('preview 生成（toolLinePreview）', () {
    test('各工具取关键参数；取不到退回结果摘要', () async {
      expect(
        ConversationDb.toolLinePreview(
          msg('m', kind: 'tool', toolName: 'write', toolArguments: <String, dynamic>{'file_path': 'b.dart'}),
        ),
        'b.dart',
      );
      expect(
        ConversationDb.toolLinePreview(
          msg('m', kind: 'tool', toolName: 'grep', toolArguments: <String, dynamic>{'pattern': 'foo', 'path': 'lib'}),
        ),
        'foo  ·  lib',
      );
      expect(
        ConversationDb.toolLinePreview(
          msg('m', kind: 'tool', toolName: 'terminal', toolArguments: <String, dynamic>{'command': 'ls -la'}),
        ),
        'ls -la',
      );
      expect(
        ConversationDb.toolLinePreview(
          msg('m', kind: 'tool', toolName: 'unknown_tool', toolResult: '  多行\n结果  '),
        ),
        '多行 结果',
      );
    });
  });

  group('conversationPage 分页', () {
    test('limit 取末尾一页；before 截断；all 合并会话；键集无重负载', () async {
      final ConversationDb db = await openDb();
      for (int i = 1; i <= 10; i++) {
        await db.appendMessage(msg('s1_$i', sessionId: 'ses1', content: '消息$i'));
      }
      for (int i = 1; i <= 3; i++) {
        await db.appendMessage(msg('s2_$i', sessionId: 'ses2', content: '另一$i'));
      }

      final Map<String, dynamic> tail = await conversationPage(
        db,
        AgentDataPaths(temp.path),
        'agt',
        sessionId: 'ses1',
        limit: 4,
      );
      expect(tail['total'], 10);
      expect(tail['offset'], 6);
      expect(tail['has_more'], isTrue);
      final List<Map<String, dynamic>> page =
          (tail['messages'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(page.map((Map<String, dynamic> m) => m['id']), <String>[
        's1_7',
        's1_8',
        's1_9',
        's1_10',
      ]);

      final Map<String, dynamic> before = await conversationPage(
        db,
        AgentDataPaths(temp.path),
        'agt',
        sessionId: 'ses1',
        limit: 3,
        before: 's1_5',
      );
      final List<Map<String, dynamic>> bPage =
          (before['messages'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(bPage.map((Map<String, dynamic> m) => m['id']), <String>[
        's1_2',
        's1_3',
        's1_4',
      ]);

      final Map<String, dynamic> all = await conversationPage(
        db,
        AgentDataPaths(temp.path),
        'agt',
        sessionId: 'all',
      );
      expect(all['total'], 13);
      expect(all['offset'], 0);
      expect(all['has_more'], isFalse);

      // 列表页只给显示数据：重负载键回空默认。
      final Map<String, dynamic> first =
          ((all['messages'] as List<dynamic>).first as Map<String, dynamic>);
      expect(first['tool_arguments'], isNull);
      expect(first['tool_result'], '');
      expect(first.containsKey('preview'), isTrue);
      expect(first['seq'], isNotNull);

      expect(await messageCountOf(db, 'ses1'), 10);
      await db.close();
    });
  });

  group('conversationPage 字节预算', () {
    test('超预算从页首丢行：offset 前移、has_more 保持真', () async {
      final ConversationDb db = await openDb();
      final String big = 'x' * 400000;
      for (int i = 1; i <= 3; i++) {
        await db.appendMessage(msg('big_$i', sessionId: 'ses1', content: big));
      }

      final Map<String, dynamic> tail = await conversationPage(
        db,
        AgentDataPaths(temp.path),
        'agt',
        sessionId: 'ses1',
      );
      final List<Map<String, dynamic>> page =
          (tail['messages'] as List<dynamic>).cast<Map<String, dynamic>>();
      // 两条就超 768 KiB ⇒ 末尾页只留最后一条，offset 前移到它的下标。
      expect(page.map((Map<String, dynamic> m) => m['id']), <String>['big_3']);
      expect(tail['total'], 3);
      expect(tail['offset'], 2);
      expect(tail['has_more'], isTrue);
      await db.close();
    });

    test('单条自己超预算时保留这一条（交给 result_path 回写）', () async {
      final ConversationDb db = await openDb();
      await db.appendMessage(msg('small', sessionId: 'ses1', content: '短'));
      await db.appendMessage(
        msg('huge', sessionId: 'ses1', content: 'y' * 900000),
      );

      final Map<String, dynamic> tail = await conversationPage(
        db,
        AgentDataPaths(temp.path),
        'agt',
        sessionId: 'ses1',
      );
      final List<Map<String, dynamic>> page =
          (tail['messages'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(page.map((Map<String, dynamic> m) => m['id']), <String>['huge']);
      expect(tail['offset'], 1);
      expect(tail['has_more'], isTrue);
      await db.close();
    });
  });

  group('jsonl 迁移（注册表首开顺带）', () {
    test('导入 + 改名 .migrated；重开不重复；seq 接库尾', () async {
      final TreePaths treePaths = TreePaths(temp.path);
      final AgentDataPaths paths = AgentDataPaths(temp.path);
      final Directory sessionDir = Directory(
        p.join(paths.agentDataDir('agt'), 'ses_a'),
      )..createSync(recursive: true);
      final List<CoreMessage> old = <CoreMessage>[
        msg('o1', sessionId: 'ses_a', role: 'user', content: '旧用户', timestamp: 10),
        msg('o2', sessionId: 'ses_a', content: '旧回复', timestamp: 20),
        msg(
          'o3',
          sessionId: 'ses_a',
          kind: 'tool',
          toolName: 'read',
          toolArguments: <String, dynamic>{'file_path': 'x'},
          timestamp: 30,
        ),
      ];
      File(p.join(sessionDir.path, 'messages.jsonl')).writeAsStringSync(
        old.map((CoreMessage m) => jsonEncode(m.toJson())).join('\n'),
      );

      final ConversationDb db = await ConversationDbRegistry.open(
        treePaths,
        'agt',
      );
      expect(await db.displayCount('ses_a'), 3);
      expect(
        await db.detailRow('o2'),
        isNotNull,
        reason: '详细行也应导入',
      );
      expect(File(p.join(sessionDir.path, 'messages.jsonl')).existsSync(), isFalse);
      expect(
        File('${p.join(sessionDir.path, 'messages.jsonl')}.migrated')
            .existsSync(),
        isTrue,
      );

      // 迁移后再追加：seq 接在导入的最大值之后（agent 全局单调）。
      await db.appendMessage(msg('n1', sessionId: 'ses_a', content: '新消息'));
      final List<Map<String, dynamic>> rows = await db.displayRows(
        sessionId: 'ses_a',
      );
      expect(rows.map((Map<String, dynamic> r) => r['seq']), <Object?>[1, 2, 3, 4]);

      // 重开（模拟进程重启）：不重复导入、不重复计数。
      final String dbPath = ConversationDbRegistry.pathFor(treePaths, 'agt');
      await ConversationDbRegistry.close(dbPath);
      final ConversationDb again = await ConversationDbRegistry.open(
        treePaths,
        'agt',
      );
      expect(await again.displayCount('ses_a'), 4);
      await ConversationDbRegistry.close(dbPath);
    });
  });
}
