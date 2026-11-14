import 'dart:convert';

import 'package:flutter/material.dart';

import '../../io/api_service.dart';
import 'production_line_utils.dart';

/// 计划审查（Task 10.3）：7 块 + findings + 追踪断链 + 门控清单 + 批次 + plan diff。
///
/// 数据源：`GET /api/production/lines/{id}/plan[?version=N]`，回包
/// `{version:'plan-vN', plan:{...}, findings:[...]}`。
///
/// 硬口径：
/// - 未关闭的 high findings 置顶，并**阻止落档**（按钮禁用 + tooltip 说明原因）；
/// - 追踪矩阵断链标红（需求 → 任务 → 门控任一环缺失都算断链）；
/// - 每个任务的 `- [ ]` 门控逐条列出 evidence，缺证据的项标红；
/// - plan diff 只展示任务新增/删除/修改与追踪条目变化摘要。
class ProductionPlanReview extends StatefulWidget {
  const ProductionPlanReview({
    super.key,
    required this.lineId,
    this.teamId = '',
    this.version,
    this.onFinalize,
    this.showFinalize = true,
    this.onBlockingChanged,
  });

  final String lineId;
  final String teamId;

  /// null = 最新版本；指定则读历史版本（diff 预览）。
  final int? version;

  /// 落档回调；null = 不显示落档按钮。
  final Future<void> Function()? onFinalize;

  final bool showFinalize;

  /// 门控条件（open high / 追踪断链）变化时通知外层（准备页控制落档）。
  final ValueChanged<bool>? onBlockingChanged;

  @override
  State<ProductionPlanReview> createState() => _ProductionPlanReviewState();
}

class _ProductionPlanReviewState extends State<ProductionPlanReview> {
  bool _loading = true;
  bool _busy = false;
  String _error = '';
  String _version = '';
  Map<String, dynamic> _plan = <String, dynamic>{};
  List<Map<String, dynamic>> _findings = <Map<String, dynamic>>[];
  Map<String, dynamic>? _previous;

  List<Map<String, dynamic>> get _openHigh =>
      productionOpenHighFindings(_plan, _findings);

  List<String> get _broken => productionTraceabilityBroken(_plan);

  bool get _blocked => _openHigh.isNotEmpty || _broken.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ProductionPlanReview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lineId != widget.lineId ||
        oldWidget.teamId != widget.teamId ||
        oldWidget.version != widget.version) {
      _previous = null;
      _load();
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = _plan.isEmpty;
      _error = '';
    });
    try {
      final Map<String, dynamic> data = await ApiService.getProductionPlan(
        widget.lineId,
        teamId: widget.teamId,
        version: widget.version,
      );
      if (!mounted) return;
      final Map<String, dynamic> plan = productionMap(data['plan']);
      final String version = '${data['version'] ?? ''}'.trim();
      setState(() {
        _loading = false;
        _version = version;
        _plan = plan;
        _findings = productionListOf(data, 'findings');
      });
      widget.onBlockingChanged?.call(_blocked);
      await _loadPrevious(version);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = productionReadable(error, '计划加载失败');
      });
    }
  }

  /// 读上一版做 diff（plan-v1 没有上一版）。
  Future<void> _loadPrevious(String version) async {
    final int? current =
        int.tryParse(version.replaceFirst('plan-v', '').trim()) ??
        widget.version;
    if (current == null || current <= 1) return;
    try {
      final Map<String, dynamic> data = await ApiService.getProductionPlan(
        widget.lineId,
        teamId: widget.teamId,
        version: current - 1,
      );
      if (!mounted) return;
      setState(() => _previous = productionMap(data['plan']));
    } catch (_) {
      // 历史版本读不到：diff 区降级成「无上一版」，不影响当前计划审查。
    }
  }

  Future<void> _finalize() async {
    final Future<void> Function()? action = widget.onFinalize;
    if (action == null || _busy || _blocked) return;
    setState(() => _busy = true);
    try {
      await action();
      await _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(productionReadable(error, '落档失败'))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Center(child: CircularProgressIndicator()),
      );
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
              key: const Key('production-plan-retry'),
              onPressed: _load,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final String version = _version.isEmpty ? '还没有计划版本' : _version;
    final List<String> missing = productionPlanMissingBlocks(_plan);
    return SingleChildScrollView(
      key: const Key('production-plan-review'),
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
            child: Row(
              children: <Widget>[
                Icon(Icons.description_outlined, size: 16, color: cs.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '计划审查 · $version',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '刷新计划',
                  visualDensity: VisualDensity.compact,
                  onPressed: _load,
                  icon: const Icon(Icons.refresh, size: 18),
                ),
              ],
            ),
          ),
          if (missing.isNotEmpty)
            _banner(
              cs,
              cs.error,
              '缺块：${missing.join('、')}（落档前必须补齐 7 块）',
            ),
          if (_openHigh.isNotEmpty)
            _banner(
              cs,
              cs.error,
              '有 ${_openHigh.length} 条未关闭的 high findings：先处理或显式关闭，才能落档',
              key: const Key('production-plan-open-high'),
            ),
          if (_broken.isNotEmpty)
            _banner(
              cs,
              cs.error,
              '追踪矩阵有 ${_broken.length} 处断链：需求必须能映射到任务与门控',
              key: const Key('production-plan-broken'),
            ),
          ..._buildFindings(cs),
          _block(cs, '① 方案设计', _buildDesign(cs)),
          _block(cs, '② 不变量账本', _buildInvariants(cs)),
          _block(cs, '③ 任务 DAG', _buildTasks(cs)),
          _block(cs, '④ 出口门禁', _buildGates(cs)),
          _block(cs, '⑤ 追踪矩阵', _buildTraceability(cs)),
          _block(cs, '⑥ 风险与未知', _buildRisks(cs)),
          _block(cs, '⑦ 变更控制', _buildChangeControl(cs)),
          _block(cs, '批次', _buildBatches(cs)),
          _block(cs, '版本差异', _buildDiff(cs)),
          if (widget.showFinalize)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: <Widget>[
                  Tooltip(
                    message: _blocked
                        ? '落档被阻止：${_openHigh.isNotEmpty ? '有未关闭 high findings；' : ''}'
                              '${_broken.isNotEmpty ? '追踪矩阵断链；' : ''}'
                        : '写 scope / plan / acceptance，并建 queued 任务',
                    child: FilledButton(
                      key: const Key('production-plan-finalize'),
                      onPressed: _blocked || _busy || widget.onFinalize == null
                          ? null
                          : _finalize,
                      child: Text(_busy ? '落档中…' : '落档'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_blocked)
                    Expanded(
                      child: Text(
                        '先关闭 high findings / 补齐追踪矩阵',
                        style: TextStyle(fontSize: 11, color: cs.error),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _banner(ColorScheme cs, Color color, String text, {Key? key}) => Padding(
    key: key,
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(text, style: TextStyle(fontSize: 11.5, color: color)),
    ),
  );

  Widget _block(ColorScheme cs, String title, List<Widget> children) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: cs.onSurfaceVariant,
          ),
        ),
      ),
      if (children.isEmpty)
        _muted(cs, '（空）')
      else
        ...children,
    ],
  );

  Widget _muted(ColorScheme cs, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 1, 16, 2),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
    ),
  );

  List<Widget> _buildFindings(ColorScheme cs) {
    if (_findings.isEmpty && productionListOf(_plan, 'findings').isEmpty) {
      return const <Widget>[];
    }
    final List<Map<String, dynamic>> all = <Map<String, dynamic>>[
      ...productionListOf(_plan, 'findings'),
      ..._findings,
    ];
    final Set<String> seen = <String>{};
    final List<Map<String, dynamic>> unique = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> finding in all) {
      final String id =
          '${finding['id'] ?? finding['text'] ?? finding['message'] ?? ''}';
      if (id.isNotEmpty && !seen.add(id)) continue;
      unique.add(finding);
    }
    List<Map<String, dynamic>> of(String severity) => <Map<String, dynamic>>[
      for (final Map<String, dynamic> finding in unique)
        if ('${finding['severity'] ?? ''}'.trim().toLowerCase() == severity)
          finding,
    ];
    final List<Widget> out = <Widget>[];
    for (final String severity in const <String>['high', 'medium', 'low']) {
      final List<Map<String, dynamic>> items = of(severity);
      if (items.isEmpty) continue;
      out.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 1),
          child: Text(
            'findings · $severity（${items.length}）',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: severity == 'high' ? cs.error : cs.onSurfaceVariant,
            ),
          ),
        ),
      );
      final List<Map<String, dynamic>> sorted = List<Map<String, dynamic>>.of(
        items,
      )..sort((Map<String, dynamic> a, Map<String, dynamic> b) {
        final bool aOpen = !_isClosed(a);
        final bool bOpen = !_isClosed(b);
        return aOpen == bOpen ? 0 : (aOpen ? -1 : 1);
      });
      for (final Map<String, dynamic> finding in sorted) {
        final bool open = !_isClosed(finding);
        out.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 1, 16, 1),
            child: Text(
              '${open ? '●' : '○'} ${_findingText(finding)}'
              '${_evidenceOf(finding).isEmpty ? '' : ' · 证据 ${_evidenceOf(finding)}'}',
              style: TextStyle(
                fontSize: 11,
                color: severity == 'high' && open
                    ? cs.error
                    : cs.onSurface,
              ),
            ),
          ),
        );
      }
    }
    return out;
  }

  bool _isClosed(Map<String, dynamic> finding) => const <String>{
    'closed',
    'resolved',
    'accepted',
    'waived',
    'done',
  }.contains('${finding['status'] ?? 'open'}'.trim().toLowerCase());

  String _findingText(Map<String, dynamic> finding) => <String>[
    if ('${finding['id'] ?? ''}'.trim().isNotEmpty) '${finding['id']}',
    '${finding['text'] ?? finding['message'] ?? finding['issue'] ?? ''}',
    if ('${finding['status'] ?? ''}'.trim().isNotEmpty)
      '（${finding['status']}）',
  ].join(' ').trim();

  String _evidenceOf(Map<String, dynamic> finding) {
    final Object? raw = finding['evidence'];
    if (raw is List) return raw.map((Object? item) => '$item').join('、');
    return '${raw ?? ''}'.trim();
  }

  List<Widget> _buildDesign(ColorScheme cs) {
    final Map<String, dynamic> design = productionMap(_plan['design']);
    if (design.isEmpty) return const <Widget>[];
    return <Widget>[
      for (final MapEntry<String, dynamic> entry in design.entries)
        _kv(cs, entry.key, entry.value),
    ];
  }

  List<Widget> _buildInvariants(ColorScheme cs) => <Widget>[
    for (final Map<String, dynamic> item in productionListOf(
      _plan,
      'invariants',
    ))
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 1, 16, 1),
        child: Text(
          '· ${item['id'] ?? ''} ${item['text'] ?? item['statement'] ?? item}'
          '${'${item['owner'] ?? ''}'.isEmpty ? '' : ' · owner ${item['owner']}'}',
          style: const TextStyle(fontSize: 11),
        ),
      ),
  ];

  List<Widget> _buildTasks(ColorScheme cs) {
    final List<Map<String, dynamic>> tasks = productionListOf(_plan, 'tasks');
    final Map<String, dynamic> gates = productionMap(_plan['gates']);
    return <Widget>[
      for (final Map<String, dynamic> task in tasks)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 3, 16, 3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '${task['id'] ?? ''}  ${task['title'] ?? ''}'
                '${'${task['task_type'] ?? ''}'.isEmpty ? '' : ' · ${task['task_type']}'}'
                '${'${task['risk'] ?? ''}'.isEmpty ? '' : ' · 风险 ${task['risk']}'}',
                style: const TextStyle(fontSize: 12),
              ),
              if ((task['depends_on'] as List<dynamic>? ?? <dynamic>[])
                  .isNotEmpty)
                Text(
                  '依赖：${(task['depends_on'] as List<dynamic>).join('、')}',
                  style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant),
                ),
              for (final Map<String, dynamic> item in <Map<String, dynamic>>[
                ...productionListOf(
                  <String, dynamic>{'items': gates['${task['id'] ?? ''}']},
                  'items',
                ),
              ])
                Text(
                  item['evidence'] == null || '${item['evidence']}'.trim().isEmpty
                      ? '- [ ] ${item['text'] ?? ''} · 缺 evidence'
                      : '- [ ] ${item['text'] ?? ''} · ${item['evidence']}',
                  style: TextStyle(
                    fontSize: 10.5,
                    color:
                        item['evidence'] == null ||
                            '${item['evidence']}'.trim().isEmpty
                        ? cs.error
                        : cs.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
    ];
  }

  List<Widget> _buildGates(ColorScheme cs) {
    final Map<String, dynamic> gates = productionMap(_plan['gates']);
    if (gates.isEmpty) return const <Widget>[];
    final List<Widget> out = <Widget>[];
    for (final MapEntry<String, dynamic> entry in gates.entries) {
      final List<Map<String, dynamic>> items = productionListOf(
        <String, dynamic>{'items': entry.value},
        'items',
      );
      out.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 3, 16, 0),
          child: Text(
            '${entry.key}（${items.length}）',
            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
          ),
        ),
      );
      for (final Map<String, dynamic> item in items) {
        final String evidence = '${item['evidence'] ?? ''}'.trim();
        out.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 1, 16, 1),
            child: Text(
              '- [ ] ${item['text'] ?? ''}'
              '${evidence.isEmpty ? ' · 缺 evidence' : ' · $evidence'}',
              style: TextStyle(
                fontSize: 10.5,
                color: evidence.isEmpty ? cs.error : cs.onSurfaceVariant,
              ),
            ),
          ),
        );
      }
    }
    return out;
  }

  List<Widget> _buildTraceability(ColorScheme cs) {
    final List<Map<String, dynamic>> rows = productionListOf(
      _plan,
      'traceability',
    );
    if (rows.isEmpty) return const <Widget>[];
    return <Widget>[
      for (final Map<String, dynamic> row in rows)
        Builder(
          builder: (BuildContext context) {
            final String req = '${row['req'] ?? ''}'.trim();
            final bool broken = _broken.any(
              (String message) => req.isEmpty || message.contains(req),
            );
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 1, 16, 1),
              child: Text(
                '${row['req'] ?? ''} → '
                '${(row['tasks'] as List<dynamic>? ?? <dynamic>[]).join('、')}'
                ' → ${(row['gates'] as List<dynamic>? ?? <dynamic>[]).map((Object? item) => item is Map ? '${productionMap(item)['text'] ?? productionMap(item)['key'] ?? ''}' : '$item').join('、')}'
                '${broken ? '  ⚠ 断链' : ''}',
                style: TextStyle(
                  fontSize: 11,
                  color: broken ? cs.error : cs.onSurface,
                  fontWeight: broken ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            );
          },
        ),
    ];
  }

  List<Widget> _buildRisks(ColorScheme cs) => <Widget>[
    for (final Map<String, dynamic> item in <Map<String, dynamic>>[
      ...productionListOf(_plan, 'risks'),
      ...productionListOf(_plan, 'unknowns'),
    ])
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 1, 16, 1),
        child: Text(
          '· ${item['id'] ?? ''} ${item['text'] ?? item['risk'] ?? item}'
          '${'${item['mitigation'] ?? ''}'.isEmpty ? '' : ' · 缓解：${item['mitigation']}'}',
          style: const TextStyle(fontSize: 11),
        ),
      ),
  ];

  List<Widget> _buildChangeControl(ColorScheme cs) {
    final Map<String, dynamic> control = productionMap(_plan['change_control']);
    final List<Map<String, dynamic>> decisions = productionListOf(
      _plan,
      'decisions',
    );
    return <Widget>[
      for (final MapEntry<String, dynamic> entry in control.entries)
        _kv(cs, entry.key, entry.value),
      for (final Map<String, dynamic> decision in decisions)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 1, 16, 1),
          child: Text(
            '· ${decision['id'] ?? ''} ${decision['text'] ?? decision['decision'] ?? ''}'
            '${'${decision['status'] ?? ''}'.isEmpty ? '' : '（${decision['status']}）'}',
            style: const TextStyle(fontSize: 11),
          ),
        ),
    ];
  }

  List<Widget> _buildBatches(ColorScheme cs) {
    final List<List<Map<String, dynamic>>> batches = productionPlanBatches(
      _plan,
    );
    if (batches.isEmpty) return const <Widget>[];
    return <Widget>[
      for (int i = 0; i < batches.length; i++)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 1, 16, 1),
          child: Text(
            '批次 ${i + 1}：${batches[i].map((Map<String, dynamic> task) => '${task['id'] ?? ''}').join('、')}',
            style: const TextStyle(fontSize: 11),
          ),
        ),
    ];
  }

  List<Widget> _buildDiff(ColorScheme cs) {
    final Map<String, dynamic>? previous = _previous;
    if (previous == null) return <Widget>[_muted(cs, '没有上一版可比较')];
    final Map<String, Map<String, dynamic>> before = <String, Map<String, dynamic>>{
      for (final Map<String, dynamic> task in productionListOf(previous, 'tasks'))
        '${task['id'] ?? ''}': task,
    };
    final Map<String, Map<String, dynamic>> after = <String, Map<String, dynamic>>{
      for (final Map<String, dynamic> task in productionListOf(_plan, 'tasks'))
        '${task['id'] ?? ''}': task,
    };
    final List<String> added = <String>[
      for (final String id in after.keys)
        if (!before.containsKey(id)) id,
    ];
    final List<String> removed = <String>[
      for (final String id in before.keys)
        if (!after.containsKey(id)) id,
    ];
    final List<String> modified = <String>[
      for (final String id in after.keys)
        if (before.containsKey(id) &&
            jsonEncode(before[id]) != jsonEncode(after[id]))
          id,
    ];
    final Set<String> beforeTrace = <String>{
      for (final Map<String, dynamic> row in productionListOf(
        previous,
        'traceability',
      ))
        jsonEncode(row),
    };
    final Set<String> afterTrace = <String>{
      for (final Map<String, dynamic> row in productionListOf(
        _plan,
        'traceability',
      ))
        jsonEncode(row),
    };
    final int traceAdded = afterTrace.difference(beforeTrace).length;
    final int traceRemoved = beforeTrace.difference(afterTrace).length;
    return <Widget>[
      _muted(
        cs,
        '新增任务：${added.isEmpty ? '无' : added.join('、')}',
      ),
      _muted(
        cs,
        '删除任务：${removed.isEmpty ? '无' : removed.join('、')}',
      ),
      _muted(
        cs,
        '修改任务：${modified.isEmpty ? '无' : modified.join('、')}',
      ),
      _muted(
        cs,
        '追踪变化：新增 $traceAdded 条 / 删除 $traceRemoved 条',
      ),
    ];
  }

  Widget _kv(ColorScheme cs, String key, Object? value) {
    final String text = value is Map || value is List
        ? jsonEncode(value)
        : '${value ?? ''}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 1, 16, 1),
      child: Text(
        '$key：$text',
        style: TextStyle(fontSize: 11, color: cs.onSurface),
      ),
    );
  }
}
