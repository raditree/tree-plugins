// tree.docnorm —— 文档归一化（DN-2：扫描 + 包图 + 六族适配层骨架）。
//
// 定位（docs/doc-normalization-recon.md §1/§5/§7）：
// - headless 插件，只读目标仓库，不修改代码/配置；
// - 暴露自建执行站命令 `docnorm.scan`（后续 DN-3+ 追加契约/计划/注入命令）；
// - 六族适配器：Dart / Python / Go / Rust / Node-TS(含 Vue) / Web-HTTP，未覆盖走 fallback；
// - 输出包图：包 id / root / 行数 / 子包 / 公开声明 / API 面 / 依赖；
// - 依赖纪律：不得 import 任何核心包。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tree_docnorm/tree_docnorm.dart';

import '../_kit/plugin_kit.dart';

const String kPluginId = 'tree.docnorm';
const String kDisplayName = 'Tree 文档归一化';
const String kVersion = '0.5.0';
const String kStationName = 'docnorm';
const List<String> kDocnormCommands = <String>[
  'docnorm.scan',
  'docnorm.contract',
  'docnorm.check',
  'docnorm.plan',
  'docnorm.generate',
  'docnorm.audit',
  'docnorm.baseline',
  'docnorm.reanalyze',
];

const String kStationReadme =
    '文档归一化：docnorm.scan 扫描目标仓库，返回包图（包/子包/行数/公开声明/API 面/依赖）；'
    'docnorm.contract 侦查文档契约（章节/索引/链接/CHANGELOG/门禁，规则按 内置→仓库自述 合成）；'
    'docnorm.check 只跑 DocPolicy 四条检查；'
    'docnorm.plan 只读归集 git 内容变更并给出注入单元与 context_cap/stage_budget 两额度估计（stat-dirty 不产计划）；'
    'docnorm.generate 经 llm.call 为单元 README 生成缺失章节提案（三模式×三档、context_cap 闸、只补缺、失败即 degraded）；'
    'docnorm.audit [--commit] 产四类建议（reuse/split_size/split_function/api_boundary）并补全 pkg_index 的收束事实/quality/stale（阈值读策略，默认 dry-run）；'
    'docnorm.baseline [--commit] 建 L0（doc_contract/pkg_index/doc_state 入 tree.storage）并按提案只追加缺章节（默认 dry-run）；'
    'docnorm.reanalyze --changed 只重算受影响包。六族适配器 + fallback；对目标仓库只读，'
    '写盘仅追加且必须显式 commit；缺 tree.storage 时 fail-closed。';

/// 当前握手完成的插件服务（由 [_onReady] 填入），用于向 tree.storage 下站命令。
PluginKitServer? _activeServer;

PluginKitServer buildServer({bool exitOnShutdown = true}) => PluginKitServer(
  channel: PluginChannel.stdio(kPluginId),
  pluginId: kPluginId,
  displayName: kDisplayName,
  onReady: _onReady,
  onRequest: handleRequest,
  exitOnShutdown: exitOnShutdown,
);

Future<void> _onReady(PluginKitServer server) async {
  _activeServer = server;
  server.channel.log('已上线：v$kVersion（tree.docnorm，DN-4/5/6/7）');
  try {
    final Map<String, dynamic> result = await server.channel.request(
      M.stationRegister,
      <String, dynamic>{
        'kind': 'execute',
        'name': kStationName,
        'description': '文档归一化扫描（docnorm.*）',
        'readme': kStationReadme,
        'commands': kDocnormCommands,
      },
    );
    server.channel.log(
      '自建执行站：${result['ok'] == true ? result['station_id'] : result['error']}',
    );
  } catch (error) {
    server.channel.log('自建执行站失败：$error');
  }
}

Future<Map<String, dynamic>?> handleRequest(
  String method,
  Map<String, dynamic> params,
) async {
  if (method != M.stationRequest) return null;
  final Map<String, dynamic> payload = asMap(params['payload']);
  final String command = asString(payload['command']);
  if (!kDocnormCommands.contains(command)) return null;
  final Map<String, dynamic> arguments = asMap(payload['arguments']);
  try {
    final String repo = asString(arguments['repo']);
    if (repo.isEmpty) {
      return <String, dynamic>{
        'reply': <String, dynamic>{
          'error': '$command 需要 repo（目标仓库路径）',
          'code': 'invalid_arguments',
        },
      };
    }
    if (command == 'docnorm.scan') {
      final ScanResult result = await scanRepository(repo);
      return <String, dynamic>{
        'reply': <String, dynamic>{'payload': result.toJson()},
      };
    }
    if (command == 'docnorm.plan') {
      final Map<String, Object?> result = await runPlan(
        repo,
        mode: asString(arguments['mode']),
        overrides: arguments['config'] is Map
            ? asMap(arguments['config'])
            : const <String, Object?>{},
      );
      return <String, dynamic>{
        'reply': <String, dynamic>{'payload': result},
      };
    }
    if (command == 'docnorm.generate') {
      final Map<String, dynamic> scope = asMap(params['scope']);
      Future<GenerateReply> llm(GenerateRequest request) =>
          _callLlm(request, scope);
      final Map<String, Object?> result = await runGenerate(
        repo,
        llm: llm,
        mode: asString(arguments['mode']),
        tier: asString(arguments['tier']),
        overrides: arguments['config'] is Map
            ? asMap(arguments['config'])
            : const <String, Object?>{},
      );
      return <String, dynamic>{
        'reply': <String, dynamic>{'payload': result},
      };
    }
    if (command == 'docnorm.audit') {
      final Map<String, dynamic> scope = asMap(params['scope']);
      Future<Map<String, dynamic>> storage(
        String name,
        Map<String, dynamic> args,
      ) => _callStorage(name, args, scope);
      final Map<String, Object?> result = await runAudit(
        repo,
        storage: storage,
        commit: arguments['commit'] == true,
        runId: asString(arguments['run_id']),
      );
      return <String, dynamic>{
        'reply': <String, dynamic>{'payload': result},
      };
    }
    if (command == 'docnorm.baseline' || command == 'docnorm.reanalyze') {
      final Map<String, dynamic> scope = asMap(params['scope']);
      Future<Map<String, dynamic>> storage(
        String name,
        Map<String, dynamic> args,
      ) => _callStorage(name, args, scope);
      final Map<String, Object?> result = command == 'docnorm.baseline'
          ? await runBaseline(
              repo,
              storage: storage,
              commit: arguments['commit'] == true,
              sections: _mapsOf(arguments['sections']),
              indexes: _mapsOf(arguments['indexes']),
              rewriteAllowlist: _stringsOf(arguments['rewrite_allowlist']),
              runId: asString(arguments['run_id']),
            )
          : await runReanalyze(
              repo,
              storage: storage,
              changed: arguments['changed'] == true,
              commit: arguments['commit'] == true,
              sections: _mapsOf(arguments['sections']),
              indexes: _mapsOf(arguments['indexes']),
              rewriteAllowlist: _stringsOf(arguments['rewrite_allowlist']),
              runId: asString(arguments['run_id']),
            );
      return <String, dynamic>{
        'reply': <String, dynamic>{'payload': result},
      };
    }
    final DocContract contract = await inspectRepository(
      repo,
      rulesPackage: arguments['rules'] is Map
          ? asMap(arguments['rules'])
          : null,
    );
    if (command == 'docnorm.contract') {
      return <String, dynamic>{
        'reply': <String, dynamic>{'payload': contract.toJson()},
      };
    }
    // docnorm.check：只回检查面，不重复契约明细。
    return <String, dynamic>{
      'reply': <String, dynamic>{
        'payload': <String, dynamic>{
          'repo': contract.repo,
          'ok': contract.ok,
          'rules': contract.policy.toJson(),
          'checks': contract.checks
              .map((DocCheck item) => item.toJson())
              .toList(),
          'violations': contract.violations
              .map((DocViolation item) => item.toJson())
              .toList(),
          'unknown': contract.unknown,
          'degraded': contract.degraded,
        },
      },
    };
  } on BaselineFailure catch (error) {
    return <String, dynamic>{
      'reply': <String, dynamic>{'error': error.message, 'code': error.code},
    };
  } on PlanFailure catch (error) {
    return <String, dynamic>{
      'reply': <String, dynamic>{'error': error.message, 'code': error.code},
    };
  } on PolicyFailure catch (error) {
    return <String, dynamic>{
      'reply': <String, dynamic>{'error': error.message, 'code': error.code},
    };
  } on ScanFailure catch (error) {
    return <String, dynamic>{
      'reply': <String, dynamic>{'error': error.message, 'code': error.code},
    };
  } catch (error) {
    return <String, dynamic>{
      'reply': <String, dynamic>{'error': '扫描失败：$error', 'code': 'scan_error'},
    };
  }
}

/// 向 `tree.storage` 下一条站命令：身份 / 团队只透传核心给本次请求的 scope。
///
/// 缺失时由存储侧拒绝（`identity_required` / `team_required`），这里收敛成
/// `storage_unavailable`，让 baseline 在写盘前 fail-closed（TC-ST-10）。
Future<Map<String, dynamic>> _callStorage(
  String command,
  Map<String, dynamic> arguments,
  Map<String, dynamic> scope,
) {
  final PluginKitServer? server = _activeServer;
  if (server == null) {
    throw BaselineFailure(
      '插件尚未就绪：tree.storage 通道不可用',
      code: 'storage_unavailable',
    );
  }
  return server.channel.command(command, arguments, '', scope);
}

/// 向 `tree.agent` 的宿主能力站下 `llm.call`：身份 / 团队只透传本次请求的 scope。
///
/// 失败也把已付费的 `text` / `json` 带回 [GenerateReply]（known-issues #31），
/// 由生成层统一判成 `degraded`，绝不用占位正文补齐。
Future<GenerateReply> _callLlm(
  GenerateRequest request,
  Map<String, dynamic> scope,
) async {
  final PluginKitServer? server = _activeServer;
  if (server == null) {
    return const GenerateReply(error: '插件尚未就绪：llm.call 通道不可用');
  }
  try {
    final Map<String, dynamic> payload = await server.channel.command(
      'llm.call',
      <String, dynamic>{
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'system', 'content': request.system},
          <String, dynamic>{'role': 'user', 'content': request.prompt},
        ],
      },
      '',
      scope,
    );
    final String reason = asString(payload['error']);
    return GenerateReply(
      text: asString(payload['text']),
      json: payload['json'],
      error: reason.trim().isNotEmpty
          ? reason
          : (payload['ok'] == false ? 'llm.call 返回 ok:false' : ''),
    );
  } on CmdFailureException catch (error) {
    return GenerateReply(
      text: asString(error.payload['text']),
      json: error.payload['json'],
      error: error.message,
    );
  } catch (error) {
    return GenerateReply(error: 'llm.call 异常：$error');
  }
}

List<Map<String, Object?>> _mapsOf(Object? value) {
  if (value is! List) return const <Map<String, Object?>>[];
  return <Map<String, Object?>>[
    for (final Object? item in value)
      if (item is Map) asMap(item),
  ];
}

List<String> _stringsOf(Object? value) {
  if (value is! List) return const <String>[];
  return <String>[
    for (final Object? item in value)
      if (asString(item).isNotEmpty) asString(item),
  ];
}

Future<void> main(List<String> args) async {
  if (args.contains('--selftest')) {
    exitCode = await selfTest();
    return;
  }
  await buildServer().run(stdin);
  try {
    await stdout.flush();
  } catch (_) {}
}

/// 假核心自检：注册面 + 六族扫描 + 命令回包。
Future<int> selfTest() async {
  final SelfTest check = SelfTest(name: 'tree_docnorm_plugin');
  final Directory temp = Directory.systemTemp.createTempSync(
    'tree_docnorm_selftest_',
  );
  final FakeCore core = FakeCore(buildServer(exitOnShutdown: false));
  core.onMethod(
    M.stationRegister,
    (Map<String, dynamic> params) => <String, dynamic>{
      'ok': true,
      'station_id': 'docnorm',
    },
  );

  void write(String path, String content) {
    final File file = File('${temp.path}${Platform.pathSeparator}$path');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  try {
    write('pubspec.yaml', 'name: demo_dart\ndependencies:\n  yaml: ^3.1.0\n');
    write('lib/a.dart', 'class Alpha {}\nclass Beta {}\n');
    write('lib/src/one.dart', 'class One {}\n');
    write('lib/src/two.dart', 'class Two {}\n');
    write('lib/src/three.dart', 'class Three {}\n');
    write(
      'package.json',
      '{"name":"demo_web","dependencies":{"vue":"^3.0.0"}}',
    );
    write('src/index.ts', 'export function boot() {}\n');
    write(
      'src/App.vue',
      '<script setup lang="ts">\nconst props = defineProps<{title: string}>()\n</script>\n',
    );
    write('go.mod', 'module example.com/demo\n\ngo 1.22\n');
    write(
      'main.go',
      'package main\n\ntype Server struct{}\n\nfunc Start() {}\n',
    );
    write('Cargo.toml', '[package]\nname = "demo_rust"\nversion = "0.1.0"\n');
    write('src/lib.rs', 'pub struct Config;\npub fn run() {}\n');
    write('pyproject.toml', '[project]\nname = "demo_py"\n');
    write('demo_py/mod.py', 'class Model:\n    pass\n\ndef run():\n    pass\n');
    write(
      'openapi.yaml',
      'openapi: 3.0.0\npaths:\n  /pets:\n    get: {}\n    post: {}\n',
    );
    write('api.http', 'GET /health\nPOST /login\n');
    write('README.md', '# demo\n');
    write('docs/README.md', '- [a.md](a.md)\n');
    write('docs/a.md', '# A\n');
    write('docnorm.yaml', '''
version: 1
required_docs:
  - README.md
  - docs/README.md
indexes:
  - dir: docs
    index: docs/README.md
thresholds:
  package_lines: 1
  file_lines: 1
''');

    bool gitOk = true;
    try {
      Process.runSync('git', <String>[
        'init',
        '--quiet',
      ], workingDirectory: temp.path);
      Process.runSync('git', <String>[
        'add',
        '-A',
      ], workingDirectory: temp.path);
      final ProcessResult committed = Process.runSync('git', <String>[
        '-c',
        'user.name=selftest',
        '-c',
        'user.email=selftest@local',
        'commit',
        '--quiet',
        '--no-gpg-sign',
        '-m',
        'fixture',
      ], workingDirectory: temp.path);
      gitOk = committed.exitCode == 0;
    } catch (_) {
      gitOk = false;
    }

    // 假 tree.storage：只实现 baseline 用到的只读/写入命令。
    final Map<String, Map<String, Map<String, Object?>>> fakeDb =
        <String, Map<String, Map<String, Object?>>>{};
    Map<String, Map<String, Object?>> collectionOf(String name) =>
        fakeDb.putIfAbsent(name, () => <String, Map<String, Object?>>{});
    int storageWrites = 0;
    core.onMethod(M.stationCommand, (Map<String, dynamic> params) {
      final String command = asString(params['command']);
      final Map<String, dynamic> args = asMap(params['arguments']);
      final String collection = asString(args['collection']);
      final Map<String, Map<String, Object?>> records = collectionOf(
        collection,
      );
      switch (command) {
        case 'llm.call':
          final List<dynamic> messages = args['messages'] is List
              ? args['messages'] as List<dynamic>
              : <dynamic>[];
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{
              'ok': messages.isNotEmpty,
              'json': <String, dynamic>{
                'sections': <Map<String, dynamic>>[
                  <String, dynamic>{'heading': '职责', 'body': '示例包负责单一职责的演示。'},
                  <String, dynamic>{'heading': '入口', 'body': '从 lib/a.dart 的 Alpha 进入。'},
                  <String, dynamic>{'heading': '边界', 'body': '不处理网络与持久化，只做类型定义。'},
                  <String, dynamic>{'heading': '测试', 'body': '运行 dart test 覆盖声明与边界。'},
                ],
              },
              'text': '{}',
              'model': 'fake',
              'usage': <String, dynamic>{'total_tokens': 10},
            },
          };
        case 'storage.ensure':
          storageWrites += 1;
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{
              'collection': collection,
              'schema_version': args['schema_version'] ?? 1,
            },
          };
        case 'storage.scan':
          final String prefix = asString(args['prefix']);
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
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{
              'values': values,
              'count': values.length,
            },
          };
        case 'storage.get':
          final Map<String, Object?>? value = records[asString(args['key'])];
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{
              'value': value,
              'rev': value == null ? 0 : 1,
            },
          };
        case 'storage.put':
          storageWrites += 1;
          records[asString(args['key'])] = Map<String, Object?>.from(
            asMap(args['value']),
          );
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{'rev': 1},
          };
        case 'storage.delete':
          storageWrites += 1;
          records.remove(asString(args['key']));
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{'deleted': true},
          };
        case 'storage.tx':
          storageWrites += 1;
          final List<dynamic> ops = args['ops'] is List
              ? args['ops'] as List<dynamic>
              : <dynamic>[];
          for (final Object? raw in ops) {
            if (raw is! Map) continue;
            final Map<String, dynamic> op = asMap(raw);
            final Map<String, Map<String, Object?>> target = collectionOf(
              asString(op['collection']),
            );
            if (asString(op['op']) == 'delete') {
              target.remove(asString(op['key']));
            } else {
              target[asString(op['key'])] = Map<String, Object?>.from(
                asMap(op['value']),
              );
            }
          }
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{
              'committed': true,
              'count': ops.length,
            },
          };
        default:
          return <String, dynamic>{
            'ok': false,
            'error': '未知存储命令：$command',
            'code': 'unknown_command',
          };
      }
    });

    final ScanResult result = await scanRepository(temp.path);
    check.that(
      result.packages.length >= 6,
      '六族适配器都扫出了包',
      actual: result.packages.map((PackageUnit p) => p.id).join(','),
    );
    check.that(
      result.adapters.toSet().containsAll(<String>[
        'dart',
        'node',
        'go',
        'rust',
        'python',
        'http',
      ]),
      '适配器命中：dart/node/go/rust/python/http',
      actual: result.adapters.join(','),
    );
    final PackageUnit dart = result.packages.firstWhere(
      (PackageUnit p) => p.language == 'dart',
    );
    check.check(dart.id, 'demo_dart', 'Dart 包名来自 pubspec');
    check.that(dart.exports.contains('Alpha'), 'Dart 公开声明被抽取');
    check.that(dart.subpackages.isNotEmpty, 'Dart 子包按文件数发现（lib/src）');
    final PackageUnit node = result.packages.firstWhere(
      (PackageUnit p) => p.language == 'node',
    );
    check.that(node.exports.contains('boot'), 'Node export 函数被抽取');
    check.that(node.exports.contains('title'), 'Vue defineProps 字段被抽取');
    final PackageUnit http = result.packages.firstWhere(
      (PackageUnit p) => p.language == 'http',
    );
    check.check(http.api.count, 4, 'HTTP 端点：OpenAPI 2 + .http 2');
    check.check(result.degraded, false, '六族齐全时 degraded=false');

    unawaited(core.start());
    core.ask('hello', M.hello, <String, dynamic>{'plugin_id': kPluginId});
    await core.waitFor(<Object?>['hello']);
    final List<Map<String, dynamic>> registrations = core.outgoing(
      M.stationRegister,
    );
    check.check(registrations.length, 1, '启动后注册一个自建执行站');
    check.check(
      asMap(registrations.first['params'])['kind'],
      'execute',
      '执行站 kind=execute',
    );

    core.ask('scan', M.stationRequest, <String, dynamic>{
      'payload': <String, dynamic>{
        'command': 'docnorm.scan',
        'arguments': <String, dynamic>{'repo': temp.path},
      },
      'meta': <String, dynamic>{'source_plugin_id': 'tree.production.line'},
      'scope': <String, dynamic>{'team_id': 'team_a'},
    });
    final Map<Object?, Map<String, dynamic>> responses = await core.waitFor(
      <Object?>['scan'],
    );
    final Map<String, dynamic> reply = asMap(
      asMap(responses['scan']?['result'])['reply'],
    );
    final Map<String, dynamic> payload = asMap(reply['payload']);
    check.that(
      (payload['packages'] as List<dynamic>?)?.isNotEmpty == true,
      '命令回包带 packages',
    );
    check.that(payload.containsKey('degraded'), '命令回包带 degraded');
    check.that(jsonEncode(payload).contains('demo_dart'), '命令回包包含 Dart 包');

    core.ask('contract', M.stationRequest, <String, dynamic>{
      'payload': <String, dynamic>{
        'command': 'docnorm.contract',
        'arguments': <String, dynamic>{'repo': temp.path},
      },
      'meta': <String, dynamic>{'source_plugin_id': 'tree.production.line'},
      'scope': <String, dynamic>{'team_id': 'team_a'},
    });
    final Map<String, dynamic> contractReply = asMap(
      asMap(
        (await core.waitFor(<Object?>['contract']))['contract']?['result'],
      )['reply'],
    );
    final Map<String, dynamic> contract = asMap(contractReply['payload']);
    check.check(contract['ok'], true, '契约侦查通过（README + docs 索引齐）');
    check.that(
      (contract['checks'] as List<dynamic>?)?.length == 6,
      '契约回包带 6 项检查（四条核心 + 模块/点名扩展）',
    );
    final Map<String, dynamic> rules = asMap(contract['rules']);
    check.that(
      (rules['layers'] as List<dynamic>?)?.contains('repo') == true,
      '规则层合并了仓库自述 docnorm.yaml',
    );
    check.check(rules['repo_files'], <dynamic>['docnorm.yaml'], '规则来源可追溯');

    core.ask('check', M.stationRequest, <String, dynamic>{
      'payload': <String, dynamic>{
        'command': 'docnorm.check',
        'arguments': <String, dynamic>{'repo': temp.path},
      },
      'meta': <String, dynamic>{'source_plugin_id': 'tree.production.line'},
      'scope': <String, dynamic>{'team_id': 'team_a'},
    });
    final Map<String, dynamic> checkReply = asMap(
      asMap(
        (await core.waitFor(<Object?>['check']))['check']?['result'],
      )['reply'],
    );
    final Map<String, dynamic> checkPayload = asMap(checkReply['payload']);
    check.check(checkPayload['ok'], true, 'docnorm.check 只回检查面且通过');
    check.that(
      !checkPayload.containsKey('sections'),
      'docnorm.check 不重复契约明细（无 sections）',
    );

    Future<Map<String, dynamic>> askCommand(
      Object id,
      String command,
      Map<String, dynamic> arguments,
    ) async {
      core.ask(id, M.stationRequest, <String, dynamic>{
        'payload': <String, dynamic>{
          'command': command,
          'arguments': arguments,
        },
        'meta': <String, dynamic>{'source_plugin_id': 'tree.production.line'},
        'scope': <String, dynamic>{'team_id': 'team_a'},
      });
      final Map<Object?, Map<String, dynamic>> responses = await core.waitFor(
        <Object?>[id],
      );
      return asMap(asMap(responses[id]?['result'])['reply']);
    }

    if (!gitOk) {
      check.that(true, 'git 不可用，跳过 baseline / reanalyze 自检');
    } else {
      final Map<String, dynamic> dryReply = await askCommand(
        'baseline-dry',
        'docnorm.baseline',
        <String, dynamic>{
          'repo': temp.path,
          'commit': false,
          'sections': <Map<String, dynamic>>[
            <String, dynamic>{
              'doc': 'README.md',
              'heading': '## 测试',
              'body': 'dart test',
            },
          ],
        },
      );
      final Map<String, dynamic> dryPayload = asMap(dryReply['payload']);
      check.check(dryPayload['dry_run'], true, 'baseline 默认 dry-run');
      check.check(
        (dryPayload['written'] as List<dynamic>?)?.isEmpty,
        true,
        'dry-run 不写目标仓库',
      );
      check.check(
        (dryPayload['would_write'] as List<dynamic>?)?.length,
        1,
        'dry-run 出 1 个落盘计划',
      );
      check.check(storageWrites, 0, 'dry-run 0 存储写');
      check.that(
        !File('${temp.path}${Platform.pathSeparator}README.md')
            .readAsStringSync()
            .contains('## 测试'),
        'dry-run 未追加章节',
      );

      final Map<String, dynamic> commitReply = await askCommand(
        'baseline-commit',
        'docnorm.baseline',
        <String, dynamic>{
          'repo': temp.path,
          'commit': true,
          'sections': <Map<String, dynamic>>[
            <String, dynamic>{
              'doc': 'README.md',
              'heading': '## 测试',
              'body': 'dart test',
            },
          ],
        },
      );
      final Map<String, dynamic> commitPayload = asMap(commitReply['payload']);
      check.that(
        (commitPayload['written'] as List<dynamic>?)?.contains('README.md') ==
            true,
        'baseline --commit 追章节',
      );
      check.that(
        File('${temp.path}${Platform.pathSeparator}README.md')
            .readAsStringSync()
            .contains('## 测试'),
        'README 落盘包含新章节',
      );
      check.that(
        (fakeDb['doc_contract'] ?? <String, Map<String, Object?>>{}).isNotEmpty,
        'doc_contract 入库',
      );
      check.that(
        (fakeDb['pkg_index'] ?? <String, Map<String, Object?>>{}).isNotEmpty,
        'pkg_index 入库',
      );
      check.that(
        (fakeDb['doc_state'] ?? <String, Map<String, Object?>>{}).isNotEmpty,
        'doc_state 入库',
      );
      final int writesAfterCommit = storageWrites;

      final Map<String, dynamic> againReply = await askCommand(
        'baseline-again',
        'docnorm.baseline',
        <String, dynamic>{
          'repo': temp.path,
          'commit': true,
          'sections': <Map<String, dynamic>>[
            <String, dynamic>{
              'doc': 'README.md',
              'heading': '## 测试',
              'body': 'dart test',
            },
          ],
        },
      );
      final Map<String, dynamic> againPayload = asMap(againReply['payload']);
      check.check(
        (againPayload['written'] as List<dynamic>?)?.length,
        0,
        '重复运行 0 文件写',
      );
      check.check(storageWrites, writesAfterCommit, '重复运行 0 存储写');

      final File source = File(
        '${temp.path}${Platform.pathSeparator}lib${Platform.pathSeparator}a.dart',
      );
      source.writeAsStringSync(
        'class Alpha {}\nclass Beta {}\nclass Gamma {}\n',
      );
      final Map<String, dynamic> reanalyzeReply = await askCommand(
        'reanalyze',
        'docnorm.reanalyze',
        <String, dynamic>{'repo': temp.path, 'changed': true, 'commit': true},
      );
      final Map<String, dynamic> reanalyzePayload = asMap(
        reanalyzeReply['payload'],
      );
      check.that(
        (reanalyzePayload['affected_packages'] as List<dynamic>?)?.isNotEmpty ==
            true,
        'reanalyze 命中受影响包',
      );
      check.that(
        (reanalyzePayload['recomputed'] as List<dynamic>?)?.isNotEmpty == true,
        'reanalyze 重算受影响包',
      );
      check.check(
        asMap(reanalyzePayload['storage'])['applied'],
        true,
        'reanalyze 写回状态',
      );

      final Map<String, dynamic> planReply = await askCommand(
        'plan',
        'docnorm.plan',
        <String, dynamic>{'repo': temp.path},
      );
      final Map<String, dynamic> planPayload = asMap(planReply['payload']);
      check.check(planPayload['dry_run'], true, 'plan 只读');
      check.that(
        (planPayload['units'] as List<dynamic>?)?.isNotEmpty == true,
        'plan 出注入单元',
      );
      check.that(
        (asMap(planPayload['budget'])['context_cap'] as num? ?? 0) > 0,
        'plan 给出 context_cap',
      );

      final Map<String, dynamic> generateReply = await askCommand(
        'generate',
        'docnorm.generate',
        <String, dynamic>{'repo': temp.path},
      );
      final Map<String, dynamic> generatePayload = asMap(
        generateReply['payload'],
      );
      check.check(generatePayload['dry_run'], true, 'generate 只读');
      check.that(
        (generatePayload['sections'] as List<dynamic>?)?.isNotEmpty == true,
        'generate 出章节提案',
      );
      check.that(
        (asMap(generatePayload['budget'])['calls'] as num? ?? 0) > 0,
        'generate 经 llm.call 生成',
      );
      check.that(
        jsonEncode(generatePayload).contains('## 职责'),
        'generate 提案可喂 baseline（## 职责）',
      );

      final Map<String, dynamic> auditDryReply = await askCommand(
        'audit-dry',
        'docnorm.audit',
        <String, dynamic>{'repo': temp.path},
      );
      final Map<String, dynamic> auditDry = asMap(auditDryReply['payload']);
      check.check(auditDry['dry_run'], true, 'audit 默认 dry-run');
      check.that(
        (auditDry['packages'] as List<dynamic>?)?.isNotEmpty == true,
        'audit 出包收束事实',
      );
      check.that(
        (auditDry['suggestions'] as List<dynamic>?)?.isNotEmpty == true,
        'audit 按阈值 1 行产出建议',
      );
      final Map<String, dynamic> auditCommitReply = await askCommand(
        'audit-commit',
        'docnorm.audit',
        <String, dynamic>{'repo': temp.path, 'commit': true},
      );
      final Map<String, dynamic> auditCommit = asMap(
        auditCommitReply['payload'],
      );
      check.check(
        asMap(auditCommit['storage'])['applied'],
        true,
        'audit --commit 写 suggestions / pkg_index',
      );
      check.that(
        (fakeDb['suggestions'] ?? <String, Map<String, Object?>>{}).isNotEmpty,
        'suggestions 入库',
      );
      final Map<String, dynamic> auditAgainReply = await askCommand(
        'audit-again',
        'docnorm.audit',
        <String, dynamic>{'repo': temp.path, 'commit': true},
      );
      final Map<String, dynamic> auditAgain = asMap(
        auditAgainReply['payload'],
      );
      check.check(
        (auditAgain['storage'] as Map<String, dynamic>)['ops'],
        0,
        'audit 重复运行 0 写',
      );
    }
  } catch (error) {
    check.that(false, '自检过程未抛异常', actual: '$error');
  } finally {
    await core.close();
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  }
  return check.finish(core.logs);
}
