// tree.production.line —— 标准开发流生产线（P1 数据模型 + 队列；P3 准备阶段；
// P4 打包 + 执行；P5 专家工具；P6 项目整理）。
//
// 定位（docs/pluginization/production-line-recon.md §7/§8/§9/§10/§11）：
// - headless 插件，granularity=team；产线与 Agent **并列**，数据落全局
//   `<data_root>/production_lines/production/`（§16）；执行身份写 `line.yaml.executor`；
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
const String kVersion = '0.11.1';

const String kStationName = 'production';

/// `tree.agent` 的工具收集站（P5 贡献 `ask_expert` 的落点）。
const String kToolCollectStation = 'plugin.tree.agent.collect.tools';

/// 追问上限的设置键。`tree.settings` 的 key 只允许字母/数字/下划线（不能带点），
/// 所以 §8.4 里写的 `questions.max_per_round` 落成 `questions_max_per_round`
/// （分组仍是 `questions`，UI 标题「追问」）。
const String kQuestionLimitKey = 'questions_max_per_round';

const String kStationReadme =
    '生产线：P1 production.line.create/list/get/migrate、production.task.create/list/get/'
    'transition、production.queue.next/rebuild/recover、production.run.list。'
    '产线与 Agent 并列，数据落全局 `<data_root>/production_lines/production/<line_id>/`：'
    'line.yaml（含 `executor: {agent_id, team_id}`，打包 / 执行 / 专家都用它）/ '
    'tasks/<task_id>/task.yaml / tasks/<task_id>/pack.json / runs/<run_id>.json / '
    'runs/messages.jsonl / state.json / inbox.jsonl / prepare.json；task.yaml 为唯一真值，'
    'state.json 可由它重建。production.line.migrate 把旧 `<team_id>/<line_id>/` 搬进全局'
    '作用域（幂等、冲突只报不覆盖、搬迁前留 .snapshots 快照、旧产线补 executor）。'
    '状态机：draft→recon→aligning→scoped→queued→packing→'
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
    'P6+ 逻辑去重：production.dedup.run（git tracked → 函数级分块 → 全字节缓存 → '
    'llm.embed 向量 → 全库 top-k → 结果落 tree.storage 的 plugin 绑定）与 '
    'production.dedup.status（只读结果）；seed=42，支持 mode=rebuild / limit 分批。'
    'P8 并行与预算：production.queue.dispatch（依赖已 done + 写域不相交 + '
    'limits.max_parallel_tasks 决定批次；写域交叠拒绝并行，交叠对象可见；只读不改状态）'
    '与 production.task.budget（token / 时长上限、累计用量、剩余与超限原因）；'
    '打包/执行累计 usage，预算到点软停（保留当前产出、标 budget_exceeded 转 blocked）。'
    '追问上限读 settings，缺省回退 line.yaml.limits 与 3（夹到 1–10）。'
    'REST（§10.2）：GET lines/line/tasks/task/runs/artifacts/audit/questions 与 '
    'POST lines/tasks/dispatch/decision/cancel/migrate、PATCH line/task、DELETE line；'
    'dispatch 默认后台跑（核心委派 30s 截止，模型跑不完），受理即回 accepted，'
    '进度看任务状态与运行台账，失败写 task.yaml.last_error。'
    'D6-O 主控决策循环：production.orchestrator.tick|status 每 tick 只做一个决策'
    '（continue / retry / ask / stop，优先级 stop > ask > retry > continue）；'
    'line.yaml.orchestrator 配 enabled / tick_interval_seconds / auto_retry / '
    'max_asks_per_task / stop_on_budget / max_ticks_per_minute，task.yaml.loop 记 '
    'attempts / ask_count / last_action / pending_question / stop_reason；'
    '快照哈希不变不调模型，单线单 tick，连续 3 次失败暂停产线，决策落 '
    'runs(role=orchestrator) 台账；运行期问答 production.task.question|questions|answer'
    '（blocked + question_pending，回答回 queued）；REST 增 orchestrate / pause / '
    'resume / orchestrator 与 tasks/{id}/answer。'
    'L0 就绪门：production.normalize.plan/apply/rollback/status 复用 docnorm.baseline'
    '（plan 0 写盘；apply 写前备份 + before/after sha256，失败自动恢复，不自动 git '
    'commit；rewrite 需 confirm_rewrite + allowlist）与 production.readiness.get'
    '（LG-02~07 落 <line>/ready.json）；未就绪时非 cleanup 命令 409 line_not_ready。';

ProductionService _service = ProductionService();
PreparationService? _preparation;
ProductionExecutionService? _execution;
ProductionAuditService? _audit;
OrchestratorService? _orchestrator;
ProductionNormalizationService? _normalization;
ProductionReadinessService? _readiness;
PluginKitServer? _activeServer;

/// Task 9.1 任务状态广播：注册成功后的站 id（空 = 未注册，事件只留日志）。
String _taskStateStationId = '';

/// 任务状态事件所属的数据根（回调签名不带 data_dir，按最近一次请求兜底）。
String _eventDataRoot = '';
bool _settingsDefined = false;

/// 事件 debounce：同一产线 1s 内的多次事件合并为一次 tick。
final Map<String, Timer> _eventTimers = <String, Timer>{};
final Map<String, DateTime> _lastTimerTick = <String, DateTime>{};
Timer? _periodicTick;

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
  _eventDataRoot = Platform.environment['TREE_DATA_ROOT'] ?? '';
  _service = ProductionService(onTaskState: _publishTaskState);
  // Task 6.4：产线只通过窄端口借 `tree.agent` 的记忆；正文进提示词，落盘只有元数据。
  final MemoryPort memoryPort = MemoryPort(
    get: _memoryGet,
    record: _memoryRecord,
  );
  _preparation = PreparationService(
    llm: _callLlm,
    visionLlm: _callVisionLlm,
    docQuery: _callDocQuery,
    limitReader: _readQuestionLimit,
    onCycle: _onProductionCycle,
    memory: memoryPort,
    onTaskState: _publishTaskState,
  );
  _execution = ProductionExecutionService(
    workers: _callWorker,
    commands: _runCommand,
    onCycle: _onProductionCycle,
    memory: memoryPort,
    onTaskState: _publishTaskState,
  );
  _audit = ProductionAuditService();
  _orchestrator = OrchestratorService(
    environment: Platform.environment,
    llm: _callLlm,
    dispatcher: _dispatchFromOrchestrator,
    execution: _execution,
  );
  // L0 就绪门：归一化复用 docnorm.baseline；readiness 额外核对去重状态。
  _normalization = ProductionNormalizationService(docnorm: _callDocnorm);
  _readiness = ProductionReadinessService(
    docnorm: _callDocnorm,
    dedupStatus: _dedupStatusFor,
  );
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
          ...kDedupCommands,
          ...kOrchestratorCommands,
          ...kNormalizationCommands,
          ...kReadinessCommands,
        ],
      },
    );
    server.channel.log(
      '自建执行站：${result['ok'] == true ? result['station_id'] : result['error']}',
    );
  } catch (error) {
    server.channel.log('自建执行站失败：$error');
  }
  // Task 9.1：任务状态广播站。注册失败只记日志（UI 收不到推送，业务照常）。
  try {
    final Map<String, dynamic> broadcast = await server.channel.request(
      M.stationRegister,
      <String, dynamic>{
        'kind': 'broadcast',
        'name': kTaskStateStationName,
        'description': '生产线任务状态事件（create / update / transition 后各一帧）',
        'readme': kTaskStateReadme,
        'shared': true,
      },
    );
    if (broadcast['ok'] == true) {
      _taskStateStationId = asString(broadcast['station_id']).isEmpty
          ? kTaskStateStationId
          : asString(broadcast['station_id']);
    } else {
      _taskStateStationId = '';
    }
    server.channel.log(
      '任务状态广播站：${broadcast['ok'] == true ? _taskStateStationId : broadcast['error']}',
    );
  } catch (error) {
    _taskStateStationId = '';
    server.channel.log('任务状态广播站注册失败：$error');
  }
  // D6-O O5：崩溃恢复 + 定时兜底（没有 data_dir 的进程不做这两件事）。
  _startOrchestratorDrivers(server);
}

/// 主控驱动（D6-O §3.1 / §5.4）：恢复一次 + 5s 定时兜底。
///
/// 定时只对有在途任务的产线生效，且每条产线按 `tick_interval_seconds`
/// 节流；没有 `TREE_DATA_ROOT` 时直接跳过（插件只处理带 data_dir 的请求）。
void _startOrchestratorDrivers(PluginKitServer server) {
  final String dataRoot = Platform.environment['TREE_DATA_ROOT'] ?? '';
  final OrchestratorService? orchestrator = _orchestrator;
  if (dataRoot.isEmpty || orchestrator == null) return;
  _eventDataRoot = dataRoot;
  final ProductionStore store = ProductionStore(
    dataRoot: dataRoot,
    onTaskState: _publishTaskState,
  );
  Future<void> recover() async {
    try {
      final List<LineRecord> lines = store.listLines();
      for (final LineRecord line in lines) {
        final List<TaskRecord> tasks = store.listTasks(line.id);
        if (!tasks.any((TaskRecord task) => task.status.isInFlight)) continue;
        store.recover(line.id);
        await orchestrator.tick(
          store,
          line.id,
          meta: <String, Object?>{'data_dir': dataRoot},
          scope: _scopeOf(line),
          trigger: 'recovery',
        );
      }
    } catch (error) {
      server.channel.log('主控崩溃恢复失败：$error');
    }
  }

  unawaited(recover());
  _periodicTick?.cancel();
  _periodicTick = Timer.periodic(const Duration(seconds: 5), (_) {
    unawaited(() async {
      try {
        for (final LineRecord line in store.listLines()) {
          final OrchestratorConfig config = OrchestratorConfig.of(line);
          if (!config.enabled || config.tickIntervalSeconds <= 0) continue;
          final DateTime now = DateTime.now();
          final DateTime? last = _lastTimerTick[line.id];
          if (last != null &&
              now.difference(last).inSeconds < config.tickIntervalSeconds) {
            continue;
          }
          _lastTimerTick[line.id] = now;
          await orchestrator.tick(
            store,
            line.id,
            meta: <String, Object?>{'data_dir': dataRoot},
            scope: _scopeOf(line),
            trigger: 'timer',
          );
        }
      } catch (error) {
        server.channel.log('主控定时 tick 失败：$error');
      }
    }());
  });
}

/// 主控调用模型 / 派发员工时使用的身份（取自 `line.yaml.executor`）。
Map<String, Object?> _scopeOf(LineRecord line) => <String, Object?>{
  if (line.executorAgentId.isNotEmpty) 'agent_id': line.executorAgentId,
  if (line.executorTeamId.isNotEmpty) 'team_id': line.executorTeamId,
};

/// Task 9.1：任务状态广播。回调签名不带 data_dir，用最近一次请求的数据根。
void _publishTaskState(String lineId, TaskRecord task) {
  final String dataDir = _eventDataRoot.isNotEmpty
      ? _eventDataRoot
      : (Platform.environment['TREE_DATA_ROOT'] ?? '');
  if (dataDir.isEmpty) {
    _activeServer?.channel.log('任务状态事件缺少 data_dir，跳过（$lineId/${task.id}）');
    return;
  }
  final String stationId = _taskStateStationId.isEmpty
      ? kTaskStateStationId
      : _taskStateStationId;
  try {
    publishTaskState(
      store: ProductionStore(dataRoot: dataDir),
      lineId: lineId,
      task: task,
      trigger: _taskStateTrigger,
      log: (String message) => _activeServer?.channel.log(message),
      stationId: stationId,
    );
  } catch (error) {
    _activeServer?.channel.log('任务状态事件发布失败：$error');
  }
}

/// 广播投递通道（`station/trigger`）；插件还没拿到 server 时给一个失败回包。
Future<Map<String, dynamic>> _taskStateTrigger(
  String stationId,
  Object? payload,
  Map<String, dynamic> meta,
  Map<String, dynamic> scope, {
  String? topic,
}) {
  final PluginKitServer? server = _activeServer;
  if (server == null) {
    return Future<Map<String, dynamic>>.value(<String, dynamic>{
      'ok': false,
      'error': 'server_unavailable',
    });
  }
  return server.channel.request(M.stationTrigger, <String, dynamic>{
    'station_id': stationId,
    if (topic != null && topic.isNotEmpty) 'topic': topic,
    'payload': payload,
    'meta': meta,
    'scope': scope,
  });
}

/// 主控决策后的派发：后台跑打包 / 执行，结束后 debounce 一次事件 tick。
Future<void> _dispatchFromOrchestrator(
  String lineId,
  String taskId,
  String stage,
  Map<String, Object?> meta,
  Map<String, Object?> scope,
) async {
  final String dataDir = asString(meta['data_dir']);
  if (dataDir.isEmpty) return;
  _eventDataRoot = dataDir;
  final ProductionStore store = ProductionStore(
    dataRoot: dataDir,
    onTaskState: _publishTaskState,
  );
  try {
    await dispatchProductionTask(
      store: store,
      execution: _execution,
      lineId: lineId,
      taskId: taskId,
      stage: stage,
      meta: meta,
      scope: scope,
      awaitDispatch: true,
    );
  } catch (error) {
    // 失败已写进 task.yaml.last_error；仍要 tick，让主控决定重试 / 停止。
    _activeServer?.channel.log('主控派发失败（$lineId/$taskId/$stage）：$error');
  } finally {
    _scheduleEventTick(lineId, dataDir, scope);
  }
}

/// 任务执行结束 / 准备落档后触发一次事件 tick（共用 [_scheduleEventTick] 的
/// 1s debounce，幂等；不在执行路径上等待 tick）。
Future<void> _onProductionCycle(
  String lineId,
  Map<String, Object?> meta,
  Map<String, Object?> scope,
) async {
  final String dataDir = asString(meta['data_dir']);
  if (dataDir.isEmpty) return;
  _scheduleEventTick(lineId, dataDir, scope);
}

/// 1s debounce：同一产线的多次事件合并为一次 tick（§6.4）。
void _scheduleEventTick(
  String lineId,
  String dataDir,
  Map<String, Object?> scope,
) {
  _eventTimers[lineId]?.cancel();
  _eventTimers[lineId] = Timer(const Duration(seconds: 1), () {
    _eventTimers.remove(lineId);
    final OrchestratorService? orchestrator = _orchestrator;
    if (orchestrator == null) return;
    _eventDataRoot = dataDir;
    unawaited(() async {
      try {
        await orchestrator.tick(
          ProductionStore(dataRoot: dataDir, onTaskState: _publishTaskState),
          lineId,
          meta: <String, Object?>{'data_dir': dataDir},
          scope: scope,
          trigger: 'event',
        );
      } catch (error) {
        _activeServer?.channel.log('主控事件 tick 失败：$error');
      }
    }());
  });
}

/// 向 `tree.agent` 的 `llm.call` 要一份 JSON：只透传本次请求的 scope（身份/团队）。
///
/// [modelId] = 产线主控的模型（`roles.orchestrator.model_id`）；非空时显式选中该
/// 模型池条目，空则沿用调用方 Agent 的模型（旧产线 / 未配主控）。
Future<Map<String, Object?>> _callLlm(
  String point,
  String system,
  String prompt,
  Map<String, Object?> scope,
  String modelId,
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
      if (modelId.trim().isNotEmpty) 'model_id': modelId.trim(),
    },
    '',
    scope,
  );
  final Object? json = payload['json'];
  if (json is Map) {
    return <String, Object?>{
      for (final MapEntry<dynamic, dynamic> entry in json.entries)
        entry.key.toString(): entry.value,
      // 主控台账要记用量；不污染模型自己的 JSON（下划线键不参与动作解析）。
      if (payload['usage'] is Map) '_usage': payload['usage'],
    };
  }
  final String text = asString(payload['text']);
  final Object? decoded = _jsonFromText(text);
  if (decoded is Map) {
    return <String, Object?>{
      for (final MapEntry<dynamic, dynamic> entry in decoded.entries)
        entry.key.toString(): entry.value,
      if (payload['usage'] is Map) '_usage': payload['usage'],
    };
  }
  throw ProductionFailure(
    '模型没有返回 JSON（$point）：${text.length > 200 ? '${text.substring(0, 200)}…' : text}',
    code: 'llm_bad_json',
  );
}

/// 向 `tree.agent` 的 `llm.call` 要一份 JSON（多模态）：图片按 OpenAI 形状的
/// `content` 数组送出去（`text` + `image_url`），回包解析与 `_callLlm` 同一口径。
Future<Map<String, Object?>> _callVisionLlm(
  String point,
  String system,
  String prompt,
  List<Map<String, Object?>> images,
  Map<String, Object?> scope,
  String modelId,
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
        <String, dynamic>{
          'role': 'user',
          'content': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'text': prompt},
            for (final Map<String, Object?> image in images)
              <String, dynamic>{
                'type': 'image_url',
                'image_url': <String, dynamic>{
                  'url': 'data:${image['mime']};base64,${image['base64']}',
                },
              },
          ],
        },
      ],
      'temperature': 0.2,
      if (modelId.trim().isNotEmpty) 'model_id': modelId.trim(),
    },
    '',
    scope,
  );
  final Object? json = payload['json'];
  if (json is Map) {
    return <String, Object?>{
      for (final MapEntry<dynamic, dynamic> entry in json.entries)
        entry.key.toString(): entry.value,
      if (payload['usage'] is Map) '_usage': payload['usage'],
    };
  }
  final String text = asString(payload['text']);
  final Object? decoded = _jsonFromText(text);
  if (decoded is Map) {
    return <String, Object?>{
      for (final MapEntry<dynamic, dynamic> entry in decoded.entries)
        entry.key.toString(): entry.value,
      if (payload['usage'] is Map) '_usage': payload['usage'],
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
    <String, dynamic>{'repo': repo, 'question': question, 'mode': 'hybrid'},
    '',
    scope,
  );
  return <String, Object?>{
    for (final MapEntry<String, dynamic> entry in payload.entries)
      entry.key: entry.value,
  };
}

/// 读 `tree.agent` 记忆（`agent.memory.get`）：通道缺失 / 异常一律降级为不可用。
///
/// 只回原始回包（含 `text` / `hash` / `sources`）；正文由 [MemoryPort] 只交给提示词，
/// 落盘的只有 `hash` / `sources` 这些元数据。
Future<Map<String, Object?>> _memoryGet(
  String agentId,
  String purpose,
  int budgetChars,
  Map<String, Object?> scope,
) async {
  final PluginKitServer? server = _activeServer;
  if (server == null) {
    return <String, Object?>{
      'error': '插件尚未就绪：agent.memory.get 通道不可用',
      'code': 'memory_unavailable',
    };
  }
  try {
    final Map<String, dynamic> payload = await server.channel.command(
      'agent.memory.get',
      <String, dynamic>{
        'agent_id': agentId,
        'purpose': purpose,
        'budget_chars': budgetChars,
      },
      '',
      scope,
    );
    return <String, Object?>{
      for (final MapEntry<String, dynamic> item in payload.entries)
        item.key: item.value,
    };
  } catch (error) {
    return <String, Object?>{
      'error': 'agent.memory.get 不可用：$error',
      'code': 'memory_unavailable',
    };
  }
}

/// 写一条 `tree.agent` 记忆（`agent.memory.record`）；失败同样只回不可用，不抛。
Future<Map<String, Object?>> _memoryRecord(
  Map<String, Object?> entry,
  Map<String, Object?> scope,
) async {
  final PluginKitServer? server = _activeServer;
  if (server == null) {
    return <String, Object?>{
      'error': '插件尚未就绪：agent.memory.record 通道不可用',
      'code': 'memory_unavailable',
    };
  }
  try {
    final Map<String, dynamic> payload = await server.channel.command(
      'agent.memory.record',
      <String, dynamic>{
        for (final String key in const <String>[
          'agent_id',
          'purpose',
          'summary',
          'sources',
          'line_id',
          'task_id',
        ])
          if (entry[key] != null) key: entry[key],
      },
      '',
      scope,
    );
    return <String, Object?>{
      for (final MapEntry<String, dynamic> item in payload.entries)
        item.key: item.value,
    };
  } catch (error) {
    return <String, Object?>{
      'error': 'agent.memory.record 不可用：$error',
      'code': 'memory_unavailable',
    };
  }
}

/// 文档归一化 / 就绪探针：向 `tree.docnorm` 的执行站下命令。
///
/// 只在 L0 就绪门（plan / apply / readiness.get）使用；失败收敛成
/// [ProductionFailure]，由命令门面回 `{code, message, missing}`。
Future<Map<String, Object?>> _callDocnorm(
  String command,
  Map<String, Object?> arguments,
  Map<String, Object?> scope,
) async {
  final PluginKitServer? server = _activeServer;
  if (server == null) {
    throw ProductionFailure(
      '插件尚未就绪：$command 通道不可用',
      code: 'docnorm_unavailable',
      missing: const <String>['docnorm'],
    );
  }
  try {
    final Map<String, dynamic> payload = await server.channel.command(
      command,
      <String, dynamic>{
        for (final MapEntry<String, Object?> entry in arguments.entries)
          entry.key: entry.value,
      },
      '',
      scope,
    );
    return <String, Object?>{
      for (final MapEntry<String, dynamic> entry in payload.entries)
        entry.key: entry.value,
    };
  } on CmdFailureException catch (error) {
    throw ProductionFailure(
      '$command 失败：${error.message}',
      code: error.code.isEmpty ? 'docnorm_failed' : error.code,
      missing: const <String>['docnorm'],
    );
  } catch (error) {
    throw ProductionFailure(
      '$command 异常：$error',
      code: 'docnorm_unavailable',
      missing: const <String>['docnorm'],
    );
  }
}

/// 就绪门的代码索引证据：`production.dedup.status`（只读已落盘结果）。
Future<Map<String, Object?>> _dedupStatusFor(
  String lineId,
  Map<String, Object?> meta,
  Map<String, Object?> scope,
) => _dedupServiceFor(scope).handle(
  'production.dedup.status',
  <String, Object?>{'line_id': lineId},
  meta,
  scope,
);

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

/// 追问上限：先确保全局 schema 已注册，再读值；失败交回 null（走 line.yaml）。
Future<int?> _readQuestionLimit(Map<String, Object?> scope) async {
  final PluginKitServer? server = _activeServer;
  if (server == null) return null;
  try {
    if (!_settingsDefined) {
      await server.channel.command(
        'settings.define',
        <String, dynamic>{'binding': 'plugin', 'schema': _questionSchema()},
        '',
        scope,
      );
      _settingsDefined = true;
    }
    final Map<String, dynamic> payload = await server.channel.command(
      'settings.get',
      <String, dynamic>{'binding': 'plugin', 'key': kQuestionLimitKey},
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

/// 设置在插件设置页显示的 schema（§8.4；v2 追加逻辑去重配置）。
Map<String, Object?> _questionSchema() => <String, Object?>{
  'schema_version': 2,
  'groups': <Map<String, Object?>>[
    <String, Object?>{'id': 'questions', 'title': '追问', 'order': 10},
    <String, Object?>{'id': 'dedup', 'title': '逻辑去重', 'order': 20},
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
    <String, Object?>{
      'key': 'dedup_enabled',
      'group': 'dedup',
      'type': 'bool',
      'title': '启用逻辑去重',
      'default': true,
      'help': '关闭后 production.dedup.run 直接跳过，不影响 FNV 精确去重。',
    },
    <String, Object?>{
      'key': 'dedup_model',
      'group': 'dedup',
      'type': 'string',
      'title': 'Embedding 模型',
      'default': '',
      'help': '留空 = 使用模型池里第一个 kind=embedding 的模型。',
    },
    <String, Object?>{
      'key': 'dedup_similarity_threshold',
      'group': 'dedup',
      'type': 'double',
      'title': '相似度阈值',
      'default': 0.90,
      'min': 0.5,
      'max': 0.99,
    },
    <String, Object?>{
      'key': 'dedup_top_k',
      'group': 'dedup',
      'type': 'int',
      'title': '每块召回数',
      'default': 5,
      'min': 1,
      'max': 20,
    },
    <String, Object?>{
      'key': 'dedup_embed_batch',
      'group': 'dedup',
      'type': 'int',
      'title': 'Embedding 批大小',
      'default': 32,
      'min': 1,
      'max': 64,
    },
    <String, Object?>{
      'key': 'dedup_instruction_prefix',
      'group': 'dedup',
      'type': 'string',
      'title': '指令前缀',
      'default': '',
      'help': '拼在待嵌入文本前；计入缓存键，改动会使旧向量失效。',
    },
    <String, Object?>{
      'key': 'dedup_normalize',
      'group': 'dedup',
      'type': 'enum',
      'title': '向量归一化',
      'default': 'l2',
      'options': <String>['l2', 'none'],
    },
    <String, Object?>{
      'key': 'dedup_pooling',
      'group': 'dedup',
      'type': 'enum',
      'title': '池化方式',
      'default': 'mean',
      'options': <String>['mean', 'cls'],
      'help': '记录并计入缓存键；实际池化由模型端决定。',
    },
    <String, Object?>{
      'key': 'dedup_max_file_bytes',
      'group': 'dedup',
      'type': 'int',
      'title': '单文件上限（字节）',
      'default': 262144,
      'min': 1024,
      'max': 8388608,
    },
    <String, Object?>{
      'key': 'dedup_files_per_request',
      'group': 'dedup',
      'type': 'int',
      'title': '每请求处理文件数',
      'default': 50,
      'min': 1,
      'max': 500,
    },
    <String, Object?>{
      'key': 'dedup_compare_per_request',
      'group': 'dedup',
      'type': 'int',
      'title': '每请求比对块数',
      'default': 100,
      'min': 1,
      'max': 500,
    },
    <String, Object?>{
      'key': 'dedup_max_index_chunks',
      'group': 'dedup',
      'type': 'int',
      'title': '索引块数上限',
      'default': 20000,
      'min': 100,
      'max': 100000,
      'help': '超过时只比较前 N 块并在 reasons 里说明。',
    },
  ],
};

/// 逻辑去重的服务实例：storage / settings 都走 plugin 绑定，scope 只作身份透传。
ProductionDedupService _dedupServiceFor(Map<String, Object?> scope) =>
    ProductionDedupService(
      environment: Platform.environment,
      storage: (String command, Map<String, dynamic> args) =>
          _callStorageWithScope(command, args, scope),
      embed: (DedupEmbedRequest request) => _callEmbedDedup(request, scope),
      settings: () => _readDedupConfig(scope),
    );

Future<Map<String, dynamic>> _callStorageWithScope(
  String command,
  Map<String, dynamic> arguments,
  Map<String, Object?> scope,
) async {
  final PluginKitServer? server = _activeServer;
  if (server == null) {
    throw ProductionFailure(
      '插件尚未就绪：tree.storage 通道不可用',
      code: 'storage_unavailable',
    );
  }
  return server.channel.command(
    command,
    <String, dynamic>{...arguments, 'binding': 'plugin'},
    '',
    scope,
  );
}

Future<DedupEmbedReply> _callEmbedDedup(
  DedupEmbedRequest request,
  Map<String, Object?> scope,
) async {
  final PluginKitServer? server = _activeServer;
  if (server == null) {
    return const DedupEmbedReply(
      error: '插件尚未就绪：llm.embed 通道不可用',
      code: 'embed_unavailable',
    );
  }
  try {
    final Map<String, dynamic> payload = await server.channel.command(
      'llm.embed',
      <String, dynamic>{
        'inputs': request.inputs,
        if (request.model.isNotEmpty) 'model': request.model,
      },
      '',
      scope,
    );
    final String reason = asString(payload['error']);
    return DedupEmbedReply(
      vectors: _vectorsOf(payload['vectors']),
      model: asString(payload['model']),
      dimensions: (payload['dimensions'] as num?)?.toInt() ?? 0,
      error: reason.trim().isNotEmpty
          ? reason
          : (payload['ok'] == false ? 'llm.embed 返回 ok:false' : ''),
      code: asString(payload['code']),
    );
  } on CmdFailureException catch (error) {
    return DedupEmbedReply(
      vectors: _vectorsOf(error.payload['vectors']),
      model: asString(error.payload['model']),
      dimensions: (error.payload['dimensions'] as num?)?.toInt() ?? 0,
      error: error.message,
      code: asString(error.payload['code']),
    );
  } catch (error) {
    return DedupEmbedReply(error: 'llm.embed 异常：$error');
  }
}

/// 读逻辑去重配置：先确保全局 schema 已注册，再 `settings.list`。
Future<DedupConfig> _readDedupConfig(Map<String, Object?> scope) async {
  final PluginKitServer? server = _activeServer;
  if (server == null) return DedupConfig.defaults;
  try {
    if (!_settingsDefined) {
      await server.channel.command(
        'settings.define',
        <String, dynamic>{'binding': 'plugin', 'schema': _questionSchema()},
        '',
        scope,
      );
      _settingsDefined = true;
    }
    final Map<String, dynamic> payload = await server.channel.command(
      'settings.list',
      <String, dynamic>{'binding': 'plugin'},
      '',
      scope,
    );
    final Map<String, Object?> values = <String, Object?>{
      for (final MapEntry<String, dynamic> entry in asMap(
        payload['values'],
      ).entries)
        entry.key: entry.value,
    };
    return DedupConfig.fromValues(values, environment: Platform.environment);
  } catch (_) {
    return DedupConfig.defaults;
  }
}

List<List<double>> _vectorsOf(Object? raw) {
  if (raw is! List) return const <List<double>>[];
  return <List<double>>[
    for (final Object? row in raw)
      if (row is List)
        <double>[
          for (final Object? value in row)
            if (value is num) value.toDouble(),
        ],
  ];
}

Future<Map<String, dynamic>?> handleRequest(
  String method,
  Map<String, dynamic> params,
) async {
  // 切片 2 / 3：REST 委派（§10.2 的读半边 + 写半边）；写操作走同一批命令门面。
  if (method == M.apiDelegate) {
    final Map<String, dynamic> envelope = asMap(params);
    final String dataDir = asString(envelope['data_dir']);
    if (dataDir.isNotEmpty) _eventDataRoot = dataDir;
    return handleProductionDelegate(
      envelope,
      service: _service,
      audit: _audit,
      execution: _execution,
      preparation: _preparation,
      orchestrator: _orchestrator,
      dedupFor: _dedupServiceFor,
      normalization: _normalization,
      readiness: _readiness,
    );
  }
  if (method != M.stationRequest) return null;
  // 路由申报：核心据此把 `/api/production/*` 的命中请求转成 `api/delegate`。
  if (asString(params['station_id']) == kApiRoutesStation) {
    return <String, dynamic>{
      'reply': <String, dynamic>{
        'payload': <String, dynamic>{'routes': kDeclaredRoutes},
      },
    };
  }
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
  final String requestDataDir = asString(asMap(params['meta'])['data_dir']);
  if (requestDataDir.isNotEmpty) _eventDataRoot = requestDataDir;
  final bool isPrepare = kPreparationCommands.contains(command);
  final bool isExecute = kExecutionCommands.contains(command);
  final bool isAudit = kAuditCommands.contains(command);
  final bool isDedup = kDedupCommands.contains(command);
  final bool isOrchestrator = kOrchestratorCommands.contains(command);
  final bool isNormalization = kNormalizationCommands.contains(command);
  final bool isReadiness = kReadinessCommands.contains(command);
  if (!isPrepare &&
      !isExecute &&
      !isAudit &&
      !isDedup &&
      !isOrchestrator &&
      !isNormalization &&
      !isReadiness &&
      !kProductionCommands.contains(command)) {
    return null;
  }
  try {
    final Map<String, Object?> scope = asMap(params['scope']);
    final Map<String, Object?> result = isPrepare
        ? await _preparation!.handle(
            command,
            asMap(payload['arguments']),
            asMap(params['meta']),
            scope,
          )
        : isExecute
        ? await _execution!.handle(
            command,
            asMap(payload['arguments']),
            asMap(params['meta']),
            scope,
          )
        : isAudit
        ? await _audit!.handle(
            command,
            asMap(payload['arguments']),
            asMap(params['meta']),
            scope,
          )
        : isDedup
        ? await _dedupServiceFor(scope).handle(
            command,
            asMap(payload['arguments']),
            asMap(params['meta']),
            scope,
          )
        : isOrchestrator
        ? await _orchestrator!.handle(
            command,
            asMap(payload['arguments']),
            asMap(params['meta']),
            scope,
          )
        : isNormalization
        ? await _normalization!.handle(
            command,
            asMap(payload['arguments']),
            asMap(params['meta']),
            scope,
          )
        : isReadiness
        ? await _readiness!.handle(
            command,
            asMap(payload['arguments']),
            asMap(params['meta']),
            scope,
          )
        : _service.handle(
            command,
            asMap(payload['arguments']),
            asMap(params['meta']),
            scope,
          );
    return <String, dynamic>{
      'reply': <String, dynamic>{'payload': result},
    };
  } on ProductionFailure catch (error) {
    return <String, dynamic>{
      'reply': <String, dynamic>{
        'error': error.message,
        'message': error.message,
        'code': error.code,
        'missing': error.missing,
      },
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
  // 结构 / 就绪门需要真实工作空间：给一条最小可扫描的包。
  final Directory demoWs = Directory(
    <String>[temp.path, 'ws'].join(Platform.pathSeparator),
  )..createSync(recursive: true);
  File(
    <String>[demoWs.path, 'pubspec.yaml'].join(Platform.pathSeparator),
  ).writeAsStringSync(
    'name: demo_ws\n'
    'description: 最小演示包：只提供 A\n'
    'environment:\n  sdk: ^3.0.0\n',
  );
  Directory(
    <String>[demoWs.path, 'lib'].join(Platform.pathSeparator),
  ).createSync(recursive: true);
  File(
    <String>[demoWs.path, 'lib', 'a.dart'].join(Platform.pathSeparator),
  ).writeAsStringSync('class A {}\n');
  File(
    <String>[demoWs.path, 'README.md'].join(Platform.pathSeparator),
  ).writeAsStringSync('# demo_ws\n\n## 职责\n\n最小演示包：只提供 A。\n');
  final ProductionStore selftestStore = ProductionStore(dataRoot: temp.path);

  /// 自检里没有 docnorm / 索引：直接落一份“已就绪”快照，只为跑通 REST 写路径。
  void markReady(String lineId) {
    handleStructureCommand(
      selftestStore,
      'production.structure.reevaluate',
      <String, Object?>{'line_id': lineId},
    );
    final LineRecord line = selftestStore.setLinePhase(lineId, 'ready');
    selftestStore.writeReady(lineId, <String, Object?>{
      'version': 1,
      'line_id': lineId,
      'ready': true,
      'graph_version': lineReadinessVersionOf(selftestStore, line),
      'missing': <String>[],
      'at': selftestStore.nowText(),
    });
  }

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
      'payload': <String, dynamic>{'command': command, 'arguments': arguments},
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

  /// 发一次 `api/delegate`（REST 口径），回 `{status, json}`。
  Future<Map<String, dynamic>> rest(
    Object id,
    String method,
    String path, {
    Map<String, Object?> query = const <String, Object?>{},
    Map<String, Object?> body = const <String, Object?>{},
    String agent = '',
    String? team = 'team_a',
  }) async {
    core.ask(id, M.apiDelegate, <String, dynamic>{
      'method': method,
      'path': path,
      'params': <String, dynamic>{},
      'query': query,
      'headers': <String, dynamic>{},
      'scope': <String, dynamic>{
        'team_id': ?team,
        if (agent.isNotEmpty) 'agent_id': agent,
      },
      'workspace_dir': '',
      'data_dir': temp.path,
      'agent_id': agent,
      'team_id': ?team,
      'request_id': 'selftest-rest-$id',
      if (body.isNotEmpty) 'body': jsonEncode(body),
    });
    final Map<Object?, Map<String, dynamic>> responses = await core.waitFor(
      <Object?>[id],
    );
    final Map<String, dynamic> frame = responses[id] ?? <String, dynamic>{};
    final Map<String, dynamic> reply = asMap(frame['result']);
    final String rawBody = asString(reply['body']);
    return <String, dynamic>{
      ...reply,
      'json': rawBody.isEmpty
          ? <String, dynamic>{}
          : asMap(jsonDecode(rawBody)),
    };
  }

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
    'production',
    'pl_demo',
  ].join(Platform.pathSeparator);

  try {
    unawaited(core.start());
    core.ask('hello', M.hello, <String, dynamic>{'plugin_id': kPluginId});
    await core.waitFor(<Object?>['hello']);

    check.check(core.outgoing(M.stationRegister).length, 2, '启动后注册执行站');

    // 数据根 fail-closed；team 只是调用方身份（§16 数据落全局作用域）。
    final Map<String, dynamic> noData = await call(
      'no-data',
      'production.line.list',
      <String, Object?>{},
      withData: false,
    );
    check.check(
      noData['code'],
      'missing_data_dir',
      '缺 data_dir ⇒ missing_data_dir',
    );
    final Map<String, dynamic> noTeam = await call(
      'no-team',
      'production.line.list',
      <String, Object?>{},
      team: null,
    );
    check.check(payloadOf(noTeam)['count'], 0, '缺 team_id 仍可读（产线数据全局存放）');

    // 产线：建 / 列 / 查 + 落盘。
    final Map<String, dynamic> created = await call(
      'line-create',
      'production.line.create',
      <String, Object?>{
        'id': 'pl_demo',
        'name': '标准开发流',
        'workspace_dir': demoWs.path,
        'executor': <String, Object?>{
          'agent_id': 'agt_demo',
          'team_id': 'team_a',
        },
      },
    );
    check.check(asMap(payloadOf(created)['line'])['id'], 'pl_demo', '建产线');
    check.check(
      asMap(asMap(payloadOf(created)['line'])['executor'])['agent_id'],
      'agt_demo',
      'line.yaml 带执行身份',
    );
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
    check.check(asMap(payloadOf(fetched)['line'])['name'], '标准开发流', '产线详情');
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
    markReady('pl_demo');
    await call('task-a', 'production.task.create', <String, Object?>{
      'line_id': 'pl_demo',
      'task': <String, Object?>{
        'id': 'A',
        'title': '底座',
        'status': 'queued',
        'priority': 10,
        'brief': '实现底座 A',
        'acceptance': <String>['A 可用'],
        'write_scope': <String>['lib/a.dart'],
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
        'brief': '在 A 上实现 B',
        'acceptance': <String>['B 可用'],
        'write_scope': <String>['lib/b.dart'],
      },
    });
    await call('task-c', 'production.task.create', <String, Object?>{
      'line_id': 'pl_demo',
      'task': <String, Object?>{
        'id': 'C',
        'title': '独立',
        'status': 'queued',
        'priority': 50,
        'brief': '实现 C',
        'acceptance': <String>['C 可用'],
        'write_scope': <String>['lib/c.dart'],
      },
    });
    check.that(
      File(
        '$lineRoot${Platform.pathSeparator}tasks${Platform.pathSeparator}A'
        '${Platform.pathSeparator}task.yaml',
      ).existsSync(),
      'task.yaml 落盘',
    );

    // 切片 2：路由申报 + 只读 REST（lines / line / tasks / runs / artifacts）。
    core.ask('routes', M.stationRequest, <String, dynamic>{
      'station_id': kApiRoutesStation,
    });
    final Map<Object?, Map<String, dynamic>> routeResponses = await core
        .waitFor(<Object?>['routes']);
    final Map<String, dynamic> routeFrame =
        routeResponses['routes'] ?? <String, dynamic>{};
    final List<dynamic> declaredRoutes =
        asMap(asMap(asMap(routeFrame['result'])['reply'])['payload'])['routes']
            as List<dynamic>? ??
        <dynamic>[];
    check.check(
      declaredRoutes.length,
      kDeclaredRoutes.length,
      '申报全部 REST 路由（读 + 写）',
    );
    final List<String> declaredMethods = <String>[
      for (final dynamic route in declaredRoutes)
        asString(asMap(route)['method']),
    ]..sort();
    check.check(<String>{...declaredMethods}.toList()..sort(), <String>[
      'DELETE',
      'GET',
      'PATCH',
      'POST',
    ], '申报覆盖 GET / POST / PATCH / DELETE');

    final Map<String, dynamic> restLines = await rest(
      'rest-lines',
      'GET',
      linesPattern,
    );
    check.check(restLines['status'], 200, 'GET /api/production/lines 200');
    check.check(asMap(restLines['json'])['count'], 1, 'REST 产线列表 1 条');
    final Map<String, dynamic> restLine = await rest(
      'rest-line',
      'GET',
      '/api/production/lines/pl_demo',
    );
    check.check(
      asMap(asMap(restLine['json'])['line'])['name'],
      '标准开发流',
      'REST 产线详情',
    );
    final Map<String, dynamic> restTasks = await rest(
      'rest-tasks',
      'GET',
      '/api/production/lines/pl_demo/tasks',
    );
    check.check(asMap(restTasks['json'])['count'], 3, 'REST 任务队列 3 条');
    final Map<String, dynamic> restTask = await rest(
      'rest-task',
      'GET',
      '/api/production/lines/pl_demo/tasks/A',
    );
    check.check(
      asMap(asMap(restTask['json'])['task'])['title'],
      '底座',
      'REST 任务详情',
    );
    final Map<String, dynamic> restRuns = await rest(
      'rest-runs',
      'GET',
      '/api/production/lines/pl_demo/runs',
    );
    check.check(asMap(restRuns['json'])['count'], 0, 'REST 运行台账为空');
    final Map<String, dynamic> restArtifacts = await rest(
      'rest-artifacts',
      'GET',
      '/api/production/lines/pl_demo/artifacts',
    );
    check.check(restArtifacts['status'], 200, 'REST 产物树 200（未配工作空间也给空树）');
    final Map<String, dynamic> restMissing = await rest(
      'rest-missing',
      'GET',
      '/api/production/lines/pl_nope',
    );
    check.check(restMissing['status'], 404, 'REST 缺产线 404');

    // 切片 3：写 REST（建 / 改 / 删产线，建 / 改 / 取消任务，派发与决策的拒绝路径）。
    final Map<String, dynamic> restCreate = await rest(
      'rest-create',
      'POST',
      linesPattern,
      body: <String, Object?>{
        'id': 'pl_rest',
        'name': 'REST 写',
        'workspace_dir': demoWs.path,
        'executor': <String, Object?>{'agent_id': 'agt_demo'},
      },
    );
    markReady('pl_rest');
    check.check(restCreate['status'], 200, 'POST /api/production/lines 200');
    check.check(
      asMap(asMap(restCreate['json'])['line'])['id'],
      'pl_rest',
      'REST 建产线',
    );
    final Map<String, dynamic> restPatchLine = await rest(
      'rest-patch-line',
      'PATCH',
      '/api/production/lines/pl_rest',
      body: <String, Object?>{'name': 'REST 改名', 'status': 'paused'},
    );
    check.check(
      asMap(asMap(restPatchLine['json'])['line'])['name'],
      'REST 改名',
      'PATCH 产线配置',
    );
    final Map<String, dynamic> restTaskCreate = await rest(
      'rest-task-create',
      'POST',
      '/api/production/lines/pl_rest/tasks',
      body: <String, Object?>{
        'id': 'RT1',
        'title': 'REST 任务',
        'status': 'queued',
        'brief': 'REST 建任务',
        'acceptance': <String>['可列出'],
        'write_scope': <String>['lib/a.dart'],
      },
    );
    check.check(
      asMap(asMap(restTaskCreate['json'])['task'])['id'],
      'RT1',
      'POST 建任务',
    );
    final Map<String, dynamic> restTransition = await rest(
      'rest-transition',
      'PATCH',
      '/api/production/lines/pl_rest/tasks/RT1',
      body: <String, Object?>{'to': 'packing'},
    );
    check.check(
      asMap(asMap(restTransition['json'])['task'])['status'],
      'packing',
      'PATCH 改任务状态',
    );
    final Map<String, dynamic> restBadTransition = await rest(
      'rest-bad-transition',
      'PATCH',
      '/api/production/lines/pl_rest/tasks/RT1',
      body: <String, Object?>{'to': 'done'},
    );
    check.check(restBadTransition['status'], 409, '非法迁移 409');
    final Map<String, dynamic> restQuestions = await rest(
      'rest-questions',
      'GET',
      '/api/production/lines/pl_rest/tasks/RT1/questions',
    );
    check.check(restQuestions['status'], 200, 'GET 待答问题 200');
    final Map<String, dynamic> restDecisionEmpty = await rest(
      'rest-decision-empty',
      'POST',
      '/api/production/lines/pl_rest/tasks/RT1/decision',
    );
    check.check(restDecisionEmpty['status'], 400, '决策缺回答 400');
    final Map<String, dynamic> restBadStage = await rest(
      'rest-dispatch-bad-stage',
      'POST',
      '/api/production/lines/pl_rest/tasks/RT1/dispatch',
      body: <String, Object?>{'stage': 'nope'},
    );
    check.check(restBadStage['status'], 400, '非法 stage 400');
    final Map<String, dynamic> restNotDispatchable = await rest(
      'rest-dispatch-bad',
      'POST',
      '/api/production/lines/pl_rest/tasks/RT1/dispatch',
      body: <String, Object?>{'stage': 'run'},
      agent: 'agt',
    );
    check.check(restNotDispatchable['status'], 409, '状态不符派发 409');
    final Map<String, dynamic> restCancel = await rest(
      'rest-cancel',
      'POST',
      '/api/production/lines/pl_rest/tasks/RT1/cancel',
      body: <String, Object?>{'reason': '自检取消'},
    );
    check.check(
      asMap(asMap(restCancel['json'])['task'])['status'],
      'cancelled',
      'REST 取消任务',
    );
    final Map<String, dynamic> restDelete = await rest(
      'rest-delete',
      'DELETE',
      '/api/production/lines/pl_rest',
    );
    check.check(restDelete['json']['deleted'], true, 'DELETE 产线');
    check.that(
      !Directory(
        <String>[
          temp.path,
          'production_lines',
          'production',
          'pl_rest',
        ].join(Platform.pathSeparator),
      ).existsSync(),
      '产线数据目录已删（项目资产不在数据根内）',
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
    check.check(nextPayload['queue'], <String>[
      'B',
      'C',
      'A',
    ], '队列按 priority / created_at / id 排序');

    // 非法迁移与 blocked 理由。
    final Map<String, dynamic> illegal = await call(
      'illegal',
      'production.task.transition',
      <String, Object?>{'line_id': 'pl_demo', 'task_id': 'A', 'to': 'done'},
    );
    check.check(illegal['code'], 'invalid_transition', 'queued → done 非法');
    final Map<String, dynamic> noReason = await call(
      'blocked-no-reason',
      'production.task.transition',
      <String, Object?>{'line_id': 'pl_demo', 'task_id': 'A', 'to': 'blocked'},
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
      check.check(asMap(payloadOf(reply)['task'])['status'], to, 'A → $to');
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
    final File stateFile = File('$lineRoot${Platform.pathSeparator}state.json');
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
    check.check(jsonDecode(stateFile.readAsStringSync())['queue'], <String>[
      'B',
      'C',
    ], 'state.queue 与 task.yaml 对齐（A 已 done）');

    // ── P3 准备阶段：假 docnorm / llm / settings，跑完整窗口 → 落档 ──
    final String ws = '${temp.path}${Platform.pathSeparator}ws';
    Directory(ws).createSync(recursive: true);
    final List<Map<String, dynamic>> workerCalls = <Map<String, dynamic>>[];
    int gitCalls = 0;
    final Map<String, Map<String, Object?>> dedupDb =
        <String, Map<String, Object?>>{};
    int dedupEmbedCalls = 0;
    core.onMethod(M.stationCommand, (Map<String, dynamic> params) {
      final String command = asString(params['command']);
      switch (command) {
        case 'storage.ensure':
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{'ok': true},
          };
        case 'storage.put':
          dedupDb['${asMap(params['arguments'])['collection']}\u0000'
              '${asMap(params['arguments'])['key']}'] = asMap(
            asMap(params['arguments'])['value'],
          );
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{'ok': true},
          };
        case 'storage.get':
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{
              'ok': true,
              'value':
                  dedupDb['${asMap(params['arguments'])['collection']}\u0000'
                      '${asMap(params['arguments'])['key']}'],
            },
          };
        case 'storage.delete':
          dedupDb.remove(
            '${asMap(params['arguments'])['collection']}\u0000'
            '${asMap(params['arguments'])['key']}',
          );
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{'ok': true},
          };
        case 'storage.scan':
          final String prefix = asString(asMap(params['arguments'])['prefix']);
          final String collection = asString(
            asMap(params['arguments'])['collection'],
          );
          final List<Map<String, Object?>> values = <Map<String, Object?>>[
            for (final MapEntry<String, Map<String, Object?>> entry
                in dedupDb.entries)
              if (entry.key.startsWith('$collection\u0000$prefix'))
                <String, Object?>{
                  'key': entry.key.substring(collection.length + 1),
                  'value': entry.value,
                },
          ];
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{
              'ok': true,
              'values': values,
              'has_more': false,
            },
          };
        case 'storage.query':
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{
              'ok': true,
              'values': <Object?>[],
              'has_more': false,
              'cursor': '',
            },
          };
        case 'storage.tx':
          for (final Object? raw
              in (asMap(params['arguments'])['ops'] as List<dynamic>? ??
                  const <dynamic>[])) {
            final Map<String, dynamic> op = asMap(raw);
            final String key = '${op['collection']}\u0000${op['key']}';
            if (asString(op['op']) == 'delete') {
              dedupDb.remove(key);
            } else {
              dedupDb[key] = asMap(op['value']);
            }
          }
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{'ok': true},
          };
        case 'settings.list':
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{
              'values': <String, Object?>{
                'dedup_enabled': <String, Object?>{'value': true},
              },
            },
          };
        case 'llm.embed':
          final Object? rawInputs = asMap(params['arguments'])['inputs'];
          final List<String> inputs = <String>[
            if (rawInputs is List)
              for (final Object? item in rawInputs)
                if (item is String) item,
          ];
          if (inputs.isNotEmpty) dedupEmbedCalls += 1;
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{
              'ok': true,
              'model': 'fake-embed',
              'dimensions': 4,
              'vectors': <Object?>[
                for (final String text in inputs)
                  <double>[
                    for (int i = 0; i < 4; i++)
                      (int.parse(
                                fnv1aHex(text).substring(i * 4, i * 4 + 4),
                                radix: 16,
                              ) +
                              1) /
                          65536,
                  ],
              ],
            },
          };
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
          // D6-O：执行期主控的决策回包（自检只验协议面与落盘，不验决策质量）。
          if (text.contains('执行期主控')) {
            return <String, dynamic>{
              'ok': true,
              'payload': <String, dynamic>{
                'json': <String, Object?>{
                  'action': 'stop',
                  'reason': '自检：先停任务',
                  'task_ids': <String>['O1'],
                  'stop_scope': 'task',
                },
                'text': '{}',
                'model': 'fake',
                'usage': <String, Object?>{'prompt': 5, 'completion': 2},
              },
            };
          }
          if (text.contains('需求摘要员')) {
            return <String, dynamic>{
              'ok': true,
              'payload': <String, dynamic>{
                'json': <String, Object?>{
                  'requirement_summary': '会话列表能按项目过滤',
                  'keywords': <String, Object?>{
                    'terms': <String>['会话列表', '项目过滤'],
                    'synonyms': <String>['筛选'],
                    'entities': <String>['Agent'],
                    'files': <String>['lib/ui/agent_list.dart'],
                    'apis': <String>[],
                  },
                  'constraints': <String>['不改数据库'],
                  'attachment_summaries': <Object?>[],
                  'ambiguities': <String>[],
                },
                'text': '{}',
                'model': 'fake',
              },
            };
          }
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
                    'task_type': 'code',
                    'acceptance': <String>['用例全绿'],
                    'write_scope': <String>['lib/ui/agent_list.dart'],
                    'gate': <String, Object?>{
                      'commands': <String>['dart test'],
                    },
                  },
                  <String, Object?>{
                    'id': 'T2',
                    'title': '补测试',
                    'task_type': 'test',
                    'depends_on': <String>['T1'],
                    'acceptance': <String>['新用例覆盖过滤'],
                    'gate': <String, Object?>{
                      'commands': <String>['dart test'],
                    },
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
                  // P8：预算按累计 token 判定（P4 的产线默认不设上限）。
                  'tokens': <String, Object?>{'prompt': 5, 'completion': 10},
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
                  'text': gitCalls.isOdd ? '' : ' M lib/ui/agent_list.dart',
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
          return <String, dynamic>{'ok': false, 'error': '假核心不认的站命令：$command'};
      }
    });

    await call('prep-line', 'production.line.create', <String, Object?>{
      'id': 'pl_prep',
      'name': '准备阶段',
      'workspace_dir': ws,
      // D7 起角色模型默认留空（由用户在模型池自选）；自检用假员工，
      // 这里显式给每个角色一个模型，避免打包 / 执行按 fail-closed 拒绝。
      'roles': <String, Object?>{
        'orchestrator': <String, Object?>{'model_id': 'fake/orchestrator'},
        'packer': <String, Object?>{'model_id': 'fake/packer'},
        'executor': <String, Object?>{'model_id': 'fake/executor'},
        'expert': <String, Object?>{'model_id': 'fake/expert'},
      },
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
        <String>[
          ws,
          'docs',
          'production_lines',
          'pl_prep',
          'recon.md',
        ].join(Platform.pathSeparator),
      ).existsSync(),
      'recon.md 落项目资产',
    );

    await call(
      'prep-close',
      'production.prepare.window.close',
      <String, Object?>{'line_id': 'pl_prep'},
    );
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
      await call(
        'prep-finalize',
        'production.prepare.finalize',
        <String, Object?>{'line_id': 'pl_prep', 'task_id': 'T_prep'},
      ),
    );
    check.check(asMap(finalized['task'])['status'], 'scoped', '准备任务落档后 scoped');
    check.check(
      (finalized['created_tasks'] as List<dynamic>).length,
      2,
      '拆出 2 个 queued 任务',
    );
    check.that(
      File(
        <String>[
          ws,
          'docs',
          'production_lines',
          'pl_prep',
          'plan.md',
        ].join(Platform.pathSeparator),
      ).existsSync(),
      'plan.md 落项目资产',
    );

    // ── P4 执行阶段：假员工 + 假本机命令，打包 → 执行 → 门控 → done ──
    markReady('pl_prep');
    final Map<String, dynamic> packed = payloadOf(
      await call(
        'p4-pack',
        'production.task.pack',
        <String, Object?>{'line_id': 'pl_prep', 'task_id': 'T1'},
        agent: 'agt',
      ),
    );
    check.check(packed['status'], 'packed', 'P4 打包 → packed');
    check.check(asMap(packed['task'])['status'], 'packed', 'T1 状态 = packed');
    check.that(
      File(
        <String>[
          temp.path,
          'production_lines',
          'production',
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
    check.check(workerCalls.length, 1, '打包调用一次员工');
    check.check(workerCalls.first['role'], 'packer', '打包角色 = packer');
    check.that(
      (workerCalls.first['tools'] as List<dynamic>).contains('read') &&
          !(workerCalls.first['tools'] as List<dynamic>).contains('write'),
      '打包工具只读（无 write）',
    );

    final Map<String, dynamic> executed = payloadOf(
      await call('p4-run', 'production.task.run', <String, Object?>{
        'line_id': 'pl_prep',
        'task_id': 'T1',
      }, agent: 'agt'),
    );
    check.check(executed['status'], 'done', 'P4 门控通过 → done');
    check.check(asMap(executed['task'])['status'], 'done', 'T1 状态 = done');
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
        'brief': '身份校验',
        'acceptance': <String>['能被拒绝'],
        'write_scope': <String>['lib/x.dart'],
      },
    });
    final Map<String, dynamic> missingAgent = await call(
      'p4-no-agent',
      'production.task.pack',
      <String, Object?>{'line_id': 'pl_prep', 'task_id': 'T3'},
    );
    check.check(
      missingAgent['code'],
      'executor_required',
      '产线无执行身份且无调用方 agent ⇒ fail-closed（不猜）',
    );

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
    check.check(
      asMap(collected.first)['name'],
      kAskExpertTool,
      '贡献的是 ask_expert',
    );

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
        // D7 起角色模型默认留空；自检的假员工仍要显式模型才过 fail-closed。
        'orchestrator': <String, Object?>{'model_id': 'fake/orchestrator'},
        'packer': <String, Object?>{'model_id': 'fake/packer'},
        'executor': <String, Object?>{'model_id': 'fake/executor'},
        'expert': <String, Object?>{
          'enabled': true,
          'model_id': 'lfm3',
          'tools': <String>['read', 'grep'],
          'max_per_task': 2,
        },
      },
    });
    markReady('pl_expert');
    await call('p5-task', 'production.task.create', <String, Object?>{
      'line_id': 'pl_expert',
      'task': <String, Object?>{
        'id': 'E1',
        'title': '问专家',
        'status': 'queued',
        'brief': '问专家 X',
        'acceptance': <String>['拿到结论'],
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
    check.check(expertOver['code'], 'expert_limit_exceeded', '超限拒绝（2/2）');
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
    check.check(expertNested['code'], 'expert_not_allowed', '专家不能再召专家');

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
    markReady('pl_evil');
    await call('p5-evil-task', 'production.task.create', <String, Object?>{
      'line_id': 'pl_evil',
      'task': <String, Object?>{
        'id': 'E2',
        'title': '越界',
        'status': 'queued',
        'brief': '越界专家',
        'acceptance': <String>['被拒绝'],
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
    check.check(expertEvil['code'], 'expert_tools_invalid', '专家工具表不许有 write');

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
    File(<String>[auditRoot, 'lib', 'dup_a.txt'].join(Platform.pathSeparator))
        .writeAsStringSync(duplicateBody);
    File(<String>[auditRoot, 'lib', 'dup_b.txt'].join(Platform.pathSeparator))
        .writeAsStringSync(duplicateBody);
    File(<String>[auditRoot, 'lib', 'big.txt'].join(Platform.pathSeparator))
        .writeAsStringSync('y' * 300000);
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
    final Map<String, dynamic> redundancy = asMap(auditReport['redundancy']);
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
    final Map<String, dynamic> auditCached = payloadOf(
      await call('audit-cached', 'production.audit.run', <String, Object?>{
        'line_id': 'pl_audit',
        'write': false,
      }),
    );
    check.check(auditCached['cached'], true, '整理报告命中落盘缓存');
    check.check(auditCached['stale'], false, '无变化时缓存不标 stale');

    final String todoBefore = todoFile.readAsStringSync();
    final Map<String, dynamic> auditWritten = payloadOf(
      await call('audit-run', 'production.audit.run', <String, Object?>{
        'line_id': 'pl_audit',
        // 第一次 write=false 已完成并落缓存；显式 refresh 才重扫并写 audit.md。
        'refresh': true,
      }),
    );
    check.check(auditWritten['written'], true, '默认写 audit.md');
    check.that(auditAsset.existsSync(), 'audit.md 落项目资产');
    check.check(
      auditAsset.readAsStringSync().contains('## TODO 台账'),
      true,
      'audit.md 含 TODO 台账',
    );
    check.check(todoFile.readAsStringSync(), todoBefore, '审计不改工作空间文件（只读）');

    // ── P8 并行与预算：写域交叠拒绝并行 / 预算到点软停 ──
    await call('p8-line', 'production.line.create', <String, Object?>{
      'id': 'pl_par',
      'name': '并行产线',
      'workspace_dir': ws,
      'limits': <String, Object?>{'max_parallel_tasks': 2},
    });
    markReady('pl_par');
    const Map<String, String> parallelScopes = <String, String>{
      'R1': 'lib/a',
      // 与 R1 目录交叠（lib/a/b.dart 落在 lib/a 下）⇒ 不允许并行。
      'R2': 'lib/a/b.dart',
      'R3': 'lib/b',
    };
    for (final MapEntry<String, String> entry in parallelScopes.entries) {
      await call(
        'p8-task-${entry.key}',
        'production.task.create',
        <String, Object?>{
          'line_id': 'pl_par',
          'task': <String, Object?>{
            'id': entry.key,
            'title': '并行 ${entry.key}',
            'status': 'queued',
            'brief': '并行 ${entry.key}',
            'acceptance': <String>['可派发'],
            'write_scope': <String>[entry.value],
          },
        },
      );
    }
    final Map<String, dynamic> planned = payloadOf(
      await call('p8-dispatch', 'production.queue.dispatch', <String, Object?>{
        'line_id': 'pl_par',
      }),
    );
    check.check(planned['batch_ids'], <String>['R1', 'R3'], '写域不相交的两个任务可并行');
    check.check(planned['slots_free'], 2, '并行槽位读数（派发前）');
    final Map<String, dynamic> overlapSkip =
        (planned['skipped'] as List<dynamic>)
            .map((dynamic item) => asMap(item))
            .firstWhere((Map<String, dynamic> item) => item['id'] == 'R2');
    check.check(overlapSkip['reason'], 'write_scope_overlap', '写域交叠拒绝并行');
    check.check(overlapSkip['with_task'], 'R1', '交叠对象可见');
    final Map<String, dynamic> limited = payloadOf(
      await call(
        'p8-dispatch-limit',
        'production.queue.dispatch',
        <String, Object?>{'line_id': 'pl_par', 'limit': 1},
      ),
    );
    check.check(limited['batch_ids'], <String>['R1'], 'limit 截断批次');

    await call('p8-budget-line', 'production.line.create', <String, Object?>{
      'id': 'pl_budget',
      'name': '预算产线',
      'workspace_dir': ws,
      'limits': <String, Object?>{'max_tokens_per_task': 10},
      'roles': <String, Object?>{
        'orchestrator': <String, Object?>{'model_id': 'fake/orchestrator'},
        'packer': <String, Object?>{'model_id': 'fake/packer'},
        'executor': <String, Object?>{'model_id': 'fake/executor'},
        'expert': <String, Object?>{'model_id': 'fake/expert'},
      },
    });
    markReady('pl_budget');
    await call('p8-budget-task', 'production.task.create', <String, Object?>{
      'line_id': 'pl_budget',
      'task': <String, Object?>{
        'id': 'B1',
        'title': '预算到点',
        'status': 'queued',
        'brief': '预算到点',
        'acceptance': <String>['软停'],
        'write_scope': <String>['lib/a.dart'],
      },
    });
    final Map<String, dynamic> budgetPack = payloadOf(
      await call('p8-budget-pack', 'production.task.pack', <String, Object?>{
        'line_id': 'pl_budget',
        'task_id': 'B1',
      }, agent: 'agt'),
    );
    check.check(
      budgetPack['status'],
      'budget_exceeded',
      '预算到点 → 软停（不进 packed）',
    );
    check.check(
      asMap(budgetPack['task'])['status'],
      'blocked',
      '软停后任务 blocked',
    );
    check.check(asMap(budgetPack['budget'])['exceeded'], true, '预算报告可见超限');
    final Map<String, dynamic> budgetReport = payloadOf(
      await call('p8-budget', 'production.task.budget', <String, Object?>{
        'line_id': 'pl_budget',
        'task_id': 'B1',
      }),
    );
    check.check(budgetReport['exceeded'], true, 'production.task.budget 报告超限');
    final Map<String, dynamic> budgetAgain = await call(
      'p8-budget-again',
      'production.task.pack',
      <String, Object?>{'line_id': 'pl_budget', 'task_id': 'B1'},
      agent: 'agt',
    );
    check.check(budgetAgain['code'], 'execute_state', '软停后不静默继续（blocked 不再打包）');

    // ── D6-O 主控决策循环：一次 tick（stop）+ 游标 + 台账 ──
    await call('orch-line', 'production.line.create', <String, Object?>{
      'id': 'pl_orch',
      'name': '主控产线',
      'workspace_dir': ws,
      'roles': <String, Object?>{
        'orchestrator': <String, Object?>{'model_id': 'fake/orchestrator'},
        'packer': <String, Object?>{'model_id': 'fake/packer'},
        'executor': <String, Object?>{'model_id': 'fake/executor'},
      },
    });
    markReady('pl_orch');
    await call('orch-task', 'production.task.create', <String, Object?>{
      'line_id': 'pl_orch',
      'task': <String, Object?>{
        'id': 'O1',
        'title': '主控停止',
        'status': 'queued',
        'brief': '主控停止',
        'acceptance': <String>['被停止'],
        'write_scope': <String>['lib/a.dart'],
      },
    });
    final Map<String, dynamic> orchTick = payloadOf(
      await call('orch-tick', 'production.orchestrator.tick', <String, Object?>{
        'line_id': 'pl_orch',
      }),
    );
    check.check(orchTick['status'], 'applied', '主控 tick 落盘');
    check.check(orchTick['action'], 'stop', '主控按回包执行 stop');
    final Map<String, dynamic> orchTask = payloadOf(
      await call('orch-task-get', 'production.task.get', <String, Object?>{
        'line_id': 'pl_orch',
        'task_id': 'O1',
      }),
    );
    check.check(
      asMap(orchTask['task'])['status'],
      'blocked',
      '主控停止后任务 blocked',
    );
    check.check(
      asMap(orchTask['task'])['blocked_reason'],
      'orchestrator_stop',
      '停止原因可读（可恢复）',
    );
    final Map<String, dynamic> orchStatus = payloadOf(
      await call(
        'orch-status',
        'production.orchestrator.status',
        <String, Object?>{'line_id': 'pl_orch'},
      ),
    );
    check.check(
      asMap(orchStatus['state'])['last_action'],
      'stop',
      '主控游标写 last_action',
    );
    final Map<String, dynamic> orchRuns = payloadOf(
      await call('orch-runs', 'production.run.list', <String, Object?>{
        'line_id': 'pl_orch',
      }),
    );
    check.check(
      (orchRuns['runs'] as List<dynamic>).any(
        (dynamic run) => asMap(run)['role'] == 'orchestrator',
      ),
      true,
      '主控决策落 runs 台账',
    );
    // ── P6+ 逻辑去重：首轮建基线，无变更二次 0 次 embedding ──
    final String dedupWs = '${temp.path}${Platform.pathSeparator}dedup_ws';
    Directory('$dedupWs${Platform.pathSeparator}lib')
        .createSync(recursive: true);
    File('$dedupWs${Platform.pathSeparator}lib${Platform.pathSeparator}a.dart')
        .writeAsStringSync('''
void alpha() {
  final values = <int>[1, 2, 3];
  for (final value in values) {
    print(value);
  }
}
''');
    Process.runSync('git', <String>[
      'init',
      '--quiet',
    ], workingDirectory: dedupWs);
    Process.runSync('git', <String>['add', '-A'], workingDirectory: dedupWs);
    Process.runSync('git', <String>[
      '-c',
      'user.name=t',
      '-c',
      'user.email=t@t',
      'commit',
      '--quiet',
      '--no-gpg-sign',
      '-m',
      'init',
    ], workingDirectory: dedupWs);
    ProductionStore(dataRoot: temp.path).createLine(<String, Object?>{
      'id': 'pl_dedup',
      'name': '逻辑去重',
      'workspace_dir': dedupWs,
    });
    Future<Map<String, dynamic>> runDedup() async {
      Map<String, dynamic> last = <String, dynamic>{};
      for (int i = 0; i < 10; i++) {
        final Map<String, dynamic> reply = await call(
          'dedup-run-$i',
          'production.dedup.run',
          <String, Object?>{'line_id': 'pl_dedup'},
        );
        last = payloadOf(reply);
        if (reply['error'] != null || last['done'] == true) break;
      }
      return last;
    }

    final Map<String, dynamic> dedupFirst = await runDedup();
    check.check(dedupFirst['done'], true, '逻辑去重首轮完成（全量基线）');
    final int dedupCalls = dedupEmbedCalls;
    check.check(dedupCalls > 0, true, '首轮确实请求过 embedding');
    final Map<String, dynamic> dedupSecond = await runDedup();
    check.check(dedupSecond['done'], true, '逻辑去重二次完成');
    check.check(dedupEmbedCalls, dedupCalls, '无变更二次运行 embedding 请求数为 0');
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
