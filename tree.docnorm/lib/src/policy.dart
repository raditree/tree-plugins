import 'dart:convert';

import 'package:yaml/yaml.dart';

import 'scan.dart';

/// 建议 / 收束阈值的内置默认（D31：可被仓库策略覆盖，引擎不硬编码）。
const Map<String, int> kDefaultThresholds = <String, int>{
  'package_lines': 5000,
  'file_lines': 1000,
  'api_count': 20,
  'declaration_count': 60,
  'subpackage_count': 12,
  'one_liner_chars': 60,
  'min_one_liner_chars': 8,
  'query_k': 10,
  'query_local_hop': 2,
  'query_global_reports': 8,
};

/// 规则读取 / 合并失败：稳定 [code] + 人话 [message]。
class PolicyFailure implements Exception {
  PolicyFailure(this.message, {this.code = 'invalid_policy'});

  final String message;
  final String code;

  @override
  String toString() => message;
}

/// 文档集合口径：哪些 Markdown 参与链接与章节侦查。
class DocSetRule {
  const DocSetRule({
    this.entries = const <String>[
      'README.md',
      'CONTRIBUTING.md',
      'CHANGELOG.md',
    ],
    this.roots = const <String>['docs', 'lib', 'packages', 'examples'],
    this.readmeOnly = true,
  });

  /// 仓库根的入口文档（存在才纳入）。
  final List<String> entries;

  /// 递归扫描的目录；[readmeOnly] 为 true 时只收 README.md，`docs` 例外收全部。
  final List<String> roots;

  final bool readmeOnly;

  Map<String, Object?> toJson() => <String, Object?>{
    'entries': entries,
    'roots': roots,
    'readme_only': readmeOnly,
  };
}

/// 必需章节：按**原文子串**匹配（与仓库门禁同口径，大小写敏感）。
class SectionRule {
  const SectionRule({required this.glob, required this.sections});

  final String glob;
  final List<String> sections;

  Map<String, Object?> toJson() => <String, Object?>{
    'glob': glob,
    'sections': sections,
  };
}

/// 索引完整性：目录下每个直接子文件都必须被索引文件提到。
class IndexRule {
  const IndexRule({
    required this.dir,
    required this.index,
    this.skipIndex = true,
  });

  final String dir;
  final String index;

  /// 索引文件本身不要求自我提及（如 `docs/README.md`）。
  final bool skipIndex;

  Map<String, Object?> toJson() => <String, Object?>{
    'dir': dir,
    'index': index,
    'skip_index': skipIndex,
  };
}

/// 模块 README：`src` 下每个目录都要有 README（含必需章节）并进索引。
class ModuleReadmeRule {
  const ModuleReadmeRule({
    required this.src,
    required this.index,
    required this.indexKey,
    this.sections = const <String>[],
  });

  final String src;
  final String index;

  /// 索引里应出现的关键字，`{name}` 替换为模块目录名。
  final String indexKey;
  final List<String> sections;

  Map<String, Object?> toJson() => <String, Object?>{
    'src': src,
    'index': index,
    'index_key': indexKey,
    'sections': sections,
  };
}

/// 点名校验：文档里必须出现的真实符号（改提示词/资产要能一眼定位）。
class MentionRule {
  const MentionRule({required this.doc, required this.symbols});

  final String doc;
  final List<String> symbols;

  Map<String, Object?> toJson() => <String, Object?>{
    'doc': doc,
    'symbols': symbols,
  };
}

/// 历史文档指向迁移前家的链接：只要 fallback 根下还在，就认可它有出处。
class LinkFallback {
  const LinkFallback({required this.prefixes, required this.root});

  final List<String> prefixes;
  final String root;

  Map<String, Object?> toJson() => <String, Object?>{
    'prefixes': prefixes,
    'root': root,
  };
}

/// 三层规则合成结果：默认值 + 仓库自述（+ 规则包接口，暂未实现）。
class DocPolicy {
  DocPolicy({
    required this.requiredDocs,
    required this.requiredSections,
    required this.indexes,
    required this.moduleReadmes,
    required this.mentions,
    required this.docSet,
    required this.linkFallbacks,
    required this.thresholds,
    required this.layers,
    required this.repoFiles,
    required this.origins,
    required this.overridden,
    required this.warnings,
    required this.unsupported,
  });

  final List<String> requiredDocs;
  final List<SectionRule> requiredSections;
  final List<IndexRule> indexes;
  final List<ModuleReadmeRule> moduleReadmes;
  final List<MentionRule> mentions;
  final DocSetRule docSet;
  final List<LinkFallback> linkFallbacks;

  /// 建议 / 收束阈值（D31）：体积、单文件、API 数、声明数、子包数与一句话长度。
  final Map<String, int> thresholds;

  /// 生效的规则层，按优先级从低到高（`builtin` → `repo`）。
  final List<String> layers;

  /// 被读入的仓库自述文件（相对路径）。
  final List<String> repoFiles;

  /// 每个规则键的最终来源：`builtin` / `repo`。
  final Map<String, String> origins;

  /// 被更高层覆盖掉的内置键。
  final List<String> overridden;

  /// 不阻断但必须可见的问题（未知键、空列表等）。
  final List<String> warnings;

  /// 明确未实现的能力（不静默）。
  final List<String> unsupported;

  Map<String, Object?> toJson() => <String, Object?>{
    'layers': layers,
    'repo_files': repoFiles,
    'origins': origins,
    'overridden': overridden,
    'rules_package': null,
    'unsupported': unsupported,
    'warnings': warnings,
    'required_docs': requiredDocs,
    'required_sections': requiredSections
        .map((SectionRule r) => r.toJson())
        .toList(),
    'indexes': indexes.map((IndexRule r) => r.toJson()).toList(),
    'module_readmes': moduleReadmes
        .map((ModuleReadmeRule r) => r.toJson())
        .toList(),
    'mentions': mentions.map((MentionRule r) => r.toJson()).toList(),
    'doc_set': docSet.toJson(),
    'link_fallbacks': linkFallbacks
        .map((LinkFallback r) => r.toJson())
        .toList(),
    'thresholds': thresholds,
  };

  /// 三层规则源：内置空仓默认 → 仓库自述 → 规则包（pin+sha256，本期未实现）。
  ///
  /// 规则包被显式传入时 **fail-closed**（[PolicyFailure]），不联网、不静默降级（D30）。
  static DocPolicy resolve(
    RepoIndex index, {
    Map<String, Object?>? rulesPackage,
  }) {
    if (rulesPackage != null && rulesPackage.isNotEmpty) {
      throw PolicyFailure(
        '规则包（pin+sha256）本期未实现：拒绝未 pin 的规则源，见 D30',
        code: 'rules_package_unsupported',
      );
    }
    final List<String> warnings = <String>[];
    final List<String> unsupported = <String>[
      'rules_package：远端规则包（pin commit + sha256、默认禁网）按 D30 留接口，本期未实现',
    ];
    final Map<String, String> origins = <String, String>{
      'required_docs': 'builtin',
      'required_sections': 'builtin',
      'indexes': 'builtin',
      'module_readmes': 'builtin',
      'mentions': 'builtin',
      'doc_set': 'builtin',
      'link_fallbacks': 'builtin',
      'thresholds': 'builtin',
    };
    final List<String> overridden = <String>[];
    final List<String> repoFiles = <String>[];

    // 内置空仓默认：只有放之四海皆准的 README 与入口文档扫描口径。
    List<String> requiredDocs = <String>['README.md'];
    List<SectionRule> sections = const <SectionRule>[];
    List<IndexRule> indexes = const <IndexRule>[];
    List<ModuleReadmeRule> modules = const <ModuleReadmeRule>[];
    List<MentionRule> mentions = const <MentionRule>[];
    DocSetRule docSet = const DocSetRule();
    List<LinkFallback> fallbacks = const <LinkFallback>[];
    Map<String, int> thresholds = Map<String, int>.of(kDefaultThresholds);

    for (final String candidate in const <String>[
      'docnorm.yaml',
      'docnorm.yml',
      '.docnorm/policy.yaml',
      '.docnorm/policy.yml',
    ]) {
      RepoFile? file;
      for (final RepoFile item in index.files) {
        if (item.path.toLowerCase() == candidate) {
          file = item;
          break;
        }
      }
      if (file == null) continue;
      final RepoFile policyFile = file;
      final Map<String, Object?> raw = _decode(policyFile, warnings);
      repoFiles.add(policyFile.path);
      final Map<String, Object?> rules = _asMap(
        raw['rules'] ?? raw,
        '${policyFile.path}: rules',
      );
      // 允许用一层 `rules:` 包住，方便与运行时配置同文件；键不存在就不覆盖。
      for (final MapEntry<String, Object?> entry in rules.entries) {
        final String key = entry.key;
        final Object? value = entry.value;
        switch (key) {
          case 'version':
            break;
          case 'required_docs':
            requiredDocs = _strings(value, '${policyFile.path}: $key');
            _mark(origins, overridden, key);
          case 'required_sections':
            sections = _maps(value, '${policyFile.path}: $key')
                .map(
                  (Map<String, Object?> item) => SectionRule(
                    glob: _string(
                      item['glob'],
                      '${policyFile.path}: $key.glob',
                    ),
                    sections: _strings(
                      item['sections'],
                      '${policyFile.path}: $key.sections',
                    ),
                  ),
                )
                .toList();
            _mark(origins, overridden, key);
          case 'indexes':
            indexes = _maps(value, '${policyFile.path}: $key')
                .map(
                  (Map<String, Object?> item) => IndexRule(
                    dir: _string(item['dir'], '${policyFile.path}: $key.dir'),
                    index: _string(
                      item['index'],
                      '${policyFile.path}: $key.index',
                    ),
                    skipIndex: item['skip_index'] as bool? ?? true,
                  ),
                )
                .toList();
            _mark(origins, overridden, key);
          case 'module_readmes':
            modules = _maps(value, '${policyFile.path}: $key')
                .map(
                  (Map<String, Object?> item) => ModuleReadmeRule(
                    src: _string(item['src'], '${policyFile.path}: $key.src'),
                    index: _string(
                      item['index'],
                      '${policyFile.path}: $key.index',
                    ),
                    indexKey: _string(
                      item['index_key'],
                      '${policyFile.path}: $key.index_key',
                    ),
                    sections: item['sections'] == null
                        ? const <String>[]
                        : _strings(
                            item['sections'],
                            '${policyFile.path}: $key.sections',
                          ),
                  ),
                )
                .toList();
            _mark(origins, overridden, key);
          case 'mentions':
            mentions = _maps(value, '${policyFile.path}: $key')
                .map(
                  (Map<String, Object?> item) => MentionRule(
                    doc: _string(item['doc'], '${policyFile.path}: $key.doc'),
                    symbols: _strings(
                      item['symbols'],
                      '${policyFile.path}: $key.symbols',
                    ),
                  ),
                )
                .toList();
            _mark(origins, overridden, key);
          case 'doc_set':
            final Map<String, Object?> set = _asMap(
              value,
              '${policyFile.path}: $key',
            );
            docSet = DocSetRule(
              entries: set['entries'] == null
                  ? docSet.entries
                  : _strings(
                      set['entries'],
                      '${policyFile.path}: $key.entries',
                    ),
              roots: set['roots'] == null
                  ? docSet.roots
                  : _strings(set['roots'], '${policyFile.path}: $key.roots'),
              readmeOnly: set['readme_only'] as bool? ?? docSet.readmeOnly,
            );
            _mark(origins, overridden, key);
          case 'thresholds':
            thresholds = _intMap(
              value,
              '${policyFile.path}: $key',
              thresholds,
              warnings,
            );
            _mark(origins, overridden, key);
          case 'link_fallbacks':
            fallbacks = _maps(value, '${policyFile.path}: $key')
                .map(
                  (Map<String, Object?> item) => LinkFallback(
                    prefixes: _strings(
                      item['prefixes'],
                      '${policyFile.path}: $key.prefixes',
                    ),
                    root: _string(
                      item['root'],
                      '${policyFile.path}: $key.root',
                    ),
                  ),
                )
                .toList();
            _mark(origins, overridden, key);
          default:
            warnings.add('${policyFile.path} 含未知规则键：$key（已忽略）');
        }
      }
    }

    return DocPolicy(
      requiredDocs: requiredDocs,
      requiredSections: sections,
      indexes: indexes,
      moduleReadmes: modules,
      mentions: mentions,
      docSet: docSet,
      linkFallbacks: fallbacks,
      thresholds: thresholds,
      layers: <String>['builtin', if (repoFiles.isNotEmpty) 'repo'],
      repoFiles: repoFiles,
      origins: origins,
      overridden: overridden,
      warnings: warnings,
      unsupported: unsupported,
    );
  }

  static void _mark(
    Map<String, String> origins,
    List<String> overridden,
    String key,
  ) {
    if (origins[key] == 'builtin' && !overridden.contains(key)) {
      overridden.add(key);
    }
    origins[key] = 'repo';
  }

  static Map<String, Object?> _decode(RepoFile file, List<String> warnings) {
    try {
      final Object? raw = file.name.toLowerCase().endsWith('.json')
          ? jsonDecode(file.content)
          : loadYaml(file.content);
      if (raw is Map) return _asMap(raw, file.path);
      warnings.add('${file.path} 不是映射（object），已忽略');
    } catch (error) {
      warnings.add('${file.path} 解析失败：$error');
    }
    return <String, Object?>{};
  }

  static String _string(Object? value, String field) {
    if (value is String && value.trim().isNotEmpty) return value.trim();
    throw PolicyFailure('$field 必须是非空字符串');
  }

  static List<String> _strings(Object? value, String field) {
    if (value is String && value.trim().isNotEmpty) {
      return <String>[value.trim()];
    }
    if (value is Iterable) {
      final List<String> out = <String>[];
      for (final Object? item in value) {
        if (item is! String || item.trim().isEmpty) {
          throw PolicyFailure('$field 的每一项都必须是非空字符串');
        }
        out.add(item.trim());
      }
      return out;
    }
    throw PolicyFailure('$field 必须是字符串数组');
  }

  static List<Map<String, Object?>> _maps(Object? value, String field) {
    if (value is! Iterable) throw PolicyFailure('$field 必须是对象数组');
    return value.map((Object? item) {
      if (item is! Map) throw PolicyFailure('$field 的每一项必须是对象');
      return _asMap(item, field);
    }).toList();
  }

  /// 阈值覆盖：只接受已知键的正整数；未知键进 warning（不阻断、不静默吞掉）。
  static Map<String, int> _intMap(
    Object? value,
    String field,
    Map<String, int> base,
    List<String> warnings,
  ) {
    if (value is! Map) throw PolicyFailure('$field 必须是对象');
    final Map<String, int> out = Map<String, int>.of(base);
    for (final MapEntry<Object?, Object?> entry in value.entries) {
      final String key = entry.key.toString().trim();
      if (!kDefaultThresholds.containsKey(key)) {
        warnings.add('$field 含未知阈值键：$key（已忽略）');
        continue;
      }
      final Object? raw = entry.value;
      final int? parsed = raw is num
          ? raw.toInt()
          : int.tryParse(raw.toString().trim());
      if (parsed == null || parsed <= 0) {
        throw PolicyFailure('$field.$key 必须是正整数：$raw');
      }
      out[key] = parsed;
    }
    return out;
  }

  static Map<String, Object?> _asMap(Object? value, String field) {
    if (value is! Map) throw PolicyFailure('$field 必须是对象');
    return value.map(
      (Object? key, Object? item) =>
          MapEntry<String, Object?>(key.toString(), item),
    );
  }
}

/// 简易 glob：`*` 不跨 `/`，`**` 跨目录；只用于路径规则。
RegExp globToRegExp(String glob) {
  final StringBuffer out = StringBuffer('^');
  for (int i = 0; i < glob.length; i++) {
    final String ch = glob[i];
    if (ch == '*') {
      if (i + 1 < glob.length && glob[i + 1] == '*') {
        out.write('.*');
        i++;
      } else {
        out.write('[^/]*');
      }
      continue;
    }
    if (r'\^$.|?+()[]{}'.contains(ch)) {
      out.write('\\$ch');
      continue;
    }
    out.write(ch);
  }
  out.write(r'$');
  return RegExp(out.toString());
}
