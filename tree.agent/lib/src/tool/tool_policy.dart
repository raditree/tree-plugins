/// Agent 级工具白名单（P2）。
///
/// 口径（production-line-recon §10.5）：
/// - **缺省 = 全量默认**：旧 `agents/<id>.yaml` 没有 `tool_policy` 键 ⇒ [allowed]
///   为 null ⇒ 现有 agent 行为零改动；
/// - **空列表 = 显式全关**：用户把所有工具都取消勾选是合法配置，不能退化成默认；
/// - [blocked] 是**绝对禁用**：只给临时员工继承用（[kSubagentBlockedTools]），
///   与用户勾选无关——父级就算开了 `team`，临时员工也不能再建团队。
library;

/// 临时员工继承父白名单时**额外剔除**的工具（§9.5：员工不能再召员工/建团队/发消息）。
const Set<String> kSubagentBlockedTools = <String>{
  'subagent',
  'team',
  'message',
};

/// 工具分组（UI 勾选按组展示；未列出的工具归 [kToolGroupPlugin]）。
const String kToolGroupRead = 'read';
const String kToolGroupWrite = 'write';
const String kToolGroupCommand = 'command';
const String kToolGroupCollab = 'collab';
const String kToolGroupWorkflow = 'workflow';
const String kToolGroupPlugin = 'plugin';

/// 分组的显示名与顺序（顺序即 UI 渲染顺序）。
const Map<String, String> kToolGroupLabels = <String, String>{
  kToolGroupRead: '读',
  kToolGroupWrite: '写',
  kToolGroupCommand: '命令',
  kToolGroupCollab: '协作',
  kToolGroupWorkflow: '待办与规范',
  kToolGroupPlugin: '插件 / MCP',
};

/// 工具名 → 分组。`plugin__<插件>__<原生名>` 一律先取原生名再判组。
String toolGroupOf(String toolName) {
  switch (_nativeName(toolName)) {
    case 'read':
    case 'list':
    case 'grep':
      return kToolGroupRead;
    case 'write':
    case 'edit':
      return kToolGroupWrite;
    case 'terminal':
      return kToolGroupCommand;
    case 'message':
    case 'team':
    case 'subagent':
      return kToolGroupCollab;
    case 'set_todo_list':
    case 'ask_user_question':
    case 'spec':
    case 'tool_runs':
      return kToolGroupWorkflow;
    default:
      return kToolGroupPlugin;
  }
}

/// 取贡献工具的原生名（`plugin__extra-tools__team` → `team`；其余原样）。
String _nativeName(String toolName) {
  if (!toolName.startsWith('plugin__')) return toolName;
  return toolName.split('__').last;
}

/// 一条可选工具目录项（`GET /api/agents/{agentId}/tool-policy` 的 `tool_catalog`）。
class ToolCatalogEntry {
  const ToolCatalogEntry({
    required this.name,
    required this.description,
    required this.group,
    required this.enabled,
  });

  /// 模型侧工具名（核心命名空间，例如 `plugin__extra-tools__team`）。
  final String name;
  final String description;

  /// 分组键（[kToolGroupLabels] 的键）。
  final String group;

  /// 当前策略下是否可用。
  final bool enabled;

  Map<String, dynamic> toApiJson() => <String, dynamic>{
    'name': name,
    'description': description,
    'group': group,
    'enabled': enabled,
  };
}

/// 一份生效的工具策略。
class ToolPolicy {
  const ToolPolicy({
    this.allowed,
    this.blocked = const <String>{},
  });

  /// 未配置（全量默认）。
  static const ToolPolicy unrestricted = ToolPolicy();

  /// null = 全量默认；空集 = 全关。
  final Set<String>? allowed;

  /// 绝对禁用（优先于 [allowed]）。
  final Set<String> blocked;

  /// 是否没有任何限制（便于快路径判断与日志）。
  bool get isUnrestricted => allowed == null && blocked.isEmpty;

  /// [name] 是否可用。
  ///
  /// 匹配同时接受核心名与原生名：目录里给的是核心名，但用户手改 YAML 时写
  /// `team` 也能命中 `plugin__extra-tools__team`（同一工具，不应因写法不同而失效）。
  bool allows(String name) {
    if (_contains(blocked, name)) return false;
    final Set<String>? allow = allowed;
    if (allow == null) return true;
    return _contains(allow, name);
  }

  /// 继承本策略并追加禁用项（临时员工用）。
  ToolPolicy inherit({Set<String> block = const <String>{}}) => ToolPolicy(
    allowed: allowed,
    blocked: <String>{...blocked, ...block},
  );
}

bool _contains(Set<String> names, String toolName) {
  if (names.contains(toolName)) return true;
  return names.contains(_nativeName(toolName));
}
