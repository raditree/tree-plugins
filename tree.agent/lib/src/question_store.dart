import 'dart:convert';
import 'dart:io';

import 'paths.dart';

/// 一道问题（与核心 `AskedQuestion` 同形）。
class AskedQuestionView {
  const AskedQuestionView(this.question, this.options);

  final String question;
  final List<String> options;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'question': question,
    'options': options,
  };
}

/// 提问记录视图（只取历史接口叠加需要的字段）。
class QuestionView {
  const QuestionView({
    required this.qid,
    required this.questions,
    required this.answers,
    required this.answer,
    required this.status,
  });

  final String qid;
  final List<AskedQuestionView> questions;
  final List<String> answers;
  final String answer;
  final String status;

  bool get isPending => status == 'pending';

  /// 候选选项 = 第一问的选项（核心 `QuestionRecord.options` 的兼容读法）。
  List<String> get options => questions.first.options;
}

/// 读 `data/questions.json`（JSON 数组；坏文件按空表）。
///
/// 与核心 `FileQuestionStore.load` + `QuestionRecord.fromJson` 同口径：
/// - 没 `questions` 的老记录由 `question`/`options` 合成一项；
/// - `answers` 归一成与疑问等长（缺项补空串、多余截掉）；
/// - `answer` 为空但逐题答案非空 ⇒ 按 `formatAnswerLines` 推出兼容摘要。
Map<String, QuestionView> readQuestionViews(AgentDataPaths paths) {
  final Map<String, QuestionView> byId = <String, QuestionView>{};
  final File file = File(paths.questionsFile);
  if (!file.existsSync()) return byId;
  try {
    final Object? decoded = jsonDecode(
      utf8.decode(file.readAsBytesSync(), allowMalformed: true),
    );
    if (decoded is! List) return byId;
    for (final Object? item in decoded) {
      if (item is! Map) continue;
      final Map<String, dynamic> json = item.map(
        (Object? key, Object? value) => MapEntry(key.toString(), value),
      );
      final QuestionView view = _toView(json);
      if (view.qid.isEmpty) continue;
      byId[view.qid] = view;
    }
  } catch (_) {
    return <String, QuestionView>{};
  }
  return byId;
}

QuestionView _toView(Map<String, dynamic> json) {
  final List<AskedQuestionView> questions =
      (json['questions'] as List<dynamic>?)
          ?.whereType<Map<dynamic, dynamic>>()
          .map(
            (Map<dynamic, dynamic> item) => _toAsked(
              item.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
            ),
          )
          .toList() ??
      <AskedQuestionView>[];
  final List<AskedQuestionView> normalizedQuestions = questions.isNotEmpty
      ? questions
      : <AskedQuestionView>[
          AskedQuestionView(
            (json['question'] as String? ?? ''),
            (json['options'] as List<dynamic>?)
                    ?.map((dynamic e) => e.toString())
                    .toList() ??
                const <String>[],
          ),
        ];
  final List<String> rawAnswers =
      (json['answers'] as List<dynamic>?)
          ?.map((dynamic e) => e.toString())
          .toList() ??
      const <String>[];
  final String rawAnswer = json['answer'] as String? ?? '';
  final List<String> fromSingle = rawAnswers.isNotEmpty
      ? rawAnswers
      : (rawAnswer.isEmpty ? const <String>[] : <String>[rawAnswer]);
  final List<String> answers = <String>[
    for (int i = 0; i < normalizedQuestions.length; i++)
      i < fromSingle.length ? fromSingle[i].trim() : '',
  ];
  String answer = rawAnswer;
  if (answer.isEmpty && answers.any((String a) => a.isNotEmpty)) {
    answer = _formatAnswerLines(normalizedQuestions, answers);
  }
  return QuestionView(
    qid: json['qid'] as String? ?? '',
    questions: normalizedQuestions,
    answers: answers,
    answer: answer,
    status: json['status'] as String? ?? 'pending',
  );
}

AskedQuestionView _toAsked(Map<String, dynamic> json) => AskedQuestionView(
  (json['question'] ?? '').toString(),
  (json['options'] as List<dynamic>?)
          ?.map((dynamic e) => e.toString())
          .toList() ??
      const <String>[],
);

/// 与核心 `formatAnswerLines` 同口径的兼容摘要。
String _formatAnswerLines(
  List<AskedQuestionView> questions,
  List<String> answers,
) {
  String at(int i) => i < answers.length ? answers[i].trim() : '';
  if (questions.length <= 1) {
    final String only = at(0);
    return only.isEmpty ? '（未作答）' : only;
  }
  final StringBuffer buffer = StringBuffer();
  for (int i = 0; i < questions.length; i++) {
    if (i > 0) buffer.write('\n');
    final String text = at(i);
    buffer.write(
      '第${i + 1}题（${_label(questions[i].question)}）：'
      '${text.isEmpty ? '（未作答）' : text}',
    );
  }
  return buffer.toString();
}

String _label(String question) {
  final String text = question.replaceAll(RegExp(r'\s+'), ' ').trim();
  const int max = 40;
  return text.length <= max ? text : '${text.substring(0, max)}…';
}
