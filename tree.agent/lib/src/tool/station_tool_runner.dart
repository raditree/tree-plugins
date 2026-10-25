import 'terminal_hook_manager.dart';
import 'tool_runner.dart';
import '../station/tool_contributions.dart';
import '../workspace/station_command.dart';

/// 通过核心执行站执行的**内置工具子集**（read / write / list / grep / terminal）。
///
/// 插件不直接碰文件与进程：每个工具都翻译成 `station/command` 的 `fs.*` /
/// `terminal.exec`，身份（agent/team/mode/session）由 [scopeFor] 解析后随命令下发。
/// 这是 A3 工具编排的落点；L-24 把执行站迁到 local_executor 后，这里零改动。
class StationToolRunner implements ToolRunner {
  StationToolRunner({
    required this.client,
    required this.scopeFor,
    this.contributed,
    this.toolRunsRunner,
    this.hooks,
  });

  final StationCommandClient client;

  /// 目标 agent 的真实归属（`agent_id` / `team_id` / `mode_key` / `session_id`）。
  final Map<String, dynamic> Function(String agentId, String sessionId) scopeFor;

  /// 收集站采集到的贡献工具（每次采集后整体替换；空表 = 没有订阅者）。
  final List<ContributedTool> Function()? contributed;

  /// `tool_runs` 的执行回调（未接线时不声明该工具）。
  final Future<ToolOutcome> Function(ToolInvocation invocation)? toolRunsRunner;

  /// terminal hook 管理器（start/status/cancel + 完成唤醒）。
  final TerminalHookManager? hooks;

  @override
  List<ToolSpec> specsFor({required String agentId, required String sessionId}) =>
      <ToolSpec>[
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
            },
            'required': <String>['pattern'],
          },
        ),
        ToolSpec(
          name: 'terminal',
          description: '在目标工作空间执行一条 shell 命令并返回输出。',
          parameters: <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'command': <String, dynamic>{'type': 'string'},
              'timeout': <String, dynamic>{'type': 'number'},
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
    final Map<String, dynamic> scope =
        scopeFor(invocation.agentId, invocation.sessionId);
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
    }
  }

  Future<ToolOutcome> _read(
    ToolInvocation invocation,
    Map<String, dynamic> scope,
  ) async {
    final String path = (invocation.arguments['path'] ?? '').toString().trim();
    if (path.isEmpty) return const ToolOutcome('read 需要 path', isError: true);
    final Map<String, dynamic> result = await client('file.read', <String, dynamic>{
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
    final Map<String, dynamic> result = await client('file.write', <String, dynamic>{
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
    final Map<String, dynamic> read = await client('file.read', <String, dynamic>{
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
      'file.write',
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
    final Map<String, dynamic> result = await client('file.list', <String, dynamic>{
      'path': (invocation.arguments['path'] ?? '.').toString(),
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
    final Map<String, dynamic> result = await client('file.grep', <String, dynamic>{
      'pattern': pattern,
      if (invocation.arguments['path'] != null)
        'path': invocation.arguments['path'],
      'regex': invocation.arguments['regex'] == true,
      'ignore_case': invocation.arguments['ignore_case'] == true,
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
    final Map<String, dynamic> result = await client('exec.command', <String, dynamic>{
      'command': command,
      if (invocation.arguments['timeout'] != null)
        'timeout': invocation.arguments['timeout'],
      if (invocation.arguments['hook'] != null)
        'hook': invocation.arguments['hook'],
      if (invocation.arguments['hook_action'] != null)
        'hook_action': invocation.arguments['hook_action'],
      if (invocation.arguments['task_id'] != null)
        'task_id': invocation.arguments['task_id'],
      if (invocation.arguments['output_file'] != null)
        'output_file': invocation.arguments['output_file'],
    }, scope);
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