import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

/// Task 6.4：产线记忆端口——只交元数据，绝不抛，绝不把正文当落盘内容。
void main() {
  const String hash =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  test('read：正常回包只取 text / hash / sources / chars / truncated', () async {
    String? gotAgent;
    String? gotPurpose;
    int? gotBudget;
    final MemoryPort port = MemoryPort(
      get:
          (
            String agentId,
            String purpose,
            int budgetChars,
            Map<String, Object?> scope,
          ) async {
            gotAgent = agentId;
            gotPurpose = purpose;
            gotBudget = budgetChars;
            return <String, Object?>{
              'ok': true,
              'agent_id': agentId,
              'purpose': purpose,
              'path': '.self/memory.md',
              'text': '上次结论：不动数据库',
              'hash': hash,
              'chars': 10,
              'total_chars': 10,
              'truncated': true,
              'sources': <String>['line/pl_demo/task/T1'],
            };
          },
    );
    final MemoryView view = await port.read(
      agentId: 'agt',
      purpose: 'production.prepare.recon',
    );
    expect(gotAgent, 'agt');
    expect(gotPurpose, 'production.prepare.recon');
    expect(gotBudget, 4000);
    expect(view.unavailable, isFalse);
    expect(view.text, '上次结论：不动数据库');
    expect(view.hash, hash);
    expect(view.sources, <String>['line/pl_demo/task/T1']);
    expect(view.chars, 10);
    expect(view.truncated, isTrue);
    expect(view.code, '');
  });

  test('read：get 抛异常 ⇒ unavailable + memory_unavailable（不抛）', () async {
    final MemoryPort port = MemoryPort(
      get:
          (
            String agentId,
            String purpose,
            int budgetChars,
            Map<String, Object?> scope,
          ) async => throw StateError('通道断了'),
    );
    final MemoryView view = await port.read(
      agentId: 'agt',
      purpose: 'production.prepare.recon',
    );
    expect(view.unavailable, isTrue);
    expect(view.code, 'memory_unavailable');
    expect(view.text, isEmpty);
    expect(view.hash, isEmpty);
  });

  test('read：回包带 error / ok=false 都降级；空 agent 直接不可用', () async {
    final MemoryPort withError = MemoryPort(
      get:
          (
            String agentId,
            String purpose,
            int budgetChars,
            Map<String, Object?> scope,
          ) async => <String, Object?>{'error': '记忆不可读'},
    );
    final MemoryView failure = await withError.read(
      agentId: 'agt',
      purpose: 'production.task.pack',
    );
    expect(failure.unavailable, isTrue);
    expect(failure.code, 'memory_unavailable');

    final MemoryPort withOkFalse = MemoryPort(
      get:
          (
            String agentId,
            String purpose,
            int budgetChars,
            Map<String, Object?> scope,
          ) async => <String, Object?>{'ok': false, 'text': '不该用'},
    );
    expect(
      (await withOkFalse.read(
        agentId: 'agt',
        purpose: 'production.task.pack',
      )).unavailable,
      isTrue,
    );

    int calls = 0;
    final MemoryPort counting = MemoryPort(
      get:
          (
            String agentId,
            String purpose,
            int budgetChars,
            Map<String, Object?> scope,
          ) async {
            calls += 1;
            return <String, Object?>{'ok': true, 'text': 'x'};
          },
    );
    expect(
      (await counting.read(
        agentId: '  ',
        purpose: 'production.prepare.recon',
      )).unavailable,
      isTrue,
    );
    expect(calls, 0, reason: 'agent 为空不发请求');
  });

  test('read：hash 不是 64 位十六进制 ⇒ 空串（不冒充指纹）', () async {
    final MemoryPort port = MemoryPort(
      get:
          (
            String agentId,
            String purpose,
            int budgetChars,
            Map<String, Object?> scope,
          ) async => <String, Object?>{
            'ok': true,
            'text': '正文',
            'hash': 'not-a-hash',
            'sources': <String>['line/pl/task/T1'],
          },
    );
    final MemoryView view = await port.read(
      agentId: 'agt',
      purpose: 'production.prepare.recon',
    );
    expect(view.hash, isEmpty);
    expect(view.sources, <String>['line/pl/task/T1'], reason: '只取字符串来源');
  });

  test('record：成功回 ok + hash + 请求里的 sources', () async {
    Map<String, Object?>? gotEntry;
    final MemoryPort port = MemoryPort(
      record:
          (Map<String, Object?> entry, Map<String, Object?> scope) async {
            gotEntry = entry;
            return <String, Object?>{
              'ok': true,
              'agent_id': entry['agent_id'],
              'path': '.self/memory.md',
              'hash': hash,
              'chars': 12,
              'appended': true,
              'deduplicated': false,
            };
          },
    );
    final MemoryWrite write = await port.record(
      agentId: 'agt',
      purpose: 'production.task.done',
      summary: '改列表：门控 1 条全部通过',
      sources: <String>['line/pl/task/T1'],
      lineId: 'pl',
      taskId: 'T1',
    );
    expect(write.ok, isTrue);
    expect(write.unavailable, isFalse);
    expect(write.hash, hash);
    expect(write.sources, <String>['line/pl/task/T1']);
    expect(gotEntry!['agent_id'], 'agt');
    expect(gotEntry!['purpose'], 'production.task.done');
    expect(gotEntry!['line_id'], 'pl');
    expect(gotEntry!['task_id'], 'T1');
  });

  test('record：抛异常 / 回包 error / ok=false / 未接线 都降级（不抛）', () async {
    final MemoryPort throwing = MemoryPort(
      record:
          (Map<String, Object?> entry, Map<String, Object?> scope) async =>
              throw StateError('写失败'),
    );
    final MemoryWrite crashed = await throwing.record(
      agentId: 'agt',
      purpose: 'production.task.done',
      summary: 's',
    );
    expect(crashed.ok, isFalse);
    expect(crashed.unavailable, isTrue);
    expect(crashed.code, 'memory_unavailable');

    final MemoryPort withError = MemoryPort(
      record:
          (Map<String, Object?> entry, Map<String, Object?> scope) async =>
              <String, Object?>{'error': '没权限', 'code': 'memory_unavailable'},
    );
    expect(
      (await withError.record(
        agentId: 'agt',
        purpose: 'production.task.done',
        summary: 's',
      )).unavailable,
      isTrue,
    );

    final MemoryPort okFalse = MemoryPort(
      record:
          (Map<String, Object?> entry, Map<String, Object?> scope) async =>
              <String, Object?>{'ok': false},
    );
    expect(
      (await okFalse.record(
        agentId: 'agt',
        purpose: 'production.task.done',
        summary: 's',
      )).unavailable,
      isTrue,
    );

    int calls = 0;
    final MemoryPort unwired = MemoryPort(
      get:
          (
            String agentId,
            String purpose,
            int budgetChars,
            Map<String, Object?> scope,
          ) async {
            calls += 1;
            return <String, Object?>{};
          },
    );
    expect(
      (await unwired.record(
        agentId: 'agt',
        purpose: 'production.task.done',
        summary: 's',
      )).unavailable,
      isTrue,
    );
    expect(calls, 0, reason: '没有写通道不发请求');
  });

  test('memory view 只有正文可外泄的 text：hash / sources 都是元数据', () async {
    final MemoryPort port = MemoryPort(
      get:
          (
            String agentId,
            String purpose,
            int budgetChars,
            Map<String, Object?> scope,
          ) async => <String, Object?>{
            'ok': true,
            'path': '.self/memory.md',
            'text': '这段是记忆正文',
            'hash': hash,
            'chars': 8,
            'sources': <String>['line/pl/task/T1'],
          },
    );
    final MemoryView view = await port.read(
      agentId: 'agt',
      purpose: 'production.prepare.recon',
    );
    // 正文只在 text；hash 是合法的 64 位指纹，sources 是路径，都不掺正文。
    expect(view.text, '这段是记忆正文');
    expect(view.hash, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(view.hash, isNot(contains('正文')));
    expect(
      view.sources.every((String source) => !source.contains('正文')),
      isTrue,
    );
  });
}
