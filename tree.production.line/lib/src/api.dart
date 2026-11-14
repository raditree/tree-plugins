/// 产线 REST 委派（`docs/pluginization/production-line-recon.md` §10.2）。
///
/// 读半边（切片 2）与写半边（切片 3）共用一张申报表：GET 列表 / 详情 / 队列 /
/// 台账 / 产物 / 报告 / 待答问题；POST 建产线 / 建任务 / 派发 / 决策 / 取消；
/// PATCH 改产线配置 / 改任务状态；DELETE 删产线（只删插件数据，项目资产保留）。
///
/// 归属与数据根都取自委派信封（`data_dir`）；`team_id` / `agent_id` 只作调用方
/// 身份透传（§16 起数据落全局作用域，不再按团队分目录）。
/// 不 import 核心包，也不碰 `_kit`（领域库纪律）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'audit_service.dart';
import 'budget.dart';
import 'dedup_service.dart';
import 'execution_service.dart';
import 'models.dart';
import 'normalization_service.dart';
import 'orchestrator_service.dart';
import 'preparation_service.dart';
import 'queue.dart';
import 'readiness.dart';
import 'readiness_service.dart';
import 'service.dart';
import 'store.dart';
import 'structure_service.dart';

/// 收集站 id：核心请插件申报自己承接的 REST 路由。
const String kApiRoutesStation = 'system.collect.api.routes';

const String linesPattern = '/api/production/lines';
const String linePattern = '/api/production/lines/{lineId}';
const String tasksPattern = '/api/production/lines/{lineId}/tasks';
const String taskPattern = '/api/production/lines/{lineId}/tasks/{taskId}';

/// 任务附件（Task 6）：POST 落盘 + 元数据登记；不写项目资产。
const String attachmentsPattern =
    '/api/production/lines/{lineId}/tasks/{taskId}/attachments';

const String runsPattern = '/api/production/lines/{lineId}/runs';
const String artifactsPattern = '/api/production/lines/{lineId}/artifacts';
const String auditPattern = '/api/production/lines/{lineId}/audit';
const String dedupPattern = '/api/production/lines/{lineId}/dedup';

/// 批次漂移哨兵（BG-01~08）：GET 读最近报告，POST 跑一次。
const String driftPattern = '/api/production/lines/{lineId}/drift';

/// 存量迁移（§16）：把旧团队目录里的产线搬进全局作用域。
const String migratePattern = '/api/production/migrate';

/// 决策卡片的数据源（§10.2 表的补充读路由：没有它 UI 不知道要回答哪些 Q）。
const String questionsPattern =
    '/api/production/lines/{lineId}/tasks/{taskId}/questions';

/// 计划文档（PC-3F）：GET 最新 `plans/plan-vN/plan.json`（7 块 + findings）。
const String planPattern = '/api/production/lines/{lineId}/plan';

/// 准备阶段（Task 10）：侦查 / 落档的 REST 等价。
const String reconPattern =
    '/api/production/lines/{lineId}/tasks/{taskId}/recon';
const String finalizePattern =
    '/api/production/lines/{lineId}/tasks/{taskId}/finalize';

/// L0 就绪门（Task 9.1）：GET 复合就绪快照。
const String readinessPattern = '/api/production/lines/{lineId}/readiness';

/// 结构整理（Task 9.1）：GET 连带就绪快照；POST 重审 / 豁免。
const String structurePattern = '/api/production/lines/{lineId}/structure';
const String structureReevaluatePattern =
    '/api/production/lines/{lineId}/structure/reevaluate';
const String structureWaivePattern =
    '/api/production/lines/{lineId}/structure/waive';

/// 文档归一化（Task 9.1）：GET 状态 / POST 计划 / 应用 / 回滚。
const String normalizePattern = '/api/production/lines/{lineId}/normalize';
const String normalizePlanPattern =
    '/api/production/lines/{lineId}/normalize/plan';
const String normalizeApplyPattern =
    '/api/production/lines/{lineId}/normalize/apply';
const String normalizeRollbackPattern =
    '/api/production/lines/{lineId}/normalize/rollback';

/// 运行期问题回答（D6-O §7.1）：追加 answer → `blocked → queued`。
const String answerPattern =
    '/api/production/lines/{lineId}/tasks/{taskId}/answer';

/// 主控决策循环（D6-O §7.1）。
const String orchestratePattern = '/api/production/lines/{lineId}/orchestrate';
const String pausePattern = '/api/production/lines/{lineId}/pause';
const String resumePattern = '/api/production/lines/{lineId}/resume';
const String orchestratorPattern =
    '/api/production/lines/{lineId}/orchestrator';
const String dispatchPattern =
    '/api/production/lines/{lineId}/tasks/{taskId}/dispatch';

/// 批量派发（dry-run 默认；`run=true` 或 `dry_run=false` 才真正派发）。
const String bulkDispatchPattern = '/api/production/lines/{lineId}/dispatch';
const String decisionPattern =
    '/api/production/lines/{lineId}/tasks/{taskId}/decision';
const String cancelPattern =
    '/api/production/lines/{lineId}/tasks/{taskId}/cancel';

/// 本插件申报的全部路由。
const List<Map<String, String>> kDeclaredRoutes = <Map<String, String>>[
  <String, String>{'method': 'GET', 'pattern': linesPattern},
  <String, String>{'method': 'POST', 'pattern': linesPattern},
  <String, String>{'method': 'POST', 'pattern': migratePattern},
  <String, String>{'method': 'GET', 'pattern': readinessPattern},
  <String, String>{'method': 'GET', 'pattern': structurePattern},
  <String, String>{'method': 'POST', 'pattern': structureReevaluatePattern},
  <String, String>{'method': 'POST', 'pattern': structureWaivePattern},
  <String, String>{'method': 'GET', 'pattern': normalizePattern},
  <String, String>{'method': 'POST', 'pattern': normalizePlanPattern},
  <String, String>{'method': 'POST', 'pattern': normalizeApplyPattern},
  <String, String>{'method': 'POST', 'pattern': normalizeRollbackPattern},
  <String, String>{'method': 'GET', 'pattern': linePattern},
  <String, String>{'method': 'PATCH', 'pattern': linePattern},
  <String, String>{'method': 'DELETE', 'pattern': linePattern},
  <String, String>{'method': 'GET', 'pattern': tasksPattern},
  <String, String>{'method': 'POST', 'pattern': tasksPattern},
  <String, String>{'method': 'GET', 'pattern': taskPattern},
  <String, String>{'method': 'PATCH', 'pattern': taskPattern},
  <String, String>{'method': 'POST', 'pattern': attachmentsPattern},
  <String, String>{'method': 'GET', 'pattern': runsPattern},
  <String, String>{'method': 'GET', 'pattern': artifactsPattern},
  <String, String>{'method': 'GET', 'pattern': auditPattern},
  <String, String>{'method': 'GET', 'pattern': dedupPattern},
  <String, String>{'method': 'POST', 'pattern': dedupPattern},
  <String, String>{'method': 'GET', 'pattern': driftPattern},
  <String, String>{'method': 'POST', 'pattern': driftPattern},
  <String, String>{'method': 'GET', 'pattern': questionsPattern},
  <String, String>{'method': 'GET', 'pattern': planPattern},
  <String, String>{'method': 'POST', 'pattern': reconPattern},
  <String, String>{'method': 'POST', 'pattern': finalizePattern},
  <String, String>{'method': 'POST', 'pattern': answerPattern},
  <String, String>{'method': 'POST', 'pattern': orchestratePattern},
  <String, String>{'method': 'POST', 'pattern': pausePattern},
  <String, String>{'method': 'POST', 'pattern': resumePattern},
  <String, String>{'method': 'GET', 'pattern': orchestratorPattern},
  <String, String>{'method': 'POST', 'pattern': dispatchPattern},
  <String, String>{'method': 'POST', 'pattern': bulkDispatchPattern},
  <String, String>{'method': 'POST', 'pattern': decisionPattern},
  <String, String>{'method': 'POST', 'pattern': cancelPattern},
];

/// 正在后台派发的任务（`<lineId>/<taskId>`）：同一任务不接受第二次派发。
final Set<String> _dispatchInFlight = <String>{};

/// 处理一次 `api/delegate`（核心 → 本插件）。
///
/// 回包固定 `{status, headers?, body}`，body 是 JSON 字符串（与 tree.agent /
/// files 同一契约）。路由都走已有的命令门面，不在 REST 层复制业务规则。
///
/// [awaitDispatch]：派发（打包 / 执行）默认**后台跑**——核心的 `api/delegate`
/// 只等 30s，模型跑完通常更久，同步回包会一律 504。测试传 `true` 以便断言结果。
Future<Map<String, dynamic>> handleProductionDelegate(
  Map<String, dynamic> envelope, {
  ProductionService? service,
  ProductionAuditService? audit,
  ProductionExecutionService? execution,
  PreparationService? preparation,
  OrchestratorService? orchestrator,
  ProductionDedupService Function(Map<String, Object?> scope)? dedupFor,
  ProductionNormalizationService? normalization,
  ProductionReadinessService? readiness,
  bool awaitDispatch = false,
  Map<String, String>? environment,
}) async {
  try {
    return await _dispatch(
      envelope,
      service ?? ProductionService(environment: environment),
      audit ?? ProductionAuditService(environment: environment),
      preparation ?? PreparationService(environment: environment),
      execution,
      orchestrator,
      dedupFor,
      normalization,
      readiness,
      awaitDispatch,
    );
  } on ProductionFailure catch (error) {
    return _error(
      _statusOf(error.code),
      error.message,
      code: error.code,
      missing: error.missing,
    );
  } catch (error) {
    return _error(500, '生产线插件内部错误：$error', code: 'internal_error');
  }
}

Future<Map<String, dynamic>> _dispatch(
  Map<String, dynamic> envelope,
  ProductionService service,
  ProductionAuditService audit,
  PreparationService preparation,
  ProductionExecutionService? execution,
  OrchestratorService? orchestrator,
  ProductionDedupService Function(Map<String, Object?> scope)? dedupFor,
  ProductionNormalizationService? normalization,
  ProductionReadinessService? readiness,
  bool awaitDispatch,
) async {
  final String method = textOf(envelope['method']).toUpperCase();
  final String path = textOf(envelope['path']);
  final Map<String, Object?> params = plainMap(envelope['params']);
  final Map<String, Object?> query = plainMap(envelope['query']);
  final Map<String, Object?> body = _bodyOf(envelope);
  final String dataDir = textOf(envelope['data_dir']);
  if (dataDir.isEmpty) {
    return _error(500, '委派信封缺少 data_dir（核心契约不完整）', code: 'missing_data_dir');
  }
  final String teamId = textOf(envelope['team_id']).isNotEmpty
      ? textOf(envelope['team_id'])
      : textOf(plainMap(envelope['scope'])['team_id']);

  final Map<String, Object?> meta = <String, Object?>{'data_dir': dataDir};
  final Map<String, Object?> scope = <String, Object?>{
    if (teamId.isNotEmpty) 'team_id': teamId,
    if (textOf(envelope['agent_id']).isNotEmpty)
      'agent_id': textOf(envelope['agent_id']),
  };
  final ProductionStore store = ProductionStore(dataRoot: dataDir);

  if (_matches(linesPattern, path)) {
    if (method == 'GET') {
      return _ok(service.handle('production.line.list', params, meta, scope));
    }
    if (method == 'POST') {
      final Map<String, Object?> input = body['line'] is Map
          ? plainMap(body['line'])
          : body;
      if (textOf(input['name']).isEmpty) {
        throw ProductionFailure('新建产线需要 name', code: 'invalid_arguments');
      }
      return _ok(service.handle('production.line.create', input, meta, scope));
    }
  }
  if (_matches(migratePattern, path) && method == 'POST') {
    // 旧团队目录 → 全局作用域（§16）。幂等；冲突只报不覆盖。
    final String agentId = textOf(body['agent_id']).isNotEmpty
        ? textOf(body['agent_id'])
        : _queryOf(query, 'agent_id');
    final String executorTeam = textOf(body['team_id']).isNotEmpty
        ? textOf(body['team_id'])
        : _queryOf(query, 'team_id');
    return _ok(
      store.migrateLegacy(
        agentId: agentId,
        teamId: executorTeam,
        dryRun: body['dry_run'] == true,
      ),
    );
  }
  if (_matches(driftPattern, path)) {
    final String lineId = _pathParam(driftPattern, path, 'lineId');
    if (method == 'GET') {
      return _ok(
        service.handle(
          'production.drift.get',
          <String, Object?>{'line_id': lineId},
          meta,
          scope,
        ),
      );
    }
    if (method == 'POST') {
      // 漂移失败是业务判定（HTTP 200 + ok:false），不转成命令异常。
      return _ok(
        service.handle(
          'production.drift.run',
          <String, Object?>{...body, 'line_id': lineId},
          meta,
          scope,
        ),
      );
    }
  }
  if (_matches(readinessPattern, path) && method == 'GET') {
    final String lineId = _pathParam(readinessPattern, path, 'lineId');
    if (readiness == null) {
      return _error(
        503,
        '复合就绪门需要 docnorm / 去重通道，当前未接线',
        code: 'readiness_unavailable',
      );
    }
    return _ok(
      await readiness.handle(
        'production.readiness.get',
        <String, Object?>{'line_id': lineId},
        meta,
        scope,
      ),
    );
  }
  if (_matches(structurePattern, path) && method == 'GET') {
    final String lineId = _pathParam(structurePattern, path, 'lineId');
    final Map<String, Object?> structure = service.handle(
      'production.structure.get',
      <String, Object?>{'line_id': lineId},
      meta,
      scope,
    );
    // 就绪快照是附带信息：拿不到就回空表，不阻断结构视图。
    Map<String, Object?> readinessPayload = <String, Object?>{};
    if (readiness != null) {
      try {
        readinessPayload = await readiness.handle(
          'production.readiness.get',
          <String, Object?>{'line_id': lineId},
          meta,
          scope,
        );
      } catch (_) {
        readinessPayload = <String, Object?>{};
      }
    }
    return _ok(<String, Object?>{
      'structure': structure,
      'readiness': readinessPayload,
    });
  }
  if (_matches(structureReevaluatePattern, path) && method == 'POST') {
    final String lineId = _pathParam(
      structureReevaluatePattern,
      path,
      'lineId',
    );
    return _ok(
      service.handle(
        'production.structure.reevaluate',
        <String, Object?>{...body, 'line_id': lineId},
        meta,
        scope,
      ),
    );
  }
  if (_matches(structureWaivePattern, path) && method == 'POST') {
    final String lineId = _pathParam(structureWaivePattern, path, 'lineId');
    return _ok(
      service.handle(
        'production.structure.waive',
        <String, Object?>{...body, 'line_id': lineId},
        meta,
        scope,
      ),
    );
  }
  if (_matches(normalizePattern, path) && method == 'GET') {
    final String lineId = _pathParam(normalizePattern, path, 'lineId');
    if (normalization == null) {
      return _error(
        503,
        '文档归一化需要 docnorm 通道，当前未接线',
        code: 'normalization_unavailable',
      );
    }
    return _ok(
      await normalization.handle(
        'production.normalize.status',
        <String, Object?>{'line_id': lineId},
        meta,
        scope,
      ),
    );
  }
  if (_matches(normalizePlanPattern, path) && method == 'POST') {
    final String lineId = _pathParam(normalizePlanPattern, path, 'lineId');
    if (normalization == null) {
      return _error(
        503,
        '文档归一化需要 docnorm 通道，当前未接线',
        code: 'normalization_unavailable',
      );
    }
    // plan 是 dry-run：没显式 commit=true 一律按不落盘处理。
    return _ok(
      await normalization.handle(
        'production.normalize.plan',
        <String, Object?>{
          ...body,
          'line_id': lineId,
          'commit': body['commit'] == true,
        },
        meta,
        scope,
      ),
    );
  }
  if (_matches(normalizeApplyPattern, path) && method == 'POST') {
    final String lineId = _pathParam(normalizeApplyPattern, path, 'lineId');
    if (normalization == null) {
      return _error(
        503,
        '文档归一化需要 docnorm 通道，当前未接线',
        code: 'normalization_unavailable',
      );
    }
    return _ok(
      await normalization.handle(
        'production.normalize.apply',
        <String, Object?>{...body, 'line_id': lineId},
        meta,
        scope,
      ),
    );
  }
  if (_matches(normalizeRollbackPattern, path) && method == 'POST') {
    final String lineId = _pathParam(normalizeRollbackPattern, path, 'lineId');
    if (normalization == null) {
      return _error(
        503,
        '文档归一化需要 docnorm 通道，当前未接线',
        code: 'normalization_unavailable',
      );
    }
    return _ok(
      await normalization.handle(
        'production.normalize.rollback',
        <String, Object?>{...body, 'line_id': lineId},
        meta,
        scope,
      ),
    );
  }
  if (_matches(linePattern, path)) {
    final String lineId = _pathParam(linePattern, path, 'lineId');
    if (method == 'GET') {
      return _ok(
        service.handle(
          'production.line.get',
          <String, Object?>{'line_id': lineId},
          meta,
          scope,
        ),
      );
    }
    if (method == 'PATCH') {
      return _ok(<String, Object?>{
        'line': store.updateLine(lineId, body).toJson(),
      });
    }
    if (method == 'DELETE') {
      return _ok(store.deleteLine(lineId));
    }
  }
  if (_matches(tasksPattern, path)) {
    final String lineId = _pathParam(tasksPattern, path, 'lineId');
    if (method == 'GET') {
      final String status = _queryOf(query, 'status');
      return _ok(
        service.handle(
          'production.task.list',
          <String, Object?>{
            'line_id': lineId,
            if (status.isNotEmpty) 'status': status,
          },
          meta,
          scope,
        ),
      );
    }
    if (method == 'POST') {
      final Map<String, Object?> task = body['task'] is Map
          ? plainMap(body['task'])
          : body;
      return _ok(
        service.handle(
          'production.task.create',
          <String, Object?>{'line_id': lineId, 'task': task},
          meta,
          scope,
        ),
      );
    }
  }
  if (_matches(attachmentsPattern, path) && method == 'POST') {
    final String lineId = _pathParam(attachmentsPattern, path, 'lineId');
    final String taskId = _pathParam(attachmentsPattern, path, 'taskId');
    final Map<String, Object?> payload = service.handle(
      'production.task.attach',
      <String, Object?>{
        'line_id': lineId,
        'task_id': taskId,
        'source': textOf(body['source']),
        'name': textOf(body['name']),
        'type': textOf(body['type']),
        'kind': textOf(body['kind']),
        'vision': body['vision'] == true,
      },
      meta,
      scope,
    );
    return _reply(201, payload);
  }
  if (_matches(taskPattern, path)) {
    final String lineId = _pathParam(taskPattern, path, 'lineId');
    final String taskId = _pathParam(taskPattern, path, 'taskId');
    if (method == 'GET') {
      return _ok(
        service.handle(
          'production.task.get',
          <String, Object?>{'line_id': lineId, 'task_id': taskId},
          meta,
          scope,
        ),
      );
    }
    if (method == 'PATCH') {
      final String to = textOf(body['to']).isEmpty
          ? textOf(body['status'])
          : textOf(body['to']);
      // 有 to / status ⇒ 状态迁移；否则按任务字段编辑（Task 5）。
      if (to.isNotEmpty) {
        return _ok(
          service.handle(
            'production.task.transition',
            <String, Object?>{
              'line_id': lineId,
              'task_id': taskId,
              'to': to,
              'reason': textOf(body['reason']),
            },
            meta,
            scope,
          ),
        );
      }
      return _ok(
        service.handle(
          'production.task.update',
          <String, Object?>{
            'line_id': lineId,
            'task_id': taskId,
            'patch': body,
          },
          meta,
          scope,
        ),
      );
    }
  }
  if (_matches(bulkDispatchPattern, path) && method == 'POST') {
    final String lineId = _pathParam(bulkDispatchPattern, path, 'lineId');
    final Map<String, Object?> plan = service.handle(
      'production.queue.plan',
      <String, Object?>{'line_id': lineId},
      meta,
      scope,
    );
    // 默认只出计划（dry_run=true）；只有显式 run=true 或 dry_run=false 才派发。
    final bool dryRun = body['dry_run'] is bool
        ? body['dry_run'] as bool
        : true;
    final bool run = body['run'] == true || dryRun == false;
    if (!run) {
      return _ok(<String, Object?>{...plan, 'dry_run': true});
    }
    if (execution == null) {
      return _error(503, '批量派发需要执行阶段通道，当前未接线', code: 'execution_unavailable');
    }
    final String stage = textOf(body['stage']).isEmpty
        ? 'auto'
        : textOf(body['stage']);
    final List<Map<String, Object?>> dispatched = <Map<String, Object?>>[];
    final List<Map<String, Object?>> failed = <Map<String, Object?>>[];
    for (final String taskId in stringsOf(plan['batch_ids'])) {
      final Map<String, dynamic> reply = await dispatchProductionTask(
        store: store,
        execution: execution,
        lineId: lineId,
        taskId: taskId,
        stage: stage,
        meta: meta,
        scope: scope,
        awaitDispatch: awaitDispatch,
      );
      final int status = intOf(reply['status'], 500);
      final Map<String, Object?> payload = _replyPayload(reply);
      if (status == 200) {
        dispatched.add(<String, Object?>{
          'task_id': taskId,
          'stage': textOf(payload['stage']),
          'accepted': true,
        });
        continue;
      }
      failed.add(<String, Object?>{
        'task_id': taskId,
        'status': status,
        'code': textOf(payload['code']),
        'message': textOf(payload['message']),
      });
    }
    return _ok(<String, Object?>{
      ...plan,
      'dry_run': false,
      'run': true,
      'dispatched': dispatched,
      'dispatched_count': dispatched.length,
      'failed': failed,
      'failed_count': failed.length,
    });
  }
  if (_matches(planPattern, path) && method == 'GET') {
    final String lineId = _pathParam(planPattern, path, 'lineId');
    return _ok(
      await preparation.handle(
        'production.plan.get',
        <String, Object?>{
          'line_id': lineId,
          if (textOf(query['version']).isNotEmpty)
            'version': intOf(query['version'], 0),
        },
        meta,
        scope,
      ),
    );
  }
  if (_matches(reconPattern, path) && method == 'POST') {
    final String lineId = _pathParam(reconPattern, path, 'lineId');
    final String taskId = _pathParam(reconPattern, path, 'taskId');
    return _ok(
      await preparation.handle(
        'production.prepare.recon',
        <String, Object?>{'line_id': lineId, 'task_id': taskId, ...body},
        meta,
        scope,
      ),
    );
  }
  if (_matches(finalizePattern, path) && method == 'POST') {
    final String lineId = _pathParam(finalizePattern, path, 'lineId');
    final String taskId = _pathParam(finalizePattern, path, 'taskId');
    return _ok(
      await preparation.handle(
        'production.prepare.finalize',
        <String, Object?>{'line_id': lineId, 'task_id': taskId, ...body},
        meta,
        scope,
      ),
    );
  }
  if (_matches(questionsPattern, path)) {
    if (method == 'GET') {
      final String lineId = _pathParam(questionsPattern, path, 'lineId');
      final String taskId = _pathParam(questionsPattern, path, 'taskId');
      final Map<String, Object?> preparePayload = await preparation.handle(
        'production.prepare.questions',
        <String, Object?>{'line_id': lineId, 'task_id': taskId},
        meta,
        scope,
      );
      // D6-O §7.2：收件箱要能区分准备阶段与运行期问题；运行期问题单独给一组。
      Map<String, Object?> executePayload = <String, Object?>{};
      if (execution != null) {
        executePayload = await execution.handle(
          'production.task.questions',
          <String, Object?>{'line_id': lineId, 'task_id': taskId},
          meta,
          scope,
        );
      }
      return _ok(<String, Object?>{
        ...preparePayload,
        'execute_questions': executePayload['questions'] ?? <Object?>[],
        'execute_open': intOf(executePayload['open'], 0),
      });
    }
  }
  if (_matches(answerPattern, path) && method == 'POST') {
    final String lineId = _pathParam(answerPattern, path, 'lineId');
    final String taskId = _pathParam(answerPattern, path, 'taskId');
    if (execution == null) {
      return _error(503, '运行期问答需要执行阶段通道，当前未接线', code: 'execution_unavailable');
    }
    final Map<String, Object?> answered = await execution.handle(
      'production.task.answer',
      <String, Object?>{
        'line_id': lineId,
        'task_id': taskId,
        'qid': textOf(body['qid']),
        'value': textOf(body['value']).isEmpty
            ? textOf(body['answer'])
            : textOf(body['value']),
      },
      meta,
      scope,
    );
    // §3.1：回答落盘后立即 tick（后台，不拖慢回答回包）。
    if (orchestrator != null) {
      unawaited(
        orchestrator
            .tick(store, lineId, meta: meta, scope: scope, trigger: 'event')
            .catchError((Object _) => <String, Object?>{}),
      );
    }
    return _ok(answered);
  }
  if (_matches(dispatchPattern, path)) {
    if (method == 'POST') {
      final String lineId = _pathParam(dispatchPattern, path, 'lineId');
      final String taskId = _pathParam(dispatchPattern, path, 'taskId');
      return _dispatchTask(
        store,
        execution,
        lineId,
        taskId,
        body,
        meta,
        scope,
        awaitDispatch,
      );
    }
  }
  if (_matches(decisionPattern, path)) {
    if (method == 'POST') {
      final String lineId = _pathParam(decisionPattern, path, 'lineId');
      final String taskId = _pathParam(decisionPattern, path, 'taskId');
      if (body['all_recommended'] == true) {
        return _ok(
          await preparation.handle(
            'production.prepare.all_recommended',
            <String, Object?>{'line_id': lineId, 'task_id': taskId},
            meta,
            scope,
          ),
        );
      }
      final Object? answers = body['answers'];
      if (answers is List && answers.isNotEmpty) {
        return _ok(
          await preparation.handle(
            'production.prepare.answer',
            <String, Object?>{
              'line_id': lineId,
              'task_id': taskId,
              'answers': answers,
            },
            meta,
            scope,
          ),
        );
      }
      final String qid = textOf(body['qid']);
      if (qid.isNotEmpty) {
        return _ok(
          await preparation.handle(
            'production.prepare.answer',
            <String, Object?>{
              'line_id': lineId,
              'task_id': taskId,
              'qid': qid,
              'value': textOf(body['value']),
            },
            meta,
            scope,
          ),
        );
      }
      throw ProductionFailure(
        'decision 需要 answers 或 qid/value，或 all_recommended=true',
        code: 'invalid_arguments',
      );
    }
  }
  if (_matches(cancelPattern, path)) {
    if (method == 'POST') {
      final String lineId = _pathParam(cancelPattern, path, 'lineId');
      final String taskId = _pathParam(cancelPattern, path, 'taskId');
      return _ok(
        service.handle(
          'production.task.transition',
          <String, Object?>{
            'line_id': lineId,
            'task_id': taskId,
            'to': TaskStatus.cancelled.wire,
            'reason': textOf(body['reason']).isEmpty
                ? '用户取消'
                : textOf(body['reason']),
          },
          meta,
          scope,
        ),
      );
    }
  }
  if (_matches(orchestratePattern, path) && method == 'POST') {
    final String lineId = _pathParam(orchestratePattern, path, 'lineId');
    if (orchestrator == null) {
      return _error(
        503,
        '主控决策循环需要 llm.call 通道，当前未接线',
        code: 'orchestrator_unavailable',
      );
    }
    return _ok(
      await orchestrator.handle(
        'production.orchestrator.tick',
        <String, Object?>{'line_id': lineId, 'trigger': 'manual'},
        meta,
        scope,
      ),
    );
  }
  if (_matches(pausePattern, path) && method == 'POST') {
    final String lineId = _pathParam(pausePattern, path, 'lineId');
    return _ok(<String, Object?>{
      'line': store.updateLine(lineId, <String, Object?>{
        'status': 'paused',
      }).toJson(),
    });
  }
  if (_matches(resumePattern, path) && method == 'POST') {
    final String lineId = _pathParam(resumePattern, path, 'lineId');
    final Map<String, Object?> line = store.updateLine(
      lineId,
      <String, Object?>{'status': 'working'},
    ).toJson();
    // §3.4：恢复后立即 tick 一次；tick 失败不撤销恢复本身。
    Map<String, Object?>? tickResult;
    String tickError = '';
    if (orchestrator != null) {
      try {
        tickResult = await orchestrator.handle(
          'production.orchestrator.tick',
          <String, Object?>{'line_id': lineId, 'trigger': 'manual'},
          meta,
          scope,
        );
      } on ProductionFailure catch (error) {
        tickError = error.message;
      }
    }
    return _ok(<String, Object?>{
      'line': line,
      'tick': tickResult,
      if (tickError.isNotEmpty) 'tick_error': tickError,
    });
  }
  if (_matches(orchestratorPattern, path) && method == 'GET') {
    final String lineId = _pathParam(orchestratorPattern, path, 'lineId');
    if (orchestrator == null) {
      return _error(503, '主控状态需要主控服务，当前未接线', code: 'orchestrator_unavailable');
    }
    return _ok(orchestrator.status(store, lineId));
  }
  if (_matches(runsPattern, path) && method == 'GET') {
    final String lineId = _pathParam(runsPattern, path, 'lineId');
    final String taskId = _queryOf(query, 'task_id');
    return _ok(
      service.handle(
        'production.run.list',
        <String, Object?>{
          'line_id': lineId,
          if (taskId.isNotEmpty) 'task_id': taskId,
        },
        meta,
        scope,
      ),
    );
  }
  if (_matches(artifactsPattern, path) && method == 'GET') {
    final String lineId = _pathParam(artifactsPattern, path, 'lineId');
    return _ok(_artifacts(store, lineId));
  }
  if (_matches(auditPattern, path) && method == 'GET') {
    final String lineId = _pathParam(auditPattern, path, 'lineId');
    // REST 是只读面：`write=false` 只出报告，不落 audit.md（落盘留给写接口）。
    // `limit` = 每批文件数；`refresh=true` 才重扫（按缓存增量），否则优先回缓存。
    final int limit = intOf(_queryOf(query, 'limit'), 0);
    final String refreshRaw = textOf(_queryOf(query, 'refresh')).toLowerCase();
    final bool refresh = refreshRaw == 'true' || refreshRaw == '1';
    return _ok(
      await audit.handle(
        'production.audit.run',
        <String, Object?>{
          'line_id': lineId,
          'write': false,
          'refresh': refresh,
          if (limit > 0) 'limit': limit,
        },
        meta,
        scope,
      ),
    );
  }
  if (_matches(dedupPattern, path)) {
    final String lineId = _pathParam(dedupPattern, path, 'lineId');
    final ProductionDedupService? dedup = dedupFor?.call(scope);
    if (dedup == null) {
      return _error(
        503,
        '逻辑去重需要 tree.storage / tree.agent 通道，当前未接线',
        code: 'dedup_unavailable',
      );
    }
    if (method == 'GET') {
      return _ok(
        await dedup.handle(
          'production.dedup.status',
          <String, Object?>{'line_id': lineId},
          meta,
          scope,
        ),
      );
    }
    if (method == 'POST') {
      final int limit = intOf(body['limit'], 0);
      return _ok(
        await dedup.handle(
          'production.dedup.run',
          <String, Object?>{
            'line_id': lineId,
            'mode': textOf(body['mode']),
            if (limit > 0) 'limit': limit,
          },
          meta,
          scope,
        ),
      );
    }
  }
  return _error(404, '未知产线路由：$method $path', code: 'not_found');
}

/// 派发（§10.2 `.../dispatch`）：按状态选打包或执行，默认后台跑。
///
/// 核心的委派回包截止是 30s，而打包 / 执行要等模型与本机命令；同步等结果
/// 只会稳定 504。所以这里先给出可读的受理回包（`accepted: true`），真实进度
/// 由 `GET .../tasks/{taskId}` 与 `GET .../runs` 轮询；失败会写进
/// `task.yaml.last_error`。
Future<Map<String, dynamic>> _dispatchTask(
  ProductionStore store,
  ProductionExecutionService? execution,
  String lineId,
  String taskId,
  Map<String, Object?> body,
  Map<String, Object?> meta,
  Map<String, Object?> scope,
  bool awaitDispatch,
) => dispatchProductionTask(
  store: store,
  execution: execution,
  lineId: lineId,
  taskId: taskId,
  stage: textOf(body['stage']),
  meta: meta,
  scope: scope,
  awaitDispatch: awaitDispatch,
);

/// 派发一个任务（打包或执行）：REST 与主控 tick 共用同一把 in-flight 锁。
///
/// 默认后台跑（`awaitDispatch=false`）：核心的委派回包截止是 30s，而打包 /
/// 执行要等模型与本机命令；真实进度由任务状态与运行台账轮询。
Future<Map<String, dynamic>> dispatchProductionTask({
  required ProductionStore store,
  required ProductionExecutionService? execution,
  required String lineId,
  required String taskId,
  String stage = 'auto',
  required Map<String, Object?> meta,
  required Map<String, Object?> scope,
  bool awaitDispatch = false,
}) async {
  if (execution == null) {
    return _error(
      503,
      '执行阶段需要 agent.worker.run / local.exec.command 通道，当前未接线',
      code: 'execution_unavailable',
    );
  }
  final TaskRecord task = store.getTask(lineId, taskId);
  // LG-01 / TG-06：结构未通过时只有 cleanup 任务能派发（手动派发同样过门）。
  final LineRecord line = store.getLine(lineId);
  requireStructureReady(store, line, taskType: task.taskType);
  // LG-07 / TG-05：归一化与索引未就绪前不得派发（organizing 的 cleanup 例外）。
  requireLineReady(store, line, taskType: task.taskType);
  String resolved = stage;
  if (resolved.isEmpty || resolved == 'auto') {
    if (task.status == TaskStatus.queued || task.status == TaskStatus.packing) {
      resolved = 'pack';
    } else if (task.status == TaskStatus.packed) {
      resolved = 'run';
    } else {
      throw ProductionFailure(
        '任务当前 ${task.status.wire} 不能派发（打包要 queued / packing，执行要 packed）',
        code: 'execute_state',
      );
    }
  }
  if (resolved != 'pack' && resolved != 'run') {
    throw ProductionFailure(
      'dispatch 的 stage 只能是 pack / run / auto：$resolved',
      code: 'invalid_arguments',
    );
  }
  if (resolved == 'pack' &&
      task.status != TaskStatus.queued &&
      task.status != TaskStatus.packing) {
    throw ProductionFailure(
      '只有 queued / packing 可以打包（当前 ${task.status.wire}）',
      code: 'execute_state',
    );
  }
  if (resolved == 'run' && task.status != TaskStatus.packed) {
    throw ProductionFailure(
      '只有 packed 可以执行（当前 ${task.status.wire}）',
      code: 'execute_state',
    );
  }
  // 手动派发与主控派发共用同一把护栏（TG-02/03/04；TG-05/06 就绪门待接线）。
  _preflightDispatch(store, store.getLine(lineId), task);
  final String key = '$lineId/$taskId';
  if (_dispatchInFlight.contains(key)) {
    throw ProductionFailure(
      '任务 $taskId 已在派发中（同一任务不接受第二次派发）',
      code: 'dispatch_in_flight',
    );
  }
  final String command = resolved == 'pack'
      ? 'production.task.pack'
      : 'production.task.run';
  final Map<String, Object?> arguments = <String, Object?>{
    'line_id': lineId,
    'task_id': taskId,
  };
  _dispatchInFlight.add(key);
  final Future<Map<String, Object?>> job = () async {
    try {
      return await execution.handle(command, arguments, meta, scope);
    } catch (error) {
      _recordDispatchFailure(store, lineId, taskId, resolved, error);
      rethrow;
    } finally {
      _dispatchInFlight.remove(key);
    }
  }();
  if (awaitDispatch) {
    return _ok(<String, Object?>{...await job, 'stage': resolved});
  }
  // 后台跑：错误已经落到 task.yaml.last_error，这里只兜住未捕获异常。
  unawaited(job.then<void>((_) {}, onError: (Object _) {}));
  return _ok(<String, Object?>{
    'accepted': true,
    'stage': resolved,
    'line_id': lineId,
    'task_id': taskId,
    'task': task.toJson(),
    'note': '已受理：进度看任务状态与运行台账，失败原因写入 last_error',
  });
}

/// 手动派发前的护栏：依赖完成 / 写域不交叠 / 并行槽位 / 预算未超。
///
/// 与主控 `guardOrchestratorDecision` 共用 `queue.dart` 的判据；拒绝时抛
/// `{code,message,missing}` 的结构化失败。就绪门（TG-05/06）属于后续切片，
/// 这里不提供 force / skip 参数，也不伪造 `ready=true`。
void _preflightDispatch(
  ProductionStore store,
  LineRecord line,
  TaskRecord task,
) {
  final List<TaskRecord> tasks = store.listTasks(line.id);
  final Map<String, TaskStatus> statuses = <String, TaskStatus>{
    for (final TaskRecord item in tasks) item.id: item.status,
  };
  final List<String> waiting = missingDependencies(task, statuses);
  if (waiting.isNotEmpty) {
    throw ProductionFailure(
      '任务 ${task.id} 的依赖未完成：${waiting.join('、')}',
      code: 'task_dependency_open',
      missing: waiting,
    );
  }

  // 写域：与在途任务（不含自己）交叠即拒绝；空写域按工作空间根处理。
  final List<TaskRecord> running = <TaskRecord>[
    for (final TaskRecord item in tasks)
      if (item.id != task.id && item.status.isInFlight) item,
  ]..sort(compareQueueOrder);
  final List<String> scope = task.effectiveWriteScope;
  for (final TaskRecord peer in running) {
    if (!writeScopesOverlap(scope, peer.effectiveWriteScope)) continue;
    throw ProductionFailure(
      '任务 ${task.id} 的写域与在途任务 ${peer.id} 交叠：${scope.join('、')}',
      code: 'task_scope_conflict',
      missing: <String>[peer.id],
    );
  }

  // 并行槽位：已在途的任务（packed → run）不额外占槽。
  if (!task.status.isInFlight) {
    final int configured = intOf(
      plainMap(line.data['limits'])['max_parallel_tasks'],
      1,
    );
    final int limit = configured < 1 ? 1 : configured;
    if (running.length >= limit) {
      throw ProductionFailure(
        '并行槽位已满（${running.length}/$limit）：先等在途任务结束',
        code: 'task_parallel_limit',
        missing: <String>[for (final TaskRecord peer in running) peer.id],
      );
    }
  }

  final BudgetState budget = budgetStateOf(
    budgetOf(plainMap(line.data['limits'])),
    usageOf(task),
  );
  if (budget.exceeded) {
    throw ProductionFailure(
      '任务 ${task.id} 预算已到点：${budget.reasons.join('；')}',
      code: 'task_budget_exceeded',
      missing: budget.reasons,
    );
  }
}

/// 后台派发失败：写进 `task.yaml.last_error`（终态任务不再写，避免篡改历史）。
void _recordDispatchFailure(
  ProductionStore store,
  String lineId,
  String taskId,
  String stage,
  Object error,
) {
  try {
    final TaskRecord task = store.getTask(lineId, taskId);
    if (task.status.isTerminal) return;
    store.putTask(lineId, taskId, <String, Object?>{
      'last_error': <String, Object?>{
        'stage': 'dispatch:$stage',
        'error': '$error',
        'at': store.nowText(),
      },
    });
  } catch (_) {
    // 记录失败不掩盖原始异常。
  }
}

/// 产物树（只读）：项目资产文件 + 插件数据里的 `tasks/<id>/pack.json`。
///
/// 工作空间未配置 / 不存在不算失败——返回空树 + `note`，让 UI 显示"还没有产物"
/// 的具体原因；其余异常照常上抛。
Map<String, Object?> _artifacts(ProductionStore store, String lineId) {
  store.getLine(lineId);
  final List<Map<String, Object?>> files = <Map<String, Object?>>[];
  String assetRoot = '';
  String note = '';
  try {
    assetRoot = store.assetRoot(lineId);
    final Directory dir = Directory(assetRoot);
    if (dir.existsSync()) {
      _collectFiles(dir, assetRoot, files);
    }
  } on ProductionFailure catch (error) {
    note = error.message;
  }
  final Directory tasksDir = Directory(p.join(store.lineDir(lineId), 'tasks'));
  if (tasksDir.existsSync()) {
    for (final FileSystemEntity entity in tasksDir.listSync()) {
      if (entity is! Directory) continue;
      final File pack = File(p.join(entity.path, 'pack.json'));
      if (!pack.existsSync()) continue;
      files.add(<String, Object?>{
        'path': 'tasks/${p.basename(entity.path)}/pack.json',
        'size': pack.lengthSync(),
        'source': 'plugin',
      });
    }
  }
  files.sort(
    (Map<String, Object?> a, Map<String, Object?> b) =>
        textOf(a['path']).compareTo(textOf(b['path'])),
  );
  return <String, Object?>{
    'line_id': lineId,
    'asset_root': assetRoot,
    'files': files,
    'count': files.length,
    if (note.isNotEmpty) 'note': note,
  };
}

void _collectFiles(Directory dir, String root, List<Map<String, Object?>> out) {
  final List<FileSystemEntity> entries = dir.listSync()
    ..sort(
      (FileSystemEntity a, FileSystemEntity b) => a.path.compareTo(b.path),
    );
  for (final FileSystemEntity entity in entries) {
    if (entity is Directory) {
      _collectFiles(entity, root, out);
      continue;
    }
    if (entity is! File) continue;
    final String relative = p
        .relative(entity.path, from: root)
        .replaceAll('\\', '/');
    out.add(<String, Object?>{
      'path': relative,
      'size': entity.lengthSync(),
      'source': 'asset',
    });
  }
}

/// 从委派信封取 JSON body：内联 `body`，或核心因大体积 / chunked 落盘的
/// `body_path`（同机路径，核心已校验）。
Map<String, Object?> _bodyOf(Map<String, dynamic> envelope) {
  Object? raw = envelope['body'];
  if (raw == null || (raw is String && raw.trim().isEmpty)) {
    final String bodyPath = textOf(envelope['body_path']);
    if (bodyPath.isNotEmpty) {
      raw = File(bodyPath).readAsStringSync();
    }
  }
  if (raw is Map) return plainMap(raw);
  if (raw is String && raw.trim().isNotEmpty) {
    final Object? decoded = jsonDecode(raw);
    if (decoded is Map) return plainMap(decoded);
    throw ProductionFailure('请求体不是 JSON 对象', code: 'invalid_arguments');
  }
  return <String, Object?>{};
}

/// `ProductionFailure.code` → HTTP 状态码。
///
/// 404 只给"这条记录不存在"；状态机 / 冲突类给 409（调用方可以据此提示
/// "刷新后重试"）；其余按请求问题处理（400）。
int _statusOf(String code) {
  if (code == 'not_found') return 404;
  if (code == 'missing_data_dir' || code == 'internal_error') return 500;
  if (code == 'attachment_too_large' || code == 'image_too_large') return 413;
  if (code == 'orchestrator_unavailable' ||
      code == 'execution_unavailable' ||
      code == 'readiness_unavailable' ||
      code == 'normalization_unavailable' ||
      code == 'storage_unavailable' ||
      code == 'docnorm_unavailable' ||
      code == 'embed_unavailable') {
    return 503;
  }
  if (const <String>{
    'terminal_state',
    'invalid_transition',
    'line_exists',
    'task_exists',
    'line_busy',
    'questions_open',
    'already_scoped',
    'execute_state',
    'prepare_state',
    'dispatch_in_flight',
    'audit_in_progress',
    'dedup_in_progress',
    'head_moved',
    'question_pending',
    'question_state',
    'ask_limit_exceeded',
    'no_open_questions',
    'task_dependency_open',
    'task_dependency_missing',
    'task_input_incomplete',
    'task_edit_forbidden',
    'attachment_invalid',
    'docs_scope_required',
    'docs_scope_forbidden',
    'task_scope_conflict',
    'task_parallel_limit',
    'task_budget_exceeded',
    'structure_not_ready',
    'structure_report_missing',
    'waiver_not_allowed',
    'line_not_ready',
    'docnorm_not_ready',
    'index_not_ready',
    'normalization_plan_missing',
    'normalization_plan_stale',
    'normalization_plan_rolled_back',
    'normalization_in_progress',
    'normalization_apply_failed',
    'normalization_rollback_failed',
    'rewrite_confirmation_required',
    'rewrite_not_allowed',
    'path_outside_workspace',
    'duplicate_execution',
    'lease_lost',
    'idempotency_violation',
    'gate_tampered',
    'gate_missing',
    'gate_source_invalid',
    'model_swap_regression',
    'recovery_slo_missed',
  }.contains(code)) {
    return 409;
  }
  return 400;
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

String _pathParam(String pattern, String path, String name) {
  final List<String> want = pattern.split('/');
  final List<String> got = path.split('/');
  for (int i = 0; i < want.length && i < got.length; i++) {
    if (want[i] == '{$name}') return got[i];
  }
  return '';
}

String _queryOf(Map<String, Object?> query, String key) {
  final Object? raw = query[key];
  if (raw is List) return raw.isEmpty ? '' : textOf(raw.first);
  return textOf(raw);
}

Map<String, Object?> _replyPayload(Map<String, dynamic> reply) {
  final String raw = textOf(reply['body']);
  if (raw.isEmpty) return <String, Object?>{};
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is Map) return plainMap(decoded);
  } catch (_) {
    // 非 JSON 回包按空表处理。
  }
  return <String, Object?>{};
}

Map<String, dynamic> _ok(Map<String, Object?> body) => _reply(200, body);

Map<String, dynamic> _error(
  int status,
  String detail, {
  String code = '',
  List<String> missing = const <String>[],
}) => _reply(status, <String, Object?>{
  // `detail` 保留给旧调用方；新口径统一为 `message` + `missing`。
  'detail': detail,
  'message': detail,
  if (code.isNotEmpty) 'code': code,
  'missing': List<String>.of(missing),
});

Map<String, dynamic> _reply(int status, Map<String, Object?> body) =>
    <String, dynamic>{
      'status': status,
      'headers': <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
      'body': jsonEncode(body),
    };
