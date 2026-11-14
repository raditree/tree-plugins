import 'package:flutter/material.dart';

import '../../io/api_service.dart';
import 'production_line_utils.dart';

/// 结构整理页（PC-5F / Task 9.3）。
///
/// 数据源：`GET /api/production/lines/{id}/structure` → `{structure, readiness}`。
/// 只读展示结构报告（包职责 / 公共 API / 依赖环 / 分层 / 重复 / 规模 / 文档 /
/// TODO）与 high findings；写操作只有两条：
/// - 逐项「豁免」（owner + 原因 + 到期），没有全局跳过；
/// - 「重新评估」（cleanup 跑完后重审）。
///
/// `organizing` 阶段只允许建 `cleanup` 任务：这里给快捷入口，具体建任务对话框
/// 由工作台复用（[onCreateCleanupTask]），避免两份表单口径漂移。
class ProductionStructurePage extends StatefulWidget {
  const ProductionStructurePage({
    super.key,
    required this.lineId,
    this.teamId = '',
    this.onClose,
    this.onCreateCleanupTask,
  });

  final String lineId;
  final String teamId;
  final VoidCallback? onClose;

  /// 打开工作台的建任务对话框并提交 `task_type=cleanup`；null = 不提供入口。
  final Future<void> Function()? onCreateCleanupTask;

  @override
  State<ProductionStructurePage> createState() =>
      _ProductionStructurePageState();
}

class _ProductionStructurePageState extends State<ProductionStructurePage> {
  bool _loading = true;
  bool _busy = false;
  String _error = '';
  String _actionError = '';
  Map<String, dynamic> _structure = <String, dynamic>{};
  Map<String, dynamic> _readiness = <String, dynamic>{};

  List<Map<String, dynamic>> get _findings =>
      productionListOf(_structure, 'findings');

  List<Map<String, dynamic>> get _highFindings => _findings
      .where(
        (Map<String, dynamic> item) => '${item['severity'] ?? ''}' == 'high',
      )
      .toList();

  String get _phase =>
      '${_readiness['phase'] ?? _structure['phase'] ?? ''}'.trim();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = _structure.isEmpty;
      _error = '';
    });
    try {
      final Map<String, dynamic> data = await ApiService.getProductionStructure(
        widget.lineId,
        teamId: widget.teamId,
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _structure = productionMap(data['structure']);
        _readiness = productionMap(data['readiness']);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = productionReadable(error, '结构报告加载失败');
      });
    }
  }

  Future<void> _reevaluate() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _actionError = '';
    });
    try {
      await ApiService.reevaluateProductionStructure(
        widget.lineId,
        teamId: widget.teamId,
      );
      await _load();
      _notify('已重新评估结构');
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = productionReadable(error, '重新评估失败'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _waive(Map<String, dynamic> finding) async {
    final String findingId = '${finding['id'] ?? finding['finding_id'] ?? ''}'
        .trim();
    if (findingId.isEmpty || _busy) return;
    final _WaiveSpec? spec = await showDialog<_WaiveSpec>(
      context: context,
      builder: (BuildContext context) => _WaiveDialog(findingId: findingId),
    );
    if (spec == null) return;
    setState(() {
      _busy = true;
      _actionError = '';
    });
    try {
      await ApiService.waiveProductionStructureFinding(
        widget.lineId,
        findingId: findingId,
        owner: spec.owner,
        reason: spec.reason,
        expiresAt: spec.expiresAt,
        teamId: widget.teamId,
      );
      await _load();
      _notify('已豁免 $findingId');
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = productionReadable(error, '豁免失败'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createCleanup() async {
    final Future<void> Function()? create = widget.onCreateCleanupTask;
    if (create == null || _busy) return;
    await create();
    if (!mounted) return;
    await _load();
  }

  void _notify(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      key: const Key('production-structure-page'),
      color: cs.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            height: 48,
            padding: const EdgeInsets.only(left: 12, right: 4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.category_outlined, size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '结构整理 · ${widget.lineId}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (_busy)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  TextButton(
                    key: const Key('production-structure-reevaluate'),
                    onPressed: _reevaluate,
                    child: const Text('重新评估'),
                  ),
                if (widget.onClose != null)
                  IconButton(
                    key: const Key('production-structure-close'),
                    tooltip: '关闭',
                    visualDensity: VisualDensity.compact,
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close, size: 18),
                  ),
              ],
            ),
          ),
          if (_actionError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                _actionError,
                style: TextStyle(fontSize: 11.5, color: cs.error),
              ),
            ),
          Expanded(child: _buildBody(cs)),
        ],
      ),
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
            TextButton(
              key: const Key('production-structure-retry'),
              onPressed: _load,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final List<String> packages = _items(
      _structure['responsibilities'] ?? _structure['packages'],
    );
    final List<String> apis = _items(_structure['public_api']);
    final List<String> cycles = _items(_structure['cycles']);
    final List<String> layers = _items(_structure['layers']);
    final List<String> duplicates = _items(_structure['duplicates']);
    final List<String> size = _items(_structure['size'] ?? _structure['scale']);
    final List<String> docs = _items(_structure['docs']);
    final List<String> todos = _items(_structure['todos']);
    final List<Map<String, dynamic>> high = _highFindings;
    return ListView(
      key: const Key('production-structure-report'),
      padding: const EdgeInsets.only(bottom: 20),
      children: <Widget>[
        if (_phase == 'organizing') _buildOrganizingBanner(cs),
        _section(cs, '包职责', packages),
        _section(cs, '公共 API', apis),
        _section(cs, '依赖环', cycles),
        _section(cs, '分层', layers),
        _section(cs, '重复', duplicates),
        _section(cs, '规模', size),
        _section(cs, '文档', docs),
        _section(cs, 'TODO', todos),
        _sectionTitle(cs, '结构问题（high）', '${high.length}'),
        if (high.isEmpty)
          _muted(cs, '没有 high 级结构问题')
        else
          for (final Map<String, dynamic> finding in high)
            _buildFinding(cs, finding),
      ],
    );
  }

  Widget _buildOrganizingBanner(ColorScheme cs) {
    final bool canCreate = widget.onCreateCleanupTask != null;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(
        color: cs.tertiaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: cs.tertiary.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '当前阶段 organizing：只能建 cleanup 任务；其他任务会返回 '
            '409 structure_not_ready。',
            style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonal(
              key: const Key('production-structure-cleanup'),
              onPressed: canCreate && !_busy ? _createCleanup : null,
              child: const Text('新建 cleanup 任务'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFinding(ColorScheme cs, Map<String, dynamic> finding) {
    final String id = '${finding['id'] ?? finding['finding_id'] ?? ''}'.trim();
    final String title = '${finding['title'] ?? finding['message'] ?? ''}';
    final String detail = '${finding['detail'] ?? finding['reason'] ?? ''}';
    final bool waived = finding['waived'] == true;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 3, 8, 3),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
        decoration: BoxDecoration(
          color: cs.errorContainer.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: cs.error.withValues(alpha: 0.25)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    id.isEmpty ? title : '$id · $title',
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (detail.isNotEmpty)
                    Text(
                      detail,
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (waived)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  '已豁免',
                  style: TextStyle(fontSize: 11, color: cs.primary),
                ),
              )
            else if (id.isNotEmpty)
              TextButton(
                key: Key('production-structure-waive-$id'),
                onPressed: _busy ? null : () => _waive(finding),
                child: const Text('豁免'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _section(ColorScheme cs, String title, List<String> items) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      _sectionTitle(cs, title, '${items.length}'),
      if (items.isEmpty)
        _muted(cs, '无')
      else
        for (final String item in items)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 1, 16, 1),
            child: Text(item, style: const TextStyle(fontSize: 11.5)),
          ),
    ],
  );

  Widget _sectionTitle(ColorScheme cs, String title, String count) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
    child: Text(
      '$title（$count）',
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        color: cs.onSurfaceVariant,
      ),
    ),
  );

  Widget _muted(ColorScheme cs, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 1, 16, 3),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
    ),
  );

  /// 结构报告的字段形态未强制：字符串 / 列表 / 映射都尽量说人话。
  List<String> _items(Object? raw) {
    if (raw == null) return <String>[];
    if (raw is List) {
      return <String>[for (final Object? item in raw) _describe(item)];
    }
    if (raw is Map) {
      final Object? nested = raw['items'];
      if (nested is List) return _items(nested);
      return <String>[
        for (final MapEntry<Object?, Object?> entry in raw.entries)
          '${entry.key}：${_describe(entry.value)}',
      ];
    }
    final String text = '$raw'.trim();
    return text.isEmpty ? <String>[] : <String>[text];
  }

  String _describe(Object? raw) {
    if (raw is Map) {
      final Map<String, dynamic> map = productionMap(raw);
      final String package = '${map['package'] ?? map['name'] ?? ''}'.trim();
      final String responsibility =
          '${map['responsibility'] ?? map['role'] ?? ''}'.trim();
      if (package.isNotEmpty || responsibility.isNotEmpty) {
        return <String>[
          if (package.isNotEmpty) package,
          if (responsibility.isNotEmpty) responsibility,
        ].join('：');
      }
      final String from = '${map['from'] ?? map['source'] ?? ''}'.trim();
      final String to = '${map['to'] ?? map['target'] ?? ''}'.trim();
      if (from.isNotEmpty || to.isNotEmpty) {
        final String reason = '${map['reason'] ?? map['detail'] ?? ''}'.trim();
        final String arrow = [
          if (from.isNotEmpty) from,
          '→',
          if (to.isNotEmpty) to,
        ].join(' ');
        return reason.isEmpty ? arrow : '$arrow（$reason）';
      }
      final List<String> parts = <String>[
        for (final MapEntry<String, dynamic> entry in map.entries)
          if (entry.value is! Map &&
              entry.value is! List &&
              '${entry.value ?? ''}'.trim().isNotEmpty)
            '${entry.key}: ${entry.value}',
      ];
      return parts.isEmpty ? '$map' : parts.join(' · ');
    }
    if (raw is List) {
      return raw.map(_describe).join(' · ');
    }
    return '${raw ?? ''}'.trim();
  }
}

/// 豁免表单结果。
class _WaiveSpec {
  const _WaiveSpec(this.owner, this.reason, this.expiresAt);

  final String owner;
  final String reason;
  final String expiresAt;
}

/// 逐项豁免：owner / 原因 / 到期时间，三者缺一不可（到期后自动失效）。
class _WaiveDialog extends StatefulWidget {
  const _WaiveDialog({required this.findingId});

  final String findingId;

  @override
  State<_WaiveDialog> createState() => _WaiveDialogState();
}

class _WaiveDialogState extends State<_WaiveDialog> {
  final TextEditingController _owner = TextEditingController();
  final TextEditingController _reason = TextEditingController();
  final TextEditingController _expires = TextEditingController();

  @override
  void dispose() {
    _owner.dispose();
    _reason.dispose();
    _expires.dispose();
    super.dispose();
  }

  bool get _valid =>
      _owner.text.trim().isNotEmpty &&
      _reason.text.trim().isNotEmpty &&
      _expires.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('豁免 · ${widget.findingId}'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              key: const Key('production-structure-waive-owner'),
              controller: _owner,
              decoration: const InputDecoration(labelText: 'owner（责任人）'),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              key: const Key('production-structure-waive-reason'),
              controller: _reason,
              maxLines: 2,
              decoration: const InputDecoration(labelText: '豁免原因'),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              key: const Key('production-structure-waive-expires'),
              controller: _expires,
              decoration: const InputDecoration(
                labelText: '到期时间',
                hintText: '2026-12-31',
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('production-structure-waive-submit'),
          onPressed: _valid
              ? () => Navigator.of(context).pop(
                  _WaiveSpec(
                    _owner.text.trim(),
                    _reason.text.trim(),
                    _expires.text.trim(),
                  ),
                )
              : null,
          child: const Text('确认豁免'),
        ),
      ],
    );
  }
}
