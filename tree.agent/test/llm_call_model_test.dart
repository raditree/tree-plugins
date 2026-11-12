import 'package:test/test.dart';
import 'package:tree_agent_loop/tree_agent_loop.dart';

/// `llm.call` 的模型选择（D5/D6）：显式 model_id 优先，且不要求 Agent 存在。
void main() {
  test('显式 model_id 优先，即使 Agent 不存在', () {
    expect(
      llmCallModelId(
        explicitModelId: 'prov/m1',
        agentModelId: '',
        agentExists: false,
      ),
      'prov/m1',
    );
    expect(
      llmCallModelId(
        explicitModelId: 'prov/m1',
        agentModelId: 'chat/main',
        agentExists: true,
      ),
      'prov/m1',
    );
  });

  test('未显式给模型 → 用 Agent 的模型', () {
    expect(
      llmCallModelId(
        explicitModelId: '',
        agentModelId: 'chat/main',
        agentExists: true,
      ),
      'chat/main',
    );
  });

  test('两者都没有 → null（调用方回「agent 不存在」）', () {
    expect(
      llmCallModelId(
        explicitModelId: '   ',
        agentModelId: '',
        agentExists: false,
      ),
      isNull,
    );
  });
}
