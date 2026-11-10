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
}
