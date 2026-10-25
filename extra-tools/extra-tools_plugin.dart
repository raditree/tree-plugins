// ignore_for_file: file_names
// extra-tools —— 独立扩展工具插件。
//
// 它只做三件事：向 tree.agent 的工具收集站申报五个工具；把 tools/call 翻译成
// tree.agent 自建领域执行站的命令；把结果转成模型可读文本。
//
// 工具声明**逐字段对齐** package:tree_agent_loop 的五个 ToolSpec：
// - team / message / subagent 见 plugins/tree.agent/lib/src/tool/{team_tool,
//   message_tool, subagent_tool}.dart；
// - set_todo_list / ask_user_question 见
//   packages/tree_core/lib/src/tool/builtin_tools.dart（tree.agent 执行站
//   agent_tools 的 todo.* / question.ask 语义与之同口径）。
//
// 依赖纪律不变：不 import 任何核心包（连 tree_agent_loop 也不 import，因为插件
// 要能被独立编译），只复用插件仓骨架 ../_kit/plugin_kit.dart。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../_kit/plugin_kit.dart';

const String kPluginId = 'extra-tools';
const String kDisplayName = '扩展工具';
const String kVersion = '0.2.0';
const String kCollectStation = 'plugin.tree.agent.collect.tools';
const String kAgentToolsStation = 'plugin.tree.agent.execute.agent_tools';

// ── 与 tree_agent_loop / 内置工具同口径的取值表 ──────────────────────────
//
// 这些常量既是工具 schema 的唯一来源，也被自检与单元测试逐字断言：值域漂了的
// 表现是"模型按 schema 传参，执行站按另一套词表判未知 action"。

/// set_todo_list 的四个动作（顺序与内置工具一致）。
const List<String> kTodoActions = <String>['set', 'update', 'clear', 'get'];

/// 待办状态（TodoItem.normalizeStatus 同一份词表）。
const List<String> kTodoStatuses = <String>[
  'pending',
  'in_progress',
  'completed',
  'blocked',
];

/// team 工具的 action（TeamService.actions 同一份词表）。
const List<String> kTeamActions = <String>[
  'list_teams',
  'list_members',
  'create_member',
  'remove_member',
  'query_member',
  'update_member',
  'review_member',
  'query_status',
];

/// message 工具的 action（TeamMessageDispatcher.actions 同一份词表）。
const List<String> kMessageActions = <String>[
  'send_message',
  'broadcast',
  'wait_for',
  'list_members',
  'list_teams',
];

/// team.review_member 的目标状态。
const List<String> kReviewStatuses = <String>[
  'approved',
  'rejected',
  'pending_review',
];

/// team.list_members 的按状态筛选值。
const List<String> kWorkStatuses = <String>['idle', 'working'];

/// 临时员工的缺省显示名（与 SubagentTool.defaultName 一致）。
const String kSubagentDefaultName = '临时员工';

/// 一次 ask_user_question 最多允许的题数（与内置工具同一上限）。
const int kMaxQuestionsPerCall = 10;

late PluginKitServer _server;

PluginKitServer buildServer({bool exitOnShutdown = true}) => PluginKitServer(
  channel: PluginChannel.stdio(kPluginId),
  pluginId: kPluginId,
  displayName: kDisplayName,
  onReady: _onReady,
  onRequest: handleRequest,
  onToolCall: handleToolCall,
  exitOnShutdown: exitOnShutdown,
);

Future<void> _onReady(PluginKitServer server) async {
  _server = server;
  server.channel.log('已上线：v$kVersion（扩展工具）');
  try {
    final Map<String, dynamic> result = await server.channel.request(
      M.stationSubscribe,
      <String, dynamic>{'station_id': kCollectStation},
    );
    server.channel.log(
      '订阅 tree.agent 工具收集站：${result['ok'] == true ? '成功' : result['error']}',
    );
  } catch (error) {
    server.channel.log('订阅工具收集站失败：$error');
  }
}

/// 收集站申报：返回五个工具定义。
///
/// 外露成函数（而不是只藏在 [handleRequest] 里）是为了让单元测试与自检**断言
/// 的就是插件真正申报的那一份**，不另写一份测试夹具。
Future<Map<String, dynamic>?> handleRequest(
  String method,
  Map<String, dynamic> params,
) async {
  if (method == M.stationRequest &&
      asString(params['station_id']) == kCollectStation) {
    return <String, dynamic>{
      'reply': <String, dynamic>{
        'payload': <String, dynamic>{'tools': toolSpecs()},
      },
    };
  }
  return null;
}

/// 去掉核心加的 plugin__<插件id>__ 命名空间前缀。
///
/// 核心把贡献工具登记为 plugin__extra-tools__team，执行时把**同一个名字**交回
/// tools/call；插件只认最后一段。
String nativeToolName(String name) =>
    name.startsWith('plugin__') ? name.split('__').last : name;

/// 工具调用 → tree.agent agent_tools 执行站命令；null = 不是本插件的工具。
///
/// 纯函数（不碰通道、不碰服务），单元测试与自检都直接断言这张映射表：
/// set_todo_list 的 action 直接决定命令名，其余四个工具是固定落点。
String? agentToolCommand(String tool, Map<String, dynamic> arguments) {
  switch (tool) {
    case 'set_todo_list':
      // 缺省 get：历史行为（读取清单是最安全的缺省）；schema 仍把 action 标
      // required，正常模型一定显式传。
      final String action = asString(arguments['action']).toLowerCase();
      return 'todo.${action.isEmpty ? 'get' : action}';
    case 'ask_user_question':
      return 'question.ask';
    case 'subagent':
      return 'subagent.run';
    case 'team':
      return 'team.run';
    case 'message':
      return 'message.run';
    default:
      return null;
  }
}

/// tools/call 的核心：命名空间剥离 + 命令翻译 + 执行站往返 + 结果文本化。
Future<Map<String, dynamic>> handleToolCall(
  String name,
  Map<String, dynamic> arguments,
  Map<String, dynamic> scope,
) async {
  final String native = nativeToolName(name);
  final String? command = agentToolCommand(native, arguments);
  if (command == null) return toolText('未知扩展工具：$name', isError: true);
  try {
    final Map<String, dynamic> result = await buildServerCall(
      command,
      arguments,
      scope,
    );
    final String text = (result['text'] ?? jsonEncode(result)).toString();
    return toolText(text, isError: result['is_error'] == true);
  } catch (error) {
    return toolText('执行失败：$error', isError: true);
  }
}

/// 下行到 tree.agent 自建领域执行站；身份（agent/session/team）随 scope 走。
///
/// 失败（未接线 / 命令被拒）由 PluginChannel.command 抛出
/// CmdFailureException，[handleToolCall] 收敛成模型可读的错误结果。
Future<Map<String, dynamic>> buildServerCall(
  String command,
  Map<String, dynamic> arguments,
  Map<String, dynamic> scope,
) => _server.channel.command(command, arguments, kAgentToolsStation, scope);

// ── 工具定义（逐字段对齐 tree_agent_loop 的 ToolSpec）──────────────────────

/// 五个工具声明（顺序稳定：提示词缓存与测试断言都依赖它）。
List<Map<String, dynamic>> toolSpecs() => <Map<String, dynamic>>[
  _todoSpec(),
  _questionSpec(),
  _subagentSpec(),
  _teamSpec(),
  _messageSpec(),
];

Map<String, dynamic> _todoSpec() => <String, dynamic>{
  'name': 'set_todo_list',
  'description':
      '把任务拆成可跟踪的待办清单并持续汇报进度。action=set 整体替换（返回带 id '
      '的清单）、update 按 id 增量更新、clear 清空、get 读取。'
      '每完成/推进一项就立即 update，不要攒到全部完成才标注。',
  'parameters': <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'action': <String, dynamic>{'type': 'string', 'enum': kTodoActions},
      'todos': <String, dynamic>{
        'type': 'array',
        'description': 'action=set/update 时必填；set 时 content 必填，update 时 id 必填',
        'items': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'id': <String, dynamic>{'type': 'string'},
            'content': <String, dynamic>{'type': 'string'},
            'status': <String, dynamic>{
              'type': 'string',
              'enum': kTodoStatuses,
            },
            'progress': <String, dynamic>{
              'type': 'integer',
              'description': '0~100',
            },
          },
        },
      },
    },
    'required': <String>['action'],
  },
};

Map<String, dynamic> _questionSpec() => <String, dynamic>{
  'name': 'ask_user_question',
  'description':
      '向用户提问并**等待**用户回答（本轮生成会暂停直到作答）。'
      '只在"必须由用户决定/补充信息"时使用；能从工作空间自己查到的不要问。'
      'questions 可以一次问多道（每题各自给 options 候选答案，用户也可以自由输入），'
      '把待确认的事一次问完，别挤牙膏式地反复打断用户；'
      '只有一道题时可用 question/options 简写。'
      '**问题要各自独立**（用户逐题作答后一次性提交）：别把多个决定塞进一道题里。',
  'parameters': <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'questions': <String, dynamic>{
        'type': 'array',
        'description': '要问的问题（1~$kMaxQuestionsPerCall 道；一次问完，用户逐题作答后一次性提交）',
        'items': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'question': <String, dynamic>{
              'type': 'string',
              'description': '这道题的题面',
            },
            'options': <String, dynamic>{
              'type': 'array',
              'items': <String, dynamic>{'type': 'string'},
              'description': '这道题的候选选项（可空；前端渲染为可点选按钮）',
            },
          },
          'required': <String>['question'],
        },
      },
      'question': <String, dynamic>{
        'type': 'string',
        'description': '只有一道题时的简写（与 questions 二选一）',
      },
      'options': <String, dynamic>{
        'type': 'array',
        'items': <String, dynamic>{'type': 'string'},
        'description': '简写形态的候选选项（可空；前端渲染为可点选按钮）',
      },
    },
    'required': <String>[],
  },
};

Map<String, dynamic> _subagentSpec() => <String, dynamic>{
  'name': 'subagent',
  'description':
      '[临时员工] 现场召一个临时员工干活：召之即来、干完还在（同一会话内可复用）。\n'
      '什么时候用：把**边界清晰、能独立完成**的活派出去——多个互不依赖的子任务'
      '（多份文件的同类改动、独立检索与调研、各自可验收的验证），或一件会把自己的'
      '上下文拖长的活；要同时推进几件，就用 background 一次开几个。\n'
      '什么时候不用：单文件小改、自己顺手就能干完的活、验收标准还说不清的事'
      '（先跟用户对齐再派）。\n'
      '它是什么：工作空间与模型**继承你**，工具集继承你的读写/命令/搜索/待办/提问/'
      '规范/MCP/插件工具，但**没有** team / message；它只活在会话里（不写 '
      'agents/<id>.yaml、不进团队名册、不能被 message 寻址）——跨会话的长期协作、'
      '需要正式团队流程（会议 / 名册 / 验收）的活请用 team。\n'
      '调用口径：task 必须**自包含**（它看不到你的会话历史，所需上下文都要写进 '
      'task）；默认阻塞，background=true 时立刻返回并稍后把报告注入本会话；'
      '工具结果里回传的 id（sub_…）就是 subagent_id 复用入口。',
  'parameters': <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'task': <String, dynamic>{
        'type': 'string',
        'description':
            '自包含的指令：背景、涉及的文件/目录、要做什么、验收标准、产出格式。'
            '它看不到你的会话历史，缺的上下文它无从得知。',
      },
      'name': <String, dynamic>{
        'type': 'string',
        'description':
            '显示名（缺省「$kSubagentDefaultName」）：仅用于界面与消息标记；'
            '同一会话内不要求唯一，名称复用有歧义时会报错。',
      },
      'subagent_id': <String, dynamic>{
        'type': 'string',
        'description':
            '复用入口：要复用的临时员工 id（sub_…，工具结果里给过）或它的显示名。'
            '只在**本会话内**有效——临时员工只活在它被召来的那个会话里，'
            '拿别的会话的 id 会得到可读错误。缺省 = 新召一个。',
      },
      'background': <String, dynamic>{
        'type': 'boolean',
        'description':
            'true = 后台执行：立刻返回它的 id，完成后报告注入本会话唤醒你；'
            '可同时开多个并行（它们共享工作空间，按文件/目录划分改写范围）。'
            'false（缺省）= 阻塞：等它跑完，把最终报告作为本次工具结果返回。',
      },
    },
    'required': <String>['task'],
  },
};

Map<String, dynamic> _teamSpec() => <String, dynamic>{
  'name': 'team',
  'description':
      '[团队协作-管理域] 建队、成员档案、分工与状态查询。\n'
      '何时使用：list_teams 查看名下团队；list_members 查看本团队名单与拓扑；'
      'create_member 应用户自然语言要求创建成员（仅限 team leader）；'
      'remove_member 应用户明确要求移除成员（默认连同下级子树）；'
      'query_member/update_member 看/改 role、duty、can_lead_team 等档案；'
      'review_member 应用户明确要求同步放行/驳回；query_status 看实时状态。\n'
      '何时不用：发消息/派活/等待完成用 message 工具。\n'
      '模型边界：本工具**没有**模型能力——create_member/update_member/'
      'review_member 不接受 model_id（传了就报错）。成员模型由用户本人在'
      '「团队成员 → 模型配置」页选择。\n'
      '成员就绪：新成员 model_id 为空、review_status=pending_model，'
      '在用户赋模型并审核通过前不接收也不执行任何消息；list_members 返回'
      'not_ready_count 与 hint。\n'
      '注意：remove_member 只能移除自己的直属/下级成员，不可移除自身或任何上级；'
      '目标仍有下级时必须显式 cascade=true。',
  'parameters': <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'action': <String, dynamic>{
        'type': 'string',
        'description': '[团队协作-管理域] 建队、成员档案、分工与状态查询。',
        'enum': kTeamActions,
      },
      'member_name': <String, dynamic>{
        'type': 'string',
        'description': 'create_member 的新成员名称',
      },
      'target_member_id': <String, dynamic>{
        'type': 'string',
        'description': '目标成员 ID 或名称',
      },
      'cascade': <String, dynamic>{
        'type': 'boolean',
        'description': 'remove_member 是否连同下级子树（默认 true）',
      },
      'name': <String, dynamic>{
        'type': 'string',
        'description': 'update_member 新名称',
      },
      'role': <String, dynamic>{
        'type': 'string',
        'description': 'create_member/update_member 角色',
      },
      'duty': <String, dynamic>{
        'type': 'string',
        'description': 'create_member/update_member 职责',
      },
      'can_lead_team': <String, dynamic>{
        'type': 'boolean',
        'description': '是否允许再建子团队（默认 true）',
      },
      'review_status': <String, dynamic>{
        'type': 'string',
        'description': 'review_member 目标状态（仅在用户明确要求时同步）',
        'enum': kReviewStatuses,
      },
      'approve': <String, dynamic>{
        'type': 'boolean',
        'description': 'review_status 未提供时生效：true=approved，false=rejected',
      },
      'work_status': <String, dynamic>{
        'type': 'string',
        'description': 'list_members 按实时状态筛选（只读字段）',
        'enum': kWorkStatuses,
      },
      'level': <String, dynamic>{
        'type': 'integer',
        'description': 'list_members 按层级筛选（TOP=0）',
      },
      'comment': <String, dynamic>{
        'type': 'string',
        'description': 'update_member 评价',
      },
      'system_prompt': <String, dynamic>{
        'type': 'string',
        'description': '成员独立系统提示词',
      },
      'scores': <String, dynamic>{
        'type': 'object',
        'description': 'update_member 评分（0~10）',
        'properties': <String, dynamic>{
          'quality': <String, dynamic>{'type': 'number'},
          'efficiency': <String, dynamic>{'type': 'number'},
          'collaboration': <String, dynamic>{'type': 'number'},
          'accuracy': <String, dynamic>{'type': 'number'},
        },
      },
    },
    'required': <String>['action'],
  },
};

Map<String, dynamic> _messageSpec() => <String, dynamic>{
  'name': 'message',
  'description':
      '[团队协作-通信域] 向成员派活、点对点沟通、直属广播、等待交付。\n'
      'send_message：给成员/直属 leader/其他 TOP 发消息（写明工作内容、预期产出与'
      '完成后回复要求）；broadcast：给全部直属成员广播；wait_for：等待成员完成'
      '当前工作（没有静态时长上限：活着的成员一直等，只有心跳丢失 / 未响应的'
      '成员才会被列进 unresponsive 并返回部分结果）；list_members/list_teams：'
      '与 team 工具同一实现。\n'
      '系统不会替你回传任何总结：需要对方知道结果，必须让对方自行 send_message '
      '回发；禁止仅为确认收到/寒暄/复述而互发。\n'
      'files 为本 agent 工作空间内的相对路径，会复制到接收方 .input/<日期>/'
      '（可用 dest_dir 指定目录）；本机与 SSH 成员之间都能投递，跨机时经本机进程'
      '中转、单文件上限 32 MB——超限或路径越界只记该文件失败，其余照投。',
  'parameters': <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'action': <String, dynamic>{
        'type': 'string',
        'description': '[团队协作-通信域] 消息派发、广播、等待完成。',
        'enum': kMessageActions,
      },
      'target_member_id': <String, dynamic>{
        'type': 'string',
        'description': 'send_message 目标：成员 ID/名称、直属 leader、其他 TOP',
      },
      'target_ids': <String, dynamic>{
        'type': 'array',
        'items': <String, dynamic>{'type': 'string'},
        'description': 'send_message 一对多目标列表（与 target_member_id 二选一）',
      },
      'target_member_ids': <String, dynamic>{
        'type': 'string',
        'description': 'wait_for 必填；多个目标用英文逗号分隔',
      },
      'message': <String, dynamic>{
        'type': 'string',
        'description': 'send_message / broadcast 的消息正文',
      },
      'files': <String, dynamic>{
        'type': 'array',
        'items': <String, dynamic>{'type': 'string'},
        'description':
            'send_message 可选：本 agent 工作空间内的相对路径'
            '（本机与 SSH 成员之间都能投递：跨机经本机中转、单文件上限 32 MB；'
            '越界 / 超限只失败该文件，其余照投）',
      },
      'dest_dir': <String, dynamic>{
        'type': 'string',
        'description':
            'files 的目标目录（默认 .input/<日期>）；须是**接收方工作空间内**的'
            '相对路径（空 / 绝对路径 / 盘符 / ~ / .. 逃逸一律拒绝）',
      },
      // 这里**没有** timeout：等待判据是成员活性（心跳丢失 / 未响应才收口）。
      'session_id': <String, dynamic>{
        'type': 'string',
        'description':
            '接收方归集的会话 id（缺省 = 发起这一跳的会话；'
            '显式写 session_default 才会落进对方的默认会话）',
      },
    },
    'required': <String>['action'],
  },
};

// ── 自检：假核心 + 假 agent_tools 站，跑真读循环 ─────────────────────────

/// --selftest 的完整回路：hello → 订阅收集站 → 收集站申报 → tools/call
/// → station/command（tree.agent agent_tools 站）→ 结果回到模型。
///
/// 假核心是同进程的 FakeCore（与真核心走同一套 JSON-RPC 字节流）；假站按
/// 命令回 {payload:{text,is_error}}，并记录每条命令供断言。自检与 dart test
/// 共用本函数：测试只断言退出码 0，具体断言全在这里（避免两份夹具漂）。
Future<int> selfTest({void Function(String)? emit}) async {
  final SelfTest check = SelfTest(name: 'extra_tools_plugin', emit: emit);
  final PluginKitServer server = buildServer(exitOnShutdown: false);
  final FakeCore core = FakeCore(server);
  final List<Map<String, dynamic>> commands = <Map<String, dynamic>>[];

  core.onMethod(
    M.stationSubscribe,
    (Map<String, dynamic> params) => <String, dynamic>{'ok': true},
  );
  core.onMethod(M.stationCommand, (Map<String, dynamic> params) {
    commands.add(params);
    final String command = asString(params['command']);
    final Map<String, dynamic> arguments = asMap(params['arguments']);
    if (command == 'message.run' && asString(arguments['message']) == 'FAIL') {
      return <String, dynamic>{'ok': false, 'error': '假站：message.run 被拒'};
    }
    return <String, dynamic>{
      'payload': <String, dynamic>{'text': '假站已执行 $command', 'is_error': false},
    };
  });

  final Future<void> serving = core.start();

  const Map<String, dynamic> scope = <String, dynamic>{
    'agent_id': 'agt',
    'session_id': 'ses_1',
    'team_id': 'team_1',
  };

  core.ask(0, M.hello, <String, dynamic>{'plugin_id': kPluginId});
  core.ask(1, M.ping);
  core.ask(2, M.toolsList);
  core.ask(3, M.stationRequest, <String, dynamic>{
    'station_id': kCollectStation,
    'payload': <String, dynamic>{'action': 'list'},
  });
  core.ask(4, M.stationRequest, <String, dynamic>{
    'station_id': 'plugin.other.collect.tools',
    'payload': <String, dynamic>{'action': 'list'},
  });
  core.ask(5, M.toolsCall, <String, dynamic>{
    'name': 'plugin__extra-tools__set_todo_list',
    'arguments': <String, dynamic>{
      'action': 'set',
      'todos': <Map<String, dynamic>>[
        <String, dynamic>{'id': 't1', 'content': '写测试', 'status': 'pending'},
      ],
    },
    'scope': scope,
  });
  core.ask(6, M.toolsCall, <String, dynamic>{
    'name': 'plugin__extra-tools__set_todo_list',
    'arguments': <String, dynamic>{
      'action': 'update',
      'todos': <Map<String, dynamic>>[
        <String, dynamic>{'id': 't1', 'status': 'completed', 'progress': 100},
      ],
    },
    'scope': scope,
  });
  core.ask(7, M.toolsCall, <String, dynamic>{
    'name': 'plugin__extra-tools__set_todo_list',
    'arguments': <String, dynamic>{'action': 'clear'},
    'scope': scope,
  });
  core.ask(8, M.toolsCall, <String, dynamic>{
    'name': 'plugin__extra-tools__set_todo_list',
    'arguments': <String, dynamic>{},
    'scope': scope,
  });
  core.ask(9, M.toolsCall, <String, dynamic>{
    'name': 'plugin__extra-tools__ask_user_question',
    'arguments': <String, dynamic>{
      'questions': <Map<String, dynamic>>[
        <String, dynamic>{
          'question': '选哪个',
          'options': <String>['A', 'B'],
        },
      ],
    },
    'scope': scope,
  });
  core.ask(10, M.toolsCall, <String, dynamic>{
    'name': 'plugin__extra-tools__subagent',
    'arguments': <String, dynamic>{
      'task': '整理日志',
      'name': '日志工',
      'background': true,
    },
    'scope': scope,
  });
  core.ask(11, M.toolsCall, <String, dynamic>{
    'name': 'plugin__extra-tools__team',
    'arguments': <String, dynamic>{
      'action': 'list_members',
      'work_status': 'working',
      'level': 1,
    },
    'scope': scope,
  });
  core.ask(12, M.toolsCall, <String, dynamic>{
    'name': 'plugin__extra-tools__message',
    'arguments': <String, dynamic>{
      'action': 'send_message',
      'target_member_id': 'agt_m',
      'message': '把测试跑完再回我',
      'files': <String>['lib/a.dart'],
      'dest_dir': '.input/2026-10-25',
      'session_id': 'ses_1',
    },
    'scope': scope,
  });
  core.ask(13, M.toolsCall, <String, dynamic>{
    'name': 'plugin__extra-tools__not_a_tool',
    'arguments': <String, dynamic>{},
    'scope': scope,
  });
  core.ask(14, M.toolsCall, <String, dynamic>{
    'name': 'plugin__extra-tools__message',
    'arguments': <String, dynamic>{
      'action': 'send_message',
      'target_member_id': 'agt_m',
      'message': 'FAIL',
    },
    'scope': scope,
  });
  core.ask(15, 'no_such/method');

  final Map<Object?, Map<String, dynamic>> byId = await core.waitFor(<int>[
    0,
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    8,
    9,
    10,
    11,
    12,
    13,
    14,
    15,
  ]);

  Map<String, dynamic> resultOf(int id) {
    final Object? result = byId[id]?['result'];
    return result is Map ? asMap(result) : <String, dynamic>{};
  }

  String textOf(Map<String, dynamic> result) {
    final Object? content = result['content'];
    if (content is! List || content.isEmpty) return '';
    return asString(asMap(content.first)['text']);
  }

  List<String> commandNames() => <String>[
    for (final Map<String, dynamic> params in commands)
      asString(params['command']),
  ];

  check.that(byId.length == 16, '十六条请求都有回包', actual: '${byId.length}');
  check.check(resultOf(0)['plugin_id'], kPluginId, 'hello 自报 plugin_id');
  check.check(resultOf(0)['name'], kDisplayName, 'hello 自报展示名');
  check.check(resultOf(1)['ok'], true, 'ping 回 ok');
  check.check(
    resultOf(2)['tools'],
    <dynamic>[],
    'tools/list 为空（工具经收集站贡献，不在 tools/list 里重复申报）',
  );

  final List<Map<String, dynamic>> subscribed = core.outgoing(
    M.stationSubscribe,
  );
  check.check(subscribed.length, 1, 'hello 后订阅收集站一次');
  check.check(
    asString(
      asMap(
        subscribed.isEmpty ? null : subscribed.first['params'],
      )['station_id'],
    ),
    kCollectStation,
    '订阅的站 id 是 plugin.tree.agent.collect.tools',
  );

  final Map<String, dynamic> collect = resultOf(3);
  check.check(
    collect['reply']?['payload']?['tools'],
    toolSpecs(),
    '收集站回包 = 插件真正申报的五份 ToolSpec',
  );
  final Object? unknownStation = byId[4]?['error'];
  check.check(
    unknownStation is Map ? unknownStation['code'] : null,
    -32601,
    '别人家的站 id 不接管（-32601，不猜）',
  );

  check.check(commandNames(), <String>[
    'todo.set',
    'todo.update',
    'todo.clear',
    'todo.get',
    'question.ask',
    'subagent.run',
    'team.run',
    'message.run',
    'message.run',
  ], '五个工具共九次调用各自翻译成 agent_tools 命令（含 FAIL 那次）');

  // 每条命令都带执行站 id + 身份 scope（核心按目标 agent 的真实归属解析）。
  final Map<String, dynamic> first = commands.isEmpty
      ? <String, dynamic>{}
      : commands.first;
  check.check(first['station_id'], kAgentToolsStation, '命令带 agent_tools 站 id');
  check.check(first['agent_id'], 'agt', 'scope.agent_id 透传');
  check.check(first['session_id'], 'ses_1', 'scope.session_id 透传');
  check.check(first['team_id'], 'team_1', 'scope.team_id 透传');
  check.check(first['arguments'], <String, dynamic>{
    'action': 'set',
    'todos': <Map<String, dynamic>>[
      <String, dynamic>{'id': 't1', 'content': '写测试', 'status': 'pending'},
    ],
  }, 'todo.set 参数原样交给执行站');

  Map<String, dynamic> commandOf(String name) => commands.firstWhere(
    (Map<String, dynamic> params) => asString(params['command']) == name,
    orElse: () => <String, dynamic>{},
  );
  check.check(commandOf('team.run')['arguments'], <String, dynamic>{
    'action': 'list_members',
    'work_status': 'working',
    'level': 1,
  }, 'team.run 参数原样交给执行站（含对齐后的 work_status/level）');
  check.check(commandOf('message.run')['arguments'], <String, dynamic>{
    'action': 'send_message',
    'target_member_id': 'agt_m',
    'message': '把测试跑完再回我',
    'files': <String>['lib/a.dart'],
    'dest_dir': '.input/2026-10-25',
    'session_id': 'ses_1',
  }, 'message.run 参数原样交给执行站（含 target/files/dest_dir/session_id）');

  for (int id = 5; id <= 12; id++) {
    final Map<String, dynamic> result = resultOf(id);
    check.check(result['isError'], false, '工具调用 $id 成功');
    check.that(
      textOf(result).startsWith('假站已执行 '),
      '工具调用 $id 结果文本来自执行站',
      actual: textOf(result),
    );
  }
  check.check(textOf(resultOf(5)), '假站已执行 todo.set', 'todo.set 结果文本化');
  check.check(textOf(resultOf(9)), '假站已执行 question.ask', 'question.ask 结果文本化');

  check.check(resultOf(13)['isError'], true, '未知工具回错误');
  check.that(
    textOf(resultOf(13)).contains('未知扩展工具'),
    '未知工具错误可读',
    actual: textOf(resultOf(13)),
  );
  check.check(commands.length, 9, '未知工具不下发执行站命令');

  check.check(resultOf(14)['isError'], true, '执行站拒绝 ⇒ isError');
  check.that(
    textOf(resultOf(14)).contains('假站：message.run 被拒'),
    '执行站拒绝原因原样带给模型',
    actual: textOf(resultOf(14)),
  );

  final Object? unknownMethod = byId[15]?['error'];
  check.check(
    unknownMethod is Map ? unknownMethod['code'] : null,
    -32601,
    '未知方法回 -32601（不静默丢弃）',
  );

  await core.close();
  await serving;
  return check.finish(core.logs);
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
