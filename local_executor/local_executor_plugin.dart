// local_executor —— 本机执行器插件（L-24）。
//
// 命令族 `local.file.*` / `local.exec.command` **由本插件自建执行站申报**（A5 起
// 核心不再持有这些名字，也不认识"本机/远端"这对概念）。租约由 `local.lease.register`
// 在本插件进程内登记：**root 只有一个来源 = 自己那张租约表**，插件在租约根目录内
// 读写、起进程；核心不碰文件、不起进程，也不解析 agent/team/mode 身份。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tree_local_executor/tree_local_executor.dart';

import '../_kit/plugin_kit.dart';
import 'terminal_sessions.dart';

const String kPluginId = 'local_executor';
const String kDisplayName = '本机执行器';
const String kVersion = '0.5.0';
final LocalExecutor _executor = LocalExecutor();

/// 自建执行站：插件内部定义命令，核心只登记与路由（与 `ssh_executor` 逐字对称）。
const List<String> kExecutorCommands = kLocalWorkspaceCommands;

const String kStationReadme =
    '本机执行器自建执行站：接 local.file.* / local.exec.command（与 ssh_executor 的 '
    'ssh.* 同后缀，只换限定词）。调用方先 local.lease.register 登记本机绝对目录 '
    '（记下登记方插件 id），之后每条命令带 local_lease_id + 工作空间内相对路径；'
    'root 只从这张租约表里查，arguments 里自带的 root / workspace_root 一律忽略，'
    '登记方与调用方不是同一个插件直接拒（lease_denied）。核心只路由，不碰文件、不起进程。';

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
        'name': kLocalWorkspaceStationName,
        'description': '本机执行器（local.file.* / local.exec.command）',
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
  // 登记方比对的身份来源：核心 `_forwardStationCommand` 在 meta 里带上发起方插件 id。
  final String sourcePluginId = asString(asMap(params['meta'])['source_plugin_id']);
  try {
    final Map<String, dynamic> result = await _executor.execute(
      command,
      arguments,
      sourcePluginId: sourcePluginId,
    );
    return <String, dynamic>{
      'reply': <String, dynamic>{'payload': result},
    };
  } catch (error) {
    return <String, dynamic>{
      'reply': <String, dynamic>{'error': error.toString(), 'code': 'unknown'},
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
    // 会话「已存在 / 不存在」是资源状态冲突 ⇒ 409（与 ssh 侧同形）。404 在这套不变量里
    // 专指「插件没装 / 没有这条路由」，兼作资源冲突就让 UI 分不清该重连还是该换 id。
    return _json(409, <String, dynamic>{'detail': error.message});
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
    const String owner = 'tree.agent';
    const String intruder = 'demo_intruder';

    // 租约：root 的唯一来源。id / 绝对根都要回给调用方（调用方只认这个句柄）。
    final Map<String, dynamic> lease = await executor.execute(
      kLocalLeaseRegisterCommand,
      <String, dynamic>{'dir': temp.path, 'local_lease_id': 'selftest'},
      sourcePluginId: owner,
    );
    check.check(lease['lease_id'], 'selftest', 'local.lease.register 回租约 id');
    check.check(lease['root'], temp.path, 'local.lease.register 回绝对根');
    check.check(executor.leaseCount, 1, '登记后租约表里有 1 条');

    Future<Map<String, dynamic>> run(
      String command, [
      Map<String, dynamic> args = const <String, dynamic>{},
    ]) => executor.execute(
      command,
      <String, dynamic>{'local_lease_id': 'selftest', ...args},
      sourcePluginId: owner,
    );
    // 失败路径：返回异常本体（自检按 `error.code` 断言，不靠"抛没抛"猜）。
    Future<ExecutorError?> why(
      String command, [
      Map<String, dynamic> args = const <String, dynamic>{},
      String as = owner,
    ]) async {
      try {
        await executor.execute(
          command,
          <String, dynamic>{'local_lease_id': 'selftest', ...args},
          sourcePluginId: as,
        );
        return null;
      } on ExecutorError catch (error) {
        return error;
      }
    }

    final Map<String, dynamic> written = await run(
      'local.file.write',
      <String, dynamic>{'path': 'notes/a.txt', 'content': 'hello\nworld\n'},
    );
    check.check(written['bytes_written'], 12, 'local.file.write 返回字节数');

    final Map<String, dynamic> read = await run(
      'local.file.read',
      <String, dynamic>{'path': 'notes/a.txt'},
    );
    check.check(read['content'], 'hello\nworld\n', 'local.file.read 读回内容');
    check.check(read['total_lines'], 3, 'local.file.read 总行数');

    final Map<String, dynamic> listed = await run(
      'local.file.list',
      <String, dynamic>{'path': '.', 'max_depth': 3},
    );
    check.that(
      (listed['entries'] as List<dynamic>).contains('notes/a.txt'),
      'local.file.list 能看到写入的文件',
    );
    // `details` 与 `entries` 同序同数（契约 §8.2：两侧键集必须相同，文件面板要 size）。
    final List<dynamic> details = listed['details'] as List<dynamic>;
    check.check(
      details.length,
      (listed['entries'] as List<dynamic>).length,
      'local.file.list 的 details 与 entries 同数',
    );
    final Map<String, dynamic> detailOf = details
        .cast<Map<String, dynamic>>()
        .firstWhere(
          (Map<String, dynamic> d) => d['name'] == 'notes/a.txt',
        );
    check.check(detailOf['type'], 'file', 'details 里有条目类型');
    check.check(detailOf['size'], 12, 'details 里有 size');
    check.that(
      (detailOf['mtime_ms'] as num).toInt() > 0,
      'details 里有 mtime_ms',
    );

    final Map<String, dynamic> grep = await run(
      'local.file.grep',
      <String, dynamic>{'pattern': 'world'},
    );
    check.check(grep['count'], 1, 'local.file.grep 命中一行');

    check.that(
      (await why('local.file.write', <String, dynamic>{
            'path': '../outside.txt',
            'content': 'x',
          }))
          ?.message
          .contains('越出工作空间根目录') ??
          false,
      '越界路径被拒绝',
    );
    // 注入 root 的**可证伪**测试：`notes/a.txt` 在租约根里有、在 systemTemp 里
    // 没有——插件若听信 arguments 里的 root，这条必然报「文件不存在」。
    final Map<String, dynamic> ignoresRootArg = await run(
      'local.file.read',
      <String, dynamic>{
        'path': 'notes/a.txt',
        'root': Directory.systemTemp.path,
      },
    );
    check.check(
      ignoresRootArg['content'],
      'hello\nworld\n',
      'arguments 里的 root 被忽略（root 只来自租约表）',
    );

    // 租约的两道 fail-closed：未登记（可重登记重试）与归属不符（绝不重试）。
    check.that(
      (await why(
            'local.file.read',
            <String, dynamic>{'path': 'notes/a.txt'},
            intruder,
          ))
              ?.code ==
          kLeaseDeniedCode,
      '别人的租约直接被拒（lease_denied）',
    );
    check.that(
      (await why(
            kLocalLeaseRegisterCommand,
            <String, dynamic>{'dir': temp.path, 'local_lease_id': 'selftest'},
            intruder,
          ))
              ?.code ==
          kLeaseDeniedCode,
      '顶不掉别人登记的租约（lease_denied）',
    );
    var unknownSeen = false;
    try {
      await executor.execute(
        'local.file.read',
        <String, dynamic>{'local_lease_id': 'never_registered'},
        sourcePluginId: owner,
      );
    } on ExecutorError catch (error) {
      unknownSeen = error.code == kLeaseUnknownCode;
    }
    check.that(unknownSeen, '未登记的租约回 lease_unknown 码');
    check.that(
      (await why('local.file.read', <String, dynamic>{
            'local_lease_id': '',
            'path': 'notes/a.txt',
          }))
          ?.message
          .contains('local_lease_id') ??
          false,
      '没带租约句柄显式失败（不回落当前目录）',
    );

    final Map<String, dynamic> made = await run(
      'local.file.mkdir',
      <String, dynamic>{'path': 'bin'},
    );
    check.check(made['created'], true, 'local.file.mkdir 创建目录');

    final Map<String, dynamic> bytes = await run(
      'local.file.writeBytes',
      <String, dynamic>{'path': 'bin/a.bin', 'base64': 'AQID'},
    );
    check.check(bytes['bytes_written'], 3, 'local.file.writeBytes 写入二进制');
    check.check(bytes['appended'], false, 'writeBytes 默认整写（appended=false）');
    final Map<String, dynamic> appended = await run(
      'local.file.writeBytes',
      <String, dynamic>{'path': 'bin/a.bin', 'base64': 'BA==', 'append': true},
    );
    check.check(appended['appended'], true, 'writeBytes 可追加');
    check.check(
      File('${temp.path}/bin/a.bin').readAsBytesSync(),
      <int>[1, 2, 3, 4],
      'append 把块续到文件尾',
    );

    // raw 分块通道：不做行处理、按 offset 递进、按 eof 收口。
    final Map<String, dynamic> raw = await run(
      'local.file.read',
      <String, dynamic>{'path': 'bin/a.bin', 'raw': true, 'offset': 1, 'length': 2},
    );
    check.check(
      base64Decode('${raw['base64']}'),
      <int>[2, 3],
      'raw 读回指定区间的字节',
    );
    check.check(raw['offset'], 1, 'raw 回显 offset');
    check.check(raw['size'], 4, 'raw 回文件总长');
    check.check(raw['eof'], false, 'raw 没读到尾部时 eof=false（调用方据此续读）');
    final Map<String, dynamic> rawTail = await run(
      'local.file.read',
      <String, dynamic>{'path': 'bin/a.bin', 'raw': true, 'offset': 3, 'length': 99},
    );
    check.check(base64Decode('${rawTail['base64']}'), <int>[4], 'raw 尾块只回剩下的字节');
    check.check(rawTail['eof'], true, 'raw 读到文件尾时 eof=true');

    final Map<String, dynamic> renamed = await run(
      'local.file.rename',
      <String, dynamic>{'from': 'bin/a.bin', 'to': 'bin/b.bin'},
    );
    check.check(renamed['to'], 'bin/b.bin', 'local.file.rename 回目标路径');
    check.that(
      File('${temp.path}/bin/b.bin').existsSync(),
      'rename 后新名存在',
    );
    check.that(
      !File('${temp.path}/bin/a.bin').existsSync(),
      'rename 后旧名消失',
    );
    check.that(
      (await why('local.file.rename', <String, dynamic>{
            'from': 'notes/a.txt',
            'to': 'bin/b.bin',
          }))
              ?.code ==
          LocalCodes.targetExists,
      'rename 不覆盖已存在的目标',
    );
    check.that(
      (await why('local.file.rename', <String, dynamic>{
            'from': 'notes/missing.txt',
            'to': 'bin/c.bin',
          }))
              ?.code ==
          LocalCodes.fileNotFound,
      'rename 源不存在显式报错',
    );

    final Map<String, dynamic> deleted = await run(
      'local.file.delete',
      <String, dynamic>{'path': 'bin/b.bin'},
    );
    check.check(deleted['deleted'], true, 'local.file.delete 删除文件');
    check.that(
      !File('${temp.path}/bin/b.bin').existsSync(),
      '删除后文件不存在',
    );

    final Map<String, dynamic> terminal = await run(
      'local.exec.command',
      <String, dynamic>{
        'command': Platform.isWindows ? 'echo hi' : 'printf hi',
      },
    );
    check.that(
      '${terminal['text']}'.contains('hi'),
      'local.exec.command 能执行并回输出',
    );

    final Map<String, dynamic> hook = await run(
      'local.exec.command',
      <String, dynamic>{
        'command': Platform.isWindows ? 'ping -n 5 127.0.0.1 >nul' : 'sleep 3',
        'hook': true,
      },
    );
    final String taskId = (hook['task_id'] ?? '').toString();
    check.that(taskId.isNotEmpty, 'terminal hook 后台启动返回 task_id');
    final Map<String, dynamic> status = await run(
      'local.exec.command',
      <String, dynamic>{'hook_action': 'status', 'task_id': taskId},
    );
    check.that(
      '${status['text']}'.contains('运行中') ||
          '${status['text']}'.contains('已结束'),
      'terminal hook 可查询状态',
    );
    final Map<String, dynamic> soft = await run(
      'local.exec.command',
      <String, dynamic>{
        'command': Platform.isWindows ? 'ping -n 6 127.0.0.1 >nul' : 'sleep 5',
        'timeout_seconds': 1,
      },
    );
    check.that(
      (soft['task_id'] ?? '').toString().isNotEmpty,
      '同步命令软超时转后台',
    );
    await run(
      'local.exec.command',
      <String, dynamic>{
        'hook_action': 'cancel',
        'task_id': (soft['task_id'] ?? '').toString(),
      },
    );

    final Map<String, dynamic> cancelled = await run(
      'local.exec.command',
      <String, dynamic>{'hook_action': 'cancel', 'task_id': taskId},
    );
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