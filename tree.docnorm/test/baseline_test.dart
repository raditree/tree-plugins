import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_docnorm/tree_docnorm.dart';

/// 假 `tree.storage`：只实现 baseline / reanalyze 用到的命令。
class FakeStorage {
  FakeStorage({this.available = true});

  bool available;
  int writes = 0;
  final Map<String, Map<String, Map<String, Object?>>> db =
      <String, Map<String, Map<String, Object?>>>{};

  Map<String, Map<String, Object?>> collectionOf(String name) =>
      db.putIfAbsent(name, () => <String, Map<String, Object?>>{});

  Future<Map<String, dynamic>> call(
    String command,
    Map<String, dynamic> arguments,
  ) async {
    if (!available) throw StateError('storage offline');
    final String collection = (arguments['collection'] ?? '').toString();
    final Map<String, Map<String, Object?>> records = collectionOf(collection);
    switch (command) {
      case 'storage.ensure':
        writes += 1;
        return <String, dynamic>{
          'collection': collection,
          'schema_version': arguments['schema_version'] ?? 1,
        };
      case 'storage.scan':
        final String prefix = (arguments['prefix'] ?? '').toString();
        final List<Map<String, Object?>> values = <Map<String, Object?>>[
          for (final MapEntry<String, Map<String, Object?>> entry
              in records.entries)
            if (entry.key.startsWith(prefix))
              <String, Object?>{
                'key': entry.key,
                'value': entry.value,
                'rev': 1,
              },
        ];
        return <String, dynamic>{'values': values, 'count': values.length};
      case 'storage.get':
        final Map<String, Object?>? value =
            records[(arguments['key'] ?? '').toString()];
        return <String, dynamic>{'value': value, 'rev': value == null ? 0 : 1};
      case 'storage.put':
        writes += 1;
        records[(arguments['key'] ?? '').toString()] =
            Map<String, Object?>.from(arguments['value'] as Map);
        return <String, dynamic>{'rev': 1};
      case 'storage.delete':
        writes += 1;
        records.remove((arguments['key'] ?? '').toString());
        return <String, dynamic>{'deleted': true};
      case 'storage.tx':
        writes += 1;
        final List<dynamic> ops = arguments['ops'] is List
            ? arguments['ops'] as List<dynamic>
            : <dynamic>[];
        for (final Object? raw in ops) {
          if (raw is! Map) continue;
          final Map<String, dynamic> op = raw.map(
            (Object? key, Object? value) =>
                MapEntry<String, dynamic>(key.toString(), value),
          );
          final Map<String, Map<String, Object?>> target = collectionOf(
            (op['collection'] ?? '').toString(),
          );
          if ((op['op'] ?? '').toString() == 'delete') {
            target.remove((op['key'] ?? '').toString());
          } else {
            target[(op['key'] ?? '').toString()] = Map<String, Object?>.from(
              op['value'] as Map,
            );
          }
        }
        return <String, dynamic>{'committed': true, 'count': ops.length};
      default:
        throw StateError('未知存储命令：$command');
    }
  }
}

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
    temp = Directory.systemTemp.createTempSync('tree_docnorm_baseline_');
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

  String read(String path) =>
      File('${temp.path}${Platform.pathSeparator}$path').readAsStringSync();

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

  void fixture() {
    write('pubspec.yaml', 'name: demo_pkg\n');
    write('lib/a.dart', 'class Alpha {}\n');
    write('README.md', '# Demo\n');
    write('docs/README.md', '- [a.md](a.md)\n');
    write('docs/a.md', '# A\n');
  }

  test('baseline 默认 dry-run：出计划、不写仓库、不写存储', () async {
    fixture();
    await commitAll();
    final FakeStorage storage = FakeStorage();
    final Map<String, Object?> result = await runBaseline(
      temp.path,
      storage: storage.call,
      sections: <Map<String, Object?>>[
        <String, Object?>{
          'doc': 'README.md',
          'heading': '## 测试',
          'body': 'dart test',
        },
      ],
    );
    expect(result['dry_run'], isTrue);
    expect(result['written'], isEmpty);
    expect(result['would_write'], <String>['README.md']);
    expect(read('README.md'), '# Demo\n');
    expect(storage.writes, 0);
    final Map<String, Object?> plan = result['plan'] as Map<String, Object?>;
    expect(plan['files'], hasLength(1));
    expect((result['storage'] as Map<String, Object?>)['applied'], isFalse);
  }, skip: gitAvailable ? false : 'git 不可用');

  test('baseline --commit 追加章节；重复运行 0 文件 / 0 存储写', () async {
    fixture();
    await commitAll();
    final FakeStorage storage = FakeStorage();
    final List<Map<String, Object?>> sections = <Map<String, Object?>>[
      <String, Object?>{
        'doc': 'README.md',
        'heading': '## 测试',
        'body': 'dart test',
      },
    ];
    final Map<String, Object?> first = await runBaseline(
      temp.path,
      storage: storage.call,
      commit: true,
      sections: sections,
    );
    expect(first['written'], <String>['README.md']);
    expect(read('README.md'), contains('## 测试'));
    expect(storage.collectionOf('doc_contract'), isNotEmpty);
    expect(storage.collectionOf('pkg_index'), isNotEmpty);
    expect(storage.collectionOf('doc_state'), isNotEmpty);

    final int writesAfterFirst = storage.writes;
    final Map<String, Object?> second = await runBaseline(
      temp.path,
      storage: storage.call,
      commit: true,
      sections: sections,
    );
    expect(second['written'], isEmpty);
    expect(storage.writes, writesAfterFirst, reason: '重复运行必须 0 写盘');
    expect(read('README.md'), contains('## 测试'));
  }, skip: gitAvailable ? false : 'git 不可用');

  test('索引只追加：新行插到分组末尾，既有行顺序与内容不变', () async {
    write('pubspec.yaml', 'name: demo_pkg\n');
    write('lib/a.dart', 'class Alpha {}\n');
    write('README.md', '# Demo\n');
    write(
      'docs/README.md',
      '# Docs\n\n## 指南\n- [a.md](a.md)\n\n## 归档\n- [old.md](old.md)\n',
    );
    write('docs/a.md', '# A\n');
    write('docs/b.md', '# B\n');
    write('docs/old.md', '# Old\n');
    await commitAll();
    final FakeStorage storage = FakeStorage();
    final Map<String, Object?> result = await runBaseline(
      temp.path,
      storage: storage.call,
      commit: true,
      indexes: <Map<String, Object?>>[
        <String, Object?>{
          'index': 'docs/README.md',
          'line': '- [b.md](b.md)',
          'group': '指南',
        },
      ],
    );
    expect(result['written'], <String>['docs/README.md']);
    final String content = read('docs/README.md');
    expect(
      content,
      '# Docs\n\n## 指南\n- [a.md](a.md)\n- [b.md](b.md)\n\n'
      '## 归档\n- [old.md](old.md)\n',
    );
    expect(
      content.indexOf('- [a.md](a.md)'),
      lessThan(content.indexOf('- [b.md](b.md)')),
    );
    expect(
      content.indexOf('- [b.md](b.md)'),
      lessThan(content.indexOf('## 归档')),
    );
  }, skip: gitAvailable ? false : 'git 不可用');

  test('rewrite_allowlist 之外拒绝整篇改写，允许时给出 diff', () async {
    fixture();
    await commitAll();
    final FakeStorage storage = FakeStorage();
    final List<Map<String, Object?>> proposal = <Map<String, Object?>>[
      <String, Object?>{
        'doc': 'README.md',
        'mode': 'rewrite',
        'content': '# Replaced\n',
      },
    ];
    final Map<String, Object?> denied = await runBaseline(
      temp.path,
      storage: storage.call,
      commit: true,
      sections: proposal,
    );
    final Map<String, Object?> deniedPlan =
        denied['plan'] as Map<String, Object?>;
    expect(deniedPlan['rejected'], isNotEmpty);
    expect(denied['written'], isEmpty);
    expect(read('README.md'), '# Demo\n');

    final Map<String, Object?> allowed = await runBaseline(
      temp.path,
      storage: storage.call,
      commit: true,
      sections: proposal,
      rewriteAllowlist: <String>['README.md'],
    );
    expect(allowed['written'], <String>['README.md']);
    expect(read('README.md'), '# Replaced\n');
    final Map<String, Object?> plan = allowed['plan'] as Map<String, Object?>;
    final List<dynamic> files = plan['files'] as List<dynamic>;
    final Map<String, Object?> file = files.first as Map<String, Object?>;
    expect(file['diff'], contains('-# Demo'));
    expect(file['diff'], contains('+# Replaced'));
  }, skip: gitAvailable ? false : 'git 不可用');

  test('存储不可用时 fail-closed（TC-ST-10）', () async {
    fixture();
    await commitAll();
    final FakeStorage storage = FakeStorage(available: false);
    await expectLater(
      runBaseline(temp.path, storage: storage.call),
      throwsA(
        isA<BaselineFailure>()
            .having(
              (BaselineFailure e) => e.code,
              'code',
              'storage_unavailable',
            )
            .having(
              (BaselineFailure e) => e.message,
              'message',
              contains('存储不可用'),
            ),
      ),
    );
    expect(read('README.md'), '# Demo\n');
  }, skip: gitAvailable ? false : 'git 不可用');

  test('reanalyze 无基线 fail-closed；有基线只重算受影响包', () async {
    fixture();
    write('lib/b.dart', 'class Beta {}\n');
    await commitAll();
    final FakeStorage storage = FakeStorage();

    await expectLater(
      runReanalyze(temp.path, storage: storage.call, changed: true),
      throwsA(
        isA<BaselineFailure>().having(
          (BaselineFailure e) => e.code,
          'code',
          'baseline_required',
        ),
      ),
    );

    await runBaseline(temp.path, storage: storage.call, commit: true);
    write('lib/a.dart', 'class Alpha {}\nclass Gamma {}\n');
    final Map<String, Object?> first = await runReanalyze(
      temp.path,
      storage: storage.call,
      changed: true,
      commit: true,
    );
    expect(first['affected_packages'], contains('demo_pkg'));
    expect(first['recomputed'], contains('demo_pkg'));
    expect((first['storage'] as Map<String, Object?>)['applied'], isTrue);
    final int writesAfterFirst = storage.writes;

    final Map<String, Object?> second = await runReanalyze(
      temp.path,
      storage: storage.call,
      changed: true,
      commit: true,
    );
    expect(second['affected_packages'], contains('demo_pkg'));
    expect(second['written'], isEmpty);
    expect(
      (second['storage'] as Map<String, Object?>)['applied'],
      isFalse,
      reason: '同一变更重复重算必须 0 写盘',
    );
    expect(storage.writes, writesAfterFirst);

    await expectLater(
      runReanalyze(temp.path, storage: storage.call, changed: false),
      throwsA(
        isA<BaselineFailure>().having(
          (BaselineFailure e) => e.code,
          'code',
          'changed_required',
        ),
      ),
    );
  }, skip: gitAvailable ? false : 'git 不可用');
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
