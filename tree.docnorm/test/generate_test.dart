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
    temp = Directory.systemTemp.createTempSync('tree_docnorm_generate_');
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

  /// 未提交的源码变更 ⇒ 一个注入单元（README.md 必须存在）。
  Future<void> fixture({String readme = '# demo\n'}) async {
    write('pubspec.yaml', 'name: demo_pkg\n');
    write('lib/a.dart', 'class Alpha {}\n');
    write('README.md', readme);
    await commitAll();
    write('lib/a.dart', 'class Alpha {}\nclass Beta {}\n');
  }

  List<Map<String, Object?>> allSections() => <Map<String, Object?>>[
    <String, Object?>{'heading': '职责', 'body': '负责示例包的核心类型与入口。'},
    <String, Object?>{'heading': '入口', 'body': '从 lib/a.dart 的 Alpha 进入。'},
    <String, Object?>{'heading': '边界', 'body': '不处理网络与持久化，只做类型定义。'},
    <String, Object?>{'heading': '测试', 'body': '运行 dart test 覆盖声明与边界。'},
  ];

  test('只补缺章节：返回可直接喂 baseline 的 sections', () async {
    await fixture();
    final List<GenerateRequest> seen = <GenerateRequest>[];
    final Map<String, Object?> result = await runGenerate(
      temp.path,
      environment: const <String, String>{},
      llm: (GenerateRequest request) async {
        seen.add(request);
        return GenerateReply(json: <String, Object?>{'sections': allSections()});
      },
    );

    expect(seen, hasLength(1));
    final List<dynamic> docs = result['documents'] as List<dynamic>;
    final Map<String, Object?> doc = docs.first as Map<String, Object?>;
    expect(doc['status'], 'generated');
    expect(doc['mode'], 'readme');
    expect(doc['tier'], 'comments');
    expect(doc['requested_sections'], kDefaultSections);
    expect((doc['generated'] as List<dynamic>).length, 4);

    final List<dynamic> sections = result['sections'] as List<dynamic>;
    expect(sections, hasLength(4));
    final Map<String, Object?> first = sections.first as Map<String, Object?>;
    expect(first['doc'], 'README.md');
    expect(first['heading'], '## 职责');
    expect(first['mode'], 'append');
    expect(
      (result['budget'] as Map<String, Object?>)['calls'],
      1,
      reason: '四个章节一次调用完成',
    );
    expect(result['degraded'], false);
  }, skip: gitAvailable ? false : 'git 不可用');

  test('已存在章节跳过：0 调用、0 提案', () async {
    await fixture(
      readme: '# demo\n\n## 职责\n已有\n\n## 入口\n已有\n\n'
          '## 边界\n已有\n\n## 测试\n已有\n',
    );
    int calls = 0;
    final Map<String, Object?> result = await runGenerate(
      temp.path,
      environment: const <String, String>{},
      llm: (GenerateRequest request) async {
        calls += 1;
        return const GenerateReply(json: <String, Object?>{'sections': <Object>[]});
      },
    );
    expect(calls, 0);
    final Map<String, Object?> doc =
        (result['documents'] as List<dynamic>).first as Map<String, Object?>;
    expect(doc['status'], 'skipped');
    expect(doc['skip_reason'], 'sections_present');
    expect(result['sections'], isEmpty);
  }, skip: gitAvailable ? false : 'git 不可用');

  test('README 不存在：跳过且不新建、0 调用', () async {
    write('pubspec.yaml', 'name: demo_pkg\n');
    write('lib/a.dart', 'class Alpha {}\n');
    await commitAll();
    write('lib/a.dart', 'class Alpha {}\nclass Beta {}\n');
    int calls = 0;
    final Map<String, Object?> result = await runGenerate(
      temp.path,
      environment: const <String, String>{},
      llm: (GenerateRequest request) async {
        calls += 1;
        return const GenerateReply();
      },
    );
    expect(calls, 0);
    final Map<String, Object?> doc =
        (result['documents'] as List<dynamic>).first as Map<String, Object?>;
    expect(doc['status'], 'skipped');
    expect(doc['skip_reason'], 'readme_missing');
    expect(
      File('${temp.path}${Platform.pathSeparator}README.md').existsSync(),
      isFalse,
      reason: 'generate 只读，不凭空新建 README',
    );
  }, skip: gitAvailable ? false : 'git 不可用');

  test('只接受请求章节：额外标题进 rejected，过短正文拒绝', () async {
    await fixture();
    final Map<String, Object?> result = await runGenerate(
      temp.path,
      environment: const <String, String>{},
      llm: (GenerateRequest request) async => const GenerateReply(
        json: <String, Object?>{
          'sections': <Object>[
            <String, Object?>{'heading': '## 职责', 'body': '负责示例包的核心类型。'},
            <String, Object?>{'heading': '部署', 'body': '这是没有被请求的章节正文。'},
            <String, Object?>{'heading': '入口', 'body': '短'},
          ],
        },
      ),
    );
    final Map<String, Object?> doc =
        (result['documents'] as List<dynamic>).first as Map<String, Object?>;
    expect((doc['generated'] as List<dynamic>), hasLength(1));
    final List<dynamic> rejected = doc['rejected'] as List<dynamic>;
    expect(jsonOf(rejected), contains('未请求的章节'));
    expect(jsonOf(rejected), contains('正文过短'));
    expect((doc['skipped'] as List<dynamic>).length, 3);
    expect((result['sections'] as List<dynamic>).length, 1);
  }, skip: gitAvailable ? false : 'git 不可用');

  test('LLM 失败 / 非法 JSON：degraded 且不伪造正文', () async {
    await fixture();
    final Map<String, Object?> failed = await runGenerate(
      temp.path,
      environment: const <String, String>{},
      llm: (GenerateRequest request) async =>
          const GenerateReply(error: '模型不可用'),
    );
    final Map<String, Object?> failedDoc =
        (failed['documents'] as List<dynamic>).first as Map<String, Object?>;
    expect(failed['degraded'], true);
    expect(failedDoc['generated'], isEmpty);
    expect((failedDoc['reasons'] as List<dynamic>).join('\n'), contains('模型不可用'));

    final Map<String, Object?> invalid = await runGenerate(
      temp.path,
      environment: const <String, String>{},
      llm: (GenerateRequest request) async =>
          const GenerateReply(text: '这里不是 JSON'),
    );
    final Map<String, Object?> invalidDoc =
        (invalid['documents'] as List<dynamic>).first as Map<String, Object?>;
    expect(invalid['degraded'], true);
    expect(invalidDoc['generated'], isEmpty);
    expect(
      (invalidDoc['reasons'] as List<dynamic>).join('\n'),
      contains('不是 JSON'),
    );
    expect(invalid['sections'], isEmpty);
  }, skip: gitAvailable ? false : 'git 不可用');

  test('context_cap 超限：full 档放不下时先降档', () async {
    write('pubspec.yaml', 'name: demo_pkg\n');
    write('lib/a.dart', 'class Alpha {}\n');
    write('lib/b.dart', 'class Beta {}\n');
    write('README.md', '# demo\n');
    await commitAll();
    write('lib/a.dart', 'class Alpha {}\n${'// 填充\n' * 400}');
    write('lib/b.dart', 'class Beta {}\n${'// 填充\n' * 400}');

    final List<GenerateRequest> seen = <GenerateRequest>[];
    final Map<String, Object?> result = await runGenerate(
      temp.path,
      environment: const <String, String>{},
      mode: 'readme',
      tier: 'full',
      overrides: <String, Object?>{'context_cap': 400},
      llm: (GenerateRequest request) async {
        seen.add(request);
        return GenerateReply(json: <String, Object?>{'sections': allSections()});
      },
    );
    final Map<String, Object?> doc =
        (result['documents'] as List<dynamic>).first as Map<String, Object?>;
    expect(doc['tier'], 'declarations', reason: 'full 档放不下时降档');
    expect((doc['reasons'] as List<dynamic>).join('\n'), contains('降档'));
    expect(seen, hasLength(1));
    expect((doc['generated'] as List<dynamic>).length, 4);
  }, skip: gitAvailable ? false : 'git 不可用');

  test('按文件分块：两次调用，重复章节只接受一次', () async {
    write('pubspec.yaml', 'name: demo_pkg\n');
    final String declarations = <String>[
      for (int i = 0; i < 60; i++) 'class A$i {}',
    ].join('\n');
    write('lib/a.dart', '$declarations\n');
    write('lib/b.dart', '$declarations\n');
    write('README.md', '# demo\n');
    await commitAll();
    write('lib/a.dart', '$declarations\nclass AExtra {}\n');
    write('lib/b.dart', '$declarations\nclass BExtra {}\n');

    final List<GenerateRequest> seen = <GenerateRequest>[];
    final Map<String, Object?> result = await runGenerate(
      temp.path,
      environment: const <String, String>{},
      mode: 'declarations',
      tier: 'declarations',
      overrides: <String, Object?>{'context_cap': 400},
      llm: (GenerateRequest request) async {
        seen.add(request);
        return GenerateReply(json: <String, Object?>{'sections': allSections()});
      },
    );
    final Map<String, Object?> doc =
        (result['documents'] as List<dynamic>).first as Map<String, Object?>;
    expect(seen.length, greaterThanOrEqualTo(2), reason: '两个文件分块调用');
    expect(
      (doc['generated'] as List<dynamic>).length,
      4,
      reason: '跨批次的重复章节只接受一次',
    );
  }, skip: gitAvailable ? false : 'git 不可用');

  test('单文件仍超 context_cap：丢弃并标 degraded', () async {
    await fixture();
    write(
      'lib/a.dart',
      <String>[for (int i = 0; i < 1500; i++) 'class Generated$i {}'].join('\n'),
    );
    final List<GenerateRequest> seen = <GenerateRequest>[];
    final Map<String, Object?> result = await runGenerate(
      temp.path,
      environment: const <String, String>{},
      mode: 'declarations',
      tier: 'declarations',
      overrides: <String, Object?>{'context_cap': 120},
      llm: (GenerateRequest request) async {
        seen.add(request);
        return GenerateReply(json: <String, Object?>{'sections': allSections()});
      },
    );
    expect(seen, isEmpty);
    final Map<String, Object?> doc =
        (result['documents'] as List<dynamic>).first as Map<String, Object?>;
    expect(result['degraded'], true);
    expect(doc['degraded'], true);
    expect((doc['reasons'] as List<dynamic>).join('\n'), contains('已丢弃'));
  }, skip: gitAvailable ? false : 'git 不可用');

  test('stage_budget 超限：停止调用并标记 exhausted', () async {
    await fixture();
    int calls = 0;
    final Map<String, Object?> result = await runGenerate(
      temp.path,
      environment: const <String, String>{},
      overrides: <String, Object?>{'stage_budget': 1},
      llm: (GenerateRequest request) async {
        calls += 1;
        return GenerateReply(json: <String, Object?>{'sections': allSections()});
      },
    );
    expect(calls, 0);
    final Map<String, Object?> budget = result['budget'] as Map<String, Object?>;
    expect(budget['exhausted'], true);
    expect(budget['within_stage_budget'], false);
    expect(result['degraded'], true);
    expect(
      ((result['documents'] as List<dynamic>).first
              as Map<String, Object?>)['reasons']
          .toString(),
      contains('stage_budget'),
    );
  }, skip: gitAvailable ? false : 'git 不可用');
}

String jsonOf(Object? value) => value.toString();

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
