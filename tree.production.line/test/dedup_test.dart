import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

/// DN-dedup：函数级分块 + 内容寻址向量缓存 + 全库 top-k。
void main() {
  group('函数级分块', () {
    test('Dart：类方法与顶层函数，行号漂移不换 id', () {
      const String source = '''
class Alpha {
  String run(String input) {
    final parts = input.split(',');
    return parts.map((e) => e.trim()).join('-');
  }
}

String helper(String value) {
  return value.toUpperCase().padLeft(12, 'x');
}
''';
      final List<CodeChunk> chunks = chunkFile('lib/a.dart', source);
      expect(chunks.map((CodeChunk c) => c.scope), containsAll(<String>[
        'Alpha.run',
        'helper',
      ]));
      final List<CodeChunk> shifted = chunkFile(
        'lib/a.dart',
        '\n\n$source',
      );
      expect(
        shifted.map((CodeChunk c) => c.id).toSet(),
        chunks.map((CodeChunk c) => c.id).toSet(),
      );
      expect(shifted.first.startLine, greaterThan(chunks.first.startLine));
    });

    test('Python / Go / Rust / TS 都能切出函数', () {
      expect(
        chunkFile('a.py', '''
def run(value):
    total = 0
    for item in value:
        total += item
    return total

class Demo:
    def work(self, value):
        return [x for x in value if x]
''').map((CodeChunk c) => c.scope),
        containsAll(<String>['run', 'Demo.work']),
      );
      expect(
        chunkFile('a.go', '''
package main

func Start(value int) int {
  // 保持函数体足够长，越过最小分块长度
  total := value * 2
  return total + 1
}
''').map((CodeChunk c) => c.scope),
        contains('Start'),
      );
      expect(
        chunkFile('a.rs', '''
pub fn run(value: i32) -> i32 {
    // 保持函数体足够长，越过最小分块长度
    let next = value + 1;
    next * 2
}
''').map((CodeChunk c) => c.scope),
        contains('run'),
      );
      expect(
        chunkFile('a.ts', '''
export function boot(value: string) {
  // 保持函数体足够长，越过最小分块长度
  const trimmed = value.trim();
  return trimmed.toLowerCase();
}
const later = (input: string) =>
  input.trim().toUpperCase();
''').map((CodeChunk c) => c.scope),
        containsAll(<String>['boot', 'later']),
      );
    });

    test('无法识别函数时整文件 fallback，代码围栏不破坏分块', () {
      final List<CodeChunk> chunks = chunkFile(
        'a.ts',
        'const value = 1;\nconst other = 2;',
      );
      expect(chunks.single.scope, '(file)');
      final List<CodeChunk> fenced = chunkFile('a.dart', '''
void run() {
  final values = <int>[1, 2, 3];
  for (final value in values) {
    print(value);
  }
}
''');
      expect(fenced.single.scope, 'run');
    });
  });

  group('配置与向量键', () {
    test('模型 / 前缀 / 归一化变化都会换 vecKey', () {
      const DedupConfig base = DedupConfig.defaults;
      final String a = base.vecKeyOf(
        contentHash: 'h',
        model: 'm1',
        dimensions: 8,
      );
      expect(
        a,
        isNot(base.vecKeyOf(contentHash: 'h', model: 'm2', dimensions: 8)),
      );
      final DedupConfig prefixed = DedupConfig.fromValues(<String, Object?>{
        'dedup_instruction_prefix': <String, Object?>{'value': 'x'},
      });
      expect(
        prefixed.vecKeyOf(contentHash: 'h', model: 'm1', dimensions: 8),
        isNot(a),
      );
    });

    test('余弦与 top-k 排序确定性', () {
      final List<double> v = <double>[1, 0, 0, 0];
      final List<DedupCandidate> candidates = <DedupCandidate>[
        DedupCandidate(
          id: 'ch-b',
          path: 'b.dart',
          scope: 'b',
          hash: 'hb',
          vector: normalizeToFloat32(<double>[1, 0.01, 0, 0]),
        ),
        DedupCandidate(
          id: 'ch-a',
          path: 'a.dart',
          scope: 'a',
          hash: 'ha',
          vector: normalizeToFloat32(<double>[1, 0, 0, 0]),
        ),
      ];
      final List<DedupMatch> matches = topMatches(
        selfId: 'ch-self',
        selfPath: 's.dart',
        selfHash: 'hs',
        vector: normalizeToFloat32(v),
        candidates: candidates,
        k: 2,
        threshold: 0.5,
      );
      expect(matches.first.id, 'ch-a');
      expect(matches.first.score, closeTo(1, 0.000001));
    });
  });

  group('production.dedup.run', () {
    late Directory temp;
    late Directory workspace;
    late _FakeStorage storage;
    late _FakeEmbed embed;
    late ProductionDedupService service;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('tree_dedup_');
      workspace = Directory(p.join(temp.path, 'ws'))..createSync();
      _writeFile(workspace, 'lib/a.dart', _alphaSource());
      _writeFile(workspace, 'lib/b.dart', _gammaSource());
      _gitInit(workspace);
      ProductionStore(dataRoot: temp.path).createLine(<String, Object?>{
        'id': 'pl_a',
        'name': 'dedup',
        'workspace_dir': workspace.path,
      });
      storage = _FakeStorage();
      embed = _FakeEmbed();
      service = ProductionDedupService(
        environment: const <String, String>{},
        storage: storage.call,
        embed: embed.call,
        settings: () async => DedupConfig.defaults,
      );
    });

    tearDown(() {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<Map<String, Object?>> run({String mode = ''}) async {
      Map<String, Object?> last = <String, Object?>{};
      for (int i = 0; i < 20; i++) {
        last = await service.handle(
          'production.dedup.run',
          <String, Object?>{'line_id': 'pl_a', if (mode.isNotEmpty) 'mode': mode},
          <String, Object?>{'data_dir': temp.path},
          <String, Object?>{},
        );
        if (last['done'] == true) break;
      }
      return last;
    }

    test('首次全量基线；无变更二次 0 次 embedding', () async {
      final Map<String, Object?> first = await run();
      expect(first['done'], true);
      expect(embed.requests, greaterThan(0));
      final int afterFirst = embed.requests;
      expect(storage.collection('dedup_chunks'), isNotEmpty);
      expect(storage.collection('dedup_vectors'), isNotEmpty);

      final Map<String, Object?> second = await run();
      expect(second['done'], true);
      expect(embed.requests, afterFirst, reason: '无变更不应再请求 embedding');
    });

    test('改一个函数只嵌新 chunk；删除文件清理缓存', () async {
      await run();
      final int before = embed.requests;
      _writeFile(workspace, 'lib/a.dart', _alphaSource(betaBody: "return 'changed'.toUpperCase();"));
      final Map<String, Object?> changed = await run();
      expect(changed['progress'] is Map, true);
      expect(embed.requests, before + 1, reason: '只应重新嵌入被改的 beta');

      File(p.join(workspace.path, 'lib', 'b.dart')).deleteSync();
      await run();
      final bool hasB = storage.collection('dedup_chunks').keys.any(
        (String key) => '${storage.collection('dedup_chunks')[key]}'.contains('b.dart'),
      );
      expect(hasB, false, reason: '删除文件后旧 chunk 必须清理');
    });

    test('改名内容不变：走内容寻址 0 次新 embedding', () async {
      await run();
      final int before = embed.requests;
      Process.runSync('git', <String>['mv', 'lib/a.dart', 'lib/c.dart'], workingDirectory: workspace.path);
      final Map<String, Object?> moved = await run();
      expect(moved['done'], true);
      expect(embed.requests, before, reason: '内容未变应命中缓存');
      expect(
        storage.collection('dedup_files').keys.any(
          (String key) => key.endsWith('#file:lib/c.dart'),
        ),
        true,
      );
    });

    test('新 chunk 与全库比对：命中另一个未变更文件', () async {
      await run();
      _writeFile(
        workspace,
        'lib/b.dart',
        '${_gammaSource()}\n${_alphaSource()}',
      );
      final Map<String, Object?> result = await run();
      expect(result['done'], true);
      final String pair = storage
          .collection('dedup_results')
          .values
          .expand((Map<String, Object?> value) =>
              (value['matches'] as List<Object?>? ?? const <Object?>[]))
          .map((Object? item) => '$item')
          .firstWhere((String text) => text.contains('lib/a.dart'), orElse: () => '');
      expect(pair, isNotEmpty, reason: '新函数应命中另一个未变更文件里的同内容函数');
    });

    test('rebuild 清空后重建', () async {
      await run();
      final Map<String, Object?> rebuilt = await run(mode: 'rebuild');
      expect(rebuilt['done'], true);
      expect(rebuilt['mode'], 'rebuild');
      expect(storage.collection('dedup_meta'), isNotEmpty);
    });
  });
}

void _writeFile(Directory workspace, String relative, String content) {
  final File file = File(
    p.joinAll(<String>[workspace.path, ...relative.split('/')]),
  );
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

void _gitInit(Directory workspace) {
  Process.runSync('git', <String>['init', '--quiet'], workingDirectory: workspace.path);
  Process.runSync('git', <String>['add', '-A'], workingDirectory: workspace.path);
  Process.runSync('git', <String>[
    '-c',
    'user.name=t',
    '-c',
    'user.email=t@t',
    'commit',
    '--quiet',
    '--no-gpg-sign',
    '-m',
    'init',
  ], workingDirectory: workspace.path);
}

class _FakeStorage {
  final Map<String, Map<String, Map<String, Object?>>> db =
      <String, Map<String, Map<String, Object?>>>{};

  Map<String, Map<String, Object?>> collection(String name) =>
      db.putIfAbsent(name, () => <String, Map<String, Object?>>{});

  Future<Map<String, dynamic>> call(
    String command,
    Map<String, dynamic> arguments,
  ) async {
    final String collectionName = '${arguments['collection'] ?? ''}';
    final Map<String, Map<String, Object?>> records = collection(collectionName);
    switch (command) {
      case 'storage.ensure':
        return <String, dynamic>{'ok': true};
      case 'storage.get':
        return <String, dynamic>{
          'ok': true,
          'value': records['${arguments['key'] ?? ''}'],
        };
      case 'storage.put':
        records['${arguments['key']}'] = Map<String, Object?>.from(
          (arguments['value'] as Map).cast<String, Object?>(),
        );
        return <String, dynamic>{'ok': true, 'rev': 1};
      case 'storage.delete':
        records.remove('${arguments['key']}');
        return <String, dynamic>{'ok': true, 'deleted': true};
      case 'storage.scan':
        final String prefix = '${arguments['prefix'] ?? ''}';
        final int limit = (arguments['limit'] as num?)?.toInt() ?? 1000;
        final List<String> keys = records.keys.where(
          (String key) => key.startsWith(prefix),
        ).toList()..sort();
        return <String, dynamic>{
          'ok': true,
          'values': <Map<String, Object?>>[
            for (final String key in keys.take(limit))
              <String, Object?>{'key': key, 'value': records[key]},
          ],
          'has_more': keys.length > limit,
        };
      case 'storage.query':
        final List<String> keys = records.keys.toList()..sort();
        return <String, dynamic>{
          'ok': true,
          'values': <Map<String, Object?>>[
            for (final String key in keys)
              <String, Object?>{'key': key, 'value': records[key]},
          ],
          'has_more': false,
          'cursor': '',
        };
      case 'storage.tx':
        for (final Object? raw in (arguments['ops'] as List<dynamic>? ?? const [])) {
          if (raw is! Map) continue;
          final String name = '${raw['collection'] ?? ''}';
          final Map<String, Map<String, Object?>> target = collection(name);
          if ('${raw['op']}' == 'delete') {
            target.remove('${raw['key']}');
          } else {
            target['${raw['key']}'] = Map<String, Object?>.from(
              (raw['value'] as Map).cast<String, Object?>(),
            );
          }
        }
        return <String, dynamic>{'ok': true, 'committed': true};
      default:
        return <String, dynamic>{
          'ok': false,
          'error': 'unknown $command',
          'code': 'unknown_command',
        };
    }
  }
}

class _FakeEmbed {
  int requests = 0;
  int inputs = 0;

  Future<DedupEmbedReply> call(DedupEmbedRequest request) async {
    if (request.inputs.isEmpty) {
      return const DedupEmbedReply(model: 'fake', dimensions: 4);
    }
    requests += 1;
    inputs += request.inputs.length;
    return DedupEmbedReply(
      model: 'fake',
      dimensions: 4,
      vectors: <List<double>>[
        for (final String text in request.inputs) _vectorOf(text),
      ],
    );
  }

  static List<double> _vectorOf(String text) {
    final String hash = fnv1aHex(text);
    return normalizeVector(<double>[
      for (int i = 0; i < 4; i++)
        (int.parse(hash.substring(i * 4, i * 4 + 4), radix: 16) + 1) / 65536.0,
    ]).toList();
  }
}

String _alphaSource({String betaBody = "return input.toUpperCase().padLeft(12, 'x');"}) =>
    '''
class Alpha {
  String alpha(String input) {
    final parts = input.split(',');
    return parts.map((e) => e.trim()).where((e) => e.isNotEmpty).join('-');
  }

  String beta(String input) {
    $betaBody
  }
}
''';

String _gammaSource() => '''
int gamma(int value) {
  var total = 0;
  for (var i = 0; i < value; i++) {
    total += i * i;
  }
  return total;
}
''';
