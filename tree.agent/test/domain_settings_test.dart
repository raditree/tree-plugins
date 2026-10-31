import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_agent_loop/src/model_catalog.dart';
import 'package:tree_agent_loop/src/paths.dart';
import 'package:tree_agent_loop/src/settings/domain_settings.dart';

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

    final CoreModelConfig m2 = settings.model('m2')!;
    expect(m2.reasoningEffortOptions, <String>['low', 'high', 'max']);
    expect(m2.tokenScale, kDefaultTokenScale);
    expect(m2.effectiveMaxSeqlen, kFallbackMaxSeqlen);
    expect(m2.toApiJson()['base_url'], 'http://127.0.0.1:8080');

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

    expect(
      m1.learnTokenScale(contextChars: 3000, promptTokens: 1000),
      isTrue,
    );
    expect(m1.tokenScale, 3.0);
    expect(m1.longestSessionTokens, 1000);
    expect(saved, 1);

    // 更短的请求不改水位线。
    expect(
      m1.learnTokenScale(contextChars: 2500, promptTokens: 900),
      isFalse,
    );
    expect(m1.tokenScale, 3.0);

    // 更长但比例越界（> 20）：拒绝，且不刷新水位线。
    expect(
      m1.learnTokenScale(contextChars: 50000, promptTokens: 2000),
      isFalse,
    );
    expect(m1.longestSessionTokens, 1000);

    // 更长且合法：刷新。
    expect(
      m1.learnTokenScale(contextChars: 5000, promptTokens: 2000),
      isTrue,
    );
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
    expect(agentFile.readAsStringSync(), contains('token_acquisition_rate: 250'));
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
}

class _RecordingSink implements DomainSettingsSink {
  _RecordingSink({this.onSave});

  final void Function()? onSave;
  final List<CoreModelConfig> saved = <CoreModelConfig>[];
  final List<String> deleted = <String>[];
  final List<int> tokenRates = <int>[];

  @override
  void saveModel(CoreModelConfig model) {
    saved.add(model);
    onSave?.call();
  }

  @override
  void deleteModel(String modelId) => deleted.add(modelId);

  @override
  void saveTokenRate(int rate) => tokenRates.add(rate);
}
