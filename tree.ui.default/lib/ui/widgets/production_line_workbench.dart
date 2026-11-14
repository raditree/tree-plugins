import 'dart:async';

import 'package:flutter/material.dart';

import '../../io/api_service.dart';
import '../../io/attachment_upload_service.dart';
import '../../io/protocol_contract.dart';
import '../../io/station_client.dart';
import 'create_production_line_dialog.dart';
import 'production_line_utils.dart';
import 'production_normalize_page.dart';
import 'production_plan_review.dart';
import 'production_prepare_page.dart';
import 'production_structure_page.dart';

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
    this.deliveries,
    this.pollInterval = const Duration(seconds: 3),
    this.onCollapse,
    this.onDeleted,
    this.onLineUpdated,
    this.onOpenTask,
  });

  /// 当前选中的产线（`line.yaml` 的 JSON）；null = 还没选。
  final Map<String, dynamic>? line;

  /// 调用方身份（REST 的 `team_id` 查询参数，只作身份，不再决定归属）。
  final String teamId;

  /// 调用方 Agent（派发缺省执行身份时的回退；产线写了 executor 就不需要）。
  final String agentId;

  /// 工作台是否露脸：由隐藏变可见时重拉明细（与左栏面板同一口径）。
  final bool visible;

  /// 站点投递流（默认 `StationClient.instance.deliveries`；测试可注入）。
  final Stream<StationDelivery>? deliveries;

  /// 推送缺失时的兜底轮询间隔（默认 3s；测试可注入毫秒级）。
  final Duration pollInterval;

  /// 折叠中栏（把宽度让给侧栏）。
  final VoidCallback? onCollapse;

  /// 产线被删除：上层清掉选中并刷新左栏列表。
  final VoidCallback? onDeleted;

  /// 产线配置被改：上层用新数据替换选中项。
  final ValueChanged<Map<String, dynamic>>? onLineUpdated;

  /// 点开一条任务：上层在右栏打开 `productionTask` 窗口（不用中栏抽屉）。
  final ValueChanged<String>? onOpenTask;

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
  Map<String, dynamic>? _dedup;

  /// 主控状态（D6-O）：配置 / 最近动作 / 连续失败 / 未答运行期问题。
  Map<String, dynamic>? _orchestrator;

  /// 整理报告每批文件数（一次请求一批；改完点「继续扫描」跑下一批）。
  final TextEditingController _auditBatch = TextEditingController(text: '500');

  /// 逻辑去重每批文件数（一次请求一批；点「运行下一批」继续）。
  final TextEditingController _dedupBatch = TextEditingController(text: '50');

  /// 批量派发每批上限（0 / 空 = 不额外限制）。
  final TextEditingController _bulkLimit = TextEditingController(text: '3');

  /// 当前入口：0 今日 / 1 准备 / 2 执行 / 3 工具。
  int _tab = 0;

  /// 批量派发 dry run 结果（`batch_ids / skipped / slots_*`）。
  Map<String, dynamic>? _bulk;

  /// 最近一次漂移报告。
  Map<String, dynamic>? _drift;

  /// 单条产线 / 任务的写操作进行中（按钮转圈、防重复提交）。
  final Set<String> _actionBusy = <String>{};

  /// 复合就绪门（null = 老插件没有该路由，不禁用按钮）。
  Map<String, dynamic>? _readiness;

  /// 产线阶段（organizing / normalizing / indexing / ready）。
  String _phase = '';

  /// `production.task_state` 的本地水位（只接受单调递增 seq）。
  int _lastSeq = 0;

  StreamSubscription<StationDelivery>? _events;
  Timer? _pollTimer;
  bool _refreshing = false;

  String? get _lineId {
    final String id = '${widget.line?['id'] ?? ''}'.trim();
    return id.isEmpty ? null : id;
  }

  String get _teamId => widget.teamId.trim();

  String get _agentId => widget.agentId.trim();

  bool? get _readyFlag => productionReadinessReady(_readiness);

  /// 未就绪 / 阶段未知时禁用开任务入口（未知 = 老插件，不禁用）。
  bool get _isBlocked => _readyFlag == false;

  String get _phaseLabel => productionPhaseLabel(_phase);

  /// 409 原因文案（缺失项逐条列出；banner 与禁用按钮 tooltip 共用）。
  String get _blockedReason {
    final List<String> missing = productionReadinessMissing(
      _readiness ?? <String, dynamic>{},
    );
    final String phase = _phaseLabel;
    final String head = phase.isEmpty ? '产线未就绪' : '$phase：产线未就绪';
    if (missing.isEmpty) return '$head（409 拒绝开新任务）';
    return '$head（409：${missing.join('；')}）';
  }

  @override
  void initState() {
    super.initState();
    _phase = '${widget.line?['phase'] ?? ''}'.trim();
    _listenEvents();
    if (_lineId != null) {
      _loadDetails();
      _startPolling();
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
    if (oldWidget.deliveries != widget.deliveries) {
      _listenEvents();
    }
    if (oldId != _lineId) {
      _tasks = <Map<String, dynamic>>[];
      _runs = <Map<String, dynamic>>[];
      _artifacts = null;
      _audit = null;
      _orchestrator = null;
      _readiness = null;
      _bulk = null;
      _drift = null;
      _tab = 0;
      _phase = '${widget.line?['phase'] ?? ''}'.trim();
      _lastSeq = 0;
      _error = '';
      _loading = _lineId != null;
      _stopPolling();
      // 换线视为新快照：上一轮请求即使还在途，也不能再往新线里写结果。
      _refreshing = false;
      if (_lineId != null) {
        _loadDetails();
        _startPolling();
      }
      return;
    }
    if (!oldWidget.visible && widget.visible && _lineId != null) {
      // 恢复可见：先拉一次 REST 快照，再恢复轮询（停轮询期间可能漏帧）。
      _loadDetails();
      _startPolling();
    } else if (oldWidget.visible && !widget.visible) {
      _stopPolling();
    }
  }

  @override
  void dispose() {
    _auditBatch.dispose();
    _dedupBatch.dispose();
    _bulkLimit.dispose();
    _stopPolling();
    final StreamSubscription<StationDelivery>? events = _events;
    _events = null;
    if (events != null) unawaited(events.cancel());
    super.dispose();
  }

  /// 订阅 `broadcast.task_state`（默认走应用级 [StationClient]）。
  void _listenEvents() {
    final StreamSubscription<StationDelivery>? previous = _events;
    _events = null;
    if (previous != null) unawaited(previous.cancel());
    _events = (widget.deliveries ?? StationClient.instance.deliveries).listen(
      _onDelivery,
    );
  }

  /// 3s 兜底轮询：只在页面可见且有选中产线时运行。
  void _startPolling() {
    _stopPolling();
    if (!mounted || _lineId == null || !widget.visible) return;
    _pollTimer = Timer.periodic(widget.pollInterval, (Timer _) {
      if (!mounted) return;
      _loadDetails();
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// 处理产线任务状态推送：seq 单调递增；跳号 / 非本产线 / 解析失败走全量刷新。
  void _onDelivery(StationDelivery delivery) {
    final String? lineId = _lineId;
    if (lineId == null) return;
    if (delivery.stationId != StationClient.productionTaskStateStation) return;
    if (delivery.state == StationDeliveryState.reset ||
        delivery.state == StationDeliveryState.lagged) {
      // 通道重置 / 队列溢出：本地水位失效，直接拉快照。
      _lastSeq = 0;
      _loadDetails();
      return;
    }
    if (delivery.state != StationDeliveryState.data) return;
    final Object? rawPayload = delivery.payload;
    if (rawPayload is! Map) {
      _loadDetails();
      return;
    }
    final Map<String, dynamic> payload = productionMap(rawPayload);
    final String eventLine =
        '${payload['line_id'] ?? payload['line']?['id'] ?? ''}'.trim();
    if (eventLine.isNotEmpty && eventLine != lineId) {
      // 非本产线事件：不混进当前队列，拉一次快照对齐当前产线。
      _loadDetails();
      return;
    }
    final int seq = (payload['seq'] as num?)?.toInt() ?? delivery.seq ?? 0;
    final Map<String, dynamic> task = productionMap(payload['task']);
    final Map<String, dynamic> line = productionMap(payload['line']);
    if (seq <= 0 || (task.isEmpty && line.isEmpty)) {
      // 解析不出可用的增量：退化成一次全量刷新，不静默。
      _loadDetails();
      return;
    }
    if (seq <= _lastSeq) return; // 重复 / 回退：忽略
    if (_lastSeq > 0 && seq > _lastSeq + 1) {
      // 跳号 = 漏帧：本地状态有缺口，拉快照；水位先跟上，避免连续 gap 抖动。
      _lastSeq = seq;
      _loadDetails();
      return;
    }
    _lastSeq = seq;
    final String phase = '${line['phase'] ?? ''}'.trim();
    if (!mounted) return;
    setState(() {
      if (phase.isNotEmpty) _phase = phase;
      if (task.isNotEmpty) _upsertTask(task);
    });
  }

  /// 增量更新一条任务（同 id 合并字段，新任务插到队首）。
  void _upsertTask(Map<String, dynamic> task) {
    final String id = '${task['id'] ?? ''}'.trim();
    if (id.isEmpty) return;
    final int index = _tasks.indexWhere(
      (Map<String, dynamic> item) => '${item['id'] ?? ''}' == id,
    );
    if (index >= 0) {
      _tasks[index] = <String, dynamic>{..._tasks[index], ...task};
    } else {
      _tasks = <Map<String, dynamic>>[task, ..._tasks];
    }
  }

  Future<void> _loadDetails() async {
    final String? lineId = _lineId;
    if (lineId == null || _refreshing) return;
    _refreshing = true;
    try {
      setState(() {
        _loading = _tasks.isEmpty;
        _error = '';
      });
      final List<Map<String, dynamic>> results = await Future.wait(
        <Future<Map<String, dynamic>>>[
          ApiService.getProductionTasks(lineId, teamId: _teamId),
          ApiService.getProductionRuns(lineId, teamId: _teamId),
          // 就绪门是增量能力：老插件没有该路由时回空（未知 = 不禁用按钮）。
          _readinessOrUnknown(lineId),
        ],
      );
      if (!mounted || _lineId != lineId) return;
      setState(() {
        _loading = false;
        _tasks = productionListOf(results[0], 'tasks');
        _runs = productionListOf(results[1], 'runs');
        _readiness = results[2].isEmpty ? null : results[2];
        final String phase = '${results[2]['phase'] ?? ''}'.trim();
        if (phase.isNotEmpty) _phase = phase;
      });
      // 主控状态是增量能力：老插件没有这条路由时不影响任务 / 台账展示。
      try {
        final Map<String, dynamic> orchestrator =
            await ApiService.getProductionOrchestrator(lineId, teamId: _teamId);
        if (!mounted || _lineId != lineId) return;
        setState(() => _orchestrator = orchestrator);
      } catch (_) {
        if (!mounted || _lineId != lineId) return;
        setState(() => _orchestrator = null);
      }
    } catch (error) {
      if (!mounted || _lineId != lineId) return;
      setState(() {
        _loading = false;
        _error = productionReadable(error, '产线明细加载失败');
      });
    } finally {
      _refreshing = false;
    }
  }

  Future<Map<String, dynamic>> _readinessOrUnknown(String lineId) async {
    try {
      return await ApiService.getProductionReadiness(lineId, teamId: _teamId);
    } catch (_) {
      return <String, dynamic>{};
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

  Future<void> _loadAudit({bool force = false, bool refresh = false}) async {
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
        refresh: refresh,
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

  /// 逻辑去重：GET 只读上次结果；GET 不触发 embedding。
  Future<void> _loadDedup() async {
    final String? lineId = _lineId;
    if (lineId == null) return;
    if (_dedup != null) {
      setState(() => _dedup = null);
      return;
    }
    await _act('$lineId/dedup-read', () async {
      final Map<String, dynamic> data = await ApiService.getProductionDedup(
        lineId,
        teamId: _teamId,
      );
      if (mounted) setState(() => _dedup = data);
    });
  }

  /// 逻辑去重：显式推进一批（embedding 付费动作）。
  Future<void> _runDedup({String mode = 'incremental'}) async {
    final String? lineId = _lineId;
    if (lineId == null) return;
    final int limit = (int.tryParse(_dedupBatch.text.trim()) ?? 50).clamp(
      1,
      500,
    );
    await _act('$lineId/dedup-run', () async {
      await ApiService.runProductionDedup(
        lineId,
        teamId: _teamId,
        mode: mode,
        limit: limit,
      );
      final Map<String, dynamic> data = await ApiService.getProductionDedup(
        lineId,
        teamId: _teamId,
      );
      if (mounted) setState(() => _dedup = data);
    });
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
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _createTask({String taskType = ''}) async {
    final String? lineId = _lineId;
    if (lineId == null) return;
    if (_isBlocked) {
      _notify(_blockedReason);
      return;
    }
    final String workspace = '${widget.line?['workspace_dir'] ?? ''}'.trim();
    final _NewTaskSpec? spec = await showDialog<_NewTaskSpec>(
      context: context,
      builder: (BuildContext context) => _NewTaskDialog(
        lineId: lineId,
        workspace: workspace,
        workspaceId: 'line:$lineId',
        teamId: _teamId,
        taskType: taskType,
      ),
    );
    if (spec == null || spec.title.isEmpty) return;
    await _act('$lineId/create-task', () async {
      final Map<String, dynamic> result = await ApiService.createProductionTask(
        lineId,
        <String, dynamic>{...spec.toTaskJson(), 'status': 'queued'},
        teamId: _teamId,
      );
      final String taskId = '${productionMap(result['task'])['id'] ?? ''}';
      if (taskId.isNotEmpty) {
        await _attachUploaded(spec, taskId);
      }
      await _loadDetails();
      _notify('已建${taskType == 'cleanup' ? ' cleanup ' : ''}任务：${spec.title}');
    });
  }

  /// 准备阶段的「新建需求草案」：intake 五栏 → `draft` 任务，随后进入准备四步。
  Future<void> _createDraftTask() async {
    final String? lineId = _lineId;
    if (lineId == null) return;
    final _IntakeSpec? spec = await showDialog<_IntakeSpec>(
      context: context,
      builder: (BuildContext context) => const _IntakeDialog(),
    );
    if (spec == null || spec.title.isEmpty) return;
    await _act('$lineId/create-draft', () async {
      final Map<String, dynamic> result = await ApiService.createProductionTask(
        lineId,
        <String, dynamic>{
          'title': spec.title,
          'status': 'draft',
          'priority': 50,
          'task_type': 'code',
          'intake': spec.intake,
          'brief': spec.intake['goal'] ?? '',
        },
        teamId: _teamId,
      );
      await _loadDetails();
      final Map<String, dynamic> task = productionMap(result['task']);
      if (mounted && task.isNotEmpty) {
        await _openPrepare(task);
      }
      _notify('已建需求草案：${spec.title}');
    });
  }

  /// 编辑任务（PATCH）；packed 任务保存后由后端回 queued 并失效旧包。
  Future<void> _editTask(Map<String, dynamic> task) async {
    final String? lineId = _lineId;
    final String taskId = '${task['id'] ?? ''}';
    if (lineId == null || taskId.isEmpty) return;
    if (_isBlocked) {
      _notify(_blockedReason);
      return;
    }
    final String workspace = '${widget.line?['workspace_dir'] ?? ''}'.trim();
    final _NewTaskSpec? spec = await showDialog<_NewTaskSpec>(
      context: context,
      builder: (BuildContext context) => _NewTaskDialog(
        lineId: lineId,
        workspace: workspace,
        workspaceId: 'line:$lineId',
        teamId: _teamId,
        initial: task,
      ),
    );
    if (spec == null) return;
    await _act('$lineId/$taskId/save', () async {
      final Map<String, dynamic> result = await ApiService.updateProductionTask(
        lineId,
        taskId,
        spec.toPatchJson(),
        teamId: _teamId,
      );
      await _attachUploaded(spec, taskId);
      await _loadDetails();
      final String note = '${result['note'] ?? ''}';
      _notify(note.isEmpty ? '已保存任务：$taskId' : note);
    });
  }

  /// 上传后的附件逐条登记到任务（`{source,name,type,vision}`）。
  Future<void> _attachUploaded(_NewTaskSpec spec, String taskId) async {
    final String? lineId = _lineId;
    if (lineId == null || spec.attachments.isEmpty) return;
    final List<String> warnings = <String>[];
    for (final Map<String, dynamic> attachment in spec.attachments) {
      final Map<String, dynamic> result = await ApiService.attachProductionTask(
        lineId,
        taskId,
        source: '${attachment['source'] ?? ''}',
        name: '${attachment['name'] ?? ''}',
        vision: attachment['vision'] == true,
        teamId: _teamId,
      );
      warnings.addAll(
        (result['warnings'] as List<dynamic>? ?? <dynamic>[])
            .map((dynamic item) => '$item'),
      );
      final String hash = '${productionMap(result['attachment'])['sha256'] ?? ''}';
      if (hash.isNotEmpty && mounted) {
        _notify(
          '附件已登记：${attachment['name'] ?? ''} · sha256 ${hash.substring(0, hash.length > 8 ? 8 : hash.length)}',
        );
      }
    }
    if (warnings.isNotEmpty && mounted) {
      _notify('附件提示：${warnings.join('；')}');
    }
  }

  /// 准备四步整页对话框（不打断工作台队列状态）。
  Future<void> _openPrepare(Map<String, dynamic> task) async {
    final String? lineId = _lineId;
    final String taskId = '${task['id'] ?? ''}';
    if (lineId == null || taskId.isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 980,
          height: 720,
          child: ProductionPreparePage(
            lineId: lineId,
            taskId: taskId,
            task: task,
            teamId: _teamId,
            onClose: () => Navigator.of(dialogContext).pop(),
            onSaved: _loadDetails,
          ),
        ),
      ),
    );
    if (!mounted) return;
    await _loadDetails();
  }

  /// 计划审查（工具入口）：7 块 / findings / 追踪矩阵 / 批次 / diff。
  Future<void> _openPlanReview() async {
    final String? lineId = _lineId;
    if (lineId == null) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 900,
          height: 680,
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      '计划审查',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
              Expanded(
                child: ProductionPlanReview(
                  lineId: lineId,
                  teamId: _teamId,
                  onFinalize: () async {
                    await ApiService.orchestrateProductionLine(
                      lineId,
                      teamId: _teamId,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted) await _loadDetails();
  }

  void _openTaskDetail(String taskId) {
    final ValueChanged<String>? callback = widget.onOpenTask;
    if (callback == null) {
      _notify('任务详情在右栏「生产线任务」窗口里打开');
      return;
    }
    callback(taskId);
  }

  /// 执行入口：批量派发 dry run（只读）与真正运行本批。
  Future<void> _loadBulk() async {
    final String? lineId = _lineId;
    if (lineId == null || _actionBusy.contains('$lineId/bulk-preview')) return;
    await _act('$lineId/bulk-preview', () async {
      final Map<String, dynamic> result =
          await ApiService.bulkDispatchProductionTasks(
            lineId,
            dryRun: true,
            teamId: _teamId,
          );
      if (mounted) setState(() => _bulk = result);
    });
  }

  Future<void> _bulkDispatch({required bool dryRun}) async {
    final String? lineId = _lineId;
    if (lineId == null) return;
    if (!dryRun && _isBlocked) {
      _notify(_blockedReason);
      return;
    }
    final int? limit = int.tryParse(_bulkLimit.text.trim());
    await _act('$lineId/bulk-$dryRun', () async {
      final Map<String, dynamic> result =
          await ApiService.bulkDispatchProductionTasks(
            lineId,
            dryRun: dryRun,
            limit: limit != null && limit > 0 ? limit : null,
            teamId: _teamId,
          );
      if (mounted) setState(() => _bulk = result);
      await _loadDetails();
      final List<String> batch = (result['batch_ids'] as List<dynamic>? ??
              <dynamic>[])
          .map((dynamic item) => '$item')
          .toList();
      final int failed = (result['failed_count'] as num?)?.toInt() ?? 0;
      _notify(
        dryRun
            ? 'dry run：本批 ${batch.isEmpty ? '（空）' : batch.join('、')}'
            : '已派发 ${batch.length} 条${failed > 0 ? '，失败 $failed 条' : ''}',
      );
    });
  }

  Future<void> _loadDrift() async {
    final String? lineId = _lineId;
    if (lineId == null) return;
    await _act('$lineId/drift', () async {
      final Map<String, dynamic> result = await ApiService.getProductionDrift(
        lineId,
        teamId: _teamId,
      );
      if (mounted) setState(() => _drift = result);
    });
  }

  Future<void> _runDrift() async {
    final String? lineId = _lineId;
    if (lineId == null) return;
    await _act('$lineId/drift-run', () async {
      final Map<String, dynamic> result = await ApiService.runProductionDrift(
        lineId,
        teamId: _teamId,
      );
      if (mounted) setState(() => _drift = result);
      _notify(
        result['ok'] == true
            ? '漂移哨兵通过（批次 ${result['batch_id'] ?? ''}）'
            : '漂移哨兵未通过：已停止下一批',
      );
    });
  }

  /// 结构整理页的 cleanup 快捷入口（复用同一个建任务对话框）。
  Future<void> _createCleanupTask() => _createTask(taskType: 'cleanup');

  Future<void> _dispatch(String taskId, String stage) async {
    final String? lineId = _lineId;
    if (lineId == null) return;
    if (_isBlocked) {
      _notify(_blockedReason);
      return;
    }
    await _act('$lineId/$taskId/dispatch', () async {
      final Map<String, dynamic> result =
          await ApiService.dispatchProductionTask(
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
      await ApiService.cancelProductionTask(lineId, taskId, teamId: _teamId);
      await _loadDetails();
      _notify('已取消：$taskId');
    });
  }

  /// 恢复被主控 / 门控停下的任务（`blocked → queued`）。
  Future<void> _resumeTask(String taskId) async {
    final String? lineId = _lineId;
    if (lineId == null) return;
    await _act('$lineId/$taskId/resume', () async {
      await ApiService.transitionProductionTask(
        lineId,
        taskId,
        to: 'queued',
        reason: '用户恢复',
        teamId: _teamId,
      );
      await _loadDetails();
      _notify('已恢复：$taskId（回到队列）');
    });
  }

  /// 手动推进一次主控决策（D6-O §7.2「立即决策」）。
  Future<void> _orchestrate() async {
    final String? lineId = _lineId;
    if (lineId == null) return;
    await _act('$lineId/orchestrate', () async {
      final Map<String, dynamic> result =
          await ApiService.orchestrateProductionLine(lineId, teamId: _teamId);
      await _loadDetails();
      final String status = '${result['status'] ?? ''}';
      if (status == 'skipped') {
        _notify('主控跳过：${result['reason'] ?? ''}');
        return;
      }
      if (status == 'failed') {
        _notify('主控失败：${result['error'] ?? result['reason'] ?? ''}');
        return;
      }
      final String guard = '${result['guard'] ?? ''}';
      _notify(
        '主控 ${result['action'] ?? ''}：${result['reason'] ?? ''}'
        '${guard.isEmpty ? '' : '（护栏：$guard）'}',
      );
    });
  }

  Future<void> _setLinePaused(bool paused) async {
    final String? lineId = _lineId;
    if (lineId == null) return;
    await _act('$lineId/${paused ? 'pause' : 'resume'}', () async {
      final Map<String, dynamic> result = paused
          ? await ApiService.pauseProductionLine(lineId, teamId: _teamId)
          : await ApiService.resumeProductionLine(lineId, teamId: _teamId);
      final Map<String, dynamic> updated = productionMap(result['line']);
      if (updated.isNotEmpty) widget.onLineUpdated?.call(updated);
      await _loadDetails();
      _notify(paused ? '已暂停：不再自动派发' : '已恢复：立即决策一次');
    });
  }

  /// 回答运行期问题（收件箱 execute 区）：回答后任务回队列。
  Future<void> _answerRuntime(Map<String, dynamic> question) async {
    final String? lineId = _lineId;
    final String taskId = '${question['task_id'] ?? ''}';
    final String qid = '${question['qid'] ?? ''}';
    if (lineId == null || taskId.isEmpty) return;
    final List<String> options =
        (question['options'] as List<dynamic>? ?? <dynamic>[])
            .map((dynamic item) => '$item'.trim())
            .where((String item) => item.isNotEmpty)
            .toList();
    String draft = options.isNotEmpty
        ? options.first
        : '${question['default'] ?? ''}';
    final String? value = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('运行期问题 · $qid'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                '${question['text'] ?? ''}',
                style: const TextStyle(fontSize: 12.5),
              ),
              const SizedBox(height: 6),
              for (final String option in options)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(option),
                    child: Text(option),
                  ),
                ),
              TextFormField(
                key: Key('production-runtime-answer-$qid'),
                initialValue: draft,
                decoration: const InputDecoration(labelText: '回答'),
                onChanged: (String text) => draft = text,
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
            key: Key('production-runtime-submit-$qid'),
            onPressed: () => Navigator.of(context).pop(draft),
            child: const Text('提交回答'),
          ),
        ],
      ),
    );
    if (value == null || value.trim().isEmpty) return;
    await _act('$lineId/$taskId/answer', () async {
      await ApiService.answerProductionQuestion(
        lineId,
        taskId,
        qid: qid,
        value: value.trim(),
        teamId: _teamId,
      );
      await _loadDetails();
      _notify('已回答 $qid：任务回队列，等主控继续');
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

  /// 存量迁移：旧团队目录 → 全局作用域（幂等）。
  Future<void> _migrate() async {
    await _act('migrate', () async {
      final Map<String, dynamic> result = await ApiService.migrateProductionLines(
        agentId: _agentId,
        teamId: _teamId,
      );
      _notify(
        '${result['note'] ?? '已迁移 ${result['migrated_count'] ?? 0} 条旧产线'}',
      );
    });
  }

  Future<void> _editLine() async {
    final String? lineId = _lineId;
    final Map<String, dynamic>? line = widget.line;
    if (lineId == null || line == null) return;
    final ProductionLineSpec? spec = await showDialog<ProductionLineSpec>(
      context: context,
      builder: (BuildContext context) =>
          CreateProductionLineDialog(defaultAgentId: _agentId, initial: line),
    );
    if (spec == null) return;
    await _act('$lineId/edit', () async {
      final Map<String, dynamic> result = await ApiService.updateProductionLine(
        lineId,
        name: spec.name,
        workspaceDir: spec.workspace,
        executor: spec.executor,
        roles: spec.roles,
        orchestrator: spec.orchestrator,
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

  /// 打开结构整理页（dialog 整页；不打断工作台队列状态）。
  Future<void> _openStructure() async {
    final String? lineId = _lineId;
    if (lineId == null) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 900,
          height: 680,
          child: ProductionStructurePage(
            lineId: lineId,
            teamId: _teamId,
            onClose: () => Navigator.of(dialogContext).pop(),
            onCreateCleanupTask: _createCleanupTask,
          ),
        ),
      ),
    );
    if (!mounted) return;
    // 豁免 / cleanup / 重审后头栏的就绪状态可能变化。
    await _loadDetails();
  }

  /// 打开归一化预览页（plan 0 写盘；apply 需二次确认）。
  Future<void> _openNormalize() async {
    final String? lineId = _lineId;
    if (lineId == null) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 940,
          height: 680,
          child: ProductionNormalizePage(
            lineId: lineId,
            teamId: _teamId,
            onClose: () => Navigator.of(dialogContext).pop(),
          ),
        ),
      ),
    );
    if (!mounted) return;
    await _loadDetails();
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
                  '$id · $status'
                  '${_phaseLabel.isEmpty ? '' : ' · $_phaseLabel'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: '结构整理',
                key: Key('production-structure-open-$id'),
                visualDensity: VisualDensity.compact,
                onPressed: _openStructure,
                icon: const Icon(Icons.category_outlined, size: 18),
              ),
              IconButton(
                tooltip: '文档归一化',
                key: Key('production-normalize-open-$id'),
                visualDensity: VisualDensity.compact,
                onPressed: _openNormalize,
                icon: const Icon(Icons.auto_fix_high_outlined, size: 18),
              ),
              IconButton(
                tooltip: _isBlocked ? _blockedReason : '新建任务',
                key: Key('production-task-create-$id'),
                visualDensity: VisualDensity.compact,
                onPressed: _isBlocked || _actionBusy.contains('$id/create-task')
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
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
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
        _buildReadinessBar(cs, id),
        _buildOrchestratorBar(cs, id, status),
        Expanded(child: _buildBody(cs, id)),
      ],
    );
  }

  /// 就绪条（PC-5B）：ready 显示绿色 + 最近检查时间；未就绪逐条列出 missing/gates。
  Widget _buildReadinessBar(ColorScheme cs, String lineId) {
    final bool? ready = _readyFlag;
    if (ready == null) return const SizedBox.shrink();
    if (ready) {
      final String checkedAt = productionReadinessCheckedAt(_readiness);
      return Container(
        padding: const EdgeInsets.fromLTRB(12, 3, 12, 3),
        color: Colors.green.withValues(alpha: 0.10),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.check_circle_outline,
              size: 14,
              color: Colors.green.shade700,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '就绪${checkedAt.isEmpty ? '' : ' · 最近检查 $checkedAt'}',
                style: TextStyle(fontSize: 11, color: Colors.green.shade800),
              ),
            ),
          ],
        ),
      );
    }
    final List<String> missing = productionReadinessMissing(
      _readiness ?? <String, dynamic>{},
    );
    return Container(
      key: Key('production-readiness-$lineId'),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      color: cs.errorContainer.withValues(alpha: 0.30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.report_problem_outlined, size: 14, color: cs.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '未就绪 · ${_phaseLabel.isEmpty ? '阶段未知' : _phaseLabel}'
                  '${missing.isEmpty ? '' : ' · ${missing.length} 项待补齐'}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: cs.error,
                  ),
                ),
              ),
            ],
          ),
          for (final String item in missing)
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 1),
              child: Text(
                '· $item',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  /// 主控条（D6-O §7.2）：开关 / 最近动作 / 连续失败 / 暂停恢复 / 立即决策。
  Widget _buildOrchestratorBar(
    ColorScheme cs,
    String lineId,
    String lineStatus,
  ) {
    final Map<String, dynamic> data = _orchestrator ?? <String, dynamic>{};
    final Map<String, dynamic> config = productionMap(data['config']);
    final Map<String, dynamic> state = productionMap(data['state']);
    final bool enabled = config['enabled'] != false;
    final String action = '${state['last_action'] ?? ''}';
    final int failures = (state['consecutive_failures'] as num?)?.toInt() ?? 0;
    final int open = (data['open_question_count'] as num?)?.toInt() ?? 0;
    final bool paused = lineStatus == 'paused';
    final bool busy =
        _actionBusy.contains('$lineId/orchestrate') ||
        _actionBusy.contains('$lineId/pause') ||
        _actionBusy.contains('$lineId/resume');
    final String summary = <String>[
      action.isEmpty ? '还没有决策' : '最近：$action',
      if (failures > 0) '连续失败 $failures',
      if (open > 0) '待答 $open',
      if (paused) '已暂停',
    ].join(' · ');
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.smart_toy_outlined,
            size: 15,
            color: enabled ? cs.primary : cs.outline,
          ),
          const SizedBox(width: 6),
          Text(
            enabled ? '主控' : '主控（关）',
            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
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
          else ...<Widget>[
            TextButton(
              key: Key('production-orchestrate-$lineId'),
              onPressed: _orchestrate,
              child: const Text('立即决策'),
            ),
            TextButton(
              key: Key('production-${paused ? 'resume' : 'pause'}-$lineId'),
              onPressed: () => _setLinePaused(!paused),
              child: Text(paused ? '恢复' : '暂停'),
            ),
          ],
        ],
      ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildTabs(cs, lineId),
        Expanded(child: _buildTabContent(cs, lineId)),
      ],
    );
  }

  /// 四入口：今日 / 准备 / 执行 / 工具。
  Widget _buildTabs(ColorScheme cs, String lineId) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: SegmentedButton<int>(
        key: const Key('production-workbench-tabs'),
        showSelectedIcon: false,
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        segments: <ButtonSegment<int>>[
          ButtonSegment<int>(
            value: 0,
            icon: const Icon(Icons.today_outlined, size: 15),
            label: const Text('今日', key: Key('production-tab-today')),
          ),
          ButtonSegment<int>(
            value: 1,
            icon: const Icon(Icons.edit_note_outlined, size: 15),
            label: const Text('准备', key: Key('production-tab-prepare')),
          ),
          ButtonSegment<int>(
            value: 2,
            icon: const Icon(Icons.directions_run_outlined, size: 15),
            label: const Text('执行', key: Key('production-tab-execution')),
          ),
          ButtonSegment<int>(
            value: 3,
            icon: const Icon(Icons.handyman_outlined, size: 15),
            label: const Text('工具', key: Key('production-tab-tools')),
          ),
        ],
        selected: <int>{_tab},
        onSelectionChanged: (Set<int> selected) {
          final int next = selected.first;
          setState(() => _tab = next);
          if (next == 2) unawaited(_loadBulk());
          if (next == 3 && _drift == null) unawaited(_loadDrift());
        },
      ),
    );
  }

  Widget _buildTabContent(ColorScheme cs, String lineId) {
    switch (_tab) {
      case 1:
        return _buildPrepareTab(cs, lineId);
      case 2:
        return _buildExecutionTab(cs, lineId);
      case 3:
        return _buildToolsTab(cs, lineId);
      default:
        return _buildTodayTab(cs, lineId);
    }
  }

  /// 今日：只显示 待决定 / 需处理 / 正在跑 / 刚完成。
  Widget _buildTodayTab(ColorScheme cs, String lineId) {
    final List<Map<String, dynamic>> decisions = <Map<String, dynamic>>[
      for (final Map<String, dynamic> task in _tasks)
        if (productionTaskBucket(task) == 'decide') task,
    ];
    final List<Map<String, dynamic>> handle = <Map<String, dynamic>>[
      for (final Map<String, dynamic> task in _tasks)
        if (productionTaskBucket(task) == 'handle') task,
    ];
    final List<Map<String, dynamic>> running = <Map<String, dynamic>>[
      for (final Map<String, dynamic> task in _tasks)
        if (productionTaskBucket(task) == 'running') task,
    ];
    final List<Map<String, dynamic>> done = <Map<String, dynamic>>[
      for (final Map<String, dynamic> task in _tasks)
        if (productionTaskBucket(task) == 'done') task,
    ];
    final List<Map<String, dynamic>> runtimeQuestions = productionListOf(
      _orchestrator ?? <String, dynamic>{},
      'open_questions',
    );
    final Map<String, dynamic>? artifacts = _artifacts;
    final Map<String, dynamic>? audit = _audit;
    final Map<String, dynamic>? dedup = _dedup;
    return ListView(
      key: const Key('production-workbench'),
      padding: const EdgeInsets.only(bottom: 16),
      children: <Widget>[
        if (decisions.isNotEmpty) ...<Widget>[
          _sectionTitle(cs, '决策收件箱', '${decisions.length}'),
          _sectionHint(cs, '待决定 · 等你拍板后落档'),
          for (final Map<String, dynamic> task in decisions)
            _buildDecisionCard(cs, lineId, task),
        ],
        if (handle.isNotEmpty) ...<Widget>[
          _sectionTitle(cs, '任务队列', '${handle.length}'),
          _sectionHint(cs, '需处理 · 被挡住 / 依赖 / 漂移 / 门控 / 待派发'),
          for (final Map<String, dynamic> task in handle)
            _buildTaskRow(cs, lineId, task),
        ],
        if (running.isNotEmpty) ...<Widget>[
          _sectionTitle(cs, '正在跑', '${running.length}'),
          _sectionHint(cs, '打包 / 打包完成 / 执行 / 门控中'),
          for (final Map<String, dynamic> task in running)
            _buildTaskRow(cs, lineId, task),
        ],
        if (done.isNotEmpty) ...<Widget>[
          _sectionTitle(cs, '刚完成', '${done.length}'),
          _sectionHint(cs, '最近 24 小时内完成'),
          for (final Map<String, dynamic> task in done)
            _buildTaskRow(cs, lineId, task),
        ],
        if (decisions.isEmpty &&
            handle.isEmpty &&
            running.isEmpty &&
            done.isEmpty)
          _muted(cs, '今天没有要处理的任务：去「准备」建需求，或去「执行」派发队列。'),
        if (runtimeQuestions.isNotEmpty) ...<Widget>[
          _sectionTitle(cs, '运行期问题', '${runtimeQuestions.length}'),
          for (final Map<String, dynamic> question in runtimeQuestions)
            _buildRuntimeQuestionCard(cs, question),
        ],
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
              SizedBox(
                width: 84,
                child: TextField(
                  key: Key('production-dedup-batch-$lineId'),
                  controller: _dedupBatch,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '去重批',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              TextButton(
                onPressed: _loadDedup,
                child: Text(dedup == null ? '逻辑去重' : '收起去重'),
              ),
            ],
          ),
        ),
        if (artifacts != null) ..._buildArtifacts(cs, artifacts),
        if (audit != null) ..._buildAudit(cs, lineId, audit),
        if (dedup != null) ..._buildDedup(cs, lineId, dedup),
      ],
    );
  }

  /// 准备：draft / recon / aligning / awaiting_user → 准备四步。
  Widget _buildPrepareTab(ColorScheme cs, String lineId) {
    final List<Map<String, dynamic>> tasks = <Map<String, dynamic>>[
      for (final Map<String, dynamic> task in _tasks)
        if (productionTaskBucket(task) == 'prepare' ||
            productionTaskBucket(task) == 'decide')
          task,
    ];
    return ListView(
      key: const Key('production-prepare-tab'),
      padding: const EdgeInsets.only(bottom: 16),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '准备四步：建需求 → 侦查 → 拍板 → 计划审查 / 落档。'
                  '未答问题 > 0 时不能落档。',
                  style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
                ),
              ),
              TextButton.icon(
                key: const Key('production-prepare-new'),
                onPressed: _isBlocked ? null : _createDraftTask,
                icon: const Icon(Icons.note_add_outlined, size: 16),
                label: const Text('新建需求草案'),
              ),
            ],
          ),
        ),
        _sectionTitle(cs, '准备中的任务', '${tasks.length}'),
        if (tasks.isEmpty)
          _muted(cs, '没有准备中的任务：点「新建需求草案」建一条，或等主控把任务推进到准备态。')
        else
          for (final Map<String, dynamic> task in tasks)
            _buildPrepareCard(cs, lineId, task),
      ],
    );
  }

  Widget _buildPrepareCard(
    ColorScheme cs,
    String lineId,
    Map<String, dynamic> task,
  ) {
    final String id = '${task['id'] ?? ''}';
    final String status = '${task['status'] ?? ''}';
    final int open = (productionMap(task['questions'])['open'] as num?)
            ?.toInt() ??
        (productionMap(task['recon'])['open'] as num?)?.toInt() ??
        0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 3, 12, 3),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              '$id  ${task['title'] ?? ''}',
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
            Text(
              '${productionStatusLabel(status)} · $status'
              '${open > 0 ? ' · 未答 $open' : ''}',
              style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant),
            ),
            Text(
              productionTaskHumanLine(task),
              style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                FilledButton.tonal(
                  key: Key('production-prepare-open-$id'),
                  onPressed: () => _openPrepare(task),
                  child: const Text('进入准备四步'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  key: Key('production-prepare-decide-$id'),
                  onPressed: status == 'aligning' || status == 'awaiting_user'
                      ? () => _decide(id)
                      : null,
                  child: const Text('拍板'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 执行：批次 / 并行槽位 / 写域冲突 skipped / 批量派发。
  Widget _buildExecutionTab(ColorScheme cs, String lineId) {
    final List<Map<String, dynamic>> tasks = <Map<String, dynamic>>[
      for (final Map<String, dynamic> task in _tasks)
        if (const <String>{
          'queued',
          'scoped',
          'packing',
          'packed',
          'running',
          'gating',
        }.contains('${task['status'] ?? ''}'))
          task,
    ];
    final Map<String, dynamic> bulk = _bulk ?? <String, dynamic>{};
    final List<String> batch = (bulk['batch_ids'] as List<dynamic>? ??
            <dynamic>[])
        .map((dynamic item) => '$item')
        .toList();
    final List<Map<String, dynamic>> skipped = productionListOf(bulk, 'skipped');
    final int used = (bulk['slots_used'] as num?)?.toInt() ?? 0;
    final int free = (bulk['slots_free'] as num?)?.toInt() ?? 0;
    final int max = (bulk['max_parallel_tasks'] as num?)?.toInt() ?? 1;
    final List<String> runningIds = (bulk['running'] as List<dynamic>? ??
            <dynamic>[])
        .map((dynamic item) => '$item')
        .toList();
    final bool busy =
        _actionBusy.contains('$lineId/bulk-true') ||
        _actionBusy.contains('$lineId/bulk-false');
    return ListView(
      key: const Key('production-execution-tab'),
      padding: const EdgeInsets.only(bottom: 16),
      children: <Widget>[
        _sectionTitle(cs, '批次与槽位', '${batch.length}'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 1, 16, 2),
          child: Text(
            bulk.isEmpty
                ? '点「dry run」预览本批：依赖 / 写域 / 并行槽位都按后端口径算。'
                : '本批：${batch.isEmpty ? '（空）' : batch.join('、')}'
                      '${runningIds.isEmpty ? '' : ' · 在跑 ${runningIds.join('、')}'}\n'
                      '并行槽位 $used / $max（剩余 $free）',
            style: const TextStyle(fontSize: 11),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Wrap(
            spacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              SizedBox(
                width: 90,
                child: TextField(
                  key: Key('production-bulk-limit-$lineId'),
                  controller: _bulkLimit,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '本批上限',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              OutlinedButton(
                key: Key('production-bulk-dry-$lineId'),
                onPressed: busy ? null : () => _bulkDispatch(dryRun: true),
                child: const Text('批量派发（dry run）'),
              ),
              FilledButton(
                key: Key('production-bulk-run-$lineId'),
                onPressed: busy || _isBlocked
                    ? null
                    : () => _bulkDispatch(dryRun: false),
                child: const Text('运行本批'),
              ),
            ],
          ),
        ),
        if (skipped.isNotEmpty) ...<Widget>[
          _sectionTitle(cs, 'skipped', '${skipped.length}'),
          for (final Map<String, dynamic> item in skipped)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 1, 16, 1),
              child: Text(
                '· ${item['id'] ?? ''}：${_skipReason(item)}',
                style: TextStyle(fontSize: 10.5, color: cs.error),
              ),
            ),
        ],
        _sectionTitle(cs, '执行队列', '${tasks.length}'),
        if (tasks.isEmpty)
          _muted(cs, '执行队列为空：先在「准备」落档，或等主控派发。')
        else
          for (final Map<String, dynamic> task in tasks)
            _buildTaskRow(cs, lineId, task),
      ],
    );
  }

  String _skipReason(Map<String, dynamic> item) {
    final String reason = '${item['reason'] ?? ''}';
    switch (reason) {
      case 'depends_on':
        final List<String> waiting = (item['waiting_on'] as List<dynamic>? ??
                <dynamic>[])
            .map((dynamic value) => '$value')
            .toList();
        return '依赖未完成${waiting.isEmpty ? '' : '（等 ${waiting.join('、')}）'}';
      case 'write_scope_overlap':
        return '写域与 ${item['with_task'] ?? '在跑任务'} 交叠，等它跑完再派';
      case 'max_parallel':
        return '并行槽位已满（上限 ${item['max_parallel'] ?? ''}）';
      case 'structure_not_ready':
        return '项目结构未通过（先整理结构）';
      case 'line_not_ready':
        return '产线未就绪（归一化 / 索引先完成）';
      case 'limit':
        return '超出本批上限 ${item['limit'] ?? ''}';
      case 'task_input_incomplete':
        return '任务输入不完整（缺内容 / 验收 / 依赖）';
      default:
        return '被跳过（${reason.isEmpty ? '原因未知' : reason}）';
    }
  }

  /// 工具：结构 / 归一化 / 去重 / 审计 / 产物 / 漂移 / 配置 / 迁移。
  Widget _buildToolsTab(ColorScheme cs, String lineId) {
    final Map<String, dynamic>? artifacts = _artifacts;
    final Map<String, dynamic>? audit = _audit;
    final Map<String, dynamic>? dedup = _dedup;
    final Map<String, dynamic>? drift = _drift;
    return ListView(
      key: const Key('production-tools-tab'),
      padding: const EdgeInsets.only(bottom: 16),
      children: <Widget>[
        _sectionTitle(cs, '产线工具', '${8}'),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: <Widget>[
              OutlinedButton.icon(
                key: Key('production-tools-structure-$lineId'),
                onPressed: _openStructure,
                icon: const Icon(Icons.category_outlined, size: 16),
                label: const Text('结构整理'),
              ),
              OutlinedButton.icon(
                key: Key('production-tools-normalize-$lineId'),
                onPressed: _openNormalize,
                icon: const Icon(Icons.auto_fix_high_outlined, size: 16),
                label: const Text('文档归一化'),
              ),
              OutlinedButton.icon(
                key: Key('production-tools-plan-$lineId'),
                onPressed: _openPlanReview,
                icon: const Icon(Icons.description_outlined, size: 16),
                label: const Text('计划审查'),
              ),
              OutlinedButton.icon(
                key: Key('production-tools-audit-$lineId'),
                onPressed: _actionBusy.contains('$lineId/audit')
                    ? null
                    : () => _loadAudit(force: true),
                icon: const Icon(Icons.fact_check_outlined, size: 16),
                label: const Text('文档审计'),
              ),
              OutlinedButton.icon(
                key: Key('production-tools-dedup-$lineId'),
                onPressed: _loadDedup,
                icon: const Icon(Icons.content_copy_outlined, size: 16),
                label: const Text('逻辑去重'),
              ),
              OutlinedButton.icon(
                key: Key('production-tools-artifacts-$lineId'),
                onPressed: _loadArtifacts,
                icon: const Icon(Icons.inventory_2_outlined, size: 16),
                label: Text(artifacts == null ? '产物' : '收起产物'),
              ),
              OutlinedButton.icon(
                key: Key('production-tools-drift-$lineId'),
                onPressed: _loadDrift,
                icon: const Icon(Icons.radar_outlined, size: 16),
                label: const Text('漂移报告'),
              ),
              OutlinedButton.icon(
                key: Key('production-tools-config-$lineId'),
                onPressed: _editLine,
                icon: const Icon(Icons.tune, size: 16),
                label: const Text('产线配置'),
              ),
              OutlinedButton.icon(
                key: Key('production-tools-migrate-$lineId'),
                onPressed: _migrate,
                icon: const Icon(Icons.move_up_outlined, size: 16),
                label: const Text('存量迁移'),
              ),
            ],
          ),
        ),
        if (drift != null) ..._buildDrift(cs, lineId, drift),
        if (artifacts != null) ..._buildArtifacts(cs, artifacts),
        if (audit != null) ..._buildAudit(cs, lineId, audit),
        if (dedup != null) ..._buildDedup(cs, lineId, dedup),
      ],
    );
  }

  List<Widget> _buildDrift(
    ColorScheme cs,
    String lineId,
    Map<String, dynamic> data,
  ) {
    final List<Map<String, dynamic>> results = productionListOf(
      data,
      'results',
    );
    final List<String> blocked = (data['blocked'] as List<dynamic>? ??
            <dynamic>[])
        .map((dynamic item) => '$item')
        .toList();
    final bool ok = data['ok'] == true;
    return <Widget>[
      _sectionTitle(cs, '漂移报告', '${results.length}'),
      Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: TextButton(
            key: const Key('production-drift-run'),
            onPressed: _actionBusy.contains('$lineId/drift-run')
                ? null
                : _runDrift,
            child: const Text('重新检查'),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 1, 16, 2),
        child: Text(
          '批次 ${data['batch_id'] ?? ''} · ${ok ? '通过' : '未通过'}'
          '${blocked.isEmpty ? '' : ' · 已挡住 ${blocked.join('、')}'}',
          style: TextStyle(fontSize: 11, color: ok ? cs.primary : cs.error),
        ),
      ),
      for (final Map<String, dynamic> result in results)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 1, 16, 1),
          child: Text(
            '${result['id'] ?? ''} · ${result['message'] ?? result['code'] ?? ''}'
            '${'${result['evidence'] ?? ''}'.isEmpty ? '' : ' · 证据 ${result['evidence']}'}',
            style: TextStyle(
              fontSize: 10.5,
              color: result['ok'] == false ? cs.error : cs.onSurface,
            ),
          ),
        ),
    ];
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
    final Map<String, dynamic> loop = productionMap(task['loop']);
    final int attempts = (loop['attempts'] as num?)?.toInt() ?? 0;
    final int askCount = (loop['ask_count'] as num?)?.toInt() ?? 0;
    final String pending = '${loop['pending_question'] ?? ''}';
    final String stopReason = '${loop['stop_reason'] ?? ''}';
    final String loopText = <String>[
      if (attempts > 0) '重试 $attempts',
      if (askCount > 0) '提问 $askCount',
      if (pending.isNotEmpty) '待答 $pending',
      if (stopReason.isNotEmpty) '停止：$stopReason',
    ].join(' · ');
    final bool busy =
        _actionBusy.contains('$lineId/$id/dispatch') ||
        _actionBusy.contains('$lineId/$id/decide') ||
        _actionBusy.contains('$lineId/$id/cancel') ||
        _actionBusy.contains('$lineId/$id/resume') ||
        _actionBusy.contains('$lineId/$id/save');
    final bool blocked = _isBlocked;
    return InkWell(
      key: Key('production-task-open-$id'),
      onTap: () => _openTaskDetail(id),
      child: Padding(
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
                  Text(
                    productionTaskHumanLine(task),
                    style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant),
                  ),
                  if (scope.isNotEmpty)
                    Text(
                      '写域：$scope',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10.5, color: cs.outline),
                    ),
                  if (loopText.isNotEmpty)
                    Text(
                      loopText,
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
            else
              PopupMenuButton<String>(
                key: Key('production-task-menu-$id'),
                tooltip: blocked ? _blockedReason : '任务操作',
                padding: EdgeInsets.zero,
                iconSize: 16,
                onSelected: (String value) {
                  switch (value) {
                    case 'open':
                      _openTaskDetail(id);
                    case 'edit':
                      _editTask(task);
                    case 'pack':
                      _dispatch(id, 'pack');
                    case 'run':
                      _dispatch(id, 'run');
                    case 'decide':
                      _decide(id);
                    case 'resume':
                      _resumeTask(id);
                    case 'cancel':
                      _cancelTask(id);
                  }
                },
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                  const PopupMenuItem<String>(
                    value: 'open',
                    child: Text('打开详情'),
                  ),
                  const PopupMenuItem<String>(
                    value: 'edit',
                    child: Text('编辑任务'),
                  ),
                  const PopupMenuDivider(),
                  for (final String value in productionTaskActions(task))
                    PopupMenuItem<String>(
                      value: value,
                      // 未就绪时只禁「打包 / 执行」；拍板 / 恢复 / 取消仍可用。
                      enabled: !(blocked && (value == 'pack' || value == 'run')),
                      child: Text(productionActionLabel(value)),
                    ),
                ],
              ),
          ],
        ),
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
                    style: TextStyle(
                      fontSize: 10.5,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    productionTaskHumanLine(task),
                    style: TextStyle(
                      fontSize: 10,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              key: Key('production-inbox-prepare-$id'),
              onPressed: () => _openPrepare(task),
              child: const Text('进入准备'),
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

  /// 运行期问题卡（收件箱 execute 区）：直接回答，任务回队列后由主控继续。
  Widget _buildRuntimeQuestionCard(
    ColorScheme cs,
    Map<String, dynamic> question,
  ) {
    final String taskId = '${question['task_id'] ?? ''}';
    final String qid = '${question['qid'] ?? ''}';
    final bool busy = _actionBusy.contains('${_lineId ?? ''}/$taskId/answer');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 3, 16, 3),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
        decoration: BoxDecoration(
          color: cs.tertiaryContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: cs.tertiary.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '$taskId · $qid',
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${question['text'] ?? ''}',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (busy)
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              FilledButton.tonal(
                key: Key('production-inbox-answer-$qid'),
                onPressed: () => _answerRuntime(question),
                child: const Text('回答'),
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
    final List<dynamic> todos =
        report['todos'] as List<dynamic>? ?? <dynamic>[];
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
    final bool cached = data['cached'] == true;
    final bool stale = data['stale'] == true;
    final int changed = (data['changed'] as num?)?.toInt() ?? 0;
    final String cacheAt = '${data['cache_generated_at'] ?? ''}';
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
      if (cached || done)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  cached
                      ? (stale
                            ? '缓存于 $cacheAt · 检测到 $changed 个文件有变化'
                            : '缓存于 $cacheAt（无变化）')
                      : '本次为最新扫描结果',
                  style: TextStyle(
                    fontSize: 11,
                    color: stale ? cs.error : cs.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton(
                key: Key('production-audit-refresh-$lineId'),
                onPressed: busy
                    ? null
                    : () => _loadAudit(force: true, refresh: true),
                child: Text(busy ? '扫描中…' : '重新扫描'),
              ),
            ],
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

  /// 逻辑去重结果（GET 只读；运行 / 重建是显式动作）。
  List<Widget> _buildDedup(
    ColorScheme cs,
    String lineId,
    Map<String, dynamic> data,
  ) {
    final Map<String, dynamic> run = productionMap(data['run']);
    final Map<String, dynamic> counts = productionMap(run['counts']);
    final List<Map<String, dynamic>> pairs = productionListOf(
      data,
      'top_pairs',
    );
    final List<dynamic> reasons =
        run['reasons'] as List<dynamic>? ?? <dynamic>[];
    final bool busyRun = _actionBusy.contains('$lineId/dedup-run');
    final int files = (counts['files'] as num?)?.toInt() ?? 0;
    final int chunks = (counts['chunks'] as num?)?.toInt() ?? 0;
    final int vectors = (counts['vectors'] as num?)?.toInt() ?? 0;
    final int results = (counts['results'] as num?)?.toInt() ?? 0;
    final String mode = '${run['mode'] ?? ''}';
    final bool degraded = run['degraded'] == true;
    return <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 2),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                mode.isEmpty
                    ? '逻辑去重：尚未运行'
                    : '逻辑去重：$mode · 文件 $files · 块 $chunks · 向量 $vectors · 结果 $results',
                style: const TextStyle(fontSize: 11),
              ),
            ),
            TextButton(
              key: Key('production-dedup-run-$lineId'),
              onPressed: busyRun ? null : () => _runDedup(),
              child: Text(busyRun ? '运行中…' : '运行下一批'),
            ),
            TextButton(
              key: Key('production-dedup-rebuild-$lineId'),
              onPressed: busyRun ? null : () => _runDedup(mode: 'rebuild'),
              child: const Text('全量重建'),
            ),
          ],
        ),
      ),
      if (degraded)
        for (final dynamic reason in reasons) _muted(cs, '降级：$reason'),
      for (final Map<String, dynamic> pair in pairs.take(10))
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 1, 16, 1),
          child: Text(
            '${_pairLabel(pair['a'])}  ↔  ${_pairLabel(pair['b'])}'
            '  ·  ${((pair['score'] as num?)?.toDouble() ?? 0).toStringAsFixed(4)}'
            '${pair['exact'] == true ? ' · 字节相同' : ''}',
            style: const TextStyle(fontSize: 11),
          ),
        ),
    ];
  }

  String _pairLabel(Object? raw) {
    final Map<String, dynamic> item = productionMap(raw);
    final String path = '${item['path'] ?? ''}';
    final String scope = '${item['scope'] ?? ''}';
    return scope.isEmpty ? path : '$path:$scope';
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

  Widget _sectionHint(ColorScheme cs, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
    child: Text(
      text,
      style: TextStyle(fontSize: 10.5, color: cs.outline),
    ),
  );

  Widget _muted(ColorScheme cs, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 1, 16, 3),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
    ),
  );

  static String _runLabel(Map<String, dynamic> run) {
    final String taskId = '${run['task_id'] ?? ''}';
    final String action = '${run['action'] ?? ''}';
    final String guard = '${run['guard'] ?? ''}';
    final String reason = '${run['reason'] ?? run['error'] ?? ''}';
    return '${run['role'] ?? ''} · ${run['status'] ?? ''}'
        '${action.isEmpty ? '' : ' · $action'}'
        '${guard.isEmpty ? '' : ' · 护栏 $guard'}'
        '${taskId.isEmpty ? '' : ' · $taskId'}'
        '${reason.isEmpty ? '' : ' · $reason'}';
  }
}

/// 新建 / 编辑任务的表单结果。
class _NewTaskSpec {
  const _NewTaskSpec({
    required this.title,
    this.brief = '',
    this.acceptance = const <String>[],
    this.references = const <String>[],
    this.scope = const <String>[],
    this.readScope = const <String>[],
    this.dependsOn = const <String>[],
    this.taskType = 'code',
    this.risk = '',
    this.priority = 50,
    this.estimatedFiles = 1,
    this.attachments = const <Map<String, dynamic>>[],
    this.isEdit = false,
  });

  final String title;
  final String brief;
  final List<String> acceptance;
  final List<String> references;
  final List<String> scope;
  final List<String> readScope;
  final List<String> dependsOn;
  final String taskType;
  final String risk;
  final int priority;
  final int estimatedFiles;

  /// 已上传到工作空间的附件：`{source, name, size, type, vision}`。
  final List<Map<String, dynamic>> attachments;
  final bool isEdit;

  /// 新建（POST `{task}`）：title / 输入字段 / 状态由调用方补。
  Map<String, dynamic> toTaskJson() => <String, dynamic>{
    'title': title,
    'brief': brief.trim().isEmpty ? title : brief.trim(),
    'acceptance': acceptance,
    'references': references,
    'write_scope': scope,
    'read_scope': readScope,
    'depends_on': dependsOn,
    'task_type': taskType,
    'risk': risk,
    'priority': priority,
    'estimated_files': estimatedFiles,
  };

  /// 编辑（PATCH）：只发后端白名单里的字段（title / task_type 不可改）。
  Map<String, dynamic> toPatchJson() => <String, dynamic>{
    'brief': brief.trim().isEmpty ? title : brief.trim(),
    'acceptance': acceptance,
    'references': references,
    'write_scope': scope,
    'read_scope': readScope,
    'depends_on': dependsOn,
    'risk': risk,
    'priority': priority,
    'estimated_files': estimatedFiles,
  };
}

/// 新建任务：写域支持「选目录 / 选文件」，选中后自动转成工作空间相对路径。
class _NewTaskDialog extends StatefulWidget {
  const _NewTaskDialog({
    required this.lineId,
    required this.workspace,
    this.workspaceId = '',
    this.teamId = '',
    this.taskType = '',
    this.initial,
  });

  final String lineId;
  final String workspace;

  /// 附件上传用（产线 = `line:<id>`）。
  final String workspaceId;
  final String teamId;

  /// 结构整理阶段的 `cleanup` 任务走同一张表单（`task_type=cleanup`）。
  final String taskType;

  /// 非空 = 编辑模式（PATCH；packed 保存后回 queued 并失效旧包）。
  final Map<String, dynamic>? initial;

  @override
  State<_NewTaskDialog> createState() => _NewTaskDialogState();
}

class _NewTaskDialogState extends State<_NewTaskDialog> {
  late final TextEditingController _title;
  late final TextEditingController _brief;
  late final TextEditingController _acceptance;
  late final TextEditingController _references;
  late final TextEditingController _scope;
  late final TextEditingController _readScope;
  late final TextEditingController _depends;
  late final TextEditingController _priority;
  late final TextEditingController _estimated;
  late String _taskType;
  late String _risk;
  bool _vision = false;
  bool _uploading = false;
  final List<Map<String, dynamic>> _uploaded = <Map<String, dynamic>>[];

  bool get _isEdit => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final Map<String, dynamic> initial = widget.initial ?? <String, dynamic>{};
    _title = TextEditingController(text: '${initial['title'] ?? ''}');
    _brief = TextEditingController(text: '${initial['brief'] ?? ''}');
    _acceptance = TextEditingController(text: _joinText(initial['acceptance']));
    _references = TextEditingController(text: _joinText(initial['references']));
    _scope = TextEditingController(text: _joinText(initial['write_scope']));
    _readScope = TextEditingController(text: _joinText(initial['read_scope']));
    _depends = TextEditingController(text: _joinText(initial['depends_on']));
    _priority = TextEditingController(
      text: '${initial['priority'] ?? 50}'.trim(),
    );
    _estimated = TextEditingController(
      text: '${initial['estimated_files'] ?? 1}'.trim(),
    );
    _taskType = '${initial['task_type'] ?? widget.taskType}'.trim();
    if (_taskType.isEmpty) _taskType = 'code';
    _risk = '${initial['risk'] ?? ''}'.trim();
  }

  static String _joinText(Object? raw) {
    if (raw is List) {
      return raw
          .map((Object? item) => '$item'.trim())
          .where((String item) => item.isNotEmpty)
          .join(', ');
    }
    return '${raw ?? ''}'.trim();
  }

  @override
  void dispose() {
    _title.dispose();
    _brief.dispose();
    _acceptance.dispose();
    _references.dispose();
    _scope.dispose();
    _readScope.dispose();
    _depends.dispose();
    _priority.dispose();
    _estimated.dispose();
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
    final List<String> current = _split(_scope.text);
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

  Future<void> _pickAttachments() async {
    if (_uploading) return;
    if (widget.workspaceId.isEmpty) {
      _toast('没有工作空间，无法上传附件');
      return;
    }
    final List<String> picked = await pickProductionFiles('选择附件');
    if (picked.isEmpty) return;
    setState(() => _uploading = true);
    try {
      final List<Map<String, dynamic>> uploaded =
          await AttachmentUploadService.uploadAll(
            widget.workspaceId,
            picked,
            teamId: widget.teamId,
          );
      if (!mounted) return;
      setState(() {
        for (final Map<String, dynamic> item in uploaded) {
          _uploaded.add(<String, dynamic>{
            'source': item['path'],
            'name': item['name'],
            'size': item['size'],
            'type': item['type'],
            'vision': _vision,
          });
        }
      });
    } catch (error) {
      if (!mounted) return;
      _toast(productionReadable(error, '附件上传失败'));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  static List<String> _split(String text) => <String>[
    for (final String item in text.split(RegExp(r'[,\n，]')))
      if (item.trim().isNotEmpty) item.trim(),
  ];

  void _toast(String text) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));
  }

  void _submit() {
    final String title = _title.text.trim();
    if (title.isEmpty) {
      _toast('标题不能为空');
      return;
    }
    Navigator.of(context).pop(
      _NewTaskSpec(
        title: title,
        brief: _brief.text.trim(),
        acceptance: _split(_acceptance.text),
        references: _split(_references.text),
        scope: _split(_scope.text),
        readScope: _split(_readScope.text),
        dependsOn: _split(_depends.text),
        taskType: _taskType,
        risk: _risk,
        priority: int.tryParse(_priority.text.trim()) ?? 50,
        estimatedFiles: int.tryParse(_estimated.text.trim()) ?? 1,
        attachments: _uploaded,
        isEdit: _isEdit,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Map<String, dynamic> initial = widget.initial ?? <String, dynamic>{};
    final List<Map<String, dynamic>> existing = productionListOf(
      initial,
      'attachments',
    );
    final bool packed = '${initial['status'] ?? ''}' == 'packed';
    return AlertDialog(
      title: Text(
        _isEdit
            ? '编辑任务 · ${initial['id'] ?? widget.lineId}'
            : '新建${widget.taskType == 'cleanup' ? ' cleanup ' : ''}任务'
                  ' · ${widget.lineId}',
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (packed)
                Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: cs.errorContainer.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '这条任务已经打包：保存后会回到 queued，旧 pack.json 失效，需要重新打包。',
                    style: TextStyle(fontSize: 11, color: cs.error),
                  ),
                ),
              if (_isEdit)
                Text(
                  '标题：${initial['title'] ?? ''}（标题 / 类型不可编辑）',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                )
              else
                TextField(
                  key: const Key('production-task-title'),
                  controller: _title,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: '标题'),
                ),
              const SizedBox(height: 4),
              TextField(
                key: const Key('production-task-brief'),
                controller: _brief,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '任务内容 brief（多行）',
                  helperText: '落档 / 派发前必填；留空会用标题',
                ),
              ),
              TextField(
                key: const Key('production-task-acceptance'),
                controller: _acceptance,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '验收 acceptance（每行一条 / 逗号分隔）',
                ),
              ),
              TextField(
                key: const Key('production-task-references'),
                controller: _references,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: '引用 references（工作空间相对路径）',
                ),
              ),
              Row(
                children: <Widget>[
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: const Key('production-task-type'),
                      initialValue: _taskType,
                      decoration: const InputDecoration(labelText: '类型'),
                      items: const <DropdownMenuItem<String>>[
                        DropdownMenuItem<String>(value: 'code', child: Text('code')),
                        DropdownMenuItem<String>(value: 'test', child: Text('test')),
                        DropdownMenuItem<String>(value: 'docs', child: Text('docs')),
                        DropdownMenuItem<String>(value: 'spike', child: Text('spike')),
                        DropdownMenuItem<String>(
                          value: 'integration',
                          child: Text('integration'),
                        ),
                        DropdownMenuItem<String>(value: 'chore', child: Text('chore')),
                        DropdownMenuItem<String>(
                          value: 'cleanup',
                          child: Text('cleanup'),
                        ),
                      ],
                      onChanged: _isEdit
                          ? null
                          : (String? value) {
                              if (value == null) return;
                              setState(() => _taskType = value);
                            },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: const Key('production-task-risk'),
                      initialValue: _risk,
                      decoration: const InputDecoration(labelText: '风险'),
                      items: const <DropdownMenuItem<String>>[
                        DropdownMenuItem<String>(value: '', child: Text('未标注')),
                        DropdownMenuItem<String>(value: 'low', child: Text('low')),
                        DropdownMenuItem<String>(
                          value: 'medium',
                          child: Text('medium'),
                        ),
                        DropdownMenuItem<String>(value: 'high', child: Text('high')),
                      ],
                      onChanged: (String? value) =>
                          setState(() => _risk = value ?? ''),
                    ),
                  ),
                ],
              ),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      key: const Key('production-task-priority'),
                      controller: _priority,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '优先级'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      key: const Key('production-task-estimated'),
                      controller: _estimated,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '预估文件数'),
                    ),
                  ),
                ],
              ),
              TextField(
                key: const Key('production-task-depends'),
                controller: _depends,
                decoration: const InputDecoration(
                  labelText: '依赖任务 depends_on（逗号分隔）',
                ),
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
              TextField(
                key: const Key('production-task-read-scope'),
                controller: _readScope,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: '读域 read_scope（逗号分隔，可空）',
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: <Widget>[
                  TextButton.icon(
                    key: const Key('production-task-attach'),
                    onPressed: _uploading ? null : _pickAttachments,
                    icon: const Icon(Icons.attach_file, size: 16),
                    label: Text(_uploading ? '上传中…' : '添加附件'),
                  ),
                  const SizedBox(width: 6),
                  Checkbox(
                    key: const Key('production-task-vision'),
                    value: _vision,
                    onChanged: (bool? value) =>
                        setState(() => _vision = value == true),
                  ),
                  const Flexible(
                    child: Text('图片交视觉模型总结', style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
              if (existing.isNotEmpty) ...<Widget>[
                Text(
                  '已有附件（${existing.length}）',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                ),
                for (final Map<String, dynamic> attachment in existing)
                  Text(
                    '· ${attachment['name'] ?? attachment['path'] ?? ''}'
                    '${productionAttachmentMeta(attachment)}',
                    style: TextStyle(
                      fontSize: 10,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
              ],
              if (_uploaded.isNotEmpty) ...<Widget>[
                Text(
                  '待登记附件（${_uploaded.length}）',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                ),
                for (final Map<String, dynamic> attachment in _uploaded)
                  Text(
                    '· ${attachment['name']} · ${productionSizeText((attachment['size'] as num?)?.toInt() ?? 0)}'
                    '${'${attachment['type'] ?? ''}'.isEmpty ? '' : ' · ${attachment['type']}'}'
                    '${attachment['vision'] == true ? ' · 视觉模型' : ' · 人工参考'}\n'
                    '    待登记（sha256 由后端落盘后计算）',
                    style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
                  ),
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
        FilledButton(
          key: Key(_isEdit ? 'production-task-save' : 'production-task-create'),
          onPressed: _uploading ? null : _submit,
          child: Text(_isEdit ? '保存' : '创建'),
        ),
      ],
    );
  }
}

/// 需求草案（intake 五栏）的表单结果。
class _IntakeSpec {
  const _IntakeSpec(this.title, this.intake);

  final String title;
  final Map<String, dynamic> intake;
}

/// 新建需求草案：五栏 → `draft` 任务，随后进入准备四步。
class _IntakeDialog extends StatefulWidget {
  const _IntakeDialog();

  @override
  State<_IntakeDialog> createState() => _IntakeDialogState();
}

class _IntakeDialogState extends State<_IntakeDialog> {
  final TextEditingController _title = TextEditingController();
  final Map<String, TextEditingController> _fields = <String, TextEditingController>{
    'goal': TextEditingController(),
    'current': TextEditingController(),
    'acceptance': TextEditingController(),
    'constraints': TextEditingController(),
    'out_of_scope': TextEditingController(),
  };

  static const Map<String, String> _labels = <String, String>{
    'goal': '目标（必填）',
    'current': '现状',
    'acceptance': '验收',
    'constraints': '约束',
    'out_of_scope': '不做 / 范围外',
  };

  @override
  void dispose() {
    _title.dispose();
    for (final TextEditingController controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final String title = _title.text.trim();
    final String goal = _fields['goal']!.text.trim();
    if (title.isEmpty || goal.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('标题与目标不能为空')),
      );
      return;
    }
    Navigator.of(context).pop(
      _IntakeSpec(title, <String, dynamic>{
        for (final MapEntry<String, TextEditingController> entry
            in _fields.entries)
          entry.key: entry.value.text.trim(),
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建需求草案'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                key: const Key('production-intake-title'),
                controller: _title,
                autofocus: true,
                decoration: const InputDecoration(labelText: '任务标题'),
              ),
              for (final MapEntry<String, String> label in _labels.entries)
                TextField(
                  key: Key('production-intake-${label.key}'),
                  controller: _fields[label.key],
                  maxLines: label.key == 'goal' ? 2 : 1,
                  decoration: InputDecoration(labelText: label.value),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('production-intake-create'),
          onPressed: _submit,
          child: const Text('建草案并准备'),
        ),
      ],
    );
  }
}
