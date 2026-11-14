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

  test('ST-4：白名单调用方可跨 namespace，未授权仍 namespace_denied', () async {
    final StorageService allowed = StorageService(
      environment: <String, String>{
        'TREE_STORAGE_ALLOWED_PLUGINS': 'tree.docnorm, tree.other',
      },
    );
    try {
      final Map<String, dynamic> result = await allowed.handle(
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
      );
      expect(result['namespace'], 'tree.other');
      expect(
        File(
          '${temp.path}${Platform.pathSeparator}storage'
          '${Platform.pathSeparator}team_a'
          '${Platform.pathSeparator}tree.other'
          '${Platform.pathSeparator}data.semdb',
        ).existsSync(),
        isTrue,
      );
    } finally {
      await allowed.close();
    }

    final StorageService listed = StorageService(
      environment: <String, String>{
        'TREE_STORAGE_ALLOWED_PLUGINS': 'tree.other',
      },
    );
    try {
      await expectLater(
        listed.handle(
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
    } finally {
      await listed.close();
    }
  });

  test('ST-4：写命令留结构化审计，读命令不记', () async {
    final List<String> logs = <String>[];
    final StorageService audited = StorageService(
      environment: <String, String>{},
      log: logs.add,
    );
    try {
      await audited.handle(
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
      final Iterable<String> audit = logs.where(
        (String line) => line.startsWith('audit '),
      );
      expect(audit, isNotEmpty);
      final String line = audit.single;
      for (final String part in <String>[
        'caller=tree.docnorm',
        'namespace=tree.docnorm',
        'collection=c',
        'op=put',
        'key=k',
        'bytes=',
        'at=',
      ]) {
        expect(line, contains(part));
      }

      logs.clear();
      await audited.handle(
        'storage.get',
        <String, dynamic>{'collection': 'c', 'key': 'k'},
        <String, dynamic>{
          'source_plugin_id': 'tree.docnorm',
          'data_dir': temp.path,
        },
        teamScope,
      );
      expect(
        logs.where((String line) => line.startsWith('audit ')),
        isEmpty,
        reason: '读命令不应产生审计行',
      );
    } finally {
      await audited.close();
    }
  });

  test('ST-5：purge 必须 confirm，且白名单也不能删别人的 namespace', () async {
    final StorageService allowed = StorageService(
      environment: <String, String>{
        'TREE_STORAGE_ALLOWED_PLUGINS': 'tree.docnorm',
      },
    );
    final Map<String, dynamic> meta = <String, dynamic>{
      'source_plugin_id': 'tree.docnorm',
      'data_dir': temp.path,
    };
    try {
      await allowed.handle(
        'storage.put',
        <String, dynamic>{
          'namespace': 'tree.other',
          'collection': 'c',
          'key': 'k',
          'value': <String, dynamic>{'v': 1},
        },
        meta,
        teamScope,
      );
      await expectLater(
        allowed.handle(
          'storage.purge',
          <String, dynamic>{'namespace': 'tree.other', 'confirm': true},
          meta,
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
      await expectLater(
        allowed.handle(
          'storage.purge',
          <String, dynamic>{'confirm': false},
          meta,
          teamScope,
        ),
        throwsA(
          isA<StorageFailure>().having(
            (StorageFailure e) => e.code,
            'code',
            'confirmation_required',
          ),
        ),
      );
      final Map<String, dynamic> purged = await allowed.handle(
        'storage.purge',
        <String, dynamic>{'confirm': true},
        meta,
        teamScope,
      );
      expect(purged['purged'], isTrue);
    } finally {
      await allowed.close();
    }
  });

  test('TC-ST-08/12：payload 自报身份被忽略，只认 meta.source_plugin_id', () async {
    final Map<String, dynamic> meta = <String, dynamic>{
      'source_plugin_id': 'tree.docnorm',
      'data_dir': temp.path,
    };
    // 自报是别人 ⇒ 不能借此写别人的 namespace。
    await expectLater(
      service.handle(
        'storage.put',
        <String, dynamic>{
          'plugin_id': 'tree.other',
          'namespace': 'tree.other',
          'collection': 'c',
          'key': 'k',
          'value': <String, dynamic>{'v': 1},
        },
        meta,
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
    // 自报是别人但没指定 namespace ⇒ 仍落到调用方自己的 namespace。
    await service.handle(
      'storage.put',
      <String, dynamic>{
        'plugin_id': 'tree.other',
        'collection': 'c',
        'key': 'k',
        'value': <String, dynamic>{'v': 1},
      },
      meta,
      teamScope,
    );
    final Map<String, dynamic> stats = await service.handle(
      'storage.stats',
      <String, dynamic>{},
      meta,
      teamScope,
    );
    expect(stats['namespace'], 'tree.docnorm');
  });

  test('ST-2/ST-3/ST-5：tx / export / import / stats / compact 路由可用', () async {
    final Map<String, dynamic> meta = <String, dynamic>{
      'source_plugin_id': 'tree.docnorm',
      'data_dir': temp.path,
    };
    final Map<String, dynamic> tx = await service.handle(
      'storage.tx',
      <String, dynamic>{
        'ops': <Map<String, dynamic>>[
          <String, dynamic>{
            'op': 'put',
            'collection': 'c',
            'key': 'k',
            'value': <String, dynamic>{'v': 1},
          },
        ],
      },
      meta,
      teamScope,
    );
    expect(tx['committed'], isTrue);

    final Map<String, dynamic> exported = await service.handle(
      'storage.export',
      <String, dynamic>{'collection': 'c'},
      meta,
      teamScope,
    );
    final Map<String, dynamic> imported = await service.handle(
      'storage.import',
      <String, dynamic>{'path': exported['path'], 'collection': 'c2'},
      meta,
      teamScope,
    );
    expect(imported['imported'], 1);

    final Map<String, dynamic> stats = await service.handle(
      'storage.stats',
      <String, dynamic>{},
      meta,
      teamScope,
    );
    expect(stats['collections'], isNotEmpty);

    final Map<String, dynamic> compacted = await service.handle(
      'storage.compact',
      <String, dynamic>{},
      meta,
      teamScope,
    );
    expect(compacted['compacted'], isTrue);
  });

  test('plugin 绑定：不带 team 可读写，库落 plugin_storage/<namespace>', () async {
    final Map<String, dynamic> meta = <String, dynamic>{
      'source_plugin_id': 'tree.docnorm',
      'data_dir': temp.path,
    };
    final Map<String, dynamic> put = await service.handle(
      'storage.put',
      <String, dynamic>{
        'binding': 'plugin',
        'collection': 'c',
        'key': 'k',
        'value': <String, dynamic>{'v': 1},
      },
      meta,
      <String, dynamic>{},
    );
    expect(put['binding'], 'plugin');
    expect(put['team_id'], '');
    expect(
      File(
        '${temp.path}${Platform.pathSeparator}plugin_storage'
        '${Platform.pathSeparator}tree.docnorm'
        '${Platform.pathSeparator}data.semdb',
      ).existsSync(),
      isTrue,
    );
    final Map<String, dynamic> get = await service.handle(
      'storage.get',
      <String, dynamic>{'binding': 'plugin', 'collection': 'c', 'key': 'k'},
      meta,
      <String, dynamic>{},
    );
    expect(get['value'], <String, dynamic>{'v': 1});
  });

  test('plugin 绑定与 team 绑定同 namespace 互不可见', () async {
    final Map<String, dynamic> meta = <String, dynamic>{
      'source_plugin_id': 'tree.docnorm',
      'data_dir': temp.path,
    };
    await service.handle(
      'storage.put',
      <String, dynamic>{
        'collection': 'c',
        'key': 'k',
        'value': <String, dynamic>{'scope': 'team'},
      },
      meta,
      teamScope,
    );
    final Map<String, dynamic> global = await service.handle(
      'storage.get',
      <String, dynamic>{'binding': 'plugin', 'collection': 'c', 'key': 'k'},
      meta,
      <String, dynamic>{},
    );
    expect(global['value'], isNull, reason: 'plugin 库不应读到 team 库的值');
    await service.handle(
      'storage.put',
      <String, dynamic>{
        'binding': 'plugin',
        'collection': 'c',
        'key': 'k',
        'value': <String, dynamic>{'scope': 'plugin'},
      },
      meta,
      <String, dynamic>{},
    );
    final Map<String, dynamic> teamValue = await service.handle(
      'storage.get',
      <String, dynamic>{'collection': 'c', 'key': 'k'},
      meta,
      teamScope,
    );
    expect(teamValue['value'], <String, dynamic>{'scope': 'team'});
  });

  test('binding 非法 ⇒ invalid_arguments', () async {
    await expectLater(
      service.handle(
        'storage.get',
        <String, dynamic>{'binding': 'global', 'collection': 'c', 'key': 'k'},
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
          'invalid_arguments',
        ),
      ),
    );
  });
}
