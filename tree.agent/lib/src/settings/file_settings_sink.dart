import 'dart:io';

import '../paths.dart';
import '../store/atomic_file.dart';
import '../store/write_queue.dart';
import '../store/yaml_codec.dart';
import 'domain_settings.dart';
import 'provider_settings.dart';

/// 领域设置落盘（provider 池 + 模型池 + token 速率）。
///
/// - `config/providers/<id>.yaml`：provider（含明文 api_key）；
/// - `config/models/*.yaml`：与核心 `FileSettingsSink` 同格式（含明文 api_key，
///   文件头说明也一致）；旧模型写回原文件，新模型写 `<provider>__<model>.yaml`；
/// - `config/agent_settings.yaml`：**只更新 token_acquisition_rate**，其余键（含核心平台
///   设置）原样保留——插件不接管平台设置，不能把别人的键写丢。
class FileDomainSettingsSink implements DomainSettingsSink {
  FileDomainSettingsSink(this.paths, {this.log});

  final AgentDataPaths paths;

  final void Function(String message)? log;

  final WriteQueue _queue = WriteQueue();

  static const String _modelHeader = 'Tree 模型配置：api_key 为明文，请勿外传。';
  static const String _providerHeader = 'Tree Provider 配置：api_key 为明文，请勿外传。';
  static const String _settingsHeader = 'Tree 领域设置（tree.agent）：可直接手改。';

  /// 模型落盘路径：装载过的旧模型沿用原文件，新建模型按 `provider__model` 命名。
  String modelPathOf(CoreModelConfig model) {
    if (model.storageFile.isNotEmpty) return model.storageFile;
    final String path = paths.modelFileFor(
      provider: model.provider,
      modelId: model.modelId,
    );
    model.storageFile = path;
    return path;
  }

  @override
  void saveModel(CoreModelConfig model) {
    final String file = modelPathOf(model);
    final String content = YamlCodec.encode(
      model.toJson(),
      header: _modelHeader,
    );
    _queue.enqueue(file, () => AtomicFile.writeStringAtomic(file, content));
  }

  @override
  void deleteModel(CoreModelConfig model) {
    final String file = modelPathOf(model);
    _queue.enqueue(file, () async {
      if (await File(file).exists()) await File(file).delete();
    });
  }

  @override
  void saveProvider(ProviderConfig provider) {
    final String file = paths.providerFile(provider.id);
    final String content = YamlCodec.encode(
      provider.toJson(),
      header: _providerHeader,
    );
    _queue.enqueue(file, () => AtomicFile.writeStringAtomic(file, content));
  }

  @override
  void deleteProvider(String providerId) {
    final String file = paths.providerFile(providerId);
    _queue.enqueue(file, () async {
      if (await File(file).exists()) await File(file).delete();
    });
  }

  @override
  void saveTokenRate(int rate) {
    // L-22 乙方案：领域键落 `config/agent_settings.yaml`（**不再**改写平台
    // settings.yaml，否则会与核心的全量重写互相覆盖）。
    final String file = paths.agentSettingsFile;
    final String? current = AtomicFile.readStringOrNullSync(file);
    Map<String, dynamic> map = <String, dynamic>{};
    if (current != null && current.trim().isNotEmpty) {
      try {
        map = Map<String, dynamic>.of(YamlCodec.decode(current));
      } catch (error) {
        log?.call('agent_settings.yaml 解析失败，token 速率将覆盖写入：$file：$error');
        map = <String, dynamic>{};
      }
    }
    map['token_acquisition_rate'] = rate;
    final String content = YamlCodec.encode(map, header: _settingsHeader);
    _queue.enqueue(file, () => AtomicFile.writeStringAtomic(file, content));
  }

  /// 等落盘完成（写端点调用后用它保证随后的读取能看到新文件）。
  Future<void> flush() => _queue.flush();
}
