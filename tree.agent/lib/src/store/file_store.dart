import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import '../util/text_decoder.dart';

import 'atomic_file.dart';
import 'conversation_db.dart';
import '../util/ids.dart';
import 'tree_paths.dart';
import 'tree_store.dart';
import 'write_queue.dart';
import 'yaml_codec.dart';

/// 落盘存储实现：`~/.tree` 下的 YAML（配置）+ JSON/JSONL（会话数据）。
///
/// 设计要点：
/// - **懒加载 + 进程内缓存**：agent 列表、每 agent 的会话元数据、每会话的消息
///   都只在首次访问时读盘，之后走缓存；写入同时更新缓存与磁盘。
/// - **write-behind**：写操作立即返回，落盘任务排进 [WriteQueue]（每路径串行），
///   [flush] 可等待全部完成。详见 [TreeStore] 的写语义说明。
/// - **崩溃容错**：会话元数据原子快照（临时文件 + 改名），消息使用追加日志；
///   读取时对无法解析的行**跳过并计数**，绝不因为一行坏数据让整个会话打不开。
/// - **人类可手改**：agent/模型/设置是 YAML（多行文本用块标量），会话元数据是
///   缩进 JSON，消息是一行一条的 jsonl；用户可以直接打开、修改、再启动核心。
///
/// 注意：本实现不保证与**外部同时修改同一目录**的其他进程一致（桌面形态是
/// 单用户单实例；多实例会各自持有内存缓存，互不感知）。
class FileTreeStore implements TreeStore {
  FileTreeStore(this.paths, {this.log}) {
    // 首次启动即建好目录骨架，方便用户直接打开 ~/.tree 查看/手改配置
    unawaited(
      paths.ensureLayout().catchError((Object error) {
        log?.call('创建数据目录失败：$error');
      }),
    );
  }

  /// 路径布局。
  final TreePaths paths;

  /// 可读日志回调（落盘错误、跳过的损坏行等）。核心进程接到 stderr。
  final void Function(String message)? log;

  final Map<String, CoreAgent> _agents = <String, CoreAgent>{};
  final Map<String, Map<String, CoreSession>> _sessions =
      <String, Map<String, CoreSession>>{};
  final Map<String, List<CoreMessage>> _messages =
      <String, List<CoreMessage>>{};

  /// 临时员工名册缓存（`agentId::sessionId` → 记录；键存在 = 已从盘上装载过）。
  final Map<String, List<CoreSubagent>> _subagents =
      <String, List<CoreSubagent>>{};
  final Map<String, CoreMessage?> _preview = <String, CoreMessage?>{};
  final WriteQueue _queue = WriteQueue();

  /// 会话库异步装载中的任务（`agent::session` → future；防并发重复读库）。
  final Map<String, Future<void>> _hydrating = <String, Future<void>>{};

  /// 本实例打开过的会话库路径（[close] 时逐个关句柄）。
  final Set<String> _dbPaths = <String>{};

  bool _agentsScanned = false;
  final Set<String> _agentLoaded = <String>{};

  static const String _agentHeader =
      'Tree agent 配置：可直接手改（system_prompt 支持多行），'
      '改动在核心进程下次启动时生效。';

  // ── agent ────────────────────────────────────────────────────────────

  @override
  List<CoreAgent> agents() => _scanAgents().toList()
    ..sort((CoreAgent a, CoreAgent b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  CoreAgent? agent(String id) {
    _scanAgents();
    return _agents[id];
  }

  @override
  List<CoreAgent> teams() =>
      agents().where((CoreAgent a) => a.teamId.isEmpty).toList(growable: false);

  @override
  List<CoreAgent> members(String teamId) =>
      agents()
          .where((CoreAgent a) => a.teamId == teamId)
          .toList(growable: false)
        ..sort(
          (CoreAgent a, CoreAgent b) => a.createdAt == b.createdAt
              ? a.id.compareTo(b.id)
              : a.createdAt.compareTo(b.createdAt),
        );

  @override
  CoreAgent createAgent({
    required String name,
    String systemPrompt = '',
    String modelId = '',
    int teamMemberCount = 0,
    int maxLevel = TeamLimits.defaultMaxLevel,
    int maxMembersPerLevel = TeamLimits.defaultMaxMembersPerLevel,
  }) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final String id = CoreIds.next('agt');
    final CoreAgent agent = CoreAgent(
      id: id,
      name: name.isEmpty ? '新 Agent' : name,
      systemPrompt: systemPrompt,
      modelId: modelId,
      // 桌面端工作空间就是本机目录（M4 由用户指定）；此处先给稳定占位 id
      workspaceId: 'ws_$id',
      teamMemberCount: teamMemberCount,
      maxLevel: maxLevel,
      maxMembersPerLevel: maxMembersPerLevel,
      createdAt: now,
      updatedAt: now,
    );
    _agents[id] = agent;
    _agentLoaded.add(id); // 新 agent 磁盘上还没有任何会话，无需扫描
    _sessions[id] = <String, CoreSession>{};
    _writeAgent(agent);
    ensureDefaultSession(id);
    return agent;
  }

  @override
  void putAgent(CoreAgent agent) {
    _loadAgent(agent.id);
    _agents[agent.id] = agent;
    _writeAgent(agent);
    ensureDefaultSession(agent.id);
  }

  @override
  CoreAgent? updateAgent(
    String id, {
    String? name,
    String? systemPrompt,
    String? modelId,
  }) {
    final CoreAgent? agent = this.agent(id);
    if (agent == null) return null;
    if (name != null) agent.name = name;
    if (systemPrompt != null) agent.systemPrompt = systemPrompt;
    if (modelId != null) agent.modelId = modelId;
    agent.updatedAt = DateTime.now().millisecondsSinceEpoch;
    _writeAgent(agent);
    return agent;
  }

  @override
  bool deleteAgent(String id) {
    _loadAgent(id);
    final bool inCache = _agents.remove(id) != null;
    _agentLoaded.remove(id);
    // 缓存里没有也可能是磁盘上存在但尚未装载的情形（`_scanAgents` 之前）
    if (!inCache && !File(paths.agentFile(id)).existsSync()) return false;
    _sessions.remove(id);
    _messages.removeWhere((String key, _) => key.startsWith('$id::'));
    _subagents.removeWhere((String key, _) => key.startsWith('$id::'));
    _preview.removeWhere((String key, _) => key.startsWith('$id::'));
    final String agentFile = paths.agentFile(id);
    final String dataDir = paths.agentDataDir(id);
    _queue.enqueue(agentFile, () async {
      final File file = File(agentFile);
      if (await file.exists()) await file.delete();
    });
    final String dbPath = ConversationDbRegistry.pathFor(paths, id);
    _dbPaths.remove(dbPath);
    _queue.enqueue(dataDir, () async {
      // 会话库（conversation.semdb）在 agent 数据目录里：**必须先关句柄**再删目录，
      // 否则 Windows 上打开中的文件会让递归删除失败。
      await ConversationDbRegistry.close(dbPath);
      final Directory dir = Directory(dataDir);
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    return true;
  }

  /// 最后一条 agent 文本消息：**只看内存缓存**（同步接口无法查库）。
  ///
  /// 缓存由 [appendMessage]（本轮新消息）与 [_hydrate]（会话库存装载）填充；
  /// 未装载的会话返回 null。需要跨进程可靠预览的调用方（HTTP 列表端点）
  /// 已改走 `ConversationDb.lastTextDisplayRow`，jsonl 倒读尾巴随之退役。
  @override
  CoreMessage? lastTextMessage(String agentId) {
    _loadAgent(agentId);
    final List<CoreSession> ordered = sessions(agentId);
    for (final CoreSession session in ordered) {
      final CoreMessage? preview = _preview[_key(agentId, session.sessionId)];
      if (preview != null) return preview;
    }
    return null;
  }

  // ── 会话 ─────────────────────────────────────────────────────────────

  @override
  List<CoreSession> sessions(String agentId) {
    _loadAgent(agentId);
    final Map<String, CoreSession>? byId = _sessions[agentId];
    if (byId == null) return <CoreSession>[];
    return byId.values.toList()..sort(
      (CoreSession a, CoreSession b) => b.updatedAt.compareTo(a.updatedAt),
    );
  }

  @override
  CoreSession? session(String agentId, String sessionId) {
    _loadAgent(agentId);
    return _sessions[agentId]?[sessionId];
  }

  @override
  CoreSession ensureDefaultSession(String agentId) {
    _loadAgent(agentId);
    final CoreSession? existing = session(agentId, TreeStore.defaultSessionId);
    if (existing != null) return existing;
    final int now = DateTime.now().millisecondsSinceEpoch;
    final CoreSession created = CoreSession(
      sessionId: TreeStore.defaultSessionId,
      agentId: agentId,
      title: '默认会话',
      createdAt: now,
      updatedAt: now,
    );
    _sessions.putIfAbsent(
      agentId,
      () => <String, CoreSession>{},
    )[created.sessionId] = created;
    _writeSession(created);
    return created;
  }

  @override
  CoreSession? createSession(
    String agentId, {
    String title = '',
    String? sessionId,
  }) {
    _loadAgent(agentId);
    if (_agents[agentId] == null) return null;
    final int now = DateTime.now().millisecondsSinceEpoch;
    final String id = (sessionId != null && sessionId.isNotEmpty)
        ? sessionId
        : CoreIds.next('ses');
    final CoreSession? existing = _sessions[agentId]?[id];
    if (existing != null) return existing;
    final CoreSession created = CoreSession(
      sessionId: id,
      agentId: agentId,
      title: title.isEmpty ? '新会话' : title,
      createdAt: now,
      updatedAt: now,
    );
    _sessions.putIfAbsent(agentId, () => <String, CoreSession>{})[id] = created;
    _writeSession(created);
    return created;
  }

  @override
  bool renameSession(String agentId, String sessionId, String title) {
    final CoreSession? session = this.session(agentId, sessionId);
    if (session == null) return false;
    session.title = title.isEmpty ? session.title : title;
    session.updatedAt = DateTime.now().millisecondsSinceEpoch;
    _writeSession(session);
    return true;
  }

  @override
  bool deleteSession(String agentId, String sessionId) {
    final CoreSession? session = this.session(agentId, sessionId);
    if (session == null) return false;
    _sessions[agentId]?.remove(sessionId);
    final String key = _key(agentId, sessionId);
    _messages.remove(key);
    // 临时员工只在会话里存在：名册随会话目录一起删（subagents.json 在同一个目录里）
    _subagents.remove(key);
    _preview.remove(key);
    final String dir = paths.sessionDir(agentId, sessionId);
    // 会话库在 **agent 级**目录（不在会话目录里）：递归删目录收不到它，
    // 必须显式删该会话的显示行 + 详细行。
    final String dbPath = ConversationDbRegistry.pathFor(paths, agentId);
    _dbPaths.add(dbPath);
    _queue.enqueue(dbPath, () async {
      final ConversationDb db = await conversationDb(agentId);
      await db.deleteSession(sessionId);
    });
    _queue.enqueue(dir, () async {
      final Directory target = Directory(dir);
      if (await target.exists()) await target.delete(recursive: true);
    });
    return true;
  }

  @override
  int setSelectedSpecs(String agentId, String sessionId, List<String> specIds) {
    final CoreSession? session = this.session(agentId, sessionId);
    if (session == null) return 0;
    session.selectedSpecIds = List<String>.of(specIds);
    _writeSession(session);
    return session.selectedSpecIds.length;
  }

  @override
  int setPinnedSystemPrompt(String agentId, String sessionId, String text) {
    final CoreSession? session = this.session(agentId, sessionId);
    if (session == null) return 0;
    session.systemPromptPinned = text;
    session.systemPromptPinnedAt =
        text.isEmpty ? 0 : DateTime.now().millisecondsSinceEpoch;
    _writeSession(session);
    return 1;
  }

  @override
  bool setCompacted(
    String agentId,
    String sessionId, {
    required String summary,
    required int messageCount,
  }) {
    final CoreSession? session = this.session(agentId, sessionId);
    if (session == null) return false;
    session.compactedSummary = summary;
    // 内置摘要路径接管：中转站产出的列表作废（两者互斥，见 CoreSession）
    session.compactedContext = <Map<String, dynamic>>[];
    session.compactedMessageCount = messageCount < 0 ? 0 : messageCount;
    session.updatedAt = DateTime.now().millisecondsSinceEpoch;
    _writeSession(session);
    return true;
  }

  @override
  bool setCompactedContext(
    String agentId,
    String sessionId, {
    required List<Map<String, dynamic>> context,
    required int coveredMessageCount,
  }) {
    final CoreSession? session = this.session(agentId, sessionId);
    if (session == null) return false;
    session.compactedContext = context;
    // 中转站路径接管：内置摘要作废（下一次内置压缩会重新总结当前前缀）
    session.compactedSummary = '';
    session.compactedMessageCount = coveredMessageCount < 0
        ? 0
        : coveredMessageCount;
    session.updatedAt = DateTime.now().millisecondsSinceEpoch;
    _writeSession(session);
    return true;
  }

  // ── 消息 ─────────────────────────────────────────────────────────────

  @override
  List<CoreMessage> messages(String agentId, String sessionId) =>
      List<CoreMessage>.unmodifiable(
        // 自己的对话：排掉临时员工的消息——**除了**给它的完成报告
        // （那是"新的输入"，发起者得知道活干完了）
        sessionMessages(agentId, sessionId).where(
          (CoreMessage m) => !m.isSubagentMessage || m.isSubagentReport,
        ),
      );

  @override
  List<CoreMessage> sessionMessages(String agentId, String sessionId) {
    _loadMessages(agentId, sessionId);
    return List<CoreMessage>.unmodifiable(
      _messages[_key(agentId, sessionId)] ?? const <CoreMessage>[],
    );
  }

  // ── 临时员工（subagent，会话级） ─────────────────────────────────────

  @override
  List<CoreSubagent> subagents(String agentId, String sessionId) {
    _loadSubagents(agentId, sessionId);
    return List<CoreSubagent>.unmodifiable(
      _subagents[_key(agentId, sessionId)] ?? const <CoreSubagent>[],
    );
  }

  @override
  void putSubagent(CoreSubagent subagent) {
    _loadSubagents(subagent.ownerAgentId, subagent.sessionId);
    final List<CoreSubagent> list = _subagents.putIfAbsent(
      _key(subagent.ownerAgentId, subagent.sessionId),
      () => <CoreSubagent>[],
    );
    final int index = list.indexWhere((CoreSubagent s) => s.id == subagent.id);
    if (index >= 0) {
      list[index] = subagent;
    } else {
      list.add(subagent);
    }
    _writeSubagents(subagent.ownerAgentId, subagent.sessionId);
  }

  @override
  int deleteSubagent(String agentId, String sessionId, String id) {
    _loadSubagents(agentId, sessionId);
    final List<CoreSubagent>? list = _subagents[_key(agentId, sessionId)];
    if (list == null) return 0;
    final Set<String> doomed = subagentTreeIds(list, id);
    final int before = list.length;
    list.removeWhere((CoreSubagent s) => doomed.contains(s.id));
    final int removed = before - list.length;
    if (removed > 0) _writeSubagents(agentId, sessionId);
    return removed;
  }

  @override
  int clearSubagents(String agentId, String sessionId) {
    _loadSubagents(agentId, sessionId);
    final List<CoreSubagent>? list = _subagents[_key(agentId, sessionId)];
    final int removed = list?.length ?? 0;
    _subagents[_key(agentId, sessionId)] = <CoreSubagent>[];
    if (removed > 0) _writeSubagents(agentId, sessionId);
    return removed;
  }

  @override
  int messageCount(String agentId, String sessionId) =>
      messages(agentId, sessionId).where((CoreMessage m) => !m.isTool).length;

  @override
  CoreMessage appendMessage(CoreMessage message) {
    _loadAgent(message.agentId);
    _loadMessages(message.agentId, message.sessionId);
    final String key = _key(message.agentId, message.sessionId);
    final List<CoreMessage> list = _messages.putIfAbsent(
      key,
      () => <CoreMessage>[],
    );
    // 单调序号（Q3）：同毫秒的多条消息在"按时间戳排序"的历史接口里会重排
    // （`List.sort` 不保证稳定），把落库顺序直接压进时间戳就不会漂移。
    message.timestamp = monotonicStamp(
      message.timestamp,
      list.isEmpty ? 0 : list.last.timestamp,
    );
    list.add(message);
    // 预览只关心"最后一条 agent 文本消息"，工具卡片、用户消息、临时员工的话都不覆盖它
    if (!message.isTool && message.role == 'agent' && !message.isSubagentMessage) {
      _preview[key] = message;
    }
    // updated_at 只前进不后退（与 MemoryStore 同一语义，见契约测试）
    final CoreSession? session = _sessions[message.agentId]?[message.sessionId];
    if (session != null && message.timestamp > session.updatedAt) {
      session.updatedAt = message.timestamp;
      _writeSession(session);
    }
    final CoreAgent? agent = _agents[message.agentId];
    if (agent != null && message.timestamp > agent.updatedAt) {
      agent.updatedAt = message.timestamp;
      _writeAgent(agent);
    }
    // 持久化进会话库（显示行 + 详细行同事务）；每 agent 一条串行队列键，
    // 保证 seq 分配与调用顺序一致（jsonl 时代由"每会话串行追加"提供同一保证）。
    final String dbPath = ConversationDbRegistry.pathFor(
      paths,
      message.agentId,
    );
    _dbPaths.add(dbPath);
    _queue.enqueue(dbPath, () async {
      final ConversationDb db = await conversationDb(message.agentId);
      await db.appendMessage(message);
    });
    return message;
  }

  @override
  bool repairToolResult(
    String agentId,
    String sessionId,
    String toolCallId, {
    required String toolResult,
    required String toolResultForModel,
  }) {
    _loadMessages(agentId, sessionId);
    final List<CoreMessage>? list = _messages[_key(agentId, sessionId)];
    if (list == null) return false;
    final int index = list.indexWhere(
      (CoreMessage m) => m.isTool && m.toolCallId == toolCallId,
    );
    if (index < 0) return false;
    final CoreMessage existing = list[index];
    // 幂等：已经有结果就不再改（自动修复每次组装请求都会问一次）
    if (existing.toolResult.trim().isNotEmpty) return false;
    final CoreMessage repaired = CoreMessage.fromJson(<String, dynamic>{
      ...existing.toJson(),
      'tool_result': toolResult,
      'tool_result_for_model': toolResultForModel,
    });
    list[index] = repaired;
    // 只改 detail payload（display 行没有 tool_result，无需动）；
    // 排进该 agent 的写队列，与 append 串行，不会读到"半修"状态。
    final String msgId = existing.id;
    final String dbPath = ConversationDbRegistry.pathFor(paths, agentId);
    _dbPaths.add(dbPath);
    _queue.enqueue(dbPath, () async {
      final ConversationDb db = await conversationDb(agentId);
      await db.updateDetailResult(
        msgId,
        toolResult: toolResult,
        toolResultForModel: toolResultForModel,
      );
    });
    return true;
  }

  @override
  int clearMessages(String agentId, {String? sessionId}) {
    _loadAgent(agentId);
    final bool all =
        sessionId == null || sessionId.isEmpty || sessionId == 'all';
    final Iterable<String> targets = all
        ? sessions(agentId).map((CoreSession s) => s.sessionId)
        : <String>[sessionId];
    int deleted = 0;
    for (final String id in targets) {
      final String key = _key(agentId, id);
      _loadMessages(agentId, id);
      deleted += _messages[key]?.length ?? 0;
      _messages[key] = <CoreMessage>[];
      _preview.remove(key);
      final String dbPath = ConversationDbRegistry.pathFor(paths, agentId);
      _dbPaths.add(dbPath);
      _queue.enqueue(dbPath, () async {
        final ConversationDb db = await conversationDb(agentId);
        await db.deleteSession(id);
      });
    }
    return deleted;
  }

  @override
  int get totalMessageCount => _messages.values.fold<int>(
    0,
    (int sum, List<CoreMessage> l) => sum + l.length,
  );

  @override
  Future<void> flush() => _queue.flush();

  @override
  Future<void> close() async {
    await flush();
    final Object? error = _queue.lastError;
    if (error != null) log?.call('落盘期间出现错误（最后一次）：$error');
    for (final String dbPath in _dbPaths.toList()) {
      await ConversationDbRegistry.close(dbPath);
    }
    _dbPaths.clear();
  }

  /// 该 agent 的会话库句柄（打开幂等；首次打开顺带完成 jsonl 迁移）。
  Future<ConversationDb> conversationDb(String agentId) async {
    final String dbPath = ConversationDbRegistry.pathFor(paths, agentId);
    _dbPaths.add(dbPath);
    return ConversationDbRegistry.open(paths, agentId, log: log);
  }

  /// **异步装载**某会话的消息缓存（幂等）——会话消息进会话库后的唯一装载入口。
  ///
  /// 为什么必须异步：Sembast 只有异步 API，而 [messages] / [appendMessage] 的
  /// 接口形状是同步的（契约如此，M1/M2 就这么跑）。折中：async 入口（对话服务、
  /// 委派路由）在读写某会话之前先 `await` 这里；同步侧撞上未装载的缓存只会
  /// 记一条错误日志（见 [_loadMessages]），**不静默兜底**。
  @override
  Future<void> ensureMessagesLoaded(String agentId, String sessionId) async {
    _loadAgent(agentId);
    final String key = _key(agentId, sessionId);
    if (_messages.containsKey(key)) return;
    final Future<void>? pending = _hydrating[key];
    if (pending != null) return pending;
    final Future<void> task = _hydrate(agentId, sessionId, key);
    _hydrating[key] = task;
    try {
      await task;
    } finally {
      _hydrating.remove(key);
    }
  }

  Future<void> _hydrate(String agentId, String sessionId, String key) async {
    final String dbPath = ConversationDbRegistry.pathFor(paths, agentId);
    // 先排干该 agent 的写队列：在途追加必须先落库，否则装载会漏掉最后几条。
    await _queue.drain(dbPath);
    final ConversationDb db = await conversationDb(agentId);
    final List<CoreMessage> list = <CoreMessage>[];
    for (final Map<String, dynamic> row in await db.detailRows(sessionId)) {
      list.add(
        CoreMessage.fromJson(
          Map<String, dynamic>.from(row['payload'] as Map),
        ),
      );
    }
    _messages[key] = list;
    CoreMessage? preview;
    for (final CoreMessage m in list.reversed) {
      if (!m.isTool && m.role == 'agent' && !m.isSubagentMessage) {
        preview = m;
        break;
      }
    }
    _preview[key] = preview;
  }

  // ── 装载 ─────────────────────────────────────────────────────────────

  /// 扫描 `agents/` 下的全部 agent 配置（一次）。
  Iterable<CoreAgent> _scanAgents() {
    if (_agentsScanned) return _agents.values;
    _agentsScanned = true;
    final Directory dir = Directory(paths.agentsDir);
    if (!dir.existsSync()) return _agents.values;
    for (final FileSystemEntity entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.yaml')) continue;
      final CoreAgent? agent = _readAgentFile(entity);
      if (agent != null) _agents[agent.id] = agent;
    }
    return _agents.values;
  }

  CoreAgent? _readAgentFile(File file) {
    try {
      // 手改坏的 yaml 不该让整个 agent 列表读不出来：容错解码（非法字节 U+FFFD 顶替），
      // 真解析不了会走下面的 catch 记日志跳过。
      final DecodedText decoded = PlatformTextDecoder.decodeTolerant(
        file.readAsBytesSync(),
      );
      if (decoded.decoding == TextDecoding.utf8Malformed) {
        log?.call('agent 配置含非法 UTF-8 字节，已按 U+FFFD 顶替后解析：${file.path}');
      }
      final Map<String, dynamic> map = YamlCodec.decode(decoded.text);
      final CoreAgent agent = CoreAgent.fromJson(map);
      if (agent.id.isEmpty) {
        log?.call('agent 配置缺少 id，已跳过：${file.path}');
        return null;
      }
      return agent;
    } catch (error) {
      log?.call('agent 配置解析失败（已跳过，不影响其他 agent）：${file.path}：$error');
      return null;
    }
  }

  /// 装载某 agent 的配置与其全部会话元数据（幂等，只做一次）。
  void _loadAgent(String agentId) {
    _scanAgents();
    if (!_agentLoaded.add(agentId)) return;
    _sessions[agentId] = <String, CoreSession>{};
    final File agentFile = File(paths.agentFile(agentId));
    if (agentFile.existsSync()) {
      final CoreAgent? agent = _readAgentFile(agentFile);
      // 磁盘是权威：缓存里若有同名（本轮新建）以磁盘为准
      if (agent != null) _agents[agentId] = agent;
    }
    final Directory agentDir = Directory(paths.agentDataDir(agentId));
    if (!agentDir.existsSync()) return;
    for (final FileSystemEntity entity in agentDir.listSync()) {
      if (entity is! Directory) continue;
      final File meta = File(p.join(entity.path, 'session.json'));
      if (!meta.existsSync()) continue;
      try {
        final DecodedText text = PlatformTextDecoder.decodeTolerant(
          meta.readAsBytesSync(),
        );
        if (text.decoding == TextDecoding.utf8Malformed) {
          log?.call('会话元数据含非法 UTF-8 字节，已按 U+FFFD 顶替后解析：${meta.path}');
        }
        final Object? decoded = jsonDecode(text.text);
        if (decoded is! Map<String, dynamic>) continue;
        final CoreSession session = CoreSession.fromJson(decoded);
        if (session.sessionId.isEmpty) continue;
        _sessions[agentId]![session.sessionId] = session;
      } catch (error) {
        log?.call('会话元数据损坏（已跳过）：${meta.path}：$error');
      }
    }
  }

  /// 同步装载入口已废除：消息改存会话库（conversation.semdb），装载走
  /// [ensureMessagesLoaded]。这里只剩"缓存命中检查"：未命中**记错误日志暴露**
  /// 调用方漏了 await，而不是静默给空列表（空列表会伪装成"会话没消息"）。
  void _loadMessages(String agentId, String sessionId) {
    _loadAgent(agentId);
    final String key = _key(agentId, sessionId);
    if (_messages.containsKey(key)) return;
    _messages[key] = <CoreMessage>[];
    log?.call(
      '消息缓存未装载就被同步读取（agent=$agentId session=$sessionId）：'
      '调用方需先 await ensureMessagesLoaded，本次按空会话继续。',
    );
  }

  /// 装载某会话的临时员工名册（幂等）：
  /// `data/<agentId>/<sessionId>/subagents.json`（人类可读、原子快照）。
  ///
  /// 坏文件**不阻断会话**：解析失败只记日志并当成空名册（与"坏消息行跳过"同一取舍）。
  void _loadSubagents(String agentId, String sessionId) {
    final String key = _key(agentId, sessionId);
    if (_subagents.containsKey(key)) return;
    _subagents[key] = <CoreSubagent>[];
    final String file = paths.subagentsFile(agentId, sessionId);
    final String? text = AtomicFile.readStringOrNullSync(file);
    if (text == null || text.trim().isEmpty) return;
    try {
      final Object? decoded = jsonDecode(text);
      final Object? raw = decoded is Map ? decoded['subagents'] : decoded;
      if (raw is! List) return;
      final List<CoreSubagent> out = <CoreSubagent>[];
      for (final Object? item in raw) {
        if (item is! Map) continue;
        final CoreSubagent subagent = CoreSubagent.fromJson(
          item.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
        );
        if (subagent.id.isEmpty) continue;
        out.add(subagent);
      }
      _subagents[key] = out;
    } catch (error) {
      log?.call('临时员工名册解析失败（当作空名册）：$file：$error');
    }
  }

  // ── 落盘 ─────────────────────────────────────────────────────────────

  static String _key(String agentId, String sessionId) =>
      '$agentId::$sessionId';

  void _writeAgent(CoreAgent agent) {
    final String file = paths.agentFile(agent.id);
    final String content = YamlCodec.encode(
      agent.toJson(),
      header: _agentHeader,
    );
    _queue.enqueue(file, () => AtomicFile.writeStringAtomic(file, content));
  }

  /// 落盘临时员工名册（原子快照；空名册也写，保持"该会话的范围内"这条不变量）。
  void _writeSubagents(String agentId, String sessionId) {
    final String file = paths.subagentsFile(agentId, sessionId);
    final String content = const JsonEncoder.withIndent('  ').convert(
      <String, dynamic>{
        'version': 1,
        'agent_id': agentId,
        'session_id': sessionId,
        'subagents': <Map<String, dynamic>>[
          for (final CoreSubagent s
              in _subagents[_key(agentId, sessionId)] ?? const <CoreSubagent>[])
            s.toJson(),
        ],
      },
    );
    _queue.enqueue(
      paths.sessionDir(agentId, sessionId),
      () => AtomicFile.writeStringAtomic(file, '$content\n'),
    );
  }

  void _writeSession(CoreSession session) {
    final String file = paths.sessionMetaFile(
      session.agentId,
      session.sessionId,
    );
    final String content = const JsonEncoder.withIndent('  ')
        .convert(session.toJson());
    _queue.enqueue(
      paths.sessionDir(session.agentId, session.sessionId),
      () => AtomicFile.writeStringAtomic(file, '$content\n'),
    );
  }
}
