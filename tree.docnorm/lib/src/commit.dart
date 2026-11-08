import 'dart:io';

import 'package:path/path.dart' as p;

import 'baseline.dart';
import 'contract.dart';
import 'plan.dart';
import 'policy.dart';
import 'scan.dart';

/// `docnorm.commit [--commit] [--run-gates]`：按域分批提交（DN-8）。
///
/// - 变更只认 [GitRepository.changedFiles]，空 diff 不产批次（不产生空提交）；
/// - 分批：docs 域 / 每个最具体包 root / unmatched；
/// - 风格探测只看 `git log -n 20 --pretty=%s`：conventional / plain / unknown，
///   混合风格不猜（标 `unknown`）；
/// - 门禁默认只列（命令 + 工作目录 + 来源），`runGates` 才执行；失败整批不提交；
/// - 不 push、不 amend、不跨仓；默认 dry-run，`commit` 才 `git add` + `git commit`。
Future<Map<String, Object?>> runCommit(
  String repo, {
  bool commit = false,
  bool runGates = false,
}) async {
  final GitRepository git = await GitRepository.open(repo);
  final RepoIndex index = await RepoIndex.load(repo);
  final DocPolicy policy = DocPolicy.resolve(index);
  final DocContract contract = inspectIndex(index, policy);
  final ScanResult scan = await scanIndex(index);
  final GitChanges changes = await git.changedFiles();
  final CommitStyle style = detectCommitStyle(await git.recentSubjects());

  final List<_Batch> batches = _buildBatches(changes.all, scan.packages);
  final List<Map<String, Object?>> gateCommands = _gateCommands(contract);

  final List<Map<String, Object?>> results = <Map<String, Object?>>[];
  int committedBatches = 0;
  int failedBatches = 0;
  for (final _Batch batch in batches) {
    final List<String> files = batch.files.toList()..sort();
    final Map<String, Object?> payload = <String, Object?>{
      'name': batch.name,
      'kind': batch.kind,
      'root': batch.root,
      'files': files,
      'message': _messageFor(batch, style, files.length),
      'message_style': style.style,
      'status': 'planned',
      'gates': <Map<String, Object?>>[
        for (final Map<String, Object?> gate in gateCommands)
          <String, Object?>{
            'command': gate['command'],
            'source': gate['source'],
            'cwd': batch.root,
          },
      ],
    };

    bool gatesPassed = true;
    if (runGates) {
      final List<Map<String, Object?>> executed = <Map<String, Object?>>[];
      for (final Map<String, Object?> gate in gateCommands) {
        final Map<String, Object?> result = await _runGate(
          index.root,
          batch.root,
          '${gate['command']}',
          '${gate['source']}',
        );
        executed.add(result);
        if (result['status'] != 'passed') gatesPassed = false;
      }
      payload['gates'] = executed;
      if (!gatesPassed) {
        payload['status'] = 'failed';
        payload['error'] = '门禁失败：整批不提交';
      }
    }

    if (gatesPassed && commit) {
      final Map<String, Object?> applied = await _commitBatch(
        git,
        files,
        '${payload['message']}',
      );
      payload.addAll(applied);
      if (applied['status'] == 'committed') {
        committedBatches += 1;
      } else {
        failedBatches += 1;
      }
    } else if (gatesPassed) {
      payload['status'] = 'planned';
    } else {
      failedBatches += 1;
    }
    results.add(payload);
  }

  return <String, Object?>{
    'command': 'docnorm.commit',
    'repo': index.root,
    'dry_run': !commit,
    'committed': commit,
    'commit_style': style.toJson(),
    'git': changes.toJson(),
    'gates': <String, Object?>{
      'mode': runGates ? 'executed' : 'listed',
      'count': gateCommands.length,
      'commands': gateCommands,
    },
    'batches': results,
    'counts': <String, Object?>{
      'batches': results.length,
      'files': changes.all.length,
      'committed': committedBatches,
      'failed': failedBatches,
    },
    'notes': <String>[
      '变更只认 git diff 的内容差异；空 diff 不产批次（不产生空提交）',
      '分批按 docs 域 / 最具体包 root / unmatched 归集，跨仓不合批',
      '门禁默认只列（命令 + 工作目录 + 来源）；--run-gates 才执行，失败整批不提交',
      '只 add / commit 本批文件，不 push、不 amend、不跳过钩子',
    ],
  };
}

/// 提交风格事实（不猜：混合风格标 `unknown`）。
class CommitStyle {
  const CommitStyle({
    required this.style,
    required this.dominantType,
    required this.samples,
    required this.types,
  });

  final String style;
  final String dominantType;
  final int samples;
  final Map<String, int> types;

  Map<String, Object?> toJson() => <String, Object?>{
    'style': style,
    'dominant_type': dominantType,
    'samples': samples,
    'types': types,
  };
}

/// 看最近提交标题判断风格：全 conventional ⇒ conventional；全非 conventional
/// 但有标题 ⇒ plain；空历史或混合 ⇒ unknown。
CommitStyle detectCommitStyle(List<String> subjects) {
  final RegExp pattern = RegExp(r'^([a-z]+)(?:\(([^)]+)\))?!?:\s+(.+)$');
  final Map<String, int> types = <String, int>{};
  int conventional = 0;
  for (final String subject in subjects) {
    final RegExpMatch? match = pattern.firstMatch(subject);
    if (match == null) continue;
    conventional += 1;
    final String type = match.group(1)!;
    types[type] = (types[type] ?? 0) + 1;
  }
  String dominant = '';
  int best = 0;
  for (final String type in types.keys.toList()..sort()) {
    final int count = types[type]!;
    if (count > best) {
      best = count;
      dominant = type;
    }
  }
  String style;
  if (subjects.isEmpty) {
    style = 'unknown';
  } else if (conventional == subjects.length) {
    style = 'conventional';
  } else if (conventional == 0) {
    style = 'plain';
  } else {
    style = 'unknown';
  }
  return CommitStyle(
    style: style,
    dominantType: dominant,
    samples: subjects.length,
    types: types,
  );
}

/// 一批变更：`kind = package | docs | unmatched`。
class _Batch {
  _Batch({required this.kind, required this.name, required this.root});

  final String kind;
  final String name;
  final String root;
  final List<String> files = <String>[];
}

List<_Batch> _buildBatches(List<String> files, List<PackageUnit> packages) {
  final Map<String, _Batch> groups = <String, _Batch>{};
  for (final String path in files) {
    // 文档优先进 docs 域：包 README / docs 变更不与代码混批。
    if (isDocPath(path) || path.startsWith('docs/')) {
      groups
          .putIfAbsent(
            'docs',
            () => _Batch(kind: 'docs', name: 'docs', root: '.'),
          )
          .files
          .add(path);
      continue;
    }
    final PackageUnit? owner = _ownerPackage(path, packages);
    if (owner != null) {
      groups
          .putIfAbsent(
            'pkg:${owner.id}',
            () => _Batch(kind: 'package', name: owner.id, root: owner.root),
          )
          .files
          .add(path);
      continue;
    }
    groups
        .putIfAbsent(
          'unmatched',
          () => _Batch(kind: 'unmatched', name: 'unmatched', root: '.'),
        )
        .files
        .add(path);
  }
  final List<_Batch> out = groups.values.toList()
    ..sort((_Batch a, _Batch b) => a.name.compareTo(b.name));
  return out;
}

PackageUnit? _ownerPackage(String path, List<PackageUnit> packages) {
  PackageUnit? best;
  int bestLength = -1;
  for (final PackageUnit unit in packages) {
    final String root = unit.root;
    if (root == '.' || path == root || path.startsWith('$root/')) {
      final int length = root == '.' ? 0 : root.length;
      if (length > bestLength) {
        bestLength = length;
        best = unit;
      }
    }
  }
  return best;
}

String _messageFor(_Batch batch, CommitStyle style, int fileCount) {
  final String target = batch.kind == 'package'
      ? batch.name
      : (batch.kind == 'docs' ? '文档与索引' : '其余文件');
  if (style.style == 'conventional') {
    if (batch.kind == 'docs') return 'docs: 同步文档与索引（$fileCount 个文件）';
    if (batch.kind == 'package') {
      return 'chore(${_scopeOf(batch.name)}): 更新 $target（$fileCount 个文件）';
    }
    return 'chore: 更新$target（$fileCount 个文件）';
  }
  if (style.style == 'plain') return '更新 $target（$fileCount 个文件）';
  return 'docnorm: 更新 $target（$fileCount 个文件）';
}

String _scopeOf(String name) =>
    name.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '-');

List<Map<String, Object?>> _gateCommands(DocContract contract) {
  final Object? raw = contract.gates['commands'];
  if (raw is! List) return const <Map<String, Object?>>[];
  return <Map<String, Object?>>[
    for (final Object? item in raw)
      if (item is Map && item['command'] != null)
        <String, Object?>{
          'command': '${item['command']}',
          'source': '${item['source'] ?? ''}',
        },
  ];
}

/// 执行一条门禁：Windows 走 `cmd /c`，其它走 `sh -lc`；只读回包不含完整输出。
Future<Map<String, Object?>> _runGate(
  String repoRoot,
  String cwd,
  String command,
  String source,
) async {
  final String workdir = cwd == '.' || cwd.isEmpty
      ? repoRoot
      : p.joinAll(<String>[repoRoot, ...cwd.split('/')]);
  final String commandLine = Platform.isWindows
      ? 'cmd /c $command'
      : 'sh -lc $command';
  final Stopwatch watch = Stopwatch()..start();
  ProcessResult result;
  try {
    result = Platform.isWindows
        ? await Process.run(
            'cmd',
            <String>['/c', command],
            workingDirectory: workdir,
          )
        : await Process.run(
            'sh',
            <String>['-lc', command],
            workingDirectory: workdir,
          );
  } catch (error) {
    watch.stop();
    return <String, Object?>{
      'command': command,
      'source': source,
      'cwd': cwd,
      'command_line': commandLine,
      'workdir': workdir,
      'status': 'failed',
      'exit_code': -1,
      'duration_ms': watch.elapsedMilliseconds,
      'stderr_tail': '$error',
    };
  }
  watch.stop();
  return <String, Object?>{
    'command': command,
    'source': source,
    'cwd': cwd,
    'command_line': commandLine,
    'workdir': workdir,
    'status': result.exitCode == 0 ? 'passed' : 'failed',
    'exit_code': result.exitCode,
    'duration_ms': watch.elapsedMilliseconds,
    'stdout_tail': _tail('${result.stdout}'),
    'stderr_tail': _tail('${result.stderr}'),
  };
}

Future<Map<String, Object?>> _commitBatch(
  GitRepository git,
  List<String> files,
  String message,
) async {
  if (files.isEmpty) {
    return <String, Object?>{'status': 'skipped', 'error': '空批次不入提交'};
  }
  final ProcessResult added = await git.exec(<String>['add', '--', ...files]);
  if (added.exitCode != 0) {
    return <String, Object?>{
      'status': 'failed',
      'error': 'git add 失败：${_tail('${added.stderr}')}',
    };
  }
  final ProcessResult committed = await git.exec(<String>[
    'commit',
    '--quiet',
    '-m',
    message,
    '--',
    ...files,
  ]);
  if (committed.exitCode != 0) {
    // 失败只撤本批的暂存，不碰工作树（不是 reset --hard）。
    await git.exec(<String>['reset', '--quiet', '--', ...files]);
    return <String, Object?>{
      'status': 'failed',
      'error': 'git commit 失败：${_tail('${committed.stderr}')}',
    };
  }
  final ProcessResult head = await git.exec(<String>['rev-parse', 'HEAD']);
  return <String, Object?>{
    'status': 'committed',
    'commit': head.exitCode == 0 ? '${head.stdout}'.trim() : '',
  };
}

String _tail(String text) {
  const int limit = 2000;
  final String trimmed = text.trim();
  return trimmed.length <= limit
      ? trimmed
      : trimmed.substring(trimmed.length - limit);
}
