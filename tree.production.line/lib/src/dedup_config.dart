/// 逻辑去重的配置：settings（plugin 绑定）> 环境变量 > 默认值。
library;

import 'dart:convert';

import 'code_chunk.dart';

/// 固定随机源：排序 / 打平 / 采样都按这个 seed 做确定性收口。
const int kDedupSeed = 42;

/// 管线版本：缓存键与结果记录都会带上，整体失效时递增。
const String kDedupPipelineVersion = 'dedup-1';

class DedupConfig {
  const DedupConfig({
    required this.enabled,
    required this.model,
    required this.threshold,
    required this.topK,
    required this.embedBatch,
    required this.instructionPrefix,
    required this.normalize,
    required this.pooling,
    required this.maxFileBytes,
    required this.filesPerRequest,
    required this.comparePerRequest,
    required this.maxIndexChunks,
  });

  final bool enabled;
  final String model;
  final double threshold;
  final int topK;
  final int embedBatch;
  final String instructionPrefix;
  final String normalize;
  final String pooling;
  final int maxFileBytes;
  final int filesPerRequest;
  final int comparePerRequest;
  final int maxIndexChunks;

  static const DedupConfig defaults = DedupConfig(
    enabled: true,
    model: '',
    threshold: 0.90,
    topK: 5,
    embedBatch: 32,
    instructionPrefix: '',
    normalize: 'l2',
    pooling: 'mean',
    maxFileBytes: 262144,
    filesPerRequest: 50,
    comparePerRequest: 100,
    maxIndexChunks: 20000,
  );

  /// 从 `settings.list` 的 values 段（key → {value,...}）与本机环境变量合成。
  factory DedupConfig.fromValues(
    Map<String, Object?> values, {
    Map<String, String> environment = const <String, String>{},
  }) {
    final DedupConfig fallback = defaults;
    Object? raw(String key) {
      final Object? item = values[key];
      if (item is Map) return item['value'];
      return item;
    }

    String text(String key, String envKey, String def) {
      final Object? fromSettings = raw(key);
      if (fromSettings is String && fromSettings.trim().isNotEmpty) {
        return fromSettings.trim();
      }
      final String fromEnv = (environment[envKey] ?? '').trim();
      return fromEnv.isEmpty ? def : fromEnv;
    }

    int integer(String key, String envKey, int def, int min, int max) {
      final Object? fromSettings = raw(key);
      final int parsed = fromSettings is num
          ? fromSettings.toInt()
          : int.tryParse('${fromSettings ?? ''}') ??
                int.tryParse(environment[envKey] ?? '') ??
                def;
      return parsed < min ? min : (parsed > max ? max : parsed);
    }

    double decimal(String key, String envKey, double def, double min, double max) {
      final Object? fromSettings = raw(key);
      final double parsed = fromSettings is num
          ? fromSettings.toDouble()
          : double.tryParse('${fromSettings ?? ''}') ??
                double.tryParse(environment[envKey] ?? '') ??
                def;
      return parsed < min ? min : (parsed > max ? max : parsed);
    }

    bool boolean(String key, String envKey, bool def) {
      final Object? fromSettings = raw(key);
      if (fromSettings is bool) return fromSettings;
      final String text = '${fromSettings ?? environment[envKey] ?? ''}'
          .trim()
          .toLowerCase();
      if (text == 'true' || text == '1') return true;
      if (text == 'false' || text == '0') return false;
      return def;
    }

    String choice(String key, String envKey, List<String> allowed, String def) {
      final String value = text(key, envKey, def).toLowerCase();
      return allowed.contains(value) ? value : def;
    }

    return DedupConfig(
      enabled: boolean('dedup_enabled', 'TREE_PL_DEDUP_ENABLED', fallback.enabled),
      model: text('dedup_model', 'TREE_PL_DEDUP_MODEL', fallback.model),
      threshold: decimal(
        'dedup_similarity_threshold',
        'TREE_PL_DEDUP_THRESHOLD',
        fallback.threshold,
        0.5,
        0.99,
      ),
      topK: integer(
        'dedup_top_k',
        'TREE_PL_DEDUP_TOP_K',
        fallback.topK,
        1,
        20,
      ),
      embedBatch: integer(
        'dedup_embed_batch',
        'TREE_PL_DEDUP_EMBED_BATCH',
        fallback.embedBatch,
        1,
        64,
      ),
      instructionPrefix: text(
        'dedup_instruction_prefix',
        'TREE_PL_DEDUP_INSTRUCTION_PREFIX',
        fallback.instructionPrefix,
      ),
      normalize: choice(
        'dedup_normalize',
        'TREE_PL_DEDUP_NORMALIZE',
        const <String>['l2', 'none'],
        fallback.normalize,
      ),
      pooling: choice(
        'dedup_pooling',
        'TREE_PL_DEDUP_POOLING',
        const <String>['mean', 'cls'],
        fallback.pooling,
      ),
      maxFileBytes: integer(
        'dedup_max_file_bytes',
        'TREE_PL_DEDUP_MAX_FILE_BYTES',
        fallback.maxFileBytes,
        1024,
        8 * 1024 * 1024,
      ),
      filesPerRequest: integer(
        'dedup_files_per_request',
        'TREE_PL_DEDUP_FILES_PER_REQUEST',
        fallback.filesPerRequest,
        1,
        500,
      ),
      comparePerRequest: integer(
        'dedup_compare_per_request',
        'TREE_PL_DEDUP_COMPARE_PER_REQUEST',
        fallback.comparePerRequest,
        1,
        500,
      ),
      maxIndexChunks: integer(
        'dedup_max_index_chunks',
        'TREE_PL_DEDUP_MAX_INDEX_CHUNKS',
        fallback.maxIndexChunks,
        100,
        100000,
      ),
    );
  }

  /// 影响向量的设置哈希（阈值 / top-k 只影响比对，不进这里）。
  String get embedSettingsHash => fnv1aHex(
    jsonEncode(<String, Object?>{
      'pipeline': kDedupPipelineVersion,
      'chunker': kChunkerVersion,
      'model': model,
      'prefix': instructionPrefix,
      'normalize': normalize,
      'pooling': pooling,
      'seed': kDedupSeed,
    }),
  );

  /// 内容寻址向量键：chunk 全字节哈希 + 全部影响向量的参数。
  String vecKeyOf({
    required String contentHash,
    required String model,
    required int dimensions,
  }) => 'vec-${fnv1aHex('$contentHash\n$embedSettingsHash\n$model\n$dimensions')}';

  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    'model': model,
    'threshold': threshold,
    'top_k': topK,
    'embed_batch': embedBatch,
    'instruction_prefix': instructionPrefix,
    'normalize': normalize,
    'pooling': pooling,
    'max_file_bytes': maxFileBytes,
    'files_per_request': filesPerRequest,
    'compare_per_request': comparePerRequest,
    'max_index_chunks': maxIndexChunks,
    'seed': kDedupSeed,
    'pipeline_version': kDedupPipelineVersion,
    'chunker_version': kChunkerVersion,
  };
}
