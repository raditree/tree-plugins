import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_agent_loop/src/compat/protocol_types.dart';
import 'package:tree_agent_loop/src/paths.dart';
import 'package:tree_agent_loop/src/settings/core_settings.dart';
import 'package:tree_agent_loop/src/settings/domain_settings.dart';

/// 插件侧设置门面与协议兼容常量。
void main() {
  late Directory temp;
  late AgentDataPaths paths;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_agent_core_settings_');
    paths = AgentDataPaths(temp.path);
    Directory(paths.modelsDir).createSync(recursive: true);
    File(p.join(paths.modelsDir, 'm1.yaml')).writeAsStringSync(
      'model_id: m1\nbase_url: https://api.example.com\napi_key: k\ntoken_scale: 3.5\n',
    );
    File(p.join(paths.root, 'config', 'settings.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('frame_rate: 60\ntoken_acquisition_rate: 300\n');
  });

  tearDown(() {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('CoreSettings.load：模型池 / token 速率 / 帧率都从同一份数据根读', () {
    final CoreSettings settings = CoreSettings.load(paths);
    expect(settings.model('m1')?.tokenScale, 3.5);
    expect(settings.models().single.modelId, 'm1');
    expect(settings.tokenAcquisitionRate, 300);
    expect(settings.frameRate, 60);
    expect(CoreSettings.fallbackMaxSeqlen, 128000);
  });

  test('缺省与夹取：帧率 1~120、token 速率 20~1000', () {
    final CoreSettings defaults = CoreSettings();
    expect(defaults.frameRate, CoreSettings.defaultFrameRate);
    expect(
      defaults.tokenAcquisitionRate,
      DomainSettings.tokenRateMax,
    );
    defaults.frameRate = 0;
    expect(defaults.frameRate, CoreSettings.minFrameRate);
    defaults.frameRate = 9999;
    expect(defaults.frameRate, CoreSettings.maxFrameRate);
    expect(defaults.setTokenAcquisitionRate(1), 20);
  });

  test('WsStreamSeq.of：只认非负 int，缺字段/字符串/负数一律未知', () {
    expect(WsStreamSeq.field, 'seq');
    expect(WsStreamSeq.firstSeq, 0);
    expect(WsStreamSeq.of(<String, dynamic>{'seq': 3}), 3);
    expect(WsStreamSeq.of(<String, dynamic>{'seq': 0}), 0);
    expect(WsStreamSeq.of(<String, dynamic>{}), isNull);
    expect(WsStreamSeq.of(<String, dynamic>{'seq': '3'}), isNull);
    expect(WsStreamSeq.of(<String, dynamic>{'seq': -1}), isNull);
    expect(WsStreamSeq.of(<String, dynamic>{'seq': 3.5}), isNull);
  });
}
