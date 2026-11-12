import 'llm/model_catalog_client.dart';
import 'model_meta.dart';
import 'paths.dart';
import 'settings/domain_settings.dart';
import 'settings/provider_settings.dart';

/// 模型池的前端视图（A2 的 `GET /api/models` 与 models-info 用）。
///
/// 单一来源：解析与脱敏都走平移来的 [CoreModelConfig]（`toApiJson`），本函数只负责
/// 排序、投影与附带 P8 的只读元数据（价格 / 思考档位探测缓存）。
/// **不探测、不写 YAML**：`meta` 只在缓存存在时出现，探测由
/// `POST /api/models/{modelId}/meta` 显式触发。
List<Map<String, dynamic>> readModels(AgentDataPaths paths) {
  final List<CoreModelConfig> configs = readModelConfigs(paths)
    ..sort((CoreModelConfig a, CoreModelConfig b) => a.key.compareTo(b.key));
  final Map<String, Map<String, dynamic>> meta = readModelMetaCache(paths);
  return <Map<String, dynamic>>[
    for (final CoreModelConfig model in configs)
      <String, dynamic>{
        ...model.toApiJson(),
        // 旧缓存键是裸 `model_id`：新键（`provider/model_id`）没有时兜底读旧键。
        if (meta[model.key] != null)
          'meta': meta[model.key]
        else if (meta[model.modelId] != null)
          'meta': meta[model.modelId],
      },
  ];
}

/// provider 的前端视图（列表 / 详情共用）：配置 + 缓存摘要。
Map<String, dynamic> providerApiJson(
  AgentDataPaths paths,
  ProviderConfig provider, {
  int boundModelCount = 0,
}) {
  final ProviderModelCache? cache = readProviderModelCache(paths, provider.id);
  return <String, dynamic>{
    ...provider.toApiJson(),
    'model_count': boundModelCount,
    'cached_model_count': cache?.models.length ?? 0,
    'fetched_at': cache?.fetchedAt ?? '',
    'error': cache?.error ?? '',
  };
}

/// provider 目录缓存的前端视图。
Map<String, dynamic> providerCacheJson(ProviderModelCache cache) =>
    <String, dynamic>{
      'provider_id': cache.providerId,
      'fetched_at': cache.fetchedAt,
      'error': cache.error,
      'models': <Map<String, dynamic>>[
        for (final ProviderModelEntry entry in cache.models) entry.toJson(),
      ],
    };

/// 拉取 provider 的模型目录并写缓存（D7）。
///
/// 失败**不抛**：只把可读原因写进 `error`，并保留上一次的成功条目——provider 刚
/// 建好时端点不可达很常见，不能因此让保存失败。
Future<ProviderModelCache> refreshProviderCatalog(
  AgentDataPaths paths,
  ProviderConfig provider, {
  ModelCatalogClient? client,
}) async {
  final ModelCatalogClient catalog = client ?? ModelCatalogClient();
  final bool owns = client == null;
  final ProviderModelCache previous =
      readProviderModelCache(paths, provider.id) ??
      ProviderModelCache(providerId: provider.id);
  final String at = DateTime.now().toIso8601String();
  try {
    final List<Map<String, Object?>> entries = await catalog.fetchCatalog(
      baseUrl: provider.resolvedBaseUrl,
      apiKey: provider.resolveApiKey(),
    );
    final List<ProviderModelEntry> models = <ProviderModelEntry>[];
    for (final Map<String, Object?> entry in entries) {
      final ProviderModelEntry parsed = parseProviderCatalogEntry(
        entry,
        fetchedAt: at,
      );
      if (parsed.modelId.isNotEmpty) models.add(parsed);
    }
    final ProviderModelCache cache = ProviderModelCache(
      providerId: provider.id,
      fetchedAt: at,
      models: models,
    );
    writeProviderModelCache(paths, cache);
    return cache;
  } on ModelMetaFailure catch (error) {
    return _failedProviderCache(paths, previous, error.message, at);
  } catch (error) {
    return _failedProviderCache(paths, previous, '模型目录拉取失败：$error', at);
  } finally {
    if (owns) catalog.close();
  }
}

ProviderModelCache _failedProviderCache(
  AgentDataPaths paths,
  ProviderModelCache previous,
  String message,
  String at,
) {
  final ProviderModelCache cache = ProviderModelCache(
    providerId: previous.providerId,
    fetchedAt: at,
    error: message,
    models: previous.models,
  );
  writeProviderModelCache(paths, cache);
  return cache;
}
