import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../settings/domain_settings.dart';
import '../util/tokens.dart';

/// embedding 调用失败：稳定 [code] + 人话 [message]。
class EmbeddingFailure implements Exception {
  EmbeddingFailure(this.message, {this.code = 'embedding_error'});

  final String message;
  final String code;

  @override
  String toString() => message;
}

/// 一批 embedding 的结果（按输入顺序返回）。
class EmbeddingResult {
  const EmbeddingResult({
    required this.vectors,
    required this.modelId,
    this.promptTokens = 0,
  });

  final List<List<double>> vectors;
  final String modelId;
  final int promptTokens;

  int get dimensions => vectors.isEmpty ? 0 : vectors.first.length;

  Map<String, Object?> toJson() => <String, Object?>{
    'model': modelId,
    'count': vectors.length,
    'dimensions': dimensions,
    'usage': <String, Object?>{'prompt_tokens': promptTokens},
  };
}

/// OpenAI 兼容 `/embeddings` 客户端（MP-5）。
///
/// 口径（model-pool-kinds-recon §4.1）：
/// - 只接受 `kind=embedding` 且 `dimensions>0` 的模型；
/// - 单次最多 [maxBatch] 条，自动分批；单条超过 `max_input_tokens` 估算 ⇒ 直接拒绝；
/// - 回包向量长度必须等于配置维度，**整批失败不返回半截**（避免污染索引）；
/// - 失败可读：HTTP 错误带端点原文（截断），超时显式报 `timeout`。
class EmbeddingClient {
  EmbeddingClient({
    HttpClient? client,
    this.requestTimeout = const Duration(seconds: 60),
    this.maxBatch = 64,
    this.log,
  }) : _client = client ?? HttpClient() {
    _client.connectionTimeout = requestTimeout;
  }

  final HttpClient _client;
  final Duration requestTimeout;
  final int maxBatch;
  final void Function(String message)? log;

  bool _closed = false;

  /// 调一次 embedding；[inputs] 为空返回空结果。
  Future<EmbeddingResult> embed({
    required CoreModelConfig model,
    required List<String> inputs,
  }) async {
    _validateModel(model);
    if (inputs.isEmpty) {
      return EmbeddingResult(
        vectors: const <List<double>>[],
        modelId: model.modelId,
      );
    }
    for (int i = 0; i < inputs.length; i++) {
      if (model.maxInputTokens > 0 &&
          estimateTokens(inputs[i], scale: model.tokenScale) >
              model.maxInputTokens) {
        throw EmbeddingFailure(
          '第 ${i + 1} 条输入超过模型 max_input_tokens='
          '${model.maxInputTokens}，请调用方先切段',
          code: 'input_too_long',
        );
      }
    }

    final List<List<double>> vectors = <List<double>>[];
    int promptTokens = 0;
    for (int start = 0; start < inputs.length; start += maxBatch) {
      final int end = (start + maxBatch < inputs.length)
          ? start + maxBatch
          : inputs.length;
      final Map<String, dynamic> response = await _post(
        model,
        inputs.sublist(start, end),
      );
      final Map<String, Object?> parsed = _parse(response, model, end - start);
      vectors.addAll(
        (parsed['vectors']! as List<List<double>>),
      );
      promptTokens += parsed['prompt_tokens']! as int;
    }
    return EmbeddingResult(
      vectors: vectors,
      modelId: model.modelId,
      promptTokens: promptTokens,
    );
  }

  /// MP-7 能力探测：发一条最小输入，验证端点、密钥与维度。
  ///
  /// 不抛异常：返回 `{ok:true, dimensions}` 或 `{ok:false, code, error}`，
  /// 让调用方给出可读降级（不空转）。
  Future<Map<String, dynamic>> probe({
    required CoreModelConfig model,
  }) async {
    try {
      final EmbeddingResult result = await embed(
        model: model,
        inputs: const <String>['tree embedding probe'],
      );
      return <String, dynamic>{
        'ok': true,
        'model': model.modelId,
        'dimensions': result.dimensions,
      };
    } on EmbeddingFailure catch (error) {
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
        'code': 'embedding_error',
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
    if (model.kind != kModelKindEmbedding) {
      throw EmbeddingFailure(
        '模型 ${model.modelId} 是 ${model.kind}，不是 embedding 模型',
        code: 'not_embedding_model',
      );
    }
    if (model.protocol != kModelProtocolOpenai) {
      throw EmbeddingFailure(
        'embedding 只支持 openai 协议（当前 ${model.protocol}）',
        code: 'unsupported_protocol',
      );
    }
    if (model.dimensions <= 0) {
      throw EmbeddingFailure(
        '模型 ${model.modelId} 未配置 dimensions（必须 >0）',
        code: 'invalid_model',
      );
    }
    if (model.baseUrl.trim().isEmpty) {
      throw EmbeddingFailure(
        '模型 ${model.modelId} 未配置 base_url',
        code: 'invalid_model',
      );
    }
    if (model.apiKey.trim().isEmpty) {
      throw EmbeddingFailure(
        '模型 ${model.modelId} 未配置 api_key',
        code: 'invalid_model',
      );
    }
  }

  Future<Map<String, dynamic>> _post(
    CoreModelConfig model,
    List<String> batch,
  ) async {
    if (_closed) {
      throw EmbeddingFailure('EmbeddingClient 已关闭', code: 'client_closed');
    }
    final Uri uri = Uri.parse(
      '${model.baseUrl.trim().replaceFirst(RegExp(r'/+$'), '')}/embeddings',
    );
    try {
      final Map<String, dynamic> body = await _send(
        uri,
        model.apiKey,
        <String, Object?>{
          'model': model.modelId,
          'input': batch,
          'dimensions': model.dimensions,
        },
      );
      return body;
    } on EmbeddingFailure {
      rethrow;
    } on TimeoutException {
      throw EmbeddingFailure(
        'embedding 请求超时（${requestTimeout.inSeconds}s）',
        code: 'timeout',
      );
    } catch (error) {
      throw EmbeddingFailure('embedding 请求失败：$error', code: 'network_error');
    }
  }

  Future<Map<String, dynamic>> _send(
    Uri uri,
    String apiKey,
    Map<String, Object?> body,
  ) async {
    final HttpClientRequest request = await _client
        .postUrl(uri)
        .timeout(requestTimeout);
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    request.add(utf8.encode(jsonEncode(body)));
    final HttpClientResponse response = await request.close().timeout(
      requestTimeout,
    );
    final String text = await utf8.decoder
        .bind(response)
        .join()
        .timeout(requestTimeout);
    if (response.statusCode != 200) {
      throw EmbeddingFailure(
        'embedding 端点返回 ${response.statusCode}：${_clip(text)}',
        code: 'http_error',
      );
    }
    final Object? decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw EmbeddingFailure(
        'embedding 回包不是对象：${_clip(text)}',
        code: 'invalid_response',
      );
    }
    return decoded.map(
      (Object? key, Object? value) =>
          MapEntry<String, dynamic>(key.toString(), value),
    );
  }

  /// 校验回包并转成 float 列表；向量长度不符 ⇒ 整批失败。
  Map<String, Object?> _parse(
    Map<String, dynamic> body,
    CoreModelConfig model,
    int expected,
  ) {
    final Object? data = body['data'];
    if (data is! List) {
      throw EmbeddingFailure(
        'embedding 回包缺 data 数组',
        code: 'invalid_response',
      );
    }
    final List<({int index, List<double> vector})> rows =
        <({int index, List<double> vector})>[];
    for (final Object? item in data) {
      if (item is! Map) {
        throw EmbeddingFailure(
          'embedding 回包的 data 项不是对象',
          code: 'invalid_response',
        );
      }
      final int index = (item['index'] as num?)?.toInt() ?? rows.length;
      final Object? raw = item['embedding'];
      if (raw is! List) {
        throw EmbeddingFailure(
          'embedding 回包第 $index 项缺 embedding 数组',
          code: 'invalid_response',
        );
      }
      if (raw.length != model.dimensions) {
        throw EmbeddingFailure(
          '维度不符：配置 ${model.dimensions}，端点返回 ${raw.length}'
          '（模型 ${model.modelId}）',
          code: 'dimension_mismatch',
        );
      }
      final List<double> vector = <double>[
        for (final Object? value in raw)
          if (value is num)
            value.toDouble()
          else
            throw EmbeddingFailure(
              'embedding 回包第 $index 项含非数字分量',
              code: 'invalid_response',
            ),
      ];
      rows.add((index: index, vector: vector));
    }
    rows.sort((a, b) => a.index.compareTo(b.index));
    if (rows.length != expected) {
      throw EmbeddingFailure(
        'embedding 回包条数不符：请求 $expected，返回 ${rows.length}',
        code: 'invalid_response',
      );
    }
    for (int i = 0; i < rows.length; i++) {
      if (rows[i].index != i) {
        throw EmbeddingFailure(
          'embedding 回包 index 不连续（期望 $i，收到 ${rows[i].index}）',
          code: 'invalid_response',
        );
      }
    }
    int promptTokens = 0;
    final Object? usage = body['usage'];
    if (usage is Map) {
      promptTokens = (usage['prompt_tokens'] as num?)?.toInt() ?? 0;
    }
    log?.call(
      'embedding model=${model.modelId} count=${rows.length} '
      'dimensions=${model.dimensions}',
    );
    return <String, Object?>{
      'vectors': <List<double>>[for (final row in rows) row.vector],
      'prompt_tokens': promptTokens,
    };
  }

  static String _clip(String text) {
    final String oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length <= 300 ? oneLine : '${oneLine.substring(0, 300)}…';
  }
}
