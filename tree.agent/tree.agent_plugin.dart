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

/// 自检跑的是假核心（不处理 station/command），必须关掉执行站入口。
bool _enableStationClient = true;

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
  // 执行站入口：hello 之后插件才能主动向核心下 station/command。
  if (_enableStationClient) {
    AgentRuntime.pluginId = kPluginId;
    AgentRuntime.stationClient = (String command, Map<String, dynamic> arguments, Map<String, dynamic> scope) =>
        server.channel.command(command, arguments, '', scope);
    AgentRuntime.stationTrigger =
        (
          String stationId,
          Object? payload,
          Map<String, dynamic> meta,
          Map<String, dynamic> scope, {
          String? topic,
        }) => server.channel.request(M.stationTrigger, <String, dynamic>{
          'station_id': stationId,
          if (topic != null && topic.isNotEmpty) 'topic': topic,
          'payload': payload,
          'meta': meta,
          'scope': scope,
        });
    try {
      final Map<String, dynamic> toolStation = await server.channel.request(
        M.stationRegister,
        <String, dynamic>{
          'kind': 'execute',
          'name': kAgentToolsStationName,
          'description': 'tree.agent 领域工具原语',
          'readme': AgentRuntime.agentToolsReadme,
          'commands': AgentRuntime.agentToolCommands,
        },
      );
      server.channel.log(
        '领域工具执行站：${toolStation['ok'] == true ? toolStation['station_id'] : toolStation['error']}',
      );
    } catch (error) {
      server.channel.log('领域工具执行站注册失败：$error');
    }
    try {
      final Map<String, dynamic> registered = await server.channel.request(
        M.stationRegister,
        <String, dynamic>{
          'kind': 'collect',
          'name': kToolCollectName,
          'description': 'tree.agent 工具贡献收集站',
          'readme': kToolCollectReadme,
          'schema': toolCollectSchema(),
          'shared': true,
        },
      );
      server.channel.log(
        '工具贡献收集站已注册：${registered['station_id'] ?? toolCollectStationId(kPluginId)}',
      );
    } catch (error) {
      server.channel.log('工具贡献收集站注册失败（不影响内置工具）：$error');
    }
    // 执行器激活站：local 检查设备与工作空间；ssh 真建连并登记租约。
    try {
      final Map<String, dynamic> executor = await server.channel.request(
        M.stationRegister,
        <String, dynamic>{
          'kind': 'execute',
          'name': kAgentExecutorStationName,
          'description': 'tree.agent 执行器激活（local 检查 / ssh 真建连）',
          'readme': kAgentExecutorReadme,
          'commands': kAgentExecutorCommands,
          'shared': true,
        },
      );
      server.channel.log(
        '执行器激活站：${executor['ok'] == true ? executor['station_id'] : executor['error']}',
      );
    } catch (error) {
      server.channel.log('执行器激活站注册失败：$error');
    }
    // **A4 事件广播站**：领域帧不再由核心发出，统一从这里出去。
    // 注册失败不影响 REST/工具：宁可少推帧，也不能让插件起不来。
    try {
      final Map<String, dynamic> events = await server.channel.request(
        M.stationRegister,
        <String, dynamic>{
          'kind': 'broadcast',
          'name': kAgentEventsStationName,
          'description': 'tree.agent 领域事件（流式增量 / 工具 / 状态 / 提问）',
          'readme': kAgentEventsReadme,
          'shared': true,
        },
      );
      final String stationId = (events['station_id'] ?? '').toString();
      AgentRuntime.eventsStationId = stationId.isEmpty
          ? kAgentEventsStationId
          : stationId;
      server.channel.log(
        '事件广播站：${AgentRuntime.eventsStationId}'
        '${events['ok'] == true ? '' : '（失败：${events['error']}）'}',
      );
    } catch (error) {
      server.channel.log('事件广播站注册失败（前端将收不到流式帧）：$error');
    }
  }
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
    if (station == agentToolsStationId(kPluginId)) {
      final Map<String, dynamic> meta = asMap(params['meta']);
      final String dataDir = asString(meta['data_dir']);
      if (dataDir.isEmpty) {
        return <String, dynamic>{
          'reply': <String, dynamic>{'error': '缺少 data_dir（核心未在站请求里带数据根）'},
        };
      }
      final Map<String, dynamic> payload = asMap(params['payload']);
      final String command = asString(payload['command']);
      final Map<String, dynamic> args = asMap(payload['arguments']);
      final Map<String, dynamic> scope = asMap(params['scope']);
      try {
        final Map<String, dynamic> result =
            await AgentRuntime.forDataDir(dataDir).handleAgentToolCommand(
              command,
              args,
              scope,
            );
        return <String, dynamic>{
          'reply': <String, dynamic>{'payload': result},
        };
      } catch (error) {
        return <String, dynamic>{
          'reply': <String, dynamic>{'error': error.toString()},
        };
      }
    }
    if (station == agentExecutorStationId(kPluginId)) {
      final Map<String, dynamic> meta = asMap(params['meta']);
      final String dataDir = asString(meta['data_dir']);
      if (dataDir.isEmpty) {
        return <String, dynamic>{
          'reply': <String, dynamic>{'error': '缺少 data_dir（核心未在站请求里带数据根）'},
        };
      }
      final Map<String, dynamic> payload = asMap(params['payload']);
      final Map<String, dynamic> result = await AgentRuntime.forDataDir(dataDir)
          .handleAgentExecutorCommand(
            asString(payload['command']),
            asMap(payload['arguments']),
            asMap(params['scope']),
          );
      return <String, dynamic>{
        'reply': <String, dynamic>{'payload': result},
      };
    }
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
  _enableStationClient = false;
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
        'reasoning_effort: low\n'
        'max_seqlen_override: 16000\n'
        'thinking_override: false\n'
        'ssh:\n'
        '  host: 10.0.0.5\n'
        'created_at: 2026-10-25T10:00:00.000\n'
        'updated_at: 2026-10-25T10:00:01.000\n',
      );
    File(p.join(temp.path, 'agents', 'agt_m2.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'id: agt_m2\n'
        'name: 执行\n'
        'team_id: agt_top\n'
        'parent_agent_id: agt_m\n'
        'level: 2\n'
        'role: 执行\n'
        'duty: 跑测试\n'
        'model_id: m2\n'
        'review_status: approved\n'
        'workspace_id: ws_m2\n'
        'created_at: 2026-10-25T10:00:04.000\n'
        'updated_at: 2026-10-25T10:00:04.000\n',
      );
    // 会话夹具：两个会话（旧的先；新会话里有"用户 / agent 文本 / 子 agent / 工具"四种行，
    // 预览只应取最后一条 agent 文本）。
    File(p.join(temp.path, 'data', 'agt', 'session_default', 'session.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '{"session_id":"session_default","agent_id":"agt","title":"默认",'
        '"created_at":"2026-10-25T10:00:02.000",'
        '"updated_at":"2026-10-25T10:00:10.000"}',
      );
    File(p.join(temp.path, 'data', 'agt', 'ses_old', 'session.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '{"session_id":"ses_old","agent_id":"agt","title":"旧会话",'
        '"created_at":"2026-10-25T10:00:03.000",'
        '"updated_at":"2026-10-25T10:00:05.000"}',
      );
    File(p.join(temp.path, 'data', 'agt', 'ses_old', 'messages.jsonl'))
      .writeAsStringSync(
        '{"id":"m0","agent_id":"agt","session_id":"ses_old","role":"agent",'
        '"content":"旧的预览","kind":"text","timestamp":"2026-10-25T10:00:04.000"}\n',
      );
    // 另一个会话的临时员工名册（没有消息）：跨会话 transcript 的"属于会话"夹具。
    File(p.join(temp.path, 'data', 'agt', 'ses_subagent', 'subagents.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
          'version': 1,
          'agent_id': 'agt',
          'session_id': 'ses_subagent',
          'subagents': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'sub_9',
              'name': '旧员工',
              'owner_agent_id': 'agt',
              'session_id': 'ses_subagent',
              'parent_id': 'agt',
              'level': 1,
              'scope': '',
              'run_count': 0,
              'agent': <String, dynamic>{},
              'created_at': '2026-10-25T10:00:00.000',
              'updated_at': '2026-10-25T10:00:05.000',
            },
          ],
        }),
      );
    File(p.join(temp.path, 'data', 'questions.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '[\n'
        '  {\n'
        '    "qid": "q1",\n'
        '    "agent_id": "agt",\n'
        '    "team_id": "",\n'
        '    "session_id": "session_default",\n'
        '    "is_member": false,\n'
        '    "questions": [{"question": "选哪个", "options": ["A", "B"]}],\n'
        '    "answers": ["B"],\n'
        '    "question": "选哪个",\n'
        '    "options": ["A", "B"],\n'
        '    "answer": "B",\n'
        '    "status": "answered",\n'
        '    "created_at": 1761360000000,\n'
        '    "answered_at": 1761360001000\n'
        '  },\n'
        '  {\n'
        '    "qid": "q2",\n'
        '    "agent_id": "agt_m",\n'
        '    "team_id": "",\n'
        '    "session_id": "session_default",\n'
        '    "is_member": false,\n'
        '    "questions": [{"question": "继续吗", "options": []}],\n'
        '    "status": "pending",\n'
        '    "created_at": 1761360002000\n'
        '  }\n'
        ']\n',
      );
    File(p.join(temp.path, 'data', 'agt', 'session_default', 'messages.jsonl'))
      .writeAsStringSync(
        '{"id":"m1","agent_id":"agt","session_id":"session_default","role":"user",'
        '"content":"你好","kind":"text","timestamp":"2026-10-25T10:00:06.000"}\n'
        '{"id":"q1","agent_id":"agt","session_id":"session_default","role":"agent",'
        '"content":"选哪个","kind":"ask_user_question",'
        '"timestamp":"2026-10-25T10:00:07.000"}\n'
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

    Map<String, dynamic> envelope(
      String path,
      String agentId, {
      Map<String, String> extraParams = const <String, String>{},
      Map<String, String>? query,
    }) => <String, dynamic>{
      'method': 'GET',
      'path': path,
      'params': <String, dynamic>{'agentId': agentId, ...extraParams},
      'query': <String, dynamic>{...?query, if (query == null) 'session_id': 'session_default'},
          'headers': <String, dynamic>{},
          'scope': <String, dynamic>{},
          'workspace_dir': '',
          'data_dir': temp.path,
          'agent_id': agentId,
          'team_id': agentId,
          'request_id': 'selftest-$agentId-$path',
        };

    Map<String, dynamic> postEnvelope(
      String path,
      String agentId,
      Map<String, dynamic> body, {
      Map<String, String> extraParams = const <String, String>{},
      Map<String, String>? query,
      String method = 'POST',
    }) => <String, dynamic>{
      'method': method,
      'path': path,
      'params': <String, dynamic>{'agentId': agentId, ...extraParams},
      'query': <String, dynamic>{...?query},
      'headers': <String, dynamic>{},
      'scope': <String, dynamic>{},
      'workspace_dir': '',
      'data_dir': temp.path,
      'agent_id': agentId,
      'team_id': agentId,
      'request_id': 'selftest-post-$agentId-$path',
      'body': jsonEncode(body),
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
    core.ask(12, M.apiDelegate, envelope(agentDetailPattern, 'agt_m'));
    core.ask(13, M.apiDelegate, envelope(sessionsPattern, 'agt'));
    core.ask(
      14,
      M.apiDelegate,
      envelope(
        sessionDetailPattern,
        'agt',
        extraParams: <String, String>{'sessionId': 'session_default'},
      ),
    );
    core.ask(
      15,
      M.apiDelegate,
      envelope(
        sessionDetailPattern,
        'agt',
        extraParams: <String, String>{'sessionId': 'ses_old'},
      ),
    );
    core.ask(
      16,
      M.apiDelegate,
      envelope(
        sessionDetailPattern,
        'agt',
        extraParams: <String, String>{'sessionId': 'ses_x'},
      ),
    );
    core.ask(
      17,
      M.apiDelegate,
      envelope(
        conversationsPattern,
        'agt',
        query: <String, String>{'session_id': 'session_default'},
      ),
    );
    core.ask(
      18,
      M.apiDelegate,
      envelope(
        conversationsPattern,
        'agt',
        query: <String, String>{'session_id': 'session_default', 'limit': '2'},
      ),
    );
    core.ask(
      19,
      M.apiDelegate,
      envelope(
        conversationsPattern,
        'agt',
        query: <String, String>{
          'session_id': 'session_default',
          'limit': '2',
          'from': '1',
        },
      ),
    );
    core.ask(
      20,
      M.apiDelegate,
      envelope(
        conversationsPattern,
        'agt',
        query: <String, String>{
          'session_id': 'session_default',
          'limit': '2',
          'at': 'm3',
        },
      ),
    );
    core.ask(
      21,
      M.apiDelegate,
      envelope(
        conversationsPattern,
        'agt',
        query: <String, String>{'session_id': 'all'},
      ),
    );
    core.ask(22, M.apiDelegate, envelope(teammatesPattern, 'agt_top'));
    core.ask(23, M.apiDelegate, envelope(teammatesPattern, 'agt_m'));
    core.ask(24, M.apiDelegate, envelope(teammatesPattern, 'ghost'));
    core.ask(
      25,
      M.apiDelegate,
      envelope('/api/agents/agt/sessions/ses_x/messages', 'agt'),
    );
    core.ask(
      26,
      M.apiDelegate,
      postEnvelope(messagesPattern, 'agt_m', <String, dynamic>{
        'content': '你好',
      }),
    );
    core.ask(
      27,
      M.apiDelegate,
      postEnvelope(messagesPattern, 'agt', <String, dynamic>{
        'content': '   ',
      }),
    );
    core.ask(
      28,
      M.apiDelegate,
      postEnvelope(cancelPattern, 'ghost', <String, dynamic>{}),
    );
    core.ask(
      29,
      M.apiDelegate,
      postEnvelope(cancelPattern, 'agt', <String, dynamic>{}),
    );
    core.ask(30, M.apiDelegate, envelope(toolsRunningPattern, 'agt'));
    core.ask(
      32,
      M.apiDelegate,
      postEnvelope(modelsPattern, 'agt', <String, dynamic>{
        'model_id': 'm3',
        'base_url': 'https://m3.example.com/v1',
        'api_key': 'sk-3',
      }),
    );
    core.ask(
      33,
      M.apiDelegate,
      postEnvelope(modelsPattern, 'agt', <String, dynamic>{
        'model_id': 'm3',
        'base_url': 'https://m3.example.com/v1',
        'api_key': 'sk-3',
      }),
    );
    core.ask(
      34,
      M.apiDelegate,
      postEnvelope(
        modelPattern,
        'agt',
        <String, dynamic>{'name': '模型三'},
        extraParams: <String, String>{'modelId': 'm3'},
        method: 'PATCH',
      ),
    );
    core.ask(
      35,
      M.apiDelegate,
      postEnvelope(
        modelPattern,
        'agt',
        <String, dynamic>{},
        extraParams: <String, String>{'modelId': 'm3'},
        method: 'DELETE',
      ),
    );
    core.ask(36, M.apiDelegate, envelope(tokenRatePattern, 'agt'));
    core.ask(
      37,
      M.apiDelegate,
      postEnvelope(tokenRatePattern, 'agt', <String, dynamic>{
        'token_rate': 200,
      }),
    );
    core.ask(38, M.apiDelegate, envelope(tokenRatePattern, 'agt'));
    core.ask(
      39,
      M.apiDelegate,
      postEnvelope(sessionsPattern, 'agt', <String, dynamic>{
        'session_id': 'ses_new',
        'title': '新会话',
      }),
    );
    core.ask(
      40,
      M.apiDelegate,
      postEnvelope(
        sessionDetailPattern,
        'agt',
        <String, dynamic>{'title': '改名'},
        extraParams: <String, String>{'sessionId': 'ses_new'},
        method: 'PATCH',
      ),
    );
    core.ask(
      41,
      M.apiDelegate,
      postEnvelope(
        sessionSpecsPattern,
        'agt',
        <String, dynamic>{
          'spec_ids': <String>['general-task'],
        },
        extraParams: <String, String>{'sessionId': 'ses_new'},
      ),
    );
    core.ask(
      42,
      M.apiDelegate,
      postEnvelope(
        sessionDetailPattern,
        'agt',
        <String, dynamic>{},
        extraParams: <String, String>{'sessionId': 'ses_new'},
        method: 'DELETE',
      ),
    );
    core.ask(43, M.apiDelegate, envelope(questionsPattern, 'agt'));
    core.ask(
      44,
      M.apiDelegate,
      postEnvelope(
        questionAnswerPattern,
        'agt',
        <String, dynamic>{
          'answers': <String>['继续'],
        },
        extraParams: <String, String>{'qid': 'q2'},
      ),
    );
    core.ask(
      45,
      M.apiDelegate,
      postEnvelope(
        conversationsPattern,
        'agt',
        <String, dynamic>{},
        query: <String, String>{'session_id': 'ses_old'},
        method: 'DELETE',
      ),
    );
    core.ask(48, M.apiDelegate, postEnvelope(agentResetPattern, 'agt', <String, dynamic>{'target': 'all'}));
    core.ask(
      49,
      M.apiDelegate,
      postEnvelope(sshReconnectPattern, 'ghost', <String, dynamic>{}),
    );
    core.ask(46, M.apiDelegate, envelope(specsPattern, 'agt'));
    core.ask(
      47,
      M.apiDelegate,
      envelope(
        specDetailPattern,
        'agt',
        extraParams: <String, String>{'specId': 'general-task'},
      ),
    );
    core.ask(
      31,
      M.apiDelegate,
      postEnvelope(
        toolsRunningClosePattern,
        'agt',
        <String, dynamic>{},
        extraParams: <String, String>{'handle': 'toolrun_missing'},
      ),
    );
    // ── agent 写路由 / transcript（G-1 §1.1 #2/#4/#5/#9）───────────────
    core.ask(
      50,
      M.apiDelegate,
      postEnvelope(agentsPattern, '', <String, dynamic>{'model_id': 'm1'}),
    );
    core.ask(
      51,
      M.apiDelegate,
      postEnvelope(agentsPattern, '', <String, dynamic>{
        'name': '新助手',
        'model_id': 'nope',
      }),
    );
    core.ask(
      52,
      M.apiDelegate,
      postEnvelope(agentsPattern, '', <String, dynamic>{
        'name': '新助手',
        'model_id': 'm1',
        'system_prompt': '你是新助手',
      }),
    );
    core.ask(
      53,
      M.apiDelegate,
      envelope(
        '/api/agents/agt/subagents/sub_1/transcript',
        'agt',
        extraParams: <String, String>{'subagentId': 'sub_1'},
        query: <String, String>{'session_id': 'session_default'},
      ),
    );
    core.ask(
      54,
      M.apiDelegate,
      envelope(
        '/api/agents/agt/subagents/sub_999/transcript',
        'agt',
        extraParams: <String, String>{'subagentId': 'sub_999'},
        query: <String, String>{'session_id': 'session_default'},
      ),
    );
    core.ask(
      55,
      M.apiDelegate,
      envelope(
        '/api/agents/agt/subagents/sub_9/transcript',
        'agt',
        extraParams: <String, String>{'subagentId': 'sub_9'},
        query: <String, String>{'session_id': 'ses_subagent'},
      ),
    );
    core.ask(
      56,
      M.apiDelegate,
      envelope(
        '/api/agents/agt/subagents/sub_9/transcript',
        'agt',
        extraParams: <String, String>{'subagentId': 'sub_9'},
        query: <String, String>{'session_id': 'session_default'},
      ),
    );
    core.ask(
      57,
      M.apiDelegate,
      postEnvelope(
        '/api/agents/ghost',
        'ghost',
        <String, dynamic>{},
        method: 'DELETE',
      ),
    );

    final Map<Object?, Map<String, dynamic>> byId = await core.waitFor(
      <int>[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57],
    );

    check.that(byId.length == 58, '五十八条请求都有回包', actual: '${byId.length}');
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
      (agentsBody['agents'] as List<dynamic>?)?.length == 4,
      'agents：四条（扫描 agents/*.yaml）',
      actual: '${agentsBody['agents']}',
    );
    check.check(
      agentsBody['agents'],
      <dynamic>[
        <String, dynamic>{
          'id': 'agt_m2',
          'name': '执行',
          'type': 'normal',
          'system_prompt': '',
          'model_id': 'm2',
          'workspace_id': 'ws_m2',
          'workspace_dir': '',
          'has_ssh': false,
          'last_message': '',
          'last_message_time': null,
          'unread_count': 0,
          'avatar_url': null,
          'pending_member_count': 0,
          'team_id': 'agt_top',
          'parent_agent_id': 'agt_m',
          'level': 2,
          'role': '执行',
          'duty': '跑测试',
          'can_lead_team': true,
          'review_status': 'approved',
          'created_at': ms('2026-10-25T10:00:04.000'),
          'updated_at': ms('2026-10-25T10:00:04.000'),
        },
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

    // ── A2：GET /api/agents/{agentId}（详情 + SSH 非机密视图）──────────
    final Map<String, dynamic> detailReply =
        (byId[12]?['result'] as Map?)?.cast<String, dynamic>() ?? {};
    check.check(detailReply['status'], 200, 'agent 详情：200');
    final Map<String, dynamic> detailBody =
        (jsonDecode('${detailReply['body'] ?? '{}'}') as Map)
            .cast<String, dynamic>();
    check.check(
      (detailBody['agent'] as Map?)?['id'],
      'agt_m',
      'agent 详情：id',
    );
    check.check(
      (detailBody['agent'] as Map?)?['last_message'],
      '',
      'agent 详情：不取预览（与核心 toApiJson() 默认一致）',
    );
    check.check(
      detailBody['ssh'],
      <String, dynamic>{
        'host': '10.0.0.5',
        'port': 22,
        'username': '',
        'auth': 'none',
      },
      'agent 详情：SSH 非机密视图（无密钥）',
    );

    // ── A2：会话列表 / 会话详情 ───────────────────────────────────────
    final Map<String, dynamic> sessionsReply =
        (byId[13]?['result'] as Map?)?.cast<String, dynamic>() ?? {};
    check.check(sessionsReply['status'], 200, 'sessions：200');
    check.check(
      (jsonDecode('${sessionsReply['body'] ?? '{}'}') as Map)['sessions'],
      <dynamic>[
        <String, dynamic>{
          'session_id': 'session_default',
          'agent_id': 'agt',
          'title': '默认',
          'status': 'active',
          'selected_spec_ids': <String>[],
          'message_count': 3,
          'created_at': ms('2026-10-25T10:00:02.000'),
          'updated_at': ms('2026-10-25T10:00:10.000'),
        },
        <String, dynamic>{
          'session_id': 'ses_old',
          'agent_id': 'agt',
          'title': '旧会话',
          'status': 'active',
          'selected_spec_ids': <String>[],
          'message_count': 1,
          'created_at': ms('2026-10-25T10:00:03.000'),
          'updated_at': ms('2026-10-25T10:00:05.000'),
        },
      ],
      'sessions：updated_at 降序 / 非工具消息计数',
    );

    final Map<String, dynamic> detailSession =
        (byId[14]?['result'] as Map?)?.cast<String, dynamic>() ?? {};
    check.check(detailSession['status'], 200, '会话详情：200');
    final Map<String, dynamic> detailSessionBody =
        (jsonDecode('${detailSession['body'] ?? '{}'}') as Map)
            .cast<String, dynamic>();
    check.check(
      (detailSessionBody['session'] as Map?)?['session_id'],
      'session_default',
      '会话详情：session_id',
    );
    check.check(
      (detailSessionBody['messages'] as List<dynamic>?)?.length,
      5,
      '会话详情：五条消息',
    );
    check.check(
      (detailSessionBody['messages'] as List<dynamic>?)?[0],
      <String, dynamic>{
        'id': 'm1',
        'agent_id': 'agt',
        'session_id': 'session_default',
        'role': 'user',
        'content': '你好',
        'timestamp': '2026-10-25T10:00:06.000',
        'kind': 'text',
        'tool_name': null,
        'tool_arguments': null,
        'tool_result': '',
        'tool_call_id': null,
        'usage': null,
        'attachments': null,
        'options': <String>[],
        'answered': false,
        'is_streaming': false,
      },
      '会话详情：用户消息 16 键规范化',
    );
    check.check(
      (detailSessionBody['messages'] as List<dynamic>?)?[1],
      <String, dynamic>{
        'id': 'q1',
        'agent_id': 'agt',
        'session_id': 'session_default',
        'role': 'agent',
        'content': '选哪个',
        'timestamp': '2026-10-25T10:00:07.000',
        'kind': 'ask_user_question',
        'tool_name': null,
        'tool_arguments': null,
        'tool_result': '',
        'tool_call_id': null,
        'usage': null,
        'attachments': null,
        'options': <String>[],
        'answered': false,
        'is_streaming': false,
      },
      '会话详情：提问卡片（详情不叠加记录状态）',
    );
    check.check(
      (detailSessionBody['messages'] as List<dynamic>?)?[2],
      <String, dynamic>{
        'id': 'm2',
        'agent_id': 'agt',
        'session_id': 'session_default',
        'role': 'agent',
        'content': '这是预览',
        'timestamp': '2026-10-25T10:00:09.000',
        'kind': 'text',
        'tool_name': null,
        'tool_arguments': null,
        'tool_result': '',
        'tool_call_id': null,
        'usage': null,
        'attachments': null,
        'options': <String>[],
        'answered': false,
        'is_streaming': false,
      },
      '会话详情：agent 消息',
    );
    check.check(
      (detailSessionBody['messages'] as List<dynamic>?)?[3],
      <String, dynamic>{
        'id': 'm3',
        'agent_id': 'agt',
        'session_id': 'session_default',
        'role': 'agent',
        'content': '子回复',
        'timestamp': '2026-10-25T10:00:09.500',
        'kind': 'text',
        'tool_name': null,
        'tool_arguments': null,
        'tool_result': '',
        'tool_call_id': null,
        'usage': null,
        'attachments': null,
        'options': <String>[],
        'answered': false,
        'subagent_id': 'sub_1',
        'subagent_name': '',
        'subagent_parent_id': '',
        'subagent_level': 0,
        'is_streaming': false,
      },
      '会话详情：临时员工消息带标记键',
    );
    check.check(
      ((detailSessionBody['messages'] as List<dynamic>?)?[4] as Map?)?['kind'],
      'tool',
      '会话详情：工具消息 kind',
    );

    final Map<String, dynamic> oldSession =
        (byId[15]?['result'] as Map?)?.cast<String, dynamic>() ?? {};
    check.check(oldSession['status'], 200, '会话详情（旧）：200');
    check.check(
      ((jsonDecode('${oldSession['body'] ?? '{}'}') as Map)['messages']
              as List<dynamic>?)
          ?.length,
      1,
      '会话详情（旧）：一条消息',
    );

    final Map<String, dynamic> missingSession =
        (byId[16]?['result'] as Map?)?.cast<String, dynamic>() ?? {};
    check.check(missingSession['status'], 404, '会话详情：不存在 ⇒ 404');
    check.check(
      jsonDecode('${missingSession['body'] ?? '{}'}'),
      <String, dynamic>{'detail': '会话不存在'},
      '会话详情：404 错误体与核心一致',
    );

    // ── A2：GET /api/conversations（分页 + 提问状态叠加）──────────────
    Map<String, dynamic> convBody(int index) {
      final Map<String, dynamic> reply =
          (byId[index]?['result'] as Map?)?.cast<String, dynamic>() ?? {};
      return (jsonDecode('${reply['body'] ?? '{}'}') as Map)
          .cast<String, dynamic>();
    }

    List<String> idsOf(Map<String, dynamic> body) => <String>[
      for (final Object? item in body['messages'] as List<dynamic>)
        '${(item as Map<dynamic, dynamic>)['id']}',
    ];

    final Map<String, dynamic> convDefault = convBody(17);
    check.check(convDefault['total'], 5, 'conversations：total = 全部消息数');
    check.check(convDefault['offset'], 0, 'conversations：offset = 0');
    check.check(convDefault['has_more'], false, 'conversations：has_more=false');
    check.check(
      idsOf(convDefault),
      <String>['m1', 'q1', 'm2', 'm3', 'm4'],
      'conversations：按 timestamp 升序',
    );
    check.check(
      (convDefault['messages'] as List<dynamic>)[1],
      <String, dynamic>{
        'id': 'q1',
        'agent_id': 'agt',
        'session_id': 'session_default',
        'role': 'agent',
        'content': '选哪个',
        'timestamp': '2026-10-25T10:00:07.000',
        'kind': 'ask_user_question',
        'tool_name': null,
        'tool_arguments': null,
        'tool_result': '',
        'tool_call_id': null,
        'usage': null,
        'attachments': null,
        'options': <String>['A', 'B'],
        'answered': true,
        'is_streaming': false,
        'answer': 'B',
        'questions': <Map<String, dynamic>>[
          <String, dynamic>{
            'question': '选哪个',
            'options': <String>['A', 'B'],
          },
        ],
        'answers': <String>['B'],
      },
      'conversations：提问卡片叠加记录状态/答案/选项',
    );

    final Map<String, dynamic> convLimit = convBody(18);
    check.check(
      idsOf(convLimit),
      <String>['m3', 'm4'],
      'conversations limit=2：末尾一页',
    );
    check.check(convLimit['offset'], 3, 'conversations limit=2：offset=3');
    check.check(convLimit['has_more'], true, 'conversations limit=2：has_more');

    final Map<String, dynamic> convFrom = convBody(19);
    check.check(
      idsOf(convFrom),
      <String>['q1', 'm2'],
      'conversations from=1&limit=2：按下标取页',
    );
    check.check(convFrom['offset'], 1, 'conversations from：offset=1');

    final Map<String, dynamic> convAt = convBody(20);
    check.check(
      idsOf(convAt),
      <String>['m2', 'm3'],
      'conversations at=m3&limit=2：以目标为中心',
    );
    check.check(convAt['offset'], 2, 'conversations at：offset=2');

    final Map<String, dynamic> convAll = convBody(21);
    check.check(
      idsOf(convAll),
      <String>['m0', 'm1', 'q1', 'm2', 'm3', 'm4'],
      'conversations session_id=all：跨会话合并后按时间升序',
    );
    check.check(convAll['total'], 6, 'conversations all：total=6');
    check.check(convAll['session_id'], 'all', 'conversations all：回显 all');

    // ── A2：GET /api/agents/{agentId}/teammates ───────────────────────
    Map<String, dynamic> matesBody(int index) {
      final Map<String, dynamic> reply =
          (byId[index]?['result'] as Map?)?.cast<String, dynamic>() ?? {};
      return (jsonDecode('${reply['body'] ?? '{}'}') as Map)
          .cast<String, dynamic>();
    }

    final Map<String, dynamic> topMates = matesBody(22);
    check.check(
      topMates['pending_member_count'],
      1,
      'teammates：TOP 名册待处理数',
    );
    check.check(
      topMates['self'],
      <String, dynamic>{
        'id': 'agt_top',
        'name': '指挥',
        'level': 0,
        'is_member': false,
        'top_agent_id': '',
        'top_agent_name': '',
      },
      'teammates：TOP 的 self 描述符',
    );
    final List<dynamic> topMembers = topMates['members'] as List<dynamic>;
    check.check(topMembers.length, 2, 'teammates：TOP 整队两名成员');
    check.check(
      topMembers[0],
      <String, dynamic>{
        'id': 'agt_m',
        'name': '成员',
        'role': '',
        'duty': '',
        'model_id': '',
        'level': 1,
        'can_lead_team': true,
        'parent_agent_id': 'agt_top',
        'leader_name': '指挥',
        'relation': 'direct',
        'work_status': 'idle',
        'review_status': 'pending_review',
        'log_path': '.tree/agt_m/.self/activity.log',
        'created_at': ms('2026-10-25T10:00:00.000'),
        'workspace_id': '',
        'overrides': <String, dynamic>{
          'reasoning_effort': 'low',
          'max_seqlen': 16000,
          'thinking': false,
        },
        'effective': <String, dynamic>{
          'reasoning_effort': 'low',
          'max_seqlen': 16000,
          'max_output_tokens': 0,
          'thinking': false,
        },
        'live_status': 'idle',
      },
      'teammates：成员视图 + 覆盖项 + 有效参数（无模型）',
    );
    check.check(
      topMembers[1],
      <String, dynamic>{
        'id': 'agt_m2',
        'name': '执行',
        'role': '执行',
        'duty': '跑测试',
        'model_id': 'm2',
        'level': 2,
        'can_lead_team': true,
        'parent_agent_id': 'agt_m',
        'leader_name': '成员',
        'relation': 'indirect',
        'work_status': 'idle',
        'review_status': 'approved',
        'log_path': '.tree/agt_m2/.self/activity.log',
        'created_at': ms('2026-10-25T10:00:04.000'),
        'workspace_id': 'ws_m2',
        'overrides': <String, dynamic>{},
        'effective': <String, dynamic>{
          'reasoning_effort': '',
          'max_seqlen': 128000,
          'max_output_tokens': 0,
          'thinking': false,
        },
        'live_status': 'idle',
      },
      'teammates：后代 indirect + 模型默认值（fallback 128000）',
    );

    final Map<String, dynamic> memberMates = matesBody(23);
    check.check(
      memberMates['pending_member_count'],
      0,
      'teammates：成员名册只数自己的下属',
    );
    check.check(
      memberMates['self'],
      <String, dynamic>{
        'id': 'agt_m',
        'name': '成员',
        'level': 1,
        'is_member': true,
        'top_agent_id': 'agt_top',
        'top_agent_name': '指挥',
      },
      'teammates：成员的 self 描述符',
    );
    check.check(
      (memberMates['members'] as List<dynamic>).length,
      1,
      'teammates：成员只列自己的下级',
    );
    check.check(
      ((memberMates['members'] as List<dynamic>).first as Map?)?['relation'],
      'direct',
      'teammates：下级 relation=direct',
    );

    check.check(
      matesBody(24),
      <String, dynamic>{
        'agent_id': 'ghost',
        'members': <dynamic>[],
        'pending_member_count': 0,
        'self': null,
      },
      'teammates：未知 agent ⇒ 200 + self:null（不是 404）',
    );

    final Map<String, dynamic> notImplemented =
        (byId[25]?['result'] as Map?)?.cast<String, dynamic>() ?? {};
    check.check(notImplemented['status'], 501, '未搬路由：501（不是 404）');
    check.that(
      jsonDecode('${notImplemented['body'] ?? '{}'}')['detail']
          .toString()
          .contains('尚未实现'),
      '未搬路由：可读原因',
      actual: '${notImplemented['body']}',
    );

    // ── C-08：POST messages / cancel ─────────────────────────────────
    Map<String, dynamic> postResult(int index) =>
        (byId[index]?['result'] as Map?)?.cast<String, dynamic>() ?? {};

    Map<String, dynamic> postBody(int index) {
      final String raw = '${postResult(index)['body'] ?? '{}'}';
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    }

    final Map<String, dynamic> messagesReply = postResult(26);
    check.check(messagesReply['status'], 200, 'messages：200');
    final Map<String, dynamic> messagesBody = postBody(26);
    check.check(messagesBody['success'], true, 'messages：success');
    check.check(messagesBody['agent_id'], 'agt_m', 'messages：回 agent_id');
    check.that(
      '${messagesBody['session_id'] ?? ''}'.isNotEmpty,
      'messages：未指定会话 ⇒ 新建并回 session_id',
    );
    check.check(
      messagesBody['session_created'],
      true,
      'messages：新建会话标记',
    );

    check.check(postResult(27)['status'], 400, 'messages：空内容 400');
    check.check(
      postBody(27),
      <String, dynamic>{'detail': 'content 不能为空'},
      'messages：400 错误体',
    );

    check.check(postResult(28)['status'], 404, 'cancel：未知 agent 404');
    check.check(
      postBody(28),
      <String, dynamic>{'detail': '未知 agent：ghost'},
      'cancel：404 错误体',
    );

    final Map<String, dynamic> cancelReply = postResult(29);
    check.check(cancelReply['status'], 200, 'cancel：200');
    final Map<String, dynamic> cancelBody = postBody(29);
    check.check(cancelBody['success'], true, 'cancel：success');
    check.check(cancelBody['agent_id'], 'agt', 'cancel：回 agent_id');
    check.check(cancelBody['cascade'], true, 'cancel：TOP 级联');
    check.check(cancelBody['cascade_ids'], <dynamic>['agt'], 'cancel：级联 id');
    check.that(
      <dynamic>[
        ...(cancelBody['cancelled'] as List<dynamic>? ?? <dynamic>[]),
        ...(cancelBody['idle'] as List<dynamic>? ?? <dynamic>[]),
      ].contains('agt'),
      'cancel：agt 落在 cancelled 或 idle（覆盖在途/空闲两种时序）',
    );

    // 运行监督：空快照 + 失效句柄的 404 都可读。
    final Map<String, dynamic> runningReply = postResult(30);
    check.check(runningReply['status'], 200, 'tools/running：200');
    check.check(
      jsonDecode('${runningReply['body'] ?? '{}'}'),
      <String, dynamic>{'runs': <dynamic>[]},
      'tools/running：空快照形状',
    );
    check.check(postResult(31)['status'], 404, 'tools/running close：404');
    check.that(
      jsonDecode('${postResult(31)['body'] ?? '{}'}')['detail']
          .toString()
          .contains('句柄已失效'),
      'tools/running close：可读原因',
    );

    // ── 模型池写接口 + token 节奏 ───────────────────────────────────
    check.check(postResult(32)['status'], 200, 'models：创建 200');
    final Map<String, dynamic> created = postBody(32);
    check.check(created['success'], true, 'models：创建 success');
    check.check(
      (created['model'] as Map?)?['model_id'],
      'm3',
      'models：创建回 model_id',
    );
    check.check(
      ((created['model'] as Map?) ?? {}).containsKey('api_key'),
      false,
      'models：创建不回密钥',
    );
    check.check(postResult(33)['status'], 409, 'models：重名 409');
    check.check(
      postBody(33),
      <String, dynamic>{'detail': '模型已存在：m3'},
      'models：重名错误体',
    );
    check.check(postResult(34)['status'], 200, 'models：PATCH 200');
    check.check(
      (postBody(34)['model'] as Map?)?['name'],
      '模型三',
      'models：PATCH 改名生效',
    );
    check.check(postResult(35)['status'], 200, 'models：DELETE 200');
    check.check(
      postBody(35)['bound_agents'],
      <dynamic>[],
      'models：DELETE 回绑定 agent 列表',
    );
    check.check(postBody(36)['token_rate'], 1000, 'token-rate：默认 1000');
    check.check(postResult(37)['status'], 200, 'token-rate：POST 200');
    check.check(postBody(37)['token_rate'], 200, 'token-rate：夹取后 200');
    check.check(postBody(38)['token_rate'], 200, 'token-rate：写后读一致');

    // ── 会话写接口 / 提问 / 会话清空 ─────────────────────────────────
    check.check(postResult(39)['status'], 200, 'sessions：创建 200');
    final Map<String, dynamic> createdSession = postBody(39);
    check.check(
      (createdSession['session'] as Map?)?['session_id'],
      'ses_new',
      'sessions：创建回 session_id',
    );
    check.check(
      (createdSession['session'] as Map?)?['message_count'],
      0,
      'sessions：新会话 message_count=0',
    );
    check.check(postResult(40)['status'], 200, 'sessions：PATCH 200');
    check.check(postBody(40)['success'], true, 'sessions：PATCH success');
    check.check(
      postBody(41)['selected_spec_ids'],
      <dynamic>['general-task'],
      'sessions/specs：回显已选规范',
    );
    check.check(postResult(42)['status'], 200, 'sessions：DELETE 200');

    final Map<String, dynamic> questionList = postBody(43);
    check.check(questionList['total'], 2, 'questions：两条（含已作答）');
    check.check(
      (questionList['questions'] as List<dynamic>).first['qid'],
      'q2',
      'questions：最新在前',
    );
    check.that(
      postResult(44)['status'] == 200,
      'questions：作答 200',
      actual: jsonEncode(postBody(44)),
    );
    check.check(postBody(44)['status'], 'answered', 'questions：状态变 answered');
    check.check(
      postBody(44)['answers'],
      <dynamic>['继续'],
      'questions：回显逐题答案',
    );
    check.check(postResult(45)['status'], 200, 'conversations：清空 200');
    check.check(postBody(45)['deleted'], 1, 'conversations：删除消息数');

    // ── Spec 列表 / 详情（无执行站时只回内置规范）──────────────────
    check.check(postResult(46)['status'], 200, 'specs：200');
    final Map<String, dynamic> specsBody = postBody(46);
    check.that(
      (specsBody['specs'] as List<dynamic>? ?? <dynamic>[]).isNotEmpty,
      'specs：内置规范非空',
      actual: '${(specsBody['specs'] as List<dynamic>? ?? <dynamic>[]).length}',
    );
    check.check(postResult(47)['status'], 200, 'specs/detail：200');
    check.that(
      '${postBody(47)['content'] ?? ''}'.isNotEmpty,
      'specs/detail：正文非空',
    );

    check.check(postResult(48)['status'], 400, 'reset：无工作空间时 400');
    check.check(postResult(49)['status'], 404, 'ssh/reconnect：未知 agent 404');

    // ── G-1：agent 写路由 / transcript（§1.1 #2/#4/#5/#9）─────────────
    check.check(postResult(50)['status'], 400, 'agents：POST 缺 name ⇒ 400');
    check.check(
      postBody(50),
      <String, dynamic>{'detail': 'name 不能为空'},
      'agents：POST name 错误体',
    );
    check.check(postResult(51)['status'], 400, 'agents：POST 未知模型 ⇒ 400');
    check.check(
      postBody(51),
      <String, dynamic>{'detail': '模型不存在：nope'},
      'agents：POST 模型错误体',
    );
    check.check(postResult(52)['status'], 200, 'agents：POST 创建 200');
    final Map<String, dynamic> createdAgent =
        (postBody(52)['agent'] as Map).cast<String, dynamic>();
    final String createdId = '${createdAgent['id'] ?? ''}';
    check.that(
      createdId.startsWith('agt_'),
      'agents：创建回 agent id',
      actual: createdId,
    );
    check.check(createdAgent['name'], '新助手', 'agents：创建回 name');
    check.check(createdAgent['model_id'], 'm1', 'agents：创建回 model_id');
    check.check(createdAgent['system_prompt'], '你是新助手', 'agents：创建回提示词');
    check.check(createdAgent['team_id'], '', 'agents：创建不接受 team_id');
    check.check(createdAgent['parent_agent_id'], '', 'agents：创建不接受 parent');
    check.check(createdAgent['level'], 0, 'agents：创建 level=0');
    check.that(
      File(
        p.join(temp.path, 'data', createdId, 'session_default', 'session.json'),
      ).existsSync(),
      'agents：创建时建默认会话',
    );

    check.check(postResult(53)['status'], 200, 'transcript：200');
    final Map<String, dynamic> transcript = postBody(53);
    check.check(transcript['agent_id'], 'agt', 'transcript：回 agent_id');
    check.check(transcript['subagent_id'], 'sub_1', 'transcript：回 subagent_id');
    check.check(transcript['total'], 1, 'transcript：只含该临时员工的消息');
    check.check(
      ((transcript['messages'] as List<dynamic>).single as Map)['id'],
      'm3',
      'transcript：按 subagent_id 过滤',
    );
    check.check(postResult(54)['status'], 404, 'transcript：未知临时员工 404');
    check.check(
      postBody(54),
      <String, dynamic>{'detail': '临时员工不存在：sub_999'},
      'transcript：未知临时员工错误体',
    );
    check.check(postResult(55)['status'], 200, 'transcript（另一会话）：200');
    final Map<String, dynamic> otherTranscript = postBody(55);
    check.check(otherTranscript['total'], 0, 'transcript（另一会话）：没有消息');
    check.check(
      otherTranscript['session_id'],
      'ses_subagent',
      'transcript（另一会话）：回显请求的 session_id',
    );
    check.check(postResult(56)['status'], 404, 'transcript：跨会话 404');
    check.check(
      postBody(56),
      <String, dynamic>{
        'detail':
            '临时员工「旧员工」属于会话 ses_subagent，'
            '不在这个会话（session_default）里——跨会话不保留是硬不变量。',
      },
      'transcript：跨会话错误体',
    );
    check.check(postResult(57)['status'], 404, 'agents：DELETE 未知 id ⇒ 404');

    // 第二批：动态 agent id 的 PATCH / GET / DELETE 全链路。
    // 插件读循环对每个请求另起异步任务（与生产一致），所以这里逐条发、逐条等：
    // 写后读必须等前一条回包，否则会读到写队列尚未落盘的状态。
    Future<Map<String, dynamic>> delegateSeq(
      int id,
      Map<String, dynamic> request,
    ) async {
      core.ask(id, M.apiDelegate, request);
      final Map<Object?, Map<String, dynamic>> replies = await core.waitFor(
        <int>[id],
      );
      return (replies[id]?['result'] as Map?)?.cast<String, dynamic>() ?? {};
    }

    Map<String, dynamic> replyBody(Map<String, dynamic> reply) {
      final String raw = '${reply['body'] ?? '{}'}';
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    }

    final String createdWorkspace = p.join(temp.path, '工作区');
    final Map<String, dynamic> patchReply = await delegateSeq(
      58,
      postEnvelope(
        '/api/agents/$createdId',
        createdId,
        <String, dynamic>{
          'name': '改名应被忽略',
          'team_id': 'agt_top',
          'system_prompt': '改过的提示词',
          'workspace_dir': createdWorkspace,
          'ssh': <String, dynamic>{
            'host': '10.0.0.9',
            'username': 'dev',
            'password': 'secret',
          },
          'max_seqlen': 32000,
          'thinking': true,
        },
        method: 'PATCH',
      ),
    );
    check.check(patchReply['status'], 200, 'agents：PATCH 200');
    final Map<String, dynamic> patched =
        (replyBody(patchReply)['agent'] as Map).cast<String, dynamic>();
    check.check(patched['name'], '新助手', 'agents：PATCH 不改 name');
    check.check(patched['team_id'], '', 'agents：PATCH 不改 team_id');
    check.check(patched['system_prompt'], '改过的提示词', 'agents：PATCH 改提示词');
    check.check(
      patched['workspace_dir'],
      createdWorkspace,
      'agents：PATCH 改工作目录',
    );
    final Map<String, dynamic> ssh =
        (replyBody(patchReply)['ssh'] as Map).cast<String, dynamic>();
    check.check(ssh['host'], '10.0.0.9', 'agents：PATCH 回 SSH 非机密视图');
    check.check(ssh['auth'], 'password', 'agents：PATCH SSH auth 口径');
    check.check(ssh.containsKey('password'), false, 'agents：PATCH 不回 SSH 密码');

    final Map<String, dynamic> invalidReply = await delegateSeq(
      59,
      postEnvelope(
        '/api/agents/$createdId',
        createdId,
        <String, dynamic>{'compress_threshold': 2},
        method: 'PATCH',
      ),
    );
    check.check(invalidReply['status'], 400, 'agents：PATCH 非法压缩阈值 400');
    check.check(
      replyBody(invalidReply),
      <String, dynamic>{
        'detail': 'compress_threshold 必须在 0.1~0.95 之间，或 null 清除该项覆盖',
      },
      'agents：PATCH 压缩阈值错误体',
    );

    final Map<String, dynamic> agentDetailReply = await delegateSeq(
      60,
      envelope('/api/agents/$createdId', createdId),
    );
    check.check(agentDetailReply['status'], 200, 'agents：GET 详情 200');
    check.check(
      (replyBody(agentDetailReply)['agent'] as Map)['system_prompt'],
      '改过的提示词',
      'agents：GET 详情读到 PATCH 后值',
    );

    final Map<String, dynamic> deleteReply = await delegateSeq(
      61,
      postEnvelope(
        '/api/agents/$createdId',
        createdId,
        <String, dynamic>{},
        method: 'DELETE',
      ),
    );
    check.check(deleteReply['status'], 200, 'agents：DELETE 200');
    check.check(
      replyBody(deleteReply)['removed'],
      <dynamic>[createdId],
      'agents：DELETE removed 含自身',
    );
    check.check(replyBody(deleteReply)['cascade'], false, 'agents：DELETE cascade=false');

    final Map<String, dynamic> goneReply = await delegateSeq(
      62,
      envelope('/api/agents/$createdId', createdId),
    );
    check.check(goneReply['status'], 404, 'agents：删除后 GET ⇒ 404');
    final Map<String, dynamic> againReply = await delegateSeq(
      63,
      postEnvelope(
        '/api/agents/$createdId',
        createdId,
        <String, dynamic>{},
        method: 'DELETE',
      ),
    );
    check.check(againReply['status'], 404, 'agents：再次 DELETE ⇒ 404');

    // ── S1：spec 工具（agent_tools 的 spec.* + 工作空间 IO）────────────
    check.that(
      AgentRuntime.agentToolCommands.toSet().containsAll(<String>[
        'spec.list',
        'spec.read',
        'spec.select',
        'spec.reset',
      ]),
      'agent_tools：申报 spec.* 命令',
      actual: '${AgentRuntime.agentToolCommands}',
    );
    final Directory specWorkspace = Directory(
      p.join(temp.path, 'workspaces', 'agt'),
    )..createSync(recursive: true);
    // 假执行站：把 local.* 落到临时工作空间（自检不开真执行站）。
    Future<Map<String, dynamic>> specStation(
      String command,
      Map<String, dynamic> arguments,
      Map<String, dynamic> scope,
    ) async {
      String abs(String relative) =>
          p.join(specWorkspace.path, p.normalize(relative));
      switch (command) {
        case 'local.lease.register':
          // 租约表在插件侧：自检只需要"登记方自己认得这个句柄"。
          return <String, dynamic>{
            'ok': true,
            'lease_id': arguments['local_lease_id'],
            'root': specWorkspace.path,
          };
        case 'local.file.read':
          final String text = await File(
            abs(arguments['path'].toString()),
          ).readAsString();
          return <String, dynamic>{
            'content': text,
            'total_lines': text.split('\n').length,
            'start_line': 1,
            'truncated': false,
          };
        case 'local.file.write':
          final File file = File(abs(arguments['path'].toString()));
          await file.parent.create(recursive: true);
          await file.writeAsString(arguments['content'].toString());
          return <String, dynamic>{
            'bytes_written': arguments['content'].toString().length,
          };
        case 'local.file.list':
          // 与 local_executor 同口径：entries 是**工作空间根为基准的相对路径**
          // （`.self/spec/x.md`），不是裸文件名（SpecService.reset 依赖这一点）。
          final String rel = arguments['path'].toString();
          final Directory dir = Directory(abs(rel));
          return <String, dynamic>{
            'entries': <dynamic>[
              if (dir.existsSync())
                for (final FileSystemEntity entity in dir.listSync())
                  entity is Directory
                      ? '${p.join(rel, p.basename(entity.path))}/'
                      : p.join(rel, p.basename(entity.path)),
            ],
          };
        case 'local.file.delete':
          final File file = File(abs(arguments['path'].toString()));
          final bool deleted = file.existsSync();
          if (deleted) await file.delete();
          return <String, dynamic>{'deleted': deleted};
        case 'local.file.mkdir':
          await Directory(
            abs(arguments['path'].toString()),
          ).create(recursive: true);
          return <String, dynamic>{'ok': true};
        default:
          return <String, dynamic>{'error': '自检假站不处理 $command'};
      }
    }

    AgentRuntime.stationClient = specStation;
    try {
      final AgentRuntime runtime = AgentRuntime.forDataDir(temp.path);
      Future<Map<String, dynamic>> specCall(
        String command, [
        Map<String, dynamic> arguments = const <String, dynamic>{},
      ]) async {
        final Map<String, dynamic> reply = await runtime.handleAgentToolCommand(
          command,
          arguments,
          <String, dynamic>{
            'agent_id': 'agt',
            'session_id': 'session_default',
          },
        );
        final Object? decoded = jsonDecode('${reply['text'] ?? '{}'}');
        return <String, dynamic>{
          'is_error': reply['is_error'] == true,
          'body': decoded is Map
              ? decoded.map(
                  (Object? key, Object? value) =>
                      MapEntry(key.toString(), value),
                )
              : <String, dynamic>{},
        };
      }

      final Map<String, dynamic> specList = await specCall('spec.list');
      check.check(specList['is_error'], false, 'spec.list：不报错');
      final Map<String, dynamic> specListBody =
          (specList['body'] as Map).cast<String, dynamic>();
      check.that(
        ((specListBody['count'] as num?)?.toInt() ?? 0) >=
            kBuiltinSpecIds.length,
        'spec.list：内置规范进入清单',
        actual: '${specListBody['count']}',
      );
      check.that(
        (specListBody['specs'] as List<dynamic>).any(
          (Object? item) => (item as Map)['spec_id'] == 'general-task',
        ),
        'spec.list：general-task 可见（spec_id 键）',
      );
      check.check(
        specListBody['selected_spec_ids'],
        <dynamic>[],
        'spec.list：初始未选择',
      );

      final Map<String, dynamic> specRead = await specCall(
        'spec.read',
        <String, dynamic>{'spec_id': 'general-task'},
      );
      check.check(specRead['is_error'], false, 'spec.read：已知 id 成功');
      check.that(
        '${(specRead['body'] as Map)['content'] ?? ''}'.contains('## '),
        'spec.read：返回规范全文',
      );
      final Map<String, dynamic> specMissing = await specCall(
        'spec.read',
        <String, dynamic>{'spec_id': 'ghost'},
      );
      check.check(specMissing['is_error'], true, 'spec.read：越界 spec_id 报错');
      check.that(
        '${(specMissing['body'] as Map)['error'] ?? ''}'.contains(
          'Spec 不存在: ghost',
        ),
        'spec.read：越界错误可读',
        actual: '${(specMissing['body'] as Map)['error']}',
      );

      final File customSpec = File(
        p.join(specWorkspace.path, '.self', 'spec', 'my-custom.md'),
      );
      await customSpec.parent.create(recursive: true);
      await customSpec.writeAsString(
        '---\nid: my-custom\ntitle: 自检自定义规范\n---\n\n正文\n',
      );
      final Map<String, dynamic> specReset = await specCall('spec.reset');
      check.check(specReset['is_error'], false, 'spec.reset：不报错');
      final Map<String, dynamic> specResetBody =
          (specReset['body'] as Map).cast<String, dynamic>();
      check.check(specResetBody['action'], 'reset', 'spec.reset：回动作');
      check.that(
        (specResetBody['backed_up'] as List<dynamic>? ?? <dynamic>[]).any(
          (Object? item) => '$item'.contains('my-custom.md'),
        ),
        'spec.reset：自定义规范进备份',
        actual: '${specResetBody['backed_up']}',
      );
      check.that(
        !customSpec.existsSync(),
        'spec.reset：自定义规范已移走',
      );
      check.that(
        File('${customSpec.path}.bak.1').existsSync(),
        'spec.reset：备份文件可找回',
      );
      check.that(
        (specResetBody['restored'] as List<dynamic>? ?? <dynamic>[]).contains(
          '.self/spec/general-task.md',
        ),
        'spec.reset：重建内置规范',
      );
      check.that(
        File(
          p.join(
            specWorkspace.path,
            '.self',
            'spec',
            'general-task.md',
          ),
        ).existsSync(),
        'spec.reset：内置文件已落盘',
      );

      // 可选动作 select：挂 hook 并回全文，随后 list 能读到会话级选择。
      final Map<String, dynamic> specSelect = await specCall(
        'spec.select',
        <String, dynamic>{
          'spec_ids': <String>['general-task'],
        },
      );
      check.check(specSelect['is_error'], false, 'spec.select：可选动作成功');
      check.check(
        (specSelect['body'] as Map)['count'],
        1,
        'spec.select：回所选条数',
      );
      final Map<String, dynamic> specListAfter = await specCall('spec.list');
      check.check(
        (specListAfter['body'] as Map)['selected_spec_ids'],
        <dynamic>['general-task'],
        'spec.list：读到本会话已选',
      );
    } finally {
      AgentRuntime.stationClient = null;
    }

    // 生成是异步的：等它收尾再删临时目录。
    await AgentRuntime.forDataDir(temp.path).waitIdle();
    await AgentRuntime.debugCloseAll();

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
