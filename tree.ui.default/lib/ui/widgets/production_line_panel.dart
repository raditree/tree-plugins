import 'package:flutter/material.dart';

import '../../io/api_service.dart';
import '../app_radius.dart';
import 'create_production_line_dialog.dart';
import 'production_line_utils.dart';

/// 左栏「生产线」面板（活动栏第 4 项）—— **只负责选产线**。
///
/// §16.1：产线是独立功能，与 Agent 同级并列。左栏窄（260px）只放列表：
/// 选中一条产线后中栏切到 [ProductionLineWorkbench]（任务队列 / 决策收件箱 /
/// 台账 / 产物）。队列与拍板不再塞在左栏里。
///
/// 数据全部走 REST（`/api/production/*`，由 `tree.production.line` 插件承接）；
/// 产线数据在**全局作用域**，`team_id` 只作调用方身份，不再决定列表归属。
class ProductionLinePanel extends StatefulWidget {
  const ProductionLinePanel({
    super.key,
    required this.teamId,
    this.agentId = '',
    this.visible = true,
    this.selectedLineId = '',
    this.refreshToken = 0,
    this.onSelectLine,
    this.onCollapse,
  });

  /// 调用方团队（REST 的 `team_id` 查询参数；只作身份，不再决定数据目录）。
  final String teamId;

  /// 调用方 Agent（派发回退身份 / 默认执行 Agent）。
  final String agentId;

  /// 面板是否露脸：由隐藏变可见时重拉清单（与插件面板同一口径）。
  final bool visible;

  /// 当前选中的产线 id（高亮用；由中栏工作台共享同一份选中状态）。
  final String selectedLineId;

  /// 外部要求重拉列表（工作台改 / 删产线后递增）。
  final int refreshToken;

  /// 选中产线：null = 清掉选中（列表里已不存在 / 删除了）。
  final ValueChanged<Map<String, dynamic>?>? onSelectLine;

  final VoidCallback? onCollapse;

  @override
  State<ProductionLinePanel> createState() => _ProductionLinePanelState();
}

class _ProductionLinePanelState extends State<ProductionLinePanel> {
  bool _loading = true;
  String _error = '';
  List<Map<String, dynamic>> _lines = <Map<String, dynamic>>[];
  final Set<String> _actionBusy = <String>{};

  String get _teamId => widget.teamId.trim();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ProductionLinePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.teamId != widget.teamId) {
      _lines = <Map<String, dynamic>>[];
      _loading = true;
      _load();
      return;
    }
    if (!oldWidget.visible && widget.visible) _load();
    if (oldWidget.refreshToken != widget.refreshToken) _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = _lines.isEmpty;
        _error = '';
      });
    }
    try {
      final Map<String, dynamic> data = await ApiService.getProductionLines(
        teamId: _teamId,
      );
      if (!mounted) return;
      final List<Map<String, dynamic>> lines = productionListOf(data, 'lines');
      setState(() {
        _loading = false;
        _lines = lines;
      });
      final String selected = widget.selectedLineId;
      if (selected.isNotEmpty &&
          !lines.any((Map<String, dynamic> line) => '${line['id']}' == selected)) {
        widget.onSelectLine?.call(null);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = productionReadable(error, '产线列表加载失败');
      });
    }
  }

  void _notify(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(text)));
  }

  /// 统一收口：忙碌标记 + 可读错误（SnackBar，不打断列表）。
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

  /// 新建产线时预填的目录：取已有产线的第一个工作空间，避免每次都手输。
  String get _lastWorkspace {
    for (final Map<String, dynamic> line in _lines) {
      final String dir = '${line['workspace_dir'] ?? ''}'.trim();
      if (dir.isNotEmpty) return dir;
    }
    return '';
  }

  Future<void> _createLine() async {
    final ProductionLineSpec? spec =
        await showDialog<ProductionLineSpec>(
          context: context,
          builder: (BuildContext context) => CreateProductionLineDialog(
            initialWorkspace: _lastWorkspace,
            defaultAgentId: widget.agentId.trim(),
          ),
        );
    if (spec == null || spec.name.isEmpty) return;
    await _act('create-line', () async {
      final Map<String, dynamic> result = await ApiService.createProductionLine(
        name: spec.name,
        workspaceDir: spec.workspace,
        executor: spec.executor,
        roles: spec.roles,
        orchestrator: spec.orchestrator,
        teamId: _teamId,
      );
      await _load();
      final Map<String, dynamic> created = productionMap(result['line']);
      if (created.isNotEmpty) widget.onSelectLine?.call(created);
      _notify('已创建产线：${spec.name}');
    });
  }

  /// 旧团队目录 → 全局作用域（§16.3）。幂等：没有旧数据时只回「无待迁移」。
  Future<void> _migrate() async {
    if (_actionBusy.contains('migrate')) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('迁移旧产线'),
        content: const Text(
          '把旧版本按 Agent / 团队分目录存放的产线搬进全局作用域。\n\n'
          '迁移是「移动」：搬迁前留快照，台账写 production_lines/_migrations/；'
          '目标已有同 id 产线时只报冲突，不覆盖。重复执行不会重复搬迁。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('production-migrate-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('开始迁移'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _act('migrate', () async {
      final Map<String, dynamic> result =
          await ApiService.migrateProductionLines(
            agentId: widget.agentId.trim(),
            teamId: _teamId,
          );
      await _load();
      _notify('${result['note'] ?? '迁移完成'}');
    });
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
                onPressed: _createLine,
                icon: const Icon(Icons.add, size: 18),
              ),
              PopupMenuButton<String>(
                key: const Key('production-line-list-menu'),
                tooltip: '更多',
                padding: EdgeInsets.zero,
                iconSize: 18,
                onSelected: (String value) {
                  if (value == 'migrate') _migrate();
                  if (value == 'refresh') _load();
                },
                itemBuilder: (BuildContext context) =>
                    <PopupMenuEntry<String>>[
                      const PopupMenuItem<String>(
                        value: 'migrate',
                        child: Text('迁移旧产线'),
                      ),
                      const PopupMenuItem<String>(
                        value: 'refresh',
                        child: Text('刷新列表'),
                      ),
                    ],
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
            Text(_error, style: TextStyle(fontSize: 12, color: cs.error)),
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
          '还没有产线：点右上角「+」新建一条（生产数据落插件数据根）。',
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
    final String workspace = '${line['workspace_dir'] ?? ''}'.trim();
    final bool selected = widget.selectedLineId == id;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: Material(
        color: selected
            ? cs.secondaryContainer.withValues(alpha: 0.5)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: Key('production-line-item-$id'),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          onTap: () => widget.onSelectLine?.call(line),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 6, 8),
          child: Row(
            children: <Widget>[
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: productionStatusColor(cs, status),
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
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
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
                    if (workspace.isNotEmpty)
                      Text(
                        workspace,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10.5, color: cs.outline),
                      ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.chevron_right, size: 16, color: cs.primary),
            ],
          ),
          ),
        ),
      ),
    );
  }
}
