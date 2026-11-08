import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_storage/tree_storage.dart';

/// ST-1：执行站入口的身份 / 数据根 / 团队 / 命名空间口径。
void main() {
  const Map<String, dynamic> teamScope = <String, dynamic>{'team_id': 'team_a'};
  late Directory temp;
  late StorageService service;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_storage_service_');
    service = StorageService(environment: <String, String>{});
  });

  tearDown(() async {
    await service.close();
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('缺 source_plugin_id ⇒ identity_required（fail-closed）', () async {
    await expectLater(
      service.handle(
        'storage.get',
        <String, dynamic>{'collection': 'c', 'key': 'k'},
        <String, dynamic>{'data_dir': temp.path},
        teamScope,
      ),
      throwsA(
        isA<StorageFailure>().having(
          (StorageFailure e) => e.code,
          'code',
          'identity_required',
        ),
      ),
    );
  });

  test('缺 team_id ⇒ team_required（不落公共库）', () async {
    await expectLater(
      service.handle(
        'storage.get',
        <String, dynamic>{'collection': 'c', 'key': 'k'},
        <String, dynamic>{
          'source_plugin_id': 'tree.docnorm',
          'data_dir': temp.path,
        },
        <String, dynamic>{},
      ),
      throwsA(
        isA<StorageFailure>().having(
          (StorageFailure e) => e.code,
          'code',
          'team_required',
        ),
      ),
    );
  });

  test('缺 data_dir 且无 TREE_DATA_ROOT ⇒ missing_data_dir', () async {
    await expectLater(
      service.handle(
        'storage.get',
        <String, dynamic>{'collection': 'c', 'key': 'k'},
        <String, dynamic>{'source_plugin_id': 'tree.docnorm'},
        teamScope,
      ),
      throwsA(
        isA<StorageFailure>().having(
          (StorageFailure e) => e.code,
          'code',
          'missing_data_dir',
        ),
      ),
    );
  });

  test('data_dir 缺失时回退环境变量 TREE_DATA_ROOT', () async {
    final StorageService fromEnv = StorageService(
      environment: <String, String>{'TREE_DATA_ROOT': temp.path},
    );
    try {
      final Map<String, dynamic> result = await fromEnv.handle(
        'storage.put',
        <String, dynamic>{
          'collection': 'c',
          'key': 'k',
          'value': <String, dynamic>{'v': 1},
        },
        <String, dynamic>{'source_plugin_id': 'tree.docnorm'},
        teamScope,
      );
      expect(result['rev'], 1);
      expect(
        File(
          '${temp.path}${Platform.pathSeparator}storage'
          '${Platform.pathSeparator}team_a'
          '${Platform.pathSeparator}tree.docnorm'
          '${Platform.pathSeparator}data.semdb',
        ).existsSync(),
        isTrue,
      );
    } finally {
      await fromEnv.close();
    }
  });

  test('namespace 缺省=调用方；填别人的 namespace ⇒ namespace_denied', () async {
    final Map<String, dynamic> own = await service.handle(
      'storage.put',
      <String, dynamic>{
        'collection': 'c',
        'key': 'k',
        'value': <String, dynamic>{'v': 1},
      },
      <String, dynamic>{
        'source_plugin_id': 'tree.docnorm',
        'data_dir': temp.path,
      },
      teamScope,
    );
    expect(own['namespace'], 'tree.docnorm');

    await expectLater(
      service.handle(
        'storage.put',
        <String, dynamic>{
          'namespace': 'tree.other',
          'collection': 'c',
          'key': 'k',
          'value': <String, dynamic>{'v': 1},
        },
        <String, dynamic>{
          'source_plugin_id': 'tree.docnorm',
          'data_dir': temp.path,
        },
        teamScope,
      ),
      throwsA(
        isA<StorageFailure>().having(
          (StorageFailure e) => e.code,
          'code',
          'namespace_denied',
        ),
      ),
    );
  });

  test('value 不是对象 ⇒ invalid_arguments', () async {
    await expectLater(
      service.handle(
        'storage.put',
        <String, dynamic>{'collection': 'c', 'key': 'k', 'value': 'not-a-map'},
        <String, dynamic>{
          'source_plugin_id': 'tree.docnorm',
          'data_dir': temp.path,
        },
        teamScope,
      ),
      throwsA(
        isA<StorageFailure>().having(
          (StorageFailure e) => e.code,
          'code',
          'invalid_arguments',
        ),
      ),
    );
  });

  test('未知命令 ⇒ unknown_command', () async {
    await expectLater(
      service.handle('storage.unknown', <String, dynamic>{}, <String, dynamic>{
        'source_plugin_id': 'tree.docnorm',
        'data_dir': temp.path,
      }, teamScope),
      throwsA(
        isA<StorageFailure>().having(
          (StorageFailure e) => e.code,
          'code',
          'unknown_command',
        ),
      ),
    );
  });
}
