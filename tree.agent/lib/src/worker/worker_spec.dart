/// 产线员工（worker）的角色规格：`agent.worker.run` 的参数解析与硬校验。
///
/// 口径（docs/pluginization/production-line-recon.md §9）：
/// - 员工是**角色化的临时员工**：`packer` / `executor` / `expert`；
/// - 工具白名单由角色配置**显式传入**（不再是"继承父的全部"）；
/// - 员工不能再建团队；再召员工默认关闭（Q3，只有 `allow_spawn` 显式打开才放行）；
/// - 打包与专家**不许写文件**：`write/edit` 直接拒绝（不靠运行时兜底）；
/// - 执行模型必须至少有一个写工具（既无 write 也无 edit ⇒ 无法落地）。
///
/// 这一层是纯函数：不读盘、不碰服务，单测零依赖。
library;

import '../tool/tool_policy.dart';

/// 三种员工角色（与 `line.yaml.roles` 的键逐字一致）。
const List<String> kWorkerRoles = <String>['packer', 'executor', 'expert'];

/// 角色的中文显示名（也是员工默认显示名）。
const Map<String, String> kWorkerRoleLabels = <String, String>{
  'packer': '打包模型',
  'executor': '执行模型',
  'expert': '专家',
};

/// 角色默认工具（与 §9.1 / §9.2 / §9.4 的表格一致）。
///
/// `message` 是任务内一对一沟通通道（§9.3）；专家默认不带。
const Map<String, List<String>> kWorkerDefaultTools = <String, List<String>>{
  'packer': <String>['read', 'list', 'grep', 'terminal', 'message'],
  'executor': <String>['read', 'write', 'edit', 'terminal', 'message', 'spec'],
  'expert': <String>['read', 'grep'],
};

/// 员工**绝对禁用**的工具：不能再建团队；默认也不能再召员工（Q3）。
const Set<String> kWorkerBlockedTools = <String>{'subagent', 'team'};

/// 写入类工具（打包 / 专家一律不给）。
const Set<String> kWorkerWriteTools = <String>{'write', 'edit'};

/// 专家工具名（由 `tree.production.line` 贡献；专家自己不能再召专家）。
const String kAskExpertTool = 'ask_expert';

/// 参数校验失败（入口把它翻成 `{error, code}` 站级失败）。
class WorkerSpecError implements Exception {
  WorkerSpecError(this.message, {this.code = 'invalid_arguments'});

  final String message;
  final String code;

  @override
  String toString() => message;
}

/// 一次员工运行的规格（已 trim、已去重）。
class WorkerSpec {
  const WorkerSpec({
    required this.role,
    required this.task,
    required this.name,
    required this.modelId,
    required this.tools,
    required this.reuse,
    required this.allowSpawn,
  });

  final String role;
  final String task;
  final String name;
  final String modelId;
  final List<String> tools;

  /// 复用入口（员工 id 或显示名；空串 = 新召）。
  final String reuse;

  /// 是否允许员工再召员工（默认 false，Q3）。
  final bool allowSpawn;
}

/// 解析并校验 `agent.worker.run` 的参数。
///
/// 缺失项一律给可读错误（不猜默认值）；`tools` 缺省按角色默认，
/// 显式传 `[]` = 显式全关（专家纯推理场景合法）。
WorkerSpec parseWorkerArguments(Map<String, Object?> arguments) {
  final String role = _text(arguments['role']);
  if (!kWorkerRoles.contains(role)) {
    throw WorkerSpecError(
      'role 只能是 ${kWorkerRoles.join(' / ')}（当前：${role.isEmpty ? '空' : role}）',
    );
  }
  final String task = _text(arguments['task']);
  if (task.isEmpty) {
    throw WorkerSpecError('缺少 task：员工看不到发起者的会话，指令必须自包含');
  }
  final Object? rawTools = arguments['tools'];
  final List<String> tools = rawTools is List
      ? _unique(<String>[
          for (final Object? item in rawTools)
            if (_text(item).isNotEmpty) _text(item),
        ])
      : List<String>.of(kWorkerDefaultTools[role]!);
  final bool allowSpawn = arguments['allow_spawn'] == true;
  final Set<String> blocked = <String>{
    'team',
    if (!allowSpawn) 'subagent',
  };
  for (final String tool in tools) {
    // 硬边界按**原生名**判定：`plugin__<插件>__team` 与 `team` 是同一条红线。
    final String native = nativeToolName(tool);
    if (role == 'expert' && native == kAskExpertTool) {
      throw WorkerSpecError(
        '专家不能再召专家：$kAskExpertTool 只给打包 / 执行',
        code: 'worker_tools_invalid',
      );
    }
    if (blocked.contains(native)) {
      throw WorkerSpecError(
        allowSpawn && native == 'subagent'
            ? '员工不能召员工（allow_spawn 也不会放开这条）：$tool'
            : '员工不能用 $tool（角色 $role 的硬边界）',
        code: 'worker_tools_invalid',
      );
    }
    if ((role == 'packer' || role == 'expert') &&
        kWorkerWriteTools.contains(native)) {
      throw WorkerSpecError(
        '$role 不许写文件：工具表里不能有 $tool（打包只读、专家不落盘）',
        code: 'worker_tools_invalid',
      );
    }
  }
  if (role == 'executor' &&
      !tools.any((String tool) => kWorkerWriteTools.contains(tool))) {
    throw WorkerSpecError(
      'executor 既没有 write 也没有 edit：无法落地任何改动',
      code: 'worker_tools_invalid',
    );
  }
  return WorkerSpec(
    role: role,
    task: task,
    name: _text(arguments['name']).isEmpty
        ? kWorkerRoleLabels[role]!
        : _text(arguments['name']),
    modelId: _text(arguments['model_id']),
    tools: tools,
    reuse: _text(arguments['reuse']).isEmpty
        ? _text(arguments['worker_id'])
        : _text(arguments['reuse']),
    allowSpawn: allowSpawn,
  );
}

String _text(Object? value) => (value ?? '').toString().trim();

List<String> _unique(List<String> values) {
  final List<String> out = <String>[];
  for (final String value in values) {
    if (!out.contains(value)) out.add(value);
  }
  return out;
}
