import 'dart:convert';
import 'dart:typed_data';

import 'station_command.dart';

/// 通过核心执行站读写工作空间（`fs.read` / `fs.write` / `fs.list`）。
///
/// 插件不做任何文件系统操作：路径与越界校验、local/SSH 差异全部由执行站承担。
class StationWorkspaceIo implements StationWorkspace {
  StationWorkspaceIo({
    required this.client,
    required this.agentId,
    required this.teamId,
    required this.modeKey,
    this.sessionId = '',
    required this.root,
  });

  final StationCommandClient client;
  final String agentId;
  final String teamId;
  final String modeKey;
  final String sessionId;

  @override
  final String root;

  Map<String, dynamic> get _scope => <String, dynamic>{
    'agent_id': agentId,
    if (teamId.isNotEmpty) 'team_id': teamId,
    if (modeKey.isNotEmpty) 'mode_key': modeKey,
    if (sessionId.isNotEmpty) 'session_id': sessionId,
  };

  Future<Map<String, dynamic>> _call(
    String command,
    Map<String, dynamic> arguments,
  ) => client(command, arguments, _scope);

  @override
  Future<StationFileContent> readFile(
    String path, {
    int? startLine,
    int? lineCount,
  }) async {
    final Map<String, dynamic> result = await _call('fs.read', <String, dynamic>{
      'path': path,
      'start_line': ?startLine,
      'line_count': ?lineCount,
    });
    final Object? encoded = result['base64'];
    return StationFileContent(
      text: (result['content'] ?? '').toString(),
      totalLines: (result['total_lines'] as num?)?.toInt() ?? 0,
      startLine: (result['start_line'] as num?)?.toInt() ?? 1,
      truncated: result['truncated'] == true,
      base64: encoded is String && encoded.isNotEmpty ? encoded : null,
    );
  }

  @override
  Future<int> writeFile(String path, String content) async {
    final Map<String, dynamic> result = await _call('fs.write', <String, dynamic>{
      'path': path,
      'content': content,
    });
    return (result['bytes_written'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<List<String>> listFiles({
    String path = '.',
    int maxDepth = 2,
    int maxEntries = 500,
  }) async {
    final Map<String, dynamic> result = await _call('fs.list', <String, dynamic>{
      'path': path,
      'max_depth': maxDepth,
      'max_entries': maxEntries,
    });
    final Object? entries = result['entries'];
    if (entries is! List) return <String>[];
    return <String>[for (final Object? entry in entries) entry.toString()];
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    final StationFileContent content = await readFile(path);
    final String? encoded = content.base64;
    if (encoded != null) return base64Decode(encoded);
    return Uint8List.fromList(utf8.encode(content.text));
  }
}