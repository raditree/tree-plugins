import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'errors.dart';
import 'local_files.dart';
import 'remote_files.dart';
import 'routes.dart';
import 'workspace.dart';

/// 一次分片上传会话（进程内内存态；重启即失效）。
class _UploadSession {
  _UploadSession({
    required this.uploadId,
    required this.target,
    required this.relativePath,
    required this.stagingPath,
    required this.sink,
    required this.totalSize,
  });

  final String uploadId;
  final WorkspaceTarget target;
  final String relativePath;
  final String stagingPath;
  final RandomAccessFile sink;
  final int totalSize;
  int received = 0;
  int nextIndex = 0;
  DateTime touchedAt = DateTime.now();

  bool get remote => target.isRemote;
}

/// /api/files/* 的领域实现：信封 → 路由 → 本机/SSH 后端 → 委派回包。
///
/// 回包形状与核心旧 FileService + 路由层逐字对齐：
/// - 读路径成功 200 JSON；失败 ${detail}$；
/// - 写路径（PUT content / mkdir / rename / DELETE）失败 ${error, detail, size?}$；
/// - 下载/打包成功用 $result_path$（核心流式写回并清理），失败仍是 JSON。
class FilesService {
  FilesService({this.log});

  final void Function(String message)? log;

  /// 执行站命令出口（生产在 onReady 接上；SSH 工作空间需要）。
  StationCommandCaller? stationCommand;

  final Map<String, _UploadSession> _uploads = <String, _UploadSession>{};
  final Map<String, SshLease> _leases = <String, SshLease>{};
  String _dataDir = '';
  int _tempSeq = 0;

  static const int chunkSize = 4 * 1024 * 1024;
  static const Duration uploadTimeout = Duration(minutes: 30);

  /// 处理一次 $api/delegate$。
  ///
  /// 读循环对每条请求各起一个异步任务，配置/文件操作可能并发；这里按**到达
  /// 顺序**串行（与 mcp 插件同口径），保证「先 mkdir 后 rename」「先 chunk 后
  /// complete」这类依赖顺序不被执行顺序打乱。
  Future<Map<String, dynamic>> handleDelegate(Map<String, dynamic> envelope) {
    final Completer<Map<String, dynamic>> completer =
        Completer<Map<String, dynamic>>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await _guarded(envelope));
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<void> _queue = Future<void>.value();

  Future<Map<String, dynamic>> _guarded(Map<String, dynamic> envelope) async {
    try {
      return await _dispatch(envelope);
    } on FileRouteError catch (error) {
      return _errorReply(error, _writeShaped(envelope));
    } catch (error) {
      return _jsonReply(500, <String, dynamic>{
        'detail': 'files 插件内部错误：$error',
      });
    }
  }

  Future<void> close() async {
    for (final _UploadSession session in _uploads.values.toList()) {
      await _discard(session);
    }
    _uploads.clear();
  }

  Future<Map<String, dynamic>> _dispatch(Map<String, dynamic> envelope) async {
    final String method = _str(envelope['method']).toUpperCase();
    final String path = _str(envelope['path']);
    final String dataDir = _str(envelope['data_dir']);
    if (dataDir.isEmpty) {
      return _jsonReply(500, <String, dynamic>{
        'detail': '委派信封缺少 data_dir（核心契约不完整）',
      });
    }
    _dataDir = dataDir;
    final Map<String, dynamic> params = _map(envelope['params']);
    final Map<String, dynamic> query = _map(envelope['query']);
    final String workspaceId = _str(params['workspaceId']);
    final WorkspaceResolver resolver = WorkspaceResolver(dataDir, log: log);
    final WorkspaceTarget target = resolver.resolve(workspaceId);
    final bool remote = target.isRemote;
    final LocalFiles local = LocalFiles(target.root, log: log);
    final RemoteFiles? remoteFiles = remote
        ? RemoteFiles(
            target: target,
            call: stationCommand ?? _noStation,
            leases: _leases,
            log: log,
          )
        : null;

    // ── 列表 / 删除（同一条路径）────────────────────────────────────
    if (method == 'GET' && _matches(filesPattern, path)) {
      final Map<String, dynamic> result = remote
          ? await remoteFiles!.list(_queryString(query, 'path'))
          : await local.list(_queryString(query, 'path'));
      return _jsonReply(200, result);
    }
    if (method == 'DELETE' && _matches(filesPattern, path)) {
      final String filePath = _queryString(query, 'path');
      final bool recursive = _truthy(_queryString(query, 'recursive'));
      final Map<String, dynamic> result = remote
          ? await remoteFiles!.remove(filePath, recursive: recursive)
          : await local.remove(filePath, recursive: recursive);
      return _jsonReply(200, result);
    }

    // ── 内容读 / 写 ────────────────────────────────────────────────
    if (method == 'GET' && _matches(fileContentPattern, path)) {
      final Map<String, dynamic> result = remote
          ? await remoteFiles!.content(_queryString(query, 'path'))
          : await local.content(_queryString(query, 'path'));
      return _jsonReply(200, result);
    }
    if (method == 'PUT' && _matches(fileContentPattern, path)) {
      final Map<String, dynamic> body = await _bodyOf(envelope);
      final Object? content = body['content'];
      if (content is! String) {
        throw const FileRouteError(
          400,
          'invalid_body',
          '请求体缺少 content 字段（必须是完整文本）',
        );
      }
      final Map<String, dynamic> result = remote
          ? await remoteFiles!.writeContent(
              _queryString(query, 'path'),
              content: content,
              ifSize: _optionalInt(body, 'if_size'),
              force: _truthy(_queryString(query, 'force')),
            )
          : await local.writeContent(
              _queryString(query, 'path'),
              content: content,
              ifSize: _optionalInt(body, 'if_size'),
              force: _truthy(_queryString(query, 'force')),
            );
      return _jsonReply(200, result);
    }

    // ── PDF 信息 ────────────────────────────────────────────────────
    if (method == 'GET' && _matches(filePdfInfoPattern, path)) {
      final Map<String, dynamic> result = remote
          ? await remoteFiles!.pdfInfo(_queryString(query, 'path'))
          : await local.pdfInfo(_queryString(query, 'path'));
      return _jsonReply(200, result);
    }

    // ── 分片上传 ────────────────────────────────────────────────────
    if (method == 'POST' && _matches(fileUploadInitPattern, path)) {
      final Map<String, dynamic> body = await _bodyOf(envelope);
      final Map<String, dynamic> result = await _uploadInit(
        target,
        fileName: _str(body['file_name']),
        relPath: _str(body['rel_path']),
        totalSize: _intOf(body['total_size']),
      );
      return _jsonReply(200, result);
    }
    if (method == 'POST' && _matches(fileUploadChunkPattern, path)) {
      final Map<String, dynamic> body = await _bodyOf(envelope);
      final Map<String, dynamic> result = await _uploadChunk(
        target,
        uploadId: _str(body['upload_id']),
        index: _intOf(body['index']),
        data: _str(body['data']),
      );
      return _jsonReply(200, result);
    }
    if (method == 'POST' && _matches(fileUploadCompletePattern, path)) {
      final Map<String, dynamic> body = await _bodyOf(envelope);
      final Map<String, dynamic> result = await _uploadComplete(
        target,
        uploadId: _str(body['upload_id']),
        totalChunks: body.containsKey('total_chunks')
            ? _intOf(body['total_chunks'])
            : null,
      );
      return _jsonReply(200, result);
    }

    // ── 同步到本地 / 下载 ──────────────────────────────────────────
    if (method == 'POST' && _matches(fileSyncToLocalPattern, path)) {
      final Map<String, dynamic> body = await _bodyOf(envelope);
      final Map<String, dynamic> result = remote
          ? await remoteFiles!.syncToLocal(
              _str(body['local_path']),
              path: _str(body['path']),
            )
          : await local.syncToLocal(
              _str(body['local_path']),
              path: _str(body['path']),
            );
      return _jsonReply(200, result);
    }
    if (method == 'POST' && _matches(fileDownloadPattern, path)) {
      final Map<String, dynamic> body = await _bodyOf(envelope);
      final String filePath = _str(body['path']);
      final String output = _tempFile('.bin');
      if (remote) {
        await remoteFiles!.download(filePath, output);
      } else {
        final String absolute = local.resolve(filePath);
        final File file = File(absolute);
        if (!file.existsSync()) {
          throw FileRouteError.read('文件不存在：$filePath');
        }
        await file.copy(output);
      }
      return _fileReply(output, p.posix.basename(filePath));
    }
    if (method == 'POST' && _matches(fileDownloadFolderPattern, path)) {
      final Map<String, dynamic> body = await _bodyOf(envelope);
      final String folderPath = _str(body['path']);
      final String output = _tempFile('.tar.gz');
      final Map<String, dynamic> result = remote
          ? await remoteFiles!.archive(folderPath, output)
          : await local.archive(folderPath, output);
      return _fileReply(output, _str(result['name']));
    }

    // ── 结构改动 ────────────────────────────────────────────────────
    if (method == 'POST' && _matches(fileMkdirPattern, path)) {
      final Map<String, dynamic> body = await _bodyOf(envelope);
      final String mkdirPath = _str(body['path']);
      final Map<String, dynamic> result = remote
          ? await remoteFiles!.mkdir(mkdirPath)
          : await local.mkdir(mkdirPath);
      return _jsonReply(200, result);
    }
    if (method == 'POST' && _matches(fileRenamePattern, path)) {
      final Map<String, dynamic> body = await _bodyOf(envelope);
      final String from = _str(body['from']);
      final String to = _str(body['to']);
      final Map<String, dynamic> result = remote
          ? await remoteFiles!.rename(from, to)
          : await local.rename(from, to);
      return _jsonReply(200, result);
    }

    return _jsonReply(501, <String, dynamic>{
      'detail': 'files 插件尚未实现该路由：$method $path',
    });
  }

  Future<Map<String, dynamic>> _noStation(
    String command,
    Map<String, dynamic> arguments,
  ) async {
    throw FileRouteError.read(
      'SSH 工作空间需要 ssh_executor 执行站，但 files 插件未接线 station/command'
      '（command=$command）',
      503,
    );
  }

  // ── 分片上传（本机/远端共用会话；只有 complete 的落盘方式不同）──────

  Future<Map<String, dynamic>> _uploadInit(
    WorkspaceTarget target, {
    required String fileName,
    required String relPath,
    required int totalSize,
  }) async {
    if (totalSize < 0) {
      throw FileRouteError.read('total_size 不能为负', 400);
    }
    final String? name = _safeSegment(fileName);
    if (name == null) {
      throw FileRouteError.read('file_name 非法：$fileName', 400);
    }
    final String? sub = _safeSubPath(relPath);
    if (sub == null) {
      throw FileRouteError.read('rel_path 非法：$relPath', 400);
    }
    final String relative = sub.isEmpty ? name : '$sub/$name';
    final String targetPath = '.input/${_dateStamp()}/$relative';
    if (target.isRemote) {
      final RemoteFiles remote = RemoteFiles(
        target: target,
        call: stationCommand ?? _noStation,
        leases: _leases,
        log: log,
      );
      await remote.lease();
    } else {
      // 提前过一遍路径边界：等 complete 才失败会让用户白传整份文件。
      LocalFiles(target.root, log: log).resolve(targetPath);
    }
    await _pruneUploads();
    final String uploadId = _newUploadId();
    final Directory staging = Directory(
      p.join(_dataDir, 'plugin-data', 'files', 'uploads', uploadId),
    );
    await staging.create(recursive: true);
    final RandomAccessFile sink = await File(p.join(staging.path, 'part.bin'))
        .open(mode: FileMode.write);
    _uploads[uploadId] = _UploadSession(
      uploadId: uploadId,
      target: target,
      relativePath: targetPath,
      stagingPath: staging.path,
      sink: sink,
      totalSize: totalSize,
    );
    log?.call('分片上传开始：$uploadId → $targetPath（$totalSize 字节）');
    return <String, dynamic>{
      'upload_id': uploadId,
      'chunk_size': chunkSize,
      'path': targetPath,
    };
  }

  Future<Map<String, dynamic>> _uploadChunk(
    WorkspaceTarget target, {
    required String uploadId,
    required int index,
    required String data,
  }) async {
    final _UploadSession? session = _uploads[uploadId];
    if (session == null || session.target.workspaceId != target.workspaceId) {
      throw FileRouteError.read('分片会话不存在或已过期', 404);
    }
    if (index < 0) throw FileRouteError.read('index 不能为负', 400);
    if (index != session.nextIndex) {
      throw FileRouteError.read(
        '分片顺序错误：期望 ${session.nextIndex}，收到 $index',
        400,
      );
    }
    final List<int> bytes;
    try {
      bytes = base64Decode(data);
    } on FormatException catch (error) {
      throw FileRouteError.read('data 不是合法 base64：${error.message}', 400);
    }
    if (session.received + bytes.length > session.totalSize) {
      throw FileRouteError.read('分片超过声明的总大小 ${session.totalSize} 字节', 400);
    }
    try {
      await session.sink.writeFrom(bytes);
    } catch (error) {
      await _discard(session);
      _uploads.remove(uploadId);
      throw FileRouteError.read('写入分片失败：$error', 500);
    }
    session.received += bytes.length;
    session.nextIndex++;
    session.touchedAt = DateTime.now();
    return <String, dynamic>{
      'received': true,
      'index': index,
      'received_bytes': session.received,
      'total_size': session.totalSize,
    };
  }

  Future<Map<String, dynamic>> _uploadComplete(
    WorkspaceTarget target, {
    required String uploadId,
    int? totalChunks,
  }) async {
    final _UploadSession? session = _uploads[uploadId];
    if (session == null || session.target.workspaceId != target.workspaceId) {
      throw FileRouteError.read('分片会话不存在或已过期', 404);
    }
    if (totalChunks != null && totalChunks != session.nextIndex) {
      throw FileRouteError.read(
        '分片不完整：已收到 ${session.nextIndex} 个，声明 $totalChunks 个',
        400,
      );
    }
    if (session.received != session.totalSize) {
      throw FileRouteError.read(
        '分片不完整：已收到 ${session.received}/${session.totalSize} 字节',
        400,
      );
    }
    try {
      await session.sink.close();
    } catch (error) {
      await _discard(session);
      _uploads.remove(uploadId);
      throw FileRouteError.read('关闭分片文件失败：$error', 500);
    }
    _uploads.remove(uploadId);
    final File staged = File(p.join(session.stagingPath, 'part.bin'));
    try {
      if (session.remote) {
        final List<int> bytes = await staged.readAsBytes();
        final RemoteFiles remote = RemoteFiles(
          target: session.target,
          call: stationCommand ?? _noStation,
          leases: _leases,
          log: log,
        );
        await remote.uploadComplete(session.relativePath, bytes);
      } else {
        final LocalFiles local = LocalFiles(session.target.root, log: log);
        final String absolute = local.resolve(session.relativePath);
        final File destination = File(absolute);
        await destination.parent.create(recursive: true);
        try {
          await staged.rename(destination.path);
        } on FileSystemException {
          await staged.copy(destination.path);
        }
      }
    } catch (error) {
      await _discard(session);
      if (error is FileRouteError) rethrow;
      throw FileRouteError.read('保存文件失败：$error', 500);
    }
    await _discardDirectory(session.stagingPath);
    log?.call('分片上传完成：${session.relativePath}（${session.received} 字节）');
    return <String, dynamic>{
      'success': true,
      'path': session.relativePath,
      'size': session.received,
    };
  }

  Future<void> _pruneUploads() async {
    final DateTime now = DateTime.now();
    for (final _UploadSession session in _uploads.values.toList()) {
      if (now.difference(session.touchedAt) <= uploadTimeout) continue;
      _uploads.remove(session.uploadId);
      log?.call('分片上传超时作废：${session.uploadId}');
      await _discard(session);
    }
  }

  Future<void> _discard(_UploadSession session) async {
    try {
      await session.sink.close();
    } catch (_) {}
    await _discardDirectory(session.stagingPath);
  }

  static Future<void> _discardDirectory(String path) async {
    try {
      final Directory dir = Directory(path);
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  // ── 信封 / 响应工具 ──────────────────────────────────────────────

  Future<Map<String, dynamic>> _bodyOf(Map<String, dynamic> envelope) async {
    final Object? raw = envelope['body'];
    if (raw is Map) return _map(raw);
    if (raw is String && raw.trim().isNotEmpty) {
      return _decodeBody(raw);
    }
    final String bodyPath = _str(envelope['body_path']);
    if (bodyPath.isNotEmpty) {
      try {
        final String text = utf8.decode(
          await File(bodyPath).readAsBytes(),
          allowMalformed: true,
        );
        return _decodeBody(text);
      } catch (error) {
        throw FileRouteError.read('读取委派请求体失败：$error', 400);
      }
    }
    return <String, dynamic>{};
  }

  static Map<String, dynamic> _decodeBody(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      throw FileRouteError.read('请求体不是合法 JSON：${error.message}', 400);
    }
    if (decoded is Map) return _map(decoded);
    throw const FileRouteError(400, 'invalid_body', '请求体不是 JSON 对象');
  }

  Map<String, dynamic> _jsonReply(int status, Map<String, dynamic> body) =>
      <String, dynamic>{
        'status': status,
        'headers': <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
        'body': jsonEncode(body),
      };

  Map<String, dynamic> _fileReply(String tempPath, String fileName) =>
      <String, dynamic>{
        'status': 200,
        'headers': <String, String>{
          'content-type': 'application/octet-stream',
          'content-disposition': _contentDisposition(fileName),
        },
        'result_path': tempPath,
      };

  /// 与核心旧 writeBytes/writeStream 同口径：ASCII 回退名 + RFC 5987
  /// `filename*`（中文文件名直接塞 HTTP 头会被 dart:io 拒绝）。
  static String _contentDisposition(String fileName) {
    final String ascii = fileName
        .replaceAll(RegExp(r'[^\x20-\x7e]'), '_')
        .replaceAll(RegExp(r'["\\]'), '_');
    return 'attachment; filename="$ascii"; '
        "filename*=UTF-8''${Uri.encodeComponent(fileName)}";
  }

  Map<String, dynamic> _errorReply(FileRouteError error, bool writeShape) {
    final Map<String, dynamic> body = writeShape
        ? <String, dynamic>{
            'error': error.code,
            'detail': error.message,
            if (error.size != null) 'size': error.size,
          }
        : <String, dynamic>{'detail': error.message};
    return _jsonReply(error.status, body);
  }

  String _tempFile(String suffix) {
    final Directory dir = Directory(
      p.join(_dataDir, 'plugin-data', 'files', 'tmp'),
    )..createSync(recursive: true);
    final String name =
        '${DateTime.now().microsecondsSinceEpoch}_${_tempSeq++}$suffix';
    return p.join(dir.path, name);
  }

  bool _writeShaped(Map<String, dynamic> envelope) {
    final String method = _str(envelope['method']).toUpperCase();
    final String path = _str(envelope['path']);
    if (method == 'PUT' && _matches(fileContentPattern, path)) return true;
    if (method == 'DELETE' && _matches(filesPattern, path)) return true;
    if (method == 'POST' && _matches(fileMkdirPattern, path)) return true;
    if (method == 'POST' && _matches(fileRenamePattern, path)) return true;
    return false;
  }

  static bool _matches(String pattern, String path) {
    final List<String> want = pattern.split('/');
    final List<String> got = path.split('/');
    if (want.length != got.length) return false;
    for (int i = 0; i < want.length; i++) {
      final String segment = want[i];
      if (segment.length >= 2 &&
          segment.startsWith('{') &&
          segment.endsWith('}')) {
        if (got[i].isEmpty) return false;
        continue;
      }
      if (segment != got[i]) return false;
    }
    return true;
  }

  static Map<String, dynamic> _map(Object? value) => value is Map
      ? value.map((Object? key, Object? item) => MapEntry(key.toString(), item))
      : <String, dynamic>{};

  static String _str(Object? value) => (value ?? '').toString().trim();

  static int _intOf(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse('${value ?? ''}') ?? 0;
  }

  static int? _optionalInt(Map<String, dynamic> body, String key) {
    final Object? value = body[key];
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static bool _truthy(String value) {
    final String text = value.trim().toLowerCase();
    return text == '1' || text == 'true' || text == 'yes' || text == 'on';
  }

  static String _queryString(Map<String, dynamic> query, String key) {
    final Object? raw = query[key];
    if (raw is List) return raw.isEmpty ? '' : _str(raw.first);
    return _str(raw);
  }

  static String? _safeSegment(String raw) {
    final String name = raw.trim();
    if (name.isEmpty || name == '.' || name == '..') return null;
    if (name.contains('/') || name.contains('\\')) return null;
    if (RegExp(r'[<>:"|?*\x00-\x1f]').hasMatch(name)) return null;
    return name;
  }

  static String? _safeSubPath(String raw) {
    final String normalized = raw.trim().replaceAll('\\', '/');
    if (normalized.isEmpty || normalized == '.') return '';
    if (normalized.startsWith('~') ||
        normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
      return null;
    }
    final List<String> segments = <String>[];
    for (final String segment in normalized.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      final String? safe = _safeSegment(segment);
      if (safe == null) return null;
      segments.add(safe);
    }
    return segments.join('/');
  }

  static String _newUploadId() {
    final Random random = Random.secure();
    return List<String>.generate(
      16,
      (int _) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static String _dateStamp([DateTime? now]) {
    final DateTime time = now ?? DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}${two(time.month)}${two(time.day)}';
  }
}
