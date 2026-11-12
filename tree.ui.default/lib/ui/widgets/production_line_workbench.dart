import 'package:flutter/material.dart';

import '../../io/api_service.dart';
import 'create_production_line_dialog.dart';
import 'production_line_utils.dart';

/// 中栏「产线工作台」（§6.2 / §16.1）。
///
/// 选中左栏一条产线后，中栏从对话切到这张工作台：任务队列 + 决策收件箱 +
/// 运行台账 + 产物与整理报告，写入口（建任务 / 派发 / 拍板 / 取消 / 配置删除）
/// 全在这里。产线没有聊天流：用户与产线的交互是「任务 + 决策卡片 + 结论」。
///
/// 左栏只负责选产线，不再把队列塞进 260px 的窄栏。
class ProductionLineWorkbench extends StatefulWidget {
  const ProductionLineWorkbench({
    super.key,
    required this.line,
    required this.teamId,
    this.agentId = '',
    this.visible = true,
    this.onCollapse,
    this.onDeleted,
    this.onLineUpdated,
  });

  /// 当前选中的产线（`line.yaml` 的 JSON）；null = 还没选。
  final Map<String, dynamic>? line;

  /// 调用方身份（REST 的 `team_id` 查询参数，只作身份，不再决定归属）。
  final String teamId;

  /// 调用方 Agent（派发缺省执行身份时的回退；产线写了 executor 就不需要）。
  final String agentId;

  /// 工作台是否露脸：由隐藏变可见时重拉明细（与左栏面板同一口径）。
  final bool visible;

  /// 折叠中栏（把宽度让给侧栏）。
  final VoidCallback? onCollapse;

  /// 产线被删除：上层清掉选中并刷新左栏列表。
  final VoidCallback? onDeleted;

  /// 产线配置被改：上层用新数据替换选中项。
  final ValueChanged<Map<String, dynamic>>? onLineUpdated;

  @override
  State<ProductionLineWorkbench> createState() =>
      _ProductionLineWorkbenchState();
}

class _ProductionLineWorkbenchState extends State<ProductionLineWorkbench> {
  bool _loading = true;
  String _error = '';

  List<Map<String, dynamic>> _tasks = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _runs = <Map<String, dynamic>>[];
  Map<String, dynamic>? _artifacts;
  Map<String, dynamic>? _audit;

  /// 整理报告每批文件数（一次请求一批；改完点「继续扫描」跑下一批）。
  final TextEditingController _auditBatch = TextEditingController(text: '500');

  /// 单条产线 / 任务的写操作进行中（按钮转圈、防重复提交）。
  final Set<String> _actionBusy = <String>{};

  String? get _lineId {
    final String id = '${widget.line?['id'] ?? ''}'.trim();
    return id.isEmpty ? null : id;
  }

  String get _teamId => widget.teamId.trim();

  String get _agentId => widget.agentId.trim();

  @override
  void initState() {
    super.initState();
    if (_lineId != null) {
      _loadDetails();
    } else {
      _loading = false;
    }
  }

  @override
  void didUpdateWidget(covariant ProductionLineWorkbench oldWidget) {
    super.didUpdateWidget(oldWidget);
    final String? oldId = '${oldWidget.line?['id'] ?? ''}'.trim().isEmpty
        ? null
        : '${oldWidget.line?['id'] ?? ''}'.trim();
    if (oldId != _lineId) {
      _tasks = <Map<String, dynamic>>[];
      _runs = <Map<String, dynamic>>[];
      _artifacts = null;
      _audit = null;
      _error = '';
      _loading = _lineId != null;
      if (_lineId != null) _loadDetails();
      return;
    }
    if (!oldWidget.visible && widget.visible && _lineId != null) {
      _loadDetails();
    }
  }

  @override
  void dispose() {
    _auditBatch.dispose();
    super.dispose();
  }

  Future<void> _loadDetails() async {
    final String? lineId = _lineId;
    if (lineId == null) return;
    setState(() {
      _loading = _tasks.isEmpty;
      _error = '';
    });
    try {
      final List<Map<String, dynamic>> results = await Future.wait(
        <Future<Map<String, dynamic>>>[
          ApiService.getProductionTasks(lineId, teamId: _teamId),
          ApiService.getProductionRuns(lineId, teamId: _teamId),
        ],
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _tasks = productionListOf(results[0], 'tasks');
        _runs = productionListOf(results[1], 'runs');
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = productionReadable(error, '产线明细加载失败');
      });
    }
  }

  Future<void> _loadArtifacts() async {
    final String? lineId = _lineId;
    if (lineId == null) return;
    if (_artifacts != null) {
      setState(() => _artifacts = null);
      return;
    }
    setState(() => _actionBusy.add('$lineId/artifacts'));
    try {
      final Map<String, dynamic> data = await ApiService.getProductionArtifacts(
        lineId,
        teamId: _teamId,
      );
      if (!mounted) return;
      setState(() => _artifacts = data);
    } catch (error) {
      if (!mounted) return;
      _notify(productionReadable(error, '产物加载失败'));
    } finally {
      if (mounted) setState(() => _actionBusy.remove('$lineId/artifacts'));
    }
  }

  Future<void> _loadAudit({bool force = false}) async {
    final String? lineId = _lineId;
    if (lineId == null) return;
    if (!force && _audit != null) {
      setState(() => _audit = null);
      return;
    }
    final int limit = (int.tryParse(_auditBatch.text.trim()) ?? 500).clamp(
      1,
      20000,
    );
    setState(() => _actionBusy.add('$lineId/audit'));
    try {
      final Map<String, dynamic> data = await ApiService.getProductionAudit(
        lineId,
        teamId: _teamId,
        limit: limit,
      );
      if (!mounted) return;
      setState(() => _audit = data);
    } catch (error) {
      if (!mounted) return;
      _notify(productionReadable(error, '整理报告加载失败'));
    } finally {
      if (mounted) setState(() => _actionBusy.remove('$lineId/audit'));
    }
  }

  /// 统一收口：忙碌标记 + 可读错误（SnackBar，不打断工作台状态）。
  Future<void> _act(String key, Future<void> Function() action) async {
    if (_actionBusy.contains(key)) return;
    setState(() => _actionBusy.add(key));
    try {
      await action();
    } catch (error) {
      _notify(productionReadable(error, '操作失败'));
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

  Future<void> _createTask() async {
    final String? lineId = _lineId;
    if (lineId == null) return;
    final String workspace = '${widget.line?['workspace_dir'] ?? ''}'.trim();
    final _NewTaskSpec? spec = await showDialog<_NewTaskSpec>(
      context: context,
      builder: (BuildContext context) =>
          _NewTaskDialog(lineId: lineId, workspace: workspace),
    );
    if (spec == null || spec.title.isEmpty) return;
    await _act('$lineId/create-task', () async {
      await ApiService.createProductionTask(
        lineId,
        <String, dynamic>{
          'title': spec.title,
          'status': 'queued',
          'priority': 50,
          'write_scope': spec.scope,
        },
        teamId: _teamId,
      );
      await _loadDetails();
      _notify('已建任务：${spec.title}');
    });
  }

  Future<void> _dispatch(String taskId, String stage) async {
    final String? lineId = _lineId;
    if (lineId == null) return;
    await _act('$lineId/$taskId/dispatch', () async {
      final Map<String, dynamic> result = await ApiService.dispatchProductionTask(
        lineId,
        taskId,
        stage: stage,
        // 产线已写 executor 时后端不依赖它；留空也不会再把派发卡在 UI。
        agentId: _agentId,
        teamId: _teamId,
      );
      await _loadDetails();
      _notify(
        result['accepted'] == true
            ? '已受理${stage == 'run' ? '执行' : '打包'}：进度看任务状态与运行台账'
            : '${result['status'] ?? '已完成'}：$taskId',
      );
    });
  }

  Future<void> _cancelTask(String taskId) async {
    final String? lineId = _lineId;
    if (lineId == null) return;
    if (!await _confirm('取消任务 $taskId？', '取消后不可再迁移（保留在队列里可追溯）。')) {
      return;
    }
    await _act('$lineId/$taskId/cancel', () async {
      await ApiService.cancelProductionTask(
        lineId,
        taskId,
        teamId: _teamId,
      );
      await _loadDetails();
      _notify('已取消：$taskId');
    });
  }

  /// 拍板：先拉待答问题，再让用户逐条回答或「全部按推荐」。
  Future<void> _decide(String taskId) async {
    final String? lineId = _lineId;
    if (lineId == null) return;
    await _act('$lineId/$taskId/decide', () async {
      final Map<String, dynamic> data = await ApiService.getProductionQuestions(
        lineId,
        taskId,
        teamId: _teamId,
      );
      final List<Map<String, dynamic>> open =
          (data['open'] as List<dynamic>? ?? <dynamic>[])
              .whereType<Map>()
              .map(productionMap)
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
      await _loadDetails();
      _notify('已记录拍板：剩余 ${result['open'] ?? 0} 条未答');
    });
  }

  Future<void> _editLine() async {
    final String? lineId = _lineId;
    final Map<String, dynamic>? line = widget.line;
    if (lineId == null || line == null) return;
    final ProductionLineSpec? spec =
        await showDialog<ProductionLineSpec>(
          context: context,
          builder: (BuildContext context) => CreateProductionLineDialog(
            defaultAgentId: _agentId,
            initial: line,
          ),
        );
    if (spec == null) return;
    await _act('$lineId/edit', () async {
      final Map<String, dynamic> result = await ApiService.updateProductionLine(
        lineId,
        name: spec.name,
        workspaceDir: spec.workspace,
        executor: spec.executor,
        roles: spec.roles,
        teamId: _teamId,
      );
      final Map<String, dynamic> updated = productionMap(result['line']);
      if (updated.isNotEmpty) widget.onLineUpdated?.call(updated);
      _notify('已保存产线配置');
    });
  }

  Future<void> _deleteLine() async {
    final String? lineId = _lineId;
    if (lineId == null) return;
    if (!await _confirm('删除产线 $lineId？', '插件数据会删除，项目资产（docs/ 下）保留。')) {
      return;
    }
    await _act('$lineId/delete', () async {
      final Map<String, dynamic> result = await ApiService.deleteProductionLine(
        lineId,
        teamId: _teamId,
      );
      _notify(
        '${result['note'] is String && '${result['note']}'.isNotEmpty ? result['note'] : '已删除产线：$lineId'}',
      );
      widget.onDeleted?.call();
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
    final Map<String, dynamic>? line = widget.line;
    if (line == null) {
      return Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.account_tree_outlined, size: 36, color: cs.outline),
                const SizedBox(height: 10),
                Text(
                  '在左侧选择一条产线',
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 4),
                Text(
                  '任务队列与决策收件箱会显示在这里；还没有产线就点左栏「+」新建',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11.5, color: cs.outline),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final String id = '${line['id'] ?? ''}';
    final String name = '${line['name'] ?? id}';
    final String status = '${line['status'] ?? 'idle'}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          height: 48,
          padding: const EdgeInsets.only(left: 12, right: 4),
          decoration: BoxDecoration(
            color: cs.surface,
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            children: <Widget>[
              Icon(Icons.account_tree_outlined, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '$id · $status',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: '新建任务',
                key: Key('production-task-create-$id'),
                visualDensity: VisualDensity.compact,
                onPressed: _actionBusy.contains('$id/create-task')
                    ? null
                    : _createTask,
                icon: const Icon(Icons.add_task, size: 18),
              ),
              IconButton(
                tooltip: '刷新任务与台账',
                visualDensity: VisualDensity.compact,
                onPressed: _loading ? null : _loadDetails,
                icon: const Icon(Icons.refresh, size: 18),
              ),
              PopupMenuButton<String>(
                key: const Key('production-line-menu'),
                tooltip: '产线操作',
                padding: EdgeInsets.zero,
                iconSize: 18,
                onSelected: (String value) {
                  switch (value) {
                    case 'config':
                      _editLine();
                    case 'delete':
                      _deleteLine();
                  }
                },
                itemBuilder: (BuildContext context) =>
                    <PopupMenuEntry<String>>[
                      const PopupMenuItem<String>(
                        value: 'config',
                        child: Text('产线配置'),
                      ),
                      const PopupMenuItem<String>(
                        value: 'delete',
                        child: Text('删除产线'),
                      ),
                    ],
              ),
              if (widget.onCollapse != null)
                IconButton(
                  tooltip: '折叠中栏',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onCollapse,
                  icon: const Icon(Icons.chevron_right, size: 18),
                ),
            ],
          ),
        ),
        Expanded(child: _buildBody(cs, id)),
      ],
    );
  }

  Widget _buildBody(ColorScheme cs, String lineId) {
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
              key: const Key('production-workbench-retry'),
              onPressed: _loadDetails,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final List<Map<String, dynamic>> decisions = <Map<String, dynamic>>[
      for (final Map<String, dynamic> task in _tasks)
        if (productionTaskActions(task).contains('decide')) task,
    ];
    final Map<String, dynamic>? artifacts = _artifacts;
    final Map<String, dynamic>? audit = _audit;
    return ListView(
      key: const Key('production-workbench'),
      padding: const EdgeInsets.only(bottom: 16),
      children: <Widget>[
        if (decisions.isNotEmpty) ...<Widget>[
          _sectionTitle(cs, '决策收件箱', '${decisions.length}'),
          for (final Map<String, dynamic> task in decisions)
            _buildDecisionCard(cs, lineId, task),
        ],
        _sectionTitle(cs, '任务队列', '${_tasks.length}'),
        if (_tasks.isEmpty)
          _muted(cs, '队列为空：点右上角「新建任务」把第一件事排进来。')
        else
          for (final Map<String, dynamic> task in _tasks)
            _buildTaskRow(cs, lineId, task),
        _sectionTitle(cs, '运行台账', '${_runs.length}'),
        if (_runs.isEmpty)
          _muted(cs, '还没有运行记录')
        else
          for (final Map<String, dynamic> run in _runs.take(20))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 1, 16, 1),
              child: Text(
                _runLabel(run),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5),
              ),
            ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Wrap(
            spacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              TextButton(
                onPressed: _loadArtifacts,
                child: Text(artifacts == null ? '产物' : '收起产物'),
              ),
              SizedBox(
                width: 84,
                child: TextField(
                  key: Key('production-audit-batch-$lineId'),
                  controller: _auditBatch,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '每批',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              TextButton(
                onPressed: () => _loadAudit(),
                child: Text(audit == null ? '整理报告' : '收起报告'),
              ),
            ],
          ),
        ),
        if (artifacts != null) ..._buildArtifacts(cs, artifacts),
        if (audit != null) ..._buildAudit(cs, lineId, audit),
      ],
    );
  }

  Widget _buildTaskRow(
    ColorScheme cs,
    String lineId,
    Map<String, dynamic> task,
  ) {
    final String id = '${task['id'] ?? ''}';
    final String status = '${task['status'] ?? ''}';
    final String scope = (task['write_scope'] as List<dynamic>? ?? <dynamic>[])
        .map((dynamic item) => '$item')
        .join(', ');
    final bool busy = _actionBusy.contains('$lineId/$id/dispatch') ||
        _actionBusy.contains('$lineId/$id/decide') ||
        _actionBusy.contains('$lineId/$id/cancel');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 3, 8, 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '$id  ${task['title'] ?? ''}',
                  style: const TextStyle(fontSize: 12.5),
                ),
                if (scope.isNotEmpty)
                  Text(
                    '写域：$scope',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: cs.outline),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            status,
            style: TextStyle(
              fontSize: 10.5,
              color: productionStatusColor(cs, status),
            ),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (productionTaskActions(task).isNotEmpty)
            PopupMenuButton<String>(
              key: Key('production-task-menu-$id'),
              tooltip: '任务操作',
              padding: EdgeInsets.zero,
              iconSize: 16,
              onSelected: (String value) {
                switch (value) {
                  case 'pack':
                    _dispatch(id, 'pack');
                  case 'run':
                    _dispatch(id, 'run');
                  case 'decide':
                    _decide(id);
                  case 'cancel':
                    _cancelTask(id);
                }
              },
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                for (final String value in productionTaskActions(task))
                  PopupMenuItem<String>(
                    value: value,
                    child: Text(productionActionLabel(value)),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildDecisionCard(
    ColorScheme cs,
    String lineId,
    Map<String, dynamic> task,
  ) {
    final String id = '${task['id'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 3, 16, 3),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
        decoration: BoxDecoration(
          color: cs.secondaryContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: cs.secondary.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '$id  ${task['title'] ?? ''}',
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${task['status'] ?? ''} · 等你拍板',
                    style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            FilledButton.tonal(
              key: Key('production-inbox-decide-$id'),
              onPressed: _actionBusy.contains('$lineId/$id/decide')
                  ? null
                  : () => _decide(id),
              child: const Text('拍板'),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildArtifacts(ColorScheme cs, Map<String, dynamic> data) {
    final String note = '${data['note'] ?? ''}';
    final List<dynamic> files = data['files'] as List<dynamic>? ?? <dynamic>[];
    return <Widget>[
      if (note.isNotEmpty) _muted(cs, note),
      if (files.isEmpty && note.isEmpty) _muted(cs, '还没有产物'),
      for (final dynamic raw in files.take(50))
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 1, 16, 1),
          child: Text(
            '${productionMap(raw)['path'] ?? ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
        ),
    ];
  }

  List<Widget> _buildAudit(
    ColorScheme cs,
    String lineId,
    Map<String, dynamic> data,
  ) {
    final Map<String, dynamic> report = productionMap(data['report']);
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
    final Map<String, dynamic> progress = productionMap(data['progress']);
    final bool done = progress.isEmpty || progress['done'] == true;
    final int index = (progress['index'] as num?)?.toInt() ?? scanned;
    final int total = (progress['total'] as num?)?.toInt() ?? scanned;
    final int percent = (progress['percent'] as num?)?.toInt() ?? 100;
    final bool busy = _actionBusy.contains('$lineId/audit');
    return <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
        child: Text(
          '扫描 $scanned 个文件 · TODO ${todos.length} · 缺文档 ${missing.length} · '
          '重复 ${duplicates.length} · 超大 ${large.length}',
          style: const TextStyle(fontSize: 11),
        ),
      ),
      if (!done) ...<Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 3, 16, 3),
          child: LinearProgressIndicator(value: percent / 100, minHeight: 4),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
          child: Text(
            '已处理 $index / $total 个文件（$percent%）',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonal(
              key: Key('production-audit-continue-$lineId'),
              onPressed: busy ? null : () => _loadAudit(force: true),
              child: Text(busy ? '扫描中…' : '继续扫描'),
            ),
          ),
        ),
      ],
      for (final dynamic note in notes) _muted(cs, '$note'),
    ];
  }

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
    child: Text(text, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
  );

  static String _runLabel(Map<String, dynamic> run) {
    final String taskId = '${run['task_id'] ?? ''}';
    return '${run['role'] ?? ''} · ${run['status'] ?? ''}'
        '${taskId.isEmpty ? '' : ' · $taskId'}';
  }
}

/// 新建任务的表单结果。
class _NewTaskSpec {
  const _NewTaskSpec(this.title, this.scope);

  final String title;
  final List<String> scope;
}

/// 新建任务：写域支持「选目录 / 选文件」，选中后自动转成工作空间相对路径。
class _NewTaskDialog extends StatefulWidget {
  const _NewTaskDialog({required this.lineId, required this.workspace});

  final String lineId;
  final String workspace;

  @override
  State<_NewTaskDialog> createState() => _NewTaskDialogState();
}

class _NewTaskDialogState extends State<_NewTaskDialog> {
  late final TextEditingController _title = TextEditingController();
  late final TextEditingController _scope = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    _scope.dispose();
    super.dispose();
  }

  Future<void> _pickDirectoryScope() async {
    final String? picked = await pickProductionDirectory('选择写域目录');
    if (picked == null) return;
    _append(<String>[picked]);
  }

  Future<void> _pickFileScope() async {
    final List<String> picked = await pickProductionFiles('选择写域文件');
    if (picked.isEmpty) return;
    _append(picked);
  }

  void _append(List<String> paths) {
    if (!mounted) return;
    if (widget.workspace.isEmpty) {
      _toast('该产线未配置工作空间：只能手填相对路径，或先给产线选目录');
      return;
    }
    final List<String> current = _scope.text
        .split(',')
        .map((String item) => item.trim())
        .where((String item) => item.isNotEmpty)
        .toList();
    final List<String> skipped = <String>[];
    for (final String path in paths) {
      final String relative = productionRelativeToWorkspace(
        widget.workspace,
        path,
      );
      if (relative.isEmpty) {
        skipped.add(path);
        continue;
      }
      if (!current.contains(relative)) current.add(relative);
    }
    setState(() => _scope.text = current.join(', '));
    if (skipped.isNotEmpty) {
      _toast('已跳过 ${skipped.length} 个不在工作空间内的路径');
    }
  }

  void _toast(String text) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('新建任务 · ${widget.lineId}'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              key: const Key('production-task-title'),
              controller: _title,
              autofocus: true,
              decoration: const InputDecoration(labelText: '标题'),
            ),
            TextField(
              key: const Key('production-task-scope'),
              controller: _scope,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: '写域（逗号分隔，可空）',
                hintText: 'lib/ui/widgets/agent_list.dart',
                helperText: widget.workspace.isEmpty
                    ? '产线未配置工作空间：只能手填相对路径'
                    : '执行阶段只允许改这些路径；留空 = 整个工作空间（不限制范围，禁区仍拦，'
                          '且会与其它任务串行）',
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                TextButton.icon(
                  key: const Key('production-task-scope-dir'),
                  onPressed: _pickDirectoryScope,
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: const Text('选目录'),
                ),
                TextButton.icon(
                  key: const Key('production-task-scope-file'),
                  onPressed: _pickFileScope,
                  icon: const Icon(Icons.insert_drive_file_outlined, size: 16),
                  label: const Text('选文件'),
                ),
              ],
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
          key: const Key('production-task-create'),
          onPressed: () => Navigator.of(context).pop(
            _NewTaskSpec(
              _title.text.trim(),
              <String>[
                for (final String item in _scope.text.split(','))
                  if (item.trim().isNotEmpty) item.trim(),
              ],
            ),
          ),
          child: const Text('创建'),
        ),
      ],
    );
  }
}
