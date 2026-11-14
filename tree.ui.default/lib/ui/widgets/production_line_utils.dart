import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// 产线左栏列表与中栏工作台共用的纯函数 / 文件选择器。
///
/// 两边看同一份 REST 数据，错误文案、状态配色与状态机可用操作必须**同一口径**，
/// 否则同一条任务在两处会给出不同的按钮。

Map<String, dynamic> productionMap(Object? raw) => raw is Map
    ? raw.map(
        (Object? key, Object? value) =>
            MapEntry<String, dynamic>('$key', value),
      )
    : <String, dynamic>{};

List<Map<String, dynamic>> productionListOf(
  Map<String, dynamic> data,
  String key,
) => (data[key] as List<dynamic>? ?? <dynamic>[])
    .whereType<Map>()
    .map(productionMap)
    .toList();

/// 依赖缺失（插件未安装 / 停用 ⇒ 503）必须给出可读说明，而不是把
/// `HTTP 404` 摊在空列表上。
String productionReadable(Object error, String prefix) {
  String text = '$error'.trim();
  if (text.startsWith('Exception: ')) {
    text = text.substring('Exception: '.length).trim();
  }
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
  if (text.contains('504')) {
    return '插件处理超时（HTTP 504）：核心委派只等 30s，操作可能太重；'
        '稍后重试，或把工作空间指向更小的目录。';
  }
  return text.isEmpty ? prefix : '$prefix：$text';
}

Color productionStatusColor(ColorScheme cs, String status) {
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

/// 状态的中文名（人话文案用；原始 wire 值仍可在小字里核对）。
String productionStatusLabel(String status) {
  switch (status.trim()) {
    case 'draft':
      return '需求草案';
    case 'recon':
      return '侦查中';
    case 'aligning':
      return '待拍板';
    case 'awaiting_user':
      return '等你回答';
    case 'scoped':
      return '已定范围';
    case 'queued':
      return '待派发';
    case 'packing':
      return '打包中';
    case 'packed':
      return '待执行';
    case 'running':
      return '执行中';
    case 'gating':
      return '门控中';
    case 'done':
      return '已完成';
    case 'blocked':
      return '被挡住';
    case 'cancelled':
      return '已取消';
    default:
      return status.trim();
  }
}

/// 任务在「今日」里的归属：decide / handle / running / done / prepare / execution / other。
String productionTaskBucket(Map<String, dynamic> task, {DateTime? now}) {
  final String status = '${task['status'] ?? ''}'.trim();
  switch (status) {
    case 'aligning':
    case 'awaiting_user':
      return 'decide';
    case 'blocked':
    case 'queued':
    case 'scoped':
      return 'handle';
    case 'packing':
    case 'packed':
    case 'running':
    case 'gating':
      return 'running';
    case 'done':
      final DateTime? at = _parseTime(
        '${task['updated_at'] ?? task['finished_at'] ?? task['created_at'] ?? ''}',
      );
      if (at == null) return 'done';
      final DateTime base = now ?? DateTime.now();
      return base.difference(at) <= const Duration(hours: 24)
          ? 'done'
          : 'other';
    case 'draft':
    case 'recon':
      return 'prepare';
    default:
      return 'other';
  }
}

DateTime? _parseTime(String raw) {
  if (raw.trim().isEmpty) return null;
  return DateTime.tryParse(raw.trim())?.toLocal();
}

/// 「谁」：任务里显式写的人优先，其次产线执行身份，最后给可读默认值。
String productionTaskWho(
  Map<String, dynamic> task, {
  String executor = '',
}) {
  for (final String key in const <String>[
    'assignee',
    'owner',
    'executor',
    'agent_id',
    'role',
  ]) {
    final String value = '${task[key] ?? ''}'.trim();
    if (value.isNotEmpty) return value;
  }
  final String fallback = executor.trim();
  return fallback.isEmpty ? '产线执行者' : fallback;
}

/// `blocked` / 门控失败的人话原因：把错误码翻译成「为什么」，不直接把英文摊给用户。
String productionTaskWhy(Map<String, dynamic> task) {
  final String status = '${task['status'] ?? ''}'.trim();
  if (status == 'aligning' || status == 'awaiting_user') {
    final Map<String, dynamic> questions = productionMap(task['questions']);
    final int open = (questions['open'] as num?)?.toInt() ?? 0;
    return open > 0 ? '还有 $open 个问题没回答，产线在等你拍板' : '理解卡已就绪，等你确认后落档';
  }
  if (status == 'blocked') {
    final String reason = <String>[
      '${task['blocked_reason'] ?? ''}',
      '${task['last_error'] ?? ''}',
    ].where((String item) => item.trim().isNotEmpty).join(' ');
    if (reason.contains('structure_not_ready') || reason.contains('LG-01')) {
      return '项目结构还没整理通过（结构门未过）';
    }
    if (reason.contains('line_not_ready') ||
        reason.contains('LG-0') ||
        reason.contains('normaliz') ||
        reason.contains('index')) {
      return '文档归一化或代码索引还没就绪（产线就绪门未过）';
    }
    if (reason.contains('depends_on') || reason.contains('依赖')) {
      return '前置任务还没完成（依赖阻塞）';
    }
    if (reason.contains('write_scope_overlap') || reason.contains('写域')) {
      return '写域与其它在跑任务交叠（并行冲突）';
    }
    if (reason.contains('gate') || reason.contains('门控')) {
      return '出口门控没有通过（缺证据或命令失败）';
    }
    if (reason.contains('drift') || reason.contains('BG-')) {
      return '批次漂移哨兵报了问题（漂移门未过）';
    }
    final String loop = '${productionMap(task['loop'])['stop_reason'] ?? ''}';
    if (loop.isNotEmpty) return '产线主控主动停下（${_humanStopReason(loop)}）';
    return '产线主控把它停下来了，需要人工确认';
  }
  final Map<String, dynamic> lastGate = productionMap(task['last_gate']);
  final List<Map<String, dynamic>> commands = productionListOf(
    lastGate,
    'commands',
  );
  if (status == 'packed' &&
      commands.any((Map<String, dynamic> item) => item['ok'] == false)) {
    return '上次出口门控有命令失败，任务退回了待执行';
  }
  switch (status) {
    case 'queued':
      return '已经排进队列，等派发';
    case 'packing':
      return '打包角色正在生成执行包';
    case 'packed':
      return '执行包已生成，等待执行';
    case 'running':
      return '执行角色正在按写域改文件';
    case 'gating':
      return '执行完成，正在逐条核对出口门控';
    case 'done':
      return '任务已完成';
    case 'cancelled':
      return '任务已取消';
    default:
      return '任务状态：${productionStatusLabel(status)}';
  }
}

String _humanStopReason(String raw) {
  if (raw.contains('budget')) return '预算/轮次用尽';
  if (raw.contains('question')) return '提问次数到顶';
  if (raw.contains('fail')) return '连续失败';
  return '触发停止条件';
}

/// 「下一步」：一句话告诉用户现在该点哪。
String productionTaskNextStep(Map<String, dynamic> task) {
  final String status = '${task['status'] ?? ''}'.trim();
  switch (status) {
    case 'draft':
    case 'recon':
      return '打开准备页，先补齐需求五栏再侦查';
    case 'aligning':
    case 'awaiting_user':
      return '打开准备页回答问题，确认计划后落档';
    case 'blocked':
      return '按上面的原因处理后点「恢复」，回到队列';
    case 'queued':
    case 'scoped':
      return '在「执行」里批量派发（可先 dry run 预览）';
    case 'packing':
      return '等打包完成；失败会自动回队列或转 blocked';
    case 'packed':
      return '在任务菜单里点「执行」';
    case 'running':
      return '等执行收尾；有问题会在「今日」里出现';
    case 'gating':
      return '核对门控清单，全部有证据后点「完成」';
    case 'done':
      return '查看台账与产物，或继续下一个任务';
    case 'cancelled':
      return '无需处理（保留可追溯）';
    default:
      return '刷新后再看';
  }
}

/// 「谁 + 为什么 + 下一步」的一行人话（不出现英文错误码）。
String productionTaskHumanLine(
  Map<String, dynamic> task, {
  String executor = '',
}) {
  final String who = productionTaskWho(task, executor: executor);
  return '执行者 $who · ${productionTaskWhy(task)} · 下一步：${productionTaskNextStep(task)}';
}

/// 任务的门控清单（`gate.checklist` / `gate.items`），合并最近一次门控结果。
List<Map<String, dynamic>> productionTaskGateItems(Map<String, dynamic> task) {
  final Map<String, dynamic> gate = productionMap(task['gate']);
  final List<Map<String, dynamic>> raw = <Map<String, dynamic>>[
    ...productionListOf(gate, 'checklist'),
    if (productionListOf(gate, 'checklist').isEmpty)
      ...productionListOf(gate, 'items'),
  ];
  final Map<String, dynamic> lastGate = productionMap(task['last_gate']);
  final List<Map<String, dynamic>> commands = productionListOf(
    lastGate,
    'commands',
  );
  return <Map<String, dynamic>>[
    for (final Map<String, dynamic> item in raw)
      _gateItem(item, commands),
  ];
}

Map<String, dynamic> _gateItem(
  Map<String, dynamic> item,
  List<Map<String, dynamic>> commands,
) {
  final String text = '${item['text'] ?? ''}'.trim();
  final String evidence = '${item['evidence'] ?? ''}'.trim();
  final bool placeholder =
      evidence.isEmpty ||
      evidence == '-' ||
      evidence == 'todo' ||
      evidence == 'tbd' ||
      evidence == '...';
  final String key = 'evidence:$text';
  final bool failed = commands.any(
    (Map<String, dynamic> command) =>
        '${command['command'] ?? ''}' == key && command['ok'] == false,
  );
  return <String, dynamic>{
    ...item,
    'text': text,
    'evidence': evidence,
    'ok': !placeholder && !failed,
    if (placeholder) 'missing': '缺 evidence',
  };
}

/// 门控未过时的可读原因；空串 = 全部通过（或没有清单）。
String productionGateBlockedReason(Map<String, dynamic> task) {
  final List<Map<String, dynamic>> items = productionTaskGateItems(task);
  if (items.isEmpty) return '';
  final List<String> missing = <String>[
    for (final Map<String, dynamic> item in items)
      if (item['ok'] != true)
        '${item['text'] ?? ''}${productionMap(item)['missing'] == null ? '（命令失败）' : '（缺 evidence）'}',
  ];
  if (missing.isEmpty) return '';
  return '门控未过：${missing.join('；')}';
}

/// 计划里的 7 块是否齐全（缺块由计划审查页显式列出）。
List<String> productionPlanMissingBlocks(Map<String, dynamic> plan) {
  final List<String> missing = <String>[];
  if (productionMap(plan['design']).isEmpty) missing.add('方案设计');
  if (productionListOf(plan, 'invariants').isEmpty) missing.add('不变量账本');
  if (productionListOf(plan, 'tasks').isEmpty) missing.add('任务 DAG');
  final Map<String, dynamic> gates = productionMap(plan['gates']);
  if (gates.isEmpty) missing.add('出口门禁');
  if (productionListOf(plan, 'traceability').isEmpty) missing.add('追踪矩阵');
  if (productionListOf(plan, 'risks').isEmpty &&
      productionListOf(plan, 'unknowns').isEmpty) {
    missing.add('风险');
  }
  if (productionMap(plan['change_control']).isEmpty) missing.add('变更控制');
  return missing;
}

/// 追踪矩阵断链（需求缺条目 / 任务或门控引用不存在）。
List<String> productionTraceabilityBroken(Map<String, dynamic> plan) {
  final Set<String> requirements = <String>{
    for (final Map<String, dynamic> item in productionListOf(
      plan,
      'requirements',
    ))
      '${item['id'] ?? ''}'.trim(),
  }..remove('');
  final Set<String> tasks = <String>{
    for (final Map<String, dynamic> item in productionListOf(plan, 'tasks'))
      '${item['id'] ?? ''}'.trim(),
  }..remove('');
  final Map<String, dynamic> gates = productionMap(plan['gates']);
  final List<String> broken = <String>[];
  final Set<String> covered = <String>{};
  for (final Map<String, dynamic> row in productionListOf(
    plan,
    'traceability',
  )) {
    final String req = '${row['req'] ?? ''}'.trim();
    if (req.isEmpty) {
      broken.add('追踪矩阵有一条缺 REQ 编号');
      continue;
    }
    if (requirements.isNotEmpty && !requirements.contains(req)) {
      broken.add('$req 引用了不存在的需求');
      continue;
    }
    covered.add(req);
    final List<String> mapped = (row['tasks'] as List<dynamic>? ?? <dynamic>[])
        .map((Object? item) => '$item'.trim())
        .where((String item) => item.isNotEmpty)
        .toList();
    if (mapped.isEmpty) broken.add('$req 没有映射任务');
    for (final String taskId in mapped) {
      if (tasks.isNotEmpty && !tasks.contains(taskId)) {
        broken.add('$req 指向不存在的任务 $taskId');
      }
    }
    final List<dynamic> gateRefs =
        row['gates'] as List<dynamic>? ?? <dynamic>[];
    if (gateRefs.isEmpty) broken.add('$req 没有映射门控');
    for (final dynamic raw in gateRefs) {
      final String taskId = raw is Map
          ? '${productionMap(raw)['task'] ?? productionMap(raw)['task_id'] ?? ''}'
                .trim()
          : '';
      if (taskId.isNotEmpty && tasks.isNotEmpty && !tasks.contains(taskId)) {
        broken.add('$req 的门控指向不存在的任务 $taskId');
      }
      final String key = raw is Map
          ? '${productionMap(raw)['text'] ?? productionMap(raw)['key'] ?? ''}'
                .trim()
          : '$raw'.trim();
      if (key.isEmpty) continue;
      final bool found = gates.values.any(
        (Object? list) => productionListOf(
          <String, dynamic>{'items': list},
          'items',
        ).any(
          (Map<String, dynamic> item) =>
              '${item['text'] ?? item['key'] ?? ''}'.contains(key),
        ),
      );
      if (!found) broken.add('$req 的门控「$key」在任务门控里不存在');
    }
  }
  for (final String req in requirements) {
    if (!covered.contains(req)) broken.add('$req 在追踪矩阵里缺条目');
  }
  return broken;
}

bool _findingOpen(Map<String, dynamic> finding) {
  final String status = '${finding['status'] ?? 'open'}'.trim().toLowerCase();
  return !const <String>{
    'closed',
    'resolved',
    'accepted',
    'waived',
    'done',
  }.contains(status);
}

/// high 且仍未关闭的 findings（未关闭的 high 会阻止落档）。
List<Map<String, dynamic>> productionOpenHighFindings(
  Map<String, dynamic> plan,
  List<Map<String, dynamic>> extraFindings,
) {
  final List<Map<String, dynamic>> all = <Map<String, dynamic>>[
    ...productionListOf(plan, 'findings'),
    ...extraFindings,
  ];
  return <Map<String, dynamic>>[
    for (final Map<String, dynamic> finding in all)
      if (('${finding['severity'] ?? ''}'.trim().toLowerCase() == 'high') &&
          _findingOpen(finding))
        finding,
  ];
}

/// 简单批次：按依赖深度分层，同层内写域交叠的任务拆到后续批次。
List<List<Map<String, dynamic>>> productionPlanBatches(
  Map<String, dynamic> plan,
) {
  final List<Map<String, dynamic>> tasks = productionListOf(plan, 'tasks');
  if (tasks.isEmpty) return <List<Map<String, dynamic>>>[];
  final Map<String, int> depth = <String, int>{};
  int depthOf(String id, Set<String> seen) {
    final int? cached = depth[id];
    if (cached != null) return cached;
    if (!seen.add(id)) return 1;
    final Map<String, dynamic> task = tasks.firstWhere(
      (Map<String, dynamic> item) => '${item['id'] ?? ''}' == id,
      orElse: () => <String, dynamic>{},
    );
    int value = 1;
    for (final Object? dep in (task['depends_on'] as List<dynamic>? ??
        <dynamic>[])) {
      final String depId = '$dep'.trim();
      if (depId.isEmpty) continue;
      final int candidate = depthOf(depId, seen) + 1;
      if (candidate > value) value = candidate;
    }
    depth[id] = value;
    return value;
  }

  for (final Map<String, dynamic> task in tasks) {
    depthOf('${task['id'] ?? ''}', <String>{});
  }
  final List<List<Map<String, dynamic>>> levels =
      <List<Map<String, dynamic>>>[];
  final List<Map<String, dynamic>> sorted = List<Map<String, dynamic>>.of(tasks)
    ..sort(
      (Map<String, dynamic> a, Map<String, dynamic> b) =>
          (depth['${a['id'] ?? ''}'] ?? 1)
              .compareTo(depth['${b['id'] ?? ''}'] ?? 1),
    );
  for (final Map<String, dynamic> task in sorted) {
    final int level = depth['${task['id'] ?? ''}'] ?? 1;
    while (levels.length < level) {
      levels.add(<Map<String, dynamic>>[]);
    }
    levels[level - 1].add(task);
  }
  // 同层按写域拆开：与已放进去的任务交叠就挪到本层的下一批。
  // 不同依赖深度不混批，保证前一批是后一批的硬依赖。
  final List<List<Map<String, dynamic>>> batches =
      <List<Map<String, dynamic>>>[];
  for (final List<Map<String, dynamic>> level in levels) {
    final List<List<Map<String, dynamic>>> levelBatches =
        <List<Map<String, dynamic>>>[];
    for (final Map<String, dynamic> task in level) {
      final List<String> scope = (task['write_scope'] as List<dynamic>? ??
              <dynamic>[])
          .map((Object? item) => '$item'.trim())
          .where((String item) => item.isNotEmpty)
          .toList();
      bool placed = false;
      for (final List<Map<String, dynamic>> batch in levelBatches) {
        final bool overlap = batch.any(
          (Map<String, dynamic> peer) => _scopeOverlap(
            scope,
            (peer['write_scope'] as List<dynamic>? ?? <dynamic>[])
                .map((Object? item) => '$item'.trim())
                .toList(),
          ),
        );
        if (!overlap) {
          batch.add(task);
          placed = true;
          break;
        }
      }
      if (!placed) levelBatches.add(<Map<String, dynamic>>[task]);
    }
    batches.addAll(levelBatches);
  }
  return batches;
}

bool _scopeOverlap(List<String> a, List<String> b) {
  if (a.isEmpty || b.isEmpty) return true;
  bool overlap(String left, String right) {
    final String l = left.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    final String r = right.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    if (l.isEmpty || r.isEmpty) return true;
    return l == r || '$l/'.startsWith('$r/') || '$r/'.startsWith('$l/');
  }

  for (final String left in a) {
    for (final String right in b) {
      if (overlap(left, right)) return true;
    }
  }
  return false;
}

/// 附件的一行元数据（sha256 前 8 位 / 大小 / 类型 + 人工参考警告）。
String productionAttachmentMeta(Map<String, dynamic> attachment) {
  final String hash = '${attachment['sha256'] ?? ''}'.trim();
  final int size = (attachment['size'] as num?)?.toInt() ?? 0;
  final String type = '${attachment['type'] ?? ''}'.trim();
  final String kind = '${attachment['kind'] ?? ''}'.trim();
  final bool manual = attachment['summary_by'] == 'manual_reference';
  final List<String> parts = <String>[
    if (hash.isNotEmpty) 'sha256 ${hash.length > 8 ? hash.substring(0, 8) : hash}',
    if (size > 0) productionSizeText(size),
    if (type.isNotEmpty) type,
    if (kind.isNotEmpty && kind != type) kind,
    if (manual) '图片需人工参考（当前模型不看图）',
  ];
  return parts.isEmpty ? '' : ' · ${parts.join(' · ')}';
}

String productionSizeText(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// 门控清单逐条的纯文本行（`- [ ] 文本 · evidence`），详情页与计划审查共用。
String productionGateLine(Map<String, dynamic> item) {
  final String evidence = '${item['evidence'] ?? ''}'.trim();
  return '- [ ] ${item['text'] ?? ''}'
      '${evidence.isEmpty ? ' · 缺 evidence' : ' · $evidence'}';
}

/// 任务可用操作：只给状态机允许的那几条（不把按钮摆出来再让后端 409）。
List<String> productionTaskActions(Map<String, dynamic> task) {
  final String status = '${task['status'] ?? ''}';
  return <String>[
    if (status == 'queued' || status == 'packing') 'pack',
    if (status == 'packed') 'run',
    if (status == 'aligning' || status == 'awaiting_user') 'decide',
    // D6-O：主控 / 门控停下的任务可恢复（blocked → queued）。
    if (status == 'blocked') 'resume',
    if (status != 'done' && status != 'cancelled') 'cancel',
  ];
}

/// 产线阶段（L0 硬门）：organizing → normalizing → indexing → ready。
String productionPhaseLabel(String phase) {
  switch (phase.trim()) {
    case 'organizing':
      return '整理中';
    case 'normalizing':
      return '归一化中';
    case 'indexing':
      return '索引中';
    case 'ready':
      return '就绪';
    default:
      return phase.trim();
  }
}

/// 就绪门判定：未知（老插件没有该路由 / 空响应）回 null = 不禁用任何按钮。
bool? productionReadinessReady(Map<String, dynamic>? readiness) {
  if (readiness == null) return null;
  final Object? raw = readiness['ready'];
  if (raw is bool) return raw;
  switch ('${readiness['status'] ?? ''}'.trim()) {
    case 'ready':
      return true;
    case 'blocked':
    case 'not_ready':
    case 'organizing':
      return false;
    default:
      return null;
  }
}

/// 逐条列出未就绪原因（`missing[]` + 未通过的 `gates[]`），用于首屏清单与 409 文案。
List<String> productionReadinessMissing(Map<String, dynamic> readiness) {
  final List<String> out = <String>[];
  void add(Object? raw) {
    if (raw == null) return;
    if (raw is Map) {
      final Map<String, dynamic> item = productionMap(raw);
      final String label =
          '${item['label'] ?? item['title'] ?? item['key'] ?? item['name'] ?? ''}'
              .trim();
      final String reason =
          '${item['reason'] ?? item['detail'] ?? item['message'] ?? ''}'.trim();
      final String text = <String>[
        if (label.isNotEmpty) label,
        if (reason.isNotEmpty) reason,
      ].join('：');
      if (text.isNotEmpty && !out.contains(text)) out.add(text);
      return;
    }
    final String text = '$raw'.trim();
    if (text.isNotEmpty && !out.contains(text)) out.add(text);
  }

  final Object? missing = readiness['missing'];
  if (missing is List) {
    for (final Object? item in missing) {
      add(item);
    }
  } else {
    add(missing);
  }
  final Object? gates = readiness['gates'];
  if (gates is List) {
    for (final Object? gate in gates) {
      if (gate is Map && productionMap(gate)['ok'] == false) add(gate);
    }
  } else if (gates is Map) {
    gates.forEach((Object? key, Object? value) {
      if (value is Map) {
        if (productionMap(value)['ok'] == false) add(value);
      } else if (value == false) {
        add(key);
      }
    });
  }
  return out;
}

/// 最近一次就绪检查时间（后端字段名兼容 `checked_at` / `at`）。
String productionReadinessCheckedAt(Map<String, dynamic>? readiness) {
  if (readiness == null) return '';
  return '${readiness['checked_at'] ?? readiness['at'] ?? ''}'.trim();
}

String productionActionLabel(String value) {
  switch (value) {
    case 'pack':
      return '打包';
    case 'run':
      return '执行';
    case 'decide':
      return '拍板';
    case 'resume':
      return '恢复';
    case 'cancel':
      return '取消任务';
    default:
      return value;
  }
}

/// 目录选择（取消 / 平台异常都回 null，不把异常抛给面板）。
Future<String?> pickProductionDirectory(String title) async {
  try {
    return await FilePicker.getDirectoryPath(dialogTitle: title);
  } catch (_) {
    return null;
  }
}

/// 文件多选（file_picker 13：`pickFiles` 即多选；返回绝对路径，取消回空列表）。
Future<List<String>> pickProductionFiles(String title) async {
  try {
    final List<PlatformFile> picked = await FilePicker.pickFiles(
      dialogTitle: title,
    );
    return <String>[
      for (final PlatformFile file in picked)
        if (file.path != null && file.path!.isNotEmpty) file.path!,
    ];
  } catch (_) {
    return <String>[];
  }
}

/// 绝对路径 → 工作空间相对路径（Windows 大小写不敏感）；不在空间内回空串。
String productionRelativeToWorkspace(String workspace, String path) {
  final String root = p.normalize(p.absolute(workspace));
  final String target = p.normalize(p.absolute(path));
  final String rootLower = root.toLowerCase();
  final String targetLower = target.toLowerCase();
  if (targetLower == rootLower) return '.';
  final String prefix = rootLower.endsWith(p.separator)
      ? rootLower
      : '$rootLower${p.separator}';
  if (!targetLower.startsWith(prefix)) return '';
  return p.relative(target, from: root).replaceAll('\\', '/');
}
