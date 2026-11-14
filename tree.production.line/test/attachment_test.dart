/// Task 6：附件探测 / 落盘 / 边界 + `production.task.attach` 与 REST 接线。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_production_line/src/attachment_service.dart';
import 'package:tree_production_line/src/attachments.dart';
import 'package:tree_production_line/tree_production_line.dart';

import 'support/structure_fixture.dart';

void main() {
  late Directory temp;
  late Directory workspace;
  late ProductionStore store;

  const String lineId = 'pl_attach';
  const String taskId = 'T1';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('production_attachment_');
    workspace = Directory(p.join(temp.path, 'ws'))..createSync(recursive: true);
    File(p.join(workspace.path, 'pubspec.yaml'))
        .writeAsStringSync('name: demo\ndescription: 附件测试工作空间\n');
    Directory(p.join(workspace.path, 'lib')).createSync(recursive: true);
    File(p.join(workspace.path, 'lib', 'demo.dart'))
        .writeAsStringSync('int answer() => 42;\n');
    store = ProductionStore(dataRoot: temp.path);
    store.createLine(<String, Object?>{
      'id': lineId,
      'name': '附件产线',
      'workspace_dir': workspace.path,
    });
    store.createTask(lineId, <String, Object?>{
      'id': taskId,
      'title': '附件任务',
      'status': 'queued',
      'brief': '验证附件落盘',
      'acceptance': <String>['附件落盘'],
      'write_scope': <String>['lib/a.dart'],
    });
  });

  tearDown(() {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Matcher failure(String code) => throwsA(
    isA<ProductionFailure>().having(
      (ProductionFailure error) => error.code,
      'code',
      code,
    ),
  );

  Future<void> ready() =>
      markLineReady(store, lineId, temp, workspace: workspace.path);

  String writeAsset(String relative, List<int> bytes) {
    final File file = File(
      p.joinAll(<String>[workspace.path, ...relative.split('/')]),
    );
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    return relative;
  }

  Map<String, Object?> attach(Map<String, Object?> extra) =>
      ProductionAttachmentService().attach(store, <String, Object?>{
        'line_id': lineId,
        'task_id': taskId,
        ...extra,
      });

  Directory attachmentDir() => Directory(
    p.joinAll(<String>[
      workspace.path,
      ...store.attachmentDir(lineId, taskId).split('/'),
    ]),
  );

  group('probeAttachment', () {
    test('PNG：IHDR 宽高 / 透明度 / EXIF', () {
      final AttachmentProbe probe = probeAttachment(
        pngBytes(width: 2, height: 3, colorType: 6, exif: true),
        'image/png',
      );
      expect(probe.format, 'png');
      expect(probe.width, 2);
      expect(probe.height, 3);
      expect(probe.transparent, isTrue);
      expect(probe.hasExif, isTrue);
      expect(probe.animated, isFalse);
      expect(probe.corrupt, isFalse);

      final AttachmentProbe trns = probeAttachment(
        pngBytes(colorType: 2, trns: true),
        'image/png',
      );
      expect(trns.transparent, isTrue);
      expect(trns.corrupt, isFalse);

      final AttachmentProbe bad = probeAttachment(<int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        0x00,
        0x00,
      ], 'image/png');
      expect(bad.corrupt, isTrue);
    });

    test('JPEG：SOF 宽高 + APP1 Exif；截断即 corrupt', () {
      final AttachmentProbe probe = probeAttachment(
        jpegBytes(width: 640, height: 480),
        'image/jpeg',
      );
      expect(probe.format, 'jpeg');
      expect(probe.width, 640);
      expect(probe.height, 480);
      expect(probe.hasExif, isTrue);
      expect(probe.corrupt, isFalse);

      final AttachmentProbe noExif = probeAttachment(
        jpegBytes(width: 10, height: 20, exif: false),
        'image/jpeg',
      );
      expect(noExif.hasExif, isFalse);
      expect(noExif.width, 10);

      final AttachmentProbe bad = probeAttachment(<int>[
        0xFF,
        0xD8,
        0xFF,
        0xE1,
        0x00,
      ], 'image/jpeg');
      expect(bad.corrupt, isTrue);
    });

    test('GIF：宽高 / NETSCAPE 动画 / GCE 透明', () {
      final AttachmentProbe animated = probeAttachment(
        gifBytes(width: 4, height: 5, animated: true, transparent: true),
        'image/gif',
      );
      expect(animated.format, 'gif');
      expect(animated.width, 4);
      expect(animated.height, 5);
      expect(animated.animated, isTrue);
      expect(animated.transparent, isTrue);
      expect(animated.corrupt, isFalse);

      final List<int> still = gifBytes();
      final AttachmentProbe plain = probeAttachment(still, 'image/gif');
      expect(plain.animated, isFalse);
      expect(plain.transparent, isFalse);
    });

    test('WebP：VP8X flags / VP8 / VP8L 宽高；解不出即 corrupt', () {
      final AttachmentProbe vp8x = probeAttachment(
        webpVp8xBytes(
          width: 640,
          height: 480,
          alpha: true,
          exif: true,
          animated: true,
        ),
        'image/webp',
      );
      expect(vp8x.format, 'webp');
      expect(vp8x.width, 640);
      expect(vp8x.height, 480);
      expect(vp8x.transparent, isTrue);
      expect(vp8x.hasExif, isTrue);
      expect(vp8x.animated, isTrue);

      final AttachmentProbe vp8 = probeAttachment(
        webpVp8Bytes(width: 320, height: 240),
        'image/webp',
      );
      expect(vp8.width, 320);
      expect(vp8.height, 240);
      expect(vp8.corrupt, isFalse);

      final AttachmentProbe vp8l = probeAttachment(
        webpVp8lBytes(width: 300, height: 200),
        'image/webp',
      );
      expect(vp8l.width, 300);
      expect(vp8l.height, 200);

      final AttachmentProbe bad = probeAttachment(<int>[
        ...'RIFF'.codeUnits,
        0,
        0,
        0,
        0,
        ...'WEBP'.codeUnits,
      ], 'image/webp');
      expect(bad.corrupt, isTrue);
    });

    test('SVG：宽高可解析；脚本 / 事件 / javascript 判 unsafe', () {
      final AttachmentProbe safe = probeAttachment(
        utf8.encode('<svg width="120" height="80"><rect /></svg>'),
        'image/svg+xml',
      );
      expect(safe.format, 'svg');
      expect(safe.width, 120);
      expect(safe.height, 80);
      expect(safe.unsafeSvg, isFalse);
      expect(safe.corrupt, isFalse);

      final AttachmentProbe script = probeAttachment(
        utf8.encode('<svg width="10"><script>alert(1)</script></svg>'),
        'image/svg+xml',
      );
      expect(script.unsafeSvg, isTrue);
      expect(script.height, 0);

      expect(
        probeAttachment(
          utf8.encode('<svg onload="x()"></svg>'),
          'image/svg+xml',
        ).unsafeSvg,
        isTrue,
      );
      expect(
        probeAttachment(
          utf8.encode('<svg><a href="javascript:void(0)"></a></svg>'),
          'image/svg+xml',
        ).unsafeSvg,
        isTrue,
      );
    });

    test('非图片：不判 corrupt、无格式、无告警', () {
      final AttachmentProbe probe = probeAttachment(
        utf8.encode('%PDF-1.4\n'),
        'application/pdf',
      );
      expect(probe.format, '');
      expect(probe.corrupt, isFalse);
      expect(attachmentWarningsOf(probe: probe, vision: false), isEmpty);
    });
  });

  test('告警稳定顺序：动画 → 透明 → EXIF → 非视觉', () {
    const AttachmentProbe probe = AttachmentProbe(
      format: 'png',
      width: 1,
      height: 1,
      animated: true,
      transparent: true,
      hasExif: true,
    );
    expect(attachmentWarningsOf(probe: probe, vision: false), <String>[
      'image_animated_first_frame',
      'image_transparent',
      'image_exif_present',
      'image_manual_reference',
    ]);
    expect(attachmentWarningsOf(probe: probe, vision: true), <String>[
      'image_animated_first_frame',
      'image_transparent',
      'image_exif_present',
    ]);
  });

  test('拒绝码：大小 → 坏图 → 像素 → 不安全 SVG', () {
    const AttachmentProbe fine = AttachmentProbe(
      format: 'png',
      width: 1,
      height: 1,
    );
    expect(
      attachmentRejectionOf(
        probe: fine,
        bytesLength: kMaxAttachmentBytes + 1,
        isImage: true,
      ),
      'attachment_too_large',
    );
    expect(
      attachmentRejectionOf(
        probe: const AttachmentProbe(format: 'png', corrupt: true),
        bytesLength: 10,
        isImage: true,
      ),
      'image_corrupt',
    );
    expect(
      attachmentRejectionOf(
        probe: const AttachmentProbe(format: 'png', width: 4097, height: 4096),
        bytesLength: 10,
        isImage: true,
      ),
      'image_too_large',
    );
    expect(
      attachmentRejectionOf(
        probe: const AttachmentProbe(format: 'svg', unsafeSvg: true),
        bytesLength: 10,
        isImage: true,
      ),
      'attachment_unsafe_svg',
    );
    expect(
      attachmentRejectionOf(
        probe: const AttachmentProbe(),
        bytesLength: 10,
        isImage: false,
      ),
      isNull,
    );
  });

  test('attach：复制到 .input 并登记完整元数据（不写项目资产）', () async {
    final List<int> content = utf8.encode('hello 附件');
    writeAsset('assets/notes.txt', content);
    await ready();

    final Map<String, Object?> result = attach(<String, Object?>{
      'source': 'assets/notes.txt',
    });
    expect(result['deduplicated'], isFalse);
    expect(result['known_issues'], isEmpty);
    final Map<String, Object?> attachment =
        result['attachment'] as Map<String, Object?>;
    final String sha = sha256.convert(content).toString();
    expect(attachment['sha256'], sha);
    expect(attachment['size'], content.length);
    expect(attachment['type'], 'text/plain');
    expect(attachment['kind'], 'text');
    expect(attachment['name'], 'notes.txt');
    expect(attachment['readable'], isTrue);
    expect(attachment['summary_by'], '');
    expect(attachment['known_issue'], '');
    expect(attachment['added_at'], isNotEmpty);
    expect(
      attachment['path'],
      '.input/production_lines/$lineId/tasks/$taskId/'
      'attachments/${sha.substring(0, 8)}-notes.txt',
    );

    final File stored = File(
      p.joinAll(<String>[
        workspace.path,
        ...'${attachment['path']}'.split('/'),
      ]),
    );
    expect(stored.existsSync(), isTrue);
    expect(stored.readAsStringSync(), 'hello 附件');

    final TaskRecord task = store.getTask(lineId, taskId);
    expect(task.attachments, hasLength(1));
    expect(task.attachments.single['sha256'], sha);
    // 附件落在 .input，不进项目资产目录（docs.production_lines）。
    final String assetRoot = store.assetRoot(lineId).replaceAll('\\', '/');
    final String storedPath = stored.path.replaceAll('\\', '/');
    expect(storedPath.startsWith(assetRoot), isFalse);
    expect(storedPath, contains('/.input/production_lines/'));
  });

  test('attach：同内容重复上传不复制、回 deduplicated', () async {
    writeAsset('assets/dup.txt', utf8.encode('same content'));
    await ready();

    final Map<String, Object?> first = attach(<String, Object?>{
      'source': 'assets/dup.txt',
    });
    final Map<String, Object?> second = attach(<String, Object?>{
      'source': 'assets/dup.txt',
    });
    expect(second['deduplicated'], isTrue);
    expect(
      (second['attachment'] as Map<String, Object?>)['sha256'],
      (first['attachment'] as Map<String, Object?>)['sha256'],
    );
    expect(store.getTask(lineId, taskId).attachments, hasLength(1));
    expect(attachmentDir().listSync().whereType<File>().length, 1);
  });

  test('attach：PDF 只存不读（readable=false + known_issue）', () async {
    writeAsset('docs/spec.pdf', utf8.encode('%PDF-1.4\nbody'));
    await ready();

    final Map<String, Object?> result = attach(<String, Object?>{
      'source': 'docs/spec.pdf',
    });
    final Map<String, Object?> attachment =
        result['attachment'] as Map<String, Object?>;
    expect(attachment['type'], 'application/pdf');
    expect(attachment['kind'], 'pdf');
    expect(attachment['readable'], isFalse);
    expect(attachment['known_issue'], 'attachment_store_only');
    expect(attachment['summary_by'], '');
    expect(
      (result['known_issues'] as List<Object?>),
      contains('attachment_store_only'),
    );
    expect('${result['note']}', contains('只存不读'));
  });

  test(
    'attach：图片 vision=false ⇒ manual_reference；vision=true ⇒ vision_model',
    () async {
      writeAsset('assets/pic.png', pngBytes(width: 4, height: 5, colorType: 6));
      await ready();

      final Map<String, Object?> manual = attach(<String, Object?>{
        'source': 'assets/pic.png',
      });
      final Map<String, Object?> manualAttachment =
          manual['attachment'] as Map<String, Object?>;
      expect(manualAttachment['kind'], 'image');
      expect(manualAttachment['readable'], isFalse);
      expect(manualAttachment['summary_by'], 'manual_reference');
      expect(
        (manual['warnings'] as List<Object?>),
        contains('image_manual_reference'),
      );
    },
  );

  test('attach：vision=true 时图片交给 vision_model', () async {
    writeAsset('assets/pic.png', pngBytes(width: 6, height: 7, colorType: 2));
    await ready();

    final Map<String, Object?> result = attach(<String, Object?>{
      'source': 'assets/pic.png',
      'vision': true,
    });
    final Map<String, Object?> attachment =
        result['attachment'] as Map<String, Object?>;
    expect(attachment['summary_by'], 'vision_model');
    expect(
      (result['warnings'] as List<Object?>),
      isNot(contains('image_manual_reference')),
    );
  });

  test('attach：数量上限 20 个 ⇒ attachment_limit', () async {
    writeAsset('assets/extra.txt', utf8.encode('extra'));
    await ready();
    store.putTask(lineId, taskId, <String, Object?>{
      'attachments': <Map<String, Object?>>[
        for (int i = 0; i < kMaxAttachmentsPerTask; i++)
          <String, Object?>{
            'path':
                '.input/production_lines/$lineId/tasks/$taskId/'
                'attachments/seed-$i.txt',
            'sha256': sha256.convert(utf8.encode('seed-$i')).toString(),
            'size': 1,
            'type': 'text/plain',
            'kind': 'text',
          },
      ],
    });

    expect(
      () => attach(<String, Object?>{'source': 'assets/extra.txt'}),
      failure('attachment_limit'),
    );
  });

  test('attach：超过 10 MiB ⇒ attachment_too_large', () async {
    writeAsset('assets/huge.bin', const <int>[]);
    await ready();
    final File huge = File(p.join(workspace.path, 'assets', 'huge.bin'));
    final RandomAccessFile handle = huge.openSync(mode: FileMode.write);
    handle.truncateSync(kMaxAttachmentBytes + 1);
    handle.closeSync();

    expect(
      () => attach(<String, Object?>{'source': 'assets/huge.bin'}),
      failure('attachment_too_large'),
    );
  });

  test('attach：结构未就绪的非 cleanup 任务 ⇒ structure_not_ready', () {
    store.createLine(<String, Object?>{
      'id': 'pl_dry',
      'name': '未就绪产线',
      'workspace_dir': workspace.path,
    });
    store.createTask('pl_dry', <String, Object?>{
      'id': 'T9',
      'title': '未就绪任务',
      'status': 'draft',
    });

    expect(
      () => ProductionAttachmentService().attach(store, <String, Object?>{
        'line_id': 'pl_dry',
        'task_id': 'T9',
        'source': 'lib/demo.dart',
      }),
      failure('structure_not_ready'),
    );
  });

  test('attach：source 越出工作空间（../x）被拒绝', () async {
    await ready();
    expect(
      () => attach(<String, Object?>{'source': '../x'}),
      failure('invalid_arguments'),
    );
  });

  test('REST：POST attachments ⇒ 201；未就绪 ⇒ 409', () async {
    writeAsset('assets/api.txt', utf8.encode('api'));
    await ready();
    final ProductionService service = ProductionService(
      environment: const <String, String>{},
    );

    Future<Map<String, dynamic>> call(String path, Map<String, Object?> body) =>
        handleProductionDelegate(<String, dynamic>{
          'method': 'POST',
          'path': path,
          'params': <String, dynamic>{},
          'query': <String, dynamic>{},
          'headers': <String, dynamic>{},
          'scope': <String, dynamic>{},
          'data_dir': temp.path,
          'body': jsonEncode(body),
        }, service: service);

    final Map<String, dynamic> reply = await call(
      '/api/production/lines/$lineId/tasks/$taskId/attachments',
      <String, Object?>{'source': 'assets/api.txt'},
    );
    expect(reply['status'], 201);
    final Map<String, dynamic> payload =
        jsonDecode('${reply['body']}') as Map<String, dynamic>;
    expect(payload['deduplicated'], isFalse);
    expect(payload['attachment']['kind'], 'text');
    expect(payload['task']['attachments'], hasLength(1));

    store.createLine(<String, Object?>{
      'id': 'pl_dry',
      'name': '未就绪产线',
      'workspace_dir': workspace.path,
    });
    store.createTask('pl_dry', <String, Object?>{
      'id': 'T9',
      'title': '未就绪任务',
      'status': 'draft',
    });
    final Map<String, dynamic> blocked = await call(
      '/api/production/lines/pl_dry/tasks/T9/attachments',
      <String, Object?>{'source': 'lib/demo.dart'},
    );
    expect(blocked['status'], 409);
    final Map<String, dynamic> error =
        jsonDecode('${blocked['body']}') as Map<String, dynamic>;
    expect(error['code'], 'structure_not_ready');
  });
}

// ── 最小文件头夹具 ───────────────────────────────────────────────────

List<int> pngBytes({
  int width = 2,
  int height = 3,
  int colorType = 6,
  bool trns = false,
  bool exif = false,
}) {
  final List<int> bytes = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  void chunk(String type, List<int> data) {
    final int length = data.length;
    bytes.addAll(<int>[
      (length >> 24) & 0xFF,
      (length >> 16) & 0xFF,
      (length >> 8) & 0xFF,
      length & 0xFF,
    ]);
    bytes.addAll(type.codeUnits);
    bytes.addAll(data);
    bytes.addAll(const <int>[0, 0, 0, 0]); // CRC 不参与探测
  }

  chunk('IHDR', <int>[
    (width >> 24) & 0xFF,
    (width >> 16) & 0xFF,
    (width >> 8) & 0xFF,
    width & 0xFF,
    (height >> 24) & 0xFF,
    (height >> 16) & 0xFF,
    (height >> 8) & 0xFF,
    height & 0xFF,
    8,
    colorType,
    0,
    0,
    0,
  ]);
  if (trns) chunk('tRNS', const <int>[0, 0]);
  if (exif) chunk('eXIf', const <int>[0, 0, 0, 0]);
  chunk('IEND', const <int>[]);
  return bytes;
}

List<int> jpegBytes({int width = 640, int height = 480, bool exif = true}) {
  final List<int> out = <int>[0xFF, 0xD8];
  if (exif) {
    final List<int> payload = <int>[...'Exif'.codeUnits, 0, 0, 0x4D, 0x4D];
    final int length = payload.length + 2;
    out.addAll(<int>[0xFF, 0xE1, (length >> 8) & 0xFF, length & 0xFF]);
    out.addAll(payload);
  }
  final List<int> sof = <int>[
    8,
    (height >> 8) & 0xFF,
    height & 0xFF,
    (width >> 8) & 0xFF,
    width & 0xFF,
    3,
    ...List<int>.filled(9, 0),
  ];
  final int length = sof.length + 2;
  out.addAll(<int>[0xFF, 0xC0, (length >> 8) & 0xFF, length & 0xFF]);
  out.addAll(sof);
  out.addAll(<int>[0xFF, 0xD9]);
  return out;
}

List<int> gifBytes({
  int width = 4,
  int height = 5,
  bool animated = false,
  bool transparent = false,
}) {
  final List<int> out = <int>[
    ...'GIF89a'.codeUnits,
    width & 0xFF,
    (width >> 8) & 0xFF,
    height & 0xFF,
    (height >> 8) & 0xFF,
    0x00,
    0x00,
    0x00,
  ];
  if (transparent) {
    out.addAll(const <int>[0x21, 0xF9, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00]);
  }
  if (animated) {
    out.addAll(<int>[
      0x21,
      0xFF,
      0x0B,
      ...'NETSCAPE2.0'.codeUnits,
      0x03,
      0x01,
      0x00,
      0x00,
      0x00,
    ]);
  }
  void image() {
    out.addAll(const <int>[0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0x00]);
    out.add(0x02);
    out.addAll(const <int>[0x02, 0x4C, 0x01]);
    out.add(0x00);
  }

  image();
  if (animated) image();
  out.add(0x3B);
  return out;
}

List<int> webpVp8xBytes({
  int width = 640,
  int height = 480,
  bool alpha = false,
  bool exif = false,
  bool animated = false,
}) {
  int flags = 0;
  if (alpha) flags |= 0x10;
  if (exif) flags |= 0x08;
  if (animated) flags |= 0x02;
  return <int>[
    ...'RIFF'.codeUnits,
    0,
    0,
    0,
    0,
    ...'WEBP'.codeUnits,
    ...'VP8X'.codeUnits,
    0x0A,
    0,
    0,
    0,
    flags,
    0,
    0,
    0,
    (width - 1) & 0xFF,
    ((width - 1) >> 8) & 0xFF,
    ((width - 1) >> 16) & 0xFF,
    (height - 1) & 0xFF,
    ((height - 1) >> 8) & 0xFF,
    ((height - 1) >> 16) & 0xFF,
  ];
}

List<int> webpVp8Bytes({int width = 320, int height = 240}) => <int>[
  ...'RIFF'.codeUnits,
  0,
  0,
  0,
  0,
  ...'WEBP'.codeUnits,
  ...'VP8 '.codeUnits,
  0x0A,
  0,
  0,
  0,
  0,
  0,
  0,
  0x9D,
  0x01,
  0x2A,
  width & 0xFF,
  (width >> 8) & 0xFF,
  height & 0xFF,
  (height >> 8) & 0xFF,
];

List<int> webpVp8lBytes({int width = 300, int height = 200}) {
  final int bits = (width - 1) | ((height - 1) << 14);
  return <int>[
    ...'RIFF'.codeUnits,
    0,
    0,
    0,
    0,
    ...'WEBP'.codeUnits,
    ...'VP8L'.codeUnits,
    0x0A,
    0,
    0,
    0,
    0x2F,
    bits & 0xFF,
    (bits >> 8) & 0xFF,
    (bits >> 16) & 0xFF,
    (bits >> 24) & 0xFF,
  ];
}
