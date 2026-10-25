// tree.agent —— agent 领域插件（批次 G）。
//
// A1（已完成）：hello / ping / 空 tools-list / 收集站 / 两路日志。
// A2（进行中）：`api/delegate` 管道 + 第一条只读路由
// `GET /api/agents/{agentId}/todos`（实现见 `lib/src/delegate.dart`）。
// 其余 35 条与广播 topic 按 `docs/pluginization/agent_api_contract.md` 逐批搬入。
//
// 本文件仍是"接线层"：骨架统一回答 hello/ping/tools-list，业务全部落在
// `package:tree_agent_loop` 里；生产与 `--selftest` 共用同一套处理函数。
//
// 依赖纪律：本插件不得 import 任何核心包（tree_core / tree_protocol）；
// 骨架与领域库都在本仓内（`../_kit` 与 `package:tree_agent_loop`）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tree_agent_loop/tree_agent_loop.dart';

import '../_kit/plugin_kit.dart';

/// 与 `plugin.json` 的 id 同串；核心以此认身份（自带清单时核心给的优先）。
const String kPluginId = 'tree.agent';

/// 面板展示名。
const String kDisplayName = 'Tree Agent 循环';

/// 建一个服务实例。自检与生产**共用**这个形状，只有退出策略不同。
PluginKitServer buildServer({bool exitOnShutdown = true}) => PluginKitServer(
  channel: PluginChannel.stdio(kPluginId),
  pluginId: kPluginId,
  displayName: kDisplayName,
  onReady: _onReady,
  onRequest: handleRequest,
  exitOnShutdown: exitOnShutdown,
);

Future<void> _onReady(PluginKitServer server) async {
  // **两路日志都主动写一条**：A1 的验收就是"插件自己的日志能从日志 API 查到"。
  // stderr 进 [stderr] 行，log 通知进 [notify:info] 行（见片 F 的 PluginLogSink）。
  server.channel.log(
    '已上线：v$kTreeAgentVersion（A2，已申报 ${kDeclaredRoutes.length} 条委派路由）',
  );
  server.channel.logNotify(
    'tree.agent 已上线（v$kTreeAgentVersion，已申报 ${kDeclaredRoutes.length} 条路由）',
  );
}

/// 骨架不认识的方法：收集站申报 + 委派执行。
///
/// 返回 null = 让骨架回 -32601（不静默）；抛异常由骨架收敛成 -32603。
Future<Map<String, dynamic>?> handleRequest(
  String method,
  Map<String, dynamic> params,
) async {
  if (method == M.apiDelegate) {
    // 核心 → 插件：委派一次 HTTP 请求；params 就是信封本体。
    return handleApiDelegate(asMap(params));
  }
  if (method == M.stationRequest) {
    final String station = asString(params['station_id']);
    if (station == kApiRoutesStation) {
      // 收集站口径：`{reply: {payload: {routes: [...]}}}`（核心只读 reply.payload）。
      return <String, dynamic>{
        'reply': <String, dynamic>{
          'payload': <String, dynamic>{'routes': kDeclaredRoutes},
        },
      };
    }
  }
  return null;
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

/// 假核心自检（**同码**跑真读循环）：A1 上线要件 + A2 第一条委派路由。
Future<int> selfTest() async {
  final SelfTest check = SelfTest(name: 'tree_agent_plugin');
  final Directory temp = Directory.systemTemp.createTempSync(
    'tree_agent_selftest_',
  );
  try {
    // 数据根夹具：agent 配置（含模型覆盖项）+ 待办 markdown（含一条裸行）+ 模型池。
    File(p.join(temp.path, 'agents', 'agt.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'id: agt\n'
        'name: 夹具\n'
        'model_id: m1\n'
        'system_prompt: 你是夹具\n'
        'reasoning_effort: high\n'
        'max_seqlen_override: 32000\n'
        'max_output_tokens: 8192\n'
        'compress_threshold: 0.8\n'
        'thinking_override: true\n'
        'created_at: 2026-10-25T10:00:03.000\n'
        'updated_at: 2026-10-25T10:00:03.000\n',
      );
    File(p.join(temp.path, 'agents', 'agt_top.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'id: agt_top\n'
        'name: 指挥\n'
        'model_id: m1\n'
        'system_prompt: 你是指挥\n'
        'created_at: 2026-10-25T10:00:01.000\n'
        'updated_at: 2026-10-25T10:00:02.000\n',
      );
    File(p.join(temp.path, 'agents', 'agt_m.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'id: agt_m\n'
        'name: 成员\n'
        'team_id: agt_top\n'
        'parent_agent_id: agt_top\n'
        'level: 1\n'
        'review_status: pending_review\n'
        'ssh:\n'
        '  host: 10.0.0.5\n'
        'created_at: 2026-10-25T10:00:00.000\n'
        'updated_at: 2026-10-25T10:00:01.000\n',
      );
    // 会话夹具：两个会话（旧的先；新会话里有"用户 / agent 文本 / 子 agent / 工具"四种行，
    // 预览只应取最后一条 agent 文本）。
    File(p.join(temp.path, 'data', 'agt', 'session_default', 'session.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '{"session_id":"session_default","agent_id":"agt","title":"默认",'
        '"updated_at":"2026-10-25T10:00:10.000"}',
      );
    File(p.join(temp.path, 'data', 'agt', 'ses_old', 'session.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '{"session_id":"ses_old","agent_id":"agt","title":"旧会话",'
        '"updated_at":"2026-10-25T10:00:05.000"}',
      );
    File(p.join(temp.path, 'data', 'agt', 'ses_old', 'messages.jsonl'))
      .writeAsStringSync(
        '{"id":"m0","agent_id":"agt","session_id":"ses_old","role":"agent",'
        '"content":"旧的预览","kind":"text","timestamp":"2026-10-25T10:00:04.000"}\n',
      );
    File(p.join(temp.path, 'data', 'agt', 'session_default', 'messages.jsonl'))
      .writeAsStringSync(
        '{"id":"m1","agent_id":"agt","session_id":"session_default","role":"user",'
        '"content":"你好","kind":"text","timestamp":"2026-10-25T10:00:06.000"}\n'
        '{"id":"m2","agent_id":"agt","session_id":"session_default","role":"agent",'
        '"content":"这是预览","kind":"text","timestamp":"2026-10-25T10:00:09.000"}\n'
        '{"id":"m3","agent_id":"agt","session_id":"session_default","role":"agent",'
        '"content":"子回复","kind":"text","subagent_id":"sub_1",'
        '"timestamp":"2026-10-25T10:00:09.500"}\n'
        '{"id":"m4","agent_id":"agt","session_id":"session_default","role":"agent",'
        '"content":"工具卡片","kind":"tool","timestamp":"2026-10-25T10:00:09.900"}\n',
      );
    File(p.join(temp.path, 'config', 'models', 'm1.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'model_id: m1\n'
        'name: 模型一\n'
        'base_url: https://api.example.com/v1\n'
        'api_key: sk-secret\n'
        'thinking: true\n'
        'if_vision: false\n'
        'reasoning_effort: high\n'
        'reasoning_effort_options: [low, high]\n'
        'max_seqlen: 64000\n'
        'max_output_tokens: 8192\n'
        'token_scale: 2.5\n'
        'longest_session_tokens: 12000\n',
      );
    File(p.join(temp.path, 'config', 'models', 'm2.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'model_id: m2\n'
        'base_url: http://127.0.0.1:8080/\n',
      );
    File(p.join(temp.path, 'data', 'agt', 'session_default', 'todos.md'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '# Tree 会话待办（夹具）\n\n'
        '- [~] t1 | status=in_progress progress=40 | 写读路径\n'
        '- [ ] 裸行待办\n',
      );
    File(
      p.join(temp.path, 'data', 'agt', 'session_default', 'subagents.json'),
    )
      ..createSync(recursive: true)
      ..writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
          'version': 1,
          'agent_id': 'agt',
          'session_id': 'session_default',
          'subagents': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'sub_1',
              'name': '临时员工',
              'owner_agent_id': 'agt',
              'session_id': 'session_default',
              'parent_id': 'agt',
              'level': 1,
              'scope': '整理日志',
              'run_count': 2,
              'agent': <String, dynamic>{},
              'created_at': '2026-10-25T10:00:00.000',
              'updated_at': '2026-10-25T10:05:00.000',
            },
            <String, dynamic>{
              'id': 'sub_2',
              'name': '下级',
              'owner_agent_id': 'agt',
              'session_id': 'session_default',
              'parent_id': 'sub_1',
              'level': 2,
              'scope': '',
              'run_count': 0,
              'agent': <String, dynamic>{},
              'created_at': 1761360000000,
              'updated_at': 1761360100000,
            },
          ],
        }),
      );

    final PluginKitServer server = PluginKitServer(
      channel: PluginChannel(logTag: 'tree_agent_plugin'),
      pluginId: kPluginId,
      displayName: kDisplayName,
      onReady: _onReady,
      onRequest: handleRequest,
      // 自检里不许退出进程：否则后续断言都跑不到。
      exitOnShutdown: false,
    );
    final FakeCore core = FakeCore(server);
    unawaited(core.start());

    Map<String, dynamic> envelope(String path, String agentId) =>
        <String, dynamic>{
          'method': 'GET',
          'path': path,
          'params': <String, dynamic>{'agentId': agentId},
          'query': <String, dynamic>{'session_id': 'session_default'},
          'headers': <String, dynamic>{},
          'scope': <String, dynamic>{},
          'workspace_dir': '',
          'data_dir': temp.path,
          'agent_id': agentId,
          'team_id': agentId,
          'request_id': 'selftest-$agentId-$path',
        };

    core.ask(0, M.hello, <String, dynamic>{'plugin_id': kPluginId});
    core.ask(1, M.ping);
    core.ask(2, M.toolsList);
    core.ask(3, M.stationRequest, <String, dynamic>{
      'station_id': kApiRoutesStation,
      'payload': <String, dynamic>{},
    });
    core.ask(4, 'no_such/method');
    core.ask(5, M.apiDelegate, envelope(todosPattern, 'agt'));
    core.ask(6, M.apiDelegate, envelope(todosPattern, 'nope'));
    core.ask(7, M.apiDelegate, envelope(subagentsPattern, 'agt'));
    core.ask(8, M.apiDelegate, envelope(modelsPattern, 'agt'));
    core.ask(9, M.apiDelegate, envelope(agentModelsInfoPattern, 'agt'));
    core.ask(10, M.apiDelegate, envelope(agentModelsInfoPattern, 'nope'));
    core.ask(11, M.apiDelegate, envelope(agentsPattern, ''));
    core.ask(
      12,
      M.apiDelegate,
      envelope('/api/agents/agt/sessions', 'agt'),
    );

    final Map<Object?, Map<String, dynamic>> byId = await core.waitFor(
      <int>[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12],
    );

    check.that(byId.length == 13, '十三条请求都有回包', actual: '${byId.length}');
    check.check(
      byId[0]?['result']?['plugin_id'],
      kPluginId,
      'hello 自报 plugin_id',
    );
    check.check(byId[0]?['result']?['name'], kDisplayName, 'hello 自报展示名');
    check.check(byId[1]?['result']?['ok'], true, 'ping 回 ok');
    check.check(
      byId[2]?['result']?['tools'],
      <dynamic>[],
      'A1 工具表为空（tools/list 可选，不阻断上线）',
    );
    check.check(
      byId[3]?['result']?['reply']?['payload']?['routes'],
      kDeclaredRoutes,
      '收集站申报与常量表一致（如实申报）',
    );
    check.that(byId[4]?['error'] != null, '未知方法回错误（不静默丢弃）');

    // ── A2：GET /api/agents/{agentId}/todos ────────────────────────────
    final Map<String, dynamic> ok =
        (byId[5]?['result'] as Map?)?.cast<String, dynamic>() ?? {};
    check.check(ok['status'], 200, 'todos：200');
    final Map<String, dynamic> okBody =
        (jsonDecode('${ok['body'] ?? '{}'}') as Map).cast<String, dynamic>();
    check.check(okBody['session_id'], 'session_default', 'todos：回 session_id');
    check.check(okBody['todos'], <dynamic>[
      <String, dynamic>{
        'id': 't1',
        'content': '写读路径',
        'status': 'in_progress',
        'progress': 40,
        'updated_at': 0,
      },
      <String, dynamic>{
        'id': 'h1',
        'content': '裸行待办',
        'status': 'pending',
        'progress': 0,
        'updated_at': 0,
      },
    ], 'todos：字段与解析（含裸行 → h1）');

    final Map<String, dynamic> missing =
        (byId[6]?['result'] as Map?)?.cast<String, dynamic>() ?? {};
    check.check(missing['status'], 404, 'todos：未知 agent ⇒ 404');
    check.check(
      jsonDecode('${missing['body'] ?? '{}'}'),
      <String, dynamic>{'detail': 'agent 不存在'},
      'todos：404 错误体与核心一致',
    );

    // ── A2：GET /api/agents/{agentId}/subagents ────────────────────────
    final Map<String, dynamic> rosterReply =
        (byId[7]?['result'] as Map?)?.cast<String, dynamic>() ?? {};
    check.check(rosterReply['status'], 200, 'subagents：200');
    final Map<String, dynamic> rosterBody =
        (jsonDecode('${rosterReply['body'] ?? '{}'}') as Map)
            .cast<String, dynamic>();
    check.check(rosterBody['agent_id'], 'agt', 'subagents：回 agent_id');
    check.check(rosterBody['total'], 2, 'subagents：total = 名册条数');
    check.check(
      rosterBody['subagents'],
      <dynamic>[
        <String, dynamic>{
          'id': 'sub_1',
          'name': '临时员工',
          'owner_agent_id': 'agt',
          'session_id': 'session_default',
          'parent_id': 'agt',
          'level': 1,
          'scope': '整理日志',
          'run_count': 2,
          'created_at': '2026-10-25T10:00:00.000',
          'updated_at': '2026-10-25T10:05:00.000',
        },
        <String, dynamic>{
          'id': 'sub_2',
          'name': '下级',
          'owner_agent_id': 'agt',
          'session_id': 'session_default',
          'parent_id': 'sub_1',
          'level': 2,
          'scope': '',
          'run_count': 0,
          'created_at': DateTime.fromMillisecondsSinceEpoch(
            1761360000000,
          ).toIso8601String(),
          'updated_at': DateTime.fromMillisecondsSinceEpoch(
            1761360100000,
          ).toIso8601String(),
        },
      ],
      'subagents：名册视图字段与时间口径（ISO / 毫秒都读）',
    );

    // ── A2：模型池 / models-info ───────────────────────────────────────
    const List<dynamic> expectedModels = <dynamic>[
      <String, dynamic>{
        'model_id': 'm1',
        'name': '模型一',
        'base_url': 'https://api.example.com',
        'thinking': true,
        'if_vision': false,
        'reasoning_effort': 'high',
        'reasoning_effort_options': <String>['low', 'high'],
        'max_seqlen': 64000,
        'max_output_tokens': 8192,
        'token_scale': 2.5,
        'longest_session_tokens': 12000,
      },
      <String, dynamic>{
        'model_id': 'm2',
        'name': 'm2',
        'base_url': 'http://127.0.0.1:8080',
        'thinking': false,
        'if_vision': false,
        'reasoning_effort': '',
        'reasoning_effort_options': <String>['low', 'high', 'max'],
        'max_seqlen': 0,
        'max_output_tokens': 0,
        'token_scale': 2.0,
        'longest_session_tokens': 0,
      },
    ];

    final Map<String, dynamic> modelsReply =
        (byId[8]?['result'] as Map?)?.cast<String, dynamic>() ?? {};
    check.check(modelsReply['status'], 200, 'models：200');
    check.check(
      jsonDecode('${modelsReply['body'] ?? '{}'}'),
      <String, dynamic>{'models': expectedModels},
      'models：11 键 / 排序 / 脱敏 / 默认值',
    );

    final Map<String, dynamic> infoReply =
        (byId[9]?['result'] as Map?)?.cast<String, dynamic>() ?? {};
    check.check(infoReply['status'], 200, 'models-info：200');
    check.check(
      jsonDecode('${infoReply['body'] ?? '{}'}'),
      <String, dynamic>{
        'agent': <String, dynamic>{
          'id': 'agt',
          'model_id': 'm1',
          'system_prompt': '你是夹具',
        },
        'models': expectedModels,
        'overrides': <String, dynamic>{
          'reasoning_effort': 'high',
          'max_seqlen': 32000,
          'max_output_tokens': 8192,
          'compress_threshold': 0.8,
          'thinking': true,
        },
      },
      'models-info：agent 三键 + 模型池 + 覆盖项',
    );

    final Map<String, dynamic> infoMissing =
        (byId[10]?['result'] as Map?)?.cast<String, dynamic>() ?? {};
    check.check(infoMissing['status'], 404, 'models-info：未知 agent ⇒ 404');
    check.check(
      jsonDecode('${infoMissing['body'] ?? '{}'}'),
      <String, dynamic>{'detail': 'agent 不存在'},
      'models-info：404 错误体与核心一致',
    );

    // ── A2：GET /api/agents（列表：22 键 + 预览 + 待处理成员数 + 排序）──
    final Map<String, dynamic> listReply =
        (byId[11]?['result'] as Map?)?.cast<String, dynamic>() ?? {};
    check.check(listReply['status'], 200, 'agents：200');
    int ms(String iso) => DateTime.parse(iso).millisecondsSinceEpoch;
    final Map<String, dynamic> agentsBody =
        (jsonDecode('${listReply['body'] ?? '{}'}') as Map)
            .cast<String, dynamic>();
    check.that(
      (agentsBody['agents'] as List<dynamic>?)?.length == 3,
      'agents：三条（扫描 agents/*.yaml）',
      actual: '${agentsBody['agents']}',
    );
    check.check(
      agentsBody['agents'],
      <dynamic>[
        <String, dynamic>{
          'id': 'agt',
          'name': '夹具',
          'type': 'normal',
          'system_prompt': '你是夹具',
          'model_id': 'm1',
          'workspace_id': '',
          'workspace_dir': '',
          'has_ssh': false,
          'last_message': '这是预览',
          'last_message_time': ms('2026-10-25T10:00:09.000'),
          'unread_count': 0,
          'avatar_url': null,
          'pending_member_count': 0,
          'team_id': '',
          'parent_agent_id': '',
          'level': 0,
          'role': '',
          'duty': '',
          'can_lead_team': true,
          'review_status': '',
          'created_at': ms('2026-10-25T10:00:03.000'),
          'updated_at': ms('2026-10-25T10:00:03.000'),
        },
        <String, dynamic>{
          'id': 'agt_top',
          'name': '指挥',
          'type': 'normal',
          'system_prompt': '你是指挥',
          'model_id': 'm1',
          'workspace_id': '',
          'workspace_dir': '',
          'has_ssh': false,
          'last_message': '',
          'last_message_time': null,
          'unread_count': 0,
          'avatar_url': null,
          'pending_member_count': 1,
          'team_id': '',
          'parent_agent_id': '',
          'level': 0,
          'role': '',
          'duty': '',
          'can_lead_team': true,
          'review_status': '',
          'created_at': ms('2026-10-25T10:00:01.000'),
          'updated_at': ms('2026-10-25T10:00:02.000'),
        },
        <String, dynamic>{
          'id': 'agt_m',
          'name': '成员',
          'type': 'normal',
          'system_prompt': '',
          'model_id': '',
          'workspace_id': '',
          'workspace_dir': '',
          'has_ssh': true,
          'last_message': '',
          'last_message_time': null,
          'unread_count': 0,
          'avatar_url': null,
          'pending_member_count': 0,
          'team_id': 'agt_top',
          'parent_agent_id': 'agt_top',
          'level': 1,
          'role': '',
          'duty': '',
          'can_lead_team': true,
          'review_status': 'pending_review',
          'created_at': ms('2026-10-25T10:00:00.000'),
          'updated_at': ms('2026-10-25T10:00:01.000'),
        },
      ],
      'agents：22 键 / 预览 / 待处理成员数 / updatedAt 降序',
    );

    final Map<String, dynamic> notImplemented =
        (byId[12]?['result'] as Map?)?.cast<String, dynamic>() ?? {};
    check.check(notImplemented['status'], 501, '未搬路由：501（不是 404）');
    check.that(
      jsonDecode('${notImplemented['body'] ?? '{}'}')['detail']
          .toString()
          .contains('尚未实现'),
      '未搬路由：可读原因',
      actual: '${notImplemented['body']}',
    );

    // 上线通知是异步发的：轮询等它到达（最多 2s）。
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 2));
    while (core.outgoing(M.log).isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final List<Map<String, dynamic>> notifications = core.outgoing(M.log);
    check.that(
      notifications.any(
        (Map<String, dynamic> frame) =>
            '${frame['params']?['message'] ?? ''}'.contains('tree.agent 已上线'),
      ),
      '上线 log 通知已发出（日志 API 写入侧）',
      actual: '${notifications.length} 条',
    );

    await core.close();
    return check.finish(core.logs);
  } finally {
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {
      // 清理失败不影响退出码（Windows 上偶发占用）。
    }
  }
}
