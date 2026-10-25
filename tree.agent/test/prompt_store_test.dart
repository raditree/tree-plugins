import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_agent_loop/src/settings/prompt_store.dart';

import 'test_workspace_io.dart';

void main() {
  late Directory temp;
  late TestWorkspaceIO io;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_prompt_');
    io = TestWorkspaceIO(temp.path);
  });
  tearDown(() {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('reset：备份自定义提示词并写回默认种子，备份序号递增', () async {
    await io.writeFile(SystemPromptStore.promptPath, 'my custom prompt');
    final SystemPromptStore store = SystemPromptStore();
    final PromptResetResult first = await store.reset('agt', io);
    expect(first.restored, isTrue);
    expect(first.backup, '${SystemPromptStore.promptPath}.bak.1');
    expect((await io.readFile(first.backup)).text, contains('my custom prompt'));
    final String seeded = (await io.readFile(SystemPromptStore.promptPath)).text;
    expect(seeded, contains('专业执行者'));

    final PromptResetResult second = await store.reset('agt', io);
    expect(second.backup, '${SystemPromptStore.promptPath}.bak.2');
  });

  test('seedIfMissing：只补缺失，不覆盖用户文件', () async {
    final SystemPromptStore store = SystemPromptStore();
    expect(await store.seedIfMissing(io), isTrue);
    await io.writeFile(SystemPromptStore.promptPath, 'user version');
    expect(await store.seedIfMissing(io), isFalse);
    expect((await io.readFile(SystemPromptStore.promptPath)).text, 'user version');
  });
}