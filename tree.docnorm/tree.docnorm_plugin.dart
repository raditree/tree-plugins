// tree.docnorm —— 文档归一化（DN-2：扫描 + 包图 + 六族适配层骨架）。
//
// 定位（docs/doc-normalization-recon.md §1/§5/§7）：
// - headless 插件，只读目标仓库，不修改代码/配置；
// - 暴露自建执行站命令 `docnorm.scan`（后续 DN-3+ 追加契约/计划/注入命令）；
// - 六族适配器：Dart / Python / Go / Rust / Node-TS(含 Vue) / Web-HTTP，未覆盖走 fallback；
// - 输出包图：包 id / root / 行数 / 子包 / 公开声明 / API 面 / 依赖；
// - 依赖纪律：不得 import 任何核心包。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tree_docnorm/tree_docnorm.dart';

import '../_kit/plugin_kit.dart';

const String kPluginId = 'tree.docnorm';
const String kDisplayName = 'Tree 文档归一化';
const String kVersion = '0.9.0';
const String kStationName = 'docnorm';
const List<String> kDocnormCommands = <String>[
  'docnorm.scan',
  'docnorm.contract',
  'docnorm.check',
  'docnorm.plan',
  'docnorm.generate',
  'docnorm.audit',
  'docnorm.baseline',
  'docnorm.reanalyze',
  'docnorm.commit',
  'docnorm.graph.build',
  'docnorm.export',
  'docnorm.query',
];

const String kStationReadme =
    '文档归一化：docnorm.scan 扫描目标仓库，返回包图（包/子包/行数/公开声明/API 面/依赖）；'
    'docnorm.contract 侦查文档契约（章节/索引/链接/CHANGELOG/门禁，规则按 内置→仓库自述 合成）；'
    'docnorm.check [--edges] 只跑 DocPolicy 四条检查；--edges 追加六类关联边检查'
    '（断链 / 孤儿 / 过期引用 / 未解析提及 / 跨包引用 / 术语冲突）；'
    'docnorm.plan 只读归集 git 内容变更并给出注入单元与 context_cap/stage_budget 两额度估计（stat-dirty 不产计划）；'
    'docnorm.generate 经 llm.call 为单元 README 生成缺失章节提案（三模式×三档、context_cap 闸、只补缺、失败即 degraded）；'
    'docnorm.audit [--commit] 产四类建议（reuse/split_size/split_function/api_boundary）并补全 pkg_index 的收束事实/quality/stale（阈值读策略，默认 dry-run）；'
    'docnorm.baseline [--commit] 建 L0（doc_contract/pkg_index/doc_state 入 tree.storage）并按提案只追加缺章节（默认 dry-run）；'
    'docnorm.reanalyze --changed 只重算受影响包；'
    'docnorm.commit [--commit] [--run-gates] 按 docs 域 / 最具体包 / unmatched 分批提交'
    '（风格探测；门禁默认只列，--run-gates 才执行且失败整批不提交；不 push / amend）；'
    'docnorm.graph.build [--commit] [rag] 默认只建三类确定性边（belongs_to / references / mentions），'
    'rag=true 追加 GraphRAG 索引（分块 / llm.call 抽取 / Leiden 社区 / 报告 / llm.embed 向量，'
    '无 embedding 时 mode=lexical）；docnorm.export [--commit] 把集合导成 .docnorm/export/*.jsonl '
    '（按 key 排序，可直接 diff）；docnorm.query --mode local|global|basic|hybrid|lexical '
    '只读检索（BM25 + cosine / 实体链接 1~2 跳 / 社区报告 reduce，默认 auto）。'
    '六族适配器 + fallback；对目标仓库只读，'
    '写盘仅追加且必须显式 commit；缺 tree.storage 时 fail-closed。';

/// 当前握手完成的插件服务（由 [_onReady] 填入），用于向 tree.storage 下站命令。
PluginKitServer? _activeServer;

/// 设置 schema 已在 `tree.settings` 的全局库（v2 `binding=plugin`）注册成功。
bool _settingsPluginReady = false;

/// 老版 `tree.settings`（只有 team 绑定）下已注册 schema 的团队。
final Set<String> _settingsTeams = <String>{};

/// 失败日志只打一次，避免每条命令都刷同一句。
bool _settingsFailureLogged = false;

/// 与 `.docnorm/config.json` 同名的六个可调参数（顺序即设置页字段顺序）。
const List<String> kDocnormSettingKeys = <String>[
  'stage_budget',
  'context_cap',
  'context_ratio',
  'full_code_ratio',
  'model_max_seqlen',
  'token_scale',
];

/// `tree.settings` 的设置 schema（D28 / K 系列）：预算 / 上下文 / 模型参数。
///
/// 键名与 `.docnorm/config.json` 完全一致；插件读取时按
/// `设置服务 > 环境变量 > config > 内置默认` 合并。
Map<String, Object?> docnormSettingsSchema() => <String, Object?>{
  'schema_version': 1,
  'groups': <Map<String, Object?>>[
    <String, Object?>{'id': 'budget', 'title': '预算', 'order': 10},
    <String, Object?>{'id': 'context', 'title': '上下文', 'order': 20},
    <String, Object?>{'id': 'model', 'title': '模型', 'order': 30},
  ],
  'fields': <Map<String, Object?>>[
    <String, Object?>{
      'key': 'stage_budget',
      'group': 'budget',
      'type': 'int',
      'title': '阶段预算',
      'default': 400000,
      'min': 1000,
      'max': 4000000,
      'help': '单个阶段的累计 token 上限，超出即停止并标 degraded。',
    },
    <String, Object?>{
      'key': 'context_cap',
      'group': 'context',
      'type': 'int',
      'title': '上下文上限',
      'default': 0,
      'min': 0,
      'max': 2000000,
      'help': '0 表示按模型上限自动计算；非 0 时与模型上限取较小值。',
    },
    <String, Object?>{
      'key': 'context_ratio',
      'group': 'context',
      'type': 'double',
      'title': '上下文占比',
      'default': 0.7,
      'min': 0.05,
      'max': 1.0,
      'help': 'context_cap = min(显式上限, 模型上限 × 本比例)。',
    },
    <String, Object?>{
      'key': 'full_code_ratio',
      'group': 'context',
      'type': 'double',
      'title': '全代码注入占比',
      'default': 0.7,
      'min': 0.05,
      'max': 1.0,
      'help': '单次注入全代码的估计上限 = context_cap × 本比例。',
    },
    <String, Object?>{
      'key': 'model_max_seqlen',
      'group': 'model',
      'type': 'int',
      'title': '模型单次上限',
      'default': 128000,
      'min': 1000,
      'max': 2000000,
      'help': '用于估算的模型最大序列长度（token）。',
    },
    <String, Object?>{
      'key': 'token_scale',
      'group': 'model',
      'type': 'double',
      'title': '字符/Token 比例',
      'default': 4.0,
      'min': 0.1,
      'max': 20.0,
      'help': '字符数换算 token 的比例，默认约 4 字符 / token。',
    },
  ],
};

/// 注册设置 schema：优先 v2 的全局库（`binding=plugin`，不按团队切碎）；
/// 老版 `tree.settings` 只认 team 绑定，退回按本次请求的 team 注册。
///
/// 返回实际可用的绑定（`plugin` / `team` / 空串=不可用）。设置不是业务数据，
/// 任何失败都只记一次日志，不阻断命令。
Future<String> _ensureSettingsSchema(Map<String, dynamic> scope) async {
  final PluginKitServer? server = _activeServer;
  if (server == null) return '';
  if (_settingsPluginReady) return 'plugin';
  final Map<String, Object?> schema = docnormSettingsSchema();
  try {
    await server.channel.command('settings.define', <String, dynamic>{
      'binding': 'plugin',
      'schema': schema,
    });
    _settingsPluginReady = true;
    return 'plugin';
  } catch (_) {
    // 老版服务会因缺 team_id 拒绝；继续走 team 绑定。
  }
  final String teamId = asString(scope['team_id']);
  if (teamId.isEmpty) return '';
  if (_settingsTeams.contains(teamId)) return 'team';
  try {
    await server.channel.command(
      'settings.define',
      <String, dynamic>{'schema': schema},
      '',
      scope,
    );
    _settingsTeams.add(teamId);
    return 'team';
  } catch (error) {
    if (!_settingsFailureLogged) {
      _settingsFailureLogged = true;
      server.channel.log('注册插件设置 schema 失败（不影响命令执行）：$error');
    }
    return '';
  }
}

/// 读设置覆盖值；设置服务不可用时 fail-open 到环境变量 / config。
///
/// 只回 `has_value=true` 的项，未覆盖的项交给 env / `.docnorm/config.json`，
/// 这样 `config.sources` 才能如实标出来源。
Future<Map<String, Object?>> _settingsOverrides(
  Map<String, dynamic> scope,
) async {
  final PluginKitServer? server = _activeServer;
  if (server == null) return const <String, Object?>{};
  final String binding = await _ensureSettingsSchema(scope);
  if (binding.isEmpty) return const <String, Object?>{};
  try {
    final Map<String, dynamic> payload = await server.channel.command(
      'settings.list',
      <String, dynamic>{if (binding == 'plugin') 'binding': 'plugin'},
      '',
      binding == 'plugin' ? const <String, dynamic>{} : scope,
    );
    final Map<String, dynamic> values = asMap(payload['values']);
    final Map<String, Object?> overrides = <String, Object?>{};
    for (final String key in kDocnormSettingKeys) {
      final Map<String, dynamic> view = asMap(values[key]);
      if (view['has_value'] == true && view['value'] != null) {
        overrides[key] = view['value'];
      }
    }
    return overrides;
  } catch (error) {
    if (!_settingsFailureLogged) {
      _settingsFailureLogged = true;
      server.channel.log('读取插件设置失败（退回 env/config）：$error');
    }
    return const <String, Object?>{};
  }
}

PluginKitServer buildServer({bool exitOnShutdown = true}) => PluginKitServer(
  channel: PluginChannel.stdio(kPluginId),
  pluginId: kPluginId,
  displayName: kDisplayName,
  onReady: _onReady,
  onRequest: handleRequest,
  exitOnShutdown: exitOnShutdown,
);

Future<void> _onReady(PluginKitServer server) async {
  _activeServer = server;
  server.channel.log('已上线：v$kVersion（tree.docnorm，DN-4~8）');
  try {
    final Map<String, dynamic> result = await server.channel.request(
      M.stationRegister,
      <String, dynamic>{
        'kind': 'execute',
        'name': kStationName,
        'description': '文档归一化扫描（docnorm.*）',
        'readme': kStationReadme,
        'commands': kDocnormCommands,
      },
    );
    server.channel.log(
      '自建执行站：${result['ok'] == true ? result['station_id'] : result['error']}',
    );
  } catch (error) {
    server.channel.log('自建执行站失败：$error');
  }
  // 启动即注册设置 schema（v2 全局库；老版服务等第一条带 team 的命令再注册）。
  await _ensureSettingsSchema(const <String, dynamic>{});
}

Future<Map<String, dynamic>?> handleRequest(
  String method,
  Map<String, dynamic> params,
) async {
  if (method != M.stationRequest) return null;
  final Map<String, dynamic> payload = asMap(params['payload']);
  final String command = asString(payload['command']);
  if (!kDocnormCommands.contains(command)) return null;
  final Map<String, dynamic> arguments = asMap(payload['arguments']);
  try {
    final String repo = asString(arguments['repo']);
    if (repo.isEmpty) {
      return <String, dynamic>{
        'reply': <String, dynamic>{
          'error': '$command 需要 repo（目标仓库路径）',
          'code': 'invalid_arguments',
        },
      };
    }
    // 任何命令都顺带确保设置 schema 已注册（启动时可能 tree.settings 还没上线）。
    await _ensureSettingsSchema(asMap(params['scope']));
    if (command == 'docnorm.scan') {
      final ScanResult result = await scanRepository(repo);
      return <String, dynamic>{
        'reply': <String, dynamic>{'payload': result.toJson()},
      };
    }
    if (command == 'docnorm.plan') {
      final Map<String, Object?> settings = await _settingsOverrides(
        asMap(params['scope']),
      );
      final Map<String, Object?> result = await runPlan(
        repo,
        mode: asString(arguments['mode']),
        settings: settings,
        overrides: arguments['config'] is Map
            ? asMap(arguments['config'])
            : const <String, Object?>{},
      );
      return <String, dynamic>{
        'reply': <String, dynamic>{'payload': result},
      };
    }
    if (command == 'docnorm.generate') {
      final Map<String, dynamic> scope = asMap(params['scope']);
      final Map<String, Object?> settings = await _settingsOverrides(scope);
      Future<GenerateReply> llm(GenerateRequest request) =>
          _callLlm(request, scope);
      final Map<String, Object?> result = await runGenerate(
        repo,
        llm: llm,
        mode: asString(arguments['mode']),
        tier: asString(arguments['tier']),
        settings: settings,
        overrides: arguments['config'] is Map
            ? asMap(arguments['config'])
            : const <String, Object?>{},
      );
      return <String, dynamic>{
        'reply': <String, dynamic>{'payload': result},
      };
    }
    if (command == 'docnorm.audit') {
      final Map<String, dynamic> scope = asMap(params['scope']);
      Future<Map<String, dynamic>> storage(
        String name,
        Map<String, dynamic> args,
      ) => _callStorage(name, args, scope);
      final Map<String, Object?> result = await runAudit(
        repo,
        storage: storage,
        commit: arguments['commit'] == true,
        runId: asString(arguments['run_id']),
      );
      return <String, dynamic>{
        'reply': <String, dynamic>{'payload': result},
      };
    }
    if (command == 'docnorm.commit') {
      final Map<String, Object?> result = await runCommit(
        repo,
        commit: arguments['commit'] == true,
        runGates: arguments['run_gates'] == true,
      );
      return <String, dynamic>{
        'reply': <String, dynamic>{'payload': result},
      };
    }
    if (command == 'docnorm.graph.build') {
      final Map<String, dynamic> scope = asMap(params['scope']);
      final Map<String, Object?> settings = await _settingsOverrides(scope);
      Future<Map<String, dynamic>> storage(
        String name,
        Map<String, dynamic> args,
      ) => _callStorage(name, args, scope);
      Future<GenerateReply> llm(GenerateRequest request) =>
          _callLlm(request, scope);
      Future<RagEmbedReply> embed(RagEmbedRequest request) =>
          _callEmbed(request, scope);
      final Map<String, Object?> result = await runGraphBuild(
        repo,
        storage: storage,
        commit: arguments['commit'] == true,
        runId: asString(arguments['run_id']),
        rag: arguments['rag'] == true,
        llm: llm,
        embed: embed,
        settings: settings,
        overrides: arguments['config'] is Map
            ? asMap(arguments['config'])
            : const <String, Object?>{},
        embeddingModel: asString(arguments['embedding_model']),
      );
      return <String, dynamic>{
        'reply': <String, dynamic>{'payload': result},
      };
    }
    if (command == 'docnorm.export') {
      final Map<String, dynamic> scope = asMap(params['scope']);
      Future<Map<String, dynamic>> storage(
        String name,
        Map<String, dynamic> args,
      ) => _callStorage(name, args, scope);
      final Map<String, Object?> result = await runExport(
        repo,
        storage: storage,
        commit: arguments['commit'] == true,
        runId: asString(arguments['run_id']),
        collections: _stringsOf(arguments['collections']),
      );
      return <String, dynamic>{
        'reply': <String, dynamic>{'payload': result},
      };
    }
    if (command == 'docnorm.query') {
      final Map<String, dynamic> scope = asMap(params['scope']);
      Future<Map<String, dynamic>> storage(
        String name,
        Map<String, dynamic> args,
      ) => _callStorage(name, args, scope);
      Future<RagEmbedReply> embed(RagEmbedRequest request) =>
          _callEmbed(request, scope);
      final Map<String, Object?> result = await runQuery(
        repo,
        storage: storage,
        question: asString(arguments['question']),
        mode: asString(arguments['mode']),
        topK: (arguments['top_k'] as num?)?.toInt() ?? 0,
        embed: embed,
        embeddingModel: asString(arguments['embedding_model']),
      );
      return <String, dynamic>{
        'reply': <String, dynamic>{'payload': result},
      };
    }
    if (command == 'docnorm.baseline' || command == 'docnorm.reanalyze') {
      final Map<String, dynamic> scope = asMap(params['scope']);
      Future<Map<String, dynamic>> storage(
        String name,
        Map<String, dynamic> args,
      ) => _callStorage(name, args, scope);
      final Map<String, Object?> result = command == 'docnorm.baseline'
          ? await runBaseline(
              repo,
              storage: storage,
              commit: arguments['commit'] == true,
              sections: _mapsOf(arguments['sections']),
              indexes: _mapsOf(arguments['indexes']),
              rewriteAllowlist: _stringsOf(arguments['rewrite_allowlist']),
              runId: asString(arguments['run_id']),
            )
          : await runReanalyze(
              repo,
              storage: storage,
              changed: arguments['changed'] == true,
              commit: arguments['commit'] == true,
              sections: _mapsOf(arguments['sections']),
              indexes: _mapsOf(arguments['indexes']),
              rewriteAllowlist: _stringsOf(arguments['rewrite_allowlist']),
              runId: asString(arguments['run_id']),
            );
      return <String, dynamic>{
        'reply': <String, dynamic>{'payload': result},
      };
    }
    final DocContract contract = await inspectRepository(
      repo,
      rulesPackage: arguments['rules'] is Map
          ? asMap(arguments['rules'])
          : null,
    );
    if (command == 'docnorm.contract') {
      return <String, dynamic>{
        'reply': <String, dynamic>{'payload': contract.toJson()},
      };
    }
    // docnorm.check：只回检查面，不重复契约明细；--edges 追加六类关联边检查。
    final Map<String, dynamic> checkPayload = <String, dynamic>{
      'repo': contract.repo,
      'ok': contract.ok,
      'rules': contract.policy.toJson(),
      'checks': contract.checks.map((DocCheck item) => item.toJson()).toList(),
      'violations': contract.violations
          .map((DocViolation item) => item.toJson())
          .toList(),
      'unknown': contract.unknown,
      'degraded': contract.degraded,
    };
    if (arguments['edges'] == true) {
      final Map<String, dynamic> scope = asMap(params['scope']);
      Future<Map<String, dynamic>> storage(
        String name,
        Map<String, dynamic> args,
      ) => _callStorage(name, args, scope);
      final Map<String, Object?> edgeChecks = await runEdgeChecks(
        repo,
        storage: storage,
        contract: contract,
      );
      checkPayload['edges'] = edgeChecks;
      if (edgeChecks['code'] == 'graph_required') {
        checkPayload['degraded'] = true;
      }
    }
    return <String, dynamic>{
      'reply': <String, dynamic>{'payload': checkPayload},
    };
  } on BaselineFailure catch (error) {
    return <String, dynamic>{
      'reply': <String, dynamic>{'error': error.message, 'code': error.code},
    };
  } on PlanFailure catch (error) {
    return <String, dynamic>{
      'reply': <String, dynamic>{'error': error.message, 'code': error.code},
    };
  } on PolicyFailure catch (error) {
    return <String, dynamic>{
      'reply': <String, dynamic>{'error': error.message, 'code': error.code},
    };
  } on ScanFailure catch (error) {
    return <String, dynamic>{
      'reply': <String, dynamic>{'error': error.message, 'code': error.code},
    };
  } catch (error) {
    return <String, dynamic>{
      'reply': <String, dynamic>{'error': '扫描失败：$error', 'code': 'scan_error'},
    };
  }
}

/// 向 `tree.storage` 下一条站命令：身份 / 团队只透传核心给本次请求的 scope。
///
/// 缺失时由存储侧拒绝（`identity_required` / `team_required`），这里收敛成
/// `storage_unavailable`，让 baseline 在写盘前 fail-closed（TC-ST-10）。
Future<Map<String, dynamic>> _callStorage(
  String command,
  Map<String, dynamic> arguments,
  Map<String, dynamic> scope,
) {
  final PluginKitServer? server = _activeServer;
  if (server == null) {
    throw BaselineFailure(
      '插件尚未就绪：tree.storage 通道不可用',
      code: 'storage_unavailable',
    );
  }
  return server.channel.command(command, arguments, '', scope);
}

/// 向 `tree.agent` 的宿主能力站下 `llm.call`：身份 / 团队只透传本次请求的 scope。
///
/// 失败也把已付费的 `text` / `json` 带回 [GenerateReply]（known-issues #31），
/// 由生成层统一判成 `degraded`，绝不用占位正文补齐。
Future<GenerateReply> _callLlm(
  GenerateRequest request,
  Map<String, dynamic> scope,
) async {
  final PluginKitServer? server = _activeServer;
  if (server == null) {
    return const GenerateReply(error: '插件尚未就绪：llm.call 通道不可用');
  }
  try {
    final Map<String, dynamic> payload = await server.channel.command(
      'llm.call',
      <String, dynamic>{
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'system', 'content': request.system},
          <String, dynamic>{'role': 'user', 'content': request.prompt},
        ],
      },
      '',
      scope,
    );
    final String reason = asString(payload['error']);
    return GenerateReply(
      text: asString(payload['text']),
      json: payload['json'],
      error: reason.trim().isNotEmpty
          ? reason
          : (payload['ok'] == false ? 'llm.call 返回 ok:false' : ''),
    );
  } on CmdFailureException catch (error) {
    return GenerateReply(
      text: asString(error.payload['text']),
      json: error.payload['json'],
      error: error.message,
    );
  } catch (error) {
    return GenerateReply(error: 'llm.call 异常：$error');
  }
}

/// 向 `tree.agent` 的宿主能力站下 `llm.embed`：模型池 kind=embedding。
///
/// 空 `inputs` 不发 HTTP，只回模型与维度（用于建索引前判断是否降级 lexical）。
Future<RagEmbedReply> _callEmbed(
  RagEmbedRequest request,
  Map<String, dynamic> scope,
) async {
  final PluginKitServer? server = _activeServer;
  if (server == null) {
    return const RagEmbedReply(
      error: '插件尚未就绪：llm.embed 通道不可用',
      code: 'embed_unavailable',
    );
  }
  try {
    final Map<String, dynamic> payload = await server.channel.command(
      'llm.embed',
      <String, dynamic>{
        'inputs': request.inputs,
        if (request.model.isNotEmpty) 'model': request.model,
      },
      '',
      scope,
    );
    final String reason = asString(payload['error']);
    return RagEmbedReply(
      vectors: _vectorsOf(payload['vectors']),
      model: asString(payload['model']),
      dimensions: (payload['dimensions'] as num?)?.toInt() ?? 0,
      error: reason,
      code: asString(payload['code']),
    );
  } on CmdFailureException catch (error) {
    return RagEmbedReply(
      vectors: _vectorsOf(error.payload['vectors']),
      model: asString(error.payload['model']),
      dimensions: (error.payload['dimensions'] as num?)?.toInt() ?? 0,
      error: error.message,
      code: asString(error.payload['code']),
    );
  } catch (error) {
    return RagEmbedReply(error: 'llm.embed 异常：$error');
  }
}

List<List<double>> _vectorsOf(Object? raw) {
  if (raw is! List) return const <List<double>>[];
  return <List<double>>[
    for (final Object? row in raw)
      if (row is List)
        <double>[
          for (final Object? value in row)
            if (value is num) value.toDouble(),
        ],
  ];
}

List<Map<String, Object?>> _mapsOf(Object? value) {
  if (value is! List) return const <Map<String, Object?>>[];
  return <Map<String, Object?>>[
    for (final Object? item in value)
      if (item is Map) asMap(item),
  ];
}

List<String> _stringsOf(Object? value) {
  if (value is! List) return const <String>[];
  return <String>[
    for (final Object? item in value)
      if (asString(item).isNotEmpty) asString(item),
  ];
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

/// 假核心自检：注册面 + 六族扫描 + 命令回包。
Future<int> selfTest() async {
  final SelfTest check = SelfTest(name: 'tree_docnorm_plugin');
  final Directory temp = Directory.systemTemp.createTempSync(
    'tree_docnorm_selftest_',
  );
  final FakeCore core = FakeCore(buildServer(exitOnShutdown: false));
  core.onMethod(
    M.stationRegister,
    (Map<String, dynamic> params) => <String, dynamic>{
      'ok': true,
      'station_id': 'docnorm',
    },
  );

  void write(String path, String content) {
    final File file = File('${temp.path}${Platform.pathSeparator}$path');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  try {
    write('pubspec.yaml', 'name: demo_dart\ndependencies:\n  yaml: ^3.1.0\n');
    write('lib/a.dart', 'class Alpha {}\nclass Beta {}\n');
    write('lib/src/one.dart', 'class One {}\n');
    write('lib/src/two.dart', 'class Two {}\n');
    write('lib/src/three.dart', 'class Three {}\n');
    write(
      'package.json',
      '{"name":"demo_web","dependencies":{"vue":"^3.0.0"}}',
    );
    write('src/index.ts', 'export function boot() {}\n');
    write(
      'src/App.vue',
      '<script setup lang="ts">\nconst props = defineProps<{title: string}>()\n</script>\n',
    );
    write('go.mod', 'module example.com/demo\n\ngo 1.22\n');
    write(
      'main.go',
      'package main\n\ntype Server struct{}\n\nfunc Start() {}\n',
    );
    write('Cargo.toml', '[package]\nname = "demo_rust"\nversion = "0.1.0"\n');
    write('src/lib.rs', 'pub struct Config;\npub fn run() {}\n');
    write('pyproject.toml', '[project]\nname = "demo_py"\n');
    write('demo_py/mod.py', 'class Model:\n    pass\n\ndef run():\n    pass\n');
    write(
      'openapi.yaml',
      'openapi: 3.0.0\npaths:\n  /pets:\n    get: {}\n    post: {}\n',
    );
    write('api.http', 'GET /health\nPOST /login\n');
    write('README.md', '# demo\n');
    write('docs/README.md', '- [a.md](a.md)\n');
    write('docs/a.md', '# A\n');
    write('docnorm.yaml', '''
version: 1
required_docs:
  - README.md
  - docs/README.md
indexes:
  - dir: docs
    index: docs/README.md
thresholds:
  package_lines: 1
  file_lines: 1
''');

    bool gitOk = true;
    try {
      Process.runSync('git', <String>[
        'init',
        '--quiet',
      ], workingDirectory: temp.path);
      Process.runSync('git', <String>[
        'add',
        '-A',
      ], workingDirectory: temp.path);
      final ProcessResult committed = Process.runSync('git', <String>[
        '-c',
        'user.name=selftest',
        '-c',
        'user.email=selftest@local',
        'commit',
        '--quiet',
        '--no-gpg-sign',
        '-m',
        'fixture',
      ], workingDirectory: temp.path);
      gitOk = committed.exitCode == 0;
    } catch (_) {
      gitOk = false;
    }

    // 假 tree.storage：只实现 baseline 用到的只读/写入命令。
    final Map<String, Map<String, Map<String, Object?>>> fakeDb =
        <String, Map<String, Map<String, Object?>>>{};
    Map<String, Map<String, Object?>> collectionOf(String name) =>
        fakeDb.putIfAbsent(name, () => <String, Map<String, Object?>>{});
    int storageWrites = 0;
    int llmCalls = 0;
    int embedCalls = 0;
    // 假 tree.settings：记录 define 次数，list 只回有覆盖值的项。
    Map<String, dynamic>? settingsSchema;
    final Map<String, Object?> settingValues = <String, Object?>{
      'stage_budget': 300000,
    };
    int settingsDefines = 0;
    core.onMethod(M.stationCommand, (Map<String, dynamic> params) {
      final String command = asString(params['command']);
      final Map<String, dynamic> args = asMap(params['arguments']);
      final String collection = asString(args['collection']);
      final Map<String, Map<String, Object?>> records = collectionOf(
        collection,
      );
      switch (command) {
        case 'settings.define':
          settingsDefines += 1;
          settingsSchema = asMap(args['schema']);
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{
              'plugin_id': kPluginId,
              'schema_version': 1,
              'unchanged': false,
            },
          };
        case 'settings.list':
          final Map<String, Object?> defaults = <String, Object?>{
            for (final Object? raw
                in (settingsSchema?['fields'] as List<dynamic>? ?? <dynamic>[]))
              asString(asMap(raw)['key']): asMap(raw)['default'],
          };
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{
              'values': <String, Object?>{
                for (final MapEntry<String, Object?> entry in defaults.entries)
                  entry.key: <String, Object?>{
                    'value': settingValues[entry.key] ?? entry.value,
                    'has_value': settingValues.containsKey(entry.key),
                  },
              },
            },
          };
        case 'llm.call':
          llmCalls += 1;
          final List<dynamic> messages = args['messages'] is List
              ? args['messages'] as List<dynamic>
              : <dynamic>[];
          final String userText = messages.isEmpty
              ? ''
              : asString(asMap(messages.last)['content']);
          if (userText.contains('知识图谱抽取器')) {
            return <String, dynamic>{
              'ok': true,
              'payload': <String, dynamic>{
                'ok': true,
                'json': <String, dynamic>{
                  'entities': <Map<String, dynamic>>[
                    <String, dynamic>{'kind': 'concept', 'name': 'Alpha'},
                  ],
                  'relations': <Map<String, dynamic>>[],
                },
                'text': '{}',
                'model': 'fake',
                'usage': <String, dynamic>{'total_tokens': 8},
              },
            };
          }
          if (userText.contains('社区摘要')) {
            return <String, dynamic>{
              'ok': true,
              'payload': <String, dynamic>{
                'ok': true,
                'json': <String, dynamic>{
                  'title': '示例社区',
                  'summary': '这个社区围绕 Alpha 概念展开，包含文档与实体节点，边界清晰可检索。',
                },
                'text': '{}',
                'model': 'fake',
                'usage': <String, dynamic>{'total_tokens': 8},
              },
            };
          }
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{
              'ok': messages.isNotEmpty,
              'json': <String, dynamic>{
                'sections': <Map<String, dynamic>>[
                  <String, dynamic>{'heading': '职责', 'body': '示例包负责单一职责的演示。'},
                  <String, dynamic>{
                    'heading': '入口',
                    'body': '从 lib/a.dart 的 Alpha 进入。',
                  },
                  <String, dynamic>{
                    'heading': '边界',
                    'body': '不处理网络与持久化，只做类型定义。',
                  },
                  <String, dynamic>{
                    'heading': '测试',
                    'body': '运行 dart test 覆盖声明与边界。',
                  },
                ],
              },
              'text': '{}',
              'model': 'fake',
              'usage': <String, dynamic>{'total_tokens': 10},
            },
          };
        case 'llm.embed':
          embedCalls += 1;
          final List<dynamic> inputs = args['inputs'] is List
              ? args['inputs'] as List<dynamic>
              : <dynamic>[];
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{
              'ok': true,
              'model': 'fake-embed',
              'dimensions': 4,
              'count': inputs.length,
              'vectors': <List<double>>[
                for (int i = 0; i < inputs.length; i++)
                  <double>[1.0, 0.0, 0.0, 0.0],
              ],
              'usage': <String, dynamic>{'prompt_tokens': inputs.length},
            },
          };
        case 'storage.ensure':
          storageWrites += 1;
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{
              'collection': collection,
              'schema_version': args['schema_version'] ?? 1,
            },
          };
        case 'storage.scan':
          final String prefix = asString(args['prefix']);
          final List<Map<String, Object?>> values = <Map<String, Object?>>[
            for (final MapEntry<String, Map<String, Object?>> entry
                in records.entries)
              if (entry.key.startsWith(prefix))
                <String, Object?>{
                  'key': entry.key,
                  'value': entry.value,
                  'rev': 1,
                },
          ];
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{
              'values': values,
              'count': values.length,
            },
          };
        case 'storage.get':
          final Map<String, Object?>? value = records[asString(args['key'])];
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{
              'value': value,
              'rev': value == null ? 0 : 1,
            },
          };
        case 'storage.put':
          storageWrites += 1;
          records[asString(args['key'])] = Map<String, Object?>.from(
            asMap(args['value']),
          );
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{'rev': 1},
          };
        case 'storage.delete':
          storageWrites += 1;
          records.remove(asString(args['key']));
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{'deleted': true},
          };
        case 'storage.tx':
          storageWrites += 1;
          final List<dynamic> ops = args['ops'] is List
              ? args['ops'] as List<dynamic>
              : <dynamic>[];
          for (final Object? raw in ops) {
            if (raw is! Map) continue;
            final Map<String, dynamic> op = asMap(raw);
            final Map<String, Map<String, Object?>> target = collectionOf(
              asString(op['collection']),
            );
            if (asString(op['op']) == 'delete') {
              target.remove(asString(op['key']));
            } else {
              target[asString(op['key'])] = Map<String, Object?>.from(
                asMap(op['value']),
              );
            }
          }
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{
              'committed': true,
              'count': ops.length,
            },
          };
        default:
          return <String, dynamic>{
            'ok': false,
            'error': '未知存储命令：$command',
            'code': 'unknown_command',
          };
      }
    });

    final ScanResult result = await scanRepository(temp.path);
    check.that(
      result.packages.length >= 6,
      '六族适配器都扫出了包',
      actual: result.packages.map((PackageUnit p) => p.id).join(','),
    );
    check.that(
      result.adapters.toSet().containsAll(<String>[
        'dart',
        'node',
        'go',
        'rust',
        'python',
        'http',
      ]),
      '适配器命中：dart/node/go/rust/python/http',
      actual: result.adapters.join(','),
    );
    final PackageUnit dart = result.packages.firstWhere(
      (PackageUnit p) => p.language == 'dart',
    );
    check.check(dart.id, 'demo_dart', 'Dart 包名来自 pubspec');
    check.that(dart.exports.contains('Alpha'), 'Dart 公开声明被抽取');
    check.that(dart.subpackages.isNotEmpty, 'Dart 子包按文件数发现（lib/src）');
    final PackageUnit node = result.packages.firstWhere(
      (PackageUnit p) => p.language == 'node',
    );
    check.that(node.exports.contains('boot'), 'Node export 函数被抽取');
    check.that(node.exports.contains('title'), 'Vue defineProps 字段被抽取');
    final PackageUnit http = result.packages.firstWhere(
      (PackageUnit p) => p.language == 'http',
    );
    check.check(http.api.count, 4, 'HTTP 端点：OpenAPI 2 + .http 2');
    check.check(result.degraded, false, '六族齐全时 degraded=false');

    unawaited(core.start());
    core.ask('hello', M.hello, <String, dynamic>{'plugin_id': kPluginId});
    await core.waitFor(<Object?>['hello']);
    final List<Map<String, dynamic>> registrations = core.outgoing(
      M.stationRegister,
    );
    check.check(registrations.length, 1, '启动后注册一个自建执行站');
    check.check(
      asMap(registrations.first['params'])['kind'],
      'execute',
      '执行站 kind=execute',
    );

    core.ask('scan', M.stationRequest, <String, dynamic>{
      'payload': <String, dynamic>{
        'command': 'docnorm.scan',
        'arguments': <String, dynamic>{'repo': temp.path},
      },
      'meta': <String, dynamic>{'source_plugin_id': 'tree.production.line'},
      'scope': <String, dynamic>{'team_id': 'team_a'},
    });
    final Map<Object?, Map<String, dynamic>> responses = await core.waitFor(
      <Object?>['scan'],
    );
    final Map<String, dynamic> reply = asMap(
      asMap(responses['scan']?['result'])['reply'],
    );
    final Map<String, dynamic> payload = asMap(reply['payload']);
    check.that(
      (payload['packages'] as List<dynamic>?)?.isNotEmpty == true,
      '命令回包带 packages',
    );
    check.that(payload.containsKey('degraded'), '命令回包带 degraded');
    check.that(jsonEncode(payload).contains('demo_dart'), '命令回包包含 Dart 包');

    core.ask('contract', M.stationRequest, <String, dynamic>{
      'payload': <String, dynamic>{
        'command': 'docnorm.contract',
        'arguments': <String, dynamic>{'repo': temp.path},
      },
      'meta': <String, dynamic>{'source_plugin_id': 'tree.production.line'},
      'scope': <String, dynamic>{'team_id': 'team_a'},
    });
    final Map<String, dynamic> contractReply = asMap(
      asMap(
        (await core.waitFor(<Object?>['contract']))['contract']?['result'],
      )['reply'],
    );
    final Map<String, dynamic> contract = asMap(contractReply['payload']);
    check.check(contract['ok'], true, '契约侦查通过（README + docs 索引齐）');
    check.that(
      (contract['checks'] as List<dynamic>?)?.length == 6,
      '契约回包带 6 项检查（四条核心 + 模块/点名扩展）',
    );
    final Map<String, dynamic> rules = asMap(contract['rules']);
    check.that(
      (rules['layers'] as List<dynamic>?)?.contains('repo') == true,
      '规则层合并了仓库自述 docnorm.yaml',
    );
    check.check(rules['repo_files'], <dynamic>['docnorm.yaml'], '规则来源可追溯');

    core.ask('check', M.stationRequest, <String, dynamic>{
      'payload': <String, dynamic>{
        'command': 'docnorm.check',
        'arguments': <String, dynamic>{'repo': temp.path},
      },
      'meta': <String, dynamic>{'source_plugin_id': 'tree.production.line'},
      'scope': <String, dynamic>{'team_id': 'team_a'},
    });
    final Map<String, dynamic> checkReply = asMap(
      asMap(
        (await core.waitFor(<Object?>['check']))['check']?['result'],
      )['reply'],
    );
    final Map<String, dynamic> checkPayload = asMap(checkReply['payload']);
    check.check(checkPayload['ok'], true, 'docnorm.check 只回检查面且通过');
    check.that(
      !checkPayload.containsKey('sections'),
      'docnorm.check 不重复契约明细（无 sections）',
    );

    Future<Map<String, dynamic>> askCommand(
      Object id,
      String command,
      Map<String, dynamic> arguments,
    ) async {
      core.ask(id, M.stationRequest, <String, dynamic>{
        'payload': <String, dynamic>{
          'command': command,
          'arguments': arguments,
        },
        'meta': <String, dynamic>{'source_plugin_id': 'tree.production.line'},
        'scope': <String, dynamic>{'team_id': 'team_a'},
      });
      final Map<Object?, Map<String, dynamic>> responses = await core.waitFor(
        <Object?>[id],
      );
      return asMap(asMap(responses[id]?['result'])['reply']);
    }

    if (!gitOk) {
      check.that(true, 'git 不可用，跳过 baseline / reanalyze 自检');
    } else {
      final Map<String, dynamic> dryReply = await askCommand(
        'baseline-dry',
        'docnorm.baseline',
        <String, dynamic>{
          'repo': temp.path,
          'commit': false,
          'sections': <Map<String, dynamic>>[
            <String, dynamic>{
              'doc': 'README.md',
              'heading': '## 测试',
              'body': 'dart test',
            },
          ],
        },
      );
      final Map<String, dynamic> dryPayload = asMap(dryReply['payload']);
      check.check(dryPayload['dry_run'], true, 'baseline 默认 dry-run');
      check.check(
        (dryPayload['written'] as List<dynamic>?)?.isEmpty,
        true,
        'dry-run 不写目标仓库',
      );
      check.check(
        (dryPayload['would_write'] as List<dynamic>?)?.length,
        1,
        'dry-run 出 1 个落盘计划',
      );
      check.check(storageWrites, 0, 'dry-run 0 存储写');
      check.that(
        !File('${temp.path}${Platform.pathSeparator}README.md')
            .readAsStringSync()
            .contains('## 测试'),
        'dry-run 未追加章节',
      );

      final Map<String, dynamic> commitReply = await askCommand(
        'baseline-commit',
        'docnorm.baseline',
        <String, dynamic>{
          'repo': temp.path,
          'commit': true,
          'sections': <Map<String, dynamic>>[
            <String, dynamic>{
              'doc': 'README.md',
              'heading': '## 测试',
              'body': 'dart test',
            },
          ],
        },
      );
      final Map<String, dynamic> commitPayload = asMap(commitReply['payload']);
      check.that(
        (commitPayload['written'] as List<dynamic>?)?.contains('README.md') ==
            true,
        'baseline --commit 追章节',
      );
      check.that(
        File('${temp.path}${Platform.pathSeparator}README.md')
            .readAsStringSync()
            .contains('## 测试'),
        'README 落盘包含新章节',
      );
      check.that(
        (fakeDb['doc_contract'] ?? <String, Map<String, Object?>>{}).isNotEmpty,
        'doc_contract 入库',
      );
      check.that(
        (fakeDb['pkg_index'] ?? <String, Map<String, Object?>>{}).isNotEmpty,
        'pkg_index 入库',
      );
      check.that(
        (fakeDb['doc_state'] ?? <String, Map<String, Object?>>{}).isNotEmpty,
        'doc_state 入库',
      );
      final int writesAfterCommit = storageWrites;

      final Map<String, dynamic> againReply = await askCommand(
        'baseline-again',
        'docnorm.baseline',
        <String, dynamic>{
          'repo': temp.path,
          'commit': true,
          'sections': <Map<String, dynamic>>[
            <String, dynamic>{
              'doc': 'README.md',
              'heading': '## 测试',
              'body': 'dart test',
            },
          ],
        },
      );
      final Map<String, dynamic> againPayload = asMap(againReply['payload']);
      check.check(
        (againPayload['written'] as List<dynamic>?)?.length,
        0,
        '重复运行 0 文件写',
      );
      check.check(storageWrites, writesAfterCommit, '重复运行 0 存储写');

      final File source = File(
        '${temp.path}${Platform.pathSeparator}lib${Platform.pathSeparator}a.dart',
      );
      source.writeAsStringSync(
        'class Alpha {}\nclass Beta {}\nclass Gamma {}\n',
      );
      final Map<String, dynamic> reanalyzeReply = await askCommand(
        'reanalyze',
        'docnorm.reanalyze',
        <String, dynamic>{'repo': temp.path, 'changed': true, 'commit': true},
      );
      final Map<String, dynamic> reanalyzePayload = asMap(
        reanalyzeReply['payload'],
      );
      check.that(
        (reanalyzePayload['affected_packages'] as List<dynamic>?)?.isNotEmpty ==
            true,
        'reanalyze 命中受影响包',
      );
      check.that(
        (reanalyzePayload['recomputed'] as List<dynamic>?)?.isNotEmpty == true,
        'reanalyze 重算受影响包',
      );
      check.check(
        asMap(reanalyzePayload['storage'])['applied'],
        true,
        'reanalyze 写回状态',
      );

      final Map<String, dynamic> planReply = await askCommand(
        'plan',
        'docnorm.plan',
        <String, dynamic>{'repo': temp.path},
      );
      final Map<String, dynamic> planPayload = asMap(planReply['payload']);
      check.check(planPayload['dry_run'], true, 'plan 只读');
      check.that(
        (planPayload['units'] as List<dynamic>?)?.isNotEmpty == true,
        'plan 出注入单元',
      );
      check.that(
        (asMap(planPayload['budget'])['context_cap'] as num? ?? 0) > 0,
        'plan 给出 context_cap',
      );
      final Map<String, dynamic> planConfig = asMap(planPayload['config']);
      check.check(settingsDefines, 1, '启动时向 tree.settings 注册 schema');
      check.check(planConfig['stage_budget'], 300000, '设置服务覆盖内置默认值');
      check.that(
        (planConfig['sources'] as List<dynamic>? ?? <dynamic>[]).contains(
          'settings:stage_budget',
        ),
        'config.sources 标出设置服务来源',
      );

      final Map<String, dynamic> generateReply = await askCommand(
        'generate',
        'docnorm.generate',
        <String, dynamic>{'repo': temp.path},
      );
      final Map<String, dynamic> generatePayload = asMap(
        generateReply['payload'],
      );
      check.check(generatePayload['dry_run'], true, 'generate 只读');
      check.that(
        (generatePayload['sections'] as List<dynamic>?)?.isNotEmpty == true,
        'generate 出章节提案',
      );
      check.that(
        (asMap(generatePayload['budget'])['calls'] as num? ?? 0) > 0,
        'generate 经 llm.call 生成',
      );
      check.that(
        jsonEncode(generatePayload).contains('## 职责'),
        'generate 提案可喂 baseline（## 职责）',
      );

      final Map<String, dynamic> auditDryReply = await askCommand(
        'audit-dry',
        'docnorm.audit',
        <String, dynamic>{'repo': temp.path},
      );
      final Map<String, dynamic> auditDry = asMap(auditDryReply['payload']);
      check.check(auditDry['dry_run'], true, 'audit 默认 dry-run');
      check.that(
        (auditDry['packages'] as List<dynamic>?)?.isNotEmpty == true,
        'audit 出包收束事实',
      );
      check.that(
        (auditDry['suggestions'] as List<dynamic>?)?.isNotEmpty == true,
        'audit 按阈值 1 行产出建议',
      );
      final Map<String, dynamic> auditCommitReply = await askCommand(
        'audit-commit',
        'docnorm.audit',
        <String, dynamic>{'repo': temp.path, 'commit': true},
      );
      final Map<String, dynamic> auditCommit = asMap(
        auditCommitReply['payload'],
      );
      check.check(
        asMap(auditCommit['storage'])['applied'],
        true,
        'audit --commit 写 suggestions / pkg_index',
      );
      check.that(
        (fakeDb['suggestions'] ?? <String, Map<String, Object?>>{}).isNotEmpty,
        'suggestions 入库',
      );
      final Map<String, dynamic> auditAgainReply = await askCommand(
        'audit-again',
        'docnorm.audit',
        <String, dynamic>{'repo': temp.path, 'commit': true},
      );
      final Map<String, dynamic> auditAgain = asMap(auditAgainReply['payload']);
      check.check(
        (auditAgain['storage'] as Map<String, dynamic>)['ops'],
        0,
        'audit 重复运行 0 写',
      );

      final Map<String, dynamic> commitDryReply = await askCommand(
        'commit-dry',
        'docnorm.commit',
        <String, dynamic>{'repo': temp.path},
      );
      final Map<String, dynamic> commitDry = asMap(commitDryReply['payload']);
      check.check(commitDry['dry_run'], true, 'commit 默认 dry-run');
      check.that(
        (commitDry['batches'] as List<dynamic>?)?.isNotEmpty == true,
        'commit 按内容变更出批次',
      );
      check.check(
        asMap(commitDry['commit_style'])['style'],
        'plain',
        'commit 风格探测：fixture 提交是 plain',
      );
      check.check(asMap(commitDry['gates'])['mode'], 'listed', '门禁默认只列不跑');
      check.check(
        asMap(commitDry['counts'])['committed'],
        0,
        'commit dry-run 0 提交',
      );

      final Map<String, dynamic> graphCommitReply = await askCommand(
        'graph-commit',
        'docnorm.graph.build',
        <String, dynamic>{'repo': temp.path, 'commit': true},
      );
      final Map<String, dynamic> graphCommit = asMap(
        graphCommitReply['payload'],
      );
      check.check(graphCommit['mode'], 'deterministic', 'graph 只做确定性边');
      check.that(
        (asMap(graphCommit['counts'])['edges'] as num? ?? 0) > 0,
        'graph 产出三类边',
      );
      check.that(
        (fakeDb['graph_nodes'] ?? <String, Map<String, Object?>>{}).isNotEmpty,
        'graph_nodes 入库',
      );
      check.that(
        (fakeDb['graph_edges'] ?? <String, Map<String, Object?>>{}).isNotEmpty,
        'graph_edges 入库',
      );
      final int graphWrites = storageWrites;
      final Map<String, dynamic> graphAgainReply = await askCommand(
        'graph-again',
        'docnorm.graph.build',
        <String, dynamic>{'repo': temp.path, 'commit': true},
      );
      final Map<String, dynamic> graphAgain = asMap(graphAgainReply['payload']);
      check.check(asMap(graphAgain['storage'])['ops'], 0, 'graph 重复运行 0 写');
      check.check(storageWrites, graphWrites, 'graph 重复运行 0 存储写');

      final Map<String, dynamic> ragDryReply = await askCommand(
        'rag-dry',
        'docnorm.graph.build',
        <String, dynamic>{'repo': temp.path, 'rag': true},
      );
      final Map<String, dynamic> ragDry = asMap(ragDryReply['payload']);
      check.check(ragDry['mode'], 'hybrid', 'rag 有 embedding ⇒ mode=hybrid');
      check.check(
        asMap(ragDry['rag'])['vector_mode'],
        'planned',
        'rag dry-run 不发 LLM / embedding',
      );
      check.check(
        asMap(ragDry['storage'])['applied'],
        false,
        'rag dry-run 0 写',
      );
      final int ragLlmBefore = llmCalls;
      final Map<String, dynamic> ragCommitReply = await askCommand(
        'rag-commit',
        'docnorm.graph.build',
        <String, dynamic>{'repo': temp.path, 'commit': true, 'rag': true},
      );
      final Map<String, dynamic> ragCommit = asMap(ragCommitReply['payload']);
      check.check(ragCommit['mode'], 'hybrid', 'rag commit 建向量索引');
      final num ragChunkTotal =
          ((asMap(ragCommit['rag'])['chunks'] as Map<String, dynamic>)['total']
              as num?) ??
          0;
      check.that(ragChunkTotal > 0, 'rag 产出分块');
      check.that(
        (fakeDb['graph_chunks'] ?? <String, Map<String, Object?>>{}).isNotEmpty,
        'graph_chunks 入库',
      );
      check.that(
        (fakeDb['graph_communities'] ?? <String, Map<String, Object?>>{})
            .isNotEmpty,
        'graph_communities 入库',
      );
      check.that(
        (fakeDb['graph_reports'] ?? <String, Map<String, Object?>>{})
            .isNotEmpty,
        'graph_reports 入库',
      );
      check.that(
        (fakeDb['graph_vectors'] ?? <String, Map<String, Object?>>{})
            .isNotEmpty,
        'graph_vectors 入库',
      );
      check.that(llmCalls > ragLlmBefore, 'rag 抽取 / 报告经 llm.call');
      check.that(embedCalls > 0, 'rag 向量经 llm.embed');
      final int ragWrites = storageWrites;
      final int ragLlmCalls = llmCalls;
      final Map<String, dynamic> ragAgainReply = await askCommand(
        'rag-again',
        'docnorm.graph.build',
        <String, dynamic>{'repo': temp.path, 'commit': true, 'rag': true},
      );
      final Map<String, dynamic> ragAgain = asMap(ragAgainReply['payload']);
      check.check(asMap(ragAgain['storage'])['ops'], 0, 'rag 重复运行 0 写');
      check.check(storageWrites, ragWrites, 'rag 重复运行 0 存储写');
      check.check(llmCalls, ragLlmCalls, 'rag 重复运行 0 LLM 调用');

      final Map<String, dynamic> exportDryReply = await askCommand(
        'export-dry',
        'docnorm.export',
        <String, dynamic>{'repo': temp.path},
      );
      final Map<String, dynamic> exportDry = asMap(exportDryReply['payload']);
      check.check(exportDry['dry_run'], true, 'export 默认 dry-run');
      check.that(
        (exportDry['would_write'] as List<dynamic>?)?.isNotEmpty == true,
        'export 出待写快照',
      );
      final Map<String, dynamic> exportCommitReply = await askCommand(
        'export-commit',
        'docnorm.export',
        <String, dynamic>{'repo': temp.path, 'commit': true},
      );
      final Map<String, dynamic> exportCommit = asMap(
        exportCommitReply['payload'],
      );
      check.that(
        (exportCommit['written'] as List<dynamic>?)?.isNotEmpty == true,
        'export --commit 写 JSONL 快照',
      );
      final Map<String, dynamic> exportAgainReply = await askCommand(
        'export-again',
        'docnorm.export',
        <String, dynamic>{'repo': temp.path, 'commit': true},
      );
      final Map<String, dynamic> exportAgain = asMap(
        exportAgainReply['payload'],
      );
      check.check(
        (exportAgain['written'] as List<dynamic>?)?.length ?? 0,
        0,
        'export 重复运行 0 写（内容不可变）',
      );

      final Map<String, dynamic> queryReply = await askCommand(
        'query',
        'docnorm.query',
        <String, dynamic>{'repo': temp.path, 'question': 'demo 职责'},
      );
      final Map<String, dynamic> query = asMap(queryReply['payload']);
      check.check(query['mode'], 'hybrid', 'query 有向量走 hybrid');
      check.that(
        (query['results'] as List<dynamic>?)?.isNotEmpty == true,
        'query 返回命中分块',
      );

      final Map<String, dynamic> edgesReply = await askCommand(
        'edges',
        'docnorm.check',
        <String, dynamic>{'repo': temp.path, 'edges': true},
      );
      final Map<String, dynamic> edgesPayload = asMap(edgesReply['payload']);
      check.that(edgesPayload['edges'] is Map, 'check --edges 返回六类关联边检查');
      check.check(
        asMap(edgesPayload['edges'])['edges'],
        true,
        '边检查标记 edges=true',
      );
    }
  } catch (error) {
    check.that(false, '自检过程未抛异常', actual: '$error');
  } finally {
    await core.close();
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  }
  return check.finish(core.logs);
}
