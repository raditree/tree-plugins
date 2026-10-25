import 'package:test/test.dart';
import 'package:tree_agent_loop/src/agent/attachment_prompt.dart';
import 'package:tree_agent_loop/src/agent/tool_result_repair.dart';

/// 提示词小件：附件说明段与工具结果自动修复文案（从核心平移）。
void main() {
  group('附件路径与提示词后缀', () {
    test('无附件 / 空路径条目被剔除，顺序保持', () {
      expect(attachmentPaths(null), isEmpty);
      expect(attachmentPaths(<Map<String, dynamic>>[]), isEmpty);
      expect(
        attachmentPaths(<Map<String, dynamic>>[
          <String, dynamic>{'path': '.input/a.png'},
          <String, dynamic>{'path': '   '},
          <String, dynamic>{'name': '没有路径'},
          <String, dynamic>{'path': '.input/b.pdf'},
        ]),
        <String>['.input/a.png', '.input/b.pdf'],
      );
    });

    test('没有任何有效路径 ⇒ 空串（调用方原样跳过）', () {
      expect(attachmentsPromptSuffix(null), '');
      expect(
        attachmentsPromptSuffix(<Map<String, dynamic>>[
          <String, dynamic>{'name': 'x'},
        ]),
        '',
      );
    });

    test('逐字形态：标题、逐行路径、读取提示', () {
      expect(
        attachmentsPromptSuffix(<Map<String, dynamic>>[
          <String, dynamic>{'path': '.input/a.png'},
          <String, dynamic>{'path': '.input/b.pdf'},
        ]),
        '\n\n[用户上传的附件（已保存到工作空间，路径相对工作空间根）]\n'
        '- .input/a.png\n'
        '- .input/b.pdf\n'
        '需要时用 read 等文件工具按上述相对路径读取。',
      );
    });
  });

  group('工具结果自动修复文案', () {
    test('如实说明失败并给出自处建议；名字/call_id 去空白', () {
      final String text = autoRepairToolResultText(
        toolName: '  read  ',
        toolCallId: ' call_1 ',
      );
      expect(text, contains('【自动修复】'));
      expect(text, contains('read（call_id=call_1）'));
      expect(text, contains('结果永远拿不到'));
      expect(text, contains('按**失败**收尾'));
      expect(text, contains('不要假设它成功'));
    });

    test('缺名字与 call_id 时有明确占位，不编造内容', () {
      final String text = autoRepairToolResultText(
        toolName: '',
        toolCallId: '  ',
      );
      expect(text, contains('（未知工具）（call_id=（没有 call_id））'));
      expect(text.contains('退出码'), isFalse);
    });
  });
}
