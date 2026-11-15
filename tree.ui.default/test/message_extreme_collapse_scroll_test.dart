// EXTREME-COLLAPSE-01（用户 2026-11-15 点名）。
//
// 现场：**20 组工具调用、每组 121 条工具**；用户输入 3 次；terminal hook 提示 7 次；
// 提问 3 次（一问 / 三问 / 五问）。展开**第 11 组**，然后匀速从底部滚到顶部、再折返
// 滚到底部。全程两条判据：
//
//  ① **页面不跳**：每个 120px 步进里，"视口顶附近某一格**高度没变**的内容"在屏幕上的
//     位移必须正好是一个步长（±1px）。只看像素位移不可靠：补页/淘汰会让内容总高在
//     一帧里变上万像素，`pixels` 跟着补偿是**正确**行为，用户看到的是那一格有没有被推走。
//  ② **拇指不异常抖动**：均匀滚动下，拇指相邻帧的位移 ≤ 8px、长度变化 ≤ 2px，
//     且方向不反复（构建区间成百格地跳，拇指就会跟着跳）。
//
// **本用例目前应当为红**（两项判据都在这个极端现场被抓到）：
//  · 拇指：几何仍按"本帧已构建的下标区间"算（`MessageWindowCoordinate`），折叠的零高度
//    行会把它撑大 —— 滚过折叠组时 first/last 成百格地跳，拇指跟着跳
//    （实测单步位移 ~16px / 上限 8px，方向反复 40+ 次）；
//  · 页面：补页（占位槽 → 折叠组一行）与淘汰（折叠组一行 → 占位槽）同帧/相邻帧发生时，
//    内容高度一帧内变动上万像素，实测有 ~9/1400 步「稳定锚点」被推走（最大 262px）。
// 修法（拇指坐标口径改成"真正与视口相交的显示行"、大高度差补偿）未做，本条即验收闸门。

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree_ui_default/io/api_service.dart';
import 'package:tree_ui_default/io/websocket_service.dart';
import 'package:tree_ui_default/ui/models/agent.dart';
import 'package:tree_ui_default/ui/widgets/message_list.dart';
import 'package:tree_ui_default/ui/widgets/message_panel.dart';
import 'package:tree_ui_default/ui/widgets/message_scrollbar.dart';

/// 现场规模
const int _groupCount = 20;
const int _toolsPerGroup = 121;
const int _expandedGroup = 10; // 第 11 组（0 基）

/// 假核心：会话列表 + 历史分页（`from` / `limit` 与真核心同形）。
class _FakeCore {
  _FakeCore._(this._http, this.rows);

  final HttpServer _http;
  final List<Map<String, dynamic>> rows;

  int get total => rows.length;

  static Future<_FakeCore> start(List<Map<String, dynamic>> rows) async {
    final HttpServer http = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _FakeCore core = _FakeCore._(http, rows);
    http.listen(core._handle);
    return core;
  }

  String get baseUrl => 'http://127.0.0.1:${_http.port}';

  Future<void> close() => _http.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final String path = Uri.decodeComponent(request.uri.path);
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      final WebSocket socket = await WebSocketTransformer.upgrade(request);
      socket.listen((dynamic _) {}, onError: (Object _) {}, cancelOnError: true);
      return;
    }
    final Map<String, String> q = request.uri.queryParameters;
    Map<String, dynamic> payload = <String, dynamic>{'success': true};
    if (path.endsWith('/sessions')) {
      payload = <String, dynamic>{
        'sessions': <Map<String, dynamic>>[
          <String, dynamic>{
            'session_id': 'session_default',
            'title': '极端场景',
            'message_count': total,
          },
        ],
      };
    } else if (path.contains('/conversations/')) {
      final int limit = int.tryParse(q['limit'] ?? '') ?? 51;
      final int? from = int.tryParse(q['from'] ?? '');
      final int start = (from ?? (total - limit)).clamp(0, total);
      final int count = limit.clamp(0, total - start);
      payload = <String, dynamic>{
        'agent_id': 'a1',
        'session_id': q['session_id'] ?? 'session_default',
        'messages': rows.sublist(start, start + count),
        'total': total,
        'offset': start,
        'has_more': start > 0,
      };
    }
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(payload));
    await request.response.close();
  }
}

/// 20 组 × 121 工具 + 20 条分隔（3 用户 / 7 hook 提示 / 3 提问 + 7 正文）。
List<Map<String, dynamic>> _scenario() {
  final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
  int seq = 0;
  String t() => DateTime(2026, 1, 1).add(Duration(seconds: seq++)).toIso8601String();

  Map<String, dynamic> text(String content, {String role = 'agent'}) =>
      <String, dynamic>{
        'id': 'm${seq + 100000}',
        'role': role,
        'content': content,
        'timestamp': t(),
        'kind': 'text',
      };

  Map<String, dynamic> hookNotice(int n) => <String, dynamic>{
        'id': 'm${seq + 100000}',
        'role': 'agent',
        'kind': 'notice',
        'timestamp': t(),
        'content': '[terminal hook] 后台命令已结束：flutter test --name hook$n\n'
            'task_id: t$n｜退出码 0\n'
            '日志文件：.output/t$n.log（用 read 查看完整输出）\n'
            '--- 日志尾部 ---\n'
            '结束：退出码 0，耗时 36s',
      };

  Map<String, dynamic> ask(int id, int questionCount) => <String, dynamic>{
        'id': 'm${seq + 100000}',
        'role': 'agent',
        'kind': 'ask_user_question',
        'timestamp': t(),
        'content': '请选择第 $id 组方案？',
        'questions': <Map<String, dynamic>>[
          for (int i = 0; i < questionCount; i++)
            <String, dynamic>{
              'question': '第 $id 组第 ${i + 1} 问：选哪个？',
              'options': <String>['方案 A', '方案 B', '方案 C'],
            },
        ],
      };

  // 分隔序列：用户 3 次、hook 7 次、提问 3 次（1/3/5 问），其余用正文分隔
  final Set<int> userAt = <int>{2, 8, 15};
  final Set<int> hookAt = <int>{0, 3, 6, 9, 12, 16, 19};
  final Map<int, int> askAt = <int, int>{5: 1, 11: 3, 17: 5};
  int hookNo = 0;
  int askNo = 0;

  for (int g = 0; g < _groupCount; g++) {
    for (int i = 0; i < _toolsPerGroup; i++) {
      rows.add(<String, dynamic>{
        'id': 'g${g}t$i',
        'role': 'agent',
        'kind': 'tool',
        'timestamp': t(),
        'content': '',
        'tool_name': <String>['read', 'grep', 'edit', 'terminal', 'write'][i % 5],
        'preview': '组 $g 目标 $i',
      });
    }
    // 每组之后一条分隔（切断折叠组；同时也是"用户输入 / hook / 提问"的落点）
    if (userAt.contains(g)) {
      rows.add(text('用户输入 ${userAt.toList().indexOf(g) + 1}', role: 'user'));
    } else if (hookAt.contains(g)) {
      rows.add(hookNotice(++hookNo));
    } else if (askAt.containsKey(g)) {
      rows.add(ask(++askNo, askAt[g]!));
    } else {
      rows.add(text('第 $g 组收尾正文'));
    }
  }
  return rows;
}

ScrollPosition _pos(WidgetTester tester) {
  final Finder list = find
      .descendant(of: find.byType(MessageList), matching: find.byType(ListView))
      .first;
  return tester
      .state<ScrollableState>(
        find.descendant(of: list, matching: find.byType(Scrollable)).first,
      )
      .position;
}

/// 消息列表的 [RenderSliverList]（懒构建子项都挂在它下面）。
RenderSliverList? _sliverList(WidgetTester tester) {
  final RenderObject root = tester.renderObject(
    find
        .descendant(of: find.byType(MessageList), matching: find.byType(ListView))
        .first,
  );
  RenderSliverList? found;
  void visit(RenderObject node) {
    if (found != null) return;
    if (node is RenderSliverList) {
      found = node;
      return;
    }
    node.visitChildren(visit);
  }

  if (root is RenderSliverList) {
    found = root;
  } else {
    root.visitChildren(visit);
  }
  return found;
}

/// 某一格的**内容坐标**顶边（只能对已布局过的子项取）。
double? _childOffset(WidgetTester tester, Finder finder) {
  final RenderSliverList? list = _sliverList(tester);
  if (list == null) return null;
  RenderObject? ro = tester.element(finder).renderObject;
  // 找到 sliver 的直接子项（行内部还有自己的 RenderBox 层级）
  while (ro != null && ro.parentData is! SliverMultiBoxAdaptorParentData) {
    ro = ro.parent;
  }
  if (ro == null) return null;
  return list.childScrollOffset(ro);
}

/// 消息列表这一趟**真正布局过**的下标区间（与 `_builtRangeFromRenderTree` 同口径）。
({int first, int last})? _builtRange(WidgetTester tester) {
  final RenderSliverList? list = _sliverList(tester);
  if (list == null) return null;
  int? first;
  int? last;
  RenderBox? item = list.firstChild;
  while (item != null) {
    if (list.childScrollOffset(item) != null) {
      final ParentData? data = item.parentData;
      if (data is SliverMultiBoxAdaptorParentData && data.index != null) {
        first ??= data.index;
        last = data.index;
      }
    }
    item = list.childAfter(item);
  }
  if (first == null || last == null) return null;
  return (first: first, last: last);
}

/// 视口顶附近**前几条**已布局子项（下标 / 屏幕 y / 高度），按顶边从下往上排。
///
/// "页面不跳"只认**高度没变**的那一条：补页/淘汰把视口顶那一格从占位槽换成真消息时，
/// 它自己的顶边会被补偿挪动（设计口径：保住它**以下**整段），不算页面跳。
List<({int index, double y, double h})> _visibleAnchors(
  WidgetTester tester, {
  int count = 4,
}) {
  final RenderSliverList? list = _sliverList(tester);
  if (list == null || !list.attached) return const <({int index, double y, double h})>[];
  final double viewportTop = list.constraints.scrollOffset;
  final List<({double top, int index, RenderBox box})> built =
      <({double top, int index, RenderBox box})>[];
  RenderBox? item = list.firstChild;
  while (item != null) {
    final double? top = list.childScrollOffset(item);
    final ParentData? data = item.parentData;
    if (top != null &&
        data is SliverMultiBoxAdaptorParentData &&
        data.index != null) {
      final double bottom = top + item.size.height;
      if (bottom > viewportTop + 0.01) {
        built.add((top: top, index: data.index!, box: item));
      }
    }
    item = list.childAfter(item);
  }
  built.sort((({double top, int index, RenderBox box}) a,
          ({double top, int index, RenderBox box}) b) =>
      a.top.compareTo(b.top));
  return <({int index, double y, double h})>[
    for (final ({double top, int index, RenderBox box}) e
        in built.take(count))
      (
        index: e.index,
        y: e.box.localToGlobal(Offset.zero).dy,
        h: e.box.size.height,
      ),
  ];
}

/// 某个下标此刻的屏幕 y（不在已布局范围内返回 null）。
double? _screenYOfIndex(WidgetTester tester, int index) {
  final RenderSliverList? list = _sliverList(tester);
  if (list == null) return null;
  RenderBox? item = list.firstChild;
  while (item != null) {
    final ParentData? data = item.parentData;
    if (data is SliverMultiBoxAdaptorParentData &&
        data.index == index &&
        list.childScrollOffset(item) != null) {
      return item.localToGlobal(Offset.zero).dy;
    }
    item = list.childAfter(item);
  }
  return null;
}

/// 某个下标此刻的高度（不在已布局范围内返回 null）。
double? _heightOfIndex(WidgetTester tester, int index) {
  final RenderSliverList? list = _sliverList(tester);
  if (list == null) return null;
  RenderBox? item = list.firstChild;
  while (item != null) {
    final ParentData? data = item.parentData;
    if (data is SliverMultiBoxAdaptorParentData &&
        data.index == index &&
        list.childScrollOffset(item) != null) {
      return item.size.height;
    }
    item = list.childAfter(item);
  }
  return null;
}

Rect? _thumb(WidgetTester tester) {
  final Finder f = find.byKey(messageScrollbarThumbKey);
  if (f.evaluate().isEmpty) return null;
  return tester.getRect(f);
}

/// 让真 socket 上的请求飞完（fake async 不会推进真实 I/O），并各推进一帧。
Future<void> _flyIO(WidgetTester tester, {int rounds = 4}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

void main() {
  late _FakeCore core;

  setUp(() async {
    HttpOverrides.global = null;
    core = await _FakeCore.start(_scenario());
    ApiService.baseUrl = core.baseUrl;
    ApiService.setToken('test-token');
    WebSocketService.baseUrl = core.baseUrl.replaceFirst('http://', 'ws://');
  });

  tearDown(() async {
    await core.close();
    ApiService.setToken(null);
    ApiService.baseUrl = 'http://127.0.0.1:0';
    WebSocketService.baseUrl = 'ws://127.0.0.1:0';
  });

  testWidgets(
    'EXTREME-COLLAPSE-01：20 组 × 121 工具 + 3 用户 + 7 hook + 3 提问（1/3/5 问），'
    '展开第 11 组，底部↔顶部匀速往返：页面不跳、拇指不抖',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessagePanel(
              selectedAgent: Agent(
                id: 'a1',
                name: 'A1',
                type: 'normal',
                lastMessage: '',
              ),
            ),
          ),
        ),
      );
      await _flyIO(tester, rounds: 16);
      final ScrollPosition pos = _pos(tester);
      final Finder msgList = find
          .descendant(
            of: find.byType(MessageList),
            matching: find.byType(ListView),
          )
          .first;

      // 进入阅读模式：首载的贴底收敛会吞掉早期的滚动通知，反复试到"确实离开底部"
      for (int i = 0; i < 30; i++) {
        await tester.drag(msgList, const Offset(0, 400));
        await tester.pump();
        await _flyIO(tester, rounds: 2);
        if (pos.maxScrollExtent - pos.pixels > 600) break;
      }
      expect(
        pos.maxScrollExtent - pos.pixels,
        greaterThan(600),
        reason: '测试前提：要进入阅读模式（否则每次补页都会被贴底拽回去）',
      );

      // 翻到第 11 组：按渲染树的"已布局下标区间"决定往哪边滚（像素是估算值，不可靠）
      const int headIndex = _expandedGroup * (_toolsPerGroup + 1);
      final Finder onStage = find.byKey(
        const ValueKey<String>('collapsed-run-g${_expandedGroup}t0'),
      );
      final Finder anywhere = find.byKey(
        const ValueKey<String>('collapsed-run-g${_expandedGroup}t0'),
        skipOffstage: false,
      );
      for (int i = 0; i < 400 && onStage.evaluate().isEmpty; i++) {
        // 已构建但还在 cache 区（不在视口里）：直接按它的内容坐标落过去
        if (anywhere.evaluate().isNotEmpty) {
          final double? off = _childOffset(tester, anywhere);
          if (off != null) {
            pos.jumpTo(
              (off + 12 - 80).clamp(0.0, pos.maxScrollExtent),
            );
            await tester.pump();
            continue;
          }
        }
        final ({int first, int last})? range = _builtRange(tester);
        if (range == null) {
          await tester.pump();
          await _flyIO(tester, rounds: 1);
          continue;
        }
        if (headIndex < range.first) {
          pos.jumpTo(math.max(0, pos.pixels - 700));
        } else if (headIndex > range.last) {
          pos.jumpTo(math.min(pos.maxScrollExtent, pos.pixels + 700));
        } else {
          // 目标落在已布局区间里：等这一趟补页/构建落地
          await _flyIO(tester, rounds: 2);
          continue;
        }
        await tester.pump();
        if (i % 2 == 0) await _flyIO(tester, rounds: 1);
      }
      expect(
        onStage,
        findsOneWidget,
        reason: '测试前提：第 11 组要能被翻到并点开'
            '（pixels=${pos.pixels.toStringAsFixed(0)} / max=${pos.maxScrollExtent.toStringAsFixed(0)}；'
            'range=${_builtRange(tester)}）',
      );
      await tester.tap(onStage);
      await tester.pump();
      await _flyIO(tester, rounds: 3);
      expect(
        find.textContaining('点击收起', skipOffstage: false),
        findsOneWidget,
        reason: '测试前提：第 11 组进入展开态'
            '（pixels=${pos.pixels.toStringAsFixed(0)}）',
      );

      // 回到最底部（粗定位，不计入匀速采样）
      for (int i = 0; i < 40; i++) {
        final double max = pos.maxScrollExtent;
        if ((max - pos.pixels).abs() <= 1) break;
        pos.jumpTo(max);
        await tester.pump();
        await _flyIO(tester, rounds: 2);
      }

      // ── 匀速往返采样 ───────────────────────────────────────────────
      const double step = 120;
      final List<String> jumps = <String>[];
      final List<double> thumbSteps = <double>[];
      final List<double> thumbLenDeltas = <double>[];
      final List<String> thumbReversals = <String>[];
      int pageSamples = 0;

      Future<void> sweep({required bool up}) async {
        for (int i = 0; i < 4000; i++) {
          final double before = pos.pixels;
          final List<({int index, double y, double h})> anchors =
              _visibleAnchors(tester);
          final Rect? thumb0 = _thumb(tester);
          final MessageList w0 = tester.widget<MessageList>(
            find.byType(MessageList),
          );
          final int stamp0 =
              w0.revision + w0.padAboveStamp + w0.contentShiftStamp;
          final double max = pos.maxScrollExtent;
          final double target = up
              ? math.max(0, before - step)
              : math.min(max, before + step);
          if ((target - before).abs() < 0.5) break;
          // 顶/底那一步会被夹住（不足一个步长）：不参与步长判据
          final bool clamped = up ? target <= 0.01 : target >= max - 0.01;

          pos.jumpTo(target);
          // 两帧：第一帧布局 + 帧后刷新视口坐标，第二帧让拇指按新坐标重绘
          await tester.pump();
          await tester.pump();
          if (i % 3 == 0) await _flyIO(tester, rounds: 1);

          // ① 页面不跳：视口顶附近**某一格高度没变**的内容，屏幕位移必须正好等于步长
          //    （上滚 = 内容整体往下走 = 屏幕 y 变大）
          if (!clamped) {
            final double expected = up ? step : -step;
            for (final ({int index, double y, double h}) a in anchors) {
              final double? afterY = _screenYOfIndex(tester, a.index);
              final double? afterH = _heightOfIndex(tester, a.index);
              if (afterY == null || afterH == null) continue;
              if ((afterH - a.h).abs() > 0.5) {
                // 这一格自己刚被换过（占位 → 真消息 / 展开 / 收起）：
                // 设计口径只保证它**以下**整段不动，换下一格当锚
                continue;
              }
              pageSamples++;
              final double moved = afterY - a.y;
              if ((moved - expected).abs() > 1.0) {
                final MessageList w1 = tester.widget<MessageList>(
                  find.byType(MessageList),
                );
                final int stamp1 =
                    w1.revision + w1.padAboveStamp + w1.contentShiftStamp;
                jumps.add(
                  '第 $i 步（${up ? '上' : '下'}滚）下标 ${a.index} 的屏幕位移 '
                  '${moved.toStringAsFixed(1)}px ≠ ${expected.toStringAsFixed(0)}px'
                  '（pixels $before → ${pos.pixels.toStringAsFixed(0)}；'
                  'max ${max.toStringAsFixed(0)} → '
                  '${pos.maxScrollExtent.toStringAsFixed(0)}；'
                  '信号 ${stamp0 == stamp1 ? '无' : '有'}）',
                );
              }
              break;
            }
          }

          // ② 拇指：均匀滚动下位移/长度变化有界、方向不反复
          final Rect? thumb1 = _thumb(tester);
          if (thumb0 != null && thumb1 != null) {
            final double dTop = thumb1.top - thumb0.top;
            final double dLen = thumb1.height - thumb0.height;
            thumbSteps.add(dTop.abs());
            thumbLenDeltas.add(dLen.abs());
            if (up ? dTop > 1.0 : dTop < -1.0) {
              thumbReversals.add(
                '第 $i 步拇指反向：${up ? '上滚' : '下滚'} dTop=${dTop.toStringAsFixed(1)}px',
              );
            }
          }
          if (clamped) break;
        }
      }

      await sweep(up: true);
      // 折返：先到底，再匀速往下滚回底部
      pos.jumpTo(0);
      await tester.pump();
      await _flyIO(tester, rounds: 2);
      await sweep(up: false);

      // 打印现场，便于失败时定位（不靠日志也能从断言消息看到数字）
      final double maxThumbStep =
          thumbSteps.isEmpty ? 0 : thumbSteps.reduce(math.max);
      final double maxThumbLen =
          thumbLenDeltas.isEmpty ? 0 : thumbLenDeltas.reduce(math.max);
      // ignore: avoid_print
      print(
        'EXTREME-COLLAPSE-01 采样：页面判据取样 $pageSamples 次、跳变 ${jumps.length} 条；'
        '拇指最大单步位移 ${maxThumbStep.toStringAsFixed(1)}px；'
        '拇指最大长度变化 ${maxThumbLen.toStringAsFixed(1)}px；'
        '拇指反向 ${thumbReversals.length} 次',
      );
      for (final String j in jumps.take(6)) {
        // ignore: avoid_print
        print('EXTREME-COLLAPSE-01 页面：$j');
      }
      for (final String j in thumbReversals.take(6)) {
        // ignore: avoid_print
        print('EXTREME-COLLAPSE-01 拇指：$j');
      }

      // ── 判据 ──────────────────────────────────────────────────────
      expect(
        jumps,
        isEmpty,
        reason: '页面跳了（共 ${jumps.length} 条）：${jumps.take(6).join(' ｜ ')}',
      );
      expect(
        maxThumbStep,
        lessThanOrEqualTo(8.0),
        reason: '拇指异常抖动：均匀 ${step.toStringAsFixed(0)}px 滚动中出现 '
            '${maxThumbStep.toStringAsFixed(1)}px 的单步位移（上限 8px）',
      );
      expect(
        maxThumbLen,
        lessThanOrEqualTo(2.0),
        reason: '拇指异常抖动：单步长度变化 ${maxThumbLen.toStringAsFixed(1)}px（上限 2px）',
      );
      expect(
        thumbReversals,
        isEmpty,
        reason: '拇指方向反复（共 ${thumbReversals.length} 次）：'
            '${thumbReversals.take(6).join(' ｜ ')}',
      );

      // 收尾：烧掉面板里的超时定时器，别留 pending timer
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
