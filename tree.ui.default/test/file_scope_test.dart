import 'package:flutter_test/flutter_test.dart';

import 'package:tree_ui_default/ui/pages/main_page.dart';

/// 文件窗作用域的纯口径（D4）：产线优先，其次 Agent，都没有为空。
void main() {
  test('产线上下文 → line:<id>，即使同时选着 Agent', () {
    expect(
      fileScopeWorkspaceIdOf(
        line: <String, dynamic>{'id': 'pl_1'},
        agentWorkspaceId: 'ws_agent',
      ),
      'line:pl_1',
    );
  });

  test('产线 id 为空 → 空串（不拼 line:）', () {
    expect(
      fileScopeWorkspaceIdOf(
        line: <String, dynamic>{'id': '  '},
        agentWorkspaceId: 'ws_agent',
      ),
      '',
    );
  });

  test('未选产线 → 回落 Agent 工作空间；都没有 → 空串', () {
    expect(
      fileScopeWorkspaceIdOf(line: null, agentWorkspaceId: 'ws_agent'),
      'ws_agent',
    );
    expect(
      fileScopeWorkspaceIdOf(line: null, agentWorkspaceId: ''),
      '',
    );
  });
}
