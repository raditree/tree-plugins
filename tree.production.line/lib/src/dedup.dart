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
  final Float64List vector;
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
List<DedupMatch> topMatches({
  required String selfId,
  required String selfPath,
  required String selfHash,
  required Float64List vector,
  required List<DedupCandidate> candidates,
  required int k,
  required double threshold,
  required int maxIndex,
}) {
  final List<DedupMatch> matches = <DedupMatch>[];
  int scanned = 0;
  for (final DedupCandidate candidate in candidates) {
    if (candidate.id == selfId) continue;
    if (scanned >= maxIndex) break;
    scanned += 1;
    final double score = cosineSimilarity(vector, candidate.vector);
    if (score < threshold) continue;
    matches.add(
      DedupMatch(
        id: candidate.id,
        path: candidate.path,
        scope: candidate.scope,
        score: score,
        exact: candidate.hash == selfHash,
      ),
    );
  }
  matches.sort((DedupMatch a, DedupMatch b) {
    final int byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    return a.id.compareTo(b.id);
  });
  return matches.length <= k ? matches : matches.sublist(0, k);
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
