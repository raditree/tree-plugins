import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'agent/compaction_service.dart';
import 'agent/question_store.dart';
import 'compat/protocol_types.dart';
import 'agent_config.dart';
import 'agent_store.dart';
import 'conversation_store.dart';
import 'model_catalog.dart';
import 'runtime/agent_runtime.dart';
import 'workspace/workspace_io.dart';
import 'settings/prompt_store.dart';
import 'spec/spec_service.dart';
import 'session_store.dart';
import 'settings/domain_settings.dart';
import 'settings/ssh_config.dart';
import 'store/records.dart';
import 'store/tree_paths.dart';
import 'teammates.dart';
import 'tool/question_channel.dart';
import 'tool/todo_store.dart';
import 'tool/tool_run_registry.dart';
import 'paths.dart';
import 'subagent_store.dart';
import 'team/team_repair.dart';

/// A2 已搬的只读路由（`G-1 对照表` 的编号见注释）。
const String todosPattern = '/api/agents/{agentId}/todos'; // agent 定义 #7
const String subagentsPattern = '/api/agents/{agentId}/subagents'; // 子 agent #8
const String subagentTranscriptPattern =
    '/api/agents/{agentId}/subagents/{subagentId}/transcript'; // 子 agent #9
const String agentsPattern = '/api/agents'; // agent 列表 #1
const String agentDetailPattern = '/api/agents/{agentId}'; // agent 详情 #3
const String sessionsPattern =
    '/api/agents/{agentId}/sessions'; // 会话列表 #3（会话/历史组）
const String sessionDetailPattern =
    '/api/agents/{agentId}/sessions/{sessionId}'; // 会话详情 #5（会话/历史组）
const String sessionSpecsPattern =
    '/api/agents/{agentId}/sessions/{sessionId}/specs'; // 会话已选规范
const String questionsPattern = '/api/questions'; // 提问列表
const String questionAnswerPattern =
    '/api/questions/{qid}/answer'; // 提问作答
const String modelsPattern = '/api/models'; // 模型池 #14
const String conversationsPattern =
    '/api/conversations/{agentId}'; // 会话历史 #1（会话/历史组）
const String teammatesPattern =
    '/api/agents/{agentId}/teammates'; // 团队名册 #10（团队组）
const String agentModelsInfoPattern =
    '/api/agents/{agentId}/models-info'; // agent 定义 #6
const String messagesPattern =
    '/api/agents/{agentId}/messages'; // C-08 新增：发消息
const String cancelPattern =
    '/api/agents/{agentId}/cancel'; // C-08 新增：停止
const String modelPattern = '/api/models/{modelId}'; // 模型池 #16（PATCH/DELETE）
const String tokenRatePattern =
    '/api/settings/token-rate'; // token 节奏 #1/#2
const String teammatePattern =
    '/api/agents/{leaderId}/teammate/{memberId}'; // 团队写 #1
const String teammateMessagePattern =
    '/api/agents/{leaderId}/teammate/{memberId}/message'; // 团队写 #2
const String teammateLogPattern =
    '/api/agents/{leaderId}/teammate/{memberId}/log'; // 团队读 #3
const String agentCompactPattern = '/api/agents/{agentId}/compact'; // 维护 #2
const String agentResetPattern = '/api/agents/{agentId}/reset'; // 维护 #1
const String sshReconnectPattern =
    '/api/agents/{agentId}/ssh/reconnect'; // 维护 #3
const String agentActivatePattern =
    '/api/agents/{agentId}/activate'; // 执行器激活（非 G-1：终端开前真建连）
const String specsPattern = '/api/agents/{agentId}/specs'; // spec 列表
const String specDetailPattern = '/api/agents/{agentId}/specs/{specId}'; // spec 详情
const String toolsRunningPattern = '/api/tools/running'; // 运行监督 #1
const String toolsRunningClosePattern =
    '/api/tools/running/{handle}/close'; // 运行监督 #2

/// 从委派信封取 JSON body：内联 `body`，或核心因 chunked/大体积落盘的
/// `body_path`（同机路径，核心已校验）——两者都支持，否则 chunked 写路由
/// 会被当成空 body。
Map<String, dynamic> _bodyOf(Map<String, dynamic> envelope) {
  Object? raw = envelope['body'];
  if ((raw == null || (raw is String && raw.trim().isEmpty))) {
    final String bodyPath = (envelope['body_path'] ?? '').toString().trim();
    if (bodyPath.isNotEmpty) {
      try {
        raw = File(bodyPath).readAsStringSync();
      } catch (error) {
        throw FormatException('读取 body_path 失败：$error');
      }
    }
  }
  if (raw is Map) {
    return raw.map(
      (Object? key, Object? value) => MapEntry(key.toString(), value),
    );
  }
  if (raw is String && raw.trim().isNotEmpty) {
    final Object? decoded = jsonDecode(raw);
    if (decoded is Map) {
      return decoded.map(
        (Object? key, Object? value) => MapEntry(key.toString(), value),
      );
    }
    throw const FormatException('请求体不是 JSON 对象');
  }
  return <String, dynamic>{};
}

/// 处理一次 `api/delegate`（核心 → 插件）。
///
/// 信封字段（固定，缺任何一个都视为契约不完整）：`method / path / params / query /
/// headers / scope / workspace_dir / data_dir / agent_id / team_id / request_id`，
/// 小 JSON 带 `body`、大体积带 `body_path`。
///
/// 回包固定为 `{status, headers?, body? | result_path?}`，**body 是字符串**（核心按
/// Content-Type 原样写回 HTTP）。未实现的路由回 501 + 可读原因——委派语义里
/// 404 表示"核心没有这个接口"，而这里是"插件还没搬"。
Future<Map<String, dynamic>> handleApiDelegate(
  Map<String, dynamic> envelope, {
  AgentRuntime Function(String dataDir)? runtimeFor,
}) async {
  try {
    return await _dispatchDelegate(envelope, runtimeFor);
  } catch (error) {
    // 与核心 `_dispatch` 的兜底同形：未捕获异常 ⇒ 500 + 可读原因。
    return _jsonReply(500, <String, dynamic>{
      'detail': '核心进程内部错误：$error',
    });
  }
}

Future<Map<String, dynamic>> _dispatchDelegate(
  Map<String, dynamic> envelope,
  AgentRuntime Function(String dataDir)? runtimeFor,
) async {
  final String method = _str(envelope['method']).toUpperCase();
  final String path = _str(envelope['path']);
  final String dataDir = _str(envelope['data_dir']);
  final Map<String, dynamic> params = _map(envelope['params']);
  final Map<String, dynamic> query = _map(envelope['query']);
  if (dataDir.isEmpty) {
    return _jsonReply(500, <String, dynamic>{
      'detail': '委派信封缺少 data_dir（核心契约不完整）',
    });
  }
  final AgentDataPaths paths = AgentDataPaths(dataDir);

  // ── 会话写接口（创建 / 改名 / 删除 / 已选规范）────────────────────
  if (method == 'POST' && _matches(sessionsPattern, path)) {
    final String agentId = _str(params['agentId']);
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    if (runtime.store.agent(agentId) == null) {
      return _jsonReply(404, <String, dynamic>{'detail': 'agent 不存在'});
    }
    final Map<String, dynamic> body = _bodyOf(envelope);
    final CoreSession? session = runtime.store.createSession(
      agentId,
      title: body['title'] as String? ?? '',
      sessionId: body['session_id'] as String?,
    );
    if (session == null) {
      return _jsonReply(404, <String, dynamic>{'detail': 'agent 不存在'});
    }
    return _jsonReply(200, <String, dynamic>{
      'success': true,
      'session': session.toApiJson(),
    });
  }
  if (method == 'PATCH' && _matches(sessionDetailPattern, path)) {
    final String agentId = _str(params['agentId']);
    final String sessionId = _str(params['sessionId']);
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    final bool renamed = runtime.store.renameSession(
      agentId,
      sessionId,
      _bodyOf(envelope)['title'] as String? ?? '',
    );
    if (!renamed) {
      return _jsonReply(404, <String, dynamic>{'detail': '会话不存在'});
    }
    return _jsonReply(200, <String, dynamic>{'success': true});
  }
  if (method == 'DELETE' && _matches(sessionDetailPattern, path)) {
    final String agentId = _str(params['agentId']);
    final String sessionId = _str(params['sessionId']);
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    runtime.registry.forgetSession(agentId, sessionId);
    if (!runtime.store.deleteSession(agentId, sessionId)) {
      return _jsonReply(404, <String, dynamic>{'detail': '会话不存在'});
    }
    return _jsonReply(200, <String, dynamic>{'success': true});
  }
  if (method == 'POST' && _matches(sessionSpecsPattern, path)) {
    final String agentId = _str(params['agentId']);
    final String sessionId = _str(params['sessionId']);
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    if (runtime.store.session(agentId, sessionId) == null) {
      return _jsonReply(404, <String, dynamic>{'detail': '会话不存在'});
    }
    final List<String> specIds = <String>[
      for (final Object? item
          in (_bodyOf(envelope)['spec_ids'] as List<dynamic>? ??
              const <dynamic>[]))
        '$item',
    ];
    runtime.store.setSelectedSpecs(agentId, sessionId, specIds);
    return _jsonReply(200, <String, dynamic>{
      'success': true,
      'selected_spec_ids': specIds,
    });
  }

  // ── 会话清空（DELETE /api/conversations/{agentId}）────────────────
  if (method == 'DELETE' && _matches(conversationsPattern, path)) {
    final String agentId = _str(params['agentId']);
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    final int deleted = runtime.store.clearMessages(
      agentId,
      sessionId: _queryString(query, 'session_id'),
    );
    return _jsonReply(200, <String, dynamic>{
      'success': true,
      'deleted': deleted,
    });
  }

  // ── 提问列表 / 作答 ──────────────────────────────────────────────
  if (method == 'GET' && _matches(questionsPattern, path)) {
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    final List<QuestionRecord> records = runtime.questionStore.list(
      agentId: _queryString(query, 'agent_id'),
      sessionId: _queryString(query, 'session_id'),
    );
    final String status = _queryString(query, 'status');
    final List<QuestionRecord> filtered = status.isEmpty
        ? records
        : records
              .where((QuestionRecord r) => r.status == status)
              .toList();
    filtered.sort(
      (QuestionRecord a, QuestionRecord b) =>
          b.createdAt.compareTo(a.createdAt),
    );
    return _jsonReply(200, <String, dynamic>{
      'questions': <Map<String, dynamic>>[
        for (final QuestionRecord record in filtered) record.toApiJson(),
      ],
      'total': filtered.length,
    });
  }
  if (method == 'POST' && _matches(questionAnswerPattern, path)) {
    final String qid = _str(params['qid']);
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    final Map<String, dynamic> body = _bodyOf(envelope);
    final Object? rawAnswers = body['answers'];
    final List<String> answers = rawAnswers is List
        ? rawAnswers.map((Object? e) => e?.toString() ?? '').toList()
        : <String>[(body['answer'] ?? '').toString()];
    final QuestionRecord? record = runtime.questionStore.byId(qid);
    if (record == null || !record.isPending) {
      return _jsonReply(404, <String, dynamic>{
        'detail': '没有等待回答的问题',
      });
    }
    if (!runtime.questions.answer(qid, answers)) {
      return _jsonReply(400, <String, dynamic>{
        'detail': '没有等待回答的问题',
      });
    }
    return _jsonReply(200, <String, dynamic>{
      'success': true,
      'qid': qid,
      'status': record.status,
      'answers': record.answers,
    });
  }

  // ── 团队写接口（成员模型分配 / 直接发消息 / 活动日志）──────────────
  if (method == 'PATCH' && _matches(teammatePattern, path)) {
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    final Map<String, dynamic> result = runtime.teamService.assignModel(
      topId: _str(params['leaderId']),
      memberId: _str(params['memberId']),
      body: _bodyOf(envelope),
    );
    final Object? error = result['error'];
    if (error != null) {
      final String message = error.toString();
      return _jsonReply(
        message.startsWith('成员不存在') ? 404 : 400,
        <String, dynamic>{'detail': message},
      );
    }
    return _jsonReply(200, result);
  }
  if (method == 'POST' && _matches(teammateMessagePattern, path)) {
    final String content = (_bodyOf(envelope)['content'] ?? '').toString();
    if (content.trim().isEmpty) {
      return _jsonReply(200, <String, dynamic>{
        'success': false,
        'error': '缺少 content',
      });
    }
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    final String sessionId =
        (_bodyOf(envelope)['session_id'] ?? '').toString().trim();
    final Map<String, dynamic> result = await runtime.messageDispatcher
        .sendFromUser(
          targetId: _str(params['memberId']),
          content: content,
          sessionId: sessionId.isEmpty ? 'session_default' : sessionId,
        );
    return _jsonReply(200, result);
  }
  if (method == 'GET' && _matches(teammateLogPattern, path)) {
    final int lines =
        int.tryParse(_queryString(query, 'lines')) ?? 60;
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    final Map<String, dynamic> read = await runtime.messageDispatcher
        .readActivityLog(_str(params['memberId']), lines: lines);
    return _jsonReply(200, <String, dynamic>{
      'success': read['success'] ?? true,
      'log': read['log'] ?? '',
      'path': read['path'] ?? '',
    });
  }

  // ── 重置工作空间提示词 / Spec（POST /api/agents/{agentId}/reset）──
  if (method == 'POST' && _matches(agentResetPattern, path)) {
    final String agentId = _str(params['agentId']);
    if (AgentRuntime.forDataDir(paths.root).store.agent(agentId) == null) {
      return _jsonReply(404, <String, dynamic>{'detail': 'agent 不存在'});
    }
    final String target =
        (_bodyOf(envelope)['target'] ?? 'all').toString().toLowerCase();
    if (target != 'system_prompt' && target != 'spec' && target != 'all') {
      return _jsonReply(400, <String, dynamic>{
        'detail': 'target 只能是 system_prompt / spec / all',
      });
    }
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    final WorkspaceIO? io = await runtime.workspaceIoFor(agentId, '');
    if (io == null) {
      return _jsonReply(400, <String, dynamic>{
        'detail': '工作空间不可用（未接线 / SSH 配置不完整），无法重置',
      });
    }
    final Map<String, dynamic> result = <String, dynamic>{'success': true};
    if (target == 'system_prompt' || target == 'all') {
      final SystemPromptStore prompts = SystemPromptStore(
        ioFor: (String agent) => runtime.workspaceIoFor(agent, ''),
      );
      final PromptResetResult reset = await prompts.reset(agentId, io);
      await prompts.refresh(agentId);
      result['system_prompt'] = reset.toJson();
    }
    if (target == 'spec' || target == 'all') {
      result['spec'] = await runtime.specService.reset(io);
      await runtime.specService.refreshIndex(agentId, io);
    }
    return _jsonReply(200, result);
  }

  // ── SSH 链路显式重连（POST /api/agents/{agentId}/ssh/reconnect）────
  if (method == 'POST' && _matches(sshReconnectPattern, path)) {
    final String agentId = _str(params['agentId']);
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    final CoreAgent? agent = runtime.store.agent(agentId);
    if (agent == null) {
      return _jsonReply(404, <String, dynamic>{'detail': 'agent 不存在：$agentId'});
    }
    if (agent.sshConfig == null) {
      return _jsonReply(400, <String, dynamic>{
        'detail': '该 agent 未使用 SSH（本地工作空间），没有可重连的远端链路',
      });
    }
    try {
      final Map<String, dynamic> result = await runtime.reconnectSsh(agentId);
      return _jsonReply(200, <String, dynamic>{
        'ok': true,
        'agent_id': agentId,
        'stale': result['stale'] ?? false,
      });
    } catch (error) {
      final String message = error.toString();
      final int status = message.contains('不是 SSH') ? 400 : 500;
      return _jsonReply(status, <String, dynamic>{'detail': message});
    }
  }

  // ── 激活 agent 执行器（POST /api/agents/{agentId}/activate）──────────
  //
  // 与自建执行站 `agent_executor` 的 `executor.activate` 同一实现：
  // local 只检查设备与工作空间；ssh 真建连并登记租约。UI 在开终端前调用它，
  // 免得 SSH 终端因为"还没有租约"而失败。
  if (method == 'POST' && _matches(agentActivatePattern, path)) {
    final String agentId = _str(params['agentId']);
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    if (runtime.store.agent(agentId) == null) {
      return _jsonReply(404, <String, dynamic>{'detail': 'agent 不存在：$agentId'});
    }
    final Map<String, dynamic> result =
        await runtime.activateAgentExecutor(agentId);
    if (result['ok'] != true) {
      // 502：失败发生在下游执行器（SSH 连不上 / 工作空间不可写），不是请求本身不合法。
      return _jsonReply(502, <String, dynamic>{
        'detail': result['error'] ?? '执行器激活失败',
        if (result['mode'] != null) 'mode': result['mode'],
      });
    }
    return _jsonReply(200, result);
  }

  // ── 手动压缩（POST /api/agents/{agentId}/compact）──────────────────
  if (method == 'POST' && _matches(agentCompactPattern, path)) {
    final String agentId = _str(params['agentId']);
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    final String sessionId = (_bodyOf(envelope)['session_id'] ?? '').toString();
    if (runtime.conversation.isRunning(agentId)) {
      return _jsonReply(200, <String, dynamic>{
        'success': true,
        'compressed': false,
        'reason': 'agent_working',
        'context_size': 0,
      });
    }
    final CompactionResult result = await runtime.compaction.compact(
      agentId,
      sessionId,
    );
    if (result.error.isNotEmpty) {
      return _jsonReply(
        result.status,
        <String, dynamic>{'detail': result.error},
      );
    }
    return _jsonReply(200, result.toJson());
  }

  // ── Spec 列表 / 详情（经执行站读工作空间）─────────────────────────
  if (method == 'GET' && _matches(specsPattern, path)) {
    final String agentId = _str(params['agentId']);
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    final String sessionId = _queryString(query, 'session_id').isEmpty
        ? 'session_default'
        : _queryString(query, 'session_id');
    final CoreSession? session = runtime.store.session(agentId, sessionId);
    final List<SpecDocument> documents = await runtime.specService.index(
      agentId,
      await runtime.workspaceIoFor(agentId, sessionId),
    );
    return _jsonReply(200, <String, dynamic>{
      'specs': <Map<String, dynamic>>[
        for (final SpecDocument document in documents) document.toMetaJson(),
      ],
      'selected_spec_ids': session?.selectedSpecIds ?? <String>[],
    });
  }
  if (method == 'GET' && _matches(specDetailPattern, path)) {
    final String agentId = _str(params['agentId']);
    final String specId = _str(params['specId']);
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    final SpecDocument? document = await runtime.specService.detail(
      agentId,
      await runtime.workspaceIoFor(agentId, ''),
      specId,
    );
    if (document == null) {
      return _jsonReply(404, <String, dynamic>{'detail': 'Spec 不存在: $specId'});
    }
    return _jsonReply(200, <String, dynamic>{
      'meta': document.toMetaJson(),
      'content': document.raw,
    });
  }

  // ── 模型池写接口（POST / PATCH / DELETE）──────────────────────────
  if (method == 'POST' && _matches(modelsPattern, path)) {
    final Map<String, dynamic> body = _bodyOf(envelope);
    final String? invalid = DomainSettings.validateNewModel(body);
    if (invalid != null) {
      return _jsonReply(400, <String, dynamic>{'detail': invalid});
    }
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    final CoreModelConfig? model = runtime.settings.createModel(body);
    if (model == null) {
      return _jsonReply(409, <String, dynamic>{
        'detail': '模型已存在：${body['model_id']}',
      });
    }
    await runtime.settingsSink.flush();
    return _jsonReply(200, <String, dynamic>{
      'success': true,
      'model': model.toApiJson(),
    });
  }
  if (method == 'PATCH' && _matches(modelPattern, path)) {
    final String modelId = _str(params['modelId']);
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    final CoreModelConfig? model = runtime.settings.updateModel(
      modelId,
      _bodyOf(envelope),
    );
    if (model == null) {
      return _jsonReply(404, <String, dynamic>{'detail': '模型不存在'});
    }
    await runtime.settingsSink.flush();
    return _jsonReply(200, <String, dynamic>{
      'success': true,
      'model': model.toApiJson(),
    });
  }
  if (method == 'DELETE' && _matches(modelPattern, path)) {
    final String modelId = _str(params['modelId']);
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    if (!runtime.settings.deleteModel(modelId)) {
      return _jsonReply(404, <String, dynamic>{'detail': '模型不存在'});
    }
    await runtime.settingsSink.flush();
    final List<String> bound = <String>[
      for (final AgentRecord record in readAgentRecords(paths))
        if (record.modelId == modelId) record.id,
    ];
    return _jsonReply(200, <String, dynamic>{
      'success': true,
      'bound_agents': bound,
    });
  }

  // ── token 节奏（GET/POST /api/settings/token-rate）──────────────────
  if (method == 'GET' && _matches(tokenRatePattern, path)) {
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    return _jsonReply(200, <String, dynamic>{
      'token_rate': runtime.settings.tokenAcquisitionRate,
      'min': DomainSettings.tokenRateMin,
      'max': DomainSettings.tokenRateMax,
    });
  }
  if (method == 'POST' && _matches(tokenRatePattern, path)) {
    final Map<String, dynamic> body = _bodyOf(envelope);
    final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
    final int requested =
        (body['token_rate'] as num?)?.toInt() ?? DomainSettings.tokenRateMax;
    final int applied = runtime.settings.setTokenAcquisitionRate(requested);
    await runtime.settingsSink.flush();
    return _jsonReply(200, <String, dynamic>{
      'token_rate': applied,
      'min': DomainSettings.tokenRateMin,
      'max': DomainSettings.tokenRateMax,
    });
  }

  // 运行中工具：只读快照（数据源是插件进程内的登记表，重启即清空）。
  if (method == 'GET' && _matches(toolsRunningPattern, path)) {
    return _jsonReply(
      200,
      AgentRuntime.forDataDir(paths.root).toolRuns.snapshot(),
    );
  }

  // 运行中工具：显式关闭（与执行站 tool.close 同一个实现）。
  if (method == 'POST' && _matches(toolsRunningClosePattern, path)) {
    final String handle = _str(params['handle']);
    final ToolCloseOutcome outcome = await AgentRuntime.forDataDir(
      paths.root,
    ).toolRuns.close(handle);
    if (!outcome.closed) {
      return _jsonReply(404, <String, dynamic>{'detail': outcome.note});
    }
    return _jsonReply(200, outcome.toJson());
  }

  // C-08：发消息（写；落库 + 入队生成，不等本轮跑完）。
  if (method == 'POST' && _matches(messagesPattern, path)) {
    final String agentId = _str(params['agentId']);
    final Map<String, dynamic> body = _bodyOf(envelope);
    final String content = _str(body['content']);
    if (content.isEmpty) {
      return _jsonReply(400, <String, dynamic>{
        'detail': 'content 不能为空',
      });
    }
    final Map<String, dynamic>? result = await AgentRuntime.forDataDir(paths.root)
        .sendMessage(
          agentId: agentId,
          content: content,
          sessionId: _str(body['session_id']),
          attachments: body['attachments'] is List<dynamic>
              ? body['attachments'] as List<dynamic>
              : null,
        );
    if (result == null) {
      return _jsonReply(404, <String, dynamic>{
        'detail': '未知 agent：$agentId',
      });
    }
    return _jsonReply(200, result);
  }

  // C-08：停止（写；TOP 级联团队树，成员只停自己）。
  if (method == 'POST' && _matches(cancelPattern, path)) {
    final String agentId = _str(params['agentId']);
    final Map<String, dynamic> body = _bodyOf(envelope);
    final Map<String, dynamic>? summary = AgentRuntime.forDataDir(paths.root)
        .cancel(agentId, sessionId: _str(body['session_id']));
    if (summary == null) {
      return _jsonReply(404, <String, dynamic>{
        'detail': '未知 agent：$agentId',
      });
    }
    return _jsonReply(200, <String, dynamic>{
      'success': true,
      'agent_id': agentId,
      ...summary,
    });
  }

  // 全局只读：agent 列表（22 键 + 预览 + 待处理成员数，按 updatedAt 降序）。
  if (method == 'GET' && _matches(agentsPattern, path)) {
    final List<AgentRecord> records = readAgentRecords(paths)
      ..sort(
        (AgentRecord a, AgentRecord b) =>
            b.updatedAt.compareTo(a.updatedAt),
      );
    final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
    for (final AgentRecord record in records) {
      final TextPreview? preview = lastTextPreview(paths, record.id);
      items.add(
        agentApiJson(
          record,
          lastMessage: preview?.content ?? '',
          lastMessageTime: preview?.timestamp,
          pendingMemberCount: pendingMemberCountOf(records, record),
        ),
      );
    }
    return _jsonReply(200, <String, dynamic>{'agents': items});
  }

  // 创建 agent（契约 §1.1 #2）：必填 name / model_id；团队字段不可在此指定。
  if (method == 'POST' && _matches(agentsPattern, path)) {
    final Map<String, dynamic> body = _bodyOf(envelope);
    final String name = (body['name'] as String? ?? '').trim();
    if (name.isEmpty) {
      return _jsonReply(400, <String, dynamic>{'detail': 'name 不能为空'});
    }
    final String modelId = (body['model_id'] as String? ?? '').trim();
    if (modelId.isEmpty) {
      return _jsonReply(400, <String, dynamic>{'detail': 'model_id 不能为空'});
    }
    final AgentRuntime runtime = _runtimeFor(paths, runtimeFor);
    if (runtime.settings.model(modelId) == null) {
      return _jsonReply(400, <String, dynamic>{'detail': '模型不存在：$modelId'});
    }
    final CoreAgent agent = runtime.store.createAgent(
      name: name,
      systemPrompt: body['system_prompt'] as String? ?? '',
      modelId: modelId,
      teamMemberCount: (body['team_member_count'] as num?)?.toInt() ?? 0,
      maxLevel: TeamLimits.level(body['max_level']),
      maxMembersPerLevel: TeamLimits.members(body['max_members_per_level']),
    );
    // 默认会话由 createAgent 落盘；先排水，保证紧接着的读接口看得见（写路由）。
    await runtime.store.flush();
    return _jsonReply(200, <String, dynamic>{
      'success': true,
      'agent': agent.toApiJson(),
    });
  }

  // 更新 agent（契约 §1.1 #4）：name / team_id / parent_agent_id / level /
  // review_status / role 是禁区；空 body 也会 bump updated_at 并重写 yaml。
  if (method == 'PATCH' && _matches(agentDetailPattern, path)) {
    final String agentId = _str(params['agentId']);
    final Map<String, dynamic> body = _bodyOf(envelope);
    final String modelId = (body['model_id'] as String? ?? '').trim();
    final AgentRuntime runtime = _runtimeFor(paths, runtimeFor);
    if (modelId.isNotEmpty && runtime.settings.model(modelId) == null) {
      return _jsonReply(400, <String, dynamic>{'detail': '模型不存在：$modelId'});
    }
    final CoreAgent? agent = runtime.store.updateAgent(
      agentId,
      systemPrompt: body.containsKey('system_prompt')
          ? (body['system_prompt'] as String? ?? '')
          : null,
      modelId: modelId.isEmpty ? null : modelId,
    );
    if (agent == null) {
      return _jsonReply(404, <String, dynamic>{'detail': 'agent 不存在'});
    }

    bool touched = false;
    bool workspaceDirChanged = false;
    if (body.containsKey('workspace_dir')) {
      final String dir = (body['workspace_dir'] as String? ?? '').trim();
      if (dir.isNotEmpty && !p.isAbsolute(dir)) {
        return _jsonReply(400, <String, dynamic>{
          'detail': 'workspace_dir 必须是绝对路径或空串（空 = 用默认工作空间）',
        });
      }
      agent.workspaceDir = dir;
      touched = true;
      workspaceDirChanged = true;
    }
    if (body.containsKey('ssh')) {
      final Object? raw = body['ssh'];
      if (raw == null) {
        agent.sshConfig = null;
        touched = true;
      } else if (raw is Map) {
        final Map<String, dynamic> sshBody = raw.map(
          (dynamic k, dynamic v) => MapEntry(k.toString(), v),
        );
        final SshConfig? parsed = SshConfig.parse(sshBody);
        if (parsed == null) {
          return _jsonReply(400, <String, dynamic>{'detail': 'ssh.host 不能为空'});
        }
        // 密码/口令按 PATCH 语义：键缺失 = 保留原值，显式空串 = 清空。
        final SshConfig? existing = agent.sshConfig;
        final String password = sshBody.containsKey('password')
            ? parsed.password
            : (existing?.password ?? '');
        final String passphrase = sshBody.containsKey('key_passphrase')
            ? parsed.keyPassphrase
            : (existing?.keyPassphrase ?? '');
        if (password.isEmpty && parsed.keyPath.isEmpty) {
          return _jsonReply(400, <String, dynamic>{
            'detail': 'SSH 需要 password 或 key_path 之一',
          });
        }
        agent.sshConfig = SshConfig(
          host: parsed.host,
          port: parsed.port,
          username: parsed.username,
          password: password,
          keyPath: parsed.keyPath,
          keyPassphrase: passphrase,
          root: parsed.root,
        );
        touched = true;
      } else {
        return _jsonReply(400, <String, dynamic>{
          'detail': 'ssh 必须是对象或 null',
        });
      }
    }
    if (body['clear_model_overrides'] == true) {
      agent.reasoningEffort = '';
      agent.maxSeqlenOverride = 0;
      agent.maxOutputTokens = 0;
      agent.compressThreshold = 0;
      agent.thinkingOverride = null;
      touched = true;
    } else {
      if (body.containsKey('reasoning_effort')) {
        agent.reasoningEffort = (body['reasoning_effort'] as String? ?? '')
            .trim();
        touched = true;
      }
      if (body.containsKey('max_seqlen')) {
        final Object? raw = body['max_seqlen'];
        if (raw == null) {
          agent.maxSeqlenOverride = 0;
        } else {
          final int? parsed = raw is num ? raw.toInt() : int.tryParse('$raw');
          if (parsed == null || parsed <= 0) {
            return _jsonReply(400, <String, dynamic>{
              'detail': 'max_seqlen 必须为正整数，或 null 清除该项覆盖',
            });
          }
          agent.maxSeqlenOverride = parsed;
        }
        touched = true;
      }
      if (body.containsKey('max_output_tokens')) {
        final Object? raw = body['max_output_tokens'];
        if (raw == null) {
          agent.maxOutputTokens = 0;
        } else {
          final int? parsed = raw is num ? raw.toInt() : int.tryParse('$raw');
          if (parsed == null || parsed <= 0) {
            return _jsonReply(400, <String, dynamic>{
              'detail': 'max_output_tokens 必须为正整数，或 null 清除该项覆盖',
            });
          }
          agent.maxOutputTokens = parsed;
        }
        touched = true;
      }
      if (body.containsKey('compress_threshold')) {
        final Object? raw = body['compress_threshold'];
        if (raw == null) {
          agent.compressThreshold = 0;
        } else {
          final double? parsed = raw is num
              ? raw.toDouble()
              : double.tryParse('$raw');
          if (parsed == null || parsed < 0.1 || parsed > 0.95) {
            return _jsonReply(400, <String, dynamic>{
              'detail':
                  'compress_threshold 必须在 0.1~0.95 之间，或 null 清除该项覆盖',
            });
          }
          agent.compressThreshold = parsed;
        }
        touched = true;
      }
      if (body.containsKey('thinking')) {
        final Object? raw = body['thinking'];
        if (raw == null) {
          agent.thinkingOverride = null;
        } else if (raw is bool) {
          agent.thinkingOverride = raw;
        } else {
          return _jsonReply(400, <String, dynamic>{
            'detail': 'thinking 必须是 true / false，或 null 清除该项覆盖',
          });
        }
        touched = true;
      }
    }
    if (touched) {
      agent.updatedAt = DateTime.now().millisecondsSinceEpoch;
      runtime.store.putAgent(agent);
    }
    // 目录改动 = 团队共享目录变了：与核心一样把生效目录镜像给成员。
    if (workspaceDirChanged) {
      await syncWorkspaceMirrors(
        runtime.store,
        defaultDirFor: (String id) =>
            TreePaths(paths.root).defaultWorkspaceDir(id),
      );
    }
    await runtime.store.flush();
    final SshConfig? ssh = agent.sshConfig;
    return _jsonReply(200, <String, dynamic>{
      'success': true,
      'agent': agent.toApiJson(),
      if (ssh != null) 'ssh': _sshApiView(ssh),
    });
  }

  // 删除 agent（契约 §1.1 #5）：两道闸门（有下级未级联 / 正在运行）都不改东西。
  if (method == 'DELETE' && _matches(agentDetailPattern, path)) {
    final String agentId = _str(params['agentId']);
    final AgentRuntime runtime = _runtimeFor(paths, runtimeFor);
    if (runtime.store.agent(agentId) == null) {
      return _jsonReply(404, <String, dynamic>{'detail': 'agent 不存在'});
    }
    // 与核心逐字比较（不 trim）：只有 '1' / 'true' 生效。
    final String cascadeRaw = _firstQueryValue(query, 'cascade');
    final bool cascade = cascadeRaw == '1' || cascadeRaw == 'true';
    final List<CoreAgent> descendants = runtime.teamService.descendants(
      agentId,
    );
    if (descendants.isNotEmpty && !cascade) {
      final String message =
          '该 agent 还有 ${descendants.length} 个下级成员，未指定 cascade';
      return _jsonReply(409, <String, dynamic>{
        'detail': message,
        'error': message,
        'cascade_required': <Map<String, dynamic>>[
          for (final CoreAgent member in descendants)
            <String, dynamic>{
              'member_id': member.id,
              'name': member.name,
              'level': member.level,
              'parent_agent_id': member.parentAgentId,
            },
        ],
        'hint':
            '直接删除会让这些下级变成孤儿（找不到上级，广播与级联停止都够不着）；'
            '确认后带 ?cascade=1 连同下级一并删除，或先用 team 工具逐个移除下级',
      });
    }
    final List<String> ids = <String>[
      agentId,
      if (cascade) ...descendants.map((CoreAgent member) => member.id),
    ];
    // 记下每条的团队归属：删完就取不到了，而计数回填要用。
    final Map<String, String> teamOf = <String, String>{};
    for (final String id in ids) {
      final CoreAgent? agent = runtime.store.agent(id);
      if (agent == null) continue;
      teamOf[id] = _teamOfFor(agent);
    }
    List<String> running() =>
        ids.where(runtime.conversation.isRunning).toList(growable: false);
    if (running().isNotEmpty) {
      return _jsonReply(409, _busyBody(running()));
    }
    // 停：作废排队任务（旧代次出队即丢）+ 收尾在途提问。
    for (final String id in ids) {
      _stopOne(runtime, id);
    }
    // 竞态兜底：恰好在闸门之后接单的排队任务会被这次代次推进作废，但"已过代次
    // 检查、即将登记 token"的窗口仍在；再确认一次（不等待）。
    final List<String> started = running();
    if (started.isNotEmpty) {
      return _jsonReply(409, _busyBody(started));
    }
    await runtime.store.flush();
    int questionsRemoved = 0;
    for (final String id in ids) {
      runtime.questions.cancelForAgent(id);
      questionsRemoved += runtime.questionStore.removeForAgent(id);
      await runtime.questionStore.flush();
    }
    // 叶→根删（父先于子的逆序），避免留下"父没了子还在"的中间态。
    final List<String> removed = <String>[];
    for (final String id in ids.reversed) {
      runtime.registry.forgetAgent(id);
      if (runtime.store.deleteAgent(id)) removed.add(id);
    }
    await runtime.store.flush();
    // 回填存活 TOP 的成员数（与 team 工具"按实际成员数"同一口径）。
    final Set<String> touchedTopIds = <String>{
      for (final String teamId in teamOf.values)
        if (!ids.contains(teamId)) teamId,
    };
    for (final String topId in touchedTopIds) {
      runtime.teamService.syncMemberCount(topId);
    }
    await runtime.store.flush();
    return _jsonReply(200, <String, dynamic>{
      'success': true,
      'removed': removed,
      'cascade': cascade,
      if (questionsRemoved > 0) 'questions_removed': questionsRemoved,
    });
  }

  // 团队名册（成员视图 + 关系 + 覆盖项；未知 agent 不 404）。
  if (method == 'GET' && _matches(teammatesPattern, path)) {
    final String agentId = _str(params['agentId']);
    return _jsonReply(
      200,
      teammatesPayload(paths, readAgentRecords(paths), agentId),
    );
  }

  // 会话历史（分页 + 提问状态叠加）。
  if (method == 'GET' && _matches(conversationsPattern, path)) {
    final String agentId = _str(params['agentId']);
    if (readAgentRecord(paths, agentId) == null) {
      return _jsonReply(404, <String, dynamic>{'detail': 'agent 不存在'});
    }
    final String rawSession = _queryString(query, 'session_id');
    return _jsonReply(
      200,
      conversationPage(
        paths,
        agentId,
        sessionId: rawSession.isEmpty ? 'session_default' : rawSession,
        limit: int.tryParse(_queryString(query, 'limit')) ?? 0,
        before: _queryString(query, 'before').trim(),
        from: int.tryParse(_queryString(query, 'from')),
        at: _queryString(query, 'at').trim(),
      ),
    );
  }

  // 会话列表（读接口，但会像核心一样兜底默认会话）。
  if (method == 'GET' && _matches(sessionsPattern, path)) {
    final String agentId = _str(params['agentId']);
    if (readAgentRecord(paths, agentId) == null) {
      return _jsonReply(404, <String, dynamic>{'detail': 'agent 不存在'});
    }
    final List<SessionRecord> sessions = readSessions(paths, agentId);
    if (!sessions.any((SessionRecord s) => s.sessionId == 'session_default')) {
      sessions.add(ensureDefaultSession(paths, agentId));
      sessions.sort(
        (SessionRecord a, SessionRecord b) =>
            b.updatedAt.compareTo(a.updatedAt),
      );
    }
    return _jsonReply(200, <String, dynamic>{
      'agent_id': agentId,
      'sessions': <Map<String, dynamic>>[
        for (final SessionRecord session in sessions)
          sessionApiJson(
            session,
            messageCount: messageCountOf(
              paths,
              agentId,
              session.sessionId,
            ),
          ),
      ],
    });
  }

  // 会话详情（消息为规范化的 CoreMessage.toJson 形态）。
  if (method == 'GET' && _matches(sessionDetailPattern, path)) {
    final String agentId = _str(params['agentId']);
    final String sessionId = _str(params['sessionId']);
    final SessionRecord? session = findSession(paths, agentId, sessionId);
    if (session == null) {
      return _jsonReply(404, <String, dynamic>{'detail': '会话不存在'});
    }
    return _jsonReply(200, <String, dynamic>{
      'session': sessionApiJson(
        session,
        messageCount: messageCountOf(paths, agentId, sessionId),
      ),
      'messages': readMessages(paths, agentId, sessionId),
    });
  }

  // 单个 agent（含 SSH 非机密视图；不回密钥）。
  if (method == 'GET' && _matches(agentDetailPattern, path)) {
    final String agentId = _str(params['agentId']);
    final AgentRecord? record = readAgentRecord(paths, agentId);
    if (record == null) {
      return _jsonReply(404, <String, dynamic>{'detail': 'agent 不存在'});
    }
    return _jsonReply(200, <String, dynamic>{
      'agent': agentApiJson(
        record,
        lastMessage: '',
        lastMessageTime: null,
        pendingMemberCount: 0,
      ),
      if (record.sshView != null) 'ssh': record.sshView!,
    });
  }

  // 全局只读：模型池（不需要 agent）。
  if (method == 'GET' && _matches(modelsPattern, path)) {
    return _jsonReply(200, <String, dynamic>{'models': readModels(paths)});
  }

  if (method == 'GET' &&
      (_matches(todosPattern, path) ||
          _matches(subagentsPattern, path) ||
          _matches(agentModelsInfoPattern, path))) {
    final String agentId = _str(params['agentId']);
    final String sessionId = _sessionOf(query);
    final AgentConfigView? agent;
    try {
      agent = readAgentConfig(paths, agentId);
    } on ArgumentError {
      // 非法 id（含路径分隔符等）：按"agent 不存在"fail-closed，不回显路径规则。
      return _jsonReply(404, <String, dynamic>{'detail': 'agent 不存在'});
    }
    if (agent == null) {
      return _jsonReply(404, <String, dynamic>{'detail': 'agent 不存在'});
    }
    if (_matches(todosPattern, path)) {
      final List<TodoItem> todos = FileTodoStore(
      TreePaths(paths.root),
    ).read(agentId, sessionId);
      return _jsonReply(200, <String, dynamic>{
        'todos': todos.map((TodoItem todo) => todo.toApiJson()).toList(),
        'session_id': sessionId,
      });
    }
    if (_matches(subagentsPattern, path)) {
      final List<Map<String, dynamic>> roster = readSubagentRoster(
        paths,
        agentId,
        sessionId,
      );
      return _jsonReply(200, <String, dynamic>{
        'agent_id': agentId,
        'session_id': sessionId,
        'total': roster.length,
        'subagents': roster,
      });
    }
    // models-info：agent 三键 + 模型池 + 真正设置过的覆盖项。
    return _jsonReply(200, <String, dynamic>{
      'agent': <String, dynamic>{
        'id': agent.id,
        'model_id': agent.modelId,
        'system_prompt': agent.systemPrompt,
      },
      'models': readModels(paths),
      'overrides': memberOverridesOf(agent),
    });
  }

  // 临时员工 transcript（契约 §1.1 #9）：只读父会话里带 subagent_id 标记的那一段。
  // 先按请求的会话装载名册，再核对记录自己的 (ownerAgentId, sessionId)——
  // 跨会话不保留是硬不变量，对不上回可读 404。
  if (method == 'GET' && _matches(subagentTranscriptPattern, path)) {
    final String agentId = _str(params['agentId']);
    final String subagentId = _str(params['subagentId']);
    if (readAgentRecord(paths, agentId) == null) {
      return _jsonReply(404, <String, dynamic>{'detail': 'agent 不存在'});
    }
    final AgentRuntime runtime = _runtimeFor(paths, runtimeFor);
    final String sessionId = _sessionOf(query);
    runtime.registry.ensureSession(agentId, sessionId);
    final CoreSubagent? record = runtime.registry.handle(subagentId);
    if (record == null) {
      return _jsonReply(404, <String, dynamic>{
        'detail': '临时员工不存在：$subagentId',
      });
    }
    if (record.ownerAgentId != agentId || record.sessionId != sessionId) {
      return _jsonReply(404, <String, dynamic>{
        'detail':
            '临时员工「${record.name}」属于会话 ${record.sessionId}，'
            '不在这个会话（$sessionId）里——跨会话不保留是硬不变量。',
      });
    }
    final List<Map<String, dynamic>> messages = <Map<String, dynamic>>[
      for (final Map<String, dynamic> message
          in readMessages(paths, record.ownerAgentId, sessionId))
        if ('${message['subagent_id'] ?? ''}' == subagentId &&
            '${message['kind']}' != 'subagent_report')
          _withQuestionOverlay(runtime.questionStore, message),
    ];
    messages.sort(
      (Map<String, dynamic> a, Map<String, dynamic> b) =>
          _messageMs(a).compareTo(_messageMs(b)),
    );
    return _jsonReply(200, <String, dynamic>{
      'agent_id': agentId,
      'subagent_id': subagentId,
      'session_id': sessionId,
      'total': messages.length,
      'messages': messages,
    });
  }

  return _jsonReply(501, <String, dynamic>{
    'detail': 'tree.agent 尚未实现该路由：$method $path',
  });
}

/// 路径模板匹配（`{name}` 段匹配任意非空段；其余段逐字相等）。
bool _matches(String pattern, String path) {
  final List<String> want = pattern.split('/');
  final List<String> got = path.split('/');
  if (want.length != got.length) return false;
  for (int i = 0; i < want.length; i++) {
    final String segment = want[i];
    if (segment.length >= 2 &&
        segment.startsWith('{') &&
        segment.endsWith('}')) {
      if (got[i].isEmpty) return false;
      continue;
    }
    if (segment != got[i]) return false;
  }
  return true;
}

Map<String, dynamic> _jsonReply(int status, Map<String, dynamic> body) =>
    <String, dynamic>{
      'status': status,
      'headers': <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
      'body': jsonEncode(body),
    };

/// 会话 id：缺省/空 ⇒ `session_default`（与核心 `TreeStore.defaultSessionId` 同值）。
String _sessionOf(Map<String, dynamic> query) {
  final String raw = _str(query['session_id']);
  return raw.isEmpty ? 'session_default' : raw;
}

/// 查询参数原样取第一个值（不 trim；重复键在信封里是数组）。
String _firstQueryValue(Map<String, dynamic> query, String key) {
  final Object? raw = query[key];
  if (raw is List) return raw.isEmpty ? '' : '${raw.first ?? ''}';
  return '${raw ?? ''}';
}

/// 枚举查询参数取**第一个值**（重复键在信封里是数组；核心取 queryParameters 的首值）。
String _queryString(Map<String, dynamic> query, String key) {
  final Object? raw = query[key];
  if (raw is List) return raw.isEmpty ? '' : _str(raw.first);
  return _str(raw);
}

String _str(Object? value) => (value ?? '').toString().trim();

Map<String, dynamic> _map(Object? value) => value is Map
    ? value.map(
        (Object? key, Object? item) => MapEntry(key.toString(), item),
      )
    : <String, dynamic>{};

/// 运行时解析：默认走进程内按数据根缓存；[runtimeFor] 只给测试注入替身。
AgentRuntime _runtimeFor(
  AgentDataPaths paths,
  AgentRuntime Function(String dataDir)? runtimeFor,
) => (runtimeFor ?? AgentRuntime.forDataDir)(paths.root);

/// agent 的团队归属：成员取 `team_id`，顶层 agent 就是它自己。
String _teamOfFor(CoreAgent agent) => agent.teamId.isEmpty ? agent.id : agent.teamId;

/// 停**单个** agent（不展开团队树）：与核心 `_stopAgentTree(cascade: false)` 同口径。
void _stopOne(AgentRuntime runtime, String id) {
  final bool running = runtime.conversation.cancelAgent(id);
  if (running) return;
  // 没有在途任务也补一条 idle：否则前端/成员窗口的「工作中」标识会一直亮着。
  runtime.hub.broadcast(<String, dynamic>{
    'type': WsOutboundType.agentStatus,
    'data': <String, dynamic>{
      'agent_id': id,
      'status': 'idle',
      'own_running': false,
    },
  });
}

/// "正在运行，不能删"的 409 响应体（与核心 `_busyBody` 逐字一致）。
Map<String, dynamic> _busyBody(List<String> running) => <String, dynamic>{
  'detail': 'agent 正在运行，不能删除',
  'error': 'agent 正在运行，不能删除',
  'running': running,
  'hint':
      '请先停止该 agent（成员可在标题栏按「停止」）并等它变为空闲后再删除；'
      '正在执行的工具无法被抢占（本地执行活着就永不超时），所以这里不会替你等待。',
};

/// SSH 的前端形态：在 `redacted()` 基础上补 `key_path`（绝不含密码/口令）。
Map<String, dynamic> _sshApiView(SshConfig config) => <String, dynamic>{
  ...config.redacted(),
  if (config.keyPath.isNotEmpty) 'key_path': config.keyPath,
};

/// 提问卡片的历史形态：用提问记录（真源）覆盖只追加消息里的旧状态。
Map<String, dynamic> _withQuestionOverlay(
  QuestionStore questions,
  Map<String, dynamic> message,
) {
  final Map<String, dynamic> json = Map<String, dynamic>.of(message);
  if ('${json['kind']}' != 'ask_user_question') return json;
  final QuestionRecord? record = questions.byId('${json['id']}');
  if (record == null) return json;
  json['answered'] = !record.isPending;
  json['answer'] = record.answer;
  json['questions'] = <Map<String, dynamic>>[
    for (final AskedQuestion question in record.questions) question.toJson(),
  ];
  json['answers'] = record.answers;
  if (record.options.isNotEmpty) json['options'] = record.options;
  return json;
}

int _messageMs(Map<String, dynamic> message) =>
    DateTime.tryParse('${message['timestamp']}')?.millisecondsSinceEpoch ?? 0;
