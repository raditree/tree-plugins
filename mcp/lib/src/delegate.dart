import 'dart:async';
import 'dart:convert';

import 'routes.dart';
import 'service.dart';

/// 处理一次 `api/delegate`（核心 → 插件）。
///
/// 信封字段与 tree.agent 同契约：`method / path / params / query / headers /
/// scope / workspace_dir / data_dir / agent_id / team_id / request_id`，
/// 小体积 JSON 用 `body`。回包固定为 `{status, headers?, body?}`，
/// **`body` 是字符串**（核心按 Content-Type 原样写回 HTTP）。
///
/// 未实现的路由回 501 + 可读原因——委派语义里 404 表示"核心没有这个接口"，
/// 而这里是"插件还没搬"。
Future<Map<String, dynamic>> handleApiDelegate(
  Map<String, dynamic> envelope, {
  required McpService service,
}) {
  // 读循环对每条请求各起一个异步任务（铁律 2），所以同一插件的两条委派
  // 可能并发。配置的「先注册后删除」若并发落盘，最后写盘的那次会决定文件
  // 内容（现场：DELETE 已回 200，文件里却还是被覆盖回来的旧服务）。
  // 这里按**到达顺序**串成一条队列：三条路由都是低频配置操作，串行代价可忽略。
  final Completer<Map<String, dynamic>> completer =
      Completer<Map<String, dynamic>>();
  _delegateQueue = _delegateQueue.then((_) async {
    try {
      completer.complete(await _handleGuarded(envelope, service));
    } catch (error, stack) {
      completer.completeError(error, stack);
    }
  });
  return completer.future;
}

Future<void> _delegateQueue = Future<void>.value();

Future<Map<String, dynamic>> _handleGuarded(
  Map<String, dynamic> envelope,
  McpService service,
) async {
  try {
    return await _dispatch(envelope, service);
  } catch (error) {
    return _jsonReply(500, <String, dynamic>{'detail': 'mcp 插件内部错误：$error'});
  }
}

Future<Map<String, dynamic>> _dispatch(
  Map<String, dynamic> envelope,
  McpService service,
) async {
  final String method = _str(envelope['method']).toUpperCase();
  final String path = _str(envelope['path']);
  final String dataDir = _str(envelope['data_dir']);
  final Map<String, dynamic> params = _map(envelope['params']);
  if (dataDir.isEmpty) {
    return _jsonReply(500, <String, dynamic>{
      'detail': '委派信封缺少 data_dir（核心契约不完整）',
    });
  }
  // 数据根是配置的唯一权威；同一数据根的重复请求是幂等的。
  await service.attach(dataDir);

  // ── GET /api/mcp/services：列表 + 已发现工具 + 各服务错误 ──────────
  if (method == 'GET' && path == mcpServicesPattern) {
    await service.syncConnections();
    return _jsonReply(200, service.listPayload());
  }

  // ── POST /api/mcp/services：注册（或覆盖）并只连它自己 ─────────────
  if (method == 'POST' && path == mcpServicesPattern) {
    final Map<String, dynamic> body;
    try {
      body = _bodyOf(envelope);
    } on FormatException catch (error) {
      return _jsonReply(400, <String, dynamic>{'detail': '$error'});
    }
    final Map<String, dynamic> result = await service.register(body);
    final String error = _str(result['error']);
    if (error.isNotEmpty) {
      return _jsonReply(400, <String, dynamic>{'detail': error});
    }
    return _jsonReply(200, result);
  }

  // ── DELETE /api/mcp/services/{name}：删除（内置/环境变量注入项拒删）──
  if (method == 'DELETE' && _matches(mcpServicePattern, path)) {
    final Map<String, dynamic> result = await service.remove(
      _str(params['name']),
    );
    final String error = _str(result['error']);
    if (error.isNotEmpty) {
      return _jsonReply(404, <String, dynamic>{'detail': error});
    }
    return _jsonReply(200, result);
  }

  return _jsonReply(501, <String, dynamic>{
    'detail': 'mcp 插件尚未实现该路由：$method $path',
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

/// 从委派信封取 JSON body（小体积内联字符串或 Map；缺失/空 = 空表）。
Map<String, dynamic> _bodyOf(Map<String, dynamic> envelope) {
  final Object? raw = envelope['body'];
  if (raw is Map) return _map(raw);
  if (raw is String && raw.trim().isNotEmpty) {
    final Object? decoded = jsonDecode(raw);
    if (decoded is Map) return _map(decoded);
    throw const FormatException('请求体不是 JSON 对象');
  }
  return <String, dynamic>{};
}

Map<String, dynamic> _jsonReply(int status, Map<String, dynamic> body) =>
    <String, dynamic>{
      'status': status,
      'headers': <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
      'body': jsonEncode(body),
    };

Map<String, dynamic> _map(Object? value) => value is Map
    ? value.map((Object? key, Object? item) => MapEntry(key.toString(), item))
    : <String, dynamic>{};

String _str(Object? value) => (value ?? '').toString().trim();
