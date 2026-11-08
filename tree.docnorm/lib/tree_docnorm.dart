/// tree.docnorm 插件的领域库：
/// - 仓库扫描 + 六族语言适配层（DN-2）；
/// - 文档契约侦查 + 三层规则源 + DocPolicy 检查（DN-3）；
/// - 基线 / 重算 + `doc_state` + git 指纹（DN-6）；
/// - 变更归集与注入计划 + 两额度估计（DN-4）。
library;

export 'src/baseline.dart';
export 'src/contract.dart';
export 'src/plan.dart';
export 'src/policy.dart';
export 'src/scan.dart';
