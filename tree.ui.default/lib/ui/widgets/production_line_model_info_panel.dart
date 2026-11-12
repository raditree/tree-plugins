import 'package:flutter/material.dart';

import '../../io/api_service.dart';
import '../app_radius.dart';
import '../services/model_pool.dart';
import 'production_line_utils.dart';

/// 产线上下文的「模型信息」窗（STAB-PL-6 / D5）。
///
/// 产线与 Agent 并列，模型配置写在 `line.yaml.roles.<role>.model_id`。
/// 未选 Agent、只选了一条产线时，右栏仍然要能看到四个角色各绑了什么模型，
/// 而不是「请先选择 Agent」。
///
/// 只读：模型池是全局的（`GET /api/models` 不需要 Agent），修改入口在工作台
/// 「配置」（[CreateProductionLineDialog]）。
class ProductionLineModelInfoPanel extends StatefulWidget {
  const ProductionLineModelInfoPanel({super.key, required this.line});

  /// 当前选中的产线（`GET /api/production/lines` 的条目）。
  final Map<String, dynamic> line;

  @override
  State<ProductionLineModelInfoPanel> createState() =>
      _ProductionLineModelInfoPanelState();
}

class _ProductionLineModelInfoPanelState
    extends State<ProductionLineModelInfoPanel> {
  static const List<(String, String)> _roles = <(String, String)>[
    ('orchestrator', '主控'),
    ('packer', '打包'),
    ('executor', '执行'),
    ('expert', '专家'),
  ];

  List<Map<String, dynamic>> _models = <Map<String, dynamic>>[];
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ProductionLineModelInfoPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ('${oldWidget.line['id'] ?? ''}' != '${widget.line['id'] ?? ''}') {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final List<Map<String, dynamic>> models = await ApiService.getModels();
      if (!mounted) return;
      setState(() {
        _models = models;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = productionReadable(error, '模型池加载失败');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: <Widget>[
              Text(
                '产线模型',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              const Spacer(),
              IconButton(
                key: const Key('line-model-info-refresh'),
                tooltip: '刷新模型池',
                visualDensity: VisualDensity.compact,
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _buildBody(cs)),
      ],
    );
  }

  Widget _buildBody(ColorScheme cs) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(_error, style: TextStyle(fontSize: 12, color: cs.error)),
            const SizedBox(height: 8),
            TextButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final Map<String, dynamic> roles = productionMap(widget.line['roles']);
    return ListView(
      key: const Key('line-model-info-list'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      children: <Widget>[
        for (final (String key, String label) in _roles)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _roleCard(cs, key, label, productionMap(roles[key])),
          ),
        const SizedBox(height: 4),
        Text(
          '修改请用中栏工作台的「配置」：每个角色可独立选模型与工具。',
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _roleCard(
    ColorScheme cs,
    String key,
    String label,
    Map<String, dynamic> role,
  ) {
    final String modelKey = '${role['model_id'] ?? ''}'.trim();
    final Map<String, dynamic>? model = _findModel(modelKey);
    final bool missing = modelKey.isNotEmpty && model == null;
    final List<String> tools = <String>[
      for (final Object? item in (role['tools'] as List<dynamic>? ??
          const <dynamic>[]))
        if ('${item ?? ''}'.trim().isNotEmpty) '${item ?? ''}'.trim(),
    ];
    final String display = modelKey.isEmpty
        ? '未配置'
        : (missing
              ? '$modelKey（模型池里已不存在）'
              : '${model?['name'] ?? model?['model_id'] ?? modelKey}');
    final String providerLine = model == null
        ? (modelKey.isEmpty ? '' : '')
        : <String>[
            providerLabelOf(providerOf(model)),
            '${model['model_id'] ?? ''}',
          ].where((String s) => s.trim().isNotEmpty).join(' · ');
    final List<String> media = model == null
        ? const <String>[]
        : modelMediaLabelsOf(model);
    final int? maxSeqlen = (model?['max_seqlen'] as num?)?.toInt();
    final int? maxOutput = (model?['max_output_tokens'] as num?)?.toInt();
    return Container(
      key: Key('line-model-role-$key'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              const Spacer(),
              if (missing)
                Text(
                  '已失效',
                  style: TextStyle(fontSize: 11, color: cs.error),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            display,
            style: TextStyle(
              fontSize: 12,
              color: missing || modelKey.isEmpty
                  ? cs.error
                  : cs.onSurfaceVariant,
            ),
          ),
          if (providerLine.isNotEmpty) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              providerLine,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ],
          if (model != null &&
              (media.isNotEmpty ||
                  maxSeqlen != null ||
                  maxOutput != null)) ...<Widget>[
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 2,
              children: <Widget>[
                for (final String item in media) _tag(cs, item),
                if (maxSeqlen != null) _tag(cs, '上下文 $maxSeqlen'),
                if (maxOutput != null) _tag(cs, '输出 $maxOutput'),
              ],
            ),
          ],
          if (key == 'expert') ...<Widget>[
            const SizedBox(height: 4),
            Text(
              role['enabled'] == true
                  ? '专家：已启用（单任务上限 ${role['max_per_task'] ?? 3}）'
                  : '专家：未启用',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ],
          if (tools.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              '工具：${tools.join('、')}',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  Widget _tag(ColorScheme cs, String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(AppRadius.pill),
      color: cs.surfaceContainerHighest,
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant),
    ),
  );

  /// 产线里的 `model_id` 可能是完整键（`provider/model_id`）或旧裸 id。
  Map<String, dynamic>? _findModel(String value) {
    if (value.isEmpty) return null;
    for (final Map<String, dynamic> model in _models) {
      if (modelKeyOf(model) == value) return model;
    }
    final List<Map<String, dynamic>> byBare = <Map<String, dynamic>>[
      for (final Map<String, dynamic> model in _models)
        if ('${model['model_id'] ?? ''}'.trim() == value) model,
    ];
    return byBare.length == 1 ? byBare.single : null;
  }
}
