import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_local_executor/tree_local_executor.dart';

/// `local.file.list` / `local.file.grep` 的默认排除口径：
/// - 隐藏项（`.` 开头）默认不列 / 不搜（`include_hidden=true` 可显式打开）；
/// - grep 额外跳过 node_modules / build 等依赖产物目录（`include_ignored=true` 可打开）；
/// - 显式 `path` 指向隐藏目录时，搜的是它**下面**的内容（不能因为 base 自己带点就全空）。
void main() {
  late Directory temp;
  late LocalExecutor executor;
  late String leaseId;

  Future<Map<String, dynamic>> run(
    String command,
    Map<String, dynamic> args,
  ) => executor.execute(command, <String, dynamic>{
    'local_lease_id': leaseId,
    ...args,
  }, sourcePluginId: 'tree.agent');

  void write(String relative, String content) {
    final File file = File('${temp.path}/$relative');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tree_grep_list_');
    write('visible.txt', 'needle here\n');
    write('sub/visible2.txt', 'another needle\n');
    write('.hidden/secret.txt', 'hidden needle\n');
    write('node_modules/pkg/index.js', 'module needle\n');
    write('build/out.txt', 'build needle\n');
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

  test('list 默认排除隐藏项；include_hidden=true 才列出', () async {
    final Map<String, dynamic> hiddenOff = await run('local.file.list', {
      'path': '.',
      'max_depth': 1,
    });
    final List<String> names = <String>[
      for (final Object? item in hiddenOff['entries'] as List<dynamic>)
        item.toString(),
    ];
    expect(names, contains('visible.txt'));
    expect(names.any((String name) => name.startsWith('.hidden')), isFalse);

    final Map<String, dynamic> hiddenOn = await run('local.file.list', {
      'path': '.',
      'max_depth': 1,
      'include_hidden': true,
    });
    final List<String> withHidden = <String>[
      for (final Object? item in hiddenOn['entries'] as List<dynamic>)
        item.toString(),
    ];
    expect(withHidden, contains('.hidden/'));
  });

  test('grep 默认排除隐藏项与依赖/产物目录', () async {
    final Map<String, dynamic> result = await run('local.file.grep', {
      'pattern': 'needle',
      'path': '.',
    });
    final List<String> paths = <String>[
      for (final Object? item in result['matches'] as List<dynamic>)
        (item as Map<dynamic, dynamic>)['path'].toString(),
    ];
    expect(paths, containsAll(<String>['visible.txt', 'sub/visible2.txt']));
    expect(paths.any((String path) => path.startsWith('.hidden')), isFalse);
    expect(paths.any((String path) => path.startsWith('node_modules')), isFalse);
    expect(paths.any((String path) => path.startsWith('build')), isFalse);
  });

  test('grep 显式指向隐藏目录时，搜索它下面的内容', () async {
    final Map<String, dynamic> result = await run('local.file.grep', {
      'pattern': 'needle',
      'path': '.hidden',
    });
    expect(result['count'], 1);
    expect(
      ((result['matches'] as List<dynamic>).single as Map<dynamic, dynamic>)['path'],
      '.hidden/secret.txt',
    );
  });

  test('grep include_hidden/include_ignored 显式打开后才搜那些目录', () async {
    final Map<String, dynamic> hidden = await run('local.file.grep', {
      'pattern': 'needle',
      'path': '.',
      'include_hidden': true,
    });
    final List<String> hiddenPaths = <String>[
      for (final Object? item in hidden['matches'] as List<dynamic>)
        (item as Map<dynamic, dynamic>)['path'].toString(),
    ];
    expect(hiddenPaths, contains('.hidden/secret.txt'));

    final Map<String, dynamic> ignored = await run('local.file.grep', {
      'pattern': 'needle',
      'path': '.',
      'include_ignored': true,
    });
    final List<String> ignoredPaths = <String>[
      for (final Object? item in ignored['matches'] as List<dynamic>)
        (item as Map<dynamic, dynamic>)['path'].toString(),
    ];
    expect(ignoredPaths, contains('node_modules/pkg/index.js'));
    expect(ignoredPaths, contains('build/out.txt'));
  });

  test('grep 达到 max_files 上限时截断并如实回报', () async {
    final Map<String, dynamic> result = await run('local.file.grep', {
      'pattern': 'needle',
      'path': '.',
      'max_files': 1,
    });
    expect(result['scanned_file_count'], 1);
    expect(result['truncated'], isTrue);
  });
}
