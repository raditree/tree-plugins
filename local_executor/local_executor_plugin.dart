// local_executor —— 本机执行器插件（L-24）。
//
// 核心执行站把 fs.* / terminal.exec 挂到本插件；插件在**租约根目录**内读写、
// 起进程。核心不碰文件、不起进程，也不解析 agent/team/mode 身份。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tree_local_executor/tree_local_executor.dart';

import '../_kit/plugin_kit.dart';
import 'terminal_sessions.dart';

const String kPluginId = 'local_executor';
const String kDisplayName = '本机执行器';
const String kVersion = '0.4.0';
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

/// 终端会话表（REST 建会话、广播站推输出；null = 未接线，自检不建）。
TerminalSessions? _terminals;

/// 终端输出站 id（`station/register` 回包写入；空 = 未注册）。
String _terminalStationId = '';

PluginKitServer buildServer({bool exitOnShutdown = true}) => PluginKitServer(
  channel: PluginChannel.stdio(kPluginId),
  pluginId: kPluginId,
  displayName: kDisplayName,
  onReady: _onReady,
  onRequest: handleRequest,
  onStop: () async => _terminals?.closeAll(),
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
  // L-26：终端输出站（REST 建会话，输出经这里推给订阅方）。
  try {
    final Map<String, dynamic> result = await server.channel.request(
      M.stationRegister,
      <String, dynamic>{
        'kind': 'broadcast',
        'name': kTerminalStationName,
        'description': '本机终端输出（terminal_output / terminal_exit）',
        'readme': kTerminalReadme,
        'shared': true,
      },
    );
    _terminalStationId = (result['station_id'] ?? '').toString();
    server.channel.log(
      '终端输出站：${_terminalStationId.isEmpty ? result['error'] : _terminalStationId}',
    );
  } catch (error) {
    server.channel.log('终端输出站注册失败（终端仍可用，但没有实时输出）：$error');
  }
  _terminals = TerminalSessions(
    log: server.channel.log,
    publish: (String topic, Map<String, dynamic> payload) async {
      if (_terminalStationId.isEmpty) return;
      await server.channel.request(M.stationTrigger, <String, dynamic>{
        'station_id': _terminalStationId,
        'topic': topic,
        'payload': payload,
        'meta': <String, dynamic>{'plugin_id': kPluginId},
        // 本机终端固定 local；UI 订阅是通配，不因此丢帧。
        'scope': <String, dynamic>{'mode_key': 'local'},
      });
    },
  );
}

Future<Map<String, dynamic>?> handleRequest(
  String method,
  Map<String, dynamic> params,
) async {
  if (method == M.apiDelegate) return _delegate(params);
  if (method != M.stationRequest) return null;
  // 核心收集委派路由申报（与工具贡献同一套收集站）。
  if (asString(params['station_id']) == 'system.collect.api.routes') {
    return <String, dynamic>{
      'reply': <String, dynamic>{
        'payload': <String, dynamic>{'routes': kTerminalRoutes},
      },
    };
  }
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

/// `api/delegate`：终端会话的 REST 面（核心只转发，不解释终端语义）。
Future<Map<String, dynamic>> _delegate(Map<String, dynamic> envelope) async {
  final String method = asString(envelope['method']).toUpperCase();
  final String path = asString(envelope['path']);
  final Map<String, dynamic> body = _bodyOf(envelope);
  final TerminalSessions? terminals = _terminals;
  if (terminals == null) {
    return _json(503, <String, dynamic>{'detail': '终端会话未接线（插件未就绪）'});
  }
  try {
    if (method == 'POST' && path == kSessionsPattern) {
      final String id = asString(body['session_id']).trim().isEmpty
          ? 'term_${DateTime.now().microsecondsSinceEpoch}'
          : asString(body['session_id']).trim();
      final Map<String, dynamic> opened = await terminals.open(
        sessionId: id,
        cwd: _resolveCwd(envelope, body),
        shell: asString(body['shell']),
        columns: (body['columns'] as num?)?.toInt() ?? 80,
        rows: (body['rows'] as num?)?.toInt() ?? 24,
      );
      return _json(200, opened);
    }
    final RegExpMatch? match = RegExp(
      r'^/api/terminal/local/sessions/([^/]+)(/input|/cancel|/resize)?$',
    ).firstMatch(path);
    if (match == null) {
      return _json(404, <String, dynamic>{'detail': '未知终端路由：$path'});
    }
    final String id = Uri.decodeComponent(match.group(1)!);
    final String action = match.group(2) ?? '';
    if (method == 'DELETE' && action.isEmpty) {
      await terminals.close(id);
      return _json(200, <String, dynamic>{'ok': true, 'session_id': id});
    }
    if (method != 'POST') {
      return _json(405, <String, dynamic>{'detail': '方法不允许：$method $path'});
    }
    switch (action) {
      case '/input':
        final String text = asString(body['text']);
        final List<int> bytes = text.isNotEmpty
            ? utf8.encode(text)
            : base64Decode(asString(body['bytes']));
        await terminals.input(id, bytes);
        return _json(200, <String, dynamic>{'ok': true});
      case '/cancel':
        await terminals.cancel(id);
        return _json(200, <String, dynamic>{'ok': true});
      case '/resize':
        await terminals.resize(
          id,
          (body['columns'] as num?)?.toInt() ?? 80,
          (body['rows'] as num?)?.toInt() ?? 24,
        );
        return _json(200, <String, dynamic>{'ok': true});
      default:
        return _json(404, <String, dynamic>{'detail': '未知终端动作：$path'});
    }
  } on StateError catch (error) {
    return _json(404, <String, dynamic>{'detail': error.message});
  } catch (error) {
    return _json(500, <String, dynamic>{'detail': '终端会话失败：$error'});
  }
}

/// 终端工作目录：`body.cwd` 优先；其次委派信封的 `workspace_dir`；再次
/// `<data_dir>/workspaces/<agent_id>`（核心默认工作空间口径）；都没有 = 空（插件当前目录）。
String _resolveCwd(
  Map<String, dynamic> envelope,
  Map<String, dynamic> body,
) {
  final String explicit = asString(body['cwd']).trim();
  if (explicit.isNotEmpty) return explicit;
  final String workspace = asString(envelope['workspace_dir']).trim();
  if (workspace.isNotEmpty) return workspace;
  final String dataDir = asString(envelope['data_dir']).trim();
  final String agentId = asString(envelope['agent_id']).trim();
  if (dataDir.isNotEmpty && agentId.isNotEmpty) {
    final String sep = Platform.pathSeparator;
    return '$dataDir${sep}workspaces$sep$agentId';
  }
  return '';
}

Map<String, dynamic> _bodyOf(Map<String, dynamic> envelope) {
  final Object? raw = envelope['body'];
  if (raw is Map) {
    return raw.map(
      (dynamic k, dynamic v) => MapEntry(k.toString(), v),
    );
  }
  if (raw is String && raw.trim().isNotEmpty) {
    final Object? decoded = jsonDecode(raw);
    if (decoded is Map) {
      return decoded.map(
        (dynamic k, dynamic v) => MapEntry(k.toString(), v),
      );
    }
  }
  return <String, dynamic>{};
}

Map<String, dynamic> _json(int status, Map<String, dynamic> body) =>
    <String, dynamic>{
      'status': status,
      'headers': <String, dynamic>{'content-type': 'application/json'},
      'body': jsonEncode(body),
    };

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
    final Map<String, dynamic> soft = await executor.execute('exec.command', <String, dynamic>{
      ...root,
      'command': Platform.isWindows ? 'ping -n 6 127.0.0.1 >nul' : 'sleep 5',
      'timeout_seconds': 1,
    });
    check.that(
      (soft['task_id'] ?? '').toString().isNotEmpty,
      '同步命令软超时转后台',
    );
    await executor.execute('exec.command', <String, dynamic>{
      ...root,
      'hook_action': 'cancel',
      'task_id': (soft['task_id'] ?? '').toString(),
    });

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

    // L-26：终端会话（REST 建会话 / 输入 / resize / cancel / close）+ 广播站推输出。
    final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
    final TerminalSessions terminals = TerminalSessions(
      publish: (String topic, Map<String, dynamic> payload) async {
        frames.add(<String, dynamic>{'topic': topic, ...payload});
      },
    );
    Future<bool> waitFor(bool Function() predicate) async {
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline)) {
        if (predicate()) return true;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return predicate();
    }

    String outputText() => frames
        .where((Map<String, dynamic> f) => f['type'] == 'terminal_output')
        .map(
          (Map<String, dynamic> f) => utf8.decode(
            base64Decode('${f['bytes']}'),
            allowMalformed: true,
          ),
        )
        .join();

    final Map<String, dynamic> opened = await terminals.open(
      sessionId: 'selftest',
      cwd: temp.path,
      shell: Platform.isWindows ? 'cmd.exe' : '/bin/sh',
      columns: 90,
      rows: 30,
    );
    check.check(opened['session_id'], 'selftest', '终端会话已建成');
    check.check(opened['cwd'], temp.path, '终端会话工作目录');
    await terminals.input(
      'selftest',
      utf8.encode(Platform.isWindows ? 'echo hi\r\n' : 'echo hi\n'),
    );
    check.that(
      await waitFor(() => outputText().contains('hi')),
      '终端输出经广播站推送',
    );
    check.that(
      frames.any((Map<String, dynamic> f) => '${f['topic']}' == 'terminal.selftest.output'),
      '输出 topic 为 terminal.<session_id>.output',
    );
    await terminals.resize('selftest', 100, 40);
    check.check(terminals.count, 1, 'resize 后会话仍在');
    await terminals.cancel('selftest');
    await terminals.close('selftest');
    check.check(terminals.count, 0, 'close 后会话被移除');
    check.that(
      await waitFor(
        () => frames.any((Map<String, dynamic> f) => f['type'] == 'terminal_exit'),
      ),
      '进程结束后推送 terminal_exit',
    );
    await terminals.closeAll();
  } finally {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  }
  return check.finish();
}