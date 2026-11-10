/// 专家工具（P5）的纯领域逻辑：工具声明、问题契约、四段回答与工具表边界。
///
/// 口径（docs/pluginization/production-line-recon.md §9.4）：
/// - 输入 `{question, context, desired_output}`；`context` 只能是已打包片段或文件引用，
///   **不能是整库**（超长直接拒绝，不截断后硬塞）；
/// - 专家是临时员工（角色 `expert`），默认工具 `read/grep`，**不许写文件**；
/// - 输出固定四段：结论 / 依据（文件:行）/ 建议 / 未决；
/// - 默认不能召专家（`roles.expert.enabled=false`），且单任务有次数上限；
/// - 工具表里出现写工具 / 再召工具一律拒绝，不靠运行时兜底。
///
/// 这一层不读盘、不碰服务：单测可以用纯函数覆盖全部判定。
library;

import 'models.dart';

/// 专家工具名（插件贡献给 `tree.agent` 的原生名）。
const String kAskExpertTool = 'ask_expert';

/// `context` 上限：够放几段已打包片段，但放不下整库。
const int kExpertMaxContextChars = 12000;

/// 专家次数上限的默认值（`roles.expert.max_per_task`）。
const int kExpertMaxPerTask = 3;

/// 专家绝对不能拿的工具：写 / 再召 / 建团队（§9.4 + Q3）。
const Set<String> kExpertForbiddenTools = <String>{
  'write',
  'edit',
  'subagent',
  'team',
  kAskExpertTool,
};

/// 专家默认工具（与 `tree.agent` 的 `kWorkerDefaultTools['expert']` 同口径）。
const List<String> kExpertDefaultTools = <String>['read', 'grep'];

/// 贡献给 `tree.agent` 的工具声明（收集站 `plugin.tree.agent.collect.tools` 的回包项）。
Map<String, dynamic> expertToolSpec() => <String, dynamic>{
  'name': kAskExpertTool,
  'description':
      '就一个具体问题召一位专家做窄而深的回答（只读、不写文件）。'
      '需要产线启用专家，且本任务的专家次数未超上限；输出固定四段：结论 / 依据 / 建议 / 未决。',
  'parameters': <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'line_id': <String, dynamic>{'type': 'string', 'description': '产线 id'},
      'task_id': <String, dynamic>{'type': 'string', 'description': '任务 id'},
      'role': <String, dynamic>{
        'type': 'string',
        'enum': <String>['packer', 'executor'],
        'description': '发起者角色（打包 / 执行；专家不能再召专家）',
      },
      'question': <String, dynamic>{
        'type': 'string',
        'description': '一个具体、可独立研究的问题（API 用法 / 协议细节 / 库行为 / 方案对比）',
      },
      'context': <String, dynamic>{
        'type': 'string',
        'description': '已打包片段或文件引用（不要整库；超过 12000 字符会被拒绝）',
      },
      'desired_output': <String, dynamic>{
        'type': 'string',
        'description': '期望的产出粒度（例如「给结论与最小示例」）',
      },
    },
    'required': <String>['line_id', 'task_id', 'question'],
  },
};

/// 一次专家提问（已 trim；`context` 已做长度校验）。
class ExpertRequest {
  const ExpertRequest({
    required this.question,
    required this.context,
    required this.desiredOutput,
    required this.role,
  });

  final String question;
  final String context;
  final String desiredOutput;

  /// 发起者角色；空串 = 不指定（打包 / 执行任一都可）。
  final String role;
}

/// 解析 `ask_expert` / `production.task.expert` 的提问参数。
ExpertRequest parseExpertArguments(Map<String, Object?> arguments) {
  final String question = textOf(arguments['question']);
  if (question.isEmpty) {
    throw ProductionFailure(
      'ask_expert 需要 question：一个具体、可独立研究的问题',
      code: 'invalid_arguments',
    );
  }
  final String context = textOf(arguments['context']);
  if (context.length > kExpertMaxContextChars) {
    throw ProductionFailure(
      '专家上下文 ${context.length} 字符，超过上限 $kExpertMaxContextChars：'
      '只给已打包片段或文件引用，不要整库',
      code: 'expert_context_too_large',
    );
  }
  return ExpertRequest(
    question: question,
    context: context,
    desiredOutput: textOf(arguments['desired_output']),
    role: textOf(arguments['role']),
  );
}

/// 专家的固定四段回答（§9.4）。
class ExpertAnswer {
  const ExpertAnswer({
    required this.conclusion,
    required this.evidence,
    required this.suggestion,
    required this.open,
  });

  final String conclusion;
  final List<String> evidence;
  final String suggestion;
  final List<String> open;

  Map<String, Object?> toJson() => <String, Object?>{
    'conclusion': conclusion,
    'evidence': evidence,
    'suggestion': suggestion,
    'open': open,
  };
}

/// 解析专家报告（JSON）；结论为空一律 `expert_bad_answer`（固定四段是硬契约）。
ExpertAnswer parseExpertAnswer(Map<String, Object?>? json) {
  if (json == null) {
    throw ProductionFailure(
      '专家没有返回 JSON：固定四段（conclusion / evidence / suggestion / open）',
      code: 'expert_bad_answer',
    );
  }
  final String conclusion = textOf(json['conclusion']);
  if (conclusion.isEmpty) {
    throw ProductionFailure(
      '专家回答缺 conclusion（结论是四段里唯一必填的）',
      code: 'expert_bad_answer',
    );
  }
  return ExpertAnswer(
    conclusion: conclusion,
    evidence: stringsOf(json['evidence']),
    suggestion: textOf(json['suggestion']),
    open: stringsOf(json['open']),
  );
}

/// 人读 / 模型读的四段文本（顺序固定，未决为空也保留段名）。
String renderExpertAnswer(ExpertAnswer answer) {
  final StringBuffer buffer = StringBuffer()
    ..writeln('结论：${answer.conclusion}')
    ..writeln('依据：');
  if (answer.evidence.isEmpty) {
    buffer.writeln('- （专家未给文件:行依据）');
  } else {
    for (final String item in answer.evidence) {
      buffer.writeln('- $item');
    }
  }
  buffer.writeln('建议：${answer.suggestion.isEmpty ? '（无）' : answer.suggestion}');
  buffer.writeln('未决：');
  if (answer.open.isEmpty) {
    buffer.writeln('- （无）');
  } else {
    for (final String item in answer.open) {
      buffer.writeln('- $item');
    }
  }
  return buffer.toString().trimRight();
}

/// 专家工具表：空 ⇒ 默认 `read/grep`；其余按配置（写 / 再召由调用方拒绝）。
List<String> expertToolsOf(Object? raw) {
  final List<String> tools = stringsOf(raw);
  return tools.isEmpty ? List<String>.of(kExpertDefaultTools) : tools;
}

/// 专家工具表里越界的工具（空 = 合规）。
List<String> expertToolViolations(Iterable<String> tools) => <String>[
  for (final String tool in tools)
    if (kExpertForbiddenTools.contains(tool)) tool,
];

String expertSystemPrompt() =>
    '你是标准开发流的专家：只回答一个具体问题，不做实现、不写文件。'
    '只输出一个 JSON 对象，不要 Markdown 代码围栏。'
    '结构：{"conclusion":"一句话结论",'
    '"evidence":["path:line — 依据"],"suggestion":"可执行建议",'
    '"open":["未决 / 不确定的点"]}。'
    '规则：结论必须明确；依据必须落到文件:行或明确的外部事实；'
    '不确定的放 open，不要编造；不许改文件、不许跑构建。';

String expertUserPrompt({
  required String taskId,
  required String title,
  required ExpertRequest request,
}) {
  final StringBuffer buffer = StringBuffer()
    ..writeln('任务：$taskId $title')
    ..writeln()
    ..writeln('问题：')
    ..writeln(request.question)
    ..writeln()
    ..writeln('上下文（已打包片段 / 文件引用，可能不完整）：')
    ..writeln(request.context.trim().isEmpty ? '（无）' : request.context.trim());
  if (request.desiredOutput.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('期望产出：')
      ..writeln(request.desiredOutput);
  }
  buffer
    ..writeln()
    ..writeln('请按固定四段回答：结论 / 依据（文件:行）/ 建议 / 未决。');
  return buffer.toString();
}
