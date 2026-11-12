import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../settings/domain_settings.dart';

/// 决策调用失败：稳定 [code] + 人话 [message]。
class DecisionFailure implements Exception {
  DecisionFailure(this.message, {this.code = 'decision_error'});

  final String message;
  final String code;

  @override
  String toString() => message;
}

/// 一个类型化问题：`noul`（是/否概率）/ `choice`（选项）/ `score`（有序分值）。
sealed class DecisionQuestion {
  const DecisionQuestion(this.name);

  /// 问题名（回包按它对应）。
  final String name;

  String get type;

  Map<String, Object?> toJson();

  /// 合法性问题（空名 / 选项不足等）；返回 null = 合法。
  String? validate() {
    if (name.trim().isEmpty) return '问题名不能为空';
    return null;
  }
}

class NoulQuestion extends DecisionQuestion {
  const NoulQuestion(super.name);

  @override
  String get type => 'noul';

  @override
  Map<String, Object?> toJson() => <String, Object?>{'type': type};
}

class ChoiceQuestion extends DecisionQuestion {
  const ChoiceQuestion(super.name, this.options);

  final List<String> options;

  @override
  String get type => 'choice';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'options': options,
  };

  @override
  String? validate() {
    final String? base = super.validate();
    if (base != null) return base;
    if (options.length < 2) return 'choice 问题 $name 至少需要 2 个选项';
    if (options.toSet().length != options.length) {
      return 'choice 问题 $name 的选项不能重复';
    }
    return null;
  }
}

class ScoreQuestion extends DecisionQuestion {
  const ScoreQuestion(super.name, this.levels);

  /// 有序档位（从低到高）。
  final List<String> levels;

  @override
  String get type => 'score';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'levels': levels,
  };

  @override
  String? validate() {
    final String? base = super.validate();
    if (base != null) return base;
    if (levels.length < 2) return 'score 问题 $name 至少需要 2 个档位';
    return null;
  }
}

/// 单个问题的回包（只有选中值/概率/置信度，没有自然语言）。
class DecisionAnswer {
  const DecisionAnswer({
    required this.question,
    required this.type,
    required this.confidence,
    this.choice,
    this.noul,
    this.score,
    this.probabilities = const <String, double>{},
    this.raw = const <String, Object?>{},
  });

  final String question;
  final String type;

  /// 选中值 / 概率 / 分值（按类型三选一）。
  final String? choice;
  final double? noul;
  final double? score;

  final Map<String, double> probabilities;

  /// 置信度（0~1）；网关没给时按概率推导。
  final double confidence;

  final Map<String, Object?> raw;

  Map<String, Object?> toJson() => <String, Object?>{
    'question': question,
    'type': type,
    if (choice != null) 'choice': choice,
    if (noul != null) 'noul': noul,
    if (score != null) 'score': score,
    if (probabilities.isNotEmpty) 'probabilities': probabilities,
    'confidence': confidence,
  };
}

/// 一次决策调用的结果。
class DecisionResult {
  const DecisionResult({
    required this.answers,
    required this.modelId,
    this.promptTokens = 0,
  });

  final Map<String, DecisionAnswer> answers;
  final String modelId;
  final int promptTokens;

  /// 低于模型阈值的题目名：调用方据此回退 chat / 向用户提问。
  List<String> lowConfidence(double threshold) => <String>[
    for (final MapEntry<String, DecisionAnswer> entry in answers.entries)
      if (entry.value.confidence < threshold) entry.key,
  ];

  Map<String, Object?> toJson() => <String, Object?>{
    'model': modelId,
    if (promptTokens > 0) 'usage': <String, Object?>{'prompt_tokens': promptTokens},
    'answers': <String, Object?>{
      for (final MapEntry<String, DecisionAnswer> entry in answers.entries)
        entry.key: entry.value.toJson(),
    },
  };
}

/// JEV 决策客户端（MP-6）：`noul` / `choice` / `score`，**不复用 chat 的 SSE 工具循环**。
///
/// 口径（model-pool-kinds-recon §4.2）：
/// - 只接受 `kind=decision` / `protocol=jev` 且配置了 `confidence_threshold` 的模型；
/// - 输入 state + 类型化问题，回包只有选中值/概率/置信度；
/// - 单次最多 [maxQuestions] 个问题；超时显式报 `timeout`；
/// - 置信度低于模型阈值时由 [DecisionResult.lowConfidence] 标出，**不自动执行不可逆动作**。
///
/// 网关字段差异集中在 [_parseAnswer]：字段漂移时给可读错误，不静默猜。
class DecisionClient {
  DecisionClient({
    HttpClient? client,
    this.requestTimeout = const Duration(seconds: 30),
    this.maxQuestions = 16,
    this.path = '/decisions',
    this.log,
  }) : _client = client ?? HttpClient() {
    _client.connectionTimeout = requestTimeout;
  }

  final HttpClient _client;
  final Duration requestTimeout;
  final int maxQuestions;

  /// 决策端点路径（追加在 `base_url` 后；网关可能不同）。
  final String path;

  final void Function(String message)? log;

  bool _closed = false;

  Future<DecisionResult> decide({
    required CoreModelConfig model,
    required String state,
    required List<DecisionQuestion> questions,
  }) async {
    _validateModel(model);
    if (state.trim().isEmpty) {
      throw DecisionFailure('state 不能为空', code: 'invalid_arguments');
    }
    if (questions.isEmpty) {
      throw DecisionFailure('至少需要一个决策问题', code: 'invalid_arguments');
    }
    if (questions.length > maxQuestions) {
      throw DecisionFailure(
        '单次问题数超过上限 $maxQuestions（收到 ${questions.length}）',
        code: 'too_many_questions',
      );
    }
    final Set<String> names = <String>{};
    for (final DecisionQuestion question in questions) {
      final String? invalid = question.validate();
      if (invalid != null) {
        throw DecisionFailure(invalid, code: 'invalid_question');
      }
      if (!names.add(question.name)) {
        throw DecisionFailure(
          '问题名重复：${question.name}',
          code: 'invalid_question',
        );
      }
    }

    final Map<String, dynamic> response = await _post(
      model,
      <String, Object?>{
        'state': state,
        'questions': <String, Object?>{
          for (final DecisionQuestion question in questions)
            question.name: question.toJson(),
        },
      },
    );
    final Map<String, Object?> answersRaw = _answersOf(response);
    final Map<String, DecisionAnswer> answers = <String, DecisionAnswer>{};
    for (final DecisionQuestion question in questions) {
      final Object? raw = answersRaw[question.name];
      if (raw is! Map) {
        throw DecisionFailure(
          '回包缺少问题 ${question.name} 的答案',
          code: 'invalid_response',
        );
      }
      answers[question.name] = _parseAnswer(
        question,
        raw.map(
          (Object? key, Object? value) =>
              MapEntry<String, Object?>(key.toString(), value),
        ),
      );
    }
    int promptTokens = 0;
    final Object? usage = response['usage'];
    if (usage is Map) {
      promptTokens = (usage['prompt_tokens'] as num?)?.toInt() ?? 0;
    }
    return DecisionResult(
      answers: answers,
      modelId: model.modelId,
      promptTokens: promptTokens,
    );
  }

  /// MP-7 能力探测：发一个 `noul` 探针；返回 `{ok, confidence}` 或 `{ok:false, code, error}`。
  Future<Map<String, dynamic>> probe({
    required CoreModelConfig model,
  }) async {
    try {
      final DecisionResult result = await decide(
        model: model,
        state: 'capability probe',
        questions: const <DecisionQuestion>[NoulQuestion('ok')],
      );
      return <String, dynamic>{
        'ok': true,
        'model': model.modelId,
        'confidence': result.answers['ok']?.confidence ?? 0,
      };
    } on DecisionFailure catch (error) {
      return <String, dynamic>{
        'ok': false,
        'model': model.modelId,
        'code': error.code,
        'error': error.message,
      };
    } catch (error) {
      return <String, dynamic>{
        'ok': false,
        'model': model.modelId,
        'code': 'decision_error',
        'error': '$error',
      };
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
  }

  void _validateModel(CoreModelConfig model) {
    if (model.kind != kModelKindDecision) {
      throw DecisionFailure(
        '模型 ${model.modelId} 是 ${model.kind}，不是 decision 模型',
        code: 'not_decision_model',
      );
    }
    if (model.protocol != kModelProtocolJev) {
      throw DecisionFailure(
        'decision 只支持 jev 协议（当前 ${model.protocol}）',
        code: 'unsupported_protocol',
      );
    }
    if (model.confidenceThreshold <= 0) {
      throw DecisionFailure(
        '模型 ${model.modelId} 未配置 confidence_threshold',
        code: 'invalid_model',
      );
    }
    if (model.effectiveBaseUrl.isEmpty) {
      throw DecisionFailure(
        '模型 ${model.modelId} 未配置 base_url',
        code: 'invalid_model',
      );
    }
    if (model.effectiveApiKey.isEmpty) {
      throw DecisionFailure(
        '模型 ${model.modelId} 未配置 api_key',
        code: 'invalid_model',
      );
    }
  }

  Future<Map<String, dynamic>> _post(
    CoreModelConfig model,
    Map<String, Object?> body,
  ) async {
    if (_closed) {
      throw DecisionFailure('DecisionClient 已关闭', code: 'client_closed');
    }
    final String base = model.effectiveBaseUrl.replaceFirst(
      RegExp(r'/+$'),
      '',
    );
    final String suffix = path.startsWith('/') ? path : '/$path';
    final Uri uri = Uri.parse('$base$suffix');
    try {
      final HttpClientRequest request = await _client
          .postUrl(uri)
          .timeout(requestTimeout);
      request.headers.contentType = ContentType.json;
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${model.effectiveApiKey}',
      );
      request.add(utf8.encode(jsonEncode(body)));
      final HttpClientResponse response = await request.close().timeout(
        requestTimeout,
      );
      final String text = await utf8.decoder
          .bind(response)
          .join()
          .timeout(requestTimeout);
      if (response.statusCode != 200) {
        throw DecisionFailure(
          '决策端点返回 ${response.statusCode}：${_clip(text)}',
          code: 'http_error',
        );
      }
      final Object? decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw DecisionFailure(
          '决策回包不是对象：${_clip(text)}',
          code: 'invalid_response',
        );
      }
      final Object? questions = body['questions'];
      log?.call(
        'decision model=${model.modelId} '
        'questions=${questions is Map ? questions.length : 0}',
      );
      return decoded.map(
        (Object? key, Object? value) =>
            MapEntry<String, dynamic>(key.toString(), value),
      );
    } on DecisionFailure {
      rethrow;
    } on TimeoutException {
      throw DecisionFailure(
        '决策请求超时（${requestTimeout.inSeconds}s）',
        code: 'timeout',
      );
    } catch (error) {
      throw DecisionFailure('决策请求失败：$error', code: 'network_error');
    }
  }

  Map<String, Object?> _answersOf(Map<String, dynamic> response) {
    final Object? raw = response['answers'];
    if (raw is! Map) {
      throw DecisionFailure(
        '决策回包缺 answers 对象',
        code: 'invalid_response',
      );
    }
    return raw.map(
      (Object? key, Object? value) =>
          MapEntry<String, Object?>(key.toString(), value),
    );
  }

  DecisionAnswer _parseAnswer(
    DecisionQuestion question,
    Map<String, Object?> raw,
  ) {
    final Map<String, double> probabilities = _probabilities(
      raw['probabilities'],
      question.name,
    );
    double? explicit = _numInUnit(raw['confidence']);
    switch (question) {
      case NoulQuestion():
        final double? value = _numInUnit(raw['noul']);
        if (value == null) {
          throw DecisionFailure(
            'noul 问题 ${question.name} 的回包缺 0~1 的 noul',
            code: 'invalid_response',
          );
        }
        final double confidence =
            explicit ?? _max(<double>[value, 1 - value]) ?? 0;
        return DecisionAnswer(
          question: question.name,
          type: question.type,
          noul: value,
          probabilities: probabilities,
          confidence: confidence,
          raw: raw,
        );
      case ChoiceQuestion():
        final String choice = (raw['choice'] ?? '').toString().trim();
        if (!question.options.contains(choice)) {
          throw DecisionFailure(
            'choice 问题 ${question.name} 回包选中值不在选项内：$choice',
            code: 'invalid_response',
          );
        }
        final double confidence =
            explicit ??
            probabilities[choice] ??
            _maxOrZero(probabilities.values.toList()) ??
            0;
        return DecisionAnswer(
          question: question.name,
          type: question.type,
          choice: choice,
          probabilities: probabilities,
          confidence: confidence,
          raw: raw,
        );
      case ScoreQuestion():
        final double? value = _num(raw['score']);
        if (value == null) {
          throw DecisionFailure(
            'score 问题 ${question.name} 的回包缺 score',
            code: 'invalid_response',
          );
        }
        final double confidence =
            explicit ?? _maxOrZero(probabilities.values.toList()) ?? 0;
        return DecisionAnswer(
          question: question.name,
          type: question.type,
          score: value,
          probabilities: probabilities,
          confidence: confidence,
          raw: raw,
        );
    }
  }

  Map<String, double> _probabilities(Object? raw, String question) {
    if (raw == null) return const <String, double>{};
    if (raw is! Map) {
      throw DecisionFailure(
        '问题 $question 的 probabilities 不是对象',
        code: 'invalid_response',
      );
    }
    final Map<String, double> out = <String, double>{};
    raw.forEach((Object? key, Object? value) {
      final double? parsed = _numInUnit(value);
      if (parsed == null) {
        throw DecisionFailure(
          '问题 $question 的 probabilities.$key 不是 0~1 的数',
          code: 'invalid_response',
        );
      }
      out[key.toString()] = parsed;
    });
    return out;
  }

  static double? _num(Object? raw) {
    if (raw is num) return raw.toDouble();
    if (raw is String) return double.tryParse(raw.trim());
    return null;
  }

  static double? _numInUnit(Object? raw) {
    final double? value = _num(raw);
    if (value == null || value < 0 || value > 1) return null;
    return value;
  }

  static double? _max(List<double> values) {
    if (values.isEmpty) return null;
    return values.reduce((double a, double b) => a > b ? a : b);
  }

  static double? _maxOrZero(List<double> values) =>
      values.isEmpty ? null : _max(values);

  static String _clip(String text) {
    final String oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length <= 300 ? oneLine : '${oneLine.substring(0, 300)}…';
  }
}
