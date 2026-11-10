// tree.production.line —— 标准开发流生产线（P1 数据模型 + 队列；P3 准备阶段；
// P4 打包 + 执行；P5 专家工具；P6 项目整理）。
//
// 定位（docs/pluginization/production-line-recon.md §7/§8/§9/§10/§11）：
// - headless 插件，granularity=team；数据只落 `<data_root>/production_lines/<team_id>/`；
// - `task.yaml` 是唯一真值，`state.json` 只是可由它重建的队列索引；
// - 状态机、队列排序、依赖判据、in-flight 崩溃恢复都在领域库，入口只做协议面；
// - P3 准备阶段：`production.prepare.*` 走需求模板 → 侦查 → 追问 → 范围/拆任务；
//   模型经 `llm.call`、文档检索经 `docnorm.query`（缺失即 fail-closed），
//   追问上限读 `tree.settings`（缺省回退 line.yaml / 默认 3）；
// - P4 执行阶段：`production.task.pack|run|message(s)` 经 `agent.worker.run`
//   调角色化员工（packer / executor），门控经 `local.exec.command`（本机租约）；
//   写域越界 / 门控失败一律不得进 `done`；
// - P5 专家工具：向 `tree.agent` 的工具收集站贡献 `ask_expert`，工具调用经
//   本插件自己的执行站回到 `production.task.expert`（拿得到 meta.data_dir）；
//   默认关闭、单任务次数上限、专家只读不落盘、四段回答；
// - P6 项目整理：`production.audit.run` 只读扫描工作空间（文档审计 / TODO 台账 /
//   冗余候选），固定 schema，唯一写入是项目资产目录里的 `audit.md`；
// - 依赖纪律：不得 import 任何核心包。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tree_production_line/tree_production_line.dart';

import '../_kit/plugin_kit.dart';

const String kPluginId = 'tree.production.line';
const String kDisplayName = 'Tree 标准开发流生产线';
const String kVersion = '0.5.0';

const String kStationName = 'production';

/// `tree.agent` 的工具收集站（P5 贡献 `ask_expert` 的落点）。
const String kToolCollectStation = 'plugin.tree.agent.collect.tools';

/// 追问上限的设置键。`tree.settings` 的 key 只允许字母/数字/下划线（不能带点），
/// 所以 §8.4 里写的 `questions.max_per_round` 落成 `questions_max_per_round`
/// （分组仍是 `questions`，UI 标题「追问」）。
const String kQuestionLimitKey = 'questions_max_per_round';

const String kStationReadme =
    '生产线：P1 production.line.create/list/get、production.task.create/list/get/'
    'transition、production.queue.next/rebuild/recover、production.run.list。'
    '数据落 `<data_root>/production_lines/<team_id>/<line_id>/`：line.yaml / '
    'tasks/<task_id>/task.yaml / tasks/<task_id>/pack.json / runs/<run_id>.json / '
    'runs/messages.jsonl / state.json / inbox.jsonl / prepare.json；task.yaml 为唯一真值，'
    'state.json 可由它重建。状态机：draft→recon→aligning→scoped→queued→packing→'
    'packed→running→gating→done；aligning↔awaiting_user；gating→packed（重试）；'
    'queued/packing/packed/running/gating→blocked；blocked→awaiting_user|queued；'
    'cancelled 可从任意非终态进入。崩溃恢复：in-flight → queued 并追加一条 '
    'status=interrupted 的 run，重复 recover 0 写。'
    'P3 准备阶段：production.prepare.intake（需求模板五栏）→ recon（侦查四块 + 追问，'
    '经 docnorm.query 取文档上下文、llm.call 出结构）→ answer / all_recommended / '
    'window.open|close（未答转 awaiting_user、次日续答）→ read（点状读取，文件 ≤ 8 / '
    'grep ≤ 2 轮）→ finalize（写 recon/scope/plan/decisions/acceptance + 建 queued 任务）。'
    'P4 执行阶段：production.task.pack（agent.worker.run role=packer → pack.json + pack.md）→ '
    'production.task.run（agent.worker.run role=executor → 写域判据 → 门控 local.exec.command；'
    '失败按 limits.retries 回 packed，超限 blocked；done 只由门控通过触发）→ '
    'production.task.message|messages（任务内一对一 message 线程，打回超过 3 次自动 blocked）。'
    'P5 专家工具：向 tree.agent 工具收集站贡献 ask_expert → production.task.expert'
    '（roles.expert.enabled 默认 false；单任务 ≤ max_per_task；专家只读不落盘；'
    '输出固定四段：结论 / 依据 / 建议 / 未决；每次调用落 runs 台账 role=expert）。'
    'P6 项目整理：production.audit.run（只读扫描工作空间 → 文档审计 / TODO 台账 / '
    '重复内容与超大文件候选；报告 schema version=1 固定；唯一写入是项目资产 '
    'docs/production_lines/<line>/audit.md，write=false 时纯查询）。'
    '追问上限读 settings，缺省回退 line.yaml.limits 与 3（夹到 1–10）。';

final ProductionService _service = ProductionService();
PreparationService? _preparation;
ProductionExecutionService? _execution;
ProductionAuditService? _audit;
PluginKitServer? _activeServer;
final Set<String> _settingsTeams = <String>{};

/// 工作空间 → 本插件登记的本机租约（`local.lease.register` 的返回值）。
final Map<String, String> _leases = <String, String>{};

PluginKitServer buildServer({bool exitOnShutdown = true}) => PluginKitServer(
  channel: PluginChannel.stdio(kPluginId),
  pluginId: kPluginId,
  displayName: kDisplayName,
  onReady: _onReady,
  onRequest: handleRequest,
  tools: <Map<String, dynamic>>[expertToolSpec()],
  onToolCall: _handleToolCall,
  exitOnShutdown: exitOnShutdown,
);

Future<void> _onReady(PluginKitServer server) async {
  _activeServer = server;
  _preparation = PreparationService(
    llm: _callLlm,
    docQuery: _callDocQuery,
    limitReader: _readQuestionLimit,
  );
  _execution = ProductionExecutionService(
    workers: _callWorker,
    commands: _runCommand,
  );
  _audit = ProductionAuditService();
  server.channel.log(
    '已上线：v$kVersion（tree.production.line，P1 数据 + P3 准备阶段 + P4 打包执行 + P5 专家 + P6 项目整理）',
  );
  // P5：把 ask_expert 贡献给 tree.agent 的工具收集站（默认不在任何 agent 的工具表里，
  // 只有显式勾选的打包 / 执行员工才拿得到）。
  try {
    final Map<String, dynamic> subscribed = await server.channel.request(
      M.stationSubscribe,
      <String, dynamic>{'station_id': kToolCollectStation},
    );
    server.channel.log(
      '订阅 tree.agent 工具收集站：${subscribed['ok'] == true ? '成功' : subscribed['error']}',
    );
  } catch (error) {
    server.channel.log('订阅工具收集站失败：$error');
  }
  try {
    final Map<String, dynamic> result = await server.channel.request(
      M.stationRegister,
      <String, dynamic>{
        'kind': 'execute',
        'name': kStationName,
        'description': '生产线数据模型、队列、准备阶段、打包执行、专家与项目整理（production.*）',
        'readme': kStationReadme,
        'commands': <String>[
          ...kProductionCommands,
          ...kPreparationCommands,
          ...kExecutionCommands,
          ...kAuditCommands,
        ],
      },
    );
    server.channel.log(
      '自建执行站：${result['ok'] == true ? result['station_id'] : result['error']}',
    );
  } catch (error) {
    server.channel.log('自建执行站失败：$error');
  }
}

/// 向 `tree.agent` 的 `llm.call` 要一份 JSON：只透传本次请求的 scope（身份/团队）。
Future<Map<String, Object?>> _callLlm(
  String point,
  String system,
  String prompt,
  Map<String, Object?> scope,
) async {
  final PluginKitServer? server = _activeServer;
  if (server == null) {
    throw ProductionFailure('插件尚未就绪：llm.call 通道不可用', code: 'llm_unavailable');
  }
  final Map<String, dynamic> payload = await server.channel.command(
    'llm.call',
    <String, dynamic>{
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{'role': 'system', 'content': system},
        <String, dynamic>{'role': 'user', 'content': prompt},
      ],
      'temperature': 0.2,
    },
    '',
    scope,
  );
  final Object? json = payload['json'];
  if (json is Map) {
    return <String, Object?>{
      for (final MapEntry<dynamic, dynamic> entry in json.entries)
        entry.key.toString(): entry.value,
    };
  }
  final String text = asString(payload['text']);
  final Object? decoded = _jsonFromText(text);
  if (decoded is Map) {
    return <String, Object?>{
      for (final MapEntry<dynamic, dynamic> entry in decoded.entries)
        entry.key.toString(): entry.value,
    };
  }
  throw ProductionFailure(
    '模型没有返回 JSON（$point）：${text.length > 200 ? '${text.substring(0, 200)}…' : text}',
    code: 'llm_bad_json',
  );
}

/// 从正文里抠第一个 JSON 对象（模型偶尔加代码围栏 / 前置说明）。
Object? _jsonFromText(String text) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  try {
    return json.decode(trimmed);
  } catch (_) {
    final int start = trimmed.indexOf('{');
    final int end = trimmed.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      return json.decode(trimmed.substring(start, end + 1));
    } catch (_) {
      return null;
    }
  }
}

/// 文档检索（`docnorm.query`）；产线工作空间就是目标仓库。
Future<Map<String, Object?>> _callDocQuery(
  String repo,
  String question,
  Map<String, Object?> scope,
) async {
  final PluginKitServer? server = _activeServer;
  if (server == null) {
    throw ProductionFailure(
      '插件尚未就绪：docnorm.query 通道不可用',
      code: 'docnorm_unavailable',
    );
  }
  final Map<String, dynamic> payload = await server.channel.command(
    'docnorm.query',
    <String, dynamic>{
      'repo': repo,
      'question': question,
      'mode': 'hybrid',
    },
    '',
    scope,
  );
  return <String, Object?>{
    for (final MapEntry<String, dynamic> entry in payload.entries)
      entry.key: entry.value,
  };
}

/// 产线调员工（`agent.worker.run`）：工具与模型由角色配置显式下发。
Future<Map<String, Object?>> _callWorker(
  WorkerCall call,
  Map<String, Object?> scope,
) async {
  final PluginKitServer? server = _activeServer;
  if (server == null) {
    throw ProductionFailure(
      '插件尚未就绪：agent.worker.run 通道不可用',
      code: 'worker_unavailable',
    );
  }
  try {
    final Map<String, dynamic> payload = await server.channel.command(
      'agent.worker.run',
      call.toArguments(),
      '',
      scope,
    );
    return <String, Object?>{
      for (final MapEntry<String, dynamic> entry in payload.entries)
        entry.key: entry.value,
    };
  } on CmdFailureException catch (error) {
    final String message = asString(error.payload['error']).isEmpty
        ? error.message
        : asString(error.payload['error']);
    return <String, Object?>{
      ...error.payload,
      'status': 'failed',
      'error': message,
    };
  } catch (error) {
    throw ProductionFailure(
      '员工调用失败（agent.worker.run）：$error',
      code: 'worker_failed',
    );
  }
}

/// 在工作空间执行一条命令（`local.exec.command`）：先登记本插件自己的租约。
///
/// 租约只在本插件名下有效（`local_executor` 的 fail-closed 口径）；
/// `lease_unknown`（插件重启过）时丢弃缓存、重新登记并重试一次。
Future<CommandResult> _runCommand(
  String command, {
  required String workspace,
  required Map<String, Object?> scope,
}) async {
  final PluginKitServer? server = _activeServer;
  if (server == null) {
    throw ProductionFailure(
      '插件尚未就绪：local.exec.command 通道不可用',
      code: 'command_unavailable',
    );
  }
  Map<String, dynamic> payload;
  try {
    payload = await server.channel.command(
      'local.exec.command',
      <String, dynamic>{
        'local_lease_id': await _leaseFor(server, workspace, scope),
        'command': command,
        'timeout_seconds': 300,
      },
      '',
      scope,
    );
  } on CmdFailureException catch (error) {
    if (error.code != 'lease_unknown') {
      return CommandResult(ok: false, exitCode: -1, output: error.message);
    }
    _leases.remove(workspace);
    try {
      payload = await server.channel.command(
        'local.exec.command',
        <String, dynamic>{
          'local_lease_id': await _leaseFor(server, workspace, scope),
          'command': command,
          'timeout_seconds': 300,
        },
        '',
        scope,
      );
    } on CmdFailureException catch (retryError) {
      return CommandResult(ok: false, exitCode: -1, output: retryError.message);
    }
  }
  return CommandResult(
    ok: payload['is_error'] != true,
    exitCode: intOf(payload['exit_code'], 0),
    // **不能 trim**：`git status --porcelain` 的行首空格是状态位的一部分
    // （`asString` 会 trim，解析出的路径就会少一个字符）。
    output: (payload['text'] ?? '').toString(),
  );
}

Future<String> _leaseFor(
  PluginKitServer server,
  String workspace,
  Map<String, Object?> scope,
) async {
  final String? existing = _leases[workspace];
  if (existing != null && existing.isNotEmpty) return existing;
  final Map<String, dynamic> payload = await server.channel.command(
    'local.lease.register',
    <String, dynamic>{'dir': workspace},
    '',
    scope,
  );
  final String leaseId = asString(payload['lease_id']);
  if (leaseId.isEmpty) {
    throw ProductionFailure(
      '本机执行器没有返回租约（local.lease.register）：$workspace',
      code: 'command_unavailable',
    );
  }
  _leases[workspace] = leaseId;
  return leaseId;
}

/// `tools/call` 的落点（P5）：只认 `ask_expert`，转回本插件自己的执行站命令
/// `production.task.expert`。
///
/// 为什么要多绕一跳：`tools/call` 的 scope 里没有 `data_dir`（核心只在
/// `station/request` 的 meta 里带数据根），绕回执行站才能拿到同一个数据根。
Future<Map<String, dynamic>> _handleToolCall(
  String name,
  Map<String, dynamic> arguments,
  Map<String, dynamic> scope,
) async {
  final String native = name.startsWith('plugin__')
      ? name.split('__').last
      : name;
  if (native != kAskExpertTool) {
    return toolText('未知工具：$name（本插件只贡献 $kAskExpertTool）', isError: true);
  }
  final PluginKitServer? server = _activeServer;
  if (server == null) {
    return toolText('插件尚未就绪：$kAskExpertTool 暂不可用', isError: true);
  }
  final String sessionId = asString(scope['session_id']);
  if (!sessionId.startsWith('pl_')) {
    return toolText(
      '$kAskExpertTool 只对产线员工开放（打包 / 执行的任务会话 pl_<line>_<task>）；'
      '当前会话：${sessionId.isEmpty ? '空' : sessionId}',
      isError: true,
    );
  }
  try {
    final Map<String, dynamic> payload = await server.channel.command(
      'production.task.expert',
      <String, dynamic>{...arguments},
      '',
      scope,
    );
    if (asString(payload['status']) != 'ok') {
      final String error = asString(payload['error']);
      return toolText(
        error.isEmpty ? '专家调用失败（status=${asString(payload['status'])}）' : error,
        isError: true,
      );
    }
    final String text = asString(payload['text']);
    return toolText(
      '$text\n\n（本任务专家调用：${payload['used']}/${payload['max_per_task']}，'
      '剩余 ${payload['remaining']} 次）',
    );
  } on CmdFailureException catch (error) {
    final String message = asString(error.payload['error']).isEmpty
        ? error.message
        : asString(error.payload['error']);
    return toolText(message, isError: true);
  } catch (error) {
    return toolText('专家调用失败：$error', isError: true);
  }
}

/// 追问上限：先确保本团队的 schema 已注册，再读值；失败交回 null（走 line.yaml）。
Future<int?> _readQuestionLimit(Map<String, Object?> scope) async {
  final PluginKitServer? server = _activeServer;
  if (server == null) return null;
  final String teamId = asString(scope['team_id']);
  if (teamId.isEmpty) return null;
  try {
    if (!_settingsTeams.contains(teamId)) {
      await server.channel.command(
        'settings.define',
        <String, dynamic>{'schema': _questionSchema()},
        '',
        scope,
      );
      _settingsTeams.add(teamId);
    }
    final Map<String, dynamic> payload = await server.channel.command(
      'settings.get',
      <String, dynamic>{'key': kQuestionLimitKey},
      '',
      scope,
    );
    final Object? value = payload['value'];
    if (value is num) return value.toInt();
    return int.tryParse('$value');
  } catch (_) {
    return null;
  }
}

/// 设置在插件设置页显示的 schema（§8.4）。
Map<String, Object?> _questionSchema() => <String, Object?>{
  'schema_version': 1,
  'groups': <Map<String, Object?>>[
    <String, Object?>{'id': 'questions', 'title': '追问', 'order': 10},
  ],
  'fields': <Map<String, Object?>>[
    <String, Object?>{
      'key': kQuestionLimitKey,
      'group': 'questions',
      'type': 'int',
      'title': '每轮最多追问数',
      'default': 3,
      'min': 1,
      'max': 10,
      'help': '准备阶段每轮新提问题的上限（1–10）；已提出的问题不受影响，下一轮生效。',
    },
  ],
};

Future<Map<String, dynamic>?> handleRequest(
  String method,
  Map<String, dynamic> params,
) async {
  if (method != M.stationRequest) return null;
  // P5：工具收集站的采集请求（subscriber 回一次工具清单）。
  if (asString(params['station_id']) == kToolCollectStation) {
    return <String, dynamic>{
      'reply': <String, dynamic>{
        'payload': <String, dynamic>{
          'tools': <Map<String, dynamic>>[expertToolSpec()],
        },
      },
    };
  }
  final Map<String, dynamic> payload = asMap(params['payload']);
  final String command = asString(payload['command']);
  final bool isPrepare = kPreparationCommands.contains(command);
  final bool isExecute = kExecutionCommands.contains(command);
  final bool isAudit = kAuditCommands.contains(command);
  if (!isPrepare &&
      !isExecute &&
      !isAudit &&
      !kProductionCommands.contains(command)) {
    return null;
  }
  try {
    final Map<String, Object?> result = isPrepare
        ? await _preparation!.handle(
            command,
            asMap(payload['arguments']),
            asMap(params['meta']),
            asMap(params['scope']),
          )
        : isExecute
        ? await _execution!.handle(
            command,
            asMap(payload['arguments']),
            asMap(params['meta']),
            asMap(params['scope']),
          )
        : isAudit
        ? await _audit!.handle(
            command,
            asMap(payload['arguments']),
            asMap(params['meta']),
            asMap(params['scope']),
          )
        : _service.handle(
            command,
            asMap(payload['arguments']),
            asMap(params['meta']),
            asMap(params['scope']),
          );
    return <String, dynamic>{
      'reply': <String, dynamic>{'payload': result},
    };
  } on ProductionFailure catch (error) {
    return <String, dynamic>{
      'reply': <String, dynamic>{'error': error.message, 'code': error.code},
    };
  } catch (error) {
    return <String, dynamic>{
      'reply': <String, dynamic>{
        'error': '产线命令执行失败：$error',
        'code': 'production_error',
      },
    };
  }
}

Future<void> main(List<String> args) async {
  if (args.contains('--selftest')) {
    // 自检输出走 stderr："stdout 只有协议帧"这条铁律不因模式而变。
    exitCode = await selfTest();
    return;
  }
  await buildServer().run(stdin);
  try {
    await stdout.flush();
  } catch (_) {
    // 管道已被对端关掉（核心退出）：刷不出去不算错误。
  }
}

/// 假核心自检（同码跑真读循环）：注册面 + fail-closed + 状态机 + 队列 + 恢复 + 重建。
Future<int> selfTest() async {
  final SelfTest check = SelfTest(name: 'tree_production_line_plugin');
  final Directory temp = Directory.systemTemp.createTempSync(
    'tree_production_line_selftest_',
  );
  final FakeCore core = FakeCore(buildServer(exitOnShutdown: false));
  core.onMethod(
    M.stationRegister,
    (Map<String, dynamic> params) => <String, dynamic>{
      'ok': true,
      'station_id': 'production',
    },
  );
  core.onMethod(
    M.stationSubscribe,
    (Map<String, dynamic> params) => <String, dynamic>{'ok': true},
  );

  Future<Map<String, dynamic>> call(
    Object id,
    String command,
    Map<String, Object?> arguments, {
    String? team = 'team_a',
    bool withData = true,
    String? agent,
  }) async {
    core.ask(id, M.stationRequest, <String, dynamic>{
      'payload': <String, dynamic>{
        'command': command,
        'arguments': arguments,
      },
      'meta': <String, dynamic>{
        'source_plugin_id': kPluginId,
        if (withData) 'data_dir': temp.path,
      },
      'scope': <String, dynamic>{'team_id': ?team, 'agent_id': ?agent},
    });
    final Map<Object?, Map<String, dynamic>> responses = await core.waitFor(
      <Object?>[id],
    );
    final Map<String, dynamic> frame = responses[id] ?? <String, dynamic>{};
    return asMap(asMap(frame['result'])['reply']);
  }

  Map<String, dynamic> payloadOf(Map<String, dynamic> reply) =>
      asMap(reply['payload']);

  String toolTextOf(Map<String, dynamic>? frame) {
    final List<dynamic> content =
        asMap(asMap(frame ?? <String, dynamic>{})['result'])['content']
            as List<dynamic>? ??
        <dynamic>[];
    return content.isEmpty ? '' : asString(asMap(content.first)['text']);
  }

  final String lineRoot = <String>[
    temp.path,
    'production_lines',
    'team_a',
    'pl_demo',
  ].join(Platform.pathSeparator);

  try {
    unawaited(core.start());
    core.ask('hello', M.hello, <String, dynamic>{'plugin_id': kPluginId});
    await core.waitFor(<Object?>['hello']);

    check.check(
      core.outgoing(M.stationRegister).length,
      1,
      '启动后注册执行站',
    );

    // 数据根 / 团队 fail-closed。
    final Map<String, dynamic> noData = await call(
      'no-data',
      'production.line.list',
      <String, Object?>{},
      withData: false,
    );
    check.check(noData['code'], 'missing_data_dir', '缺 data_dir ⇒ missing_data_dir');
    final Map<String, dynamic> noTeam = await call(
      'no-team',
      'production.line.list',
      <String, Object?>{},
      team: null,
    );
    check.check(noTeam['code'], 'team_required', '缺 team_id ⇒ team_required');

    // 产线：建 / 列 / 查 + 落盘。
    final Map<String, dynamic> created = await call(
      'line-create',
      'production.line.create',
      <String, Object?>{'id': 'pl_demo', 'name': '标准开发流'},
    );
    check.check(asMap(payloadOf(created)['line'])['id'], 'pl_demo', '建产线');
    final Map<String, dynamic> listed = await call(
      'line-list',
      'production.line.list',
      <String, Object?>{},
    );
    check.check(payloadOf(listed)['count'], 1, '产线列表 1 条');
    final Map<String, dynamic> fetched = await call(
      'line-get',
      'production.line.get',
      <String, Object?>{'line_id': 'pl_demo'},
    );
    check.check(
      asMap(payloadOf(fetched)['line'])['name'],
      '标准开发流',
      '产线详情',
    );
    check.that(
      File('$lineRoot${Platform.pathSeparator}line.yaml').existsSync(),
      'line.yaml 落盘',
    );
    check.that(
      File('$lineRoot${Platform.pathSeparator}inbox.jsonl').existsSync(),
      'inbox.jsonl 落盘',
    );
    final Map<String, dynamic> missingLine = await call(
      'line-missing',
      'production.line.get',
      <String, Object?>{'line_id': 'pl_nope'},
    );
    check.check(missingLine['code'], 'not_found', '缺产线 ⇒ not_found');

    // 任务：A(p10) ← B(p50) 依赖 A；C(p50) 独立。
    await call('task-a', 'production.task.create', <String, Object?>{
      'line_id': 'pl_demo',
      'task': <String, Object?>{
        'id': 'A',
        'title': '底座',
        'status': 'queued',
        'priority': 10,
      },
    });
    await call('task-b', 'production.task.create', <String, Object?>{
      'line_id': 'pl_demo',
      'task': <String, Object?>{
        'id': 'B',
        'title': '依赖 A',
        'status': 'queued',
        'priority': 50,
        'depends_on': <String>['A'],
      },
    });
    await call('task-c', 'production.task.create', <String, Object?>{
      'line_id': 'pl_demo',
      'task': <String, Object?>{
        'id': 'C',
        'title': '独立',
        'status': 'queued',
        'priority': 50,
      },
    });
    check.that(
      File(
        '$lineRoot${Platform.pathSeparator}tasks${Platform.pathSeparator}A'
        '${Platform.pathSeparator}task.yaml',
      ).existsSync(),
      'task.yaml 落盘',
    );

    final Map<String, dynamic> nextPayload = payloadOf(
      await call('queue-next', 'production.queue.next', <String, Object?>{
        'line_id': 'pl_demo',
      }),
    );
    check.check(
      asMap((nextPayload['tasks'] as List<dynamic>).first)['id'],
      'C',
      '队列先派无依赖的 C（B 等 A）',
    );
    check.check(
      asMap((nextPayload['skipped'] as List<dynamic>).first)['id'],
      'B',
      'B 因依赖被跳过',
    );
    check.check(
      nextPayload['queue'],
      <String>['B', 'C', 'A'],
      '队列按 priority / created_at / id 排序',
    );

    // 非法迁移与 blocked 理由。
    final Map<String, dynamic> illegal = await call(
      'illegal',
      'production.task.transition',
      <String, Object?>{
        'line_id': 'pl_demo',
        'task_id': 'A',
        'to': 'done',
      },
    );
    check.check(illegal['code'], 'invalid_transition', 'queued → done 非法');
    final Map<String, dynamic> noReason = await call(
      'blocked-no-reason',
      'production.task.transition',
      <String, Object?>{
        'line_id': 'pl_demo',
        'task_id': 'A',
        'to': 'blocked',
      },
    );
    check.check(noReason['code'], 'reason_required', 'blocked 必须带理由');
    await call('blocked', 'production.task.transition', <String, Object?>{
      'line_id': 'pl_demo',
      'task_id': 'A',
      'to': 'blocked',
      'reason': '等拍板',
    });
    await call('unblocked', 'production.task.transition', <String, Object?>{
      'line_id': 'pl_demo',
      'task_id': 'A',
      'to': 'queued',
    });

    // A 走完整链到 done。
    for (final String to in <String>[
      'packing',
      'packed',
      'running',
      'gating',
      'done',
    ]) {
      final Map<String, dynamic> reply = await call(
        'a-$to',
        'production.task.transition',
        <String, Object?>{'line_id': 'pl_demo', 'task_id': 'A', 'to': to},
      );
      check.check(
        asMap(payloadOf(reply)['task'])['status'],
        to,
        'A → $to',
      );
    }
    final Map<String, dynamic> afterDone = payloadOf(
      await call('queue-next-2', 'production.queue.next', <String, Object?>{
        'line_id': 'pl_demo',
      }),
    );
    check.check(
      asMap((afterDone['tasks'] as List<dynamic>).first)['id'],
      'B',
      'A 完成后 B 可派发',
    );

    // 崩溃恢复：C 卡在 packing → 回 queued + 一条 interrupted 台账，重复 0 写。
    await call('c-packing', 'production.task.transition', <String, Object?>{
      'line_id': 'pl_demo',
      'task_id': 'C',
      'to': 'packing',
    });
    final Map<String, dynamic> recovered = payloadOf(
      await call('recover', 'production.queue.recover', <String, Object?>{
        'line_id': 'pl_demo',
      }),
    );
    check.check(recovered['count'], 1, '恢复 1 个 in-flight');
    final Map<String, dynamic> recoveredAgain = payloadOf(
      await call('recover-2', 'production.queue.recover', <String, Object?>{
        'line_id': 'pl_demo',
      }),
    );
    check.check(recoveredAgain['count'], 0, '重复 recover 0 写');
    final Map<String, dynamic> runs = payloadOf(
      await call('runs', 'production.run.list', <String, Object?>{
        'line_id': 'pl_demo',
      }),
    );
    check.check(runs['count'], 1, 'interrupted run 落台账');
    check.check(
      asMap((runs['runs'] as List<dynamic>).first)['status'],
      'interrupted',
      'run 状态 = interrupted',
    );
    final Map<String, dynamic> cTask = payloadOf(
      await call('c-get', 'production.task.get', <String, Object?>{
        'line_id': 'pl_demo',
        'task_id': 'C',
      }),
    );
    check.check(asMap(cTask['task'])['status'], 'queued', 'C 已回 queued');

    // 索引：损坏后重建一次，第二次 0 写。
    final File stateFile = File(
      '$lineRoot${Platform.pathSeparator}state.json',
    );
    stateFile.writeAsStringSync('{"broken": true}');
    final Map<String, dynamic> rebuilt = payloadOf(
      await call('rebuild', 'production.queue.rebuild', <String, Object?>{
        'line_id': 'pl_demo',
      }),
    );
    check.check(rebuilt['changed'], true, '损坏索引被重建');
    final Map<String, dynamic> rebuiltAgain = payloadOf(
      await call('rebuild-2', 'production.queue.rebuild', <String, Object?>{
        'line_id': 'pl_demo',
      }),
    );
    check.check(rebuiltAgain['changed'], false, '重建幂等（第二次 0 写）');
    check.check(
      jsonDecode(stateFile.readAsStringSync())['queue'],
      <String>['B', 'C'],
      'state.queue 与 task.yaml 对齐（A 已 done）',
    );

    // ── P3 准备阶段：假 docnorm / llm / settings，跑完整窗口 → 落档 ──
    final String ws = '${temp.path}${Platform.pathSeparator}ws';
    Directory(ws).createSync(recursive: true);
    final List<Map<String, dynamic>> workerCalls = <Map<String, dynamic>>[];
    int gitCalls = 0;
    core.onMethod(M.stationCommand, (Map<String, dynamic> params) {
      final String command = asString(params['command']);
      switch (command) {
        case 'docnorm.query':
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{
              'mode': 'lexical',
              'results': <Object?>[
                <String, Object?>{
                  'doc': 'docs/project-status.md',
                  'heading': 'H 车道',
                  'snippet': '生产线 P1/P2 已完成',
                },
              ],
            },
          };
        case 'settings.define':
          return <String, dynamic>{'ok': true, 'payload': <String, dynamic>{}};
        case 'settings.get':
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{'value': 2},
          };
        case 'llm.call':
          final List<dynamic> messages = params['arguments'] is Map
              ? (asMap(params['arguments'])['messages'] as List<dynamic>? ??
                    <dynamic>[])
              : <dynamic>[];
          final String text = messages
              .map((dynamic item) => asString(asMap(item)['content']))
              .join('\n');
          if (text.contains('侦查员')) {
            return <String, dynamic>{
              'ok': true,
              'payload': <String, dynamic>{
                'json': <String, Object?>{
                  'regular': <Object?>[
                    <String, Object?>{
                      'text': '改列表',
                      'landing': 'lib/ui/agent_list.dart',
                    },
                  ],
                  'special': <Object?>[
                    <String, Object?>{'text': '本地模型', 'why': '云端慢'},
                  ],
                  'questions': <Object?>[
                    for (int i = 1; i <= 5; i++)
                      <String, Object?>{
                        'text': '问题 $i',
                        'default': '默认 $i',
                        'recommended': '推荐 $i',
                        'consequence': '后果 $i',
                      },
                  ],
                  'fallbacks': <Object?>['退回云端'],
                  'notes': <Object?>['数据库不可动'],
                  'flags': <String>['lib/ui/agent_list.dart'],
                },
                'text': '{}',
                'model': 'fake',
              },
            };
          }
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{
              'json': <String, Object?>{
                'in': <String>['列表过滤'],
                'out': <String>['不动数据库'],
                'not_doing': <String>['不做搜索'],
                'tasks': <Object?>[
                  <String, Object?>{
                    'id': 'T1',
                    'title': '改列表',
                    'acceptance': <String>['用例全绿'],
                    'write_scope': <String>['lib/ui/agent_list.dart'],
                  },
                  <String, Object?>{
                    'id': 'T2',
                    'title': '补测试',
                    'depends_on': <String>['T1'],
                    'acceptance': <String>['新用例覆盖过滤'],
                  },
                ],
              },
              'text': '{}',
              'model': 'fake',
            },
          };
        case 'agent.worker.run':
          {
            final Map<String, dynamic> workerArgs = asMap(params['arguments']);
            workerCalls.add(workerArgs);
            final String role = asString(workerArgs['role']);
            if (role == 'packer') {
              return <String, dynamic>{
                'ok': true,
                'payload': <String, dynamic>{
                  'worker_id': 'sub_packer',
                  'role': role,
                  'status': 'ok',
                  'error': '',
                  'report': jsonEncode(<String, Object?>{
                    'files': <Object?>[
                      <String, Object?>{
                        'path': 'lib/ui/agent_list.dart',
                        'start_line': 1,
                        'end_line': 3,
                        'content': 'class AgentList {}',
                      },
                    ],
                    'baseline': <Object?>['dart analyze'],
                    'risks': <String>[],
                    'dependencies': <String>[],
                  }),
                },
              };
            }
            if (role == 'expert') {
              return <String, dynamic>{
                'ok': true,
                'payload': <String, dynamic>{
                  'worker_id': 'sub_expert',
                  'role': role,
                  'model_id': 'lfm3',
                  'status': 'ok',
                  'error': '',
                  'report': jsonEncode(<String, Object?>{
                    'conclusion': '按 A 的公开 API 用即可',
                    'evidence': <String>['lib/ui/agent_list.dart:1 — class 定义'],
                    'suggestion': '先 read 再 edit',
                    'open': <String>['旧版本行为未验证'],
                  }),
                },
              };
            }
            return <String, dynamic>{
              'ok': true,
              'payload': <String, dynamic>{
                'worker_id': 'sub_executor',
                'role': role,
                'status': 'ok',
                'error': '',
                'report': '已改 lib/ui/agent_list.dart',
              },
            };
          }
        case 'production.task.expert':
          // tools/call → 本插件执行站的自回路（假核只回形状，真核会带 meta.data_dir）。
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{
              'status': 'ok',
              'text': '结论：假的\n依据：\n- lib/a.dart:1\n建议：照做\n未决：\n- （无）',
              'used': 1,
              'max_per_task': 3,
              'remaining': 2,
            },
          };
        case 'local.lease.register':
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{
              'lease_id': 'lease_selftest',
              'root': ws,
            },
          };
        case 'local.exec.command':
          {
            final String cmd = asString(asMap(params['arguments'])['command']);
            if (cmd.contains('git status')) {
              gitCalls += 1;
              return <String, dynamic>{
                'ok': true,
                'payload': <String, dynamic>{
                  'text': gitCalls.isOdd
                      ? ''
                      : ' M lib/ui/agent_list.dart',
                  'is_error': false,
                  'exit_code': 0,
                },
              };
            }
            return <String, dynamic>{
              'ok': true,
              'payload': <String, dynamic>{
                'text': 'ok',
                'is_error': false,
                'exit_code': 0,
              },
            };
          }
        default:
          return <String, dynamic>{
            'ok': false,
            'error': '假核心不认的站命令：$command',
          };
      }
    });

    await call('prep-line', 'production.line.create', <String, Object?>{
      'id': 'pl_prep',
      'name': '准备阶段',
      'workspace_dir': ws,
    });
    await call('prep-intake', 'production.prepare.intake', <String, Object?>{
      'line_id': 'pl_prep',
      'task': <String, Object?>{
        'id': 'T_prep',
        'title': '列表过滤',
        'intake': <String, Object?>{
          'goal': '会话列表能按项目过滤',
          'current': '只有 flat 列表',
          'acceptance': '只剩该项目会话；有测试',
        },
      },
    });
    final Map<String, dynamic> reconReply = payloadOf(
      await call('prep-recon', 'production.prepare.recon', <String, Object?>{
        'line_id': 'pl_prep',
        'task_id': 'T_prep',
      }),
    );
    check.check(reconReply['open'], 2, '追问上限读 settings（=2）');
    check.check(reconReply['dropped'], 3, '超限问题被截断且计数可见');
    check.that(
      File(
        <String>[ws, 'docs', 'production_lines', 'pl_prep', 'recon.md'].join(
          Platform.pathSeparator,
        ),
      ).existsSync(),
      'recon.md 落项目资产',
    );

    await call('prep-close', 'production.prepare.window.close', <String, Object?>{
      'line_id': 'pl_prep',
    });
    final Map<String, dynamic> blocked = await call(
      'prep-finalize-blocked',
      'production.prepare.finalize',
      <String, Object?>{'line_id': 'pl_prep', 'task_id': 'T_prep'},
    );
    check.check(blocked['code'], 'questions_open', '未答不实施（finalize 被拒）');

    await call('prep-open', 'production.prepare.window.open', <String, Object?>{
      'line_id': 'pl_prep',
    });
    final Map<String, dynamic> recommended = payloadOf(
      await call(
        'prep-recommended',
        'production.prepare.all_recommended',
        <String, Object?>{'line_id': 'pl_prep', 'task_id': 'T_prep'},
      ),
    );
    check.check(recommended['open'], 0, '全部按推荐后 0 条未答');
    check.check(recommended['ready'], true, '答完即可落档');

    final Map<String, dynamic> finalized = payloadOf(
      await call('prep-finalize', 'production.prepare.finalize', <String, Object?>{
        'line_id': 'pl_prep',
        'task_id': 'T_prep',
      }),
    );
    check.check(
      asMap(finalized['task'])['status'],
      'scoped',
      '准备任务落档后 scoped',
    );
    check.check(
      (finalized['created_tasks'] as List<dynamic>).length,
      2,
      '拆出 2 个 queued 任务',
    );
    check.that(
      File(
        <String>[ws, 'docs', 'production_lines', 'pl_prep', 'plan.md'].join(
          Platform.pathSeparator,
        ),
      ).existsSync(),
      'plan.md 落项目资产',
    );

    // ── P4 执行阶段：假员工 + 假本机命令，打包 → 执行 → 门控 → done ──
    final Map<String, dynamic> packed = payloadOf(
      await call(
        'p4-pack',
        'production.task.pack',
        <String, Object?>{'line_id': 'pl_prep', 'task_id': 'T1'},
        agent: 'agt',
      ),
    );
    check.check(packed['status'], 'packed', 'P4 打包 → packed');
    check.check(
      asMap(packed['task'])['status'],
      'packed',
      'T1 状态 = packed',
    );
    check.that(
      File(
        <String>[
          temp.path,
          'production_lines',
          'team_a',
          'pl_prep',
          'tasks',
          'T1',
          'pack.json',
        ].join(Platform.pathSeparator),
      ).existsSync(),
      'pack.json 落插件数据',
    );
    check.that(
      File(
        <String>[
          ws,
          'docs',
          'production_lines',
          'pl_prep',
          'tasks',
          'T1',
          'pack.md',
        ].join(Platform.pathSeparator),
      ).existsSync(),
      'pack.md 落项目资产',
    );
    check.check(
      workerCalls.length,
      1,
      '打包调用一次员工',
    );
    check.check(workerCalls.first['role'], 'packer', '打包角色 = packer');
    check.that(
      (workerCalls.first['tools'] as List<dynamic>).contains('read') &&
          !(workerCalls.first['tools'] as List<dynamic>).contains('write'),
      '打包工具只读（无 write）',
    );

    final Map<String, dynamic> executed = payloadOf(
      await call(
        'p4-run',
        'production.task.run',
        <String, Object?>{'line_id': 'pl_prep', 'task_id': 'T1'},
        agent: 'agt',
      ),
    );
    check.check(executed['status'], 'done', 'P4 门控通过 → done');
    check.check(
      asMap(executed['task'])['status'],
      'done',
      'T1 状态 = done',
    );
    check.check(
      asMap((executed['gate'] as List<dynamic>).single)['exit_code'],
      0,
      '门控退出码 0',
    );
    check.check(workerCalls.length, 2, '执行再调用一次员工');
    check.check(workerCalls.last['role'], 'executor', '执行角色 = executor');
    final Map<String, dynamic> taskRuns = payloadOf(
      await call('p4-runs', 'production.run.list', <String, Object?>{
        'line_id': 'pl_prep',
        'task_id': 'T1',
      }),
    );
    check.check(taskRuns['count'], 2, 'packer + executor 两条运行台账');
    final Map<String, dynamic> message = payloadOf(
      await call('p4-message', 'production.task.message', <String, Object?>{
        'line_id': 'pl_prep',
        'task_id': 'T1',
        'from': 'executor',
        'to': 'packer',
        'kind': 'note',
        'text': '已按片段改完',
      }),
    );
    check.check(message['count'], 1, '任务内 message 线程落盘');
    await call('p4-task-d', 'production.task.create', <String, Object?>{
      'line_id': 'pl_prep',
      'task': <String, Object?>{
        'id': 'T3',
        'title': '身份校验用',
        'status': 'queued',
        'write_scope': <String>['lib/x.dart'],
      },
    });
    final Map<String, dynamic> missingAgent = await call(
      'p4-no-agent',
      'production.task.pack',
      <String, Object?>{'line_id': 'pl_prep', 'task_id': 'T3'},
    );
    check.check(missingAgent['code'], 'agent_required', '缺发起者身份 fail-closed');

    // ── P5 专家工具：收集站贡献 / 默认关闭 / 次数上限 / 只读 / 台账 / 工具调用 ──
    core.ask('p5-collect', M.stationRequest, <String, dynamic>{
      'station_id': kToolCollectStation,
      'payload': <String, dynamic>{'action': 'list'},
    });
    final Map<String, dynamic> collectFrame =
        (await core.waitFor(<Object?>['p5-collect']))['p5-collect'] ??
        <String, dynamic>{};
    final Map<String, dynamic> collectReply = asMap(
      asMap(collectFrame['result'])['reply'],
    );
    final List<dynamic> collected =
        asMap(collectReply['payload'])['tools'] as List<dynamic>? ??
        <dynamic>[];
    check.check(collected.length, 1, '向 tree.agent 收集站贡献 1 个工具');
    check.check(asMap(collected.first)['name'], kAskExpertTool, '贡献的是 ask_expert');

    // 默认关闭（pl_prep 是默认 roles.expert.enabled=false）。
    final Map<String, dynamic> expertOff = await call(
      'p5-off',
      'production.task.expert',
      <String, Object?>{
        'line_id': 'pl_prep',
        'task_id': 'T1',
        'question': 'X 怎么用？',
      },
      agent: 'agt',
    );
    check.check(expertOff['code'], 'expert_disabled', '默认不能召专家');

    // 启用专家：次数上限 2，成功回答落 runs 台账。
    await call('p5-line', 'production.line.create', <String, Object?>{
      'id': 'pl_expert',
      'name': '专家产线',
      'workspace_dir': ws,
      'roles': <String, Object?>{
        'expert': <String, Object?>{
          'enabled': true,
          'model_id': 'lfm3',
          'tools': <String>['read', 'grep'],
          'max_per_task': 2,
        },
      },
    });
    await call('p5-task', 'production.task.create', <String, Object?>{
      'line_id': 'pl_expert',
      'task': <String, Object?>{
        'id': 'E1',
        'title': '问专家',
        'status': 'queued',
        'write_scope': <String>['lib/a.dart'],
      },
    });
    final Map<String, dynamic> expertOk = payloadOf(
      await call('p5-expert', 'production.task.expert', <String, Object?>{
        'line_id': 'pl_expert',
        'task_id': 'E1',
        'role': 'packer',
        'question': 'X 怎么用？',
        'context': 'lib/a.dart:1 class A {}',
      }, agent: 'agt'),
    );
    check.check(expertOk['status'], 'ok', '启用后专家回答成功');
    check.check(expertOk['remaining'], 1, '单任务次数上限计数');
    check.that(
      asString(expertOk['text']).contains('结论：') &&
          asString(expertOk['text']).contains('未决：'),
      '输出固定四段（结论 / 依据 / 建议 / 未决）',
    );
    final Map<String, dynamic> expertRuns = payloadOf(
      await call('p5-runs', 'production.run.list', <String, Object?>{
        'line_id': 'pl_expert',
        'task_id': 'E1',
      }),
    );
    check.check(expertRuns['count'], 1, '专家调用落 runs 台账');
    check.check(
      asMap((expertRuns['runs'] as List<dynamic>).first)['role'],
      'expert',
      '台账角色 = expert',
    );

    // 启用专家后，打包工具表自动含 ask_expert（专家默认关闭时不出现）。
    await call('p5-pack', 'production.task.pack', <String, Object?>{
      'line_id': 'pl_expert',
      'task_id': 'E1',
    }, agent: 'agt');
    check.that(
      (workerCalls.last['tools'] as List<dynamic>).contains(kAskExpertTool),
      '打包工具表含 ask_expert',
    );

    await call('p5-expert-2', 'production.task.expert', <String, Object?>{
      'line_id': 'pl_expert',
      'task_id': 'E1',
      'question': '另一个问题',
    }, agent: 'agt');
    final Map<String, dynamic> expertOver = await call(
      'p5-expert-3',
      'production.task.expert',
      <String, Object?>{
        'line_id': 'pl_expert',
        'task_id': 'E1',
        'question': '第三个问题',
      },
      agent: 'agt',
    );
    check.check(
      expertOver['code'],
      'expert_limit_exceeded',
      '超限拒绝（2/2）',
    );
    final Map<String, dynamic> expertNested = await call(
      'p5-nested',
      'production.task.expert',
      <String, Object?>{
        'line_id': 'pl_expert',
        'task_id': 'E1',
        'role': 'expert',
        'question': '专家再召专家',
      },
      agent: 'agt',
    );
    check.check(
      expertNested['code'],
      'expert_not_allowed',
      '专家不能再召专家',
    );

    // 专家工具表含 write ⇒ 直接拒绝（专家不落盘）。
    await call('p5-evil-line', 'production.line.create', <String, Object?>{
      'id': 'pl_evil',
      'name': '越界专家',
      'workspace_dir': ws,
      'roles': <String, Object?>{
        'expert': <String, Object?>{
          'enabled': true,
          'tools': <String>['read', 'write'],
        },
      },
    });
    await call('p5-evil-task', 'production.task.create', <String, Object?>{
      'line_id': 'pl_evil',
      'task': <String, Object?>{
        'id': 'E2',
        'title': '越界',
        'status': 'queued',
        'write_scope': <String>['lib/a.dart'],
      },
    });
    final Map<String, dynamic> expertEvil = await call(
      'p5-evil',
      'production.task.expert',
      <String, Object?>{
        'line_id': 'pl_evil',
        'task_id': 'E2',
        'question': 'X?',
      },
      agent: 'agt',
    );
    check.check(
      expertEvil['code'],
      'expert_tools_invalid',
      '专家工具表不许有 write',
    );

    // tools/call：非产线会话被拒；产线会话经执行站回到本插件。
    core.ask('p5-tool-bad', M.toolsCall, <String, dynamic>{
      'name': 'plugin__tree.production.line__ask_expert',
      'arguments': <String, dynamic>{
        'line_id': 'pl_expert',
        'task_id': 'E1',
        'question': 'X?',
      },
      'scope': <String, dynamic>{
        'agent_id': 'agt',
        'team_id': 'team_a',
        'session_id': 's1',
      },
    });
    final Map<Object?, Map<String, dynamic>> badTool = await core.waitFor(
      <Object?>['p5-tool-bad'],
    );
    check.that(
      toolTextOf(badTool['p5-tool-bad']).contains('只对产线员工开放'),
      'ask_expert 只对产线任务会话开放',
    );
    core.ask('p5-tool', M.toolsCall, <String, dynamic>{
      'name': 'plugin__tree.production.line__ask_expert',
      'arguments': <String, dynamic>{
        'line_id': 'pl_expert',
        'task_id': 'E1',
        'question': 'X?',
      },
      'scope': <String, dynamic>{
        'agent_id': 'agt',
        'team_id': 'team_a',
        'session_id': 'pl_pl_expert_E1',
      },
    });
    final Map<Object?, Map<String, dynamic>> okTool = await core.waitFor(
      <Object?>['p5-tool'],
    );
    check.that(
      toolTextOf(okTool['p5-tool']).contains('结论：') &&
          toolTextOf(okTool['p5-tool']).contains('剩余'),
      'ask_expert 工具回四段 + 剩余次数',
    );

    // ── P6 项目整理：只读扫描 / 固定 schema / 只写 audit.md ──
    final String auditRoot = ws;
    final File todoFile = File(
      <String>[auditRoot, 'lib', 'todo.dart'].join(Platform.pathSeparator),
    );
    todoFile.parent.createSync(recursive: true);
    todoFile.writeAsStringSync('// TODO: 收尾\nclass X {}\n// FIXME: 边界\n');
    final String duplicateBody = 'x' * 2048;
    File(
      <String>[auditRoot, 'lib', 'dup_a.txt'].join(Platform.pathSeparator),
    ).writeAsStringSync(duplicateBody);
    File(
      <String>[auditRoot, 'lib', 'dup_b.txt'].join(Platform.pathSeparator),
    ).writeAsStringSync(duplicateBody);
    File(
      <String>[auditRoot, 'lib', 'big.txt'].join(Platform.pathSeparator),
    ).writeAsStringSync('y' * 300000);
    await call('audit-line', 'production.line.create', <String, Object?>{
      'id': 'pl_audit',
      'name': '项目整理',
      'workspace_dir': ws,
    });
    final File auditAsset = File(
      <String>[
        auditRoot,
        'docs',
        'production_lines',
        'pl_audit',
        'audit.md',
      ].join(Platform.pathSeparator),
    );
    final Map<String, dynamic> auditDry = payloadOf(
      await call('audit-dry', 'production.audit.run', <String, Object?>{
        'line_id': 'pl_audit',
        'write': false,
      }),
    );
    check.that(!auditAsset.existsSync(), 'write=false 不写产物');
    final Map<String, dynamic> auditReport = asMap(auditDry['report']);
    check.check(auditReport['version'], 1, '审计报告 schema version=1');
    final List<dynamic> auditTodos =
        auditReport['todos'] as List<dynamic>? ?? <dynamic>[];
    check.that(
      auditTodos.any(
        (dynamic item) =>
            asMap(item)['path'] == 'lib/todo.dart' &&
            asMap(item)['marker'] == 'TODO',
      ),
      'TODO 台账识别（path / line / marker）',
    );
    check.check(
      (asMap(auditReport['docs'])['missing'] as List<dynamic>? ?? <dynamic>[])
          .length,
      4,
      '文档审计：缺 4 份项目记忆文档',
    );
    final Map<String, dynamic> redundancy = asMap(
      auditReport['redundancy'],
    );
    check.check(
      (redundancy['duplicates'] as List<dynamic>? ?? <dynamic>[]).length,
      1,
      '冗余候选：重复内容 1 组',
    );
    check.that(
      (redundancy['large_files'] as List<dynamic>? ?? <dynamic>[]).any(
        (dynamic item) => asMap(item)['path'] == 'lib/big.txt',
      ),
      '冗余候选：超大文件',
    );
    final String todoBefore = todoFile.readAsStringSync();
    final Map<String, dynamic> auditWritten = payloadOf(
      await call('audit-run', 'production.audit.run', <String, Object?>{
        'line_id': 'pl_audit',
      }),
    );
    check.check(auditWritten['written'], true, '默认写 audit.md');
    check.that(auditAsset.existsSync(), 'audit.md 落项目资产');
    check.check(
      auditAsset.readAsStringSync().contains('## TODO 台账'),
      true,
      'audit.md 含 TODO 台账',
    );
    check.check(
      todoFile.readAsStringSync(),
      todoBefore,
      '审计不改工作空间文件（只读）',
    );
  } catch (error) {
    check.that(false, '自检过程未抛异常', actual: '$error');
  } finally {
    await core.close();
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  }
  return check.finish(core.logs);
}
