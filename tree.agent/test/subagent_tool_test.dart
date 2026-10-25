import 'package:test/test.dart';
import 'package:tree_agent_loop/src/tool/subagent_tool.dart';
import 'package:tree_agent_loop/src/tool/tool_runner.dart';

class _FakeChannel implements SubagentChannel {
  final List<SubagentRequest> requests = <SubagentRequest>[];

  @override
  Future<ToolOutcome> run(SubagentRequest request) async {
    requests.add(request);
    return const ToolOutcome('已派出');
  }

  @override
  bool isSubagent(String agentId) => agentId.startsWith('sub_');

  @override
  SubagentTag? tagOf(String agentId) => null;

  @override
  String privateOwnerOf(String agentId) => agentId;

  @override
  List<SubagentTag> directSubagentsOf(String agentId, String sessionId) =>
      const <SubagentTag>[];
}

ToolInvocation invocation(Map<String, dynamic> arguments) => ToolInvocation(
  id: 'tool_1',
  name: SubagentTool.name,
  arguments: arguments,
  agentId: 'agt',
  sessionId: 'session_default',
);

void main() {
  test('spec：名字/说明/参数 schema 与核心一致', () {
    final ToolSpec spec = SubagentTool.spec();
    expect(spec.name, 'subagent');
    expect(spec.description, contains('临时员工'));
    final Map<String, dynamic> params = spec.parameters;
    expect(params['type'], 'object');
    final Map<String, dynamic> props = params['properties'] as Map<String, dynamic>;
    expect(
      props.keys,
      containsAll(<String>['task', 'name', 'subagent_id', 'background']),
    );
    expect(params['required'], <String>['task']);
  });

  test('形状校验：缺 task / 空 task 给可读错误，不进入通道', () async {
    final _FakeChannel channel = _FakeChannel();
    final ToolOutcome missing = await SubagentTool.run(
      invocation(<String, dynamic>{}),
      channel,
    );
    expect(missing.isError, isTrue);
    expect(missing.content, contains('缺少 task'));
    final ToolOutcome blank = await SubagentTool.run(
      invocation(<String, dynamic>{'task': '   '}),
      channel,
    );
    expect(blank.isError, isTrue);
    expect(blank.content, contains('task 不能为空'));
    expect(channel.requests, isEmpty);
  });

  test('正常请求：task 去空白、空名字用默认名、background 宽容解析、复用入口透传', () async {
    final _FakeChannel channel = _FakeChannel();
    await SubagentTool.run(
      invocation(<String, dynamic>{
        'task': '  整理日志  ',
        'subagent_id': '  sub_1 ',
        'background': 'yes',
      }),
      channel,
    );
    final SubagentRequest request = channel.requests.single;
    expect(request.task, '整理日志');
    expect(request.name, SubagentTool.defaultName);
    expect(request.reuseRef, 'sub_1');
    expect(request.background, isTrue);
    expect(request.invocation.id, 'tool_1');
  });

  test('SubagentTag.frameFields：空名字/父节点不写，level 恒写', () {
    const SubagentTag tag = SubagentTag(
      id: 'sub_1',
      name: '',
      parentId: '',
      level: 1,
    );
    expect(tag.frameFields, <String, dynamic>{
      'subagent_id': 'sub_1',
      'subagent_level': 1,
    });
  });
}
