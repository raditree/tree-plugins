import 'dart:io';

import 'package:test/test.dart';

import 'package:tree_agent_loop/src/agent/memory_service.dart';
import 'package:tree_agent_loop/src/agent/private_paths.dart';
import 'package:tree_agent_loop/src/station/agent_tools.dart';
import 'package:tree_agent_loop/src/workspace/workspace_io.dart';

import 'test_workspace_io.dart';

void main() {
  late Directory dir;
  late TestWorkspaceIO io;
  late MemoryService service;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('memory_service_test_');
    io = TestWorkspaceIO(dir.path);
    service = MemoryService(
      ioFor: (String agentId, String sessionId) async => io,
    );
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('空文件 get：ok、text 空、hash 64 位十六进制', () async {
    final Map<String, dynamic> reply = await service.get(agentId: 'a1');
    expect(reply['ok'], isTrue);
    expect(reply['text'], '');
    expect(reply['total_chars'], 0);
    expect(reply['chars'], 0);
    expect(reply['truncated'], isFalse);
    expect(reply['hash'], matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  test('record 同一 summary 两次：第二次去重、文件只出现一次', () async {
    final Map<String, dynamic> first = await service.record(
      agentId: 'a1',
      summary: '产线跑通了 A 段',
      purpose: 'build',
      taskId: 't1',
    );
    expect(first['ok'], isTrue);
    expect(first['appended'], isTrue);
    expect(first['deduplicated'], isFalse);

    final Map<String, dynamic> second = await service.record(
      agentId: 'a1',
      summary: '产线跑通了 A 段',
      purpose: 'build',
      taskId: 't1',
    );
    expect(second['ok'], isTrue);
    expect(second['appended'], isFalse);
    expect(second['deduplicated'], isTrue);
    expect(second['hash'], first['hash']);

    final String text = await io.readFile(service.memoryPath('a1')).then(
      (FileContent content) => content.text,
    );
    expect('产线跑通了 A 段'.allMatches(text).length, 1);
    expect(text.startsWith(kMemoryHeader), isTrue);
  });

  test('record 后 get 能读到摘要，sources 含记忆路径', () async {
    await service.record(
      agentId: 'a1',
      summary: '记忆内容：先读规范再动手',
      sources: <String>['.self/spec/base.md'],
    );
    final Map<String, dynamic> reply = await service.get(
      agentId: 'a1',
      purpose: 'build',
    );
    expect(reply['text'], contains('记忆内容：先读规范再动手'));
    expect(reply['text'], contains('.self/spec/base.md'));
    expect(reply['purpose'], 'build');
    expect(reply['path'], '${privateSelfDir('a1')}/memory.md');
    expect(reply['sources'], <String>['${privateSelfDir('a1')}/memory.md']);
  });

  test('budget 截断：只保留最近字符并带提示行', () async {
    await io.writeFile(service.memoryPath('a1'), 'x' * 5000);
    final Map<String, dynamic> reply = await service.get(
      agentId: 'a1',
      budgetChars: 200,
    );
    expect(reply['truncated'], isTrue);
    expect(reply['total_chars'], 5000);
    expect(reply['text'], contains(kMemoryTruncationNotice));
    expect(
      (reply['chars'] as int) - kMemoryTruncationNotice.length - 1,
      lessThanOrEqualTo(200),
    );
    expect((reply['text'] as String).endsWith('x' * 200), isTrue);
  });

  test('ioFor 返回 null 或抛异常：memory_unavailable 且不抛', () async {
    final MemoryService missing = MemoryService(
      ioFor: (String agentId, String sessionId) async => null,
    );
    final Map<String, dynamic> reply = await missing.get(agentId: 'a1');
    expect(reply['code'], 'memory_unavailable');
    expect(reply.containsKey('error'), isTrue);

    final MemoryService failing = MemoryService(
      ioFor: (String agentId, String sessionId) async =>
          throw WorkspaceIoException('工作空间炸了'),
    );
    final Map<String, dynamic> recordReply = await failing.record(
      agentId: 'a1',
      summary: '写不进去',
    );
    expect(recordReply['code'], 'memory_unavailable');
  });

  test('回包键形状固定', () async {
    final Map<String, dynamic> reply = await service.get(agentId: 'a1');
    expect(reply.keys.toSet(), <String>{
      'ok',
      'agent_id',
      'purpose',
      'path',
      'text',
      'hash',
      'chars',
      'total_chars',
      'truncated',
      'sources',
    }.toSet());
  });

  test('宿主命令清单含记忆命令', () {
    expect(
      kAgentHostCommands,
      containsAll(<String>['agent.memory.get', 'agent.memory.record']),
    );
  });
}
