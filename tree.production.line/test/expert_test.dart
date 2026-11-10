import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

/// P5 专家工具（§9.4）：工具声明、提问契约、四段回答与工具表边界。
void main() {
  test('工具声明：名字 / 必填参数 / 角色枚举', () {
    final Map<String, dynamic> spec = expertToolSpec();
    expect(spec['name'], kAskExpertTool);
    final Map<String, dynamic> parameters =
        spec['parameters'] as Map<String, dynamic>;
    expect(parameters['required'], <String>['line_id', 'task_id', 'question']);
    final Map<String, dynamic> properties =
        parameters['properties'] as Map<String, dynamic>;
    expect(properties.containsKey('context'), isTrue);
    expect(
      (properties['role'] as Map<String, dynamic>)['enum'],
      <String>['packer', 'executor'],
    );
  });

  test('提问契约：缺 question 拒绝；context 超长拒绝且不截断', () {
    expect(
      () => parseExpertArguments(<String, Object?>{'context': 'x'}),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure e) => e.code,
          'code',
          'invalid_arguments',
        ),
      ),
    );
    expect(
      () => parseExpertArguments(<String, Object?>{
        'question': 'X 怎么用？',
        'context': 'x' * (kExpertMaxContextChars + 1),
      }),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure e) => e.code,
          'code',
          'expert_context_too_large',
        ),
      ),
    );
    final ExpertRequest request = parseExpertArguments(<String, Object?>{
      'question': ' X 怎么用？ ',
      'context': ' lib/a.dart:1 ',
      'desired_output': '给最小示例',
      'role': 'packer',
    });
    expect(request.question, 'X 怎么用？');
    expect(request.context, 'lib/a.dart:1');
    expect(request.desiredOutput, '给最小示例');
    expect(request.role, 'packer');
  });

  test('四段回答：结论必填；依据 / 未决列表化；渲染顺序固定', () {
    expect(
      () => parseExpertAnswer(<String, Object?>{'evidence': <String>['a:1']}),
      throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure e) => e.code,
          'code',
          'expert_bad_answer',
        ),
      ),
    );
    final ExpertAnswer answer = parseExpertAnswer(<String, Object?>{
      'conclusion': '用 A',
      'evidence': <Object?>['lib/a.dart:1 — 定义', ''],
      'suggestion': '先 read 再 edit',
      'open': <String>['旧版本未验证'],
    });
    expect(answer.evidence, <String>['lib/a.dart:1 — 定义']);
    final String text = renderExpertAnswer(answer);
    expect(text.indexOf('结论：'), 0);
    expect(text.indexOf('依据：'), greaterThan(text.indexOf('结论：')));
    expect(text.indexOf('建议：'), greaterThan(text.indexOf('依据：')));
    expect(text.indexOf('未决：'), greaterThan(text.indexOf('建议：')));
    expect(text, contains('lib/a.dart:1 — 定义'));
  });

  test('专家工具表：空走默认 read/grep；写 / 再召 / 建团队一律算越界', () {
    expect(expertToolsOf(null), <String>['read', 'grep']);
    expect(expertToolsOf(<String>[]), <String>['read', 'grep']);
    expect(expertToolsOf(<String>['read']), <String>['read']);
    expect(expertToolViolations(<String>['read', 'grep']), isEmpty);
    expect(
      expertToolViolations(<String>['read', 'write', 'edit']),
      <String>['write', 'edit'],
    );
    expect(
      expertToolViolations(<String>[kAskExpertTool, 'subagent', 'team']),
      <String>[kAskExpertTool, 'subagent', 'team'],
    );
  });

  test('提示词：固定四段 + 不许写文件', () {
    expect(expertSystemPrompt(), contains('conclusion'));
    expect(expertSystemPrompt(), contains('不写文件'));
    final String prompt = expertUserPrompt(
      taskId: 'T1',
      title: '改列表',
      request: parseExpertArguments(<String, Object?>{
        'question': 'X 怎么用？',
        'context': 'lib/a.dart:1 class A {}',
      }),
    );
    expect(prompt, contains('任务：T1 改列表'));
    expect(prompt, contains('lib/a.dart:1'));
    expect(prompt, contains('结论 / 依据'));
  });
}
