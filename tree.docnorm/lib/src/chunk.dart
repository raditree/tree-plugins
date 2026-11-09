import 'dart:convert';

/// 文档分块（DN-9）：Markdown 标题切 section，段落合并到 600~1 200 字符。
///
/// 口径（doc-normalization-recon §4.6）：
/// - 标题（1~6 级）开新 section，`heading` 是标题路径（`A / B / C`）；
/// - 段落按空行切分，代码围栏里的空行不切段；
/// - 合并到 [minChars] 以上、单块不超过 [maxChars]；超长段落按行再按字符硬切；
/// - `id` 以内容寻址（doc + 标题路径 + 正文哈希），同内容重复出现时追加序号；
/// - 分块确定：同一输入重复运行得到同一批 id（增量只算变化 chunk 的基础）。
class DocChunk {
  const DocChunk({
    required this.id,
    required this.doc,
    required this.heading,
    required this.ordinal,
    required this.hash,
    required this.text,
  });

  final String id;
  final String doc;
  final String heading;
  final int ordinal;
  final String hash;
  final String text;

  Map<String, Object?> toJson(String repoKey) => <String, Object?>{
    'schema': 1,
    'repo': repoKey,
    'id': id,
    'doc': doc,
    'heading': heading,
    'ordinal': ordinal,
    'hash': hash,
    'chars': text.length,
    'text': text,
  };
}

/// 单篇文档分块；[startOrdinal] 让多篇文档共用一个单调序号时也能保持稳定。
List<DocChunk> chunkDocument(
  String doc,
  String content, {
  int minChars = 600,
  int maxChars = 1200,
  int startOrdinal = 0,
}) {
  final List<DocChunk> out = <DocChunk>[];
  final Map<String, int> seen = <String, int>{};
  int ordinal = startOrdinal;

  void addChunk(String heading, String rawText) {
    final String text = rawText.trim();
    if (text.isEmpty) return;
    final String hash = fnv1aHex(text);
    final String base = 'chunk-${fnv1aHex('$doc\n$heading\n$hash')}';
    final int occurrence = (seen[base] ?? 0) + 1;
    seen[base] = occurrence;
    final String id = occurrence == 1 ? base : '$base-$occurrence';
    out.add(
      DocChunk(
        id: id,
        doc: doc,
        heading: heading,
        ordinal: ordinal,
        hash: hash,
        text: text,
      ),
    );
    ordinal += 1;
  }

  for (final _Section section in _sections(content)) {
    final List<String> blocks = _blocks(section.lines);
    final StringBuffer current = StringBuffer();
    int currentLength = 0;

    void flush() {
      if (currentLength == 0) return;
      addChunk(section.heading, current.toString());
      current.clear();
      currentLength = 0;
    }

    for (final String block in blocks) {
      if (block.length > maxChars) {
        flush();
        for (final String piece in _hardSplit(block, maxChars)) {
          addChunk(section.heading, piece);
        }
        continue;
      }
      final int extra = currentLength == 0 ? block.length : block.length + 2;
      if (currentLength > 0 && currentLength + extra > maxChars) flush();
      if (currentLength > 0) current.write('\n\n');
      current.write(block);
      currentLength += extra;
    }
    flush();
  }
  return out;
}

/// 多篇文档按路径排序后分块（顺序稳定，便于重复运行 0 写）。
List<DocChunk> chunkDocuments(
  Map<String, String> docs, {
  int minChars = 600,
  int maxChars = 1200,
}) {
  final List<String> paths = docs.keys.toList()..sort();
  final List<DocChunk> out = <DocChunk>[];
  for (final String path in paths) {
    out.addAll(
      chunkDocument(
        path,
        docs[path] ?? '',
        minChars: minChars,
        maxChars: maxChars,
      ),
    );
  }
  return out;
}

class _Section {
  _Section(this.heading, this.lines);

  final String heading;
  final List<String> lines;
}

/// 按标题切 section；代码围栏里的 `#` 不算标题。
List<_Section> _sections(String content) {
  final List<_Section> out = <_Section>[];
  final List<String> stack = <String>[];
  final List<String> current = <String>[];
  String heading = '(root)';
  bool inFence = false;

  void flush() {
    if (current.any((String line) => line.trim().isNotEmpty)) {
      out.add(_Section(heading, List<String>.of(current)));
    }
    current.clear();
  }

  for (final String line in content.split('\n')) {
    final String trimmed = line.trimLeft();
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      inFence = !inFence;
      current.add(line);
      continue;
    }
    final RegExpMatch? match = inFence
        ? null
        : RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(trimmed);
    if (match == null) {
      current.add(line);
      continue;
    }
    flush();
    final int level = match.group(1)!.length;
    while (stack.length >= level) {
      stack.removeLast();
    }
    stack.add(match.group(2)!.trim());
    heading = stack.where((String item) => item.isNotEmpty).join(' / ');
    if (heading.isEmpty) heading = '(root)';
  }
  flush();
  return out;
}

/// 段落切分：空行分段；代码围栏里的空行不切。
List<String> _blocks(List<String> lines) {
  final List<String> out = <String>[];
  final StringBuffer current = StringBuffer();
  bool inFence = false;

  void flush() {
    final String text = current.toString().trim();
    if (text.isNotEmpty) out.add(text);
    current.clear();
  }

  for (final String line in lines) {
    final String trimmed = line.trimLeft();
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      inFence = !inFence;
      current.writeln(line);
      continue;
    }
    if (!inFence && line.trim().isEmpty) {
      flush();
      continue;
    }
    current.writeln(line);
  }
  flush();
  return out;
}

/// 超长块按行切，单行仍超再按字符切；不丢内容。
List<String> _hardSplit(String block, int maxChars) {
  final List<String> out = <String>[];
  final StringBuffer current = StringBuffer();
  int length = 0;

  void flush() {
    if (length == 0) return;
    out.add(current.toString().trim());
    current.clear();
    length = 0;
  }

  for (final String line in block.split('\n')) {
    if (line.length > maxChars) {
      flush();
      for (int start = 0; start < line.length; start += maxChars) {
        final int end = start + maxChars > line.length
            ? line.length
            : start + maxChars;
        out.add(line.substring(start, end));
      }
      continue;
    }
    final int extra = length == 0 ? line.length : line.length + 1;
    if (length > 0 && length + extra > maxChars) flush();
    if (length > 0) current.write('\n');
    current.write(line);
    length += extra;
  }
  flush();
  return out;
}

/// FNV-1a 64 位，取前 12 位十六进制：分块 id / 缓存键共用（确定性、无依赖）。
String fnv1aHex(String text) {
  int hash = 0xcbf29ce484222325;
  for (final int byte in utf8.encode(text)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0').substring(0, 12);
}
