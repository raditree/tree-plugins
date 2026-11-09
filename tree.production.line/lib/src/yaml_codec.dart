/// 极小 YAML 发射器：只覆盖 `line.yaml` / `task.yaml` 的固定形状。
///
/// 为什么自己写：仓里依赖的 `yaml` 包只解析、不发射，为这几张固定表再引一个编码器
/// 不值。标量统一走 JSON 双引号（JSON 标量是合法 YAML），数字 / 布尔 / null 原样；
/// 输出顺序 = 输入 Map 顺序，所以同一份数据重复写盘字节不变（可直接 diff）。
library;

import 'dart:convert';

import 'models.dart';

String encodeYaml(Object? value) {
  final StringBuffer out = StringBuffer();
  final Map<String, Object?> map = plainMap(value);
  _writeMap(out, map, 0);
  return out.toString();
}

void _writeMap(StringBuffer out, Map<String, Object?> map, int indent) {
  final String pad = ' ' * indent;
  for (final MapEntry<String, Object?> entry in map.entries) {
    final String key = _key(entry.key);
    final Object? value = entry.value;
    if (value is Map) {
      final Map<String, Object?> child = plainMap(value);
      if (child.isEmpty) {
        out.writeln('$pad$key: {}');
      } else {
        out.writeln('$pad$key:');
        _writeMap(out, child, indent + 2);
      }
      continue;
    }
    if (value is List) {
      final List<Object?> list = plainValue(value) as List<Object?>;
      if (list.isEmpty) {
        out.writeln('$pad$key: []');
      } else {
        out.writeln('$pad$key:');
        _writeList(out, list, indent + 2);
      }
      continue;
    }
    out.writeln('$pad$key: ${_scalar(value)}');
  }
}

void _writeList(StringBuffer out, List<Object?> list, int indent) {
  final String pad = ' ' * indent;
  for (final Object? item in list) {
    if (item is Map || item is List) {
      // 复合项走 JSON flow（YAML 1.2 是 JSON 的超集），P1 的两张固定表不需要块状嵌套。
      out.writeln('$pad- ${json.encode(plainValue(item))}');
      continue;
    }
    out.writeln('$pad- ${_scalar(item)}');
  }
}

String _key(String key) {
  if (RegExp(r'^[A-Za-z_][A-Za-z0-9_-]*$').hasMatch(key)) return key;
  return json.encode(key);
}

String _scalar(Object? value) {
  if (value == null) return 'null';
  if (value is bool || value is num) return value.toString();
  return json.encode(value.toString());
}
