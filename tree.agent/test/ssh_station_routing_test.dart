import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_agent_loop/src/agent/scripted_agent.dart';
import 'package:tree_agent_loop/src/paths.dart';
import 'package:tree_agent_loop/src/runtime/agent_runtime.dart';
import 'package:tree_agent_loop/src/settings/ssh_config.dart';
import 'package:tree_agent_loop/src/store/file_store.dart';
import 'package:tree_agent_loop/src/store/records.dart';
import 'package:tree_agent_loop/src/store/tree_paths.dart';
import 'package:tree_agent_loop/src/workspace/workspace_io.dart';

/// C：SSH 模式的 tree.agent **不得**再落到本机执行站（契约 §8.1 / §8.3）。
///
/// 钉住三件事：
/// 1. 命令路由：`local.*` 在 SSH 模式只换前缀成 `ssh.*`（两侧后缀逐字相同），
///    非 `local.*` 的命令（`todo.*` 这类）原样下发；
/// 2. 租约：两侧都由**执行器插件自己**登记（`local.lease.register` /
///    `ssh.lease.register`），后续命令只带对应句柄键，核心不再持有 `lease_id`，
///    `root` 也不从 arguments 走；
/// 3. 失效重登记：执行站回 `*_lease_unknown` 时重登记并**只重试一次**，
///    其它业务错误绝不重放。
void main() {
  late Directory temp;
  late AgentDataPaths paths;
  late List<Map<String, dynamic>> calls;
  bool failFirstSshRead = false;
  bool failFirstLocalRead = false;
  bool sshReadFails = false;
  int sshRegisterCount = 0;
  int localRegisterCount = 0;
  int sshReadCount = 0;

  Future<void> seedAgents() async {
    final FileTreeStore store = FileTreeStore(TreePaths(temp.path));
    store.putAgent(
      CoreAgent(
        id: 'ssh_agt',
        name: '远端',
        createdAt: 1,
        updatedAt: 1,
        modelId: 'm1',
        sshConfig: SshConfig(
          host: '10.0.0.9',
          username: 'tester',
          password: 'secret',
          root: '/srv/app',
        ),
      ),
    );
    store.putAgent(
      CoreAgent(
        id: 'local_agt',
        name: '本机',
        createdAt: 2,
        updatedAt: 2,
        modelId: 'm1',
      ),
    );
    store.putAgent(
      CoreAgent(
        id: 'top',
        name: '指挥',
        createdAt: 3,
        updatedAt: 3,
        modelId: 'm1',
        sshConfig: SshConfig(
          host: '10.0.0.10',
          username: 'top',
          password: 'topsecret',
          root: '/srv/team',
        ),
      ),
    );
    store.putAgent(
      CoreAgent(
        id: 'member',
        name: '成员',
        createdAt: 4,
        updatedAt: 4,
        modelId: 'm1',
        teamId: 'top',
        parentAgentId: 'top',
        level: 1,
      ),
    );
    await store.flush();
    await store.close();
  }

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tree_agent_ssh_route_');
    paths = AgentDataPaths(temp.path);
    await seedAgents();
    await AgentRuntime.debugCloseAll();
    calls = <Map<String, dynamic>>[];
    failFirstSshRead = false;
    failFirstLocalRead = false;
    sshReadFails = false;
    sshRegisterCount = 0;
    localRegisterCount = 0;
    sshReadCount = 0;
    AgentRuntime.stationClient =
        (
          String command,
          Map<String, dynamic> arguments,
          Map<String, dynamic> scope,
        ) async {
          calls.add(<String, dynamic>{
            'command': command,
            'arguments': arguments,
            'scope': scope,
          });
          switch (command) {
            case 'ssh.lease.register':
              sshRegisterCount++;
              return <String, dynamic>{
                'ok': true,
                'lease_id': arguments['ssh_lease_id'],
                'conn_id': 'conn-ssh-1',
                'root': '/home/tester/ws',
                'host': (arguments['ssh'] as Map)['host'],
              };
            case 'local.lease.register':
              localRegisterCount++;
              return <String, dynamic>{
                'ok': true,
                'lease_id': arguments['local_lease_id'],
                'root': arguments['dir'],
              };
            case 'ssh.file.read':
              sshReadCount++;
              if (failFirstSshRead) {
                failFirstSshRead = false;
                throw StateError(
                  '$kSshLeaseUnknownCode: 租约未登记（插件进程可能重启过）',
                );
              }
              if (sshReadFails) throw StateError('文件不存在：notes/a.txt');
              return <String, dynamic>{
                'path': arguments['path'],
                'content': 'hello',
                'total_lines': 1,
                'start_line': 1,
                'truncated': false,
              };
            case 'ssh.file.write':
              return <String, dynamic>{'bytes_written': 5};
            case 'ssh.file.list':
              return <String, dynamic>{
                'entries': <String>['a.txt'],
                'count': 1,
                'truncated': false,
              };
            case 'ssh.file.delete':
              return <String, dynamic>{'deleted': true};
            case 'ssh.file.writeBytes':
              return <String, dynamic>{'bytes_written': 3};
            case 'ssh.file.mkdir':
              return <String, dynamic>{'created': true};
            case 'ssh.exec.command':
              return <String, dynamic>{
                'text': 'hi',
                'is_error': false,
                'exit_code': 0,
              };
            case 'local.file.read':
              if (failFirstLocalRead) {
                failFirstLocalRead = false;
                throw StateError(
                  '$kLocalLeaseUnknownCode: 租约未登记（插件进程可能重启过）',
                );
              }
              return <String, dynamic>{
                'path': arguments['path'],
                'content': 'local',
                'total_lines': 1,
                'start_line': 1,
                'truncated': false,
              };
            case 'local.file.write':
              return <String, dynamic>{'bytes_written': 5};
            case 'local.file.delete':
              return <String, dynamic>{'deleted': true};
            case 'local.file.writeBytes':
              return <String, dynamic>{'bytes_written': 3};
            case 'local.file.mkdir':
              return <String, dynamic>{'created': true};
            case 'local.exec.command':
              return <String, dynamic>{
                'text': 'hi',
                'is_error': false,
                'exit_code': 0,
              };
            case 'todo.set':
              return <String, dynamic>{'ok': true};
            default:
              throw StateError('路由测试遇到意外命令：$command');
          }
        };
  });

  tearDown(() async {
    AgentRuntime.stationClient = null;
    await AgentRuntime.debugCloseAll();
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  AgentRuntime runtime() => AgentRuntime(
    paths: paths,
    engine: ScriptedAgent(chunkDelay: Duration.zero),
  );

  test('改道只有一条规则：前缀 local. 换 ssh.；别的命令不碰', () {
    expect(sshStationCommandFor('local.file.read'), 'ssh.file.read');
    expect(sshStationCommandFor('local.file.write'), 'ssh.file.write');
    expect(sshStationCommandFor('local.file.list'), 'ssh.file.list');
    expect(sshStationCommandFor('local.file.grep'), 'ssh.file.grep');
    expect(sshStationCommandFor('local.file.delete'), 'ssh.file.delete');
    expect(sshStationCommandFor('local.file.mkdir'), 'ssh.file.mkdir');
    expect(sshStationCommandFor('local.file.writeBytes'), 'ssh.file.writeBytes');
    expect(sshStationCommandFor('local.file.rename'), 'ssh.file.rename');
    expect(sshStationCommandFor('local.exec.command'), 'ssh.exec.command');
    // 旧名与领域命令都不在改道范围内。
    expect(sshStationCommandFor('file.read'), isNull);
    expect(sshStationCommandFor('fs.write'), isNull);
    expect(sshStationCommandFor('terminal.exec'), isNull);
    expect(sshStationCommandFor('todo.set'), isNull);
    expect(isLocalStationCommand('local.file.read'), isTrue);
    expect(isLocalStationCommand('ssh.file.read'), isFalse);
    expect(isLocalStationCommand('spec.read'), isFalse);
  });

  test('SSH 工作空间：先登记远端租约，local.file.read 走 ssh.file.read', () async {
    final AgentRuntime rt = runtime();
    final WorkspaceIO? io = await rt.workspaceIoFor('ssh_agt', 's1');
    expect(io, isNotNull);
    expect(io!.root, startsWith('ssh://tester@10.0.0.9:22/'));
    final FileContent content = await io.readFile('notes/a.txt');
    expect(content.text, 'hello');

    expect(calls, hasLength(2));
    final Map<String, dynamic> register = calls[0];
    expect(register['command'], 'ssh.lease.register');
    final Map<String, dynamic> registerArgs =
        register['arguments'] as Map<String, dynamic>;
    expect(registerArgs.containsKey('lease_id'), isFalse);
    expect(registerArgs.containsKey('ssh_lease_id'), isTrue);
    final Map<String, dynamic> ssh =
        registerArgs['ssh'] as Map<String, dynamic>;
    expect(ssh['host'], '10.0.0.9');
    expect(ssh['password'], 'secret');
    expect(ssh['root'], '/srv/app');
    expect((register['scope'] as Map)['mode_key'], 'ssh');

    final Map<String, dynamic> read = calls[1];
    expect(read['command'], 'ssh.file.read');
    final Map<String, dynamic> readArgs =
        read['arguments'] as Map<String, dynamic>;
    expect(readArgs['path'], 'notes/a.txt');
    expect(readArgs.containsKey('lease_id'), isFalse);
    expect(readArgs['ssh_lease_id'], registerArgs['ssh_lease_id']);
    // root 只来自执行器那张租约表：不从 arguments 走（核心也会把它剥掉）。
    expect(readArgs.containsKey('root'), isFalse);
    expect(readArgs.containsKey('local_lease_id'), isFalse);
    expect((read['scope'] as Map)['mode_key'], 'ssh');
  });

  test('本机工作空间：local.lease.register 走执行站，命令带 local_lease_id', () async {
    final AgentRuntime rt = runtime();
    final WorkspaceIO io = (await rt.workspaceIoFor('local_agt', 's1'))!;
    final FileContent content = await io.readFile('a.txt');
    expect(content.text, 'local');
    expect(io.root, contains(temp.path));

    expect(calls, hasLength(2));
    final Map<String, dynamic> register = calls.first;
    expect(register['command'], 'local.lease.register');
    final Map<String, dynamic> registerArgs =
        register['arguments'] as Map<String, dynamic>;
    expect('${registerArgs['dir']}', contains(temp.path));
    expect('${registerArgs['local_lease_id']}', startsWith('local_ws_'));
    expect((register['scope'] as Map)['mode_key'], 'local');

    final Map<String, dynamic> read = calls.last;
    expect(read['command'], 'local.file.read');
    final Map<String, dynamic> args =
        read['arguments'] as Map<String, dynamic>;
    expect(args['local_lease_id'], registerArgs['local_lease_id']);
    expect(args.containsKey('lease_id'), isFalse, reason: '核心租约簿记已撤');
    expect(args.containsKey('ssh_lease_id'), isFalse);
    expect(args.containsKey('root'), isFalse);

    // 同一根只登记一次：后续命令复用缓存句柄。
    await io.writeFile('b.txt', 'x');
    expect(localRegisterCount, 1);
  });

  test('local_lease_unknown：重登记后重试一次（与 SSH 侧同一判据）', () async {
    final AgentRuntime rt = runtime();
    final WorkspaceIO io = (await rt.workspaceIoFor('local_agt', 's1'))!;
    failFirstLocalRead = true;
    final FileContent content = await io.readFile('a.txt');
    expect(content.text, 'local');
    expect(localRegisterCount, 2, reason: '首次登记 + 失效后重登记');
  });

  test('local.* 全族在 SSH 模式下改道（不残留本机命令）', () async {
    final AgentRuntime rt = runtime();
    final WorkspaceIO io = (await rt.workspaceIoFor('ssh_agt', 's1'))!;
    await io.writeFile('a.txt', 'hello');
    await io.listFiles();
    await io.deleteFile('a.txt');
    final WorkspaceFiles files = io as WorkspaceFiles;
    await files.writeBytes('a.bin', <int>[1, 2, 3]);
    await files.makeDirectory('sub');
    final List<String> commands = <String>[
      for (final Map<String, dynamic> call in calls) '${call['command']}',
    ];
    expect(
      commands,
      containsAll(<String>[
        'ssh.lease.register',
        'ssh.file.write',
        'ssh.file.list',
        'ssh.file.delete',
        'ssh.file.writeBytes',
        'ssh.file.mkdir',
      ]),
    );
    expect(
      commands.any((String c) => c.startsWith('local.')),
      isFalse,
      reason: 'SSH 模式绝不降级回本机命令',
    );
  });

  test('local.exec.command 改道 ssh.exec.command；不带租约外的 root', () async {
    final AgentRuntime rt = runtime();
    final Map<String, dynamic> foreground = await rt.dispatchStationCommand(
      'ssh_agt',
      'local.exec.command',
      <String, dynamic>{'command': 'echo hi'},
      sessionId: 's1',
    );
    expect(foreground['text'], 'hi');
    final Map<String, dynamic> last = calls.last;
    expect(last['command'], 'ssh.exec.command');
    final Map<String, dynamic> args = last['arguments'] as Map<String, dynamic>;
    expect(args['command'], 'echo hi');
    expect(args.containsKey('lease_id'), isFalse);
    expect(args.containsKey('root'), isFalse);
    expect(args.containsKey('ssh_lease_id'), isTrue);
  });

  test('非 local.* 的命令原样下发（领域命令不受改道影响）', () async {
    final AgentRuntime rt = runtime();
    await rt.dispatchStationCommand(
      'local_agt',
      'todo.set',
      <String, dynamic>{'items': <String>[]},
      sessionId: 's1',
    );
    expect(calls.single['command'], 'todo.set');
    expect(calls.single['arguments'], isNot(contains('local_lease_id')));
  });

  test('团队成员跟随 TOP 的 SSH 配置（同样改道 ssh.*）', () async {
    final AgentRuntime rt = runtime();
    final WorkspaceIO io = (await rt.workspaceIoFor('member', 's1'))!;
    await io.readFile('a.txt');
    expect(calls.first['command'], 'ssh.lease.register');
    final Map<String, dynamic> ssh =
        (calls.first['arguments'] as Map<String, dynamic>)['ssh']
            as Map<String, dynamic>;
    expect(ssh['host'], '10.0.0.10');
    expect(calls.last['command'], 'ssh.file.read');
    expect((calls.last['scope'] as Map)['team_id'], 'top');
    expect((calls.last['scope'] as Map)['mode_key'], 'ssh');
  });

  test('ssh_lease_unknown：重登记后重试一次；其它错误不重试', () async {
    final AgentRuntime rt = runtime();
    final WorkspaceIO io = (await rt.workspaceIoFor('ssh_agt', 's1'))!;
    failFirstSshRead = true;
    final FileContent content = await io.readFile('notes/a.txt');
    expect(content.text, 'hello');
    expect(sshRegisterCount, 2, reason: '首次登记 + 失效后重登记');
    expect(sshReadCount, 2, reason: '只重试一次');

    failFirstSshRead = false;
    sshRegisterCount = 0;
    sshReadCount = 0;
    sshReadFails = true;
    await expectLater(io.readFile('notes/a.txt'), throwsA(isA<StateError>()));
    expect(sshRegisterCount, 0, reason: '缓存租约仍有效：业务失败不重登记、不重试');
    expect(sshReadCount, 1, reason: '业务失败绝不重放');
  });

  test('reconnectSsh：丢弃缓存句柄后重新登记（命令表里没有 ssh.reconnect）', () async {
    final AgentRuntime rt = runtime();
    final WorkspaceIO io = (await rt.workspaceIoFor('ssh_agt', 's1'))!;
    await io.readFile('notes/a.txt');
    expect(sshRegisterCount, 1);

    calls.clear();
    final Map<String, dynamic> result = await rt.reconnectSsh('ssh_agt');
    expect(result['ok'], isTrue);
    expect(result['stale'], isTrue, reason: '丢掉了上一轮缓存的句柄');
    expect(result['root'], '/home/tester/ws');
    expect(result['conn_id'], 'conn-ssh-1');
    expect(calls, hasLength(1));
    expect(calls.single['command'], 'ssh.lease.register');
    expect((calls.single['scope'] as Map)['agent_id'], 'ssh_agt');
    expect(sshRegisterCount, 2);
  });

  test('reconnectSsh：非 SSH 工作空间给可读错误（REST 据此回 400）', () async {
    final AgentRuntime rt = runtime();
    await expectLater(
      rt.reconnectSsh('local_agt'),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('不是 SSH'),
        ),
      ),
    );
    expect(calls, isEmpty);
  });
}
