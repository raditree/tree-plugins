import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_agent_loop/src/paths.dart';
import 'package:tree_agent_loop/src/runtime/agent_runtime.dart';

import 'ported_core.dart';

/// `llm.embed`（DN-9）：模型池 kind=embedding 的宿主出口。
///
/// 只钉两件确定性的事：空 inputs 不发 HTTP、只解析模型与维度；没有
/// embedding 模型时 fail-closed（docnorm 据此把索引降级为 lexical）。
void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_agent_embed_');
  });

  tearDown(() async {
    await AgentRuntime.debugCloseAll();
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  Future<({AgentRuntime runtime, String agentId})> runtimeWith({
    required bool embeddingModel,
  }) async {
    final AgentDataPaths paths = AgentDataPaths(temp.path);
    Directory(paths.modelsDir).createSync(recursive: true);
    if (embeddingModel) {
      File(p.join(paths.modelsDir, 'emb.yaml')).writeAsStringSync('''
model_id: emb1
name: emb
base_url: http://127.0.0.1:1/v1
api_key: k
kind: embedding
dimensions: 8
''');
    }
    final FileTreeStore store = FileTreeStore(TreePaths(temp.path));
    final CoreAgent agent = store.createAgent(name: '夹具', modelId: 'emb1');
    await store.flush();
    await store.close();
    return (runtime: AgentRuntime(paths: paths), agentId: agent.id);
  }

  Future<Map<String, dynamic>> embed(
    AgentRuntime runtime,
    String agentId,
    Map<String, dynamic> arguments,
  ) => runtime.handleAgentToolCommand('llm.embed', arguments, <String, dynamic>{
    'agent_id': agentId,
    'session_id': 'session_default',
  });

  test('空 inputs 只解析 embedding 模型，不发请求', () async {
    final ({AgentRuntime runtime, String agentId}) fixture = await runtimeWith(
      embeddingModel: true,
    );
    final Map<String, dynamic> reply = await embed(
      fixture.runtime,
      fixture.agentId,
      <String, dynamic>{'inputs': <String>[]},
    );
    expect(reply['ok'], isTrue, reason: '$reply');
    expect(reply['model'], 'emb1');
    expect(reply['dimensions'], 8);
    expect(reply['vectors'], isEmpty);
  });

  test('没有 embedding 模型 ⇒ no_embedding_model', () async {
    final ({AgentRuntime runtime, String agentId}) fixture = await runtimeWith(
      embeddingModel: false,
    );
    final Map<String, dynamic> reply = await embed(
      fixture.runtime,
      fixture.agentId,
      <String, dynamic>{'inputs': <String>[]},
    );
    expect(reply['ok'], isNull);
    expect(reply['code'], 'no_embedding_model', reason: '$reply');
  });
}
