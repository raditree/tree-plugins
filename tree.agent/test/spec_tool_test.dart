import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_agent_loop/src/paths.dart';
import 'package:tree_agent_loop/src/runtime/agent_runtime.dart';
import 'package:tree_agent_loop/src/station/agent_tools.dart';
import 'package:tree_agent_loop/src/tool/spec_tool.dart';
import 'package:tree_agent_loop/src/tool/station_tool_runner.dart';

import 'ported_core.dart';
import 'test_workspace_io.dart';

/// S1：`spec` 工具（list / read / select / create / update / reset）与
/// agent_tools 执行站的 spec.* 命令。
///
/// 工具层只做参数归一 + 结果格式化；语义复用既有 SpecService，所以这里重点钉：
/// - 参数 schema / 动作词表 / 执行站命令表三者不漂；
/// - list/read/越界错误、select 的会话级选择、reset 的备份与重建；
/// - 工作空间未接线时显式失败（不假装成功）；
/// - StationToolRunner 的 specRunner 接线，以及 AgentRuntime 的 spec.* 命令落点。
void main() {
  group('声明与执行站命令表', () {
    test('spec 工具：动作枚举 / 参数 schema / station 命令一一对应', () {
      final ToolSpec spec = SpecTool.spec();
      expect(spec.name, 'spec');
      expect(spec.description, contains('list'));
      expect(spec.description, contains('reset'));
      final Map<String, dynamic> properties =
          (spec.parameters['properties'] as Map).cast<String, dynamic>();
      expect(
        (properties['action'] as Map)['enum'],
        SpecTool.actions,
        reason: 'schema 的 enum 必须就是执行分发用的那一份词表',
      );
      expect(spec.parameters['required'], <String>['action']);
      expect(properties.keys, containsAll(<String>['spec_id', 'spec_ids']));

      expect(SpecTool.actions, <String>[
        'list',
        'read',
        'select',
        'create',
        'update',
        'reset',
      ]);
      expect(SpecTool.stationCommands, <String>[
        'spec.list',
        'spec.read',
        'spec.select',
        'spec.create',
        'spec.update',
        'spec.reset',
      ]);
      expect(SpecTool.stationCommands.length, SpecTool.actions.length);
    });

    test('agent_tools 执行站申报：既有领域命令 + spec.*', () {
      expect(
        AgentRuntime.agentToolCommands.toSet().containsAll(
          kAgentToolCommands,
        ),
        isTrue,
      );
      expect(
        AgentRuntime.agentToolCommands.toSet().containsAll(
          SpecTool.stationCommands,
        ),
        isTrue,
        reason: '不申报 = 核心按未知命令拒绝，extra-tools 之类经站调用会失败',
      );
      expect(AgentRuntime.agentToolsReadme, contains('spec.*'));
    });
  });

  group('SpecTool 动作', () {
    late Directory temp;
    late TestWorkspaceIO io;
    late MemoryStore store;
    late SpecService service;
    late CoreAgent agent;

    const String sessionId = TreeStore.defaultSessionId;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('tree_agent_spec_tool_');
      io = TestWorkspaceIO(temp.path);
      store = MemoryStore();
      service = SpecService(store: store);
      agent = store.createAgent(name: '队长');
    });

    tearDown(() async {
      for (int i = 0; i < 5; i++) {
        try {
          if (temp.existsSync()) temp.deleteSync(recursive: true);
          return;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });

    ToolInvocation call(Map<String, dynamic> arguments) => ToolInvocation(
      id: 'tool_spec',
      name: 'spec',
      arguments: arguments,
      agentId: agent.id,
      sessionId: sessionId,
    );

    Future<({ToolOutcome outcome, Map<String, dynamic> body})> runWith(
      WorkspaceIO workspace,
      Map<String, dynamic> arguments,
    ) async {
      final ToolOutcome outcome = await SpecTool.run(
        call(arguments),
        service,
        workspace,
      );
      final Object? decoded = jsonDecode(outcome.content);
      return (
        outcome: outcome,
        body: (decoded as Map).cast<String, dynamic>(),
      );
    }

    Future<({ToolOutcome outcome, Map<String, dynamic> body})> run(
      Map<String, dynamic> arguments,
    ) => runWith(io, arguments);

    test('list / read：内置清单、全文、越界 spec_id', () async {
      final list = await run(<String, dynamic>{'action': 'list'});
      expect(list.outcome.isError, isFalse);
      expect(list.body['count'], kBuiltinSpecIds.length);
      expect(list.body['spec_dir'], '.self/spec');
      expect(list.body['selected_spec_ids'], isEmpty);
      final List<dynamic> specs = list.body['specs'] as List<dynamic>;
      expect((specs.first as Map)['spec_id'], 'general-task');
      expect(
        File(p.join(temp.path, '.self', 'spec', 'general-task.md')).existsSync(),
        isTrue,
        reason: 'list 会像 REST 一样先播种内置模板',
      );

      final read = await run(<String, dynamic>{
        'action': 'read',
        'spec_id': 'general-task',
      });
      expect(read.outcome.isError, isFalse);
      expect(read.body['content'], kBuiltinSpecTexts['general-task']);
      expect((read.body['spec'] as Map)['title'], contains('通用任务'));

      final missing = await run(<String, dynamic>{
        'action': 'read',
        'spec_id': 'ghost',
      });
      expect(missing.outcome.isError, isTrue);
      expect(missing.body['error'], contains('Spec 不存在: ghost'));

      final noId = await run(<String, dynamic>{'action': 'read'});
      expect(noId.outcome.isError, isTrue);
      expect(noId.body['error'], 'read 需要 spec_id');
    });

    test('select：挂 hook 并回全文；空数组清空；list 读得到会话级选择', () async {
      final selected = await run(<String, dynamic>{
        'action': 'select',
        'spec_ids': <String>['general-task'],
      });
      expect(selected.outcome.isError, isFalse);
      expect(selected.body['count'], 1);
      expect(selected.body['spec_ids'], <dynamic>['general-task']);
      final Map<String, dynamic> first =
          (selected.body['specs'] as List<dynamic>).single as Map<String, dynamic>;
      expect(first['content'], isNotEmpty);
      expect(
        store.session(agent.id, sessionId)!.selectedSpecIds,
        <String>['general-task'],
      );

      final listed = await run(<String, dynamic>{'action': 'list'});
      expect(listed.body['selected_spec_ids'], <dynamic>['general-task']);

      final cleared = await run(<String, dynamic>{
        'action': 'select',
        'spec_ids': <String>[],
      });
      expect(cleared.outcome.isError, isFalse);
      expect(store.session(agent.id, sessionId)!.selectedSpecIds, isEmpty);
      expect(cleared.body['note'], contains('取消全部'));
    });

    test('create / update / 未知动作', () async {
      final created = await run(<String, dynamic>{
        'action': 'create',
        'title': 'DB Migration',
        'task_type': 'custom',
        'when': <String>['改表结构'],
        'workflow': '先备份再迁移',
        'rules': '必须留回滚脚本',
      });
      expect(created.outcome.isError, isFalse);
      expect(created.body['spec_id'], 'db-migration');
      final readBack = await run(<String, dynamic>{
        'action': 'read',
        'spec_id': 'db-migration',
      });
      expect(readBack.outcome.isError, isFalse);
      expect(readBack.body['content'], contains('先备份再迁移'));

      final builtin = await run(<String, dynamic>{
        'action': 'update',
        'spec_id': 'general-task',
        'rules': '试图改内置',
      });
      expect(builtin.outcome.isError, isTrue);
      expect(builtin.body['error'], 'general-task 为内置 Spec，不可修改');

      final updated = await run(<String, dynamic>{
        'action': 'update',
        'spec_id': 'db-migration',
        'rules': '新规则',
      });
      expect(updated.outcome.isError, isFalse);
      expect(updated.body['success'], isTrue);

      final unknown = await run(<String, dynamic>{'action': 'nope'});
      expect(unknown.outcome.isError, isTrue);
      expect(unknown.body['error'], contains('未知 spec 动作: nope'));
    });

    test('reset：自定义规范进备份、内置规范重建、索引刷新', () async {
      await run(<String, dynamic>{
        'action': 'create',
        'title': 'DB Migration',
        'workflow': '先备份',
      });
      final _FullPathIo fullPaths = _FullPathIo(io);
      final reset = await runWith(fullPaths, <String, dynamic>{
        'action': 'reset',
      });
      expect(reset.outcome.isError, isFalse);
      expect(reset.body['action'], 'reset');
      expect(reset.body['backup_index'], 1);
      expect(
        (reset.body['backed_up'] as List<dynamic>).any(
          (Object? item) => '$item'.contains('db-migration.md'),
        ),
        isTrue,
        reason: '自定义规范必须先备份（${reset.body['backed_up']}）',
      );
      expect(
        (reset.body['removed'] as List<dynamic>).contains(
          '.self/spec/db-migration.md',
        ),
        isTrue,
      );
      expect(
        (reset.body['restored'] as List<dynamic>).contains(
          '.self/spec/general-task.md',
        ),
        isTrue,
      );
      expect(
        File(p.join(temp.path, '.self', 'spec', 'db-migration.md')).existsSync(),
        isFalse,
      );
      expect(
        File(
          p.join(temp.path, '.self', 'spec', 'db-migration.md.bak.1'),
        ).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(temp.path, '.self', 'spec', 'general-task.md')).existsSync(),
        isTrue,
      );

      // 索引快照也刷了：reset 之后 list 只剩内置规范。
      final listed = await run(<String, dynamic>{'action': 'list'});
      final List<String> ids = <String>[
        for (final Object? item in listed.body['specs'] as List<dynamic>)
          (item as Map)['spec_id'].toString(),
      ];
      expect(ids, isNot(contains('db-migration')));
    });

    test('reset：列目录只回文件名（远端风格）也归一到 .self/spec/（契约面与后端无关）', () async {
      await run(<String, dynamic>{
        'action': 'create',
        'title': 'DB Migration',
        'workflow': '先备份',
      });
      // 直接用测试 IO：它的 listFiles 只回文件名（请求目录相对风格），
      // 与真实执行器的「工作空间相对路径」是两种后端风格，回包必须一致。
      final reset = await run(<String, dynamic>{'action': 'reset'});
      expect(reset.outcome.isError, isFalse);
      expect(reset.body['spec_dir'], '.self/spec');
      expect(
        (reset.body['removed'] as List<dynamic>).contains(
          '.self/spec/db-migration.md',
        ),
        isTrue,
        reason: '回包必须是工作空间相对路径：${reset.body['removed']}',
      );
      expect(
        (reset.body['backed_up'] as List<dynamic>).contains(
          '.self/spec/db-migration.md → .self/spec/db-migration.md.bak.1',
        ),
        isTrue,
        reason: '备份条目同样要归一：${reset.body['backed_up']}',
      );
      // 备份落在真实路径上，而不是工作空间根目录下的裸名文件
      expect(
        File(
          p.join(temp.path, '.self', 'spec', 'db-migration.md.bak.1'),
        ).existsSync(),
        isTrue,
      );
      expect(File(p.join(temp.path, 'db-migration.md.bak.1')).existsSync(), isFalse);
    });

    test('工作空间未接线：显式报错，不假装成功', () async {
      final ToolOutcome outcome = await SpecTool.run(
        call(<String, dynamic>{'action': 'list'}),
        service,
        null,
      );
      expect(outcome.isError, isTrue);
      expect(outcome.content, contains('工作空间不可用'));
    });
  });

  group('StationToolRunner 接线', () {
    test('specRunner 注入后才声明 spec，调用转给注入回调', () async {
      final List<String> seen = <String>[];
      final StationToolRunner runner = StationToolRunner(
        client: (
          String command,
          Map<String, dynamic> arguments,
          Map<String, dynamic> scope,
        ) async => <String, dynamic>{},
        scopeFor: (String agentId, String sessionId) =>
            <String, dynamic>{'agent_id': agentId},
        specRunner: (ToolInvocation invocation) async {
          seen.add('${invocation.name}:${invocation.arguments['action']}');
          return const ToolOutcome('spec-ok');
        },
      );
      expect(
        runner
            .specsFor(agentId: 'agt', sessionId: 's')
            .map((ToolSpec spec) => spec.name),
        contains('spec'),
      );
      final ToolOutcome outcome = await runner.run(
        const ToolInvocation(
          id: 'c1',
          name: 'spec',
          arguments: <String, dynamic>{'action': 'list'},
          agentId: 'agt',
          sessionId: 's',
        ),
      );
      expect(outcome.content, 'spec-ok');
      expect(seen, <String>['spec:list']);

      final StationToolRunner bare = StationToolRunner(
        client: (
          String command,
          Map<String, dynamic> arguments,
          Map<String, dynamic> scope,
        ) async => <String, dynamic>{},
        scopeFor: (String agentId, String sessionId) =>
            <String, dynamic>{'agent_id': agentId},
      );
      expect(
        bare
            .specsFor(agentId: 'agt', sessionId: 's')
            .map((ToolSpec spec) => spec.name),
        isNot(contains('spec')),
        reason: '未接线时不声明，模型不会调到半成品',
      );
    });
  });

  group('AgentRuntime spec.* 命令', () {
    test('经工作空间 IO 执行 list / read / 越界 / reset', () async {
      final Directory temp = Directory.systemTemp.createTempSync(
        'tree_agent_spec_cmd_',
      );
      final AgentDataPaths paths = AgentDataPaths(temp.path);
      final FileTreeStore store = FileTreeStore(TreePaths(temp.path));
      final CoreAgent agent = store.createAgent(name: '夹具', modelId: 'm1');
      await store.flush();
      await store.close();

      final TestWorkspaceIO workspace = TestWorkspaceIO(
        p.join(temp.path, 'workspace'),
      );
      AgentRuntime.stationClient = (
        String command,
        Map<String, dynamic> arguments,
        Map<String, dynamic> scope,
      ) => _fileStation(workspace, command, arguments);
      try {
        final AgentRuntime runtime = AgentRuntime(paths: paths);
        // 生产形状：默认 LlmAgentEngine 的 toolRunner 就是 StationToolRunner，
        // 模型工具表里必须能看见 spec（否则工具只存在于单元测试里）。
        final LlmAgentEngine engine =
            runtime.conversation.engine as LlmAgentEngine;
        expect(
          engine.toolRunner
              .specsFor(agentId: agent.id, sessionId: 'session_default')
              .map((ToolSpec spec) => spec.name),
          contains('spec'),
        );
        final Map<String, dynamic> scope = <String, dynamic>{
          'agent_id': agent.id,
          'session_id': 'session_default',
        };
        Future<Map<String, dynamic>> command(
          String name, [
          Map<String, dynamic> arguments = const <String, dynamic>{},
        ]) => runtime.handleAgentToolCommand(name, arguments, scope);

        Map<String, dynamic> bodyOf(Map<String, dynamic> reply) =>
            (jsonDecode('${reply['text'] ?? '{}'}') as Map)
                .cast<String, dynamic>();

        final Map<String, dynamic> list = await command('spec.list');
        expect(list['is_error'], isFalse);
        expect(bodyOf(list)['count'], kBuiltinSpecIds.length);

        final Map<String, dynamic> read = await command(
          'spec.read',
          <String, dynamic>{'spec_id': 'general-task'},
        );
        expect(read['is_error'], isFalse);
        expect(bodyOf(read)['content'], kBuiltinSpecTexts['general-task']);

        final Map<String, dynamic> missing = await command(
          'spec.read',
          <String, dynamic>{'spec_id': 'ghost'},
        );
        expect(missing['is_error'], isTrue);
        expect(bodyOf(missing)['error'], contains('Spec 不存在: ghost'));

        final Map<String, dynamic> reset = await command('spec.reset');
        expect(reset['is_error'], isFalse);
        expect(bodyOf(reset)['action'], 'reset');
      } finally {
        AgentRuntime.stationClient = null;
        await AgentRuntime.debugCloseAll();
        try {
          if (temp.existsSync()) temp.deleteSync(recursive: true);
        } catch (_) {
          // Windows 偶发占用：交给系统清理。
        }
      }
    });
  });
}

/// 测试用文件执行站：把 `file.*` 落到 [WorkspaceIO]（语义与 local_executor 同形）。
Future<Map<String, dynamic>> _fileStation(
  WorkspaceIO io,
  String command,
  Map<String, dynamic> arguments,
) async {
  switch (command) {
    case 'file.read':
      final FileContent content = await io.readFile(
        arguments['path'].toString(),
      );
      return <String, dynamic>{
        'content': content.text,
        'total_lines': content.totalLines,
        'start_line': 1,
        'truncated': false,
      };
    case 'file.write':
      return <String, dynamic>{
        'bytes_written': await io.writeFile(
          arguments['path'].toString(),
          arguments['content'].toString(),
        ),
      };
    case 'file.list':
      return <String, dynamic>{
        'entries': await io.listFiles(
          relativePath: arguments['path'].toString(),
        ),
      };
    case 'file.delete':
      final bool deleted = await io.deleteFile(
        arguments['path'].toString(),
      );
      return <String, dynamic>{'deleted': deleted};
    case 'file.mkdir':
      await Directory(
        p.join(io.root, p.normalize(arguments['path'].toString())),
      ).create(recursive: true);
      return <String, dynamic>{'ok': true};
    default:
      throw StateError('测试假站不处理命令：$command');
  }
}

/// 把 [TestWorkspaceIO.listFiles] 的裸文件名包装成**工作空间相对路径**
/// （local_executor / ssh_executor 的真实口径；`SpecService.reset` 依赖它）。
class _FullPathIo implements WorkspaceIO {
  _FullPathIo(this.inner);

  final TestWorkspaceIO inner;

  @override
  String get root => inner.root;

  @override
  Future<FileContent> readFile(
    String relativePath, {
    int? startLine,
    int? lineCount,
    int? maxBytes,
  }) => inner.readFile(
    relativePath,
    startLine: startLine,
    lineCount: lineCount,
    maxBytes: maxBytes,
  );

  @override
  Future<int> writeFile(String relativePath, String content) =>
      inner.writeFile(relativePath, content);

  @override
  Future<bool> deleteFile(String relativePath) =>
      inner.deleteFile(relativePath);

  @override
  Future<List<String>> listFiles({
    String relativePath = '.',
    int maxDepth = 2,
    int maxEntries = 500,
  }) async {
    final List<String> entries = await inner.listFiles(
      relativePath: relativePath,
      maxDepth: maxDepth,
      maxEntries: maxEntries,
    );
    if (relativePath == '.' || relativePath.isEmpty) return entries;
    return <String>[
      for (final String entry in entries) '$relativePath/$entry',
    ];
  }
}
