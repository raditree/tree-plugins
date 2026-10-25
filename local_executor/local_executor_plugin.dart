// local_executor —— 本机执行器插件（L-24）。
//
// 核心执行站把 fs.* / terminal.exec 挂到本插件；插件在**租约根目录**内读写、
// 起进程。核心不碰文件、不起进程，也不解析 agent/team/mode 身份。
import 'dart:async';
import 'dart:io';

import 'package:tree_local_executor/tree_local_executor.dart';

import '../_kit/plugin_kit.dart';

const String kPluginId = 'local_executor';
const String kDisplayName = '本机执行器';
const String kVersion = '0.3.0';
final LocalExecutor _executor = LocalExecutor();

/// 自建执行站：插件内部定义命令，核心只登记与路由。
const List<String> kExecutorCommands = <String>[
  'file.read',
  'file.write',
  'file.list',
  'file.grep',
  'file.delete',
  'file.mkdir',
  'file.writeBytes',
  'exec.command',
];

const String kStationReadme =
    '本机执行器自建执行站：接 file.* / exec.command。调用方带 lease_id + '
    '工作空间内相对路径，核心只登记 lease_id → 目录并路由，不碰文件、不起进程。';

PluginKitServer buildServer({bool exitOnShutdown = true}) => PluginKitServer(
  channel: PluginChannel.stdio(kPluginId),
  pluginId: kPluginId,
  displayName: kDisplayName,
  onReady: _onReady,
  onRequest: handleRequest,
  exitOnShutdown: exitOnShutdown,
);

Future<void> _onReady(PluginKitServer server) async {
  server.channel.log('已上线：v$kVersion（本机执行器，L-24）');
  try {
    final Map<String, dynamic> result = await server.channel.request(
      M.stationRegister,
      <String, dynamic>{
        'kind': 'execute',
        'name': 'local',
        'description': '本机执行器（file.* / exec.command）',
        'readme': kStationReadme,
        'commands': kExecutorCommands,
        'shared': true,
      },
    );
    server.channel.log(
      '自建执行站：${result['ok'] == true ? result['station_id'] : result['error']}',
    );
  } catch (error) {
    server.channel.log('自建执行站失败：$error');
  }
}

Future<Map<String, dynamic>?> handleRequest(
  String method,
  Map<String, dynamic> params,
) async {
  if (method != M.stationRequest) return null;
  final Map<String, dynamic> payload = asMap(params['payload']);
  final String command = asString(payload['command']);
  final Map<String, dynamic> arguments = asMap(payload['arguments']);
  try {
    final Map<String, dynamic> result = await _executor.execute(
      command,
      arguments,
    );
    return <String, dynamic>{
      'reply': <String, dynamic>{'payload': result},
    };
  } catch (error) {
    return <String, dynamic>{
      'reply': <String, dynamic>{'error': error.toString()},
    };
  }
}

Future<void> main(List<String> args) async {
  if (args.contains('--selftest')) {
    exitCode = await selfTest();
    return;
  }
  await buildServer().run(stdin);
  try {
    await stdout.flush();
  } catch (_) {}
}

Future<int> selfTest() async {
  final SelfTest check = SelfTest(name: 'local_executor_plugin');
  final Directory temp = Directory.systemTemp.createTempSync('local_exec_');
  try {
    final LocalExecutor executor = LocalExecutor();
    final Map<String, dynamic> root = <String, dynamic>{'root': temp.path};

    final Map<String, dynamic> written = await executor.execute('fs.write', <String, dynamic>{
      ...root,
      'path': 'notes/a.txt',
      'content': 'hello\nworld\n',
    });
    check.check(written['bytes_written'], 12, 'fs.write 返回字节数');

    final Map<String, dynamic> read = await executor.execute('fs.read', <String, dynamic>{
      ...root,
      'path': 'notes/a.txt',
    });
    check.check(read['content'], 'hello\nworld\n', 'fs.read 读回内容');
    check.check(read['total_lines'], 3, 'fs.read 总行数');

    final Map<String, dynamic> listed = await executor.execute('fs.list', <String, dynamic>{
      ...root,
      'path': '.',
      'max_depth': 3,
    });
    check.that(
      (listed['entries'] as List<dynamic>).contains('notes/a.txt'),
      'fs.list 能看到写入的文件',
    );

    final Map<String, dynamic> grep = await executor.execute('fs.grep', <String, dynamic>{
      ...root,
      'pattern': 'world',
    });
    check.check(grep['count'], 1, 'fs.grep 命中一行');

    final Map<String, dynamic> escaped = <String, dynamic>{
      'root': temp.path,
      'path': '../outside.txt',
    };
    var rejected = false;
    try {
      await executor.execute('fs.write', escaped);
    } on ExecutorError {
      rejected = true;
    }
    check.that(rejected, '越界路径被拒绝');

    final Map<String, dynamic> made = await executor.execute('fs.mkdir', <String, dynamic>{
      ...root,
      'path': 'bin',
    });
    check.check(made['created'], true, 'fs.mkdir 创建目录');

    final Map<String, dynamic> bytes = await executor.execute('fs.writeBytes', <String, dynamic>{
      ...root,
      'path': 'bin/a.bin',
      'base64': 'AQID',
    });
    check.check(bytes['bytes_written'], 3, 'fs.writeBytes 写入二进制');
    check.check(
      File('${temp.path}/bin/a.bin').readAsBytesSync(),
      <int>[1, 2, 3],
      'fs.writeBytes 字节内容',
    );

    final Map<String, dynamic> deleted = await executor.execute('fs.delete', <String, dynamic>{
      ...root,
      'path': 'bin/a.bin',
    });
    check.check(deleted['deleted'], true, 'fs.delete 删除文件');
    check.that(
      !File('${temp.path}/bin/a.bin').existsSync(),
      '删除后文件不存在',
    );

    final Map<String, dynamic> terminal = await executor.execute('terminal.exec', <String, dynamic>{
      ...root,
      'command': Platform.isWindows ? 'echo hi' : 'printf hi',
    });
    check.that(
      '${terminal['text']}'.contains('hi'),
      'terminal.exec 能执行并回输出',
    );

    final Map<String, dynamic> hook = await executor.execute('exec.command', <String, dynamic>{
      ...root,
      'command': Platform.isWindows ? 'ping -n 5 127.0.0.1 >nul' : 'sleep 3',
      'hook': true,
    });
    final String taskId = (hook['task_id'] ?? '').toString();
    check.that(taskId.isNotEmpty, 'terminal hook 后台启动返回 task_id');
    final Map<String, dynamic> status = await executor.execute('exec.command', <String, dynamic>{
      ...root,
      'hook_action': 'status',
      'task_id': taskId,
    });
    check.that(
      '${status['text']}'.contains('运行中') ||
          '${status['text']}'.contains('已结束'),
      'terminal hook 可查询状态',
    );
    final Map<String, dynamic> cancelled = await executor.execute('exec.command', <String, dynamic>{
      ...root,
      'hook_action': 'cancel',
      'task_id': taskId,
    });
    check.that(
      '${cancelled['text']}'.contains('已请求终止') ||
          '${cancelled['text']}'.contains('已结束'),
      'terminal hook 可取消',
    );
  } finally {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  }
  return check.finish();
}