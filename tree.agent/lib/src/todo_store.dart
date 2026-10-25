import 'dart:convert';
import 'dart:io';

import 'paths.dart';

/// 一条待办（与核心 `TodoItem.toApiJson` 逐字段一致）。
class TodoItem {
  const TodoItem({
    required this.id,
    required this.content,
    this.status = 'pending',
    this.progress = 0,
    this.updatedAt = 0,
  });

  final String id;
  final String content;
  final String status;

  /// 0~100。
  final int progress;

  /// 最后更新时间（毫秒）。
  final int updatedAt;

  /// 前端形态（`GET /api/agents/{id}/todos` 的条目）。
  Map<String, dynamic> toApiJson() => <String, dynamic>{
    'id': id,
    'content': content,
    'status': status,
    'progress': progress,
    'updated_at': updatedAt,
  };

  /// 非法状态一律回落 pending（与核心同一口径，避免前端 switch 落到意外分支）。
  static String normalizeStatus(String raw) {
    const List<String> allowed = <String>[
      'pending',
      'in_progress',
      'completed',
      'blocked',
    ];
    final String value = raw.trim().toLowerCase();
    return allowed.contains(value) ? value : 'pending';
  }

  /// 夹取进度到 0~100。
  static int clampProgress(int value) =>
      value < 0 ? 0 : (value > 100 ? 100 : value);
}

/// 读某会话的待办（`data/<agent>/<session>/todos.md`）。
///
/// 文件不存在 / 空文件 ⇒ 空列表。解码口径与核心一致：markdown 勾选清单，元数据
/// 前置；缺少元数据的裸行也能读出来（id 自动生成为 `h1`、`h2`…）。
List<TodoItem> readTodos(
  AgentDataPaths paths,
  String agentId,
  String sessionId,
) {
  final File file = File(paths.todosFile(agentId, sessionId));
  if (!file.existsSync()) return <TodoItem>[];
  final String text = utf8.decode(
    file.readAsBytesSync(),
    allowMalformed: true,
  );
  if (text.trim().isEmpty) return <TodoItem>[];
  return decodeTodoMarkdown(text);
}

/// 解析 markdown 清单（与核心 `FileTodoStore.decodeMarkdown` 同一正则）。
List<TodoItem> decodeTodoMarkdown(String text) {
  final List<TodoItem> items = <TodoItem>[];
  final RegExp full = RegExp(
    r'^- \[([ x~!])\] (\S+) \| status=(\w+) progress=(\d+) \| (.*)$',
  );
  final RegExp loose = RegExp(r'^- \[([ x~!])\] (.*)$');
  int auto = 0;
  for (final String raw in const LineSplitter().convert(text)) {
    final String line = raw.trimRight();
    final RegExpMatch? match = full.firstMatch(line);
    if (match != null) {
      items.add(
        TodoItem(
          id: match.group(2)!,
          content: match.group(5)!.trim(),
          status: TodoItem.normalizeStatus(match.group(3)!),
          progress: TodoItem.clampProgress(
            int.tryParse(match.group(4)!) ?? 0,
          ),
        ),
      );
      continue;
    }
    final RegExpMatch? looseMatch = loose.firstMatch(line);
    if (looseMatch == null) continue;
    auto++;
    items.add(
      TodoItem(
        id: 'h$auto',
        content: looseMatch.group(2)!.trim(),
        status: looseMatch.group(1) == 'x' ? 'completed' : 'pending',
        progress: looseMatch.group(1) == 'x' ? 100 : 0,
      ),
    );
  }
  return items;
}
