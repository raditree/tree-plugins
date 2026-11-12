import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree_ui_default/ui/pages/settings_page.dart';
import 'package:tree_ui_default/ui/services/model_pool.dart';

/// 模型池 kind / protocol 与消费方过滤（MP-3 / MP-4 前端部分）。
///
/// 锁住：
/// 1. 旧数据缺省 kind 视为 chat，kind → protocol 推导固定；
/// 2. 三种 kind 的提交体只带各自字段（embedding → dimensions，decision →
///    confidence_threshold）；
/// 3. 编辑模式不下发 kind / protocol（后端 MP-2 禁止改类型），kind 下拉禁用；
/// 4. 创建 Agent 等消费方只列 chat 模型。
void main() {
  group('kind / protocol / 过滤', () {
    test('缺省 kind 视为 chat', () {
      expect(modelKindOf(<String, dynamic>{'model_id': 'a'}), kModelKindChat);
      expect(
        modelKindOf(<String, dynamic>{'model_id': 'a', 'kind': ''}),
        kModelKindChat,
      );
    });

    test('kind → protocol：chat/embedding 为 openai，decision 为 jev', () {
      expect(protocolForKind(kModelKindChat), 'openai');
      expect(protocolForKind(kModelKindEmbedding), 'openai');
      expect(protocolForKind(kModelKindDecision), 'jev');
    });

    test('展示三态：缺 kind / has_api_key 时如实标未知', () {
      expect(
        modelKindDisplayOf(<String, dynamic>{'model_id': 'a'}),
        kModelKindUnknown,
      );
      expect(
        modelKindDisplayOf(<String, dynamic>{'model_id': 'a', 'kind': 'chat'}),
        kModelKindChat,
      );
      expect(
        modelKeyStateOf(<String, dynamic>{'has_api_key': true}),
        ModelKeyState.configured,
      );
      expect(
        modelKeyStateOf(<String, dynamic>{'has_api_key': false}),
        ModelKeyState.missing,
      );
      expect(modelKeyStateOf(<String, dynamic>{}), ModelKeyState.unknown);
    });

    test('条件字段组：三组互斥', () {
      final ModelKindFields chat = modelKindFieldsOf(kModelKindChat);
      expect(<bool>[chat.chat, chat.embedding, chat.decision],
          <bool>[true, false, false]);
      final ModelKindFields embedding =
          modelKindFieldsOf(kModelKindEmbedding);
      expect(<bool>[embedding.chat, embedding.embedding, embedding.decision],
          <bool>[false, true, false]);
      final ModelKindFields decision = modelKindFieldsOf(kModelKindDecision);
      expect(<bool>[decision.chat, decision.embedding, decision.decision],
          <bool>[false, false, true]);
    });

    test('chatModelsOf 只保留 chat，缺省 kind 视为 chat', () {
      final List<Map<String, dynamic>> models = <Map<String, dynamic>>[
        <String, dynamic>{'model_id': 'chat_old'},
        <String, dynamic>{'model_id': 'emb', 'kind': 'embedding'},
        <String, dynamic>{'model_id': 'dec', 'kind': 'decision'},
        <String, dynamic>{'model_id': 'chat_new', 'kind': 'chat'},
      ];
      expect(
        chatModelsOf(models).map((Map<String, dynamic> m) => m['model_id']),
        <String>['chat_old', 'chat_new'],
      );
    });
  });

  group('模型元数据展示（P8）', () {
    test('端点价格标签：每 1M、USD 用美元符号，缺项显示 ?', () {
      expect(
        modelPricingLabel(<String, dynamic>{
          'meta': <String, dynamic>{
            'pricing': <String, dynamic>{
              'prompt_per_million': 3,
              'completion_per_million': 15,
              'currency': 'USD',
            },
          },
        }),
        r'$3.00 / 1M 输入 · $15.00 / 1M 输出',
      );
      expect(
        modelPricingLabel(<String, dynamic>{
          'meta': <String, dynamic>{
            'pricing': <String, dynamic>{
              'prompt_per_million': 0.0005,
              'completion_per_million': 0.002,
            },
          },
        }),
        r'$0.0005 / 1M 输入 · $0.0020 / 1M 输出',
      );
      expect(modelPricingLabel(<String, dynamic>{}), isEmpty);
      expect(
        modelPricingLabel(<String, dynamic>{
          'meta': <String, dynamic>{'error': '不可达'},
        }),
        isEmpty,
      );
    });

    test('端点档位：meta 优先；未探测 ⇒ 空（UI 回退兜底）', () {
      expect(
        modelMetaEffortsOf(<String, dynamic>{
          'meta': <String, dynamic>{
            'reasoning_effort_options': <String>['low', 'medium', 'high'],
          },
        }),
        <String>['low', 'medium', 'high'],
      );
      expect(modelMetaEffortsOf(<String, dynamic>{}), isEmpty);
      expect(
        modelMetaEffortsOf(<String, dynamic>{
          'meta': <String, dynamic>{'reasoning_effort_options': <String>[]},
        }),
        isEmpty,
      );
    });
  });

  group('D7 provider / 模型身份', () {
    test('provider / key / 分组标题 / 模态徽标', () {
      final Map<String, dynamic> model = <String, dynamic>{
        'provider': 'deepseek',
        'key': 'deepseek/flash',
        'model_id': 'flash',
        'if_vision': true,
        'if_audio': false,
        'if_video': true,
      };
      expect(providerOf(model), 'deepseek');
      expect(modelKeyOf(model), 'deepseek/flash');
      expect(modelMediaLabelsOf(model), <String>['image', 'video']);
      // 旧数据：没有 provider / key。
      expect(
        modelKeyOf(<String, dynamic>{'model_id': 'm1'}),
        'm1',
      );
      expect(providerLabelOf('legacy'), contains('旧版'));
      expect(providerLabelOf(''), contains('独立端点'));
    });

    test('归到 provider 的新增：免端点密钥，提交带 provider', () {
      const ModelEditorDraft draft = ModelEditorDraft(
        kind: kModelKindChat,
        provider: 'deepseek',
        modelId: 'flash',
        name: 'Flash',
        ifVision: true,
      );
      expect(draft.validate(), isNull);
      final Map<String, dynamic> payload = draft.toPayload();
      expect(payload['provider'], 'deepseek');
      expect(payload.containsKey('base_url'), isFalse);
      expect(payload.containsKey('api_key'), isFalse);
      expect(payload['if_vision'], isTrue);
      expect(payload['if_audio'], isFalse);
      expect(payload['if_video'], isFalse);
    });

    test('独立端点仍要求 base_url/api_key', () {
      const ModelEditorDraft draft = ModelEditorDraft(
        kind: kModelKindChat,
        modelId: 'x',
        name: 'X',
      );
      expect(draft.validate(), contains('base_url 与 api_key'));
    });

    test('D8：没声明档位就不下发 reasoning_effort_options', () {
      const ModelEditorDraft draft = ModelEditorDraft(
        kind: kModelKindChat,
        provider: 'p',
        modelId: 'm',
        name: 'M',
      );
      final Map<String, dynamic> payload = draft.toPayload();
      expect(payload.containsKey('reasoning_effort_options'), isFalse);
      expect(payload.containsKey('reasoning_effort'), isFalse);
    });

    test('编辑 provider 模型：不下发 provider（创建后不可改）', () {
      const ModelEditorDraft draft = ModelEditorDraft(
        originalKind: kModelKindChat,
        provider: 'deepseek',
        kind: kModelKindChat,
        modelId: 'flash',
        name: 'Flash',
      );
      expect(draft.toPayload().containsKey('provider'), isFalse);
    });
  });

  group('ModelEditorDraft 提交体', () {
    test('chat 新增：带 kind/protocol 与现有 chat 字段', () {
      const ModelEditorDraft draft = ModelEditorDraft(
        kind: kModelKindChat,
        modelId: 'lfm3',
        name: 'LFM3',
        baseUrl: 'http://127.0.0.1:8000/v1',
        apiKey: 'sk-x',
        thinking: true,
        ifVision: true,
        reasoningEffort: 'high',
        reasoningEffortOptions: <String>['low', 'high'],
        maxSeqlen: 131072,
        maxOutputTokens: 8192,
      );
      expect(draft.validate(), isNull);
      final Map<String, dynamic> payload = draft.toPayload();
      expect(payload['kind'], 'chat');
      expect(payload['protocol'], 'openai');
      expect(payload['thinking'], isTrue);
      expect(payload['if_vision'], isTrue);
      expect(payload['reasoning_effort'], 'high');
      expect(payload['max_seqlen'], 131072);
      expect(payload.containsKey('dimensions'), isFalse);
      expect(payload.containsKey('confidence_threshold'), isFalse);
    });

    test('embedding 新增：带 dimensions / max_input_tokens，不带 chat 字段', () {
      const ModelEditorDraft draft = ModelEditorDraft(
        kind: kModelKindEmbedding,
        modelId: 'bge-m3',
        name: 'BGE-M3',
        baseUrl: 'http://127.0.0.1:8000/v1',
        apiKey: 'sk-x',
        dimensions: 1024,
        maxInputTokens: 8192,
        thinking: true,
      );
      expect(draft.validate(), isNull);
      final Map<String, dynamic> payload = draft.toPayload();
      expect(payload['kind'], 'embedding');
      expect(payload['protocol'], 'openai');
      expect(payload['dimensions'], 1024);
      expect(payload['max_input_tokens'], 8192);
      expect(payload.containsKey('thinking'), isFalse);
      expect(payload.containsKey('max_seqlen'), isFalse);
    });

    test('decision 新增：带 confidence_threshold / max_input_tokens', () {
      const ModelEditorDraft draft = ModelEditorDraft(
        kind: kModelKindDecision,
        modelId: 'jev',
        name: 'JEV',
        baseUrl: 'https://api.example/v1',
        apiKey: 'sk-x',
        confidenceThreshold: 0.7,
        maxInputTokens: 262144,
      );
      expect(draft.validate(), isNull);
      final Map<String, dynamic> payload = draft.toPayload();
      expect(payload['kind'], 'decision');
      expect(payload['protocol'], 'jev');
      expect(payload['confidence_threshold'], 0.7);
      expect(payload['max_input_tokens'], 262144);
      expect(payload.containsKey('dimensions'), isFalse);
      expect(payload.containsKey('thinking'), isFalse);
    });

    test('编辑：不下发 kind/protocol；base_url/api_key 留空即不改', () {
      const ModelEditorDraft draft = ModelEditorDraft(
        originalKind: kModelKindChat,
        kind: kModelKindChat,
        modelId: 'lfm3',
        name: 'LFM3',
      );
      expect(draft.validate(), isNull);
      final Map<String, dynamic> payload = draft.toPayload();
      expect(payload.containsKey('kind'), isFalse);
      expect(payload.containsKey('protocol'), isFalse);
      expect(payload.containsKey('base_url'), isFalse);
      expect(payload.containsKey('api_key'), isFalse);
    });

    test('embedding 缺 dimensions / ≤0 被拦下', () {
      const ModelEditorDraft missing = ModelEditorDraft(
        kind: kModelKindEmbedding,
        modelId: 'e',
        name: 'e',
        baseUrl: 'http://x/v1',
        apiKey: 'sk-x',
      );
      expect(missing.validate(), 'embedding 模型必须填写大于 0 的维度（dimensions）');
      const ModelEditorDraft zero = ModelEditorDraft(
        kind: kModelKindEmbedding,
        modelId: 'e',
        name: 'e',
        baseUrl: 'http://x/v1',
        apiKey: 'sk-x',
        dimensions: 0,
      );
      expect(zero.validate(), 'embedding 模型必须填写大于 0 的维度（dimensions）');
    });

    test('decision 置信度阈值：必填且必须落在 (0,1)', () {
      const ModelEditorDraft missing = ModelEditorDraft(
        kind: kModelKindDecision,
        modelId: 'd',
        name: 'd',
        baseUrl: 'http://x/v1',
        apiKey: 'sk-x',
      );
      expect(missing.validate(), 'decision 模型必须填写置信度阈值');
      const ModelEditorDraft zero = ModelEditorDraft(
        kind: kModelKindDecision,
        modelId: 'd',
        name: 'd',
        baseUrl: 'http://x/v1',
        apiKey: 'sk-x',
        confidenceThreshold: 0,
      );
      expect(zero.validate(), 'decision 模型的置信度阈值必须在 (0,1) 之间');
      const ModelEditorDraft one = ModelEditorDraft(
        kind: kModelKindDecision,
        modelId: 'd',
        name: 'd',
        baseUrl: 'http://x/v1',
        apiKey: 'sk-x',
        confidenceThreshold: 1,
      );
      expect(one.validate(), 'decision 模型的置信度阈值必须在 (0,1) 之间');
      const ModelEditorDraft ok = ModelEditorDraft(
        kind: kModelKindDecision,
        modelId: 'd',
        name: 'd',
        baseUrl: 'http://x/v1',
        apiKey: 'sk-x',
        confidenceThreshold: 0.7,
      );
      expect(ok.validate(), isNull);
    });
  });

  group('ModelEditorDialog 条件字段与 kind 可编辑性', () {
    Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

    testWidgets('新增默认 chat：无 dimensions / 阈值字段，kind 可切换', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(wrap(const ModelEditorDialog()));
      expect(find.byKey(const Key('model-editor-dimensions')), findsNothing);
      expect(find.byKey(const Key('model-editor-confidence')), findsNothing);
      final DropdownButtonFormField<String> kind =
          tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const Key('model-editor-kind')),
      );
      expect(kind.onChanged, isNotNull, reason: '新增时 kind 可选择');
    });

    testWidgets('新增切到 embedding / decision 时显示对应字段', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(wrap(const ModelEditorDialog()));

      await tester.tap(find.byKey(const Key('model-editor-kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('embedding').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('model-editor-dimensions')), findsOneWidget);
      expect(
        find.byKey(const Key('model-editor-max-input-tokens')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('model-editor-confidence')), findsNothing);

      await tester.tap(find.byKey(const Key('model-editor-kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('decision').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('model-editor-confidence')), findsOneWidget);
      expect(
        find.byKey(const Key('model-editor-max-input-tokens')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('model-editor-dimensions')), findsNothing);
    });

    testWidgets('旧插件模型（缺 kind / has_api_key）：编辑器可用并提示未知', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          const ModelEditorDialog(
            existing: <String, dynamic>{'model_id': 'old', 'name': '旧模型'},
          ),
        ),
      );
      expect(find.textContaining('旧版插件未返回 kind'), findsOneWidget);
      expect(find.textContaining('当前状态未知'), findsOneWidget);
      final DropdownButtonFormField<String> kind =
          tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const Key('model-editor-kind')),
      );
      expect(kind.onChanged, isNull, reason: '编辑时不允许改 kind（回到 chat 兜底）');
    });

    testWidgets('编辑模式 kind 下拉禁用（类型不可改）', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(
          const ModelEditorDialog(
            existing: <String, dynamic>{
              'model_id': 'emb',
              'name': 'BGE-M3',
              'kind': 'embedding',
              'dimensions': 1024,
            },
          ),
        ),
      );
      final DropdownButtonFormField<String> kind =
          tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const Key('model-editor-kind')),
      );
      expect(kind.onChanged, isNull, reason: '编辑时不允许改 kind');
      expect(
        find.byKey(const Key('model-editor-dimensions')),
        findsOneWidget,
        reason: '编辑 embedding 仍显示其专属字段',
      );
    });
  });
}
