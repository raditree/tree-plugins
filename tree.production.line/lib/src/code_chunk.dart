/// 逻辑去重的函数级分块（DN-dedup）。
///
/// 口径：
/// - 只处理代码文本；按扩展名识别语言，Vue 只切 `<script>`；
/// - 函数边界用「行级声明正则 + 字符状态机」找闭合，不引入 `analyzer`；
/// - 找不到可靠闭合的文件整体 fallback 为 `(file)` 块，宁可粗不可碎；
/// - chunk id = `ch-<fnv(path + scope + 内容哈希)>`，不含行号，行号漂移不换 id。
library;

import 'dart:convert';

/// 分块算法版本：语义变更时递增，缓存键随之失效。
const int kChunkerVersion = 1;

/// 单个函数块。
class CodeChunk {
  const CodeChunk({
    required this.path,
    required this.scope,
    required this.signature,
    required this.startLine,
    required this.endLine,
    required this.text,
  });

  final String path;
  final String scope;
  final String signature;
  final int startLine;
  final int endLine;
  final String text;

  String get hash => fnv1aHex(text);

  String get id => 'ch-${fnv1aHex('$path\n$scope\n$hash')}';

  Map<String, Object?> toJson(String repoKey) => <String, Object?>{
    'schema': 1,
    'repo': repoKey,
    'id': id,
    'path': path,
    'scope': scope,
    'signature': signature,
    'start_line': startLine,
    'end_line': endLine,
    'hash': hash,
    'chars': text.length,
    'text': text,
    'chunker_version': kChunkerVersion,
  };
}

/// 分一块文件；[maxChars] 超出时按行窗口切分（`scope#n`）。
List<CodeChunk> chunkFile(
  String path,
  String content, {
  int maxChars = 6000,
  int minChars = 60,
}) {
  final String text = content.replaceAll('\r\n', '\n');
  if (text.trim().isEmpty) return <CodeChunk>[];
  final String language = _languageOf(path);
  final List<String> lines = text.split('\n');
  List<CodeChunk> chunks = <CodeChunk>[];
  if (language == 'vue') {
    chunks = _chunkVue(path, lines, maxChars: maxChars, minChars: minChars);
  } else if (language == 'python') {
    chunks = _chunkPython(path, lines, maxChars: maxChars, minChars: minChars);
  } else if (language == 'brace') {
    chunks = _chunkBrace(path, lines, maxChars: maxChars, minChars: minChars);
  }
  if (chunks.isNotEmpty) return chunks;
  return _fileChunks(path, lines, maxChars: maxChars);
}

/// FNV-1a 64 位，取 16 位十六进制（缓存键 / id 共用）。
String fnv1aHex(String text) {
  int hash = 0xcbf29ce484222325;
  for (final int byte in utf8.encode(text)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

String _languageOf(String path) {
  final String lower = path.toLowerCase();
  if (lower.endsWith('.vue')) return 'vue';
  if (lower.endsWith('.py')) return 'python';
  if (lower.endsWith('.dart') ||
      lower.endsWith('.go') ||
      lower.endsWith('.rs') ||
      lower.endsWith('.ts') ||
      lower.endsWith('.tsx') ||
      lower.endsWith('.js') ||
      lower.endsWith('.jsx')) {
    return 'brace';
  }
  return 'other';
}

// ── 大括号语言（Dart / Go / Rust / TS / JS） ─────────────────────────

const Set<String> _notFunctions = <String>{
  'if',
  'for',
  'while',
  'switch',
  'catch',
  'return',
  'new',
  'do',
  'else',
  'try',
  'with',
  'assert',
  'throw',
  'super',
  'this',
};

final RegExp _classLine = RegExp(
  r'^\s*(?:export\s+)?(?:abstract\s+|final\s+|base\s+|sealed\s+|public\s+|private\s+|internal\s+)*'
  r'(?:class|mixin|enum)\s+([A-Za-z_$][\w$]*)',
);
final RegExp _implLine = RegExp(
  r'^\s*(?:pub\s+)?impl(?:<[^>]*>)?\s+(?:[\w:<>, ]+\s+for\s+)?([A-Za-z_$][\w$]*)',
);
final RegExp _namedFunction = RegExp(
  r'^\s*(?:@\w+\s*)*'
  r'(?:export\s+)?(?:default\s+)?(?:public\s+|private\s+|protected\s+|static\s+|final\s+|async\s+|get\s+|set\s+|override\s+)*'
  r'(?:[A-Za-z_$][\w$<>,\[\]\?\. ]*\s+)?'
  r'([A-Za-z_$][\w$]*)\s*\([^;{}]*\)\s*(?:async\s*)?(?:\{|=>)',
);
final RegExp _goFunction = RegExp(
  r'^\s*func\s+(?:\([^)]*\)\s*)?([A-Za-z_$][\w$]*)\s*\([^;{}]*\)',
);
final RegExp _rustFunction = RegExp(
  r'^\s*(?:pub\s+)?(?:async\s+)?(?:const\s+)?(?:unsafe\s+)?fn\s+([A-Za-z_$][\w$]*)\s*[<(]',
);
final RegExp _arrowConst = RegExp(
  r'^\s*(?:export\s+)?const\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*(?:async\s*)?\(',
);

class _OwnerRange {
  const _OwnerRange(this.start, this.end, this.name);

  final int start;
  final int end;
  final String name;
}

List<CodeChunk> _chunkBrace(
  String path,
  List<String> lines, {
  required int maxChars,
  required int minChars,
}) {
  final List<_OwnerRange> owners = <_OwnerRange>[];
  for (int i = 0; i < lines.length; i++) {
    final String line = lines[i];
    final RegExpMatch? cls = _classLine.firstMatch(line);
    final RegExpMatch? impl = _implLine.firstMatch(line);
    final String? name = cls?.group(1) ?? impl?.group(1);
    if (name == null) continue;
    final int? end = _findBraceEnd(lines, i);
    if (end == null) continue;
    owners.add(_OwnerRange(i, end, name));
  }

  final List<CodeChunk> out = <CodeChunk>[];
  int coveredUntil = -1;
  for (int i = 0; i < lines.length; i++) {
    if (i <= coveredUntil) continue;
    final String? name = _functionNameAt(lines[i]);
    if (name == null) continue;
    final int start = i;
    int? end;
    if (lines[i].contains('=>') && !_braceBeforeArrow(lines[i])) {
      end = _findSemicolonEnd(lines, start);
    }
    end ??= _findBraceEnd(lines, start);
    if (end == null) continue;
    coveredUntil = end;
    final String owner = _ownerOf(owners, start);
    final String scope = _joinScope(owner, name);
    _appendChunk(
      out,
      path: path,
      lines: lines,
      start: start,
      end: end,
      scope: scope,
      signature: lines[start].trim(),
      maxChars: maxChars,
      minChars: minChars,
    );
  }
  return out;
}

String? _functionNameAt(String line) {
  final String trimmed = line.trim();
  if (trimmed.isEmpty || trimmed.startsWith('//')) return null;
  final RegExpMatch? go = _goFunction.firstMatch(line);
  if (go != null) return go.group(1);
  final RegExpMatch? rust = _rustFunction.firstMatch(line);
  if (rust != null) return rust.group(1);
  final RegExpMatch? arrow = _arrowConst.firstMatch(line);
  if (arrow != null) return arrow.group(1);
  final RegExpMatch? named = _namedFunction.firstMatch(line);
  if (named == null) return null;
  final String name = named.group(1) ?? '';
  if (name.isEmpty || _notFunctions.contains(name)) return null;
  return name;
}

bool _braceBeforeArrow(String line) {
  final int brace = line.indexOf('{');
  final int arrow = line.indexOf('=>');
  return brace >= 0 && arrow >= 0 && brace < arrow;
}

String _ownerOf(List<_OwnerRange> owners, int line) {
  String owner = '';
  int bestLength = -1;
  for (final _OwnerRange range in owners) {
    if (line <= range.start || line > range.end) continue;
    final int length = range.end - range.start;
    if (length > bestLength) {
      bestLength = length;
      owner = range.name;
    }
  }
  return owner;
}

String _joinScope(String owner, String name) {
  final String scope = owner.isEmpty ? name : '$owner.$name';
  return scope.length <= 120 ? scope : scope.substring(0, 120);
}

/// 从 [startLine] 起找成对 `{...}` 的结束行；失败返回 null。
int? _findBraceEnd(List<String> lines, int startLine) {
  int depth = 0;
  bool seen = false;
  _LexState state = _LexState.normal;
  int blockCommentDepth = 0;
  for (int i = startLine; i < lines.length; i++) {
    final String line = lines[i];
    for (int j = 0; j < line.length; j++) {
      final String c = line[j];
      final String next = j + 1 < line.length ? line[j + 1] : '';
      switch (state) {
        case _LexState.lineComment:
          j = line.length;
        case _LexState.blockComment:
          if (c == '/' && next == '*') {
            blockCommentDepth += 1;
            j += 1;
          } else if (c == '*' && next == '/') {
            blockCommentDepth -= 1;
            j += 1;
            if (blockCommentDepth <= 0) state = _LexState.normal;
          }
        case _LexState.singleQuote:
          if (c == r'\') {
            j += 1;
          } else if (c == "'") {
            state = _LexState.normal;
          }
        case _LexState.doubleQuote:
          if (c == r'\') {
            j += 1;
          } else if (c == '"') {
            state = _LexState.normal;
          }
        case _LexState.backtick:
          if (c == r'\') {
            j += 1;
          } else if (c == '`') {
            state = _LexState.normal;
          }
        case _LexState.normal:
          if (c == '/' && next == '/') {
            state = _LexState.lineComment;
            j += 1;
          } else if (c == '/' && next == '*') {
            state = _LexState.blockComment;
            blockCommentDepth = 1;
            j += 1;
          } else if (c == "'") {
            state = _LexState.singleQuote;
          } else if (c == '"') {
            state = _LexState.doubleQuote;
          } else if (c == '`') {
            state = _LexState.backtick;
          } else if (c == '{') {
            depth += 1;
            seen = true;
          } else if (c == '}') {
            depth -= 1;
            if (seen && depth <= 0) return i;
          }
      }
    }
    if (state == _LexState.lineComment) state = _LexState.normal;
  }
  return null;
}

/// 表达式体 `=> expr;`：从 [startLine] 找深度 0 的 `;`。
int? _findSemicolonEnd(List<String> lines, int startLine) {
  int depth = 0;
  for (int i = startLine; i < lines.length; i++) {
    final String line = lines[i];
    bool inSingle = false;
    bool inDouble = false;
    bool inBacktick = false;
    for (int j = 0; j < line.length; j++) {
      final String c = line[j];
      if (inSingle) {
        if (c == r'\') {
          j += 1;
        } else if (c == "'") {
          inSingle = false;
        }
        continue;
      }
      if (inDouble) {
        if (c == r'\') {
          j += 1;
        } else if (c == '"') {
          inDouble = false;
        }
        continue;
      }
      if (inBacktick) {
        if (c == r'\') {
          j += 1;
        } else if (c == '`') {
          inBacktick = false;
        }
        continue;
      }
      if (c == "'") {
        inSingle = true;
      } else if (c == '"') {
        inDouble = true;
      } else if (c == '`') {
        inBacktick = true;
      } else if (c == '{' || c == '(' || c == '[') {
        depth += 1;
      } else if (c == '}' || c == ')' || c == ']') {
        depth -= 1;
      } else if (c == ';' && depth <= 0) {
        return i;
      }
    }
  }
  return null;
}

// ── Python（缩进） ──────────────────────────────────────────────────

final RegExp _pyDef = RegExp(r'^(\s*)(?:async\s+)?def\s+([A-Za-z_$][\w$]*)\s*\(');
final RegExp _pyClass = RegExp(r'^(\s*)class\s+([A-Za-z_$][\w$]*)');

List<CodeChunk> _chunkPython(
  String path,
  List<String> lines, {
  required int maxChars,
  required int minChars,
}) {
  final List<CodeChunk> out = <CodeChunk>[];
  final List<(int, String)> classes = <(int, String)>[];
  int i = 0;
  while (i < lines.length) {
    final RegExpMatch? cls = _pyClass.firstMatch(lines[i]);
    if (cls != null) {
      classes.add((cls.group(1)!.length, cls.group(2)!));
      i += 1;
      continue;
    }
    final RegExpMatch? def = _pyDef.firstMatch(lines[i]);
    if (def == null) {
      i += 1;
      continue;
    }
    final int indent = def.group(1)!.length;
    final String name = def.group(2)!;
    int end = i + 1;
    while (end < lines.length) {
      final String line = lines[end];
      if (line.trim().isEmpty) {
        end += 1;
        continue;
      }
      if (line.trimLeft().startsWith('#')) {
        end += 1;
        continue;
      }
      final int currentIndent = line.length - line.trimLeft().length;
      if (currentIndent <= indent) break;
      end += 1;
    }
    if (end > i + 1) end -= 1;
    while (end > i && lines[end].trim().isEmpty) {
      end -= 1;
    }
    final String owner = _pyOwner(classes, indent);
    final String scope = _joinScope(owner, name);
    _appendChunk(
      out,
      path: path,
      lines: lines,
      start: i,
      end: end,
      scope: scope,
      signature: lines[i].trim(),
      maxChars: maxChars,
      minChars: minChars,
    );
    i = end + 1;
  }
  return out;
}

String _pyOwner(List<(int, String)> classes, int indent) {
  String owner = '';
  for (final (int classIndent, String name) in classes) {
    if (classIndent < indent) owner = name;
  }
  return owner;
}

// ── Vue（只切 <script>） ────────────────────────────────────────────

final RegExp _scriptStart = RegExp(r'<script[^>]*>', caseSensitive: false);
final RegExp _scriptEnd = RegExp(r'</script>', caseSensitive: false);

List<CodeChunk> _chunkVue(
  String path,
  List<String> lines, {
  required int maxChars,
  required int minChars,
}) {
  final List<CodeChunk> out = <CodeChunk>[];
  int i = 0;
  while (i < lines.length) {
    final RegExpMatch? start = _scriptStart.firstMatch(lines[i]);
    if (start == null) {
      i += 1;
      continue;
    }
    int end = i + 1;
    while (end < lines.length && !_scriptEnd.hasMatch(lines[end])) {
      end += 1;
    }
    if (end <= i + 1) {
      i = end + 1;
      continue;
    }
    final List<String> slice = lines.sublist(i + 1, end);
    final List<CodeChunk> inner = _chunkBrace(
      path,
      slice,
      maxChars: maxChars,
      minChars: minChars,
    );
    for (final CodeChunk chunk in inner) {
      out.add(
        CodeChunk(
          path: path,
          scope: chunk.scope,
          signature: chunk.signature,
          startLine: chunk.startLine + i + 1,
          endLine: chunk.endLine + i + 1,
          text: chunk.text,
        ),
      );
    }
    i = end + 1;
  }
  return out;
}

// ── 公共 ────────────────────────────────────────────────────────────

void _appendChunk(
  List<CodeChunk> out, {
  required String path,
  required List<String> lines,
  required int start,
  required int end,
  required String scope,
  required String signature,
  required int maxChars,
  required int minChars,
}) {
  final String text = lines.sublist(start, end + 1).join('\n').trimRight();
  if (text.trim().length < minChars) return;
  if (text.length <= maxChars) {
    out.add(
      CodeChunk(
        path: path,
        scope: scope,
        signature: _clip(signature, 200),
        startLine: start + 1,
        endLine: end + 1,
        text: text,
      ),
    );
    return;
  }
  final List<String> block = lines.sublist(start, end + 1);
  int index = 0;
  int part = 1;
  while (index < block.length) {
    final StringBuffer buffer = StringBuffer();
    int length = 0;
    int cursor = index;
    while (cursor < block.length) {
      final String line = block[cursor];
      final int extra = length == 0 ? line.length : line.length + 1;
      if (length > 0 && length + extra > maxChars) break;
      if (length > 0) buffer.write('\n');
      buffer.write(line);
      length += extra;
      cursor += 1;
    }
    if (cursor == index) cursor += 1;
    final String partText = buffer.toString().trimRight();
    if (partText.trim().length >= minChars) {
      out.add(
        CodeChunk(
          path: path,
          scope: '$scope#$part',
          signature: _clip(signature, 200),
          startLine: start + index + 1,
          endLine: start + cursor,
          text: partText,
        ),
      );
      part += 1;
    }
    index = cursor;
  }
}

List<CodeChunk> _fileChunks(
  String path,
  List<String> lines, {
  required int maxChars,
}) {
  final String text = lines.join('\n').trimRight();
  if (text.trim().isEmpty) return <CodeChunk>[];
  if (text.length <= maxChars) {
    return <CodeChunk>[
      CodeChunk(
        path: path,
        scope: '(file)',
        signature: '(file)',
        startLine: 1,
        endLine: lines.length,
        text: text,
      ),
    ];
  }
  final List<CodeChunk> out = <CodeChunk>[];
  int index = 0;
  int part = 1;
  while (index < lines.length) {
    final StringBuffer buffer = StringBuffer();
    int length = 0;
    int cursor = index;
    while (cursor < lines.length) {
      final String line = lines[cursor];
      final int extra = length == 0 ? line.length : line.length + 1;
      if (length > 0 && length + extra > maxChars) break;
      if (length > 0) buffer.write('\n');
      buffer.write(line);
      length += extra;
      cursor += 1;
    }
    if (cursor == index) cursor += 1;
    out.add(
      CodeChunk(
        path: path,
        scope: '(file)#$part',
        signature: '(file)',
        startLine: index + 1,
        endLine: cursor,
        text: buffer.toString().trimRight(),
      ),
    );
    part += 1;
    index = cursor;
  }
  return out;
}

String _clip(String text, int max) =>
    text.length <= max ? text : text.substring(0, max);

enum _LexState { normal, lineComment, blockComment, singleQuote, doubleQuote, backtick }
