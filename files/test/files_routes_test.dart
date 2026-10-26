import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_files/tree_files.dart';

void main() {
  group('路由申报', () {
    test('13 条 files 路由与核心契约同形，不含 Git', () {
      expect(kDeclaredRoutes, hasLength(13));
      bool has(String method, String pattern) => kDeclaredRoutes.any(
        (Map<String, String> route) =>
            route['method'] == method && route['pattern'] == pattern,
      );
      expect(has('GET', '/api/files/{workspaceId}'), isTrue);
      expect(has('DELETE', '/api/files/{workspaceId}'), isTrue);
      expect(has('PUT', '/api/files/{workspaceId}/content'), isTrue);
      expect(
        kDeclaredRoutes.any(
          (Map<String, String> route) =>
              (route['pattern'] ?? '').contains('git'),
        ),
        isFalse,
      );
      final Set<String> keys = <String>{
        for (final Map<String, String> route in kDeclaredRoutes)
          '${route['method']} ${route['pattern']}',
      };
      expect(keys, hasLength(13), reason: '申报键不得重复');
    });
  });

  group('工作空间解析', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('files_ws_');
    });

    tearDown(() {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('workspace_id 优先、agent id 兜底；成员跟随 TOP 的目录与 SSH', () {
      final Directory top = Directory(p.join(temp.path, 'top_ws'))
        ..createSync(recursive: true);
      File(p.join(temp.path, 'agents', 'top.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          'id: top\n'
          'workspace_id: ws_top\n'
          'workspace_dir: "${top.path.replaceAll('\\', '/')}"\n'
          'ssh:\n'
          '  host: example.com\n'
          '  username: u\n'
          '  password: p\n',
        );
      File(p.join(temp.path, 'agents', 'member.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          'id: member\n'
          'workspace_id: ws_member\n'
          'parent_agent_id: top\n'
          'workspace_dir: "${p.join(temp.path, 'ignored').replaceAll('\\', '/')}"\n',
        );
      final WorkspaceResolver resolver = WorkspaceResolver(temp.path);
      final WorkspaceTarget byWorkspace = resolver.resolve('ws_member');
      expect(byWorkspace.agent.id, 'member');
      expect(byWorkspace.owner.id, 'top');
      expect(byWorkspace.root, p.normalize(top.path));
      expect(byWorkspace.isRemote, isTrue, reason: '成员跟随 TOP 的 SSH');
      expect(byWorkspace.ssh?['host'], 'example.com');

      final WorkspaceTarget byAgent = resolver.resolve('member');
      expect(byAgent.workspaceId, 'ws_member');
      expect(byAgent.agent.id, 'member');
      expect(() => resolver.resolve('ghost'), throwsA(isA<FileRouteError>()));
    });

    test('无 workspace_dir 时默认 <数据根>/workspaces/<ownerId>', () {
      File(p.join(temp.path, 'agents', 'solo.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('id: solo\nworkspace_id: ws_solo\n');
      final WorkspaceTarget target = WorkspaceResolver(temp.path)
          .resolve('ws_solo');
      expect(target.root, p.join(temp.path, 'workspaces', 'solo'));
      expect(target.isRemote, isFalse);
    });
  });

  group('本机 delegate', () {
    late Directory temp;
    late Directory workspace;
    late FilesService service;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('files_local_');
      workspace = Directory(p.join(temp.path, 'workspace'))
        ..createSync(recursive: true);
      File(p.join(workspace.path, 'hello.txt')).writeAsStringSync('hello');
      File(p.join(workspace.path, 'doc.pdf'))
          .writeAsStringSync('%PDF-1.4\n1 0 obj\n<< /Count 3 >>\n');
      File(p.join(temp.path, 'agents', 'agt.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          'id: agt\n'
          'workspace_id: ws_agt\n'
          'workspace_dir: "${workspace.path.replaceAll('\\', '/')}"\n',
        );
      service = FilesService();
    });

    tearDown(() async {
      await service.close();
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    Map<String, dynamic> envelope(
      String method,
      String path, {
      Map<String, Object?> query = const <String, Object?>{},
      Map<String, Object?>? body,
      String? bodyPath,
    }) => <String, dynamic>{
      'method': method,
      'path': path,
      'params': <String, dynamic>{'workspaceId': 'ws_agt'},
      'query': query,
      'headers': <String, dynamic>{},
      'scope': <String, dynamic>{},
      'workspace_dir': '',
      'data_dir': temp.path,
      'agent_id': 'ws_agt',
      'team_id': '',
      'request_id': 'test-${method.toLowerCase()}',
      if (body != null) 'body': jsonEncode(body),
      'body_path': ?bodyPath,
    };

    Future<Map<String, dynamic>> call(
      String method,
      String path, {
      Map<String, Object?> query = const <String, Object?>{},
      Map<String, Object?>? body,
      String? bodyPath,
    }) => service.handleDelegate(
      envelope(method, path, query: query, body: body, bodyPath: bodyPath),
    );

    Map<String, dynamic> bodyOf(Map<String, dynamic> reply) {
      final Object? raw = reply['body'];
      if (raw is! String || raw.isEmpty) return <String, dynamic>{};
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    }

    test('列表 / 内容 / PDF / 写文本 / 结构改动 / 错误体', () async {
      final Map<String, dynamic> listed = bodyOf(
        await call('GET', filesPattern),
      );
      expect(listed['total'], 2);
      expect((listed['files'] as List<dynamic>), hasLength(2));

      final Map<String, dynamic> content = bodyOf(
        await call(
          'GET',
          fileContentPattern,
          query: <String, Object?>{'path': 'hello.txt'},
        ),
      );
      expect(content['content'], 'hello');
      expect(content['size'], 5);
      expect(content['encoding'], 'utf-8');

      final Map<String, dynamic> pdf = bodyOf(
        await call(
          'GET',
          filePdfInfoPattern,
          query: <String, Object?>{'path': 'doc.pdf'},
        ),
      );
      expect(pdf['total_pages'], 3);
      expect(pdf['pages_source'], 'count');

      final Map<String, dynamic> write = await call(
        'PUT',
        fileContentPattern,
        query: <String, Object?>{'path': 'hello.txt'},
        body: <String, Object?>{'content': 'updated'},
      );
      expect(write['status'], 200);
      expect(bodyOf(write)['size'], 7);

      final Map<String, dynamic> conflict = await call(
        'PUT',
        fileContentPattern,
        query: <String, Object?>{'path': 'hello.txt'},
        body: <String, Object?>{'content': 'x', 'if_size': 5},
      );
      expect(conflict['status'], 409);
      expect(bodyOf(conflict)['error'], 'conflict');
      expect(bodyOf(conflict)['size'], 7);

      expect(
        (await call(
          'POST',
          fileMkdirPattern,
          body: <String, Object?>{'path': 'sub'},
        ))['status'],
        200,
      );
      expect(
        (await call(
          'POST',
          fileRenamePattern,
          body: <String, Object?>{'from': 'hello.txt', 'to': 'sub/hello.txt'},
        ))['status'],
        200,
      );
      expect(
        (await call(
          'DELETE',
          filesPattern,
          query: <String, Object?>{'path': 'sub/hello.txt'},
        ))['status'],
        200,
      );

      final Map<String, dynamic> missingWorkspace = await service
          .handleDelegate(<String, dynamic>{
            ...envelope('GET', filesPattern),
            'params': <String, dynamic>{'workspaceId': 'ghost'},
          });
      expect(missingWorkspace['status'], 404);
      expect(bodyOf(missingWorkspace)['detail'], contains('工作空间不存在'));

      final Map<String, dynamic> missingDelete = await call(
        'DELETE',
        filesPattern,
        query: <String, Object?>{'path': 'ghost.txt'},
      );
      expect(missingDelete['status'], 404);
      expect(bodyOf(missingDelete)['error'], 'not_found');
      expect(bodyOf(missingDelete)['detail'], contains('路径不存在'));
    });

    test('分片上传：init / chunk（body_path）/ complete / 回读', () async {
      final Map<String, dynamic> init = bodyOf(
        await call(
          'POST',
          fileUploadInitPattern,
          body: <String, Object?>{
            'file_name': 'up.txt',
            'rel_path': '',
            'total_size': 5,
          },
        ),
      );
      final String uploadId = (init['upload_id'] ?? '').toString();
      final String target = (init['path'] ?? '').toString();
      expect(uploadId, isNotEmpty);
      expect(target, startsWith('.input/'));

      final File chunkBody = File(p.join(temp.path, 'chunk.json'))
        ..writeAsStringSync(
          jsonEncode(<String, Object?>{
            'upload_id': uploadId,
            'index': 0,
            'data': base64Encode(utf8.encode('hello')),
          }),
        );
      final Map<String, dynamic> chunk = await call(
        'POST',
        fileUploadChunkPattern,
        bodyPath: chunkBody.path,
      );
      expect(chunk['status'], 200);
      expect(bodyOf(chunk)['received_bytes'], 5);

      final Map<String, dynamic> complete = await call(
        'POST',
        fileUploadCompletePattern,
        body: <String, Object?>{'upload_id': uploadId, 'total_chunks': 1},
      );
      expect(complete['status'], 200);
      expect(bodyOf(complete)['success'], true);

      final Map<String, dynamic> read = bodyOf(
        await call(
          'GET',
          fileContentPattern,
          query: <String, Object?>{'path': target},
        ),
      );
      expect(read['content'], 'hello');
    });

    test('同步到本地与目录打包：产物真实存在', () async {
      final Directory syncTarget = Directory(p.join(temp.path, 'synced'));
      final Map<String, dynamic> synced = await call(
        'POST',
        fileSyncToLocalPattern,
        body: <String, Object?>{'local_path': syncTarget.path, 'path': ''},
      );
      expect(synced['status'], 200);
      expect(bodyOf(synced)['success'], true);
      expect(File(p.join(syncTarget.path, 'hello.txt')).existsSync(), isTrue);

      final Map<String, dynamic> folder = await call(
        'POST',
        fileDownloadFolderPattern,
        body: <String, Object?>{'path': 'sub_missing'},
      );
      expect(folder['status'], 404);

      final Map<String, dynamic> archive = await call(
        'POST',
        fileDownloadFolderPattern,
        body: <String, Object?>{'path': ''},
      );
      expect(archive['status'], 200);
      final String resultPath = (archive['result_path'] ?? '').toString();
      expect(File(resultPath).existsSync(), isTrue);
      final List<int> bytes = File(resultPath).readAsBytesSync();
      expect(bytes.length, greaterThan(2));
      expect(bytes[0], 0x1f);
      expect(bytes[1], 0x8b);
    });
  });

  group('SSH delegate（假执行站）', () {
    late Directory temp;
    late FilesService service;
    late List<(String, Map<String, dynamic>)> calls;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('files_ssh_');
      File(p.join(temp.path, 'agents', 'ssh_agt.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          'id: ssh_agt\n'
          'workspace_id: ws_ssh\n'
          'ssh:\n'
          '  host: example.com\n'
          '  username: u\n'
          '  password: p\n',
        );
      calls = <(String, Map<String, dynamic>)>[];
      service = FilesService();
      service
          .stationCommand = (String command, Map<String, dynamic> args) async {
        calls.add((command, args));
        switch (command) {
          case 'ssh.lease.register':
            return <String, dynamic>{
              'lease_id': 'L1',
              'root': '/remote/ws',
              'conn_id': 'c1',
            };
          case 'ssh.file.list':
            final String path = (args['path'] ?? '.').toString();
            if (path == '.' || path == '') {
              return <String, dynamic>{
                'entries': <String>['a.txt', 'd/'],
                'details': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'name': 'a.txt',
                    'type': 'file',
                    'size': 5,
                    'mtime_ms': 1700000000000,
                  },
                  <String, dynamic>{'name': 'd', 'type': 'dir'},
                ],
                'count': 2,
                'truncated': false,
              };
            }
            if (path == 'd') {
              return <String, dynamic>{
                'entries': <String>[],
                'details': <Map<String, dynamic>>[],
                'count': 0,
                'truncated': false,
              };
            }
            if (path == 'a.txt') {
              return <String, dynamic>{
                'entries': <String>['a.txt'],
                'details': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'name': 'a.txt',
                    'type': 'file',
                    'size': 5,
                    'mtime_ms': 1700000000000,
                  },
                ],
                'count': 1,
                'truncated': false,
              };
            }
            throw Exception('路径不存在：$path');
          case 'ssh.file.read':
            final String path = (args['path'] ?? '').toString();
            // `raw: true` = 分块下载通道：二进制原样回，带 eof。
            if (args['raw'] == true) {
              if (path == 'a.txt') {
                return <String, dynamic>{
                  'base64': base64Encode(utf8.encode('hello')),
                  'offset': 0,
                  'size': 5,
                  'eof': true,
                };
              }
              if (path.endsWith('.tar.gz')) {
                return <String, dynamic>{
                  'base64': base64Encode(<int>[0x1f, 0x8b, 0x08, 0x00]),
                  'offset': 0,
                  'size': 4,
                  'eof': true,
                };
              }
              throw Exception('文件不存在：$path');
            }
            if (path == 'a.txt') {
              return <String, dynamic>{
                'content': 'hello',
                'total_lines': 1,
                'truncated': false,
              };
            }
            if (path == 'bin.png') {
              return <String, dynamic>{
                'content': '',
                'base64': 'AQID',
                'total_lines': 0,
                'truncated': false,
              };
            }
            throw Exception('文件不存在：$path');
          case 'ssh.file.write':
            return <String, dynamic>{
              'path': args['path'],
              'bytes_written': utf8
                  .encode((args['content'] ?? '').toString())
                  .length,
            };
          case 'ssh.file.writeBytes':
            return <String, dynamic>{'path': args['path'], 'bytes_written': 5};
          case 'ssh.file.rename':
            return <String, dynamic>{
              'path': args['to'],
              'from': args['from'],
              'to': args['to'],
            };
          case 'ssh.file.mkdir':
            return <String, dynamic>{'path': args['path'], 'created': true};
          case 'ssh.file.delete':
            return <String, dynamic>{'path': args['path'], 'deleted': true};
          case 'ssh.exec.command':
            final String commandText = (args['command'] ?? '').toString();
            if (commandText.startsWith('tar ')) {
              return <String, dynamic>{'exit_code': 0, 'text': ''};
            }
            return <String, dynamic>{'exit_code': 1, 'text': ''};
          default:
            throw Exception('未模拟的命令：$command');
        }
      };
    });

    tearDown(() async {
      await service.close();
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    Map<String, dynamic> envelope(
      String method,
      String path, {
      Map<String, Object?> query = const <String, Object?>{},
      Map<String, Object?>? body,
    }) => <String, dynamic>{
      'method': method,
      'path': path,
      'params': <String, dynamic>{'workspaceId': 'ws_ssh'},
      'query': query,
      'headers': <String, dynamic>{},
      'scope': <String, dynamic>{},
      'workspace_dir': '',
      'data_dir': temp.path,
      'agent_id': 'ws_ssh',
      'team_id': '',
      'request_id': 'ssh-test',
      if (body != null) 'body': jsonEncode(body),
    };

    Map<String, dynamic> bodyOf(Map<String, dynamic> reply) {
      final Object? raw = reply['body'];
      if (raw is! String || raw.isEmpty) return <String, dynamic>{};
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    }

    test('列表 / 内容（文本与二进制）/ 写 / mkdir / rename / 删除', () async {
      final Map<String, dynamic> listed = bodyOf(
        await service.handleDelegate(envelope('GET', filesPattern)),
      );
      expect(listed['total'], 2);
      expect(
        (listed['files'] as List<dynamic>).first,
        containsPair('type', 'dir'),
      );

      final Map<String, dynamic> content = bodyOf(
        await service.handleDelegate(
          envelope(
            'GET',
            fileContentPattern,
            query: <String, Object?>{'path': 'a.txt'},
          ),
        ),
      );
      expect(content['content'], 'hello');

      final Map<String, dynamic> binary = bodyOf(
        await service.handleDelegate(
          envelope(
            'GET',
            fileContentPattern,
            query: <String, Object?>{'path': 'bin.png'},
          ),
        ),
      );
      expect(binary['encoding'], 'base64');
      expect(binary['content'], 'AQID');

      final Map<String, dynamic> write = await service.handleDelegate(
        envelope(
          'PUT',
          fileContentPattern,
          query: <String, Object?>{'path': 'a.txt'},
          body: <String, Object?>{'content': 'hi'},
        ),
      );
      expect(write['status'], 200);

      final Map<String, dynamic> mkdir = await service.handleDelegate(
        envelope(
          'POST',
          fileMkdirPattern,
          body: <String, Object?>{'path': 'new'},
        ),
      );
      expect(mkdir['status'], 200);

      final Map<String, dynamic> rename = await service.handleDelegate(
        envelope(
          'POST',
          fileRenamePattern,
          body: <String, Object?>{'from': 'a.txt', 'to': 'b.txt'},
        ),
      );
      expect(rename['status'], 200);
      expect(
        calls.any(
          ((String, Map<String, dynamic>) call) =>
              call.$1 == 'ssh.file.rename' &&
              call.$2['from'] == 'a.txt' &&
              call.$2['to'] == 'b.txt',
        ),
        isTrue,
        reason: '重命名必须走目标机 fs.rename（原子），不再 shell 拼 mv',
      );

      final Map<String, dynamic> removed = await service.handleDelegate(
        envelope(
          'DELETE',
          filesPattern,
          query: <String, Object?>{'path': 'a.txt'},
        ),
      );
      expect(removed['status'], 200);
      expect(
        calls.any(
          ((String, Map<String, dynamic>) call) => call.$1 == 'ssh.file.delete',
        ),
        isTrue,
      );
    });

    test('SSH 分片上传 → 分块 writeBytes；sync/archive 走分块通道', () async {
      final Map<String, dynamic> init = bodyOf(
        await service.handleDelegate(
          envelope(
            'POST',
            fileUploadInitPattern,
            body: <String, Object?>{
              'file_name': 'up.txt',
              'rel_path': '',
              'total_size': 5,
            },
          ),
        ),
      );
      final String uploadId = (init['upload_id'] ?? '').toString();
      expect(uploadId, isNotEmpty);
      expect(
        calls.any(
          ((String, Map<String, dynamic>) call) =>
              call.$1 == 'ssh.lease.register',
        ),
        isTrue,
      );

      final Map<String, dynamic> chunk = await service.handleDelegate(
        envelope(
          'POST',
          fileUploadChunkPattern,
          body: <String, Object?>{
            'upload_id': uploadId,
            'index': 0,
            'data': base64Encode(utf8.encode('hello')),
          },
        ),
      );
      expect(chunk['status'], 200);
      final Map<String, dynamic> complete = await service.handleDelegate(
        envelope(
          'POST',
          fileUploadCompletePattern,
          body: <String, Object?>{'upload_id': uploadId, 'total_chunks': 1},
        ),
      );
      expect(complete['status'], 200);
      expect(complete['body'], contains('"size":5'));
      expect(
        calls.any(
          ((String, Map<String, dynamic>) call) =>
              call.$1 == 'ssh.file.writeBytes',
        ),
        isTrue,
      );

      // 同步到本地：走 raw 分块读 + 本地落盘（不再 501）。
      final String syncTarget = p.join(temp.path, 'out');
      final Map<String, dynamic> sync = await service.handleDelegate(
        envelope(
          'POST',
          fileSyncToLocalPattern,
          body: <String, Object?>{'local_path': syncTarget},
        ),
      );
      expect(sync['status'], 200, reason: '${sync['body']}');
      expect(
        File(p.join(syncTarget, 'a.txt')).readAsStringSync(),
        'hello',
        reason: '远端 a.txt 应被分块下载到本地',
      );

      // 目录打包下载：远端 tar → 分块回传 → 清理远端临时包（不再 501）。
      final Map<String, dynamic> archive = await service.handleDelegate(
        envelope(
          'POST',
          fileDownloadFolderPattern,
          body: <String, Object?>{'path': ''},
        ),
      );
      expect(archive['status'], 200, reason: '${archive['body']}');
      final String resultPath = (archive['result_path'] ?? '').toString();
      expect(File(resultPath).existsSync(), isTrue);
      expect(
        calls.any(
          ((String, Map<String, dynamic>) call) =>
              call.$1 == 'ssh.file.delete' &&
              call.$2['path'].toString().contains('.tree-archive-'),
        ),
        isTrue,
        reason: '远端临时包必须清理',
      );
    });

    test('SSH 分片上传 > 单块上限：按 append 分块写', () async {
      final int size = RemoteFiles.writeChunkBytes + 1;
      final Map<String, dynamic> init = bodyOf(
        await service.handleDelegate(
          envelope(
            'POST',
            fileUploadInitPattern,
            body: <String, Object?>{
              'file_name': 'big.bin',
              'rel_path': '',
              'total_size': size,
            },
          ),
        ),
      );
      final String uploadId = (init['upload_id'] ?? '').toString();
      final Map<String, dynamic> chunk = await service.handleDelegate(
        envelope(
          'POST',
          fileUploadChunkPattern,
          body: <String, Object?>{
            'upload_id': uploadId,
            'index': 0,
            'data': base64Encode(Uint8List(size)),
          },
        ),
      );
      expect(chunk['status'], 200);
      calls.clear();
      final Map<String, dynamic> complete = await service.handleDelegate(
        envelope(
          'POST',
          fileUploadCompletePattern,
          body: <String, Object?>{'upload_id': uploadId, 'total_chunks': 1},
        ),
      );
      expect(complete['status'], 200, reason: '${complete['body']}');
      final List<Map<String, dynamic>> writes = <Map<String, dynamic>>[
        for (final (String, Map<String, dynamic>) call in calls)
          if (call.$1 == 'ssh.file.writeBytes') call.$2,
      ];
      expect(writes.length, greaterThanOrEqualTo(2), reason: '超过单块上限必须分块');
      expect(writes.first['append'], isNot(true), reason: '首块截断重建');
      expect(writes.last['append'], isTrue, reason: '后续块追加');
    });

    test('未接执行站时 SSH 路由给可读 503', () async {
      final FilesService bare = FilesService();
      addTearDown(bare.close);
      final Map<String, dynamic> reply = await bare.handleDelegate(
        envelope('GET', filesPattern),
      );
      expect(reply['status'], 503, reason: 'body=${reply['body']}');
      expect(bodyOf(reply)['detail'], contains('ssh_executor 执行站'));
    });
  });
}
