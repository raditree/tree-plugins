import 'paths.dart';
import 'question_store.dart';
import 'session_store.dart';

/// 会话历史单页上限（与核心 `CoreServer._historyPageMax` 同值）。
const int kHistoryPageMax = 2000;

/// `GET /api/conversations/{agentId}` 的分页实现（与核心逐行同算法）。
///
/// 语义：
/// - `session_id=all`：合并该 agent **全部会话**的消息，再按 timestamp 升序；
/// - 默认按 `timestamp` 升序（相同时间戳保持输入顺序——核心与本实现都是同一
///   Dart sort 在相同输入上的同一次置换）；
/// - `limit` 取**末尾**一页；`before` 取该消息之前的一页；`from` 按下标；
///   `at` 以该消息为中心取一页；都找不到时按核心口径退回末尾一页；
/// - 响应 `offset` = 这一页第一条的全局下标；`has_more` = 前面还有没有。
Map<String, dynamic> conversationPage(
  AgentDataPaths paths,
  String agentId, {
  required String sessionId,
  int limit = 0,
  String before = '',
  int? from,
  String at = '',
}) {
  final List<Map<String, dynamic>> ordered = sessionId == 'all'
      ? <Map<String, dynamic>>[
          for (final SessionRecord session in readSessions(paths, agentId))
            ...readMessages(paths, agentId, session.sessionId),
        ]
      : readMessages(paths, agentId, sessionId);
  ordered.sort(
    (Map<String, dynamic> a, Map<String, dynamic> b) =>
        _timestampOf(a).compareTo(_timestampOf(b)),
  );

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

  final Map<String, QuestionView> questions = readQuestionViews(paths);
  final List<Map<String, dynamic>> page = <Map<String, dynamic>>[
    for (final Map<String, dynamic> message in ordered.sublist(start, end))
      _withQuestionOverlay(message, questions),
  ];
  return <String, dynamic>{
    'agent_id': agentId,
    'session_id': sessionId,
    'messages': page,
    'total': total,
    'offset': start,
    'has_more': start > 0,
  };
}

/// 提问卡片的历史形态：用提问记录（真源）覆盖只追加消息里的旧状态。
///
/// 与核心 `_messageJson` 同一处、同一顺序赋值（已有键保持位置，新键追加）——
/// 这样 JSON 字节序也一致。
Map<String, dynamic> _withQuestionOverlay(
  Map<String, dynamic> message,
  Map<String, QuestionView> questions,
) {
  final Map<String, dynamic> json = Map<String, dynamic>.of(message);
  if ('${json['kind']}' != 'ask_user_question') return json;
  final QuestionView? record = questions['${json['id']}'];
  if (record == null) return json;
  json['answered'] = !record.isPending;
  json['answer'] = record.answer;
  json['questions'] = <Map<String, dynamic>>[
    for (final AskedQuestionView question in record.questions)
      question.toJson(),
  ];
  json['answers'] = record.answers;
  if (record.options.isNotEmpty) json['options'] = record.options;
  return json;
}

int _timestampOf(Map<String, dynamic> message) {
  final Object? raw = message['timestamp'];
  if (raw is String) return DateTime.tryParse(raw)?.millisecondsSinceEpoch ?? 0;
  return 0;
}
