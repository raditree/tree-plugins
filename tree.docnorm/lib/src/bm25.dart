import 'dart:math' as math;

/// 自写 BM25（DN-10）：确定性、无三方依赖，供 `docnorm.query` 的 lexical 面使用。
///
/// 分词口径（中英混排）：
/// - 拉丁字母 / 数字 / 下划线按 `[a-z0-9_]{2,}` 切词；
/// - CJK 连续片段同时产出**单字**与**相邻双字**（中文查询常见 2 字词）；
/// - 其余标点与空白只作分隔符。
class Bm25Document {
  const Bm25Document({required this.id, required this.text});

  final String id;
  final String text;
}

class Bm25Index {
  Bm25Index._({
    required this.ids,
    required this._termFreq,
    required this._docLengths,
    required this._idf,
    required this._averageLength,
  });

  static const double k1 = 1.2;
  static const double b = 0.75;

  final List<String> ids;
  final Map<String, Map<String, int>> _termFreq;
  final Map<String, int> _docLengths;
  final Map<String, double> _idf;
  final double _averageLength;

  bool get isEmpty => ids.isEmpty;
  int get size => ids.length;

  factory Bm25Index.build(Iterable<Bm25Document> documents) {
    final List<Bm25Document> list = documents.toList();
    final Map<String, Map<String, int>> termFreq = <String, Map<String, int>>{};
    final Map<String, int> docLengths = <String, int>{};
    final Map<String, int> documentFreq = <String, int>{};
    for (final Bm25Document doc in list) {
      final List<String> tokens = tokenize(doc.text);
      final Map<String, int> frequencies = <String, int>{};
      for (final String token in tokens) {
        frequencies[token] = (frequencies[token] ?? 0) + 1;
      }
      termFreq[doc.id] = frequencies;
      docLengths[doc.id] = tokens.length;
      for (final String token in frequencies.keys) {
        documentFreq[token] = (documentFreq[token] ?? 0) + 1;
      }
    }
    final int total = list.length;
    final Map<String, double> idf = <String, double>{
      for (final MapEntry<String, int> entry in documentFreq.entries)
        entry.key: math.log(
          1 + (total - entry.value + 0.5) / (entry.value + 0.5),
        ),
    };
    final int totalLength = docLengths.values.fold<int>(
      0,
      (int sum, int value) => sum + value,
    );
    return Bm25Index._(
      ids: <String>[for (final Bm25Document doc in list) doc.id],
      termFreq: termFreq,
      docLengths: docLengths,
      idf: idf,
      averageLength: total == 0 || totalLength == 0 ? 0 : totalLength / total,
    );
  }

  /// 返回原始 BM25 分数（未归一化）；调用方自行归一化 / 融合。
  Map<String, double> score(String query) {
    final List<String> tokens = tokenize(query);
    if (tokens.isEmpty || ids.isEmpty) return <String, double>{};
    final Map<String, int> queryFreq = <String, int>{};
    for (final String token in tokens) {
      queryFreq[token] = (queryFreq[token] ?? 0) + 1;
    }
    final Map<String, double> out = <String, double>{};
    for (final String id in ids) {
      final Map<String, int> frequencies =
          _termFreq[id] ?? const <String, int>{};
      final int length = _docLengths[id] ?? 0;
      double score = 0;
      for (final MapEntry<String, int> entry in queryFreq.entries) {
        final int frequency = frequencies[entry.key] ?? 0;
        if (frequency == 0) continue;
        final double idf = _idf[entry.key] ?? 0;
        final double denominator =
            frequency +
            k1 *
                (1 -
                    b +
                    b * (length / (_averageLength == 0 ? 1 : _averageLength)));
        score += idf * (frequency * (k1 + 1)) / denominator * entry.value;
      }
      if (score > 0) out[id] = score;
    }
    return out;
  }
}

/// 中英混排分词（导出给实体链接与测试复用）。
List<String> tokenize(String text) {
  final String lower = text.toLowerCase();
  final List<String> tokens = <String>[];
  for (final RegExpMatch match in _latin.allMatches(lower)) {
    final String token = match.group(0) ?? '';
    if (token.length >= 2) tokens.add(token);
  }
  final StringBuffer cjk = StringBuffer();
  for (final int rune in lower.runes) {
    if (_isCjk(rune)) {
      cjk.writeCharCode(rune);
    } else {
      _emitCjk(cjk.toString(), tokens);
      cjk.clear();
    }
  }
  _emitCjk(cjk.toString(), tokens);
  return tokens;
}

final RegExp _latin = RegExp(r'[a-z0-9_]+');

bool _isCjk(int rune) =>
    (rune >= 0x4E00 && rune <= 0x9FFF) ||
    (rune >= 0x3400 && rune <= 0x4DBF) ||
    (rune >= 0xF900 && rune <= 0xFAFF);

void _emitCjk(String run, List<String> out) {
  if (run.isEmpty) return;
  final List<String> chars = <String>[
    for (final int rune in run.runes) String.fromCharCode(rune),
  ];
  out.addAll(chars);
  for (int i = 0; i + 1 < chars.length; i++) {
    out.add('${chars[i]}${chars[i + 1]}');
  }
}
