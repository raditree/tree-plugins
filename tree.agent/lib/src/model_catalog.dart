import 'model_meta.dart';
import 'paths.dart';
import 'settings/domain_settings.dart';

/// 模型池的前端视图（A2 的 `GET /api/models` 与 models-info 用）。
///
/// 单一来源：解析与脱敏都走平移来的 [CoreModelConfig]（`toApiJson`），本函数只负责
/// 排序、投影与附带 P8 的只读元数据（价格 / 思考档位探测缓存）。
/// **不探测、不写 YAML**：`meta` 只在缓存存在时出现，探测由
/// `POST /api/models/{modelId}/meta` 显式触发。
List<Map<String, dynamic>> readModels(AgentDataPaths paths) {
  final List<CoreModelConfig> configs = readModelConfigs(paths)
    ..sort(
      (CoreModelConfig a, CoreModelConfig b) =>
          a.modelId.compareTo(b.modelId),
    );
  final Map<String, Map<String, dynamic>> meta = readModelMetaCache(paths);
  return <Map<String, dynamic>>[
    for (final CoreModelConfig model in configs)
      <String, dynamic>{
        ...model.toApiJson(),
        if (meta.containsKey(model.modelId)) 'meta': meta[model.modelId],
      },
  ];
}
