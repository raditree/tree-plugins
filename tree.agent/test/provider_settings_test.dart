import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_agent_loop/src/paths.dart';
import 'package:tree_agent_loop/src/settings/domain_settings.dart';
import 'package:tree_agent_loop/src/settings/provider_settings.dart';

/// D7：provider 池 + provider 模型目录缓存 + `provider/model_id` 身份。
void main() {
  late Directory temp;
  late AgentDataPaths paths;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_agent_provider_');
    paths = AgentDataPaths(temp.path);
    Directory(paths.providersDir).createSync(recursive: true);
    Directory(paths.modelsDir).createSync(recursive: true);
  });

  tearDown(() {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  void writeProvider(String id, String body) {
    File(paths.providerFile(id)).writeAsStringSync(
      'id: $id\n$body',
    );
  }

  test('provider 配置：读写、脱敏、环境变量优先、id slug', () {
    writeProvider(
      'deepseek',
      'name: DeepSeek 官方\n'
      'base_url: https://api.deepseek.com/v1/\n'
      'api_key: sk-file\n'
      'api_key_env: DEEPSEEK_API_KEY\n'
      'protocol: openai\n'
      'enabled: true\n',
    );
    final List<ProviderConfig> providers = readProviderConfigs(paths);
    expect(providers, hasLength(1));
    final ProviderConfig provider = providers.single;
    expect(provider.id, 'deepseek');
    expect(provider.label, 'DeepSeek 官方');
    expect(provider.resolvedBaseUrl, 'https://api.deepseek.com/v1');
    expect(
      provider.resolveApiKey(environment: <String, String>{
        'DEEPSEEK_API_KEY': ' sk-env ',
      }),
      'sk-env',
    );
    expect(
      provider.resolveApiKey(environment: const <String, String>{}),
      'sk-file',
      reason: '环境变量读不到时回落到明文',
    );

    final Map<String, dynamic> api = provider.toApiJson();
    expect(api['base_url'], 'https://api.deepseek.com');
    expect(api['has_api_key'], isTrue);
    expect(api['api_key_env'], 'DEEPSEEK_API_KEY');
    expect(api.containsKey('api_key'), isFalse, reason: '密钥永不出插件');

    expect(ProviderConfig.slugOf('DeepSeek 官方'), 'deepseek');
    expect(ProviderConfig.slugOf('   '), 'provider');
    expect(ProviderConfig.slugOf('OpenAI/Compatible'), 'openai-compatible');
  });

  test('provider 校验：新增必填、URL 形态、环境变量名、协议白名单', () {
    expect(
      ProviderConfig.validateProvider(<String, dynamic>{}),
      'name 不能为空',
    );
    expect(
      ProviderConfig.validateProvider(<String, dynamic>{'name': 'x'}),
      'base_url 不能为空',
    );
    expect(
      ProviderConfig.validateProvider(<String, dynamic>{
        'name': 'x',
        'base_url': 'ftp://a',
      }),
      'base_url 必须是 http(s) 地址',
    );
    expect(
      ProviderConfig.validateProvider(<String, dynamic>{
        'name': 'x',
        'base_url': 'https://a',
        'api_key_env': '1BAD',
      }),
      contains('不是合法的环境变量名'),
    );
    expect(
      ProviderConfig.validateProvider(<String, dynamic>{
        'name': 'x',
        'base_url': 'https://a',
        'protocol': 'jev',
      }),
      contains('v1 只支持 protocol=openai'),
    );
    expect(
      ProviderConfig.validateProvider(<String, dynamic>{
        'name': 'x',
        'base_url': 'https://a',
        'api_key_env': 'OPENAI_API_KEY',
      }),
      isNull,
    );
  });

  test('领域设置：provider 应用端点/密钥，模型级覆盖优先', () {
    writeProvider(
      'deepseek',
      'name: DeepSeek\n'
      'base_url: https://api.deepseek.com\n'
      'api_key_env: DEEPSEEK_API_KEY\n',
    );
    File(p.join(paths.modelsDir, 'deepseek__flash.yaml')).writeAsStringSync(
      'provider: deepseek\n'
      'model_id: flash\n'
      'name: Flash\n'
      'base_url: ""\n'
      'api_key: ""\n',
    );
    File(p.join(paths.modelsDir, 'deepseek__flash-pro.yaml')).writeAsStringSync(
      'provider: deepseek\n'
      'model_id: flash-pro\n'
      'base_url: https://proxy.example.com/v1\n'
      'api_key: sk-own\n',
    );

    final DomainSettings settings = loadDomainSettings(paths);
    expect(settings.providers().map((ProviderConfig p) => p.id), <String>[
      'deepseek',
    ]);
    final CoreModelConfig flash = settings.model('deepseek/flash')!;
    expect(flash.key, 'deepseek/flash');
    expect(flash.effectiveBaseUrl, 'https://api.deepseek.com');
    expect(flash.providerBaseUrl, 'https://api.deepseek.com');

    final CoreModelConfig pro = settings.model('flash-pro')!;
    expect(pro.effectiveBaseUrl, 'https://proxy.example.com/v1');
    expect(pro.effectiveApiKey, 'sk-own', reason: '模型级覆盖优先');

    // 改 provider 端点：内存里的模型立即跟着换。
    settings.updateProvider('deepseek', <String, dynamic>{
      'base_url': 'https://api.deepseek.com/v2',
    });
    expect(flash.effectiveBaseUrl, 'https://api.deepseek.com/v2');
    expect(pro.effectiveBaseUrl, 'https://proxy.example.com/v1');
  });

  test('旧文件归到 legacy：裸 id 可解析、同 id 跨 provider 歧义、精确键优先', () {
    File(p.join(paths.modelsDir, 'm1.yaml')).writeAsStringSync(
      'model_id: m1\nbase_url: https://old.example.com\napi_key: sk-old\n',
    );
    File(p.join(paths.modelsDir, 'a__m1.yaml')).writeAsStringSync(
      'provider: a\nmodel_id: m1\n',
    );

    final DomainSettings settings = loadDomainSettings(paths);
    final CoreModelConfig legacy = settings.model('legacy/m1')!;
    expect(legacy.provider, kLegacyProviderId);
    expect(legacy.storageFile, endsWith('m1.yaml'));
    expect(legacy.effectiveBaseUrl, 'https://old.example.com');

    // 裸 id 现在命中两个 provider：歧义，并且必须给出可选的完整键。
    final ModelResolution resolution = settings.resolveModel('m1');
    expect(resolution.found, isFalse);
    expect(resolution.ambiguous, isTrue);
    expect(resolution.candidates, <String>['a/m1', 'legacy/m1']);

    // 精确键仍直接命中（不会被裸 id 歧义带偏）。
    expect(settings.resolveModel('a/m1').model!.provider, 'a');
    expect(settings.resolveModel('legacy/m1').model!.provider, 'legacy');
  });

  test('新建模型：provider 下免填 base_url/api_key；未知 provider 拒绝；同键去重', () {
    final _RecordingSink sink = _RecordingSink();
    final DomainSettings settings = DomainSettings(sink: sink);

    expect(
      DomainSettings.validateNewModel(<String, dynamic>{
        'provider': 'deepseek',
        'model_id': 'flash',
      }),
      isNull,
      reason: 'provider 已提供端点与密钥',
    );
    expect(
      settings.createModel(<String, dynamic>{
        'provider': 'deepseek',
        'model_id': 'flash',
      }),
      isNull,
      reason: 'provider 不在池里',
    );

    settings.createProvider(<String, dynamic>{
      'name': 'DeepSeek',
      'base_url': 'https://api.deepseek.com',
      'api_key': 'sk-1',
    });
    final CoreModelConfig? model = settings.createModel(<String, dynamic>{
      'provider': 'deepseek',
      'model_id': 'flash',
      'name': 'Flash',
    });
    expect(model, isNotNull);
    expect(model!.key, 'deepseek/flash');
    expect(model.effectiveBaseUrl, 'https://api.deepseek.com');
    expect(model.effectiveApiKey, 'sk-1');
    expect(sink.saved.single.key, 'deepseek/flash');

    // 同 provider 同 model_id 冲突；显示名重复不冲突（STAB-PL-8）。
    expect(
      settings.createModel(<String, dynamic>{
        'provider': 'deepseek',
        'model_id': 'flash',
        'name': '别名',
      }),
      isNull,
    );
    expect(
      settings.createModel(<String, dynamic>{
        'provider': 'deepseek',
        'model_id': 'flash-2',
        'name': 'Flash',
      }),
      isNotNull,
    );
  });

  test('provider 删除：有模型绑定时拒绝；无绑定时落盘删除', () {
    final _RecordingSink sink = _RecordingSink();
    final DomainSettings settings = DomainSettings(sink: sink);
    settings.createProvider(<String, dynamic>{
      'name': 'A',
      'base_url': 'https://a.example.com',
      'api_key': 'k',
    });
    settings.createModel(<String, dynamic>{
      'provider': 'a',
      'model_id': 'm',
    });
    expect(settings.boundModelKeys('a'), <String>['a/m']);
    expect(settings.deleteProvider('a'), isFalse);

    settings.deleteModel('a/m');
    expect(settings.deleteProvider('a'), isTrue);
    expect(sink.deletedProviders, <String>['a']);
  });

  test('模型目录缓存：往返、坏 JSON 回 null、可删除', () {
    final ProviderModelCache cache = ProviderModelCache(
      providerId: 'deepseek',
      fetchedAt: '2026-11-12T00:00:00.000Z',
      models: <ProviderModelEntry>[
        const ProviderModelEntry(
          modelId: 'flash',
          name: 'Flash',
          contextLength: 131072,
          maxOutputTokens: 8192,
          inputModalities: <String>['text', 'image'],
          reasoningEffortOptions: <String>['low', 'high'],
        ),
      ],
    );
    writeProviderModelCache(paths, cache);
    final ProviderModelCache loaded = readProviderModelCache(
      paths,
      'deepseek',
    )!;
    expect(loaded.providerId, 'deepseek');
    expect(loaded.models.single.modelId, 'flash');
    expect(loaded.models.single.ifVision, isTrue);
    expect(loaded.models.single.reasoningEffortOptions, <String>['low', 'high']);

    File(paths.providerModelsFile('broken'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{{{');
    expect(readProviderModelCache(paths, 'broken'), isNull);

    removeProviderModelCache(paths, 'deepseek');
    expect(readProviderModelCache(paths, 'deepseek'), isNull);
  });

  test('目录条目解析：模态 / 思考档位 / 上下文 / 最大输出 / 类型推断', () {
    final ProviderModelEntry entry = parseProviderCatalogEntry(
      <String, Object?>{
        'id': 'deepseek-v4.1-flash',
        'name': 'DeepSeek V4.1 Flash',
        'context_length': 131072,
        'top_provider': <String, Object?>{'max_completion_tokens': 8192},
        'architecture': <String, Object?>{
          'input_modalities': <Object?>['text', 'image'],
          'output_modalities': <Object?>['text'],
        },
        'reasoning': <String, Object?>{
          'supported_efforts': <Object?>['low', 'high'],
        },
        'pricing': <String, Object?>{
          'prompt': '0.0000001',
          'completion': '0.0000002',
        },
      },
    );
    expect(entry.modelId, 'deepseek-v4.1-flash');
    expect(entry.name, 'DeepSeek V4.1 Flash');
    expect(entry.kind, 'chat');
    expect(entry.contextLength, 131072);
    expect(entry.maxOutputTokens, 8192);
    expect(entry.ifVision, isTrue);
    expect(entry.ifAudio, isFalse);
    expect(entry.reasoningEffortOptions, <String>['low', 'high']);
    expect(entry.pricing!.promptPerMillion, closeTo(0.1, 0.0001));

    final ProviderModelEntry embed = parseProviderCatalogEntry(
      <String, Object?>{
        'id': 'text-embedding-3-large',
        'capabilities': <String, Object?>{'vision': true},
        'modality': 'text->text',
        'max_output_tokens': 1000,
      },
    );
    expect(embed.kind, 'embedding');
    expect(embed.ifVision, isTrue);
    expect(embed.maxOutputTokens, 1000);
    expect(embed.reasoningEffortOptions, isEmpty, reason: '端点没声明就不猜');
    expect(embed.pricing, isNull);
  });

  test('缓存文件是可直接手改的 JSON', () {
    writeProviderModelCache(
      paths,
      ProviderModelCache(
        providerId: 'p',
        fetchedAt: 't',
        models: <ProviderModelEntry>[
          const ProviderModelEntry(modelId: 'm', inputModalities: <String>['text']),
        ],
      ),
    );
    final Map<String, dynamic> json =
        jsonDecode(File(paths.providerModelsFile('p')).readAsStringSync())
            as Map<String, dynamic>;
    expect(json['provider_id'], 'p');
    expect((json['models'] as List<dynamic>).single['model_id'], 'm');
  });
}

class _RecordingSink implements DomainSettingsSink {
  final List<CoreModelConfig> saved = <CoreModelConfig>[];
  final List<ProviderConfig> savedProviders = <ProviderConfig>[];
  final List<String> deletedProviders = <String>[];

  @override
  void saveModel(CoreModelConfig model) => saved.add(model);

  @override
  void deleteModel(CoreModelConfig model) {}

  @override
  void saveProvider(ProviderConfig provider) => savedProviders.add(provider);

  @override
  void deleteProvider(String providerId) => deletedProviders.add(providerId);

  @override
  void saveTokenRate(int rate) {}
}
