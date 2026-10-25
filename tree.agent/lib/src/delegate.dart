import 'dart:convert';

import 'agent/compaction_service.dart';
import 'agent/question_store.dart';
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
import 'store/records.dart';
import 'store/tree_paths.dart';
import 'teammates.dart';
import 'tool/todo_store.dart';
import 'tool/tool_run_registry.dart';
import 'paths.dart';
import 'subagent_store.dart';

/// A2 已搬的只读路由（`G-1 对照表` 的编号见注释）。
const String todosPattern = '/api/agents/{agentId}/todos'; // agent 定义 #7
const String subagentsPattern = '/api/agents/{agentId}/subagents'; // 子 agent #8
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
const String specsPattern = '/api/agents/{agentId}/specs'; // spec 列表
const String specDetailPattern = '/api/agents/{agentId}/specs/{specId}'; // spec 详情
const String toolsRunningPattern = '/api/tools/running'; // 运行监督 #1
const String toolsRunningClosePattern =
    '/api/tools/running/{handle}/close'; // 运行监督 #2

/// 从委派信封取 JSON body（小体积内联字符串；缺失/空 = 空表）。
///
/// 大体积 `body_path` 目前不用于这两条写端点（核心侧 POST 请求体都很小）。
Map<String, dynamic> _bodyOf(Map<String, dynamic> envelope) {
  final Object? raw = envelope['body'];
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
  Map<String, dynamic> envelope,
) async {
  try {
    return await _dispatchDelegate(envelope);
  } catch (error) {
    // 与核心 `_dispatch` 的兜底同形：未捕获异常 ⇒ 500 + 可读原因。
    return _jsonReply(500, <String, dynamic>{
      'detail': '核心进程内部错误：$error',
    });
  }
}

Future<Map<String, dynamic>> _dispatchDelegate(
  Map<String, dynamic> envelope,
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
    if (runtime.store.agent(agentId) == null) {
      return _jsonReply(404, <String, dynamic>{'detail': 'agent 不存在：$agentId'});
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
