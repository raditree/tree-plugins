// 回归：建连后**第一条**业务帧必须是 `ui.hello`。
//
// 背景（known-issues #49）：核心的站点桥要求连接先经 `ui.hello` 绑定，否则
// `station/subscribe` 会被可读拒绝；而订阅方（StationClient）是挂在
// `onConnectionChange` 上的——它收到 true 的同一拍就会发订阅。过去
// `connect()` 把 hello 放在这个回调之后，于是首轮订阅必然被拒、且不重试，
// 界面永久收不到任何站点帧（消息面板停在 idle、没有停止按钮）。
//
// 这里用真本机 WS 服务器抓帧顺序，把"身份先于一切业务帧"钉死在明面上。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tree_ui_default/io/websocket_service.dart';

void main() {
  test('connect() 先发 ui.hello，onConnectionChange 里的业务帧排在其后', () async {
    // flutter_test 默认装了 HttpOverrides（请求被拦成 400）：要真起本机 socket
    HttpOverrides.global = null;
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final List<Map<String, dynamic>> received = <Map<String, dynamic>>[];
    final Completer<List<Map<String, dynamic>>> firstTwo =
        Completer<List<Map<String, dynamic>>>();
    server.listen((HttpRequest request) async {
      final WebSocket socket = await WebSocketTransformer.upgrade(request);
      socket.listen((dynamic data) {
        received.add(jsonDecode(data.toString()) as Map<String, dynamic>);
        if (received.length >= 2 && !firstTwo.isCompleted) {
          firstTwo.complete(List<Map<String, dynamic>>.of(received));
        }
      });
    });

    WebSocketService.baseUrl = 'ws://127.0.0.1:${server.port}';
    WebSocketService.helloFrame = <String, dynamic>{
      'type': 'ui.hello',
      'data': <String, dynamic>{
        'plugin_id': 'tree.ui.default',
        'version': '1.0.9',
      },
    };
    final WebSocketService ws = WebSocketService();
    // 与 StationClient 同形：连接一建立就发订阅。
    ws.onConnectionChange = (bool connected) {
      if (!connected) return;
      ws.send(<String, dynamic>{
        'type': 'station/subscribe',
        'data': <String, dynamic>{'station_id': 'plugin.tree.agent.broadcast.events'},
      });
    };

    try {
      ws.connect('test-token');
      final List<Map<String, dynamic>> order = await firstTwo.future.timeout(
        const Duration(seconds: 5),
      );
      expect(order[0]['type'], 'ui.hello', reason: '身份必须第一条上线');
      expect(order[1]['type'], 'station/subscribe', reason: '订阅只能排在 hello 之后');
    } finally {
      ws.disconnect();
      WebSocketService.helloFrame = null;
      WebSocketService.baseUrl = 'ws://127.0.0.1:0';
      await server.close(force: true);
    }
  });
}
