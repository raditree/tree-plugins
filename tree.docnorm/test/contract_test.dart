import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_docnorm/tree_docnorm.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_docnorm_contract_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  void write(String path, String content) {
    final File file = File('${temp.path}${Platform.pathSeparator}$path');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  /// 桌面仓根：插件仓挂在 `<桌面仓>/plugins/tree.docnorm`；独立 clone 时不存在则跳过。
  final String desktop = Directory.current.parent.parent.path;
  final bool hasDesktop = File('$desktop/docs/README.md').existsSync();

  test('空仓零配置可跑：三层规则只剩内置，缺 README 明确报出', () async {
    final DocContract contract = await inspectRepository(temp.path);
    expect(contract.docs, isEmpty);
    expect(contract.policy.layers, <String>['builtin']);
    expect(
      contract.checks.map((DocCheck check) => check.id),
      containsAll(<String>[
        'required_docs',
        'required_sections',
        'index_complete',
        'links_resolvable',
      ]),
    );
    expect(contract.ok, isFalse);
    expect(
      contract.violations.map((DocViolation item) => item.doc),
      contains('README.md'),
    );
    expect(contract.unknown.join('\n'), contains('commit_style'));
    expect(contract.policy.unsupported, isNotEmpty);
  });

  test('仓库自述覆盖内置规则，且规则键来源可见', () async {
    write('README.md', '# Demo\n');
    write('CHANGELOG.md', '# Changelog\n\n## [1.0.0] - 2026-01-01\n');
    write('docs/README.md', '- [a.md](a.md)\n');
    write('docs/a.md', '# A\n\nAlpha\n');
    write('packages/demo/README.md', '## 测试\n不变量（assertions）\n');
    write('docnorm.yaml', '''
version: 1
required_docs:
  - README.md
  - docs/README.md
  - CHANGELOG.md
required_sections:
  - glob: "packages/*/README.md"
    sections:
      - "不变量（assertions）"
      - "## 测试"
indexes:
  - dir: docs
    index: docs/README.md
mentions:
  - doc: docs/a.md
    symbols: [Alpha]
''');

    final DocContract contract = await inspectRepository(temp.path);
    expect(contract.policy.layers, <String>['builtin', 'repo']);
    expect(contract.policy.repoFiles, <String>['docnorm.yaml']);
    expect(contract.policy.overridden, contains('required_docs'));
    expect(contract.policy.origins['required_docs'], 'repo');
    expect(contract.policy.origins['link_fallbacks'], 'builtin');
    expect(contract.ok, isTrue, reason: _show(contract.violations));
    expect(contract.changelog['style'], 'keep_a_changelog');
    expect(contract.changelog['latest'], '## [1.0.0] - 2026-01-01');
    expect(contract.sections['docs/a.md'], contains('# A'));
  });

  test('索引缺项 / 断链 / 缺章节各自报出，不互相吞掉', () async {
    write('README.md', '# Demo\n');
    write('docs/README.md', '- [a.md](a.md)\n- [bad](nope.md)\n');
    write('docs/a.md', '# A\n');
    write('docs/extra.md', '# Extra\n');
    write('packages/demo/README.md', '# Demo 包\n');
    write('docnorm.yaml', '''
version: 1
required_docs:
  - README.md
  - docs/README.md
required_sections:
  - glob: "packages/*/README.md"
    sections:
      - "不变量（assertions）"
      - "## 测试"
indexes:
  - dir: docs
    index: docs/README.md
''');

    final DocContract contract = await inspectRepository(temp.path);
    expect(contract.ok, isFalse);
    final Set<String> kinds = contract.violations
        .map((DocViolation item) => item.kind)
        .toSet();
    expect(
      kinds,
      containsAll(<String>[
        'required_sections',
        'index_complete',
        'links_resolvable',
      ]),
    );
    expect(
      contract.violations.any(
        (DocViolation item) =>
            item.kind == 'index_complete' && item.detail.contains('extra.md'),
      ),
      isTrue,
    );
    expect(
      contract.violations.any(
        (DocViolation item) =>
            item.kind == 'links_resolvable' && item.detail.contains('nope.md'),
      ),
      isTrue,
    );
  });

  test('规则包未 pin/未实现时 fail-closed，不偷偷联网', () async {
    await expectLater(
      inspectRepository(
        temp.path,
        rulesPackage: <String, Object?>{
          'source': 'git+https://example.com/rules.git',
        },
      ),
      throwsA(
        isA<PolicyFailure>().having(
          (PolicyFailure error) => error.code,
          'code',
          'rules_package_unsupported',
        ),
      ),
    );
  });

  test('本仓契约与 docs_contract_test 同口径', () async {
    final DocContract contract = await inspectRepository(desktop);
    expect(contract.policy.repoFiles, contains('docnorm.yaml'));
    expect(contract.ok, isTrue, reason: _show(contract.violations));
    expect(contract.checks.map((DocCheck check) => check.id).toSet(), <String>{
      'required_docs',
      'required_sections',
      'index_complete',
      'links_resolvable',
      'module_readme',
      'mentions',
    });
    expect(contract.docs.length, greaterThan(10));
    expect(contract.gates['executed'], isFalse);
    expect(
      (contract.gates['commands'] as List<dynamic>).isNotEmpty,
      isTrue,
      reason: 'CONTRIBUTING / development 里应当能静态抽到门禁命令',
    );
  }, skip: hasDesktop ? false : '未找到桌面仓（独立 clone 本插件仓时跳过）');
}

String _show(List<DocViolation> violations) =>
    jsonEncode(violations.map((DocViolation item) => item.toJson()).toList());
