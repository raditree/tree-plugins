import 'package:flutter/material.dart';

import '../../io/api_service.dart';

/// 左栏「产线」面板（活动栏第 4 项）。
///
/// 切片 2 只读：产线列表 → 展开看任务队列 / 运行台账，再按需拉产物树与项目
/// 整理报告。数据全部走 REST（`/api/production/*`，由 `tree.production.line`
/// 插件承接）；UI 不直连插件、不读写插件数据。
///
/// 依赖缺失（插件未安装 / 停用 ⇒ 503）必须给出可读说明，而不是把
/// `HTTP 404` 摊在空列表上。
class ProductionLinePanel extends StatefulWidget {
  const ProductionLinePanel({
    super.key,
    required this.teamId,
    this.visible = true,
    this.onCollapse,
  });

  /// 团队归属（= 顶部 Agent 的 `teamScopeId`）；空串时提示先选 Agent。
  final String teamId;

  /// 面板是否露脸：由隐藏变可见时重拉清单（与插件面板同一口径）。
  final bool visible;

  final VoidCallback? onCollapse;

  @override
  State<ProductionLinePanel> createState() => _ProductionLinePanelState();
}

class _ProductionLinePanelState extends State<ProductionLinePanel> {
  bool _loading = true;
  String _error = '';
  String _emptyHint = '';
  List<Map<String, dynamic>> _lines = <Map<String, dynamic>>[];

  /// 展开行的明细缓存（按 lineId）；`_detailErrors` 里有的行不再自动重试。
  final Map<String, List<Map<String, dynamic>>> _tasks =
      <String, List<Map<String, dynamic>>>{};
  final Map<String, List<Map<String, dynamic>>> _runs =
      <String, List<Map<String, dynamic>>>{};
  final Map<String, Map<String, dynamic>> _artifacts =
      <String, Map<String, dynamic>>{};
  final Map<String, Map<String, dynamic>> _audits =
      <String, Map<String, dynamic>>{};
  final Map<String, String> _detailErrors = <String, String>{};
  final Set<String> _detailBusy = <String>{};

  String _expanded = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ProductionLinePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.teamId != widget.teamId) {
      _tasks.clear();
      _runs.clear();
      _artifacts.clear();
      _audits.clear();
      _detailErrors.clear();
      _expanded = '';
      _lines = <Map<String, dynamic>>[];
      _loading = true;
      _load();
      return;
    }
    if (!oldWidget.visible && widget.visible) _load();
  }

  Future<void> _load() async {
    final String teamId = widget.teamId.trim();
    if (teamId.isEmpty) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '';
        _lines = <Map<String, dynamic>>[];
        _emptyHint = '先在左侧选择一个 Agent（团队），再查看它的生产线。';
      });
      return;
    }
    if (mounted) {
      setState(() {
        _loading = _lines.isEmpty;
        _error = '';
      });
    }
    try {
      final Map<String, dynamic> data = await ApiService.getProductionLines(
        teamId: teamId,
      );
      if (!mounted) return;
      final List<Map<String, dynamic>> lines =
          (data['lines'] as List<dynamic>? ?? <dynamic>[])
              .whereType<Map>()
              .map(_map)
              .toList();
      setState(() {
        _loading = false;
        _lines = lines;
        _emptyHint = lines.isEmpty
            ? '还没有产线：新建入口在切片 3 开放（当前只读列表 / 队列 / 台账）。'
            : '';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _readable(error, '产线列表加载失败');
      });
    }
  }

  Future<void> _toggleLine(String lineId) async {
    if (_expanded == lineId) {
      setState(() => _expanded = '');
      return;
    }
    setState(() => _expanded = lineId);
    if (_tasks.containsKey(lineId) || _detailErrors.containsKey(lineId)) return;
    await _loadDetails(lineId);
  }

  Future<void> _loadDetails(String lineId) async {
    final String teamId = widget.teamId.trim();
    setState(() {
      _detailBusy.add(lineId);
      _detailErrors.remove(lineId);
    });
    try {
      final List<Map<String, dynamic>> results = await Future.wait(
        <Future<Map<String, dynamic>>>[
          ApiService.getProductionTasks(lineId, teamId: teamId),
          ApiService.getProductionRuns(lineId, teamId: teamId),
        ],
      );
      if (!mounted) return;
      setState(() {
        _tasks[lineId] = _listOf(results[0], 'tasks');
        _runs[lineId] = _listOf(results[1], 'runs');
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _detailErrors[lineId] = _readable(error, '产线明细加载失败');
      });
    } finally {
      if (mounted) setState(() => _detailBusy.remove(lineId));
    }
  }

  Future<void> _loadArtifacts(String lineId) async {
    if (_artifacts.containsKey(lineId)) {
      setState(() => _artifacts.remove(lineId));
      return;
    }
    setState(() => _detailBusy.add(lineId));
    try {
      final Map<String, dynamic> data = await ApiService.getProductionArtifacts(
        lineId,
        teamId: widget.teamId,
      );
      if (!mounted) return;
      setState(() => _artifacts[lineId] = data);
    } catch (error) {
      if (!mounted) return;
      setState(() => _detailErrors[lineId] = _readable(error, '产物加载失败'));
    } finally {
      if (mounted) setState(() => _detailBusy.remove(lineId));
    }
  }

  Future<void> _loadAudit(String lineId) async {
    if (_audits.containsKey(lineId)) {
      setState(() => _audits.remove(lineId));
      return;
    }
    setState(() => _detailBusy.add(lineId));
    try {
      final Map<String, dynamic> data = await ApiService.getProductionAudit(
        lineId,
        teamId: widget.teamId,
      );
      if (!mounted) return;
      setState(() => _audits[lineId] = data);
    } catch (error) {
      if (!mounted) return;
      setState(() => _detailErrors[lineId] = _readable(error, '整理报告加载失败'));
    } finally {
      if (mounted) setState(() => _detailBusy.remove(lineId));
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
                '生产线',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: '刷新产线列表',
                visualDensity: VisualDensity.compact,
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh, size: 18),
              ),
              if (widget.onCollapse != null)
                IconButton(
                  tooltip: '收起左栏',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onCollapse,
                  icon: const Icon(Icons.chevron_left, size: 18),
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
            Text(
              _error,
              style: TextStyle(fontSize: 12, color: cs.error),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('production-line-retry'),
              onPressed: _load,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_lines.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          _emptyHint,
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
      );
    }
    return ListView(
      key: const Key('production-line-list'),
      padding: const EdgeInsets.only(bottom: 12),
      children: <Widget>[
        for (final Map<String, dynamic> line in _lines) _buildLine(cs, line),
      ],
    );
  }

  Widget _buildLine(ColorScheme cs, Map<String, dynamic> line) {
    final String id = '${line['id'] ?? ''}';
    final String name = '${line['name'] ?? id}';
    final String status = '${line['status'] ?? 'idle'}';
    final bool expanded = _expanded == id;
    final bool busy = _detailBusy.contains(id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InkWell(
          onTap: () => _toggleLine(id),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: Row(
              children: <Widget>[
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: cs.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: _statusColor(cs, status),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '$id · $status',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (busy)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
        ),
        if (expanded) ..._buildDetail(cs, id),
        const Divider(height: 1),
      ],
    );
  }

  List<Widget> _buildDetail(ColorScheme cs, String lineId) {
    final String error = _detailErrors[lineId] ?? '';
    if (error.isNotEmpty) {
      return <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 4, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                error,
                style: TextStyle(fontSize: 11.5, color: cs.error),
              ),
              TextButton(
                onPressed: () {
                  setState(() => _detailErrors.remove(lineId));
                  _loadDetails(lineId);
                },
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      ];
    }
    if (!_tasks.containsKey(lineId)) {
      return <Widget>[
        const Padding(
          padding: EdgeInsets.fromLTRB(28, 4, 12, 10),
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ];
    }
    final List<Map<String, dynamic>> tasks = _tasks[lineId] ?? const [];
    final List<Map<String, dynamic>> runs = _runs[lineId] ?? const [];
    final Map<String, dynamic>? artifacts = _artifacts[lineId];
    final Map<String, dynamic>? audit = _audits[lineId];
    return <Widget>[
      _sectionTitle(cs, '任务队列', '${tasks.length}'),
      if (tasks.isEmpty)
        _muted(cs, '队列为空')
      else
        for (final Map<String, dynamic> task in tasks.take(20))
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 1, 12, 1),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Text(
                    '${task['id'] ?? ''}  ${task['title'] ?? ''}',
                    style: const TextStyle(fontSize: 11.5),
                  ),
                ),
                Text(
                  '${task['status'] ?? ''}',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: _statusColor(cs, '${task['status'] ?? ''}'),
                  ),
                ),
              ],
            ),
          ),
      _sectionTitle(cs, '运行台账', '${runs.length}'),
      if (runs.isEmpty)
        _muted(cs, '还没有运行记录')
      else
        for (final Map<String, dynamic> run in runs.take(10))
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 1, 12, 1),
            child: Text(
              _runLabel(run),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5),
            ),
          ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 8, 0),
        child: Wrap(
          spacing: 4,
          children: <Widget>[
            TextButton(
              onPressed: () => _loadArtifacts(lineId),
              child: Text(artifacts == null ? '产物' : '收起产物'),
            ),
            TextButton(
              onPressed: () => _loadAudit(lineId),
              child: Text(audit == null ? '整理报告' : '收起报告'),
            ),
          ],
        ),
      ),
      if (artifacts != null) ..._buildArtifacts(cs, artifacts),
      if (audit != null) ..._buildAudit(cs, audit),
      const SizedBox(height: 6),
    ];
  }

  List<Widget> _buildArtifacts(ColorScheme cs, Map<String, dynamic> data) {
    final String note = '${data['note'] ?? ''}';
    final List<dynamic> files =
        data['files'] as List<dynamic>? ?? <dynamic>[];
    return <Widget>[
      if (note.isNotEmpty) _muted(cs, note),
      if (files.isEmpty && note.isEmpty) _muted(cs, '还没有产物'),
      for (final dynamic raw in files.take(30))
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 1, 12, 1),
          child: Text(
            '${_map(raw)['path'] ?? ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
        ),
    ];
  }

  List<Widget> _buildAudit(ColorScheme cs, Map<String, dynamic> data) {
    final Map<String, dynamic> report = _map(data['report']);
    final int scanned = (report['scanned'] as num?)?.toInt() ?? 0;
    final List<dynamic> todos = report['todos'] as List<dynamic>? ?? <dynamic>[];
    final List<dynamic> missing =
        report['docs_missing'] as List<dynamic>? ?? <dynamic>[];
    final List<dynamic> duplicates =
        report['duplicates'] as List<dynamic>? ?? <dynamic>[];
    final List<dynamic> large =
        report['large_files'] as List<dynamic>? ?? <dynamic>[];
    final List<dynamic> notes =
        report['notes'] as List<dynamic>? ?? <dynamic>[];
    return <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(28, 2, 12, 2),
        child: Text(
          '扫描 $scanned 个文件 · TODO ${todos.length} · 缺文档 ${missing.length} · '
          '重复 ${duplicates.length} · 超大 ${large.length}',
          style: const TextStyle(fontSize: 11),
        ),
      ),
      for (final dynamic note in notes)
        _muted(cs, '$note'),
    ];
  }

  Widget _sectionTitle(ColorScheme cs, String title, String count) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 6, 12, 2),
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
    padding: const EdgeInsets.fromLTRB(28, 1, 12, 3),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
    ),
  );

  static String _runLabel(Map<String, dynamic> run) {
    final String taskId = '${run['task_id'] ?? ''}';
    return '${run['role'] ?? ''} · ${run['status'] ?? ''}'
        '${taskId.isEmpty ? '' : ' · $taskId'}';
  }

  static Color _statusColor(ColorScheme cs, String status) {
    switch (status) {
      case 'done':
        return cs.primary;
      case 'blocked':
      case 'cancelled':
        return cs.error;
      case 'running':
      case 'gating':
      case 'packing':
        return cs.tertiary;
      case 'queued':
      case 'packed':
        return cs.secondary;
      default:
        return cs.outline;
    }
  }

  static String _readable(Object error, String prefix) {
    String text = '$error'.trim();
    if (text.startsWith('Exception: ')) {
      text = text.substring('Exception: '.length).trim();
    }
    // 归属插件未安装 / 停用：核心回 503 且点名插件；给可操作说明。
    final bool missing =
        (text.contains('tree.production.line') || text.contains('503')) &&
        (text.contains('未安装') ||
            text.contains('未启用') ||
            text.contains('不可用') ||
            text.contains('503'));
    if (missing) {
      return '未安装 tree.production.line 插件（或已停用）：产线是独立插件的能力。'
          '在「插件管理」里安装并启用后重启核心即可出现。';
    }
    return text.isEmpty ? prefix : '$prefix：$text';
  }

  static List<Map<String, dynamic>> _listOf(
    Map<String, dynamic> data,
    String key,
  ) => (data[key] as List<dynamic>? ?? <dynamic>[])
      .whereType<Map>()
      .map(_map)
      .toList();

  static Map<String, dynamic> _map(Object? raw) => raw is Map
      ? raw.map(
          (Object? key, Object? value) =>
              MapEntry<String, dynamic>('$key', value),
        )
      : <String, dynamic>{};
}
