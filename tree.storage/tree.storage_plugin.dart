// tree.storage —— 插件集合存储（ST-1：骨架 + 单库 CRUD）。
//
// 定位（docs/pluginization/tree-storage-recon.md §1/§5）：
// - headless 插件，对其它插件只暴露**自建执行站**命令族 `storage.*`；
// - 每团队 × 每命名空间一个库
//   `<data_root>/storage/<team_id>/<namespace>/data.semdb`（Sembast、纯 Dart）；
// - 命名空间缺省 = 调用方 plugin_id，其它命名空间在 ST-1 一律拒绝（白名单在 ST-4 接）；
// - 本文件只做接线：命令实现在 `package:tree_storage`，生产与 `--selftest` 同一套代码。
//
// 依赖纪律：不得 import 任何核心包（tree_core / tree_protocol）。
import 'dart:async';
import 'dart:io';

import 'package:tree_storage/tree_storage.dart';

import '../_kit/plugin_kit.dart';

/// 与 `plugin.json` 的 id 同串；核心以此认身份（自带清单时核心给的优先）。
const String kPluginId = 'tree.storage';

/// 面板展示名。
const String kDisplayName = 'Tree 集合存储';

const String kVersion = '0.1.0';

/// 自建执行站名（命令族唯一前缀 `storage.`，其它插件不得申报同名命令）。
const String kStationName = 'storage';

const String kStationReadme =
    '插件集合存储：storage.ensure/put/get/delete/query。每团队 × 每插件一个库 '
    '<data_root>/storage/<team_id>/<namespace>/data.semdb；team_id 只认核心解析的 '
    'scope，namespace 缺省=调用方 plugin_id，ST-1 拒绝一切跨命名空间访问。'
    '调用方身份只认核心透传的 meta.source_plugin_id。';

/// 生产与自检共用同一个服务（自检用临时数据根，靠 meta.data_dir 切换）。
final StorageService _service = StorageService();

PluginKitServer buildServer({bool exitOnShutdown = true}) => PluginKitServer(
  channel: PluginChannel.stdio(kPluginId),
  pluginId: kPluginId,
  displayName: kDisplayName,
  onReady: _onReady,
  onRequest: handleRequest,
  onStop: _service.close,
  exitOnShutdown: exitOnShutdown,
);

Future<void> _onReady(PluginKitServer server) async {
  server.channel.log('已上线：v$kVersion（tree.storage，ST-1）');
  try {
    final Map<String, dynamic> result = await server.channel.request(
      M.stationRegister,
      <String, dynamic>{
        'kind': 'execute',
        'name': kStationName,
        'description': '插件集合存储（storage.*）',
        'readme': kStationReadme,
        'commands': kStorageCommands,
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
  if (!kStorageCommands.contains(command)) return null;
  final Map<String, dynamic> meta = asMap(params['meta']);
  try {
    final Map<String, dynamic> result = await _service.handle(
      command,
      asMap(payload['arguments']),
      meta,
      asMap(params['scope']),
    );
    return <String, dynamic>{
      'reply': <String, dynamic>{'payload': result},
    };
  } on StorageFailure catch (error) {
    return <String, dynamic>{
      'reply': <String, dynamic>{'error': error.message, 'code': error.code},
    };
  } catch (error) {
    return <String, dynamic>{
      'reply': <String, dynamic>{
        'error': '存储命令执行失败：$error',
        'code': 'storage_error',
      },
    };
  }
}

Future<void> main(List<String> args) async {
  if (args.contains('--selftest')) {
    // 自检输出走 stderr："stdout 只有协议帧"这条铁律不因模式而变。
    exitCode = await selfTest();
    return;
  }
  await buildServer().run(stdin);
  try {
    await stdout.flush();
  } catch (_) {
    // 管道已被对端关掉（核心退出）：刷不出去不算错误。
  }
}

/// 假核心自检（同码跑真读循环）：注册面 + CRUD + 隔离/校验。
Future<int> selfTest() async {
  final SelfTest check = SelfTest(name: 'tree_storage_plugin');
  final Directory temp = Directory.systemTemp.createTempSync(
    'tree_storage_selftest_',
  );
  final FakeCore core = FakeCore(buildServer(exitOnShutdown: false));
  core.onMethod(
    M.stationRegister,
    (Map<String, dynamic> params) => <String, dynamic>{
      'ok': true,
      'station_id': 'storage',
    },
  );
  Future<Map<String, dynamic>> call(
    Object id,
    String command,
    Map<String, dynamic> arguments, {
    String caller = 'tree.docnorm',
    String? team = 'team_a',
    Map<String, dynamic> meta = const <String, dynamic>{},
  }) async {
    core.ask(id, M.stationRequest, <String, dynamic>{
      'payload': <String, dynamic>{'command': command, 'arguments': arguments},
      'meta': <String, dynamic>{
        'source_plugin_id': caller,
        'data_dir': temp.path,
        ...meta,
      },
      'scope': <String, dynamic>{'team_id': ?team},
    });
    final Map<Object?, Map<String, dynamic>> responses = await core.waitFor(
      <Object?>[id],
    );
    final Map<String, dynamic> frame = responses[id] ?? <String, dynamic>{};
    return asMap(asMap(frame['result'])['reply']);
  }

  Map<String, dynamic> payloadOf(Map<String, dynamic> reply) =>
      asMap(reply['payload']);
  List<dynamic> valuesOf(Map<String, dynamic> reply) =>
      (payloadOf(reply)['values'] as List<dynamic>?) ?? <dynamic>[];

  try {
    unawaited(core.start());
    core.ask('hello', M.hello, <String, dynamic>{'plugin_id': kPluginId});
    final Map<Object?, Map<String, dynamic>> hello = await core.waitFor(
      <Object?>['hello'],
    );
    check.check(
      asMap(hello['hello']?['result'])['plugin_id'],
      kPluginId,
      'hello 回包带插件身份',
    );

    final List<Map<String, dynamic>> registrations = core.outgoing(
      M.stationRegister,
    );
    check.check(registrations.length, 1, '启动后只注册一个自建执行站');
    final Map<String, dynamic> registration = asMap(
      registrations.isEmpty ? null : registrations.first['params'],
    );
    check.check(registration['kind'], 'execute', '执行站 kind=execute');
    check.check(registration['name'], kStationName, '执行站 name=storage');
    check.check(
      (registration['commands'] as List<dynamic>?)?.length,
      kStorageCommands.length,
      '命令表长度与 ST-1 一致',
    );

    // 身份 fail-closed：核心没带 source_plugin_id ⇒ 拒绝，不猜调用方。
    core.ask('no-identity', M.stationRequest, <String, dynamic>{
      'payload': <String, dynamic>{
        'command': 'storage.get',
        'arguments': <String, dynamic>{'collection': 'c', 'key': 'k'},
      },
      'meta': <String, dynamic>{'data_dir': temp.path},
    });
    final Map<Object?, Map<String, dynamic>> denied = await core.waitFor(
      <Object?>['no-identity'],
    );
    final Map<String, dynamic> deniedReply = asMap(
      asMap(denied['no-identity']?['result'])['reply'],
    );
    check.check(
      deniedReply['code'],
      'identity_required',
      '缺身份 ⇒ identity_required',
    );

    // team 粒度：核心没在 scope 里带 team_id ⇒ 拒绝，不落到公共库。
    final Map<String, dynamic> noTeam = await call(
      'no-team',
      'storage.get',
      <String, dynamic>{'collection': 'c', 'key': 'k'},
      team: null,
    );
    check.check(noTeam['code'], 'team_required', '缺 team_id ⇒ team_required');

    // ensure：v2 建集合；降级到 v1 拒绝；同版本幂等。
    Map<String, dynamic> reply = await call(
      'ensure-2',
      'storage.ensure',
      <String, dynamic>{'collection': 'suggestions', 'schema_version': 2},
    );
    check.check(payloadOf(reply)['schema_version'], 2, 'ensure v2 成功');
    reply = await call('ensure-1', 'storage.ensure', <String, dynamic>{
      'collection': 'suggestions',
      'schema_version': 1,
    });
    check.check(reply['code'], 'schema_version_conflict', 'ensure 降级被拒');
    reply = await call('ensure-again', 'storage.ensure', <String, dynamic>{
      'collection': 'suggestions',
      'schema_version': 2,
    });
    check.check(payloadOf(reply)['schema_version'], 2, 'ensure 同版本幂等');

    // put/get：rev 单调；值原样往返。
    reply = await call('put-1', 'storage.put', <String, dynamic>{
      'collection': 'suggestions',
      'key': 'sug-01',
      'value': <String, dynamic>{'title': '复用建议', 'tag': 'reuse', 'n': 1},
    });
    check.check(payloadOf(reply)['rev'], 1, '首次 put rev=1');
    reply = await call('put-2', 'storage.put', <String, dynamic>{
      'collection': 'suggestions',
      'key': 'sug-01',
      'value': <String, dynamic>{'title': '复用建议（改）', 'tag': 'reuse', 'n': 2},
    });
    check.check(payloadOf(reply)['rev'], 2, '再次 put rev=2');
    reply = await call('get-1', 'storage.get', <String, dynamic>{
      'collection': 'suggestions',
      'key': 'sug-01',
    });
    check.check(payloadOf(reply)['value'], <String, dynamic>{
      'title': '复用建议（改）',
      'tag': 'reuse',
      'n': 2,
    }, 'get 取回最新值');
    reply = await call('get-missing', 'storage.get', <String, dynamic>{
      'collection': 'suggestions',
      'key': 'nope',
    });
    check.check(payloadOf(reply)['value'], null, 'get 不存在 ⇒ value=null');

    // delete：不存在幂等 false；存在 true。
    reply = await call('del-missing', 'storage.delete', <String, dynamic>{
      'collection': 'suggestions',
      'key': 'nope',
    });
    check.check(payloadOf(reply)['deleted'], false, 'delete 不存在 ⇒ false');
    reply = await call('del-1', 'storage.delete', <String, dynamic>{
      'collection': 'suggestions',
      'key': 'sug-01',
    });
    check.check(payloadOf(reply)['deleted'], true, 'delete 存在 ⇒ true');
    reply = await call('get-after-del', 'storage.get', <String, dynamic>{
      'collection': 'suggestions',
      'key': 'sug-01',
    });
    check.check(payloadOf(reply)['value'], null, 'delete 后 get ⇒ null');

    // query：条件 + 降序 + limit 上限。
    for (final (String key, String tag, int n) in <(String, String, int)>[
      ('a', 'reuse', 1),
      ('b', 'reuse', 3),
      ('c', 'split', 2),
    ]) {
      await call('seed-$key', 'storage.put', <String, dynamic>{
        'collection': 'items',
        'key': key,
        'value': <String, dynamic>{'tag': tag, 'n': n},
      });
    }
    reply = await call('query-1', 'storage.query', <String, dynamic>{
      'collection': 'items',
      'filter': <String, dynamic>{'tag': 'reuse'},
      'sort': 'n',
      'descending': true,
      'limit': 1,
    });
    final List<dynamic> values = valuesOf(reply);
    check.check(values.length, 1, 'query filter+limit 命中一条');
    check.check(
      asMap(values.isEmpty ? null : values.first)['key'],
      'b',
      'query 按 n 降序取首条',
    );
    reply = await call('query-cap', 'storage.query', <String, dynamic>{
      'collection': 'items',
      'limit': 9999,
    });
    check.check(payloadOf(reply)['limit'], 500, 'limit 上限夹到 500');

    // 命名空间隔离：别人的 namespace 拒绝；各自缺省命名空间互不可见。
    reply = await call('cross-ns', 'storage.put', <String, dynamic>{
      'namespace': 'tree.other',
      'collection': 'items',
      'key': 'x',
      'value': <String, dynamic>{'tag': 'x'},
    });
    check.check(reply['code'], 'namespace_denied', '跨命名空间被拒');
    await call('other-put', 'storage.put', <String, dynamic>{
      'collection': 'items',
      'key': 'a',
      'value': <String, dynamic>{'tag': 'other'},
    }, caller: 'tree.otherdoc');
    reply = await call('own-get', 'storage.get', <String, dynamic>{
      'collection': 'items',
      'key': 'a',
    });
    check.check(payloadOf(reply)['value'], <String, dynamic>{
      'tag': 'reuse',
      'n': 1,
    }, '不同调用方各自库互不可见');

    // TC-ST-13：两个 team 各写各的库文件（同调用方、同 key 互不影响）。
    await call('team-b-put', 'storage.put', <String, dynamic>{
      'collection': 'items',
      'key': 'a',
      'value': <String, dynamic>{'tag': 'team_b', 'n': 9},
    }, team: 'team_b');
    reply = await call('team-a-get', 'storage.get', <String, dynamic>{
      'collection': 'items',
      'key': 'a',
    });
    check.check(payloadOf(reply)['value'], <String, dynamic>{
      'tag': 'reuse',
      'n': 1,
    }, '两个 team 的库互不可见');

    // 非法名 / 保留前缀。
    reply = await call('bad-collection', 'storage.put', <String, dynamic>{
      'collection': 'bad/name',
      'key': 'k',
      'value': <String, dynamic>{},
    });
    check.check(reply['code'], 'invalid_arguments', '非法集合名被拒');
    reply = await call('reserved', 'storage.ensure', <String, dynamic>{
      'collection': '__meta',
    });
    check.check(reply['code'], 'invalid_arguments', '保留前缀 __ 被拒');

    // 库文件确实落在 <data_root>/storage/<team_id>/<namespace>/data.semdb。
    String dbPath(String team) =>
        '${temp.path}${Platform.pathSeparator}storage'
        '${Platform.pathSeparator}$team'
        '${Platform.pathSeparator}tree.docnorm'
        '${Platform.pathSeparator}data.semdb';
    check.that(
      File(dbPath('team_a')).existsSync() &&
          File(dbPath('team_b')).existsSync(),
      '两个 team 各自落库（路径带 team_id）',
      actual: '${dbPath('team_a')} / ${dbPath('team_b')}',
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
