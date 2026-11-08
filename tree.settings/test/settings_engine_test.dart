import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_settings/tree_settings.dart';

void main() {
  late Directory temp;
  late SettingsEngine engine;

  Map<String, dynamic> schema({int version = 1}) => <String, dynamic>{
    'schema_version': version,
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
        'default': 'hybrid',
      },
      <String, dynamic>{'key': 'api_token', 'type': 'secret', 'title': '网关令牌'},
    ],
  };

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_settings_test_');
    engine = SettingsEngine(dataRoot: temp.path);
  });

  tearDown(() async {
    await engine.close();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('schema 同版本幂等、同版本不同内容拒绝、降级拒绝', () async {
    final Map<String, dynamic> first = await engine.define(
      teamId: 'team_a',
      owner: 'tree.docnorm',
      schema: schema(),
    );
    expect(first['schema_version'], 1);

    final Map<String, dynamic> again = await engine.define(
      teamId: 'team_a',
      owner: 'tree.docnorm',
      schema: schema(),
    );
    expect(again['unchanged'], true);

    await expectLater(
      engine.define(
        teamId: 'team_a',
        owner: 'tree.docnorm',
        schema: <String, dynamic>{
          ...schema(),
          'fields': <Map<String, dynamic>>[
            <String, dynamic>{
              'key': 'stage_budget',
              'type': 'int',
              'title': '改名',
            },
          ],
        },
      ),
      throwsA(
        isA<SettingsFailure>().having(
          (SettingsFailure error) => error.code,
          'code',
          'schema_version_conflict',
        ),
      ),
    );
    final Map<String, dynamic> upgraded = await engine.define(
      teamId: 'team_a',
      owner: 'tree.docnorm',
      schema: schema(version: 2),
    );
    expect(upgraded['schema_version'], 2);
  });

  test('默认值取 min，secret 永不回显，reset 回默认', () async {
    await engine.define(
      teamId: 'team_a',
      owner: 'tree.docnorm',
      schema: schema(),
    );
    Map<String, dynamic> listed = await engine.list(
      teamId: 'team_a',
      owner: 'tree.docnorm',
    );
    final Map<String, dynamic> values = Map<String, dynamic>.from(
      listed['values'] as Map,
    );
    expect((values['stage_budget'] as Map)['value'], 1000);
    expect((values['mode'] as Map)['value'], 'hybrid');
    expect((values['api_token'] as Map)['value'], isNull);
    expect((values['api_token'] as Map)['has_value'], false);

    await engine.set(
      teamId: 'team_a',
      owner: 'tree.docnorm',
      values: <String, dynamic>{'stage_budget': 500000, 'api_token': 'sk-x'},
    );
    final Map<String, dynamic> secret = await engine.get(
      teamId: 'team_a',
      owner: 'tree.docnorm',
      key: 'api_token',
    );
    expect(secret['value'], isNull);
    expect(secret['has_value'], true);

    await engine.reset(
      teamId: 'team_a',
      owner: 'tree.docnorm',
      keys: <String>['api_token', 'stage_budget'],
    );
    listed = await engine.list(teamId: 'team_a', owner: 'tree.docnorm');
    final Map<String, dynamic> resetValues = Map<String, dynamic>.from(
      listed['values'] as Map,
    );
    expect((resetValues['stage_budget'] as Map)['value'], 1000);
    expect((resetValues['api_token'] as Map)['has_value'], false);
  });

  test('类型/范围/未知 key 拒绝，且不落库', () async {
    await engine.define(
      teamId: 'team_a',
      owner: 'tree.docnorm',
      schema: schema(),
    );
    await expectLater(
      engine.set(
        teamId: 'team_a',
        owner: 'tree.docnorm',
        values: <String, dynamic>{'stage_budget': '500000'},
      ),
      throwsA(
        isA<SettingsFailure>().having(
          (SettingsFailure error) => error.code,
          'code',
          'value_type_mismatch',
        ),
      ),
    );
    await expectLater(
      engine.set(
        teamId: 'team_a',
        owner: 'tree.docnorm',
        values: <String, dynamic>{'stage_budget': 99999999},
      ),
      throwsA(
        isA<SettingsFailure>().having(
          (SettingsFailure error) => error.code,
          'code',
          'value_out_of_range',
        ),
      ),
    );
    await expectLater(
      engine.set(
        teamId: 'team_a',
        owner: 'tree.docnorm',
        values: <String, dynamic>{'nope': 1},
      ),
      throwsA(
        isA<SettingsFailure>().having(
          (SettingsFailure error) => error.code,
          'code',
          'unknown_key',
        ),
      ),
    );
    final Map<String, dynamic> current = await engine.get(
      teamId: 'team_a',
      owner: 'tree.docnorm',
      key: 'stage_budget',
    );
    expect(current['value'], 1000);
  });

  test('跨团队隔离：另一个 team 没有 schema', () async {
    await engine.define(
      teamId: 'team_a',
      owner: 'tree.docnorm',
      schema: schema(),
    );
    await expectLater(
      engine.list(teamId: 'team_b', owner: 'tree.docnorm'),
      throwsA(
        isA<SettingsFailure>().having(
          (SettingsFailure error) => error.code,
          'code',
          'schema_not_found',
        ),
      ),
    );
  });

  test('未知字段类型直接拒绝，不猜默认控件', () async {
    await expectLater(
      engine.define(
        teamId: 'team_a',
        owner: 'tree.docnorm',
        schema: <String, dynamic>{
          'schema_version': 1,
          'fields': <Map<String, dynamic>>[
            <String, dynamic>{'key': 'weird', 'type': 'color', 'title': '未知类型'},
          ],
        },
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

  test('并发写不丢更新：generation 单调递增到最后一次', () async {
    await engine.define(
      teamId: 'team_a',
      owner: 'tree.docnorm',
      schema: schema(),
    );
    final List<Future<Map<String, dynamic>>> writes =
        <Future<Map<String, dynamic>>>[
          for (int i = 0; i < 20; i++)
            engine.set(
              teamId: 'team_a',
              owner: 'tree.docnorm',
              values: <String, dynamic>{'stage_budget': 1000 + i},
            ),
        ];
    final List<Map<String, dynamic>> results = await Future.wait(writes);
    final List<int> generations =
        results
            .map((Map<String, dynamic> result) => result['generation'] as int)
            .toList()
          ..sort();
    expect(generations, List<int>.generate(20, (int index) => index + 1));
    final Map<String, dynamic> current = await engine.get(
      teamId: 'team_a',
      owner: 'tree.docnorm',
      key: 'stage_budget',
    );
    expect(current['value'], 1019);
  });

  test('secret default 必须为空；schema 回包也不带默认密钥', () async {
    await expectLater(
      engine.define(
        teamId: 'team_a',
        owner: 'tree.docnorm',
        schema: <String, dynamic>{
          'schema_version': 1,
          'fields': <Map<String, dynamic>>[
            <String, dynamic>{
              'key': 'api_token',
              'type': 'secret',
              'title': '令牌',
              'default': 'sk-inline',
            },
          ],
        },
      ),
      throwsA(
        isA<SettingsFailure>().having(
          (SettingsFailure error) => error.code,
          'code',
          'invalid_arguments',
        ),
      ),
    );

    await engine.define(
      teamId: 'team_a',
      owner: 'tree.docnorm',
      schema: schema(),
    );
    final Map<String, dynamic> listed = await engine.list(
      teamId: 'team_a',
      owner: 'tree.docnorm',
    );
    final Map<String, dynamic> secretField = (listed['fields'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .firstWhere(
          (Map<String, dynamic> field) => field['key'] == 'api_token',
        );
    expect(secretField['default'], '');
  });

  test('export 脱敏：schema 在、secret 原值不在', () async {
    await engine.define(
      teamId: 'team_a',
      owner: 'tree.docnorm',
      schema: schema(),
    );
    await engine.set(
      teamId: 'team_a',
      owner: 'tree.docnorm',
      values: <String, dynamic>{'api_token': 'sk-secret'},
    );
    final Map<String, dynamic> exported = await engine.export(
      teamId: 'team_a',
      owner: 'tree.docnorm',
    );
    expect(exported['schema_version'], 1);
    final Map<String, dynamic> values = Map<String, dynamic>.from(
      exported['values'] as Map,
    );
    expect((values['api_token'] as Map)['value'], isNull);
    expect((values['api_token'] as Map)['has_value'], true);
    expect(exported.toString().contains('sk-secret'), false);
  });
}
