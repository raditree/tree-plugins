import 'dart:convert';

import 'agent/question_store.dart';
import 'paths.dart';
import 'store/conversation_db.dart';
import 'store/tree_paths.dart';
import 'tool/question_channel.dart';

/// 会话历史单页上限（与核心 `CoreServer._historyPageMax` 同值）。
const int kHistoryPageMax = 2000;

/// 会话历史单页的**JSON 字节预算**（按行累加）。
///
/// 一页最多 2000 条显示行，长会话的正文足以把回包顶到核心 1 MiB 硬上限
/// （`delegateInlineBodyLimit`）。超预算就从页首丢行——`offset` 随之前移、
/// `has_more` 保持真，UI 的 `before` 补页不受影响；单条自己就超预算时保留它，
/// 由委派层走 `result_path` 流式回写。
const int kHistoryPageByteBudget = 768 * 1024;

/// `GET /api/conversations/{agentId}` 的分页实现。
///
/// **只读显示行**（messages_display store）：列表页一行卡片不再拖着
/// tool_arguments / tool_result 全量重负载——详细数据由
/// `GET /api/conversations/{agentId}/messages/{messageId}` 按点击即查。
///
/// 语义（与 jsonl 时代逐字对照）：
/// - `session_id=all`：该 agent **全部会话**合并；排序从 timestamp 换成
///   **seq**（会话库的 agent 全局单调键，落库顺序的显式化，规格 §3.1.2）；
/// - `limit` 取**末尾**一页；`before` 取该消息之前的一页；`from` 按下标；
///   `at` 以该消息为中心取一页；都找不到时按核心口径退回末尾一页；
/// - 响应 `offset` = 这一页第一条的全局下标；`has_more` = 前面还有没有。
Future<Map<String, dynamic>> conversationPage(
  ConversationDb db,
  AgentDataPaths paths,
  String agentId, {
  required String sessionId,
  int limit = 0,
  String before = '',
  int? from,
  String at = '',
}) async {
  final List<Map<String, dynamic>> ordered = <Map<String, dynamic>>[
    for (final Map<String, dynamic> row in await db.displayRows(
      sessionId: sessionId == 'all' ? null : sessionId,
    ))
      displayRowToJson(row, agentId),
  ];

  final int pageSize = limit <= 0
      ? 0
      : (limit > kHistoryPageMax ? kHistoryPageMax : limit);
  final int total = ordered.length;
  int start;
  int end;
  if (at.isNotEmpty) {
    final int found = ordered.indexWhere(
      (Map<String, dynamic> m) => '${m['id']}' == at,
    );
    if (found < 0) {
      end = total;
      start = (pageSize > 0 && end > pageSize) ? end - pageSize : 0;
    } else {
      final int span = pageSize > 0 ? pageSize : total;
      start = (found - span ~/ 2).clamp(0, total);
      end = (start + span).clamp(0, total);
      if (end - start < span) start = (end - span).clamp(0, total);
      if (found < start) start = found;
      if (found >= end) end = found + 1;
    }
  } else if (from != null) {
    start = from.clamp(0, total);
    end = pageSize > 0 ? (start + pageSize).clamp(0, total) : total;
  } else {
    end = total;
    if (before.isNotEmpty) {
      final int index = ordered.indexWhere(
        (Map<String, dynamic> m) => '${m['id']}' == before,
      );
      if (index >= 0) end = index;
    }
    start = (pageSize > 0 && end > pageSize) ? end - pageSize : 0;
  }

  final FileQuestionStore questions = FileQuestionStore(
    TreePaths(paths.root),
  );
  final List<Map<String, dynamic>> page = <Map<String, dynamic>>[
    for (final Map<String, dynamic> message in ordered.sublist(start, end))
      _withQuestionOverlay(message, questions),
  ];
  // 字节预算：从**末尾**往前累加（末尾一页才是默认口径），超预算丢页首。
  int keepFrom = page.length;
  int bytes = 0;
  while (keepFrom > 0) {
    final int size = utf8.encode(jsonEncode(page[keepFrom - 1])).length;
    if (bytes + size > kHistoryPageByteBudget && keepFrom < page.length) break;
    bytes += size;
    keepFrom--;
  }
  final List<Map<String, dynamic>> visible =
      keepFrom == 0 ? page : page.sublist(keepFrom);
  start += keepFrom;
  return <String, dynamic>{
    'agent_id': agentId,
    'session_id': sessionId,
    'messages': visible,
    'total': total,
    'offset': start,
    'has_more': start > 0,
  };
}

/// 消息数：**非工具消息**（与核心 `messageCount` 同口径：排 `kind == tool`，
/// 排临时员工消息**除了**完成报告）。只扫显示行，不再全量读消息文件。
Future<int> messageCountOf(ConversationDb db, String sessionId) async {
  int count = 0;
  for (final Map<String, dynamic> row in await db.displayRows(
    sessionId: sessionId,
  )) {
    final String kind = '${row['kind'] ?? 'text'}';
    final String subagentId = '${row['subagent_id'] ?? ''}';
    if (kind == 'tool') continue;
    if (subagentId.isNotEmpty && kind != 'subagent_report') continue;
    count++;
  }
  return count;
}

/// 提问卡片的历史形态：用提问记录（真源）覆盖只追加消息里的旧状态。
///
/// 与核心 `_messageJson` 同一处、同一顺序赋值（已有键保持位置，新键追加）——
/// 这样 JSON 字节序也一致。
Map<String, dynamic> _withQuestionOverlay(
  Map<String, dynamic> message,
  QuestionStore questions,
) {
  final Map<String, dynamic> json = Map<String, dynamic>.of(message);
  if ('${json['kind']}' != 'ask_user_question') return json;
  final QuestionRecord? record = questions.byId('${json['id']}');
  if (record == null) return json;
  json['answered'] = !record.isPending;
  json['answer'] = record.answer;
  json['questions'] = <Map<String, dynamic>>[
    for (final AskedQuestion question in record.questions) question.toJson(),
  ];
  json['answers'] = record.answers;
  if (record.options.isNotEmpty) json['options'] = record.options;
  return json;
}
