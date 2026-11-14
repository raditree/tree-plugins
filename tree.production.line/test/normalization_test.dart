import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

/// Task 3 的验收（LG-02~07 / AG-04）：
///
/// 锁住：
/// 1. `plan` 复用 docnorm dry-run，0 写盘，manifest 落项目资产；
/// 2. `apply` 写前备份 + before/after sha256，不 git commit，幂等；
/// 3. `rollback` 按备份恢复并校验 sha256，可重复；
/// 4. 整篇改写必须 `confirm_rewrite=true` 且在 allowlist；
/// 5. 路径穿越在 plan 与 apply 两处都被拒绝；
/// 6. 写入失败自动恢复备份并标记 failed；
/// 7. 复合就绪门：LG-02~07 全过才 ready；未就绪时非 cleanup 命令 409
///    `line_not_ready`；organizing 的 cleanup 放行。
void main() {
  late Directory temp;
  late Directory workspace;
  late ProductionStore store;
  late _FakeDocnorm docnorm;
  late ProductionNormalizationService normalization;
  late ProductionService service;
  final DateTime fixed = DateTime(2026, 11, 14, 10);

  setUp(() {
    void write(String relative, String content) {
      final File file = File(
        p.joinAll(<String>[workspace.path, ...relative.split('/')]),
      );
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(content);
    }

    temp = Directory.systemTemp.createTempSync('tree_production_norm_');
    workspace = Directory(p.join(temp.path, 'ws'))
      ..createSync(recursive: true);
    write('pubspec.yaml', 'name: demo\nversion: 0.1.0\ndescription: 演示包\n');
    write('lib/demo.dart', 'class Demo {}\n');
    write('test/demo_test.dart', 'void main() {}\n');
    write('README.md', '# Demo\n');
    store = ProductionStore(dataRoot: temp.path, clock: () => fixed);
    store.createLine(<String, Object?>{
      'id': 'pl_n',
      'name': '归一化',
      'workspace_dir': workspace.path,
      'roles': <String, Object?>{
        'packer': <String, Object?>{'model_id': 'chat/main'},
        'executor': <String, Object?>{'model_id': 'chat/main'},
      },
    });
    handleStructureCommand(
      store,
      'production.structure.reevaluate',
      <String, Object?>{'line_id': 'pl_n'},
    );
    docnorm = _FakeDocnorm(workspace.path);
    normalization = ProductionNormalizationService(
      environment: const <String, String>{},
      clock: () => fixed,
      docnorm: docnorm.call,
    );
    service = ProductionService(
      environment: const <String, String>{},
      clock: () => fixed,
    );
  });

  tearDown(() {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  String read(String relative) =>
      File(p.joinAll(<String>[workspace.path, ...relative.split('/')]))
          .readAsStringSync();

  String assetPath(String runId, String relative) => p.joinAll(<String>[
    workspace.path,
    'docs',
    'production_lines',
    'pl_n',
    'normalization',
    runId,
    ...relative.split('/'),
  ]);

  Map<String, Object?> section({
    String doc = 'README.md',
    String heading = '测试',
    String body = 'dart test',
  }) => <String, Object?>{
    'doc': doc,
    'heading': heading,
    'body': body,
  };

  Future<Map<String, Object?>> call(
    String command,
    Map<String, Object?> arguments,
  ) => normalization.handle(
    command,
    arguments,
    <String, Object?>{'data_dir': temp.path},
    <String, Object?>{'team_id': 'team_a', 'agent_id': 'agt'},
  );

  Map<String, Object?> callSync(
    String command,
    Map<String, Object?> arguments,
  ) => service.handle(
    command,
    arguments,
    <String, Object?>{'data_dir': temp.path},
    <String, Object?>{'team_id': 'team_a', 'agent_id': 'agt'},
  );

  Matcher failure(String code) => throwsA(
    isA<ProductionFailure>().having(
      (ProductionFailure error) => error.code,
      'code',
      code,
    ),
  );

  Map<String, Object?> manifestOf(String runId) {
    final File file = File(assetPath(runId, 'plan.json'));
    return plainMap(jsonDecode(file.readAsStringSync()));
  }

  test('plan：0 写盘、返回 files/rejected/skipped 并落 manifest', () async {
    final String before = read('README.md');
    final Map<String, Object?> plan = await call(
      'production.normalize.plan',
      <String, Object?>{
        'line_id': 'pl_n',
        'sections': <Map<String, Object?>>[section()],
      },
    );
    expect(plan['dry_run'], true);
    expect(plan['writes'], 0);
    expect(read('README.md'), before, reason: 'plan 不得写目标仓库');
    expect(docnorm.commitCalls, 0, reason: 'plan 只能 dry-run');
    final List<Object?> files = plan['files'] as List<Object?>;
    expect(files, hasLength(1));
    final Map<String, Object?> file = plainMap(files.first);
    expect(file['path'], 'README.md');
    expect(stringsOf(file['actions']), contains('append_section'));
    expect(file['diff'], isNotEmpty);
    expect(file['before_sha256'], sha256Hex(utf8.encode(before)));
    expect(plan['rejected'], isA<List<Object?>>());
    expect(plan['skipped'], isA<List<Object?>>());
    expect(plan['manifest'], 'normalization/${plan['run_id']}/plan.json');
    expect(File(assetPath('${plan['run_id']}', 'plan.json')).existsSync(), isTrue);
    expect(manifestOf('${plan['run_id']}')['state'], 'planned');
  });

  test('apply：写盘 + 备份 + before/after sha256；不做 git commit；phase indexing', () async {
    final String before = read('README.md');
    final Map<String, Object?> plan = await call(
      'production.normalize.plan',
      <String, Object?>{
        'line_id': 'pl_n',
        'sections': <Map<String, Object?>>[section()],
      },
    );
    final String runId = '${plan['run_id']}';
    final Map<String, Object?> applied = await call(
      'production.normalize.apply',
      <String, Object?>{'line_id': 'pl_n', 'run_id': runId},
    );
    expect(applied['state'], 'applied');
    expect(applied['applied'], true);
    expect(docnorm.commitCalls, 1);
    final String after = read('README.md');
    expect(after, contains('## 测试'));
    final Map<String, Object?> file = plainMap(
      (applied['files'] as List<Object?>).first,
    );
    expect(file['before_sha256'], sha256Hex(utf8.encode(before)));
    expect(file['after_sha256'], sha256Hex(utf8.encode(after)));
    expect(file['backup'], 'normalization/$runId/before/README.md');
    expect(
      File(assetPath(runId, 'before/README.md')).readAsStringSync(),
      before,
    );
    expect(
      File(assetPath(runId, 'before/README.md')).existsSync(),
      isTrue,
    );
    expect(store.getLine('pl_n').phase, 'indexing');
    expect(docnorm.gitCommits, 0, reason: '归一化不允许自动 git commit');
    final Map<String, Object?> manifest = manifestOf(runId);
    expect(manifest['state'], 'applied');
    expect((manifest['written'] as List<Object?>), contains('README.md'));
  });

  test('重复 apply 幂等：docnorm 0 写、manifest 状态不变', () async {
    final Map<String, Object?> plan = await call(
      'production.normalize.plan',
      <String, Object?>{
        'line_id': 'pl_n',
        'sections': <Map<String, Object?>>[section()],
      },
    );
    final String runId = '${plan['run_id']}';
    await call(
      'production.normalize.apply',
      <String, Object?>{'line_id': 'pl_n', 'run_id': runId},
    );
    final String after = read('README.md');
    final Map<String, Object?> again = await call(
      'production.normalize.apply',
      <String, Object?>{'line_id': 'pl_n', 'run_id': runId},
    );
    expect(again['idempotent'], true);
    expect(again['written'], isEmpty);
    expect(again['state'], 'applied');
    expect(read('README.md'), after);
    expect(manifestOf(runId)['state'], 'applied');
    expect(docnorm.commitCalls, 2);
  });

  test('rollback：恢复备份、核对 sha256，可重复调用', () async {
    final String before = read('README.md');
    final Map<String, Object?> plan = await call(
      'production.normalize.plan',
      <String, Object?>{
        'line_id': 'pl_n',
        'sections': <Map<String, Object?>>[section()],
      },
    );
    final String runId = '${plan['run_id']}';
    await call(
      'production.normalize.apply',
      <String, Object?>{'line_id': 'pl_n', 'run_id': runId},
    );
    final Map<String, Object?> rolled = await call(
      'production.normalize.rollback',
      <String, Object?>{'line_id': 'pl_n', 'run_id': runId},
    );
    expect(rolled['state'], 'rolled_back');
    expect(stringsOf(rolled['restored']), <String>['README.md']);
    expect(read('README.md'), before);
    expect(store.getLine('pl_n').phase, 'normalizing');
    final Map<String, Object?> again = await call(
      'production.normalize.rollback',
      <String, Object?>{'line_id': 'pl_n', 'run_id': runId},
    );
    expect(again['idempotent'], true);
    expect(read('README.md'), before);
    expect(manifestOf(runId)['state'], 'rolled_back');
  });

  test('整篇改写：必须 confirm_rewrite + allowlist', () async {
    final String before = read('README.md');
    final Map<String, Object?> plan = await call(
      'production.normalize.plan',
      <String, Object?>{
        'line_id': 'pl_n',
        'sections': <Map<String, Object?>>[
          <String, Object?>{
            'doc': 'README.md',
            'mode': 'rewrite',
            'content': '# New\n',
          },
        ],
      },
    );
    final String runId = '${plan['run_id']}';
    final Map<String, Object?> file = plainMap(
      (plan['files'] as List<Object?>).first,
    );
    expect(stringsOf(file['actions']), <String>['rewrite']);

    await expectLater(
      call(
        'production.normalize.apply',
        <String, Object?>{'line_id': 'pl_n', 'run_id': runId},
      ),
      failure('rewrite_confirmation_required'),
    );
    await expectLater(
      call(
        'production.normalize.apply',
        <String, Object?>{
          'line_id': 'pl_n',
          'run_id': runId,
          'confirm_rewrite': true,
        },
      ),
      failure('rewrite_not_allowed'),
    );
    expect(read('README.md'), before, reason: '两次拒绝都不得写盘');

    final Map<String, Object?> applied = await call(
      'production.normalize.apply',
      <String, Object?>{
        'line_id': 'pl_n',
        'run_id': runId,
        'confirm_rewrite': true,
        'rewrite_allowlist': <String>['README.md'],
      },
    );
    expect(applied['state'], 'applied');
    expect(read('README.md'), '# New\n');
  });

  test('路径穿越：plan 拒绝，apply 重新校验 manifest', () async {
    docnorm.planFiles = <Map<String, Object?>>[
      <String, Object?>{
        'path': '../escape.md',
        'actions': <String>['append_section'],
        'changed': true,
        'diff': 'x',
      },
    ];
    final Map<String, Object?> plan = await call(
      'production.normalize.plan',
      <String, Object?>{
        'line_id': 'pl_n',
        'sections': <Map<String, Object?>>[section()],
      },
    );
    final List<Map<String, Object?>> rejected = <Map<String, Object?>>[
      for (final Object? item in plan['rejected'] as List<Object?>)
        plainMap(item),
    ];
    expect(
      rejected.any(
        (Map<String, Object?> item) =>
            item['path'] == '../escape.md' &&
            item['reason'] == 'path_outside_workspace',
      ),
      isTrue,
    );
    expect(
      (plan['files'] as List<Object?>).map(
        (Object? item) => plainMap(item)['path'],
      ),
      isNot(contains('../escape.md')),
    );
    expect(File(p.join(temp.path, 'escape.md')).existsSync(), isFalse);

    // 手改 manifest 再 apply：仍必须拒绝（manifest 是不可信输入）。
    final String runId = '${plan['run_id']}';
    final Map<String, Object?> manifest = manifestOf(runId);
    final List<Object?> files = manifest['files'] as List<Object?>;
    files.add(<String, Object?>{
      'path': '../escape.md',
      'actions': <String>['append_section'],
      'changed': true,
      'diff': '',
      'before_sha256': '',
    });
    File(assetPath(runId, 'plan.json')).writeAsStringSync(
      jsonEncode(manifest),
    );
    await expectLater(
      call(
        'production.normalize.apply',
        <String, Object?>{'line_id': 'pl_n', 'run_id': runId},
      ),
      failure('path_outside_workspace'),
    );
  });

  test('apply 失败：自动恢复备份并标记 failed', () async {
    final String before = read('README.md');
    final Map<String, Object?> plan = await call(
      'production.normalize.plan',
      <String, Object?>{
        'line_id': 'pl_n',
        'sections': <Map<String, Object?>>[section()],
      },
    );
    final String runId = '${plan['run_id']}';
    docnorm.failAfterWrite = true;
    await expectLater(
      call(
        'production.normalize.apply',
        <String, Object?>{'line_id': 'pl_n', 'run_id': runId},
      ),
      failure('normalization_apply_failed'),
    );
    expect(read('README.md'), before, reason: '失败必须恢复备份');
    final Map<String, Object?> manifest = manifestOf(runId);
    expect(manifest['state'], 'failed');
    expect(stringsOf(manifest['restored']), contains('README.md'));
    expect('${manifest['error']}', isNotEmpty);
  });

  test('status：返回最新 manifest 与 state', () async {
    final Map<String, Object?> empty = await call(
      'production.normalize.status',
      <String, Object?>{'line_id': 'pl_n'},
    );
    expect(empty['state'], 'none');
    final Map<String, Object?> plan = await call(
      'production.normalize.plan',
      <String, Object?>{
        'line_id': 'pl_n',
        'sections': <Map<String, Object?>>[section()],
      },
    );
    final Map<String, Object?> runId = await call(
      'production.normalize.status',
      <String, Object?>{'line_id': 'pl_n'},
    );
    expect(runId['run_id'], plan['run_id']);
    expect(runId['state'], 'planned');
    expect((runId['files'] as List<Object?>), hasLength(1));
  });

  test('复合就绪门：未就绪拒绝非 cleanup；ready 后放行', () async {
    // 结构通过（normalizing）但还没归一化 / 建索引。
    expect(
      () => callSync('production.task.create', <String, Object?>{
        'line_id': 'pl_n',
        'title': '需求',
        'status': 'queued',
      }),
      throwsA(
        isA<ProductionFailure>()
            .having(
              (ProductionFailure error) => error.code,
              'code',
              'line_not_ready',
            )
            .having(
              (ProductionFailure error) => error.missing,
              'missing',
              isNotEmpty,
            ),
      ),
    );

    final Map<String, Object?> plan = await call(
      'production.normalize.plan',
      <String, Object?>{
        'line_id': 'pl_n',
        'sections': <Map<String, Object?>>[section()],
      },
    );
    await call(
      'production.normalize.apply',
      <String, Object?>{'line_id': 'pl_n', 'run_id': plan['run_id']},
    );
    final ProductionReadinessService readiness = ProductionReadinessService(
      environment: const <String, String>{},
      clock: () => fixed,
      docnorm: docnorm.call,
      dedupStatus: docnorm.dedupStatus,
    );
    final Map<String, Object?> result = await readiness.handle(
      'production.readiness.get',
      <String, Object?>{'line_id': 'pl_n'},
      <String, Object?>{'data_dir': temp.path},
      <String, Object?>{},
    );
    expect(result['ready'], true, reason: '${result['missing']}');
    expect(result['phase'], 'ready');
    final List<Map<String, Object?>> checks = <Map<String, Object?>>[
      for (final Object? item in result['checks'] as List<Object?>)
        plainMap(item),
    ];
    expect(
      checks.map((Map<String, Object?> item) => item['id']),
      containsAll(<String>['LG-02', 'LG-03', 'LG-04', 'LG-05', 'LG-06', 'LG-07']),
    );
    expect(
      checks.every(
        (Map<String, Object?> item) => item['status'] == 'pass',
      ),
      isTrue,
      reason: '${checks.where((Map<String, Object?> item) => item['status'] != 'pass')}',
    );
    expect(File(store.readyFile('pl_n')).existsSync(), isTrue);
    expect(plainMap(callSync('production.line.get', <String, Object?>{
      'line_id': 'pl_n',
    })['line'])['ready'], true);

    final Map<String, Object?> created = callSync(
      'production.task.create',
      <String, Object?>{
        'line_id': 'pl_n',
        'title': '需求',
        'status': 'queued',
        'brief': '需求内容',
        'acceptance': <String>['验收通过'],
        'write_scope': <String>['lib/root.dart'],
      },
    );
    expect(plainMap(created['task'])['id'], isNotEmpty);
  });

  test('就绪信号缺失（去重通道未接）⇒ 未就绪并给出 missing，不假通过', () async {
    final Map<String, Object?> plan = await call(
      'production.normalize.plan',
      <String, Object?>{
        'line_id': 'pl_n',
        'sections': <Map<String, Object?>>[section()],
      },
    );
    await call(
      'production.normalize.apply',
      <String, Object?>{'line_id': 'pl_n', 'run_id': plan['run_id']},
    );
    final ProductionReadinessService readiness = ProductionReadinessService(
      environment: const <String, String>{},
      clock: () => fixed,
      docnorm: docnorm.call,
    );
    final Map<String, Object?> result = await readiness.handle(
      'production.readiness.get',
      <String, Object?>{'line_id': 'pl_n'},
      <String, Object?>{'data_dir': temp.path},
      <String, Object?>{},
    );
    expect(result['ready'], isFalse);
    expect(stringsOf(result['missing']), contains('LG-05'));
    expect(stringsOf(result['missing']), contains('dedup_index'));
    expect(result['phase'], 'indexing');
    expect(
      () => callSync('production.task.create', <String, Object?>{
        'line_id': 'pl_n',
        'title': '需求',
        'status': 'queued',
      }),
      failure('line_not_ready'),
    );
  });

  test('organizing 阶段的 cleanup 任务放行', () {
    store.createLine(<String, Object?>{
      'id': 'pl_c',
      'name': '整理',
      'workspace_dir': workspace.path,
    });
    final Map<String, Object?> created = callSync(
      'production.task.create',
      <String, Object?>{
        'line_id': 'pl_c',
        'title': '清理依赖',
        'task_type': 'cleanup',
        'status': 'queued',
        'write_scope': <String>['lib/demo.dart'],
        'acceptance': <String>['结构重审通过'],
      },
    );
    expect(plainMap(created['task'])['task_type'], 'cleanup');
  });
}

/// 会真实写盘的假 docnorm：append / rewrite / 失败注入 / 图与去重证据。
class _FakeDocnorm {
  _FakeDocnorm(this.workspace);

  final String workspace;
  int baselineCalls = 0;
  int commitCalls = 0;
  int gitCommits = 0;
  int graphCalls = 0;

  /// 仓库文档数（readiness 的 LG-02 证据）。
  int docs = 1;
  int packages = 1;

  /// plan 追加的额外文件（路径穿越用例）。
  List<Map<String, Object?>> planFiles = const <Map<String, Object?>>[];

  /// 写盘后抛错（验证失败自动回滚）。
  bool failAfterWrite = false;

  String head = 'h1';

  Future<Map<String, Object?>> call(
    String command,
    Map<String, Object?> arguments,
    Map<String, Object?> scope,
  ) async {
    if (command == 'docnorm.baseline') return _baseline(arguments);
    if (command == 'docnorm.graph.build') {
      graphCalls += 1;
      return <String, Object?>{
        'command': 'docnorm.graph.build',
        'repo': workspace,
        'mode': 'deterministic',
        'dry_run': arguments['commit'] != true,
        'committed': arguments['commit'] == true,
        'git': <String, Object?>{'head': head},
        'nodes': <Object?>[],
        'edges': <Object?>[],
        'counts': <String, Object?>{
          'nodes': 3,
          'edges': 2,
          'docs': docs,
          'packages': packages,
        },
        'storage': <String, Object?>{'applied': false, 'ops': 0},
      };
    }
    throw StateError('_FakeDocnorm 不支持：$command');
  }

  Map<String, Object?> _baseline(Map<String, Object?> arguments) {
    baselineCalls += 1;
    final bool commit = arguments['commit'] == true;
    if (commit) commitCalls += 1;
    final List<Object?> sections = arguments['sections'] is List
        ? arguments['sections'] as List<Object?>
        : <Object?>[];
    final List<Map<String, Object?>> files = <Map<String, Object?>>[];
    final List<String> written = <String>[];
    for (final Object? raw in sections) {
      final Map<String, Object?> proposal = plainMap(raw);
      final String doc = textOf(proposal['doc']);
      final File file = File(p.joinAll(<String>[workspace, ...doc.split('/')]));
      if (!file.existsSync()) continue;
      final String before = file.readAsStringSync();
      final String mode = textOf(proposal['mode']);
      if (mode == 'rewrite' || proposal['content'] != null) {
        final String after = '${proposal['content'] ?? ''}';
        if (after == before) continue;
        files.add(<String, Object?>{
          'path': doc,
          'actions': <String>['rewrite'],
          'changed': true,
          'diff': '--- a/$doc\n+++ b/$doc\n',
        });
        if (commit) {
          file.writeAsStringSync(after);
          written.add(doc);
        }
        continue;
      }
      final String rawHeading = textOf(proposal['heading']);
      if (rawHeading.isEmpty) continue;
      final String heading = rawHeading.startsWith('#')
          ? rawHeading
          : '## $rawHeading';
      if (before.contains(heading)) continue;
      final String body = textOf(proposal['body']);
      final String after = before.endsWith('\n')
          ? '$before\n$heading\n\n$body\n'
          : '$before\n\n$heading\n\n$body\n';
      files.add(<String, Object?>{
        'path': doc,
        'actions': <String>['append_section'],
        'changed': true,
        'diff': '--- a/$doc\n+++ b/$doc\n+$heading',
      });
      if (commit) {
        file.writeAsStringSync(after);
        written.add(doc);
        if (failAfterWrite) {
          failAfterWrite = false;
          throw StateError('写盘后断网');
        }
      }
    }
    files.addAll(planFiles);
    return <String, Object?>{
      'command': 'docnorm.baseline',
      'repo': workspace,
      'repo_key': workspace,
      'run_id': arguments['run_id'] ?? '',
      'dry_run': !commit,
      'committed': commit,
      'code_fingerprint': 'fp1',
      'git': <String, Object?>{'head': head},
      'contract': <String, Object?>{
        'ok': true,
        'docs': docs,
        'violations': 0,
        'degraded': false,
        'unknown': <String>[],
      },
      'packages': <String, Object?>{
        'total': packages,
        'ids': <String>[for (int i = 0; i < packages; i++) 'pkg-$i'],
        'degraded': false,
      },
      'plan': <String, Object?>{
        'files': files,
        'skipped': <Map<String, Object?>>[],
        'rejected': <Map<String, Object?>>[],
        'rewrite_allowlist': arguments['rewrite_allowlist'] ?? <String>[],
      },
      'would_write': <String>[],
      'written': written,
      'doc_state': <String, Object?>{
        'updated': <String>[for (int i = 0; i < packages; i++) 'pkg-$i'],
        'documents': <String, Object?>{
          for (int i = 0; i < docs; i++) 'doc-$i.md': <String, Object?>{},
        },
        'packages': <String, Object?>{
          for (int i = 0; i < packages; i++)
            'pkg-$i': <String, Object?>{'stale': false},
        },
      },
      'storage': <String, Object?>{
        'ok': true,
        'writes': <Object?>[],
        'applied': commit,
      },
    };
  }

  Future<Map<String, Object?>> dedupStatus(
    String lineId,
    Map<String, Object?> meta,
    Map<String, Object?> scope,
  ) async => <String, Object?>{
    'command': 'production.dedup.status',
    'line_id': lineId,
    'run': <String, Object?>{
      'run_id': 'dedup-1',
      'mode': 'hybrid',
      'head_sha': head,
      'base_sha': head,
      'degraded': false,
      'counts': <String, Object?>{
        'chunks': 2,
        'vectors': 2,
        'results': 0,
      },
    },
    'counts': <String, Object?>{'results': 0},
    'degraded': false,
  };
}
