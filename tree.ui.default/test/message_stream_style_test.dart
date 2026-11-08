import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree_ui_default/ui/app_theme.dart';
import 'package:tree_ui_default/ui/models/message.dart';
import 'package:tree_ui_default/ui/widgets/message_list.dart';
import 'package:tree_ui_default/ui/widgets/thinking_card.dart';

/// 消息流的排版口径（[lib/README.md](../lib/README.md) 不变量 11）：
/// 模型消息是**高亮块**（左侧中性竖条，无底色、没有整圈边框），
/// 用户消息是**中性气泡**（中性底 + 1px 中性边框，不再用主色满色底）；
/// 工具调用 / 思考各占一行（见 tool_row_detail_test.dart）。
ChatMessage textMessage({
  required String id,
  required String role,
  required String content,
  bool streaming = false,
}) =>
    ChatMessage(
      id: id,
      role: role,
      content: content,
      timestamp: DateTime(2026, 10, 2, 21, 39),
      isStreaming: streaming,
    );

Future<void> pumpList(WidgetTester tester, List<ChatMessage> messages) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: MessageList(slots: messages)),
  ));
  await tester.pump();
}

/// 所有容器里那个「只画了左边框」的装饰（= 模型消息的高亮块）
BoxDecoration? assistantHighlight(WidgetTester tester) {
  for (final Container c in tester.widgetList<Container>(find.byType(Container))) {
    final Decoration? d = c.decoration;
    if (d is! BoxDecoration) continue;
    final BoxBorder? border = d.border;
    if (border is Border && border.left.width == 3) return d;
  }
  return null;
}

void main() {
  testWidgets('模型消息用左侧高亮条，不套整圈边框', (WidgetTester tester) async {
    await pumpList(tester, <ChatMessage>[
      textMessage(id: 'a1', role: 'agent', content: '这就是模型说的话'),
    ]);

    final BoxDecoration? decoration = assistantHighlight(tester);
    expect(decoration, isNotNull, reason: '模型消息要有高亮块');
    final Border border = decoration!.border! as Border;
    expect(border.left.width, 3);
    expect(border.top, BorderSide.none, reason: '只有左边一条竖线，不是整圈盒子');
    expect(border.right, BorderSide.none);
    expect(border.bottom, BorderSide.none);
    expect(
      decoration.color,
      isNull,
      reason: '去绿后模型消息无底色（用户 2026-11-08：消息流一起中性化）',
    );
    final ColorScheme cs =
        Theme.of(tester.element(find.byType(MessageList))).colorScheme;
    expect(
      border.left.color,
      cs.outline,
      reason: '竖条是中性描边色，不再用主色',
    );
    expect(find.text('这就是模型说的话'), findsOneWidget);
  });

  testWidgets('用户消息是中性气泡：中性底 + 圆角 + 1px 边框，没有竖条',
      (WidgetTester tester) async {
    await pumpList(tester, <ChatMessage>[
      textMessage(id: 'u1', role: 'user', content: '这是我说的'),
    ]);

    expect(assistantHighlight(tester), isNull, reason: '用户消息不该有高亮竖条');
    final ThemeData theme = Theme.of(tester.element(find.byType(MessageList)));
    final Color primary = theme.colorScheme.primary;
    BoxDecoration? bubble;
    for (final Container c in tester.widgetList<Container>(
      find.byType(Container),
    )) {
      final Decoration? d = c.decoration;
      if (d is BoxDecoration && d.color == AppTheme.userBubbleLight) {
        bubble = d;
        break;
      }
    }
    expect(bubble, isNotNull, reason: '用户消息是中性浅灰底气泡');
    expect(bubble!.color, isNot(primary), reason: '不再用主色满色底');
    expect(bubble.borderRadius, isNotNull, reason: '保持圆角');
    final BoxBorder? border = bubble.border;
    expect(border, isNotNull, reason: '1px 中性边框');
    expect((border! as Border).top.width, 1);
    expect(find.text('这是我说的'), findsOneWidget);
  });

  testWidgets('模型消息按 markdown 渲染（正文用 w500 与更大行距）',
      (WidgetTester tester) async {
    await pumpList(tester, <ChatMessage>[
      textMessage(id: 'a2', role: 'agent', content: '**加粗** 的一段 \n 第二行'),
    ]);

    expect(find.textContaining('加粗', findRichText: true), findsOneWidget);
  });

  testWidgets('思考行摘要不是斜体（与工具调用条一致）', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(
          children: <Widget>[
            ThinkingCard(
              message: textMessage(
                id: 'k1',
                role: 'assistant',
                content: '先看看 team 的字段，再决定怎么改',
              ),
            ),
          ],
        ),
      ),
    ));

    final Text summary = tester.widget<Text>(
      find.text('先看看 team 的字段，再决定怎么改'),
    );
    expect(
      summary.style?.fontStyle,
      isNot(FontStyle.italic),
      reason: '思考摘要不斜体（用户 2026-10-19：与工具调用条的字重/样式一致）',
    );
  });
}
