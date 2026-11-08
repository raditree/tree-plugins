import 'dart:math' as math;

import 'plan.dart';
import 'scan.dart';

/// 包功能收束的事实（D19/§4.3）：一句话功能 + 唯一入口 + 边界 + 质量。
///
/// 全部由 README 章节确定性解析得出，**不调 LLM、不改写文档**；质量只报告。
class PackageSummary {
  const PackageSummary({
    required this.oneLiner,
    required this.entry,
    required this.boundaries,
    required this.quality,
    required this.lines,
    required this.maxFileLines,
    required this.declarationCount,
    required this.subpackageCount,
    required this.readme,
  });

  final String oneLiner;
  final String entry;
  final List<String> boundaries;

  /// `ok` / `empty` / `thin` / `suspect`（空 / 过短或不全 / 超长）。
  final String quality;
  final int lines;
  final int maxFileLines;
  final int declarationCount;
  final int subpackageCount;
  final String? readme;

  Map<String, Object?> toJson() => <String, Object?>{
    'one_liner': oneLiner,
    'entry': entry,
    'boundaries': boundaries,
    'quality': quality,
    'lines': lines,
    'max_file_lines': maxFileLines,
    'declaration_count': declarationCount,
    'subpackage_count': subpackageCount,
    'readme': readme,
  };
}

/// 参与体积度量的源码文件：排除测试、文档与清单 / 配置（D13）。
List<RepoFile> packageSourceFiles(RepoIndex index, String root) =>
    unitSourceFiles(index, root)
        .where(
          (RepoFile file) =>
              !isTestPath(file.path) && !_isManifest(file.path),
        )
        .toList();

const Set<String> _manifestNames = <String>{
  'pubspec.yaml',
  'pubspec.lock',
  'package.json',
  'package-lock.json',
  'tsconfig.json',
  'composer.json',
  'pyproject.toml',
  'requirements.txt',
  'go.mod',
  'go.sum',
  'cargo.toml',
  'cargo.lock',
  'pom.xml',
  'build.gradle',
  'settings.gradle',
  'cmakelists.txt',
  'openapi.yaml',
  'openapi.yml',
  'openapi.json',
};

/// 清单 / 配置 / API 描述不算源码体积（D13：只算源码目录追踪文件）。
bool _isManifest(String path) {
  final String lower = path.toLowerCase();
  final String name = lower.split('/').last;
  if (_manifestNames.contains(name)) return true;
  return lower.endsWith('.yaml') ||
      lower.endsWith('.yml') ||
      lower.endsWith('.toml') ||
      lower.endsWith('.http');
}

/// 从一个包解析收束事实；阈值来自仓库策略（D31），缺键时调用方给兜底。
PackageSummary summarizePackage(
  RepoIndex index,
  PackageUnit unit,
  Map<String, int> thresholds,
) {
  final List<RepoFile> files = packageSourceFiles(index, unit.root);
  int lines = 0;
  int maxFileLines = 0;
  for (final RepoFile file in files) {
    lines += file.lines;
    maxFileLines = math.max(maxFileLines, file.lines);
  }
  final RepoFile? readme = unitReadme(index, unit.root);
  final List<_Section> sections = readme == null
      ? const <_Section>[]
      : _parseSections(readme.content);

  final String oneLiner = _firstLine(
    _bodyOf(sections, const <String>['职责', '功能', '定位']),
  );
  final String entry = _firstLine(
    _bodyOf(sections, const <String>['入口', '使用', '快速开始']),
  );
  final List<String> boundaries = _listItems(
    _bodyOf(sections, const <String>['边界', '约束', '不变量']),
  );

  final int oneLinerChars = thresholds['one_liner_chars'] ?? 60;
  final int minOneLiner = thresholds['min_one_liner_chars'] ?? 8;
  String quality;
  if (readme == null || oneLiner.isEmpty) {
    quality = 'empty';
  } else if (oneLiner.length < minOneLiner ||
      entry.isEmpty ||
      boundaries.isEmpty) {
    quality = 'thin';
  } else if (oneLiner.length > oneLinerChars) {
    quality = 'suspect';
  } else {
    quality = 'ok';
  }

  return PackageSummary(
    oneLiner: oneLiner,
    entry: entry,
    boundaries: boundaries,
    quality: quality,
    lines: lines,
    maxFileLines: maxFileLines,
    declarationCount: unit.exports.length,
    subpackageCount: unit.subpackages.length,
    readme: readme?.path,
  );
}

class _Section {
  const _Section(this.level, this.title, this.body);

  final int level;
  final String title;
  final String body;
}

/// Markdown 章节：标题行到「同级或更高级标题」之前的正文。
///
/// 嵌套标题也要各自成为章节（`# 包` 下的 `## 职责` 不能被父级吞掉）。
List<_Section> _parseSections(String content) {
  final List<String> lines = content.split('\n');
  final RegExp heading = RegExp(r'^(#{1,6})\s+(.*)$');
  final List<_Heading> headings = <_Heading>[];
  for (int index = 0; index < lines.length; index++) {
    final RegExpMatch? match = heading.firstMatch(lines[index]);
    if (match == null) continue;
    headings.add(
      _Heading(index, match.group(1)!.length, match.group(2)!.trim()),
    );
  }
  final List<_Section> out = <_Section>[];
  for (int i = 0; i < headings.length; i++) {
    final _Heading current = headings[i];
    int end = lines.length;
    for (int j = i + 1; j < headings.length; j++) {
      if (headings[j].level <= current.level) {
        end = headings[j].line;
        break;
      }
    }
    out.add(
      _Section(
        current.level,
        current.title,
        lines.sublist(current.line + 1, end).join('\n'),
      ),
    );
  }
  return out;
}

class _Heading {
  const _Heading(this.line, this.level, this.title);

  final int line;
  final int level;
  final String title;
}

String _bodyOf(List<_Section> sections, List<String> keywords) {
  for (final _Section section in sections) {
    if (keywords.any((String keyword) => section.title.contains(keyword))) {
      return section.body;
    }
  }
  return '';
}

String _firstLine(String body) {
  for (final String raw in body.split('\n')) {
    final String cleaned = _cleanInline(raw);
    if (cleaned.isEmpty || cleaned.startsWith('<!--')) continue;
    return cleaned;
  }
  return '';
}

List<String> _listItems(String body) {
  final List<String> out = <String>[];
  for (final String raw in body.split('\n')) {
    final String cleaned = _cleanInline(raw);
    if (cleaned.isEmpty || cleaned.startsWith('<!--')) continue;
    if (!out.contains(cleaned)) out.add(cleaned);
    if (out.length >= 20) break;
  }
  return out;
}

/// 去掉列表 / 引用 / 代码围栏标记，保留可读文本。
String _cleanInline(String raw) {
  String text = raw.trim();
  text = text.replaceFirst(RegExp(r'^(?:[-*+]\s+|\d+\.\s+|>\s*)'), '').trim();
  text = text.replaceFirst(RegExp(r'^`+'), '').replaceFirst(RegExp(r'`+$'), '');
  return text.trim();
}
