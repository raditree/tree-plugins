import 'service.dart';

/// 处理一次 `api/delegate`（核心 → 插件）。
///
/// 信封字段与 tree.agent 同契约：`method / path / params / query / headers /
/// scope / workspace_dir / data_dir / agent_id / team_id / request_id`，
/// 小体积 JSON 用 `body`，大体积（例如 4 MiB 上传分片）用 `body_path`。
/// 回包固定为 `{status, headers?, body? | result_path?}`，body 是字符串。
Future<Map<String, dynamic>> handleApiDelegate(
  Map<String, dynamic> envelope, {
  required FilesService service,
}) => service.handleDelegate(envelope);
