import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_agent_loop/src/paths.dart';
import 'package:tree_agent_loop/src/runtime/agent_runtime.dart';
import 'package:tree_agent_loop/src/station/tool_contributions.dart';
import 'package:tree_agent_loop/src/store/file_store.dart';
import 'package:tree_agent_loop/src/store/records.dart';
import 'package:tree_agent_loop/src/store/tree_paths.dart';
import 'package:tree_agent_loop/src/tool/station_tool_runner.dart';
import 'package:tree_agent_loop/src/tool/tool_policy.dart';
import 'package:tree_agent_loop/src/tool/tool_runner.dart';

/// P2 工具白名单：策略解析 / 工具表过滤 / 运行兜底 / 临时员工继承。
void main() {
  group('ToolPolicy', () {
    test('null = 全量默认；空集 = 显式全关', () {
      const ToolPolicy defaults = ToolPolicy();
      expect(defaults.allows('read'), isTrue);
      expect(defaults.allows('plugin__extra-tools__team'), isTrue);
      expect(defaults.isUnrestricted, isTrue);

      const ToolPolicy none = ToolPolicy(allowed: <String>{});
      expect(none.allows('read'), isFalse);
      expect(none.allows('terminal'), isFalse);
      expect(none.isUnrestricted, isFalse);
    });

    test('allow 名单：核心名与原生名都命中；未列出的拒绝', () {
      const ToolPolicy policy = ToolPolicy(
        allowed: <String>{'read', 'plugin__extra-tools__team'},
      );
      expect(policy.allows('read'), isTrue);
      expect(policy.allows('write'), isFalse);
      expect(policy.allows('plugin__extra-tools__team'), isTrue);
      // 用户手改 YAML 写原生名也应命中同一工具。
      const ToolPolicy byNative = ToolPolicy(allowed: <String>{'team'});
      expect(byNative.allows('plugin__extra-tools__team'), isTrue);
    });

    test('blocked 优先于 allowed', () {
      const ToolPolicy policy = ToolPolicy(blocked: kSubagentBlockedTools);
      expect(policy.allows('subagent'), isFalse);
      expect(policy.allows('plugin__extra-tools__team'), isFalse);
      expect(policy.allows('plugin__extra-tools__message'), isFalse);
      expect(policy.allows('read'), isTrue);
    });

    test('inherit 追加 block、保留 allow', () {
      const ToolPolicy parent = ToolPolicy(allowed: <String>{'read', 'team'});
      final ToolPolicy child = parent.inherit(block: kSubagentBlockedTools);
      expect(child.allows('read'), isTrue);
      expect(child.allows('team'), isFalse);
      // 父策略本身不被修改。
      expect(parent.allows('team'), isTrue);
    });

    test('显式勾选类工具：ask_expert 的核心名与原生名同一判定', () {
      expect(isOptInTool('ask_expert'), isTrue);
      expect(isOptInTool('plugin__tree.production.line__ask_expert'), isTrue);
      expect(isOptInTool('read'), isFalse);
      expect(isOptInTool('subagent'), isFalse);
    });

    test('分组：内置按语义归组，贡献工具落 plugin / collab', () {
      expect(toolGroupOf('read'), kToolGroupRead);
      expect(toolGroupOf('list'), kToolGroupRead);
      expect(toolGroupOf('grep'), kToolGroupRead);
      expect(toolGroupOf('write'), kToolGroupWrite);
      expect(toolGroupOf('edit'), kToolGroupWrite);
      expect(toolGroupOf('terminal'), kToolGroupCommand);
      expect(toolGroupOf('spec'), kToolGroupWorkflow);
      expect(toolGroupOf('tool_runs'), kToolGroupWorkflow);
      expect(toolGroupOf('plugin__extra-tools__set_todo_list'),
          kToolGroupWorkflow);
      expect(toolGroupOf('plugin__extra-tools__team'), kToolGroupCollab);
      expect(toolGroupOf('plugin__mcp__search'), kToolGroupPlugin);
      expect(toolGroupOf('anything-else'), kToolGroupPlugin);
    });
  });

  group('CoreAgent.tool_policy', () {
    CoreAgent agentWith(List<String>? policy) => CoreAgent(
      id: 'agt',
      name: '夹具',
      createdAt: 1,
      updatedAt: 1,
      toolPolicy: policy,
    );

    test('null 不落盘（旧文件语义不变）', () {
      expect(agentWith(null).toJson().containsKey('tool_policy'), isFalse);
      final CoreAgent parsed = CoreAgent.fromJson(agentWith(null).toJson());
      expect(parsed.toolPolicy, isNull);
    });

    test('空列表落盘且读回仍是空列表（显式全关）', () {
      final Map<String, dynamic> json = agentWith(<String>[]).toJson();
      expect(json['tool_policy'], isEmpty);
      expect(CoreAgent.fromJson(json).toolPolicy, isEmpty);
    });

    test('清单去重去空；脏值回退为未配置', () {
      final Map<String, dynamic> json = agentWith(<String>['read']).toJson();
      expect(CoreAgent.fromJson(json).toolPolicy, <String>['read']);
      expect(toolPolicyListOf(<Object?>['read', ' read ', '', null]), <String>['read']);
      expect(toolPolicyListOf('read'), isNull);
    });
  });

  group('StationToolRunner 白名单', () {
    late List<ToolInvocation> executed;

    StationToolRunner runnerFor(ToolPolicy Function(String agentId) policyFor) {
      Future<Map<String, dynamic>> client(
        String command,
        Map<String, dynamic> arguments,
        Map<String, dynamic> scope,
      ) async {
        executed.add(
          ToolInvocation(
            id: 'echo',
            name: command,
            arguments: arguments,
            agentId: '${scope['agent_id'] ?? ''}',
            sessionId: '${scope['session_id'] ?? ''}',
          ),
        );
        return <String, dynamic>{'content': 'ok', 'bytes_written': 2};
      }

      return StationToolRunner(
        client: client,
        scopeFor: (String agentId, String sessionId) => <String, dynamic>{
          'agent_id': agentId,
          'session_id': sessionId,
        },
        policyFor: policyFor,
      );
    }

    setUp(() => executed = <ToolInvocation>[]);

    test('未接线 = 全量默认（现有行为零改动）', () {
      final StationToolRunner runner = StationToolRunner(
        client: (String command, Map<String, dynamic> arguments, Map<String, dynamic> scope) async =>
            <String, dynamic>{},
        scopeFor: (String agentId, String sessionId) => <String, dynamic>{},
      );
      expect(
        runner
            .specsFor(agentId: 'agt', sessionId: 's')
            .map((ToolSpec spec) => spec.name),
        <String>['read', 'write', 'list', 'grep', 'terminal', 'edit'],
      );
      expect(runner.catalogFor(agentId: 'agt').every((ToolCatalogEntry e) => e.enabled), isTrue);
    });

    test('specsFor 只留勾选工具；空清单 = 没有工具', () {
      final StationToolRunner runner = runnerFor(
        (String agentId) => agentId == 'narrow'
            ? const ToolPolicy(allowed: <String>{'read', 'terminal'})
            : const ToolPolicy(allowed: <String>{}),
      );
      expect(
        runner
            .specsFor(agentId: 'narrow', sessionId: 's')
            .map((ToolSpec spec) => spec.name),
        <String>['read', 'terminal'],
      );
      expect(runner.specsFor(agentId: 'empty', sessionId: 's'), isEmpty);
      // 未筛选的目录仍完整。
      expect(
        runner.catalogFor(agentId: 'empty').length,
        greaterThanOrEqualTo(6),
      );
    });

    test('catalogFor：目录完整并标注 enabled / group', () {
      final StationToolRunner runner = runnerFor(
        (String agentId) => const ToolPolicy(allowed: <String>{'read'}),
      );
      final List<ToolCatalogEntry> catalog = runner.catalogFor(agentId: 'agt');
      final ToolCatalogEntry read = catalog.firstWhere((ToolCatalogEntry e) => e.name == 'read');
      final ToolCatalogEntry write = catalog.firstWhere((ToolCatalogEntry e) => e.name == 'write');
      expect(read.enabled, isTrue);
      expect(read.group, kToolGroupRead);
      expect(write.enabled, isFalse);
      expect(write.group, kToolGroupWrite);
      // 目录项形状与 REST 契约一致。
      expect(read.toApiJson().keys.toSet(), <String>{
        'name',
        'description',
        'group',
        'enabled',
      });
    });

    test('run 兜底：未勾选的内置工具被拒且不触达执行站', () async {
      final StationToolRunner runner = runnerFor(
        (String agentId) => const ToolPolicy(allowed: <String>{'read'}),
      );
      final ToolOutcome denied = await runner.run(
        const ToolInvocation(
          id: 'w1',
          name: 'write',
          arguments: <String, dynamic>{'path': 'a', 'content': 'b'},
          agentId: 'agt',
          sessionId: 's',
        ),
      );
      expect(denied.isError, isTrue);
      expect(denied.content, contains('工具白名单'));
      expect(executed, isEmpty);

      final ToolOutcome allowed = await runner.run(
        const ToolInvocation(
          id: 'r1',
          name: 'read',
          arguments: <String, dynamic>{'path': 'a'},
          agentId: 'agt',
          sessionId: 's',
        ),
      );
      expect(allowed.isError, isFalse);
      expect(executed, hasLength(1));
    });

    test('run 兜底不改变"未知工具"的原有错误', () async {
      final StationToolRunner runner = runnerFor(
        (String agentId) => const ToolPolicy(allowed: <String>{'read'}),
      );
      final ToolOutcome unknown = await runner.run(
        const ToolInvocation(
          id: 'x1',
          name: 'no_such_tool',
          arguments: <String, dynamic>{},
          agentId: 'agt',
          sessionId: 's',
        ),
      );
      expect(unknown.isError, isTrue);
      expect(unknown.content, contains('未知工具'));
    });

    test('ask_expert 必须显式勾选：全量默认不出现，勾选后才出现 / 可执行', () async {
      StationToolRunner runnerForPolicy(ToolPolicy policy) {
        Future<Map<String, dynamic>> client(
          String command,
          Map<String, dynamic> arguments,
          Map<String, dynamic> scope,
        ) async => <String, dynamic>{'result': '专家回答', 'is_error': false};
        return StationToolRunner(
          client: client,
          scopeFor: (String agentId, String sessionId) => <String, dynamic>{
            'agent_id': agentId,
            'session_id': sessionId,
          },
          policyFor: (String agentId) => policy,
          contributed: () => <ContributedTool>[
            const ContributedTool(
              pluginId: 'tree.production.line',
              name: 'ask_expert',
              description: '问专家',
              parameters: <String, dynamic>{'type': 'object'},
            ),
          ],
        );
      }

      const String name = 'plugin__tree.production.line__ask_expert';
      final StationToolRunner defaults = runnerForPolicy(const ToolPolicy());
      expect(
        defaults
            .specsFor(agentId: 'agt', sessionId: 's')
            .map((ToolSpec spec) => spec.name),
        isNot(contains(name)),
        reason: '未配置 tool_policy 时不出现（默认不能召专家）',
      );
      final ToolCatalogEntry off = defaults
          .catalogFor(agentId: 'agt')
          .firstWhere((ToolCatalogEntry entry) => entry.name == name);
      expect(off.enabled, isFalse, reason: '目录里可见但默认未勾选');
      final ToolOutcome rejected = await defaults.run(
        const ToolInvocation(
          id: 'e1',
          name: name,
          arguments: <String, dynamic>{'question': 'X?'},
          agentId: 'agt',
          sessionId: 's',
        ),
      );
      expect(rejected.isError, isTrue);
      expect(rejected.content, contains('需要显式勾选'));

      final StationToolRunner picked = runnerForPolicy(
        const ToolPolicy(allowed: <String>{'ask_expert'}),
      );
      expect(
        picked
            .specsFor(agentId: 'agt', sessionId: 's')
            .map((ToolSpec spec) => spec.name),
        contains(name),
      );
      final ToolOutcome allowed = await picked.run(
        const ToolInvocation(
          id: 'e2',
          name: name,
          arguments: <String, dynamic>{'question': 'X?'},
          agentId: 'agt',
          sessionId: 's',
        ),
      );
      expect(allowed.isError, isFalse);
      expect(allowed.content, '专家回答');
    });
  });

  group('AgentRuntime.toolPolicyFor', () {
    late Directory temp;
    late AgentDataPaths paths;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('tree_agent_policy_');
      paths = AgentDataPaths(temp.path);
    });

    tearDown(() async {
      await AgentRuntime.debugCloseAll();
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('真实 agent 读 YAML；未配置 = 全量默认', () async {
      final FileTreeStore store = FileTreeStore(TreePaths(paths.root));
      store.putAgent(
        CoreAgent(
          id: 'narrow',
          name: '窄权限',
          createdAt: 1,
          updatedAt: 1,
          modelId: 'm1',
          toolPolicy: <String>['read'],
        ),
      );
      store.putAgent(
        CoreAgent(
          id: 'wide',
          name: '默认',
          createdAt: 1,
          updatedAt: 1,
          modelId: 'm1',
        ),
      );
      await store.flush();
      await store.close();

      final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
      expect(runtime.toolPolicyFor('narrow').allows('read'), isTrue);
      expect(runtime.toolPolicyFor('narrow').allows('write'), isFalse);
      expect(runtime.toolPolicyFor('wide').isUnrestricted, isTrue);
    });

    test('临时员工继承父策略并剔除协作工具', () async {
      final FileTreeStore store = FileTreeStore(TreePaths(paths.root));
      final CoreAgent parent = store.createAgent(name: '父', modelId: 'm1');
      await store.flush();
      await store.close();

      final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
      runtime.registry.ensureSession(parent.id, 's1');
      runtime.registry.put(
        CoreSubagent(
          id: 'sub_1',
          name: '员工',
          ownerAgentId: parent.id,
          sessionId: 's1',
          parentId: parent.id,
          level: 1,
          agent: CoreAgent(
            id: 'sub_1',
            name: '员工',
            createdAt: 1,
            updatedAt: 1,
            modelId: 'm1',
          ),
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      final ToolPolicy inherited = runtime.toolPolicyFor('sub_1');
      expect(inherited.allows('read'), isTrue);
      expect(inherited.allows('write'), isTrue);
      expect(inherited.allows('subagent'), isFalse);
      expect(inherited.allows('plugin__extra-tools__team'), isFalse);
      expect(inherited.allows('plugin__extra-tools__message'), isFalse);

      // 名册未装载时按 `sub_` 前缀兜底：同样不能拿到协作工具。
      final ToolPolicy unknown = runtime.toolPolicyFor('sub_not_loaded');
      expect(unknown.allows('read'), isTrue);
      expect(unknown.allows('team'), isFalse);
    });

    test('产线员工用显式工具表：message 放行，团队 / 再召仍禁用', () async {
      final FileTreeStore store = FileTreeStore(TreePaths(paths.root));
      final CoreAgent parent = store.createAgent(name: '主控', modelId: 'm1');
      await store.flush();
      await store.close();

      final AgentRuntime runtime = AgentRuntime.forDataDir(paths.root);
      runtime.registry.ensureSession(parent.id, 's1');
      runtime.registry.put(
        CoreSubagent(
          id: 'sub_worker',
          name: '执行模型',
          ownerAgentId: parent.id,
          sessionId: 's1',
          parentId: parent.id,
          level: 1,
          agent: CoreAgent(
            id: 'sub_worker',
            name: '执行模型',
            createdAt: 1,
            updatedAt: 1,
            modelId: 'm1',
            role: 'executor',
            toolPolicy: <String>['read', 'write', 'edit', 'message', 'team'],
          ),
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      final ToolPolicy worker = runtime.toolPolicyFor('sub_worker');
      expect(worker.allows('write'), isTrue);
      expect(worker.allows('message'), isTrue);
      expect(worker.allows('team'), isFalse);
      expect(worker.allows('subagent'), isFalse);
      expect(worker.allows('read'), isTrue);
      // 白名单外的工具不出现（不再是"继承父级全量"）。
      expect(worker.allows('tool_runs'), isFalse);
    });
  });
}
