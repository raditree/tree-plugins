import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_settings/tree_settings.dart';

/// K 系列 REST 委派边界：team 归属、未注册插件、广播载荷与错误码。
void main() {
  late Directory temp;
  late SettingsService service;
  final List<SettingsChange> changes = <SettingsChange>[];

  Map<String, dynamic> schema() => <String, dynamic>{
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
        'min': 1000,
        'max': 2000000,
      },
      <String, dynamic>{
        'key': 'mode',
        'type': 'enum',
        'title': '模式',
        'options': <String>['lexical', 'hybrid'],
      },
    ],
  };

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tree_settings_service_');
    changes.clear();
    service = SettingsService(
      environment: <String, String>{},
      onChanged: (SettingsChange change) async => changes.add(change),
    );
    final Map<String, dynamic> defined = await service.handle(
      'settings.define',
      <String, dynamic>{'schema': schema()},
      <String, dynamic>{
        'source_plugin_id': 'tree.docnorm',
        'data_dir': temp.path,
      },
      <String, dynamic>{'team_id': 'team_a'},
    );
    expect(defined['schema_version'], 1);
  });

  tearDown(() async {
    await service.close();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<Map<String, dynamic>> delegate(
    String method,
    String path, {
    Map<String, dynamic> query = const <String, dynamic>{},
    Map<String, dynamic>? body,
    String teamId = 'team_a',
  }) async {
    final Map<String, dynamic> reply = await service.handleDelegate(
      <String, dynamic>{
        'method': method,
        'path': path,
        'query': query,
        'scope': <String, dynamic>{'team_id': teamId},
        'team_id': teamId,
        'data_dir': temp.path,
        'body': ?body,
      },
    );
    return reply;
  }

  Map<String, dynamic> bodyOf(Map<String, dynamic> reply) =>
      (jsonDecode('${reply['body']}') as Map).cast<String, dynamic>();

  test('缺 team_id ⇒ 400 team_required（不落公共库）', () async {
    final Map<String, dynamic> reply = await delegate(
      'GET',
      '/api/plugin-settings/schema',
      teamId: '',
    );
    expect(reply['status'], 400);
    expect(bodyOf(reply)['code'], 'team_required');
  });

  test('未注册插件的写入 / 重置 ⇒ 404 unknown_plugin', () async {
    final Map<String, dynamic> patch = await delegate(
      'PATCH',
      '/api/plugin-settings/values',
      body: <String, dynamic>{
        'plugin_id': 'tree.other',
        'values': <String, dynamic>{'stage_budget': 2000},
      },
    );
    expect(patch['status'], 404);
    expect(bodyOf(patch)['code'], 'unknown_plugin');

    final Map<String, dynamic> reset = await delegate(
      'POST',
      '/api/plugin-settings/reset',
      body: <String, dynamic>{
        'plugin_id': 'tree.other',
        'keys': <String>['stage_budget'],
      },
    );
    expect(reset['status'], 404);
    expect(bodyOf(reset)['code'], 'unknown_plugin');
  });

  test('已注册插件写入：回 generation、广播带 at 且不带值', () async {
    final Map<String, dynamic> patch = await delegate(
      'PATCH',
      '/api/plugin-settings/values',
      body: <String, dynamic>{
        'plugin_id': 'tree.docnorm',
        'values': <String, dynamic>{'stage_budget': 2000},
      },
    );
    expect(patch['status'], 200);
    expect(bodyOf(patch)['generation'], 1);
    expect(changes.single.pluginId, 'tree.docnorm');
    expect(changes.single.keys, <String>['stage_budget']);
    expect(changes.single.at, greaterThan(0));
    expect(changes.single.toPayload().containsKey('values'), isFalse);
  });

  test('enum 传入非字符串 ⇒ 400 value_type_mismatch，不落库', () async {
    final Map<String, dynamic> patch = await delegate(
      'PATCH',
      '/api/plugin-settings/values',
      body: <String, dynamic>{
        'plugin_id': 'tree.docnorm',
        'values': <String, dynamic>{'mode': 1},
      },
    );
    expect(patch['status'], 400);
    expect(bodyOf(patch)['code'], 'value_type_mismatch');
    final Map<String, dynamic> values = await delegate(
      'GET',
      '/api/plugin-settings/values',
      query: <String, dynamic>{'plugin_id': 'tree.docnorm'},
    );
    expect(
      ((bodyOf(values)['values'] as Map)['mode'] as Map)['has_value'],
      isFalse,
    );
  });

  test('plugin 绑定：不带 team 可 define/set/get，回包带 binding', () async {
    final Map<String, dynamic> meta = <String, dynamic>{
      'source_plugin_id': 'tree.docnorm',
      'data_dir': temp.path,
    };
    final Map<String, dynamic> defined = await service.handle(
      'settings.define',
      <String, dynamic>{'binding': 'plugin', 'schema': schema()},
      meta,
      <String, dynamic>{},
    );
    expect(defined['binding'], 'plugin');
    expect(defined['team_id'], '');
    final Map<String, dynamic> set = await service.handle(
      'settings.set',
      <String, dynamic>{
        'binding': 'plugin',
        'values': <String, dynamic>{'stage_budget': 5000},
      },
      meta,
      <String, dynamic>{},
    );
    expect(set['generation'], 1);
    final Map<String, dynamic> get = await service.handle(
      'settings.get',
      <String, dynamic>{'binding': 'plugin', 'key': 'stage_budget'},
      meta,
      <String, dynamic>{},
    );
    expect(get['value'], 5000);
    expect(
      File(
        '${temp.path}${Platform.pathSeparator}plugin_settings'
        '${Platform.pathSeparator}settings.semdb',
      ).existsSync(),
      isTrue,
    );
    expect(changes.single.binding, 'plugin');
    expect(changes.single.toPayload()['binding'], 'plugin');
  });

  test('plugin 与 team 绑定的同名 key 互不覆盖', () async {
    final Map<String, dynamic> meta = <String, dynamic>{
      'source_plugin_id': 'tree.docnorm',
      'data_dir': temp.path,
    };
    await service.handle(
      'settings.define',
      <String, dynamic>{'binding': 'plugin', 'schema': schema()},
      meta,
      <String, dynamic>{},
    );
    await service.handle(
      'settings.set',
      <String, dynamic>{
        'values': <String, dynamic>{'stage_budget': 3000},
      },
      meta,
      <String, dynamic>{'team_id': 'team_a'},
    );
    final Map<String, dynamic> global = await service.handle(
      'settings.get',
      <String, dynamic>{'binding': 'plugin', 'key': 'stage_budget'},
      meta,
      <String, dynamic>{},
    );
    expect(
      global['value'],
      1000,
      reason: '全局库没有覆盖值，应回 schema 默认而不是团队覆盖值',
    );
    final Map<String, dynamic> team = await service.handle(
      'settings.get',
      <String, dynamic>{'key': 'stage_budget'},
      meta,
      <String, dynamic>{'team_id': 'team_a'},
    );
    expect(team['value'], 3000);
  });

  test('REST：binding=plugin 不需要 team_id', () async {
    final Map<String, dynamic> meta = <String, dynamic>{
      'source_plugin_id': 'tree.docnorm',
      'data_dir': temp.path,
    };
    await service.handle(
      'settings.define',
      <String, dynamic>{'binding': 'plugin', 'schema': schema()},
      meta,
      <String, dynamic>{},
    );
    final Map<String, dynamic> reply = await service.handleDelegate(
      <String, dynamic>{
        'method': 'GET',
        'path': '/api/plugin-settings/values',
        'query': <String, dynamic>{
          'binding': 'plugin',
          'plugin_id': 'tree.docnorm',
        },
        'scope': <String, dynamic>{},
        'data_dir': temp.path,
      },
    );
    expect(reply['status'], 200);
    final Map<String, dynamic> body = bodyOf(reply);
    expect(body['binding'], 'plugin');
    expect(body['team_id'], '');
    expect(body['plugin_id'], 'tree.docnorm');
  });

  test('binding 非法 ⇒ 400 invalid_arguments', () async {
    await expectLater(
      service.handle(
        'settings.get',
        <String, dynamic>{'binding': 'global', 'key': 'stage_budget'},
        <String, dynamic>{
          'source_plugin_id': 'tree.docnorm',
          'data_dir': temp.path,
        },
        <String, dynamic>{},
      ),
      throwsA(
        isA<SettingsFailure>().having(
          (SettingsFailure error) => error.code,
          'code',
          'invalid_arguments',
        ),
      ),
    );
  });
}
