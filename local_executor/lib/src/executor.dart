import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 执行器错误：带可读中文原因，入口原样回给核心。
class ExecutorError implements Exception {
  ExecutorError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 本机执行器：只认 `root`（租约根）与相对路径，**不认 agent/team/mode 身份**。
class LocalExecutor {
  const LocalExecutor();

  Future<Map<String, dynamic>> execute(
    String command,
    Map<String, dynamic> arguments,
  ) async {
    switch (command) {
      case 'fs.read':
      case 'file.read':
        return _read(arguments);
      case 'fs.write':
      case 'file.write':
        return _write(arguments);
      case 'fs.list':
      case 'file.list':
        return _list(arguments);
      case 'fs.grep':
      case 'file.grep':
        return _grep(arguments);
      case 'fs.delete':
      case 'file.delete':
        return _delete(arguments);
      case 'fs.mkdir':
      case 'file.mkdir':
        return _mkdir(arguments);
      case 'fs.writeBytes':
      case 'file.writeBytes':
        return _writeBytes(arguments);
      case 'terminal.exec':
      case 'exec.command':
        return _terminal(arguments);
      default:
        throw ExecutorError('本机执行器不支持命令：$command');
    }
  }

  String _root(Map<String, dynamic> args) {
    final String root = (args['root'] ?? '').toString().trim();
    if (root.isEmpty || !p.isAbsolute(root)) {
      throw ExecutorError('执行器需要绝对路径 root（工作空间租约由核心注入）');
    }
    final String normalized = p.normalize(root);
    if (!Directory(normalized).existsSync()) {
      throw ExecutorError('工作空间根目录不存在：$normalized');
    }
    return normalized;
  }

  String _resolve(String root, String relative) {
    final String rel = relative.trim();
    if (rel.isEmpty) throw ExecutorError('缺少 path（工作空间内相对路径）');
    if (p.isAbsolute(rel)) {
      throw ExecutorError('path 必须是工作空间内相对路径：$rel');
    }
    final String joined = p.normalize(p.join(root, rel));
    if (joined != root && !p.isWithin(root, joined)) {
      throw ExecutorError('path 越出工作空间根目录：$rel');
    }
    return joined;
  }

  String _relative(String root, String absolute) =>
      p.relative(absolute, from: root).replaceAll('\\', '/');

  Future<Map<String, dynamic>> _read(Map<String, dynamic> args) async {
    final String root = _root(args);
    final String relative = (args['path'] ?? args['file_path'] ?? '').toString();
    final String path = _resolve(root, relative);
    final File file = File(path);
    if (!file.existsSync()) throw ExecutorError('文件不存在：$relative');
    final List<int> bytes = await file.readAsBytes();
    String text;
    String? base64;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      text = '';
      base64 = base64Encode(bytes);
    }
    final List<String> lines = text.split('\n');
    final int total = text.isEmpty ? 0 : lines.length;
    final int start = ((args['start_line'] as num?)?.toInt() ?? 1);
    final int first = start < 1 ? 1 : (start > total ? total : start);
    final int? count = (args['line_count'] as num?)?.toInt();
    final int end = count != null && count > 0
        ? (first + count - 1 > total ? total : first + count - 1)
        : total;
    final String content = total == 0
        ? ''
        : lines.sublist(first - 1, end).join('\n');
    final bool truncated = content.length > 512 * 1024;
    return <String, dynamic>{
      'path': _relative(root, path),
      'content': truncated ? content.substring(0, 512 * 1024) : content,
      'total_lines': total,
      'start_line': total == 0 ? 1 : first,
      'truncated': truncated,
      'base64': ?base64,
    };
  }

  Future<Map<String, dynamic>> _write(Map<String, dynamic> args) async {
    final String root = _root(args);
    final String relative = (args['path'] ?? args['file_path'] ?? '').toString();
    final String path = _resolve(root, relative);
    final String content = (args['content'] ?? '').toString();
    final File file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(content, flush: true);
    return <String, dynamic>{
      'path': _relative(root, path),
      'bytes_written': utf8.encode(content).length,
    };
  }

  Future<Map<String, dynamic>> _list(Map<String, dynamic> args) async {
    final String root = _root(args);
    final String relative = (args['path'] ?? '.').toString();
    final String base = _resolve(root, relative);
    final int maxDepth = ((args['max_depth'] as num?)?.toInt() ?? 2).clamp(0, 32);
    final int maxEntries = ((args['max_entries'] as num?)?.toInt() ?? 500).clamp(1, 5000);
    final List<String> entries = <String>[];
    void walk(Directory dir, int depth) {
      if (entries.length >= maxEntries) return;
      final List<FileSystemEntity> children = dir.listSync(followLinks: false)
        ..sort((FileSystemEntity a, FileSystemEntity b) => a.path.compareTo(b.path));
      for (final FileSystemEntity child in children) {
        if (entries.length >= maxEntries) return;
        final String rel = _relative(root, child.path);
        if (child is Directory) {
          entries.add('$rel/');
          if (depth < maxDepth) walk(child, depth + 1);
        } else if (child is File) {
          entries.add(rel);
        }
      }
    }
    final FileSystemEntityType type = FileSystemEntity.typeSync(base);
    if (type == FileSystemEntityType.directory) {
      walk(Directory(base), 0);
    } else if (type == FileSystemEntityType.file) {
      entries.add(_relative(root, base));
    } else {
      throw ExecutorError('路径不存在：$relative');
    }
    return <String, dynamic>{
      'path': relative,
      'root': root,
      'entries': entries,
      'count': entries.length,
      'truncated': entries.length >= maxEntries,
    };
  }

  Future<Map<String, dynamic>> _delete(Map<String, dynamic> args) async {
    final String root = _root(args);
    final String relative = (args['path'] ?? '').toString();
    final String path = _resolve(root, relative);
    final FileSystemEntityType type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) {
      throw ExecutorError('路径不存在：$relative');
    }
    final bool recursive = args['recursive'] == true;
    if (type == FileSystemEntityType.directory) {
      final Directory dir = Directory(path);
      if (!recursive && dir.listSync().isNotEmpty) {
        throw ExecutorError('目录非空，删除需要 recursive=true：$relative');
      }
      dir.deleteSync(recursive: recursive);
    } else {
      File(path).deleteSync();
    }
    return <String, dynamic>{'path': relative, 'deleted': true};
  }

  Future<Map<String, dynamic>> _mkdir(Map<String, dynamic> args) async {
    final String root = _root(args);
    final String relative = (args['path'] ?? '').toString();
    final String path = _resolve(root, relative);
    final Directory dir = Directory(path);
    if (!dir.existsSync()) {
      dir.createSync(recursive: args['recursive'] != false);
    }
    return <String, dynamic>{'path': relative, 'created': true};
  }

  Future<Map<String, dynamic>> _writeBytes(Map<String, dynamic> args) async {
    final String root = _root(args);
    final String relative = (args['path'] ?? '').toString();
    final String path = _resolve(root, relative);
    final String encoded = (args['base64'] ?? args['content_base64'] ?? '')
        .toString();
    if (encoded.isEmpty) {
      throw ExecutorError('fs.writeBytes 需要 base64（要写入的二进制）');
    }
    final List<int> bytes;
    try {
      bytes = base64Decode(encoded);
    } on FormatException {
      throw ExecutorError('fs.writeBytes 的 base64 非法');
    }
    final File file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return <String, dynamic>{
      'path': _relative(root, path),
      'bytes_written': bytes.length,
    };
  }

  Future<Map<String, dynamic>> _grep(Map<String, dynamic> args) async {
    final String root = _root(args);
    final String pattern = (args['pattern'] ?? '').toString();
    if (pattern.isEmpty) throw ExecutorError('grep 需要 pattern');
    final bool regex = args['regex'] == true;
    final bool ignoreCase = args['ignore_case'] == true;
    final RegExp matcher = regex
        ? RegExp(pattern, caseSensitive: !ignoreCase)
        : RegExp(RegExp.escape(pattern), caseSensitive: !ignoreCase);
    final String relative = (args['path'] ?? '.').toString();
    final String base = _resolve(root, relative);
    final int maxDepth = ((args['max_depth'] as num?)?.toInt() ?? 0).clamp(0, 64);
    final int maxResults = ((args['max_results'] as num?)?.toInt() ?? 200).clamp(1, 5000);
    final bool includeHidden = args['include_hidden'] == true;
    final List<Map<String, dynamic>> matches = <Map<String, dynamic>>[];
    int scanned = 0;
    bool truncated = false;
    void scanFile(File file) {
      if (matches.length >= maxResults) return;
      final String rel = _relative(root, file.path);
      if (!includeHidden &&
          p.split(rel).any((String part) => part.startsWith('.'))) {
        return;
      }
      String text;
      try {
        text = utf8.decode(file.readAsBytesSync());
      } catch (_) {
        return;
      }
      scanned++;
      final List<String> lines = text.split('\n');
      for (int i = 0; i < lines.length; i++) {
        if (matcher.hasMatch(lines[i])) {
          matches.add(<String, dynamic>{
            'path': rel,
            'line': i + 1,
            'text': lines[i],
          });
          if (matches.length >= maxResults) {
            truncated = true;
            return;
          }
        }
      }
    }

    void walk(Directory dir, int depth) {
      if (matches.length >= maxResults) return;
      for (final FileSystemEntity child in dir.listSync(followLinks: false)) {
        if (child is Directory) {
          if (depth >= maxDepth && maxDepth > 0) continue;
          walk(child, depth + 1);
        } else if (child is File) {
          scanFile(child);
        }
      }
    }

    if (FileSystemEntity.typeSync(base) == FileSystemEntityType.directory) {
      walk(Directory(base), 0);
    } else if (FileSystemEntity.typeSync(base) == FileSystemEntityType.file) {
      scanFile(File(base));
    } else {
      throw ExecutorError('路径不存在：$relative');
    }
    return <String, dynamic>{
      'pattern': pattern,
      'count': matches.length,
      'matches': matches,
      'truncated': truncated,
      'scanned_file_count': scanned,
    };
  }

  Future<Map<String, dynamic>> _terminal(Map<String, dynamic> args) async {
    final String root = _root(args);
    final String command = (args['command'] ?? '').toString().trim();
    if (command.isEmpty) throw ExecutorError('terminal.exec 需要 command');
    final int timeout = ((args['timeout'] as num?)?.toInt() ?? 0);
    final bool windows = Platform.isWindows;
    final Process process = await Process.start(
      windows ? 'cmd' : '/bin/sh',
      windows ? <String>['/c', command] : <String>['-c', command],
      workingDirectory: root,
      runInShell: false,
    );
    final Future<String> stdout = process.stdout.transform(utf8.decoder).join();
    final Future<String> stderr = process.stderr.transform(utf8.decoder).join();
    int code;
    if (timeout > 0) {
      code = await process.exitCode.timeout(
        Duration(seconds: timeout),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
    } else {
      code = await process.exitCode;
    }
    final String out = await stdout;
    final String err = await stderr;
    final String text = <String>[
      if (out.isNotEmpty) out.trimRight(),
      if (err.isNotEmpty) err.trimRight(),
    ].join('\n');
    return <String, dynamic>{
      'text': text,
      'is_error': code != 0,
      'exit_code': code,
    };
  }
}