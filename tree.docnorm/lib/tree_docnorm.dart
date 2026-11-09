/// tree.docnorm 插件的领域库：
/// - 仓库扫描 + 六族语言适配层（DN-2）；
/// - 文档契约侦查 + 三层规则源 + DocPolicy 检查（DN-3）；
/// - 基线 / 重算 + `doc_state` + git 指纹（DN-6）；
/// - 变更归集与注入计划 + 两额度估计（DN-4）；
/// - 缺章节生成提案（DN-5，只读、严格 JSON 校验）；
/// - 包功能收束与四类建议（DN-7，确定性、无 LLM）；
/// - 分批提交与基础链接图（DN-8，门禁默认只列、三类确定性边）；
/// - GraphRAG 索引与 JSONL 快照导出（DN-9，分块/抽取/Leiden/报告/向量）。
library;

export 'src/audit.dart';
export 'src/baseline.dart';
export 'src/chunk.dart';
export 'src/commit.dart';
export 'src/contract.dart';
export 'src/export.dart';
export 'src/generate.dart';
export 'src/graph.dart';
export 'src/plan.dart';
export 'src/policy.dart';
export 'src/rag.dart';
export 'src/scan.dart';
export 'src/summary.dart';
