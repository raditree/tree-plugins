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
const String kVersion = '0.1.0';
const String kStationName = 'docnorm';
const List<String> kDocnormCommands = <String>[
  'docnorm.scan',
  'docnorm.contract',
  'docnorm.check',
];

const String kStationReadme =
    '文档归一化：docnorm.scan 扫描目标仓库，返回包图（包/子包/行数/公开声明/API 面/依赖）；'
    'docnorm.contract 侦查文档契约（章节/索引/链接/CHANGELOG/门禁，规则按 内置→仓库自述 合成）；'
    'docnorm.check 只跑 DocPolicy 四条检查。六族适配器 + fallback；只读，不改目标仓库。';

PluginKitServer buildServer({bool exitOnShutdown = true}) => PluginKitServer(
  channel: PluginChannel.stdio(kPluginId),
  pluginId: kPluginId,
  displayName: kDisplayName,
  onReady: _onReady,
  onRequest: handleRequest,
  exitOnShutdown: exitOnShutdown,
);

Future<void> _onReady(PluginKitServer server) async {
  server.channel.log('已上线：v$kVersion（tree.docnorm，DN-2）');
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
''');

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
