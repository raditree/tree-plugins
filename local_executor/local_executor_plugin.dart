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
const String kVersion = '0.1.0';

/// 执行站点位 → 本插件接管的命令。
const Map<String, List<String>> kMounts = <String, List<String>>{
  'system.execute.fs': <String>['fs.read', 'fs.write', 'fs.list', 'fs.grep'],
  'system.execute.terminal': <String>['terminal.exec'],
};

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
  for (final MapEntry<String, List<String>> entry in kMounts.entries) {
    try {
      final Map<String, dynamic> result = await server.channel.command(
        'plugin.mount',
        <String, dynamic>{
          'station_id': entry.key,
          'commands': entry.value,
        },
      );
      server.channel.log(
        '挂载 $entry.key：${result['ok'] == true ? '成功' : result['error'] ?? '失败'}',
      );
    } catch (error) {
      server.channel.log('挂载 $entry.key 失败：$error');
    }
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
    final Map<String, dynamic> result = await const LocalExecutor().execute(
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
    const LocalExecutor executor = LocalExecutor();
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

    final Map<String, dynamic> terminal = await executor.execute('terminal.exec', <String, dynamic>{
      ...root,
      'command': Platform.isWindows ? 'echo hi' : 'printf hi',
    });
    check.that(
      '${terminal['text']}'.contains('hi'),
      'terminal.exec 能执行并回输出',
    );
  } finally {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  }
  return check.finish();
}