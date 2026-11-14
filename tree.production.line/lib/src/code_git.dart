/// 逻辑去重的只读 git 能力：tracked 集合 + 变更集合（DN-dedup）。
///
/// 只做三件事：`git ls-files`、`git rev-parse HEAD`、`git diff --name-status -M`
/// （工作区 vs 基线）。不写工作区、不改索引；未跟踪文件按要求排除。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';

/// `git diff --name-status -M` 的解析结果（路径统一 `/`，相对工作空间）。
class GitDelta {
  GitDelta({
    required this.added,
    required this.modified,
    required this.deleted,
    required this.renamed,
    required this.baseSha,
    required this.headSha,
  });

  final List<String> added;
  final List<String> modified;
  final List<String> deleted;

  /// `(oldPath, newPath)`；按「删旧 + 增新」处理。
  final List<(String, String)> renamed;
  final String baseSha;
  final String headSha;

  bool get isEmpty =>
      added.isEmpty &&
      modified.isEmpty &&
      deleted.isEmpty &&
      renamed.isEmpty;
}

/// 一个仓库的只读 git 句柄。
class CodeGit {
  CodeGit._(this.root);

  final String root;

  static const Duration _timeout = Duration(seconds: 60);

  /// 打开并以 `rev-parse --is-inside-work-tree` 验证。
  static Future<CodeGit> open(String workspace) async {
    if (workspace.trim().isEmpty) {
      throw ProductionFailure('缺少工作空间路径', code: 'workspace_unavailable');
    }
    if (!Directory(workspace).existsSync()) {
      throw ProductionFailure(
        '工作空间不存在：$workspace',
        code: 'workspace_unavailable',
      );
    }
    final CodeGit git = CodeGit._(p.canonicalize(p.absolute(workspace)));
    final _GitResult check = await git._run(<String>[
      'rev-parse',
      '--is-inside-work-tree',
    ]);
    if (!check.ok || check.stdout.trim() != 'true') {
      throw ProductionFailure(
        '工作空间不是 git 仓库：$workspace',
        code: 'git_required',
      );
    }
    return git;
  }

  /// 当前 HEAD；空仓库（无提交）返回空串。
  Future<String> headSha() async {
    final _GitResult result = await _run(<String>['rev-parse', 'HEAD']);
    return result.ok ? result.stdout.trim() : '';
  }

  /// 全部 tracked 文件（`git ls-files -z --`）。
  Future<List<String>> lsFiles() async {
    final _GitResult result = await _run(<String>['ls-files', '-z', '--']);
    if (!result.ok) {
      throw ProductionFailure(
        'git ls-files 失败：${result.stderr.trim()}',
        code: 'git_unavailable',
      );
    }
    return <String>[
      for (final String item in result.stdout.split('\u0000'))
        if (item.trim().isNotEmpty) _normalize(item),
    ]..sort();
  }

  /// 自 [baseSha] 到工作区的变更；[baseSha] 为空视为全量新增。
  Future<GitDelta> deltaSince(String baseSha) async {
    final String head = await headSha();
    final String base = baseSha.trim();
    if (base.isEmpty) {
      return GitDelta(
        added: await lsFiles(),
        modified: <String>[],
        deleted: <String>[],
        renamed: <(String, String)>[],
        baseSha: '',
        headSha: head,
      );
    }
    final _GitResult result = await _run(<String>[
      'diff',
      '--name-status',
      '-M',
      '-z',
      base,
      '--',
    ]);
    if (!result.ok) {
      throw ProductionFailure(
        'git diff 失败：${result.stderr.trim()}',
        code: 'git_unavailable',
      );
    }
    final List<String> added = <String>[];
    final List<String> modified = <String>[];
    final List<String> deleted = <String>[];
    final List<(String, String)> renamed = <(String, String)>[];
    final List<String> tokens = result.stdout
        .split('\u0000')
        .where((String item) => item.isNotEmpty)
        .toList();
    int index = 0;
    while (index < tokens.length) {
      final String status = tokens[index++];
      if (status.isEmpty) continue;
      final String kind = status.substring(0, 1).toUpperCase();
      if (kind == 'R' || kind == 'C') {
        if (index + 1 >= tokens.length) break;
        final String from = _normalize(tokens[index++]);
        final String to = _normalize(tokens[index++]);
        renamed.add((from, to));
        continue;
      }
      if (index >= tokens.length) break;
      final String path = _normalize(tokens[index++]);
      switch (kind) {
        case 'A':
          added.add(path);
        case 'D':
          deleted.add(path);
        default:
          modified.add(path);
      }
    }
    return GitDelta(
      added: added,
      modified: modified,
      deleted: deleted,
      renamed: renamed,
      baseSha: base,
      headSha: head,
    );
  }

  Future<_GitResult> _run(List<String> args) async {
    try {
      final Process process = await Process.start(
        'git',
        <String>['-C', root, ...args],
        runInShell: false,
      );
      final Future<List<int>> out = process.stdout.fold<List<int>>(
        <int>[],
        (List<int> all, List<int> chunk) => all..addAll(chunk),
      );
      final Future<List<int>> err = process.stderr.fold<List<int>>(
        <int>[],
        (List<int> all, List<int> chunk) => all..addAll(chunk),
      );
      final int code = await process.exitCode.timeout(
        _timeout,
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      return _GitResult(
        ok: code == 0,
        stdout: utf8.decode(await out, allowMalformed: true),
        stderr: utf8.decode(await err, allowMalformed: true),
        exitCode: code,
      );
    } on ProcessException catch (error) {
      throw ProductionFailure(
        '无法执行 git：${error.message}',
        code: 'git_unavailable',
      );
    } on TimeoutException {
      throw ProductionFailure('git 命令超时', code: 'git_timeout');
    }
  }

  static String _normalize(String path) => path.replaceAll('\\', '/');
}

class _GitResult {
  const _GitResult({
    required this.ok,
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });

  final bool ok;
  final String stdout;
  final String stderr;
  final int exitCode;
}
