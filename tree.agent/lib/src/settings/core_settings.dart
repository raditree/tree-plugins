import 'dart:io';

import 'package:path/path.dart' as p;

import '../paths.dart';
import '../yaml_utils.dart';
import 'domain_settings.dart';

/// 插件侧的 `CoreSettings` **兼容门面**（A3 生成循环专用）。
///
/// 核心的 `CoreSettings` 混装平台开关与领域配置；插件只保留生成循环真正用到的部分，
/// 其余走默认值：
/// - 领域：模型池 / token 速率（委托 [DomainSettings]）；
/// - 平台：帧率 `frame_rate`（默认 25，与核心同一份 settings.yaml）。
///
/// 名字保留 `CoreSettings` 是为了让从核心平移的 `conversation_service` /
/// `compaction_service` 可以原样 import；**不要**再把平台开关加回这里。
class CoreSettings {
  CoreSettings({DomainSettings? domain, int? frameRate})
    : domain = domain ?? DomainSettings(),
      _frameRate = _clampFrameRate(frameRate ?? defaultFrameRate);

  /// 默认帧率（与核心 `CoreSettings.defaultFrameRate` 同值）。
  static const int defaultFrameRate = 25;

  /// 帧率可接受区间（与核心一致）。
  static const int minFrameRate = 1;
  static const int maxFrameRate = 120;

  /// 模型没配 `max_seqlen` 时的保守兜底（与核心同值）。
  static const int fallbackMaxSeqlen = kFallbackMaxSeqlen;

  /// 领域半边（模型池 / token 速率）。
  final DomainSettings domain;

  int _frameRate;

  /// 从数据根装载（模型池 + token 速率 + frame_rate）。
  factory CoreSettings.load(AgentDataPaths paths) {
    final DomainSettings domain = loadDomainSettings(paths);
    final Map<String, dynamic>? settingsYaml = readYamlMap(
      File(p.join(paths.root, 'config', 'settings.yaml')),
    );
    final Object? rawFrameRate = settingsYaml?['frame_rate'];
    int? frameRate;
    if (rawFrameRate is num) {
      frameRate = rawFrameRate.toInt();
    } else if (rawFrameRate is String) {
      frameRate = int.tryParse(rawFrameRate.trim());
    }
    return CoreSettings(domain: domain, frameRate: frameRate);
  }

  /// 模型配置（含密钥；不存在返回 null）。
  CoreModelConfig? model(String modelId) => domain.model(modelId);

  /// 模型列表（按 model_id 升序）。
  List<CoreModelConfig> models() => domain.models();

  /// 直接放入模型（装载 / 测试夹具用；不触发落盘）。
  void putModel(CoreModelConfig model) => domain.putModel(model);

  /// 新建模型（model_id 已存在 ⇒ null）。
  CoreModelConfig? createModel(Map<String, dynamic> payload) =>
      domain.createModel(payload);

  /// 更新模型（不存在 ⇒ null）。
  CoreModelConfig? updateModel(String modelId, Map<String, dynamic> payload) =>
      domain.updateModel(modelId, payload);

  /// 删除模型（返回是否真的删除）。
  bool deleteModel(String modelId) => domain.deleteModel(modelId);

  /// token 获取速率（20~1000）。
  int get tokenAcquisitionRate => domain.tokenAcquisitionRate;

  /// 改 token 速率（内存；落盘随设置写端点接入）。
  int setTokenAcquisitionRate(int value) =>
      domain.setTokenAcquisitionRate(value);

  /// 推送帧率（1~120）。
  int get frameRate => _frameRate;

  set frameRate(int value) => _frameRate = _clampFrameRate(value);

  static int _clampFrameRate(int value) => value < minFrameRate
      ? minFrameRate
      : (value > maxFrameRate ? maxFrameRate : value);
}
