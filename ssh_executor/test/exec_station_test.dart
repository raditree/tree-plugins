import 'dart:convert';

import 'package:test/test.dart';
import 'package:tree_ssh_plugin/tree_ssh_plugin.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

/// 一个**假目标机**：只认识 agent L2 的 fs.* / exec.run，维护一张内存文件表。
///
/// 为什么用假 agent 而不是真 SSH：本插件最容易漂的是**命令形状与路径翻译**
/// （相对路径 → 目标机绝对路径、fs.read 的分块/offset、fs.listEntries 的递归拼接）。
/// 假 agent 只接受这些形状，形状漂了用例当场红。
class FakeAgent {
  final Map<String, List<int>> files = <String, List<int>>{};
  final Set<String> dirs = <String>{};
  final List<Map<String, dynamic>> ensureCalls = <Map<String, dynamic>>[];
  final List<({String connId, String method, Map<String, dynamic> params})>
  calls = <({String connId, String method, Map<String, dynamic> params})>[];
  String root = '/home/u/ws';

  Future<Map<String, dynamic>> ensure(Map<String, dynamic> config) async {
    ensureCalls.add(config);
    return <String, dynamic>{
      'ok': true,
      'conn_id': 'conn-1',
      'root': root,
      'agent': <String, dynamic>{'version': '1.2.3'},
    };
  }

  Future<Map<String, dynamic>> request(
    String connId,
    String method,
    Map<String, dynamic> params,
  ) async {
    calls.add((connId: connId, method: method, params: params));
    switch (method) {
      case AgentMethods.fsStat:
        final String path = params['path'].toString();
        if (files.containsKey(path)) {
          return _ok(<String, dynamic>{
            'type': 'file',
            'size': files[path]!.length,
          });
        }
        if (_isDir(path)) {
          return _ok(<String, dynamic>{'type': 'dir', 'size': 0});
        }
        return _ok(<String, dynamic>{'type': 'missing', 'size': 0});
      case AgentMethods.fsRead:
        final String path = params['path'].toString();
        final List<int>? bytes = files[path];
        if (bytes == null) {
          return _fail('路径不存在：$path', TunnelErrorCodes.notFound);
        }
        final int offset = (params['offset'] as num?)?.toInt() ?? 0;
        final int length = (params['length'] as num?)?.toInt() ?? bytes.length;
        final int end = offset + length > bytes.length
            ? bytes.length
            : offset + length;
        final List<int> chunk = offset >= bytes.length
            ? const <int>[]
            : bytes.sublist(offset, end);
        return _ok(<String, dynamic>{
          'data': base64Encode(chunk),
          'size': bytes.length,
          'offset': offset,
          'eof': end >= bytes.length,
        });
      case AgentMethods.fsWrite:
        final String path = params['path'].toString();
        final List<int> bytes = base64Decode(params['data'].toString());
        files[path] = bytes;
        _ensureParents(path);
        return _ok(<String, dynamic>{'size': bytes.length});
      case AgentMethods.fsListEntries:
        final String path = params['path'].toString();
        if (!_isDir(path)) {
          return _fail('目录不存在：$path', TunnelErrorCodes.notFound);
        }
        final Map<String, String> names = <String, String>{};
        for (final String file in files.keys) {
          if (_parent(file) == path) names[_base(file)] = 'file';
        }
        for (final String dir in _allDirs()) {
          if (dir != path && _parent(dir) == path) names[_base(dir)] = 'dir';
        }
        final List<String> sorted = names.keys.toList()..sort();
        return _ok(<String, dynamic>{
          'entries': <Map<String, dynamic>>[
            for (final String name in sorted)
              <String, dynamic>{
                'name': name,
                'type': names[name],
                'size': names[name] == 'file'
                    ? files[_join(path, name)]!.length
                    : 0,
              },
          ],
        });
      case AgentMethods.fsMkdir:
        dirs.add(params['path'].toString());
        _ensureParents(params['path'].toString());
        return _ok(<String, dynamic>{});
      case AgentMethods.fsRemove:
        final String path = params['path'].toString();
        files.removeWhere(
          (String key, List<int> value) =>
              key == path || key.startsWith('$path/'),
        );
        dirs.removeWhere(
          (String dir) => dir == path || dir.startsWith('$path/'),
        );
        return _ok(<String, dynamic>{});
      case AgentMethods.fsDelete:
        files.remove(params['path'].toString());
        return _ok(<String, dynamic>{});
      case AgentMethods.execRun:
        return _ok(<String, dynamic>{
          'exit_code': 0,
          'stdout': base64Encode(utf8.encode('hi\n')),
          'stderr': base64Encode(utf8.encode('warn\n')),
          'truncated': false,
        });
      default:
        return _fail('假 agent 不认识：$method');
    }
  }

  Map<String, dynamic> _ok(Map<String, dynamic> result) => <String, dynamic>{
    'ok': true,
    'result': result,
  };

  Map<String, dynamic> _fail(String error, [int? code]) => <String, dynamic>{
    'ok': false,
    'error': error,
    'error_code': ?code,
  };

  void putFile(String path, String text) {
    files[path] = utf8.encode(text);
    _ensureParents(path);
  }

  bool _isDir(String path) =>
      path == root || dirs.contains(path) || _allDirs().contains(path);

  List<String> _allDirs() {
    final Set<String> all = <String>{root};
    for (final String dir in dirs) {
      all.add(dir);
      all.addAll(_ancestors(dir));
    }
    for (final String file in files.keys) {
      all.addAll(_ancestors(file));
    }
    return all.toList(growable: false);
  }

  Set<String> _ancestors(String path) {
    final Set<String> out = <String>{};
    String current = _parent(path);
    while (current.isNotEmpty && current != root) {
      out.add(current);
      current = _parent(current);
    }
    return out;
  }

  void _ensureParents(String path) {
    String current = _parent(path);
    while (current.isNotEmpty && current != root) {
      dirs.add(current);
      current = _parent(current);
    }
  }

  static String _parent(String path) {
    final int index = path.lastIndexOf('/');
    if (index <= 0) return '/';
    return path.substring(0, index);
  }

  static String _base(String path) => path.substring(path.lastIndexOf('/') + 1);

  static String _join(String dir, String name) =>
      dir == '/' ? '/$name' : '$dir/$name';
}

Map<String, dynamic> sshJson() => <String, dynamic>{
  'host': '10.0.0.9',
  'port': 22,
  'username': 'tester',
  'password': 'secret',
  'root': '/srv/app',
};

void main() {
  late FakeAgent agent;
  late SshWorkspaceExecutor executor;

  setUp(() {
    agent = FakeAgent();
    executor = SshWorkspaceExecutor(
      ensureTunnel: agent.ensure,
      requestAgent: agent.request,
    );
  });

  Future<Map<String, dynamic>> register({String leaseId = 'lease-1'}) =>
      executor.execute(kSshLeaseRegisterCommand, <String, dynamic>{
        'ssh': sshJson(),
        'ssh_lease_id': leaseId,
      });

  test('命令表：9 条、全部 ssh. 命名空间（不占用 local_executor 的 file.*）', () {
    expect(kSshWorkspaceCommands, <String>[
      'ssh.lease.register',
      'ssh.file.read',
      'ssh.file.write',
      'ssh.file.list',
      'ssh.file.grep',
      'ssh.file.delete',
      'ssh.file.mkdir',
      'ssh.file.writeBytes',
      'ssh.exec.command',
    ]);
    expect(kSshWorkspaceCommands.contains('file.read'), isFalse);
    expect(kSshWorkspaceCommands.contains('exec.command'), isFalse);
    expect(
      sshWorkspaceStationId('ssh_executor'),
      'plugin.ssh_executor.execute.ssh_workspace',
    );
  });

  test('租约登记：ssh 配置只在这里建/复用隧道，回远端绝对根', () async {
    final Map<String, dynamic> result = await register();
    expect(result['ok'], isTrue);
    expect(result['lease_id'], 'lease-1');
    expect(result['conn_id'], 'conn-1');
    expect(result['root'], '/home/u/ws');
    expect(agent.ensureCalls.single['host'], '10.0.0.9');
    expect(agent.ensureCalls.single['root'], '/srv/app');
    expect(executor.leaseCount, 1);
  });

  test('未登记租约 ⇒ ssh_lease_unknown（调用方据此重登记；不做静默回退）', () async {
    await expectLater(
      executor.execute('ssh.file.read', <String, dynamic>{
        'ssh_lease_id': 'gone',
        'path': 'a.txt',
      }),
      throwsA(
        isA<SshStationError>().having(
          (SshStationError error) => error.message,
          'message',
          contains(kSshLeaseUnknownCode),
        ),
      ),
    );
  });

  test('file.read：相对路径 → 远端绝对路径，行切片与 total_lines 对齐', () async {
    agent.putFile('/home/u/ws/notes/a.txt', 'hello\nworld\n');
    await register();
    final Map<String, dynamic> result = await executor.execute(
      'ssh.file.read',
      <String, dynamic>{
        'ssh_lease_id': 'lease-1',
        'path': 'notes/a.txt',
        'start_line': 2,
        'line_count': 1,
      },
    );
    expect(result['content'], 'world');
    expect(result['total_lines'], 3);
    expect(result['start_line'], 2);
    expect(result['truncated'], isFalse);
    expect(result['path'], 'notes/a.txt');
    expect(agent.calls.every((call) => call.connId == 'conn-1'), isTrue);
  });

  test('file.read：二进制文件回 base64（text 为空）', () async {
    agent.files['/home/u/ws/bin.dat'] = <int>[0xff, 0xfe];
    await register();
    final Map<String, dynamic> result = await executor.execute(
      'ssh.file.read',
      <String, dynamic>{'ssh_lease_id': 'lease-1', 'path': 'bin.dat'},
    );
    expect(result['base64'], '//4=');
    expect(result['content'], '');
  });

  test('越界路径（.. / 绝对路径）一律拒绝', () async {
    await register();
    await expectLater(
      executor.execute('ssh.file.read', <String, dynamic>{
        'ssh_lease_id': 'lease-1',
        'path': '../etc/passwd',
      }),
      throwsA(
        isA<SshStationError>().having(
          (SshStationError error) => error.message,
          'message',
          contains('越出工作空间根目录'),
        ),
      ),
    );
    await expectLater(
      executor.execute('ssh.file.read', <String, dynamic>{
        'ssh_lease_id': 'lease-1',
        'path': '/etc/passwd',
      }),
      throwsA(isA<SshStationError>()),
    );
  });

  test('file.write / writeBytes：自动建父目录，回 bytes_written', () async {
    await register();
    final Map<String, dynamic> written = await executor.execute(
      'ssh.file.write',
      <String, dynamic>{
        'ssh_lease_id': 'lease-1',
        'path': 'notes/b.txt',
        'content': 'hello',
      },
    );
    expect(written['bytes_written'], 5);
    expect(utf8.decode(agent.files['/home/u/ws/notes/b.txt']!), 'hello');

    final Map<String, dynamic> binary = await executor.execute(
      'ssh.file.writeBytes',
      <String, dynamic>{
        'ssh_lease_id': 'lease-1',
        'path': 'bin/a.bin',
        'base64': 'AQID',
      },
    );
    expect(binary['bytes_written'], 3);
    expect(agent.files['/home/u/ws/bin/a.bin'], <int>[1, 2, 3]);
  });

  test('file.list：递归 entries 带目录尾斜杠 / 深度与上限', () async {
    agent.putFile('/home/u/ws/notes/a.txt', 'a');
    agent.putFile('/home/u/ws/notes/deep/c.txt', 'c');
    await register();
    final Map<String, dynamic> result = await executor.execute(
      'ssh.file.list',
      <String, dynamic>{'ssh_lease_id': 'lease-1', 'path': '.', 'max_depth': 2},
    );
    expect(result['entries'], <String>[
      'notes/',
      'notes/a.txt',
      'notes/deep/',
      'notes/deep/c.txt',
    ]);
    expect(result['count'], 4);
    expect(result['truncated'], isFalse);
    expect(result['root'], '/home/u/ws');
  });

  test('file.grep：命中行带相对路径/行号，跳过隐藏目录', () async {
    agent.putFile('/home/u/ws/a.md', 'first\nneedle here\n');
    agent.putFile('/home/u/ws/.hidden/b.md', 'needle hidden\n');
    await register();
    final Map<String, dynamic> result = await executor.execute(
      'ssh.file.grep',
      <String, dynamic>{'ssh_lease_id': 'lease-1', 'pattern': 'needle'},
    );
    expect(result['count'], 1);
    expect((result['matches'] as List<dynamic>).single, <String, dynamic>{
      'path': 'a.md',
      'line': 2,
      'text': 'needle here',
    });
  });

  test('file.delete：文件 / 非空目录（需 recursive）/ mkdir', () async {
    agent.putFile('/home/u/ws/a.txt', 'a');
    agent.putFile('/home/u/ws/dir/b.txt', 'b');
    await register();
    final Map<String, dynamic> file = await executor.execute(
      'ssh.file.delete',
      <String, dynamic>{'ssh_lease_id': 'lease-1', 'path': 'a.txt'},
    );
    expect(file['deleted'], isTrue);
    expect(agent.files.containsKey('/home/u/ws/a.txt'), isFalse);

    await expectLater(
      executor.execute('ssh.file.delete', <String, dynamic>{
        'ssh_lease_id': 'lease-1',
        'path': 'dir',
      }),
      throwsA(
        isA<SshStationError>().having(
          (SshStationError error) => error.message,
          'message',
          contains('目录非空'),
        ),
      ),
    );
    final Map<String, dynamic> dir = await executor.execute(
      'ssh.file.delete',
      <String, dynamic>{
        'ssh_lease_id': 'lease-1',
        'path': 'dir',
        'recursive': true,
      },
    );
    expect(dir['deleted'], isTrue);

    final Map<String, dynamic> made = await executor.execute(
      'ssh.file.mkdir',
      <String, dynamic>{'ssh_lease_id': 'lease-1', 'path': 'new/sub'},
    );
    expect(made['created'], isTrue);
    expect(agent.dirs.contains('/home/u/ws/new/sub'), isTrue);
  });

  test('exec.command：前台输出映射 local_executor 契约；后台 hook 显式未支持', () async {
    await register();
    final Map<String, dynamic> result = await executor.execute(
      'ssh.exec.command',
      <String, dynamic>{
        'ssh_lease_id': 'lease-1',
        'command': 'echo hi',
        'timeout_seconds': 5,
      },
    );
    expect(result['text'], 'hi\nwarn');
    expect(result['exit_code'], 0);
    expect(result['is_error'], isFalse);
    final Map<String, dynamic> execParams = agent.calls
        .lastWhere((call) => call.method == AgentMethods.execRun)
        .params;
    expect(execParams['timeout_ms'], 5000);

    await expectLater(
      executor.execute('ssh.exec.command', <String, dynamic>{
        'ssh_lease_id': 'lease-1',
        'command': 'sleep 1',
        'hook': true,
      }),
      throwsA(
        isA<SshStationError>().having(
          (SshStationError error) => error.message,
          'message',
          contains('暂不支持后台 hook'),
        ),
      ),
    );
    await expectLater(
      executor.execute('ssh.exec.command', <String, dynamic>{
        'ssh_lease_id': 'lease-1',
        'hook_action': 'status',
        'task_id': 't1',
      }),
      throwsA(
        isA<SshStationError>().having(
          (SshStationError error) => error.message,
          'message',
          contains('暂不支持 hook_action'),
        ),
      ),
    );
  });

  test('L2 失败透传为可读错误（含 error_kind 时附加分类）', () async {
    await register();
    final FakeAgent failing = FakeAgent();
    final SshWorkspaceExecutor broken = SshWorkspaceExecutor(
      ensureTunnel: failing.ensure,
      requestAgent:
          (String connId, String method, Map<String, dynamic> params) async {
            return <String, dynamic>{
              'ok': false,
              'error': '隧道未就绪',
              'error_kind': TunnelErrorKinds.tunnelNotReady,
            };
          },
    );
    await broken.execute(kSshLeaseRegisterCommand, <String, dynamic>{
      'ssh': sshJson(),
      'ssh_lease_id': 'lease-1',
    });
    await expectLater(
      broken.execute('ssh.file.read', <String, dynamic>{
        'ssh_lease_id': 'lease-1',
        'path': 'a.txt',
      }),
      throwsA(
        isA<SshStationError>().having(
          (SshStationError error) => error.message,
          'message',
          allOf(contains('隧道未就绪'), contains(TunnelErrorKinds.tunnelNotReady)),
        ),
      ),
    );
  });
}
