import 'dart:async';

import 'package:test/test.dart';
import 'package:tree_agent_loop/src/tool/terminal_hook_manager.dart';
import 'package:tree_agent_loop/src/tool/tool_runner.dart';

void main() {
  test('start：登记任务并轮询到结束，唤醒 agent', () async {
    final List<Map<String, dynamic>> calls = <Map<String, dynamic>>[];
    final List<String> wakes = <String>[];
    int statusCalls = 0;
    final TerminalHookManager manager = TerminalHookManager(
      pollInterval: const Duration(milliseconds: 5),
      client: (
        String command,
        Map<String, dynamic> arguments,
        Map<String, dynamic> scope,
      ) async {
        calls.add(<String, dynamic>{'command': command, 'arguments': arguments});
        if (arguments['hook_action'] == 'status') {
          statusCalls++;
          return <String, dynamic>{'text': '状态', 'running': false, 'exit_code': 0};
        }
        if (arguments['hook_action'] == 'cancel') {
          return <String, dynamic>{'text': '已请求终止', 'running': false};
        }
        return <String, dynamic>{
          'text': '[terminal hook] 已启动',
          'task_id': 'hook_1',
          'log_relative': '.self/hooks/hook_1.log',
        };
      },
      scopeFor: (String agentId, String sessionId) => <String, dynamic>{
        'agent_id': agentId,
        'session_id': sessionId,
      },
      wake: (String agentId, String sessionId, String notice) async {
        wakes.add(notice);
      },
    );
    final ToolOutcome started = await manager.start(
      const ToolInvocation(
        id: 't1',
        name: 'terminal',
        arguments: <String, dynamic>{'command': 'sleep 1', 'hook': true},
        agentId: 'agt',
        sessionId: 's',
      ),
    );
    expect(started.isError, isFalse);
    expect(started.content, contains('hook_1'));
    expect((calls.first['arguments'] as Map)['hook'], isTrue);
    expect(manager.listVisible('agt', 's').single.id, 'hook_1');

    final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
    while (wakes.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(statusCalls, greaterThan(0));
    expect(wakes.single, contains('[terminal hook]'));
    expect(wakes.single, contains('exit_code'));
    expect(manager.find('hook_1')!.running, isFalse);
  });

  test('status/cancel：未知 task_id 给可读错误，已知任务可取消', () async {
    final TerminalHookManager manager = TerminalHookManager(
      pollInterval: const Duration(seconds: 30),
      client: (
        String command,
        Map<String, dynamic> arguments,
        Map<String, dynamic> scope,
      ) async {
        if (arguments['hook_action'] == 'cancel') {
          return <String, dynamic>{'text': '已请求终止', 'running': false};
        }
        return <String, dynamic>{
          'text': '已启动',
          'task_id': 'hook_2',
          'log_relative': '.self/hooks/hook_2.log',
        };
      },
      scopeFor: (String agentId, String sessionId) => <String, dynamic>{
        'agent_id': agentId,
      },
      wake: (String agentId, String sessionId, String notice) async {},
    );
    expect((await manager.status('nope')).isError, isTrue);
    await manager.start(
      const ToolInvocation(
        id: 't2',
        name: 'terminal',
        arguments: <String, dynamic>{'command': 'x', 'hook': true},
        agentId: 'agt',
        sessionId: 's',
      ),
    );
    final ToolOutcome cancelled = await manager.cancel('hook_2');
    expect(cancelled.content, contains('已请求终止'));
    expect(manager.find('hook_2')!.running, isFalse);
  });
}