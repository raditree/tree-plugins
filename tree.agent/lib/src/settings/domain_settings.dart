import 'dart:io';

import '../paths.dart';
import '../store/atomic_file.dart';
import '../store/yaml_codec.dart';
import '../yaml_utils.dart';
import 'provider_settings.dart';

/// `token_scale` 的默认值（与核心 `defaultTokenScale` 同值）。
const double kDefaultTokenScale = 2.0;

/// 模型类型（MP 系列 / D33）：三类模型协议不同，**禁止串用**。
const String kModelKindChat = 'chat';
const String kModelKindEmbedding = 'embedding';
const String kModelKindDecision = 'decision';
const List<String> kModelKinds = <String>[
  kModelKindChat,
  kModelKindEmbedding,
  kModelKindDecision,
];

/// 模型协议：chat/embedding 走 OpenAI 生态（后者用 `/embeddings`），decision 走 JEV。
const String kModelProtocolOpenai = 'openai';
const String kModelProtocolJev = 'jev';
const List<String> kModelProtocols = <String>[
  kModelProtocolOpenai,
  kModelProtocolJev,
];

/// 某类型的默认协议（旧文件缺 `protocol` 时按它补，不回写文件）。
String defaultProtocolFor(String kind) =>
    kind == kModelKindDecision ? kModelProtocolJev : kModelProtocolOpenai;

/// 模型没配 `max_seqlen` 时的兜底上下文长度（与核心 `CoreSettings.fallbackMaxSeqlen` 同值）。
const int kFallbackMaxSeqlen = 128000;

/// 自定义模型配置（从核心 `CoreModelConfig` 平移；含密钥，只活在插件进程内）。
///
/// **api_key 永不回显**：`toApiJson` 剥离密钥并把 `base_url` 脱敏。
/// `PATCH` 时空的 `base_url`/`api_key` 表示"保留原值"。
class CoreModelConfig {
  CoreModelConfig({
    required this.modelId,
    this.provider = '',
    this.name = '',
    String kind = kModelKindChat,
    String protocol = '',
    this.dimensions = 0,
    this.maxInputTokens = 0,
    this.confidenceThreshold = 0,
    this.baseUrl = '',
    this.apiKey = '',
    this.thinking = false,
    this.ifVision = false,
    this.ifAudio = false,
    this.ifVideo = false,
    this.reasoningEffort = '',
    List<String>? reasoningEffortOptions,
    this.maxSeqlen = 0,
    this.maxOutputTokens = 0,
    this.tokenScale = kDefaultTokenScale,
    this.longestSessionTokens = 0,
  }) : kind = _readKind(kind),
       protocol = _readProtocol(protocol, kind),
       reasoningEffortOptions =
           reasoningEffortOptions ?? List<String>.of(defaultReasoningEfforts);

  /// token_scale 的可接受区间（超出区间的"学习样本"一律不采纳）。
  static const double minTokenScale = 0.2;
  static const double maxTokenScale = 20;

  /// 端点支持的思考强度档位兜底。
  static const List<String> defaultReasoningEfforts = <String>[
    'low',
    'high',
    'max',
  ];

  final String modelId;

  /// 所属 provider 的 id（旧文件为 [kLegacyProviderId]；空 = 未归组）。
  String provider;

  /// 模型池唯一键：`provider/model_id`（provider 为空时就是 `model_id`）。
  String get key => provider.isEmpty ? modelId : '$provider/$modelId';

  /// 由 provider 配置解析出的端点根（**不落盘**；模型级 `base_url` 非空时不用它）。
  String providerBaseUrl = '';

  /// 由 provider 配置解析出的密钥（**不落盘**；模型级 `api_key` 非空时不用它）。
  String providerApiKey = '';

  /// 该模型落盘的文件路径（装载时记下；新建为空 ⇒ 按 `provider__model_id` 推导）。
  ///
  /// 旧文件必须记住原路径：否则编辑一次旧模型会写到新命名上、留下同名两份。
  String storageFile = '';

  /// 请求时真正使用的端点：模型级覆盖优先，其次 provider。
  String get effectiveBaseUrl {
    final String own = baseUrl.trim();
    return own.isNotEmpty ? own : providerBaseUrl.trim();
  }

  /// 请求时真正使用的密钥：模型级覆盖优先，其次 provider（含环境变量解析）。
  String get effectiveApiKey {
    final String own = apiKey.trim();
    return own.isNotEmpty ? own : providerApiKey.trim();
  }

  String name;

  /// 模型类型：`chat` / `embedding` / `decision`（创建后不可改，见 MP-2）。
  String kind;

  /// 协议：`openai` / `jev`（默认由 [kind] 推导）。
  String protocol;

  /// embedding 维度（必填校验在 MP-2；这里 0 = 未设置）。
  int dimensions;

  /// embedding / decision 的输入上下文上限（**不复用** [maxSeqlen]，两者口径不同）。
  int maxInputTokens;

  /// decision 的置信度阈值（(0,1)；0 = 未设置，MP-6 用）。
  double confidenceThreshold;

  String baseUrl;
  String apiKey;
  bool thinking;
  bool ifVision;

  /// 端点声明的模态能力（D7 自动填充、用户可改；`false` = 不假装支持）。
  bool ifAudio;
  bool ifVideo;
  String reasoningEffort;
  List<String> reasoningEffortOptions;
  int maxSeqlen;
  int maxOutputTokens;

  /// 逐模型的 字符→token 换算比例（学习状态，不参与 [merge]）。
  double tokenScale;

  /// 学到 [tokenScale] 那次请求的真实 prompt_tokens（"最长会话"水位线）。
  int longestSessionTokens;

  /// 学习状态变更后的落盘回调（由 [DomainSettings] 放入模型池时挂上）。
  void Function(CoreModelConfig model)? onChanged;

  /// 用一次真实 usage 学习 字符/token 比例：只有更长的请求才有资格刷新水位线。
  bool learnTokenScale({required int contextChars, required int promptTokens}) {
    if (contextChars <= 0 || promptTokens <= 0) return false;
    if (promptTokens <= longestSessionTokens) return false;
    final double ratio = contextChars / promptTokens;
    if (ratio < minTokenScale || ratio > maxTokenScale) return false;
    longestSessionTokens = promptTokens;
    tokenScale = (ratio * 100).round() / 100;
    onChanged?.call(this);
    return true;
  }

  /// 持久化形态（含密钥）。
  ///
  /// `kind` / `protocol` 等新键**只在与缺省值不同时写**：旧 chat 模型保存后仍逐键
  /// 保持原样（旧 YAML 无新键 ⇒ 读补默认值、不回写文件，TC-MP-01）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    if (provider.isNotEmpty) 'provider': provider,
    'model_id': modelId,
    'name': name,
    if (kind != kModelKindChat) 'kind': kind,
    if (protocol != defaultProtocolFor(kind)) 'protocol': protocol,
    if (dimensions > 0) 'dimensions': dimensions,
    if (maxInputTokens > 0) 'max_input_tokens': maxInputTokens,
    if (confidenceThreshold > 0) 'confidence_threshold': confidenceThreshold,
    'base_url': baseUrl,
    'api_key': apiKey,
    'thinking': thinking,
    'if_vision': ifVision,
    if (ifAudio) 'if_audio': ifAudio,
    if (ifVideo) 'if_video': ifVideo,
    'reasoning_effort': reasoningEffort,
    'reasoning_effort_options': reasoningEffortOptions,
    'max_seqlen': maxSeqlen,
    'max_output_tokens': maxOutputTokens,
    'token_scale': tokenScale,
    'longest_session_tokens': longestSessionTokens,
  };

  /// 前端形态：无密钥、base_url 脱敏；`kind` / `protocol` 始终下发（旧 UI 忽略）。
  Map<String, dynamic> toApiJson() => <String, dynamic>{
    'provider': provider,
    'key': key,
    'model_id': modelId,
    'name': name.isEmpty ? modelId : name,
    'kind': kind,
    'protocol': protocol,
    'dimensions': dimensions > 0 ? dimensions : null,
    'max_input_tokens': maxInputTokens > 0 ? maxInputTokens : null,
    'confidence_threshold': confidenceThreshold > 0
        ? confidenceThreshold
        : null,
    'base_url': maskBaseUrl(baseUrl),
    // 只回"是否配置"，密钥本身永不出插件。
    'has_api_key': apiKey.trim().isNotEmpty,
    'thinking': thinking,
    'if_vision': ifVision,
    'if_audio': ifAudio,
    'if_video': ifVideo,
    'reasoning_effort': reasoningEffort,
    'reasoning_effort_options': reasoningEffortOptions,
    'max_seqlen': maxSeqlen,
    'max_output_tokens': maxOutputTokens,
    'token_scale': tokenScale,
    'longest_session_tokens': longestSessionTokens,
  };

  static CoreModelConfig fromJson(Map<String, dynamic> json) {
    return CoreModelConfig(
      modelId: json['model_id'] as String? ?? '',
      provider: json['provider'] as String? ?? '',
      name: json['name'] as String? ?? '',
      kind: json['kind'] as String? ?? kModelKindChat,
      protocol: json['protocol'] as String? ?? '',
      dimensions: (json['dimensions'] as num?)?.toInt() ?? 0,
      maxInputTokens: (json['max_input_tokens'] as num?)?.toInt() ?? 0,
      confidenceThreshold: _readThreshold(json['confidence_threshold']),
      baseUrl: json['base_url'] as String? ?? '',
      apiKey: json['api_key'] as String? ?? '',
      thinking: json['thinking'] as bool? ?? false,
      ifVision: json['if_vision'] as bool? ?? false,
      ifAudio: json['if_audio'] as bool? ?? false,
      ifVideo: json['if_video'] as bool? ?? false,
      reasoningEffort: json['reasoning_effort'] as String? ?? '',
      reasoningEffortOptions:
          (json['reasoning_effort_options'] as List<dynamic>?)
              ?.map((dynamic e) => e.toString())
              .toList(),
      maxSeqlen: (json['max_seqlen'] as num?)?.toInt() ?? 0,
      maxOutputTokens: (json['max_output_tokens'] as num?)?.toInt() ?? 0,
      tokenScale: _readScale(json['token_scale']),
      longestSessionTokens:
          (json['longest_session_tokens'] as num?)?.toInt() ?? 0,
    );
  }

  /// 用请求体合并字段；`base_url`/`api_key` 为空串表示保留原值。
  ///
  /// `kind` 变更而未同时给 `protocol` 时，协议回到新类型的默认值（创建 embedding /
  /// decision 模型不必重复写协议）；改动是否合法由 MP-2 的 API 校验负责。
  void merge(Map<String, dynamic> payload) {
    if (payload.containsKey('provider')) {
      final String value = (payload['provider'] as String? ?? '').trim();
      if (value.isNotEmpty) provider = value;
    }
    if (payload.containsKey('name')) name = payload['name'] as String? ?? name;
    if (payload.containsKey('kind')) {
      final String value = _readKind(payload['kind'] as String? ?? '');
      if (value != kind) {
        kind = value;
        if (!payload.containsKey('protocol')) {
          protocol = defaultProtocolFor(kind);
        }
      }
    }
    if (payload.containsKey('protocol')) {
      protocol = _readProtocol(payload['protocol'] as String? ?? '', kind);
    }
    if (payload.containsKey('dimensions')) {
      dimensions = (payload['dimensions'] as num?)?.toInt() ?? dimensions;
    }
    if (payload.containsKey('max_input_tokens')) {
      maxInputTokens =
          (payload['max_input_tokens'] as num?)?.toInt() ?? maxInputTokens;
    }
    if (payload.containsKey('confidence_threshold')) {
      confidenceThreshold = _readThreshold(payload['confidence_threshold']);
    }
    if (payload.containsKey('base_url')) {
      final String value = (payload['base_url'] as String? ?? '').trim();
      if (value.isNotEmpty) baseUrl = value;
    }
    if (payload.containsKey('api_key')) {
      final String value = (payload['api_key'] as String? ?? '').trim();
      if (value.isNotEmpty) apiKey = value;
    }
    if (payload.containsKey('thinking')) {
      thinking = payload['thinking'] as bool? ?? thinking;
    }
    if (payload.containsKey('if_vision')) {
      ifVision = payload['if_vision'] as bool? ?? ifVision;
    }
    if (payload.containsKey('if_audio')) {
      ifAudio = payload['if_audio'] as bool? ?? ifAudio;
    }
    if (payload.containsKey('if_video')) {
      ifVideo = payload['if_video'] as bool? ?? ifVideo;
    }
    if (payload.containsKey('reasoning_effort')) {
      reasoningEffort = payload['reasoning_effort'] as String? ?? '';
    }
    final List<dynamic>? options =
        payload['reasoning_effort_options'] as List<dynamic>?;
    if (options != null && options.isNotEmpty) {
      final List<String> normalized = options
          .map((dynamic e) => e.toString().trim())
          .where((String e) => e.isNotEmpty)
          .toList();
      if (normalized.isNotEmpty) {
        reasoningEffortOptions = normalized;
        if (reasoningEffort.isNotEmpty &&
            !reasoningEffortOptions.contains(reasoningEffort)) {
          reasoningEffort = reasoningEffortOptions.first;
        }
      }
    }
    if (payload.containsKey('max_seqlen')) {
      maxSeqlen = (payload['max_seqlen'] as num?)?.toInt() ?? maxSeqlen;
    }
    if (payload.containsKey('max_output_tokens')) {
      maxOutputTokens =
          (payload['max_output_tokens'] as num?)?.toInt() ?? maxOutputTokens;
    }
  }

  /// `base_url` 脱敏：仅保留协议 + 主机（+ 非默认端口）。
  static String maskBaseUrl(String raw) => maskEndpointUrl(raw);

  /// 应用成员级模型参数覆盖（只覆盖非空项，返回副本；学习状态一起带走）。
  ///
  /// 新字段必须在这里逐个复制：固定字段列表漏一个，成员级覆盖后 `kind` 就会回退成
  /// chat（TC-MP-13）。
  CoreModelConfig withOverrides(Map<String, Object?> overrides) {
    if (overrides.isEmpty) return this;
    final CoreModelConfig copy = CoreModelConfig(
      modelId: modelId,
      provider: provider,
      name: name,
      kind: kind,
      protocol: protocol,
      dimensions: dimensions,
      maxInputTokens: maxInputTokens,
      confidenceThreshold: confidenceThreshold,
      baseUrl: baseUrl,
      apiKey: apiKey,
      thinking: thinking,
      ifVision: ifVision,
      ifAudio: ifAudio,
      ifVideo: ifVideo,
      reasoningEffort: reasoningEffort,
      reasoningEffortOptions: reasoningEffortOptions,
      maxSeqlen: maxSeqlen,
      maxOutputTokens: maxOutputTokens,
      tokenScale: tokenScale,
      longestSessionTokens: longestSessionTokens,
    )
      // provider 解析出的端点/密钥也要带走，否则成员级覆盖后会退回"未配置 base_url"。
      ..providerBaseUrl = providerBaseUrl
      ..providerApiKey = providerApiKey;

    final Object? effort = overrides['reasoning_effort'];
    if (effort is String && effort.trim().isNotEmpty) {
      copy.reasoningEffort = effort.trim();
    }
    final Object? seqlen = overrides['max_seqlen'];
    if (seqlen is num && seqlen.toInt() > 0) copy.maxSeqlen = seqlen.toInt();
    final Object? output = overrides['max_output_tokens'];
    if (output is num && output.toInt() > 0) {
      copy.maxOutputTokens = output.toInt();
    }
    final Object? reasoning = overrides['thinking'];
    if (reasoning is bool) copy.thinking = reasoning;
    return copy;
  }

  /// 模型上下文长度（前端进度条分母）；未配置时给保守兜底。
  int get effectiveMaxSeqlen => maxSeqlen > 0 ? maxSeqlen : kFallbackMaxSeqlen;

  /// 宽容读 kind（缺失 ⇒ chat；未知值原样保留，由 MP-2 的 API 校验拒绝）。
  static String _readKind(Object? raw) {
    final String value = (raw ?? '').toString().trim();
    return value.isEmpty ? kModelKindChat : value;
  }

  /// 宽容读 protocol（缺失 ⇒ 按 kind 的默认协议）。
  static String _readProtocol(Object? raw, Object? kindRaw) {
    final String value = (raw ?? '').toString().trim();
    return value.isEmpty ? defaultProtocolFor(_readKind(kindRaw)) : value;
  }

  /// 读置信度阈值（num / 数字字符串；不在 (0,1) 内 ⇒ 0 = 未设置）。
  static double _readThreshold(Object? raw) {
    double? value;
    if (raw is num) {
      value = raw.toDouble();
    } else if (raw is String) {
      value = double.tryParse(raw.trim());
    }
    if (value == null || value <= 0 || value >= 1) return 0;
    return value;
  }

  /// 宽容读取 token_scale（数字或纯数字字符串都能生效，非法值回初值）。
  static double _readScale(Object? raw) {
    double? value;
    if (raw is num) {
      value = raw.toDouble();
    } else if (raw is String) {
      value = double.tryParse(raw.trim());
    }
    if (value == null || value < minTokenScale || value > maxTokenScale) {
      return kDefaultTokenScale;
    }
    return value;
  }
}

/// 模型配置的落盘出口（插件侧暂为只读；写端点在 A3 后续切片接入）。
abstract interface class DomainSettingsSink {
  void saveModel(CoreModelConfig model);

  void deleteModel(CoreModelConfig model);

  /// provider 变更（写 `config/providers/<id>.yaml`）。
  void saveProvider(ProviderConfig provider);

  void deleteProvider(String providerId);

  /// token 速率变更（写 `config/agent_settings.yaml` 的 `token_acquisition_rate`）。
  void saveTokenRate(int rate);
}

/// 一次模型解析的结果（模型池身份是 `provider/model_id`，旧绑定是裸 `model_id`）。
class ModelResolution {
  const ModelResolution.found(CoreModelConfig this.model)
    : ambiguous = false,
      candidates = const <String>[];

  const ModelResolution.notFound()
    : model = null,
      ambiguous = false,
      candidates = const <String>[];

  const ModelResolution.ambiguous(this.candidates)
    : model = null,
      ambiguous = true;

  final CoreModelConfig? model;

  /// 裸 `model_id` 命中多个 provider 时为 true（调用方应提示"绑定有歧义，请重新选择"）。
  final bool ambiguous;

  /// 歧义时的候选键（`provider/model_id`）。
  final List<String> candidates;

  bool get found => model != null;
}

/// 领域设置（模型池 + provider 池 + token 速率）——从核心 `CoreSettings` 拆出的**领域半边**。
///
/// 核心的 `CoreSettings` 混装平台开关与领域配置；插件只保留后者。存储位置按
/// L-22 乙方案分文件：模型池 `config/models/*.yaml`、provider 池
/// `config/providers/*.yaml`、token 速率 `config/agent_settings.yaml`
/// （旧核心的 `settings.yaml` 只在迁移期兜底读）。
class DomainSettings {
  DomainSettings({this.sink});

  static const int tokenRateMin = 20;
  static const int tokenRateMax = 1000;

  /// 落盘出口；为 null 时只改内存（测试 / 只读期）。
  DomainSettingsSink? sink;

  final Map<String, CoreModelConfig> _models = <String, CoreModelConfig>{};

  final Map<String, ProviderConfig> _providers = <String, ProviderConfig>{};

  int _tokenAcquisitionRate = tokenRateMax;

  /// 模型列表（按 `provider/model_id` 升序）。
  List<CoreModelConfig> models() {
    final List<CoreModelConfig> list = _models.values.toList()
      ..sort((CoreModelConfig a, CoreModelConfig b) => a.key.compareTo(b.key));
    return list;
  }

  /// 按 `provider/model_id` 或裸 `model_id` 精确取模型（歧义时返回 null，见 [resolveModel]）。
  CoreModelConfig? model(String idOrKey) => resolveModel(idOrKey).model;

  /// 解析模型身份（D7）：
  /// 1. `provider/model_id` 全等；
  /// 2. 否则按裸 `model_id` 唯一匹配（旧绑定零迁移）；
  /// 3. 多个 provider 下同名 ⇒ 歧义，调用方要求用户重新选择。
  ///
  /// 解析顺序必须先全等再裸 id：否则旧库里出现 `x` 与 `a/x` 后，精确绑定 `x`
  /// 会被误判成歧义。
  ModelResolution resolveModel(String idOrKey) {
    final String key = idOrKey.trim();
    if (key.isEmpty) return const ModelResolution.notFound();
    final CoreModelConfig? direct = _models[key];
    if (direct != null) return ModelResolution.found(direct);
    final List<CoreModelConfig> matches = <CoreModelConfig>[
      for (final CoreModelConfig model in _models.values)
        if (model.modelId == key) model,
    ];
    if (matches.isEmpty) return const ModelResolution.notFound();
    if (matches.length == 1) return ModelResolution.found(matches.first);
    final List<String> candidates = <String>[
      for (final CoreModelConfig model in matches) model.key,
    ]..sort();
    return ModelResolution.ambiguous(candidates);
  }

  /// 直接放入模型（装载用；不触发落盘）。
  void putModel(CoreModelConfig model) => _attach(model);

  void _attach(CoreModelConfig model) {
    model.onChanged = (CoreModelConfig changed) => sink?.saveModel(changed);
    _models[model.key] = model;
    _applyProviderToModel(model);
  }

  /// provider 列表（按 id 升序）。
  List<ProviderConfig> providers() {
    final List<ProviderConfig> list = _providers.values.toList()
      ..sort((ProviderConfig a, ProviderConfig b) => a.id.compareTo(b.id));
    return list;
  }

  ProviderConfig? provider(String providerId) =>
      _providers[providerId.trim()];

  /// 直接放入 provider（装载用；不触发落盘）。
  void putProvider(ProviderConfig provider) => _putProvider(provider);

  void _putProvider(ProviderConfig provider) {
    _providers[provider.id] = provider;
    for (final CoreModelConfig model in _models.values) {
      _applyProviderToModel(model);
    }
  }

  void _applyProviderToModel(CoreModelConfig model) {
    final ProviderConfig? provider = _providers[model.provider];
    model.providerBaseUrl = provider?.resolvedBaseUrl ?? '';
    model.providerApiKey = provider?.resolveApiKey() ?? '';
  }

  /// 绑在某个 provider 上的模型键（删除 provider 前的守卫）。
  List<String> boundModelKeys(String providerId) {
    final List<String> keys = <String>[
      for (final CoreModelConfig model in _models.values)
        if (model.provider == providerId) model.key,
    ]..sort();
    return keys;
  }

  /// 新建 provider；`id` 缺省按显示名 slug 生成，冲突自动加 `-2` / `-3`。
  ProviderConfig? createProvider(Map<String, dynamic> payload) {
    final String name = (payload['name'] as String? ?? '').trim();
    final String explicitId = (payload['id'] as String? ?? '').trim();
    final ProviderConfig provider = ProviderConfig(
      id: _uniqueProviderId(
        ProviderConfig.slugOf(explicitId.isEmpty ? name : explicitId),
      ),
      createdAt: DateTime.now().toIso8601String(),
    );
    provider.merge(payload);
    provider.name = name.isEmpty ? provider.id : name;
    provider.updatedAt = provider.createdAt;
    _putProvider(provider);
    sink?.saveProvider(provider);
    return provider;
  }

  /// 更新 provider；不存在返回 null。
  ProviderConfig? updateProvider(
    String providerId,
    Map<String, dynamic> payload,
  ) {
    final ProviderConfig? provider = _providers[providerId.trim()];
    if (provider == null) return null;
    provider.merge(payload);
    provider.updatedAt = DateTime.now().toIso8601String();
    _putProvider(provider);
    sink?.saveProvider(provider);
    return provider;
  }

  /// 删除 provider；还有模型绑定时拒绝（调用方回 409 + [boundModelKeys]）。
  bool deleteProvider(String providerId) {
    final String id = providerId.trim();
    if (_providers[id] == null || boundModelKeys(id).isNotEmpty) return false;
    _providers.remove(id);
    sink?.deleteProvider(id);
    return true;
  }

  String _uniqueProviderId(String base) {
    if (!_providers.containsKey(base)) return base;
    int index = 2;
    while (_providers.containsKey('$base-$index')) {
      index++;
    }
    return '$base-$index';
  }

  /// 新建模型；同 `provider/model_id` 已存在时返回 null（调用方回 409）。
  ///
  /// 显示名不做唯一校验：同一模型允许挂多个别名（STAB-PL-8 的拍板）。
  CoreModelConfig? createModel(Map<String, dynamic> payload) {
    final String modelId = (payload['model_id'] as String? ?? '').trim();
    if (modelId.isEmpty) return null;
    final String provider = (payload['provider'] as String? ?? '').trim();
    if (provider.isNotEmpty && !_providers.containsKey(provider)) return null;
    final CoreModelConfig model = CoreModelConfig(
      modelId: modelId,
      provider: provider,
    );
    if (_models.containsKey(model.key)) return null;
    model.merge(payload);
    _attach(model);
    sink?.saveModel(model);
    return model;
  }

  /// 更新模型（`idOrKey` 支持 `provider/model_id` 与裸 `model_id`）；不存在返回 null。
  CoreModelConfig? updateModel(String idOrKey, Map<String, dynamic> payload) {
    final CoreModelConfig? existing = model(idOrKey);
    if (existing == null) return null;
    existing.merge(payload);
    sink?.saveModel(existing);
    return existing;
  }

  /// 删除模型；返回是否真的删除了条目。
  bool deleteModel(String idOrKey) {
    final CoreModelConfig? model = this.model(idOrKey);
    if (model == null) return false;
    _models.remove(model.key);
    sink?.deleteModel(model);
    return true;
  }

  /// 校验新增模型必填项与 kind/protocol 组合。
  ///
  /// 归到 provider 下的模型不需要重复填 `base_url` / `api_key`（由 provider 提供）；
  /// 裸模型（旧式 / 独立端点）仍与核心一致：两者必填。
  static String? validateNewModel(Map<String, dynamic> payload) {
    final String modelId = (payload['model_id'] as String? ?? '').trim();
    if (modelId.isEmpty) return 'model_id 不能为空';
    final String provider = (payload['provider'] as String? ?? '').trim();
    if (provider.isEmpty) {
      final String baseUrl = (payload['base_url'] as String? ?? '').trim();
      if (baseUrl.isEmpty) return 'base_url 不能为空';
      final String apiKey = (payload['api_key'] as String? ?? '').trim();
      if (apiKey.isEmpty) return 'api_key 不能为空';
    }
    return validateModelKindFields(payload);
  }

  /// 校验 PATCH 后的模型形态：kind/protocol 不可改，组合与类型必填项仍成立（MP-2）。
  ///
  /// 存量条目若被手改成未知 kind/protocol，PATCH 其他字段也拒绝（不替用户猜），
  /// 用户应删除后按合法类型重建。
  static String? validateModelChange(
    CoreModelConfig existing,
    Map<String, dynamic> payload,
  ) {
    if (!kModelKinds.contains(existing.kind)) {
      return '模型类型未知：${existing.kind}（请删除后按合法类型重建）';
    }
    if (!kModelProtocols.contains(existing.protocol)) {
      return '模型协议未知：${existing.protocol}（请删除后按合法类型重建）';
    }
    final String provider = (payload['provider'] as String? ?? '').trim();
    if (provider.isNotEmpty && provider != existing.provider) {
      return 'provider 创建后不可修改（当前 ${existing.provider}）';
    }
    final String modelId = (payload['model_id'] as String? ?? '').trim();
    if (modelId.isNotEmpty && modelId != existing.modelId) {
      return 'model_id 创建后不可修改（当前 ${existing.modelId}）';
    }
    return validateModelKindFields(payload, base: existing);
  }

  /// `kind` / `protocol` 组合与类型必填字段（MP-2 的唯一判据）。
  ///
  /// 规则来自 model-pool-kinds-recon §3：
  /// - `chat` / `embedding` 只能用 `openai`，`decision` 只能用 `jev`；
  /// - `embedding` 必须 `dimensions > 0`，`decision` 必须 `confidence_threshold ∈ (0,1)`；
  /// - 未知 kind/protocol ⇒ 拒绝，不猜。
  /// [base] 非空表示更新：`kind` / `protocol` 一律不可改。
  static String? validateModelKindFields(
    Map<String, dynamic> payload, {
    CoreModelConfig? base,
  }) {
    String kind;
    if (payload.containsKey('kind')) {
      kind = (payload['kind'] ?? '').toString().trim();
      if (kind.isEmpty) return 'kind 不能为空';
      if (!kModelKinds.contains(kind)) {
        return '未知模型类型：$kind（可选：${kModelKinds.join(' / ')}）';
      }
      if (base != null && kind != base.kind) {
        return 'kind 创建后不可修改（当前 ${base.kind}）';
      }
    } else {
      kind = base?.kind ?? kModelKindChat;
    }

    String protocol;
    if (payload.containsKey('protocol')) {
      protocol = (payload['protocol'] ?? '').toString().trim();
      if (protocol.isEmpty) protocol = defaultProtocolFor(kind);
      if (!kModelProtocols.contains(protocol)) {
        return '未知模型协议：$protocol（可选：${kModelProtocols.join(' / ')}）';
      }
      if (base != null && protocol != base.protocol) {
        return 'protocol 创建后不可修改（当前 ${base.protocol}）';
      }
    } else {
      protocol = base?.protocol ?? defaultProtocolFor(kind);
    }
    final String expected = defaultProtocolFor(kind);
    if (protocol != expected) {
      return 'kind=$kind 只能使用 protocol=$expected（收到 $protocol）';
    }

    int dimensions;
    if (payload.containsKey('dimensions')) {
      final int? parsed = _intOrNull(payload['dimensions']);
      if (payload['dimensions'] != null && parsed == null) {
        return 'dimensions 必须是整数';
      }
      dimensions = parsed ?? 0;
      if (parsed != null && parsed < 0) return 'dimensions 不能为负数';
    } else {
      dimensions = base?.dimensions ?? 0;
    }

    double threshold;
    if (payload.containsKey('confidence_threshold')) {
      final Object? raw = payload['confidence_threshold'];
      if (raw == null) {
        threshold = 0;
      } else {
        threshold = CoreModelConfig._readThreshold(raw);
        if (threshold <= 0) {
          return 'confidence_threshold 必须是 (0,1) 之间的数';
        }
      }
    } else {
      threshold = base?.confidenceThreshold ?? 0;
    }

    if (kind == kModelKindEmbedding && dimensions <= 0) {
      return 'embedding 模型必须配置 dimensions（>0）';
    }
    if (kind == kModelKindDecision && threshold <= 0) {
      return 'decision 模型必须配置 confidence_threshold（(0,1)）';
    }
    return null;
  }

  /// 非对话模型的绑定错误（Agent / 团队成员只允许 `kind=chat`）。
  static String? modelKindError(
    CoreModelConfig model, {
    String role = '对话模型',
  }) {
    if (model.kind == kModelKindChat) return null;
    return '该模型是 ${model.kind}，不能作为$role（需要 kind=chat）';
  }

  static int? _intOrNull(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }


  int get tokenAcquisitionRate => _tokenAcquisitionRate;

  /// token 获取帧率（夹取到 20~1000）；有 sink 时同步排队落盘。
  int setTokenAcquisitionRate(int value) {
    _tokenAcquisitionRate = value < tokenRateMin
        ? tokenRateMin
        : (value > tokenRateMax ? tokenRateMax : value);
    sink?.saveTokenRate(_tokenAcquisitionRate);
    return _tokenAcquisitionRate;
  }
}

/// 读 `config/models/*.yaml`（含密钥的完整模型配置）。
///
/// 与核心 `FileSettingsSink.load` 同口径：逐文件解析、坏文件跳过、`model_id` 为空
/// 跳过、同键后读覆盖先读；调用方自行按 `key` 排序（[DomainSettings.models]）。
///
/// 旧文件没有 `provider` 键 ⇒ 归到 [kLegacyProviderId]（不移动文件、不改绑定）；
/// 同时在 `storageFile` 里记下原路径，编辑保存时仍写回同一份文件。
List<CoreModelConfig> readModelConfigs(AgentDataPaths paths) {
  final Directory dir = Directory(paths.modelsDir);
  if (!dir.existsSync()) return <CoreModelConfig>[];
  final Map<String, CoreModelConfig> byKey = <String, CoreModelConfig>{};
  for (final FileSystemEntity entity in dir.listSync()) {
    if (entity is! File || !entity.path.endsWith('.yaml')) continue;
    final Map<String, dynamic>? json = readYamlMap(entity);
    if (json == null) continue;
    try {
      final CoreModelConfig model = CoreModelConfig.fromJson(json);
      if (model.modelId.isEmpty) continue;
      if (model.provider.isEmpty) model.provider = kLegacyProviderId;
      model.storageFile = entity.path;
      byKey[model.key] = model;
    } catch (_) {
      continue; // 字段类型不符：与核心同一取舍（跳过该文件）
    }
  }
  return byKey.values.toList();
}

/// 从磁盘装载领域设置（provider 池 + 模型池 + token 速率）。
///
/// L-22 乙方案（阶段 1）：优先读 `config/agent_settings.yaml`；不存在则回退读平台
/// `settings.yaml` 的旧键，并**当场原子写一份新文件**（"写完即可见"的同步语义，
/// 让核心下一次启动就能安全删旧键，且与两侧启动顺序无关）。缺失 = 默认 1000。
DomainSettings loadDomainSettings(AgentDataPaths paths) {
  final DomainSettings settings = DomainSettings();
  // provider 先装载：模型装载时要拿它解析端点与密钥（`provider/model_id` 身份）。
  for (final ProviderConfig provider in readProviderConfigs(paths)) {
    settings.putProvider(provider);
  }
  for (final CoreModelConfig model in readModelConfigs(paths)) {
    settings.putModel(model);
  }
  final int? rate = _readTokenRate(paths.agentSettingsFile);
  if (rate != null) {
    settings.setTokenAcquisitionRate(rate);
    return settings;
  }
  final int? legacy = _readTokenRate(paths.platformSettingsFile);
  if (legacy != null) {
    settings.setTokenAcquisitionRate(legacy);
    // 镜像到领域文件：只写这一个键，不碰平台 settings.yaml 的其它内容。
    AtomicFile.writeStringAtomicSync(
      paths.agentSettingsFile,
      YamlCodec.encode(<String, dynamic>{
        'token_acquisition_rate': settings.tokenAcquisitionRate,
      }, header: 'Tree 领域设置（tree.agent）：可直接手改。'),
    );
  }
  return settings;
}

/// 读某个 yaml 文件里的有效 token 速率（文件不存在 / 坏值 ⇒ null）。
int? _readTokenRate(String path) {
  final Map<String, dynamic>? map = readYamlMap(File(path));
  if (map == null) return null;
  final Object? raw = map['token_acquisition_rate'];
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw.trim());
  return null;
}
