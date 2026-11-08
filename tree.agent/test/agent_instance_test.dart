import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_agent_loop/src/agent/agent_instance.dart';
import 'package:tree_agent_loop/src/message/inbox_ledger.dart';
import 'package:tree_agent_loop/src/paths.dart';

/// AC-1 Agent 实例骨架：懒建、复用、状态迁移、收件箱路径与关停 flush。
void main() {
  late Directory temp;
  late AgentDataPaths paths;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_agent_instance_');
    paths = AgentDataPaths(temp.path);
  });

  tearDown(() {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {
      // Windows 偶发占用：临时目录交给系统清理。
    }
  });

  test('注册表按 agent 懒建并复用同一实例', () {
    final AgentInstanceRegistry registry = AgentInstanceRegistry(paths: paths);
    expect(registry.length, 0);
    expect(registry.existing('agt'), isNull);

    final AgentInstance first = registry.instanceOf('agt');
    final AgentInstance second = registry.instanceOf('agt');
    expect(identical(first, second), isTrue);
    expect(registry.length, 1);
    expect(registry.existing('agt'), same(first));
    expect(registry.values, hasLength(1));
  });

  test('状态迁移幂等；只在实际变化时更新时间', () {
    int now = 1000;
    final AgentInstance instance = AgentInstance(
      agentId: 'agt',
      paths: paths,
      clock: () => DateTime.fromMillisecondsSinceEpoch(now++),
    );
    expect(instance.state, AgentActivityState.idle);
    expect(instance.isWorking, isFalse);
    final int initialUpdatedAt = instance.updatedAt;

    instance.markWorking();
    expect(instance.state, AgentActivityState.working);
    expect(instance.isWorking, isTrue);
    final int workingUpdatedAt = instance.updatedAt;
    expect(workingUpdatedAt, greaterThanOrEqualTo(initialUpdatedAt));

    instance.markWorking();
    expect(instance.updatedAt, workingUpdatedAt);

    instance.markIdle();
    expect(instance.state, AgentActivityState.idle);
    expect(instance.updatedAt, greaterThanOrEqualTo(workingUpdatedAt));
  });

  test('会话收件箱懒建、路径正确、同会话复用', () {
    final AgentInstance instance = AgentInstance(agentId: 'agt', paths: paths);
    expect(instance.inboxes, isEmpty);

    final MessageInbox first = instance.inbox('ses_a');
    final MessageInbox second = instance.inbox('ses_a');
    expect(identical(first, second), isTrue);
    expect(first.path, paths.inboxFile('agt', 'ses_a'));
    expect(instance.inboxes, hasLength(1));

    instance.inbox('ses_b');
    expect(instance.inboxes, hasLength(2));
  });

  test('dispose 先 flush 收件箱，再释放实例；文件保留可重读', () async {
    final AgentInstanceRegistry registry = AgentInstanceRegistry(paths: paths);
    final AgentInstance instance = registry.instanceOf('agt');
    await instance.inbox('ses_a').appendPending(<String, dynamic>{
      'message_id': 'm1',
      'content': '你好',
    });

    await registry.dispose('agt');
    expect(registry.existing('agt'), isNull);
    expect(File(paths.inboxFile('agt', 'ses_a')).existsSync(), isTrue);

    final MessageInbox reopened = MessageInbox(
      path: paths.inboxFile('agt', 'ses_a'),
    );
    final List<InboxEntry> entries = await reopened.readAll();
    expect(entries.single.messageId, 'm1');
    expect(entries.single.status, InboxStatus.pending);
  });

  test('disposeAll 清空注册表并 flush 全部实例', () async {
    final AgentInstanceRegistry registry = AgentInstanceRegistry(paths: paths);
    await registry.instanceOf('agt_a').inbox('ses_a').appendPending(
      <String, dynamic>{'message_id': 'a1'},
    );
    await registry.instanceOf('agt_b').inbox('ses_b').appendPending(
      <String, dynamic>{'message_id': 'b1'},
    );

    await registry.disposeAll();
    expect(registry.length, 0);
    expect(File(paths.inboxFile('agt_a', 'ses_a')).existsSync(), isTrue);
    expect(File(paths.inboxFile('agt_b', 'ses_b')).existsSync(), isTrue);
  });
}
