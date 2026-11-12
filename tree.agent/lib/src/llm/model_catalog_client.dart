/// OpenAI 兼容端点的模型目录客户端（P8）：探测价格与思考强度档位。
///
/// 只走 `GET {base_url}/models`：OpenRouter 等聚合网关会在条目里带
/// `pricing` / `supported_parameters` / `reasoning`，部分自建网关只回 id——
/// 那种情况按"未声明"处理（UI 回退兜底档位），**不报错**。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../model_meta.dart';
import '../settings/domain_settings.dart';

/// 模型目录端点：把用户填的 base_url（可能已含 `/chat/completions`）归一到 `/models`。
String modelsEndpointFor(String baseUrl) {
  String base = baseUrl.trim();
  if (base.isEmpty) {
    throw ModelMetaFailure('模型未配置 base_url', code: 'invalid_model');
  }
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  for (final String suffix in const <String>[
    '/chat/completions',
    '/completions',
  ]) {
    if (base.endsWith(suffix)) {
      base = base.substring(0, base.length - suffix.length);
      break;
    }
  }
  if (base.isEmpty) {
    throw ModelMetaFailure('base_url 不能只有路径后缀：$baseUrl', code: 'invalid_model');
  }
  return '$base/models';
}

class ModelCatalogClient {
  ModelCatalogClient({
    HttpClient? client,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? HttpClient();

  final HttpClient _client;
  final Duration timeout;

  /// 拉取端点模型目录，并挑出目标模型条目（回包必须是 JSON 对象）。
  Future<Map<String, Object?>> fetchModelEntry({
    required String baseUrl,
    required String apiKey,
    required String modelId,
  }) async {
    final Map<String, Object?> payload = await _fetchModelsPayload(
      baseUrl: baseUrl,
      apiKey: apiKey,
    );
    return selectOpenAiModelEntry(payload, modelId);
  }

  /// 拉取端点声明的**全部**模型条目（provider 池的目录缓存用，D7）。
  ///
  /// 回包不是列表（单模型对象）时返回只含该对象的一项；条目缺少 id/name 的跳过。
  Future<List<Map<String, Object?>>> fetchCatalog({
    required String baseUrl,
    required String apiKey,
  }) async {
    final Map<String, Object?> payload = await _fetchModelsPayload(
      baseUrl: baseUrl,
      apiKey: apiKey,
    );
    final Object? data = payload['data'];
    final Object? models = payload['models'];
    final Object? rawList = data is List
        ? data
        : (models is List ? models : null);
    if (rawList == null) {
      final List<Map<String, Object?>> single = <Map<String, Object?>>[];
      if (modelEntryId(payload).isNotEmpty) single.add(payload);
      if (single.isEmpty) {
        throw ModelMetaFailure(
          '端点回包没有 data / models 列表（也不像单模型对象）',
          code: 'model_meta_shape',
        );
      }
      return single;
    }
    return <Map<String, Object?>>[
      for (final Object? item in rawList as List<Object?>)
        if (item is Map)
          <String, Object?>{
            for (final MapEntry<Object?, Object?> entry in item.entries)
              entry.key.toString(): entry.value,
          },
    ];
  }

  Future<Map<String, Object?>> _fetchModelsPayload({
    required String baseUrl,
    required String apiKey,
  }) async {
    final Uri uri = Uri.parse(modelsEndpointFor(baseUrl));
    if (apiKey.trim().isEmpty) {
      throw ModelMetaFailure('模型未配置 api_key', code: 'invalid_model');
    }
    final HttpClientRequest request;
    try {
      request = await _client.getUrl(uri).timeout(timeout);
    } catch (error) {
      throw ModelMetaFailure(
        '连接模型目录失败（$uri）：$error',
        code: 'model_meta_network',
      );
    }
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${apiKey.trim()}');
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final HttpClientResponse response;
    final String text;
    try {
      response = await request.close().timeout(timeout);
      text = await utf8.decoder.bind(response).join().timeout(timeout);
    } catch (error) {
      throw ModelMetaFailure(
        '读取模型目录失败（$uri）：$error',
        code: 'model_meta_network',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ModelMetaFailure(
        '模型目录返回 ${response.statusCode}：${_clip(text)}',
        code: 'model_meta_http',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      throw ModelMetaFailure(
        '模型目录回包不是 JSON：${_clip(text)}',
        code: 'model_meta_shape',
      );
    }
    if (decoded is! Map) {
      throw ModelMetaFailure(
        '模型目录回包不是对象：${_clip(text)}',
        code: 'model_meta_shape',
      );
    }
    return <String, Object?>{
      for (final MapEntry<Object?, Object?> entry in decoded.entries)
        entry.key.toString(): entry.value,
    };
  }

  /// 探测一个模型的元数据（价格 / 思考档位 / 上下文长度）。
  Future<ModelMeta> probe(
    CoreModelConfig model, {
    DateTime Function()? clock,
  }) async {
    if (model.protocol != kModelProtocolOpenai) {
      throw ModelMetaFailure(
        '只有 OpenAI 兼容端点支持元数据探测（当前协议：${model.protocol}）',
        code: 'model_meta_unsupported',
      );
    }
    final Map<String, Object?> entry = await fetchModelEntry(
      baseUrl: model.effectiveBaseUrl,
      apiKey: model.effectiveApiKey,
      modelId: model.modelId,
    );
    final DateTime now = (clock ?? DateTime.now)();
    return parseModelMetaEntry(
      entry,
      modelId: model.modelId,
      fetchedAt: now.toIso8601String(),
    );
  }

  void close() => _client.close(force: true);

  static String _clip(String text) =>
      text.length <= 240 ? text : '${text.substring(0, 240)}…';
}
