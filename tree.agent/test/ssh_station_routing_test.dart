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

/// C：SSH 模式的 tree.agent **不得**再落到核心本机 IO。
///
/// 钉住三件事：
/// 1. 命令路由：`file.*` / `exec.command` 在 SSH 模式改写成 `ssh.*`
///    （`local_executor` 已占用 `file.*`，同名无法区分本机/远端）；
/// 2. 租约：先 `ssh.lease.register` 拿远端根，后续命令只带 `ssh_lease_id`，
///    **不带**核心 `lease_id`（核心只认本机存在的目录）；
/// 3. 失效重登记：执行站回 `ssh_lease_unknown` 时重登记并**只重试一次**，
///    其它业务错误绝不重放。
void main() {
  late Directory temp;
  late AgentDataPaths paths;
  late List<Map<String, dynamic>> calls;
  late List<Map<String, dynamic>> registrations;
  bool failFirstSshRead = false;
  bool sshReadFails = false;
  int registerCount = 0;
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
    registrations = <Map<String, dynamic>>[];
    failFirstSshRead = false;
    sshReadFails = false;
    registerCount = 0;
    sshReadCount = 0;
    AgentRuntime.workspaceRegister = (String id, String dir) async {
      registrations.add(<String, dynamic>{'id': id, 'dir': dir});
    };
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
              registerCount++;
              return <String, dynamic>{
                'ok': true,
                'lease_id': arguments['ssh_lease_id'],
                'conn_id': 'conn-ssh-1',
                'root': '/home/tester/ws',
                'host': (arguments['ssh'] as Map)['host'],
              };
            case 'ssh.file.read':
              sshReadCount++;
              if (failFirstSshRead) {
                failFirstSshRead = false;
                throw StateError('$kSshLeaseUnknownCode: 租约未登记（插件进程可能重启过）');
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
            case 'file.read':
              return <String, dynamic>{
                'path': arguments['path'],
                'content': 'local',
                'total_lines': 1,
                'start_line': 1,
                'truncated': false,
              };
            default:
              throw StateError('路由测试遇到意外命令：$command');
          }
        };
  });

  tearDown(() async {
    AgentRuntime.stationClient = null;
    AgentRuntime.workspaceRegister = null;
    await AgentRuntime.debugCloseAll();
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  AgentRuntime runtime() => AgentRuntime(
    paths: paths,
    engine: ScriptedAgent(chunkDelay: Duration.zero),
  );

  test('命令映射表：file.* / terminal.exec / exec.command 全部改道 ssh.*', () {
    expect(sshStationCommandFor('file.read'), 'ssh.file.read');
    expect(sshStationCommandFor('fs.write'), 'ssh.file.write');
    expect(sshStationCommandFor('file.list'), 'ssh.file.list');
    expect(sshStationCommandFor('file.grep'), 'ssh.file.grep');
    expect(sshStationCommandFor('file.delete'), 'ssh.file.delete');
    expect(sshStationCommandFor('file.mkdir'), 'ssh.file.mkdir');
    expect(sshStationCommandFor('file.writeBytes'), 'ssh.file.writeBytes');
    expect(sshStationCommandFor('terminal.exec'), 'ssh.exec.command');
    expect(sshStationCommandFor('exec.command'), 'ssh.exec.command');
    expect(sshStationCommandFor('todo.set'), isNull);
    expect(
      kSshStationCommands.values.every((v) => v.startsWith('ssh.')),
      isTrue,
    );
  });

  test('SSH 工作空间：先登记远端租约，file.read 走 ssh.file.read（无核心 lease_id）', () async {
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
    expect(registrations, isEmpty, reason: 'SSH 不登记核心本机租约');

    final Map<String, dynamic> read = calls[1];
    expect(read['command'], 'ssh.file.read');
    final Map<String, dynamic> readArgs =
        read['arguments'] as Map<String, dynamic>;
    expect(readArgs['path'], 'notes/a.txt');
    expect(readArgs.containsKey('lease_id'), isFalse);
    expect(readArgs['ssh_lease_id'], registerArgs['ssh_lease_id']);
    expect(readArgs['root'], '/home/tester/ws');
    expect((read['scope'] as Map)['mode_key'], 'ssh');
  });

  test('file.write/list/delete/writeBytes/mkdir 全部走 ssh.*（不回本机）', () async {
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
    expect(commands.any((String c) => c.startsWith('file.')), isFalse);
    expect(commands.contains('exec.command'), isFalse);
  });

  test('exec.command / terminal.exec 改道 ssh.exec.command', () async {
    final AgentRuntime rt = runtime();
    final Map<String, dynamic> foreground = await rt.dispatchStationCommand(
      'ssh_agt',
      'exec.command',
      <String, dynamic>{'command': 'echo hi'},
      sessionId: 's1',
    );
    expect(foreground['text'], 'hi');
    final Map<String, dynamic> last = calls.last;
    expect(last['command'], 'ssh.exec.command');
    final Map<String, dynamic> args = last['arguments'] as Map<String, dynamic>;
    expect(args['command'], 'echo hi');
    expect(args.containsKey('lease_id'), isFalse);
    expect(args['root'], '/home/tester/ws');

    await rt.dispatchStationCommand(
      'ssh_agt',
      'terminal.exec',
      <String, dynamic>{'command': 'pwd'},
    );
    expect(calls.last['command'], 'ssh.exec.command');
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
    expect(registerCount, 2, reason: '首次登记 + 失效后重登记');
    expect(sshReadCount, 2, reason: '只重试一次');

    calls.clear();
    registerCount = 0;
    sshReadCount = 0;
    sshReadFails = true;
    await expectLater(io.readFile('notes/a.txt'), throwsA(isA<StateError>()));
    expect(registerCount, 0, reason: '缓存租约仍有效：业务失败不重登记、不重试');
    expect(sshReadCount, 1, reason: '业务失败绝不重放');
  });

  test('本机 agent 行为不变：file.* + 核心 workspace/register 租约', () async {
    final AgentRuntime rt = runtime();
    final WorkspaceIO io = (await rt.workspaceIoFor('local_agt', 's1'))!;
    final FileContent content = await io.readFile('a.txt');
    expect(content.text, 'local');
    expect(calls.single['command'], 'file.read');
    final Map<String, dynamic> args =
        calls.single['arguments'] as Map<String, dynamic>;
    expect(args.containsKey('lease_id'), isTrue);
    expect(args.containsKey('ssh_lease_id'), isFalse);
    expect(args.containsKey('root'), isFalse);
    expect(registrations, hasLength(1));
    expect('${registrations.single['dir']}', contains(temp.path));
    expect((calls.single['scope'] as Map)['mode_key'], 'local');
  });
}
