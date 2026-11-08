import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_docnorm/tree_docnorm.dart';

void main() {
  final bool gitAvailable = () {
    try {
      return Process.runSync('git', <String>['--version']).exitCode == 0;
    } catch (_) {
      return false;
    }
  }();

  late Directory temp;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tree_docnorm_audit_');
    if (!gitAvailable) return;
    await _git(temp, <String>['init', '--quiet']);
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  void write(String path, String content) {
    final File file = File('${temp.path}${Platform.pathSeparator}$path');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  Future<void> commitAll() async {
    await _git(temp, <String>['add', '-A']);
    await _git(temp, <String>[
      '-c',
      'user.name=test',
      '-c',
      'user.email=test@local',
      'commit',
      '--quiet',
      '--no-gpg-sign',
      '-m',
      'fixture',
    ]);
  }

  String readme({
    String oneLiner = '提供示例包的核心类型与单一入口。',
    bool boundaries = true,
  }) =>
      '# demo\n\n## 职责\n$oneLiner\n\n## 入口\nlib/a.dart 的 Alpha。\n\n'
      '${boundaries ? '## 边界\n- 不处理网络与持久化。\n' : ''}';

  String policy({String extra = ''}) =>
      'version: 1\nthresholds:\n  package_lines: 10\n  file_lines: 10\n'
      '  api_count: 1\n  declaration_count: 2\n  subpackage_count: 5\n'
      '  one_liner_chars: 60\n  min_one_liner_chars: 8\n$extra';

  test('收束事实：README 四要素解析与 quality 分级', () async {
    write('pubspec.yaml', 'name: demo_pkg\n');
    write('lib/a.dart', <String>[
      for (int i = 0; i < 12; i++) 'class A$i {}',
    ].join('\n'));
    write('README.md', readme());
    write('docnorm.yaml', policy());
    await commitAll();

    final FakeStorage storage = FakeStorage();
    final Map<String, Object?> result = await runAudit(
      temp.path,
      storage: storage.call,
    );
    final Map<String, Object?> pkg =
        (result['packages'] as List<dynamic>).first as Map<String, Object?>;
    expect(pkg['quality'], 'ok');
    expect(pkg['one_liner'], '提供示例包的核心类型与单一入口。');
    expect(pkg['entry'], 'lib/a.dart 的 Alpha。');
    expect((pkg['boundaries'] as List<dynamic>).length, 1);
    expect(pkg['lines'], 12);
    expect(
      (result['thresholds'] as Map<String, Object?>)['package_lines'],
      10,
      reason: '阈值来自仓库策略 docnorm.yaml',
    );
    expect(result['dry_run'], true);
    expect(
      (result['storage'] as Map<String, Object?>)['applied'],
      false,
      reason: 'dry-run 不写存储',
    );
  }, skip: gitAvailable ? false : 'git 不可用');

  test('quality：缺职责为 empty；缺边界为 thin', () async {
    write('pubspec.yaml', 'name: demo_pkg\n');
    write('lib/a.dart', 'class Alpha {}\n');
    write('README.md', '# demo\n');
    await commitAll();
    final FakeStorage storage = FakeStorage();
    final Map<String, Object?> empty = await runAudit(
      temp.path,
      storage: storage.call,
    );
    expect(
      ((empty['packages'] as List<dynamic>).first
          as Map<String, Object?>)['quality'],
      'empty',
    );

    write('README.md', readme(boundaries: false));
    final Map<String, Object?> thin = await runAudit(
      temp.path,
      storage: storage.call,
    );
    expect(
      ((thin['packages'] as List<dynamic>).first
          as Map<String, Object?>)['quality'],
      'thin',
    );
  }, skip: gitAvailable ? false : 'git 不可用');

  test('建议四类：split_size / api_boundary / reuse', () async {
    write('pubspec.yaml', 'name: demo_pkg\n');
    write('lib/a.dart', <String>[
      for (int i = 0; i < 12; i++) 'class A$i {}',
    ].join('\n'));
    write('README.md', readme());
    write('docnorm.yaml', policy());
    write(
      'openapi.yaml',
      'openapi: 3.0.0\npaths:\n  /pets:\n    get: {}\n  /pets/{id}:\n    get: {}\n',
    );
    write('packages/a/pubspec.yaml', 'name: pkg_a\n');
    write('packages/a/lib/a.dart', 'class Shared {}\n');
    write('packages/b/pubspec.yaml', 'name: pkg_b\n');
    write('packages/b/lib/b.dart', 'class Shared {}\n');
    await commitAll();

    final FakeStorage storage = FakeStorage();
    final Map<String, Object?> result = await runAudit(
      temp.path,
      storage: storage.call,
    );
    final List<dynamic> suggestions = result['suggestions'] as List<dynamic>;
    final Map<String, Object?> kinds =
        (result['counts'] as Map<String, Object?>)['by_kind']
            as Map<String, Object?>;
    expect(kinds['split_size'], isNotNull);
    expect(kinds['api_boundary'], isNotNull, reason: 'api_count 2 > 1');
    expect(kinds['reuse'], isNotNull, reason: '两个包都导出 Shared');

    final Map<String, Object?> reuse = suggestions
        .cast<Map<String, Object?>>()
        .firstWhere((Map<String, Object?> item) => item['kind'] == 'reuse');
    expect(reuse['detail'], contains('Shared'));
    expect((reuse['targets'] as List<dynamic>).length, 2);
    expect(reuse['lastTaskId'], isNull);
  }, skip: gitAvailable ? false : 'git 不可用');

  test('commit 写 suggestions/pkg_index；重复运行 0 写；代码变更标 stale', () async {
    write('pubspec.yaml', 'name: demo_pkg\n');
    write('lib/a.dart', <String>[
      for (int i = 0; i < 12; i++) 'class A$i {}',
    ].join('\n'));
    write('README.md', readme());
    write('docnorm.yaml', policy());
    await commitAll();

    final FakeStorage storage = FakeStorage();
    await runBaseline(temp.path, storage: storage.call, commit: true);
    final Map<String, Object?> fresh = await runAudit(
      temp.path,
      storage: storage.call,
      commit: true,
    );
    expect(fresh['baseline_required'], false);
    expect(
      ((fresh['packages'] as List<dynamic>).first
          as Map<String, Object?>)['stale'],
      false,
    );
    expect(storage.db['suggestions'], isNotEmpty);
    expect(storage.db['pkg_index'], isNotEmpty);
    final Map<String, Object?> storedRecord =
        storage.db['pkg_index']!.values.first;
    expect(storedRecord['quality'], isNotNull);
    expect(storedRecord['summary'], isNotNull);

    final int writes = storage.writes;
    final Map<String, Object?> again = await runAudit(
      temp.path,
      storage: storage.call,
      commit: true,
    );
    expect(
      (again['storage'] as Map<String, Object?>)['ops'],
      0,
      reason: '同一事实重复运行 0 写',
    );
    expect(storage.writes, writes);

    write('lib/a.dart', <String>[
      for (int i = 0; i < 20; i++) 'class A$i {}',
    ].join('\n'));
    final Map<String, Object?> stale = await runAudit(
      temp.path,
      storage: storage.call,
    );
    expect(
      ((stale['packages'] as List<dynamic>).first
          as Map<String, Object?>)['stale'],
      true,
      reason: '代码指纹已与 doc_state 不一致',
    );
  }, skip: gitAvailable ? false : 'git 不可用');
}

class FakeStorage {
  final Map<String, Map<String, Map<String, Object?>>> db =
      <String, Map<String, Map<String, Object?>>>{};
  int writes = 0;

  Map<String, Map<String, Object?>> _collection(String name) =>
      db.putIfAbsent(name, () => <String, Map<String, Object?>>{});

  Future<Map<String, dynamic>> call(
    String command,
    Map<String, dynamic> arguments,
  ) async {
    final String collection = '${arguments['collection'] ?? ''}';
    final Map<String, Map<String, Object?>> records = _collection(collection);
    switch (command) {
      case 'storage.ensure':
        writes += 1;
        return <String, dynamic>{
          'collection': collection,
          'schema_version': arguments['schema_version'] ?? 1,
        };
      case 'storage.scan':
        final String prefix = '${arguments['prefix'] ?? ''}';
        final List<Map<String, Object?>> values = <Map<String, Object?>>[
          for (final MapEntry<String, Map<String, Object?>> entry
              in records.entries)
            if (entry.key.startsWith(prefix))
              <String, Object?>{'key': entry.key, 'value': entry.value, 'rev': 1},
        ];
        return <String, dynamic>{'values': values, 'count': values.length};
      case 'storage.tx':
        writes += 1;
        final List<dynamic> ops = arguments['ops'] is List
            ? arguments['ops'] as List<dynamic>
            : <dynamic>[];
        for (final Object? raw in ops) {
          if (raw is! Map) continue;
          final Map<String, dynamic> op = Map<String, dynamic>.from(raw);
          final Map<String, Map<String, Object?>> target = _collection(
            '${op['collection']}',
          );
          final String key = '${op['key']}';
          if (op['op'] == 'delete') {
            target.remove(key);
          } else {
            target[key] = Map<String, Object?>.from(
              (op['value'] as Map).cast<String, Object?>(),
            );
          }
        }
        return <String, dynamic>{'committed': true, 'count': ops.length};
      default:
        throw StateError('未知存储命令：$command');
    }
  }
}

Future<void> _git(Directory directory, List<String> args) async {
  final ProcessResult result = await Process.run(
    'git',
    args,
    workingDirectory: directory.path,
  );
  if (result.exitCode != 0) {
    throw StateError('git ${args.join(' ')} 失败：${result.stderr}');
  }
}
