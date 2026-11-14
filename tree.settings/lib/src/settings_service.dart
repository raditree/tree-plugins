import 'dart:convert';
import 'dart:io';

import 'settings_engine.dart';

/// 执行站命令族（K1/K2 已实现的全部）。
const List<String> kSettingsCommands = <String>[
  'settings.define',
  'settings.list',
  'settings.get',
  'settings.set',
  'settings.reset',
  'settings.export',
];

/// 一次写入成功后的变更事实（广播用；不携带值，避免 secret 泄露）。
class SettingsChange {
  const SettingsChange({
    required this.teamId,
    required this.binding,
    required this.pluginId,
    required this.keys,
    required this.generation,
    this.at = 0,
  });

  final String teamId;
  final String binding;
  final String pluginId;
  final List<String> keys;
  final int generation;

  /// 广播时刻（epoch ms；订阅方只做排序 / 日志，不做判活）。
  final int at;

  Map<String, Object?> toPayload() => <String, Object?>{
    'plugin_id': pluginId,
    'binding': binding,
    'keys': keys,
    'generation': generation,
    'at': at,
  };
}

typedef SettingsChanged = Future<void> Function(SettingsChange change);

/// 设置服务：身份 → 数据根 → 团队 → 命令 / REST。
class SettingsService {
  SettingsService({Map<String, String>? environment, this.log, this.onChanged})
    : _environment = environment ?? Platform.environment;

  final Map<String, String> _environment;
  final void Function(String message)? log;
  SettingsChanged? onChanged;

  final Map<String, SettingsEngine> _engines = <String, SettingsEngine>{};

  Future<Map<String, dynamic>> handle(
    String command,
    Map<String, dynamic> arguments,
    Map<String, dynamic> meta,
    Map<String, dynamic> scope,
  ) async {
    final String caller = _str(meta['source_plugin_id']);
    if (caller.isEmpty) {
      throw SettingsFailure(
        '核心未在站请求的 meta 里带 source_plugin_id，拒绝猜测调用方',
        code: 'identity_required',
      );
    }
    final String teamId = _str(scope['team_id']);
    final String binding = _bindingOf(arguments);
    final SettingsScope settingsScope;
    if (binding == 'plugin') {
      settingsScope = const SettingsScope.plugin();
    } else {
      if (teamId.isEmpty) {
        throw SettingsFailure(
          '核心未在站请求的 scope 里带 team_id，拒绝落到公共设置库'
          '（plugin 级设置请传 binding:plugin）',
          code: 'team_required',
        );
      }
      settingsScope = SettingsScope.team(teamId);
    }
    final String dataRoot = _dataRoot(meta);
    if (dataRoot.isEmpty) {
      throw SettingsFailure(
        '缺少 data_dir（核心未在站请求的 meta 里带数据根，环境变量 TREE_DATA_ROOT 也未设置）',
        code: 'missing_data_dir',
      );
    }
    final SettingsEngine engine = _engineOf(dataRoot);
    switch (command) {
      case 'settings.define':
        final Map<String, dynamic> explicit = _map(arguments['schema']);
        final Map<String, dynamic> schema = explicit.isNotEmpty
            ? explicit
            : arguments;
        return _withScope(
          await engine.define(
            scope: settingsScope,
            owner: caller,
            schema: schema,
          ),
          binding,
          teamId,
        );
      case 'settings.list':
        return _withScope(
          await engine.list(scope: settingsScope, owner: caller),
          binding,
          teamId,
        );
      case 'settings.get':
        return _withScope(
          await engine.get(
            scope: settingsScope,
            owner: caller,
            key: _str(arguments['key']),
          ),
          binding,
          teamId,
        );
      case 'settings.set':
        final Map<String, dynamic> values = _valuesOf(arguments);
        final Map<String, dynamic> result = await engine.set(
          scope: settingsScope,
          owner: caller,
          values: values,
        );
        _notify(teamId, binding, caller, result);
        return _withScope(result, binding, teamId);
      case 'settings.reset':
        final List<String> keys = _strings(arguments['keys']);
        final Map<String, dynamic> result = await engine.reset(
          scope: settingsScope,
          owner: caller,
          keys: keys,
        );
        _notify(teamId, binding, caller, result);
        return _withScope(result, binding, teamId);
      case 'settings.export':
        return _withScope(
          await engine.export(scope: settingsScope, owner: caller),
          binding,
          teamId,
        );
      default:
        throw SettingsFailure('未知设置命令：$command', code: 'unknown_command');
    }
  }

  /// 处理一次 `api/delegate`（核心 → 插件）。
  Future<Map<String, dynamic>> handleDelegate(
    Map<String, dynamic> envelope,
  ) async {
    final Map<String, dynamic> scope = _map(envelope['scope']);
    final String teamId = _str(envelope['team_id']).isEmpty
        ? _str(scope['team_id'])
        : _str(envelope['team_id']);
    final String dataRoot = _dataRoot(envelope);
    if (dataRoot.isEmpty) {
      return _error(500, 'missing_data_dir', '委派信封缺少 data_dir');
    }
    final String method = _str(envelope['method']).toUpperCase();
    final String path = _normalizePath(_str(envelope['path']));
    final Map<String, dynamic> query = _map(envelope['query']);
    final SettingsEngine engine = _engineOf(dataRoot);
    try {
      final Map<String, dynamic> body = method == 'GET'
          ? <String, dynamic>{}
          : _bodyOf(envelope);
      final String binding = _bindingFrom(query, body);
      final SettingsScope settingsScope;
      if (binding == 'plugin') {
        settingsScope = const SettingsScope.plugin();
      } else {
        if (teamId.isEmpty) {
          return _error(
            400,
            'team_required',
            '委派信封缺少 team_id / scope.team_id（plugin 级设置请传 binding=plugin）',
          );
        }
        settingsScope = SettingsScope.team(teamId);
      }
      switch ('$method $path') {
        case 'GET /api/plugin-settings/schema':
          final String filter = _str(query['plugin_id']);
          List<Map<String, dynamic>> schemas = await engine.listSchemas(
            settingsScope,
          );
          if (filter.isNotEmpty) {
            schemas = schemas
                .where(
                  (Map<String, dynamic> item) =>
                      _str(item['plugin_id']) == filter,
                )
                .toList();
          }
          return _json(200, _withScope(<String, dynamic>{
            'schemas': schemas,
          }, binding, teamId));
        case 'GET /api/plugin-settings/values':
          final String pluginId = _str(query['plugin_id']);
          if (pluginId.isEmpty) {
            return _error(400, 'invalid_arguments', '缺少 plugin_id');
          }
          return _json(200, _withScope(
            await engine.list(scope: settingsScope, owner: pluginId),
            binding,
            teamId,
          ));
        case 'PATCH /api/plugin-settings/values':
          final String pluginId = _str(body['plugin_id']);
          if (pluginId.isEmpty) {
            return _error(400, 'invalid_arguments', '缺少 plugin_id');
          }
          if (!await _schemaExists(engine, settingsScope, pluginId)) {
            return _error(404, 'unknown_plugin', '插件 $pluginId 未注册设置 schema');
          }
          final Map<String, dynamic> values = _map(body['values']);
          final Map<String, dynamic> result = await engine.set(
            scope: settingsScope,
            owner: pluginId,
            values: values,
          );
          _notify(teamId, binding, pluginId, result);
          return _json(200, _withScope(result, binding, teamId));
        case 'POST /api/plugin-settings/reset':
          final String pluginId = _str(body['plugin_id']);
          if (pluginId.isEmpty) {
            return _error(400, 'invalid_arguments', '缺少 plugin_id');
          }
          if (!await _schemaExists(engine, settingsScope, pluginId)) {
            return _error(404, 'unknown_plugin', '插件 $pluginId 未注册设置 schema');
          }
          final Map<String, dynamic> result = await engine.reset(
            scope: settingsScope,
            owner: pluginId,
            keys: _strings(body['keys']),
          );
          _notify(teamId, binding, pluginId, result);
          return _json(200, _withScope(result, binding, teamId));
        case 'POST /api/plugin-settings/apply':
          // 变更已经通过广播下发；这里只做一次显式重放的确认。
          return _json(200, <String, dynamic>{
            'ok': true,
            'binding': binding,
            'team_id': teamId,
          });
        default:
          return _error(404, 'not_found', '未知设置路由：$method $path');
      }
    } on SettingsFailure catch (error) {
      return _error(_statusOf(error.code), error.code, error.message);
    } catch (error) {
      return _error(500, 'settings_error', '设置服务内部错误：$error');
    }
  }

  Future<void> close() async {
    for (final SettingsEngine engine in _engines.values) {
      await engine.close();
    }
    _engines.clear();
  }

  SettingsEngine _engineOf(String dataRoot) => _engines.putIfAbsent(
    dataRoot,
    () => SettingsEngine(dataRoot: dataRoot, log: log),
  );

  void _notify(
    String teamId,
    String binding,
    String pluginId,
    Map<String, dynamic> result,
  ) {
    final SettingsChanged? callback = onChanged;
    if (callback == null) return;
    final List<String> keys = _changedKeys(result);
    if (keys.isEmpty) return;
    final int generation = _int(result['generation'], 0);
    // 广播失败不能回滚已经落库的值；只在日志留痕。
    callback(
      SettingsChange(
        teamId: teamId,
        binding: binding,
        pluginId: pluginId,
        keys: keys,
        generation: generation,
        at: DateTime.now().millisecondsSinceEpoch,
      ),
    ).catchError((Object error) {
      log?.call('settings.changed 广播失败：$error');
    });
  }

  /// 解析绑定维度：缺省 team（兼容旧调用），只接受 team / plugin。
  static String _bindingOf(Map<String, dynamic> arguments) =>
      _bindingValue(arguments['binding']);

  static String _bindingFrom(
    Map<String, dynamic> query,
    Map<String, dynamic> body,
  ) {
    final String fromQuery = _str(query['binding']);
    return _bindingValue(fromQuery.isEmpty ? body['binding'] : fromQuery);
  }

  static String _bindingValue(Object? raw) {
    final String value = _str(raw).toLowerCase();
    if (value.isEmpty) return 'team';
    if (value == 'team' || value == 'plugin') return value;
    throw SettingsFailure(
      'binding 只能是 team / plugin：$value',
      code: 'invalid_arguments',
    );
  }

  /// 回包统一带归属：binding + team_id（plugin 时为空串）。
  static Map<String, dynamic> _withScope(
    Map<String, dynamic> result,
    String binding,
    String teamId,
  ) => <String, dynamic>{
    ...result,
    'binding': binding,
    'team_id': binding == 'plugin' ? '' : teamId,
  };

  static List<String> _changedKeys(Map<String, dynamic> result) {
    if (result['applied'] is List) return _strings(result['applied']);
    if (result['reset'] is List) return _strings(result['reset']);
    return const <String>[];
  }

  Map<String, dynamic> _valuesOf(Map<String, dynamic> arguments) {
    final Map<String, dynamic> values = _map(arguments['values']);
    if (values.isNotEmpty) return values;
    final String key = _str(arguments['key']);
    if (key.isEmpty) {
      throw SettingsFailure(
        'settings.set 需要 values 或 key',
        code: 'invalid_arguments',
      );
    }
    return <String, dynamic>{key: arguments['value']};
  }

  String _dataRoot(Map<String, dynamic> source) {
    final String fromEnvelope = _str(source['data_dir']);
    if (fromEnvelope.isNotEmpty) return fromEnvelope;
    return _str(_environment['TREE_DATA_ROOT']);
  }

  static String _normalizePath(String path) {
    String value = path.trim();
    if (value.isEmpty) return value;
    if (!value.startsWith('/')) value = '/$value';
    while (value.length > 1 && value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  static Map<String, dynamic> _bodyOf(Map<String, dynamic> envelope) {
    final Object? body = envelope['body'];
    if (body is Map) return _map(body);
    final String text = _str(body);
    if (text.isEmpty) return <String, dynamic>{};
    try {
      final Object? decoded = json.decode(text);
      if (decoded is! Map) {
        throw SettingsFailure('请求体必须是 JSON 对象', code: 'invalid_arguments');
      }
      return _map(decoded);
    } on SettingsFailure {
      rethrow;
    } catch (_) {
      throw SettingsFailure('请求体不是合法 JSON', code: 'invalid_arguments');
    }
  }

  static Map<String, dynamic> _json(int status, Map<String, dynamic> body) =>
      <String, dynamic>{
        'status': status,
        'headers': <String, String>{'content-type': 'application/json'},
        'body': json.encode(body),
      };

  static Map<String, dynamic> _error(int status, String code, String message) =>
      _json(status, <String, dynamic>{
        'status': status,
        'code': code,
        'message': message,
      });

  /// REST 写入前确认目标插件真的注册过 schema（没注册就不接受覆盖值）。
  static Future<bool> _schemaExists(
    SettingsEngine engine,
    SettingsScope scope,
    String pluginId,
  ) async {
    final List<Map<String, dynamic>> schemas = await engine.listSchemas(scope);
    return schemas.any(
      (Map<String, dynamic> item) => _str(item['plugin_id']) == pluginId,
    );
  }

  static int _statusOf(String code) {
    switch (code) {
      case 'schema_not_found':
      case 'unknown_key':
      case 'unknown_plugin':
        return 404;
      case 'schema_version_conflict':
        return 409;
      case 'identity_required':
        return 403;
      case 'team_required':
      case 'missing_data_dir':
        return 400;
      case 'unknown_command':
        return 400;
      default:
        return 400;
    }
  }

  static String _str(Object? raw) => (raw ?? '').toString().trim();

  static int _int(Object? raw, int fallback) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim()) ?? fallback;
    return fallback;
  }

  static Map<String, dynamic> _map(Object? raw) => raw is Map
      ? raw.map(
          (Object? key, Object? value) =>
              MapEntry<String, dynamic>(key.toString(), value),
        )
      : <String, dynamic>{};

  static List<String> _strings(Object? raw) {
    if (raw is List) {
      return raw
          .map((Object? item) => (item ?? '').toString().trim())
          .where((String item) => item.isNotEmpty)
          .toList();
    }
    final String single = _str(raw);
    return single.isEmpty ? <String>[] : <String>[single];
  }
}
