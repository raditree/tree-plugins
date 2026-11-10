/// 模型池的 kind / protocol 口径与消费方过滤。
///
/// 后端 `GET /api/models` 与 `models-info` 的每条模型都带 `kind`；旧数据可能
/// 没有该字段，一律视为 `chat`（见 docs/pluginization/model-pool-kinds-recon.md）。
/// `protocol` 由 `kind` 推导，前端只读展示，创建时必须随请求带上。
library;

/// 对话模型（旧数据缺省即此值）。
const String kModelKindChat = 'chat';

/// 检索用 embedding 模型（`protocol: openai`，走 `/embeddings`）。
const String kModelKindEmbedding = 'embedding';

/// JEV 决策模型（`protocol: jev`，只做流程决策，不能当 chat 用）。
const String kModelKindDecision = 'decision';

/// 模型编辑器 kind 下拉的固定顺序。
const List<String> kModelKinds = <String>[
  kModelKindChat,
  kModelKindEmbedding,
  kModelKindDecision,
];

/// 读取模型的 kind；缺省 / 空串按 `chat` 处理。
///
/// 这是**行为口径**（过滤、字段组、绑定校验都用它）；展示口径用
/// [modelKindDisplayOf]——旧插件没回 kind 时不能假装它是 chat。
String modelKindOf(Map<String, dynamic> model) {
  final String kind = (model['kind'] as String? ?? '').trim();
  return kind.isEmpty ? kModelKindChat : kind;
}

/// 展示用的"未知类型"标记（旧插件不回 `kind` 字段）。
const String kModelKindUnknown = 'unknown';

/// 读取模型的 kind，**字段缺失如实标成 `unknown`**（列表徽标 / 编辑器提示用）。
String modelKindDisplayOf(Map<String, dynamic> model) {
  final String kind = (model['kind'] as String? ?? '').trim();
  return kind.isEmpty ? kModelKindUnknown : kind;
}

/// 模型 API Key 的配置状态三态：旧插件不回 `has_api_key` 时是 [unknown]，
/// 不能默认按"未配置"误导用户去重填。
enum ModelKeyState { configured, missing, unknown }

ModelKeyState modelKeyStateOf(Map<String, dynamic> model) {
  final Object? raw = model['has_api_key'];
  if (raw is! bool) return ModelKeyState.unknown;
  return raw ? ModelKeyState.configured : ModelKeyState.missing;
}

/// kind → protocol 推导（后端 MP-2 规定创建后不可修改）。
String protocolForKind(String kind) {
  switch (kind) {
    case kModelKindDecision:
      return 'jev';
    case kModelKindChat:
    case kModelKindEmbedding:
    default:
      return 'openai';
  }
}

/// 只保留可当对话模型使用的条目（缺省 kind 视为 chat）。
List<Map<String, dynamic>> chatModelsOf(
  List<Map<String, dynamic>> models,
) {
  return models
      .where((Map<String, dynamic> m) => modelKindOf(m) == kModelKindChat)
      .toList();
}

/// 模型编辑器按 kind 展示的字段组（三组互斥）。
class ModelKindFields {
  final bool chat;
  final bool embedding;
  final bool decision;

  const ModelKindFields({
    required this.chat,
    required this.embedding,
    required this.decision,
  });
}

ModelKindFields modelKindFieldsOf(String kind) {
  return ModelKindFields(
    chat: kind == kModelKindChat,
    embedding: kind == kModelKindEmbedding,
    decision: kind == kModelKindDecision,
  );
}

/// 思考强度档位的兜底列表（与后端 `CoreModelConfig.defaultReasoningEfforts` 一致）。
const List<String> kFallbackReasoningEfforts = <String>['low', 'high', 'max'];

/// 从模型条目的 `meta` 里取端点声明的思考档位（没探测过 / 未声明 ⇒ 空）。
List<String> modelMetaEffortsOf(Map<String, dynamic> model) {
  final Object? meta = model['meta'];
  if (meta is! Map) return const <String>[];
  final Object? raw = meta['reasoning_effort_options'];
  if (raw is! List) return const <String>[];
  return <String>[
    for (final Object? item in raw)
      if ('${item ?? ''}'.trim().isNotEmpty) '${item ?? ''}'.trim(),
  ];
}

/// 模型价格标签（`$3 / 1M 输入 · $15 / 1M 输出`）；没有探测结果 ⇒ 空串。
String modelPricingLabel(Map<String, dynamic> model) {
  final Object? meta = model['meta'];
  if (meta is! Map) return '';
  final Object? pricing = meta['pricing'];
  if (pricing is! Map) return '';
  final num? prompt = pricing['prompt_per_million'] as num?;
  final num? completion = pricing['completion_per_million'] as num?;
  if (prompt == null && completion == null) return '';
  final String currency = '${pricing['currency'] ?? 'USD'}';
  final String prefix = currency == 'USD' ? r'$' : '$currency ';
  return '$prefix${_formatPrice(prompt)} / 1M 输入 · '
      '$prefix${_formatPrice(completion)} / 1M 输出';
}

String _formatPrice(num? value) {
  if (value == null) return '?';
  final double price = value.toDouble();
  if (price == 0) return '0';
  if (price < 0.01) return price.toStringAsFixed(4);
  if (price < 1) return price.toStringAsFixed(3);
  return price.toStringAsFixed(2);
}

/// 模型编辑器的纯数据草稿：负责校验与组装提交体，便于脱离界面测试。
///
/// 编辑模式（[originalKind] 非空）**不下发 kind / protocol**：后端 MP-2 规定
/// 二者创建后不可改，带上只会被判成"修改类型"。
class ModelEditorDraft {
  /// 编辑前的 kind（null = 新增）。
  final String? originalKind;
  final String kind;
  final String modelId;
  final String name;
  final String baseUrl;
  final String apiKey;
  final String reasoningEffort;
  final List<String> reasoningEffortOptions;
  final int? maxSeqlen;
  final int? maxOutputTokens;
  final bool thinking;
  final bool ifVision;
  final int? dimensions;
  final int? maxInputTokens;
  final double? confidenceThreshold;

  const ModelEditorDraft({
    required this.kind,
    required this.modelId,
    required this.name,
    this.originalKind,
    this.baseUrl = '',
    this.apiKey = '',
    this.reasoningEffort = '',
    this.reasoningEffortOptions = const <String>[],
    this.maxSeqlen,
    this.maxOutputTokens,
    this.thinking = false,
    this.ifVision = false,
    this.dimensions,
    this.maxInputTokens,
    this.confidenceThreshold,
  });

  bool get isEdit => originalKind != null;

  String get protocol => protocolForKind(kind);

  /// 返回 null 表示通过；否则是可读错误文案（弹 SnackBar）。
  String? validate() {
    if (modelId.trim().isEmpty) return 'model_id 不能为空';
    if (!isEdit && (baseUrl.trim().isEmpty || apiKey.trim().isEmpty)) {
      return '新增模型必须填写 base_url 与 api_key';
    }
    if (kind == kModelKindEmbedding) {
      final int? dim = dimensions;
      if (dim == null || dim <= 0) {
        return 'embedding 模型必须填写大于 0 的维度（dimensions）';
      }
    }
    if (kind == kModelKindDecision) {
      final double? threshold = confidenceThreshold;
      if (threshold == null) {
        return 'decision 模型必须填写置信度阈值';
      }
      if (threshold <= 0 || threshold >= 1) {
        return 'decision 模型的置信度阈值必须在 (0,1) 之间';
      }
    }
    return null;
  }

  /// 组装 `POST /api/models` / `PATCH /api/models/{id}` 的请求体。
  Map<String, dynamic> toPayload() {
    final Map<String, dynamic> payload = <String, dynamic>{
      'model_id': modelId.trim(),
      'name': name.trim(),
    };
    // 新增必须带 kind / protocol；编辑不带（后端禁止改类型）。
    if (!isEdit) {
      payload['kind'] = kind;
      payload['protocol'] = protocol;
    }
    // base_url / api_key：编辑时留空表示沿用原值（后端据此保留）。
    if (baseUrl.trim().isNotEmpty) payload['base_url'] = baseUrl.trim();
    if (apiKey.trim().isNotEmpty) payload['api_key'] = apiKey.trim();

    switch (kind) {
      case kModelKindEmbedding:
        if (dimensions != null) payload['dimensions'] = dimensions;
        if (maxInputTokens != null) {
          payload['max_input_tokens'] = maxInputTokens;
        }
        break;
      case kModelKindDecision:
        if (confidenceThreshold != null) {
          payload['confidence_threshold'] = confidenceThreshold;
        }
        if (maxInputTokens != null) {
          payload['max_input_tokens'] = maxInputTokens;
        }
        break;
      case kModelKindChat:
      default:
        payload['thinking'] = thinking;
        payload['if_vision'] = ifVision;
        if (reasoningEffort.isNotEmpty) {
          payload['reasoning_effort'] = reasoningEffort;
        }
        // 留空 = 用后端默认档位，此时不下发该键。
        if (reasoningEffortOptions.isNotEmpty) {
          payload['reasoning_effort_options'] = reasoningEffortOptions;
        }
        if (maxSeqlen != null) payload['max_seqlen'] = maxSeqlen;
        if (maxOutputTokens != null) {
          payload['max_output_tokens'] = maxOutputTokens;
        }
        break;
    }
    return payload;
  }
}
