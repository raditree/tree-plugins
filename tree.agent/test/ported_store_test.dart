import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_agent_loop/src/store/file_store.dart';
import 'package:tree_agent_loop/src/store/records.dart';
import 'package:tree_agent_loop/src/store/tree_paths.dart';

/// 端口层（从核心平移到插件包的 `lib/src/store`）的独立自检。
///
/// 为什么值得单独测：A3 的生成循环要直接复用这份存储实现；它一旦与核心行为漂移，
/// 后续所有写路径（会话、消息、子 agent、待办）都会跟着漂。这里只测"移植后仍能
/// 独立读写同一套磁盘格式、且降级方向与核心一致"，不依赖核心包。
void main() {
  late Directory temp;
  late TreePaths paths;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_agent_port_');
    paths = TreePaths(temp.path);
  });

  tearDown(() {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {
      // Windows 偶发占用：临时目录交给系统清理。
    }
  });

  CoreAgent agent() => CoreAgent(
    id: 'agt',
    name: '夹具',
    createdAt: 1,
    updatedAt: 1,
    modelId: 'm1',
    systemPrompt: '你是夹具',
    workspaceDir: p.join(temp.path, 'workspace'),
  );

  CoreMessage message(
    String id,
    String role,
    String content, {
    String kind = 'text',
    String subagentId = '',
    int timestamp = 0,
  }) => CoreMessage(
    id: id,
    agentId: 'agt',
    sessionId: 'ses_a',
    role: role,
    content: content,
    kind: kind,
    subagentId: subagentId,
    timestamp: timestamp,
  );

  test('落盘后重新装载：agent / 会话 / 消息 / 子 agent 全在', () async {
    final FileTreeStore store = FileTreeStore(paths);
    store.putAgent(agent());
    final CoreSession session = store.createSession(
      'agt',
      title: '会话A',
      sessionId: 'ses_a',
    )!;
    expect(session.sessionId, 'ses_a');

    store.appendMessage(message('m1', 'user', '你好', timestamp: 1000));
    store.appendMessage(message('m2', 'agent', '回复', timestamp: 2000));
    store.appendMessage(
      message('m3', 'agent', '工具卡片', kind: 'tool', timestamp: 3000),
    );
    store.appendMessage(
      message('m4', 'agent', '子回复', subagentId: 'sub_x', timestamp: 4000),
    );
    store.putSubagent(
      CoreSubagent(
        id: 'sub_x',
        name: '临时员工',
        ownerAgentId: 'agt',
        sessionId: 'ses_a',
        parentId: 'agt',
        level: 1,
        scope: '整理日志',
        runCount: 2,
        createdAt: 1500,
        updatedAt: 2500,
        agent: CoreAgent(
          id: 'sub_x',
          name: '临时员工',
          createdAt: 1500,
          updatedAt: 2500,
          parentAgentId: 'agt',
        ),
      ),
    );
    await store.flush();

    // 与核心同口径：sessionMessages 全量；messages 排掉临时员工；
    // messageCount 再用 messages 排掉工具消息。
    expect(store.sessionMessages('agt', 'ses_a'), hasLength(4));
    expect(store.messages('agt', 'ses_a'), hasLength(3));
    expect(store.messageCount('agt', 'ses_a'), 2);
    expect(store.lastTextMessage('agt')?.content, '回复');
    expect(store.subagents('agt', 'ses_a'), hasLength(1));

    final FileTreeStore reloaded = FileTreeStore(paths);
    expect(reloaded.agent('agt')?.name, '夹具');
    // putAgent 会兜底默认会话，所以重载后是「默认 + 手工会话」两条。
    expect(
      reloaded.sessions('agt').map((CoreSession s) => s.sessionId),
      containsAll(<String>['ses_a', 'session_default']),
    );
    expect(reloaded.sessionMessages('agt', 'ses_a'), hasLength(4));
    expect(reloaded.lastTextMessage('agt')?.content, '回复');
    expect(reloaded.subagents('agt', 'ses_a').single.id, 'sub_x');
    await reloaded.close();
  });

  test('坏 yaml 不阻断其它 agent；删除会话连带清掉数据目录', () async {
    final FileTreeStore store = FileTreeStore(paths);
    store.putAgent(agent());
    await store.flush();
    File(p.join(paths.agentsDir, 'broken.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{{{ 这不是 yaml');

    expect(store.agents().map((CoreAgent a) => a.id), <String>['agt']);

    store.ensureDefaultSession('agt');
    expect(store.deleteSession('agt', 'session_default'), isTrue);
    expect(store.session('agt', 'session_default'), isNull);
    // 目录删除走 write-behind 队列：必须 flush 再断言（与核心同一语义）。
    await store.flush();
    expect(
      Directory(paths.sessionDir('agt', 'session_default')).existsSync(),
      isFalse,
    );
    await store.close();
  });

  test('默认会话幂等；清空消息只删消息不删会话', () async {
    final FileTreeStore store = FileTreeStore(paths);
    store.putAgent(agent());
    final CoreSession first = store.ensureDefaultSession('agt');
    final CoreSession second = store.ensureDefaultSession('agt');
    expect(first.sessionId, second.sessionId);
    expect(first.createdAt, second.createdAt);

    store.createSession('agt', title: '会话A', sessionId: 'ses_a');
    store.appendMessage(message('m1', 'user', '你好', timestamp: 1000));
    await store.flush();
    expect(store.clearMessages('agt', sessionId: 'ses_a'), 1);
    expect(store.session('agt', 'ses_a'), isNotNull);
    expect(store.sessionMessages('agt', 'ses_a'), isEmpty);
    await store.close();
  });
}
