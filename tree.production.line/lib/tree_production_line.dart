/// tree.production.line 的领域库：P1 数据模型 / 队列 / 存储 / 命令门面，
/// P3 准备阶段领域与命令门面，P4 打包 / 执行 / 门控，P5 专家工具，
/// P6 项目整理（只读审计报告），P8 并行派发与预算软停。
library;

export 'src/api.dart';
export 'src/audit.dart';
export 'src/audit_service.dart';
export 'src/budget.dart';
export 'src/code_chunk.dart';
export 'src/code_git.dart';
export 'src/dedup.dart';
export 'src/dedup_config.dart';
export 'src/dedup_service.dart';
export 'src/dedup_store.dart';
export 'src/drift.dart';
export 'src/drift_service.dart';
export 'src/expert.dart';
export 'src/execution.dart';
export 'src/execution_service.dart';
export 'src/events.dart';
export 'src/gate_runner.dart';
export 'src/lease.dart';
export 'src/memory_port.dart';
export 'src/models.dart';
export 'src/normalization.dart';
export 'src/normalization_service.dart';
export 'src/orchestrator.dart';
export 'src/orchestrator_service.dart';
export 'src/plan_document.dart';
export 'src/planner.dart';
export 'src/preparation.dart';
export 'src/preparation_service.dart';
export 'src/queue.dart';
export 'src/readiness.dart';
export 'src/readiness_service.dart';
export 'src/service.dart';
export 'src/stability.dart';
export 'src/store.dart';
export 'src/structure.dart';
export 'src/structure_service.dart';
export 'src/task_input.dart';
export 'src/yaml_codec.dart';
