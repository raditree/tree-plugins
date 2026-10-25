import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_agent_loop/src/tool/station_tool_runner.dart';
import 'package:tree_agent_loop/src/tool/tool_runner.dart';

import 'test_workspace_io.dart';

/// 执行站工具层：read/write/list/grep/terminal 全部经 station/command。
void main() {
  late Directory temp;
  late TestWorkspaceIO io;
  late List<Map<String, dynamic>> calls;

  StationToolRunner runnerFor({String agentId = 'agt'}) {
    Future<Map<String, dynamic>> client(
      String command,
      Map<String, dynamic> arguments,
      Map<String, dynamic> scope,
    ) async {
      calls.add(<String, dynamic>{
        'command': command,
        'arguments': arguments,
        'scope': scope,
      });
      switch (command) {
        case 'fs.read':
          final content = await io.readFile(arguments['path'].toString());
          return <String, dynamic>{
            'path': arguments['path'],
            'content': content.text,
            'total_lines': content.text.split('\n').length,
            'start_line': 1,
            'truncated': false,
          };
        case 'fs.write':
          final bytes = await io.writeFile(
            arguments['path'].toString(),
            arguments['content'].toString(),
          );
          return <String, dynamic>{'bytes_written': bytes};
        case 'fs.list':
          final entries = await io.listFiles(
            relativePath: arguments['path'].toString(),
          );
          return <String, dynamic>{'entries': entries};
        case 'fs.grep':
          return <String, dynamic>{
            'matches': <Map<String, dynamic>>[
              <String, dynamic>{'path': '.self/a.md', 'line': 1, 'text': '命中'},
            ],
          };
        case 'terminal.exec':
          return <String, dynamic>{
            'text': 'exit=0\nhello',
            'is_error': false,
          };
        default:
          throw StateError('未知命令：$command');
      }
    }
    return StationToolRunner(
      client: client,
      scopeFor: (String agentId, String sessionId) => <String, dynamic>{
        'agent_id': agentId,
        'team_id': 'top',
        'mode_key': 'local',
        if (sessionId.isNotEmpty) 'session_id': sessionId,
      },
    );
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_agent_tools_');
    io = TestWorkspaceIO(temp.path);
    calls = <Map<String, dynamic>>[];
  });

  tearDown(() {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('specs：read/write/list/grep/terminal 都声明', () {
    final StationToolRunner runner = runnerFor();
    final names = runner
        .specsFor(agentId: 'agt', sessionId: 'session_default')
        .map((ToolSpec spec) => spec.name)
        .toList();
    expect(names, <String>['read', 'write', 'list', 'grep', 'terminal']);
  });

  test('read/write/list：经执行站读写工作空间，scope 带身份', () async {
    final StationToolRunner runner = runnerFor();
    final ToolOutcome written = await runner.run(
      const ToolInvocation(
        id: 't1',
        name: 'write',
        arguments: <String, dynamic>{'path': '.self/a.md', 'content': 'hello'},
        agentId: 'agt',
        sessionId: 'session_default',
      ),
    );
    expect(written.isError, isFalse);
    expect(File(p.join(temp.path, '.self', 'a.md')).readAsStringSync(), 'hello');

    final ToolOutcome read = await runner.run(
      const ToolInvocation(
        id: 't2',
        name: 'read',
        arguments: <String, dynamic>{'path': '.self/a.md'},
        agentId: 'agt',
        sessionId: 'session_default',
      ),
    );
    expect(read.content, 'hello');

    final ToolOutcome listed = await runner.run(
      const ToolInvocation(
        id: 't3',
        name: 'list',
        arguments: <String, dynamic>{'path': '.self'},
        agentId: 'agt',
        sessionId: 'session_default',
      ),
    );
    expect(listed.content, contains('a.md'));
    expect(calls.first['scope'], <String, dynamic>{
      'agent_id': 'agt',
      'team_id': 'top',
      'mode_key': 'local',
      'session_id': 'session_default',
    });
  });

  test('grep / terminal：回包格式化成模型可读文本', () async {
    final StationToolRunner runner = runnerFor();
    final ToolOutcome grep = await runner.run(
      const ToolInvocation(
        id: 't4',
        name: 'grep',
        arguments: <String, dynamic>{'pattern': '命中'},
        agentId: 'agt',
        sessionId: 'session_default',
      ),
    );
    expect(grep.content, contains('.self/a.md:1: 命中'));

    final ToolOutcome terminal = await runner.run(
      const ToolInvocation(
        id: 't5',
        name: 'terminal',
        arguments: <String, dynamic>{'command': 'echo hello'},
        agentId: 'agt',
        sessionId: 'session_default',
      ),
    );
    expect(terminal.isError, isFalse);
    expect(terminal.content, contains('hello'));
  });

  test('参数缺失给可读错误；执行站异常收敛成工具错误', () async {
    final StationToolRunner runner = StationToolRunner(
      client: (String command, Map<String, dynamic> arguments, Map<String, dynamic> scope) async {
        throw StateError('station down');
      },
      scopeFor: (String agentId, String sessionId) => <String, dynamic>{'agent_id': agentId},
    );
    expect(
      (await runner.run(
        const ToolInvocation(
          id: 't6',
          name: 'read',
          arguments: <String, dynamic>{},
          agentId: 'agt',
          sessionId: 's',
        ),
      )).isError,
      isTrue,
    );
    final ToolOutcome failed = await runner.run(
      const ToolInvocation(
        id: 't7',
        name: 'read',
        arguments: <String, dynamic>{'path': 'x'},
        agentId: 'agt',
        sessionId: 's',
      ),
    );
    expect(failed.isError, isTrue);
    expect(failed.content, contains('station down'));
  });
}