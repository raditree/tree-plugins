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
  final Map<String, Map<String, dynamic>> procs = <String, Map<String, dynamic>>{};
  int _seq = 0;

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
        // `mode: append` = 分块写的后续块（与目标机 tree_agent 同语义）。
        final bool append = params['mode'] == 'append';
        files[path] = append
            ? <int>[...?files[path], ...bytes]
            : bytes;
        _ensureParents(path);
        return _ok(<String, dynamic>{'size': files[path]!.length});
      case AgentMethods.fsRename:
        final String from = params['from'].toString();
        final String to = params['to'].toString();
        if (!files.containsKey(from) && !_isDir(from)) {
          return _fail('源路径不存在：$from', TunnelErrorCodes.notFound);
        }
        if (files.containsKey(to) || _isDir(to)) {
          return _fail('目标已存在：$to', TunnelErrorCodes.alreadyExists);
        }
        final List<int>? data = files.remove(from);
        if (data != null) {
          files[to] = data;
          _ensureParents(to);
        } else {
          dirs.add(to);
          dirs.remove(from);
          _ensureParents(to);
        }
        return _ok(<String, dynamic>{});
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
                if (names[name] == 'file') 'mtime_ms': 1700000000000,
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
      case AgentMethods.execSpawn:
        final String id = 'job-${++_seq}';
        final String logPath = params['log_path'].toString();
        procs[id] = <String, dynamic>{
          'id': id,
          'state': 'running',
          'log_path': logPath,
          'command': params['command'],
        };
        return _ok(<String, dynamic>{
          'id': id,
          'pid': 100 + _seq,
          'pgid': 100 + _seq,
          'log_path': logPath,
          'started_at_ms': 1,
        });
      case AgentMethods.execQuery:
        final Map<String, dynamic>? proc = procs[params['id'].toString()];
        if (proc == null) {
          return _fail('没有这条后台任务', TunnelErrorCodes.notFound);
        }
        return _ok(<String, dynamic>{'proc': proc});
      case AgentMethods.execKill:
        final Map<String, dynamic>? proc = procs[params['id'].toString()];
        if (proc != null) proc['state'] = 'exited';
        return _ok(<String, dynamic>{'killed': proc != null});
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

  test('命令表：10 条、全部 ssh. 命名空间（不占用 local_executor 的 file.*）', () {
    expect(kSshWorkspaceCommands, <String>[
      'ssh.lease.register',
      'ssh.file.read',
      'ssh.file.write',
      'ssh.file.list',
      'ssh.file.grep',
      'ssh.file.delete',
      'ssh.file.mkdir',
      'ssh.file.writeBytes',
      'ssh.file.rename',
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

  test('租约归属：登记方之外的插件借句柄 ⇒ lease_denied（与本机侧同一口径）', () async {
    // 契约 §8.3：租约统一到插件侧后，「租约只能登记方自己用」这道闸门只剩执行器一个
    // 落点。不比对发起方（核心 meta 里带下来的 source_plugin_id），任何插件猜到会
    // 句柄就能借别人的隧道读写远端文件。
    Future<Map<String, dynamic>> registerAs(String pluginId) =>
        executor.execute(
          kSshLeaseRegisterCommand,
          <String, dynamic>{'ssh': sshJson(), 'ssh_lease_id': 'lease-1'},
          sourcePluginId: pluginId,
        );
    await registerAs('tree.agent');
    agent.putFile('/home/u/ws/notes/a.txt', 'hello\n');
    final Map<String, dynamic> mine = await executor.execute(
      'ssh.file.read',
      <String, dynamic>{'ssh_lease_id': 'lease-1', 'path': 'notes/a.txt'},
      sourcePluginId: 'tree.agent',
    );
    expect(mine['content'], 'hello\n');

    await expectLater(
      executor.execute(
        'ssh.file.read',
        <String, dynamic>{'ssh_lease_id': 'lease-1', 'path': 'notes/a.txt'},
        sourcePluginId: 'demo_intruder',
      ),
      throwsA(
        isA<SshStationError>().having(
          (SshStationError error) => error.message,
          'message',
          allOf(contains(kLeaseDeniedCode), contains('tree.agent')),
        ),
      ),
    );
    // 顶不掉：重登记同一条句柄也只认原登记方。
    await expectLater(registerAs('demo_intruder'), throwsA(
      isA<SshStationError>().having(
        (SshStationError error) => error.message,
        'message',
        contains(kLeaseDeniedCode),
      ),
    ));
    expect(executor.leaseCount, 1);
    // 归属不符**不是**租约失效：带了完整 ssh 配置也不能自动重登记（否则入侵者
    // 只要把凭据再递一次就顶掉了原登记方）。
    await expectLater(
      executor.execute(
        'ssh.file.read',
        <String, dynamic>{
          'ssh_lease_id': 'lease-1',
          'path': 'notes/a.txt',
          'ssh': sshJson(),
        },
        sourcePluginId: 'demo_intruder',
      ),
      throwsA(
        isA<SshStationError>().having(
          (SshStationError error) => error.message,
          'message',
          allOf(contains(kLeaseDeniedCode), isNot(contains(kSshLeaseUnknownCode))),
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

  test('file.read{raw}：分块通道（offset/length/eof）不受文本上限约束', () async {
    agent.files['/home/u/ws/big.bin'] = List<int>.generate(100, (int i) => i);
    await register();
    final Map<String, dynamic> first = await executor.execute(
      'ssh.file.read',
      <String, dynamic>{
        'ssh_lease_id': 'lease-1',
        'path': 'big.bin',
        'raw': true,
        'offset': 0,
        'length': 40,
      },
    );
    expect(base64Decode(first['base64'] as String), hasLength(40));
    expect(first['offset'], 0);
    expect(first['size'], 100);
    expect(first['eof'], isFalse, reason: '只读了前 40 字节');
    expect(first.containsKey('content'), isFalse, reason: 'raw 通道不做行处理');

    final Map<String, dynamic> tail = await executor.execute(
      'ssh.file.read',
      <String, dynamic>{
        'ssh_lease_id': 'lease-1',
        'path': 'big.bin',
        'raw': true,
        'offset': 80,
        'length': 40,
      },
    );
    expect(base64Decode(tail['base64'] as String), hasLength(20));
    expect(tail['eof'], isTrue, reason: '越过尾部时 eof=true，调用方据此收口');
  });

  test('file.writeBytes{append}：首块截断重建、后续块追加', () async {
    await register();
    await executor.execute('ssh.file.writeBytes', <String, dynamic>{
      'ssh_lease_id': 'lease-1',
      'path': 'up.bin',
      'base64': base64Encode(<int>[1, 2, 3]),
    });
    await executor.execute('ssh.file.writeBytes', <String, dynamic>{
      'ssh_lease_id': 'lease-1',
      'path': 'up.bin',
      'base64': base64Encode(<int>[4, 5]),
      'append': true,
    });
    expect(agent.files['/home/u/ws/up.bin'], <int>[1, 2, 3, 4, 5]);
  });

  test('file.list：entries 保持字符串表，details 带 size/mtime', () async {
    agent.putFile('/home/u/ws/notes/a.txt', 'hello');
    agent.dirs.add('/home/u/ws/notes/sub');
    await register();
    final Map<String, dynamic> listed = await executor.execute(
      'ssh.file.list',
      <String, dynamic>{
        'ssh_lease_id': 'lease-1',
        'path': 'notes',
        'max_depth': 0,
      },
    );
    expect(listed['entries'], contains('notes/a.txt'));
    expect(listed['entries'], contains('notes/sub/'));
    final List<dynamic> details = listed['details'] as List<dynamic>;
    final Map<String, dynamic> fileDetail = details
        .cast<Map<String, dynamic>>()
        .firstWhere((Map<String, dynamic> item) => item['name'] == 'notes/a.txt');
    expect(fileDetail['type'], 'file');
    expect(fileDetail['size'], 5);
    expect(fileDetail['mtime_ms'], 1700000000000);
  });

  test('file.rename：走目标机 fs.rename（原子；目标已存在即拒）', () async {
    agent.putFile('/home/u/ws/a.txt', 'one');
    await register();
    final Map<String, dynamic> renamed = await executor.execute(
      'ssh.file.rename',
      <String, dynamic>{
        'ssh_lease_id': 'lease-1',
        'from': 'a.txt',
        'to': 'b.txt',
      },
    );
    expect(renamed['from'], 'a.txt');
    expect(renamed['to'], 'b.txt');
    expect(agent.files.containsKey('/home/u/ws/a.txt'), isFalse);
    expect(utf8.decode(agent.files['/home/u/ws/b.txt']!), 'one');
    expect(
      agent.calls.any(
        (({String connId, String method, Map<String, dynamic> params}) call) =>
            call.method == AgentMethods.fsRename,
      ),
      isTrue,
      reason: '不允许再用 ssh.exec.command 拼 mv',
    );

    agent.putFile('/home/u/ws/a.txt', 'one');
    agent.putFile('/home/u/ws/c.txt', 'two');
    await expectLater(
      executor.execute('ssh.file.rename', <String, dynamic>{
        'ssh_lease_id': 'lease-1',
        'from': 'a.txt',
        'to': 'c.txt',
      }),
      throwsA(isA<SshStationError>()),
      reason: '目标已存在必须拒绝（fs.rename 绝不覆盖）',
    );
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

  test('exec.command：前台映射；hook 走远端 exec.spawn/query/kill', () async {
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

    final Map<String, dynamic> started = await executor.execute(
      'ssh.exec.command',
      <String, dynamic>{
        'ssh_lease_id': 'lease-1',
        'command': 'sleep 100',
        'hook': true,
      },
    );
    final String taskId = started['task_id'].toString();
    expect(taskId, isNotEmpty);
    expect(started['running'], isTrue);
    expect(started['log_relative'], startsWith('.self/ssh_hooks/'));
    final Map<String, dynamic> spawnParams = agent.calls
        .lastWhere((call) => call.method == AgentMethods.execSpawn)
        .params;
    expect(spawnParams['log_path'], startsWith('/home/u/ws/.self/ssh_hooks/'));
    expect(spawnParams['cwd'], '/home/u/ws');

    final Map<String, dynamic> running = await executor.execute(
      'ssh.exec.command',
      <String, dynamic>{
        'ssh_lease_id': 'lease-1',
        'hook_action': 'status',
        'task_id': taskId,
      },
    );
    expect(running['running'], isTrue);

    agent.procs[taskId]!['state'] = 'exited';
    agent.procs[taskId]!['exit_code'] = 0;
    final Map<String, dynamic> done = await executor.execute(
      'ssh.exec.command',
      <String, dynamic>{
        'ssh_lease_id': 'lease-1',
        'hook_action': 'status',
        'task_id': taskId,
      },
    );
    expect(done['running'], isFalse);
    expect(done['exit_code'], 0);

    final Map<String, dynamic> cancelled = await executor.execute(
      'ssh.exec.command',
      <String, dynamic>{
        'ssh_lease_id': 'lease-1',
        'hook_action': 'cancel',
        'task_id': taskId,
      },
    );
    expect(cancelled['cancelled'], isTrue);
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
