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
    temp = Directory.systemTemp.createTempSync('tree_docnorm_plan_');
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

  void fixture() {
    write('pubspec.yaml', 'name: demo_pkg\n');
    write('lib/a.dart', 'class Alpha {}\nclass Beta {}\n');
  }

  test('stat-dirty 不产计划：只改 mtime 不算变更', () async {
    fixture();
    await commitAll();
    final File source = File(
      '${temp.path}${Platform.pathSeparator}lib${Platform.pathSeparator}a.dart',
    );
    source.setLastModifiedSync(DateTime(2035, 1, 1));
    final Map<String, Object?> result = await runPlan(
      temp.path,
      environment: const <String, String>{},
    );
    expect((result['git'] as Map<String, Object?>)['total'], 0);
    expect(result['units'], isEmpty);
  }, skip: gitAvailable ? false : 'git 不可用');

  test('内容变更产出注入单元与两额度估计；新文件显式纳入', () async {
    fixture();
    await commitAll();
    write('lib/a.dart', 'class Alpha {}\nclass Beta {}\nclass Gamma {}\n');
    write('lib/new.dart', 'class Delta {}\n');
    final Map<String, Object?> result = await runPlan(
      temp.path,
      environment: const <String, String>{},
    );
    final List<dynamic> units = result['units'] as List<dynamic>;
    expect(units, hasLength(1));
    final Map<String, Object?> unit = units.first as Map<String, Object?>;
    expect(unit['package'], 'demo_pkg');
    expect(unit['mode'], 'declarations');
    expect(unit['changed_files'], contains('lib/a.dart'));
    expect(unit['changed_files'], contains('lib/new.dart'));
    expect(unit['selected_tokens'] as int, greaterThan(0));

    final Map<String, Object?> budget =
        result['budget'] as Map<String, Object?>;
    expect(budget['context_cap'], 89600);
    expect(budget['stage_budget'], 400000);
    expect(budget['within_stage_budget'], isTrue);
    expect(budget['within_context_cap'], isTrue);
  }, skip: gitAvailable ? false : 'git 不可用');

  test(
    '配置优先级：config < env < settings < overrides，context_cap 与模型上限取 min',
    () async {
      fixture();
      write(
        '.docnorm/config.json',
        '{"model_max_seqlen": 1000, "context_ratio": 0.7, "stage_budget": 1}',
      );
      await commitAll();
      write('lib/a.dart', 'class Alpha {}\nclass Beta {}\nclass Gamma {}\n');

      final Map<String, Object?> configured = await runPlan(
        temp.path,
        environment: const <String, String>{},
      );
      final Map<String, Object?> config =
          configured['config'] as Map<String, Object?>;
      expect(config['sources'], contains('.docnorm/config.json'));
      expect(config['context_cap'], 700);
      final Map<String, Object?> budget =
          configured['budget'] as Map<String, Object?>;
      expect(budget['stage_budget'], 1);
      expect(budget['within_stage_budget'], isFalse);
      expect(budget['over_stage_by'] as int, greaterThan(0));

      final Map<String, Object?> fromEnv = await runPlan(
        temp.path,
        environment: const <String, String>{'TREE_DOCNORM_CONTEXT_CAP': '10'},
      );
      expect((fromEnv['config'] as Map<String, Object?>)['context_cap'], 10);
      expect(
        (fromEnv['config'] as Map<String, Object?>)['sources'],
        contains('env:TREE_DOCNORM_CONTEXT_CAP'),
      );

      final Map<String, Object?> fromSettings = await runPlan(
        temp.path,
        environment: const <String, String>{'TREE_DOCNORM_CONTEXT_CAP': '10'},
        settings: <String, Object?>{'context_cap': 30, 'stage_budget': 2},
      );
      expect(
        (fromSettings['config'] as Map<String, Object?>)['context_cap'],
        30,
      );
      expect(
        (fromSettings['config'] as Map<String, Object?>)['sources'],
        contains('settings:context_cap'),
      );
      expect(
        (fromSettings['budget'] as Map<String, Object?>)['stage_budget'],
        2,
      );

      // 设置服务里 context_cap=0 表示“按模型上限自动算”，不能当成显式上限。
      final Map<String, Object?> zeroCap = await runPlan(
        temp.path,
        environment: const <String, String>{},
        settings: <String, Object?>{'context_cap': 0},
      );
      expect((zeroCap['config'] as Map<String, Object?>)['context_cap'], 700);

      final Map<String, Object?> overridden = await runPlan(
        temp.path,
        environment: const <String, String>{'TREE_DOCNORM_CONTEXT_CAP': '10'},
        settings: <String, Object?>{'context_cap': 30},
        overrides: <String, Object?>{'context_cap': 20},
      );
      expect((overridden['config'] as Map<String, Object?>)['context_cap'], 20);
    },
    skip: gitAvailable ? false : 'git 不可用',
  );

  test('测试文件走 assertions 模式；显式 full 超限时降级', () async {
    fixture();
    write(
      'test/a_test.dart',
      "import 'package:test/test.dart';\n\nvoid main() {\n"
          "  test('x', () { expect(1, 1); });\n}\n",
    );
    await commitAll();
    write(
      'test/a_test.dart',
      "import 'package:test/test.dart';\n\nvoid main() {\n"
          "  test('x', () { expect(1, 1); expect(2, 2); });\n}\n",
    );
    final Map<String, Object?> assertions = await runPlan(
      temp.path,
      environment: const <String, String>{},
    );
    final Map<String, Object?> unit =
        (assertions['units'] as List<dynamic>).first as Map<String, Object?>;
    expect(unit['mode'], 'assertions');
    expect(unit['selected_tokens'] as int, greaterThan(0));

    final Map<String, Object?> full = await runPlan(
      temp.path,
      environment: const <String, String>{},
      mode: 'full',
      overrides: <String, Object?>{'context_cap': 1},
    );
    final Map<String, Object?> fallback =
        (full['units'] as List<dynamic>).first as Map<String, Object?>;
    expect(fallback['mode'], 'declarations');
    expect(
      (fallback['reasons'] as List<dynamic>).join('\n'),
      contains('full_code_limit'),
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
