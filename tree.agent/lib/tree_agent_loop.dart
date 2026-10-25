/// tree.agent 的领域库（插件仓内包，包名 `tree_agent_loop`）。
///
/// **依赖纪律**（agent_pluginization.md 不变量 1/13）：本包只允许 pub.dev 依赖与
/// 插件仓自带的 `_kit`，**不得 import tree_core / tree_protocol**。复用核心能力
/// 只能走核心的平台内置站（日志 / 存储 / 租约）或其它插件的自建执行站。
///
/// A1 骨架已上线；A2 正在按 `docs/pluginization/agent_api_contract.md`
/// 把 tree_core 的 `agent/`、`llm/`、`team/`、`tool/` 平移进 `lib/src/`
/// （只改 import 与依赖注入）。第一批只读路由见 `src/delegate.dart`。
library;

import 'src/delegate.dart'
    show
        agentDetailPattern,
        agentModelsInfoPattern,
        agentsPattern,
        cancelPattern,
        conversationsPattern,
        messagesPattern,
        modelPattern,
        modelsPattern,
        questionAnswerPattern,
        questionsPattern,
        sessionDetailPattern,
        sessionSpecsPattern,
        sessionsPattern,
        subagentsPattern,
        teammatesPattern,
        todosPattern,
        tokenRatePattern,
        toolsRunningClosePattern,
        toolsRunningPattern;

export 'src/agent_config.dart';
export 'src/agent_store.dart';
export 'src/conversation_store.dart';
export 'src/delegate.dart';
export 'src/model_catalog.dart';
export 'src/paths.dart';
export 'src/agent/agent_engine.dart';
export 'src/agent/attachment_prompt.dart';
export 'src/agent/compaction_service.dart';
export 'src/agent/conversation_service.dart';
export 'src/agent/subagent_service.dart';
export 'src/agent/question_broker.dart';
export 'src/agent/question_store.dart';
export 'src/agent/private_paths.dart';
export 'src/agent/scripted_agent.dart';
export 'src/agent/tool_result_repair.dart';
export 'src/agent/workspace_prompt.dart';
export 'src/compat/protocol_types.dart';
export 'src/llm/llm_agent_engine.dart';
export 'src/llm/llm_json_caller.dart';
export 'src/llm/llm_result_gate.dart';
export 'src/llm/llm_session.dart';
export 'src/llm/llm_summarizer.dart';
export 'src/llm/llm_transport.dart';
export 'src/llm/llm_types.dart';
export 'src/llm/openai_codec.dart';
export 'src/llm/sse_parser.dart';
export 'src/llm/vision_files.dart';
export 'src/session_store.dart';
export 'src/spec/builtin_spec_assets.dart';
export 'src/spec/builtin_specs.dart';
export 'src/spec/spec_service.dart';
export 'src/runtime/agent_runtime.dart';
export 'src/settings/core_settings.dart';
export 'src/settings/domain_settings.dart';
export 'src/store/usage_log.dart';
export 'src/subagent_store.dart';
export 'src/team/message_dispatcher.dart';
export 'src/team/team_model.dart';
export 'src/team/team_repair.dart';
export 'src/team/team_service.dart';
export 'src/team/team_workspace.dart';
export 'src/teammates.dart';
export 'src/tool/question_channel.dart';
export 'src/tool/subagent_tool.dart';
export 'src/tool/message_tool.dart';
export 'src/tool/team_tool.dart';
export 'src/tool/station_tool_runner.dart';
export 'src/tool/todo_store.dart';
export 'src/tool/tool_runs_scope.dart';
export 'src/tool/tool_runner.dart';
export 'src/util/liveness.dart';
export 'src/util/tokens.dart';
export 'src/workspace/station_command.dart';
export 'src/workspace/station_workspace_io.dart';
export 'src/workspace/workspace_io.dart';
export 'src/ws/ws_hub.dart';
export 'src/yaml_utils.dart';

/// 插件版本（与 `plugin.json` 的 version 同源；发布时两处一起改）。
const String kTreeAgentVersion = '0.16.0';

/// 收集站 id：插件经它申报自己承担的 `{method, pattern}` 委派路由。
const String kApiRoutesStation = 'system.collect.api.routes';

/// 已申报的委派路由（**如实申报**：核心据此知道哪些键归本插件）。
///
/// A2 起按 `agent_api_contract.md` §1 逐组追加；双跑期核心仍实现同键时，
/// 核心会把它标注为 shadowed 并继续由核心承接（查表顺序），交接删除后自动生效。
const List<Map<String, String>> kDeclaredRoutes = <Map<String, String>>[
  <String, String>{'method': 'GET', 'pattern': agentsPattern},
  <String, String>{'method': 'GET', 'pattern': conversationsPattern},
  <String, String>{'method': 'GET', 'pattern': agentDetailPattern},
  <String, String>{'method': 'GET', 'pattern': sessionsPattern},
  <String, String>{'method': 'GET', 'pattern': sessionDetailPattern},
  <String, String>{'method': 'GET', 'pattern': teammatesPattern},
  <String, String>{'method': 'GET', 'pattern': todosPattern},
  <String, String>{'method': 'GET', 'pattern': subagentsPattern},
  <String, String>{'method': 'GET', 'pattern': modelsPattern},
  <String, String>{'method': 'GET', 'pattern': agentModelsInfoPattern},
  // C-08 新增（核心未实现，无 HTTP 对照；行为由插件自检覆盖）。
  <String, String>{'method': 'POST', 'pattern': messagesPattern},
  <String, String>{'method': 'POST', 'pattern': cancelPattern},
  // 运行监督（A2 最后两条）。
  <String, String>{'method': 'GET', 'pattern': toolsRunningPattern},
  <String, String>{'method': 'POST', 'pattern': toolsRunningClosePattern},
  // 模型池写接口 + token 节奏（A3 写路径）。
  <String, String>{'method': 'POST', 'pattern': modelsPattern},
  <String, String>{'method': 'PATCH', 'pattern': modelPattern},
  <String, String>{'method': 'DELETE', 'pattern': modelPattern},
  <String, String>{'method': 'GET', 'pattern': tokenRatePattern},
  <String, String>{'method': 'POST', 'pattern': tokenRatePattern},
  // 会话 / 历史 / 提问写接口（A3 写路径）。
  <String, String>{'method': 'POST', 'pattern': sessionsPattern},
  <String, String>{'method': 'PATCH', 'pattern': sessionDetailPattern},
  <String, String>{'method': 'DELETE', 'pattern': sessionDetailPattern},
  <String, String>{'method': 'POST', 'pattern': sessionSpecsPattern},
  <String, String>{'method': 'DELETE', 'pattern': conversationsPattern},
  <String, String>{'method': 'GET', 'pattern': questionsPattern},
  <String, String>{'method': 'POST', 'pattern': questionAnswerPattern},
];

/// 一条委派路由声明的形状（`{method, pattern}`）。
Map<String, String> routeDeclaration(String method, String pattern) =>
    <String, String>{'method': method, 'pattern': pattern};
