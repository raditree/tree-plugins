import 'package:flutter/material.dart';

import '../../io/api_service.dart';

/// 左栏「产线」面板（活动栏第 4 项）。
///
/// 读：产线列表 → 展开看任务队列 / 运行台账，再按需拉产物树与项目整理报告。
/// 写（切片 3）：新建 / 删除产线、建任务、派发（打包 / 执行）、拍板回答、取消。
/// 数据全部走 REST（`/api/production/*`，由 `tree.production.line` 插件承接）；
/// UI 不直连插件、不读写插件数据。
///
/// 依赖缺失（插件未安装 / 停用 ⇒ 503）必须给出可读说明，而不是把
/// `HTTP 404` 摊在空列表上。
class ProductionLinePanel extends StatefulWidget {
  const ProductionLinePanel({
    super.key,
    required this.teamId,
    this.agentId = '',
    this.visible = true,
    this.onCollapse,
  });

  /// 团队归属（= 顶部 Agent 的 `teamScopeId`）；空串时提示先选 Agent。
  final String teamId;

  /// 发起者身份：派发时员工按它继承工作空间与团队（缺省不能派发）。
  final String agentId;

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
            ? '还没有产线：点右上角「+」新建一条（生产数据落插件数据根）。'
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

  /// 单条产线 / 任务的写操作进行中（按钮转圈、防重复提交）。
  final Set<String> _actionBusy = <String>{};

  String get _teamId => widget.teamId.trim();

  String get _agentId => widget.agentId.trim();

  /// 统一收口：忙碌标记 + 可读错误（SnackBar，不打断面板状态）。
  Future<void> _act(String key, Future<void> Function() action) async {
    if (_actionBusy.contains(key)) return;
    setState(() => _actionBusy.add(key));
    try {
      await action();
    } catch (error) {
      _notify(_readable(error, '操作失败'));
    } finally {
      if (mounted) setState(() => _actionBusy.remove(key));
    }
  }

  void _notify(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(text)));
  }

  /// 写操作后重拉某条产线的明细（清缓存，避免停在旧状态）。
  Future<void> _reloadDetails(String lineId) async {
    setState(() {
      _tasks.remove(lineId);
      _runs.remove(lineId);
      _detailErrors.remove(lineId);
    });
    await _loadDetails(lineId);
  }

  Future<void> _createLine() async {
    String nameText = '';
    String workspaceText = '';
    final String? confirmed = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('新建产线'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextFormField(
                key: const Key('production-line-name'),
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '标准开发流',
                ),
                onChanged: (String value) => nameText = value.trim(),
              ),
              TextFormField(
                key: const Key('production-line-workspace'),
                decoration: const InputDecoration(
                  labelText: '工作空间（可空）',
                  hintText: 'E:/work/project',
                  helperText: '准备阶段与门控都在这个目录里执行',
                ),
                onChanged: (String value) => workspaceText = value.trim(),
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
            onPressed: () => Navigator.of(context).pop(nameText),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (confirmed == null || confirmed.isEmpty) return;
    await _act('create-line', () async {
      await ApiService.createProductionLine(
        name: confirmed,
        workspaceDir: workspaceText,
        teamId: _teamId,
      );
      await _load();
      _notify('已创建产线：$confirmed');
    });
  }

  Future<void> _deleteLine(String lineId) async {
    if (!await _confirm('删除产线 $lineId？', '插件数据会删除，项目资产（docs/ 下）保留。')) {
      return;
    }
    await _act('$lineId/delete', () async {
      final Map<String, dynamic> result = await ApiService.deleteProductionLine(
        lineId,
        teamId: _teamId,
      );
      if (_expanded == lineId) setState(() => _expanded = '');
      await _load();
      _notify(
        '${result['note'] is String && '${result['note']}'.isNotEmpty ? result['note'] : '已删除产线：$lineId'}',
      );
    });
  }

  Future<void> _createTask(String lineId) async {
    String titleText = '';
    String scopeText = '';
    final String? confirmed = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('新建任务 · $lineId'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextFormField(
                key: const Key('production-task-title'),
                autofocus: true,
                decoration: const InputDecoration(labelText: '标题'),
                onChanged: (String value) => titleText = value.trim(),
              ),
              TextFormField(
                key: const Key('production-task-scope'),
                decoration: const InputDecoration(
                  labelText: '写域（逗号分隔，可空）',
                  hintText: 'lib/ui/widgets/agent_list.dart',
                  helperText: '执行阶段只允许改这些路径；留空则不能打包',
                ),
                onChanged: (String value) => scopeText = value.trim(),
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
            onPressed: () => Navigator.of(context).pop(titleText),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (confirmed == null || confirmed.isEmpty) return;
    await _act('$lineId/create-task', () async {
      await ApiService.createProductionTask(
        lineId,
        <String, dynamic>{
          'title': confirmed,
          'status': 'queued',
          'priority': 50,
          'write_scope': <String>[
            for (final String item in scopeText.split(','))
              if (item.trim().isNotEmpty) item.trim(),
          ],
        },
        teamId: _teamId,
      );
      await _reloadDetails(lineId);
      _notify('已建任务：$confirmed');
    });
  }

  Future<void> _dispatch(String lineId, String taskId, String stage) async {
    if (_agentId.isEmpty) {
      _notify('先在左侧选择一个 Agent：派发要用它的身份跑员工');
      return;
    }
    await _act('$lineId/$taskId/dispatch', () async {
      final Map<String, dynamic> result = await ApiService.dispatchProductionTask(
        lineId,
        taskId,
        stage: stage,
        agentId: _agentId,
        teamId: _teamId,
      );
      await _reloadDetails(lineId);
      _notify(
        result['accepted'] == true
            ? '已受理${stage == 'run' ? '执行' : '打包'}：进度看任务状态与运行台账'
            : '${result['status'] ?? '已完成'}：$taskId',
      );
    });
  }

  Future<void> _cancelTask(String lineId, String taskId) async {
    if (!await _confirm('取消任务 $taskId？', '取消后不可再迁移（保留在队列里可追溯）。')) {
      return;
    }
    await _act('$lineId/$taskId/cancel', () async {
      await ApiService.cancelProductionTask(
        lineId,
        taskId,
        teamId: _teamId,
      );
      await _reloadDetails(lineId);
      _notify('已取消：$taskId');
    });
  }

  /// 拍板：先拉待答问题，再让用户逐条回答或「全部按推荐」。
  Future<void> _decide(String lineId, String taskId) async {
    await _act('$lineId/$taskId/decide', () async {
      final Map<String, dynamic> data = await ApiService.getProductionQuestions(
        lineId,
        taskId,
        teamId: _teamId,
      );
      final List<Map<String, dynamic>> open =
          (data['open'] as List<dynamic>? ?? <dynamic>[])
              .whereType<Map>()
              .map(_map)
              .toList();
      if (open.isEmpty) {
        _notify('任务 $taskId 没有待答问题');
        return;
      }
      if (!mounted) return;
      final Map<String, String> values = <String, String>{
        for (final Map<String, dynamic> question in open)
          '${question['qid'] ?? ''}':
              '${question['recommended'] ?? question['default'] ?? ''}',
      };
      String? choice;
      await showDialog<void>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: Text('拍板 · $taskId'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (final Map<String, dynamic> question in open) ...<Widget>[
                    Text(
                      '${question['qid'] ?? ''}  ${question['text'] ?? ''}',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                    if ('${question['consequence'] ?? ''}'.isNotEmpty)
                      Text(
                        '后果：${question['consequence']}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    TextFormField(
                      key: Key('production-answer-${question['qid'] ?? ''}'),
                      initialValue: values['${question['qid'] ?? ''}'],
                      decoration: InputDecoration(
                        helperText:
                            '默认：${question['default'] ?? '（无）'} · '
                            '推荐：${question['recommended'] ?? '（无）'}',
                      ),
                      onChanged: (String value) =>
                          values['${question['qid'] ?? ''}'] = value.trim(),
                    ),
                    const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              key: const Key('production-decide-recommended'),
              onPressed: () {
                choice = 'recommended';
                Navigator.of(context).pop();
              },
              child: const Text('全部按推荐'),
            ),
            FilledButton(
              key: const Key('production-decide-submit'),
              onPressed: () {
                choice = 'submit';
                Navigator.of(context).pop();
              },
              child: const Text('提交回答'),
            ),
          ],
        ),
      );
      final String? submitted = choice;
      if (submitted == null) return;
      final Map<String, dynamic> result = submitted == 'recommended'
          ? await ApiService.decideProductionTask(
              lineId,
              taskId,
              allRecommended: true,
              teamId: _teamId,
            )
          : await ApiService.decideProductionTask(
              lineId,
              taskId,
              answers: <Map<String, String>>[
                for (final Map<String, dynamic> question in open)
                  <String, String>{
                    'qid': '${question['qid'] ?? ''}',
                    'value': values['${question['qid'] ?? ''}'] ?? '',
                  },
              ],
              teamId: _teamId,
            );
      await _reloadDetails(lineId);
      _notify('已记录拍板：剩余 ${result['open'] ?? 0} 条未答');
    });
  }

  Future<bool> _confirm(String title, String body) async {
    if (!mounted) return false;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('production-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return ok == true;
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
                tooltip: '新建产线',
                key: const Key('production-line-create'),
                visualDensity: VisualDensity.compact,
                onPressed: _teamId.isEmpty ? null : _createLine,
                icon: const Icon(Icons.add, size: 18),
              ),
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
            padding: const EdgeInsets.fromLTRB(28, 1, 4, 1),
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
                if (_actionBusy.contains(
                  '$lineId/${task['id'] ?? ''}/dispatch',
                ) ||
                    _actionBusy.contains('$lineId/${task['id'] ?? ''}/decide') ||
                    _actionBusy.contains('$lineId/${task['id'] ?? ''}/cancel'))
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else if (_taskActions(task).isNotEmpty)
                  PopupMenuButton<String>(
                    key: Key('production-task-menu-${task['id'] ?? ''}'),
                    tooltip: '任务操作',
                    padding: EdgeInsets.zero,
                    iconSize: 16,
                    onSelected: (String value) {
                      final String id = '${task['id'] ?? ''}';
                      switch (value) {
                        case 'pack':
                          _dispatch(lineId, id, 'pack');
                        case 'run':
                          _dispatch(lineId, id, 'run');
                        case 'decide':
                          _decide(lineId, id);
                        case 'cancel':
                          _cancelTask(lineId, id);
                      }
                    },
                    itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                      for (final String value in _taskActions(task))
                        PopupMenuItem<String>(
                          value: value,
                          child: Text(_actionLabel(value)),
                        ),
                    ],
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
              key: Key('production-task-create-$lineId'),
              onPressed: _actionBusy.contains('$lineId/create-task')
                  ? null
                  : () => _createTask(lineId),
              child: const Text('新建任务'),
            ),
            TextButton(
              onPressed: () => _loadArtifacts(lineId),
              child: Text(artifacts == null ? '产物' : '收起产物'),
            ),
            TextButton(
              onPressed: () => _loadAudit(lineId),
              child: Text(audit == null ? '整理报告' : '收起报告'),
            ),
            TextButton(
              key: Key('production-line-delete-$lineId'),
              onPressed: _actionBusy.contains('$lineId/delete')
                  ? null
                  : () => _deleteLine(lineId),
              child: Text(
                '删除产线',
                style: TextStyle(color: cs.error),
              ),
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

  /// 任务可用操作：只给状态机允许的那几条（不把按钮摆出来再让后端 409）。
  static List<String> _taskActions(Map<String, dynamic> task) {
    final String status = '${task['status'] ?? ''}';
    return <String>[
      if (status == 'queued' || status == 'packing') 'pack',
      if (status == 'packed') 'run',
      if (status == 'aligning' || status == 'awaiting_user') 'decide',
      if (status != 'done' && status != 'cancelled') 'cancel',
    ];
  }

  static String _actionLabel(String value) {
    switch (value) {
      case 'pack':
        return '打包';
      case 'run':
        return '执行';
      case 'decide':
        return '拍板';
      case 'cancel':
        return '取消任务';
      default:
        return value;
    }
  }

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
