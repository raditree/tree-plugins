import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_local_exec/tree_local_exec.dart' show Shell;
import 'package:tree_local_executor/tree_local_executor.dart';

/// terminal 失败时**输出不许丢**（2026-11-15 现场回归）。
///
/// 现场：中文 Windows 上 `cmd` 的报错是 GBK 字节，旧实现用 `readAsString()`
/// （严格 UTF-8）读 hook 日志，解码抛 `FormatException` 被吞成空串，工具只回
/// 「退出码 1」——调用方看不到 `'ls' 不是内部或外部命令…`，只能盲猜。
///
/// 这里让命令**打印一段非 UTF-8 内容再以 1 退出**，钉住两条命令路径
/// （hook 软超时 / 直接执行）都必须把输出原样交回来。
void main() {
  late Directory temp;
  late LocalExecutor executor;
  late String leaseId;

  /// GBK 的「不是」：在严格 UTF-8 下非法，正好走"非 UTF-8 输出"这条路。
  final List<int> gbkNot = <int>[0xB2, 0xBB, 0xCA, 0xC7];

  Future<Map<String, dynamic>> run(
    String command,
    Map<String, dynamic> args,
  ) => executor.execute('local.exec.command', <String, dynamic>{
    'local_lease_id': leaseId,
    'command': command,
    ...args,
  }, sourcePluginId: 'tree.agent');

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tree_terminal_out_');
    // 首尾带 ASCII 标记：无论系统代码页是什么，这两段都必须原样出现。
    File('${temp.path}/gbk.txt').writeAsBytesSync(<int>[
      ...ascii.encode('GBK:'),
      ...gbkNot,
      ...ascii.encode(':END\r\n'),
    ]);
    executor = LocalExecutor();
    final Map<String, dynamic> registered = await executor.execute(
      kLocalLeaseRegisterCommand,
      <String, dynamic>{'dir': temp.path},
      sourcePluginId: 'tree.agent',
    );
    leaseId = registered['lease_id'].toString();
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  /// 打印非 UTF-8 内容后**以 1 退出**（模拟 `ls -la` 这种"失败 + 有输出"）。
  ///
  /// `&&` 三种 shell 都认（PowerShell 5.1 由包装层翻译，7 原生支持，cmd 原生支持），
  /// 所以这条用例不依赖本机最终选中的是哪一个。
  String failingOutput() => Platform.isWindows
      ? 'type gbk.txt && exit 1'
      : 'cat gbk.txt; exit 1';

  void expectOutputKept(Map<String, dynamic> result) {
    expect(result['exit_code'], 1);
    final String text = '${result['text']}';
    expect(text, contains('GBK:'), reason: '输出前半段不能丢');
    expect(text, contains(':END'), reason: '输出后半段不能丢');
  }

  test('hook 路径（软超时）：非 0 退出码 + 非 UTF-8 输出仍然交回', () async {
    final Map<String, dynamic> result = await run(failingOutput(), {
      'timeout_seconds': 10,
    });
    expectOutputKept(result);
    final String text = '${result['text']}';
    expect(text, contains('退出码 1'));
    expect(text, contains('--- 输出 ---'), reason: '失败时也要有输出段');
  });

  test('直接路径（timeout_seconds=0）：非 0 退出码 + 非 UTF-8 输出仍然交回', () async {
    final Map<String, dynamic> result = await run(failingOutput(), {
      'timeout_seconds': 0,
    });
    expectOutputKept(result);
  });

  test('Windows 上命令走 PowerShell：pwd 有输出、ls 能列目录', () async {
    // cmd 下 `pwd` 不存在、`ls` 也不存在；这两条只有在 PowerShell 里才成立。
    if (!Platform.isWindows) return;
    if (Shell.windowsShell.toLowerCase().endsWith('cmd.exe')) return;

    final Map<String, dynamic> pwd = await run('pwd', {'timeout_seconds': 10});
    expect(pwd['exit_code'], 0, reason: '${pwd['text']}');
    expect('${pwd['text']}', contains(temp.path), reason: 'pwd 的输出不能被吞');

    final Map<String, dynamic> ls = await run('ls', {'timeout_seconds': 10});
    expect(ls['exit_code'], 0, reason: '${ls['text']}');
    expect('${ls['text']}', contains('gbk.txt'));
  });
}
