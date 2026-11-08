/// tree.docnorm 插件的领域库：
/// - 仓库扫描 + 六族语言适配层（DN-2）；
/// - 文档契约侦查 + 三层规则源 + DocPolicy 检查（DN-3）；
/// - 基线 / 重算 + `doc_state` + git 指纹（DN-6）；
/// - 变更归集与注入计划 + 两额度估计（DN-4）；
/// - 缺章节生成提案（DN-5，只读、严格 JSON 校验）；
/// - 包功能收束与四类建议（DN-7，确定性、无 LLM）。
library;

export 'src/audit.dart';
export 'src/baseline.dart';
export 'src/contract.dart';
export 'src/generate.dart';
export 'src/plan.dart';
export 'src/policy.dart';
export 'src/scan.dart';
export 'src/summary.dart';
