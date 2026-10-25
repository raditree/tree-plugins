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
import '../tool/message_tool.dart';
import '../tool/question_channel.dart';
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
              toolRunsRunner: runToolRuns,
              mcpRunner: runMcpTool,
              hooks: terminalHooks,
              client: _stationCommand,
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

  /// 工作空间租约登记（通知；由入口在 hello 后注入）。
  static Future<void> Function(String workspaceId, String dir)? workspaceRegister;

  /// 其它插件贡献的工具（最近一次采集结果）。
  final List<ContributedTool> contributedTools = <ContributedTool>[];

  /// 工作空间根 → 租约 id / 已登记集合（同一根只登记一次）。
  final Map<String, String> _workspaceIds = <String, String>{};
  final Set<String> _registeredWorkspaces = <String>{};

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

  /// 显式重建目标 agent 的远端 SSH 链路（经核心执行站 ssh.reconnect）。
  Future<Map<String, dynamic>> reconnectSsh(String agentId) async {
    final StationCommandClient? client = stationClient;
    if (client == null) {
      throw StateError('执行站未接线：ssh.reconnect 不可用');
    }
    final Map<String, dynamic> scope = _stationScopeFor(agentId, '');
    return client('ssh.reconnect', <String, dynamic>{'agent_id': agentId}, scope);
  }

  /// `mcp` 元工具：help 汇总 MCP 插件自发现的工具；call 兜底调用。
  Future<ToolOutcome> runMcpTool(ToolInvocation invocation) async {
    final StationCommandClient? client = stationClient;
    if (client == null) {
      return const ToolOutcome('MCP 插件未接线（执行站不可用）', isError: true);
    }
    final Map<String, dynamic> scope = _stationScopeFor(
      invocation.agentId,
      invocation.sessionId,
    );
    final String action =
        (invocation.arguments['action'] ?? '').toString().trim();
    try {
      if (action == 'help') {
        final Map<String, dynamic> inventory = await client(
          'inventory',
          <String, dynamic>{},
          scope,
        );
        final List<String> lines = <String>['可用 MCP 工具列表:'];
        final List<dynamic> servers =
            inventory['servers'] as List<dynamic>? ?? <dynamic>[];
        for (final Object? rawServer in servers) {
          if (rawServer is! Map) continue;
          final String server = (rawServer['server'] ?? '').toString();
          final List<dynamic> tools =
              rawServer['tools'] as List<dynamic>? ?? <dynamic>[];
          for (final Object? rawTool in tools) {
            if (rawTool is! Map) continue;
            final String tool = (rawTool['name'] ?? '').toString();
            final String description = (rawTool['description'] ?? '').toString();
            lines.add(
              '- mcp__${server}__$tool${description.isEmpty ? '' : ': $description'}',
            );
          }
        }
        if (lines.length == 1) {
          lines.add('当前没有可用的 MCP 工具（检查 MCP 服务配置）。');
        }
        return ToolOutcome(lines.join('\n'));
      }
      if (action == 'call') {
        final String toolName =
            (invocation.arguments['tool_name'] ?? '').toString().trim();
        final List<String> parts = toolName.split('__');
        if (parts.length != 3 || parts[0] != 'mcp') {
          return ToolOutcome(
            'tool_name 必须是 mcp__<服务>__<工具>：$toolName',
            isError: true,
          );
        }
        final Object? rawArgs = invocation.arguments['arguments'];
        final Map<String, dynamic> args = rawArgs is Map
            ? rawArgs.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
            : <String, dynamic>{};
        final Map<String, dynamic> result = await client(
          'call_tool',
          <String, dynamic>{
            'server': parts[1],
            'tool': parts[2],
            'arguments': args,
          },
          scope,
        );
        return ToolOutcome(
          (result['text'] ?? '').toString().isEmpty
              ? '（MCP 工具没有返回内容）'
              : (result['text'] ?? '').toString(),
          isError: result['is_error'] == true,
        );
      }
      return const ToolOutcome("未知的 action，支持 'help' 或 'call'", isError: true);
    } catch (error) {
      return ToolOutcome('MCP 调用失败：$error', isError: true);
    }
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
      default:
        return <String, dynamic>{'text': '未知领域工具命令：$command', 'is_error': true};
    }
  }

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

  /// 执行站命令的统一出口：fs.* / terminal.exec 自动带工作空间租约。
  Future<Map<String, dynamic>> _stationCommand(
    String command,
    Map<String, dynamic> arguments,
    Map<String, dynamic> scope,
  ) async {
    final StationCommandClient? client = stationClient;
    if (client == null) {
      throw StateError('执行站未接线：station/command 不可用');
    }
    Map<String, dynamic> outgoing = arguments;
    if (command.startsWith('fs.') ||
        command.startsWith('file.') ||
        command == 'terminal.exec' ||
        command == 'exec.command') {
      final String agentId = (scope['agent_id'] ?? '').toString();
      final String root = agentId.isEmpty ? '' : _workspaceDirOf(agentId);
      if (root.isNotEmpty) {
        final String workspaceId = _workspaceIds.putIfAbsent(
          root,
          () =>
              'ws_${base64Url.encode(utf8.encode(root)).replaceAll('=', '')}',
        );
        final Future<void> Function(String, String)? register =
            workspaceRegister;
        if (register != null && !_registeredWorkspaces.contains(root)) {
          await register(workspaceId, root);
          _registeredWorkspaces.add(root);
        }
        outgoing = <String, dynamic>{...arguments, 'lease_id': workspaceId};
      }
    }
    return client(command, outgoing, scope);
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
    if (stationClient == null) return null;
    final Map<String, dynamic> scope = _stationScopeFor(agentId, sessionId);
    final String root = _workspaceDirOf(agentId);
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
