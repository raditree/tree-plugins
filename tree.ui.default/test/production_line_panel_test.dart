import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree_ui_default/io/api_service.dart';
import 'package:tree_ui_default/ui/widgets/create_production_line_dialog.dart';
import 'package:tree_ui_default/ui/widgets/model_info_panel.dart';
import 'package:tree_ui_default/ui/widgets/production_line_model_info_panel.dart';
import 'package:tree_ui_default/ui/widgets/production_line_panel.dart';
import 'package:tree_ui_default/ui/widgets/production_line_workbench.dart';

/// 假核心：实现产线 REST（读 + 写）+ 配置页要用的 Agent / 模型池。
class _FakeCore {
  _FakeCore._(this._http);

  final HttpServer _http;

  /// 非 0 时所有请求按该状态码回 `detail`（模拟插件未安装 / 停用）。
  int failStatus = 0;
  String failDetail = '插件 tree.production.line 未安装';

  /// 任务列表里的状态（对齐 / 拍板用例用）。
  String taskStatus = 'queued';

  /// 整理报告：是否已完成 + 最近一次请求的 limit（续扫用例）。
  bool auditDone = true;
  int auditLimit = -1;

  /// `METHOD /path` 调用流水（断言写接口有没有真的被调用）。
  final List<String> calls = <String>[];

  /// `METHOD /path` → 请求体（同路径多次调用以最后一次为准）。
  final Map<String, Map<String, dynamic>> bodies =
      <String, Map<String, dynamic>>{};

  Map<String, dynamic> bodyOf(String method, String path) =>
      bodies['$method $path'] ?? <String, dynamic>{};

  final List<Map<String, dynamic>> _lines = <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'pl_1',
      'name': '标准开发流',
      'status': 'working',
      'workspace_dir': 'E:/work/demo',
    },
  ];

  static Future<_FakeCore> start() async {
    final HttpServer http = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _FakeCore core = _FakeCore._(http);
    http.listen(core._handle);
    return core;
  }

  String get baseUrl => 'http://127.0.0.1:${_http.port}';

  Future<void> close() => _http.close(force: true);

  bool called(String method, String path) => calls.contains('$method $path');

  Future<void> _handle(HttpRequest request) async {
    final String method = request.method;
    final String path = request.uri.path;
    final String raw = await utf8.decoder.bind(request).join();
    calls.add('$method $path');
    Map<String, dynamic> body = <String, dynamic>{};
    if (raw.trim().isNotEmpty) {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) {
        body = decoded.map(
          (Object? key, Object? value) =>
              MapEntry<String, dynamic>('$key', value),
        );
      }
    }
    bodies['$method $path'] = body;
    final Map<String, dynamic> lastBody = body;
    if (failStatus != 0) {
      request.response.statusCode = failStatus;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(<String, dynamic>{
        'detail': failDetail,
      }));
      await request.response.close();
      return;
    }
    Map<String, dynamic> payload = <String, dynamic>{'success': true};
    if (path == '/api/agents' && method == 'GET') {
      payload = <String, dynamic>{
        'agents': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'agt_1', 'name': '樾深'},
          <String, dynamic>{
            'id': 'agt_2',
            'name': '成员',
            'team_id': 'agt_1',
          },
        ],
      };
    } else if (path == '/api/models' && method == 'GET') {
      payload = <String, dynamic>{
        'models': <Map<String, dynamic>>[
          <String, dynamic>{
            'model_id': 'lfm3',
            'name': 'LFM3',
            'kind': 'chat',
          },
          // D5/D6：provider 模型 + 端点声明（模态 / 上下文 / 输出）。
          <String, dynamic>{
            'model_id': 'm1',
            'provider': 'demo',
            'key': 'demo/m1',
            'name': '演示模型',
            'kind': 'chat',
            'max_seqlen': 32000,
            'max_output_tokens': 4096,
            'if_vision': true,
          },
        ],
      };
    } else if (path == '/api/production/migrate' && method == 'POST') {
      payload = <String, dynamic>{
        'scope': 'production',
        'migrated_count': 1,
        'migrated': <Object?>[],
        'conflicts': <Object?>[],
        'skipped': <Object?>[],
        'note': '已迁移 1 条；冲突 0 条；跳过 0 条',
      };
    } else if (path == '/api/production/lines' && method == 'GET') {
      payload = <String, dynamic>{
        'lines': List<Map<String, dynamic>>.of(_lines),
        'count': _lines.length,
      };
    } else if (path == '/api/production/lines' && method == 'POST') {
      final Map<String, dynamic> line = <String, dynamic>{
        'id': 'pl_${_lines.length + 1}',
        'name': lastBody['name'],
        'status': 'idle',
        'workspace_dir': lastBody['workspace_dir'] ?? '',
        if (lastBody['executor'] is Map)
          'executor': lastBody['executor'] as Map<String, dynamic>,
      };
      _lines.add(line);
      payload = <String, dynamic>{'line': line};
    } else if (path.startsWith('/api/production/lines/') &&
        method == 'PATCH') {
      final String id = path.split('/')[4];
      for (final Map<String, dynamic> line in _lines) {
        if ('${line['id']}' == id) {
          line.addAll(lastBody);
          payload = <String, dynamic>{'line': line};
          break;
        }
      }
    } else if (path.endsWith('/questions') && method == 'GET') {
      payload = <String, dynamic>{
        'open': <Map<String, dynamic>>[
          <String, dynamic>{
            'qid': 'Q1',
            'text': '选哪个实现',
            'default': 'A',
            'recommended': 'A',
            'consequence': '影响后续拆分',
          },
        ],
        'limit': 3,
      };
    } else if (path.endsWith('/decision') && method == 'POST') {
      payload = <String, dynamic>{'open': 0, 'ready': true};
    } else if (path.endsWith('/dispatch') && method == 'POST') {
      payload = <String, dynamic>{
        'accepted': true,
        'stage': lastBody['stage'] ?? 'auto',
      };
    } else if (path.endsWith('/cancel') && method == 'POST') {
      payload = <String, dynamic>{
        'task': <String, dynamic>{'id': 'T1', 'status': 'cancelled'},
      };
    } else if (path.endsWith('/tasks') && method == 'GET') {
      payload = <String, dynamic>{
        'tasks': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'T1',
            'title': '底座',
            'status': taskStatus,
            'write_scope': <String>['lib/'],
          },
        ],
        'count': 1,
      };
    } else if (path.endsWith('/runs')) {
      payload = <String, dynamic>{
        'runs': <Map<String, dynamic>>[
          <String, dynamic>{
            'run_id': 'r1',
            'task_id': 'T1',
            'role': 'packer',
            'status': 'done',
          },
        ],
        'count': 1,
      };
    } else if (path.endsWith('/audit')) {
      auditLimit =
          int.tryParse(request.uri.queryParameters['limit'] ?? '') ?? -1;
      payload = <String, dynamic>{
        'report': <String, dynamic>{
          'scanned': 2,
          'todos': <Object?>[],
          'docs_missing': <Object?>[],
          'duplicates': <Object?>[],
          'large_files': <Object?>[],
          'notes': <Object?>[],
        },
        'written': false,
        'progress': <String, dynamic>{
          'done': auditDone,
          'index': 2,
          'total': 5,
          'percent': 40,
          'batch': auditLimit > 0 ? auditLimit : 500,
        },
      };
    }
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(payload));
    await request.response.close();
  }
}

/// 左栏列表 + 中栏工作台的组合（与 main_page 的接法一致）。
class _Harness extends StatefulWidget {
  const _Harness({required this.teamId, required this.agentId});

  final String teamId;
  final String agentId;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  Map<String, dynamic>? _line;
  int _refreshToken = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: <Widget>[
          SizedBox(
            width: 300,
            height: 720,
            child: ProductionLinePanel(
              teamId: widget.teamId,
              agentId: widget.agentId,
              selectedLineId: '${_line?['id'] ?? ''}',
              refreshToken: _refreshToken,
              onSelectLine: (Map<String, dynamic>? line) {
                setState(() => _line = line);
              },
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: ProductionLineWorkbench(
              key: ValueKey<String>('workbench-${_line?['id'] ?? ''}'),
              line: _line,
              teamId: widget.teamId,
              agentId: widget.agentId,
              onDeleted: () {
                setState(() {
                  _line = null;
                  _refreshToken++;
                });
              },
              onLineUpdated: (Map<String, dynamic> line) {
                setState(() {
                  _line = line;
                  _refreshToken++;
                });
              },
            ),
          ),
        ],
      ),
    );
  }
}

void main() {
  late _FakeCore core;

  setUp(() async {
    HttpOverrides.global = null;
    core = await _FakeCore.start();
    ApiService.baseUrl = core.baseUrl;
    ApiService.setToken('test-token');
  });

  tearDown(() async {
    await core.close();
    ApiService.setToken(null);
    ApiService.baseUrl = 'http://127.0.0.1:0';
  });

  Widget harness({String teamId = 'team_a', String agentId = 'agt_1'}) =>
      MaterialApp(
        home: _Harness(teamId: teamId, agentId: agentId),
      );

  Future<void> flyIO(WidgetTester tester, {int rounds = 6}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
  }

  /// 等到某个 Finder 出现（写操作后要等一次真实 HTTP 往返）。
  Future<void> waitFor(
    WidgetTester tester,
    Finder finder, {
    int rounds = 40,
  }) async {
    for (int i = 0; i < rounds; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await flyIO(tester, rounds: 1);
    }
  }

  Future<void> openLine(WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await flyIO(tester);
    await tester.tap(find.text('标准开发流'));
    await flyIO(tester);
  }

  Future<void> openTaskMenu(WidgetTester tester, String action) async {
    await tester.tap(find.byKey(const Key('production-task-menu-T1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(action));
    // 不能用 pumpAndSettle：写操作进行中会转圈（无限动画），永远 settle 不了。
    await flyIO(tester, rounds: 3);
  }

  testWidgets('左栏列表 → 选中后中栏显示任务队列与运行台账', (WidgetTester tester) async {
    await openLine(tester);

    expect(find.text('任务队列（1）'), findsOneWidget);
    expect(find.textContaining('T1'), findsWidgets);
    expect(find.text('运行台账（1）'), findsOneWidget);
    expect(find.textContaining('packer'), findsOneWidget);
    expect(find.text('写域：lib/'), findsOneWidget);
  });

  testWidgets('未选团队也能列出全局产线', (WidgetTester tester) async {
    await tester.pumpWidget(harness(teamId: ''));
    await flyIO(tester);

    expect(find.text('标准开发流'), findsOneWidget);
    expect(find.textContaining('先在左侧选择一个 Agent'), findsNothing);
  });

  testWidgets('新建产线：配置页写 executor / 角色模型 / 执行工具', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(harness());
    await flyIO(tester);

    await tester.tap(find.byKey(const Key('production-line-create')));
    await flyIO(tester);
    await tester.enterText(
      find.byKey(const Key('production-line-name')),
      '新产线',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('production-line-submit')));
    await flyIO(tester, rounds: 10);

    expect(core.called('POST', '/api/production/lines'), isTrue);
    final Map<String, dynamic> body =
        core.bodyOf('POST', '/api/production/lines');
    expect(body['name'], '新产线');
    expect(
      (body['executor'] as Map<String, dynamic>)['agent_id'],
      'agt_1',
    );
    final Map<String, dynamic> roles =
        body['roles'] as Map<String, dynamic>;
    expect(
      (roles['executor'] as Map<String, dynamic>)['model_id'],
      'lfm3',
    );
    expect(
      (roles['executor'] as Map<String, dynamic>)['tools'],
      contains('write'),
    );
    expect(
      (roles['expert'] as Map<String, dynamic>)['enabled'],
      isFalse,
    );

    final Finder created = find.descendant(
      of: find.byKey(const Key('production-line-list')),
      matching: find.text('新产线'),
    );
    await waitFor(tester, created);
    expect(created, findsOneWidget);
  });

  testWidgets('新建产线：预填现有工作空间，并可从目录选择', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await flyIO(tester);

    await tester.tap(find.byKey(const Key('production-line-create')));
    await flyIO(tester);

    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('E:/work/demo'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('production-line-workspace-pick')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('production-line-executor')), findsOneWidget);
    expect(find.byKey(const Key('production-line-submit')), findsOneWidget);
  });

  testWidgets('迁移旧产线：菜单 → 确认 → POST migrate', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await flyIO(tester);

    await tester.tap(find.byKey(const Key('production-line-list-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('迁移旧产线'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('production-migrate-confirm')));
    await flyIO(tester, rounds: 10);

    expect(core.called('POST', '/api/production/migrate'), isTrue);
    expect(
      core.bodyOf('POST', '/api/production/migrate')['agent_id'],
      'agt_1',
    );
  });

  testWidgets('新建任务：写域可选目录 / 文件', (WidgetTester tester) async {
    await openLine(tester);
    await tester.tap(find.byKey(const Key('production-task-create-pl_1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('production-task-scope-dir')), findsOneWidget);
    expect(find.byKey(const Key('production-task-scope-file')), findsOneWidget);
    expect(find.byKey(const Key('production-task-scope')), findsOneWidget);
  });

  testWidgets('整理报告：分批进度 + 继续扫描按输入带上 limit', (
    WidgetTester tester,
  ) async {
    core.auditDone = false;
    await openLine(tester);

    await tester.enterText(
      find.byKey(const Key('production-audit-batch-pl_1')),
      '2',
    );
    await tester.tap(find.text('整理报告'));
    await flyIO(tester);

    expect(find.textContaining('已处理 2 / 5'), findsOneWidget);
    expect(
      find.byKey(const Key('production-audit-continue-pl_1')),
      findsOneWidget,
    );
    expect(core.auditLimit, 2);

    core.auditDone = true;
    await tester.tap(find.byKey(const Key('production-audit-continue-pl_1')));
    await flyIO(tester);
    expect(
      find.byKey(const Key('production-audit-continue-pl_1')),
      findsNothing,
    );
  });

  testWidgets('取消任务：菜单 → 确认 → POST cancel', (WidgetTester tester) async {
    await openLine(tester);
    await openTaskMenu(tester, '取消任务');

    expect(find.textContaining('取消任务 T1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('production-confirm')));
    await flyIO(tester);

    expect(
      core.called('POST', '/api/production/lines/pl_1/tasks/T1/cancel'),
      isTrue,
    );
  });

  testWidgets('派发：菜单 → POST dispatch（带 agent_id）', (WidgetTester tester) async {
    await openLine(tester);
    await openTaskMenu(tester, '打包');
    await flyIO(tester);

    final String call = core.calls.firstWhere(
      (String item) => item.endsWith('/tasks/T1/dispatch'),
      orElse: () => '',
    );
    expect(call, 'POST /api/production/lines/pl_1/tasks/T1/dispatch');
    expect(
      core.bodyOf(
        'POST',
        '/api/production/lines/pl_1/tasks/T1/dispatch',
      )['stage'],
      'pack',
    );
  });

  testWidgets('决策收件箱：拍板 → 全部按推荐 → POST decision', (
    WidgetTester tester,
  ) async {
    core.taskStatus = 'aligning';
    await openLine(tester);

    expect(find.text('决策收件箱（1）'), findsOneWidget);
    await tester.tap(find.byKey(const Key('production-inbox-decide-T1')));
    await flyIO(tester);

    expect(find.text('拍板 · T1'), findsOneWidget);
    expect(find.textContaining('Q1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('production-decide-recommended')));
    await flyIO(tester);

    expect(
      core.called('POST', '/api/production/lines/pl_1/tasks/T1/decision'),
      isTrue,
    );
    expect(
      core.bodyOf(
        'POST',
        '/api/production/lines/pl_1/tasks/T1/decision',
      )['all_recommended'],
      isTrue,
    );
  });

  testWidgets('产线配置：菜单 → 保存 → PATCH（executor / roles）', (
    WidgetTester tester,
  ) async {
    await openLine(tester);
    await tester.tap(find.byKey(const Key('production-line-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('产线配置'));
    await flyIO(tester);

    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.byKey(const Key('production-line-submit')));
    await flyIO(tester, rounds: 10);

    expect(
      core.called('PATCH', '/api/production/lines/pl_1'),
      isTrue,
    );
    final Map<String, dynamic> body =
        core.bodyOf('PATCH', '/api/production/lines/pl_1');
    expect(
      (body['executor'] as Map<String, dynamic>)['agent_id'],
      '',
    );
    expect(body['roles'], isA<Map<String, dynamic>>());
  });

  testWidgets('插件未安装：可读说明 + 重试', (WidgetTester tester) async {
    core.failStatus = 503;
    await tester.pumpWidget(harness());
    await flyIO(tester);

    expect(find.textContaining('未安装 tree.production.line 插件'), findsOneWidget);
    expect(find.byKey(const Key('production-line-retry')), findsOneWidget);

    core.failStatus = 0;
    await tester.tap(find.byKey(const Key('production-line-retry')));
    await flyIO(tester);
    expect(find.text('标准开发流'), findsOneWidget);
    expect(find.textContaining('未安装 tree.production.line 插件'), findsNothing);
  });

  testWidgets('配置页：四张角色卡各带白名单工具 + 专家开关入 roles（D6）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(harness());
    await flyIO(tester);
    await tester.tap(find.byKey(const Key('production-line-create')));
    await flyIO(tester);
    await tester.enterText(
      find.byKey(const Key('production-line-name')),
      '角色产线',
    );

    for (final String role in <String>[
      'orchestrator',
      'packer',
      'executor',
      'expert',
    ]) {
      expect(
        find.byKey(Key('production-line-role-$role')),
        findsOneWidget,
        reason: '每个角色一张卡',
      );
    }
    // 硬边界：打包 / 专家不出现写文件与编辑；执行必须有。
    expect(
      find.byKey(const Key('production-line-tool-packer-write')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('production-line-tool-expert-edit')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('production-line-tool-executor-write')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('production-line-expert-max')), findsNothing);

    await tester.ensureVisible(
      find.byKey(const Key('production-line-expert-enabled')),
    );
    await tester.pumpAndSettle();
    // 配置页在对话框的滚动区里：直接触发组件回调，避免命中测试被滚动/
    // 遮罩干扰（这里钉的是状态与提交体，不是手势本身）。
    final Switch expertSwitch = tester.widget<Switch>(
      find.byKey(const Key('production-line-expert-enabled')),
    );
    expertSwitch.onChanged!(true);
    await tester.pump();
    expect(find.byKey(const Key('production-line-expert-max')), findsOneWidget);

    await tester.tap(find.byKey(const Key('production-line-submit')));
    await flyIO(tester, rounds: 10);

    expect(core.called('POST', '/api/production/lines'), isTrue);
    final Map<String, dynamic> roles =
        core.bodyOf('POST', '/api/production/lines')['roles']
            as Map<String, dynamic>;
    final Map<String, dynamic> expert = roles['expert'] as Map<String, dynamic>;
    expect(expert['enabled'], isTrue);
    expect(expert['max_per_task'], 3);
    final List<dynamic> packerTools =
        (roles['packer'] as Map<String, dynamic>)['tools'] as List<dynamic>;
    expect(packerTools, isNot(contains('write')));
    final List<dynamic> executorTools =
        (roles['executor'] as Map<String, dynamic>)['tools'] as List<dynamic>;
    expect(executorTools, contains('write'));
    final List<dynamic> orchestratorTools =
        (roles['orchestrator'] as Map<String, dynamic>)['tools']
            as List<dynamic>;
    expect(orchestratorTools, containsAll(<String>['read', 'grep', 'message']));
  });

  testWidgets('执行角色缺 write / edit ⇒ 不提交（配置页拦截）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(harness());
    await flyIO(tester);
    await tester.tap(find.byKey(const Key('production-line-create')));
    await flyIO(tester);
    await tester.enterText(
      find.byKey(const Key('production-line-name')),
      '无写权限',
    );

    for (final String tool in <String>['write', 'edit']) {
      final Finder chip = find.byKey(Key('production-line-tool-executor-$tool'));
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      final FilterChip widget = tester.widget<FilterChip>(chip);
      widget.onSelected!(false);
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('production-line-submit')));
    await flyIO(tester, rounds: 4);

    expect(core.called('POST', '/api/production/lines'), isFalse);
    expect(find.textContaining('执行工具至少要有'), findsOneWidget);
  });

  testWidgets('产线上下文模型信息：四角色解析 / 失效标红 / 不请求 Agent（D5）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProductionLineModelInfoPanel(
            line: <String, dynamic>{
              'id': 'pl_model',
              'name': '模型线',
              'roles': <String, dynamic>{
                'orchestrator': <String, dynamic>{
                  'model_id': 'demo/m1',
                  'tools': <String>['read', 'grep'],
                },
                'packer': <String, dynamic>{'model_id': 'ghost/missing'},
                'executor': <String, dynamic>{'model_id': ''},
                'expert': <String, dynamic>{
                  'model_id': '',
                  'enabled': true,
                  'max_per_task': 3,
                  'tools': <String>['read'],
                },
              },
            },
          ),
        ),
      ),
    );
    await flyIO(tester);

    expect(
      core.called('GET', '/api/agents//models-info'),
      isFalse,
      reason: '产线上下文不该拿空 agentId 去请求 Agent 模型信息',
    );
    expect(find.text('演示模型'), findsOneWidget);
    expect(find.text('demo · m1'), findsOneWidget);
    expect(find.text('上下文 32000'), findsOneWidget);
    expect(find.text('输出 4096'), findsOneWidget);
    expect(find.text('image'), findsOneWidget);
    expect(find.text('工具：read、grep'), findsOneWidget);
    expect(find.text('已失效'), findsOneWidget);
    expect(find.text('ghost/missing（模型池里已不存在）'), findsOneWidget);
    expect(find.text('未配置'), findsNWidgets(2));
    expect(find.text('专家：已启用（单任务上限 3）'), findsOneWidget);
  });

  testWidgets('未选 Agent：模型信息空态且不发请求（PL-4）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ModelInfoPanel(agentId: ''))),
    );
    await flyIO(tester);

    expect(find.textContaining('请先在左侧选择或创建一个 Agent'), findsOneWidget);
    expect(
      core.calls.where((String call) => call.contains('/models-info')),
      isEmpty,
      reason: '空 agentId 不能拼出 /api/agents//models-info',
    );
  });

  testWidgets('存量角色模型不在池中 ⇒ 标失效并拦提交（PL-3-C）', (
    WidgetTester tester,
  ) async {
    ProductionLineSpec? spec;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async {
                spec = await showDialog<ProductionLineSpec>(
                  context: context,
                  builder: (_) => const CreateProductionLineDialog(
                    initial: <String, dynamic>{
                      'id': 'pl_stale',
                      'name': '存量产线',
                      'workspace_dir': 'E:/work/demo',
                      'roles': <String, dynamic>{
                        'executor': <String, dynamic>{
                          'model_id': 'ghost/missing',
                        },
                      },
                    },
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await flyIO(tester);

    expect(find.text('ghost/missing（已失效）'), findsOneWidget);
    await tester.tap(find.byKey(const Key('production-line-submit')));
    await flyIO(tester, rounds: 4);

    expect(spec, isNull, reason: '失效模型必须拦下，不产出配置');
    expect(find.textContaining('不在模型池里（已失效）'), findsOneWidget);
  });

  testWidgets('存量非法工具：如实提示，保存时按角色白名单剔除（D6）', (
    WidgetTester tester,
  ) async {
    ProductionLineSpec? spec;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async {
                spec = await showDialog<ProductionLineSpec>(
                  context: context,
                  builder: (_) => const CreateProductionLineDialog(
                    initial: <String, dynamic>{
                      'id': 'pl_legacy',
                      'name': '旧配置',
                      'workspace_dir': 'E:/work/demo',
                      'roles': <String, dynamic>{
                        'packer': <String, dynamic>{
                          'model_id': 'lfm3',
                          'tools': <String>['read', 'write'],
                        },
                        'executor': <String, dynamic>{'model_id': 'lfm3'},
                      },
                    },
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await flyIO(tester);

    expect(
      find.textContaining('已忽略非本角色允许的工具：write'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('production-line-submit')));
    await flyIO(tester, rounds: 4);

    expect(spec, isNotNull);
    final Map<String, dynamic> roles =
        spec!.roles['packer'] as Map<String, dynamic>;
    expect(roles['tools'], isNot(contains('write')));
  });
}
