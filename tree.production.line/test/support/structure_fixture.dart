/// 测试夹具：把产线结构门（LG-01）与复合就绪门（LG-07）置为通过。
///
/// 门禁要求 organizing 阶段的非 cleanup 命令先有 fresh 的 `structure.json`，
/// 非 cleanup 任务还要 `line.ready`。这里**复用真实扫描与真实命令路径**：
/// 1. `production.structure.reevaluate` 生成结构报告；
/// 2. `production.normalize.plan/apply` 走真实归一化服务（docnorm 用确定性假实现，
///    单测没有 git / tree.storage）；
/// 3. `production.readiness.get` 生成并落盘 `ready.json`。
///
/// 不在测试里伪造 `ready=true`：任何一步没通过都会直接抛错。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tree_production_line/tree_production_line.dart';

/// 确定性假 docnorm：只回 L0 就绪门需要的证据字段，不读写目标仓库。
class FixtureDocnorm {
  FixtureDocnorm(this.workspace, {this.docs = 0, this.head = 'fixture-head'});

  final String workspace;

  /// 仓库里的文档数（0 ⇒ LG-02 走 `no_docs`）。
  final int docs;
  final String head;

  int baselineCalls = 0;
  int commitCalls = 0;
  int graphCalls = 0;

  Future<Map<String, Object?>> call(
    String command,
    Map<String, Object?> arguments,
    Map<String, Object?> scope,
  ) async {
    if (command == 'docnorm.baseline') {
      baselineCalls += 1;
      final bool commit = arguments['commit'] == true;
      if (commit) commitCalls += 1;
      return <String, Object?>{
        'command': 'docnorm.baseline',
        'repo': workspace,
        'repo_key': workspace,
        'run_id': arguments['run_id'] ?? '',
        'dry_run': !commit,
        'committed': commit,
        'code_fingerprint': 'fixture-fingerprint',
        'git': <String, Object?>{'head': head},
        'contract': <String, Object?>{
          'ok': true,
          'docs': docs,
          'violations': 0,
          'degraded': false,
          'unknown': <String>[],
        },
        'packages': <String, Object?>{
          'total': 0,
          'ids': <String>[],
          'degraded': false,
        },
        'plan': <String, Object?>{
          'files': <Map<String, Object?>>[],
          'skipped': <Map<String, Object?>>[],
          'rejected': <Map<String, Object?>>[],
          'rewrite_allowlist': arguments['rewrite_allowlist'] ?? <String>[],
        },
        'would_write': <String>[],
        'written': <String>[],
        'doc_state': <String, Object?>{
          'updated': <String>['fixture#pkg:root'],
          'documents': <String, Object?>{
            for (int i = 0; i < docs; i++) 'doc-$i.md': <String, Object?>{},
          },
          'packages': <String, Object?>{
            'root': <String, Object?>{'stale': false},
          },
        },
        'storage': <String, Object?>{
          'ok': true,
          'writes': <Object?>[],
          'applied': commit,
        },
      };
    }
    if (command == 'docnorm.graph.build') {
      graphCalls += 1;
      return <String, Object?>{
        'command': 'docnorm.graph.build',
        'repo': workspace,
        'mode': 'deterministic',
        'dry_run': arguments['commit'] != true,
        'committed': arguments['commit'] == true,
        'git': <String, Object?>{'head': head},
        'nodes': <Object?>[],
        'edges': <Object?>[],
        'counts': <String, Object?>{
          'nodes': 0,
          'edges': 0,
          'docs': docs,
          'packages': 0,
        },
        'storage': <String, Object?>{'applied': false, 'ops': 0},
      };
    }
    throw StateError('FixtureDocnorm 不支持：$command');
  }

  Future<Map<String, Object?>> dedupStatus(
    String lineId,
    Map<String, Object?> meta,
    Map<String, Object?> scope,
  ) async => <String, Object?>{
    'command': 'production.dedup.status',
    'line_id': lineId,
    'run': <String, Object?>{
      'run_id': 'fixture-dedup',
      'mode': 'hybrid',
      'head_sha': head,
      'base_sha': head,
      'degraded': false,
      'counts': <String, Object?>{
        'chunks': 1,
        'vectors': 1,
        'results': 0,
      },
    },
    'counts': <String, Object?>{'results': 0},
    'degraded': false,
  };
}

/// 只做结构门：返回被标记的 workspace 路径。
String markStructureReady(
  ProductionStore store,
  String lineId,
  Directory root, {
  String workspace = '',
}) {
  final Directory dir = Directory(
    workspace.isEmpty ? p.join(root.path, 'structure_ws', lineId) : workspace,
  )..createSync(recursive: true);
  if (store.getLine(lineId).workspaceDir != dir.path) {
    store.updateLine(lineId, <String, Object?>{'workspace_dir': dir.path});
  }
  final Map<String, Object?> result = handleStructureCommand(
    store,
    'production.structure.reevaluate',
    <String, Object?>{'line_id': lineId},
  );
  if (result['ready'] != true) {
    throw StateError('结构夹具未通过：${result['missing']}');
  }
  return dir.path;
}

/// 结构 + 归一化 + 复合就绪门：通过真实命令路径把产线推到 `ready`。
Future<String> markLineReady(
  ProductionStore store,
  String lineId,
  Directory root, {
  String workspace = '',
  FixtureDocnorm? docnorm,
}) async {
  final String resolved = markStructureReady(
    store,
    lineId,
    root,
    workspace: workspace,
  );
  final FixtureDocnorm probe = docnorm ?? FixtureDocnorm(resolved);
  final Map<String, Object?> meta = <String, Object?>{
    'data_dir': store.dataRoot,
  };
  final Map<String, Object?> scope = <String, Object?>{};
  final ProductionNormalizationService normalization =
      ProductionNormalizationService(
        environment: const <String, String>{},
        docnorm: probe.call,
      );
  await normalization.handle(
    'production.normalize.plan',
    <String, Object?>{
      'line_id': lineId,
      'sections': <Object?>[],
      'indexes': <Object?>[],
    },
    meta,
    scope,
  );
  await normalization.handle(
    'production.normalize.apply',
    <String, Object?>{'line_id': lineId},
    meta,
    scope,
  );
  final ProductionReadinessService readiness = ProductionReadinessService(
    environment: const <String, String>{},
    docnorm: probe.call,
    dedupStatus: probe.dedupStatus,
  );
  final Map<String, Object?> result = await readiness.handle(
    'production.readiness.get',
    <String, Object?>{'line_id': lineId},
    meta,
    scope,
  );
  if (result['ready'] != true) {
    throw StateError('产线就绪夹具未通过：${result['missing']}');
  }
  return resolved;
}
