/// 项目整理（P6）的纯领域逻辑：TODO 台账、文档审计、冗余候选与只读报告。
///
/// 口径（docs/pluginization/production-line-recon.md §10 / §11 的 P6 行）：
/// - 只读：扫描工作空间，**不改任何代码**；唯一写入是项目资产目录里的 `audit.md`；
/// - 报告 schema 固定（`version: 1`），键名不随实现细节漂移，UI / 其他插件可稳定消费；
/// - 四块内容：文档审计（项目记忆清单是否齐全）、TODO 台账（TODO/FIXME/XXX/HACK）、
///   冗余候选（重复内容 + 超大文件）、说明（扫描是否截断等）。
///
/// 这一层不读盘、不碰服务：扫描由 `audit_service.dart` 负责，单测直接覆盖判定。
library;

import 'models.dart';

/// 台账识别的标记（只认大写，避免把正文里的 “todo” 误当标记）。
const List<String> kAuditMarkers = <String>['TODO', 'FIXME', 'XXX', 'HACK'];

/// 扫描时跳过的目录（与准备阶段的 `grep` 同口径）。
///
/// 依赖 / 构建 / 缓存目录一律不进：它们动辄上万文件，会把一次只读整理拖成
/// 30s 以上的 REST 委派超时（真机 504 的来源）。
const Set<String> kAuditSkipDirs = <String>{
  '.git',
  '.svn',
  '.dart_tool',
  '.pub-cache',
  'build',
  'dist',
  'out',
  'target',
  'coverage',
  'node_modules',
  'vendor',
  '.venv',
  'venv',
  '__pycache__',
  '.tox',
  '.mypy_cache',
  '.pytest_cache',
  '.idea',
  '.vscode',
  '.cache',
  '.parcel-cache',
  '.next',
  '.nuxt',
  '.gradle',
  'Pods',
  '.docnorm',
};

/// 只扫这些文本扩展名（二进制 / 媒体一律跳过）。
const Set<String> kAuditExtensions = <String>{
  'dart',
  'md',
  'yaml',
  'yml',
  'json',
  'txt',
  'sh',
  'ps1',
  'py',
  'ts',
  'js',
  'vue',
  'html',
  'css',
  'java',
  'kt',
  'swift',
  'c',
  'h',
  'cpp',
  'gradle',
  'toml',
  'ini',
};

/// 单次整理会话的候选文件上限（不是单批上限；到点写说明，不静默）。
///
/// 依赖 / 构建目录已在 [kAuditSkipDirs] 排除，正常仓库远达不到这个数。
const int kAuditMaxFiles = 20000;

/// 每批扫描的默认文件数（UI 可改；一批一次请求，支持续扫）。
const int kAuditDefaultBatch = 500;

/// 每批扫描的文件数上限（防止一次请求被填成天文数字）。
const int kAuditMaxBatch = 20000;

/// 单文件读取上限（超过跳过并计入 skipped）。
const int kAuditMaxFileBytes = 512 * 1024;

/// 台账条数上限（防止一个巨型仓库把回包撑爆）。
const int kAuditMaxTodos = 500;

/// 重复内容检测的最小文件体积（小文件撞哈希没有整理价值）。
const int kAuditDuplicateMinBytes = 1024;

/// 超大文件阈值（候选拆分 / 收束）。
const int kAuditLargeFileBytes = 256 * 1024;

/// 一条 TODO 台账。
class AuditTodo {
  const AuditTodo({
    required this.path,
    required this.line,
    required this.marker,
    required this.text,
  });

  final String path;
  final int line;
  final String marker;
  final String text;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'line': line,
    'marker': marker,
    'text': text,
  };
}

/// 一组重复内容。
class AuditDuplicate {
  const AuditDuplicate({
    required this.digest,
    required this.size,
    required this.paths,
  });

  final String digest;
  final int size;
  final List<String> paths;

  Map<String, Object?> toJson() => <String, Object?>{
    'digest': digest,
    'size': size,
    'paths': paths,
  };
}

/// 一份只读的项目整理报告（`audit.md` 的机读真值）。
class AuditReport {
  const AuditReport({
    required this.lineId,
    required this.taskId,
    required this.generatedAt,
    required this.workspace,
    required this.scanned,
    required this.skipped,
    required this.totalBytes,
    required this.docsChecked,
    required this.docsMissing,
    required this.todos,
    required this.duplicates,
    required this.largeFiles,
    required this.notes,
  });

  final String lineId;
  final String taskId;
  final String generatedAt;
  final String workspace;
  final int scanned;
  final int skipped;
  final int totalBytes;
  final List<String> docsChecked;
  final List<String> docsMissing;
  final List<AuditTodo> todos;
  final List<AuditDuplicate> duplicates;
  final List<Map<String, Object?>> largeFiles;
  final List<String> notes;

  /// 固定 schema：顶层 9 键、`files` / `docs` / `redundancy` 三段不多不少。
  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'line_id': lineId,
    'task_id': taskId,
    'generated_at': generatedAt,
    'workspace': workspace,
    'files': <String, Object?>{
      'scanned': scanned,
      'skipped': skipped,
      'bytes': totalBytes,
    },
    'docs': <String, Object?>{
      'checked': docsChecked,
      'missing': docsMissing,
    },
    'todos': <Map<String, Object?>>[
      for (final AuditTodo todo in todos) todo.toJson(),
    ],
    'redundancy': <String, Object?>{
      'duplicates': <Map<String, Object?>>[
        for (final AuditDuplicate item in duplicates) item.toJson(),
      ],
      'large_files': largeFiles,
    },
    'notes': notes,
  };
}

/// 从文件正文里抽 TODO 台账（行号 1 起，正文裁到 200 字符）。
List<AuditTodo> auditTodosOf(String path, String content) {
  final RegExp pattern = RegExp(r'\b(TODO|FIXME|XXX|HACK)\b');
  final List<AuditTodo> out = <AuditTodo>[];
  final List<String> lines = content.split('\n');
  for (int i = 0; i < lines.length; i++) {
    final RegExpMatch? match = pattern.firstMatch(lines[i]);
    if (match == null) continue;
    out.add(
      AuditTodo(
        path: path,
        line: i + 1,
        marker: match.group(1)!,
        text: _clip(lines[i].trim(), 200),
      ),
    );
  }
  return out;
}

/// FNV-1a 64 位（重复内容检测用；不引入额外依赖，VM 上确定）。
String auditDigest(List<int> bytes) {
  int hash = -0x340d631b7bdddcdb; // 0xcbf29ce484222325（有符号写法）
  for (final int byte in bytes) {
    hash ^= byte & 0xff;
    hash *= 0x100000001b3; // VM 上 64 位溢出按补码回绕
  }
  // 取低 63 位再转十六进制：VM 的 toUnsigned(64) 在最高位为 1 时仍可能是负数，
  // 这里统一成正数并补足 16 位（只用于重复内容比较，不要求密码学强度）。
  return (hash & 0x7fffffffffffffff).toRadixString(16).padLeft(16, '0');
}

/// 把扫描结果收成重复组（只保留 ≥ [kAuditDuplicateMinBytes] 且 ≥ 2 个路径的组）。
List<AuditDuplicate> auditDuplicatesOf(
  Map<String, List<String>> pathsByDigest,
  Map<String, int> sizeByDigest,
) {
  final List<AuditDuplicate> out = <AuditDuplicate>[];
  for (final MapEntry<String, List<String>> entry in pathsByDigest.entries) {
    final int size = sizeByDigest[entry.key] ?? 0;
    if (entry.value.length < 2 || size < kAuditDuplicateMinBytes) continue;
    final List<String> paths = List<String>.of(entry.value)..sort();
    out.add(AuditDuplicate(digest: entry.key, size: size, paths: paths));
  }
  out.sort((AuditDuplicate a, AuditDuplicate b) {
    final int bySize = b.size.compareTo(a.size);
    return bySize != 0 ? bySize : a.digest.compareTo(b.digest);
  });
  return out;
}

/// 超大文件候选（按体积降序）。
List<Map<String, Object?>> auditLargeFilesOf(Map<String, int> sizeByPath) {
  final List<Map<String, Object?>> out = <Map<String, Object?>>[
    for (final MapEntry<String, int> entry in sizeByPath.entries)
      if (entry.value >= kAuditLargeFileBytes)
        <String, Object?>{'path': entry.key, 'size': entry.value},
  ];
  out.sort(
    (Map<String, Object?> a, Map<String, Object?> b) =>
        intOf(b['size'], 0).compareTo(intOf(a['size'], 0)),
  );
  return out;
}

/// `audit.md`：人读版报告（机读真值是回包里的 `report`）。
String renderAuditMd(AuditReport report) {
  final StringBuffer buffer = StringBuffer()
    ..writeln('# 项目整理 · ${report.lineId}')
    ..writeln()
    ..writeln(
      '> 生成于 ${report.generatedAt} · 扫描 ${report.scanned} 个文件 · '
      '跳过 ${report.skipped} 个 · 共 ${report.totalBytes} 字节',
    )
    ..writeln()
    ..writeln('## 文档审计')
    ..writeln()
    ..writeln(
      '检查 ${report.docsChecked.length} 份项目记忆文档；'
      '缺 ${report.docsMissing.length} 份。',
    )
    ..writeln();
  if (report.docsMissing.isEmpty) {
    buffer.writeln('（齐全）');
  } else {
    for (final String path in report.docsMissing) {
      buffer.writeln('- 缺：`$path`');
    }
  }
  buffer
    ..writeln()
    ..writeln('## TODO 台账')
    ..writeln()
    ..writeln(
      report.todos.isEmpty
          ? '（无 TODO / FIXME / XXX / HACK）'
          : '共 ${report.todos.length} 条：',
    );
  for (final AuditTodo todo in report.todos) {
    buffer.writeln(
      '- `${todo.path}:${todo.line}` ${todo.marker} — ${todo.text}',
    );
  }
  buffer
    ..writeln()
    ..writeln('## 冗余候选')
    ..writeln()
    ..writeln('### 重复内容')
    ..writeln();
  if (report.duplicates.isEmpty) {
    buffer.writeln('（无）');
  } else {
    for (final AuditDuplicate item in report.duplicates) {
      buffer
        ..writeln('- ${item.size} 字节 · ${item.digest}')
        ..writeln('  - ${item.paths.join('\n  - ')}');
    }
  }
  buffer
    ..writeln()
    ..writeln('### 超大文件（≥ $kAuditLargeFileBytes 字节）')
    ..writeln();
  if (report.largeFiles.isEmpty) {
    buffer.writeln('（无）');
  } else {
    for (final Map<String, Object?> item in report.largeFiles) {
      buffer.writeln('- `${textOf(item['path'])}` — ${intOf(item['size'], 0)} 字节');
    }
  }
  if (report.notes.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('## 说明')
      ..writeln();
    for (final String note in report.notes) {
      buffer.writeln('- $note');
    }
  }
  return buffer.toString().trimRight();
}

String _clip(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max)}…';
