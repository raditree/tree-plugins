import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

/// 读一个 YAML 配置文件为纯 Dart Map（键统一成 String，嵌套也递归转换）。
///
/// 与核心 `YamlCodec.decode` 的口径一致：UTF-8 坏字节按 U+FFFD 顶替后解析；
/// 语法错误 / 顶层不是映射 / 读盘失败一律返回 null——调用方各自决定"跳过文件"
/// 还是"当作空配置"（核心对模型文件是跳过、对 agent 文件是当不存在）。
Map<String, dynamic>? readYamlMap(File file) {
  if (!file.existsSync()) return null;
  try {
    final String text = utf8.decode(
      file.readAsBytesSync(),
      allowMalformed: true,
    );
    final Object? raw = loadYaml(text);
    if (raw is! Map) return null;
    return plainMap(raw);
  } catch (_) {
    return null;
  }
}

/// 把 YAML 值转成纯 Dart 值（Map 键转 String，List 递归）。
Map<String, dynamic> plainMap(Object raw) {
  final Map<String, dynamic> out = <String, dynamic>{};
  for (final MapEntry<Object?, Object?> entry in (raw as Map).entries) {
    out[entry.key.toString()] = plainValue(entry.value);
  }
  return out;
}

/// 同 [plainMap]，但接受任意值（非 Map 原样返回）。
Object? plainValue(Object? value) {
  if (value is Map) return plainMap(value);
  if (value is List) return <Object?>[for (final Object? item in value) plainValue(item)];
  return value;
}
