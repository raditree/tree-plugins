import 'dart:convert';

import 'plan.dart';
import 'policy.dart';
import 'scan.dart';

/// 生成深度档：`comments` < `declarations` < `full`。
const Set<String> kGenerateTiers = <String>{'comments', 'declarations', 'full'};

/// 没有任何章节规则时使用的模块默认四节（与 DN-1 口径一致）。
const List<String> kDefaultSections = <String>['职责', '入口', '边界', '测试'];

/// 生成调用的入参（插件接线时映射为执行站 `llm.call`）。
class GenerateRequest {
  const GenerateRequest({
    required this.unit,
    required this.prompt,
    required this.system,
    required this.estimatedTokens,
  });

  final String unit;
  final String prompt;
  final String system;
  final int estimatedTokens;
}

/// 生成调用的结果：失败时 [error] 给可读原因，正文**绝不伪造**。
class GenerateReply {
  const GenerateReply({this.text = '', this.json, this.error = ''});

  final String text;
  final Object? json;
  final String error;

  bool get ok => error.trim().isEmpty;
}

/// 一次 LLM 调用；插件层把它接到 `llm.call`，单测用假实现。
typedef LlmCall = Future<GenerateReply> Function(GenerateRequest request);

/// `docnorm.generate`：只读生成缺失章节的提案（DN-5）。
///
/// - 只补缺：目标单元必须有 README，缺失章节 = 规则章节 - 已存在章节；
/// - 三模式（readme / declarations / assertions / full）× 三档（comments /
///   declarations / full），`context_cap` 超限先降档、再按文件分块、单文件仍超则丢弃；
/// - `stage_budget` 累计，超限停止并标 `degraded`；
/// - 返回的 `sections` 可直接交给 `docnorm.baseline` 的 `sections` 参数。
Future<Map<String, Object?>> runGenerate(
  String repo, {
  required LlmCall llm,
  Map<String, Object?> settings = const <String, Object?>{},
  Map<String, Object?> overrides = const <String, Object?>{},
  String mode = 'auto',
  String tier = 'auto',
  Map<String, String>? environment,
}) async {
  final String requestedMode = validateMode(mode);
  final String requestedTier = _validateTier(tier);

  final PlanContext context = await loadPlanContext(
    repo,
    settings: settings,
    overrides: overrides,
    environment: environment,
  );
  final DocnormConfig config = context.config;
  final DocPolicy policy = DocPolicy.resolve(context.index);
  final _Budget budget = _Budget(config.stageBudget);

  final List<Map<String, Object?>> documents = <Map<String, Object?>>[];
  final List<Map<String, Object?>> proposals = <Map<String, Object?>>[];
  for (final PlanUnit unit in context.units) {
    final _UnitResult result = await _generateUnit(
      unit: unit,
      index: context.index,
      config: config,
      policy: policy,
      llm: llm,
      budget: budget,
      requestedMode: requestedMode,
      requestedTier: requestedTier,
    );
    documents.add(result.toJson());
    proposals.addAll(result.proposals);
  }

  return <String, Object?>{
    'command': 'docnorm.generate',
    'repo': context.index.root,
    'dry_run': true,
    'git': context.changes.toJson(),
    'config': config.toJson(),
    'budget': <String, Object?>{
      'context_cap': config.contextCap,
      'stage_budget': config.stageBudget,
      'spent_tokens': budget.spent,
      'calls': budget.calls,
      'within_stage_budget': !budget.exhausted,
      'exhausted': budget.exhausted,
    },
    'documents': documents,
    'sections': proposals,
    'degraded': documents.any(
      (Map<String, Object?> item) => item['degraded'] == true,
    ),
    'unmatched': context.unmatched,
    'notes': <String>[
      '只补缺章节：README 不存在时跳过（不凭空新建），已存在章节 0 调用',
      '正文由 LLM 生成，严格 JSON 校验；失败 / 无 JSON 一律 degraded，不用占位内容补齐',
      'context_cap 管单次调用：先降档再按文件分块，单文件仍超则丢弃并标 degraded',
      'sections 可直接作为 docnorm.baseline 的 sections（默认 dry-run，commit 才落盘）',
    ],
  };
}

class _Budget {
  _Budget(this.stageBudget);

  final int stageBudget;
  int spent = 0;
  int calls = 0;
  bool exhausted = false;

  /// 还能不能发下一批：超限即停，不静默裁剪已答应的调用。
  bool allows(int tokens) {
    if (exhausted) return false;
    if (spent + tokens <= stageBudget) return true;
    exhausted = true;
    return false;
  }
}

class _UnitResult {
  _UnitResult({
    required this.unit,
    required this.package,
    required this.root,
    required this.doc,
    required this.mode,
    required this.tier,
    required this.requestedSections,
    required this.missingSections,
    required this.status,
    required this.skipReason,
    required this.generated,
    required this.rejected,
    required this.skipped,
    required this.calls,
    required this.tokens,
    required this.degraded,
    required this.reasons,
    required this.proposals,
  });

  final PlanUnit unit;
  final String package;
  final String root;
  final String? doc;
  final String mode;
  final String tier;
  final List<String> requestedSections;
  final List<String> missingSections;
  final String status;
  final String skipReason;
  final List<Map<String, Object?>> generated;
  final List<Map<String, Object?>> rejected;
  final List<Map<String, Object?>> skipped;
  final int calls;
  final int tokens;
  final bool degraded;
  final List<String> reasons;
  final List<Map<String, Object?>> proposals;

  Map<String, Object?> toJson() => <String, Object?>{
    'unit': unit.key,
    'package': package,
    'root': root,
    'doc': doc,
    'mode': mode,
    'tier': tier,
    'status': status,
    if (skipReason.isNotEmpty) 'skip_reason': skipReason,
    'requested_sections': requestedSections,
    'missing_sections': missingSections,
    'generated': generated,
    'rejected': rejected,
    'skipped': skipped,
    'calls': calls,
    'tokens': tokens,
    'degraded': degraded,
    'reasons': reasons,
  };
}

Future<_UnitResult> _generateUnit({
  required PlanUnit unit,
  required RepoIndex index,
  required DocnormConfig config,
  required DocPolicy policy,
  required LlmCall llm,
  required _Budget budget,
  required String requestedMode,
  required String requestedTier,
}) async {
  final List<String> reasons = <String>[];
  final RepoFile? readme = unitReadme(index, unit.root);
  if (readme == null) {
    return _UnitResult(
      unit: unit,
      package: unit.package.id,
      root: unit.root,
      doc: null,
      mode: requestedMode,
      tier: requestedTier,
      requestedSections: const <String>[],
      missingSections: const <String>[],
      status: 'skipped',
      skipReason: 'readme_missing',
      generated: const <Map<String, Object?>>[],
      rejected: const <Map<String, Object?>>[],
      skipped: const <Map<String, Object?>>[],
      calls: 0,
      tokens: 0,
      degraded: false,
      reasons: reasons,
      proposals: const <Map<String, Object?>>[],
    );
  }

  final List<String> required = _requiredSections(policy, readme.path);
  final List<String> missing = <String>[
    for (final String section in required)
      if (!readme.content.contains(section)) section,
  ];
  if (missing.isEmpty) {
    return _UnitResult(
      unit: unit,
      package: unit.package.id,
      root: unit.root,
      doc: readme.path,
      mode: requestedMode,
      tier: requestedTier,
      requestedSections: required,
      missingSections: const <String>[],
      status: 'skipped',
      skipReason: 'sections_present',
      generated: const <Map<String, Object?>>[],
      rejected: const <Map<String, Object?>>[],
      skipped: const <Map<String, Object?>>[],
      calls: 0,
      tokens: 0,
      degraded: false,
      reasons: reasons,
      proposals: const <Map<String, Object?>>[],
    );
  }

  final String mode = _resolveMode(unit, requestedMode, index, config, reasons);
  String tier = requestedTier == 'auto' ? _defaultTier(mode) : requestedTier;

  final List<_SourcePiece> pieces = _sourcePieces(
    unit: unit,
    index: index,
    readme: readme,
    mode: mode,
    tier: tier,
  );
  if (pieces.isEmpty) {
    reasons.add('注入来源为空：$mode（没有可用的声明 / 断言 / README）');
    return _skippedUnit(
      unit: unit,
      readme: readme,
      mode: mode,
      tier: tier,
      required: required,
      missing: missing,
      reasons: reasons,
      skipReason: 'empty_source',
      degraded: true,
    );
  }

  // context_cap 闸：先按 full → declarations → comments 降档，再按文件分块。
  ({List<_PromptChunk> chunks, List<String> dropped}) plan(String atTier) {
    final List<_SourcePiece> atPieces = atTier == tier
        ? pieces
        : _sourcePieces(
            unit: unit,
            index: index,
            readme: readme,
            mode: mode,
            tier: atTier,
          );
    final List<String> dropped = <String>[];
    return (
      chunks: _buildChunks(
        unit: unit,
        mode: mode,
        tier: atTier,
        sections: missing,
        pieces: atPieces,
        config: config,
        dropped: dropped,
      ),
      dropped: dropped,
    );
  }

  ({List<_PromptChunk> chunks, List<String> dropped}) planned = plan(tier);
  bool fits(({List<_PromptChunk> chunks, List<String> dropped}) value) =>
      value.dropped.isEmpty && value.chunks.isNotEmpty;
  if (!fits(planned)) {
    final List<String> downgrades = <String>[];
    String atTier = tier;
    while (true) {
      final String? lowered = _lowerTier(atTier);
      if (lowered == null) break;
      atTier = lowered;
      downgrades.add(atTier);
      planned = plan(atTier);
      if (fits(planned)) break;
    }
    if (atTier != tier) {
      reasons.add('context_cap 超限，降档到 $atTier（${downgrades.join(' → ')}）');
      tier = atTier;
    }
  }
  final List<_PromptChunk> chunks = planned.chunks;
  for (final String path in planned.dropped) {
    reasons.add('单文件注入仍超 context_cap，已丢弃：$path');
  }

  final List<Map<String, Object?>> generated = <Map<String, Object?>>[];
  final List<Map<String, Object?>> rejected = <Map<String, Object?>>[];
  final List<Map<String, Object?>> skipped = <Map<String, Object?>>[];
  final List<Map<String, Object?>> proposals = <Map<String, Object?>>[];
  final Set<String> accepted = <String>{};
  final Set<String> requestSet = missing.toSet();
  int calls = 0;
  int tokens = 0;
  bool degraded = chunks.isEmpty;

  for (final _PromptChunk chunk in chunks) {
    if (!budget.allows(chunk.estimatedTokens)) {
      reasons.add(
        'stage_budget 不足（已用 ${budget.spent}，本次估计 ${chunk.estimatedTokens}，'
        '上限 ${budget.stageBudget}），停止生成',
      );
      degraded = true;
      break;
    }
    budget.spent += chunk.estimatedTokens;
    budget.calls += 1;
    calls += 1;
    tokens += chunk.estimatedTokens;

    final GenerateReply reply = await llm(
      GenerateRequest(
        unit: unit.key,
        prompt: chunk.prompt,
        system: _systemPrompt,
        estimatedTokens: chunk.estimatedTokens,
      ),
    );
    if (!reply.ok) {
      reasons.add('LLM 调用失败：${reply.error}');
      degraded = true;
      break;
    }
    final Object? decoded = reply.json ?? _decodeJson(reply.text);
    if (decoded is! Map) {
      reasons.add('LLM 返回不是 JSON 对象：${_clip(reply.text, 120)}');
      degraded = true;
      break;
    }
    final Object? rawSections = decoded['sections'];
    if (rawSections is! List) {
      reasons.add('LLM 返回缺少 sections 数组');
      degraded = true;
      break;
    }
    for (final Object? item in rawSections) {
      if (item is! Map) {
        rejected.add(<String, Object?>{'reason': 'sections[] 元素不是对象'});
        continue;
      }
      final String heading = _normalizeHeading(_str(item['heading']));
      final String body = _str(item['body']).trim();
      if (heading.isEmpty) {
        rejected.add(<String, Object?>{'reason': 'heading 为空'});
        continue;
      }
      if (!requestSet.contains(heading)) {
        rejected.add(<String, Object?>{
          'heading': heading,
          'reason': '未请求的章节（只接受缺失章节）',
        });
        continue;
      }
      if (accepted.contains(heading)) {
        rejected.add(<String, Object?>{
          'heading': heading,
          'reason': '重复章节（已在前一批接受）',
        });
        continue;
      }
      if (body.isEmpty) {
        rejected.add(<String, Object?>{'heading': heading, 'reason': '正文为空'});
        continue;
      }
      if (body.length < 10) {
        rejected.add(<String, Object?>{
          'heading': heading,
          'reason': '正文过短（< 10 字符）',
        });
        continue;
      }
      accepted.add(heading);
      generated.add(<String, Object?>{'heading': heading, 'body': body});
      proposals.add(<String, Object?>{
        'doc': readme.path,
        'heading': '## $heading',
        'body': body,
        'mode': 'append',
      });
    }
  }

  for (final String section in missing) {
    if (!accepted.contains(section)) {
      skipped.add(<String, Object?>{'section': section, 'reason': '未生成'});
    }
  }

  return _UnitResult(
    unit: unit,
    package: unit.package.id,
    root: unit.root,
    doc: readme.path,
    mode: mode,
    tier: tier,
    requestedSections: required,
    missingSections: missing,
    status: generated.isEmpty ? 'skipped' : 'generated',
    skipReason: generated.isEmpty ? 'no_sections_returned' : '',
    generated: generated,
    rejected: rejected,
    skipped: skipped,
    calls: calls,
    tokens: tokens,
    degraded: degraded,
    reasons: reasons,
    proposals: proposals,
  );
}

_UnitResult _skippedUnit({
  required PlanUnit unit,
  required RepoFile readme,
  required String mode,
  required String tier,
  required List<String> required,
  required List<String> missing,
  required List<String> reasons,
  required String skipReason,
  required bool degraded,
}) => _UnitResult(
  unit: unit,
  package: unit.package.id,
  root: unit.root,
  doc: readme.path,
  mode: mode,
  tier: tier,
  requestedSections: required,
  missingSections: missing,
  status: 'skipped',
  skipReason: skipReason,
  generated: const <Map<String, Object?>>[],
  rejected: const <Map<String, Object?>>[],
  skipped: const <Map<String, Object?>>[],
  calls: 0,
  tokens: 0,
  degraded: degraded,
  reasons: reasons,
  proposals: const <Map<String, Object?>>[],
);

String _resolveMode(
  PlanUnit unit,
  String requested,
  RepoIndex index,
  DocnormConfig config,
  List<String> reasons,
) {
  if (requested == 'auto') {
    if (unit.changedFiles.any(_isTestPath)) return 'assertions';
    return 'readme';
  }
  if (requested == 'full') {
    final List<RepoFile> files = _relevantFiles(unit, index);
    final int full = estimateTokens(
      files.fold<int>(0, (int sum, RepoFile file) => sum + file.content.length),
      config.tokenScale,
    );
    if (full <= config.fullCodeLimit) return 'full';
    reasons.add(
      'full 估计 $full > full_code_limit ${config.fullCodeLimit}，降级到 readme',
    );
    return 'readme';
  }
  return requested;
}

String _defaultTier(String mode) {
  if (mode == 'full') return 'full';
  if (mode == 'declarations') return 'declarations';
  return 'comments';
}

String? _lowerTier(String tier) {
  switch (tier) {
    case 'full':
      return 'declarations';
    case 'declarations':
      return 'comments';
    default:
      return null;
  }
}

List<String> _requiredSections(DocPolicy policy, String readmePath) {
  final List<String> out = <String>[];
  for (final SectionRule rule in policy.requiredSections) {
    if (!globToRegExp(rule.glob).hasMatch(readmePath)) continue;
    for (final String section in rule.sections) {
      if (section.trim().isNotEmpty && !out.contains(section.trim())) {
        out.add(section.trim());
      }
    }
  }
  return out.isEmpty ? List<String>.of(kDefaultSections) : out;
}

/// 只看变更文件；没有（或变更都不在源码面）时退回单元全量源码。
List<RepoFile> _relevantFiles(PlanUnit unit, RepoIndex index) {
  final List<RepoFile> all = unitSourceFiles(index, unit.root);
  final List<RepoFile> changed = all
      .where((RepoFile file) => unit.changedFiles.contains(file.path))
      .toList();
  return changed.isEmpty ? all : changed;
}

class _SourcePiece {
  const _SourcePiece(this.path, this.text);

  final String path;
  final String text;
}

List<_SourcePiece> _sourcePieces({
  required PlanUnit unit,
  required RepoIndex index,
  required RepoFile readme,
  required String mode,
  required String tier,
}) {
  final List<RepoFile> files = _relevantFiles(unit, index);
  // 按路径去重且**后者覆盖前者**：tier=full 时用完整正文替换同名声明摘录。
  final Map<String, String> byPath = <String, String>{};
  void add(String path, String text) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;
    byPath[path] = trimmed;
  }

  switch (mode) {
    case 'readme':
      add(readme.path, readme.content);
      if (tier == 'declarations' || tier == 'full') {
        for (final RepoFile file in files) {
          add(file.path, declarationExcerpt(file));
        }
      }
      if (tier == 'full') {
        for (final RepoFile file in files) {
          add(file.path, file.content);
        }
      }
    case 'assertions':
      for (final RepoFile file in files) {
        add(file.path, assertionExcerpt(file));
      }
      if (tier == 'full') {
        for (final RepoFile file in files) {
          add(file.path, file.content);
        }
      }
    case 'full':
      for (final RepoFile file in files) {
        add(file.path, file.content);
      }
    default:
      for (final RepoFile file in files) {
        add(file.path, declarationExcerpt(file));
      }
      if (tier == 'full') {
        for (final RepoFile file in files) {
          add(file.path, file.content);
        }
      }
  }
  return <_SourcePiece>[
    for (final MapEntry<String, String> entry in byPath.entries)
      _SourcePiece(entry.key, entry.value),
  ];
}

class _PromptChunk {
  const _PromptChunk({
    required this.prompt,
    required this.estimatedTokens,
    required this.pieces,
  });

  final String prompt;
  final int estimatedTokens;
  final int pieces;
}

List<_PromptChunk> _buildChunks({
  required PlanUnit unit,
  required String mode,
  required String tier,
  required List<String> sections,
  required List<_SourcePiece> pieces,
  required DocnormConfig config,
  required List<String> dropped,
}) {
  final int overhead = estimateTokens(
    _prompt(
      unit: unit,
      mode: mode,
      tier: tier,
      sections: sections,
      source: '',
    ).length,
    config.tokenScale,
  );
  final List<_PromptChunk> chunks = <_PromptChunk>[];
  final List<_SourcePiece> current = <_SourcePiece>[];
  int currentTokens = overhead;

  void flush() {
    if (current.isEmpty) return;
    final String prompt = _prompt(
      unit: unit,
      mode: mode,
      tier: tier,
      sections: sections,
      source: current
          .map((_SourcePiece piece) => '### ${piece.path}\n${piece.text}')
          .join('\n\n'),
    );
    chunks.add(
      _PromptChunk(
        prompt: prompt,
        estimatedTokens: estimateTokens(prompt.length, config.tokenScale),
        pieces: current.length,
      ),
    );
    current.clear();
    currentTokens = overhead;
  }

  for (final _SourcePiece piece in pieces) {
    final int tokens = estimateTokens(
      '### ${piece.path}\n${piece.text}'.length + 2,
      config.tokenScale,
    );
    if (overhead + tokens > config.contextCap) {
      dropped.add(piece.path);
      continue;
    }
    if (current.isNotEmpty && currentTokens + tokens > config.contextCap) {
      flush();
    }
    current.add(piece);
    currentTokens += tokens;
  }
  flush();
  return chunks;
}

String _prompt({
  required PlanUnit unit,
  required String mode,
  required String tier,
  required List<String> sections,
  required String source,
}) {
  final StringBuffer buffer = StringBuffer()
    ..writeln('你是文档归一化助手：为下面的代码包补写 README 中缺失的章节。')
    ..writeln()
    ..writeln('包：${unit.package.id}（${unit.package.language}）')
    ..writeln('根目录：${unit.root}')
    ..writeln('注入来源：$mode；内容深度：$tier')
    ..writeln('缺失章节：${sections.join('、')}')
    ..writeln()
    ..writeln('只输出严格 JSON：{"sections":[{"heading":"章节名","body":"Markdown 正文"}]}')
    ..writeln('约束：')
    ..writeln('- heading 必须原样使用上面列出的章节名，不要带 #；')
    ..writeln('- body 用中文，只写代码与 README 里能证实的行为、入口与边界；')
    ..writeln('- 不要编造不存在的命令、路径或 API；没有事实可写就回 {"sections":[]}；')
    ..writeln('- 不要写“待补充”“TODO”这类占位正文。');
  if (source.trim().isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('--- 注入来源 ---')
      ..writeln(source.trim());
  }
  return buffer.toString();
}

const String _systemPrompt = '你是严谨的中文技术文档助手：只输出 JSON 对象，不要代码围栏或额外说明。';

String _validateTier(String tier) {
  final String requested = tier.trim().isEmpty ? 'auto' : tier.trim();
  if (requested == 'auto' || kGenerateTiers.contains(requested)) {
    return requested;
  }
  throw PlanFailure(
    'tier 只能是 auto / ${kGenerateTiers.join(' / ')}：$requested',
    code: 'invalid_arguments',
  );
}

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

String _normalizeHeading(String raw) {
  String text = raw.trim();
  text = text.replaceFirst(RegExp(r'^#{1,6}\s*'), '');
  return text.trim();
}

Object? _decodeJson(String text) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  try {
    return jsonDecode(trimmed);
  } on FormatException {
    final RegExpMatch? match = RegExp(r'\{[\s\S]*\}').firstMatch(trimmed);
    if (match == null) return null;
    try {
      return jsonDecode(match.group(0)!);
    } on FormatException {
      return null;
    }
  }
}

String _str(Object? value) => value is String ? value : (value?.toString() ?? '');

String _clip(String text, int limit) =>
    text.length <= limit ? text : '${text.substring(0, limit)}…';
