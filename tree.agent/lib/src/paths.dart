import 'package:path/path.dart' as p;

/// 数据根布局（与核心 `TreePaths` **同一串落盘点**）。
///
/// 为什么插件复制这份布局而不是 import 核心包：数据接管的硬口径是「同一文件只
/// 允许一个写者」，而位置就是契约本身；同时依赖纪律禁止 import
/// tree_core / tree_protocol。布局变化必须核心与插件同批改——G-1 对照表
/// （docs/pluginization/agent_api_contract.md）是这份契约的读者。
class AgentDataPaths {
  const AgentDataPaths(this.root);

  /// 数据根（核心经委派信封的 `data_dir` 给出；插件不自行推导）。
  final String root;

  /// `<root>/agents`：每个 agent 一个 yaml。
  String get agentsDir => p.join(root, 'agents');

  /// `<root>/data`：会话数据（`<agent>/<session>/`）。
  String get sessionsDataDir => p.join(root, 'data');

  /// 单个 agent 配置：`<root>/agents/<id>.yaml`。
  String agentFile(String agentId) =>
      p.join(agentsDir, '${safeSegment(agentId)}.yaml');

  /// 某 agent 的会话数据目录：`<root>/data/<id>`。
  String agentDataDir(String agentId) =>
      p.join(sessionsDataDir, safeSegment(agentId));

  /// 某会话目录：`<root>/data/<agent>/<session>`。
  String sessionDir(String agentId, String sessionId) =>
      p.join(agentDataDir(agentId), safeSegment(sessionId));

  /// 会话待办：`<root>/data/<agent>/<session>/todos.md`。
  String todosFile(String agentId, String sessionId) =>
      p.join(sessionDir(agentId, sessionId), 'todos.md');

  /// 临时员工名册：`<root>/data/<agent>/<session>/subagents.json`。
  String subagentsFile(String agentId, String sessionId) =>
      p.join(sessionDir(agentId, sessionId), 'subagents.json');

  /// 校验单个路径分段（防路径穿越）。与核心 `TreePaths.safeSegment` 同一口径：
  /// 只允许 `[A-Za-z0-9_.-]`，拒绝空串 / `.` / `..`。
  static String safeSegment(String raw) {
    final String value = raw.trim();
    if (value.isEmpty) {
      throw ArgumentError.value(raw, 'segment', '路径分段不能为空');
    }
    if (value == '.' || value == '..') {
      throw ArgumentError.value(raw, 'segment', '路径分段不能是 . 或 ..');
    }
    if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(value)) {
      throw ArgumentError.value(
        raw,
        'segment',
        '路径分段只允许 [A-Za-z0-9_.-]（防路径穿越）',
      );
    }
    return value;
  }
}
