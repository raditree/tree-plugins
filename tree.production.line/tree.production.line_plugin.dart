// tree.production.line —— 标准开发流生产线（P1 数据模型 + 队列；P3 准备阶段）。
//
// 定位（docs/pluginization/production-line-recon.md §7/§8/§10/§11）：
// - headless 插件，granularity=team；数据只落 `<data_root>/production_lines/<team_id>/`；
// - `task.yaml` 是唯一真值，`state.json` 只是可由它重建的队列索引；
// - 状态机、队列排序、依赖判据、in-flight 崩溃恢复都在领域库，入口只做协议面；
// - P3 准备阶段：`production.prepare.*` 走需求模板 → 侦查 → 追问 → 范围/拆任务；
//   模型经 `llm.call`、文档检索经 `docnorm.query`（缺失即 fail-closed），
//   追问上限读 `tree.settings`（缺省回退 line.yaml / 默认 3）；
// - 依赖纪律：不得 import 任何核心包。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tree_production_line/tree_production_line.dart';

import '../_kit/plugin_kit.dart';

const String kPluginId = 'tree.production.line';
const String kDisplayName = 'Tree 标准开发流生产线';
const String kVersion = '0.2.0';

const String kStationName = 'production';

/// 追问上限的设置键。`tree.settings` 的 key 只允许字母/数字/下划线（不能带点），
/// 所以 §8.4 里写的 `questions.max_per_round` 落成 `questions_max_per_round`
/// （分组仍是 `questions`，UI 标题「追问」）。
const String kQuestionLimitKey = 'questions_max_per_round';

const String kStationReadme =
    '生产线 P1：production.line.create/list/get、production.task.create/list/get/'
    'transition、production.queue.next/rebuild/recover、production.run.list。'
    '数据落 `<data_root>/production_lines/<team_id>/<line_id>/`：line.yaml / '
    'tasks/<task_id>/task.yaml / runs/<run_id>.json / state.json / inbox.jsonl / '
    'prepare.json；task.yaml 为唯一真值，state.json 可由它重建。状态机：draft→recon→'
    'aligning→scoped→queued→packing→packed→running→gating→done；aligning↔awaiting_user；'
    'gating→packed（重试）；queued/packing/packed/running/gating→blocked；'
    'blocked→awaiting_user|queued；cancelled 可从任意非终态进入。崩溃恢复：in-flight → '
    'queued 并追加一条 status=interrupted 的 run，重复 recover 0 写。'
    'P3 准备阶段：production.prepare.intake（需求模板五栏）→ recon（侦查四块 + 追问，'
    '经 docnorm.query 取文档上下文、llm.call 出结构）→ answer / all_recommended / '
    'window.open|close（未答转 awaiting_user、次日续答）→ read（点状读取，文件 ≤ 8 / '
    'grep ≤ 2 轮）→ finalize（写 recon/scope/plan/decisions/acceptance + 建 queued 任务）。'
    '追问上限读 settings，缺省回退 line.yaml.limits 与 3（夹到 1–10）。';

final ProductionService _service = ProductionService();
PreparationService? _preparation;
PluginKitServer? _activeServer;
final Set<String> _settingsTeams = <String>{};

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
  _preparation = PreparationService(
    llm: _callLlm,
    docQuery: _callDocQuery,
    limitReader: _readQuestionLimit,
  );
  server.channel.log('已上线：v$kVersion（tree.production.line，P1 数据 + P3 准备阶段）');
  try {
    final Map<String, dynamic> result = await server.channel.request(
      M.stationRegister,
      <String, dynamic>{
        'kind': 'execute',
        'name': kStationName,
        'description': '生产线数据模型、队列与准备阶段（production.*）',
        'readme': kStationReadme,
        'commands': <String>[
          ...kProductionCommands,
          ...kPreparationCommands,
        ],
      },
    );
    server.channel.log(
      '自建执行站：${result['ok'] == true ? result['station_id'] : result['error']}',
    );
  } catch (error) {
    server.channel.log('自建执行站失败：$error');
  }
}

/// 向 `tree.agent` 的 `llm.call` 要一份 JSON：只透传本次请求的 scope（身份/团队）。
Future<Map<String, Object?>> _callLlm(
  String point,
  String system,
  String prompt,
  Map<String, Object?> scope,
) async {
  final PluginKitServer? server = _activeServer;
  if (server == null) {
    throw ProductionFailure('插件尚未就绪：llm.call 通道不可用', code: 'llm_unavailable');
  }
  final Map<String, dynamic> payload = await server.channel.command(
    'llm.call',
    <String, dynamic>{
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{'role': 'system', 'content': system},
        <String, dynamic>{'role': 'user', 'content': prompt},
      ],
      'temperature': 0.2,
    },
    '',
    scope,
  );
  final Object? json = payload['json'];
  if (json is Map) {
    return <String, Object?>{
      for (final MapEntry<dynamic, dynamic> entry in json.entries)
        entry.key.toString(): entry.value,
    };
  }
  final String text = asString(payload['text']);
  final Object? decoded = _jsonFromText(text);
  if (decoded is Map) {
    return <String, Object?>{
      for (final MapEntry<dynamic, dynamic> entry in decoded.entries)
        entry.key.toString(): entry.value,
    };
  }
  throw ProductionFailure(
    '模型没有返回 JSON（$point）：${text.length > 200 ? '${text.substring(0, 200)}…' : text}',
    code: 'llm_bad_json',
  );
}

/// 从正文里抠第一个 JSON 对象（模型偶尔加代码围栏 / 前置说明）。
Object? _jsonFromText(String text) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  try {
    return json.decode(trimmed);
  } catch (_) {
    final int start = trimmed.indexOf('{');
    final int end = trimmed.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      return json.decode(trimmed.substring(start, end + 1));
    } catch (_) {
      return null;
    }
  }
}

/// 文档检索（`docnorm.query`）；产线工作空间就是目标仓库。
Future<Map<String, Object?>> _callDocQuery(
  String repo,
  String question,
  Map<String, Object?> scope,
) async {
  final PluginKitServer? server = _activeServer;
  if (server == null) {
    throw ProductionFailure(
      '插件尚未就绪：docnorm.query 通道不可用',
      code: 'docnorm_unavailable',
    );
  }
  final Map<String, dynamic> payload = await server.channel.command(
    'docnorm.query',
    <String, dynamic>{
      'repo': repo,
      'question': question,
      'mode': 'hybrid',
    },
    '',
    scope,
  );
  return <String, Object?>{
    for (final MapEntry<String, dynamic> entry in payload.entries)
      entry.key: entry.value,
  };
}

/// 追问上限：先确保本团队的 schema 已注册，再读值；失败交回 null（走 line.yaml）。
Future<int?> _readQuestionLimit(Map<String, Object?> scope) async {
  final PluginKitServer? server = _activeServer;
  if (server == null) return null;
  final String teamId = asString(scope['team_id']);
  if (teamId.isEmpty) return null;
  try {
    if (!_settingsTeams.contains(teamId)) {
      await server.channel.command(
        'settings.define',
        <String, dynamic>{'schema': _questionSchema()},
        '',
        scope,
      );
      _settingsTeams.add(teamId);
    }
    final Map<String, dynamic> payload = await server.channel.command(
      'settings.get',
      <String, dynamic>{'key': kQuestionLimitKey},
      '',
      scope,
    );
    final Object? value = payload['value'];
    if (value is num) return value.toInt();
    return int.tryParse('$value');
  } catch (_) {
    return null;
  }
}

/// 设置在插件设置页显示的 schema（§8.4）。
Map<String, Object?> _questionSchema() => <String, Object?>{
  'schema_version': 1,
  'groups': <Map<String, Object?>>[
    <String, Object?>{'id': 'questions', 'title': '追问', 'order': 10},
  ],
  'fields': <Map<String, Object?>>[
    <String, Object?>{
      'key': kQuestionLimitKey,
      'group': 'questions',
      'type': 'int',
      'title': '每轮最多追问数',
      'default': 3,
      'min': 1,
      'max': 10,
      'help': '准备阶段每轮新提问题的上限（1–10）；已提出的问题不受影响，下一轮生效。',
    },
  ],
};

Future<Map<String, dynamic>?> handleRequest(
  String method,
  Map<String, dynamic> params,
) async {
  if (method != M.stationRequest) return null;
  final Map<String, dynamic> payload = asMap(params['payload']);
  final String command = asString(payload['command']);
  final bool isPrepare = kPreparationCommands.contains(command);
  if (!isPrepare && !kProductionCommands.contains(command)) return null;
  try {
    final Map<String, Object?> result = isPrepare
        ? await _preparation!.handle(
            command,
            asMap(payload['arguments']),
            asMap(params['meta']),
            asMap(params['scope']),
          )
        : _service.handle(
            command,
            asMap(payload['arguments']),
            asMap(params['meta']),
            asMap(params['scope']),
          );
    return <String, dynamic>{
      'reply': <String, dynamic>{'payload': result},
    };
  } on ProductionFailure catch (error) {
    return <String, dynamic>{
      'reply': <String, dynamic>{'error': error.message, 'code': error.code},
    };
  } catch (error) {
    return <String, dynamic>{
      'reply': <String, dynamic>{
        'error': '产线命令执行失败：$error',
        'code': 'production_error',
      },
    };
  }
}

Future<void> main(List<String> args) async {
  if (args.contains('--selftest')) {
    // 自检输出走 stderr："stdout 只有协议帧"这条铁律不因模式而变。
    exitCode = await selfTest();
    return;
  }
  await buildServer().run(stdin);
  try {
    await stdout.flush();
  } catch (_) {
    // 管道已被对端关掉（核心退出）：刷不出去不算错误。
  }
}

/// 假核心自检（同码跑真读循环）：注册面 + fail-closed + 状态机 + 队列 + 恢复 + 重建。
Future<int> selfTest() async {
  final SelfTest check = SelfTest(name: 'tree_production_line_plugin');
  final Directory temp = Directory.systemTemp.createTempSync(
    'tree_production_line_selftest_',
  );
  final FakeCore core = FakeCore(buildServer(exitOnShutdown: false));
  core.onMethod(
    M.stationRegister,
    (Map<String, dynamic> params) => <String, dynamic>{
      'ok': true,
      'station_id': 'production',
    },
  );

  Future<Map<String, dynamic>> call(
    Object id,
    String command,
    Map<String, Object?> arguments, {
    String? team = 'team_a',
    bool withData = true,
  }) async {
    core.ask(id, M.stationRequest, <String, dynamic>{
      'payload': <String, dynamic>{
        'command': command,
        'arguments': arguments,
      },
      'meta': <String, dynamic>{
        'source_plugin_id': kPluginId,
        if (withData) 'data_dir': temp.path,
      },
      'scope': <String, dynamic>{'team_id': ?team},
    });
    final Map<Object?, Map<String, dynamic>> responses = await core.waitFor(
      <Object?>[id],
    );
    final Map<String, dynamic> frame = responses[id] ?? <String, dynamic>{};
    return asMap(asMap(frame['result'])['reply']);
  }

  Map<String, dynamic> payloadOf(Map<String, dynamic> reply) =>
      asMap(reply['payload']);

  final String lineRoot = <String>[
    temp.path,
    'production_lines',
    'team_a',
    'pl_demo',
  ].join(Platform.pathSeparator);

  try {
    unawaited(core.start());
    core.ask('hello', M.hello, <String, dynamic>{'plugin_id': kPluginId});
    await core.waitFor(<Object?>['hello']);

    check.check(
      core.outgoing(M.stationRegister).length,
      1,
      '启动后注册执行站',
    );

    // 数据根 / 团队 fail-closed。
    final Map<String, dynamic> noData = await call(
      'no-data',
      'production.line.list',
      <String, Object?>{},
      withData: false,
    );
    check.check(noData['code'], 'missing_data_dir', '缺 data_dir ⇒ missing_data_dir');
    final Map<String, dynamic> noTeam = await call(
      'no-team',
      'production.line.list',
      <String, Object?>{},
      team: null,
    );
    check.check(noTeam['code'], 'team_required', '缺 team_id ⇒ team_required');

    // 产线：建 / 列 / 查 + 落盘。
    final Map<String, dynamic> created = await call(
      'line-create',
      'production.line.create',
      <String, Object?>{'id': 'pl_demo', 'name': '标准开发流'},
    );
    check.check(asMap(payloadOf(created)['line'])['id'], 'pl_demo', '建产线');
    final Map<String, dynamic> listed = await call(
      'line-list',
      'production.line.list',
      <String, Object?>{},
    );
    check.check(payloadOf(listed)['count'], 1, '产线列表 1 条');
    final Map<String, dynamic> fetched = await call(
      'line-get',
      'production.line.get',
      <String, Object?>{'line_id': 'pl_demo'},
    );
    check.check(
      asMap(payloadOf(fetched)['line'])['name'],
      '标准开发流',
      '产线详情',
    );
    check.that(
      File('$lineRoot${Platform.pathSeparator}line.yaml').existsSync(),
      'line.yaml 落盘',
    );
    check.that(
      File('$lineRoot${Platform.pathSeparator}inbox.jsonl').existsSync(),
      'inbox.jsonl 落盘',
    );
    final Map<String, dynamic> missingLine = await call(
      'line-missing',
      'production.line.get',
      <String, Object?>{'line_id': 'pl_nope'},
    );
    check.check(missingLine['code'], 'not_found', '缺产线 ⇒ not_found');

    // 任务：A(p10) ← B(p50) 依赖 A；C(p50) 独立。
    await call('task-a', 'production.task.create', <String, Object?>{
      'line_id': 'pl_demo',
      'task': <String, Object?>{
        'id': 'A',
        'title': '底座',
        'status': 'queued',
        'priority': 10,
      },
    });
    await call('task-b', 'production.task.create', <String, Object?>{
      'line_id': 'pl_demo',
      'task': <String, Object?>{
        'id': 'B',
        'title': '依赖 A',
        'status': 'queued',
        'priority': 50,
        'depends_on': <String>['A'],
      },
    });
    await call('task-c', 'production.task.create', <String, Object?>{
      'line_id': 'pl_demo',
      'task': <String, Object?>{
        'id': 'C',
        'title': '独立',
        'status': 'queued',
        'priority': 50,
      },
    });
    check.that(
      File(
        '$lineRoot${Platform.pathSeparator}tasks${Platform.pathSeparator}A'
        '${Platform.pathSeparator}task.yaml',
      ).existsSync(),
      'task.yaml 落盘',
    );

    final Map<String, dynamic> nextPayload = payloadOf(
      await call('queue-next', 'production.queue.next', <String, Object?>{
        'line_id': 'pl_demo',
      }),
    );
    check.check(
      asMap((nextPayload['tasks'] as List<dynamic>).first)['id'],
      'C',
      '队列先派无依赖的 C（B 等 A）',
    );
    check.check(
      asMap((nextPayload['skipped'] as List<dynamic>).first)['id'],
      'B',
      'B 因依赖被跳过',
    );
    check.check(
      nextPayload['queue'],
      <String>['B', 'C', 'A'],
      '队列按 priority / created_at / id 排序',
    );

    // 非法迁移与 blocked 理由。
    final Map<String, dynamic> illegal = await call(
      'illegal',
      'production.task.transition',
      <String, Object?>{
        'line_id': 'pl_demo',
        'task_id': 'A',
        'to': 'done',
      },
    );
    check.check(illegal['code'], 'invalid_transition', 'queued → done 非法');
    final Map<String, dynamic> noReason = await call(
      'blocked-no-reason',
      'production.task.transition',
      <String, Object?>{
        'line_id': 'pl_demo',
        'task_id': 'A',
        'to': 'blocked',
      },
    );
    check.check(noReason['code'], 'reason_required', 'blocked 必须带理由');
    await call('blocked', 'production.task.transition', <String, Object?>{
      'line_id': 'pl_demo',
      'task_id': 'A',
      'to': 'blocked',
      'reason': '等拍板',
    });
    await call('unblocked', 'production.task.transition', <String, Object?>{
      'line_id': 'pl_demo',
      'task_id': 'A',
      'to': 'queued',
    });

    // A 走完整链到 done。
    for (final String to in <String>[
      'packing',
      'packed',
      'running',
      'gating',
      'done',
    ]) {
      final Map<String, dynamic> reply = await call(
        'a-$to',
        'production.task.transition',
        <String, Object?>{'line_id': 'pl_demo', 'task_id': 'A', 'to': to},
      );
      check.check(
        asMap(payloadOf(reply)['task'])['status'],
        to,
        'A → $to',
      );
    }
    final Map<String, dynamic> afterDone = payloadOf(
      await call('queue-next-2', 'production.queue.next', <String, Object?>{
        'line_id': 'pl_demo',
      }),
    );
    check.check(
      asMap((afterDone['tasks'] as List<dynamic>).first)['id'],
      'B',
      'A 完成后 B 可派发',
    );

    // 崩溃恢复：C 卡在 packing → 回 queued + 一条 interrupted 台账，重复 0 写。
    await call('c-packing', 'production.task.transition', <String, Object?>{
      'line_id': 'pl_demo',
      'task_id': 'C',
      'to': 'packing',
    });
    final Map<String, dynamic> recovered = payloadOf(
      await call('recover', 'production.queue.recover', <String, Object?>{
        'line_id': 'pl_demo',
      }),
    );
    check.check(recovered['count'], 1, '恢复 1 个 in-flight');
    final Map<String, dynamic> recoveredAgain = payloadOf(
      await call('recover-2', 'production.queue.recover', <String, Object?>{
        'line_id': 'pl_demo',
      }),
    );
    check.check(recoveredAgain['count'], 0, '重复 recover 0 写');
    final Map<String, dynamic> runs = payloadOf(
      await call('runs', 'production.run.list', <String, Object?>{
        'line_id': 'pl_demo',
      }),
    );
    check.check(runs['count'], 1, 'interrupted run 落台账');
    check.check(
      asMap((runs['runs'] as List<dynamic>).first)['status'],
      'interrupted',
      'run 状态 = interrupted',
    );
    final Map<String, dynamic> cTask = payloadOf(
      await call('c-get', 'production.task.get', <String, Object?>{
        'line_id': 'pl_demo',
        'task_id': 'C',
      }),
    );
    check.check(asMap(cTask['task'])['status'], 'queued', 'C 已回 queued');

    // 索引：损坏后重建一次，第二次 0 写。
    final File stateFile = File(
      '$lineRoot${Platform.pathSeparator}state.json',
    );
    stateFile.writeAsStringSync('{"broken": true}');
    final Map<String, dynamic> rebuilt = payloadOf(
      await call('rebuild', 'production.queue.rebuild', <String, Object?>{
        'line_id': 'pl_demo',
      }),
    );
    check.check(rebuilt['changed'], true, '损坏索引被重建');
    final Map<String, dynamic> rebuiltAgain = payloadOf(
      await call('rebuild-2', 'production.queue.rebuild', <String, Object?>{
        'line_id': 'pl_demo',
      }),
    );
    check.check(rebuiltAgain['changed'], false, '重建幂等（第二次 0 写）');
    check.check(
      jsonDecode(stateFile.readAsStringSync())['queue'],
      <String>['B', 'C'],
      'state.queue 与 task.yaml 对齐（A 已 done）',
    );

    // ── P3 准备阶段：假 docnorm / llm / settings，跑完整窗口 → 落档 ──
    final String ws = '${temp.path}${Platform.pathSeparator}ws';
    Directory(ws).createSync(recursive: true);
    core.onMethod(M.stationCommand, (Map<String, dynamic> params) {
      final String command = asString(params['command']);
      switch (command) {
        case 'docnorm.query':
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{
              'mode': 'lexical',
              'results': <Object?>[
                <String, Object?>{
                  'doc': 'docs/project-status.md',
                  'heading': 'H 车道',
                  'snippet': '生产线 P1/P2 已完成',
                },
              ],
            },
          };
        case 'settings.define':
          return <String, dynamic>{'ok': true, 'payload': <String, dynamic>{}};
        case 'settings.get':
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{'value': 2},
          };
        case 'llm.call':
          final List<dynamic> messages = params['arguments'] is Map
              ? (asMap(params['arguments'])['messages'] as List<dynamic>? ??
                    <dynamic>[])
              : <dynamic>[];
          final String text = messages
              .map((dynamic item) => asString(asMap(item)['content']))
              .join('\n');
          if (text.contains('侦查员')) {
            return <String, dynamic>{
              'ok': true,
              'payload': <String, dynamic>{
                'json': <String, Object?>{
                  'regular': <Object?>[
                    <String, Object?>{
                      'text': '改列表',
                      'landing': 'lib/ui/agent_list.dart',
                    },
                  ],
                  'special': <Object?>[
                    <String, Object?>{'text': '本地模型', 'why': '云端慢'},
                  ],
                  'questions': <Object?>[
                    for (int i = 1; i <= 5; i++)
                      <String, Object?>{
                        'text': '问题 $i',
                        'default': '默认 $i',
                        'recommended': '推荐 $i',
                        'consequence': '后果 $i',
                      },
                  ],
                  'fallbacks': <Object?>['退回云端'],
                  'notes': <Object?>['数据库不可动'],
                  'flags': <String>['lib/ui/agent_list.dart'],
                },
                'text': '{}',
                'model': 'fake',
              },
            };
          }
          return <String, dynamic>{
            'ok': true,
            'payload': <String, dynamic>{
              'json': <String, Object?>{
                'in': <String>['列表过滤'],
                'out': <String>['不动数据库'],
                'not_doing': <String>['不做搜索'],
                'tasks': <Object?>[
                  <String, Object?>{
                    'id': 'T1',
                    'title': '改列表',
                    'acceptance': <String>['用例全绿'],
                    'write_scope': <String>['lib/ui/agent_list.dart'],
                  },
                  <String, Object?>{
                    'id': 'T2',
                    'title': '补测试',
                    'depends_on': <String>['T1'],
                    'acceptance': <String>['新用例覆盖过滤'],
                  },
                ],
              },
              'text': '{}',
              'model': 'fake',
            },
          };
        default:
          return <String, dynamic>{
            'ok': false,
            'error': '假核心不认的站命令：$command',
          };
      }
    });

    await call('prep-line', 'production.line.create', <String, Object?>{
      'id': 'pl_prep',
      'name': '准备阶段',
      'workspace_dir': ws,
    });
    await call('prep-intake', 'production.prepare.intake', <String, Object?>{
      'line_id': 'pl_prep',
      'task': <String, Object?>{
        'id': 'T_prep',
        'title': '列表过滤',
        'intake': <String, Object?>{
          'goal': '会话列表能按项目过滤',
          'current': '只有 flat 列表',
          'acceptance': '只剩该项目会话；有测试',
        },
      },
    });
    final Map<String, dynamic> reconReply = payloadOf(
      await call('prep-recon', 'production.prepare.recon', <String, Object?>{
        'line_id': 'pl_prep',
        'task_id': 'T_prep',
      }),
    );
    check.check(reconReply['open'], 2, '追问上限读 settings（=2）');
    check.check(reconReply['dropped'], 3, '超限问题被截断且计数可见');
    check.that(
      File(
        <String>[ws, 'docs', 'production_lines', 'pl_prep', 'recon.md'].join(
          Platform.pathSeparator,
        ),
      ).existsSync(),
      'recon.md 落项目资产',
    );

    await call('prep-close', 'production.prepare.window.close', <String, Object?>{
      'line_id': 'pl_prep',
    });
    final Map<String, dynamic> blocked = await call(
      'prep-finalize-blocked',
      'production.prepare.finalize',
      <String, Object?>{'line_id': 'pl_prep', 'task_id': 'T_prep'},
    );
    check.check(blocked['code'], 'questions_open', '未答不实施（finalize 被拒）');

    await call('prep-open', 'production.prepare.window.open', <String, Object?>{
      'line_id': 'pl_prep',
    });
    final Map<String, dynamic> recommended = payloadOf(
      await call(
        'prep-recommended',
        'production.prepare.all_recommended',
        <String, Object?>{'line_id': 'pl_prep', 'task_id': 'T_prep'},
      ),
    );
    check.check(recommended['open'], 0, '全部按推荐后 0 条未答');
    check.check(recommended['ready'], true, '答完即可落档');

    final Map<String, dynamic> finalized = payloadOf(
      await call('prep-finalize', 'production.prepare.finalize', <String, Object?>{
        'line_id': 'pl_prep',
        'task_id': 'T_prep',
      }),
    );
    check.check(
      asMap(finalized['task'])['status'],
      'scoped',
      '准备任务落档后 scoped',
    );
    check.check(
      (finalized['created_tasks'] as List<dynamic>).length,
      2,
      '拆出 2 个 queued 任务',
    );
    check.that(
      File(
        <String>[ws, 'docs', 'production_lines', 'pl_prep', 'plan.md'].join(
          Platform.pathSeparator,
        ),
      ).existsSync(),
      'plan.md 落项目资产',
    );
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
