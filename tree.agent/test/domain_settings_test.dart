import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_agent_loop/src/model_catalog.dart';
import 'package:tree_agent_loop/src/paths.dart';
import 'package:tree_agent_loop/src/settings/domain_settings.dart';
import 'package:tree_agent_loop/src/settings/provider_settings.dart';

/// 领域设置的独立自检（A3 从核心 `CoreSettings` 拆出的模型池半边）。
void main() {
  late Directory temp;
  late AgentDataPaths paths;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_agent_settings_');
    paths = AgentDataPaths(temp.path);
    Directory(paths.modelsDir).createSync(recursive: true);
    File(p.join(paths.modelsDir, 'm1.yaml')).writeAsStringSync(
      'model_id: m1\n'
      'name: 模型一\n'
      'base_url: https://api.example.com/v1\n'
      'api_key: sk-secret\n'
      'thinking: true\n'
      'reasoning_effort: high\n'
      'reasoning_effort_options: [low, high]\n'
      'max_seqlen: 64000\n'
      'max_output_tokens: 8192\n'
      'token_scale: 2.5\n'
      'longest_session_tokens: 12000\n',
    );
    File(p.join(paths.modelsDir, 'm2.yaml')).writeAsStringSync(
      'model_id: m2\n'
      'base_url: http://127.0.0.1:8080/\n',
    );
    File(p.join(paths.modelsDir, 'broken.yaml')).writeAsStringSync('{{{');
  });

  tearDown(() {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('装载：含密钥配置、脱敏前端视图、排序、坏文件跳过、与 readModels 同源', () {
    final DomainSettings settings = loadDomainSettings(paths);
    expect(settings.models().map((CoreModelConfig m) => m.modelId), <String>[
      'm1',
      'm2',
    ]);
    final CoreModelConfig m1 = settings.model('m1')!;
    expect(m1.apiKey, 'sk-secret');
    expect(m1.baseUrl, 'https://api.example.com/v1');
    expect(m1.reasoningEffortOptions, <String>['low', 'high']);
    expect(m1.tokenScale, 2.5);
    expect(m1.toApiJson()['base_url'], 'https://api.example.com');
    expect(m1.toApiJson().containsKey('api_key'), isFalse);
    expect(m1.toApiJson()['has_api_key'], isTrue);

    final CoreModelConfig m2 = settings.model('m2')!;
    expect(m2.reasoningEffortOptions, <String>['low', 'high', 'max']);
    expect(m2.tokenScale, kDefaultTokenScale);
    expect(m2.effectiveMaxSeqlen, kFallbackMaxSeqlen);
    expect(m2.toApiJson()['base_url'], 'http://127.0.0.1:8080');
    expect(m2.toApiJson()['has_api_key'], isFalse);

    // 单一来源：A2 的只读视图必须与领域设置逐条一致。
    expect(readModels(paths), <Map<String, dynamic>>[
      for (final CoreModelConfig model in settings.models()) model.toApiJson(),
    ]);
  });

  test('成员覆盖：只覆盖非空项，返回副本且学习状态一起带走', () {
    final DomainSettings settings = loadDomainSettings(paths);
    final CoreModelConfig m1 = settings.model('m1')!;
    final CoreModelConfig overridden = m1.withOverrides(<String, Object?>{
      'reasoning_effort': 'max',
      'max_seqlen': 32000,
      'thinking': false,
    });
    expect(overridden.reasoningEffort, 'max');
    expect(overridden.maxSeqlen, 32000);
    expect(overridden.thinking, isFalse);
    expect(overridden.tokenScale, m1.tokenScale);
    expect(overridden.longestSessionTokens, m1.longestSessionTokens);
    // 原对象不变。
    expect(m1.reasoningEffort, 'high');
    expect(m1.maxSeqlen, 64000);
  });

  test('token_scale 学习：只采纳更长上下文、区间外拒绝、回调可落盘', () {
    final DomainSettings settings = loadDomainSettings(paths);
    final CoreModelConfig m1 = settings.model('m1')!;
    // 夹具里带 longest_session_tokens: 12000；学习用例先清零，单独验证水位线逻辑。
    m1.longestSessionTokens = 0;
    int saved = 0;
    settings.sink = _RecordingSink(onSave: () => saved++);

    expect(m1.learnTokenScale(contextChars: 3000, promptTokens: 1000), isTrue);
    expect(m1.tokenScale, 3.0);
    expect(m1.longestSessionTokens, 1000);
    expect(saved, 1);

    // 更短的请求不改水位线。
    expect(m1.learnTokenScale(contextChars: 2500, promptTokens: 900), isFalse);
    expect(m1.tokenScale, 3.0);

    // 更长但比例越界（> 20）：拒绝，且不刷新水位线。
    expect(
      m1.learnTokenScale(contextChars: 50000, promptTokens: 2000),
      isFalse,
    );
    expect(m1.longestSessionTokens, 1000);

    // 更长且合法：刷新。
    expect(m1.learnTokenScale(contextChars: 5000, promptTokens: 2000), isTrue);
    expect(m1.tokenScale, 2.5);
    expect(saved, 2);
  });

  test('token 速率：读 agent_settings.yaml 优先，缺失回退旧键并镜像新文件', () {
    // 只有旧键（L-22 迁移前形态）：读到 250，并当场原子写 agent_settings.yaml。
    File(p.join(paths.root, 'config', 'settings.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('token_acquisition_rate: 250\nframe_rate: 60\n');
    expect(loadDomainSettings(paths).tokenAcquisitionRate, 250);
    final File agentFile = File(paths.agentSettingsFile);
    expect(agentFile.existsSync(), isTrue);
    expect(
      agentFile.readAsStringSync(),
      contains('token_acquisition_rate: 250'),
    );
    // 平台文件不被插件改写（帧率等键原样）。
    expect(
      File(p.join(paths.root, 'config', 'settings.yaml')).readAsStringSync(),
      contains('frame_rate: 60'),
    );

    // 新文件已存在 ⇒ 不再读旧键（即使旧键被手改成别的值）。
    File(p.join(paths.root, 'config', 'settings.yaml'))
        .writeAsStringSync('token_acquisition_rate: 900\n');
    agentFile.writeAsStringSync('token_acquisition_rate: 300\n');
    expect(loadDomainSettings(paths).tokenAcquisitionRate, 300);

    final DomainSettings settings = DomainSettings();
    expect(settings.tokenAcquisitionRate, DomainSettings.tokenRateMax);
    expect(settings.setTokenAcquisitionRate(1), 20);
    expect(settings.setTokenAcquisitionRate(99999), 1000);
    expect(settings.setTokenAcquisitionRate(200), 200);
  });

  test('新增校验与模型池写接口（sink 记录调用）', () {
    expect(
      DomainSettings.validateNewModel(<String, dynamic>{}),
      'model_id 不能为空',
    );
    expect(
      DomainSettings.validateNewModel(<String, dynamic>{'model_id': 'x'}),
      'base_url 不能为空',
    );
    expect(
      DomainSettings.validateNewModel(<String, dynamic>{
        'model_id': 'x',
        'base_url': 'https://x',
        'api_key': 'k',
      }),
      isNull,
    );

    final _RecordingSink sink = _RecordingSink();
    final DomainSettings settings = DomainSettings(sink: sink);
    final CoreModelConfig? created = settings.createModel(<String, dynamic>{
      'model_id': 'm3',
      'base_url': 'https://api.example.com',
      'api_key': 'sk-3',
    });
    expect(created, isNotNull);
    expect(sink.saved.map((CoreModelConfig m) => m.modelId), <String>['m3']);
    expect(settings.createModel(<String, dynamic>{'model_id': 'm3'}), isNull);
    expect(settings.updateModel('nope', <String, dynamic>{}), isNull);
    expect(settings.deleteModel('m3'), isTrue);
    expect(sink.deleted, <String>['m3']);
  });

  test('MP-2：存量未知 kind/protocol 的 PATCH 拒绝；同值 kind 放行', () {
    final CoreModelConfig weird = CoreModelConfig(
      modelId: 'w',
      kind: 'weird',
      baseUrl: 'https://x',
    );
    expect(
      DomainSettings.validateModelChange(weird, <String, dynamic>{'name': 'x'}),
      contains('模型类型未知'),
    );
    final CoreModelConfig chat = CoreModelConfig(
      modelId: 'c',
      baseUrl: 'https://x',
      apiKey: 'k',
    );
    expect(
      DomainSettings.validateModelChange(chat, <String, dynamic>{
        'kind': 'chat',
        'name': '改名',
      }),
      isNull,
      reason: '同值 kind 不视为修改',
    );
  });

  test('MP-1：旧 YAML 无 kind ⇒ chat/openai，文件不被改写、toJson 不多键', () {
    final File m1 = File(p.join(paths.modelsDir, 'm1.yaml'));
    final String before = m1.readAsStringSync();
    File(p.join(paths.modelsDir, 'emb.yaml')).writeAsStringSync(
      'model_id: emb\n'
      'kind: embedding\n'
      'dimensions: 1024\n'
      'max_input_tokens: 8192\n'
      'base_url: https://api.example.com/v1\n',
    );
    File(p.join(paths.modelsDir, 'jev.yaml')).writeAsStringSync(
      'model_id: jev\n'
      'kind: decision\n'
      'confidence_threshold: 0.7\n'
      'base_url: https://api.jev.example/v1\n',
    );

    final DomainSettings settings = loadDomainSettings(paths);
    final CoreModelConfig old = settings.model('m1')!;
    expect(old.kind, kModelKindChat);
    expect(old.protocol, kModelProtocolOpenai);
    expect(old.toJson().containsKey('kind'), isFalse);
    expect(old.toJson().containsKey('protocol'), isFalse);
    expect(old.toApiJson()['kind'], kModelKindChat);
    expect(old.toApiJson()['protocol'], kModelProtocolOpenai);
    expect(old.toApiJson()['dimensions'], isNull);
    expect(old.toApiJson()['max_input_tokens'], isNull);
    expect(old.toApiJson()['confidence_threshold'], isNull);
    // 装载只读：旧文件逐字节不变。
    expect(m1.readAsStringSync(), before);

    final CoreModelConfig emb = settings.model('emb')!;
    expect(emb.kind, kModelKindEmbedding);
    expect(emb.protocol, kModelProtocolOpenai, reason: 'embedding 缺省 openai');
    expect(emb.dimensions, 1024);
    expect(emb.maxInputTokens, 8192);
    expect(emb.toJson()['kind'], kModelKindEmbedding);
    expect(emb.toJson()['dimensions'], 1024);
    expect(emb.toJson().containsKey('protocol'), isFalse, reason: '协议=缺省时不写');

    final CoreModelConfig jev = settings.model('jev')!;
    expect(jev.kind, kModelKindDecision);
    expect(jev.protocol, kModelProtocolJev, reason: 'decision 缺省 jev');
    expect(jev.confidenceThreshold, 0.7);
    expect(jev.toJson()['kind'], kModelKindDecision);
    expect(jev.toJson()['confidence_threshold'], 0.7);
    expect(jev.toJson().containsKey('protocol'), isFalse, reason: '协议=缺省时不写');
  });

  test('TC-MP-13：成员级覆盖不丢 kind/protocol/维度/阈值', () {
    final CoreModelConfig embedding = CoreModelConfig(
      modelId: 'emb',
      kind: kModelKindEmbedding,
      dimensions: 1024,
      maxInputTokens: 8192,
    );
    final CoreModelConfig overridden = embedding.withOverrides(
      <String, Object?>{'max_seqlen': 32000, 'thinking': true},
    );
    expect(overridden.kind, kModelKindEmbedding);
    expect(overridden.protocol, kModelProtocolOpenai);
    expect(overridden.dimensions, 1024);
    expect(overridden.maxInputTokens, 8192);

    final CoreModelConfig decision = CoreModelConfig(
      modelId: 'jev',
      kind: kModelKindDecision,
      confidenceThreshold: 0.7,
    );
    expect(decision.protocol, kModelProtocolJev);
    final CoreModelConfig decisionCopy = decision.withOverrides(
      <String, Object?>{'reasoning_effort': 'max'},
    );
    expect(decisionCopy.kind, kModelKindDecision);
    expect(decisionCopy.protocol, kModelProtocolJev);
    expect(decisionCopy.confidenceThreshold, 0.7);
  });

  test('MP-1：新建三类模型按 kind 推导协议并落盘', () {
    final _RecordingSink sink = _RecordingSink();
    final DomainSettings settings = DomainSettings(sink: sink);
    final CoreModelConfig? embedding = settings.createModel(<String, dynamic>{
      'model_id': 'emb',
      'base_url': 'https://api.example.com',
      'api_key': 'sk-emb',
      'kind': 'embedding',
      'dimensions': 1024,
    });
    expect(embedding!.kind, kModelKindEmbedding);
    expect(embedding.protocol, kModelProtocolOpenai);
    expect(sink.saved.last.toJson()['kind'], kModelKindEmbedding);
    expect(sink.saved.last.toJson()['dimensions'], 1024);

    final CoreModelConfig? decision = settings.createModel(<String, dynamic>{
      'model_id': 'jev',
      'base_url': 'https://api.jev.example',
      'api_key': 'sk-jev',
      'kind': 'decision',
      'confidence_threshold': 0.7,
    });
    expect(decision!.protocol, kModelProtocolJev, reason: 'kind 驱动协议默认值');
    expect(sink.saved.last.toJson()['kind'], kModelKindDecision);
    expect(sink.saved.last.toJson()['confidence_threshold'], 0.7);
    expect(sink.saved.last.toApiJson().containsKey('api_key'), isFalse);
  });

  test('MP-2：kind/protocol 组合、类型必填项与不可改', () {
    String? validate(Map<String, dynamic> payload) =>
        DomainSettings.validateModelKindFields(payload);

    expect(validate(<String, dynamic>{'kind': 'nope'}), contains('未知模型类型'));
    expect(
      validate(<String, dynamic>{'kind': 'chat', 'protocol': 'jev'}),
      'kind=chat 只能使用 protocol=openai（收到 jev）',
    );
    expect(
      validate(<String, dynamic>{'kind': 'decision', 'protocol': 'jev'}),
      contains('confidence_threshold'),
    );
    expect(
      validate(<String, dynamic>{'kind': 'embedding'}),
      'embedding 模型必须配置 dimensions（>0）',
    );
    expect(
      validate(<String, dynamic>{'kind': 'embedding', 'dimensions': 1024}),
      isNull,
    );
    expect(
      validate(<String, dynamic>{
        'kind': 'decision',
        'confidence_threshold': 0.7,
      }),
      isNull,
    );
    expect(
      validate(<String, dynamic>{'kind': 'chat', 'dimensions': 'x'}),
      'dimensions 必须是整数',
    );
    expect(
      validate(<String, dynamic>{
        'kind': 'decision',
        'confidence_threshold': 1.5,
      }),
      'confidence_threshold 必须是 (0,1) 之间的数',
    );

    final CoreModelConfig embedding = CoreModelConfig(
      modelId: 'emb',
      kind: kModelKindEmbedding,
      dimensions: 1024,
      baseUrl: 'https://x/v1',
      apiKey: 'k',
    );
    expect(
      DomainSettings.validateModelChange(embedding, <String, dynamic>{
        'kind': 'chat',
      }),
      'kind 创建后不可修改（当前 embedding）',
    );
    expect(
      DomainSettings.validateModelChange(embedding, <String, dynamic>{
        'protocol': 'jev',
      }),
      'protocol 创建后不可修改（当前 openai）',
    );
    expect(
      DomainSettings.validateModelChange(embedding, <String, dynamic>{
        'dimensions': 0,
      }),
      'embedding 模型必须配置 dimensions（>0）',
    );
    expect(
      DomainSettings.validateModelChange(embedding, <String, dynamic>{
        'dimensions': 512,
      }),
      isNull,
    );

    expect(
      DomainSettings.modelKindError(
        CoreModelConfig(modelId: 'c', baseUrl: 'x', apiKey: 'k'),
      ),
      isNull,
    );
    expect(
      DomainSettings.modelKindError(embedding),
      '该模型是 embedding，不能作为对话模型（需要 kind=chat）',
    );
  });
}

class _RecordingSink implements DomainSettingsSink {
  _RecordingSink({this.onSave});

  final void Function()? onSave;
  final List<CoreModelConfig> saved = <CoreModelConfig>[];
  final List<String> deleted = <String>[];
  final List<ProviderConfig> savedProviders = <ProviderConfig>[];
  final List<String> deletedProviders = <String>[];
  final List<int> tokenRates = <int>[];

  @override
  void saveModel(CoreModelConfig model) {
    saved.add(model);
    onSave?.call();
  }

  @override
  void deleteModel(CoreModelConfig model) => deleted.add(model.key);

  @override
  void saveProvider(ProviderConfig provider) => savedProviders.add(provider);

  @override
  void deleteProvider(String providerId) => deletedProviders.add(providerId);

  @override
  void saveTokenRate(int rate) => tokenRates.add(rate);
}
