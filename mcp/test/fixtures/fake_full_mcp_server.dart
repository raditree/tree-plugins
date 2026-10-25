import 'package:tree_mcp/tree_mcp.dart';
// ignore_for_file: unused_local_variable, prefer_interpolation_to_compose_strings
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 测试用 MCP 服务：initialize / tools/resources/prompts 自发现、分页、
/// list_changed、resources/read、prompts/get、roots/list。
void main() {
  bool initialized = false;
  final List<String> tools = <String>['echo', 'roots'];
  final Map<int, Completer<Map<String, dynamic>>> waiting =
      <int, Completer<Map<String, dynamic>>>{};
  int nextServerId = 7000;

  void write(Map<String, dynamic> message) {
    stdout.writeln(jsonEncode(message));
  }

  void reply(Object? id, Map<String, dynamic> result) {
    write(<String, dynamic>{'jsonrpc': '2.0', 'id': id, 'result': result});
  }

  void replyError(Object? id, String message) {
    write(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'error': <String, dynamic>{'code': -32601, 'message': message},
    });
  }

  Future<Map<String, dynamic>> ask(String method, Map<String, dynamic> params) {
    final int id = ++nextServerId;
    final Completer<Map<String, dynamic>> completer =
        Completer<Map<String, dynamic>>();
    waiting[id] = completer;
    write(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    return completer.future;
  }

  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((
    String line,
  ) async {
    if (line.trim().isEmpty) return;
    final Map<String, dynamic> message =
        (jsonDecode(line) as Map<dynamic, dynamic>)
            .map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
    final Object? id = message['id'];
    final String method = (message['method'] ?? '').toString();
    if (method.isEmpty && id is int) {
      waiting.remove(id)?.complete(
        (message['result'] as Map<dynamic, dynamic>? ?? const <dynamic, dynamic>{})
            .map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
      );
      return;
    }
    if (id == null) {
      if (method == 'notifications/initialized') initialized = true;
      return;
    }
    switch (method) {
      case McpMethods.initialize:
        return reply(id, <String, dynamic>{
          'protocolVersion': '2025-06-18',
          'capabilities': <String, dynamic>{
            'tools': <String, dynamic>{'listChanged': true},
            'resources': <String, dynamic>{'subscribe': true, 'listChanged': true},
            'prompts': <String, dynamic>{'listChanged': true},
            'logging': <String, dynamic>{},
          },
          'serverInfo': <String, dynamic>{'name': 'fake-full-mcp', 'version': '1.0'},
        });
      case McpMethods.ping:
        return reply(id, <String, dynamic>{});
      case McpMethods.toolsList:
        final String cursor = (message['params'] as Map<dynamic, dynamic>? ??
                const <dynamic, dynamic>{})
            .map((dynamic k, dynamic v) => MapEntry(k.toString(), v))['cursor']
            ?.toString() ?? '';
        if (cursor == 'p2') {
          return reply(id, <String, dynamic>{
            'tools': <Map<String, dynamic>>[
              if (tools.contains('added'))
                <String, dynamic>{
                  'name': 'added',
                  'description': '后加的工具',
                  'inputSchema': <String, dynamic>{'type': 'object'},
                },
            ],
          });
        }
        return reply(id, <String, dynamic>{
          'tools': <Map<String, dynamic>>[
            <String, dynamic>{'name': 'echo', 'description': '回显', 'inputSchema': <String, dynamic>{'type': 'object'}},
            <String, dynamic>{'name': 'roots', 'description': '读回客户端 roots', 'inputSchema': <String, dynamic>{'type': 'object'}},
            <String, dynamic>{'name': 'notify_add', 'description': '触发 list_changed', 'inputSchema': <String, dynamic>{'type': 'object'}},
          ],
          'nextCursor': 'p2',
        });
      case McpMethods.resourcesList:
        return reply(id, <String, dynamic>{
          'resources': <Map<String, dynamic>>[
            <String, dynamic>{
              'uri': 'mem://a',
              'name': 'A',
              'description': '资源 A',
              'mimeType': 'text/plain',
            },
          ],
        });
      case McpMethods.resourceTemplatesList:
        return reply(id, <String, dynamic>{
          'resourceTemplates': <Map<String, dynamic>>[
            <String, dynamic>{'uriTemplate': 'mem://{id}', 'name': 'mem'},
          ],
        });
      case McpMethods.promptsList:
        return reply(id, <String, dynamic>{
          'prompts': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': 'greet',
              'description': '问候',
              'arguments': <Map<String, dynamic>>[
                <String, dynamic>{'name': 'who', 'required': true},
              ],
            },
          ],
        });
      case McpMethods.resourcesRead:
        final String uri = ((message['params'] as Map<dynamic, dynamic>? ??
                    const <dynamic, dynamic>{})['uri'] ?? '')
            .toString();
        return reply(id, <String, dynamic>{
          'contents': <Map<String, dynamic>>[
            <String, dynamic>{
              'uri': uri,
              'mimeType': 'text/plain',
              'text': 'resource-body:' + uri,
            },
          ],
        });
      case McpMethods.promptsGet:
        return reply(id, <String, dynamic>{
          'description': 'prompt-desc',
          'messages': <Map<String, dynamic>>[
            <String, dynamic>{
              'role': 'user',
              'content': <String, dynamic>{'type': 'text', 'text': 'prompt-body'},
            },
          ],
        });
      case McpMethods.toolsCall:
        final Map<String, dynamic> params =
            (message['params'] as Map<dynamic, dynamic>? ?? const <dynamic, dynamic>{})
                .map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
        final String tool = (params['name'] ?? '').toString();
        final Map<String, dynamic> args =
            (params['arguments'] as Map<dynamic, dynamic>? ?? const <dynamic, dynamic>{})
                .map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
        if (tool == 'echo') {
          return reply(id, <String, dynamic>{
            'content': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'text': (args['text'] ?? '').toString()},
            ],
          });
        }
        if (tool == 'roots') {
          final Map<String, dynamic> result = await ask(
            McpMethods.rootsList,
            <String, dynamic>{},
          );
          return reply(id, <String, dynamic>{
            'content': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'text',
                'text': jsonEncode(result['roots'] ?? <dynamic>[]),
              },
            ],
          });
        }
        if (tool == 'notify_add') {
          if (!tools.contains('added')) tools.add('added');
          write(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': McpMethods.toolsListChanged,
            'params': <String, dynamic>{},
          });
          return reply(id, <String, dynamic>{
            'content': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'text': 'added'},
            ],
          });
        }
        return replyError(id, '未知工具：' + tool);
      default:
        return replyError(id, 'method not found: ' + method);
    }
  });
}