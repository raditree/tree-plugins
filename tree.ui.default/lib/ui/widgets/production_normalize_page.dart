import 'package:flutter/material.dart';

import '../../io/api_service.dart';
import 'production_line_utils.dart';

/// 文档归一化预览页（PC-5C / Task 9.4）。
///
/// 数据源：
/// - `GET  /api/production/lines/{id}/normalize`（状态，只读）
/// - `POST /api/production/lines/{id}/normalize/plan`（commit=false，0 写盘，回 diff）
/// - `POST /api/production/lines/{id}/normalize/apply`（确认后串行写盘）
/// - `POST /api/production/lines/{id}/normalize/rollback`（按 run_id 回滚）
///
/// 硬口径在页面上直接写出来：不自动 git commit；写入期间暂停开新任务；
/// `rewrite` 必须勾选二次确认并填写 allowlist 才能应用。
class ProductionNormalizePage extends StatefulWidget {
  const ProductionNormalizePage({
    super.key,
    required this.lineId,
    this.teamId = '',
    this.onClose,
  });

  final String lineId;
  final String teamId;
  final VoidCallback? onClose;

  @override
  State<ProductionNormalizePage> createState() =>
      _ProductionNormalizePageState();
}

class _ProductionNormalizePageState extends State<ProductionNormalizePage> {
  bool _loading = true;
  bool _applying = false;
  bool _rollingBack = false;
  bool _confirmRewrite = false;
  String _error = '';
  String _message = '';
  Map<String, dynamic> _status = <String, dynamic>{};
  Map<String, dynamic>? _plan;
  final TextEditingController _allowlist = TextEditingController();

  List<Map<String, dynamic>> get _files => _plan == null
      ? productionListOf(_status, 'files')
      : productionListOf(_plan!, 'files');

  bool get _hasRewrite => _files.any(_isRewrite);

  bool get _busy => _applying || _rollingBack;

  bool get _canApply {
    if (_busy || _loading) return false;
    if (_hasRewrite && (!_confirmRewrite || _allowlist.text.trim().isEmpty)) {
      return false;
    }
    return true;
  }

  String get _runId => '${_plan?['run_id'] ?? _status['run_id'] ?? ''}'.trim();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _allowlist.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = _plan == null;
      _error = '';
    });
    try {
      final Map<String, dynamic> status =
          await ApiService.getProductionNormalize(
            widget.lineId,
            teamId: widget.teamId,
          );
      final Map<String, dynamic> plan =
          await ApiService.planProductionNormalize(
            widget.lineId,
            teamId: widget.teamId,
          );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _status = status;
        _plan = plan;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = productionReadable(error, '归一化预检失败');
      });
    }
  }

  Future<void> _apply() async {
    if (!_canApply) return;
    setState(() {
      _applying = true;
      _error = '';
      _message = '';
    });
    try {
      final Map<String, dynamic> result =
          await ApiService.applyProductionNormalize(
            widget.lineId,
            runId: _runId,
            confirmRewrite: _hasRewrite && _confirmRewrite,
            rewriteAllowlist: _hasRewrite ? _parseAllowlist() : null,
            teamId: widget.teamId,
          );
      if (!mounted) return;
      setState(() {
        _confirmRewrite = false;
        _allowlist.clear();
        _message = '已应用归一化：${result['status'] ?? result['run_id'] ?? '完成'}';
      });
      await _load();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = productionReadable(error, '应用失败'));
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Future<void> _rollback() async {
    final String runId = _runId;
    if (_busy) return;
    if (runId.isEmpty) {
      setState(() => _error = '没有可回滚的运行（缺 run_id）');
      return;
    }
    setState(() {
      _rollingBack = true;
      _error = '';
      _message = '';
    });
    try {
      final Map<String, dynamic> result =
          await ApiService.rollbackProductionNormalize(
            widget.lineId,
            runId: runId,
            teamId: widget.teamId,
          );
      if (!mounted) return;
      setState(() => _message = '已回滚：${result['status'] ?? runId}');
      await _load();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = productionReadable(error, '回滚失败'));
    } finally {
      if (mounted) setState(() => _rollingBack = false);
    }
  }

  List<String> _parseAllowlist() => <String>[
    for (final String item in _allowlist.text.split(RegExp(r'[,，\n]')))
      if (item.trim().isNotEmpty) item.trim(),
  ];

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      key: const Key('production-normalize-page'),
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
                Icon(Icons.auto_fix_high_outlined, size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '文档归一化 · ${widget.lineId}',
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
                  ),
                TextButton(
                  key: const Key('production-normalize-plan-refresh'),
                  onPressed: _busy ? null : _load,
                  child: const Text('重新预检'),
                ),
                if (widget.onClose != null)
                  IconButton(
                    key: const Key('production-normalize-close'),
                    tooltip: '关闭',
                    visualDensity: VisualDensity.compact,
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close, size: 18),
                  ),
              ],
            ),
          ),
          if (_busy)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const LinearProgressIndicator(minHeight: 4),
                  const SizedBox(height: 4),
                  Text(
                    _applying ? '写入中…（期间暂停开新任务）' : '回滚中…',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                _error,
                key: const Key('production-normalize-error'),
                style: TextStyle(fontSize: 11.5, color: cs.error),
              ),
            ),
          if (_message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                _message,
                key: const Key('production-normalize-message'),
                style: TextStyle(fontSize: 11.5, color: cs.primary),
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
    if (_error.isNotEmpty && _plan == null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(_error, style: TextStyle(fontSize: 12, color: cs.error)),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('production-normalize-retry'),
              onPressed: _load,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final List<Map<String, dynamic>> files = _files;
    return ListView(
      key: const Key('production-normalize-plan'),
      padding: const EdgeInsets.only(bottom: 20),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
          child: Text(
            '状态：${_statusText(cs)}'
            '${_runId.isEmpty ? '' : ' · run $_runId'}',
            style: const TextStyle(fontSize: 11.5),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
          child: Text(
            '预检（commit=false）0 写盘；应用后只追加 / 建索引，'
            '不会自动 git commit。写入期间暂停开新任务。',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ),
        if (files.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
            child: Text(
              '没有需要归一化的文件',
              style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
            ),
          )
        else ...<Widget>[
          for (final Map<String, dynamic> file in files) _buildFile(cs, file),
          _buildRewriteGate(cs),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: <Widget>[
              FilledButton(
                key: const Key('production-normalize-apply'),
                onPressed: _canApply ? _apply : null,
                child: Text(_applying ? '写入中…' : '应用'),
              ),
              const SizedBox(width: 8),
              TextButton(
                key: const Key('production-normalize-rollback'),
                onPressed: _busy || _runId.isEmpty ? null : _rollback,
                child: Text(_rollingBack ? '回滚中…' : '回滚'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _statusText(ColorScheme cs) {
    final String status = '${_status['status'] ?? _status['phase'] ?? ''}'
        .trim();
    if (status.isEmpty) return '未知（还没有归一化运行）';
    final Map<String, dynamic> counts = productionMap(_status['counts']);
    final List<String> extra = <String>[
      if (counts['files'] != null) '文件 ${counts['files']}',
      if (counts['skipped'] != null) '跳过 ${counts['skipped']}',
      if (counts['rejected'] != null) '拒绝 ${counts['rejected']}',
    ];
    return extra.isEmpty ? status : '$status · ${extra.join(' · ')}';
  }

  Widget _buildFile(ColorScheme cs, Map<String, dynamic> file) {
    final String path = '${file['path'] ?? ''}';
    final List<String> actions = _actions(file);
    final String diff = '${file['diff'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            if (actions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '动作：${actions.join('、')}',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ),
            if (diff.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.all(8),
                width: double.infinity,
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Theme.of(context).dividerColor),
                ),
                child: Text(
                  diff,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10.5,
                    height: 1.35,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRewriteGate(ColorScheme cs) {
    if (!_hasRewrite) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
        decoration: BoxDecoration(
          color: cs.errorContainer.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: cs.error.withValues(alpha: 0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '本次预检包含 rewrite（改写既有文档）：必须勾选二次确认并填写 '
              'allowlist 才能应用。',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
            Row(
              children: <Widget>[
                Checkbox(
                  key: const Key('production-normalize-confirm-rewrite'),
                  value: _confirmRewrite,
                  onChanged: _busy
                      ? null
                      : (bool? value) =>
                            setState(() => _confirmRewrite = value == true),
                ),
                const Expanded(
                  child: Text('我确认改写', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            TextField(
              key: const Key('production-normalize-allowlist'),
              controller: _allowlist,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'rewrite allowlist（逗号分隔）',
                hintText: 'docs/architecture.md, README.md',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
    );
  }

  List<String> _actions(Map<String, dynamic> file) {
    final Object? raw = file['actions'] ?? file['action'];
    if (raw is List) {
      return <String>[
        for (final Object? item in raw)
          if ('$item'.trim().isNotEmpty) '$item'.trim(),
      ];
    }
    final String text = '${raw ?? ''}'.trim();
    return text.isEmpty ? <String>[] : <String>[text];
  }

  bool _isRewrite(Map<String, dynamic> file) {
    if (file['rewrite'] == true) return true;
    return _actions(file)
        .any((String action) => action.toLowerCase().contains('rewrite'));
  }
}
