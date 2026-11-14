import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../io/api_service.dart';
import 'production_line_utils.dart';

/// 右栏「生产线任务」窗口（Task 10.4）：概览 / 计划 / 打包 / 门控 / 消息专家 / 台账。
///
/// 数据源：
/// - `GET .../tasks/{taskId}`（任务原始字段：brief / acceptance / references /
///   attachments / gate / last_gate / changed_files / blocked_reason …）；
/// - `GET .../runs?task_id=`（台账；专家报告与任务内 message 也在这里）；
/// - `GET .../plan`（所属计划版本、任务条目与门控）；
/// - `GET .../artifacts`（产物路径）。
///
/// 门控的「完成」只在 `gating` 且清单每项都有真实 evidence、最近一次门控没有失败命令
/// 时可用；否则按钮禁用并用 tooltip 说明缺什么。
class ProductionTaskDetailPanel extends StatefulWidget {
  const ProductionTaskDetailPanel({
    super.key,
    required this.lineId,
    required this.taskId,
    this.teamId = '',
    this.workspace = '',
    this.onClose,
  });

  final String lineId;
  final String taskId;
  final String teamId;

  /// 产线工作空间（绝对路径）；证据「打开文件」时拼绝对路径，空则只复制。
  final String workspace;
  final VoidCallback? onClose;

  @override
  State<ProductionTaskDetailPanel> createState() =>
      _ProductionTaskDetailPanelState();
}

class _ProductionTaskDetailPanelState extends State<ProductionTaskDetailPanel> {
  bool _loading = true;
  bool _busy = false;
  String _error = '';
  Map<String, dynamic> _task = <String, dynamic>{};
  List<Map<String, dynamic>> _runs = <Map<String, dynamic>>[];
  Map<String, dynamic> _plan = <String, dynamic>{};
  String _planVersion = '';
  String _planError = '';
  Map<String, dynamic> _artifacts = <String, dynamic>{};
  List<Map<String, dynamic>> _openQuestions = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ProductionTaskDetailPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lineId != widget.lineId ||
        oldWidget.taskId != widget.taskId) {
      _task = <String, dynamic>{};
      _runs = <Map<String, dynamic>>[];
      _plan = <String, dynamic>{};
      _artifacts = <String, dynamic>{};
      _load();
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = _task.isEmpty;
      _error = '';
    });
    try {
      final List<Map<String, dynamic>> results = await Future.wait(
        <Future<Map<String, dynamic>>>[
          ApiService.getProductionTask(
            widget.lineId,
            widget.taskId,
            teamId: widget.teamId,
          ),
          ApiService.getProductionRuns(
            widget.lineId,
            teamId: widget.teamId,
            taskId: widget.taskId,
          ),
        ],
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _task = productionMap(results[0]['task']);
        _runs = productionListOf(results[1], 'runs');
      });
      await Future.wait(<Future<void>>[
        _loadPlan(),
        _loadArtifacts(),
        _loadQuestions(),
      ]);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = productionReadable(error, '任务详情加载失败');
      });
    }
  }

  Future<void> _loadPlan() async {
    try {
      final Map<String, dynamic> data = await ApiService.getProductionPlan(
        widget.lineId,
        teamId: widget.teamId,
      );
      if (!mounted) return;
      setState(() {
        _plan = productionMap(data['plan']);
        _planVersion = '${data['version'] ?? ''}';
        _planError = '';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _planError = productionReadable(error, '计划读取失败'));
    }
  }

  Future<void> _loadArtifacts() async {
    try {
      final Map<String, dynamic> data = await ApiService.getProductionArtifacts(
        widget.lineId,
        teamId: widget.teamId,
      );
      if (!mounted) return;
      setState(() => _artifacts = data);
    } catch (_) {
      // 产物是增量能力：读不到不影响其它页签。
    }
  }

  Future<void> _loadQuestions() async {
    try {
      final Map<String, dynamic> data = await ApiService.getProductionQuestions(
        widget.lineId,
        widget.taskId,
        teamId: widget.teamId,
      );
      if (!mounted) return;
      setState(() => _openQuestions = productionListOf(data, 'open'));
    } catch (_) {
      // 没有准备阶段问题（例如执行期任务）时静默。
    }
  }

  Future<void> _complete() async {
    if (_busy || productionGateBlockedReason(_task).isNotEmpty) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await ApiService.transitionProductionTask(
        widget.lineId,
        widget.taskId,
        to: 'done',
        reason: '门控通过',
        teamId: widget.teamId,
      );
      await _load();
      _notify('已标记完成：门控清单与 evidence 都已核对');
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = productionReadable(error, '完成失败'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _notify(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));
  }

  void _openEvidence(String evidence) {
    final String value = evidence.trim();
    if (value.isEmpty) return;
    Clipboard.setData(ClipboardData(text: value));
    _notify('已复制证据路径：$value');
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error.isNotEmpty && _task.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(_error, style: TextStyle(fontSize: 12, color: cs.error)),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('production-task-detail-retry'),
              onPressed: _load,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    return DefaultTabController(
      length: 6,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _header(cs),
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelPadding: const EdgeInsets.symmetric(horizontal: 10),
            tabs: const <Widget>[
              Tab(
                key: Key('production-task-tab-overview'),
                height: 34,
                text: '概览',
              ),
              Tab(
                key: Key('production-task-tab-plan'),
                height: 34,
                text: '计划',
              ),
              Tab(
                key: Key('production-task-tab-pack'),
                height: 34,
                text: '打包',
              ),
              Tab(
                key: Key('production-task-tab-gate'),
                height: 34,
                text: '门控',
              ),
              Tab(
                key: Key('production-task-tab-message'),
                height: 34,
                text: '消息专家',
              ),
              Tab(
                key: Key('production-task-tab-runs'),
                height: 34,
                text: '台账',
              ),
            ],
          ),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Text(
                _error,
                style: TextStyle(fontSize: 11, color: cs.error),
              ),
            ),
          Expanded(
            child: TabBarView(
              children: <Widget>[
                _buildOverview(cs),
                _buildPlan(cs),
                _buildPack(cs),
                _buildGate(cs),
                _buildMessages(cs),
                _buildRuns(cs),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(ColorScheme cs) {
    final String status = '${_task['status'] ?? ''}';
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.assignment_outlined, size: 18, color: cs.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${widget.taskId}  ${_task['title'] ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${productionStatusLabel(status)} · $status'
                  '${'${_task['task_type'] ?? ''}'.isEmpty ? '' : ' · ${_task['task_type']}'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '刷新',
            visualDensity: VisualDensity.compact,
            onPressed: _load,
            icon: const Icon(Icons.refresh, size: 18),
          ),
          if (widget.onClose != null)
            IconButton(
              tooltip: '关闭',
              visualDensity: VisualDensity.compact,
              onPressed: widget.onClose,
              icon: const Icon(Icons.close, size: 18),
            ),
        ],
      ),
    );
  }

  ListView _shell(String key, List<Widget> children) => ListView(
    key: Key(key),
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
    children: children,
  );

  Widget _buildOverview(ColorScheme cs) {
    final String brief = '${_task['brief'] ?? ''}'.trim();
    final List<String> acceptance = _strings(_task['acceptance']);
    final List<String> references = _strings(_task['references']);
    final List<Map<String, dynamic>> attachments = productionListOf(
      _task,
      'attachments',
    );
    return _shell('production-task-overview', <Widget>[
      Text(
        productionTaskHumanLine(_task),
        style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
      ),
      const SizedBox(height: 8),
      _section(cs, '内容'),
      if (brief.isEmpty)
        _muted(cs, '（还没有 brief；准备阶段可先落 intake.goal）')
      else
        SelectableText(brief, style: const TextStyle(fontSize: 11.5)),
      _section(cs, '验收'),
      if (acceptance.isEmpty)
        _muted(cs, '（还没有 acceptance）')
      else
        for (final String item in acceptance)
          _bullet(cs, item, error: false),
      _section(cs, '引用'),
      if (references.isEmpty)
        _muted(cs, '（无）')
      else
        for (final String item in references) _bullet(cs, item),
      _section(cs, '附件（${attachments.length}）'),
      if (attachments.isEmpty)
        _muted(cs, '（无）')
      else
        for (final Map<String, dynamic> attachment in attachments)
          Text(
            '· ${attachment['name'] ?? attachment['path'] ?? ''}'
            '${productionAttachmentMeta(attachment)}',
            style: const TextStyle(fontSize: 10.5),
          ),
      _section(cs, '写域 / 读域'),
      Text(
        '写域：${_join(_task['write_scope'])}\n读域：${_join(_task['read_scope'])}',
        style: const TextStyle(fontSize: 11),
      ),
      _section(cs, '依赖'),
      Text(
        '依赖任务：${_join(_task['depends_on'])}\n'
        '冲突：${_join(_task['conflicts_with'])}'
        '${'${_task['serial_group'] ?? ''}'.isEmpty ? '' : '\n串行组：${_task['serial_group']}'}',
        style: const TextStyle(fontSize: 11),
      ),
      _section(cs, '风险 / 规模'),
      Text(
        '风险：${'${_task['risk'] ?? ''}'.isEmpty ? '未标注' : _task['risk']} · '
        '预估文件：${_task['estimated_files'] ?? 1}',
        style: const TextStyle(fontSize: 11),
      ),
      if (_task['contract'] != null) ...<Widget>[
        _section(cs, '契约'),
        Text(
          '${_task['contract']}',
          style: const TextStyle(fontSize: 10.5),
        ),
      ],
      if (_openQuestions.isNotEmpty) ...<Widget>[
        _section(cs, '待答问题（${_openQuestions.length}）'),
        for (final Map<String, dynamic> question in _openQuestions)
          _bullet(cs, '${question['qid'] ?? ''} ${question['text'] ?? ''}'),
      ],
    ]);
  }

  Widget _buildPlan(ColorScheme cs) {
    if (_planError.isNotEmpty && _plan.isEmpty) {
      return _shell('production-task-plan', <Widget>[
        Text(_planError, style: TextStyle(fontSize: 11.5, color: cs.error)),
      ]);
    }
    final Map<String, dynamic> entry = _planTaskEntry();
    final List<Map<String, dynamic>> gates = productionListOf(
      <String, dynamic>{'items': productionMap(_plan['gates'])[widget.taskId]},
      'items',
    );
    final List<Map<String, dynamic>> trace = <Map<String, dynamic>>[
      for (final Map<String, dynamic> row in productionListOf(
        _plan,
        'traceability',
      ))
        if (_strings(row['tasks']).contains(widget.taskId)) row,
    ];
    return _shell('production-task-plan', <Widget>[
      Text(
        '所属计划：${_planVersion.isEmpty ? '（还没有计划版本）' : _planVersion}',
        style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 6),
      if (entry.isEmpty)
        _muted(cs, '当前计划里没有这条任务（可能是旧计划或手工建的任务）')
      else ...<Widget>[
        _section(cs, '计划任务条目'),
        Text(
          '${entry['id'] ?? ''}  ${entry['title'] ?? ''}\n'
          '类型：${entry['task_type'] ?? ''} · 风险：${entry['risk'] ?? ''} · '
          '预估文件：${entry['estimated_files'] ?? ''}\n'
          '写域：${_join(entry['write_scope'])}',
          style: const TextStyle(fontSize: 11),
        ),
      ],
      _section(cs, '计划门控'),
      if (gates.isEmpty)
        _muted(cs, '（计划里没有这条任务的门控）')
      else
        for (final Map<String, dynamic> item in gates)
          Text(
            productionGateLine(item),
            style: TextStyle(
              fontSize: 10.5,
              color: '${item['evidence'] ?? ''}'.trim().isEmpty
                  ? cs.error
                  : cs.onSurface,
            ),
          ),
      _section(cs, '追踪矩阵'),
      if (trace.isEmpty)
        _muted(cs, '（没有指向这条任务的追踪行）')
      else
        for (final Map<String, dynamic> row in trace)
          Text(
            '${row['req'] ?? ''} → ${_join(row['tasks'])}',
            style: const TextStyle(fontSize: 10.5),
          ),
    ]);
  }

  Widget _buildPack(ColorScheme cs) {
    final Map<String, dynamic> pack = productionMap(_task['pack']);
    final List<String> changed = _strings(_task['changed_files']);
    final List<dynamic> files = _artifacts['files'] as List<dynamic>? ?? <dynamic>[];
    final List<String> packArtifacts = <String>[
      for (final dynamic raw in files)
        if ('${productionMap(raw)['path'] ?? ''}'.contains('pack.json'))
          '${productionMap(raw)['path']}',
    ];
    return _shell('production-task-pack', <Widget>[
      _section(cs, 'pack.json 摘要'),
      if (pack.isEmpty)
        _muted(cs, '还没有打包结果（queued / packed 后才会有）')
      else
        for (final MapEntry<String, dynamic> entry in pack.entries)
          Text(
            '${entry.key}：${entry.value}',
            style: const TextStyle(fontSize: 10.5),
          ),
      if (packArtifacts.isNotEmpty) ...<Widget>[
        _section(cs, '产物'),
        for (final String path in packArtifacts)
          InkWell(
            onTap: () => _openEvidence(path),
            child: Text(
              path,
              style: TextStyle(fontSize: 10.5, color: cs.primary),
            ),
          ),
      ],
      _section(cs, 'changed_files（${changed.length}）'),
      if (changed.isEmpty)
        _muted(cs, '（还没有执行结果）')
      else
        for (final String path in changed) _bullet(cs, path),
      if ('${_task['last_error'] ?? ''}'.isNotEmpty) ...<Widget>[
        _section(cs, '最近错误'),
        Text(
          '${_task['last_error']}',
          style: TextStyle(fontSize: 10.5, color: cs.error),
        ),
      ],
    ]);
  }

  Widget _buildGate(ColorScheme cs) {
    final List<Map<String, dynamic>> items = productionTaskGateItems(_task);
    final String blocked = productionGateBlockedReason(_task);
    final String status = '${_task['status'] ?? ''}';
    final bool canDone = status == 'gating' && blocked.isEmpty;
    final Map<String, dynamic> lastGate = productionMap(_task['last_gate']);
    final List<Map<String, dynamic>> commands = productionListOf(
      lastGate,
      'commands',
    );
    return _shell('production-task-gate', <Widget>[
      Row(
        children: <Widget>[
          Expanded(
            child: Text(
              blocked.isEmpty
                  ? (items.isEmpty ? '这条任务还没有门控清单' : '门控清单全部有 evidence')
                  : blocked,
              style: TextStyle(
                fontSize: 11.5,
                color: blocked.isEmpty ? cs.onSurfaceVariant : cs.error,
              ),
            ),
          ),
          Tooltip(
            message: canDone
                ? '门控逐条有 evidence，可以标记完成'
                : (status != 'gating'
                      ? '只有门控中（gating）的任务可以完成'
                      : blocked),
            child: FilledButton(
              key: const Key('production-task-done'),
              onPressed: canDone && !_busy ? _complete : null,
              child: Text(_busy ? '提交中…' : '完成'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      if (items.isEmpty)
        _muted(cs, '计划里的 `- [ ]` 门控会在这里逐条核对。')
      else
        for (int i = 0; i < items.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${items[i]['ok'] == true ? '☑' : '☐'} ${productionGateLine(items[i])}',
                  style: TextStyle(
                    fontSize: 11,
                    color: items[i]['ok'] == true ? cs.onSurface : cs.error,
                  ),
                ),
                if ('${items[i]['evidence'] ?? ''}'.trim().isNotEmpty)
                  InkWell(
                    key: Key('production-task-evidence-$i'),
                    onTap: () => _openEvidence('${items[i]['evidence']}'),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 16, top: 1),
                      child: Text(
                        '证据：${items[i]['evidence']}',
                        style: TextStyle(fontSize: 10.5, color: cs.primary),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      if (commands.isNotEmpty) ...<Widget>[
        _section(cs, '最近一次门控命令'),
        for (final Map<String, dynamic> command in commands)
          Text(
            '${command['ok'] == true ? '通过' : '失败'} · ${command['command'] ?? ''}'
            '${'${command['output'] ?? ''}'.isEmpty ? '' : '\n  ${command['output']}'}',
            style: TextStyle(
              fontSize: 10.5,
              color: command['ok'] == true ? cs.onSurface : cs.error,
            ),
          ),
      ],
    ]);
  }

  Widget _buildMessages(ColorScheme cs) {
    final List<Map<String, dynamic>> messages = <Map<String, dynamic>>[
      for (final dynamic raw in (_task['messages'] as List<dynamic>? ??
          <dynamic>[]))
        if (raw is Map) productionMap(raw),
    ];
    final List<Map<String, dynamic>> experts = <Map<String, dynamic>>[
      for (final Map<String, dynamic> run in _runs)
        if ('${run['role'] ?? ''}' == 'expert' ||
            '${run['action'] ?? ''}'.contains('expert') ||
            '${run['action'] ?? ''}'.contains('message'))
          run,
    ];
    return _shell('production-task-messages', <Widget>[
      _section(cs, '任务内消息（${messages.length}）'),
      if (messages.isEmpty)
        _muted(cs, '（没有任务内 message 线程）')
      else
        for (final Map<String, dynamic> message in messages)
          Text(
            '${message['role'] ?? message['from'] ?? ''}：'
            '${message['text'] ?? message['content'] ?? ''}',
            style: const TextStyle(fontSize: 11),
          ),
      _section(cs, '专家报告（${experts.length}）'),
      if (experts.isEmpty)
        _muted(cs, '（还没有专家调用）')
      else
        for (final Map<String, dynamic> run in experts)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '${run['status'] ?? ''} · ${run['action'] ?? run['run_id'] ?? ''}\n'
              '${run['report'] ?? run['message'] ?? run['output'] ?? ''}',
              style: const TextStyle(fontSize: 10.5),
            ),
          ),
    ]);
  }

  Widget _buildRuns(ColorScheme cs) {
    final String blocked = '${_task['blocked_reason'] ?? ''}'.trim();
    final String lastError = '${_task['last_error'] ?? ''}'.trim();
    return _shell('production-task-runs', <Widget>[
      if (blocked.isNotEmpty || lastError.isNotEmpty)
        Container(
          padding: const EdgeInsets.all(8),
          margin: const EdgeInsets.only(bottom: 6),
          decoration: BoxDecoration(
            color: cs.errorContainer.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                productionTaskWhy(_task),
                style: TextStyle(fontSize: 11.5, color: cs.error),
              ),
              if (blocked.isNotEmpty)
                Text(
                  'blocked_reason：$blocked',
                  style: TextStyle(fontSize: 10, color: cs.error),
                ),
              if (lastError.isNotEmpty)
                Text(
                  'last_error：$lastError',
                  style: TextStyle(fontSize: 10, color: cs.error),
                ),
            ],
          ),
        ),
      _section(cs, '运行台账（${_runs.length}）'),
      if (_runs.isEmpty)
        _muted(cs, '还没有运行记录')
      else
        for (final Map<String, dynamic> run in _runs)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '${run['run_id'] ?? ''} · ${run['role'] ?? ''} · ${run['status'] ?? ''}'
              '${'${run['action'] ?? ''}'.isEmpty ? '' : ' · ${run['action']}'}'
              '${'${run['guard'] ?? ''}'.isEmpty ? '' : ' · 护栏 ${run['guard']}'}'
              '${'${run['error'] ?? run['reason'] ?? ''}'.isEmpty ? '' : '\n  ${run['error'] ?? run['reason']}'}',
              style: const TextStyle(fontSize: 10.5),
            ),
          ),
    ]);
  }

  Map<String, dynamic> _planTaskEntry() {
    for (final Map<String, dynamic> task in productionListOf(_plan, 'tasks')) {
      if ('${task['id'] ?? ''}' == widget.taskId) return task;
    }
    return <String, dynamic>{};
  }

  List<String> _strings(Object? raw) => raw is List
      ? <String>[
          for (final Object? item in raw)
            if ('$item'.trim().isNotEmpty) '$item',
        ]
      : <String>[
          if ('${raw ?? ''}'.trim().isNotEmpty) '$raw',
        ];

  String _join(Object? raw) {
    final List<String> items = _strings(raw);
    return items.isEmpty ? '（无）' : items.join('、');
  }

  Widget _section(ColorScheme cs, String title) => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 2),
    child: Text(
      title,
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        color: cs.onSurfaceVariant,
      ),
    ),
  );

  Widget _muted(ColorScheme cs, String text) => Text(
    text,
    style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant),
  );

  Widget _bullet(ColorScheme cs, String text, {bool error = false}) => Padding(
    padding: const EdgeInsets.only(left: 6, top: 1),
    child: Text(
      '· $text',
      style: TextStyle(fontSize: 11, color: error ? cs.error : cs.onSurface),
    ),
  );
}
