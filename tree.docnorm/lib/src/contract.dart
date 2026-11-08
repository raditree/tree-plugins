import 'dart:io';

import 'package:path/path.dart' as p;

import 'policy.dart';
import 'scan.dart';

/// 一条契约违规（稳定 [kind] + 人话 [detail]）。
class DocViolation {
  const DocViolation({
    required this.kind,
    required this.doc,
    required this.detail,
  });

  final String kind;
  final String doc;
  final String detail;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'doc': doc,
    'detail': detail,
  };
}

/// 一项检查（DocPolicy 四条核心 + 仓库扩展）。
class DocCheck {
  const DocCheck({
    required this.id,
    required this.kind,
    required this.checked,
    required this.violations,
  });

  final String id;

  /// `core` = DocPolicy 四条；`repo` = 仓库自述扩展（模块 README / 点名校验）。
  final String kind;
  final int checked;
  final List<DocViolation> violations;

  bool get ok => violations.isEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind,
    'ok': ok,
    'checked': checked,
    'violations': violations.map((DocViolation item) => item.toJson()).toList(),
  };
}

/// 文档契约侦查结果（L0 事实；确定性、无 LLM、只读）。
class DocContract {
  DocContract({
    required this.repo,
    required this.policy,
    required this.docs,
    required this.sections,
    required this.checks,
    required this.changelog,
    required this.gates,
    required this.unknown,
    required this.degraded,
  });

  final String repo;
  final DocPolicy policy;

  /// 参与契约的文档（仓库相对路径，已排序）。
  final List<String> docs;

  /// 每份文档的 Markdown 标题（含 `#` 前缀），用于后续"按仓库风格写章节"。
  final Map<String, List<String>> sections;

  final List<DocCheck> checks;
  final Map<String, Object?> changelog;
  final Map<String, Object?> gates;
  final List<String> unknown;
  final bool degraded;

  bool get ok => checks.every((DocCheck check) => check.ok);

  List<DocViolation> get violations => <DocViolation>[
    for (final DocCheck check in checks) ...check.violations,
  ];

  Map<String, Object?> toJson() => <String, Object?>{
    'repo': repo,
    'ok': ok,
    'rules': policy.toJson(),
    'docs': <String, Object?>{
      'total': docs.length,
      'files': docs.take(200).toList(),
    },
    'sections': sections,
    'checks': checks.map((DocCheck check) => check.toJson()).toList(),
    'violations': violations.map((DocViolation item) => item.toJson()).toList(),
    'changelog': changelog,
    'gates': gates,
    'unknown': unknown,
    'degraded': degraded,
  };
}

/// 扫描目标仓库并产出文档契约（命令 `docnorm.contract`）。
Future<DocContract> inspectRepository(
  String repo, {
  Map<String, Object?>? rulesPackage,
}) async {
  final RepoIndex index = await RepoIndex.load(repo);
  final DocPolicy policy = DocPolicy.resolve(index, rulesPackage: rulesPackage);
  return inspectIndex(index, policy);
}

/// 从已加载的索引产出契约（便于测试与同一次运行内复用）。
DocContract inspectIndex(RepoIndex index, DocPolicy policy) {
  final List<String> docs = _docSet(index, policy.docSet);
  final Map<String, List<String>> headings = <String, List<String>>{};
  for (final String rel in docs) {
    final RepoFile? file = _fileOf(index, rel);
    if (file == null) continue;
    headings[rel] = _headings(file.content).take(40).toList();
  }

  final List<DocCheck> checks = <DocCheck>[
    _checkRequiredDocs(index, policy),
    _checkSections(index, policy),
    _checkIndexes(index, policy),
    _checkLinks(index, policy, docs),
    _checkModuleReadmes(index, policy),
    _checkMentions(index, policy),
  ];

  final Map<String, Object?> changelog = _changelog(index);
  final Map<String, Object?> gates = _gates(index);

  final List<String> unknown = <String>[
    'commit_style：本期不执行 git（DN-8 探测提交风格）',
    if (docs.isEmpty) 'doc_set：仓内没有可侦查的 Markdown',
    if (changelog['style'] == 'unknown') 'changelog_style：无法识别 CHANGELOG 风格',
  ];

  final bool policyBroken = policy.warnings.any(
    (String line) => line.contains('解析失败'),
  );
  final bool truncated = index.truncated;
  return DocContract(
    repo: index.root,
    policy: policy,
    docs: docs,
    sections: headings,
    checks: checks,
    changelog: changelog,
    gates: gates,
    unknown: unknown,
    degraded: docs.isEmpty || policyBroken || truncated,
  );
}

DocCheck _checkRequiredDocs(RepoIndex index, DocPolicy policy) {
  final List<DocViolation> violations = <DocViolation>[];
  for (final String rel in policy.requiredDocs) {
    if (!_exists(index, rel)) {
      violations.add(
        DocViolation(kind: 'required_docs', doc: rel, detail: '必需文档不存在'),
      );
    }
  }
  return DocCheck(
    id: 'required_docs',
    kind: 'core',
    checked: policy.requiredDocs.length,
    violations: violations,
  );
}

DocCheck _checkSections(RepoIndex index, DocPolicy policy) {
  final List<DocViolation> violations = <DocViolation>[];
  int checked = 0;
  for (final SectionRule rule in policy.requiredSections) {
    final RegExp glob = globToRegExp(rule.glob);
    final List<RepoFile> matched = index.files
        .where((RepoFile file) => glob.hasMatch(file.path))
        .toList();
    if (matched.isEmpty) {
      violations.add(
        DocViolation(
          kind: 'required_sections',
          doc: rule.glob,
          detail: '规则没有匹配到任何文件',
        ),
      );
      continue;
    }
    for (final RepoFile file in matched) {
      checked += 1;
      for (final String marker in rule.sections) {
        if (!file.content.contains(marker)) {
          violations.add(
            DocViolation(
              kind: 'required_sections',
              doc: file.path,
              detail: '缺少必需章节/原文：$marker',
            ),
          );
        }
      }
    }
  }
  return DocCheck(
    id: 'required_sections',
    kind: 'core',
    checked: checked,
    violations: violations,
  );
}

DocCheck _checkIndexes(RepoIndex index, DocPolicy policy) {
  final List<DocViolation> violations = <DocViolation>[];
  int checked = 0;
  for (final IndexRule rule in policy.indexes) {
    final RepoFile? indexFile = _fileOf(index, rule.index);
    if (indexFile == null) {
      violations.add(
        DocViolation(
          kind: 'index_complete',
          doc: rule.index,
          detail: '索引文件不存在（目录：${rule.dir}）',
        ),
      );
      continue;
    }
    final String dir = rule.dir == '.' ? '' : rule.dir;
    final List<RepoFile> children = index.files
        .where(
          (RepoFile file) => (dir.isEmpty
              ? p.posix.dirname(file.path) == '.'
              : p.posix.dirname(file.path) == dir),
        )
        .where(
          (RepoFile file) =>
              !(rule.skipIndex &&
                  p.posix.basename(file.path) == p.posix.basename(rule.index)),
        )
        .toList();
    if (children.isEmpty) {
      violations.add(
        DocViolation(
          kind: 'index_complete',
          doc: rule.dir,
          detail: '目录下没有文档，索引无从校验',
        ),
      );
      continue;
    }
    for (final RepoFile child in children) {
      checked += 1;
      final String name = p.posix.basename(child.path);
      if (!indexFile.content.contains(name)) {
        violations.add(
          DocViolation(
            kind: 'index_complete',
            doc: rule.index,
            detail: '没列出 $name（新增/移动文档要同步索引）',
          ),
        );
      }
    }
  }
  return DocCheck(
    id: 'index_complete',
    kind: 'core',
    checked: checked,
    violations: violations,
  );
}

DocCheck _checkLinks(RepoIndex index, DocPolicy policy, List<String> docs) {
  final List<DocViolation> violations = <DocViolation>[];
  int checked = 0;
  for (final String rel in docs) {
    final RepoFile? file = _fileOf(index, rel);
    if (file == null) continue;
    final String base = p.posix.dirname(rel);
    final String baseDir = base == '.' ? '' : base;
    bool inFence = false;
    for (final String line in file.content.split('\n')) {
      if (line.trimLeft().startsWith('```')) {
        inFence = !inFence;
        continue;
      }
      if (inFence) continue;
      for (final RegExpMatch match in _mdLink.allMatches(line)) {
        String target = match.group(1) ?? '';
        if (target.startsWith('<') ||
            target.startsWith('#') ||
            target.startsWith('mailto:') ||
            target.contains('://')) {
          continue;
        }
        final int hash = target.indexOf('#');
        if (hash >= 0) target = target.substring(0, hash);
        if (target.isEmpty) continue;
        try {
          target = Uri.decodeComponent(target);
        } on FormatException {
          // 裸 `%`：按原文解析，失败照常报出。
        }
        checked += 1;
        final String resolved = resolveLinkPath(baseDir, target);
        if (_exists(index, resolved) ||
            _fallbackExists(index, policy, resolved)) {
          continue;
        }
        violations.add(
          DocViolation(
            kind: 'links_resolvable',
            doc: rel,
            detail: '相对链接指向不存在的路径：${match.group(1)}',
          ),
        );
      }
    }
  }
  return DocCheck(
    id: 'links_resolvable',
    kind: 'core',
    checked: checked,
    violations: violations,
  );
}

DocCheck _checkModuleReadmes(RepoIndex index, DocPolicy policy) {
  final List<DocViolation> violations = <DocViolation>[];
  int checked = 0;
  for (final ModuleReadmeRule rule in policy.moduleReadmes) {
    final String src = rule.src;
    final Set<String> modules = <String>{};
    for (final RepoFile file in index.files) {
      if (!file.path.startsWith('$src/')) continue;
      final String rest = file.path.substring(src.length + 1);
      final List<String> parts = rest.split('/');
      if (parts.length < 2) continue;
      modules.add(parts.first);
    }
    if (modules.isEmpty) {
      violations.add(
        DocViolation(
          kind: 'module_readme',
          doc: rule.src,
          detail: '目录下没有模块，规则无从校验',
        ),
      );
      continue;
    }
    final RepoFile? indexFile = _fileOf(index, rule.index);
    if (indexFile == null) {
      violations.add(
        DocViolation(
          kind: 'module_readme',
          doc: rule.index,
          detail: '模块地图索引不存在',
        ),
      );
      continue;
    }
    for (final String module in modules.toList()..sort()) {
      checked += 1;
      final String readme = '$src/$module/README.md';
      final RepoFile? file = _fileOf(index, readme);
      if (file == null) {
        violations.add(
          DocViolation(
            kind: 'module_readme',
            doc: readme,
            detail: '模块缺 README',
          ),
        );
        continue;
      }
      for (final String marker in rule.sections) {
        if (!file.content.contains(marker)) {
          violations.add(
            DocViolation(
              kind: 'module_readme',
              doc: readme,
              detail: '缺少必需章节/原文：$marker',
            ),
          );
        }
      }
      final String key = rule.indexKey.replaceAll('{name}', module);
      if (!indexFile.content.contains(key)) {
        violations.add(
          DocViolation(
            kind: 'module_readme',
            doc: rule.index,
            detail: '模块地图没列出 $key（新增模块要同步索引）',
          ),
        );
      }
    }
  }
  return DocCheck(
    id: 'module_readme',
    kind: 'repo',
    checked: checked,
    violations: violations,
  );
}

DocCheck _checkMentions(RepoIndex index, DocPolicy policy) {
  final List<DocViolation> violations = <DocViolation>[];
  int checked = 0;
  for (final MentionRule rule in policy.mentions) {
    final RepoFile? file = _fileOf(index, rule.doc);
    if (file == null) {
      violations.add(
        DocViolation(
          kind: 'mentions',
          doc: rule.doc,
          detail: '文档不存在，无法校验点名的符号',
        ),
      );
      continue;
    }
    for (final String symbol in rule.symbols) {
      checked += 1;
      if (!file.content.contains(symbol)) {
        violations.add(
          DocViolation(
            kind: 'mentions',
            doc: rule.doc,
            detail: '缺少对真实符号的点名：$symbol',
          ),
        );
      }
    }
  }
  return DocCheck(
    id: 'mentions',
    kind: 'repo',
    checked: checked,
    violations: violations,
  );
}

Map<String, Object?> _changelog(RepoIndex index) {
  for (final String candidate in const <String>[
    'CHANGELOG.md',
    'CHANGELOG',
    'docs/CHANGELOG.md',
  ]) {
    final RepoFile? file = _fileOf(index, candidate);
    if (file == null) {
      continue;
    }
    String style = 'unknown';
    if (RegExp(r'^##\s*\[', multiLine: true).hasMatch(file.content)) {
      style = 'keep_a_changelog';
    } else if (RegExp(r'^##\s+\S', multiLine: true).hasMatch(file.content)) {
      style = 'headings';
    }
    String latest = '';
    for (final String line in file.content.split('\n')) {
      if (line.startsWith('## ')) {
        latest = line.trim();
        break;
      }
    }
    return <String, Object?>{
      'path': candidate,
      'style': style,
      'latest': latest,
    };
  }
  return <String, Object?>{'path': null, 'style': 'absent', 'latest': ''};
}

/// 静态抽取门禁命令：**只列不跑**（D30）。
Map<String, Object?> _gates(RepoIndex index) {
  const List<String> sources = <String>[
    'CONTRIBUTING.md',
    'AGENTS.md',
    'README.md',
    'docs/development.md',
  ];
  final Set<String> seen = <String>{};
  final List<Map<String, String>> commands = <Map<String, String>>[];
  for (final String rel in sources) {
    final RepoFile? file = _fileOf(index, rel);
    if (file == null) continue;
    for (final String line in file.content.split('\n')) {
      String text = line.trim();
      if (text.startsWith('```') || text.startsWith('>') || text.isEmpty) {
        continue;
      }
      // 去掉行首列表符与行内反引号，只留命令本身。
      text = text.replaceAll(RegExp(r'^[-*]\s+'), '');
      final RegExpMatch? inline = RegExp(r'`([^`]+)`').firstMatch(text);
      if (inline != null) text = inline.group(1)!.trim();
      if (!_looksLikeCommand(text)) continue;
      final String command = text.replaceAll(RegExp(r'[。；;]$'), '').trim();
      if (command.isEmpty || !seen.add(command)) continue;
      commands.add(<String, String>{'command': command, 'source': rel});
      if (commands.length >= 30) break;
    }
    if (commands.length >= 30) break;
  }
  return <String, Object?>{
    'commands': commands,
    'executed': false,
    'note': '门禁命令默认只列不跑；--run-gates 由 DN-8 实现',
  };
}

bool _looksLikeCommand(String text) {
  const List<String> prefixes = <String>[
    'dart ',
    'flutter ',
    'git ',
    'build_plugins',
    'make ',
    'npm ',
    'pnpm ',
    'yarn ',
    'go test',
    'cargo ',
    'pytest',
  ];
  return prefixes.any(text.startsWith);
}

List<String> _docSet(RepoIndex index, DocSetRule rule) {
  final Set<String> out = <String>{};
  for (final String entry in rule.entries) {
    if (_fileOf(index, entry) != null) out.add(entry);
  }
  for (final RepoFile file in index.files) {
    final String lower = file.path.toLowerCase();
    if (!lower.endsWith('.md')) continue;
    for (final String root in rule.roots) {
      if (!file.path.startsWith('$root/')) continue;
      if (root == 'docs' || !rule.readmeOnly) {
        out.add(file.path);
        break;
      }
      if (p.posix.basename(file.path).toLowerCase() == 'readme.md') {
        out.add(file.path);
        break;
      }
    }
  }
  final List<String> sorted = out.toList()..sort();
  return sorted;
}

List<String> _headings(String content) {
  final List<String> out = <String>[];
  bool inFence = false;
  for (final String line in content.split('\n')) {
    if (line.trimLeft().startsWith('```')) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    final RegExpMatch? match = RegExp(r'^(#{1,6})\s+(.+)$').firstMatch(line);
    if (match != null) out.add('${match.group(1)} ${match.group(2)!.trim()}');
  }
  return out;
}

RepoFile? _fileOf(RepoIndex index, String rel) {
  final String wanted = rel.replaceAll('\\', '/');
  for (final RepoFile file in index.files) {
    if (file.path == wanted) return file;
  }
  return null;
}

bool _exists(RepoIndex index, String rel) {
  final String path = rel.replaceAll('\\', '/');
  if (_fileOf(index, path) != null) return true;
  // 空目录 / 非文件目标（链接可能指向目录）需要问文件系统；只读、不出仓。
  if (path.contains('..') || path.startsWith('/')) return false;
  final String full = p.joinAll(<String>[index.root, ...path.split('/')]);
  return File(full).existsSync() || Directory(full).existsSync();
}

bool _fallbackExists(RepoIndex index, DocPolicy policy, String resolved) {
  for (final LinkFallback fallback in policy.linkFallbacks) {
    if (!fallback.prefixes.any(resolved.startsWith)) continue;
    final String rel = '${fallback.root}/$resolved';
    if (_exists(index, rel)) return true;
  }
  return false;
}

final RegExp _mdLink = RegExp(r'\]\(([^)\s]+)\)');

/// 把 [target] 按 [base]（仓库相对目录，可为空）解析成仓库相对路径。
String resolveLinkPath(String base, String target) {
  final List<String> parts = <String>[
    if (base.isNotEmpty) ...base.split('/'),
    ...target.split('/'),
  ];
  final List<String> out = <String>[];
  for (final String part in parts) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(part);
  }
  return out.join('/');
}
