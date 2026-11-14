/// 逻辑去重的纯领域：归一化、余弦、top-k、阈值判重。
///
/// 全部确定性：分数相同时按 chunk id 升序；固定 seed=42 只用于流程可复现
/// （本实现没有随机采样，seed 记录在缓存键与结果里）。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// L2 归一化；零向量原样返回。
Float64List normalizeVector(List<double> values) {
  double sum = 0;
  for (final double value in values) {
    sum += value * value;
  }
  if (sum <= 0) return Float64List.fromList(values);
  final double scale = 1 / math.sqrt(sum);
  final Float64List out = Float64List(values.length);
  for (int i = 0; i < values.length; i++) {
    out[i] = values[i] * scale;
  }
  return out;
}

/// 归一化并降为 Float32：索引常驻内存时体积减半，点积仍是逐元素乘加。
Float32List normalizeToFloat32(List<double> values) {
  double sum = 0;
  for (final double value in values) {
    sum += value * value;
  }
  if (sum <= 0) return Float32List(values.length);
  final double scale = 1 / math.sqrt(sum);
  final Float32List out = Float32List(values.length);
  for (int i = 0; i < values.length; i++) {
    out[i] = values[i] * scale;
  }
  return out;
}

/// 归一化向量的点积 = 余弦相似度（不再重复算两边范数）。
double dotProduct(Float32List a, Float32List b) {
  if (a.isEmpty || a.length != b.length) return 0;
  double dot = 0;
  for (int i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
  }
  return dot;
}

/// 余弦相似度（两边都应已归一化；这里仍做一次范数保护）。
double cosineSimilarity(Float64List a, Float64List b) {
  if (a.isEmpty || b.isEmpty || a.length != b.length) return 0;
  double dot = 0;
  double na = 0;
  double nb = 0;
  for (int i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na <= 0 || nb <= 0) return 0;
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

/// 索引里的一个候选块。
class DedupCandidate {
  const DedupCandidate({
    required this.id,
    required this.path,
    required this.scope,
    required this.hash,
    required this.vector,
  });

  final String id;
  final String path;
  final String scope;
  final String hash;

  /// 已 L2 归一化的 Float32 向量：点积即余弦。
  final Float32List vector;
}

/// 命中一条。
class DedupMatch {
  const DedupMatch({
    required this.id,
    required this.path,
    required this.scope,
    required this.score,
    required this.exact,
  });

  final String id;
  final String path;
  final String scope;
  final double score;
  final bool exact;

  Map<String, Object?> toJson() => <String, Object?>{
    'chunk_id': id,
    'path': path,
    'scope': scope,
    'score': double.parse(score.toStringAsFixed(6)),
    'exact': exact,
  };
}

/// 对一个源块做全库 top-k；`selfId` 不参与。
///
/// 优化点：
/// - 向量在入索引时已归一化，这里只做点积（原来每对都重算两边范数）；
/// - 内容哈希相同直接记 1.0，不再算向量；
/// - 用长度 ≤ k 的有序表增量维护，避免收集全部命中再整体排序；
/// - 排序口径不变：分数降序，同分按 chunk id 升序。
List<DedupMatch> topMatches({
  required String selfId,
  required String selfPath,
  required String selfHash,
  required Float32List vector,
  required List<DedupCandidate> candidates,
  required int k,
  required double threshold,
}) {
  if (k <= 0) return const <DedupMatch>[];
  final List<DedupMatch> matches = <DedupMatch>[];
  for (final DedupCandidate candidate in candidates) {
    if (candidate.id == selfId) continue;
    final bool exact = candidate.hash == selfHash;
    final double score = exact ? 1.0 : dotProduct(vector, candidate.vector);
    if (score < threshold) continue;
    _offerMatch(
      matches,
      DedupMatch(
        id: candidate.id,
        path: candidate.path,
        scope: candidate.scope,
        score: score,
        exact: exact,
      ),
      k,
    );
  }
  return matches;
}

/// 增量维护 top-k：先按“分数降序、id 升序”找插入位，插完裁掉尾部。
void _offerMatch(List<DedupMatch> top, DedupMatch match, int k) {
  int at = 0;
  while (at < top.length && !_better(match, top[at])) {
    at += 1;
  }
  if (at >= k) return;
  top.insert(at, match);
  if (top.length > k) top.removeLast();
}

bool _better(DedupMatch a, DedupMatch b) {
  if (a.score != b.score) return a.score > b.score;
  return a.id.compareTo(b.id) < 0;
}


/// 从已落盘的 per-chunk 结果里汇总 top pairs（status 用，确定性排序）。
List<Map<String, Object?>> topPairs(
  List<Map<String, Object?>> results, {
  int limit = 50,
}) {
  final Map<String, Map<String, Object?>> pairs = <String, Map<String, Object?>>{};
  for (final Map<String, Object?> result in results) {
    final String fromId = '${result['id'] ?? ''}';
    final String fromPath = '${result['path'] ?? ''}';
    final String fromScope = '${result['scope'] ?? ''}';
    final List<Object?> matches =
        (result['matches'] as List<Object?>? ?? const <Object?>[]);
    for (final Object? raw in matches) {
      if (raw is! Map) continue;
      final String toId = '${raw['chunk_id'] ?? ''}';
      if (toId.isEmpty) continue;
      final List<String> ends = <String>[fromId, toId]..sort();
      final String key = '${ends[0]}|${ends[1]}';
      pairs.putIfAbsent(
        key,
        () => <String, Object?>{
          'a': <String, Object?>{
            'chunk_id': fromId,
            'path': fromPath,
            'scope': fromScope,
          },
          'b': <String, Object?>{
            'chunk_id': toId,
            'path': '${raw['path'] ?? ''}',
            'scope': '${raw['scope'] ?? ''}',
          },
          'score': raw['score'],
          'exact': raw['exact'] == true,
        },
      );
    }
  }
  final List<Map<String, Object?>> out = pairs.values.toList()
    ..sort((Map<String, Object?> a, Map<String, Object?> b) {
      final double sa = (a['score'] as num?)?.toDouble() ?? 0;
      final double sb = (b['score'] as num?)?.toDouble() ?? 0;
      final int byScore = sb.compareTo(sa);
      if (byScore != 0) return byScore;
      return '${a['a']}'.compareTo('${b['a']}');
    });
  return out.length <= limit ? out : out.sublist(0, limit);
}
