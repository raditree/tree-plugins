import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../agent/agent_engine.dart';
import '../agent/compaction_service.dart';
import '../agent/conversation_service.dart';
import '../agent/question_broker.dart';
import '../agent/question_store.dart';
import '../agent/subagent_service.dart';
import '../agent_store.dart';
import '../compat/protocol_types.dart';
import '../llm/llm_agent_engine.dart';
import '../llm/llm_summarizer.dart';
import '../paths.dart';
import '../settings/core_settings.dart';
import '../settings/file_settings_sink.dart';
import '../spec/spec_service.dart';
import '../station/tool_contributions.dart';
import '../store/file_store.dart';
import '../store/records.dart';
import '../store/subagent_registry.dart';
import '../store/subagent_store.dart';
import '../store/tree_paths.dart';
import '../store/usage_log.dart';
import '../team/message_dispatcher.dart';
import '../team/team_service.dart';
import '../team/team_workspace.dart';
import '../tool/station_tool_runner.dart';
import '../tool/subagent_tool.dart';
import '../tool/tool_run_registry.dart';
import '../workspace/station_command.dart';
import '../workspace/station_compat_io.dart';
import '../workspace/station_workspace_io.dart';
import '../workspace/workspace_io.dart';
import '../ws/ws_hub.dart';

/// 插件进程内**单个数据根**的运行时：存储 + 设置 + 提问回路 + 会话服务 + 临时员工。
///
/// 为什么按数据根缓存：REST 是无状态的，但"在途生成 / 提问等待 / 排队代次"必须在
/// 多次请求之间共享；每次请求新建一套服务会让 stop 找不到在途轮次。
/// 生产只有一个数据根；测试/多实例可并存多个。
///
/// **A3 阶段引擎**：默认 `ScriptedAgent`（占位回显）。`LlmAgentEngine` 平移完成后
/// 在这里切成真实引擎；端点与协议形状不变。
class AgentRuntime {
  AgentRuntime({required this.paths, AgentEngine? engine})
    : store = FileTreeStore(TreePaths(paths.root)) {
    settings = CoreSettings.load(paths);
    settingsSink = FileDomainSettingsSink(TreePaths(paths.root));
    settings.domain.sink = settingsSink;
    registry = SubagentRegistry(persistence: store);
    hub = WsHub(
      onBroadcast: (Map<String, dynamic> frame) {
        frames.add(frame);
        if (frames.length > 2000) frames.removeAt(0);
      },
    );
    questionStore = FileQuestionStore(TreePaths(paths.root));
    questions = QuestionBroker(
      questions: questionStore,
      transcript: store,
      broadcast: hub.broadcast,
    );
    subagentService = SubagentService(
      store: SubagentStore(inner: store, registry: registry),
      registry: registry,
      settings: settings,
    );
    final UsageLog usageLog = UsageLog(TreePaths(paths.root));
    Map<String, Object?> overridesFor(String agentId) {
      for (final AgentRecord record in readAgentRecords(paths)) {
        if (record.id == agentId) return overridesOf(record);
      }
      return const <String, Object?>{};
    }

    compaction = CompactionService(
      store: store,
      settings: settings,
      summarizer: LlmSummarizer(
        resolveModel: (String modelId) => settings.model(modelId),
        agentOverrides: overridesFor,
      ),
    )..usageLog = usageLog;
    conversation = ConversationService(
      store: store,
      hub: hub,
      settings: settings,
      questions: questions,
      compaction: compaction,
      subagents: registry,
      engine: engine ??
          LlmAgentEngine(
            resolveModel: (String modelId) => settings.model(modelId),
            agentOverrides: overridesFor,
            usageLog: usageLog,
            toolRunner: StationToolRunner(
              contributed: () => contributedTools,
              client: (String command, Map<String, dynamic> arguments, Map<String, dynamic> scope) {
                final StationCommandClient? client = stationClient;
                if (client == null) {
                  throw StateError('执行站未接线：station/command 不可用');
                }
                return client(command, arguments, scope);
              },
              scopeFor: _stationScopeFor,
            ),
          ),
    );
    teamService = TeamService(
      store: store,
      settings: settings,
      isWorking: conversation.isRunning,
      toolRuns: toolRuns,
      defaultWorkspaceDir: TreePaths(paths.root).defaultWorkspaceDir,
    );
    messageDispatcher = TeamMessageDispatcher(
      store: store,
      teams: teamService,
      deliver:
          ({
            required String agentId,
            required String sessionId,
            required String content,
            String senderId = '',
            String senderName = '',
          }) => conversation.deliver(
            agentId: agentId,
            sessionId: sessionId,
            content: content,
            senderId: senderId,
            senderName: senderName,
          ),
      workspaceDirOf: _workspaceDirOf,
      ioFor: (String agentId) => workspaceIoFor(agentId, ''),
    );
    specService = SpecService(store: store)
      ..ioFor = (String agentId) => workspaceIoFor(agentId, '');

    subagentService.runner = conversation.runSubagent;
    subagentService.onFinished = (String owner, String session, String notice, SubagentTag tag) {
      unawaited(
        conversation.wake(
          agentId: tag.id,
          sessionId: session,
          notice: notice,
          subagent: tag,
        ),
      );
    };
  }

  final AgentDataPaths paths;
  final FileTreeStore store;
  late final CoreSettings settings;
  late final FileDomainSettingsSink settingsSink;
  late final SubagentRegistry registry;
  late final WsHub hub;
  late final FileQuestionStore questionStore;
  late final QuestionBroker questions;
  late final TeamService teamService;
  late final TeamMessageDispatcher messageDispatcher;
  late final SpecService specService;
  late final SubagentService subagentService;
  late final CompactionService compaction;
  late final ConversationService conversation;

  /// 运行中工具登记表（与核心同一实现；工具编排接线后由工具执行器登记）。
  late final ToolRunRegistry toolRuns = ToolRunRegistry();

  /// 已广播的帧（有上限，测试/排障用；运行期真正出口是 A4 的站内主题）。
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];

  Future<void>? _lastTurn;

  /// 核心执行站命令入口（由插件入口在 hello 后注入；null = 未接线）。
  static StationCommandClient? stationClient;

  /// 本插件 id 与收集站触发入口（入口在 hello 后注入）。
  static String pluginId = 'tree.agent';
  static StationTriggerClient? stationTrigger;

  /// 其它插件贡献的工具（最近一次采集结果）。
  final List<ContributedTool> contributedTools = <ContributedTool>[];

  static final Map<String, AgentRuntime> _byRoot = <String, AgentRuntime>{};

  /// 取（或创建）某个数据根的运行时。
  static AgentRuntime forDataDir(String dataDir) {
    final String root = p.normalize(Directory(dataDir).absolute.path);
    return _byRoot.putIfAbsent(root, () => AgentRuntime(paths: AgentDataPaths(root)));
  }

  /// 测试用：关掉全部缓存运行时。
  static Future<void> debugCloseAll() async {
    for (final AgentRuntime runtime in _byRoot.values.toList()) {
      await runtime.close();
    }
    _byRoot.clear();
  }

  /// 解析会话（与 `ConversationService._resolveSession` 同口径）。
  ///
  /// 返回是否本次新建；新建时同样广播 `session_created`（前端据此即时入列）。
  ({CoreSession session, bool created}) resolveSession(
    CoreAgent agent,
    String sessionId,
    String content,
  ) {
    if (sessionId.isEmpty) {
      final CoreSession created = store.createSession(
        agent.id,
        title: _titleFrom(content),
      )!;
      _broadcastSessionCreated(agent.id, created);
      return (session: created, created: true);
    }
    final CoreSession? existing = store.session(agent.id, sessionId);
    if (existing != null) return (session: existing, created: false);
    final CoreSession created = store.createSession(agent.id, sessionId: sessionId)!;
    _broadcastSessionCreated(agent.id, created);
    return (session: created, created: true);
  }

  void _broadcastSessionCreated(String agentId, CoreSession session) {
    hub.broadcast(<String, dynamic>{
      'type': WsOutboundType.sessionCreated,
      'data': <String, dynamic>{
        'agent_id': agentId,
        'session_id': session.sessionId,
        'title': session.title,
      },
    });
  }

  static String _titleFrom(String content) {
    final String text = content.trim();
    if (text.isEmpty) return '新会话';
    return text.length > 30 ? '${text.substring(0, 30)}…' : text;
  }

  /// 发送一条用户消息：落库 + 打断同会话在途轮次 + 入队生成。
  ///
  /// 返回 C-08 的成功体；agent 不存在返回 null（端点回 404）。
  /// **不等待本轮生成**——端点立刻回 200，帧通过 [frames] / 站内主题推送。
  Future<Map<String, dynamic>?> sendMessage({
    required String agentId,
    required String content,
    String sessionId = '',
    List<dynamic>? attachments,
  }) async {
    await refreshContributedTools();
    final CoreAgent? agent = store.agent(agentId);
    if (agent == null) return null;
    final (:CoreSession session, :bool created) = resolveSession(
      agent,
      sessionId,
      content,
    );
    final Future<void> turn = conversation.handleUserMessage(
      <String, dynamic>{
        'agent_id': agentId,
        'content': content,
        'session_id': session.sessionId,
        'attachments': attachments ?? const <dynamic>[],
      },
    );
    _lastTurn = turn;
    unawaited(
      turn.whenComplete(() {
        if (identical(_lastTurn, turn)) _lastTurn = null;
      }).catchError((Object _) {}),
    );
    return <String, dynamic>{
      'success': true,
      'agent_id': agentId,
      'session_id': session.sessionId,
      'session_created': created,
    };
  }

  /// 停止该 agent（TOP 级联团队树；成员只停自己），返回 C-08 摘要。
  ///
  /// agent 不存在返回 null（端点回 404）。
  Map<String, dynamic>? cancel(String agentId, {String sessionId = ''}) {
    final List<AgentRecord> records = readAgentRecords(paths);
    AgentRecord? self;
    for (final AgentRecord record in records) {
      if (record.id == agentId) {
        self = record;
        break;
      }
    }
    if (self == null) return null;
    final bool cascade = self.teamId.isEmpty;
    final List<String> ids = cascade
        ? <String>[
            agentId,
            ...rosterOf(records, self).map((AgentRecord m) => m.id),
          ]
        : <String>[agentId];
    final List<String> cancelled = <String>[];
    final List<String> idle = <String>[];
    for (final String id in ids) {
      final bool running = conversation.cancelAgent(id);
      if (running) {
        cancelled.add(id);
      } else {
        idle.add(id);
        hub.broadcast(<String, dynamic>{
          'type': WsOutboundType.agentStatus,
          'data': <String, dynamic>{
            'agent_id': id,
            'status': 'idle',
            if (sessionId.isNotEmpty) 'session_id': sessionId,
            'own_running': false,
          },
        });
      }
    }
    return <String, dynamic>{
      'cascade': cascade,
      'cascade_ids': ids,
      'cancelled': cancelled,
      'idle': idle,
      'any_running': cancelled.isNotEmpty,
    };
  }

  /// 工作空间根目录（本机绝对路径；SSH 团队返回空串）。
  String _workspaceDirOf(String agentId) {
    final CoreAgent? agent = store.agent(agentId);
    if (agent == null) return TreePaths(paths.root).defaultWorkspaceDir(agentId);
    if (teamSshConfigFor(agent, store.agent) != null) return '';
    final TeamWorkspace shared = teamWorkspaceFor(agent, store.agent);
    return shared.configuredDir.isNotEmpty
        ? shared.configuredDir
        : TreePaths(paths.root).defaultWorkspaceDir(shared.owner.id);
  }

  /// 触发工具贡献收集站并刷新缓存（无订阅者 / 未接线 ⇒ 空表，不阻断发消息）。
  Future<void> refreshContributedTools() async {
    final StationTriggerClient? trigger = stationTrigger;
    if (trigger == null) return;
    try {
      final Map<String, dynamic> response = await trigger(
        toolCollectStationId(pluginId),
        <String, dynamic>{'action': 'list'},
        <String, dynamic>{'purpose': 'agent.tools'},
        <String, dynamic>{'mode_key': 'local'},
      );
      contributedTools
        ..clear()
        ..addAll(parseContributedTools(response));
    } catch (_) {
      // 收集失败不阻断发送：工具表退回内置五项。
    }
  }

  /// 某个 agent 的工作空间 IO（经核心执行站；未接线时返回 null）。
  Future<WorkspaceIO?> workspaceIoFor(String agentId, String sessionId) async {
    final CoreAgent? agent = store.agent(agentId);
    if (agent == null) return null;
    final StationCommandClient? client = stationClient;
    if (client == null) return null;
    final Map<String, dynamic> scope = _stationScopeFor(agentId, sessionId);
    final String root = _workspaceDirOf(agentId);
    return StationCompatIo(
      StationWorkspaceIo(
        client: client,
        agentId: agentId,
        teamId: (scope['team_id'] ?? '').toString(),
        modeKey: (scope['mode_key'] ?? '').toString(),
        sessionId: sessionId,
        root: root,
      ),
    );
  }

  /// 执行站命令的身份：agent 的真实归属（TOP 自己 / 团队）与工作空间模式。
  Map<String, dynamic> _stationScopeFor(String agentId, String sessionId) {
    final CoreAgent? agent = store.agent(agentId);
    if (agent == null) {
      throw StateError('agent 不存在：$agentId');
    }
    final String team = agent.teamId.trim().isEmpty
        ? agent.id
        : agent.teamId.trim();
    final bool remote = teamSshConfigFor(agent, store.agent) != null;
    return <String, dynamic>{
      'agent_id': agentId,
      'team_id': team,
      'mode_key': remote ? 'ssh' : 'local',
      if (sessionId.isNotEmpty) 'session_id': sessionId,
    };
  }

  /// 等当前这一轮生成收尾（测试用；生产端点不等待）。
  Future<void> waitIdle() async {
    while (_lastTurn != null) {
      try {
        await _lastTurn;
      } catch (_) {
        // 生成失败由会话服务落成可见错误消息；这里只等它收尾。
      }
    }
  }

  /// 关停：中止在途生成并释放存储（幂等）。
  Future<void> close() async {
    conversation.dispose();
    questions.dispose();
    await store.close();
    _byRoot.removeWhere((String _, AgentRuntime runtime) => identical(runtime, this));
  }
}
