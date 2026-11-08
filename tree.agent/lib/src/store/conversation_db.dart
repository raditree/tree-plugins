import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sembast/sembast_io.dart';

import 'atomic_file.dart';
import 'records.dart';
import 'tree_paths.dart';

/// 会话数据库（**每 agent 一库**，Sembast 纯 Dart）：
/// `<dataRoot>/data/<agent_id>/conversation.semdb`，内含两张 store。
///
/// 规格见 docs/conversation-sembast-and-collapse-recon.md §3.1（拍板口径）：
/// - `messages_display`：key = `seq`（int，**agent 全局单调** ⇒ 会话内单调，排序
///   唯一依据，替代 timestamp 排序），记录只放"渲染一行卡片头"的轻字段；
///   `content` 只对**气泡类**消息存正文（tool / thinking 置空——thinking 正文是
///   详细数据，点开才查）。
/// - `messages_detail`：key = `msg_id`，value = `{seq, session_id, payload}`，
///   payload 是整份 `CoreMessage.toJson()`（tool_arguments / tool_result /
///   thinking 正文 / attachments / questions / usage 等重负载全在这里）。
///
/// 崩溃模型与 jsonl 同构：Sembast 自身是追加日志 + 检查点，硬杀最多丢末条写入。
/// 单写者成立：一个 agent 的消息写者只有它的 runtime 进程（核心有单实例约束）。
class ConversationDb {
  ConversationDb(this.database, this.path);

  /// 已打开的底层库。
  final Database database;

  /// 库文件路径（注册表键）。
  final String path;

  static const String storeDisplay = 'messages_display';
  static const String storeDetail = 'messages_detail';

  /// 显示行库指针（key = seq int；value = 轻字段记录）。
  static final StoreRef<int, Map<String, Object?>> _display =
      StoreRef<int, Map<String, Object?>>(storeDisplay);

  /// 详细行库指针（key = msg_id；value = `{seq, session_id, payload}`）。
  static final StoreRef<String, Map<String, Object?>> _detail =
      StoreRef<String, Map<String, Object?>>(storeDetail);

  static Finder _bySeqDesc() =>
      Finder(sortOrders: <SortOrder>[SortOrder('seq', false)]);

  // ── 写 ──────────────────────────────────────────────────────────────

  /// 同事务追加一条消息：seq = display store 当前最大 seq + 1（事务内取，保证单调）。
  Future<int> appendMessage(CoreMessage message) async {
    return database.transaction<int>((Transaction txn) async {
      final RecordSnapshot<int, Map<String, Object?>>? tail =
          await _display.findFirst(txn, finder: _bySeqDesc());
      final int seq = ((tail?.value['seq'] as num?) ?? 0).toInt() + 1;
      await _display.record(seq).put(txn, buildDisplayRecord(message, seq));
      await _detail.record(message.id).put(
        txn,
        <String, Object?>{
          'seq': seq,
          'session_id': message.sessionId,
          'payload': message.toJson(),
        },
      );
      return seq;
    });
  }

  /// 迁移导入：把一个会话的消息按序整批接到库尾（单事务）。
  ///
  /// seq 从库当前最大 seq 续号；会话内按 jsonl 行序 = 原 append 序。
  Future<void> appendMigrated(List<CoreMessage> messages) async {
    await database.transaction((Transaction txn) async {
      final RecordSnapshot<int, Map<String, Object?>>? tail =
          await _display.findFirst(txn, finder: _bySeqDesc());
      int seq = ((tail?.value['seq'] as num?) ?? 0).toInt();
      for (final CoreMessage message in messages) {
        seq++;
        await _display.record(seq).put(txn, buildDisplayRecord(message, seq));
        await _detail.record(message.id).put(
          txn,
          <String, Object?>{
            'seq': seq,
            'session_id': message.sessionId,
            'payload': message.toJson(),
          },
        );
      }
    });
  }

  /// 修理历史（自动修复工具结果）：只更新 detail payload 的对应键。
  ///
  /// display 行不含 tool_result（工具行只显示 preview 一行关键值），无需动。
  Future<bool> updateDetailResult(
    String msgId, {
    required String toolResult,
    required String toolResultForModel,
  }) async {
    final Map<String, Object?>? stored = await _detail.record(msgId).get(
      database,
    );
    if (stored == null) return false;
    final Map<String, dynamic> payload = Map<String, dynamic>.from(
      stored['payload'] as Map,
    );
    payload['tool_result'] = toolResult;
    payload['tool_result_for_model'] = toolResultForModel;
    await _detail.record(msgId).put(database, <String, Object?>{
      'seq': stored['seq'],
      'session_id': stored['session_id'],
      'payload': payload,
    });
    return true;
  }

  /// 删除某会话的全部显示行与详细行（clearMessages / deleteSession 用）。
  Future<void> deleteSession(String sessionId) async {
    await database.transaction((Transaction txn) async {
      await _display.delete(
        txn,
        finder: Finder(filter: Filter.equals('session_id', sessionId)),
      );
      await _detail.delete(
        txn,
        finder: Finder(filter: Filter.equals('session_id', sessionId)),
      );
    });
  }

  // ── 读 ──────────────────────────────────────────────────────────────

  /// 显示行（按 seq 升序）。[sessionId] 为 null = 全部会话合并。
  Future<List<Map<String, dynamic>>> displayRows({String? sessionId}) async {
    final Finder finder = Finder(
      filter: sessionId == null
          ? null
          : Filter.equals('session_id', sessionId),
      sortOrders: <SortOrder>[SortOrder('seq')],
    );
    final List<RecordSnapshot<int, Map<String, Object?>>> records =
        await _display.find(database, finder: finder);
    return <Map<String, dynamic>>[
      for (final RecordSnapshot<int, Map<String, Object?>> r in records)
        Map<String, dynamic>.from(r.value),
    ];
  }

  /// 某会话显示行的条数（迁移幂等判断用；"有效消息数"谓词计数在调用方做）。
  Future<int> displayCount(String sessionId) async {
    return _display.count(
      database,
      filter: Filter.equals('session_id', sessionId),
    );
  }

  /// 单条详细记录（`{seq, session_id, payload}`）；不存在返回 null。
  Future<Map<String, dynamic>?> detailRow(String msgId) async {
    final Map<String, Object?>? stored = await _detail.record(msgId).get(
      database,
    );
    if (stored == null) return null;
    return Map<String, dynamic>.from(stored);
  }

  /// 某会话全部详细记录（按 seq 升序；hydration 与"整份历史"端点用）。
  Future<List<Map<String, dynamic>>> detailRows(String sessionId) async {
    final List<RecordSnapshot<String, Map<String, Object?>>> records =
        await _detail.find(
      database,
      finder: Finder(
        filter: Filter.equals('session_id', sessionId),
        sortOrders: <SortOrder>[SortOrder('seq')],
      ),
    );
    return <Map<String, dynamic>>[
      for (final RecordSnapshot<String, Map<String, Object?>> r in records)
        Map<String, dynamic>.from(r.value),
    ];
  }

  /// 该 agent 最后一条 **agent 文本消息**的显示行（列表页预览用）；无则 null。
  ///
  /// 口径与旧 `_previewFor` / `lastTextPreview` 一致：排 tool、排非 agent 角色、
  /// 排临时员工消息（`subagent_id` 非空）。
  Future<Map<String, dynamic>?> lastTextDisplayRow() async {
    final RecordSnapshot<int, Map<String, Object?>>? row =
        await _display.findFirst(
      database,
      finder: Finder(
        filter: Filter.and(<Filter>[
          Filter.notEquals('kind', 'tool'),
          Filter.equals('role', 'agent'),
          Filter.equals('subagent_id', ''),
        ]),
        sortOrders: <SortOrder>[SortOrder('seq', false)],
        limit: 1,
      ),
    );
    if (row == null) return null;
    return Map<String, dynamic>.from(row.value);
  }

  Future<void> close() => database.close();

  // ── 记录构造 ────────────────────────────────────────────────────────

  /// 由消息生成显示行（seq 由调用方在事务内分配）。
  ///
  /// `content` 只对**气泡类**存正文：tool 的正文本来就是空壳、thinking 的正文是
  /// 详细数据（点开才查），其余 kind（text / notice / subagent_report /
  /// ask_user_question…）都是中栏直接渲染的气泡文本。
  static Map<String, Object?> buildDisplayRecord(CoreMessage m, int seq) {
    final bool isBubble = !m.isTool && !m.isThinking;
    return <String, Object?>{
      'seq': seq,
      'session_id': m.sessionId,
      'msg_id': m.id,
      'role': m.role,
      'kind': m.kind,
      'timestamp': m.timestamp,
      'tool_name': m.toolName ?? '',
      'tool_call_id': m.toolCallId ?? '',
      'preview': m.isTool ? toolLinePreview(m) : '',
      'content': isBubble ? m.content : '',
      'answered': m.answered,
      'llm_hidden': m.llmHidden,
      'subagent_id': m.subagentId,
      'subagent_name': m.subagentName,
      'subagent_level': m.subagentLevel,
    };
  }

  // ── 工具行一行关键值（toolLineValue 的写入侧前移，规格 §5.1.2）────────

  /// 与主仓 `lib/ui/widgets/tool_call_card.dart` 的 `toolLineValue` 同口径：
  /// 这条工具调用最关键的那个参数（路径 / 命令 / 查询词…）；取不到退回结果摘要。
  static String toolLinePreview(CoreMessage m) {
    final String name = m.toolName ?? '';
    final Map<String, dynamic> args = m.toolArguments ?? <String, dynamic>{};
    String arg(String key) => (args[key] ?? '').toString();

    switch (name) {
      case 'read':
      case 'write':
      case 'edit':
        return arg('file_path');
      case 'grep':
        final String pattern = arg('pattern');
        final String path = arg('path');
        if (pattern.isEmpty) return path;
        return path.isEmpty ? pattern : '$pattern  ·  $path';
      case 'terminal':
        return arg('cmd').isEmpty ? arg('command') : arg('cmd');
      case 'set':
        return arg('key').isEmpty ? arg('param') : arg('key');
      case 'set_todo_list':
        return arg('content').isEmpty ? arg('action') : arg('content');
      case 'team':
        return arg('description').isEmpty ? arg('action') : arg('description');
      case 'mcp':
        final String tool =
            arg('tool_name').isEmpty ? arg('tool') : arg('tool_name');
        final Object? rawNested = args['arguments'];
        final Map<String, dynamic> nested = rawNested is Map
            ? rawNested.cast<String, dynamic>()
            : <String, dynamic>{};
        final String inner = (nested['cmd'] ??
                nested['command'] ??
                nested['path'] ??
                nested['query'] ??
                '')
            .toString();
        return inner.isEmpty ? tool : '$tool  ·  $inner';
      case 'subagent':
        final String task = arg('task');
        final String reuse = arg('subagent_id');
        final String head = <String>[
          if (reuse.isNotEmpty) '复用 $reuse',
          if (args['background'] == true) '后台',
        ].join(' · ');
        if (task.isEmpty) return head;
        return head.isEmpty ? task : '$head · $task';
      case 'ask_user_question':
        final List<dynamic>? questions = args['questions'] as List<dynamic>?;
        String textOf(dynamic item) => item is Map
            ? (item['question'] ?? '').toString()
            : (item?.toString() ?? '');
        if (questions != null && questions.length > 1) {
          return '共 ${questions.length} 题：${textOf(questions.first)}';
        }
        if (questions != null && questions.length == 1) {
          return textOf(questions.first);
        }
        return arg('question');
      case 'embed_search':
        return arg('query');
      default:
        if (args.isNotEmpty) {
          final Object? first = args.values.first;
          final String text = first?.toString() ?? '';
          if (text.isNotEmpty) return text;
        }
        return _resultPreview(m.toolResult);
    }
  }

  /// 结果的一句话摘要（对应 UI 侧 `toolResultPreview` 的简化版：
  /// 压平空白、截 200 字符——只在"参数里取不到关键值"的罕见分支用到）。
  static String _resultPreview(String result) {
    final String collapsed = result.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.length <= 200) return collapsed;
    return '${collapsed.substring(0, 200)}…';
  }
}

/// 显示行 → API 形态（与 `session_store._messageToJson` 同键集、同默认值）。
///
/// 详细字段（tool_arguments / tool_result / attachments / usage / questions…）
/// 回**空默认值**：列表页只给显示数据，重负载由详情端点按 id 即查（F3 接上）。
/// 额外多给两个键：`preview`（工具行一行关键值）与 `seq`（排序游标）。
Map<String, dynamic> displayRowToJson(
  Map<String, dynamic> row,
  String agentId,
) {
  final String subagentId = '${row['subagent_id'] ?? ''}';
  final int ts = (row['timestamp'] as num?)?.toInt() ?? 0;
  final String toolName = '${row['tool_name'] ?? ''}';
  final String toolCallId = '${row['tool_call_id'] ?? ''}';
  return <String, dynamic>{
    'id': '${row['msg_id'] ?? ''}',
    'agent_id': agentId,
    'session_id': '${row['session_id'] ?? 'session_default'}',
    'role': '${row['role'] ?? 'agent'}',
    'content': '${row['content'] ?? ''}',
    'timestamp': DateTime.fromMillisecondsSinceEpoch(ts).toIso8601String(),
    'kind': '${row['kind'] ?? 'text'}',
    'tool_name': toolName.isEmpty ? null : toolName,
    'tool_arguments': null,
    'tool_result': '',
    'tool_call_id': toolCallId.isEmpty ? null : toolCallId,
    'usage': null,
    'attachments': null,
    'options': const <String>[],
    'answered': row['answered'] == true,
    if (row['llm_hidden'] == true) 'llm_hidden': true,
    if (subagentId.isNotEmpty) ...<String, dynamic>{
      'subagent_id': subagentId,
      'subagent_name': '${row['subagent_name'] ?? ''}',
      'subagent_parent_id': '',
      'subagent_level': (row['subagent_level'] as num?)?.toInt() ?? 0,
    },
    'preview': '${row['preview'] ?? ''}',
    'seq': (row['seq'] as num?)?.toInt(),
    'is_streaming': false,
  };
}

/// 详细 payload → API 形态（与 `session_store._messageToJson` 同口径的规范化）。
Map<String, dynamic> detailPayloadToJson(Map<String, dynamic> payload) {
  final String toolArgumentsRaw = payload['tool_arguments_raw'] as String? ?? '';
  final String toolResultForModel =
      payload['tool_result_for_model'] as String? ?? '';
  final List<Map<String, dynamic>>? questions = (payload['questions']
          as List<dynamic>?)
      ?.whereType<Map<dynamic, dynamic>>()
      .map(
        (Map<dynamic, dynamic> item) =>
            item.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
      )
      .toList();
  final String subagentId = payload['subagent_id'] as String? ?? '';
  return <String, dynamic>{
    'id': payload['id'] as String? ?? '',
    'agent_id': payload['agent_id'] as String? ?? '',
    'session_id': payload['session_id'] as String? ?? 'session_default',
    'role': payload['role'] as String? ?? 'agent',
    'content': payload['content'] as String? ?? '',
    'timestamp': _encodeTime(
      _decodeTime(payload['timestamp']) ??
          DateTime.now().millisecondsSinceEpoch,
    ),
    'kind': payload['kind'] as String? ?? 'text',
    'tool_name': payload['tool_name'] as String?,
    'tool_arguments': _mapOrNull(payload['tool_arguments']),
    'tool_result': payload['tool_result'] as String? ?? '',
    'tool_call_id': payload['tool_call_id'] as String?,
    if (toolArgumentsRaw.isNotEmpty) 'tool_arguments_raw': toolArgumentsRaw,
    if (toolResultForModel.isNotEmpty)
      'tool_result_for_model': toolResultForModel,
    'usage': _mapOrNull(payload['usage']),
    'attachments': _listOfMapsOrNull(payload['attachments']),
    'options':
        (payload['options'] as List<dynamic>?)
            ?.map((dynamic e) => e.toString())
            .toList() ??
        const <String>[],
    if (questions != null && questions.isNotEmpty) 'questions': questions,
    'answered': payload['answered'] as bool? ?? false,
    if (payload['llm_hidden'] == true) 'llm_hidden': true,
    if (subagentId.isNotEmpty) ...<String, dynamic>{
      'subagent_id': subagentId,
      'subagent_name': payload['subagent_name'] as String? ?? '',
      'subagent_parent_id': payload['subagent_parent_id'] as String? ?? '',
      'subagent_level': (payload['subagent_level'] as num?)?.toInt() ?? 0,
    },
    // 消息机信封元数据（AC-1 加法键）：只在非空时出现，老消息形状不变。
    if ((payload['source_message_id'] as String? ?? '').isNotEmpty)
      'source_message_id': payload['source_message_id'],
    if ((payload['message_type'] as String? ?? '').isNotEmpty)
      'message_type': payload['message_type'],
    if ((payload['message_subtype'] as String? ?? '').isNotEmpty)
      'message_subtype': payload['message_subtype'],
    if ((payload['inject_mode'] as String? ?? '').isNotEmpty)
      'inject_mode': payload['inject_mode'],
    if ((payload['source_team_id'] as String? ?? '').isNotEmpty)
      'source_team_id': payload['source_team_id'],
    if ((payload['source_agent_id'] as String? ?? '').isNotEmpty)
      'source_agent_id': payload['source_agent_id'],
    if ((payload['source_session_id'] as String? ?? '').isNotEmpty)
      'source_session_id': payload['source_session_id'],
    'is_streaming': false,
  };
}

Map<String, dynamic>? _mapOrNull(Object? value) {
  if (value == null) return null;
  if (value is! Map) throw const FormatException('消息字段类型不符：应为对象');
  return value.map(
    (Object? key, Object? item) => MapEntry(key.toString(), item),
  );
}

List<Map<String, dynamic>>? _listOfMapsOrNull(Object? value) {
  if (value == null) return null;
  if (value is! List) throw const FormatException('消息字段类型不符：应为数组');
  return <Map<String, dynamic>>[
    for (final Object? item in value)
      Map<String, dynamic>.from(item! as Map<dynamic, dynamic>),
  ];
}

String _encodeTime(int ms) =>
    DateTime.fromMillisecondsSinceEpoch(ms).toIso8601String();

int? _decodeTime(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toInt();
  if (value is String && value.isNotEmpty) {
    final String text = value.trim();
    if (RegExp(r'^-?\d+$').hasMatch(text)) return int.tryParse(text);
    return DateTime.tryParse(text)?.millisecondsSinceEpoch;
  }
  return null;
}

/// **库句柄注册表**：按 (dataRoot, agentId) 打开并缓存 [ConversationDb]，
/// 打开时顺带完成 jsonl → db 的一次性迁移（幂等）。
///
/// 所有触库方（FileTreeStore 读写、delegate 只读路由）都走 [open]，
/// 于是"迁移先于任何库使用"这条顺序**不需要**任何启动钩子来保证。
abstract final class ConversationDbRegistry {
  static final Map<String, Future<ConversationDb>> _open =
      <String, Future<ConversationDb>>{};

  /// 打开（或复用）某 agent 的会话库；首次打开时迁移该 agent 的 jsonl。
  static Future<ConversationDb> open(
    TreePaths paths,
    String agentId, {
    void Function(String message)? log,
  }) {
    final String dbPath = pathFor(paths, agentId);
    final Future<ConversationDb>? existing = _open[dbPath];
    if (existing != null) return existing;
    final Future<ConversationDb> future = _openAndMigrate(dbPath, paths, agentId, log);
    _open[dbPath] = future;
    return future;
  }

  static Future<ConversationDb> _openAndMigrate(
    String dbPath,
    TreePaths paths,
    String agentId,
    void Function(String)? log,
  ) async {
    try {
      final ConversationDb db = await ConversationDatabase.open(dbPath);
      await migrateAgentJsonl(paths, agentId, db, log: log);
      return db;
    } catch (_) {
      // 开库/迁移失败：摘除缓存，让下一次调用重试（否则坏 future 永久缓存）。
      _open.remove(dbPath);
      rethrow;
    }
  }

  static String pathFor(TreePaths paths, String agentId) =>
      p.join(paths.agentDataDir(agentId), 'conversation.semdb');

  /// 关闭并摘除句柄（deleteAgent / store.close 用）。
  static Future<void> close(String dbPath) async {
    final Future<ConversationDb>? pending = _open.remove(dbPath);
    if (pending == null) return;
    try {
      await (await pending).close();
    } catch (_) {
      // 已经关了 / 开失败过：摘除即达成目的。
    }
  }

  // ── jsonl 迁移 ──────────────────────────────────────────────────────

  /// 逐会话把 `messages.jsonl` 导入 db，成功后改名 `messages.jsonl.migrated`。
  ///
  /// 幂等：db 里该会话已有显示行 ⇒ 只补改名（上次导入后改名前被硬杀）；
  /// jsonl 不存在 / 已改名 ⇒ 跳过。seq 是 **agent 全局**键：会话按"首条时间戳"
  /// 升序依次接在库当前最大 key 之后；会话内按**文件行序 = append 序**分配。
  static Future<void> migrateAgentJsonl(
    TreePaths paths,
    String agentId,
    ConversationDb db, {
    void Function(String message)? log,
  }) async {
    final Directory agentDir = Directory(paths.agentDataDir(agentId));
    if (!agentDir.existsSync()) return;
    // 先收集"待导入会话"（目录序不稳定，按首条时间戳排，保证 'all' 视图观感一致）
    final List<({String sessionId, int firstTs, List<CoreMessage> messages})>
        pending =
        <({String sessionId, int firstTs, List<CoreMessage> messages})>[];
    for (final FileSystemEntity entity in agentDir.listSync()) {
      if (entity is! Directory) continue;
      final File jsonl = File(p.join(entity.path, 'messages.jsonl'));
      if (!jsonl.existsSync()) continue;
      final String sessionId = p.basename(entity.path);
      if (await db.displayCount(sessionId) > 0) {
        // 已导入过（改名没赶上）：补改名即可。
        await _renameImported(jsonl, log);
        continue;
      }
      final String? text = AtomicFile.readStringOrNullSync(jsonl.path);
      if (text == null || text.isEmpty) {
        await _renameImported(jsonl, log);
        continue;
      }
      final JsonlReadResult result = AtomicFile.decodeJsonl(text);
      if (result.skipped > 0) {
        log?.call(
          '迁移 messages.jsonl 跳过 ${result.skipped} 行坏数据：${jsonl.path}',
        );
      }
      final List<CoreMessage> messages =
          result.records.map(CoreMessage.fromJson).toList();
      pending.add((
        sessionId: sessionId,
        firstTs: messages.isEmpty ? 0 : messages.first.timestamp,
        messages: messages,
      ));
    }
    if (pending.isEmpty) return;
    pending.sort((a, b) => a.firstTs.compareTo(b.firstTs));
    for (final ({String sessionId, int firstTs, List<CoreMessage> messages})
        session
        in pending) {
      await db.appendMigrated(session.messages);
      final File jsonl = File(
        p.join(paths.sessionDir(agentId, session.sessionId), 'messages.jsonl'),
      );
      await _renameImported(jsonl, log);
      log?.call(
        'messages.jsonl 已迁移进会话库：agent=$agentId '
        'session=${session.sessionId}（${session.messages.length} 条）',
      );
    }
  }

  static Future<void> _renameImported(
    File jsonl,
    void Function(String)? log,
  ) async {
    try {
      await jsonl.rename('${jsonl.path}.migrated');
    } catch (error) {
      log?.call('迁移改名失败（不影响数据，下次启动重试）：$error');
    }
  }
}

/// Sembast 打开封装（生产固定 `databaseFactoryIo`；库文件自动建父目录）。
abstract final class ConversationDatabase {
  static Future<ConversationDb> open(String path) async {
    await File(path).parent.create(recursive: true);
    final Database db = await databaseFactoryIo.openDatabase(path);
    return ConversationDb(db, path);
  }
}
