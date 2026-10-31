import 'dart:async';
import 'dart:convert';
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
import '../llm/llm_json_caller.dart';
import '../llm/llm_summarizer.dart';
import '../paths.dart';
import '../settings/core_settings.dart';
import '../settings/file_settings_sink.dart';
import '../settings/ssh_config.dart';
import '../spec/spec_service.dart';
import '../station/agent_executor.dart';
import '../station/agent_tools.dart';
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
import '../tool/message_tool.dart';
import '../tool/question_channel.dart';
import '../tool/spec_tool.dart';
import '../tool/station_tool_runner.dart';
import '../tool/team_tool.dart';
import '../tool/terminal_hook_manager.dart';
import '../tool/todo_store.dart';
import '../tool/subagent_tool.dart';
import '../tool/tool_run_registry.dart';
import '../tool/tool_runs_scope.dart';
import '../tool/tool_runs_tool.dart';
import '../tool/tool_runner.dart';
import '../workspace/station_command.dart';
import '../workspace/station_compat_io.dart';
import '../workspace/station_workspace_io.dart';
import '../workspace/workspace_io.dart';
import '../ws/ws_hub.dart';

/// 两个执行器的命令族前缀（契约 §8.1）：本机 `local.*`、SSH `ssh.*`，
/// **后缀逐字相同**，限定词正是 `StationScope.modeKey` 的两个取值。
const String kLocalStationCommandPrefix = 'local.';
const String kSshStationCommandPrefix = 'ssh.';

/// 本机执行站（`local_executor`）的租约登记命令与**租约失效码**（契约 §8.3）：
/// 看到后者才丢弃缓存租约、重新登记并重试一次（其余失败可能是写了一半，绝不重试）。
const String kLocalLeaseRegisterCommand = 'local.lease.register';

/// 租约失效的**唯一**码（本机与 SSH 同码，契约 §4.2 只登记 `lease_unknown`）。
const String kLeaseUnknownCode = 'lease_unknown';

/// 一条本机命令在 SSH 模式下的执行站命令名：前缀 `local.` 换 `ssh.`。
///
/// 过去这里是一张 16 项逐条映射表（`fs.*` / `file.*` / `terminal.exec` /
/// `exec.command` → `ssh.*`），而 `fs.*` 那半边是**假别名**：申报了却没人执行。
/// 现在两侧命令族逐字对称，改名规则只剩换前缀这一条；不带 `local.` 前缀的命令
/// （`todo.*` / `spec.*` / `plugin.*` 等）原样下发。
String? sshStationCommandFor(String command) {
  if (!command.startsWith(kLocalStationCommandPrefix)) return null;
  return kSshStationCommandPrefix +
      command.substring(kLocalStationCommandPrefix.length);
}

/// 一条命令是否走**本机执行站**（需要带插件侧租约句柄）。
bool isLocalStationCommand(String command) =>
    command.startsWith(kLocalStationCommandPrefix);

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
        // 本地留痕（测试 / 排障），并**同时**走 A4 的事件站出口。
        frames.add(frame);
        if (frames.length > 2000) frames.removeAt(0);
        publishAgentEvent(frame);
      },
    );
    todoStore = FileTodoStore(TreePaths(paths.root));
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
    usageLog = UsageLog(TreePaths(paths.root));
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
    // 宿主能力 `llm.call` 的落点：一次性调用，缺省硬设 JSON（显式 text 时改走
    // 对话同形态以复用前缀缓存）。账落在调用方给的会话上。
    llmCaller = LlmJsonCaller(
      resolveModel: (String modelId) => settings.model(modelId),
      agentOverrides: overridesFor,
    );
    terminalHooks = TerminalHookManager(
      client: _stationCommand,
      scopeFor: _stationScopeFor,
      wake: (String agentId, String sessionId, String notice) =>
          conversation.wake(
            agentId: agentId,
            sessionId: sessionId,
            notice: notice,
          ),
    );
    // 工具执行器**一份**：生成循环与宿主 `tool.call` 共用同一张工具表
    // （内置子集 + spec + 贡献工具），两条入口不许各建一份（否则表会漂）。
    stationToolRunner = StationToolRunner(
      contributed: () => contributedTools,
      toolRunsRunner: runToolRuns,
      specRunner: _runSpecTool,
      hooks: terminalHooks,
      client: _stationCommand,
      scopeFor: _stationScopeFor,
    );
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
            toolRunner: stationToolRunner,
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
  late final FileTodoStore todoStore;
  late final FileQuestionStore questionStore;
  late final QuestionBroker questions;
  late final TerminalHookManager terminalHooks;
  late final TeamService teamService;
  late final TeamMessageDispatcher messageDispatcher;
  late final SpecService specService;
  late final SubagentService subagentService;
  late final CompactionService compaction;
  late final ConversationService conversation;
  late final UsageLog usageLog;
  late final LlmJsonCaller llmCaller;

  /// 生成循环与宿主 `tool.call` 共用的工具执行器（构造期创建，只一份）。
  late final StationToolRunner stationToolRunner;

  /// 运行中工具登记表（与核心同一实现；工具编排接线后由工具执行器登记）。
  late final ToolRunRegistry toolRuns = ToolRunRegistry();

  /// 已广播的帧（有上限，测试/排障用；运行期真正出口是 A4 的站内主题）。
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];

  Future<void>? _lastTurn;

  /// 核心执行站命令入口（由插件入口在 hello 后注入；null = 未接线）。
  static StationCommandClient? stationClient;

  /// 本插件自建 `agent_tools` 执行站对外申报的命令。
  ///
  /// 领域原语来自 [kAgentToolCommands]；spec.* 是 S1 新增的规范域命令
  /// （见 [SpecTool.stationCommands]）；宿主能力五条来自 [kAgentHostCommands]
  /// （Q-7 (a)：llm.call / fs.read / tool.call / agent.compact / session.rename）。
  /// 执行站注册（入口）必须用这一份，否则 extra-tools 之类经站调用的插件会被核心
  /// 按“未知命令”拒绝。
  static List<String> get agentToolCommands => <String>[
    ...kAgentToolCommands,
    ...kAgentHostCommands,
    ...SpecTool.stationCommands,
  ];

  /// `agent_tools` 站 readme（在既有领域原语说明后补 spec.* 一句）。
  static String get agentToolsReadme =>
      '$kAgentToolsReadme spec.*：工作空间规范 list / read / select / create / update / reset。';

  /// 本插件 id 与收集站触发入口（入口在 hello 后注入）。
  static String pluginId = 'tree.agent';
  static StationTriggerClient? stationTrigger;

  /// **A4 事件站 id**：入口在 hello 后注册自建广播站时写入；空 = 未接线。
  static String eventsStationId = '';

  /// 把一帧领域事件发布到自建广播站（`station/trigger`）。
  ///
  /// topic 口径与协议包 `StationTopic` 一致：`<plugin_id>.<session_id>.<kind>`。
  /// **payload 原样是旧 WS 帧**——UI 侧只需换收口，不改渲染字段。
  ///
  /// 空 session_id 用 `_` 兜底（topic 三段都不能为空，否则订阅匹配不到）。
  /// `scope.mode_key` 决定"这条消息属于哪种工作面"：帧自身带 `mode_key` 就用它，
  /// 否则按 local（UI 订阅是通配，不因此丢帧）。
  static void publishAgentEvent(Map<String, dynamic> frame) {
    final StationTriggerClient? trigger = stationTrigger;
    final String stationId = eventsStationId;
    if (trigger == null || stationId.isEmpty) return;
    final String sessionId =
        (frame['session_id'] ?? frame['sessionId'] ?? '_').toString().trim();
    final String kind = (frame['type'] ?? 'event').toString().trim();
    if (kind.isEmpty) return;
    final String mode =
        (frame['mode_key'] ?? frame['mode'] ?? 'local').toString().trim();
    final Map<String, dynamic> scope = <String, dynamic>{
      'mode_key': mode == 'ssh' ? 'ssh' : 'local',
    };
    final String topic = '$pluginId.$sessionId.$kind';
    // 单向：投递结果不回灌业务（与核心 announce 同口径）；失败只留日志。
    unawaited(
      trigger(
            stationId,
            frame,
            <String, dynamic>{'plugin_id': pluginId},
            scope,
            topic: topic,
          )
          .catchError((Object error) => <String, dynamic>{'ok': false}),
    );
  }

  /// 其它插件贡献的工具（最近一次采集结果）。
  final List<ContributedTool> contributedTools = <ContributedTool>[];

  /// 本机工作空间租约缓存：`根目录` → 执行站返回的 `local_lease_id`。
  ///
  /// **租约表在 `local_executor` 那边**（契约 §8.3）：核心不再持有 `_workspaces`，
  /// 也不再往 arguments 里注入 `root`。同一根只登记一次。
  final Map<String, String> _localLeases = <String, String>{};

  /// SSH 工作空间租约缓存：`agentId + ssh 指纹` → (lease_id, conn_id, 远端根)。
  ///
  /// 与本机侧同构：远端根由 `ssh_executor` 执行站自己登记持有（`ssh.lease.register`），
  /// tree.agent 只缓存它的句柄。
  final Map<String, _SshWorkspaceLease> _sshLeases =
      <String, _SshWorkspaceLease>{};

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

  /// 显式重建目标 agent 的远端 SSH 链路（UI 的重连按钮走 REST 委派这条）。
  ///
  /// 命令表里**没有** `ssh.reconnect`，也不该有：两侧执行站各 10 条命令逐字对称，
  /// "重连"不是本机侧没有的能力。它落在 `ssh.lease.register` 上——那条命令本来就是
  /// "确保这条隧道在、并把租约登记回来"：链路已 `down` ⇒ 清零退避重来（见
  /// ssh_executor 的约定 4）；链路健康 ⇒ 复用不动（与 `tunnel.reconnect` 对健康
  /// 通道是 no-op 同一口径）。先丢缓存句柄，保证调用方拿到的是这一轮真实可用的连接。
  Future<Map<String, dynamic>> reconnectSsh(String agentId) async {
    final CoreAgent? agent = store.agent(agentId);
    final SshConfig? ssh = agent == null
        ? null
        : teamSshConfigFor(agent, store.agent);
    if (ssh == null) {
      throw StateError('该 agent 不是 SSH 工作空间：没有可重连的远端链路');
    }
    final _SshWorkspaceLease? dropped =
        _sshLeases.remove(_sshLeaseKey(agentId, ssh));
    final _SshWorkspaceLease lease = await _sshLeaseFor(agentId, ssh);
    return <String, dynamic>{
      'ok': true,
      'lease_id': lease.leaseId,
      'conn_id': lease.connId,
      'root': lease.root,
      // 「这一次是否丢弃过一条旧句柄」——调用方据此区分"重建"与"本来就是好的"。
      'stale': dropped != null,
    };
  }

  /// `tool_runs` 工具：作用域 = 本 agent + 直属下级，关闭落到同一登记表。
  Future<ToolOutcome> runToolRuns(ToolInvocation invocation) async {
    final String action =
        (invocation.arguments['action'] ?? '').toString().trim().toLowerCase();
    if (action == 'close') {
      final String handle =
          (invocation.arguments['handle'] ?? '').toString().trim();
      if (handle.isNotEmpty && terminalHooks.find(handle) != null) {
        return terminalHooks.cancel(handle);
      }
    }
    final ToolRunsScope scope = ToolRunsScope(
      registry: toolRuns,
      teamService: teamService,
      subagents: subagentService,
    );
    final ToolOutcome base = await ToolRunsTool.run(invocation, scope);
    if (action != 'list') return base;
    final List<HookRun> hooks = terminalHooks.listVisible(
      invocation.agentId,
      invocation.sessionId,
    );
    if (hooks.isEmpty) return base;
    final String extra = <String>[
      '后台终端任务（terminal hook）：',
      for (final HookRun run in hooks) '- ${run.describe()}',
    ].join('\n');
    return ToolOutcome('${base.content}\n\n$extra', isError: base.isError);
  }

  /// `spec` 工具的执行入口：解析工作空间后交给 [SpecTool]（工具层共用）。
  Future<ToolOutcome> _runSpecTool(ToolInvocation invocation) async {
    final WorkspaceIO? io = await workspaceIoFor(
      invocation.agentId,
      invocation.sessionId,
    );
    return SpecTool.run(invocation, specService, io);
  }

  /// 领域工具原语（extra-tools 插件经自建执行站调用）。
  Future<Map<String, dynamic>> handleAgentToolCommand(
    String command,
    Map<String, dynamic> arguments,
    Map<String, dynamic> scope,
  ) async {
    final String agentId = (scope['agent_id'] ?? '').toString();
    if (agentId.isEmpty || store.agent(agentId) == null) {
      return <String, dynamic>{'text': 'agent 不存在：$agentId', 'is_error': true};
    }
    final String rawSession = (scope['session_id'] ?? '').toString();
    final String sessionId = rawSession.isEmpty ? 'session_default' : rawSession;
    final ToolInvocation invocation = ToolInvocation(
      id: 'extra-tools-$command',
      name: command.split('.').first,
      arguments: arguments,
      agentId: agentId,
      sessionId: sessionId,
    );
    switch (command) {
      case 'todo.get':
        return _todoReply(todoStore.read(agentId, sessionId));
      case 'todo.set':
      case 'todo.update':
        final List<TodoItem> current = todoStore.read(agentId, sessionId);
        final List<Map<String, dynamic>> raw = <Map<String, dynamic>>[
          for (final Object? item in (arguments['todos'] as List<dynamic>? ?? const <dynamic>[]))
            if (item is Map)
              item.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
        ];
        if (raw.isEmpty) {
          return const <String, dynamic>{'text': 'todos 不能为空', 'is_error': true};
        }
        final Map<String, TodoItem> byId = <String, TodoItem>{
          for (final TodoItem item in current) item.id: item,
        };
        for (int i = 0; i < raw.length; i++) {
          final Map<String, dynamic> item = raw[i];
          final String content = (item['content'] ?? '').toString().trim();
          if (content.isEmpty) {
            return <String, dynamic>{'text': '第 ${i + 1} 项缺少 content', 'is_error': true};
          }
          final String id = (item['id'] ?? 't${i + 1}').toString();
          byId[id] = TodoItem(
            id: id,
            content: content,
            status: (item['status'] ?? 'pending').toString(),
            progress: (item['progress'] as num?)?.toInt() ?? 0,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          );
        }
        final List<TodoItem> next = command == 'todo.update'
            ? <TodoItem>[for (final TodoItem item in current) byId[item.id] ?? item]
            : byId.values.toList();
        todoStore.write(agentId, sessionId, next);
        return _todoReply(next);
      case 'todo.clear':
        todoStore.write(agentId, sessionId, <TodoItem>[]);
        return const <String, dynamic>{'text': '已清空待办。', 'todos': <Map<String, dynamic>>[], 'is_error': false};
      case 'question.ask':
        final List<AskedQuestion> asked = <AskedQuestion>[];
        final Object? rawQuestions = arguments['questions'];
        if (rawQuestions is List) {
          for (final Object? raw in rawQuestions) {
            if (raw is Map) {
              asked.add(AskedQuestion.fromJson(
                raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
              ));
            }
          }
        }
        if (asked.isEmpty) {
          final String question = (arguments['question'] ?? '').toString().trim();
          if (question.isEmpty) {
            return const <String, dynamic>{'text': 'question.ask 需要 question', 'is_error': true};
          }
          asked.add(AskedQuestion.single(question));
        }
        final QuestionOutcome outcome = await questions.ask(
          AskQuestionRequest(
            agentId: agentId,
            sessionId: sessionId,
            questions: asked,
            isCancelled: () => false,
          ),
        );
        return <String, dynamic>{
          'text': outcome.cancelled ? '提问已取消（未作答）' : formatAnswerLines(asked, outcome.answers),
          'answers': outcome.answers,
          'cancelled': outcome.cancelled,
          'is_error': false,
        };
      case 'subagent.run':
        final ToolOutcome r = await SubagentTool.run(invocation, subagentService);
        return <String, dynamic>{'text': r.content, 'is_error': r.isError};
      case 'team.run':
        final ToolOutcome r = await TeamTool.run(invocation, teamService);
        return <String, dynamic>{'text': r.content, 'is_error': r.isError};
      case 'message.run':
        final ToolOutcome r = await MessageTool.run(invocation, messageDispatcher);
        return <String, dynamic>{'text': r.content, 'is_error': r.isError};
      case 'llm.call':
      case 'fs.read':
      case 'tool.call':
      case 'agent.compact':
      case 'session.rename':
        return _handleHostCommand(command, arguments, invocation, scope);
      case 'spec.list':
      case 'spec.read':
      case 'spec.select':
      case 'spec.create':
      case 'spec.update':
      case 'spec.reset':
        final WorkspaceIO? io = await workspaceIoFor(agentId, sessionId);
        if (io == null) {
          return const <String, dynamic>{
            'text': '工作空间不可用（未接线 / SSH 配置不完整），无法执行 spec 工具',
            'is_error': true,
          };
        }
        final Map<String, dynamic> result = await SpecTool.runAction(
          service: specService,
          io: io,
          invocation: invocation,
          action: command.split('.').last,
        );
        return <String, dynamic>{
          'text': const JsonEncoder.withIndent('  ').convert(result),
          'is_error': result.containsKey('error'),
        };
      default:
        return <String, dynamic>{'text': '未知领域工具命令：$command', 'is_error': true};
    }
  }

  /// **宿主能力命令**（`kAgentHostCommands`）：Q-5 A 让名后由 tree.agent 认领。
  ///
  /// 回包与核心信封同形：`error` 非空 ⇒ 核心按失败处理，但 `payload` 会一起带回
  /// 调用方（`StationReply.failedWith`）——`llm.call` 的"已付费正文"靠它抢救。
  Future<Map<String, dynamic>> _handleHostCommand(
    String command,
    Map<String, dynamic> arguments,
    ToolInvocation invocation,
    Map<String, dynamic> scope,
  ) async {
    switch (command) {
      case 'llm.call':
        return _llmCall(arguments, invocation.agentId, invocation.sessionId);
      case 'fs.read':
        return _fsRead(arguments, invocation.agentId, invocation.sessionId);
      case 'tool.call':
        return _toolCall(arguments, invocation.agentId, invocation.sessionId);
      case 'agent.compact':
        return _agentCompact(arguments, invocation.agentId);
      case 'session.rename':
        return _sessionRename(
          arguments,
          invocation.agentId,
          invocation.sessionId,
        );
      default:
        return <String, dynamic>{'error': '未知宿主命令：$command'};
    }
  }

  /// 一次性 LLM 调用（复用目标 agent 的模型与成员级覆盖）。
  ///
  /// 返回形状与旧核心的 `llm.call` 逐字一致：成功 `{ok, json, text, model, usage}`；
  /// 失败 `{error, error_kind?, text, text_length, truncated_suspect?, model}`。
  /// `response_format: "text"` 时**不发**该字段（为复用对话前缀缓存，见节点 #27）。
  Future<Map<String, dynamic>> _llmCall(
    Map<String, dynamic> arguments,
    String agentId,
    String sessionId,
  ) async {
    final CoreAgent? agent = store.agent(agentId);
    if (agent == null) return <String, dynamic>{'error': 'agent 不存在：$agentId'};
    final Object? rawMessages = arguments['messages'];
    final Object? rawTools = arguments['tools'];
    return llmCaller.call(
      agentId: agentId,
      modelId: agent.modelId,
      messages: rawMessages is List ? rawMessages : null,
      prompt: _text(arguments['prompt']),
      system: _text(arguments['system']),
      model: _text(arguments['model']),
      temperature: _number(arguments['temperature'])?.toDouble(),
      maxTokens: _number(arguments['max_tokens'])?.toInt(),
      tools: rawTools is List ? rawTools : null,
      responseFormat: _responseFormatOf(arguments['response_format']),
      usageSink: sessionId.isEmpty ? null : usageLog.sinkFor(sessionId),
    );
  }

  static String? _responseFormatOf(Object? raw) {
    final String value = raw is Map ? _text(raw['type']) : _text(raw);
    return value.toLowerCase() == 'text' ? 'text' : null;
  }

  /// 读目标 agent 工作空间里的文件（目录解析只在 tree.agent 里做一份）。
  ///
  /// 回包键与执行站的 `file.read` 对齐：`{path, content, total_lines, start_line,
  /// truncated}`（二进制内容额外带 `base64`）。
  Future<Map<String, dynamic>> _fsRead(
    Map<String, dynamic> arguments,
    String agentId,
    String sessionId,
  ) async {
    final String path = _text(arguments['path']).isEmpty
        ? _text(arguments['file_path'])
        : _text(arguments['path']);
    if (path.isEmpty) {
      return <String, dynamic>{'error': 'fs.read 需要 path'};
    }
    final WorkspaceIO? io = await workspaceIoFor(agentId, sessionId);
    if (io == null) {
      return <String, dynamic>{'error': '工作空间不可用（执行站未接线或该 agent 没有工作空间）'};
    }
    try {
      final FileContent content = await io.readFile(
        path,
        startLine: _number(arguments['start_line'])?.toInt(),
        lineCount: _number(arguments['line_count'])?.toInt(),
      );
      return <String, dynamic>{
        'path': path,
        'content': content.text,
        'total_lines': content.totalLines,
        'start_line': content.startLine,
        'truncated': content.truncated,
        if (content.base64 != null) 'base64': content.base64,
      };
    } catch (error) {
      return <String, dynamic>{'error': '$error'};
    }
  }

  /// 执行任意工具：贡献工具经 `plugin.toolCall` 转给贡献插件，其余走本插件的工具表。
  ///
  /// 口径与旧核心一致：**命令本身成功 = `ok:true`**；工具自己的失败只体现在
  /// `is_error:true` + `result` 文本里（模型与插件读同一段可读原因）。
  Future<Map<String, dynamic>> _toolCall(
    Map<String, dynamic> arguments,
    String agentId,
    String sessionId,
  ) async {
    final String tool = _text(arguments['tool']);
    if (tool.isEmpty) return <String, dynamic>{'error': 'tool.call 需要 tool'};
    final Object? rawArguments = arguments['arguments'];
    final Map<String, dynamic> callArguments = rawArguments is Map
        ? rawArguments.map(
            (dynamic key, dynamic value) => MapEntry(key.toString(), value),
          )
        : <String, dynamic>{};
    ContributedTool? contributed;
    if (contributedTools.isEmpty) await refreshContributedTools();
    for (final ContributedTool item in contributedTools) {
      if (item.name == tool || item.coreName == tool) {
        contributed = item;
        break;
      }
    }
    if (contributed != null) {
      final Map<String, dynamic> forwarded = await _stationCommand(
        'plugin.toolCall',
        <String, dynamic>{
          'plugin_id': contributed.pluginId,
          'tool': contributed.coreName,
          'arguments': callArguments,
          'scope': _stationScopeFor(agentId, sessionId),
        },
        const <String, dynamic>{},
      );
      return <String, dynamic>{
        'tool': tool,
        'result': (forwarded['result'] ?? '').toString(),
        'is_error': forwarded['is_error'] == true,
        // 转给贡献插件不算工具中转；本插件没有 relay 挂钩。
        'relayed': false,
      };
    }
    final ToolOutcome outcome = await stationToolRunner.run(
      ToolInvocation(
        id: 'tool.call-${DateTime.now().microsecondsSinceEpoch}',
        name: tool,
        arguments: callArguments,
        agentId: agentId,
        sessionId: sessionId,
      ),
    );
    return <String, dynamic>{
      'tool': tool,
      'result': outcome.content,
      'is_error': outcome.isError,
      'relayed': false,
    };
  }

  /// 手动压缩一次：与 REST `/compact` 同一个实现（生成中的 agent 拒绝）。
  Future<Map<String, dynamic>> _agentCompact(
    Map<String, dynamic> arguments,
    String agentId,
  ) async {
    final String sessionId = _text(arguments['session_id']);
    if (conversation.isRunning(agentId)) {
      return <String, dynamic>{
        'success': true,
        'compressed': false,
        'reason': 'agent_working',
        'context_size': 0,
      };
    }
    final CompactionResult result = await compaction.compact(agentId, sessionId);
    return result.toJson();
  }

  /// 改会话标题；空标题**显式拒绝**（store 层"空标题=不改名"不能在命令层静默成功）。
  ///
  /// 改名后广播 `session_renamed` 帧：前端没有"插件发起"的本地路径，不推就看不到。
  Future<Map<String, dynamic>> _sessionRename(
    Map<String, dynamic> arguments,
    String agentId,
    String sessionId,
  ) async {
    final String title = _text(arguments['title']);
    if (title.isEmpty) {
      return <String, dynamic>{'error': 'session.rename 需要非空 title'};
    }
    final String target = sessionId.isEmpty ? 'session_default' : sessionId;
    if (!store.renameSession(agentId, target, title)) {
      return <String, dynamic>{'error': '会话不存在：$target'};
    }
    hub.broadcast(<String, dynamic>{
      'type': WsOutboundType.sessionRenamed,
      'data': <String, dynamic>{
        'agent_id': agentId,
        'session_id': target,
        'title': title,
      },
    });
    return <String, dynamic>{
      'renamed': true,
      'title': title,
      'session_id': target,
    };
  }

  static String _text(Object? value) =>
      value == null ? '' : '$value'.trim();

  static num? _number(Object? value) =>
      value is num ? value : num.tryParse('${value ?? ''}'.trim());

  Map<String, dynamic> _todoReply(List<TodoItem> todos) => <String, dynamic>{
    'text': todos.isEmpty
        ? '（暂无待办）'
        : <String>[
            for (final TodoItem item in todos)
              '${item.id} [${item.status}] ${item.progress}% ${item.content}',
          ].join('\n'),
    'todos': <Map<String, dynamic>>[for (final TodoItem item in todos) item.toApiJson()],
    'is_error': false,
  };

  /// 「激活指定 agent 执行器」执行站入口（命令见 `station/agent_executor.dart`）。
  ///
  /// 回包**不抛异常**：成败都在 `ok` 上，调用方（其它插件 / UI 的 REST 层）
  /// 只看一种形状，不必按平台分叉。
  Future<Map<String, dynamic>> handleAgentExecutorCommand(
    String command,
    Map<String, dynamic> arguments,
    Map<String, dynamic> scope,
  ) {
    final String agentId =
        (arguments['agent_id'] ?? scope['agent_id'] ?? '').toString();
    if (command != kActivateExecutorCommand) {
      return Future<Map<String, dynamic>>.value(
        _activationFailure(agentId, '执行站不支持命令：$command'),
      );
    }
    return activateAgentExecutor(agentId);
  }

  /// 激活某个 agent 的执行器（local 检查 / ssh 真建连）。
  ///
  /// - **local**：确保工作空间存在且可写，回报设备基本信息。这是"检查"，不建连接；
  /// - **ssh**：经 `ssh.lease.register` 建到目标机的连接并登记远端租约，回报
  ///   `ssh_lease_id` / `conn_id` / `root`；同一 agent + 同一份 SSH 配置走缓存
  ///   （重复激活不会重复建连）。
  Future<Map<String, dynamic>> activateAgentExecutor(String agentId) async {
    final String id = agentId.trim();
    if (id.isEmpty) return _activationFailure('', '缺少 agent_id');
    final CoreAgent? agent = store.agent(id);
    if (agent == null) return _activationFailure(id, 'agent 不存在：$id');
    final Map<String, dynamic> device = _deviceInfo();
    final SshConfig? ssh = teamSshConfigFor(agent, store.agent);
    if (ssh == null) {
      final String root = _workspaceDirOf(id);
      if (root.isEmpty) {
        return _activationFailure(id, '本机工作空间未解析出目录（agent=$id）');
      }
      try {
        final Directory dir = Directory(root);
        if (!dir.existsSync()) dir.createSync(recursive: true);
        // 写一个探针文件再删掉：只看 exists 会把"只读目录"误判成可用。
        final File probe = File(
          p.join(
            dir.path,
            '.tree_probe_${pid}_${DateTime.now().microsecondsSinceEpoch}',
          ),
        );
        probe.writeAsStringSync('ok', flush: true);
        probe.deleteSync();
      } catch (error) {
        return _activationFailure(id, '本机工作空间不可写：$root（$error）');
      }
      return <String, dynamic>{
        'ok': true,
        'mode': 'local',
        'executor': 'local_executor',
        'agent_id': id,
        'workspace': root,
        'device': device,
        'text': '本机执行器就绪：${device['os']} / ${device['hostname']} / $root',
      };
    }
    try {
      final _SshWorkspaceLease lease = await _sshLeaseFor(id, ssh);
      return <String, dynamic>{
        'ok': true,
        'mode': 'ssh',
        'executor': 'ssh_executor',
        'agent_id': id,
        'root': lease.root,
        'ssh_lease_id': lease.leaseId,
        'conn_id': lease.connId,
        'host': ssh.host,
        'device': device,
        'text': 'SSH 执行器已激活：${ssh.username}@${ssh.host} → ${lease.root}',
      };
    } catch (error) {
      return _activationFailure(id, 'SSH 执行器激活失败：$error');
    }
  }

  Map<String, dynamic> _activationFailure(String agentId, String message) =>
      <String, dynamic>{
        'ok': false,
        'agent_id': agentId,
        'error': message,
        'text': message,
      };

  /// 设备基本信息（本机激活一并回报，方便调用方统一展示）。
  ///
  /// 刻意只放**事实**：不给远端设备做任何推断（ssh 激活时这里仍是本机信息，
  /// 远端的真实情况由 `agent.hello` 负责）。
  Map<String, dynamic> _deviceInfo() => <String, dynamic>{
    'os': Platform.operatingSystem,
    'os_version': Platform.operatingSystemVersion,
    'hostname': Platform.localHostname,
    'processors': Platform.numberOfProcessors,
    'dart': Platform.version.split(' ').first,
  };

  /// 执行站命令的统一出口：**`local.*` 命令自动带本机租约；SSH 模式的同一命令换前缀下发**。
  ///
  /// 两条路必须分清（2026-10-25，任务 C；租约口径 2026-10-31 契约 §8.3）：
  /// - **本机**：向 `local_executor` 的站发一次 `local.lease.register {dir}` →
  ///   后续命令带 `local_lease_id`。**核心不再持有租约**，`root` 只存在于执行器那张表里；
  /// - **SSH**：远端根在本机不存在 ⇒ 命令名换成 `ssh.*`（同后缀、只换前缀），租约由
  ///   `ssh_executor` 执行站登记（`ssh.lease.register`），后续命令带 `ssh_lease_id`。
  ///   **绝不降级回本机命令**：执行站不可用时显式失败（否则会静默读写本机工作空间）。
  ///
  /// 两侧的"租约失效 ⇒ 重登记并只重试一次"是同一条判据：只有 `*_lease_unknown`
  /// 才是**确定未执行**、可安全重发的失败；其它失败可能已经写了一半，绝不重放。
  Future<Map<String, dynamic>> _stationCommand(
    String command,
    Map<String, dynamic> arguments,
    Map<String, dynamic> scope,
  ) async {
    final StationCommandClient? client = stationClient;
    if (client == null) {
      throw StateError('执行站未接线：station/command 不可用');
    }
    final String agentId = (scope['agent_id'] ?? '').toString();
    if (isLocalStationCommand(command) && agentId.isNotEmpty) {
      final CoreAgent? agent = store.agent(agentId);
      final SshConfig? ssh =
          agent == null ? null : teamSshConfigFor(agent, store.agent);
      if (ssh != null) {
        final String sshCommand = sshStationCommandFor(command)!;
        final _SshWorkspaceLease lease = await _sshLeaseFor(agentId, ssh);
        try {
          return await client(
            sshCommand,
            _sshArguments(arguments, lease),
            scope,
          );
        } catch (error) {
          if (!_isLeaseUnknown(error)) rethrow;
          _sshLeases.remove(_sshLeaseKey(agentId, ssh));
          final _SshWorkspaceLease renewed = await _sshLeaseFor(agentId, ssh);
          return client(
            sshCommand,
            _sshArguments(arguments, renewed),
            scope,
          );
        }
      }
      // 本机：租约由执行器插件持有（同一根只登记一次）。
      final String root = _workspaceDirOf(agentId);
      if (root.isNotEmpty) {
        final String leaseId = await _localLeaseFor(root, scope);
        try {
          return await client(
            command,
            <String, dynamic>{...arguments, 'local_lease_id': leaseId},
            scope,
          );
        } catch (error) {
          if (!_isLeaseUnknown(error)) rethrow;
          _localLeases.remove(root);
          final String renewed = await _localLeaseFor(root, scope);
          return client(
            command,
            <String, dynamic>{...arguments, 'local_lease_id': renewed},
            scope,
          );
        }
      }
    }
    return client(command, arguments, scope);
  }

  /// 失败是否**确定未执行**（只有 `lease_unknown` 这一个码可以安全重发）。
  ///
  /// 判据必须是结构化错误码，不是消息文本：过去两侧各扫 `*_lease_unknown`
  /// 前缀，插件换文案就会静默失去重登记能力（契约 §4.1）。
  static bool _isLeaseUnknown(Object error) =>
      error is StationCommandFailure && error.code == kLeaseUnknownCode;

  /// 取（或登记）本机工作空间租约（`local_executor` 侧那张表）。
  ///
  /// 确定性 id：同一个根永远算出同一个 `local_lease_id`，插件重启后重登记也不会
  /// 换键；目录必须已存在（执行器拒登记不存在的目录），所以这里补建。
  Future<String> _localLeaseFor(
    String root,
    Map<String, dynamic> scope,
  ) async {
    final String? cached = _localLeases[root];
    if (cached != null) return cached;
    final StationCommandClient? client = stationClient;
    if (client == null) {
      throw StateError('执行站未接线：本机工作空间租约不可用');
    }
    final Directory dir = Directory(root);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final String leaseId = _localLeaseId(dir.absolute.path);
    final Map<String, dynamic> result = await client(
      kLocalLeaseRegisterCommand,
      <String, dynamic>{
        'dir': p.normalize(dir.absolute.path),
        'local_lease_id': leaseId,
      },
      scope,
    );
    final String id = (result['lease_id'] ?? leaseId).toString();
    _localLeases[root] = id;
    return id;
  }

  /// 本机租约句柄（同一根 ⇒ 同一 id，与执行器的兜底算法同一形状）。
  static String _localLeaseId(String root) =>
      'local_ws_${base64Url.encode(utf8.encode(p.normalize(root))).replaceAll('=', '')}';

  /// 以某 agent 的身份下发一条执行站命令（工具 / 工作空间 / 测试共用同一条路由）。
  Future<Map<String, dynamic>> dispatchStationCommand(
    String agentId,
    String command,
    Map<String, dynamic> arguments, {
    String sessionId = '',
  }) => _stationCommand(
    command,
    arguments,
    _stationScopeFor(agentId, sessionId),
  );

  /// SSH 执行站命令参数：只带插件侧的远端租约句柄。
  ///
  /// **不带 `root`**（契约 §8.3 第 2 条）：远端根由 `ssh_executor` 按租约自己查，
  /// arguments 里出现的 `root` 即使发出去也会被核心的 `sanitizeStationArguments`
  /// 剥掉，留在这里只会让两侧形状不一致。同理剥掉本机侧的句柄键。
  static Map<String, dynamic> _sshArguments(
    Map<String, dynamic> arguments,
    _SshWorkspaceLease lease,
  ) {
    final Map<String, dynamic> outgoing = <String, dynamic>{...arguments}
      ..remove('local_lease_id')
      ..remove('root');
    return <String, dynamic>{
      ...outgoing,
      'ssh_lease_id': lease.leaseId,
    };
  }

  /// 取（或登记）SSH 工作空间租约。
  ///
  /// 凭据**只在登记时过线一次**（`ssh.toJson()`）；后续命令只带 `ssh_lease_id`。
  /// 插件重启后租约失效 ⇒ 执行站回 `ssh_lease_unknown` ⇒ 这里重登记一次。
  Future<_SshWorkspaceLease> _sshLeaseFor(String agentId, SshConfig ssh) async {
    final String key = _sshLeaseKey(agentId, ssh);
    final _SshWorkspaceLease? cached = _sshLeases[key];
    if (cached != null) return cached;
    final StationCommandClient? client = stationClient;
    if (client == null) {
      throw StateError('执行站未接线：SSH 工作空间租约不可用');
    }
    final String leaseId = _sshLeaseId(ssh);
    final Map<String, dynamic> result;
    try {
      result = await client(
        'ssh.lease.register',
        <String, dynamic>{
          'ssh': ssh.toJson(),
          'ssh_lease_id': leaseId,
        },
        _stationScopeFor(agentId, ''),
      );
    } catch (error) {
      throw WorkspaceIoException(
        'SSH 工作空间租约登记失败（ssh_executor 执行站不可用？）：$error',
      );
    }
    final _SshWorkspaceLease lease = _SshWorkspaceLease(
      leaseId: (result['lease_id'] ?? leaseId).toString(),
      connId: (result['conn_id'] ?? '').toString(),
      root: (result['root'] ?? '').toString().trim(),
    );
    if (lease.root.isEmpty || !lease.root.startsWith('/')) {
      throw WorkspaceIoException(
        'SSH 工作空间租约登记未返回远端绝对根（agent=$agentId）',
      );
    }
    _sshLeases[key] = lease;
    return lease;
  }

  /// 租约缓存键：同一个 agent 的 SSH 配置变了（host/root/login_shell）就重新登记。
  static String _sshLeaseKey(String agentId, SshConfig ssh) =>
      '$agentId|${_sshLeaseId(ssh)}';

  /// 确定性租约 id（与 ssh_executor 侧同形；仅作标识，不参与路径解析）。
  static String _sshLeaseId(SshConfig ssh) {
    final String loginShell = ssh.loginShell == null
        ? '~'
        : (ssh.loginShell!.isEmpty ? '!' : ssh.loginShell!);
    final String identity = <String>[
      ssh.host,
      ssh.port.toString(),
      ssh.username,
      ssh.root,
      loginShell,
    ].join('|');
    return 'ssh_ws_${base64Url.encode(utf8.encode(identity)).replaceAll('=', '')}';
  }

  /// 工作空间根目录（本机绝对路径；SSH 团队返回空串）。
  ///
  /// SSH 返回空串是**刻意的**：本机租约登记要求目录在本机真实存在，远端根不可能
  /// 满足；SSH 的租约路径见 [_sshLeaseFor]（同样是插件侧租约，只是登记在
  /// `ssh_executor` 那张表里）。
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
    if (stationClient == null) return null;
    final Map<String, dynamic> scope = _stationScopeFor(agentId, sessionId);
    String root = _workspaceDirOf(agentId);
    if (root.isEmpty) {
      // SSH：这里给的是**工作空间身份**而不是本机路径——只有登记租约后才知道远端
      // 绝对根；而 WorkspaceIO.root 还被 vision file_id 缓存当键（换主机/账号/根
      // 必须换键），所以带上 host/port/user。真正路径解析在 ssh_executor 站内完成。
      final SshConfig? ssh = teamSshConfigFor(agent, store.agent);
      if (ssh != null) {
        final String configured = ssh.root.isEmpty ? '~' : ssh.root;
        final String user = ssh.username.isEmpty ? '-' : ssh.username;
        root = 'ssh://$user@${ssh.host}:${ssh.port}/$configured';
      }
    }
    return StationCompatIo(
      StationWorkspaceIo(
        client: _stationCommand,
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

/// tree.agent 视角的 SSH 工作空间租约（句柄；真实状态在 `ssh_executor` 执行站里）。
class _SshWorkspaceLease {
  const _SshWorkspaceLease({
    required this.leaseId,
    required this.connId,
    required this.root,
  });

  final String leaseId;

  /// ssh_executor 的隧道会话 id（诊断 / 测试用；不参与命令参数）。
  final String connId;

  /// 目标机上的绝对工作空间根（执行站登记时由 `agent.hello.root` 回填）。
  final String root;
}
