// extra-tools 的合同测试：五个 ToolSpec 与命令翻译。
//
// 对齐目标（tree_agent_loop / 内置工具）：
// - team / message / subagent：plugins/tree.agent/lib/src/tool/*.dart
// - set_todo_list / ask_user_question：
//   packages/tree_core/lib/src/tool/builtin_tools.dart
//
// 端到端（collect 申报 → tools/call → agent_tools）的断言在 selfTest 里，
// 本文件用「退出码 0」把它挂进 dart test，避免两份夹具漂。
import 'package:test/test.dart';

import '../extra-tools_plugin.dart' as plugin;

Map<String, dynamic> _map(Object? value) => value is Map
    ? value.map(
        (Object? key, Object? item) => MapEntry<String, dynamic>('$key', item),
      )
    : <String, dynamic>{};

Map<String, dynamic> _tool(String name) => plugin.toolSpecs().firstWhere(
  (Map<String, dynamic> spec) => spec['name'] == name,
);

Map<String, dynamic> _params(String name) => _map(_tool(name)['parameters']);

Map<String, dynamic> _props(String name) => _map(_params(name)['properties']);

List<String> _keys(String name) => _props(name).keys.toList();

List<dynamic> _required(String name) =>
    (_params(name)['required'] as List<dynamic>?) ?? const <dynamic>[];

Map<String, dynamic> _prop(String tool, String name) =>
    _map(_props(tool)[name]);

void main() {
  const List<String> names = <String>[
    'set_todo_list',
    'ask_user_question',
    'subagent',
    'team',
    'message',
  ];

  group('ToolSpec 字段对齐 tree_agent_loop / 内置工具', () {
    test('五个工具定义齐全、顺序稳定、名字无命名空间前缀', () {
      expect(plugin.toolSpecs().length, 5);
      expect(
        plugin
            .toolSpecs()
            .map((Map<String, dynamic> spec) => spec['name'])
            .toList(),
        names,
      );
    });

    test('每份定义都有非空 name/description 与 object parameters', () {
      for (final Map<String, dynamic> spec in plugin.toolSpecs()) {
        expect((spec['name'] as String).trim(), isNotEmpty);
        expect((spec['description'] as String).trim(), isNotEmpty);
        final Map<String, dynamic> params = _map(spec['parameters']);
        expect(params['type'], 'object');
        expect(_map(params['properties']), isNotEmpty);
        expect(params['required'], isA<List<dynamic>>());
      }
    });

    test('set_todo_list：action 四值 + todos 条目字段与内置工具一致', () {
      expect(_keys('set_todo_list'), <String>['action', 'todos']);
      expect(_map(_prop('set_todo_list', 'action'))['enum'], <String>[
        'set',
        'update',
        'clear',
        'get',
      ]);
      expect(_required('set_todo_list'), <String>['action']);
      final Map<String, dynamic> items = _map(
        _map(_prop('set_todo_list', 'todos'))['items'],
      );
      expect(items['type'], 'object');
      expect(_map(items['properties']).keys.toList(), <String>[
        'id',
        'content',
        'status',
        'progress',
      ]);
      expect(_map(_map(items['properties'])['status'])['enum'], <String>[
        'pending',
        'in_progress',
        'completed',
        'blocked',
      ]);
      expect(_map(_map(items['properties'])['progress'])['type'], 'integer');
    });

    test('ask_user_question：多问数组 + 单问简写', () {
      expect(_keys('ask_user_question'), <String>[
        'questions',
        'question',
        'options',
      ]);
      expect(_required('ask_user_question'), isEmpty);
      final Map<String, dynamic> items = _map(
        _map(_prop('ask_user_question', 'questions'))['items'],
      );
      expect(items['type'], 'object');
      expect(_map(items['properties']).keys.toList(), <String>[
        'question',
        'options',
      ]);
      expect(items['required'], <String>['question']);
      expect(_map(_prop('ask_user_question', 'question'))['type'], 'string');
      expect(_map(_prop('ask_user_question', 'options'))['type'], 'array');
    });

    test('subagent：task/name/subagent_id/background，task 必填', () {
      expect(_keys('subagent'), <String>[
        'task',
        'name',
        'subagent_id',
        'background',
      ]);
      expect(_required('subagent'), <String>['task']);
      expect(_map(_prop('subagent', 'background'))['type'], 'boolean');
    });

    test('team：15 个参数与 TeamService.actions / 枚举逐字对齐', () {
      expect(_keys('team'), <String>[
        'action',
        'member_name',
        'target_member_id',
        'cascade',
        'name',
        'role',
        'duty',
        'can_lead_team',
        'review_status',
        'approve',
        'work_status',
        'level',
        'comment',
        'system_prompt',
        'scores',
      ]);
      expect(_required('team'), <String>['action']);
      expect(_map(_prop('team', 'action'))['enum'], <String>[
        'list_teams',
        'list_members',
        'create_member',
        'remove_member',
        'query_member',
        'update_member',
        'review_member',
        'query_status',
      ]);
      expect(_map(_prop('team', 'review_status'))['enum'], <String>[
        'approved',
        'rejected',
        'pending_review',
      ]);
      expect(_map(_prop('team', 'work_status'))['enum'], <String>[
        'idle',
        'working',
      ]);
      expect(_map(_prop('team', 'cascade'))['type'], 'boolean');
      expect(_map(_prop('team', 'can_lead_team'))['type'], 'boolean');
      expect(_map(_prop('team', 'approve'))['type'], 'boolean');
      expect(_map(_prop('team', 'level'))['type'], 'integer');
      final Map<String, dynamic> scores = _map(_prop('team', 'scores'));
      expect(scores['type'], 'object');
      expect(_map(scores['properties']).keys.toList(), <String>[
        'quality',
        'efficiency',
        'collaboration',
        'accuracy',
      ]);
      for (final String key in <String>[
        'quality',
        'efficiency',
        'collaboration',
        'accuracy',
      ]) {
        expect(_map(_map(scores['properties'])[key])['type'], 'number');
      }
    });

    test('message：target 三种形态 + files/dest_dir/session_id', () {
      expect(_keys('message'), <String>[
        'action',
        'target_member_id',
        'target_ids',
        'target_member_ids',
        'message',
        'files',
        'dest_dir',
        'session_id',
      ]);
      expect(_required('message'), <String>['action']);
      expect(_map(_prop('message', 'action'))['enum'], <String>[
        'send_message',
        'broadcast',
        'wait_for',
        'list_members',
        'list_teams',
      ]);
      expect(_map(_prop('message', 'target_ids'))['type'], 'array');
      expect(
        _map(_map(_prop('message', 'target_ids'))['items'])['type'],
        'string',
      );
      expect(_map(_prop('message', 'files'))['type'], 'array');
      expect(_map(_map(_prop('message', 'files'))['items'])['type'], 'string');
      expect(_map(_prop('message', 'dest_dir'))['type'], 'string');
      expect(_map(_prop('message', 'session_id'))['type'], 'string');
    });
  });

  group('命令翻译（tools/call → agent_tools）', () {
    test('set_todo_list 四个 action 映射到 todo.*', () {
      for (final String action in <String>['set', 'update', 'clear', 'get']) {
        expect(
          plugin.agentToolCommand('set_todo_list', <String, dynamic>{
            'action': action,
          }),
          'todo.$action',
        );
      }
    });

    test('set_todo_list 缺省 get，且大小写/空白归一', () {
      expect(
        plugin.agentToolCommand('set_todo_list', <String, dynamic>{}),
        'todo.get',
      );
      expect(
        plugin.agentToolCommand('set_todo_list', <String, dynamic>{
          'action': ' UPDATE ',
        }),
        'todo.update',
      );
    });

    test('ask/subagent/team/message 固定落点', () {
      expect(
        plugin.agentToolCommand('ask_user_question', <String, dynamic>{}),
        'question.ask',
      );
      expect(
        plugin.agentToolCommand('subagent', <String, dynamic>{'task': 'x'}),
        'subagent.run',
      );
      expect(
        plugin.agentToolCommand('team', <String, dynamic>{
          'action': 'list_teams',
        }),
        'team.run',
      );
      expect(
        plugin.agentToolCommand('message', <String, dynamic>{
          'action': 'wait_for',
        }),
        'message.run',
      );
    });

    test('未知工具返回 null（与 handleToolCall 的可读错误配套）', () {
      expect(plugin.agentToolCommand('unknown', <String, dynamic>{}), isNull);
      expect(plugin.agentToolCommand('read', <String, dynamic>{}), isNull);
    });

    test('核心命名空间前缀剥离', () {
      expect(plugin.nativeToolName('plugin__extra-tools__team'), 'team');
      expect(
        plugin.nativeToolName('plugin__extra-tools__set_todo_list'),
        'set_todo_list',
      );
      expect(plugin.nativeToolName('team'), 'team');
    });

    test('未上线时未知工具不碰执行站（可读错误而非 late 崩溃）', () async {
      final Map<String, dynamic> result = await plugin.handleToolCall(
        'plugin__extra-tools__nope',
        <String, dynamic>{},
        <String, dynamic>{},
      );
      expect(result['isError'], true);
      expect(
        ((result['content'] as List<dynamic>).first
            as Map<dynamic, dynamic>)['text'],
        contains('未知扩展工具'),
      );
    });
  });

  group('collect 申报', () {
    test('只认 tree.agent 的收集站，回包是五份工具定义', () async {
      final Map<String, dynamic>? reply = await plugin.handleRequest(
        'station/request',
        <String, dynamic>{
          'station_id': plugin.kCollectStation,
          'payload': <String, dynamic>{'action': 'list'},
        },
      );
      expect(reply, isNotNull);
      final Object? tools = reply!['reply']?['payload']?['tools'];
      expect(tools, plugin.toolSpecs());
    });

    test('别的站点/方法不接管（返回 null 让骨架回 -32601）', () async {
      expect(
        await plugin.handleRequest('station/request', <String, dynamic>{
          'station_id': 'plugin.other.collect.tools',
        }),
        isNull,
      );
      expect(
        await plugin.handleRequest('tools/list', <String, dynamic>{}),
        isNull,
      );
    });
  });

  group('假核心 + 假站端到端', () {
    test('collect 申报 → tools/call → tree.agent agent_tools 全链路自检通过', () async {
      final List<String> lines = <String>[];
      final int code = await plugin.selfTest(emit: lines.add);
      expect(code, 0, reason: lines.join('\n'));
    });
  });
}
