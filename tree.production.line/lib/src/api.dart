/// 产线 REST 委派（`docs/pluginization/production-line-recon.md` §10.2）。
///
/// 读半边（切片 2）与写半边（切片 3）共用一张申报表：GET 列表 / 详情 / 队列 /
/// 台账 / 产物 / 报告 / 待答问题；POST 建产线 / 建任务 / 派发 / 决策 / 取消；
/// PATCH 改产线配置 / 改任务状态；DELETE 删产线（只删插件数据，项目资产保留）。
///
/// 归属与数据根都取自委派信封（`data_dir` / `team_id`），缺一 fail-closed；
/// 不 import 核心包，也不碰 `_kit`（领域库纪律）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'audit_service.dart';
import 'execution_service.dart';
import 'models.dart';
import 'preparation_service.dart';
import 'service.dart';
import 'store.dart';

/// 收集站 id：核心请插件申报自己承接的 REST 路由。
const String kApiRoutesStation = 'system.collect.api.routes';

const String linesPattern = '/api/production/lines';
const String linePattern = '/api/production/lines/{lineId}';
const String tasksPattern = '/api/production/lines/{lineId}/tasks';
const String taskPattern = '/api/production/lines/{lineId}/tasks/{taskId}';
const String runsPattern = '/api/production/lines/{lineId}/runs';
const String artifactsPattern = '/api/production/lines/{lineId}/artifacts';
const String auditPattern = '/api/production/lines/{lineId}/audit';

/// 决策卡片的数据源（§10.2 表的补充读路由：没有它 UI 不知道要回答哪些 Q）。
const String questionsPattern =
    '/api/production/lines/{lineId}/tasks/{taskId}/questions';
const String dispatchPattern =
    '/api/production/lines/{lineId}/tasks/{taskId}/dispatch';
const String decisionPattern =
    '/api/production/lines/{lineId}/tasks/{taskId}/decision';
const String cancelPattern =
    '/api/production/lines/{lineId}/tasks/{taskId}/cancel';

/// 本插件申报的全部路由。
const List<Map<String, String>> kDeclaredRoutes = <Map<String, String>>[
  <String, String>{'method': 'GET', 'pattern': linesPattern},
  <String, String>{'method': 'POST', 'pattern': linesPattern},
  <String, String>{'method': 'GET', 'pattern': linePattern},
  <String, String>{'method': 'PATCH', 'pattern': linePattern},
  <String, String>{'method': 'DELETE', 'pattern': linePattern},
  <String, String>{'method': 'GET', 'pattern': tasksPattern},
  <String, String>{'method': 'POST', 'pattern': tasksPattern},
  <String, String>{'method': 'GET', 'pattern': taskPattern},
  <String, String>{'method': 'PATCH', 'pattern': taskPattern},
  <String, String>{'method': 'GET', 'pattern': runsPattern},
  <String, String>{'method': 'GET', 'pattern': artifactsPattern},
  <String, String>{'method': 'GET', 'pattern': auditPattern},
  <String, String>{'method': 'GET', 'pattern': questionsPattern},
  <String, String>{'method': 'POST', 'pattern': dispatchPattern},
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
      awaitDispatch,
    );
  } on ProductionFailure catch (error) {
    return _error(
      _statusOf(error.code),
      error.message,
      code: error.code,
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
  if (teamId.isEmpty) {
    return _error(400, '缺少 team_id（核心未在委派信封里带团队归属）', code: 'team_required');
  }

  final Map<String, Object?> meta = <String, Object?>{'data_dir': dataDir};
  final Map<String, Object?> scope = <String, Object?>{
    'team_id': teamId,
    if (textOf(envelope['agent_id']).isNotEmpty)
      'agent_id': textOf(envelope['agent_id']),
  };
  final ProductionStore store = ProductionStore(
    dataRoot: dataDir,
    teamId: teamId,
  );

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
      return _ok(
        service.handle('production.line.create', input, meta, scope),
      );
    }
  }
  if (_matches(linePattern, path)) {
    final String lineId = _pathParam(linePattern, path, 'lineId');
    if (method == 'GET') {
      return _ok(
        service.handle('production.line.get', <String, Object?>{
          'line_id': lineId,
        }, meta, scope),
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
        service.handle('production.task.list', <String, Object?>{
          'line_id': lineId,
          if (status.isNotEmpty) 'status': status,
        }, meta, scope),
      );
    }
    if (method == 'POST') {
      final Map<String, Object?> task = body['task'] is Map
          ? plainMap(body['task'])
          : body;
      return _ok(
        service.handle('production.task.create', <String, Object?>{
          'line_id': lineId,
          'task': task,
        }, meta, scope),
      );
    }
  }
  if (_matches(taskPattern, path)) {
    final String lineId = _pathParam(taskPattern, path, 'lineId');
    final String taskId = _pathParam(taskPattern, path, 'taskId');
    if (method == 'GET') {
      return _ok(
        service.handle('production.task.get', <String, Object?>{
          'line_id': lineId,
          'task_id': taskId,
        }, meta, scope),
      );
    }
    if (method == 'PATCH') {
      final String to = textOf(body['to']).isEmpty
          ? textOf(body['status'])
          : textOf(body['to']);
      if (to.isEmpty) {
        throw ProductionFailure(
          '改状态需要 to（或 status）',
          code: 'invalid_arguments',
        );
      }
      return _ok(
        service.handle('production.task.transition', <String, Object?>{
          'line_id': lineId,
          'task_id': taskId,
          'to': to,
          'reason': textOf(body['reason']),
        }, meta, scope),
      );
    }
  }
  if (_matches(questionsPattern, path)) {
    if (method == 'GET') {
      final String lineId = _pathParam(questionsPattern, path, 'lineId');
      final String taskId = _pathParam(questionsPattern, path, 'taskId');
      return _ok(
        await preparation.handle('production.prepare.questions', <String, Object?>{
          'line_id': lineId,
          'task_id': taskId,
        }, meta, scope),
      );
    }
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
        service.handle('production.task.transition', <String, Object?>{
          'line_id': lineId,
          'task_id': taskId,
          'to': TaskStatus.cancelled.wire,
          'reason': textOf(body['reason']).isEmpty
              ? '用户取消'
              : textOf(body['reason']),
        }, meta, scope),
      );
    }
  }
  if (_matches(runsPattern, path) && method == 'GET') {
    final String lineId = _pathParam(runsPattern, path, 'lineId');
    final String taskId = _queryOf(query, 'task_id');
    return _ok(
      service.handle('production.run.list', <String, Object?>{
        'line_id': lineId,
        if (taskId.isNotEmpty) 'task_id': taskId,
      }, meta, scope),
    );
  }
  if (_matches(artifactsPattern, path) && method == 'GET') {
    final String lineId = _pathParam(artifactsPattern, path, 'lineId');
    return _ok(_artifacts(store, lineId));
  }
  if (_matches(auditPattern, path) && method == 'GET') {
    final String lineId = _pathParam(auditPattern, path, 'lineId');
    // REST 是只读面：`write=false` 只出报告，不落 audit.md（落盘留给写接口）。
    return _ok(
      await audit.handle('production.audit.run', <String, Object?>{
        'line_id': lineId,
        'write': false,
      }, meta, scope),
    );
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
) async {
  if (execution == null) {
    return _error(
      503,
      '执行阶段需要 agent.worker.run / local.exec.command 通道，当前未接线',
      code: 'execution_unavailable',
    );
  }
  if (textOf(scope['agent_id']).isEmpty) {
    throw ProductionFailure(
      '派发需要发起者身份（query.agent_id）：员工按它继承工作空间与团队',
      code: 'agent_required',
    );
  }
  final TaskRecord task = store.getTask(lineId, taskId);
  final String requested = textOf(body['stage']);
  String stage = requested;
  if (stage.isEmpty || stage == 'auto') {
    if (task.status == TaskStatus.queued || task.status == TaskStatus.packing) {
      stage = 'pack';
    } else if (task.status == TaskStatus.packed) {
      stage = 'run';
    } else {
      throw ProductionFailure(
        '任务当前 ${task.status.wire} 不能派发（打包要 queued / packing，执行要 packed）',
        code: 'execute_state',
      );
    }
  }
  if (stage != 'pack' && stage != 'run') {
    throw ProductionFailure(
      'dispatch 的 stage 只能是 pack / run / auto：$stage',
      code: 'invalid_arguments',
    );
  }
  if (stage == 'pack' &&
      task.status != TaskStatus.queued &&
      task.status != TaskStatus.packing) {
    throw ProductionFailure(
      '只有 queued / packing 可以打包（当前 ${task.status.wire}）',
      code: 'execute_state',
    );
  }
  if (stage == 'run' && task.status != TaskStatus.packed) {
    throw ProductionFailure(
      '只有 packed 可以执行（当前 ${task.status.wire}）',
      code: 'execute_state',
    );
  }
  final String key = '$lineId/$taskId';
  if (_dispatchInFlight.contains(key)) {
    throw ProductionFailure(
      '任务 $taskId 已在派发中（同一任务不接受第二次派发）',
      code: 'dispatch_in_flight',
    );
  }
  final String command = stage == 'pack'
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
      _recordDispatchFailure(store, lineId, taskId, stage, error);
      rethrow;
    } finally {
      _dispatchInFlight.remove(key);
    }
  }();
  if (awaitDispatch) {
    return _ok(<String, Object?>{...await job, 'stage': stage});
  }
  // 后台跑：错误已经落到 task.yaml.last_error，这里只兜住未捕获异常。
  unawaited(job.then<void>((_) {}, onError: (Object _) {}));
  return _ok(<String, Object?>{
    'accepted': true,
    'stage': stage,
    'line_id': lineId,
    'task_id': taskId,
    'task': task.toJson(),
    'note': '已受理：进度看任务状态与运行台账，失败原因写入 last_error',
  });
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

void _collectFiles(
  Directory dir,
  String root,
  List<Map<String, Object?>> out,
) {
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
    throw ProductionFailure(
      '请求体不是 JSON 对象',
      code: 'invalid_arguments',
    );
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

Map<String, dynamic> _ok(Map<String, Object?> body) => _reply(200, body);

Map<String, dynamic> _error(int status, String detail, {String code = ''}) =>
    _reply(status, <String, Object?>{
      'detail': detail,
      if (code.isNotEmpty) 'code': code,
    });

Map<String, dynamic> _reply(int status, Map<String, Object?> body) =>
    <String, dynamic>{
      'status': status,
      'headers': <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
      'body': jsonEncode(body),
    };
