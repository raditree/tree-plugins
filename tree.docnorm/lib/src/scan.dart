import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// 扫描 / 解析失败：稳定 [code] + 人话 [message]。
class ScanFailure implements Exception {
  ScanFailure(this.message, {this.code = 'scan_error'});

  final String message;
  final String code;

  @override
  String toString() => message;
}

/// 仓库里的一份文本文件（只读；过大的文件不载入内容）。
class RepoFile {
  const RepoFile({
    required this.path,
    required this.lines,
    required this.content,
  });

  /// 相对仓库根的路径，统一 `/` 分隔。
  final String path;
  final int lines;
  final String content;

  String get name => p.posix.basename(path);
  String get dir => p.posix.dirname(path);
}

/// 一次扫描的文件索引；跳过构建产物与依赖目录，避免把 node_modules 读穿。
class RepoIndex {
  RepoIndex({
    required this.root,
    required this.files,
    required this.truncated,
    required this.skippedFiles,
  });

  final String root;
  final List<RepoFile> files;
  final bool truncated;
  final int skippedFiles;

  static const Set<String> ignoredDirs = <String>{
    '.git',
    '.dart_tool',
    '.idea',
    '.venv',
    '__pycache__',
    'node_modules',
    'build',
    'dist',
    'target',
    'vendor',
    '.output',
    'coverage',
  };

  static const int maxFiles = 20000;
  static const int maxFileBytes = 2 * 1024 * 1024;
  static const int maxTotalBytes = 64 * 1024 * 1024;

  static Future<RepoIndex> load(String root) async {
    final Directory dir = Directory(root);
    if (!await dir.exists()) {
      throw ScanFailure('仓库目录不存在：$root', code: 'repo_not_found');
    }
    final List<RepoFile> files = <RepoFile>[];
    int skipped = 0;
    int totalBytes = 0;
    bool truncated = false;

    Future<void> walk(Directory current) async {
      if (files.length >= maxFiles) {
        truncated = true;
        return;
      }
      await for (final FileSystemEntity entity in current.list(
        followLinks: false,
      )) {
        if (entity is Directory) {
          if (ignoredDirs.contains(p.basename(entity.path))) continue;
          await walk(entity);
          continue;
        }
        if (entity is! File) continue;
        final String relative = p
            .relative(entity.path, from: root)
            .replaceAll(r'\', '/');
        if (relative.startsWith('..')) continue;
        final int size = await entity.length();
        if (size > maxFileBytes) {
          skipped += 1;
          continue;
        }
        if (totalBytes + size > maxTotalBytes) {
          truncated = true;
          continue;
        }
        String content = '';
        try {
          content = await entity.readAsString();
        } catch (_) {
          skipped += 1;
          continue;
        }
        if (content.contains('\u0000')) {
          skipped += 1;
          continue;
        }
        totalBytes += size;
        files.add(
          RepoFile(
            path: relative,
            lines: content.isEmpty ? 0 : '\n'.allMatches(content).length + 1,
            content: content,
          ),
        );
      }
    }

    await walk(dir);
    files.sort((RepoFile a, RepoFile b) => a.path.compareTo(b.path));
    return RepoIndex(
      root: p.normalize(root),
      files: files,
      truncated: truncated,
      skippedFiles: skipped,
    );
  }

  List<RepoFile> withExtensions(Iterable<String> extensions) {
    final List<String> suffixes = extensions
        .map((String extension) => extension.toLowerCase())
        .toList();
    return files
        .where(
          (RepoFile file) => suffixes.any(
            (String suffix) => file.path.toLowerCase().endsWith(suffix),
          ),
        )
        .toList();
  }

  List<RepoFile> named(Iterable<String> names) {
    final Set<String> wanted = names
        .map((String name) => name.toLowerCase())
        .toSet();
    return files
        .where((RepoFile file) => wanted.contains(file.name.toLowerCase()))
        .toList();
  }
}

/// 子包（按文件数 × 内聚度发现；README 只影响注入模式，不影响发现）。
class SubUnit {
  const SubUnit({
    required this.path,
    required this.fileCount,
    required this.lines,
    required this.hasReadme,
  });

  final String path;
  final int fileCount;
  final int lines;
  final bool hasReadme;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'file_count': fileCount,
    'lines': lines,
    'has_readme': hasReadme,
  };
}

/// 一个 API 端点（Web-HTTP 适配器用；其它语言为 null）。
class ApiEndpoint {
  const ApiEndpoint({
    required this.method,
    required this.path,
    this.source = '',
  });

  final String method;
  final String path;
  final String source;

  Map<String, Object?> toJson() => <String, Object?>{
    'method': method,
    'path': path,
    if (source.isNotEmpty) 'source': source,
  };
}

class ApiSurface {
  const ApiSurface({
    required this.count,
    this.endpoints = const <ApiEndpoint>[],
    this.source = 'declarations',
  });

  final int count;
  final List<ApiEndpoint> endpoints;
  final String source;

  Map<String, Object?> toJson() => <String, Object?>{
    'count': count,
    'source': source,
    if (endpoints.isNotEmpty)
      'endpoints': endpoints.map((ApiEndpoint e) => e.toJson()).toList(),
  };
}

/// 一个包（manifest 所在目录）；`container` 由是否存在子包表达。
class PackageUnit {
  PackageUnit({
    required this.id,
    required this.root,
    required this.language,
    required this.fileCount,
    required this.lines,
    required this.maxFileLines,
    required this.subpackages,
    required this.exports,
    required this.api,
    required this.dependencies,
    required this.degraded,
  });

  final String id;
  final String root;
  final String language;
  final int fileCount;
  final int lines;
  final int maxFileLines;
  final List<SubUnit> subpackages;
  final List<String> exports;
  final ApiSurface api;
  final List<String> dependencies;
  final List<String> dependsOn = <String>[];
  final bool degraded;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'root': root,
    'language': language,
    'file_count': fileCount,
    'lines': lines,
    'max_file_lines': maxFileLines,
    'container': subpackages.isNotEmpty,
    'subpackages': subpackages.map((SubUnit unit) => unit.toJson()).toList(),
    'exports': exports,
    'api': api.toJson(),
    'dependencies': dependencies,
    'depends_on': dependsOn,
    'degraded': degraded,
  };
}

class ScanResult {
  const ScanResult({
    required this.repo,
    required this.packages,
    required this.filesScanned,
    required this.skippedFiles,
    required this.truncated,
    required this.adapters,
    required this.errors,
  });

  final String repo;
  final List<PackageUnit> packages;
  final int filesScanned;
  final int skippedFiles;
  final bool truncated;
  final List<String> adapters;
  final List<String> errors;

  bool get degraded =>
      truncated ||
      errors.isNotEmpty ||
      packages.isEmpty ||
      packages.any((PackageUnit unit) => unit.degraded);

  Map<String, Object?> toJson() => <String, Object?>{
    'repo': repo,
    'files_scanned': filesScanned,
    'skipped_files': skippedFiles,
    'truncated': truncated,
    'degraded': degraded,
    'adapters': adapters,
    'packages': packages.map((PackageUnit unit) => unit.toJson()).toList(),
    if (errors.isNotEmpty) 'errors': errors,
  };
}

/// 语言适配层：DN-2 只做只读扫描；注释/声明/断言/门禁在 DN-3+ 接。
abstract class LanguageAdapter {
  String get id;
  Future<List<PackageUnit>> scan(RepoIndex index);
}

/// 通用 manifest 适配器：包名 / 依赖 / 公开声明正则由各语言配置。
class ManifestAdapter implements LanguageAdapter {
  ManifestAdapter({
    required this.id,
    required this.manifests,
    required this.extensions,
    required this.nameOf,
    required this.dependenciesOf,
    required this.exportPatterns,
    this.exportFilter,
    this.extraExports,
  });

  @override
  final String id;
  final List<String> manifests;
  final List<String> extensions;
  final String Function(RepoFile manifest) nameOf;
  final List<String> Function(RepoFile manifest) dependenciesOf;
  final List<RegExp> exportPatterns;
  final bool Function(String name)? exportFilter;

  /// 语言特有的附加公开面（如 Vue SFC 的 props / emits）。
  final List<String> Function(RepoFile file)? extraExports;

  @override
  Future<List<PackageUnit>> scan(RepoIndex index) async {
    final List<RepoFile> found = index.named(manifests);
    if (found.isEmpty) return <PackageUnit>[];
    final Set<String> roots = found.map((RepoFile file) => file.dir).toSet();
    final List<PackageUnit> out = <PackageUnit>[];
    for (final RepoFile manifest in found) {
      final String root = manifest.dir;
      final List<RepoFile> files = _filesFor(index, root, roots);
      if (files.isEmpty) continue;
      final String name = nameOf(manifest).trim();
      final String idValue = name.isEmpty
          ? (root == '.' ? p.basename(index.root) : p.posix.basename(root))
          : name;
      final Set<String> names = <String>{};
      for (final RepoFile file in files) {
        for (final RegExp pattern in exportPatterns) {
          for (final RegExpMatch match in pattern.allMatches(file.content)) {
            final String nameValue = match.group(1) ?? '';
            if (nameValue.isEmpty) continue;
            if (exportFilter != null && !exportFilter!(nameValue)) continue;
            names.add(nameValue);
          }
        }
        for (final String extra
            in extraExports?.call(file) ?? const <String>[]) {
          if (extra.isNotEmpty) names.add(extra);
        }
      }
      final List<String> exports = names.toList()..sort();
      out.add(
        PackageUnit(
          id: idValue,
          root: root,
          language: id,
          fileCount: files.length,
          lines: files.fold<int>(
            0,
            (int sum, RepoFile file) => sum + file.lines,
          ),
          maxFileLines: files.fold<int>(
            0,
            (int max, RepoFile file) => file.lines > max ? file.lines : max,
          ),
          subpackages: _subpackages(index, root, files),
          exports: exports.take(200).toList(),
          api: ApiSurface(count: exports.length),
          dependencies: dependenciesOf(manifest).take(50).toList(),
          degraded: false,
        ),
      );
    }
    return out;
  }

  List<RepoFile> _filesFor(RepoIndex index, String root, Set<String> roots) {
    final Set<String> nested = roots
        .where((String other) => other != root)
        .toSet();
    return index.files.where((RepoFile file) {
      if (!extensions.any(
        (String ext) => file.path.toLowerCase().endsWith(ext),
      )) {
        return false;
      }
      if (root != '.') {
        if (file.path != root && !file.path.startsWith('$root/')) return false;
      }
      for (final String child in nested) {
        if (child == '.') continue;
        if (child.startsWith(root == '.' ? '' : '$root/') && child != root) {
          if (file.path == child || file.path.startsWith('$child/')) {
            return false;
          }
        }
      }
      return true;
    }).toList();
  }

  List<SubUnit> _subpackages(
    RepoIndex index,
    String root,
    List<RepoFile> files,
  ) {
    final Map<String, List<RepoFile>> groups = <String, List<RepoFile>>{};
    for (final RepoFile file in files) {
      final String relative = root == '.'
          ? file.path
          : (file.path == root
                ? p.posix.basename(file.path)
                : file.path.substring(root.length + 1));
      final List<String> parts = relative.split('/');
      if (parts.length < 2) continue;
      final String group = parts.first;
      if (group == 'test' || group == 'tests') continue;
      groups.putIfAbsent(group, () => <RepoFile>[]).add(file);
    }
    final List<SubUnit> out = <SubUnit>[];
    for (final MapEntry<String, List<RepoFile>> entry in groups.entries) {
      if (entry.value.length < 3) continue;
      final String groupRoot = root == '.' ? entry.key : '$root/${entry.key}';
      final bool hasReadme = index.files.any(
        (RepoFile file) => file.path.toLowerCase().startsWith(
          '${groupRoot.toLowerCase()}/readme',
        ),
      );
      out.add(
        SubUnit(
          path: groupRoot,
          fileCount: entry.value.length,
          lines: entry.value.fold<int>(
            0,
            (int sum, RepoFile file) => sum + file.lines,
          ),
          hasReadme: hasReadme,
        ),
      );
    }
    out.sort((SubUnit a, SubUnit b) => a.path.compareTo(b.path));
    return out;
  }
}

/// Web-HTTP：从 OpenAPI / `.http` 抽端点；不依赖 manifest。
class HttpAdapter implements LanguageAdapter {
  @override
  String get id => 'http';

  @override
  Future<List<PackageUnit>> scan(RepoIndex index) async {
    final List<ApiEndpoint> endpoints = <ApiEndpoint>[];
    final List<RepoFile> sources = <RepoFile>[];
    for (final RepoFile file in index.files) {
      final String lower = file.name.toLowerCase();
      final bool openapi =
          (lower.startsWith('openapi') || lower.startsWith('swagger')) &&
          (lower.endsWith('.json') ||
              lower.endsWith('.yaml') ||
              lower.endsWith('.yml'));
      if (openapi) {
        endpoints.addAll(_openApi(file));
        sources.add(file);
        continue;
      }
      if (lower.endsWith('.http')) {
        endpoints.addAll(_httpFile(file));
        sources.add(file);
      }
    }
    if (endpoints.isEmpty) return <PackageUnit>[];
    final Set<String> unique = <String>{};
    final List<ApiEndpoint> deduped = <ApiEndpoint>[];
    for (final ApiEndpoint endpoint in endpoints) {
      if (unique.add('${endpoint.method} ${endpoint.path}')) {
        deduped.add(endpoint);
      }
    }
    return <PackageUnit>[
      PackageUnit(
        id: 'http',
        root: '.',
        language: id,
        fileCount: sources.length,
        lines: sources.fold<int>(
          0,
          (int sum, RepoFile file) => sum + file.lines,
        ),
        maxFileLines: sources.fold<int>(
          0,
          (int max, RepoFile file) => file.lines > max ? file.lines : max,
        ),
        subpackages: const <SubUnit>[],
        exports: deduped
            .map((ApiEndpoint e) => '${e.method} ${e.path}')
            .take(200)
            .toList(),
        api: ApiSurface(
          count: deduped.length,
          endpoints: deduped,
          source: 'http',
        ),
        dependencies: const <String>[],
        degraded: false,
      ),
    ];
  }

  List<ApiEndpoint> _openApi(RepoFile file) {
    Object? decoded;
    try {
      decoded = file.path.toLowerCase().endsWith('.json')
          ? jsonDecode(file.content)
          : loadYaml(file.content);
    } catch (_) {
      return const <ApiEndpoint>[];
    }
    if (decoded is! Map) return const <ApiEndpoint>[];
    final Object? paths = decoded['paths'];
    if (paths is! Map) return const <ApiEndpoint>[];
    const List<String> methods = <String>[
      'get',
      'post',
      'put',
      'patch',
      'delete',
      'head',
      'options',
    ];
    final List<ApiEndpoint> out = <ApiEndpoint>[];
    for (final MapEntry<Object?, Object?> entry in paths.entries) {
      final Object? item = entry.value;
      if (item is! Map) continue;
      for (final String method in methods) {
        if (item.containsKey(method)) {
          out.add(
            ApiEndpoint(
              method: method.toUpperCase(),
              path: entry.key.toString(),
              source: file.path,
            ),
          );
        }
      }
    }
    return out;
  }

  List<ApiEndpoint> _httpFile(RepoFile file) {
    final RegExp pattern = RegExp(
      r'^\s*(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+(\S+)',
      multiLine: true,
      caseSensitive: false,
    );
    return <ApiEndpoint>[
      for (final RegExpMatch match in pattern.allMatches(file.content))
        ApiEndpoint(
          method: (match.group(1) ?? '').toUpperCase(),
          path: match.group(2) ?? '',
          source: file.path,
        ),
    ];
  }
}

/// 无 manifest 或全部适配器失败时的兜底：仍给出包，只是 `degraded: true`。
class FallbackAdapter implements LanguageAdapter {
  @override
  String get id => 'fallback';

  @override
  Future<List<PackageUnit>> scan(RepoIndex index) async {
    final List<RepoFile> files = index.files
        .where((RepoFile file) => !file.name.toLowerCase().endsWith('.lock'))
        .toList();
    return <PackageUnit>[
      PackageUnit(
        id: p.basename(index.root),
        root: '.',
        language: id,
        fileCount: files.length,
        lines: files.fold<int>(0, (int sum, RepoFile file) => sum + file.lines),
        maxFileLines: files.fold<int>(
          0,
          (int max, RepoFile file) => file.lines > max ? file.lines : max,
        ),
        subpackages: const <SubUnit>[],
        exports: const <String>[],
        api: const ApiSurface(count: 0),
        dependencies: const <String>[],
        degraded: true,
      ),
    ];
  }
}

/// 六族 + fallback 的默认适配器表（DN-2）。
List<LanguageAdapter> defaultAdapters() => <LanguageAdapter>[
  ManifestAdapter(
    id: 'dart',
    manifests: const <String>['pubspec.yaml', 'pubspec.yml'],
    extensions: const <String>['.dart'],
    nameOf: (RepoFile manifest) => _yaml(manifest)['name']?.toString() ?? '',
    dependenciesOf: (RepoFile manifest) {
      final Object? deps = _yaml(manifest)['dependencies'];
      return deps is Map
          ? deps.keys.map((Object? key) => key.toString()).toList()
          : <String>[];
    },
    exportPatterns: <RegExp>[
      RegExp(
        r'^\s*(?:abstract\s+|sealed\s+|base\s+|final\s+|interface\s+)?(?:class|mixin|enum|typedef|extension)\s+([A-Za-z_]\w*)',
        multiLine: true,
      ),
    ],
    exportFilter: (String name) => !name.startsWith('_'),
  ),
  ManifestAdapter(
    id: 'python',
    manifests: const <String>['pyproject.toml', 'setup.py', 'setup.cfg'],
    extensions: const <String>['.py'],
    nameOf: _pythonName,
    dependenciesOf: _pythonDependencies,
    exportPatterns: <RegExp>[
      RegExp(r'^\s*(?:class|def)\s+([A-Za-z_]\w*)', multiLine: true),
    ],
    exportFilter: (String name) => !name.startsWith('_'),
  ),
  ManifestAdapter(
    id: 'go',
    manifests: const <String>['go.mod'],
    extensions: const <String>['.go'],
    nameOf: _goModule,
    dependenciesOf: _goDependencies,
    exportPatterns: <RegExp>[
      RegExp(
        r'^\s*(?:func|type)\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)',
        multiLine: true,
      ),
    ],
    exportFilter: (String name) =>
        name.isNotEmpty &&
        name[0].toUpperCase() == name[0] &&
        name[0].toLowerCase() != name[0],
  ),
  ManifestAdapter(
    id: 'rust',
    manifests: const <String>['Cargo.toml'],
    extensions: const <String>['.rs'],
    nameOf: _cargoName,
    dependenciesOf: _cargoDependencies,
    exportPatterns: <RegExp>[
      RegExp(
        r'^\s*pub\s+(?:async\s+)?(?:fn|struct|enum|trait|type|const|static)\s+([A-Za-z_]\w*)',
        multiLine: true,
      ),
    ],
  ),
  ManifestAdapter(
    id: 'node',
    manifests: const <String>['package.json'],
    extensions: const <String>[
      '.ts',
      '.tsx',
      '.js',
      '.jsx',
      '.mjs',
      '.cjs',
      '.vue',
    ],
    nameOf: _nodeName,
    dependenciesOf: _nodeDependencies,
    exportPatterns: <RegExp>[
      RegExp(
        r'export\s+(?:default\s+)?(?:async\s+)?(?:function|class|const|let|var|interface|type|enum)\s+([A-Za-z_$][\w$]*)',
        multiLine: true,
      ),
    ],
    extraExports: (RepoFile file) {
      if (!file.path.toLowerCase().endsWith('.vue')) return const <String>[];
      final List<String> out = <String>[];
      // Vue 3 SFC：`defineProps<{...}>` / `defineEmits<{...}>` 的字段就是对外面。
      for (final RegExpMatch block in RegExp(
        r'(?:defineProps|defineEmits)\s*<\{([\s\S]*?)\}>',
      ).allMatches(file.content)) {
        for (final RegExpMatch field in RegExp(
          r'^\s*([A-Za-z_$][\w$]*)\s*\??\s*:',
          multiLine: true,
        ).allMatches(block.group(1) ?? '')) {
          final String name = field.group(1) ?? '';
          if (name.isNotEmpty) out.add(name);
        }
      }
      return out;
    },
  ),
  HttpAdapter(),
];

Future<ScanResult> scanRepository(String repo) async {
  final RepoIndex index = await RepoIndex.load(repo);
  final List<PackageUnit> packages = <PackageUnit>[];
  final List<String> adapters = <String>[];
  final List<String> errors = <String>[];

  for (final LanguageAdapter adapter in defaultAdapters()) {
    try {
      final List<PackageUnit> found = await adapter.scan(index);
      if (found.isEmpty) continue;
      adapters.add(adapter.id);
      packages.addAll(found);
    } catch (error) {
      errors.add('${adapter.id}: $error');
    }
  }
  if (packages.isEmpty) {
    packages.addAll(await FallbackAdapter().scan(index));
    adapters.add('fallback');
  }

  final Map<String, PackageUnit> byId = <String, PackageUnit>{
    for (final PackageUnit unit in packages) unit.id: unit,
  };
  for (final PackageUnit unit in packages) {
    for (final String dependency in unit.dependencies) {
      final PackageUnit? target = byId[dependency];
      if (target != null && !unit.dependsOn.contains(target.id)) {
        unit.dependsOn.add(target.id);
      }
    }
  }

  // 同名包去重：保留第一个，其余加 root 后缀。
  final Set<String> ids = <String>{};
  for (int i = 0; i < packages.length; i++) {
    final PackageUnit unit = packages[i];
    if (ids.add(unit.id)) continue;
    final String unique = '${unit.id}@${unit.root == '.' ? 'root' : unit.root}';
    packages[i] = PackageUnit(
      id: unique,
      root: unit.root,
      language: unit.language,
      fileCount: unit.fileCount,
      lines: unit.lines,
      maxFileLines: unit.maxFileLines,
      subpackages: unit.subpackages,
      exports: unit.exports,
      api: unit.api,
      dependencies: unit.dependencies,
      degraded: unit.degraded,
    );
    ids.add(unique);
  }

  return ScanResult(
    repo: index.root,
    packages: packages,
    filesScanned: index.files.length,
    skippedFiles: index.skippedFiles,
    truncated: index.truncated,
    adapters: adapters,
    errors: errors,
  );
}

Map<String, dynamic> _yaml(RepoFile file) {
  try {
    final Object? value = loadYaml(file.content);
    return value is Map ? _map(value) : <String, dynamic>{};
  } catch (_) {
    return <String, dynamic>{};
  }
}

Map<String, dynamic> _json(RepoFile file) {
  try {
    final Object? value = jsonDecode(file.content);
    return value is Map ? _map(value) : <String, dynamic>{};
  } catch (_) {
    return <String, dynamic>{};
  }
}

Map<String, dynamic> _map(Object? raw) => raw is Map
    ? raw.map(
        (Object? key, Object? value) =>
            MapEntry<String, dynamic>(key.toString(), value),
      )
    : <String, dynamic>{};

String _firstGroup(RegExp pattern, String content) {
  final RegExpMatch? match = pattern.firstMatch(content);
  return match?.group(1) ?? '';
}

String _pythonName(RepoFile manifest) {
  if (manifest.name == 'pyproject.toml') {
    return _firstGroup(
      RegExp(r'''^\s*name\s*=\s*["']([^"']+)["']''', multiLine: true),
      manifest.content,
    );
  }
  return _firstGroup(
    RegExp(r'''name\s*=\s*["']([^"']+)["']'''),
    manifest.content,
  );
}

List<String> _pythonDependencies(RepoFile manifest) {
  final List<String> out = <String>[];
  for (final RegExpMatch match in RegExp(
    r'''["']([A-Za-z0-9_.-]+)\s*[<>=!~]''',
  ).allMatches(manifest.content)) {
    final String name = match.group(1) ?? '';
    if (name.isNotEmpty && !out.contains(name)) out.add(name);
  }
  return out;
}

String _goModule(RepoFile manifest) => _firstGroup(
  RegExp(r'^\s*module\s+(\S+)', multiLine: true),
  manifest.content,
);

List<String> _goDependencies(RepoFile manifest) {
  final List<String> out = <String>[];
  for (final RegExpMatch match in RegExp(
    r'^\s*([A-Za-z0-9_.\-/]+\.[A-Za-z]{2,})(?:\s+v\S+)?$',
    multiLine: true,
  ).allMatches(manifest.content)) {
    final String name = match.group(1) ?? '';
    if (name.isNotEmpty && name != 'module' && !out.contains(name)) {
      out.add(name);
    }
  }
  return out;
}

String _cargoName(RepoFile manifest) => _firstGroup(
  RegExp(r'''^\s*name\s*=\s*["']([^"']+)["']''', multiLine: true),
  manifest.content,
);

List<String> _cargoDependencies(RepoFile manifest) {
  final List<String> out = <String>[];
  bool inDeps = false;
  for (final String line in const LineSplitter().convert(manifest.content)) {
    final String trimmed = line.trim();
    if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
      inDeps = trimmed.contains('dependencies');
      continue;
    }
    if (!inDeps || trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final RegExpMatch? match = RegExp(r'^([A-Za-z0-9_-]+)\s*=')
        .firstMatch(trimmed);
    if (match != null) out.add(match.group(1)!);
  }
  return out;
}

String _nodeName(RepoFile manifest) =>
    _json(manifest)['name']?.toString() ?? '';

List<String> _nodeDependencies(RepoFile manifest) {
  final Map<String, dynamic> data = _json(manifest);
  final List<String> out = <String>[];
  for (final String key in <String>[
    'dependencies',
    'devDependencies',
    'peerDependencies',
  ]) {
    final Object? value = data[key];
    if (value is Map) {
      out.addAll(value.keys.map((Object? item) => item.toString()));
    }
  }
  return out.toSet().toList();
}
