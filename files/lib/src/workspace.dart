import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'errors.dart';

/// `agents/<id>.yaml` 的**最小**只读视图：文件面板只需工作空间归属与 SSH 配置。
///
/// 为什么不 import 核心的 CoreAgent / SshConfig：插件不能依赖 tree_core；
/// 这些字段本来就是用户可直接手改的 YAML 键（workspace_dir / parent_agent_id /
/// ssh），按同一套键名读即可，不复制核心的整个记录模型。
class AgentRecord {
  const AgentRecord({
    required this.id,
    this.workspaceId = '',
    this.workspaceDir = '',
    this.parentAgentId = '',
    this.ssh,
  });

  final String id;
  final String workspaceId;
  final String workspaceDir;
  final String parentAgentId;

  /// `ssh:` 段原样（含凭据，只在插件进程内用于登记租约，不写日志）。
  final Map<String, dynamic>? ssh;
}

/// 一次文件请求解析出的工作空间：团队所有者、本机根、有效 SSH 配置。
class WorkspaceTarget {
  const WorkspaceTarget({
    required this.workspaceId,
    required this.agent,
    required this.owner,
    required this.root,
    required this.ssh,
  });

  final String workspaceId;
  final AgentRecord agent;

  /// 团队所有者（TOP agent）：成员与 TOP 共享工作目录/SSH。
  final AgentRecord owner;

  /// 本机工作空间绝对根（远端工作空间也会计算，但不用于远端读写）。
  final String root;

  /// 有效 SSH 配置：自己没有就跟随团队所有者；空 = 本机。
  final Map<String, dynamic>? ssh;

  bool get isRemote => ssh != null;

  /// 租约缓存键（同一 agent + 同一 SSH 配置复用一条远端租约）。
  String get leaseKey {
    final Map<String, dynamic> value = ssh ?? const <String, dynamic>{};
    return <String>[
      owner.id,
      '${value['host'] ?? ''}',
      '${value['port'] ?? 22}',
      '${value['username'] ?? value['user'] ?? ''}',
      '${value['root'] ?? ''}',
      '${value['login_shell'] ?? value['loginShell'] ?? ''}',
    ].join('|');
  }
}

/// 从数据根读取 agents/*.yaml 并解析工作空间（每次请求重读，用户手改立即生效）。
class WorkspaceResolver {
  WorkspaceResolver(this.dataDir, {this.log});

  final String dataDir;
  final void Function(String message)? log;

  late final Map<String, AgentRecord> _agents = _loadAgents();

  /// 按 `workspace_id` 优先、agent id 兜底匹配（与核心旧 `FileService.agentFor` 同口径）。
  WorkspaceTarget resolve(String workspaceId) {
    final String id = workspaceId.trim();
    if (id.isEmpty) {
      throw FileRouteError.read('缺少 workspaceId');
    }
    AgentRecord? agent;
    for (final AgentRecord record in _agents.values) {
      if (record.workspaceId == id) {
        agent = record;
        break;
      }
    }
    agent ??= _agents[id];
    if (agent == null) {
      throw FileRouteError.read('工作空间不存在：$id');
    }
    // 成员跟随团队 TOP 的工作目录/SSH；成环或悬空上级就地停下（与团队口径一致）。
    AgentRecord owner = agent;
    final Set<String> seen = <String>{agent.id};
    for (int depth = 0; depth < 32; depth++) {
      final String parentId = owner.parentAgentId.trim();
      if (parentId.isEmpty) break;
      final AgentRecord? parent = _agents[parentId];
      if (parent == null || !seen.add(parent.id)) break;
      owner = parent;
    }
    final String configured = owner.workspaceDir.trim();
    final String root = configured.isNotEmpty
        ? p.normalize(p.absolute(configured))
        : p.join(p.normalize(dataDir), 'workspaces', _safeSegment(owner.id));
    final Map<String, dynamic>? ssh = agent.ssh ?? owner.ssh;
    return WorkspaceTarget(
      // 规范化为 agent 自己的 workspace_id（输入可能是 agent id）：上传会话按它比对。
      workspaceId: agent.workspaceId.isNotEmpty ? agent.workspaceId : agent.id,
      agent: agent,
      owner: owner,
      root: root,
      ssh: ssh,
    );
  }

  Map<String, AgentRecord> _loadAgents() {
    final Map<String, AgentRecord> out = <String, AgentRecord>{};
    final Directory dir = Directory(p.join(dataDir, 'agents'));
    if (!dir.existsSync()) return out;
    final List<File> files = <File>[
      for (final FileSystemEntity entity in dir.listSync(followLinks: false))
        if (entity is File && entity.path.toLowerCase().endsWith('.yaml'))
          entity,
    ]..sort((File a, File b) => a.path.compareTo(b.path));
    for (final File file in files) {
      try {
        final Map<String, dynamic>? data = _readYamlMap(file);
        if (data == null) continue;
        final String fallbackId = p.basenameWithoutExtension(file.path);
        final String id = (data['id'] ?? fallbackId).toString().trim();
        if (id.isEmpty) continue;
        final Object? rawSsh = data['ssh'];
        final Map<String, dynamic>? ssh =
            rawSsh is Map && '${rawSsh['host'] ?? ''}'.trim().isNotEmpty
            ? _stringMap(rawSsh)
            : null;
        out[id] = AgentRecord(
          id: id,
          workspaceId: (data['workspace_id'] ?? '').toString().trim(),
          workspaceDir: (data['workspace_dir'] ?? '').toString().trim(),
          parentAgentId: (data['parent_agent_id'] ?? '').toString().trim(),
          ssh: ssh,
        );
      } catch (error) {
        log?.call('读取 agent 配置失败（${file.path}）：$error');
      }
    }
    return out;
  }

  Map<String, dynamic>? _readYamlMap(File file) {
    final String text = utf8.decode(
      file.readAsBytesSync(),
      allowMalformed: true,
    );
    final Object? raw = loadYaml(text);
    if (raw is! Map) return null;
    return _normalizeMap(raw);
  }

  static Map<String, dynamic> _normalizeMap(Map<dynamic, dynamic> raw) {
    return <String, dynamic>{
      for (final MapEntry<dynamic, dynamic> entry in raw.entries)
        entry.key.toString(): _normalizeValue(entry.value),
    };
  }

  static Object? _normalizeValue(Object? value) {
    if (value is Map) return _normalizeMap(value);
    if (value is List) {
      return <Object?>[for (final Object? item in value) _normalizeValue(item)];
    }
    return value;
  }

  static Map<String, dynamic> _stringMap(Map<dynamic, dynamic> raw) =>
      <String, dynamic>{
        for (final MapEntry<dynamic, dynamic> entry in raw.entries)
          entry.key.toString(): entry.value,
      };

  static String _safeSegment(String id) {
    final String safe = id.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (safe.isEmpty || safe == '.' || safe == '..') return 'workspace';
    return safe;
  }
}
