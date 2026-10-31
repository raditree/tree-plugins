import 'dart:io';

import '../store/atomic_file.dart';
import '../store/tree_paths.dart';
import '../store/write_queue.dart';
import '../store/yaml_codec.dart';
import 'domain_settings.dart';

/// 领域设置落盘（模型池 + token 速率）。
///
/// - `config/models/<id>.yaml`：与核心 `FileSettingsSink` 同格式（含明文 api_key，
///   文件头说明也一致）；
/// - `config/settings.yaml`：**只更新 token_acquisition_rate**，其余键（含核心平台
///   设置）原样保留——插件不接管平台设置，不能把别人的键写丢。
class FileDomainSettingsSink implements DomainSettingsSink {
  FileDomainSettingsSink(this.paths, {this.log});

  final TreePaths paths;

  final void Function(String message)? log;

  final WriteQueue _queue = WriteQueue();

  static const String _modelHeader = 'Tree 模型配置：api_key 为明文，请勿外传。';
  static const String _settingsHeader = 'Tree 领域设置（tree.agent）：可直接手改。';

  @override
  void saveModel(CoreModelConfig model) {
    final String file = paths.modelFile(model.modelId);
    final String content = YamlCodec.encode(
      model.toJson(),
      header: _modelHeader,
    );
    _queue.enqueue(file, () => AtomicFile.writeStringAtomic(file, content));
  }

  @override
  void deleteModel(String modelId) {
    final String file = paths.modelFile(modelId);
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
