/// 逻辑去重的执行站门面：git tracked → 函数级分块 → 向量缓存 → 全库 top-k。
///
/// 命令：
/// - `production.dedup.run`：推进一个有界批次（plan / embed / compare / finalize）；
/// - `production.dedup.status`：只读已落盘结果，不跑 git、不发 embedding。
///
/// 所有缓存与结果走 `tree.storage` 的 plugin 绑定；配置走 `tree.settings`
/// 的 plugin 绑定。断点状态落在插件数据 `<line>/dedup_state.json`。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'code_chunk.dart';
import 'code_git.dart';
import 'dedup.dart';
import 'dedup_config.dart';
import 'dedup_store.dart';
import 'models.dart';
import 'service.dart';
import 'store.dart';

const List<String> kDedupCommands = <String>[
  'production.dedup.run',
  'production.dedup.status',
];

const String kDedupStateFile = 'dedup_state.json';
const int kDedupStateVersion = 1;

/// 进程内索引快照：run 内向量在 compare 前已写完，后续批次直接复用。
///
/// 20k 块 × 1536 维 Float32 ≈ 120 MB；finalize / 新 run 时清理，避免跨 run 堆积。
final Map<String, _DedupIndex> _indexCache = <String, _DedupIndex>{};

String _indexCacheKey(String repoKey, String runId) => '$repoKey|$runId';

void _dropIndexRun(String repoKey, String runId) {
  _indexCache.remove(_indexCacheKey(repoKey, runId));
}

void _dropIndexRepo(String repoKey) {
  _indexCache.removeWhere((String key, _DedupIndex _) => key.startsWith('$repoKey|'));
}

class _DedupIndex {
  const _DedupIndex({
    required this.candidates,
    required this.byId,
    required this.truncated,
  });

  final List<DedupCandidate> candidates;
  final Map<String, DedupCandidate> byId;
  final bool truncated;
}

/// 只对这些代码扩展名做函数级分块。
const Set<String> kDedupExtensions = <String>{
  'dart',
  'py',
  'go',
  'rs',
  'ts',
  'tsx',
  'js',
  'jsx',
  'vue',
};

class DedupEmbedRequest {
  const DedupEmbedRequest({required this.inputs, this.model = ''});

  final List<String> inputs;
  final String model;
}

class DedupEmbedReply {
  const DedupEmbedReply({
    this.vectors = const <List<double>>[],
    this.model = '',
    this.dimensions = 0,
    this.error = '',
    this.code = '',
  });

  final List<List<double>> vectors;
  final String model;
  final int dimensions;
  final String error;
  final String code;

  bool get ok => error.trim().isEmpty;
}

typedef DedupEmbedCall = Future<DedupEmbedReply> Function(
  DedupEmbedRequest request,
);

typedef DedupSettingsCall = Future<DedupConfig> Function();

class ProductionDedupService {
  ProductionDedupService({
    Map<String, String>? environment,
    DateTime Function()? clock,
    this.storage,
    this.embed,
    this.settings,
    this.filesPerRun,
  }) : _environment = environment ?? Platform.environment,
       _clock = clock ?? DateTime.now;

  final Map<String, String> _environment;
  final DateTime Function() _clock;

  /// 测试缝：固定单请求处理的文件数。
  final int? filesPerRun;

  final DedupStorageCall? storage;
  final DedupEmbedCall? embed;
  final DedupSettingsCall? settings;

  Future<Map<String, Object?>> handle(
    String command,
    Map<String, Object?> arguments,
    Map<String, Object?> meta,
    Map<String, Object?> scope,
  ) async {
    final ProductionTarget target = resolveProductionTarget(
      meta,
      scope,
      _environment,
    );
    final ProductionStore lineStore = ProductionStore(
      dataRoot: target.dataRoot,
      clock: _clock,
    );
    final String lineId = _argument(arguments, 'line_id');
    final LineRecord line = lineStore.getLine(lineId);
    final String workspace = lineStore.workspaceDirOf(lineId);
    final DedupStore store = DedupStore(
      storage ??
          (String name, Map<String, dynamic> args) async =>
              <String, dynamic>{
                'ok': false,
                'error': '存储通道不可用：$name',
                'code': 'storage_unavailable',
              },
    );
    final String repoKey = _repoKeyOf(workspace);
    switch (command) {
      case 'production.dedup.run':
        return _run(
          lineStore,
          store,
          lineId: lineId,
          workspace: workspace,
          repoKey: repoKey,
          arguments: arguments,
        );
      case 'production.dedup.status':
        return _status(store, line, repoKey);
      default:
        throw ProductionFailure('未知逻辑去重命令：$command', code: 'unknown_command');
    }
  }

  Future<Map<String, Object?>> _status(
    DedupStore store,
    LineRecord line,
    String repoKey,
  ) async {
    final Map<String, Object?>? meta = await store.get(
      'dedup_meta',
      '$repoKey#meta',
    );
    final List<StoredRecord> results = await store.listAll(
      'dedup_results',
      '$repoKey#result:',
    );
    final List<Map<String, Object?>> values = <Map<String, Object?>>[
      for (final StoredRecord record in results) record.value,
    ];
    return <String, Object?>{
      'command': 'production.dedup.status',
      'line_id': line.id,
      'repo_key': repoKey,
      'run': meta?['last_run'],
      'progress': meta?['progress'],
      'top_pairs': topPairs(values),
      'counts': <String, Object?>{
        'results': values.length,
        'pairs': topPairs(values, limit: 100000).length,
      },
      'degraded': meta?['last_run'] is Map
          ? (meta!['last_run'] as Map)['degraded'] == true
          : false,
    };
  }

  Future<Map<String, Object?>> _run(
    ProductionStore lineStore,
    DedupStore store, {
    required String lineId,
    required String workspace,
    required String repoKey,
    required Map<String, Object?> arguments,
  }) async {
    final Directory root = Directory(workspace);
    if (!root.existsSync()) {
      throw ProductionFailure(
        '产线工作空间不存在：$workspace',
        code: 'workspace_unavailable',
      );
    }
    final String statePath = p.join(lineStore.lineDir(lineId), kDedupStateFile);
    final String lockPath = '$statePath.lock';
    if (!_acquireLock(lockPath)) {
      throw ProductionFailure(
        '逻辑去重正在进行中（上一个请求还没结束），稍后再试。',
        code: 'dedup_in_progress',
      );
    }
    try {
      final DedupConfig config = await _readConfig(repoKey);
      if (!config.enabled) {
        return <String, Object?>{
          'command': 'production.dedup.run',
          'line_id': lineId,
          'repo_key': repoKey,
          'done': true,
          'skipped': true,
          'mode': 'disabled',
          'progress': <String, Object?>{'done': true, 'percent': 100},
          'degraded': false,
          'reasons': const <String>['dedup_enabled=false：本次跳过'],
        };
      }
      final CodeGit git = await CodeGit.open(workspace);
      final String head = await git.headSha();
      _DedupState? state = _loadState(statePath, workspace);
      if (state != null && state.headSha != head) {
        _deleteState(statePath);
        throw ProductionFailure(
          '运行期间 git HEAD 已变化，已丢弃本次断点，请重试',
          code: 'head_moved',
        );
      }
      state ??= await _initState(
        store,
        git: git,
        config: config,
        workspace: workspace,
        repoKey: repoKey,
        lineId: lineId,
        head: head,
        mode: textOf(arguments['mode']),
        limit: filesPerRun ?? intOf(arguments['limit'], 0),
      );
      if (state.done) {
        _deleteState(statePath);
        return _reply(state, done: true);
      }

      final int filesBudget =
          state.filesPerRun > 0 ? state.filesPerRun : config.filesPerRequest;
      await _scanFiles(state, store, filesBudget);
      if (state.model.isNotEmpty && !state.unavailable) {
        await _embedChunks(state, store, config);
      }
      if (state.embedQueue.isEmpty && !state.unavailable) {
        await _compareChunks(state, store, config);
      }
      final bool done = state.pendingFiles.isEmpty &&
          state.embedQueue.isEmpty &&
          state.compareQueue.isEmpty;
      if (done) {
        await _finalize(state, store, repoKey: repoKey);
        _deleteState(statePath);
        return _reply(state, done: true);
      }
      _saveState(statePath, state);
      return _reply(state, done: false);
    } finally {
      _releaseLock(lockPath);
    }
  }

  Future<DedupConfig> _readConfig(String repoKey) async {
    final DedupSettingsCall? reader = settings;
    if (reader == null) return DedupConfig.defaults;
    try {
      return await reader();
    } catch (_) {
      return DedupConfig.defaults;
    }
  }

  Future<_DedupState> _initState(
    DedupStore store, {
    required CodeGit git,
    required DedupConfig config,
    required String workspace,
    required String repoKey,
    required String lineId,
    required String head,
    required String mode,
    required int limit,
  }) async {
    await store.ensureAll();
    final Map<String, Object?>? meta = await store.get(
      'dedup_meta',
      '$repoKey#meta',
    );
    String baseline = textOf(meta?['baseline_sha']);
    final bool rebuild = mode == 'rebuild';
    if (rebuild) {
      for (final String collection in kDedupCollections) {
        await store.deletePrefix(collection, '$repoKey#');
      }
      baseline = '';
    }
    final bool hasIndex = (await store.listAll('dedup_files', '$repoKey#file:'))
        .isNotEmpty;
    final bool lastDegraded =
        meta?['last_run'] is Map &&
        (meta!['last_run'] as Map)['degraded'] == true;
    if (!hasIndex || lastDegraded) baseline = '';
    final GitDelta delta = await _deltaOrFull(git, baseline);
    final List<String> pending = <String>[
      ...delta.added,
      ...delta.modified,
      for (final (String _, String to) in delta.renamed) to,
    ];
    final List<String> deleted = <String>[
      ...delta.deleted,
      for (final (String from, String _) in delta.renamed) from,
    ];

    final _DedupState state = _DedupState(
      workspace: workspace,
      repoKey: repoKey,
      lineId: lineId,
      runId: 'dedup-${_clock().millisecondsSinceEpoch}',
      headSha: head,
      baseSha: baseline,
      mode: rebuild ? 'rebuild' : 'incremental',
      startedAt: _clock().toIso8601String(),
      filesPerRun: limit > 0 ? limit : config.filesPerRequest,
    )..maxFileBytes = config.maxFileBytes;
    // 新 run 的索引会随 embed 重建，旧快照立即失效。
    _dropIndexRepo(repoKey);
    for (final String path in deleted) {
      await _deleteFile(store, state, path);
    }
    state.pendingFiles = pending
        .where(_isCandidatePath)
        .toSet()
        .toList()
      ..sort();
    state.filesTotal = state.pendingFiles.length;
    final DedupEmbedCall? embedCall = embed;
    if (config.model.isEmpty) {
      final DedupEmbedReply probe = embedCall == null
          ? const DedupEmbedReply(error: 'embed 通道不可用', code: 'embed_unavailable')
          : await embedCall(const DedupEmbedRequest(inputs: <String>[]));
      if (probe.ok && probe.model.isNotEmpty && probe.dimensions > 0) {
        state.model = probe.model;
        state.dimensions = probe.dimensions;
      } else {
        state.unavailable = true;
        state.degraded = true;
        state.reasons.add(
          probe.code == 'no_embedding_model'
              ? '没有可用的 embedding 模型：仅 FNV 精确去重可用'
              : 'embedding 探测失败：${probe.error}',
        );
      }
    } else {
      final DedupEmbedReply probe = embedCall == null
          ? const DedupEmbedReply(error: 'embed 通道不可用', code: 'embed_unavailable')
          : await embedCall(
              DedupEmbedRequest(inputs: <String>[], model: config.model),
            );
      if (probe.ok && probe.model.isNotEmpty && probe.dimensions > 0) {
        state.model = probe.model;
        state.dimensions = probe.dimensions;
      } else {
        state.unavailable = true;
        state.degraded = true;
        state.reasons.add(
          probe.code == 'no_embedding_model'
              ? '没有可用的 embedding 模型：仅 FNV 精确去重可用'
              : 'embedding 探测失败：${probe.error}',
        );
      }
    }
    return state;
  }

  Future<GitDelta> _deltaOrFull(CodeGit git, String baseline) async {
    if (baseline.isEmpty) return git.deltaSince('');
    try {
      return await git.deltaSince(baseline);
    } on ProductionFailure catch (error) {
      if (error.code != 'git_unavailable') rethrow;
      return git.deltaSince('');
    }
  }

  /// plan：读文件 → 分块 → 与旧 chunk 求差 → 写文件/chunk 记录。
  Future<void> _scanFiles(
    _DedupState state,
    DedupStore store,
    int budget,
  ) async {
    int processed = 0;
    while (state.pendingFiles.isNotEmpty && processed < budget) {
      final String relative = state.pendingFiles.removeAt(0);
      final File file = File(
        p.joinAll(<String>[state.workspace, ...relative.split('/')]),
      );
      processed += 1;
      try {
        if (!file.existsSync()) {
          await _deleteFile(store, state, relative);
          state.filesDone += 1;
          continue;
        }
        final int bytes = file.lengthSync();
        if (bytes > state.maxFileBytes) {
          state.reasons.add('跳过超限文件（$bytes bytes）：$relative');
          state.filesDone += 1;
          continue;
        }
        final List<int> raw = file.readAsBytesSync();
        if (raw.contains(0)) {
          state.reasons.add('跳过二进制文件：$relative');
          state.filesDone += 1;
          continue;
        }
        final String content = utf8.decode(raw, allowMalformed: true);
        final List<CodeChunk> chunks = chunkFile(relative, content);
        final String fileKey = '${state.repoKey}#file:$relative';
        final Map<String, Object?>? oldFile = await store.get(
          'dedup_files',
          fileKey,
        );
        final List<String> oldIds = <String>[
          for (final Object? id in (oldFile?['chunk_ids'] as List<Object?>? ??
              const <Object?>[]))
            if (id is String) id,
        ];
        final List<String> newIds = <String>[for (final CodeChunk c in chunks) c.id];
        final Set<String> removed = oldIds.toSet().difference(newIds.toSet());
        final Set<String> added = newIds.toSet().difference(oldIds.toSet());
        final List<Map<String, Object?>> ops = <Map<String, Object?>>[];
        for (final String id in removed) {
          ops.addAll(<Map<String, Object?>>[
            <String, Object?>{
              'op': 'delete',
              'collection': 'dedup_chunks',
              'key': '${state.repoKey}#chunk:$id',
            },
            <String, Object?>{
              'op': 'delete',
              'collection': 'dedup_results',
              'key': '${state.repoKey}#result:$id',
            },
          ]);
        }
        for (final CodeChunk chunk in chunks) {
          final bool needsRecord = added.contains(chunk.id);
          if (!needsRecord && state.baseSha.isNotEmpty) continue;
          final String vecKey = state.model.isEmpty
              ? ''
              : _vecKey(state, chunk.hash);
          if (needsRecord) {
            ops.add(<String, Object?>{
              'op': 'put',
              'collection': 'dedup_chunks',
              'key': '${state.repoKey}#chunk:${chunk.id}',
              'value': <String, Object?>{
                ...chunk.toJson(state.repoKey),
                'vec_key': vecKey,
                'vector_ok': false,
                'pipeline_version': kDedupPipelineVersion,
              },
            });
          }
          if (!state.unavailable) state.embedQueue.add(chunk.id);
        }
        ops.add(<String, Object?>{
          'op': 'put',
          'collection': 'dedup_files',
          'key': fileKey,
          'value': <String, Object?>{
            'schema': 1,
            'repo': state.repoKey,
            'path': relative,
            'content_hash': fnv1aHex(content),
            'bytes': bytes,
            'chunker_version': kChunkerVersion,
            'chunk_ids': newIds,
          },
        });
        if (ops.isNotEmpty) await store.tx(ops);
        state.filesDone += 1;
      } catch (error) {
        state.reasons.add('处理失败（$relative）：$error');
        state.degraded = true;
        state.filesDone += 1;
      }
    }
  }

  /// embed：缓存全字节命中则复用；未命中才请求（单请求最多 2 批）。
  Future<void> _embedChunks(
    _DedupState state,
    DedupStore store,
    DedupConfig config,
  ) async {
    final Map<String, Map<String, Object?>> vectors = <String, Map<String, Object?>>{
      for (final StoredRecord record
          in await store.listAll('dedup_vectors', '${state.repoKey}#vec:'))
        textOf(record.value['vec_key']): record.value,
    };
    int calls = 0;
    while (state.embedQueue.isNotEmpty && calls < 2) {
      final int take = state.embedQueue.length <= config.embedBatch
          ? state.embedQueue.length
          : config.embedBatch;
      final List<String> ids = state.embedQueue.sublist(0, take);
      final List<Map<String, Object?>> pending = <Map<String, Object?>>[];
      final List<Map<String, Object?>> pendingOps = <Map<String, Object?>>[];
      for (final String id in ids) {
        final String key = '${state.repoKey}#chunk:$id';
        final Map<String, Object?>? record = await store.get('dedup_chunks', key);
        if (record == null) continue;
        final String vecKey = textOf(record['vec_key']);
        if (record['vector_ok'] == true || vectors.containsKey(vecKey)) {
          state.reused += 1;
          state.compareQueue.add(id);
          if (record['vector_ok'] != true && vecKey.isNotEmpty) {
            pendingOps.add(<String, Object?>{
              'op': 'put',
              'collection': 'dedup_chunks',
              'key': key,
              'value': <String, Object?>{...record, 'vector_ok': true},
            });
          }
          continue;
        }
        final String text = '${record['text'] ?? ''}';
        if (text.trim().isEmpty) {
          continue;
        }
        pending.add(record);
      }
      state.embedQueue.removeRange(0, ids.length);
      state.compareQueue.addAll(<String>[
        for (final Map<String, Object?> record in pending) textOf(record['id']),
      ]);
      if (pendingOps.isNotEmpty) {
        await store.tx(pendingOps);
        for (final Map<String, Object?> op in pendingOps) {
          final Map<String, Object?> value =
              (op['value'] as Map).cast<String, Object?>();
          vectors[textOf(value['vec_key'])] = value;
        }
      }
      if (pending.isEmpty) continue;
      calls += 1;
      final DedupEmbedReply reply = await embed!(
        DedupEmbedRequest(
          inputs: <String>[
            for (final Map<String, Object?> record in pending)
              '${config.instructionPrefix}${record['text'] ?? ''}',
          ],
          model: state.model,
        ),
      );
      if (!reply.ok) {
        state.degraded = true;
        state.reasons.add('embedding 失败：${reply.error}');
        state.embedQueue.insertAll(0, <String>[
          for (final Map<String, Object?> record in pending) textOf(record['id']),
        ]);
        state.compareQueue.removeWhere(
          (String id) => pending.any(
            (Map<String, Object?> record) => textOf(record['id']) == id,
          ),
        );
        return;
      }
      if (reply.vectors.length != pending.length ||
          reply.dimensions != state.dimensions) {
        state.degraded = true;
        state.reasons.add(
          'embedding 回包不匹配：请求 ${pending.length} 条，'
          '返回 ${reply.vectors.length} 条 / 维度 ${reply.dimensions}',
        );
        state.embedQueue.insertAll(0, <String>[
          for (final Map<String, Object?> record in pending) textOf(record['id']),
        ]);
        state.compareQueue.removeWhere(
          (String id) => pending.any(
            (Map<String, Object?> record) => textOf(record['id']) == id,
          ),
        );
        return;
      }
      final List<Map<String, Object?>> ops = <Map<String, Object?>>[];
      for (int i = 0; i < pending.length; i++) {
        final Map<String, Object?> record = pending[i];
        final String id = textOf(record['id']);
        final String vecKey = textOf(record['vec_key']);
        final List<double> vector = config.normalize == 'l2'
            ? normalizeVector(reply.vectors[i]).toList()
            : reply.vectors[i];
        ops.add(<String, Object?>{
          'op': 'put',
          'collection': 'dedup_vectors',
          'key': '${state.repoKey}#vec:$vecKey',
          'value': <String, Object?>{
            'schema': 1,
            'repo': state.repoKey,
            'vec_key': vecKey,
            'content_hash': textOf(record['hash']),
            'model': state.model,
            'dimensions': state.dimensions,
            'seed': kDedupSeed,
            'normalize': config.normalize,
            'pooling': config.pooling,
            'instruction_prefix': config.instructionPrefix,
            'embed_settings_hash': config.embedSettingsHash,
            'pipeline_version': kDedupPipelineVersion,
            'vector': vector,
          },
        });
        ops.add(<String, Object?>{
          'op': 'put',
          'collection': 'dedup_chunks',
          'key': '${state.repoKey}#chunk:$id',
          'value': <String, Object?>{...record, 'vector_ok': true},
        });
        vectors[vecKey] = <String, Object?>{'vector': vector};
      }
      await store.tx(ops);
      state.embedded += pending.length;
      // 索引里新增了向量：已缓存的快照不再完整，下一轮 compare 重新构建。
      if (pending.isNotEmpty) _dropIndexRun(state.repoKey, state.runId);
    }
  }

  /// compare：新/变更 chunk 与全库索引做 top-k。
  ///
  /// 索引按 `repoKey|runId` 常驻内存：一个 run 内向量在 compare 前已写完，
  /// 后续每批不必重新翻 storage、重新解析 JSON；
  /// 只做归一化点积 + 哈希直达，按源块定期让出事件循环（保心跳）。
  Future<void> _compareChunks(
    _DedupState state,
    DedupStore store,
    DedupConfig config,
  ) async {
    if (state.compareQueue.isEmpty) return;
    final String cacheKey = _indexCacheKey(state.repoKey, state.runId);
    _DedupIndex? index = _indexCache[cacheKey];
    if (index == null) {
      index = await _buildIndex(state, store, config);
      _indexCache[cacheKey] = index;
    }
    if (index.truncated) {
      state.reasons.add('索引块数达到上限 ${config.maxIndexChunks}，只比较前 N 块');
      state.degraded = true;
    }

    final int take = state.compareQueue.length <= config.comparePerRequest
        ? state.compareQueue.length
        : config.comparePerRequest;
    final List<String> ids = state.compareQueue.sublist(0, take);
    final List<Map<String, Object?>> ops = <Map<String, Object?>>[];
    for (int i = 0; i < ids.length; i++) {
      final String id = ids[i];
      final DedupCandidate? chunk = index.byId[id];
      if (chunk == null) continue;
      final List<DedupMatch> matches = topMatches(
        selfId: id,
        selfPath: chunk.path,
        selfHash: chunk.hash,
        vector: chunk.vector,
        candidates: index.candidates,
        k: config.topK,
        threshold: config.threshold,
      );
      if (matches.isEmpty) continue;
      ops.add(<String, Object?>{
        'op': 'put',
        'collection': 'dedup_results',
        'key': '${state.repoKey}#result:$id',
        'value': <String, Object?>{
          'schema': 1,
          'repo': state.repoKey,
          'id': id,
          'path': chunk.path,
          'scope': chunk.scope,
          'matches': <Map<String, Object?>>[
            for (final DedupMatch match in matches) match.toJson(),
          ],
          'threshold': config.threshold,
          'model': state.model,
          'pipeline_version': kDedupPipelineVersion,
          'generated_at': _clock().toIso8601String(),
        },
      });
      state.compared += 1;
      state.pairs += matches.length;
      // 全库暴力比对是 CPU 密集：每 10 个源块让出一次事件循环，ping 才回得去。
      if (i % 10 == 9) await Future<void>.delayed(Duration.zero);
    }
    state.compareQueue.removeRange(0, ids.length);
    if (ops.isNotEmpty) await store.tx(ops);
  }

  /// 读一次 chunks + vectors，构造成可直接点积的内存索引。
  Future<_DedupIndex> _buildIndex(
    _DedupState state,
    DedupStore store,
    DedupConfig config,
  ) async {
    final List<StoredRecord> chunkRecords = await store.listAll(
      'dedup_chunks',
      '${state.repoKey}#chunk:',
    );
    // 按 chunk id 排序：上限截断与候选顺序都可复现。
    chunkRecords.sort(
      (StoredRecord a, StoredRecord b) =>
          textOf(a.value['id']).compareTo(textOf(b.value['id'])),
    );
    final Map<String, List<double>> vectors = <String, List<double>>{};
    for (final StoredRecord record
        in await store.listAll('dedup_vectors', '${state.repoKey}#vec:')) {
      final String vecKey = textOf(record.value['vec_key']);
      final Object? raw = record.value['vector'];
      if (vecKey.isEmpty || raw is! List) continue;
      final List<double> values = <double>[
        for (final Object? item in raw)
          if (item is num) item.toDouble(),
      ];
      if (values.isNotEmpty) vectors[vecKey] = values;
    }

    final List<DedupCandidate> candidates = <DedupCandidate>[];
    bool truncated = false;
    for (final StoredRecord record in chunkRecords) {
      final Map<String, Object?> chunk = record.value;
      if (chunk['vector_ok'] != true) continue;
      final List<double>? vector = vectors[textOf(chunk['vec_key'])];
      if (vector == null) continue;
      candidates.add(
        DedupCandidate(
          id: textOf(chunk['id']),
          path: textOf(chunk['path']),
          scope: textOf(chunk['scope']),
          hash: textOf(chunk['hash']),
          vector: normalizeToFloat32(vector),
        ),
      );
      if (candidates.length >= config.maxIndexChunks) {
        truncated = true;
        break;
      }
      // 大仓首次建索引也要让出事件循环，避免长时间阻塞心跳。
      if (candidates.length % 500 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    return _DedupIndex(
      candidates: candidates,
      byId: <String, DedupCandidate>{
        for (final DedupCandidate candidate in candidates)
          candidate.id: candidate,
      },
      truncated: truncated,
    );
  }

  Future<void> _finalize(
    _DedupState state,
    DedupStore store, {
    required String repoKey,
  }) async {
    _dropIndexRun(repoKey, state.runId);
    // 孤儿向量：先收集仍被 chunk 引用的 vec_key，再删未被引用的向量。
    final List<StoredRecord> chunks = await store.listAll(
      'dedup_chunks',
      '$repoKey#chunk:',
    );
    final Set<String> liveKeys = <String>{
      for (final StoredRecord record in chunks)
        if (textOf(record.value['vec_key']).isNotEmpty)
          textOf(record.value['vec_key']),
    };
    final List<Map<String, Object?>> ops = <Map<String, Object?>>[];
    for (final StoredRecord record
        in await store.listAll('dedup_vectors', '$repoKey#vec:')) {
      if (liveKeys.contains(textOf(record.value['vec_key']))) continue;
      ops.add(<String, Object?>{
        'op': 'delete',
        'collection': 'dedup_vectors',
        'key': record.key,
      });
    }
    final Set<String> liveChunkIds = <String>{
      for (final StoredRecord record in chunks) textOf(record.value['id']),
    };
    for (final StoredRecord record
        in await store.listAll('dedup_results', '$repoKey#result:')) {
      if (liveChunkIds.contains(textOf(record.value['id']))) continue;
      ops.add(<String, Object?>{
        'op': 'delete',
        'collection': 'dedup_results',
        'key': record.key,
      });
    }
    if (ops.isNotEmpty) await store.tx(ops);

    final List<StoredRecord> files = await store.listAll(
      'dedup_files',
      '$repoKey#file:',
    );
    final List<StoredRecord> results = await store.listAll(
      'dedup_results',
      '$repoKey#result:',
    );
    final Map<String, Object?> lastRun = <String, Object?>{
      'run_id': state.runId,
      'mode': state.mode,
      'head_sha': state.headSha,
      'base_sha': state.baseSha,
      'model': state.model,
      'dimensions': state.dimensions,
      'counts': <String, Object?>{
        'files': files.length,
        'chunks': chunks.length,
        'vectors': liveKeys.length,
        'results': results.length,
        'embedded': state.embedded,
        'reused': state.reused,
        'compared': state.compared,
        'pairs': state.pairs,
      },
      'degraded': state.degraded,
      'reasons': state.reasons,
      'finished_at': _clock().toIso8601String(),
    };
    final String baseline = state.degraded ? state.baseSha : state.headSha;
    await store.put('dedup_meta', '$repoKey#meta', <String, Object?>{
      'schema': 1,
      'repo': repoKey,
      'pipeline_version': kDedupPipelineVersion,
      'chunker_version': kChunkerVersion,
      'seed': kDedupSeed,
      'baseline_sha': baseline,
      'last_run': lastRun,
    });
  }

  Future<void> _deleteFile(
    DedupStore store,
    _DedupState state,
    String path,
  ) async {
    final String fileKey = '${state.repoKey}#file:$path';
    final Map<String, Object?>? file = await store.get('dedup_files', fileKey);
    final List<Map<String, Object?>> ops = <Map<String, Object?>>[];
    for (final Object? raw in (file?['chunk_ids'] as List<Object?>? ?? const [])) {
      if (raw is! String) continue;
      ops.add(<String, Object?>{
        'op': 'delete',
        'collection': 'dedup_chunks',
        'key': '${state.repoKey}#chunk:$raw',
      });
      ops.add(<String, Object?>{
        'op': 'delete',
        'collection': 'dedup_results',
        'key': '${state.repoKey}#result:$raw',
      });
    }
    ops.add(<String, Object?>{
      'op': 'delete',
      'collection': 'dedup_files',
      'key': fileKey,
    });
    await store.tx(ops);
  }

  String _vecKey(_DedupState state, String contentHash) =>
      'vec-${fnv1aHex('$contentHash\n${state.model}\n${state.dimensions}'
          '\n$kDedupPipelineVersion\n$kChunkerVersion\n$kDedupSeed')}';

  bool _isCandidatePath(String path) {
    final String ext = p.extension(path).replaceFirst('.', '').toLowerCase();
    return kDedupExtensions.contains(ext);
  }

  Map<String, Object?> _reply(_DedupState state, {required bool done}) {
    final int total = state.filesTotal == 0 ? 1 : state.filesTotal;
    final int percent = done
        ? 100
        : ((state.filesDone * 100) / total).round().clamp(0, 99);
    return <String, Object?>{
      'command': 'production.dedup.run',
      'line_id': state.lineId,
      'run_id': state.runId,
      'repo_key': state.repoKey,
      'mode': state.unavailable ? 'unavailable' : state.mode,
      'done': done,
      'percent': percent,
      'progress': <String, Object?>{
        'done': done,
        'phase': _phaseOf(state),
        'files_total': state.filesTotal,
        'files_done': state.filesDone,
        'pending_files': state.pendingFiles.length,
        'embed_pending': state.embedQueue.length,
        'compare_pending': state.compareQueue.length,
        'chunks': state.embedded + state.reused,
        'embedded': state.embedded,
        'reused': state.reused,
        'compared': state.compared,
        'pairs': state.pairs,
      },
      'model': state.model,
      'dimensions': state.dimensions,
      'degraded': state.degraded,
      'reasons': state.reasons,
    };
  }

  String _phaseOf(_DedupState state) {
    if (state.pendingFiles.isNotEmpty) return 'scan';
    if (state.embedQueue.isNotEmpty) return 'embed';
    if (state.compareQueue.isNotEmpty) return 'compare';
    return 'finalize';
  }

  _DedupState? _loadState(String path, String workspace) {
    final File file = File(path);
    if (!file.existsSync()) return null;
    try {
      final Object? raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map) return null;
      final Map<String, Object?> map = <String, Object?>{
        for (final MapEntry<Object?, Object?> entry in raw.entries)
          '${entry.key}': entry.value,
      };
      if (intOf(map['version'], 0) != kDedupStateVersion) return null;
      if (textOf(map['workspace']) != workspace) return null;
      return _DedupState.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  void _saveState(String path, _DedupState state) {
    final File file = File(path);
    final File tmp = File('$path.tmp');
    tmp.writeAsStringSync(jsonEncode(state.toJson()), flush: true);
    if (file.existsSync()) file.deleteSync();
    tmp.renameSync(path);
  }

  void _deleteState(String path) {
    final File file = File(path);
    if (file.existsSync()) file.deleteSync();
  }

  bool _acquireLock(String path) {
    final File lock = File(path);
    try {
      lock.createSync(exclusive: true);
      return true;
    } on FileSystemException {
      try {
        if (lock.existsSync() &&
            _clock().difference(lock.lastModifiedSync()) >
                const Duration(minutes: 10)) {
          lock.deleteSync();
          lock.createSync(exclusive: true);
          return true;
        }
      } catch (_) {}
      return false;
    }
  }

  void _releaseLock(String path) {
    final File lock = File(path);
    try {
      if (lock.existsSync()) lock.deleteSync();
    } catch (_) {}
  }

  String _argument(Map<String, Object?> arguments, String key) {
    final String value = textOf(arguments[key]);
    if (value.isEmpty) {
      throw ProductionFailure('缺少 $key', code: 'invalid_arguments');
    }
    return value;
  }

  static String _repoKeyOf(String workspace) {
    final String normalized = p
        .canonicalize(p.absolute(workspace))
        .replaceAll('\\', '/')
        .toLowerCase();
    return 'r-${fnv1aHex(normalized)}';
  }
}

class _DedupState {
  _DedupState({
    required this.workspace,
    required this.repoKey,
    required this.lineId,
    required this.runId,
    required this.headSha,
    required this.baseSha,
    required this.mode,
    required this.startedAt,
    required this.filesPerRun,
  });

  final String workspace;
  final String repoKey;
  final String lineId;
  final String runId;
  final String headSha;
  final String baseSha;
  final String mode;
  final String startedAt;
  final int filesPerRun;

  List<String> pendingFiles = <String>[];
  final List<String> embedQueue = <String>[];
  final List<String> compareQueue = <String>[];
  final List<String> reasons = <String>[];

  int filesTotal = 0;
  int filesDone = 0;
  int embedded = 0;
  int reused = 0;
  int compared = 0;
  int pairs = 0;
  int maxFileBytes = 262144;
  String model = '';
  int dimensions = 0;
  bool unavailable = false;
  bool degraded = false;

  bool get done =>
      pendingFiles.isEmpty && embedQueue.isEmpty && compareQueue.isEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': kDedupStateVersion,
    'workspace': workspace,
    'repo_key': repoKey,
    'line_id': lineId,
    'run_id': runId,
    'head_sha': headSha,
    'base_sha': baseSha,
    'mode': mode,
    'started_at': startedAt,
    'files_per_run': filesPerRun,
    'pending_files': pendingFiles,
    'embed_queue': embedQueue,
    'compare_queue': compareQueue,
    'reasons': reasons,
    'files_total': filesTotal,
    'files_done': filesDone,
    'embedded': embedded,
    'reused': reused,
    'compared': compared,
    'pairs': pairs,
    'max_file_bytes': maxFileBytes,
    'model': model,
    'dimensions': dimensions,
    'unavailable': unavailable,
    'degraded': degraded,
  };

  static _DedupState fromJson(Map<String, Object?> map) {
    final _DedupState state = _DedupState(
      workspace: textOf(map['workspace']),
      repoKey: textOf(map['repo_key']),
      lineId: textOf(map['line_id']),
      runId: textOf(map['run_id']),
      headSha: textOf(map['head_sha']),
      baseSha: textOf(map['base_sha']),
      mode: textOf(map['mode']),
      startedAt: textOf(map['started_at']),
      filesPerRun: intOf(map['files_per_run'], 50),
    )
      ..filesTotal = intOf(map['files_total'], 0)
      ..filesDone = intOf(map['files_done'], 0)
      ..embedded = intOf(map['embedded'], 0)
      ..reused = intOf(map['reused'], 0)
      ..compared = intOf(map['compared'], 0)
      ..pairs = intOf(map['pairs'], 0)
      ..maxFileBytes = intOf(map['max_file_bytes'], 262144)
      ..model = textOf(map['model'])
      ..dimensions = intOf(map['dimensions'], 0)
      ..unavailable = map['unavailable'] == true
      ..degraded = map['degraded'] == true;
    state.pendingFiles.addAll(_strings(map['pending_files']));
    state.embedQueue.addAll(_strings(map['embed_queue']));
    state.compareQueue.addAll(_strings(map['compare_queue']));
    state.reasons.addAll(_strings(map['reasons']));
    return state;
  }

  static List<String> _strings(Object? raw) => <String>[
    if (raw is List)
      for (final Object? item in raw)
        if (item is String && item.isNotEmpty) item,
  ];
}
