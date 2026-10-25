import 'paths.dart';
import 'settings/domain_settings.dart';

/// 模型池的前端视图（A2 的 `GET /api/models` 与 models-info 用）。
///
/// 单一来源：解析与脱敏都走平移来的 [CoreModelConfig]（`toApiJson`），本函数只负责
/// 排序与投影——**不再维护第二套解析逻辑**，避免 A2 只读视图与 A3 生成循环漂移。
List<Map<String, dynamic>> readModels(AgentDataPaths paths) {
  final List<CoreModelConfig> configs = readModelConfigs(paths)
    ..sort(
      (CoreModelConfig a, CoreModelConfig b) =>
          a.modelId.compareTo(b.modelId),
    );
  return <Map<String, dynamic>>[
    for (final CoreModelConfig model in configs) model.toApiJson(),
  ];
}
