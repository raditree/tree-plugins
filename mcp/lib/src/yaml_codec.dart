import 'package:yaml/yaml.dart';

/// 配置文件的 YAML 编解码（从 tree.agent 的 `store/yaml_codec.dart` 平移）。
///
/// 为什么引第三方依赖：`config/mcp.yaml` 是给用户**直接手改**的入口，
/// 读取侧必须接受任意合法 YAML（flow 风格、引号风格、块标量…）。写入侧
/// 自己实现，保证键顺序稳定、文件头注释可读、路径/命令不会被引号规则洗坏。
abstract final class YamlCodec {
  /// 解析 YAML 文本为普通 Map/List（递归去掉 `YamlMap`/`YamlList` 包装）。
  ///
  /// 顶层必须是映射，否则抛 [FormatException]（配置写错时宁可大声失败，
  /// 也不要静默当成空配置）。
  static Map<String, dynamic> decode(String source) {
    final Object? document = loadYaml(source);
    if (document == null) return <String, dynamic>{};
    final Object? plain = normalize(document);
    if (plain is! Map) {
      throw const FormatException('配置文件的顶层必须是 key: value 映射');
    }
    return plain.cast<String, dynamic>();
  }

  /// 递归把 YamlMap/YamlList 转成 `Map<String,dynamic>`/`List<dynamic>`。
  static Object? normalize(Object? value) {
    if (value is Map) {
      final Map<String, dynamic> out = <String, dynamic>{};
      value.forEach((Object? key, Object? item) {
        out['$key'] = normalize(item);
      });
      return out;
    }
    if (value is List) {
      return value.map<Object?>(normalize).toList();
    }
    return value;
  }

  /// 编码为 YAML 文本；[header] 会作为文件头注释写入。
  static String encode(Map<String, dynamic> data, {String? header}) {
    final StringBuffer out = StringBuffer();
    if (header != null && header.trim().isNotEmpty) {
      for (final String line in header.split('\n')) {
        out.writeln(line.startsWith('#') ? line : '# $line');
      }
      out.writeln();
    }
    if (data.isEmpty) {
      out.writeln('{}');
      return out.toString();
    }
    _writeMap(out, data, 0);
    return out.toString();
  }

  static void _writeMap(
    StringBuffer out,
    Map<String, dynamic> map,
    int indent,
  ) {
    final String pad = ' ' * indent;
    map.forEach((String key, Object? value) {
      final String name = _key(key);
      if (value is Map) {
        if (value.isEmpty) {
          out.writeln('$pad$name: {}');
        } else {
          out.writeln('$pad$name:');
          _writeMap(out, value.cast<String, dynamic>(), indent + 2);
        }
      } else if (value is List) {
        if (value.isEmpty) {
          out.writeln('$pad$name: []');
        } else {
          out.writeln('$pad$name:');
          for (final Object? item in value) {
            _writeListItem(out, item, indent + 2);
          }
        }
      } else if (value is String && value.contains('\n')) {
        _writeBlockScalar(out, '$pad$name:', value, indent);
      } else {
        out.writeln('$pad$name: ${_scalar(value)}');
      }
    });
  }

  static void _writeListItem(StringBuffer out, Object? item, int indent) {
    final String pad = ' ' * indent;
    if (item is Map) {
      if (item.isEmpty) {
        out.writeln('$pad- {}');
        return;
      }
      out.writeln('$pad-');
      _writeMap(out, item.cast<String, dynamic>(), indent + 2);
      return;
    }
    if (item is List) {
      out.writeln('$pad-');
      for (final Object? nested in item) {
        _writeListItem(out, nested, indent + 2);
      }
      return;
    }
    if (item is String && item.contains('\n')) {
      _writeBlockScalar(out, '$pad-', item, indent);
      return;
    }
    out.writeln('$pad- ${_scalar(item)}');
  }

  /// 多行字符串写成块标量：结尾有换行用 `|`，否则用 `|-`。
  static void _writeBlockScalar(
    StringBuffer out,
    String prefix,
    String value,
    int indent,
  ) {
    final String normalized = value
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '');
    final bool trailingNewline = normalized.endsWith('\n');
    final String body = trailingNewline
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    out.writeln('$prefix ${trailingNewline ? '|' : '|-'}');
    final String pad = ' ' * (indent + 2);
    for (final String line in body.split('\n')) {
      out.writeln(line.isEmpty ? '' : '$pad$line');
    }
  }

  static String _key(String key) {
    if (RegExp(r'^[A-Za-z_][A-Za-z0-9_-]*$').hasMatch(key)) return key;
    return _quote(key);
  }

  static String _scalar(Object? value) {
    if (value == null) return 'null';
    if (value is bool) return value ? 'true' : 'false';
    if (value is num) return '$value';
    if (value is String) return _quote(value);
    return _quote('$value');
  }

  /// 只有"绝对安全"的字符串才裸写，其余一律双引号。
  ///
  /// 特别注意**看起来像数字/布尔值的字符串**（如 `"123"` / `"on"`）
  /// 必须加引号，否则重新解析会变成 int/bool，往返不一致。
  static String _quote(String value) {
    if (value.isEmpty) return '""';
    final bool looksPlain =
        RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_./@+-]*$').hasMatch(value) &&
        num.tryParse(value) == null &&
        !_reservedWords.contains(value.toLowerCase());
    if (looksPlain) return value;
    final String escaped = value
        .replaceAll('\\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n')
        .replaceAll('\t', r'\t')
        .replaceAll('\r', '');
    return '"$escaped"';
  }

  /// YAML 1.1 里会被解析成非字符串的裸词。
  static const Set<String> _reservedWords = <String>{
    'true',
    'false',
    'yes',
    'no',
    'on',
    'off',
    'null',
    '~',
  };
}
