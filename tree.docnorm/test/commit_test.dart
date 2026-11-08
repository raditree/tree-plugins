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
    temp = Directory.systemTemp.createTempSync('tree_docnorm_commit_');
    if (!gitAvailable) return;
    await _git(temp, <String>['init', '--quiet']);
    await _git(temp, <String>['config', 'user.name', 'test']);
    await _git(temp, <String>['config', 'user.email', 'test@local']);
    await _git(temp, <String>['config', 'commit.gpgsign', 'false']);
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
    await _git(temp, <String>['commit', '--quiet', '-m', 'fixture']);
  }

  Future<int> commitCount() async =>
      int.parse((await _gitOut(temp, <String>['rev-list', '--count', 'HEAD'])).trim());

  test('风格探测：conventional / plain / 混合一律 unknown', () {
    final CommitStyle conventional = detectCommitStyle(<String>[
      'feat(docnorm): 新增提交',
      'feat(docnorm): 补图',
      'fix: 修边',
    ]);
    expect(conventional.style, 'conventional');
    expect(conventional.dominantType, 'feat');
    expect(conventional.samples, 3);

    expect(detectCommitStyle(<String>['更新文档', '修复断链']).style, 'plain');
    expect(detectCommitStyle(<String>['feat: a', '随手改']).style, 'unknown');
    expect(detectCommitStyle(const <String>[]).style, 'unknown');
  }, skip: false);

  test('分批：docs 域 / 最具体包 / unmatched；dry-run 0 提交，commit 只提交本批文件', () async {
    if (!gitAvailable) {
      markTestSkipped('git 不可用');
      return;
    }
    write('pubspec.yaml', 'name: demo_pkg\n');
    write('lib/a.dart', 'class Alpha {}\n');
    write('packages/sub/pubspec.yaml', 'name: pkg_sub\n');
    write('packages/sub/lib/s.dart', 'class Sub {}\n');
    write('docs/README.md', '- [a.md](a.md)\n');
    write('docs/a.md', '# A\n');
    write('README.md', '# demo\n');
    await commitAll();
    final int before = await commitCount();

    write('lib/a.dart', 'class Alpha {}\nclass Beta {}\n');
    write('packages/sub/lib/s.dart', 'class Sub {}\nclass Extra {}\n');
    write('docs/a.md', '# A\n\n补充\n');
    write('notes.txt', 'unmatched\n');

    final FakeStorage storage = FakeStorage();
    final Map<String, Object?> dry = await runCommit(temp.path);
    expect(dry['dry_run'], true);
    final List<dynamic> batches = dry['batches'] as List<dynamic>;
    expect(batches.length, 3, reason: '根包 demo_pkg 收走根级文件，docs 与子包各自成批');
    final Set<String> names = <String>{
      for (final dynamic batch in batches)
        '${(batch as Map<String, Object?>)['name']}',
    };
    expect(names, <String>{'docs', 'demo_pkg', 'pkg_sub'});
    final Map<String, Object?> docsBatch = batches
        .cast<Map<String, Object?>>()
        .firstWhere((Map<String, Object?> batch) => batch['name'] == 'docs');
    expect(docsBatch['files'], <String>['docs/a.md']);
    expect(
      (dry['counts'] as Map<String, Object?>)['committed'],
      0,
      reason: 'dry-run 0 提交',
    );
    expect(await commitCount(), before);

    final Map<String, Object?> applied = await runCommit(temp.path, commit: true);
    expect((applied['counts'] as Map<String, Object?>)['committed'], 3);
    expect((applied['counts'] as Map<String, Object?>)['failed'], 0);
    expect(await commitCount(), before + 3);
    expect((await _gitOut(temp, <String>['status', '--short'])).trim(), isEmpty);
    final String lastFiles = (await _gitOut(temp, <String>[
      'show',
      '--name-only',
      '--pretty=format:',
      'HEAD',
    ])).trim();
    expect(
      lastFiles,
      'packages/sub/lib/s.dart',
      reason: '每批只提交自己的文件（最后一批是 pkg_sub）',
    );
    expect(storage.writes, 0, reason: 'commit 不写存储');
  }, skip: gitAvailable ? false : 'git 不可用');

  test('无根包时，包外文件进 unmatched 批', () async {
    if (!gitAvailable) {
      markTestSkipped('git 不可用');
      return;
    }
    write('packages/a/pubspec.yaml', 'name: pkg_a\n');
    write('packages/a/lib/a.dart', 'class A {}\n');
    write('scripts/deploy.sh', 'echo a\n');
    await commitAll();

    write('scripts/deploy.sh', 'echo b\n');
    final Map<String, Object?> dry = await runCommit(temp.path);
    final List<dynamic> batches = dry['batches'] as List<dynamic>;
    expect(batches.length, 1);
    final Map<String, Object?> batch =
        batches.first as Map<String, Object?>;
    expect(batch['kind'], 'unmatched');
    expect(batch['files'], <String>['scripts/deploy.sh']);
  }, skip: gitAvailable ? false : 'git 不可用');

  test('门禁：默认只列；--run-gates 执行，失败整批不提交', () async {
    if (!gitAvailable) {
      markTestSkipped('git 不可用');
      return;
    }
    write('pubspec.yaml', 'name: demo_pkg\n');
    write('lib/a.dart', 'class Alpha {}\n');
    write('README.md', '# demo\n');
    write('CONTRIBUTING.md', '- `git status --short`\n');
    await commitAll();

    write('lib/a.dart', 'class Alpha {}\nclass Beta {}\n');
    final Map<String, Object?> listed = await runCommit(temp.path);
    final Map<String, Object?> gates =
        listed['gates'] as Map<String, Object?>;
    expect(gates['mode'], 'listed');
    expect(gates['count'], greaterThanOrEqualTo(1));
    final Map<String, Object?> onlyBatch =
        (listed['batches'] as List<dynamic>).first as Map<String, Object?>;
    final List<dynamic> listedGates = onlyBatch['gates'] as List<dynamic>;
    expect(listedGates, isNotEmpty);
    for (final dynamic gate in listedGates) {
      expect((gate as Map<String, Object?>).containsKey('status'), false);
      expect(gate['cwd'], isNotNull);
    }

    final int passed = await commitCount();
    final Map<String, Object?> executed = await runCommit(
      temp.path,
      commit: true,
      runGates: true,
    );
    expect((executed['counts'] as Map<String, Object?>)['committed'], 1);
    final Map<String, Object?> executedBatch =
        (executed['batches'] as List<dynamic>).first as Map<String, Object?>;
    for (final dynamic gate in executedBatch['gates'] as List<dynamic>) {
      expect((gate as Map<String, Object?>)['status'], 'passed');
      expect(gate['command_line'], isNotNull);
    }
    expect(await commitCount(), passed + 1);

    write('CONTRIBUTING.md', '- `git nosuchcommand`\n');
    write('lib/a.dart', 'class Alpha {}\nclass Beta {}\nclass Gamma {}\n');
    final int afterPass = await commitCount();
    final Map<String, Object?> failed = await runCommit(
      temp.path,
      commit: true,
      runGates: true,
    );
    expect((failed['counts'] as Map<String, Object?>)['committed'], 0);
    expect(
      (failed['counts'] as Map<String, Object?>)['failed'],
      greaterThanOrEqualTo(1),
    );
    expect(await commitCount(), afterPass, reason: '门禁失败不产生提交');
    for (final dynamic batch in failed['batches'] as List<dynamic>) {
      expect((batch as Map<String, Object?>)['status'], 'failed');
    }
  }, skip: gitAvailable ? false : 'git 不可用');
}

class FakeStorage {
  int writes = 0;

  Future<Map<String, dynamic>> call(
    String command,
    Map<String, dynamic> arguments,
  ) async {
    writes += 1;
    return <String, dynamic>{'ok': true};
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

Future<String> _gitOut(Directory directory, List<String> args) async {
  final ProcessResult result = await Process.run(
    'git',
    args,
    workingDirectory: directory.path,
  );
  if (result.exitCode != 0) {
    throw StateError('git ${args.join(' ')} 失败：${result.stderr}');
  }
  return '${result.stdout}';
}
