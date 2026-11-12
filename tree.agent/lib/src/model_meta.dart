/// 模型元数据（P8）：端点声明的价格与思考强度档位。
///
/// 口径：
/// - 只对 **OpenAI 兼容端点** 生效：`GET {base_url}/models`（部分聚合网关会在这
///   里返回 `pricing` 与 `supported_parameters` / `reasoning`）；
/// - 结果缓存到 `<data_root>/config/model_meta.json`，**不改模型池 YAML**
///   （用户配置是单一真值，探测结果只是可刷新的旁路信息）；
/// - 价格统一折算成「每 1M token」便于展示，币种缺省 USD；
/// - 端点不声明档位时返回空列表，UI 回退到 `low/high/max` 兜底。
library;

import 'dart:convert';

import 'package:path/path.dart' as p;

import 'paths.dart';
import 'store/atomic_file.dart';

/// 端点没有可读元数据时的可读失败。
class ModelMetaFailure implements Exception {
  ModelMetaFailure(this.message, {this.code = 'model_meta_error'});

  final String message;
  final String code;

  @override
  String toString() => message;
}

/// 每 1M token 的价格（币种缺省 USD）。
class ModelPricing {
  const ModelPricing({
    required this.promptPerMillion,
    required this.completionPerMillion,
    this.currency = 'USD',
  });

  final double promptPerMillion;
  final double completionPerMillion;
  final String currency;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'prompt_per_million': promptPerMillion,
    'completion_per_million': completionPerMillion,
    'currency': currency,
  };

  static ModelPricing? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? prompt = raw['prompt_per_million'];
    final Object? completion = raw['completion_per_million'];
    if (prompt == null && completion == null) return null;
    return ModelPricing(
      promptPerMillion: _doubleOf(prompt),
      completionPerMillion: _doubleOf(completion),
      currency: (raw['currency'] ?? 'USD').toString(),
    );
  }

  /// 解析端点回包里的 `pricing`：
  /// - `*_per_million` / `*_per_1m`：已经是每百万价，原样取；
  /// - `prompt` / `input` / `completion` / `output`：按「每 token」折算（OpenRouter 口径）。
  static ModelPricing? parse(Object? raw) {
    if (raw is! Map) return null;
    double? prompt = _firstOf(raw, <String>[
      'prompt_per_million',
      'input_per_million',
      'prompt_per_1m',
      'input_per_1m',
    ]);
    double? completion = _firstOf(raw, <String>[
      'completion_per_million',
      'output_per_million',
      'completion_per_1m',
      'output_per_1m',
    ]);
    if (prompt == null) {
      final double? perToken = _firstOf(raw, <String>['prompt', 'input']);
      if (perToken != null) prompt = perToken * 1000000;
    }
    if (completion == null) {
      final double? perToken = _firstOf(raw, <String>['completion', 'output']);
      if (perToken != null) completion = perToken * 1000000;
    }
    if (prompt == null && completion == null) return null;
    return ModelPricing(
      promptPerMillion: _round6(prompt ?? 0),
      completionPerMillion: _round6(completion ?? 0),
      currency: (raw['currency'] ?? 'USD').toString(),
    );
  }

  static double? _firstOf(Map raw, List<String> keys) {
    for (final String key in keys) {
      final Object? value = raw[key];
      if (value == null) continue;
      final double? parsed = _tryDouble(value);
      if (parsed != null) return parsed;
    }
    return null;
  }
}

/// 一个模型的元数据快照。
class ModelMeta {
  const ModelMeta({
    required this.modelId,
    this.pricing,
    this.reasoningEffortOptions = const <String>[],
    this.reasoningSupported = false,
    this.contextLength = 0,
    this.source = '',
    this.fetchedAt = '',
    this.error = '',
  });

  final String modelId;
  final ModelPricing? pricing;

  /// 端点声明的可用思考强度档位（空 = 未声明，UI 回退兜底档位）。
  final List<String> reasoningEffortOptions;
  final bool reasoningSupported;
  final int contextLength;

  /// 来源标记（当前只有 `openai.models`）。
  final String source;
  final String fetchedAt;

  /// 最近一次探测失败的可读原因（成功时为空）。
  final String error;

  bool get hasPricing => pricing != null;
  bool get hasReasoningOptions => reasoningEffortOptions.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'model_id': modelId,
    if (pricing != null) 'pricing': pricing!.toJson(),
    'reasoning_effort_options': reasoningEffortOptions,
    'reasoning_supported': reasoningSupported,
    'context_length': contextLength,
    'source': source,
    'fetched_at': fetchedAt,
    if (error.isNotEmpty) 'error': error,
  };

  /// 探测失败时保留上一次的成功信息，只追加错误与时间。
  ModelMeta withError(String message, {required String at}) => ModelMeta(
    modelId: modelId,
    pricing: pricing,
    reasoningEffortOptions: reasoningEffortOptions,
    reasoningSupported: reasoningSupported,
    contextLength: contextLength,
    source: source,
    fetchedAt: at,
    error: message,
  );

  /// 换一个缓存键（provider 池的键是 `provider/model_id`，探测结果本身只认识 `model_id`）。
  ModelMeta withModelId(String key) => ModelMeta(
    modelId: key,
    pricing: pricing,
    reasoningEffortOptions: reasoningEffortOptions,
    reasoningSupported: reasoningSupported,
    contextLength: contextLength,
    source: source,
    fetchedAt: fetchedAt,
    error: error,
  );

  static ModelMeta? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String modelId = (raw['model_id'] ?? '').toString().trim();
    if (modelId.isEmpty) return null;
    return ModelMeta(
      modelId: modelId,
      pricing: ModelPricing.fromJson(raw['pricing']),
      reasoningEffortOptions: _stringList(raw['reasoning_effort_options']),
      reasoningSupported: raw['reasoning_supported'] == true,
      contextLength: _intOf(raw['context_length']),
      source: (raw['source'] ?? '').toString(),
      fetchedAt: (raw['fetched_at'] ?? '').toString(),
      error: (raw['error'] ?? '').toString(),
    );
  }
}

/// 从 OpenAI 兼容 `/models` 回包里挑出目标模型条目。
///
/// 支持 `{data: [...]}` / `{models: [...]}` 与单模型对象；匹配顺序：
/// 全等 → 忽略大小写 → 末段（`openai/gpt-4o` 与 `gpt-4o` 互认）。找不到就抛，
/// 不猜"列表里只有一个就是它"（那只在回包本身就是单模型对象时成立）。
Map<String, Object?> selectOpenAiModelEntry(
  Map<String, Object?> payload,
  String modelId,
) {
  final String wanted = modelId.trim();
  if (wanted.isEmpty) {
    throw ModelMetaFailure('model_id 不能为空', code: 'invalid_arguments');
  }
  List<Object?>? rawList;
  final Object? data = payload['data'];
  final Object? models = payload['models'];
  if (data is List) {
    rawList = data;
  } else if (models is List) {
    rawList = models;
  }
  if (rawList == null) {
    final String direct = modelEntryId(payload);
    if (direct.isEmpty) {
      throw ModelMetaFailure(
        '端点回包没有 data / models 列表（也不像单模型对象）',
        code: 'model_meta_shape',
      );
    }
    if (!_idMatches(direct, wanted)) {
      throw ModelMetaFailure(
        '端点返回的模型是 $direct，不是 $wanted',
        code: 'model_not_in_catalog',
      );
    }
    return payload;
  }
  final List<Map<String, Object?>> entries = <Map<String, Object?>>[
    for (final Object? item in rawList)
      if (item is Map)
        <String, Object?>{
          for (final MapEntry<Object?, Object?> entry in item.entries)
            entry.key.toString(): entry.value,
        },
  ];
  for (final Map<String, Object?> entry in entries) {
    if (modelEntryId(entry) == wanted) return entry;
  }
  for (final Map<String, Object?> entry in entries) {
    if (modelEntryId(entry).toLowerCase() == wanted.toLowerCase()) {
      return entry;
    }
  }
  for (final Map<String, Object?> entry in entries) {
    if (_idMatches(modelEntryId(entry), wanted)) return entry;
  }
  throw ModelMetaFailure(
    '端点模型列表里没有 $wanted（共 ${entries.length} 个模型）',
    code: 'model_not_in_catalog',
  );
}

/// 解析一条模型条目的价格、思考档位与上下文长度。
ModelMeta parseModelMetaEntry(
  Map<String, Object?> entry, {
  required String modelId,
  required String fetchedAt,
}) {
  final List<String> options = _reasoningOptionsOf(entry);
  final List<String> parameters = _stringList(entry['supported_parameters']);
  final bool reasoningSupported =
      options.isNotEmpty ||
      parameters.any(
        (String item) =>
            item == 'reasoning' ||
            item == 'reasoning_effort' ||
            item == 'include_reasoning',
      ) ||
      entry['reasoning'] is Map ||
      entry['reasoning'] == true;
  return ModelMeta(
    modelId: modelId,
    pricing: ModelPricing.parse(entry['pricing']),
    reasoningEffortOptions: options,
    reasoningSupported: reasoningSupported,
    contextLength: _contextLengthOf(entry),
    source: 'openai.models',
    fetchedAt: fetchedAt,
  );
}

List<String> _reasoningOptionsOf(Map<String, Object?> entry) {
  final List<Object?> sources = <Object?>[
    entry['reasoning_effort_options'],
    entry['reasoning_efforts'],
    entry['supported_reasoning_efforts'],
    entry['reasoning_effort_values'],
  ];
  final Object? reasoning = entry['reasoning'];
  if (reasoning is Map) {
    sources.addAll(<Object?>[
      reasoning['supported_efforts'],
      reasoning['efforts'],
      reasoning['options'],
      reasoning['values'],
    ]);
  }
  final List<String> options = <String>[];
  for (final Object? source in sources) {
    for (final String item in _stringList(source)) {
      if (!options.contains(item)) options.add(item);
    }
  }
  return options;
}

int _contextLengthOf(Map<String, Object?> entry) {
  for (final String key in const <String>[
    'context_length',
    'max_context_length',
    'max_seqlen',
  ]) {
    final int value = _intOf(entry[key]);
    if (value > 0) return value;
  }
  final Object? top = entry['top_provider'];
  if (top is Map) return _intOf(top['context_length']);
  return 0;
}

/// 模型条目的 id（依次尝试 `id` / `model_id` / `name`；都没有返回空串）。
String modelEntryId(Map<String, Object?> entry) {
  for (final String key in const <String>['id', 'model_id', 'name']) {
    final String value = (entry[key] ?? '').toString().trim();
    if (value.isNotEmpty) return value;
  }
  return '';
}

bool _idMatches(String candidate, String wanted) {
  if (candidate.isEmpty) return false;
  if (candidate == wanted) return true;
  if (candidate.toLowerCase() == wanted.toLowerCase()) return true;
  final String left = candidate.split('/').last;
  final String right = wanted.split('/').last;
  return left.toLowerCase() == right.toLowerCase();
}

List<String> _stringList(Object? raw) {
  if (raw is! List) return <String>[];
  final List<String> out = <String>[];
  for (final Object? item in raw) {
    final String value = (item ?? '').toString().trim();
    if (value.isNotEmpty && !out.contains(value)) out.add(value);
  }
  return out;
}

int _intOf(Object? raw) {
  if (raw is num) return raw.toInt();
  return int.tryParse('${raw ?? ''}'.trim()) ?? 0;
}

double _doubleOf(Object? raw) {
  if (raw is num) return _round6(raw.toDouble());
  return _round6(double.tryParse('${raw ?? ''}'.trim()) ?? 0);
}

double? _tryDouble(Object? raw) {
  if (raw is num) return raw.toDouble();
  return double.tryParse('${raw ?? ''}'.trim());
}

double _round6(double value) => (value * 1000000).round() / 1000000;

// ── 缓存（`<data_root>/config/model_meta.json`）────────────────────────

/// 元数据缓存文件（与模型池 YAML 分家：探测结果可随时丢）。
String modelMetaFile(AgentDataPaths paths) =>
    p.join(paths.root, 'config', 'model_meta.json');

/// 读整份缓存；文件缺失 / 坏 JSON ⇒ 空表（可再探测重建）。
Map<String, Map<String, dynamic>> readModelMetaCache(AgentDataPaths paths) {
  final String? text = AtomicFile.readStringOrNullSync(modelMetaFile(paths));
  if (text == null || text.trim().isEmpty) {
    return <String, Map<String, dynamic>>{};
  }
  try {
    final Object? decoded = jsonDecode(text);
    if (decoded is! Map) return <String, Map<String, dynamic>>{};
    final Map<String, Map<String, dynamic>> out =
        <String, Map<String, dynamic>>{};
    for (final MapEntry<Object?, Object?> entry in decoded.entries) {
      final String modelId = entry.key.toString().trim();
      if (modelId.isEmpty || entry.value is! Map) continue;
      out[modelId] = <String, dynamic>{
        for (final MapEntry<Object?, Object?> field in (entry.value as Map).entries)
          field.key.toString(): field.value,
      };
    }
    return out;
  } catch (_) {
    return <String, Map<String, dynamic>>{};
  }
}

/// 读单个模型的元数据；没有探测过 ⇒ null。
ModelMeta? readModelMeta(AgentDataPaths paths, String modelId) =>
    ModelMeta.fromJson(readModelMetaCache(paths)[modelId]);

/// 写入单个模型的元数据（读-改-写，原子落盘）。
void writeModelMeta(AgentDataPaths paths, ModelMeta meta) {
  final Map<String, Map<String, dynamic>> cache = readModelMetaCache(paths);
  cache[meta.modelId] = meta.toJson();
  final Map<String, Map<String, dynamic>> sorted =
      <String, Map<String, dynamic>>{};
  final List<String> ids = cache.keys.toList()..sort();
  for (final String id in ids) {
    sorted[id] = cache[id]!;
  }
  AtomicFile.writeStringAtomicSync(
    modelMetaFile(paths),
    '${const JsonEncoder.withIndent('  ').convert(sorted)}\n',
  );
}

/// 删除模型时清掉它的元数据（避免同 id 重建后沿用旧价格）。
void removeModelMeta(AgentDataPaths paths, String modelId) {
  final Map<String, Map<String, dynamic>> cache = readModelMetaCache(paths);
  if (!cache.containsKey(modelId)) return;
  cache.remove(modelId);
  AtomicFile.writeStringAtomicSync(
    modelMetaFile(paths),
    '${const JsonEncoder.withIndent('  ').convert(cache)}\n',
  );
}
