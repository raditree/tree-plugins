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

  StationToolRunner runnerFor({
    String agentId = 'agt',
    Future<ToolOutcome> Function(ToolInvocation invocation)? toolRuns,
  }) {
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
        case 'local.file.read':
          final content = await io.readFile(arguments['path'].toString());
          return <String, dynamic>{
            'path': arguments['path'],
            'content': content.text,
            'total_lines': content.text.split('\n').length,
            'start_line': 1,
            'truncated': false,
          };
        case 'local.file.write':
          final bytes = await io.writeFile(
            arguments['path'].toString(),
            arguments['content'].toString(),
          );
          return <String, dynamic>{'bytes_written': bytes};
        case 'local.file.list':
          final entries = await io.listFiles(
            relativePath: arguments['path'].toString(),
          );
          return <String, dynamic>{'entries': entries};
        case 'local.file.grep':
          return <String, dynamic>{
            'matches': <Map<String, dynamic>>[
              <String, dynamic>{'path': '.self/a.md', 'line': 1, 'text': '命中'},
            ],
          };
        case 'local.exec.command':
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
      toolRunsRunner: toolRuns,
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
    expect(names, <String>['read', 'write', 'list', 'grep', 'terminal', 'edit']);
  });

  test('edit：唯一匹配替换；重复匹配需 replace_all', () async {
    final StationToolRunner runner = runnerFor();
    await io.writeFile('notes/a.md', 'alpha beta alpha');
    final ToolOutcome unique = await runner.run(
      const ToolInvocation(
        id: 'e1',
        name: 'edit',
        arguments: <String, dynamic>{
          'file_path': 'notes/a.md',
          'old_text': 'beta',
          'new_text': 'BETA',
        },
        agentId: 'agt',
        sessionId: 'session_default',
      ),
    );
    expect(unique.isError, isFalse, reason: unique.content);
    expect(File(p.join(temp.path, 'notes', 'a.md')).readAsStringSync(), 'alpha BETA alpha');

    final ToolOutcome ambiguous = await runner.run(
      const ToolInvocation(
        id: 'e2',
        name: 'edit',
        arguments: <String, dynamic>{
          'file_path': 'notes/a.md',
          'old_text': 'alpha',
          'new_text': 'A',
        },
        agentId: 'agt',
        sessionId: 'session_default',
      ),
    );
    expect(ambiguous.isError, isTrue);
    expect(ambiguous.content, contains('2 次'));

    final ToolOutcome all = await runner.run(
      const ToolInvocation(
        id: 'e3',
        name: 'edit',
        arguments: <String, dynamic>{
          'file_path': 'notes/a.md',
          'old_text': 'alpha',
          'new_text': 'A',
          'replace_all': true,
        },
        agentId: 'agt',
        sessionId: 'session_default',
      ),
    );
    expect(all.isError, isFalse, reason: all.content);
    expect(File(p.join(temp.path, 'notes', 'a.md')).readAsStringSync(), 'A BETA A');
  });

  test('terminal：hook 参数透传到执行器', () async {
    final StationToolRunner runner = runnerFor();
    await runner.run(
      const ToolInvocation(
        id: 't9',
        name: 'terminal',
        arguments: <String, dynamic>{'command': 'x', 'hook': true},
        agentId: 'agt',
        sessionId: 'session_default',
      ),
    );
    final Map<String, dynamic> last = calls.last;
    expect(last['command'], 'local.exec.command');
    expect((last['arguments'] as Map)['hook'], isTrue);
  });

  test('tool_runs：接线后进工具表，执行落到回调', () async {
    final StationToolRunner runner = runnerFor(
      toolRuns: (ToolInvocation invocation) async =>
          ToolOutcome('runs: ${invocation.arguments['action']}'),
    );
    final List<String> names = runner
        .specsFor(agentId: 'agt', sessionId: 'session_default')
        .map((ToolSpec spec) => spec.name)
        .toList();
    expect(names, contains('tool_runs'));
    final ToolOutcome outcome = await runner.run(
      const ToolInvocation(
        id: 'r1',
        name: 'tool_runs',
        arguments: <String, dynamic>{'action': 'list'},
        agentId: 'agt',
        sessionId: 'session_default',
      ),
    );
    expect(outcome.content, 'runs: list');
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