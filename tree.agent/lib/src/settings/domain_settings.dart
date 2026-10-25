import 'dart:io';

import 'package:path/path.dart' as p;

import '../paths.dart';
import '../yaml_utils.dart';

/// `token_scale` 的默认值（与核心 `defaultTokenScale` 同值）。
const double kDefaultTokenScale = 2.0;

/// 模型没配 `max_seqlen` 时的兜底上下文长度（与核心 `CoreSettings.fallbackMaxSeqlen` 同值）。
const int kFallbackMaxSeqlen = 128000;

/// 自定义模型配置（从核心 `CoreModelConfig` 平移；含密钥，只活在插件进程内）。
///
/// **api_key 永不回显**：`toApiJson` 剥离密钥并把 `base_url` 脱敏。
/// `PATCH` 时空的 `base_url`/`api_key` 表示"保留原值"。
class CoreModelConfig {
  CoreModelConfig({
    required this.modelId,
    this.name = '',
    this.baseUrl = '',
    this.apiKey = '',
    this.thinking = false,
    this.ifVision = false,
    this.reasoningEffort = '',
    List<String>? reasoningEffortOptions,
    this.maxSeqlen = 0,
    this.maxOutputTokens = 0,
    this.tokenScale = kDefaultTokenScale,
    this.longestSessionTokens = 0,
  }) : reasoningEffortOptions =
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
  String name;
  String baseUrl;
  String apiKey;
  bool thinking;
  bool ifVision;
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
  Map<String, dynamic> toJson() => <String, dynamic>{
    'model_id': modelId,
    'name': name,
    'base_url': baseUrl,
    'api_key': apiKey,
    'thinking': thinking,
    'if_vision': ifVision,
    'reasoning_effort': reasoningEffort,
    'reasoning_effort_options': reasoningEffortOptions,
    'max_seqlen': maxSeqlen,
    'max_output_tokens': maxOutputTokens,
    'token_scale': tokenScale,
    'longest_session_tokens': longestSessionTokens,
  };

  /// 前端形态：无密钥、base_url 脱敏。
  Map<String, dynamic> toApiJson() => <String, dynamic>{
    'model_id': modelId,
    'name': name.isEmpty ? modelId : name,
    'base_url': maskBaseUrl(baseUrl),
    'thinking': thinking,
    'if_vision': ifVision,
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
      name: json['name'] as String? ?? '',
      baseUrl: json['base_url'] as String? ?? '',
      apiKey: json['api_key'] as String? ?? '',
      thinking: json['thinking'] as bool? ?? false,
      ifVision: json['if_vision'] as bool? ?? false,
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
  void merge(Map<String, dynamic> payload) {
    if (payload.containsKey('name')) name = payload['name'] as String? ?? name;
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
  static String maskBaseUrl(String raw) {
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

  /// 应用成员级模型参数覆盖（只覆盖非空项，返回副本；学习状态一起带走）。
  CoreModelConfig withOverrides(Map<String, Object?> overrides) {
    if (overrides.isEmpty) return this;
    final CoreModelConfig copy = CoreModelConfig(
      modelId: modelId,
      name: name,
      baseUrl: baseUrl,
      apiKey: apiKey,
      thinking: thinking,
      ifVision: ifVision,
      reasoningEffort: reasoningEffort,
      reasoningEffortOptions: reasoningEffortOptions,
      maxSeqlen: maxSeqlen,
      maxOutputTokens: maxOutputTokens,
      tokenScale: tokenScale,
      longestSessionTokens: longestSessionTokens,
    );
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
  int get effectiveMaxSeqlen =>
      maxSeqlen > 0 ? maxSeqlen : kFallbackMaxSeqlen;

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

  void deleteModel(String modelId);

  /// token 速率变更（写回 settings.yaml 的 token_acquisition_rate）。
  void saveTokenRate(int rate);
}

/// 领域设置（模型池 + token 速率）——从核心 `CoreSettings` 拆出的**领域半边**。
///
/// 核心的 `CoreSettings` 混装平台开关与领域配置；插件只保留后者。存储位置与核心
/// 相同（`config/models/*.yaml`、`config/settings.yaml` 的 `token_acquisition_rate`），
/// 这样双跑期两边读到的是同一份数据。
class DomainSettings {
  DomainSettings({this.sink});

  static const int tokenRateMin = 20;
  static const int tokenRateMax = 1000;

  /// 落盘出口；为 null 时只改内存（测试 / 只读期）。
  DomainSettingsSink? sink;

  final Map<String, CoreModelConfig> _models = <String, CoreModelConfig>{};

  int _tokenAcquisitionRate = tokenRateMax;

  /// 模型列表（按 model_id 升序）。
  List<CoreModelConfig> models() {
    final List<CoreModelConfig> list = _models.values.toList()
      ..sort(
        (CoreModelConfig a, CoreModelConfig b) =>
            a.modelId.compareTo(b.modelId),
      );
    return list;
  }

  CoreModelConfig? model(String modelId) => _models[modelId];

  /// 直接放入模型（装载用；不触发落盘）。
  void putModel(CoreModelConfig model) => _attach(model);

  void _attach(CoreModelConfig model) {
    model.onChanged = (CoreModelConfig changed) => sink?.saveModel(changed);
    _models[model.modelId] = model;
  }

  /// 新建模型；`model_id` 已存在时返回 null（调用方回 409）。
  CoreModelConfig? createModel(Map<String, dynamic> payload) {
    final String modelId = (payload['model_id'] as String? ?? '').trim();
    if (modelId.isEmpty || _models.containsKey(modelId)) return null;
    final CoreModelConfig model = CoreModelConfig(modelId: modelId);
    model.merge(payload);
    _attach(model);
    sink?.saveModel(model);
    return model;
  }

  /// 更新模型；不存在返回 null。
  CoreModelConfig? updateModel(String modelId, Map<String, dynamic> payload) {
    final CoreModelConfig? model = _models[modelId];
    if (model == null) return null;
    model.merge(payload);
    sink?.saveModel(model);
    return model;
  }

  /// 删除模型；返回是否真的删除了条目。
  bool deleteModel(String modelId) {
    final bool removed = _models.remove(modelId) != null;
    if (removed) sink?.deleteModel(modelId);
    return removed;
  }

  /// 校验新增模型必填项（与核心一致：model_id / base_url / api_key）。
  static String? validateNewModel(Map<String, dynamic> payload) {
    final String modelId = (payload['model_id'] as String? ?? '').trim();
    if (modelId.isEmpty) return 'model_id 不能为空';
    final String baseUrl = (payload['base_url'] as String? ?? '').trim();
    if (baseUrl.isEmpty) return 'base_url 不能为空';
    final String apiKey = (payload['api_key'] as String? ?? '').trim();
    if (apiKey.isEmpty) return 'api_key 不能为空';
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
/// 跳过、同 id 后读覆盖先读；调用方自行按 model_id 排序（[DomainSettings.models]）。
List<CoreModelConfig> readModelConfigs(AgentDataPaths paths) {
  final Directory dir = Directory(paths.modelsDir);
  if (!dir.existsSync()) return <CoreModelConfig>[];
  final Map<String, CoreModelConfig> byId = <String, CoreModelConfig>{};
  for (final FileSystemEntity entity in dir.listSync()) {
    if (entity is! File || !entity.path.endsWith('.yaml')) continue;
    final Map<String, dynamic>? json = readYamlMap(entity);
    if (json == null) continue;
    try {
      final CoreModelConfig model = CoreModelConfig.fromJson(json);
      if (model.modelId.isEmpty) continue;
      byId[model.modelId] = model;
    } catch (_) {
      continue; // 字段类型不符：与核心同一取舍（跳过该文件）
    }
  }
  return byId.values.toList();
}

/// 从磁盘装载领域设置（模型池 + token 速率）。
///
/// `settings.yaml` 的 `token_acquisition_rate` 与核心共用同一份文件；缺失/非法时用
/// 默认 1000（近似不限速）。
DomainSettings loadDomainSettings(AgentDataPaths paths) {
  final DomainSettings settings = DomainSettings();
  for (final CoreModelConfig model in readModelConfigs(paths)) {
    settings.putModel(model);
  }
  final Map<String, dynamic>? settingsYaml = readYamlMap(
    File(p.join(paths.root, 'config', 'settings.yaml')),
  );
  final Object? rawRate = settingsYaml?['token_acquisition_rate'];
  if (rawRate is num) {
    settings.setTokenAcquisitionRate(rawRate.toInt());
  } else if (rawRate is String) {
    final int? parsed = int.tryParse(rawRate.trim());
    if (parsed != null) settings.setTokenAcquisitionRate(parsed);
  }
  return settings;
}
