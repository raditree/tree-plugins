import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'ported_core.dart';
import 'package:tree_agent_loop/src/agent/subagent_service.dart';
import 'package:tree_agent_loop/src/paths.dart';
import 'package:tree_agent_loop/src/worker/worker_spec.dart';

/// 产线员工（P4）：`SubagentService.runWorker` 的组装与校验（假运行器，不碰 LLM）。
void main() {
  late Directory temp;
  late CoreSettings settings;
  late MemoryStore memory;
  late SubagentRegistry registry;
  late SubagentService service;
  late CoreAgent caller;
  final List<SubagentTurnRequest> turns = <SubagentTurnRequest>[];

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_agent_worker_');
    final AgentDataPaths paths = AgentDataPaths(temp.path);
    Directory(paths.modelsDir).createSync(recursive: true);
    File(p.join(paths.modelsDir, 'm1.yaml')).writeAsStringSync(
      'model_id: m1\nbase_url: https://api.example.com\napi_key: k\n',
    );
    settings = CoreSettings.load(paths);
    memory = MemoryStore();
    registry = SubagentRegistry(persistence: memory);
    service = SubagentService(
      store: SubagentStore(inner: memory, registry: registry),
      registry: registry,
      settings: settings,
    );
    int now = DateTime.now().millisecondsSinceEpoch;
    caller = CoreAgent(
      id: 'agt',
      name: '主控',
      modelId: 'm1',
      createdAt: now,
      updatedAt: now,
    );
    memory.putAgent(caller);
    turns.clear();
    service.runner = (SubagentTurnRequest request) async {
      turns.add(request);
      return const SubagentTurnResult(report: '{"files": ["a.dart"]}');
    };
  });

  tearDown(() {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  WorkerSpec spec(
    String role, {
    List<String>? tools,
    String modelId = '',
    String reuse = '',
  }) => parseWorkerArguments(<String, Object?>{
    'role': role,
    'task': '干活：$role',
    'tools': ?tools,
    if (modelId.isNotEmpty) 'model_id': modelId,
    if (reuse.isNotEmpty) 'reuse': reuse,
  });

  test('新召员工：模型与工具按参数落地，回 worker_id 与最终报告', () async {
    final Map<String, Object?> result = await service.runWorker(
      spec(
        'packer',
        tools: <String>['read', 'grep', 'message'],
        modelId: 'm1',
      ),
      callerId: 'agt',
      sessionId: 's1',
    );
    expect(result['error'], '');
    expect(result['status'], 'ok');
    expect(result['role'], 'packer');
    expect(result['model_id'], 'm1');
    expect(result['tools'], <String>['read', 'grep', 'message']);
    expect(result['reused'], false);
    expect(result['report'], contains('files'));
    final String id = '${result['worker_id']}';
    expect(id, startsWith('sub_'));
    final CoreSubagent? record = registry.handle(id);
    expect(record, isNotNull);
    expect(record!.agent.role, 'packer');
    expect(record.agent.toolPolicy, <String>['read', 'grep', 'message']);
    expect(record.agent.modelId, 'm1');
    expect(record.level, 1);
    expect(turns.single.task, '干活：packer');
  });

  test('模型不在池里 / 没有模型：可读拒绝，不进入运行器', () async {
    final Map<String, Object?> missing = await service.runWorker(
      spec('packer', modelId: 'nope'),
      callerId: 'agt',
      sessionId: 's1',
    );
    expect(missing['code'], 'model_not_found');
    expect(turns, isEmpty);

    final CoreAgent noModel = CoreAgent(
      id: 'no_model',
      name: '没模型',
      createdAt: 1,
      updatedAt: 1,
    );
    memory.putAgent(noModel);
    final Map<String, Object?> none = await service.runWorker(
      spec('packer'),
      callerId: 'no_model',
      sessionId: 's1',
    );
    expect(none['code'], 'model_required');
  });

  test('复用：同角色可复用（换模型 / 工具），跨角色拒绝', () async {
    final Map<String, Object?> first = await service.runWorker(
      spec('executor'),
      callerId: 'agt',
      sessionId: 's1',
    );
    final String id = '${first['worker_id']}';
    final Map<String, Object?> again = await service.runWorker(
      spec(
        'executor',
        tools: <String>['read', 'edit'],
        reuse: id,
      ),
      callerId: 'agt',
      sessionId: 's1',
    );
    expect(again['reused'], true);
    expect(again['worker_id'], id);
    expect(registry.handle(id)!.agent.toolPolicy, <String>['read', 'edit']);

    final Map<String, Object?> wrong = await service.runWorker(
      spec('packer', reuse: id),
      callerId: 'agt',
      sessionId: 's1',
    );
    expect(wrong['error'], contains('角色是 executor'));
  });

  test('未知 agent / 空会话：可读拒绝', () async {
    final Map<String, Object?> unknown = await service.runWorker(
      spec('packer'),
      callerId: 'nope',
      sessionId: 's1',
    );
    expect(unknown['code'], 'unknown_agent');
    final Map<String, Object?> noSession = await service.runWorker(
      spec('packer'),
      callerId: 'agt',
      sessionId: '',
    );
    expect(noSession['error'], contains('缺少会话上下文'));
  });
}
