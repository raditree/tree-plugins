import 'package:test/test.dart';
import 'package:tree_docnorm/tree_docnorm.dart';

/// DN-9 分块：标题切 section、段落合并 600~1 200、稳定 id。
void main() {
  test('标题切 section，heading 是标题路径', () {
    final List<DocChunk> chunks = chunkDocument(
      'docs/a.md',
      '# A\n\n第一段。\n\n## B\n\n第二段。\n\n### C\n\n第三段。\n',
    );
    expect(chunks.map((DocChunk c) => c.heading), <String>[
      'A',
      'A / B',
      'A / B / C',
    ]);
    expect(chunks.map((DocChunk c) => c.text), <String>[
      '第一段。',
      '第二段。',
      '第三段。',
    ]);
    expect(chunks.map((DocChunk c) => c.ordinal), <int>[0, 1, 2]);
  });

  test('短段落合并到 600~1 200；不产生超长块', () {
    final String paragraph = 'x' * 300;
    final String content = <String>[
      '# A',
      for (int i = 0; i < 6; i++) paragraph,
    ].join('\n\n');
    final List<DocChunk> chunks = chunkDocument('a.md', content);
    expect(chunks.length, 2, reason: '6 × 300 字符按 1 200 上限切成两块');
    for (final DocChunk chunk in chunks) {
      expect(chunk.text.length, lessThanOrEqualTo(1200));
      expect(chunk.text.length, greaterThanOrEqualTo(600));
    }
  });

  test('超长段落按行 / 字符硬切，不丢内容', () {
    final String longLine = 'y' * 3000;
    final List<DocChunk> chunks = chunkDocument('a.md', '# A\n\n$longLine\n');
    expect(chunks.length, 3);
    for (final DocChunk chunk in chunks) {
      expect(chunk.text.length, lessThanOrEqualTo(1200));
    }
    expect(chunks.map((DocChunk chunk) => chunk.text).join(), longLine);
  });

  test('代码围栏里的 # 与空行不切段', () {
    const String content = '# A\n\n```dart\n# 不是标题\n\ncode();\n```\n';
    final List<DocChunk> chunks = chunkDocument('a.md', content);
    expect(chunks.length, 1);
    expect(chunks.first.heading, 'A');
    expect(chunks.first.text, contains('# 不是标题'));
    expect(chunks.first.text, contains('code();'));
  });

  test('同内容重复出现时 id 加序号；重复运行 id 稳定', () {
    const String content = '# A\n\n同一段。\n\n# A\n\n同一段。\n';
    final List<DocChunk> first = chunkDocument('a.md', content);
    final List<DocChunk> second = chunkDocument('a.md', content);
    expect(
      first.map((DocChunk c) => c.id).toList(),
      second.map((DocChunk c) => c.id).toList(),
    );
    expect(first.length, 2);
    expect(first.first.id, isNot(first.last.id));
    expect(first.last.id, endsWith('-2'));
  });

  test('只改一节时其它节 id 不变（内容寻址）', () {
    final List<DocChunk> before = chunkDocument(
      'a.md',
      '# A\n\n第一节。\n\n# B\n\n第二节。\n',
    );
    final List<DocChunk> after = chunkDocument(
      'a.md',
      '# A\n\n第一节。\n\n# B\n\n第二节（改）。\n',
    );
    expect(after.first.id, before.first.id);
    expect(after.last.id, isNot(before.last.id));
  });
}
