// tree.settings —— 插件设置服务（K1~K3：schema / 覆盖值 / 变更广播）。
//
// 定位（docs/pluginization/plugin-settings-recon.md §1/§5）：
// - headless 插件，对其它插件暴露自建执行站命令族 `settings.*`；
// - 对 UI 暴露委派路由 `/api/plugin-settings/*`（避开核心已有的 `/api/settings/*`）；
// - 每团队一个 Sembast 库 `<data_root>/settings/<team_id>/settings.semdb`；
// - plugin 绑定用全局库 `<data_root>/plugin_settings/settings.semdb`（不要求 team_id）；
// - 只存“用户覆盖值”；最终优先级由插件自己合并（设置服务 > env > config > 默认）；
// - secret 只写不读；写入成功广播 `settings.changed`（不带值）。
//
// 依赖纪律：不得 import 任何核心包（tree_core / tree_protocol）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tree_settings/tree_settings.dart';

import '../_kit/plugin_kit.dart';

const String kPluginId = 'tree.settings';
const String kDisplayName = 'Tree 插件设置';
const String kVersion = '0.2.0';

const String kStationName = 'settings';
const String kStationReadme =
    '插件设置：settings.define/list/get/set/reset/export。binding=team（默认）时'
    '每团队一个库 <data_root>/settings/<team_id>/settings.semdb；binding=plugin 时'
    '用全局库 <data_root>/plugin_settings/settings.semdb，不要求 team_id。owner 只认'
    '核心透传的 meta.source_plugin_id；secret 只写不读。';

/// 广播站名（名字不能带点；核心会拼成 plugin.tree.settings.broadcast.settings_changed）。
const String kBroadcastName = 'settings_changed';
const String kBroadcastReadme =
    '插件设置变更通知：topic=settings.changed，载荷 {plugin_id, binding, keys, generation}，'
    '不带值（secret 永不出插件）。订阅方收到后自行 settings.get。';

final SettingsService _service = SettingsService();
String _broadcastStationId = '';

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
  _service.onChanged = (SettingsChange change) async {
    final String stationId = _broadcastStationId;
    if (stationId.isEmpty) return;
    // 广播站按 team 归属投递；全局变更无 team 时无法证明归属，订阅方下次读取即可。
    if (change.teamId.isEmpty) return;
    await server.channel.request(M.stationTrigger, <String, dynamic>{
      'station_id': stationId,
      'topic': 'settings.changed',
      'scope': <String, dynamic>{'team_id': change.teamId, 'mode_key': 'local'},
      'payload': change.toPayload(),
    });
  };
  server.channel.log('已上线：v$kVersion（tree.settings）');
  try {
    final Map<String, dynamic> execute = await server.channel.request(
      M.stationRegister,
      <String, dynamic>{
        'kind': 'execute',
        'name': kStationName,
        'description': '插件设置（settings.*）',
        'readme': kStationReadme,
        'commands': kSettingsCommands,
      },
    );
    server.channel.log(
      '自建执行站：${execute['ok'] == true ? execute['station_id'] : execute['error']}',
    );
  } catch (error) {
    server.channel.log('自建执行站失败：$error');
  }
  try {
    final Map<String, dynamic> broadcast = await server.channel.request(
      M.stationRegister,
      <String, dynamic>{
        'kind': 'broadcast',
        'name': kBroadcastName,
        'description': '插件设置变更',
        'readme': kBroadcastReadme,
        'shared': true,
      },
    );
    _broadcastStationId = asString(broadcast['station_id']);
    server.channel.log(
      '自建广播站：${broadcast['ok'] == true ? _broadcastStationId : broadcast['error']}',
    );
  } catch (error) {
    server.channel.log('自建广播站失败：$error');
  }
}

Future<Map<String, dynamic>?> handleRequest(
  String method,
  Map<String, dynamic> params,
) async {
  if (method == M.apiDelegate) {
    return _service.handleDelegate(asMap(params));
  }
  if (method != M.stationRequest) return null;
  if (asString(params['station_id']) == kApiRoutesStation) {
    return <String, dynamic>{
      'reply': <String, dynamic>{
        'payload': <String, dynamic>{'routes': kDeclaredRoutes},
      },
    };
  }
  final Map<String, dynamic> payload = asMap(params['payload']);
  final String command = asString(payload['command']);
  if (!kSettingsCommands.contains(command)) return null;
  try {
    final Map<String, dynamic> result = await _service.handle(
      command,
      asMap(payload['arguments']),
      asMap(params['meta']),
      asMap(params['scope']),
    );
    return <String, dynamic>{
      'reply': <String, dynamic>{'payload': result},
    };
  } on SettingsFailure catch (error) {
    return <String, dynamic>{
      'reply': <String, dynamic>{'error': error.message, 'code': error.code},
    };
  } catch (error) {
    return <String, dynamic>{
      'reply': <String, dynamic>{
        'error': '设置命令执行失败：$error',
        'code': 'settings_error',
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

/// 假核心自检（同码跑真读循环）：注册面 + schema + 值 + secret + 广播 + REST。
Future<int> selfTest() async {
  final SelfTest check = SelfTest(name: 'tree_settings_plugin');
  final Directory temp = Directory.systemTemp.createTempSync(
    'tree_settings_selftest_',
  );
  final FakeCore core = FakeCore(buildServer(exitOnShutdown: false));
  core.onMethod(
    M.stationRegister,
    (Map<String, dynamic> params) => <String, dynamic>{
      'ok': true,
      'station_id': asString(params['kind']) == 'execute'
          ? 'settings'
          : 'plugin.tree.settings.broadcast.settings_changed',
    },
  );
  core.onMethod(
    M.stationTrigger,
    (Map<String, dynamic> params) => <String, dynamic>{'ok': true},
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

  final Map<String, dynamic> schema = <String, dynamic>{
    'schema_version': 1,
    'groups': <Map<String, dynamic>>[
      <String, dynamic>{'id': 'budget', 'title': '预算'},
    ],
    'fields': <Map<String, dynamic>>[
      <String, dynamic>{
        'key': 'stage_budget',
        'group': 'budget',
        'type': 'int',
        'title': '阶段预算',
        'default': 400000,
        'min': 1000,
        'max': 2000000,
      },
      <String, dynamic>{
        'key': 'mode',
        'type': 'enum',
        'title': '模式',
        'options': <String>['lexical', 'hybrid'],
        'default': 'hybrid',
      },
      <String, dynamic>{'key': 'api_token', 'type': 'secret', 'title': '网关令牌'},
      <String, dynamic>{'key': 'roots', 'type': 'string_list', 'title': '根目录'},
      <String, dynamic>{'key': 'verbose', 'type': 'bool', 'title': '详细日志'},
    ],
  };

  try {
    unawaited(core.start());
    core.ask('hello', M.hello, <String, dynamic>{'plugin_id': kPluginId});
    await core.waitFor(<Object?>['hello']);

    final List<Map<String, dynamic>> registrations = core.outgoing(
      M.stationRegister,
    );
    check.check(registrations.length, 2, '启动后注册执行站 + 广播站');
    final List<String> kinds = registrations
        .map(
          (Map<String, dynamic> frame) =>
              asString(asMap(frame['params'])['kind']),
        )
        .toList();
    check.that(
      kinds.contains('execute') && kinds.contains('broadcast'),
      '站点 kind 覆盖 execute / broadcast',
      actual: kinds.join(','),
    );

    // 身份 / 团队 fail-closed。
    final Map<String, dynamic> noIdentity = await call(
      'no-identity',
      'settings.list',
      <String, dynamic>{},
      meta: <String, dynamic>{},
    );
    // 上面的 call 始终带 source_plugin_id；改成显式空值再验一次。
    core.ask('no-identity-2', M.stationRequest, <String, dynamic>{
      'payload': <String, dynamic>{
        'command': 'settings.list',
        'arguments': <String, dynamic>{},
      },
      'meta': <String, dynamic>{'data_dir': temp.path},
      'scope': <String, dynamic>{'team_id': 'team_a'},
    });
    final Map<Object?, Map<String, dynamic>> denied = await core.waitFor(
      <Object?>['no-identity-2'],
    );
    check.check(
      asMap(asMap(denied['no-identity-2']?['result'])['reply'])['code'],
      'identity_required',
      '缺身份 ⇒ identity_required',
    );
    final Map<String, dynamic> noTeam = await call(
      'no-team',
      'settings.list',
      <String, dynamic>{},
      team: null,
    );
    check.check(noTeam['code'], 'team_required', '缺 team_id ⇒ team_required');

    // plugin 级绑定：不带 team 也能 define/set/get。
    Map<String, dynamic> pluginReply = await call(
      'plugin-define',
      'settings.define',
      <String, dynamic>{'binding': 'plugin', 'schema': schema},
      team: null,
    );
    check.check(
      payloadOf(pluginReply)['binding'],
      'plugin',
      'plugin 绑定 define 回 binding',
    );
    pluginReply = await call(
      'plugin-set',
      'settings.set',
      <String, dynamic>{
        'binding': 'plugin',
        'values': <String, dynamic>{'stage_budget': 4321},
      },
      team: null,
    );
    check.check(payloadOf(pluginReply)['generation'], 1, 'plugin 绑定可写');
    pluginReply = await call(
      'plugin-get',
      'settings.get',
      <String, dynamic>{'binding': 'plugin', 'key': 'stage_budget'},
      team: null,
    );
    check.check(payloadOf(pluginReply)['value'], 4321, 'plugin 绑定可读回');
    pluginReply = await call(
      'plugin-bad-binding',
      'settings.get',
      <String, dynamic>{'binding': 'global', 'key': 'stage_budget'},
      team: null,
    );
    check.check(pluginReply['code'], 'invalid_arguments', '非法 binding 被拒');
    check.check(
      noIdentity['code'],
      'schema_not_found',
      '未注册 schema ⇒ schema_not_found',
    );

    // define：首次、同版本幂等、同版本不同内容拒绝、降级拒绝。
    Map<String, dynamic> reply = await call(
      'define-1',
      'settings.define',
      <String, dynamic>{'schema': schema},
    );
    check.check(payloadOf(reply)['schema_version'], 1, 'define v1 成功');
    reply = await call('define-same', 'settings.define', <String, dynamic>{
      'schema': schema,
    });
    check.check(payloadOf(reply)['unchanged'], true, '同版本同内容幂等');
    reply = await call('define-diff', 'settings.define', <String, dynamic>{
      'schema': <String, dynamic>{
        ...schema,
        'fields': <Map<String, dynamic>>[
          <String, dynamic>{
            'key': 'stage_budget',
            'type': 'int',
            'title': '阶段预算（改名）',
            'default': 400000,
          },
        ],
      },
    });
    check.check(reply['code'], 'schema_version_conflict', '同版本不同内容被拒');

    // list/get：默认值可见；secret 不回显。
    reply = await call('list-1', 'settings.list', <String, dynamic>{});
    final Map<String, dynamic> values = asMap(payloadOf(reply)['values']);
    check.check(asMap(values['stage_budget'])['value'], 400000, '默认值可见');
    check.check(asMap(values['api_token'])['value'], null, 'secret 不回显');
    check.check(asMap(values['api_token'])['has_value'], false, 'secret 未写入');

    // set：范围 / 类型 / 未知 key。
    reply = await call('set-budget', 'settings.set', <String, dynamic>{
      'values': <String, dynamic>{'stage_budget': 500000},
    });
    check.check(payloadOf(reply)['applied'], <String>['stage_budget'], '写入预算');
    reply = await call('get-budget', 'settings.get', <String, dynamic>{
      'key': 'stage_budget',
    });
    check.check(payloadOf(reply)['value'], 500000, '读回预算');
    reply = await call('set-overflow', 'settings.set', <String, dynamic>{
      'values': <String, dynamic>{'stage_budget': 99999999},
    });
    check.check(reply['code'], 'value_out_of_range', '越界被拒');
    reply = await call('set-type', 'settings.set', <String, dynamic>{
      'values': <String, dynamic>{'stage_budget': '500000'},
    });
    check.check(reply['code'], 'value_type_mismatch', '类型不符被拒');
    reply = await call('set-unknown', 'settings.set', <String, dynamic>{
      'values': <String, dynamic>{'nope': 1},
    });
    check.check(reply['code'], 'unknown_key', '未知 key 被拒');

    // secret：写入后只有 has_value；reset 回默认。
    await call('set-secret', 'settings.set', <String, dynamic>{
      'values': <String, dynamic>{'api_token': 'sk-test'},
    });
    reply = await call('get-secret', 'settings.get', <String, dynamic>{
      'key': 'api_token',
    });
    check.check(payloadOf(reply)['value'], null, 'secret 永不回显');
    check.check(payloadOf(reply)['has_value'], true, 'secret has_value');
    await call('reset-secret', 'settings.reset', <String, dynamic>{
      'keys': <String>['api_token'],
    });
    reply = await call('get-secret-2', 'settings.get', <String, dynamic>{
      'key': 'api_token',
    });
    check.check(payloadOf(reply)['has_value'], false, 'reset 后回默认');

    // 跨插件 / 跨团队隔离。
    reply = await call(
      'other-list',
      'settings.list',
      <String, dynamic>{},
      caller: 'tree.other',
    );
    check.check(reply['code'], 'schema_not_found', '跨插件看不到别人的 schema');
    await call('team-b-define', 'settings.define', <String, dynamic>{
      'schema': schema,
    }, team: 'team_b');
    await call('team-b-set', 'settings.set', <String, dynamic>{
      'values': <String, dynamic>{'stage_budget': 1234},
    }, team: 'team_b');
    reply = await call('team-a-get', 'settings.get', <String, dynamic>{
      'key': 'stage_budget',
    });
    check.check(payloadOf(reply)['value'], 500000, '两个 team 互不影响');

    // 广播：写入后触发 settings.changed，且不带值。
    final List<Map<String, dynamic>> triggers = core.outgoing(M.stationTrigger);
    check.that(triggers.isNotEmpty, '写入后发出 settings.changed 广播');
    final Map<String, dynamic> lastPayload = asMap(
      asMap(triggers.isEmpty ? null : triggers.last['params'])['payload'],
    );
    check.check(lastPayload['plugin_id'], 'tree.docnorm', '广播带 plugin_id');
    check.that(
      lastPayload['keys'] is List && !lastPayload.containsKey('value'),
      '广播只带 keys，不带值',
      actual: jsonEncode(lastPayload),
    );

    // REST：schema / values / PATCH。
    core.ask('rest-schema', M.apiDelegate, <String, dynamic>{
      'method': 'GET',
      'path': kSchemaPattern,
      'query': <String, dynamic>{},
      'body': null,
      'data_dir': temp.path,
      'team_id': 'team_a',
      'scope': <String, dynamic>{'team_id': 'team_a'},
    });
    Map<Object?, Map<String, dynamic>> rest = await core.waitFor(<Object?>[
      'rest-schema',
    ]);
    Map<String, dynamic> restResult = asMap(rest['rest-schema']?['result']);
    check.check(restResult['status'], 200, 'REST schema 200');
    Map<String, dynamic> restBody = asMap(
      json.decode(asString(restResult['body'])),
    );
    check.check(
      (restBody['schemas'] as List<dynamic>?)?.length,
      1,
      'REST schema 聚合一个插件',
    );

    core.ask('rest-patch', M.apiDelegate, <String, dynamic>{
      'method': 'PATCH',
      'path': kValuesPattern,
      'query': <String, dynamic>{},
      'body': json.encode(<String, dynamic>{
        'plugin_id': 'tree.docnorm',
        'values': <String, dynamic>{'stage_budget': 600000},
      }),
      'data_dir': temp.path,
      'team_id': 'team_a',
      'scope': <String, dynamic>{'team_id': 'team_a'},
    });
    rest = await core.waitFor(<Object?>['rest-patch']);
    restResult = asMap(rest['rest-patch']?['result']);
    check.check(restResult['status'], 200, 'REST PATCH 200');
    reply = await call('get-after-rest', 'settings.get', <String, dynamic>{
      'key': 'stage_budget',
    });
    check.check(payloadOf(reply)['value'], 600000, 'REST 写入生效');

    core.ask('rest-values', M.apiDelegate, <String, dynamic>{
      'method': 'GET',
      'path': kValuesPattern,
      'query': <String, dynamic>{'plugin_id': 'tree.docnorm'},
      'body': null,
      'data_dir': temp.path,
      'team_id': 'team_a',
      'scope': <String, dynamic>{'team_id': 'team_a'},
    });
    rest = await core.waitFor(<Object?>['rest-values']);
    restResult = asMap(rest['rest-values']?['result']);
    restBody = asMap(json.decode(asString(restResult['body'])));
    check.check(
      asMap(asMap(restBody['values'])['api_token'])['value'],
      null,
      'REST 不泄露 secret',
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
