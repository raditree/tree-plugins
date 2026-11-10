import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_agent_loop/src/llm/model_catalog_client.dart';
import 'package:tree_agent_loop/src/model_meta.dart';
import 'package:tree_agent_loop/src/paths.dart';

void main() {
  group('模型目录端点（P8）', () {
    test('base_url 归一：补 /models，去掉已带的 completions 后缀', () {
      expect(
        modelsEndpointFor('https://openrouter.ai/api/v1'),
        'https://openrouter.ai/api/v1/models',
      );
      expect(
        modelsEndpointFor('https://api.example.com/v1/'),
        'https://api.example.com/v1/models',
      );
      expect(
        modelsEndpointFor('https://api.example.com/v1/chat/completions'),
        'https://api.example.com/v1/models',
      );
      expect(
        () => modelsEndpointFor('  '),
        throwsA(isA<ModelMetaFailure>()),
      );
    });
  });

  group('OpenAI /models 回包解析（P8）', () {
    final Map<String, Object?> payload = <String, Object?>{
      'data': <Object?>[
        <String, Object?>{
          'id': 'other/model',
          'pricing': <String, Object?>{'prompt': '0.000001'},
        },
        <String, Object?>{
          'id': 'openai/gpt-x',
          'pricing': <String, Object?>{
            'prompt': '0.000003',
            'completion': '0.000015',
          },
          'supported_parameters': <String>['tools', 'reasoning'],
          'reasoning': <String, Object?>{
            'supported_efforts': <String>['low', 'medium', 'high'],
          },
          'top_provider': <String, Object?>{'context_length': 128000},
        },
      ],
    };

    test('挑条目：全等 / 忽略大小写 / 末段互认', () {
      expect(
        selectOpenAiModelEntry(payload, 'openai/gpt-x')['id'],
        'openai/gpt-x',
      );
      expect(selectOpenAiModelEntry(payload, 'GPT-X')['id'], 'openai/gpt-x');
      expect(selectOpenAiModelEntry(payload, 'gpt-x')['id'], 'openai/gpt-x');
      expect(
        () => selectOpenAiModelEntry(payload, 'nope'),
        throwsA(isA<ModelMetaFailure>()),
      );
    });

    test('价格折算每 1M；档位来自 supported_efforts；上下文取 top_provider', () {
      final ModelMeta meta = parseModelMetaEntry(
        selectOpenAiModelEntry(payload, 'gpt-x'),
        modelId: 'gpt-x',
        fetchedAt: '2026-11-10T10:00:00',
      );
      expect(meta.pricing!.promptPerMillion, 3.0);
      expect(meta.pricing!.completionPerMillion, 15.0);
      expect(meta.pricing!.currency, 'USD');
      expect(meta.reasoningEffortOptions, <String>['low', 'medium', 'high']);
      expect(meta.reasoningSupported, isTrue);
      expect(meta.contextLength, 128000);
      expect(meta.error, isEmpty);
    });

    test('端点只回 id：按"未声明"处理，价格为空', () {
      final ModelMeta meta = parseModelMetaEntry(
        <String, Object?>{'id': 'bare'},
        modelId: 'bare',
        fetchedAt: '2026-11-10T10:00:00',
      );
      expect(meta.pricing, isNull);
      expect(meta.reasoningEffortOptions, isEmpty);
      expect(meta.reasoningSupported, isFalse);
    });

    test('单模型对象回包也能解析', () {
      final Map<String, Object?> single = <String, Object?>{
        'id': 'solo',
        'pricing': <String, Object?>{'input_per_million': 2.5},
      };
      expect(selectOpenAiModelEntry(single, 'solo')['id'], 'solo');
      final ModelMeta meta = parseModelMetaEntry(
        single,
        modelId: 'solo',
        fetchedAt: '2026-11-10T10:00:00',
      );
      expect(meta.pricing!.promptPerMillion, 2.5);
    });
  });

  group('元数据缓存（P8）', () {
    late Directory temp;
    late AgentDataPaths paths;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('tree_agent_meta_');
      paths = AgentDataPaths(temp.path);
    });

    tearDown(() {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('读-改-写：按 model_id 排序、坏缓存回空表、可删除', () {
      expect(readModelMeta(paths, 'm1'), isNull);
      writeModelMeta(
        paths,
        const ModelMeta(
          modelId: 'm2',
          pricing: ModelPricing(
            promptPerMillion: 3,
            completionPerMillion: 15,
          ),
          reasoningEffortOptions: <String>['low', 'high'],
          source: 'openai.models',
          fetchedAt: '2026-11-10T10:00:00',
        ),
      );
      writeModelMeta(
        paths,
        const ModelMeta(
          modelId: 'm1',
          contextLength: 32000,
          fetchedAt: '2026-11-10T10:01:00',
        ),
      );
      final Map<String, Map<String, dynamic>> cache = readModelMetaCache(paths);
      expect(cache.keys.toList(), <String>['m1', 'm2']);
      expect(readModelMeta(paths, 'm2')!.pricing!.completionPerMillion, 15);
      expect(
        readModelMeta(paths, 'm2')!.reasoningEffortOptions,
        <String>['low', 'high'],
      );

      // 失败保留上次成功信息，只追加错误。
      final ModelMeta failed = readModelMeta(paths, 'm2')!.withError(
        '端点不可达',
        at: '2026-11-10T10:02:00',
      );
      expect(failed.pricing!.promptPerMillion, 3);
      expect(failed.error, '端点不可达');
      expect(failed.reasoningEffortOptions, <String>['low', 'high']);

      removeModelMeta(paths, 'm2');
      expect(readModelMeta(paths, 'm2'), isNull);
      expect(readModelMeta(paths, 'm1'), isNotNull);

      File(modelMetaFile(paths)).writeAsStringSync('{{{');
      expect(readModelMetaCache(paths), isEmpty);
      expect(p.join(paths.root, 'config', 'model_meta.json'), modelMetaFile(paths));
    });
  });
}
