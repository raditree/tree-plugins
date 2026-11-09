import 'package:test/test.dart';
import 'package:tree_docnorm/tree_docnorm.dart';

/// DN-10 BM25：中英混排分词与排序。
void main() {
  test('分词：英文词 + 中文单字与双字', () {
    final List<String> tokens = tokenize('SSE 流式协议');
    expect(tokens, containsAll(<String>['sse']));
    expect(tokens, containsAll(<String>['流', '式', '协议', '流式']));
  });

  test('BM25：命中文档得分更高，且按分数排序', () {
    final Bm25Index index = Bm25Index.build(<Bm25Document>[
      const Bm25Document(id: 'a', text: '网关负责分层与路由'),
      const Bm25Document(id: 'b', text: 'SSE 流式接口'),
      const Bm25Document(id: 'c', text: '限流与回滚配置'),
    ]);
    final Map<String, double> scores = index.score('网关 分层');
    expect(scores['a'], greaterThan(0));
    expect(scores['b'] ?? 0, 0);
    expect(scores['a']!, greaterThan(scores['c'] ?? 0));
  });

  test('空查询 ⇒ 空分数', () {
    final Bm25Index index = Bm25Index.build(<Bm25Document>[
      const Bm25Document(id: 'a', text: '网关'),
    ]);
    expect(index.score('   '), isEmpty);
  });
}
