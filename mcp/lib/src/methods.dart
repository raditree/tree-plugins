/// MCP 协议的方法/通知常量（独立协议，不属于插件 ↔ 核心 RPC 面）。
abstract final class McpMethods {
  static const String initialize = 'initialize';
  static const String initialized = 'notifications/initialized';
  static const String ping = 'ping';
  static const String toolsList = 'tools/list';
  static const String toolsCall = 'tools/call';
  static const String resourcesList = 'resources/list';
  static const String resourceTemplatesList = 'resources/templates/list';
  static const String resourcesRead = 'resources/read';
  static const String promptsList = 'prompts/list';
  static const String promptsGet = 'prompts/get';
  static const String rootsList = 'roots/list';
  static const String rootsListChanged = 'notifications/roots/list_changed';
  static const String toolsListChanged = 'notifications/tools/list_changed';
  static const String resourcesListChanged = 'notifications/resources/list_changed';
  static const String promptsListChanged = 'notifications/prompts/list_changed';
  static const String logMessage = 'notifications/message';

  static const Set<String> all = <String>{
    initialize,
    initialized,
    ping,
    toolsList,
    toolsCall,
    resourcesList,
    resourceTemplatesList,
    resourcesRead,
    promptsList,
    promptsGet,
    rootsList,
    rootsListChanged,
    toolsListChanged,
    resourcesListChanged,
    promptsListChanged,
    logMessage,
  };
}