import 'spec_tool.dart';
import 'terminal_hook_manager.dart';
import 'tool_policy.dart';
import 'tool_run_registry.dart';
import 'tool_runner.dart';
import '../station/tool_contributions.dart';
import '../workspace/station_command.dart';

/// 通过核心执行站执行的**内置工具子集**（read / write / list / grep / terminal）。
///
/// 插件不直接碰文件与进程：每个工具都翻译成 `station/command` 的 `fs.*` /
/// `local.exec.command`（SSH 模式下由 `_stationCommand` 换成 `ssh.exec.command`），
/// 身份（agent/team/mode/session）由 [scopeFor] 解析后随命令下发。
/// 这是 A3 工具编排的落点；L-24 把执行站迁到 local_executor 后，这里零改动。
class StationToolRunner implements ToolRunner {
  StationToolRunner({
    required this.client,
    required this.scopeFor,
    this.contributed,
    this.toolRunsRunner,
    this.specRunner,
    this.hooks,
    this.policyFor,
    this.toolRuns,
  });

  final StationCommandClient client;

  /// 目标 agent 的真实归属（`agent_id` / `team_id` / `mode_key` / `session_id`）。
  final Map<String, dynamic> Function(String agentId, String sessionId) scopeFor;

  /// 收集站采集到的贡献工具（每次采集后整体替换；空表 = 没有订阅者）。
  final List<ContributedTool> Function()? contributed;

  /// `tool_runs` 的执行回调（未接线时不声明该工具）。
  final Future<ToolOutcome> Function(ToolInvocation invocation)? toolRunsRunner;

  /// `spec` 的执行回调（未接线时不声明该工具）。
  ///
  /// 真正的工作空间解析在运行时里（要按 agent 走本机 / SSH 执行站）；工具层只
  /// 负责声明与把调用转过去。
  final Future<ToolOutcome> Function(ToolInvocation invocation)? specRunner;

  /// terminal hook 管理器（start/status/cancel + 完成唤醒）。
  final TerminalHookManager? hooks;

  /// 本 agent 的工具白名单解析（临时员工在这里继承父级）。
  ///
  /// 未接线 ⇒ 全量默认：工具层不自己读 `agents/*.yaml`，身份到策略的映射由
  /// 运行时决定（工具层只认 `agentId`）。
  final ToolPolicy Function(String agentId)? policyFor;

  /// [agentId] 当前生效的策略（未接线 = 全量默认）。
  ToolPolicy policyOf(String agentId) =>
      policyFor?.call(agentId) ?? ToolPolicy.unrestricted;

  /// 运行中工具登记表（右栏「正在执行的 tool」/ `tool_runs` / `query_status` 的
  /// **唯一**数据源）。null = 不登记（测试 / 未接线），行为与从前一致。
  ///
  /// 为什么挂在**这一层**：内置工具与宿主 `tool.call` 都经 [run] 这一个入口，
  /// 在这里 start/finish 才能保证"工具一开始跑就有一行"、结束后一定收掉。
  final ToolRunRegistry? toolRuns;

  /// 本 agent 可用的工具声明（白名单里没有的工具**不出现**）。
  ///
  /// P5：`ask_expert` 是**必须显式勾选**的工具——未配置 `tool_policy`
  /// （全量默认）时也不出现（默认不能召专家，§9.4）。
  @override
  List<ToolSpec> specsFor({required String agentId, required String sessionId}) {
    final List<ToolSpec> specs = _buildSpecs();
    final ToolPolicy policy = policyOf(agentId);
    if (policy.isUnrestricted) {
      return <ToolSpec>[
        for (final ToolSpec spec in specs)
          if (!isOptInTool(spec.name)) spec,
      ];
    }
    return <ToolSpec>[
      for (final ToolSpec spec in specs)
        if (policy.allows(spec.name)) spec,
    ];
  }

  /// 可选工具目录（**不过滤**）：模型配置页要同时看到已选与未选的工具。
  List<ToolCatalogEntry> catalogFor({required String agentId}) {
    final ToolPolicy policy = policyOf(agentId);
    return <ToolCatalogEntry>[
      for (final ToolSpec spec in _buildSpecs())
        ToolCatalogEntry(
          name: spec.name,
          description: spec.description,
          group: toolGroupOf(spec.name),
          enabled:
              policy.allows(spec.name) &&
              !(isOptInTool(spec.name) && policy.allowed == null),
        ),
    ];
  }

  /// 全部工具声明（内置 + spec / tool_runs + 贡献工具），不做白名单过滤。
  List<ToolSpec> _buildSpecs() => <ToolSpec>[
        ToolSpec(
          name: 'read',
          description: '读取工作空间内的文件（相对路径；可指定起始行与行数）。',
          parameters: <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'path': <String, dynamic>{'type': 'string', 'description': '工作空间相对路径'},
              'start_line': <String, dynamic>{'type': 'integer'},
              'line_count': <String, dynamic>{'type': 'integer'},
            },
            'required': <String>['path'],
          },
        ),
        ToolSpec(
          name: 'write',
          description: '写入工作空间内的文件（自动创建父目录）。',
          parameters: <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'path': <String, dynamic>{'type': 'string'},
              'content': <String, dynamic>{'type': 'string'},
            },
            'required': <String>['path', 'content'],
          },
        ),
        ToolSpec(
          name: 'list',
          description: '列出工作空间内的目录。',
          parameters: <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'path': <String, dynamic>{'type': 'string'},
              'max_depth': <String, dynamic>{'type': 'integer'},
              'include_hidden': <String, dynamic>{
                'type': 'boolean',
                'description': 'true = 连 .git / .dart_tool 这类隐藏项一起列（缺省排除）',
              },
            },
            'required': <String>['path'],
          },
        ),
        ToolSpec(
          name: 'grep',
          description: '在工作空间内按正则/字面搜索文件内容。',
          parameters: <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'pattern': <String, dynamic>{'type': 'string'},
              'path': <String, dynamic>{'type': 'string'},
              'regex': <String, dynamic>{'type': 'boolean'},
              'ignore_case': <String, dynamic>{'type': 'boolean'},
              'include_hidden': <String, dynamic>{
                'type': 'boolean',
                'description': 'true = 搜索 .git / .dart_tool 这类隐藏项（缺省排除）',
              },
              'include_ignored': <String, dynamic>{
                'type': 'boolean',
                'description': 'true = 搜索 node_modules / build / dist 等依赖产物目录（缺省跳过）',
              },
            },
            'required': <String>['pattern'],
          },
        ),
        ToolSpec(
          name: 'terminal',
          description:
              '在目标工作空间执行一条 shell 命令并返回输出（命令失败时也返回输出与退出码）。'
              'Windows 本机由 PowerShell 执行（优先 pwsh，其次 Windows PowerShell，'
              '都没有才回退 cmd）：`ls` / `dir` 是 Get-ChildItem 的别名，'
              '没有 GNU 的 `-la` 这类参数；POSIX 与 SSH 走 sh -c。',
          parameters: <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'command': <String, dynamic>{'type': 'string'},
              'timeout': <String, dynamic>{'type': 'number'},
              'timeout_seconds': <String, dynamic>{
                'type': 'number',
                'description': '软超时（秒，缺省 300；0=永不）：到点不杀进程，转后台并返回 task_id',
              },
              'hook': <String, dynamic>{'type': 'boolean', 'description': 'true = 后台执行并回 task_id'},
              'hook_action': <String, dynamic>{'type': 'string', 'enum': <String>['status', 'cancel']},
              'task_id': <String, dynamic>{'type': 'string'},
              'output_file': <String, dynamic>{'type': 'string'},
            },
            'required': <String>['command'],
          },
        ),
        ToolSpec(
          name: 'edit',
          description: '在文件中把 old_text 替换为 new_text（默认要求唯一匹配）。',
          parameters: <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'file_path': <String, dynamic>{'type': 'string', 'description': '工作空间相对路径'},
              'old_text': <String, dynamic>{'type': 'string', 'description': '要替换的原文'},
              'new_text': <String, dynamic>{'type': 'string', 'description': '替换后的文本'},
              'replace_all': <String, dynamic>{'type': 'boolean', 'description': 'true = 替换全部匹配'},
            },
            'required': <String>['file_path', 'old_text', 'new_text'],
          },
        ),
        if (specRunner != null) SpecTool.spec(),
        if (toolRunsRunner != null)
          ToolSpec(
            name: 'tool_runs',
            description: '查看/显式关闭本 agent 与其直属下级正在执行的工具调用。',
            parameters: <String, dynamic>{
              'type': 'object',
              'properties': <String, dynamic>{
                'action': <String, dynamic>{'type': 'string', 'enum': <String>['list', 'close']},
                'handle': <String, dynamic>{'type': 'string'},
                'member_id': <String, dynamic>{'type': 'string'},
              },
              'required': <String>['action'],
            },
          ),
        for (final ContributedTool tool in contributed?.call() ?? const <ContributedTool>[])
          ToolSpec(
            name: tool.coreName,
            description: '[来自插件 ${tool.pluginId}] ${tool.description}',
            parameters: tool.parameters,
          ),
      ];

  @override
  Future<ToolOutcome> run(
    ToolInvocation invocation, {
    bool Function()? isCancelled,
  }) async {
    // 二次兜底：模型可能记住旧工具名（工具表本轮已过滤，它仍按历史消息发起调用）。
    // 只拦"目录里确实存在、但本 agent 未勾选"的工具；不存在的工具仍走原有未知分支。
    final ToolPolicy policy = policyOf(invocation.agentId);
    // P5：显式勾选类工具（ask_expert）在没有 tool_policy 时也不放行。
    if (isOptInTool(invocation.name) &&
        (policy.allowed == null || !policy.allows(invocation.name))) {
      return ToolOutcome(
        '工具「${invocation.name}」需要显式勾选（默认不开放）：'
        '请在模型配置页的工具清单里加上它。',
        isError: true,
      );
    }
    if (!policy.isUnrestricted &&
        !policy.allows(invocation.name) &&
        _buildSpecs().any((ToolSpec spec) => spec.name == invocation.name)) {
      return ToolOutcome(
        '工具「${invocation.name}」未在该 agent 的工具白名单中，已拒绝执行'
        '（需要时可在模型配置页勾选）。',
        isError: true,
      );
    }
    final Map<String, dynamic> scope =
        scopeFor(invocation.agentId, invocation.sessionId);
    // 工具一开始执行就登记（右栏「正在执行的 tool」因此能在卡住时看到它）；
    // `tool_runs` 自己不登记，避免列表里出现"正在查工具列表"的自我引用。
    final ToolRunRegistry? registry = toolRuns;
    final ToolRun? running = registry != null && invocation.name != 'tool_runs'
        ? registry.start(
            tool: invocation.name,
            arguments: invocation.arguments,
            agentId: invocation.agentId,
            sessionId: invocation.sessionId,
          )
        : null;
    try {
      switch (invocation.name) {
        case 'read':
          return await _read(invocation, scope);
        case 'write':
          return await _write(invocation, scope);
        case 'edit':
          return await _edit(invocation, scope);
        case 'tool_runs':
          final Future<ToolOutcome> Function(ToolInvocation)? runner =
              toolRunsRunner;
          return runner == null
              ? const ToolOutcome('tool_runs 未接线', isError: true)
              : await runner(invocation);
        case SpecTool.name:
          final Future<ToolOutcome> Function(ToolInvocation)? runner =
              specRunner;
          return runner == null
              ? const ToolOutcome('spec 工具未接线', isError: true)
              : await runner(invocation);
        case 'list':
          return await _list(invocation, scope);
        case 'grep':
          return await _grep(invocation, scope);
        case 'terminal':
          return await _terminal(invocation, scope);
        default:
          return await _contributedTool(invocation, scope);
      }
    } catch (error) {
      return ToolOutcome('工具执行失败：$error', isError: true);
    } finally {
      if (running != null) registry!.finish(running);
    }
  }

  Future<ToolOutcome> _read(
    ToolInvocation invocation,
    Map<String, dynamic> scope,
  ) async {
    final String path = (invocation.arguments['path'] ?? '').toString().trim();
    if (path.isEmpty) return const ToolOutcome('read 需要 path', isError: true);
    final Map<String, dynamic> result = await client('local.file.read', <String, dynamic>{
      'path': path,
      if (invocation.arguments['start_line'] != null)
        'start_line': invocation.arguments['start_line'],
      if (invocation.arguments['line_count'] != null)
        'line_count': invocation.arguments['line_count'],
    }, scope);
    final String text = (result['content'] ?? '').toString();
    if (text.isEmpty) return ToolOutcome('（空文件）$path');
    return ToolOutcome(text);
  }

  Future<ToolOutcome> _write(
    ToolInvocation invocation,
    Map<String, dynamic> scope,
  ) async {
    final String path = (invocation.arguments['path'] ?? '').toString().trim();
    if (path.isEmpty) return const ToolOutcome('write 需要 path', isError: true);
    final Map<String, dynamic> result = await client('local.file.write', <String, dynamic>{
      'path': path,
      'content': (invocation.arguments['content'] ?? '').toString(),
    }, scope);
    final int bytes = (result['bytes_written'] as num?)?.toInt() ?? 0;
    return ToolOutcome('已写入 $path（$bytes 字节）');
  }

  Future<ToolOutcome> _edit(
    ToolInvocation invocation,
    Map<String, dynamic> scope,
  ) async {
    final String path =
        (invocation.arguments['file_path'] ?? '').toString().trim();
    final String oldText = (invocation.arguments['old_text'] ?? '').toString();
    final String newText = (invocation.arguments['new_text'] ?? '').toString();
    final bool replaceAll = invocation.arguments['replace_all'] == true;
    if (path.isEmpty) return const ToolOutcome('file_path 不能为空', isError: true);
    if (oldText.isEmpty) return const ToolOutcome('old_text 不能为空', isError: true);
    final Map<String, dynamic> read = await client('local.file.read', <String, dynamic>{
      'path': path,
    }, scope);
    final String text = (read['content'] ?? '').toString();
    final int occurrences = RegExp(RegExp.escape(oldText)).allMatches(text).length;
    if (occurrences == 0) {
      return ToolOutcome('未找到 old_text：$path', isError: true);
    }
    if (occurrences > 1 && !replaceAll) {
      return ToolOutcome(
        'old_text 在 $path 中出现 $occurrences 次，'
        '请提供更精确的 old_text 或传 replace_all=true',
        isError: true,
      );
    }
    final String next = replaceAll
        ? text.replaceAll(oldText, newText)
        : text.replaceFirst(oldText, newText);
    final Map<String, dynamic> written = await client(
      'local.file.write',
      <String, dynamic>{'path': path, 'content': next},
      scope,
    );
    return ToolOutcome(
      '已替换 $occurrences 处：$path'
      '（文件现为 ${written['bytes_written'] ?? next.length} 字节）',
    );
  }

  Future<ToolOutcome> _list(
    ToolInvocation invocation,
    Map<String, dynamic> scope,
  ) async {
    final Map<String, dynamic> result = await client('local.file.list', <String, dynamic>{
      'path': (invocation.arguments['path'] ?? '.').toString(),
      'include_hidden': invocation.arguments['include_hidden'] == true,
      if (invocation.arguments['max_depth'] != null)
        'max_depth': invocation.arguments['max_depth'],
    }, scope);
    final Object? entries = result['entries'];
    if (entries is! List || entries.isEmpty) return const ToolOutcome('（空目录）');
    return ToolOutcome(<String>[for (final Object? entry in entries) entry.toString()].join('\n'));
  }

  Future<ToolOutcome> _grep(
    ToolInvocation invocation,
    Map<String, dynamic> scope,
  ) async {
    final String pattern = (invocation.arguments['pattern'] ?? '').toString();
    if (pattern.isEmpty) return const ToolOutcome('grep 需要 pattern', isError: true);
    final Map<String, dynamic> result = await client('local.file.grep', <String, dynamic>{
      'pattern': pattern,
      if (invocation.arguments['path'] != null)
        'path': invocation.arguments['path'],
      'regex': invocation.arguments['regex'] == true,
      'ignore_case': invocation.arguments['ignore_case'] == true,
      'include_hidden': invocation.arguments['include_hidden'] == true,
      'include_ignored': invocation.arguments['include_ignored'] == true,
    }, scope);
    final Object? matches = result['matches'];
    if (matches is! List || matches.isEmpty) return const ToolOutcome('（无匹配）');
    final List<String> lines = <String>[];
    for (final Object? item in matches) {
      if (item is! Map) continue;
      lines.add('${item['path']}:${item['line']}: ${item['text']}');
    }
    return ToolOutcome(lines.join('\n'));
  }

  Future<ToolOutcome> _terminal(
    ToolInvocation invocation,
    Map<String, dynamic> scope,
  ) async {
    final String command =
        (invocation.arguments['command'] ?? '').toString().trim();
    final String hookAction =
        (invocation.arguments['hook_action'] ?? '').toString().trim();
    final TerminalHookManager? manager = hooks;
    if (manager != null &&
        (hookAction.isNotEmpty || invocation.arguments['hook'] == true)) {
      if (hookAction.isNotEmpty) {
        final String taskId =
            (invocation.arguments['task_id'] ?? '').toString().trim();
        if (taskId.isEmpty) {
          return ToolOutcome('hook_action=$hookAction 需要 task_id', isError: true);
        }
        return hookAction == 'cancel'
            ? manager.cancel(taskId)
            : manager.status(taskId);
      }
      return manager.start(invocation);
    }
    if (command.isEmpty) return const ToolOutcome('terminal 需要 command', isError: true);
    final Map<String, dynamic> result = await client('local.exec.command', <String, dynamic>{
      'command': command,
      'timeout_seconds': invocation.arguments['timeout_seconds'] ?? 300,
      if (invocation.arguments['hook'] != null)
        'hook': invocation.arguments['hook'],
      if (invocation.arguments['hook_action'] != null)
        'hook_action': invocation.arguments['hook_action'],
      if (invocation.arguments['task_id'] != null)
        'task_id': invocation.arguments['task_id'],
      if (invocation.arguments['output_file'] != null)
        'output_file': invocation.arguments['output_file'],
    }, scope);
    if (result['task_id'] != null && hooks != null) {
      return hooks!.adopt(invocation, result);
    }
    return ToolOutcome(
      (result['text'] ?? '').toString(),
      isError: result['is_error'] == true,
    );
  }

  Future<ToolOutcome> _contributedTool(
    ToolInvocation invocation,
    Map<String, dynamic> scope,
  ) async {
    final List<ContributedTool> tools =
        contributed?.call() ?? const <ContributedTool>[];
    ContributedTool? match;
    for (final ContributedTool tool in tools) {
      if (tool.coreName == invocation.name) {
        match = tool;
        break;
      }
    }
    if (match == null) {
      return ToolOutcome('未知工具：${invocation.name}', isError: true);
    }
    // 核心只负责把调用转给贡献插件，**不解析**身份字段：scope 放 payload，
    // 顶层 scope 留空（mode 由核心按平台路由兜底，与领域身份无关）。
    final Map<String, dynamic> result = await client(
      'plugin.toolCall',
      <String, dynamic>{
        'plugin_id': match.pluginId,
        'tool': match.name,
        'arguments': invocation.arguments,
        'scope': scope,
      },
      <String, dynamic>{},
    );
    return ToolOutcome(
      (result['result'] ?? '').toString(),
      isError: result['is_error'] == true,
    );
  }

  @override
  Future<void> close() async {}
}