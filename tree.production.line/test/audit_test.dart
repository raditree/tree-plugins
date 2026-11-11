import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

/// P6 项目整理：TODO 台账 / 文档审计 / 冗余候选 / 只读报告。
void main() {
  group('审计纯逻辑', () {
    test('TODO 台账：只认大写标记，行号 1 起，正文去空白', () {
      final List<AuditTodo> todos = auditTodosOf(
        'lib/a.dart',
        '// TODO: 收尾\nclass A {}\n  // FIXME 边界 \n// todo 不算\n',
      );
      expect(todos, hasLength(2));
      expect(todos.first.path, 'lib/a.dart');
      expect(todos.first.line, 1);
      expect(todos.first.marker, 'TODO');
      expect(todos.first.text, '// TODO: 收尾');
      expect(todos.last.marker, 'FIXME');
      expect(todos.last.line, 3);
    });

    test('FNV-1a：同内容同摘要，异内容异摘要，固定 16 位', () {
      final String a = auditDigest(<int>[1, 2, 3, 4]);
      expect(a, auditDigest(<int>[1, 2, 3, 4]));
      expect(a, isNot(auditDigest(<int>[1, 2, 3, 5])));
      expect(a.length, 16);
    });

    test('重复组：≥ 1 KiB 且 ≥ 2 个路径；按体积降序', () {
      final List<AuditDuplicate> groups = auditDuplicatesOf(
        <String, List<String>>{
          'd1': <String>['b.txt', 'a.txt'],
          'd2': <String>['small.txt'],
          'd3': <String>['big_b.txt', 'big_a.txt'],
        },
        <String, int>{'d1': 2048, 'd2': 10, 'd3': 4096},
      );
      expect(groups, hasLength(2));
      expect(groups.first.digest, 'd3');
      expect(groups.first.paths, <String>['big_a.txt', 'big_b.txt']);
      expect(groups.last.digest, 'd1');
    });

    test('超大文件：按体积降序；报告 schema 固定 9 键', () {
      final List<Map<String, Object?>> large = auditLargeFilesOf(
        <String, int>{
          'a.dart': kAuditLargeFileBytes,
          'b.dart': kAuditLargeFileBytes * 2,
          'c.dart': kAuditLargeFileBytes - 1,
        },
      );
      expect(large, hasLength(2));
      expect(large.first['path'], 'b.dart');

      final AuditReport report = AuditReport(
        lineId: 'pl_x',
        taskId: '',
        generatedAt: '2026-11-10T10:00:00',
        workspace: '/ws',
        scanned: 1,
        skipped: 0,
        totalBytes: 10,
        docsChecked: <String>['docs/work-log.md'],
        docsMissing: <String>[],
        todos: const <AuditTodo>[
          AuditTodo(
            path: 'lib/a.dart',
            line: 1,
            marker: 'TODO',
            text: '// TODO',
          ),
        ],
        duplicates: const <AuditDuplicate>[],
        largeFiles: const <Map<String, Object?>>[],
        notes: const <String>[],
      );
      final Map<String, Object?> json = report.toJson();
      expect(json.keys.toSet(), <String>{
        'version',
        'line_id',
        'task_id',
        'generated_at',
        'workspace',
        'files',
        'docs',
        'todos',
        'redundancy',
        'notes',
      });
      expect(json['version'], 1);
      expect((json['files'] as Map<String, Object?>).keys.toSet(), <String>{
        'scanned',
        'skipped',
        'bytes',
      });
      expect((json['docs'] as Map<String, Object?>).keys.toSet(), <String>{
        'checked',
        'missing',
      });
      expect(
        (json['redundancy'] as Map<String, Object?>).keys.toSet(),
        <String>{'duplicates', 'large_files'},
      );
      final String text = renderAuditMd(report);
      expect(text, contains('## 文档审计'));
      expect(text, contains('## TODO 台账'));
      expect(text, contains('## 冗余候选'));
    });
  });

  group('production.audit.run', () {
    late Directory temp;
    late String workspace;
    late ProductionStore store;
    late ProductionAuditService service;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('tree_production_p6_');
      workspace = p.join(temp.path, 'ws');
      Directory(workspace).createSync(recursive: true);
      store = ProductionStore(dataRoot: temp.path);
      service = ProductionAuditService(environment: const <String, String>{});
      store.createLine(<String, Object?>{
        'id': 'pl_a',
        'name': '整理产线',
        'workspace_dir': workspace,
      });
    });

    tearDown(() {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<Map<String, Object?>> call(
      Map<String, Object?> arguments, {
      String team = 'team_a',
    }) => service.handle(
      'production.audit.run',
      arguments,
      <String, Object?>{'data_dir': temp.path},
      <String, Object?>{'team_id': team},
    );

    void writeFile(String relative, String content) {
      final File file = File(
        p.joinAll(<String>[workspace, ...relative.split('/')]),
      );
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(content);
    }

    List<String> workspaceFiles() => <String>[
      for (final FileSystemEntity entity in Directory(workspace).listSync(
        recursive: true,
      ))
        if (entity is File)
          p.relative(entity.path, from: workspace).replaceAll('\\', '/'),
    ]..sort();

    test('固定 schema + 四块内容；唯一写入是项目资产里的 audit.md', () async {
      writeFile('lib/todo.dart', '// TODO: 收尾\n// HACK 临时\nclass X {}');
      writeFile('lib/a.txt', 'x' * 2048);
      writeFile('lib/b.txt', 'x' * 2048);
      writeFile('lib/big.txt', 'y' * (kAuditLargeFileBytes + 10));
      writeFile('lib/skip.bin', 'z');
      final List<String> before = workspaceFiles();

      final Map<String, Object?> result = await call(<String, Object?>{
        'line_id': 'pl_a',
      });
      final Map<String, Object?> report =
          result['report'] as Map<String, Object?>;
      expect(result['written'], true);
      expect(
        result['artifact'],
        'docs/production_lines/pl_a/audit.md',
      );
      expect(report['version'], 1);
      final List<Object?> todos = report['todos'] as List<Object?>;
      expect(todos.length, 2);
      expect((todos.first as Map<String, Object?>)['path'], 'lib/todo.dart');
      final Map<String, Object?> docs = report['docs'] as Map<String, Object?>;
      expect(
        (docs['missing'] as List<Object?>).length,
        4,
        reason: '默认项目记忆清单 4 份都不在工作空间',
      );
      final Map<String, Object?> redundancy =
          report['redundancy'] as Map<String, Object?>;
      expect(
        ((redundancy['duplicates'] as List<Object?>).single
            as Map<String, Object?>)['size'],
        2048,
      );
      expect(
        ((redundancy['large_files'] as List<Object?>).single)
            as Map<String, Object?>,
        containsPair('path', 'lib/big.txt'),
      );

      final List<String> after = workspaceFiles();
      final Set<String> added = after.toSet().difference(before.toSet());
      expect(added, <String>{'docs/production_lines/pl_a/audit.md'});
      expect(after.toSet().containsAll(before), isTrue, reason: '不删不改已有文件');
      final File audit = File(p.join(workspace, added.single));
      expect(audit.readAsStringSync(), contains('## TODO 台账'));
    });

    test('依赖 / 缓存目录不参与扫描（整理报告不再拖成 504）', () async {
      writeFile('src/keep.dart', '// TODO: keep');
      writeFile('.venv/lib/site.py', '// TODO: skip');
      writeFile('.pub-cache/pkg/x.md', '# TODO skip');
      writeFile('node_modules/pkg/y.js', '// TODO skip');
      writeFile('dist/bundle.js', '// TODO skip');

      final Map<String, Object?> result = await call(<String, Object?>{
        'line_id': 'pl_a',
        'write': false,
      });
      final Map<String, Object?> report =
          result['report'] as Map<String, Object?>;
      final Map<String, Object?> files =
          report['files'] as Map<String, Object?>;
      expect(files['scanned'], 1);
      final List<Object?> todos = report['todos'] as List<Object?>;
      expect(
        todos.map((Object? item) => (item as Map<String, Object?>)['path']),
        <String>['src/keep.dart'],
      );
    });

    test('分批续扫：每批 1 个文件，跨调用累积，最后一批才落 audit.md', () async {
      writeFile('a/one.dart', '// TODO: one');
      writeFile('a/two.dart', '// TODO: two');
      final ProductionAuditService batched = ProductionAuditService(
        environment: const <String, String>{},
        filesPerRun: 1,
      );
      Future<Map<String, Object?>> step() => batched.handle(
        'production.audit.run',
        <String, Object?>{'line_id': 'pl_a'},
        <String, Object?>{'data_dir': temp.path},
        <String, Object?>{'team_id': 'team_a'},
      );

      final Map<String, Object?> first = await step();
      expect((first['progress'] as Map<String, Object?>)['done'], isFalse);
      expect(first['written'], isFalse);
      expect(
        File(
          p.join(
            workspace,
            'docs',
            'production_lines',
            'pl_a',
            'audit.md',
          ),
        ).existsSync(),
        isFalse,
        reason: '未扫完不落 audit.md',
      );

      final Map<String, Object?> second = await step();
      expect((second['progress'] as Map<String, Object?>)['done'], isTrue);
      expect(second['written'], isTrue);
      final Map<String, Object?> report =
          second['report'] as Map<String, Object?>;
      expect((report['files'] as Map<String, Object?>)['scanned'], 2);
      expect((report['todos'] as List<Object?>).length, 2);
    });

    test('write=false 纯查询：不写 audit.md', () async {
      writeFile('lib/a.dart', 'void a() {}\n');
      final Map<String, Object?> result = await call(<String, Object?>{
        'line_id': 'pl_a',
        'write': false,
      });
      expect(result['written'], false);
      expect(result['artifact'], '');
      expect(
        File(
          p.join(
            workspace,
            'docs',
            'production_lines',
            'pl_a',
            'audit.md',
          ),
        ).existsSync(),
        isFalse,
      );
    });

    test('显式 task_id 必须存在；缺团队仍可扫描（全局作用域）', () async {
      writeFile('lib/a.dart', 'void a() {}\n');
      await expectLater(
        call(<String, Object?>{'line_id': 'pl_a', 'task_id': 'nope'}),
        throwsA(
          isA<ProductionFailure>().having(
            (ProductionFailure e) => e.code,
            'code',
            'not_found',
          ),
        ),
      );
      final Map<String, Object?> noTeam = await call(
        <String, Object?>{'line_id': 'pl_a'},
        team: '',
      );
      expect(noTeam['report'], isA<Map<String, Object?>>());
    });

    test('工作空间不存在：workspace_unavailable', () async {
      store.createLine(<String, Object?>{
        'id': 'pl_missing',
        'name': '没有目录',
        'workspace_dir': p.join(temp.path, 'no_such_dir'),
      });
      await expectLater(
        call(<String, Object?>{'line_id': 'pl_missing'}),
        throwsA(
          isA<ProductionFailure>().having(
            (ProductionFailure e) => e.code,
            'code',
            'workspace_unavailable',
          ),
        ),
      );
    });

    test('未配置 memory_manifest：文档审计为空并留说明', () async {
      store.createLine(<String, Object?>{
        'id': 'pl_no_manifest',
        'name': '空清单',
        'workspace_dir': workspace,
        'docs': <String, Object?>{'memory_manifest': <String>[]},
      });
      final Map<String, Object?> result = await call(<String, Object?>{
        'line_id': 'pl_no_manifest',
        'write': false,
      });
      final Map<String, Object?> report =
          result['report'] as Map<String, Object?>;
      final Map<String, Object?> docs =
          report['docs'] as Map<String, Object?>;
      expect(docs['checked'], isEmpty);
      expect(docs['missing'], isEmpty);
      expect(
        (report['notes'] as List<Object?>).join('\n'),
        contains('memory_manifest'),
      );
    });
  });
}
