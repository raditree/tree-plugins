/// Provider 池 + provider 模型目录缓存（D7）。
///
/// 口径（`production-line-stability-recon.md` §5.1）：
/// - provider 配置落 `config/providers/<id>.yaml`，含 `base_url` 与密钥；
/// - 模型身份是 `provider/model_id`，同一 `model_id` 允许出现在多个 provider；
/// - provider 的模型目录缓存落 `config/provider_models/<id>.json`，端点声明什么就
///   缓存什么——**没声明的字段留空**（不落 `low/high/max` 之类的兜底值，D8）；
/// - 密钥只写盘、不回显；前端只拿 `has_api_key` / `api_key_env`。
library;

import 'dart:convert';
import 'dart:io';

import '../model_meta.dart';
import '../paths.dart';
import '../store/atomic_file.dart';
import '../yaml_utils.dart';

/// v1 只支持 OpenAI 兼容协议（与模型池的 `protocol` 取值同串）。
const String kProviderProtocolOpenai = 'openai';

/// 旧文件没有 `provider` 键时的归组 id（不落盘，只在内存里分组）。
const String kLegacyProviderId = 'legacy';

/// 端点 URL 脱敏：仅保留协议 + 主机（+ 非默认端口）。
///
/// 与模型池 `base_url` 的回显同口径：前端看到的是"连到哪"，看不到路径与密钥。
String maskEndpointUrl(String raw) {
  if (raw.isEmpty) return '';
  final Uri? uri = Uri.tryParse(raw);
  if (uri == null || uri.host.isEmpty) return '';
  final bool defaultPort =
      (uri.scheme == 'https' && uri.port == 443) ||
      (uri.scheme == 'http' && uri.port == 80);
  return defaultPort || uri.port == 0
      ? '${uri.scheme}://${uri.host}'
      : '${uri.scheme}://${uri.host}:${uri.port}';
}

/// 一个 provider 的配置（含密钥，只活在插件进程内）。
class ProviderConfig {
  ProviderConfig({
    required this.id,
    this.name = '',
    this.baseUrl = '',
    this.apiKey = '',
    this.apiKeyEnv = '',
    this.protocol = kProviderProtocolOpenai,
    this.enabled = true,
    this.createdAt = '',
    this.updatedAt = '',
  });

  /// 稳定 id（由显示名 slug 生成，创建后不可改）。
  final String id;

  String name;

  /// 端点根（`/models` / `/chat/completions` 由请求侧拼接）。
  String baseUrl;

  /// 明文密钥（`api_key_env` 非空且读得到时不使用它）。
  String apiKey;

  /// 密钥环境变量名（非空时优先读环境变量）。
  String apiKeyEnv;

  String protocol;
  bool enabled;
  String createdAt;
  String updatedAt;

  String get label => name.trim().isEmpty ? id : name.trim();

  /// 去尾 `/` 的端点根。
  String get resolvedBaseUrl {
    String value = baseUrl.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  /// 请求时真正使用的密钥：环境变量优先，读不到再回落到明文。
  ///
  /// [environment] 仅测试注入用。
  String resolveApiKey({Map<String, String>? environment}) {
    final String env = apiKeyEnv.trim();
    if (env.isNotEmpty) {
      final String? value = (environment ?? Platform.environment)[env];
      if (value != null && value.trim().isNotEmpty) return value.trim();
    }
    return apiKey.trim();
  }

  /// 持久化形态（含密钥；`created_at` / `updated_at` 为空时不写）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'base_url': resolvedBaseUrl,
    'api_key': apiKey,
    'api_key_env': apiKeyEnv,
    'protocol': protocol,
    'enabled': enabled,
    if (createdAt.isNotEmpty) 'created_at': createdAt,
    if (updatedAt.isNotEmpty) 'updated_at': updatedAt,
  };

  /// 前端形态：密钥不外泄，`base_url` 脱敏。
  Map<String, dynamic> toApiJson() => <String, dynamic>{
    'id': id,
    'name': label,
    'base_url': maskEndpointUrl(baseUrl),
    'has_api_key': apiKey.trim().isNotEmpty,
    'api_key_env': apiKeyEnv,
    'protocol': protocol,
    'enabled': enabled,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  static ProviderConfig? fromJson(Map<String, dynamic> json) {
    final String id = (json['id'] ?? '').toString().trim();
    if (id.isEmpty) return null;
    return ProviderConfig(
      id: id,
      name: (json['name'] ?? '').toString(),
      baseUrl: (json['base_url'] ?? '').toString(),
      apiKey: (json['api_key'] ?? '').toString(),
      apiKeyEnv: (json['api_key_env'] ?? '').toString(),
      protocol: _readProtocol(json['protocol']),
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      createdAt: (json['created_at'] ?? '').toString(),
      updatedAt: (json['updated_at'] ?? '').toString(),
    );
  }

  /// 用请求体合并；`base_url` / `api_key` 为空串表示保留原值，
  /// `api_key_env` 显式空串表示清空（它不是密钥，需要能切换回明文）。
  void merge(Map<String, dynamic> payload) {
    if (payload.containsKey('name')) {
      final String value = (payload['name'] as String? ?? '').trim();
      if (value.isNotEmpty) name = value;
    }
    if (payload.containsKey('base_url')) {
      final String value = (payload['base_url'] as String? ?? '').trim();
      if (value.isNotEmpty) baseUrl = value;
    }
    if (payload.containsKey('api_key')) {
      final String value = (payload['api_key'] as String? ?? '').trim();
      if (value.isNotEmpty) apiKey = value;
    }
    if (payload.containsKey('api_key_env')) {
      apiKeyEnv = (payload['api_key_env'] as String? ?? '').trim();
    }
    if (payload.containsKey('protocol')) {
      protocol = _readProtocol(payload['protocol']);
    }
    if (payload.containsKey('enabled')) {
      enabled = payload['enabled'] as bool? ?? enabled;
    }
  }

  /// 新增 / 修改的校验；[base] 非空表示更新（`name` / `base_url` 可留空不变）。
  static String? validateProvider(
    Map<String, dynamic> payload, {
    ProviderConfig? base,
  }) {
    if (payload.containsKey('name') || base == null) {
      final String name = (payload['name'] as String? ?? '').trim();
      if (name.isEmpty && base == null) return 'name 不能为空';
    }
    final String baseUrl = (payload['base_url'] as String? ?? '').trim();
    if (baseUrl.isEmpty && base == null) return 'base_url 不能为空';
    if (baseUrl.isNotEmpty) {
      final Uri? uri = Uri.tryParse(baseUrl);
      if (uri == null ||
          !(uri.scheme == 'http' || uri.scheme == 'https') ||
          uri.host.isEmpty) {
        return 'base_url 必须是 http(s) 地址';
      }
    }
    final String env = (payload['api_key_env'] as String? ?? '').trim();
    if (env.isNotEmpty &&
        !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(env)) {
      return 'api_key_env 不是合法的环境变量名：$env';
    }
    final String protocol = _readProtocol(payload['protocol']);
    if (protocol != kProviderProtocolOpenai) {
      return 'v1 只支持 protocol=$kProviderProtocolOpenai（收到 $protocol）';
    }
    return null;
  }

  /// 显示名 → 稳定 id（只保留 `[a-z0-9-]`；中文名等回落 `provider`）。
  static String slugOf(String raw) {
    final String lowered = raw.trim().toLowerCase();
    final String replaced = lowered.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    final String trimmed = replaced.replaceAll(RegExp(r'^-+|-+$'), '');
    return trimmed.isEmpty ? 'provider' : trimmed;
  }

  static String _readProtocol(Object? raw) {
    final String value = (raw ?? '').toString().trim();
    return value.isEmpty ? kProviderProtocolOpenai : value;
  }
}

/// provider 模型目录里的一条模型（端点声明的原样快照）。
class ProviderModelEntry {
  const ProviderModelEntry({
    required this.modelId,
    this.name = '',
    this.kind = 'chat',
    this.contextLength = 0,
    this.maxOutputTokens = 0,
    this.inputModalities = const <String>[],
    this.outputModalities = const <String>[],
    this.reasoningEffortOptions = const <String>[],
    this.pricing,
  });

  final String modelId;
  final String name;

  /// 推断出的模型类型（`chat` / `embedding` / `decision`），用户可改。
  final String kind;

  /// 端点声明的上下文长度（0 = 未声明）。
  final int contextLength;

  /// 端点声明的最大输出（0 = 未声明）。
  final int maxOutputTokens;

  /// 输入模态（`text` / `image` / `audio` / `video`）。
  final List<String> inputModalities;

  /// 输出模态。
  final List<String> outputModalities;

  /// 端点声明的思考档位（空 = 未声明，**不落兜底值**）。
  final List<String> reasoningEffortOptions;

  final ModelPricing? pricing;

  bool get ifVision => _hasAny(inputModalities, const <String>['image']);
  bool get ifAudio => _hasAny(inputModalities, const <String>['audio']);
  bool get ifVideo => _hasAny(inputModalities, const <String>['video']);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'model_id': modelId,
    'name': name,
    'kind': kind,
    'context_length': contextLength,
    'max_output_tokens': maxOutputTokens,
    'input_modalities': inputModalities,
    'output_modalities': outputModalities,
    'reasoning_effort_options': reasoningEffortOptions,
    if (pricing != null) 'pricing': pricing!.toJson(),
  };

  static ProviderModelEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String modelId = (raw['model_id'] ?? '').toString().trim();
    if (modelId.isEmpty) return null;
    return ProviderModelEntry(
      modelId: modelId,
      name: (raw['name'] ?? '').toString(),
      kind: (raw['kind'] ?? '').toString().trim().isEmpty
          ? 'chat'
          : raw['kind'].toString().trim(),
      contextLength: _intOf(raw['context_length']),
      maxOutputTokens: _intOf(raw['max_output_tokens']),
      inputModalities: _stringList(raw['input_modalities']),
      outputModalities: _stringList(raw['output_modalities']),
      reasoningEffortOptions: _stringList(raw['reasoning_effort_options']),
      pricing: ModelPricing.fromJson(raw['pricing']),
    );
  }

  static bool _hasAny(List<String> values, List<String> wanted) {
    for (final String value in values) {
      if (wanted.contains(value.toLowerCase())) return true;
    }
    return false;
  }
}

/// 一个 provider 的模型目录缓存（`config/provider_models/<id>.json`）。
class ProviderModelCache {
  ProviderModelCache({
    required this.providerId,
    this.fetchedAt = '',
    this.error = '',
    List<ProviderModelEntry>? models,
  }) : models = models ?? <ProviderModelEntry>[];

  final String providerId;
  String fetchedAt;

  /// 最近一次拉取失败的可读原因（成功时为空）；失败不影响旧缓存继续可用。
  String error;

  List<ProviderModelEntry> models;

  ProviderModelEntry? entry(String modelId) {
    for (final ProviderModelEntry item in models) {
      if (item.modelId == modelId) return item;
    }
    return null;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'provider_id': providerId,
    'fetched_at': fetchedAt,
    if (error.isNotEmpty) 'error': error,
    'models': <Map<String, dynamic>>[
      for (final ProviderModelEntry item in models) item.toJson(),
    ],
  };

  static ProviderModelCache? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String providerId = (raw['provider_id'] ?? '').toString().trim();
    if (providerId.isEmpty) return null;
    final List<ProviderModelEntry> models = <ProviderModelEntry>[];
    for (final Object? item
        in (raw['models'] as List<dynamic>?) ?? const <dynamic>[]) {
      final ProviderModelEntry? entry = ProviderModelEntry.fromJson(item);
      if (entry != null) models.add(entry);
    }
    return ProviderModelCache(
      providerId: providerId,
      fetchedAt: (raw['fetched_at'] ?? '').toString(),
      error: (raw['error'] ?? '').toString(),
      models: models,
    );
  }
}

/// 把一个端点目录条目解析成缓存条目。
///
/// 价格 / 思考档位 / 上下文复用模型元数据探测的解析口径（[parseModelMetaEntry]）；
/// 这里再补类型推断、最大输出与模态。
ProviderModelEntry parseProviderCatalogEntry(
  Map<String, Object?> entry, {
  String fetchedAt = '',
}) {
  final String modelId = _entryId(entry);
  final ModelMeta meta = parseModelMetaEntry(
    entry,
    modelId: modelId,
    fetchedAt: fetchedAt,
  );
  return ProviderModelEntry(
    modelId: modelId,
    name: _entryName(entry, modelId),
    kind: _inferKind(entry, modelId),
    contextLength: meta.contextLength,
    maxOutputTokens: _maxOutputTokensOf(entry),
    inputModalities: _modalitiesOf(entry, output: false),
    outputModalities: _modalitiesOf(entry, output: true),
    reasoningEffortOptions: meta.reasoningEffortOptions,
    pricing: meta.pricing,
  );
}

/// 读 `config/providers/*.yaml`（坏文件跳过、`id` 为空跳过、同 id 后读覆盖先读）。
List<ProviderConfig> readProviderConfigs(AgentDataPaths paths) {
  final Directory dir = Directory(paths.providersDir);
  if (!dir.existsSync()) return <ProviderConfig>[];
  final Map<String, ProviderConfig> byId = <String, ProviderConfig>{};
  for (final FileSystemEntity entity in dir.listSync()) {
    if (entity is! File || !entity.path.endsWith('.yaml')) continue;
    final Map<String, dynamic>? json = readYamlMap(entity);
    if (json == null) continue;
    final ProviderConfig? provider = ProviderConfig.fromJson(json);
    if (provider == null) continue;
    byId[provider.id] = provider;
  }
  return byId.values.toList();
}

/// 读某个 provider 的模型目录缓存；缺失 / 坏 JSON ⇒ null。
ProviderModelCache? readProviderModelCache(
  AgentDataPaths paths,
  String providerId,
) {
  final String? text = AtomicFile.readStringOrNullSync(
    paths.providerModelsFile(providerId),
  );
  if (text == null || text.trim().isEmpty) return null;
  try {
    return ProviderModelCache.fromJson(jsonDecode(text));
  } catch (_) {
    return null;
  }
}

/// 写模型目录缓存（原子落盘）。
void writeProviderModelCache(
  AgentDataPaths paths,
  ProviderModelCache cache,
) {
  AtomicFile.writeStringAtomicSync(
    paths.providerModelsFile(cache.providerId),
    '${const JsonEncoder.withIndent('  ').convert(cache.toJson())}\n',
  );
}

/// 删除 provider 时清掉它的目录缓存。
void removeProviderModelCache(AgentDataPaths paths, String providerId) {
  final File file = File(paths.providerModelsFile(providerId));
  if (file.existsSync()) file.deleteSync();
}

// ── 目录条目解析细节 ────────────────────────────────────────────────────

String _entryId(Map<String, Object?> entry) {
  for (final String key in const <String>['id', 'model_id', 'name']) {
    final String value = (entry[key] ?? '').toString().trim();
    if (value.isNotEmpty) return value;
  }
  return '';
}

String _entryName(Map<String, Object?> entry, String modelId) {
  final String name = (entry['name'] ?? '').toString().trim();
  return name.isEmpty ? modelId : name;
}

String _inferKind(Map<String, Object?> entry, String modelId) {
  final String declared = (entry['type'] ?? entry['model_type'] ?? '')
      .toString()
      .toLowerCase();
  if (declared.contains('embed') ||
      modelId.toLowerCase().contains('embed')) {
    return 'embedding';
  }
  if (declared.contains('decision')) return 'decision';
  return 'chat';
}

int _maxOutputTokensOf(Map<String, Object?> entry) {
  for (final String key in const <String>[
    'max_output_tokens',
    'max_completion_tokens',
  ]) {
    final int value = _intOf(entry[key]);
    if (value > 0) return value;
  }
  final Object? top = entry['top_provider'];
  if (top is Map) return _intOf(top['max_completion_tokens']);
  return 0;
}

/// 模态解析：兼容 `architecture.*_modalities`、顶层 `*_modalities`、
/// `capabilities`（list / map）与 `supports_vision|audio|video`，以及
/// `modality: "text+image->text"` 这类声明。
List<String> _modalitiesOf(Map<String, Object?> entry, {required bool output}) {
  final List<String> out = <String>[];
  void add(Object? raw) {
    for (final String item in _stringList(raw)) {
      final String value = _normalizeModality(item);
      if (value.isNotEmpty && !out.contains(value)) out.add(value);
    }
  }

  final String key = output ? 'output_modalities' : 'input_modalities';
  final Object? arch = entry['architecture'];
  if (arch is Map) add(arch[key]);
  add(entry[key]);

  final Object? modality = entry['modality'];
  if (modality is String) {
    final List<String> sides = modality.split('->');
    add(sides.length > (output ? 1 : 0) ? sides[output ? 1 : 0] : '');
  }

  final Object? capabilities = entry['capabilities'];
  if (capabilities is List) {
    add(capabilities);
  } else if (capabilities is Map) {
    for (final MapEntry<Object?, Object?> item in capabilities.entries) {
      if (item.value == true) add(item.key);
    }
  }

  if (!output) {
    for (final String flag in const <String>[
      'supports_vision',
      'supports_audio',
      'supports_video',
    ]) {
      if (entry[flag] == true) add(flag);
    }
  }
  return out;
}

String _normalizeModality(String raw) {
  final String value = raw.trim().toLowerCase();
  if (value.isEmpty) return '';
  if (value == '+' || value == 'text') return 'text';
  if (value.contains('image') || value.contains('vision')) return 'image';
  if (value.contains('audio') || value.contains('speech')) return 'audio';
  if (value.contains('video')) return 'video';
  if (value.contains('text')) return 'text';
  return '';
}

List<String> _stringList(Object? raw) {
  if (raw is List) {
    return <String>[
      for (final Object? item in raw)
        if ((item ?? '').toString().trim().isNotEmpty)
          (item ?? '').toString().trim(),
    ];
  }
  if (raw is String) {
    return <String>[
      for (final String item in raw.split(RegExp(r'[+, ]')))
        if (item.trim().isNotEmpty) item.trim(),
    ];
  }
  return <String>[];
}

int _intOf(Object? raw) {
  if (raw is num) return raw.toInt();
  return int.tryParse('${raw ?? ''}'.trim()) ?? 0;
}
