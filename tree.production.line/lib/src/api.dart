/// 产线 REST 委派（`docs/pluginization/production-line-recon.md` §10.2 的读半边）。
///
/// 切片 2 **只申报 GET**：产线列表 / 详情、任务队列 / 详情、运行台账、产物树、
/// 项目整理报告。写操作（POST/PATCH/DELETE、dispatch / decision / cancel）留到
/// 切片 3；在那之前命中清单之外的方法一律 405，绝不"收下请求但不做事"。
///
/// 归属与数据根都取自委派信封（`data_dir` / `team_id`），缺一 fail-closed；
/// 不 import 核心包，也不碰 `_kit`（领域库纪律）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'audit_service.dart';
import 'models.dart';
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

/// 本插件当前申报的全部路由（切片 2：只有 GET）。
const List<Map<String, String>> kDeclaredRoutes = <Map<String, String>>[
  <String, String>{'method': 'GET', 'pattern': linesPattern},
  <String, String>{'method': 'GET', 'pattern': linePattern},
  <String, String>{'method': 'GET', 'pattern': tasksPattern},
  <String, String>{'method': 'GET', 'pattern': taskPattern},
  <String, String>{'method': 'GET', 'pattern': runsPattern},
  <String, String>{'method': 'GET', 'pattern': artifactsPattern},
  <String, String>{'method': 'GET', 'pattern': auditPattern},
];

/// 处理一次 `api/delegate`（核心 → 本插件）。
///
/// 回包固定 `{status, headers?, body}`，body 是 JSON 字符串（与 tree.agent /
/// files 同一契约）。只读路由都走已有的命令门面，不在 REST 层复制业务规则。
Future<Map<String, dynamic>> handleProductionDelegate(
  Map<String, dynamic> envelope, {
  ProductionService? service,
  ProductionAuditService? audit,
  Map<String, String>? environment,
}) async {
  try {
    return await _dispatch(
      envelope,
      service ?? ProductionService(environment: environment),
      audit ?? ProductionAuditService(environment: environment),
    );
  } on ProductionFailure catch (error) {
    return _error(
      error.code == 'not_found' ? 404 : 400,
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
) async {
  final String method = textOf(envelope['method']).toUpperCase();
  final String path = textOf(envelope['path']);
  final Map<String, Object?> params = plainMap(envelope['params']);
  final Map<String, Object?> query = plainMap(envelope['query']);
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
  if (method != 'GET') {
    return _error(405, '写操作将在切片 3 开放：$method $path', code: 'read_only');
  }

  final Map<String, Object?> meta = <String, Object?>{'data_dir': dataDir};
  final Map<String, Object?> scope = <String, Object?>{'team_id': teamId};
  final ProductionStore store = ProductionStore(
    dataRoot: dataDir,
    teamId: teamId,
  );

  if (_matches(linesPattern, path)) {
    return _ok(service.handle('production.line.list', params, meta, scope));
  }
  if (_matches(linePattern, path)) {
    final String lineId = _pathParam(linePattern, path, 'lineId');
    return _ok(
      service.handle('production.line.get', <String, Object?>{
        'line_id': lineId,
      }, meta, scope),
    );
  }
  if (_matches(tasksPattern, path)) {
    final String lineId = _pathParam(tasksPattern, path, 'lineId');
    final String status = _queryOf(query, 'status');
    return _ok(
      service.handle('production.task.list', <String, Object?>{
        'line_id': lineId,
        if (status.isNotEmpty) 'status': status,
      }, meta, scope),
    );
  }
  if (_matches(taskPattern, path)) {
    final String lineId = _pathParam(taskPattern, path, 'lineId');
    final String taskId = _pathParam(taskPattern, path, 'taskId');
    return _ok(
      service.handle('production.task.get', <String, Object?>{
        'line_id': lineId,
        'task_id': taskId,
      }, meta, scope),
    );
  }
  if (_matches(runsPattern, path)) {
    final String lineId = _pathParam(runsPattern, path, 'lineId');
    final String taskId = _queryOf(query, 'task_id');
    return _ok(
      service.handle('production.run.list', <String, Object?>{
        'line_id': lineId,
        if (taskId.isNotEmpty) 'task_id': taskId,
      }, meta, scope),
    );
  }
  if (_matches(artifactsPattern, path)) {
    final String lineId = _pathParam(artifactsPattern, path, 'lineId');
    return _ok(_artifacts(store, lineId));
  }
  if (_matches(auditPattern, path)) {
    final String lineId = _pathParam(auditPattern, path, 'lineId');
    // REST 是只读面：`write=false` 只出报告，不落 audit.md（落盘留给切片 3 的写接口）。
    return _ok(
      await audit.handle('production.audit.run', <String, Object?>{
        'line_id': lineId,
        'write': false,
      }, meta, scope),
    );
  }
  return _error(404, '未知产线路由：$path', code: 'not_found');
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
