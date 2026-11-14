import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree_ui_default/io/api_service.dart';
import 'package:tree_ui_default/io/attachment_upload_service.dart';
import 'package:tree_ui_default/io/protocol_contract.dart';
import 'package:tree_ui_default/ui/widgets/production_line_workbench.dart';

import 'production_ui_fakes.dart';

void main() {
  late ProductionFakeCore core;
  late Directory temp;

  setUp(() async {
    HttpOverrides.global = null;
    core = await ProductionFakeCore.start();
    ApiService.baseUrl = core.baseUrl;
    ApiService.setToken('test-token');
    temp = Directory.systemTemp.createTempSync('tree_production_ui_');
    core.tasks = <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'T1',
        'title': '打包过的任务',
        'status': 'packed',
        'brief': '旧内容',
        'acceptance': <String>['旧验收'],
        'write_scope': <String>['lib/'],
        'task_type': 'code',
      },
      <String, dynamic>{
        'id': 'T6',
        'title': '待派发任务',
        'status': 'queued',
        'brief': '等派发',
        'acceptance': <String>['可派发'],
        'write_scope': <String>['lib/run/'],
      },
    ];
  });

  tearDown(() async {
    await core.close();
    ApiService.setToken(null);
    ApiService.baseUrl = 'http://127.0.0.1:0';
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<void> flyIO(WidgetTester tester, {int rounds = 10}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
  }

  Widget harness() => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 1000,
        height: 720,
        child: ProductionLineWorkbench(
          line: <String, dynamic>{
            'id': 'pl_1',
            'name': '标准开发流',
            'status': 'working',
            'workspace_dir': 'E:/work/demo',
          },
          teamId: 'team_a',
          deliveries: const Stream<StationDelivery>.empty(),
          pollInterval: const Duration(days: 1),
        ),
      ),
    ),
  );

  testWidgets('编辑任务：PATCH 输入字段；packed 提示回队列并失效旧包', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(harness());
    await flyIO(tester);

    await tester.tap(find.byKey(const Key('production-task-menu-T1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑任务'));
    await tester.pumpAndSettle();

    expect(find.textContaining('旧 pack.json 失效'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('production-task-brief')),
      '新的任务内容',
    );
    await tester.enterText(
      find.byKey(const Key('production-task-acceptance')),
      '新验收一\n新验收二',
    );
    await tester.tap(find.byKey(const Key('production-task-save')));
    await flyIO(tester, rounds: 14);

    expect(
      core.called('PATCH', '/api/production/lines/pl_1/tasks/T1'),
      isTrue,
    );
    final Map<String, dynamic> body = core.bodyOf(
      'PATCH',
      '/api/production/lines/pl_1/tasks/T1',
    );
    expect(body['brief'], '新的任务内容');
    expect(body['acceptance'], <String>['新验收一', '新验收二']);
    expect(body['write_scope'], <String>['lib/']);
  });

  testWidgets('附件：先上传到工作空间，再 POST attachments（source/name/type）', (
    WidgetTester tester,
  ) async {
    final File file = File('${temp.path}/design.png')
      ..writeAsStringSync('not-a-real-png');
    late List<Map<String, dynamic>> uploaded;
    late String source;
    await tester.runAsync(() async {
      uploaded = await AttachmentUploadService.uploadAll('line:pl_1', <String>[
        file.path,
      ]);
      source = '${uploaded.first['path']}';
      await ApiService.attachProductionTask(
        'pl_1',
        'T1',
        source: source,
        name: '${uploaded.first['name']}',
        teamId: 'team_a',
      );
    });
    expect(uploaded, hasLength(1));
    expect(source, startsWith('.input/'));

    expect(
      core.called(
        'POST',
        '/api/production/lines/pl_1/tasks/T1/attachments',
      ),
      isTrue,
    );
    final Map<String, dynamic> body = core.bodyOf(
      'POST',
      '/api/production/lines/pl_1/tasks/T1/attachments',
    );
    expect(body['source'], source);
    expect(body['name'], 'design.png');
  });

  testWidgets('批量派发：dry run 发 dry_run=true 并显示 skipped 写域原因', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(harness());
    await flyIO(tester);

    await tester.tap(find.byKey(const Key('production-tab-execution')));
    await flyIO(tester);
    await tester.tap(find.byKey(const Key('production-bulk-dry-pl_1')));
    await flyIO(tester);

    expect(
      core.called('POST', '/api/production/lines/pl_1/dispatch'),
      isTrue,
    );
    expect(
      core.bodyOf('POST', '/api/production/lines/pl_1/dispatch')['dry_run'],
      isTrue,
    );
    expect(find.textContaining('T6'), findsWidgets);
    expect(find.textContaining('写域与 T9 交叠'), findsOneWidget);
    expect(find.textContaining('并行槽位'), findsWidgets);
  });
}
