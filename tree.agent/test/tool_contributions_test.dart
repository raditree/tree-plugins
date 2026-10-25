import 'package:test/test.dart';
import 'package:tree_agent_loop/src/station/tool_contributions.dart';
import 'package:tree_agent_loop/src/tool/station_tool_runner.dart';
import 'package:tree_agent_loop/src/tool/tool_runner.dart';

void main() {
  test('站点身份 / schema / readme', () {
    expect(toolCollectStationId('tree.agent'), 'plugin.tree.agent.collect.tools');
    expect(kToolCollectName, 'tools');
    final Map<String, dynamic> schema = toolCollectSchema();
    expect(schema['kind'], 'object');
    final List<dynamic> fields = schema['fields'] as List<dynamic>;
    expect((fields.single as Map)['name'], 'tools');
    expect(kToolCollectReadme, contains('tool.call'));
  });

  test('解析收集回包：坏条目跳过，工具名带命名空间', () {
    final List<ContributedTool> tools = parseContributedTools(<String, dynamic>{
      'result': <String, dynamic>{
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'plugin_id': 'tree.sample',
            'payload': <String, dynamic>{
              'tools': <Map<String, dynamic>>[
                <String, dynamic>{
                  'name': 'query',
                  'description': '查一条',
                  'parameters': <String, dynamic>{'type': 'object'},
                },
                <String, dynamic>{'description': '没有名字'},
              ],
            },
          },
          <String, dynamic>{'plugin_id': '', 'payload': <String, dynamic>{}},
        ],
      },
    });
    expect(tools, hasLength(1));
    expect(tools.single.pluginId, 'tree.sample');
    expect(tools.single.coreName, 'plugin__tree.sample__query');
    expect(tools.single.parameters, <String, dynamic>{'type': 'object'});
  });

  test('贡献工具进入 specs，执行走 tool.call', () async {
    final List<Map<String, dynamic>> calls = <Map<String, dynamic>>[];
    final StationToolRunner runner = StationToolRunner(
      contributed: () => <ContributedTool>[
        const ContributedTool(
          pluginId: 'tree.sample',
          name: 'query',
          description: '查一条',
          parameters: <String, dynamic>{'type': 'object'},
        ),
      ],
      client: (String command, Map<String, dynamic> arguments, Map<String, dynamic> scope) async {
        calls.add(<String, dynamic>{
          'command': command,
          'arguments': arguments,
          'scope': scope,
        });
        return <String, dynamic>{'result': '来自插件的答案', 'is_error': false};
      },
      scopeFor: (String agentId, String sessionId) => <String, dynamic>{
        'agent_id': agentId,
        'team_id': 'top',
        'mode_key': 'local',
        'session_id': sessionId,
      },
    );
    final List<String> names = runner
        .specsFor(agentId: 'agt', sessionId: 's')
        .map((ToolSpec spec) => spec.name)
        .toList();
    expect(names, contains('plugin__tree.sample__query'));
    final ToolOutcome outcome = await runner.run(
      const ToolInvocation(
        id: 'c1',
        name: 'plugin__tree.sample__query',
        arguments: <String, dynamic>{'id': 1},
        agentId: 'agt',
        sessionId: 's',
      ),
    );
    expect(outcome.content, '来自插件的答案');
    expect(outcome.isError, isFalse);
    expect(calls.single['command'], 'plugin.toolCall');
    final Map<String, dynamic> callArgs =
        calls.single['arguments'] as Map<String, dynamic>;
    expect(callArgs['plugin_id'], 'tree.sample');
    expect(callArgs['tool'], 'query');
    expect(
      callArgs['scope'],
      <String, dynamic>{
        'agent_id': 'agt',
        'team_id': 'top',
        'mode_key': 'local',
        'session_id': 's',
      },
      reason: '领域身份放 payload；核心不解析这些字段',
    );
    expect(calls.single['scope'], isEmpty, reason: '顶层 scope 留空');
  });
}