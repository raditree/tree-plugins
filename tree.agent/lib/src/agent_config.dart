import 'dart:io';

import 'paths.dart';
import 'yaml_utils.dart';

/// agent 配置视图（models-info 需要的字段子集）。
///
/// 只解析本视图要用的键：其余键**故意不读**——它们分别属于工作空间 / 团队 /
/// SSH（各自的域在后续批次搬）；这也意味着"名册无关字段写坏了"时核心可能报错、
/// 本视图仍能返回，属于可接受的退化差异（正常文件不受影响）。
class AgentConfigView {
  const AgentConfigView({
    required this.id,
    required this.modelId,
    required this.systemPrompt,
    required this.reasoningEffort,
    required this.maxSeqlenOverride,
    required this.maxOutputTokens,
    required this.compressThreshold,
    required this.thinkingOverride,
  });

  final String id;
  final String modelId;
  final String systemPrompt;
  final String reasoningEffort;
  final int maxSeqlenOverride;
  final int maxOutputTokens;
  final double compressThreshold;
  final bool? thinkingOverride;
}

/// 读 `agents/<id>.yaml`。
///
/// 与核心 `FileTreeStore.agent` 同口径：文件不存在 / YAML 坏 / 字段类型不符
/// ⇒ null（核心把该 agent 当不存在 → 端点 404）。
///
/// `id` 缺失时核心会生成一个新 id；这里回落到请求的 agentId（正常文件都带 id）。
AgentConfigView? readAgentConfig(
  AgentDataPaths paths,
  String agentId,
) {
  final File file = File(paths.agentFile(agentId));
  final Map<String, dynamic>? json = readYamlMap(file);
  if (json == null) return null;
  try {
    final String id = json['id'] as String? ?? '';
    return AgentConfigView(
      id: id.isEmpty ? agentId : id,
      modelId: json['model_id'] as String? ?? '',
      systemPrompt: json['system_prompt'] as String? ?? '',
      reasoningEffort: json['reasoning_effort'] as String? ?? '',
      maxSeqlenOverride:
          (json['max_seqlen_override'] as num?)?.toInt() ?? 0,
      maxOutputTokens: (json['max_output_tokens'] as num?)?.toInt() ?? 0,
      compressThreshold:
          (json['compress_threshold'] as num?)?.toDouble() ?? 0,
      thinkingOverride: json['thinking_override'] as bool?,
    );
  } catch (_) {
    return null;
  }
}

/// 成员级模型参数覆盖（只含真正设置过的键，与核心 `memberOverrides` 同口径）。
Map<String, Object?> memberOverridesOf(AgentConfigView agent) =>
    <String, Object?>{
      if (agent.reasoningEffort.trim().isNotEmpty)
        'reasoning_effort': agent.reasoningEffort,
      if (agent.maxSeqlenOverride > 0) 'max_seqlen': agent.maxSeqlenOverride,
      if (agent.maxOutputTokens > 0)
        'max_output_tokens': agent.maxOutputTokens,
      if (agent.compressThreshold > 0)
        'compress_threshold': agent.compressThreshold,
      if (agent.thinkingOverride != null) 'thinking': agent.thinkingOverride,
    };
