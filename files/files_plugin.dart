// files —— 文件面板领域插件。
//
// 承接原核心 /api/files/* 的 13 条 REST（经 system.collect.api.routes 申报，
// 由核心转成 api/delegate）。Git 3 条按用户决定删除，本插件不申报。
//
// 本机工作空间：文件插件直接读写（路径安全边界在 lib/src/local_files.dart）；
// SSH 工作空间：经 ssh_executor 自建执行站的 ssh.* 命令（不 import 核心包）。
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tree_files/tree_files.dart';

import '../_kit/plugin_kit.dart';

const String kPluginId = 'files';
const String kDisplayName = '文件与工作空间';
const String kVersion = '0.1.0';

FilesService _service = FilesService(log: _logToStderr);

void _logToStderr(String message) => stderr.writeln('[files] $message');

PluginKitServer buildServer({bool exitOnShutdown = true}) => PluginKitServer(
  channel: PluginChannel.stdio(kPluginId),
  pluginId: kPluginId,
  displayName: kDisplayName,
  onReady: _onReady,
  onRequest: handleRequest,
  onStop: () => _service.close(),
  exitOnShutdown: exitOnShutdown,
);

Future<void> _onReady(PluginKitServer server) async {
  _service = FilesService(log: server.channel.log);
  // SSH 工作空间经执行站命令（ssh.lease.register / ssh.file.*）。
  // 骨架异常 → 领域库自有异常（`lib/` 不能 import 包外的 `../_kit`，契约 §4.3 环 8）。
  _service.stationCommand = (
    String command,
    Map<String, dynamic> arguments,
  ) async {
    try {
      return await server.channel.command(command, arguments);
    } on CmdFailureException catch (error) {
      throw StationCommandFailure(
        error.message,
        code: (error.code.isEmpty ? 'unknown' : error.code),
        payload: <String, dynamic>{
          for (final MapEntry<String, Object?> entry in error.payload.entries)
            entry.key: entry.value,
        },
      );
    }
  };
  server.channel.log(
    '已上线：v$kVersion（文件面板；已申报 ${kDeclaredRoutes.length} 条委派路由）',
  );
}

Future<Map<String, dynamic>?> handleRequest(
  String method,
  Map<String, dynamic> params,
) async {
  if (method == M.apiDelegate) {
    return handleApiDelegate(asMap(params), service: _service);
  }
  if (method == M.stationRequest &&
      asString(params['station_id']) == kApiRoutesStation) {
    // 收集站口径：{reply: {payload: {routes: [...]}}}（核心只读 reply.payload）。
    return <String, dynamic>{
      'reply': <String, dynamic>{
        'payload': <String, dynamic>{'routes': kDeclaredRoutes},
      },
    };
  }
  return null;
}

Future<void> main(List<String> args) async {
  if (args.contains('--selftest')) {
    exitCode = await selfTest();
    return;
  }
  await buildServer().run(stdin);
  await _service.close();
  try {
    await stdout.flush();
  } catch (_) {}
}

/// 假核心自检：路由申报 + 本机文件全链路（列表/读写/结构/上传/下载/打包/同步）。
Future<int> selfTest() async {
  final SelfTest check = SelfTest(name: 'files_plugin');
  final Directory temp = Directory.systemTemp.createTempSync('files_selftest_');
  final Directory workspace = Directory(p.join(temp.path, 'workspace'))
    ..createSync(recursive: true);
  File(p.join(workspace.path, 'hello.txt')).writeAsStringSync('hello');
  File(p.join(workspace.path, 'doc.pdf')).writeAsStringSync(
    '%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R /Count 3 >>\n',
  );
  File(p.join(temp.path, 'agents', 'agt.yaml'))
    ..createSync(recursive: true)
    ..writeAsStringSync(
      'id: agt\n'
      'name: 夹具\n'
      'workspace_id: ws_agt\n'
      'workspace_dir: "${workspace.path.replaceAll('\\', '/')}"\n',
    );
  _service = FilesService(log: _logToStderr);
  final PluginKitServer server = PluginKitServer(
    channel: PluginChannel(logTag: kPluginId),
    pluginId: kPluginId,
    displayName: kDisplayName,
    onReady: (_) async {},
    onRequest: handleRequest,
    exitOnShutdown: false,
  );
  final FakeCore core = FakeCore(server);
  final Future<void> loop = core.start();
  try {
    Map<String, dynamic> envelope(
      String method,
      String path, {
      Map<String, Object?> params = const <String, Object?>{},
      Map<String, Object?> query = const <String, Object?>{},
      Map<String, Object?>? body,
      String? bodyPath,
      String dataDir = '',
    }) => <String, dynamic>{
      'method': method,
      'path': path,
      // 真实核心把路径模板里的 workspaceId 放在 params 里（与 ApiPaths 同形）。
      'params': <String, Object?>{'workspaceId': 'ws_agt', ...params},
      'query': query,
      'headers': <String, dynamic>{},
      'scope': <String, dynamic>{},
      'workspace_dir': '',
      'data_dir': dataDir,
      'agent_id': '',
      'team_id': '',
      'request_id': 'selftest-${method.toLowerCase()}',
      if (body != null) 'body': jsonEncode(body),
      'body_path': ?bodyPath,
    };

    core.ask(0, M.hello, <String, dynamic>{'plugin_id': kPluginId});
    core.ask(1, M.stationRequest, <String, dynamic>{
      'station_id': kApiRoutesStation,
      'payload': <String, dynamic>{},
    });
    core.ask(
      2,
      M.apiDelegate,
      envelope('GET', filesPattern, dataDir: temp.path),
    );
    core.ask(
      3,
      M.apiDelegate,
      envelope(
        'GET',
        fileContentPattern,
        query: <String, Object?>{'path': 'hello.txt'},
        dataDir: temp.path,
      ),
    );
    core.ask(
      4,
      M.apiDelegate,
      envelope(
        'GET',
        filePdfInfoPattern,
        query: <String, Object?>{'path': 'doc.pdf'},
        dataDir: temp.path,
      ),
    );
    core.ask(
      5,
      M.apiDelegate,
      envelope(
        'PUT',
        fileContentPattern,
        query: <String, Object?>{'path': 'hello.txt'},
        body: <String, Object?>{'content': 'updated'},
        dataDir: temp.path,
      ),
    );
    core.ask(
      6,
      M.apiDelegate,
      envelope(
        'GET',
        fileContentPattern,
        query: <String, Object?>{'path': 'hello.txt'},
        dataDir: temp.path,
      ),
    );
    core.ask(
      7,
      M.apiDelegate,
      envelope(
        'POST',
        fileMkdirPattern,
        body: <String, Object?>{'path': 'sub'},
        dataDir: temp.path,
      ),
    );
    core.ask(
      8,
      M.apiDelegate,
      envelope(
        'POST',
        fileRenamePattern,
        body: <String, Object?>{'from': 'hello.txt', 'to': 'sub/hello.txt'},
        dataDir: temp.path,
      ),
    );
    core.ask(
      9,
      M.apiDelegate,
      envelope(
        'GET',
        filesPattern,
        query: <String, Object?>{'path': 'sub'},
        dataDir: temp.path,
      ),
    );
    core.ask(
      10,
      M.apiDelegate,
      envelope(
        'DELETE',
        filesPattern,
        query: <String, Object?>{'path': 'sub/hello.txt'},
        dataDir: temp.path,
      ),
    );
    core.ask(
      11,
      M.apiDelegate,
      envelope(
        'POST',
        fileMkdirPattern,
        body: <String, Object?>{'path': 'sub'},
        dataDir: temp.path,
      ),
    );
    core.ask(
      12,
      M.apiDelegate,
      envelope(
        'DELETE',
        filesPattern,
        query: <String, Object?>{'path': 'ghost.txt'},
        dataDir: temp.path,
      ),
    );
    core.ask(
      13,
      M.apiDelegate,
      envelope(
        'POST',
        fileUploadInitPattern,
        body: <String, Object?>{
          'file_name': 'up.txt',
          'rel_path': '',
          'total_size': 5,
        },
        dataDir: temp.path,
      ),
    );

    final Map<Object?, Map<String, dynamic>> first = await core.waitFor(<int>[
      0,
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
      9,
      10,
      11,
      12,
      13,
    ]);

    Map<String, dynamic> replyOf(
      Object id, [
      Map<Object?, Map<String, dynamic>>? source,
    ]) =>
        ((source ?? first)[id]?['result'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};

    Map<String, dynamic> bodyOf(
      Object id, [
      Map<Object?, Map<String, dynamic>>? source,
    ]) {
      final Object? raw = replyOf(id, source)['body'];
      if (raw is String && raw.trim().isNotEmpty) {
        final Object? decoded = jsonDecode(raw);
        if (decoded is Map) {
          return decoded.map(
            (Object? k, Object? v) => MapEntry(k.toString(), v),
          );
        }
      }
      return <String, dynamic>{};
    }

    // ── 路由申报：13 条 files（不含 Git）────────────────────────────
    final Object? declared =
        ((replyOf(1)['reply'] as Map?)?['payload'] as Map?)?['routes'];
    check.check(declared, kDeclaredRoutes, '路由申报：13 条 files 路由');
    check.check(kDeclaredRoutes.length, 13, '路由申报：条数为 13');
    check.that(
      !kDeclaredRoutes.any(
        (Map<String, String> route) => (route['pattern'] ?? '').contains('git'),
      ),
      '路由申报：不含 Git 路由',
    );

    // ── 列表 / 内容 / PDF ─────────────────────────────────────────
    final Map<String, dynamic> listed = bodyOf(2);
    check.check(replyOf(2)['status'], 200, 'GET 列表：200');
    check.check(listed['total'], 2, 'GET 列表：两个条目');
    final List<dynamic> files =
        listed['files'] as List<dynamic>? ?? <dynamic>[];
    check.that(
      files.any((dynamic e) => (e as Map)['name'] == 'hello.txt'),
      'GET 列表：含 hello.txt',
    );
    check.that(
      files.any((dynamic e) => (e as Map)['type'] == 'file'),
      'GET 列表：type=file',
    );

    final Map<String, dynamic> content = bodyOf(3);
    check.check(content['content'], 'hello', 'GET 内容：原文');
    check.check(content['size'], 5, 'GET 内容：size');
    check.check(content['encoding'], 'utf-8', 'GET 内容：encoding');

    final Map<String, dynamic> pdf = bodyOf(4);
    check.check(pdf['total_pages'], 3, 'PDF 信息：页数');
    check.check(pdf['pages_source'], 'count', 'PDF 信息：页数来源');

    // ── 写文本 / 结构改动 ─────────────────────────────────────────
    final Map<String, dynamic> written = bodyOf(5);
    check.check(replyOf(5)['status'], 200, 'PUT 内容：200');
    check.check(written['success'], true, 'PUT 内容：success');
    check.check(written['size'], 7, 'PUT 内容：写入字节数');
    check.check(bodyOf(6)['content'], 'updated', 'PUT 内容：再读为新内容');

    check.check(replyOf(7)['status'], 200, 'mkdir：200');
    check.check(bodyOf(7)['path'], 'sub', 'mkdir：返回相对路径');
    check.check(replyOf(8)['status'], 200, 'rename：200');
    check.check(bodyOf(8)['to'], 'sub/hello.txt', 'rename：返回目标路径');
    final List<dynamic> subFiles =
        bodyOf(9)['files'] as List<dynamic>? ?? <dynamic>[];
    check.check(subFiles.length, 1, 'rename 后列 dir：一条');
    check.check(replyOf(10)['status'], 200, 'DELETE：200');

    check.check(replyOf(11)['status'], 409, 'mkdir 已存在：409');
    check.check(bodyOf(11)['error'], 'already_exists', 'mkdir 已存在：error 码');
    check.check(replyOf(12)['status'], 404, 'DELETE 不存在：404');
    check.check(bodyOf(12)['error'], 'not_found', 'DELETE 不存在：error 码');

    final Map<String, dynamic> init = bodyOf(13);
    check.check(replyOf(13)['status'], 200, 'upload_init：200');
    check.check(init['chunk_size'], 4 * 1024 * 1024, 'upload_init：分片大小');
    final String uploadId = (init['upload_id'] ?? '').toString();
    final String uploadedPath = (init['path'] ?? '').toString();
    check.that(uploadId.isNotEmpty, 'upload_init：upload_id 非空');
    check.that(
      uploadedPath.startsWith('.input/'),
      'upload_init：落点 .input/',
      actual: uploadedPath,
    );

    // ── 第二批：分片 / 完成 / 回读 / 同步 / 打包 / 下载 ───────────
    final File chunkBody = File(p.join(temp.path, 'chunk.json'))
      ..writeAsStringSync(
        jsonEncode(<String, Object?>{
          'upload_id': uploadId,
          'index': 0,
          'data': base64Encode(utf8.encode('hello')),
        }),
      );
    core.ask(
      14,
      M.apiDelegate,
      envelope(
        'POST',
        fileUploadChunkPattern,
        bodyPath: chunkBody.path,
        dataDir: temp.path,
      ),
    );
    core.ask(
      15,
      M.apiDelegate,
      envelope(
        'POST',
        fileUploadCompletePattern,
        body: <String, Object?>{'upload_id': uploadId, 'total_chunks': 1},
        dataDir: temp.path,
      ),
    );
    core.ask(
      16,
      M.apiDelegate,
      envelope(
        'GET',
        fileContentPattern,
        query: <String, Object?>{'path': uploadedPath},
        dataDir: temp.path,
      ),
    );
    final Directory syncTarget = Directory(p.join(temp.path, 'synced'));
    core.ask(
      17,
      M.apiDelegate,
      envelope(
        'POST',
        fileSyncToLocalPattern,
        body: <String, Object?>{'local_path': syncTarget.path, 'path': ''},
        dataDir: temp.path,
      ),
    );
    core.ask(
      18,
      M.apiDelegate,
      envelope(
        'POST',
        fileDownloadFolderPattern,
        body: <String, Object?>{'path': ''},
        dataDir: temp.path,
      ),
    );
    core.ask(
      19,
      M.apiDelegate,
      envelope(
        'POST',
        fileDownloadPattern,
        body: <String, Object?>{'path': uploadedPath},
        dataDir: temp.path,
      ),
    );

    final Map<Object?, Map<String, dynamic>> second = await core.waitFor(<int>[
      14,
      15,
      16,
      17,
      18,
      19,
    ]);

    final Map<String, dynamic> chunk = bodyOf(14, second);
    check.check(
      replyOf(14, second)['status'],
      200,
      'upload_chunk（body_path）：200',
    );
    check.check(chunk['received_bytes'], 5, 'upload_chunk：累计字节数');

    final Map<String, dynamic> complete = bodyOf(15, second);
    check.check(replyOf(15, second)['status'], 200, 'upload_complete：200');
    check.check(complete['success'], true, 'upload_complete：success');
    check.check(complete['path'], uploadedPath, 'upload_complete：返回落点');
    check.check(bodyOf(16, second)['content'], 'hello', '上传后回读内容');

    final Map<String, dynamic> synced = bodyOf(17, second);
    check.check(replyOf(17, second)['status'], 200, 'syncToLocal：200');
    check.check(synced['success'], true, 'syncToLocal：success');
    check.that(
      File(p.joinAll(<String>[syncTarget.path, ...p.posix.split(uploadedPath)]))
          .existsSync(),
      'syncToLocal：目标目录里有上传文件',
    );

    final Map<String, dynamic> folder = replyOf(18, second);
    final String folderPath = (folder['result_path'] ?? '').toString();
    check.check(folder['status'], 200, 'download_folder：200');
    check.that(folderPath.isNotEmpty, 'download_folder：result_path 非空');
    check.that(
      folderPath.isNotEmpty &&
          File(folderPath).existsSync() &&
          File(folderPath).readAsBytesSync().length > 2 &&
          File(folderPath).readAsBytesSync()[0] == 0x1f &&
          File(folderPath).readAsBytesSync()[1] == 0x8b,
      'download_folder：产物是 gzip 流',
    );

    final Map<String, dynamic> download = replyOf(19, second);
    final String downloadPath = (download['result_path'] ?? '').toString();
    check.check(download['status'], 200, 'download：200');
    check.check(
      downloadPath.isNotEmpty && File(downloadPath).existsSync()
          ? utf8.decode(File(downloadPath).readAsBytesSync())
          : '',
      'hello',
      'download：字节内容',
    );
  } finally {
    await core.close();
    await loop.timeout(const Duration(seconds: 2), onTimeout: () {});
    await _service.close();
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  }
  return check.finish(core.logs);
}
