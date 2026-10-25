import 'dart:io';

import 'paths.dart';
import 'yaml_utils.dart';

/// 模型池读取：`config/models/*.yaml` → 前端 **ModelApi**（11 键，无密钥、
/// `base_url` 脱敏）。
///
/// 与核心 `FileSettingsSink.load` + `CoreSettings.models()` +
/// `CoreModelConfig.toApiJson` 同口径：
/// - 逐文件解析；坏文件 / 顶层不是映射 / 字段类型不符 ⇒ **跳过该文件**
///   （核心在装载时 catch 后跳过，不是整池作废）；
/// - `model_id` 为空 ⇒ 跳过；
/// - 同 id 后读覆盖先读（核心用 Map 存，键冲突时后写覆盖）；最后按 model_id 升序；
/// - `token_scale` 宽容读取（数字或纯数字字符串），越界/非法回 2.0；
/// - `base_url` 脱敏只留 `scheme://host[:port]`（默认端口省略），解析失败给空串。
List<Map<String, dynamic>> readModels(AgentDataPaths paths) {
  final Directory dir = Directory(paths.modelsDir);
  if (!dir.existsSync()) return <Map<String, dynamic>>[];
  final Map<String, Map<String, dynamic>> byId = <String, Map<String, dynamic>>{};
  for (final FileSystemEntity entity in dir.listSync()) {
    if (entity is! File || !entity.path.endsWith('.yaml')) continue;
    final Map<String, dynamic>? json = readYamlMap(entity);
    if (json == null) continue;
    try {
      final String modelId = json['model_id'] as String? ?? '';
      if (modelId.isEmpty) continue;
      byId[modelId] = _toApiJson(json);
    } catch (_) {
      continue; // 字段类型不符：与核心同一取舍（跳过该文件）
    }
  }
  final List<Map<String, dynamic>> list = byId.values.toList()
    ..sort(
      (Map<String, dynamic> a, Map<String, dynamic> b) =>
          (a['model_id'] as String).compareTo(b['model_id'] as String),
    );
  return list;
}

/// 默认思考强度档位（与核心 `CoreModelConfig.defaultReasoningEfforts` 同值）。
const List<String> kDefaultReasoningEfforts = <String>['low', 'high', 'max'];

/// 默认 token 换算比例（与核心 `defaultTokenScale` 同值）。
const double kDefaultTokenScale = 2.0;

Map<String, dynamic> _toApiJson(Map<String, dynamic> json) {
  final String modelId = json['model_id'] as String? ?? '';
  final String name = json['name'] as String? ?? '';
  final String baseUrl = json['base_url'] as String? ?? '';
  // 这些字段名册接口不返回，但核心**解析时会强转**：类型不符 ⇒ 该文件被跳过。
  // 这里读一遍只为复刻同一退化方向（不是多返回字段）。
  json['api_key'] as String?;
  final bool thinking = json['thinking'] as bool? ?? false;
  final bool ifVision = json['if_vision'] as bool? ?? false;
  final String reasoningEffort = json['reasoning_effort'] as String? ?? '';
  final Object? rawOptions = json['reasoning_effort_options'];
  final List<String> options = rawOptions == null
      ? List<String>.of(kDefaultReasoningEfforts)
      : (rawOptions as List<dynamic>)
            .map((dynamic item) => item.toString())
            .toList();
  final int maxSeqlen = (json['max_seqlen'] as num?)?.toInt() ?? 0;
  final int maxOutputTokens =
      (json['max_output_tokens'] as num?)?.toInt() ?? 0;
  final double tokenScale = _readScale(json['token_scale']);
  final int longestSessionTokens =
      (json['longest_session_tokens'] as num?)?.toInt() ?? 0;
  return <String, dynamic>{
    'model_id': modelId,
    'name': name.isEmpty ? modelId : name,
    'base_url': maskBaseUrl(baseUrl),
    'thinking': thinking,
    'if_vision': ifVision,
    'reasoning_effort': reasoningEffort,
    'reasoning_effort_options': options,
    'max_seqlen': maxSeqlen,
    'max_output_tokens': maxOutputTokens,
    'token_scale': tokenScale,
    'longest_session_tokens': longestSessionTokens,
  };
}

/// 宽容读取 token_scale：手写 yaml 里的整数 / 字符串也能生效，非法值回 2.0。
double _readScale(Object? raw) {
  double? value;
  if (raw is num) {
    value = raw.toDouble();
  } else if (raw is String) {
    value = double.tryParse(raw.trim());
  }
  if (value == null || value < 0.2 || value > 20) return kDefaultTokenScale;
  return value;
}

/// `base_url` 脱敏：仅保留协议 + 主机（+ 非默认端口）。
///
/// 与核心 `CoreModelConfig.maskBaseUrl` 逐字同口径：解析失败 / 无主机 ⇒ 空串。
String maskBaseUrl(String raw) {
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
