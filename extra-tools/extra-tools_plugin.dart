// ignore_for_file: file_names
// extra-tools —— 独立扩展工具插件。
//
// 它只做三件事：向 tree.agent 的工具收集站申报五个工具；把 tools/call 翻译成
// tree.agent 自建领域执行站的命令；把结果转成模型可读文本。
import 'dart:convert';
import 'dart:io';

import '../_kit/plugin_kit.dart';

const String kPluginId = 'extra-tools';
const String kDisplayName = '扩展工具';
const String kVersion = '0.1.0';
const String kCollectStation = 'plugin.tree.agent.collect.tools';
const String kAgentToolsStation = 'plugin.tree.agent.execute.agent_tools';

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

Future<Map<String, dynamic>?> handleRequest(
  String method,
  Map<String, dynamic> params,
) async {
  if (method == M.stationRequest &&
      asString(params['station_id']) == kCollectStation) {
    return <String, dynamic>{
      'reply': <String, dynamic>{
        'payload': <String, dynamic>{'tools': _toolSpecs()},
      },
    };
  }
  return null;
}

Future<Map<String, dynamic>> handleToolCall(
  String name,
  Map<String, dynamic> arguments,
  Map<String, dynamic> scope,
) async {
  final String native = name.startsWith('plugin__')
      ? name.split('__').last
      : name;
  final String? command = _commandFor(native, arguments);
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

Future<Map<String, dynamic>> buildServerCall(
  String command,
  Map<String, dynamic> arguments,
  Map<String, dynamic> scope,
) => _server.channel.command(command, arguments, kAgentToolsStation, scope);

String? _commandFor(String tool, Map<String, dynamic> arguments) {
  switch (tool) {
    case 'set_todo_list':
      final String action = (arguments['action'] ?? 'get').toString();
      return 'todo.${action == 'get' ? 'get' : action}';
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

List<Map<String, dynamic>> _toolSpecs() => <Map<String, dynamic>>[
  <String, dynamic>{
    'name': 'set_todo_list',
    'description': '维护会话待办清单（get/set/update/clear）。',
    'parameters': <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'action': <String, dynamic>{
          'type': 'string',
          'enum': <String>['get', 'set', 'update', 'clear'],
        },
        'todos': <String, dynamic>{
          'type': 'array',
          'items': <String, dynamic>{'type': 'object'},
        },
      },
      'required': <String>['action'],
    },
  },
  <String, dynamic>{
    'name': 'ask_user_question',
    'description': '向用户提问并等待作答（可一次多问）。',
    'parameters': <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'question': <String, dynamic>{'type': 'string'},
        'questions': <String, dynamic>{
          'type': 'array',
          'items': <String, dynamic>{'type': 'object'},
        },
      },
    },
  },
  <String, dynamic>{
    'name': 'subagent',
    'description': '召一个临时员工执行自包含任务（可复用、可后台）。',
    'parameters': <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'task': <String, dynamic>{'type': 'string'},
        'name': <String, dynamic>{'type': 'string'},
        'subagent_id': <String, dynamic>{'type': 'string'},
        'background': <String, dynamic>{'type': 'boolean'},
      },
      'required': <String>['task'],
    },
  },
  <String, dynamic>{
    'name': 'team',
    'description': '团队管理域：建队、成员档案、分工与状态查询。',
    'parameters': <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'action': <String, dynamic>{'type': 'string'},
        'member_name': <String, dynamic>{'type': 'string'},
        'target_member_id': <String, dynamic>{'type': 'string'},
        'role': <String, dynamic>{'type': 'string'},
        'duty': <String, dynamic>{'type': 'string'},
        'cascade': <String, dynamic>{'type': 'boolean'},
      },
      'required': <String>['action'],
    },
  },
  <String, dynamic>{
    'name': 'message',
    'description': '团队通信域：派活、点对点消息、广播、等待完成。',
    'parameters': <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'action': <String, dynamic>{'type': 'string'},
        'target_member_id': <String, dynamic>{'type': 'string'},
        'message': <String, dynamic>{'type': 'string'},
        'files': <String, dynamic>{'type': 'array'},
      },
      'required': <String>['action'],
    },
  },
];

Future<void> main(List<String> args) async {
  if (args.contains('--selftest')) {
    final List<String> errors = <String>[];
    if (_toolSpecs().length != 5) errors.add('工具数不是 5');
    if (_commandFor('set_todo_list', <String, dynamic>{'action': 'set'}) !=
        'todo.set') {
      errors.add('todo 命令映射错误');
    }
    if (_commandFor('team', <String, dynamic>{}) != 'team.run') {
      errors.add('team 命令映射错误');
    }
    if (_commandFor('unknown', <String, dynamic>{}) != null) {
      errors.add('未知工具不应有命令');
    }
    for (final String error in errors) {
      stderr.writeln('[FAIL] $error');
    }
    stderr.writeln(
      errors.isEmpty ? 'extra_tools_plugin 自检：全部通过' : 'extra_tools_plugin 自检：失败',
    );
    exitCode = errors.isEmpty ? 0 : 1;
    return;
  }
  await buildServer().run(stdin);
  try {
    await stdout.flush();
  } catch (_) {}
}