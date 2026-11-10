import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

/// P4 纯领域：片段包解析、写域判据、门控命令与渲染。
void main() {
  group('parsePackJson', () {
    test('有效片段包：路径规范化、行区间兜底', () {
      final PackSpec pack = parsePackJson(<String, Object?>{
        'files': <Object?>[
          <String, Object?>{
            'path': './lib\\a.dart',
            'start_line': 3,
            'end_line': 5,
            'content': 'class A {}',
          },
          <String, Object?>{
            'path': 'lib/b.dart',
            'snippet': 'void b() {}',
          },
        ],
        'baseline': <Object?>[
          <String, Object?>{'command': 'dart analyze'},
          'dart test',
        ],
        'risks': <String>['依赖未就绪'],
        'dependencies': <String>['T1'],
      });
      expect(pack.files.length, 2);
      expect(pack.files.first.path, 'lib/a.dart');
      expect(pack.files.first.startLine, 3);
      expect(pack.files.first.endLine, 5);
      expect(pack.files[1].content, 'void b() {}');
      expect(pack.files[1].startLine, 0);
      expect(pack.baseline.map((PackCommand c) => c.command), <String>[
        'dart analyze',
        'dart test',
      ]);
      expect(pack.risks, <String>['依赖未就绪']);
    });

    test('空文件 = 打包失败；绝对路径 / 越界路径 / 空内容都拒绝', () {
      expect(
        () => parsePackJson(<String, Object?>{'files': <Object?>[]}),
        throwsA(
          isA<ProductionFailure>().having(
            (ProductionFailure e) => e.code,
            'code',
            'pack_incomplete',
          ),
        ),
      );
      for (final Map<String, Object?> file in <Map<String, Object?>>[
        <String, Object?>{'path': '/etc/passwd', 'content': 'x'},
        <String, Object?>{'path': '../a.dart', 'content': 'x'},
        <String, Object?>{'path': 'lib/a.dart', 'content': '   '},
      ]) {
        expect(
          () => parsePackJson(<String, Object?>{
            'files': <Object?>[file],
          }),
          throwsA(isA<ProductionFailure>()),
          reason: '${file['path']}',
        );
      }
    });
  });

  group('写域判据', () {
    test('文件全等 / 目录前缀 / glob / 问号', () {
      expect(matchesWriteScope('lib/a.dart', 'lib/a.dart'), isTrue);
      expect(matchesWriteScope('lib/a.dart', 'lib/'), isTrue);
      expect(matchesWriteScope('lib/ui/a.dart', 'lib/ui'), isTrue);
      expect(matchesWriteScope('lib/ui/a.dart', 'lib/io'), isFalse);
      expect(matchesWriteScope('lib/ui/a.dart', 'lib/**/a.dart'), isTrue);
      expect(matchesWriteScope('lib/a.dart', 'lib/*.dart'), isTrue);
      expect(matchesWriteScope('lib/ui/a.dart', 'lib/*.dart'), isFalse);
      expect(matchesWriteScope('lib/a.dart', 'lib/?.dart'), isTrue);
    });

    test('越界与禁区都单独回报', () {
      final List<String> changed = <String>[
        'lib/a.dart',
        'lib/b.dart',
        '.env',
      ];
      expect(
        writeScopeViolations(changed, <String>['lib/a.dart']),
        <String>['lib/b.dart', '.env'],
      );
      expect(
        denyGlobViolations(changed, <String>['.env', '**/*_key*']),
        <String>['.env'],
      );
    });

    test('git status 解析：普通 / 重命名 / 引号 / 删除', () {
      final List<String> files = parseChangedFiles(<String>[
        ' M lib/a.dart',
        '?? lib/new.dart',
        'R  old.dart -> lib/renamed.dart',
        ' D lib/gone.dart',
        ' M "docs/中文.md"',
      ].join('\n'));
      expect(files, <String>[
        'docs/中文.md',
        'lib/a.dart',
        'lib/gone.dart',
        'lib/new.dart',
        'lib/renamed.dart',
      ]);
    });

    test('isSafeRelativePath：拒绝绝对路径与 ..', () {
      expect(isSafeRelativePath('lib/a.dart'), isTrue);
      expect(isSafeRelativePath('./lib/a.dart'), isTrue);
      expect(isSafeRelativePath('/lib/a.dart'), isFalse);
      expect(isSafeRelativePath('E:/lib/a.dart'), isFalse);
      expect(isSafeRelativePath('lib/../a.dart'), isFalse);
      expect(isSafeRelativePath('lib//a.dart'), isFalse);
    });
  });

  test('门控命令：显式 > 基线 > dart analyze', () {
    expect(gateCommandsOf(<String>['dart test'], <String>['dart analyze']), <String>['dart test']);
    expect(gateCommandsOf(null, <String>['dart analyze']), <String>['dart analyze']);
    expect(gateCommandsOf(null, <String>[]), <String>['dart analyze']);
  });

  test('jsonObjectFromText：纯 JSON / 代码围栏 / 前置说明', () {
    expect(jsonObjectFromText('{"a":1}'), <String, Object?>{'a': 1});
    expect(
      jsonObjectFromText('说明\n```json\n{"a":2}\n```'),
      <String, Object?>{'a': 2},
    );
    expect(jsonObjectFromText('没有 JSON'), isNull);
  });

  test('renderPackMd：人读版带文件、基线、风险', () {
    final String text = renderPackMd(
      taskId: 'T1',
      title: '改列表',
      pack: parsePackJson(<String, Object?>{
        'files': <Object?>[
          <String, Object?>{
            'path': 'lib/a.dart',
            'start_line': 1,
            'end_line': 2,
            'content': 'class A {}',
          },
        ],
        'baseline': <Object?>['dart analyze'],
        'risks': <String>['数据兼容'],
      }),
    );
    expect(text, contains('# 片段包 · T1 改列表'));
    expect(text, contains('lib/a.dart'));
    expect(text, contains('class A {}'));
    expect(text, contains('dart analyze'));
    expect(text, contains('数据兼容'));
  });
}
