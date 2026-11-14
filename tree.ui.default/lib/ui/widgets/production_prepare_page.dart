import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../io/api_service.dart';
import 'production_line_utils.dart';
import 'production_plan_review.dart';

/// 准备四步（Task 10.2）：建需求 → 侦查 → 拍板 → 计划审查/落档。
///
/// 数据源全部走已有 REST：
/// - 任务详情 `GET .../tasks/{taskId}`（含 `intake` / `recon` / `gate` 等原始字段）；
/// - 待答问题 `GET .../questions`，拍板 `POST .../decision`；
/// - 计划 `GET .../plan`（[ProductionPlanReview] 复用）；
/// - 侦查 / 落档：`POST .../recon`、`POST .../finalize`（后端若未开放，界面给出可读提示，
///   不伪造成功）。
class ProductionPreparePage extends StatefulWidget {
  const ProductionPreparePage({
    super.key,
    required this.lineId,
    required this.taskId,
    required this.task,
    this.teamId = '',
    this.onClose,
    this.onSaved,
  });

  final String lineId;
  final String taskId;

  /// 工作台当前任务快照（先渲染，随后再拉最新）。
  final Map<String, dynamic> task;
  final String teamId;
  final VoidCallback? onClose;

  /// 落档成功后通知工作台刷新队列。
  final VoidCallback? onSaved;

  @override
  State<ProductionPreparePage> createState() => _ProductionPreparePageState();
}

class _ProductionPreparePageState extends State<ProductionPreparePage> {
  static const List<String> _stepTitles = <String>['建需求', '侦查', '拍板', '计划审查 / 落档'];

  int _step = 0;
  bool _busy = false;
  String _error = '';
  String _notice = '';
  Map<String, dynamic> _task = <String, dynamic>{};
  List<Map<String, dynamic>> _open = <Map<String, dynamic>>[];
  final Map<String, String> _answers = <String, String>{};
  bool _planBlocked = false;

  String get _taskId => widget.taskId;
  String get _lineId => widget.lineId;
  String get _status => '${_task['status'] ?? widget.task['status'] ?? ''}';

  Map<String, dynamic> get _recon => productionMap(_task['recon']);

  List<String> get _openQids => <String>[
    for (final Map<String, dynamic> question in _open)
      '${question['qid'] ?? ''}'.trim(),
  ].where((String item) => item.isNotEmpty).toList();

  bool get _canFinalize =>
      _open.isEmpty && !_planBlocked && _status == 'aligning';

  @override
  void initState() {
    super.initState();
    _task = Map<String, dynamic>.of(widget.task);
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _error = '');
    try {
      final List<Map<String, dynamic>> results = await Future.wait(
        <Future<Map<String, dynamic>>>[
          ApiService.getProductionTask(
            _lineId,
            _taskId,
            teamId: widget.teamId,
          ),
          ApiService.getProductionQuestions(
            _lineId,
            _taskId,
            teamId: widget.teamId,
          ),
        ],
      );
      if (!mounted) return;
      final Map<String, dynamic> task = productionMap(results[0]['task']);
      final List<Map<String, dynamic>> open = productionListOf(results[1], 'open');
      setState(() {
        if (task.isNotEmpty) _task = task;
        _open = open;
        for (final Map<String, dynamic> question in open) {
          final String qid = '${question['qid'] ?? ''}';
          _answers.putIfAbsent(
            qid,
            () => '${question['recommended'] ?? question['default'] ?? ''}',
          );
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = productionReadable(error, '准备数据加载失败'));
    }
  }

  Future<void> _runRecon() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = '';
      _notice = '';
    });
    try {
      await ApiService.reconProductionTask(
        _lineId,
        _taskId,
        teamId: widget.teamId,
      );
      await _load();
      if (!mounted) return;
      setState(() => _notice = '侦查完成：理解卡与问题已更新');
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = productionReadable(
          error,
          '侦查失败（后端未开放准备接口时，请先在 Agent 对话里完成侦查）',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decide({required bool allRecommended}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = '';
      _notice = '';
    });
    try {
      if (allRecommended) {
        await ApiService.decideProductionTask(
          _lineId,
          _taskId,
          allRecommended: true,
          teamId: widget.teamId,
        );
      } else {
        final List<Map<String, String>> answers = <Map<String, String>>[
          for (final Map<String, dynamic> question in _open)
            <String, String>{
              'qid': '${question['qid'] ?? ''}',
              'value': _answers['${question['qid'] ?? ''}'] ?? '',
            },
        ];
        if (answers.any((Map<String, String> item) => item['value']!.isEmpty)) {
          throw Exception('每一条问题都要有回答（不能留空）');
        }
        await ApiService.decideProductionTask(
          _lineId,
          _taskId,
          answers: answers,
          teamId: widget.teamId,
        );
      }
      await _load();
      if (!mounted) return;
      setState(
        () => _notice = _open.isEmpty
            ? '已记录拍板：没有未答问题，可以进入计划审查'
            : '已记录拍板：还剩 ${_open.length} 条未答',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = productionReadable(error, '拍板失败'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finalize() async {
    if (!_canFinalize || _busy) return;
    setState(() {
      _busy = true;
      _error = '';
      _notice = '';
    });
    try {
      await ApiService.finalizeProductionTask(
        _lineId,
        _taskId,
        teamId: widget.teamId,
      );
      widget.onSaved?.call();
      if (!mounted) return;
      setState(() => _notice = '已落档：范围、计划与验收已写入，任务进入队列');
      await _load();
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = productionReadable(
          error,
          '落档失败（后端未开放准备接口时，请先在 Agent 对话里完成落档）',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _copyEvidence(String value) {
    if (value.trim().isEmpty) return;
    Clipboard.setData(ClipboardData(text: value.trim()));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('已复制证据路径：${value.trim()}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildHeader(cs),
        if (_error.isNotEmpty)
          Container(
            key: const Key('production-prepare-error'),
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            color: cs.errorContainer.withValues(alpha: 0.35),
            child: Text(
              _error,
              style: TextStyle(fontSize: 11.5, color: cs.error),
            ),
          ),
        if (_notice.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(
              _notice,
              style: TextStyle(fontSize: 11.5, color: cs.primary),
            ),
          ),
        _buildStepBar(cs),
        Expanded(
          child: IndexedStack(
            index: _step,
            children: <Widget>[
              _buildIntake(cs),
              _buildRecon(cs),
              _buildQuestions(cs),
              _buildPlan(cs),
            ],
          ),
        ),
        _buildFooter(cs),
      ],
    );
  }

  Widget _buildHeader(ColorScheme cs) => Container(
    height: 48,
    padding: const EdgeInsets.only(left: 14, right: 4),
    decoration: BoxDecoration(
      color: cs.surface,
      border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
    ),
    child: Row(
      children: <Widget>[
        Icon(Icons.rule_folder_outlined, size: 18, color: cs.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '准备 $_taskId · ${_task['title'] ?? widget.task['title'] ?? ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        IconButton(
          tooltip: '刷新',
          visualDensity: VisualDensity.compact,
          onPressed: _busy ? null : _load,
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

  Widget _buildStepBar(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < _stepTitles.length; i++) ...<Widget>[
            InkWell(
              key: Key('production-prepare-step-${i + 1}'),
              onTap: () => setState(() => _step = i),
              borderRadius: BorderRadius.circular(6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: i == _step
                      ? cs.primary.withValues(alpha: 0.12)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: i == _step
                        ? cs.primary.withValues(alpha: 0.5)
                        : Colors.transparent,
                  ),
                ),
                child: Text(
                  '${i + 1}. ${_stepTitles[i]}',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: i == _step
                        ? FontWeight.w600
                        : FontWeight.normal,
                    color: i == _step ? cs.primary : cs.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            if (i < _stepTitles.length - 1)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Icon(Icons.chevron_right, size: 14, color: cs.outline),
              ),
          ],
          const Spacer(),
          Text(
            '状态：${productionStatusLabel(_status)}',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildIntake(ColorScheme cs) {
    final Map<String, dynamic> intake = productionMap(_task['intake']);
    final List<MapEntry<String, dynamic>> fields = <MapEntry<String, dynamic>>[
      MapEntry<String, dynamic>('目标', intake['goal']),
      MapEntry<String, dynamic>('现状', intake['current']),
      MapEntry<String, dynamic>('验收', intake['acceptance']),
      MapEntry<String, dynamic>('约束', intake['constraints']),
      MapEntry<String, dynamic>('不做', intake['out_of_scope']),
    ];
    final bool empty = fields.every(
      (MapEntry<String, dynamic> item) =>
          '${item.value ?? ''}'.trim().isEmpty,
    );
    return ListView(
      key: const Key('production-prepare-intake'),
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        const Text(
          '① 建需求：需求模板五栏。落档时写进范围与验收，缺目标/验收会被后端拒绝。',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        if (empty)
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: cs.errorContainer.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '这条任务还没有需求五栏：请回到工作台「准备」用「新建需求草案」登记，'
              '或在 Agent 对话里补齐后再侦查。',
              style: TextStyle(fontSize: 11.5, color: cs.error),
            ),
          )
        else
          for (final MapEntry<String, dynamic> field in fields)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 44,
                    child: Text(
                      field.key,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '${field.value ?? ''}'.trim().isEmpty
                          ? '（未填）'
                          : '${field.value}',
                      style: const TextStyle(fontSize: 11.5),
                    ),
                  ),
                ],
              ),
            ),
        if (productionListOf(_task, 'attachments').isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            '附件（${productionListOf(_task, 'attachments').length}）',
            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
          ),
          for (final Map<String, dynamic> attachment
              in productionListOf(_task, 'attachments'))
            Text(
              '· ${attachment['name'] ?? attachment['path'] ?? ''}'
              '${productionAttachmentMeta(attachment)}',
              style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant),
            ),
        ],
      ],
    );
  }

  Widget _buildRecon(ColorScheme cs) {
    final Map<String, dynamic> digest = productionMap(_recon['digest']);
    final List<Map<String, dynamic>> evidence = productionListOf(
      _recon,
      'evidence',
    );
    final List<String> keywords = (digest['keywords'] as List<dynamic>? ??
            <dynamic>[])
        .map((Object? item) => '$item')
        .where((String item) => item.trim().isNotEmpty)
        .toList();
    final int questionCount =
        (_recon['questions'] as num?)?.toInt() ??
        _open.length;
    final bool partial = _recon['partial'] == true;
    final bool timeout = _recon['timeout'] == true;
    final bool degraded = _recon['degraded'] == true;
    final bool recallGap = _recon['recall_gap'] == true;
    final bool stale =
        _recon['stale'] == true ||
        '${_recon['flags'] ?? ''}'.contains('stale');
    final String summary = '${digest['requirement_summary'] ?? ''}'.trim();
    return ListView(
      key: const Key('production-prepare-recon'),
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Row(
          children: <Widget>[
            const Expanded(
              child: Text(
                '② 侦查：理解卡（摘要 / 检索 / 模型分段耗时，证据可点）。',
                style: TextStyle(fontSize: 12),
              ),
            ),
            OutlinedButton.icon(
              key: const Key('production-prepare-recon-run'),
              onPressed: _busy ? null : _runRecon,
              icon: const Icon(Icons.manage_search, size: 16),
              label: const Text('重新侦查'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: <Widget>[
            _badge(cs, '问题 ${_open.length}/$questionCount', cs.secondary),
            _badge(cs, '证据 ${evidence.length}', cs.tertiary),
            _badge(cs, '关键词 ${keywords.length}', cs.primary),
            if (partial)
              _badge(
                cs,
                'partial 首版',
                cs.error,
                key: const Key('production-recon-badge-partial'),
              ),
            if (timeout) _badge(cs, 'timeout 到点', cs.error),
            if (degraded) _badge(cs, 'degraded 降级', cs.error),
            if (recallGap) _badge(cs, 'recall_gap 召回缺口', cs.error),
            if (stale) _badge(cs, 'stale 已过期', cs.error),
          ],
        ),
        const SizedBox(height: 8),
        _timing(cs),
        const SizedBox(height: 10),
        if (summary.isEmpty && evidence.isEmpty)
          Text(
            '还没有理解卡：先在工作台/Agent 里完成侦查，或点右上角「重新侦查」。',
            style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
          )
        else ...<Widget>[
          if (summary.isNotEmpty) ...<Widget>[
            const Text('摘要', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(summary, style: const TextStyle(fontSize: 11.5)),
            const SizedBox(height: 8),
          ],
          if (keywords.isNotEmpty) ...<Widget>[
            const Text('关键词', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: <Widget>[
                for (final String keyword in keywords)
                  Chip(
                    label: Text(keyword, style: const TextStyle(fontSize: 10)),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          ..._stringList(cs, '约束', digest['constraints']),
          ..._stringList(cs, '歧义', digest['ambiguities']),
          ..._stringList(cs, '附件摘要', digest['attachment_summaries']),
          if (evidence.isNotEmpty) ...<Widget>[
            const Text('证据', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            for (final Map<String, dynamic> item in evidence)
              InkWell(
                key: Key('production-evidence-${item['id'] ?? ''}'),
                onTap: () => _copyEvidence(
                  '${item['doc'] ?? item['path'] ?? item['id'] ?? ''}',
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '[${item['id'] ?? ''}] ${item['doc'] ?? item['path'] ?? ''}'
                    '${'${item['heading'] ?? ''}'.isEmpty ? '' : ' · ${item['heading']}'}'
                    '${'${item['snippet'] ?? ''}'.isEmpty ? '' : '\n    ${item['snippet']}'}',
                    style: TextStyle(fontSize: 11, color: cs.primary),
                  ),
                ),
              ),
          ],
        ],
      ],
    );
  }

  List<Widget> _stringList(ColorScheme cs, String title, Object? raw) {
    final List<String> items = raw is List
        ? <String>[
            for (final Object? item in raw)
              if (item is Map)
                '${item['name'] ?? item['path'] ?? item['text'] ?? productionMap(item)}'
              else
                '$item',
          ].where((String item) => item.trim().isNotEmpty).toList()
        : <String>[
            if ('${raw ?? ''}'.trim().isNotEmpty) '$raw',
          ];
    if (items.isEmpty) return const <Widget>[];
    return <Widget>[
      Text(title, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
      for (final String item in items)
        Padding(
          padding: const EdgeInsets.only(left: 8, top: 1),
          child: Text(
            '· $item',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ),
      const SizedBox(height: 8),
    ];
  }

  Widget _timing(ColorScheme cs) {
    final int digestMs = (_recon['digest_ms'] as num?)?.toInt() ?? 0;
    final int retrieveMs = (_recon['retrieve_ms'] as num?)?.toInt() ?? 0;
    final int llmMs = (_recon['llm_ms'] as num?)?.toInt() ?? 0;
    final int totalMs = (_recon['total_ms'] as num?)?.toInt() ?? 0;
    return Container(
      key: const Key('production-recon-timing'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: <Widget>[
          _timingCell(cs, '摘要', digestMs),
          _timingCell(cs, '检索', retrieveMs),
          _timingCell(cs, '模型', llmMs),
          _timingCell(cs, '合计', totalMs),
        ],
      ),
    );
  }

  Widget _timingCell(ColorScheme cs, String label, int ms) => Expanded(
    child: Column(
      children: <Widget>[
        Text(
          '$ms ms',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        Text(
          label,
          style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
        ),
      ],
    ),
  );

  Widget _badge(ColorScheme cs, String text, Color color, {Key? key}) => Container(
    key: key,
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: color.withValues(alpha: 0.4)),
    ),
    child: Text(text, style: TextStyle(fontSize: 10.5, color: color)),
  );

  Widget _buildQuestions(ColorScheme cs) {
    return ListView(
      key: const Key('production-prepare-questions'),
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        const Text(
          '③ 拍板：逐条回答或「全部按推荐」。只要还有未答问题，落档按钮就是禁用的。',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                _open.isEmpty
                    ? '没有未答问题，可以进入下一步'
                    : '剩余未答：${_openQids.join('、')}',
                key: const Key('production-prepare-open-questions'),
                style: TextStyle(
                  fontSize: 11.5,
                  color: _open.isEmpty ? cs.onSurfaceVariant : cs.error,
                  fontWeight: _open.isEmpty
                      ? FontWeight.normal
                      : FontWeight.w600,
                ),
              ),
            ),
            TextButton(
              key: const Key('production-prepare-all-recommended'),
              onPressed: _busy || _open.isEmpty
                  ? null
                  : () => _decide(allRecommended: true),
              child: const Text('全部按推荐'),
            ),
            const SizedBox(width: 4),
            FilledButton.tonal(
              key: const Key('production-prepare-submit-answers'),
              onPressed: _busy || _open.isEmpty
                  ? null
                  : () => _decide(allRecommended: false),
              child: const Text('提交回答'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (_open.isEmpty)
          Text(
            '已全部回答；进入「计划审查 / 落档」检查 7 块与 high findings。',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          )
        else
          for (final Map<String, dynamic> question in _open)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    '${question['qid'] ?? ''}  ${question['text'] ?? ''}',
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  if ('${question['consequence'] ?? ''}'.isNotEmpty)
                    Text(
                      '后果：${question['consequence']}',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  TextFormField(
                    key: Key('production-prepare-answer-${question['qid'] ?? ''}'),
                    initialValue: _answers['${question['qid'] ?? ''}'] ?? '',
                    decoration: InputDecoration(
                      isDense: true,
                      helperText:
                          '默认：${question['default'] ?? '（无）'} · '
                          '推荐：${question['recommended'] ?? '（无）'}',
                    ),
                    onChanged: (String value) =>
                        _answers['${question['qid'] ?? ''}'] = value.trim(),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  Widget _buildPlan(ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _open.isEmpty
                      ? '④ 计划审查：7 块 / findings / 追踪矩阵 / 批次 / 版本差异。'
                      : '先回答剩余问题（${_openQids.join('、')}），再落档。',
                  style: TextStyle(
                    fontSize: 12,
                    color: _open.isEmpty ? null : cs.error,
                  ),
                ),
              ),
              Tooltip(
                message: _canFinalize
                    ? '写 scope / plan / acceptance，建 queued 任务'
                    : (!_open.isNotEmpty
                          ? '还有未答问题：${_openQids.join('、')}'
                          : (_planBlocked
                                ? '计划有未关闭 high findings 或追踪断链'
                                : '当前状态 ${productionStatusLabel(_status)} 不能落档')),
                child: FilledButton(
                  key: const Key('production-prepare-finalize'),
                  onPressed: _canFinalize && !_busy ? _finalize : null,
                  child: Text(_busy ? '落档中…' : '落档'),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ProductionPlanReview(
            lineId: _lineId,
            teamId: widget.teamId,
            showFinalize: false,
            onBlockingChanged: (bool blocked) {
              if (_planBlocked == blocked) return;
              setState(() => _planBlocked = blocked);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildFooter(ColorScheme cs) => Container(
    padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
    ),
    child: Row(
      children: <Widget>[
        if (_step > 0)
          TextButton(
            key: const Key('production-prepare-prev'),
            onPressed: () => setState(() => _step -= 1),
            child: const Text('上一步'),
          ),
        const Spacer(),
        if (_step < 3)
          FilledButton.tonal(
            key: const Key('production-prepare-next'),
            onPressed: () => setState(() => _step += 1),
            child: const Text('下一步'),
          ),
      ],
    ),
  );
}
