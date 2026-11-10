import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

/// 切片 2：只读 REST 委派（§10.2 的读半边）。
///
/// 锁住：
/// 1. 申报清单**只有 GET**，写操作一律 405（切片 3 才开放）；
/// 2. 读路由都复用命令门面，不复制业务规则；
/// 3. 数据根 / 团队缺失 fail-closed，未知产线 404；
/// 4. 产物树在"未配 workspace_dir"时给 200 + 空树 + note，不是失败。
void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('production_api_');
  });

  tearDown(() {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  ProductionStore storeWith({String workspaceDir = ''}) {
    final ProductionStore store = ProductionStore(
      dataRoot: temp.path,
      teamId: 'team_a',
    );
    store.createLine(<String, Object?>{
      'id': 'pl_1',
      'name': '标准开发流',
      'workspace_dir': workspaceDir,
    });
    store.createTask('pl_1', <String, Object?>{
      'id': 'T1',
      'title': '底座',
      'status': 'queued',
      'priority': 10,
    });
    return store;
  }

  Map<String, dynamic> envelope(
    String method,
    String path, {
    Map<String, Object?> query = const <String, Object?>{},
    String team = 'team_a',
    String? dataDir,
  }) => <String, dynamic>{
    'method': method,
    'path': path,
    'params': <String, dynamic>{},
    'query': query,
    'headers': <String, dynamic>{},
    'scope': <String, dynamic>{'team_id': team},
    'workspace_dir': '',
    'data_dir': dataDir ?? temp.path,
    'agent_id': '',
    'team_id': team,
    'request_id': 'test-api',
  };

  Future<Map<String, dynamic>> call(
    String method,
    String path, {
    Map<String, Object?> query = const <String, Object?>{},
    String team = 'team_a',
    String? dataDir,
  }) async {
    final Map<String, dynamic> reply = await handleProductionDelegate(
      envelope(method, path, query: query, team: team, dataDir: dataDir),
    );
    return <String, dynamic>{
      'status': reply['status'],
      'json': jsonDecode('${reply['body']}') as Map<String, dynamic>,
    };
  }

  test('申报清单只有 GET（写操作属于切片 3）', () {
    expect(kDeclaredRoutes, isNotEmpty);
    expect(
      kDeclaredRoutes.every(
        (Map<String, String> route) => route['method'] == 'GET',
      ),
      isTrue,
    );
  });

  test('读路由：lines / line / tasks / task / runs', () async {
    storeWith();

    final Map<String, dynamic> lines = await call('GET', linesPattern);
    expect(lines['status'], 200);
    expect((lines['json']['lines'] as List<dynamic>).length, 1);

    final Map<String, dynamic> line = await call(
      'GET',
      '/api/production/lines/pl_1',
    );
    expect(line['json']['line']['name'], '标准开发流');

    final Map<String, dynamic> tasks = await call(
      'GET',
      '/api/production/lines/pl_1/tasks',
      query: <String, Object?>{'status': 'queued'},
    );
    expect(tasks['json']['count'], 1);

    final Map<String, dynamic> task = await call(
      'GET',
      '/api/production/lines/pl_1/tasks/T1',
    );
    expect(task['json']['task']['title'], '底座');

    final Map<String, dynamic> runs = await call(
      'GET',
      '/api/production/lines/pl_1/runs',
    );
    expect(runs['json']['count'], 0);
  });

  test('产物树：未配 workspace_dir ⇒ 200 + 空树 + note', () async {
    storeWith();
    final Map<String, dynamic> artifacts = await call(
      'GET',
      '/api/production/lines/pl_1/artifacts',
    );
    expect(artifacts['status'], 200);
    expect(artifacts['json']['count'], 0);
    expect('${artifacts['json']['note']}', contains('workspace_dir'));
  });

  test('项目整理：GET 只出报告，不落 audit.md', () async {
    final Directory workspace = Directory(p.join(temp.path, 'workspace'))
      ..createSync(recursive: true);
    storeWith(workspaceDir: workspace.path);
    final Map<String, dynamic> audit = await call(
      'GET',
      '/api/production/lines/pl_1/audit',
    );
    expect(audit['status'], 200);
    expect(audit['json']['written'], isFalse);
    expect(audit['json']['artifact'], '');
    expect(audit['json']['report'], isA<Map<String, dynamic>>());
  });

  test('fail-closed 与越界：team / data_dir / 未知产线 / 写操作 / 未知路由', () async {
    storeWith();

    final Map<String, dynamic> noTeam = await call(
      'GET',
      linesPattern,
      team: '',
    );
    expect(noTeam['status'], 400);

    final Map<String, dynamic> noData = await call(
      'GET',
      linesPattern,
      dataDir: '',
    );
    expect(noData['status'], 500);

    final Map<String, dynamic> missing = await call(
      'GET',
      '/api/production/lines/pl_nope',
    );
    expect(missing['status'], 404);

    final Map<String, dynamic> write = await call('POST', linesPattern);
    expect(write['status'], 405);

    final Map<String, dynamic> unknown = await call(
      'GET',
      '/api/production/unknown',
    );
    expect(unknown['status'], 404);
  });
}
