/// 执行阶段（P4）的纯领域逻辑：片段包、写域判据、门控与提示词。
///
/// 口径（docs/pluginization/production-line-recon.md §9）：
/// - 打包产物 `pack.json` 必须**一次性打齐**（文件片段非空），执行模型不再整库读；
/// - `write_scope` 是**并行与权限的判据**：改动越出写域一律拒收；
/// - `done` 只能由门控通过触发，**不许模型自报完成**；
/// - 门控失败按 `limits.retries` 回 `packed` 重跑，超限转 `blocked`。
///
/// 这一层不读盘、不碰服务：单测可以用纯函数覆盖所有判定。
library;

import 'dart:convert';

import 'models.dart';

// ── 片段包（§9.1 / §7.4）─────────────────────────────────────────────

/// `pack.json` 里的一个文件片段。
class PackFile {
  const PackFile({
    required this.path,
    required this.startLine,
    required this.endLine,
    required this.content,
  });

  /// 工作空间相对路径（已规范化 `/`）。
  final String path;

  /// 1 起的行号；0 = 未标注（整文件）。
  final int startLine;
  final int endLine;

  /// 原片段（执行模型不再需要回读文件）。
  final String content;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'start_line': startLine,
    'end_line': endLine,
    'content': content,
  };
}

/// 一条基线 / 门控命令（`pack.baseline`）。
class PackCommand {
  const PackCommand({required this.command, this.note = ''});

  final String command;
  final String note;

  Map<String, Object?> toJson() => <String, Object?>{
    'command': command,
    if (note.isNotEmpty) 'note': note,
  };
}

/// 一次打包的完整产物（直接映射到 `tasks/<id>/pack.json`）。
class PackSpec {
  const PackSpec({
    required this.files,
    required this.baseline,
    required this.risks,
    required this.dependencies,
  });

  final List<PackFile> files;
  final List<PackCommand> baseline;
  final List<String> risks;
  final List<String> dependencies;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'files': <Map<String, Object?>>[
      for (final PackFile file in files) file.toJson(),
    ],
    'baseline': <Map<String, Object?>>[
      for (final PackCommand command in baseline) command.toJson(),
    ],
    'risks': risks,
    'dependencies': dependencies,
  };
}

/// 解析打包模型的报告 JSON；**片段为空 = 打包失败**（不得让执行模型回读整库）。
PackSpec parsePackJson(Map<String, Object?> json) {
  final Object? rawFiles = json['files'];
  if (rawFiles is! List || rawFiles.isEmpty) {
    throw ProductionFailure(
      '打包结果没有任何文件片段（files 为空）：执行模型会不得不回读整库',
      code: 'pack_incomplete',
    );
  }
  final List<PackFile> files = <PackFile>[];
  for (final Object? item in rawFiles) {
    if (item is! Map) continue;
    final Map<String, Object?> map = plainMap(item);
    final String path = normalizeRelPath(textOf(map['path']));
    final String content = textOf(
      textOf(map['content']).isEmpty ? map['snippet'] : map['content'],
    );
    if (path.isEmpty) {
      throw ProductionFailure('打包结果里有片段缺 path', code: 'pack_incomplete');
    }
    if (!isSafeRelativePath(path)) {
      throw ProductionFailure(
        '打包片段路径必须是工作空间相对路径：$path',
        code: 'pack_incomplete',
      );
    }
    if (content.isEmpty) {
      throw ProductionFailure(
        '打包片段 $path 没有内容（content/snippet 均空）',
        code: 'pack_incomplete',
      );
    }
    final int start = intOf(
      textOf('${map['start_line']}').isEmpty ? map['start'] : map['start_line'],
      0,
    );
    final int end = intOf(
      textOf('${map['end_line']}').isEmpty ? map['end'] : map['end_line'],
      start,
    );
    files.add(
      PackFile(
        path: path,
        startLine: start < 0 ? 0 : start,
        endLine: end < start ? start : end,
        content: content,
      ),
    );
  }
  if (files.isEmpty) {
    throw ProductionFailure(
      '打包结果的 files 里没有有效条目',
      code: 'pack_incomplete',
    );
  }
  return PackSpec(
    files: files,
    baseline: _commandsOf(json['baseline']),
    risks: stringsOf(json['risks']),
    dependencies: stringsOf(json['dependencies']),
  );
}

List<PackCommand> _commandsOf(Object? raw) {
  if (raw is! List) return <PackCommand>[];
  final List<PackCommand> out = <PackCommand>[];
  for (final Object? item in raw) {
    if (item is Map) {
      final Map<String, Object?> map = plainMap(item);
      final String command = textOf(
        textOf(map['command']).isEmpty ? map['cmd'] : map['command'],
      );
      if (command.isNotEmpty) {
        out.add(PackCommand(command: command, note: textOf(map['note'])));
      }
    } else {
      final String command = textOf(item);
      if (command.isNotEmpty) out.add(PackCommand(command: command));
    }
  }
  return out;
}

/// 从模型正文里抠出第一个 JSON 对象（偶尔带代码围栏 / 前置说明）。
Map<String, Object?>? jsonObjectFromText(String text) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final List<String> candidates = <String>[
    trimmed,
    if (trimmed.contains('{') && trimmed.lastIndexOf('}') > trimmed.indexOf('{'))
      trimmed.substring(trimmed.indexOf('{'), trimmed.lastIndexOf('}') + 1),
  ];
  for (final String candidate in candidates) {
    try {
      final Object? decoded = json.decode(candidate);
      if (decoded is Map) return plainMap(decoded);
    } catch (_) {
      // 换下一个候选。
    }
  }
  return null;
}

// ── 路径与写域（§8.5 / §9.2）───────────────────────────────────────

/// 规范化相对路径：反斜杠转 `/`、去掉前置 `./`。
String normalizeRelPath(String path) {
  String value = path.trim().replaceAll('\\', '/');
  while (value.startsWith('./')) {
    value = value.substring(2);
  }
  return value;
}

/// 是否是安全的相对路径（拒绝绝对路径与 `..`）。
bool isSafeRelativePath(String path) {
  final String value = normalizeRelPath(path);
  if (value.isEmpty) return false;
  if (value.startsWith('/')) return false;
  if (RegExp(r'^[A-Za-z]:').hasMatch(value)) return false;
  for (final String segment in value.split('/')) {
    if (segment.isEmpty || segment == '.' || segment == '..') return false;
  }
  return true;
}

/// `path` 是否落在 `scope` 里：文件全等、目录前缀、`*` / `**` 通配。
bool matchesWriteScope(String path, String scope) {
  final String file = normalizeRelPath(path);
  final String rule = normalizeRelPath(scope);
  if (file.isEmpty || rule.isEmpty) return false;
  if (rule == file) return true;
  if (rule.endsWith('/')) return file.startsWith(rule);
  if (rule.contains('*') || rule.contains('?')) {
    return _globToRegExp(rule).hasMatch(file);
  }
  return file.startsWith('$rule/');
}

RegExp _globToRegExp(String glob) {
  final StringBuffer buffer = StringBuffer('^');
  int i = 0;
  while (i < glob.length) {
    final String char = glob[i];
    if (char == '*') {
      if (i + 1 < glob.length && glob[i + 1] == '*') {
        buffer.write('.*');
        i += 2;
        if (i < glob.length && glob[i] == '/') i += 1;
        continue;
      }
      buffer.write('[^/]*');
      i += 1;
      continue;
    }
    if (char == '?') {
      buffer.write('[^/]');
      i += 1;
      continue;
    }
    buffer.write(RegExp.escape(char));
    i += 1;
  }
  buffer.write(r'$');
  return RegExp(buffer.toString());
}

/// 越出写域的改动（空 = 合规）。
List<String> writeScopeViolations(
  Iterable<String> changed,
  List<String> writeScope,
) => <String>[
  for (final String path in changed)
    if (!writeScope.any((String scope) => matchesWriteScope(path, scope))) path,
];

/// 命中禁区（`.env` / `**/*_key*` 等）的路径。
List<String> denyGlobViolations(
  Iterable<String> changed,
  List<String> denyGlobs,
) => <String>[
  for (final String path in changed)
    if (denyGlobs.any((String glob) => matchesWriteScope(path, glob))) path,
];

/// 解析 `git status --porcelain` 的改动路径（重命名取新名；去引号）。
List<String> parseChangedFiles(String output) {
  final Set<String> files = <String>{};
  for (final String line in output.split('\n')) {
    if (line.trim().length < 4) continue;
    String rest = line.substring(3).trim();
    final int arrow = rest.indexOf(' -> ');
    if (arrow >= 0) rest = rest.substring(arrow + 4).trim();
    if (rest.length >= 2 && rest.startsWith('"') && rest.endsWith('"')) {
      rest = rest.substring(1, rest.length - 1);
    }
    if (rest.isEmpty) continue;
    files.add(normalizeRelPath(rest));
  }
  final List<String> out = files.toList()..sort();
  return out;
}

// ── 门控（§9.2）────────────────────────────────────────────────────

/// 门控命令：调用方显式给的优先；否则用打包基线；都没有就只跑 `dart analyze`。
List<String> gateCommandsOf(
  Object? requested,
  List<String> baseline,
) {
  final List<String> explicit = stringsOf(requested);
  if (explicit.isNotEmpty) return explicit;
  if (baseline.isNotEmpty) return baseline;
  return const <String>['dart analyze'];
}

// ── 文档渲染 ────────────────────────────────────────────────────────

/// `tasks/<task_id>/pack.md`：人读版片段包（插件数据里的 `pack.json` 才是机读真值）。
String renderPackMd({
  required String taskId,
  required String title,
  required PackSpec pack,
}) {
  final StringBuffer buffer = StringBuffer()
    ..writeln('# 片段包 · $taskId $title')
    ..writeln()
    ..writeln(
      '> 文件 ${pack.files.length} 个 · 基线命令 ${pack.baseline.length} 条 · '
      '风险 ${pack.risks.length} 条',
    )
    ..writeln()
    ..writeln('## 文件片段')
    ..writeln();
  for (final PackFile file in pack.files) {
    final String range = file.startLine <= 0
        ? '整文件'
        : '行 ${file.startLine}–${file.endLine}';
    buffer
      ..writeln('### `${file.path}`（$range）')
      ..writeln()
      ..writeln('```')
      ..writeln(file.content)
      ..writeln('```')
      ..writeln();
  }
  buffer
    ..writeln('## 基线命令')
    ..writeln()
    ..writeln(
      pack.baseline.isEmpty
          ? '（无）'
          : pack.baseline
                .map(
                  (PackCommand command) =>
                      '- `${command.command}`${command.note.isEmpty ? '' : '（${command.note}）'}',
                )
                .join('\n'),
    )
    ..writeln()
    ..writeln('## 风险点')
    ..writeln()
    ..writeln(pack.risks.isEmpty ? '（无）' : pack.risks.map((String r) => '- $r').join('\n'))
    ..writeln()
    ..writeln('## 依赖关系')
    ..writeln()
    ..writeln(
      pack.dependencies.isEmpty
          ? '（无）'
          : pack.dependencies.map((String d) => '- $d').join('\n'),
    );
  return buffer.toString();
}

// ── 提示词（模型契约）────────────────────────────────────────────────

String packerSystemPrompt() =>
    '你是标准开发流的打包模型（只读）。只输出一个 JSON 对象，不要 Markdown 代码围栏。'
    '结构：{"files":[{"path","start_line","end_line","content"}],'
    '"baseline":[{"command"}],"risks":["…"],"dependencies":["…"]}。'
    '规则：files 必须**一次性打齐**执行模型需要的全部片段（路径 + 行区间 + 原片段），'
    '不要只给摘要；baseline 写门控要跑的命令（如 dart analyze）；'
    'risks 写可能踩的坑；dependencies 写任务间依赖。不许改文件、不许跑构建。';

String packerUserPrompt({
  required String lineId,
  required String lineName,
  required String taskId,
  required String title,
  required String intake,
  required String plan,
  required String memory,
  required List<String> readScope,
  required List<String> writeScope,
  bool expertAvailable = false,
}) {
  final StringBuffer buffer = StringBuffer()
    ..writeln('产线：${lineName.isEmpty ? taskId : lineName}（line_id=$lineId）')
    ..writeln('任务：$taskId $title')
    ..writeln()
    ..writeln('需求：')
    ..writeln(intake)
    ..writeln()
    ..writeln('计划（冻结）：')
    ..writeln(plan.trim().isEmpty ? '（无）' : plan.trim())
    ..writeln()
    ..writeln('项目记忆：')
    ..writeln(memory.trim().isEmpty ? '（无）' : memory.trim())
    ..writeln()
    ..writeln('读域：${readScope.isEmpty ? '（不限，但仍不允许写）' : readScope.join('、')}')
    ..writeln('写域：${writeScope.join('、')}')
    ..writeln();
  if (expertAvailable) {
    buffer
      ..writeln(
        '问专家：遇到一个具体、可独立研究的问题（API 用法 / 协议细节 / 库行为 / 方案对比），'
        '可调用 ask_expert（line_id=$lineId，task_id=$taskId，role=packer）；'
        'context 只放已打包片段或文件引用，不要整库。',
      )
      ..writeln();
  }
  buffer.writeln('请把执行模型改这一处所需的片段全部打齐；不许改文件、不许跑构建或测试。');
  return buffer.toString();
}

String executorSystemPrompt() =>
    '你是标准开发流的执行模型。按片段包改文件并跑门控。'
    '规则：只在写域内改文件；不删测试、不改验收判据；片段不够就说明缺什么，不许猜；'
    '改完给一段最终报告：改了哪些文件、跑了哪些命令、还有什么没做完。'
    '**不许自报完成**——门控说了算。';

String executorUserPrompt({
  required String lineId,
  required String taskId,
  required String title,
  required String packJson,
  required List<String> writeScope,
  required List<String> acceptance,
  required String acceptanceDoc,
  bool expertAvailable = false,
}) {
  final StringBuffer buffer = StringBuffer()
    ..writeln('任务：$taskId $title（line_id=$lineId）')
    ..writeln('写域（越界即失败）：${writeScope.join('、')}')
    ..writeln()
    ..writeln('验收判据：')
    ..writeln(acceptance.isEmpty ? '（见 acceptance.md）' : acceptance.map((String a) => '- $a').join('\n'))
    ..writeln()
    ..writeln('片段包（pack.json，已打齐，不要回读整库）：')
    ..writeln(packJson)
    ..writeln()
    ..writeln('验收文档：')
    ..writeln(acceptanceDoc.trim().isEmpty ? '（无）' : acceptanceDoc.trim())
    ..writeln();
  if (expertAvailable) {
    buffer
      ..writeln(
        '问专家：遇到一个具体、可独立研究的问题（API 用法 / 协议细节 / 库行为 / 方案对比），'
        '可调用 ask_expert（line_id=$lineId，task_id=$taskId，role=executor）；'
        'context 只放已打包片段或文件引用，不要整库。',
      )
      ..writeln();
  }
  buffer.writeln('请只改上述写域内的文件；完成后如实报告改动与命令。');
  return buffer.toString();
}
