import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_docnorm/tree_docnorm.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_docnorm_test_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  void write(String path, String content) {
    final File file = File('${temp.path}${Platform.pathSeparator}$path');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  test('无 manifest 的仓库走 fallback，并标 degraded', () async {
    write('notes.txt', 'hello\n');
    final ScanResult result = await scanRepository(temp.path);
    expect(result.packages, hasLength(1));
    expect(result.packages.first.language, 'fallback');
    expect(result.packages.first.degraded, isTrue);
    expect(result.degraded, isTrue);
    expect(result.adapters, contains('fallback'));
  });

  test('多包仓库生成包图与依赖边', () async {
    write(
      'packages/a/pubspec.yaml',
      'name: pkg_a\ndependencies:\n  pkg_b: ^1.0.0\n',
    );
    write('packages/a/lib/a.dart', 'class A {}\n');
    write('packages/b/pubspec.yaml', 'name: pkg_b\n');
    write('packages/b/lib/b.dart', 'class B {}\n');
    final ScanResult result = await scanRepository(temp.path);
    final PackageUnit a = result.packages.firstWhere(
      (PackageUnit unit) => unit.id == 'pkg_a',
    );
    expect(
      result.packages.map((PackageUnit unit) => unit.id),
      contains('pkg_b'),
    );
    expect(a.dependsOn, contains('pkg_b'));
  });

  test('Web-HTTP 无 manifest 也能抽端点', () async {
    write('openapi.yaml', 'openapi: 3.0.0\npaths:\n  /users:\n    get: {}\n');
    write('requests.http', 'POST /login\n');
    final ScanResult result = await scanRepository(temp.path);
    final PackageUnit http = result.packages.firstWhere(
      (PackageUnit unit) => unit.language == 'http',
    );
    expect(http.api.count, 2);
    expect(http.api.endpoints, hasLength(2));
  });

  test('超大/二进制文件被跳过，不让扫描炸掉', () async {
    final File binary = File('${temp.path}${Platform.pathSeparator}bin.dat');
    binary.writeAsBytesSync(<int>[0, 1, 2, 3]);
    write('pubspec.yaml', 'name: safe\n');
    write('lib/a.dart', 'class A {}\n');
    final ScanResult result = await scanRepository(temp.path);
    expect(result.packages.first.id, 'safe');
    expect(result.filesScanned, greaterThan(0));
    expect(result.packages.first.fileCount, 1);
  });
}
