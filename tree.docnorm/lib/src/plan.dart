import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'baseline.dart';
import 'scan.dart';

/// 生成计划失败：稳定 [code] + 人话 [message]。
///
/// 复用 [BaselineFailure] 会让入口的 catch 一处收口，但计划阶段的错误语义
/// 更窄（配置非法 / 参数非法），所以单独给一个类型、由入口分别收敛。
class PlanFailure implements Exception {
  PlanFailure(this.message, {this.code = 'plan_failed'});

  final String message;
  final String code;

  @override
  String toString() => message;
}

/// 计划口径（D5/D6）：两个额度分开，阈值可被 `.docnorm/config.json` / 环境变量覆盖。
class DocnormConfig {
  const DocnormConfig({
    required this.tokenScale,
    required this.modelMaxSeqlen,
    required this.contextRatio,
    required this.fullCodeRatio,
    required this.stageBudget,
    required this.configuredContextCap,
    required this.sources,
  });

  /// 字符数 → token 的换算比例（默认 4，即约 4 字符 / token）。
  final double tokenScale;

  /// 模型单次上限；未配置时用兜底 128k（与 tree.agent 的 kFallbackMaxSeqlen 同口径）。
  final int modelMaxSeqlen;

  /// `context_cap = min(配置, model_max_seqlen × context_ratio)` 的比例。
  final double contextRatio;

  /// 全代码注入的门槛比例（D6：单次估计 ≤ context_cap × 70%）。
  final double fullCodeRatio;

  /// 阶段累计额度（抽取 / 报告 / 检索各自独立，本命令只算当前阶段）。
  final int stageBudget;

  /// 显式配置的 context_cap（可选）；仍会与模型上限取 min。
  final int? configuredContextCap;

  /// 生效的配置来源（文件 / 环境变量 / 调用方覆盖）。
  final List<String> sources;

  int get contextCap {
    final int modelCap = (modelMaxSeqlen * contextRatio).floor();
    final int? configured = configuredContextCap;
    return configured == null ? modelCap : math.min(configured, modelCap);
  }

  int get fullCodeLimit => (contextCap * fullCodeRatio).floor();

  Map<String, Object?> toJson() => <String, Object?>{
    'sources': sources,
    'token_scale': tokenScale,
    'model_max_seqlen': modelMaxSeqlen,
    'context_ratio': contextRatio,
    'configured_context_cap': configuredContextCap,
    'context_cap': contextCap,
    'full_code_ratio': fullCodeRatio,
    'full_code_limit': fullCodeLimit,
    'stage_budget': stageBudget,
  };

  /// 配置优先级：`.docnorm/config.json` < 环境变量 < 调用方 overrides。
  ///
  /// K（tree.settings）落地后这里再接设置服务；当前按 D28 的降级口径。
  static DocnormConfig load(
    RepoIndex index, {
    Map<String, String>? environment,
    Map<String, Object?> overrides = const <String, Object?>{},
  }) {
    final Map<String, String> env = environment ?? Platform.environment;
    final Map<String, Object?> raw = <String, Object?>{};
    final List<String> sources = <String>[];

    final RepoFile? file = _fileOf(index, '.docnorm/config.json');
    if (file != null) {
      sources.add(file.path);
      Object? decoded;
      try {
        decoded = jsonDecode(file.content);
      } on FormatException catch (error) {
        throw PlanFailure(
          '.docnorm/config.json 解析失败：$error',
          code: 'invalid_config',
        );
      }
      if (decoded is! Map) {
        throw PlanFailure(
          '.docnorm/config.json 必须是 JSON 对象',
          code: 'invalid_config',
        );
      }
      raw.addAll(_map(decoded));
    }

    void fromEnv(String key, String envKey) {
      final String value = (env[envKey] ?? '').trim();
      if (value.isEmpty) return;
      raw[key] = value;
      sources.add('env:$envKey');
    }

    fromEnv('token_scale', 'TREE_DOCNORM_TOKEN_SCALE');
    fromEnv('model_max_seqlen', 'TREE_DOCNORM_MODEL_MAX_SEQLEN');
    fromEnv('context_ratio', 'TREE_DOCNORM_CONTEXT_RATIO');
    fromEnv('context_cap', 'TREE_DOCNORM_CONTEXT_CAP');
    fromEnv('full_code_ratio', 'TREE_DOCNORM_FULL_CODE_RATIO');
    fromEnv('stage_budget', 'TREE_DOCNORM_STAGE_BUDGET');

    for (final MapEntry<String, Object?> entry in overrides.entries) {
      raw[entry.key] = entry.value;
      sources.add('override:${entry.key}');
    }

    return DocnormConfig(
      tokenScale: _positiveDouble(raw['token_scale'], 'token_scale', 4),
      modelMaxSeqlen: _positiveInt(
        raw['model_max_seqlen'],
        'model_max_seqlen',
        128000,
      ),
      contextRatio: _ratio(raw['context_ratio'], 'context_ratio', 0.7),
      fullCodeRatio: _ratio(raw['full_code_ratio'], 'full_code_ratio', 0.7),
      stageBudget: _positiveInt(raw['stage_budget'], 'stage_budget', 400000),
      configuredContextCap: raw['context_cap'] == null
          ? null
          : _positiveInt(raw['context_cap'], 'context_cap', 0),
      sources: sources,
    );
  }
}

/// 注入模式白名单：plan / generate 共用同一套取值。
String validateMode(String mode) {
  final String requested = mode.trim().isEmpty ? 'auto' : mode.trim();
  const Set<String> modes = <String>{
    'auto',
    'readme',
    'declarations',
    'assertions',
    'full',
  };
  if (!modes.contains(requested)) {
    throw PlanFailure(
      'mode 只能是 ${modes.join(' / ')}：$requested',
      code: 'invalid_arguments',
    );
  }
  return requested;
}

/// 一个注入单元：按「最具体包 + 子包」归并（DN-4 口径，DN-5 生成复用）。
class PlanUnit {
  PlanUnit({
    required this.package,
    required this.subpackage,
    required this.changedFiles,
  });

  final PackageUnit package;
  final SubUnit? subpackage;
  final Set<String> changedFiles;

  String get key =>
      subpackage == null ? package.id : '${package.id}@${subpackage!.path}';

  String get root => subpackage?.path ?? package.root;
}

/// `docnorm.plan` / `docnorm.generate` 共用的加载结果（只读）。
class PlanContext {
  PlanContext({
    required this.git,
    required this.index,
    required this.config,
    required this.scan,
    required this.changes,
    required this.units,
    required this.unmatched,
  });

  final GitRepository git;
  final RepoIndex index;
  final DocnormConfig config;
  final ScanResult scan;
  final GitChanges changes;
  final List<PlanUnit> units;
  final List<String> unmatched;
}

/// 一次加载仓库 / 配置 / 扫描 / 变更归集 / 注入单元（只读）。
Future<PlanContext> loadPlanContext(
  String repo, {
  Map<String, Object?> overrides = const <String, Object?>{},
  Map<String, String>? environment,
}) async {
  final GitRepository git = await GitRepository.open(repo);
  final RepoIndex index = await RepoIndex.load(repo);
  final DocnormConfig config = DocnormConfig.load(
    index,
    environment: environment,
    overrides: overrides,
  );
  final ScanResult scan = await scanIndex(index);
  final GitChanges changes = await git.changedFiles();

  final Map<String, PlanUnit> units = <String, PlanUnit>{};
  final List<String> unmatched = <String>[];
  for (final String path in changes.all) {
    final PackageUnit? package = _ownerPackage(path, scan.packages);
    if (package == null) {
      unmatched.add(path);
      continue;
    }
    final SubUnit? subpackage = _ownerSubpackage(path, package.subpackages);
    final String key = subpackage == null
        ? package.id
        : '${package.id}@${subpackage.path}';
    units
        .putIfAbsent(
          key,
          () => PlanUnit(
            package: package,
            subpackage: subpackage,
            changedFiles: <String>{},
          ),
        )
        .changedFiles
        .add(path);
  }
  final List<PlanUnit> sorted = units.values.toList()
    ..sort((PlanUnit a, PlanUnit b) => a.key.compareTo(b.key));
  return PlanContext(
    git: git,
    index: index,
    config: config,
    scan: scan,
    changes: changes,
    units: sorted,
    unmatched: unmatched,
  );
}

/// `docnorm.plan`：只读变更归集 + 注入单元 + 两额度估计（DN-4）。
///
/// - 变更只认 `git diff` 的内容差异（stat-dirty 不产计划）；
/// - 单元按「最具体包 + 子包」归并，README 存在时注入 README，否则注入声明；
/// - 每个单元同时给出 full / readme / declarations / assertions 四种估计，
///   模式选择与 `context_cap` 分开报告，不做静默裁剪。
Future<Map<String, Object?>> runPlan(
  String repo, {
  Map<String, Object?> overrides = const <String, Object?>{},
  String mode = 'auto',
  Map<String, String>? environment,
}) async {
  final String requested = validateMode(mode);

  final PlanContext context = await loadPlanContext(
    repo,
    overrides: overrides,
    environment: environment,
  );
  final DocnormConfig config = context.config;

  final List<Map<String, Object?>> unitPayloads = <Map<String, Object?>>[];
  final List<String> requiresChunking = <String>[];
  int plannedTokens = 0;
  int batches = 0;
  for (final PlanUnit unit in context.units) {
    final Map<String, Object?> payload = _buildUnit(
      index: context.index,
      unit: unit,
      config: config,
      requested: requested,
    );
    unitPayloads.add(payload);
    final int tokens = payload['selected_tokens'] as int;
    final int chunks = payload['chunks'] as int;
    plannedTokens += tokens;
    batches += chunks;
    if (chunks > 1) requiresChunking.add(unit.key);
  }

  final bool withinStage = plannedTokens <= config.stageBudget;
  return <String, Object?>{
    'command': 'docnorm.plan',
    'repo': context.index.root,
    'dry_run': true,
    'git': context.changes.toJson(),
    'config': config.toJson(),
    'budget': <String, Object?>{
      'context_cap': config.contextCap,
      'context_ratio': config.contextRatio,
      'model_max_seqlen': config.modelMaxSeqlen,
      'configured_context_cap': config.configuredContextCap,
      'full_code_ratio': config.fullCodeRatio,
      'full_code_limit': config.fullCodeLimit,
      'stage_budget': config.stageBudget,
      'planned_tokens': plannedTokens,
      'batches': batches,
      'requires_chunking': requiresChunking,
      'within_context_cap': requiresChunking.isEmpty,
      'within_stage_budget': withinStage,
      'over_stage_by': withinStage ? 0 : plannedTokens - config.stageBudget,
    },
    'units': unitPayloads,
    'unmatched': context.unmatched,
    'notes': <String>[
      '变更只认 git diff 的内容差异；stat-dirty / mode-only 不产计划',
      'context_cap 管单次调用；stage_budget 管阶段累计，两者分别报告',
      '估计为字符数 / token_scale 的启发式值，接入模型池后按真实 token 校准',
    ],
  };
}

Map<String, Object?> _buildUnit({
  required RepoIndex index,
  required PlanUnit unit,
  required DocnormConfig config,
  required String requested,
}) {
  final PackageUnit package = unit.package;
  final String root = unit.root;
  final List<RepoFile> files = unitSourceFiles(index, root);
  final RepoFile? readme = unitReadme(index, root);
  final List<String> changed = unit.changedFiles.toList()..sort();
  final bool hasReadme = readme != null;

  final int full = _tokens(
    files.fold<int>(0, (int sum, RepoFile file) => sum + file.content.length),
    config.tokenScale,
  );
  final int readmeTokens = readme == null
      ? 0
      : _tokens(readme.content.length, config.tokenScale);
  final int declarations = _declarationTokens(files, config.tokenScale);
  final int assertions = _assertionTokens(files, config.tokenScale);

  final List<String> reasons = <String>[];
  String mode;
  if (requested == 'full') {
    if (full <= config.fullCodeLimit) {
      mode = 'full';
    } else {
      mode = hasReadme ? 'readme' : 'declarations';
      reasons.add(
        'full 估计 $full > full_code_limit ${config.fullCodeLimit}，降级到 $mode',
      );
    }
  } else if (requested != 'auto') {
    mode = requested;
  } else if (changed.any(_isTestPath)) {
    mode = 'assertions';
  } else if (hasReadme) {
    mode = 'readme';
  } else {
    mode = 'declarations';
  }

  final Map<String, int> estimates = <String, int>{
    'full': full,
    'readme': readmeTokens,
    'declarations': declarations,
    'assertions': assertions,
  };
  final int selected = estimates[mode] ?? 0;
  if (selected == 0) {
    reasons.add('所选模式 $mode 的估计为 0（缺 README / 声明 / 断言）');
  }
  final int chunks = selected <= config.contextCap
      ? 1
      : (selected / config.contextCap).ceil();
  if (chunks > 1) {
    reasons.add(
      '单次估计 $selected 超过 context_cap ${config.contextCap}，需分 $chunks 批',
    );
  }
  final bool degraded = package.degraded || reasons.isNotEmpty;

  return <String, Object?>{
    'key': unit.key,
    'package': package.id,
    'root': root,
    'subpackage': unit.subpackage?.path,
    'language': package.language,
    'mode': mode,
    'has_readme': hasReadme,
    'readme': readme?.path,
    'changed_files': changed,
    'file_count': files.length,
    'estimates': estimates,
    'selected_tokens': selected,
    'chunks': chunks,
    'degraded': degraded,
    'reasons': reasons,
  };
}

PackageUnit? _ownerPackage(String path, List<PackageUnit> packages) {
  PackageUnit? best;
  int bestLength = -1;
  for (final PackageUnit unit in packages) {
    final String root = unit.root;
    if (root == '.' || path == root || path.startsWith('$root/')) {
      final int length = root == '.' ? 0 : root.length;
      if (length > bestLength) {
        bestLength = length;
        best = unit;
      }
    }
  }
  return best;
}

SubUnit? _ownerSubpackage(String path, List<SubUnit> subpackages) {
  SubUnit? best;
  int bestLength = -1;
  for (final SubUnit unit in subpackages) {
    if (path == unit.path || path.startsWith('${unit.path}/')) {
      if (unit.path.length > bestLength) {
        bestLength = unit.path.length;
        best = unit;
      }
    }
  }
  return best;
}

bool _under(String path, String root) =>
    root == '.' || path == root || path.startsWith('$root/');

/// 单元下的源码文件（排除文档 / 锁文件 / `.docnorm` 配置），按路径排序。
List<RepoFile> unitSourceFiles(RepoIndex index, String root) => index.files
    .where(
      (RepoFile file) =>
          _under(file.path, root) &&
          _isCode(file.path) &&
          !_isConfig(file.path),
    )
    .toList()
  ..sort((RepoFile a, RepoFile b) => a.path.compareTo(b.path));

/// 单元的 README（存在才返回；generate 不凭空新建 README）。
RepoFile? unitReadme(RepoIndex index, String root) =>
    _fileOf(index, root == '.' ? 'README.md' : '$root/README.md');

/// 字符数 → token 的启发式估计（与 plan 的额度口径一致）。
int estimateTokens(int chars, double scale) => _tokens(chars, scale);

/// 声明行摘录：`comments` / `declarations` 档复用同一份口径。
String declarationExcerpt(RepoFile file) => _excerpt(file, _declarationLine);

/// 断言行摘录：测试相关变更的注入来源。
String assertionExcerpt(RepoFile file) => _excerpt(file, _assertionLine);

String _excerpt(RepoFile file, RegExp pattern) {
  final StringBuffer buffer = StringBuffer();
  for (final String line in const LineSplitter().convert(file.content)) {
    if (pattern.hasMatch(line)) buffer.writeln(line.trimRight());
  }
  return buffer.toString();
}

/// 参与注入估计的源码：排除文档与锁文件（构建产物目录已在扫描时忽略）。
bool _isCode(String path) {
  final String lower = path.toLowerCase();
  return !(lower.endsWith('.md') ||
      lower.endsWith('.markdown') ||
      lower.endsWith('.lock') ||
      lower.endsWith('.txt'));
}

bool _isConfig(String path) =>
    path == '.docnorm/config.json' || path.startsWith('.docnorm/');

/// 测试文件判定（D13：收束与体积度量都排除测试）。
bool isTestPath(String path) => _isTestPath(path);

/// 文档文件判定（指纹口径只排文档，测试仍计入——与 baseline 一致）。
bool isDocPath(String path) {
  final String lower = path.toLowerCase();
  return lower.endsWith('.md') || lower.endsWith('.markdown');
}

/// 参与代码指纹的文件集（baseline / audit 共用同一口径）。
Set<String> fingerprintPathsIn(Iterable<RepoFile> files, String root) => <String>{
  for (final RepoFile file in files)
    if (_under(file.path, root) && !isDocPath(file.path)) file.path,
};

bool _isTestPath(String path) {
  final String lower = path.toLowerCase();
  final List<String> parts = lower.split('/');
  if (parts.contains('test') || parts.contains('tests')) return true;
  return lower.endsWith('_test.dart') ||
      lower.endsWith('_test.py') ||
      lower.endsWith('.test.ts') ||
      lower.endsWith('.test.js') ||
      lower.endsWith('.spec.ts') ||
      lower.endsWith('.spec.js');
}

int _tokens(int chars, double scale) => chars <= 0 ? 0 : (chars / scale).ceil();

/// 声明注入的启发式估计：声明行 + 每文件固定上下文。
final RegExp _declarationLine = RegExp(
  r'^\s*(?:@\w+\s*)*'
  r'(?:(?:pub|public|protected|private|internal|export|default|abstract|sealed|final|base|interface|partial|static|async|inline|const|let|var|readonly|override)\s+)*'
  r'(?:class|interface|enum|struct|trait|type|typedef|extension|mixin|record|func|def|function|fn|method|constructor|module|namespace)\b'
  r'|^\s*(?:export|public|pub)\s+(?:default\s+)?(?:async\s+)?(?:function|class|const|let|var|interface|type|enum)\b'
  r'|^\s*(?:def|function|func|fn)\s+[A-Za-z_$]',
  multiLine: true,
);

final RegExp _assertionLine = RegExp(
  r'\b(?:assert|assertThat|assertEquals|expect|should|verify|@Test)\b',
  caseSensitive: false,
);

int _declarationTokens(List<RepoFile> files, double scale) {
  int chars = 0;
  for (final RepoFile file in files) {
    chars += file.path.length + 32;
    for (final String line in const LineSplitter().convert(file.content)) {
      if (_declarationLine.hasMatch(line)) {
        chars += line.trim().length + 1;
      }
    }
  }
  return _tokens(chars, scale);
}

int _assertionTokens(List<RepoFile> files, double scale) {
  int chars = 0;
  for (final RepoFile file in files) {
    chars += file.path.length + 16;
    for (final String line in const LineSplitter().convert(file.content)) {
      if (_assertionLine.hasMatch(line)) {
        chars += line.trim().length + 1;
      }
    }
  }
  return _tokens(chars, scale);
}

RepoFile? _fileOf(RepoIndex index, String path) {
  for (final RepoFile file in index.files) {
    if (file.path == path) return file;
  }
  return null;
}

Map<String, Object?> _map(Object? value) => value is Map
    ? value.map(
        (Object? key, Object? item) =>
            MapEntry<String, Object?>(key.toString(), item),
      )
    : <String, Object?>{};

double _positiveDouble(Object? value, String field, double fallback) {
  if (value == null) return fallback;
  final double? parsed = value is num
      ? value.toDouble()
      : double.tryParse(value.toString().trim());
  if (parsed == null || parsed <= 0) {
    throw PlanFailure('$field 必须是正数：$value', code: 'invalid_config');
  }
  return parsed;
}

int _positiveInt(Object? value, String field, int fallback) {
  if (value == null) return fallback;
  final int? parsed = value is num
      ? value.toInt()
      : int.tryParse(value.toString().trim());
  if (parsed == null || parsed <= 0) {
    throw PlanFailure('$field 必须是正整数：$value', code: 'invalid_config');
  }
  return parsed;
}

double _ratio(Object? value, String field, double fallback) {
  final double parsed = _positiveDouble(value, field, fallback);
  if (parsed > 1) {
    throw PlanFailure('$field 必须在 (0, 1]：$value', code: 'invalid_config');
  }
  return parsed;
}
