import 'dart:convert';

import 'package:flutter/material.dart';

import '../../io/api_service.dart';

/// 插件设置卡片：按 `tree.settings` 的 schema 通用渲染，不写任何插件专用代码。
///
/// 契约见 `docs/pluginization/plugin-settings-recon.md` §6：
/// - 每个 owner 一个分组；字段类型决定控件；
/// - secret 只写不回显，留空 = 保持原值；
/// - 保存只提交脏字段；reset 回到 schema 默认。
class PluginSettingsCard extends StatefulWidget {
  const PluginSettingsCard({super.key});

  @override
  State<PluginSettingsCard> createState() => _PluginSettingsCardState();
}

class _PluginSettingsCardState extends State<PluginSettingsCard> {
  List<Map<String, dynamic>> _schemas = <Map<String, dynamic>>[];
  final Map<String, Map<String, dynamic>> _values =
      <String, Map<String, dynamic>>{};
  final Map<String, Map<String, dynamic>> _drafts =
      <String, Map<String, dynamic>>{};
  final Map<String, String> _errors = <String, String>{};
  bool _loading = true;
  String? _loadError;
  String? _saving;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      final Map<String, dynamic> data = await ApiService.getPluginSettingsSchema();
      final List<Map<String, dynamic>> schemas =
          (data['schemas'] as List<dynamic>? ?? <dynamic>[])
              .whereType<Map>()
              .map(
                (Map item) => item.map(
                  (Object? key, Object? value) =>
                      MapEntry<String, dynamic>(key.toString(), value),
                ),
              )
              .toList();
      final Map<String, Map<String, dynamic>> values =
          <String, Map<String, dynamic>>{};
      for (final Map<String, dynamic> schema in schemas) {
        final String pluginId = (schema['plugin_id'] ?? '').toString();
        if (pluginId.isEmpty) continue;
        final Map<String, dynamic> result =
            await ApiService.getPluginSettingsValues(pluginId);
        values[pluginId] = _map(result['values']);
      }
      if (!mounted) return;
      setState(() {
        _schemas = schemas;
        _values
          ..clear()
          ..addAll(values);
        _generation += 1;
        _drafts
          ..clear()
          ..addAll(<String, Map<String, dynamic>>{
            for (final Map<String, dynamic> schema in schemas)
              (schema['plugin_id'] ?? '').toString(): _draftOf(schema, values),
          });
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '$error';
      });
    }
  }

  Map<String, dynamic> _draftOf(
    Map<String, dynamic> schema,
    Map<String, Map<String, dynamic>> values,
  ) {
    final String pluginId = (schema['plugin_id'] ?? '').toString();
    final Map<String, dynamic> current = values[pluginId] ?? <String, dynamic>{};
    final Map<String, dynamic> draft = <String, dynamic>{};
    for (final Object? raw in (schema['fields'] as List<dynamic>? ?? <dynamic>[])) {
      final Map<String, dynamic> field = _map(raw);
      final String key = (field['key'] ?? '').toString();
      if (key.isEmpty) continue;
      final Map<String, dynamic> view = _map(current[key]);
      draft[key] = field['type'] == 'secret' ? '' : view['value'] ?? field['default'];
    }
    return draft;
  }

  Map<String, dynamic> _originalOf(String pluginId, String key) {
    final Map<String, dynamic> current = _values[pluginId] ?? <String, dynamic>{};
    return _map(current[key]);
  }

  Future<void> _save(Map<String, dynamic> schema) async {
    final String pluginId = (schema['plugin_id'] ?? '').toString();
    final Map<String, dynamic> draft = _drafts[pluginId] ?? <String, dynamic>{};
    final Map<String, dynamic> payload = <String, dynamic>{};
    for (final Object? raw in (schema['fields'] as List<dynamic>? ?? <dynamic>[])) {
      final Map<String, dynamic> field = _map(raw);
      final String key = (field['key'] ?? '').toString();
      final bool isSecret = (field['type'] ?? '').toString() == 'secret';
      final Object? value = draft[key];
      if (isSecret) {
        if (value is String && value.isNotEmpty) payload[key] = value;
        continue;
      }
      if (_same(value, _originalOf(pluginId, key)['value'] ?? field['default'])) {
        continue;
      }
      payload[key] = value;
    }
    if (payload.isEmpty) {
      setState(() => _errors[pluginId] = '没有改动');
      return;
    }
    setState(() {
      _saving = pluginId;
      _errors.remove(pluginId);
    });
    try {
      await ApiService.updatePluginSettings(pluginId, payload);
      await _load();
    } catch (error) {
      if (!mounted) return;
      setState(() => _errors[pluginId] = '$error');
    } finally {
      if (mounted) setState(() => _saving = null);
    }
  }

  Future<void> _reset(Map<String, dynamic> schema) async {
    final String pluginId = (schema['plugin_id'] ?? '').toString();
    final List<String> keys = (schema['fields'] as List<dynamic>? ?? <dynamic>[])
        .map((Object? raw) => (_map(raw)['key'] ?? '').toString())
        .where((String key) => key.isNotEmpty)
        .toList();
    if (keys.isEmpty) return;
    setState(() {
      _saving = pluginId;
      _errors.remove(pluginId);
    });
    try {
      await ApiService.resetPluginSettings(pluginId, keys);
      await _load();
    } catch (error) {
      if (!mounted) return;
      setState(() => _errors[pluginId] = '$error');
    } finally {
      if (mounted) setState(() => _saving = null);
    }
  }

  static bool _same(Object? a, Object? b) =>
      jsonEncode(a) == jsonEncode(b);

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_loadError != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          '加载插件设置失败：$_loadError',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      );
    }
    if (_schemas.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          '还没有插件声明设置项。插件启动后通过 settings.define 注册，'
          '这里会自动出现。',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }
    return Column(
      children: <Widget>[
        for (final Map<String, dynamic> schema in _schemas)
          _buildPlugin(context, schema),
      ],
    );
  }

  Widget _buildPlugin(BuildContext context, Map<String, dynamic> schema) {
    final String pluginId = (schema['plugin_id'] ?? '').toString();
    final String error = _errors[pluginId] ?? '';
    final bool saving = _saving == pluginId;
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      initiallyExpanded: true,
      title: Text(pluginId),
      subtitle: Text('schema v${schema['schema_version'] ?? 1}'),
      children: <Widget>[
        ..._buildGroups(context, pluginId, schema),
        if (error.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            TextButton(
              onPressed: saving ? null : () => _reset(schema),
              child: const Text('恢复默认'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: saving ? null : () => _save(schema),
              child: saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('保存'),
            ),
          ],
        ),
      ],
    );
  }

  List<Widget> _buildGroups(
    BuildContext context,
    String pluginId,
    Map<String, dynamic> schema,
  ) {
    final List<Map<String, dynamic>> fields =
        (schema['fields'] as List<dynamic>? ?? <dynamic>[])
            .map(_map)
            .toList();
    final List<Map<String, dynamic>> groups =
        (schema['groups'] as List<dynamic>? ?? <dynamic>[])
            .map(_map)
            .toList();
    final List<Widget> out = <Widget>[];
    if (groups.isEmpty) {
      for (final Map<String, dynamic> field in fields) {
        out.add(_buildField(context, pluginId, field));
      }
      return out;
    }
    final Set<String> groupIds = groups
        .map((Map<String, dynamic> group) => (group['id'] ?? '').toString())
        .toSet();
    for (final Map<String, dynamic> group in groups) {
      final String groupId = (group['id'] ?? '').toString();
      final List<Map<String, dynamic>> inGroup = fields
          .where((Map<String, dynamic> field) => (field['group'] ?? '') == groupId)
          .toList();
      if (inGroup.isEmpty) continue;
      out.add(
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Text(
            (group['title'] ?? groupId).toString(),
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
      );
      for (final Map<String, dynamic> field in inGroup) {
        out.add(_buildField(context, pluginId, field));
      }
    }
    // schema 允许字段不归组；有 groups 时它们不能被静默吞掉。
    final List<Map<String, dynamic>> ungrouped = fields
        .where(
          (Map<String, dynamic> field) =>
              !groupIds.contains((field['group'] ?? '').toString()),
        )
        .toList();
    for (final Map<String, dynamic> field in ungrouped) {
      out.add(_buildField(context, pluginId, field));
    }
    return out;
  }

  Widget _buildField(
    BuildContext context,
    String pluginId,
    Map<String, dynamic> field,
  ) {
    final String key = (field['key'] ?? '').toString();
    final String type = (field['type'] ?? 'string').toString();
    final String title = (field['title'] ?? key).toString();
    final String help = (field['help'] ?? '').toString();
    final Object? value = (_drafts[pluginId] ?? <String, dynamic>{})[key];
    final Map<String, dynamic> original = _originalOf(pluginId, key);
    final bool secretSet = original['has_value'] == true;
    final List<String> options = (field['options'] as List<dynamic>? ?? <dynamic>[])
        .map((Object? item) => item.toString())
        .toList();

    Widget control;
    switch (type) {
      case 'bool':
        control = Switch(
          value: value == true,
          onChanged: (bool next) => _setDraft(pluginId, key, next),
        );
      case 'enum':
        control = DropdownButtonFormField<String>(
          initialValue: options.contains(value) ? value as String : null,
          decoration: InputDecoration(
            isDense: true,
            hintText: help.isEmpty ? null : help,
          ),
          items: <DropdownMenuItem<String>>[
            for (final String option in options)
              DropdownMenuItem<String>(value: option, child: Text(option)),
          ],
          onChanged: (String? next) => _setDraft(pluginId, key, next),
        );
      case 'secret':
        control = TextFormField(
          key: ValueKey<String>('$pluginId|$key|$_generation'),
          obscureText: true,
          decoration: InputDecoration(
            isDense: true,
            hintText: secretSet ? '已设置，留空保持原值' : '未设置',
          ),
          onChanged: (String next) => _setDraft(pluginId, key, next),
        );
      case 'string_list':
        control = TextFormField(
          key: ValueKey<String>('$pluginId|$key|$_generation'),
          initialValue: value is List ? value.join(', ') : '',
          decoration: const InputDecoration(
            isDense: true,
            hintText: '逗号分隔',
          ),
          onChanged: (String next) => _setDraft(
            pluginId,
            key,
            next
                .split(',')
                .map((String item) => item.trim())
                .where((String item) => item.isNotEmpty)
                .toList(),
          ),
        );
      default:
        control = TextFormField(
          key: ValueKey<String>('$pluginId|$key|$_generation'),
          initialValue: value?.toString() ?? '',
          keyboardType:
              (type == 'int' || type == 'double')
                  ? const TextInputType.numberWithOptions(decimal: true)
                  : TextInputType.text,
          decoration: InputDecoration(
            isDense: true,
            hintText: help.isEmpty ? null : help,
          ),
          onChanged: (String next) {
            if (type == 'int') {
              _setDraft(pluginId, key, int.tryParse(next.trim()) ?? next.trim());
            } else if (type == 'double') {
              _setDraft(pluginId, key, double.tryParse(next.trim()) ?? next.trim());
            } else {
              _setDraft(pluginId, key, next);
            }
          },
        );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            flex: 2,
            child: Text(title, style: Theme.of(context).textTheme.bodyMedium),
          ),
          const SizedBox(width: 12),
          Expanded(flex: 3, child: control),
        ],
      ),
    );
  }

  void _setDraft(String pluginId, String key, Object? value) {
    setState(() {
      (_drafts[pluginId] ??= <String, dynamic>{})[key] = value;
      _errors.remove(pluginId);
    });
  }

  static Map<String, dynamic> _map(Object? raw) => raw is Map
      ? raw.map(
          (Object? key, Object? value) =>
              MapEntry<String, dynamic>(key.toString(), value),
        )
      : <String, dynamic>{};
}
