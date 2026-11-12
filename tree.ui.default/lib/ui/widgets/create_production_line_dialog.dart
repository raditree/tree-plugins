import 'package:flutter/material.dart';

import '../../io/api_service.dart';
import '../app_radius.dart';
import '../models/agent.dart';
import '../services/model_pool.dart';
import 'production_line_utils.dart';

/// 新建 / 编辑产线的配置页。
///
/// 与「创建 Agent」同规格：名称、工作空间、执行 Agent、角色与模型、执行工具。
/// 产线是**独立功能**（与 Agent 同级，§16.1），所以执行身份（`executor`）在这里
/// 选定并写进 `line.yaml`，派发时不再依赖「谁点了一下」。
///
/// 新建时允许不选执行 Agent（后端允许留空）；编辑时可以清空。
class CreateProductionLineDialog extends StatefulWidget {
  const CreateProductionLineDialog({
    super.key,
    this.initialWorkspace = '',
    this.defaultAgentId = '',
    this.initial,
  });

  /// 新建时预填的工作空间（取现有产线，避免每次手输绝对路径）。
  final String initialWorkspace;

  /// 默认选中的执行 Agent（= 当前选中的 Agent）。
  final String defaultAgentId;

  /// 编辑模式的产线数据（`line.yaml` 的 JSON）；null = 新建。
  final Map<String, dynamic>? initial;

  @override
  State<CreateProductionLineDialog> createState() =>
      _CreateProductionLineDialogState();
}

/// 对话框结果：面板 / 工作台据此组 `POST` / `PATCH` 请求体。
class ProductionLineSpec {
  const ProductionLineSpec({
    required this.name,
    required this.workspace,
    required this.executor,
    required this.roles,
    required this.orchestrator,
  });

  final String name;
  final String workspace;

  /// `{agent_id, team_id}`；新建且没选执行 Agent 时为 null（不下发）。
  final Map<String, dynamic>? executor;

  /// 四个角色槽位（model_id + tools；专家保留 enabled / max_per_task）。
  final Map<String, dynamic> roles;

  /// D6-O `line.yaml.orchestrator`（enabled / tick / auto_retry / max_asks /
  /// stop_on_budget）；缺省即后端默认。
  final Map<String, dynamic> orchestrator;
}

class _RoleDef {
  const _RoleDef(this.key, this.label, this.defaultModel, this.defaultTools);

  final String key;
  final String label;
  final String defaultModel;
  final List<String> defaultTools;
}

const List<_RoleDef> _roleDefs = <_RoleDef>[
  _RoleDef('orchestrator', '主控', '', <String>['read', 'grep', 'message']),
  _RoleDef(
    'packer',
    '打包',
    '',
    <String>['read', 'list', 'grep', 'terminal', 'message'],
  ),
  _RoleDef(
    'executor',
    '执行',
    '',
    <String>['read', 'write', 'edit', 'terminal', 'message', 'spec'],
  ),
  _RoleDef('expert', '专家', '', <String>['read', 'grep']),
];

/// 角色工具目录：名称 + 中文标签（顺序即 chips 顺序）。
///
/// 与后端硬边界一致（`expert.dart` 禁 write / edit / subagent / team / ask_expert；
/// 打包只要读 + 命令），因此**不把非法组合摆出来**：每张角色卡只列自己的工具。
const List<(String, String)> _toolDefs = <(String, String)>[
  ('read', '读文件'),
  ('list', '列目录'),
  ('grep', '搜索'),
  ('write', '写文件'),
  ('edit', '编辑'),
  ('terminal', '命令'),
  ('message', '协作'),
  ('spec', '规范'),
];

/// 各角色允许勾选的工具（白名单；工具名与 `kRoleDefaultTools` 同键）。
const Map<String, Set<String>> _roleAllowedTools = <String, Set<String>>{
  'orchestrator': <String>{'read', 'list', 'grep', 'message'},
  'packer': <String>{'read', 'list', 'grep', 'terminal', 'message'},
  'executor': <String>{
    'read',
    'list',
    'grep',
    'write',
    'edit',
    'terminal',
    'message',
    'spec',
  },
  'expert': <String>{'read', 'list', 'grep'},
};

class _CreateProductionLineDialogState
    extends State<CreateProductionLineDialog> {
  late final TextEditingController _name = TextEditingController(
    text: '${widget.initial?['name'] ?? ''}',
  );
  late final TextEditingController _workspace = TextEditingController(
    text: widget.initial == null
        ? widget.initialWorkspace
        : '${widget.initial?['workspace_dir'] ?? ''}',
  );

  List<_RoleDef> get _roles => _roleDefs;

  List<Agent> _agents = <Agent>[];
  List<Map<String, dynamic>> _models = <Map<String, dynamic>>[];
  bool _loading = true;
  String _loadError = '';

  String _executorAgentId = '';
  final Map<String, String> _roleModels = <String, String>{};
  final Map<String, Set<String>> _roleTools = <String, Set<String>>{};

  /// 存量产线里出现过、但不属于该角色的工具（保存时剔除；如实提示一次）。
  final Map<String, List<String>> _droppedTools = <String, List<String>>{};

  /// `roles.expert.enabled` / `max_per_task`（默认关闭，与后端一致）。
  bool _expertEnabled = false;
  int _expertMax = 3;

  /// `line.yaml.orchestrator`（D6-O；缺省与后端默认一致）。
  bool _orchestratorEnabled = true;
  bool _autoRetry = true;
  bool _stopOnBudget = true;
  late final TextEditingController _tickInterval = TextEditingController(
    text: '${productionMap(widget.initial?['orchestrator'])['tick_interval_seconds'] ?? 5}',
  );
  late final TextEditingController _maxAsks = TextEditingController(
    text: '${productionMap(widget.initial?['orchestrator'])['max_asks_per_task'] ?? 3}',
  );

  bool get _editing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final Map<String, dynamic> roles = productionMap(widget.initial?['roles']);
    for (final _RoleDef role in _roles) {
      final Object? raw = roles[role.key];
      final Map<String, dynamic> data = productionMap(raw);
      final String model = '${data['model_id'] ?? ''}'.trim();
      _roleModels[role.key] = model;
      final Set<String> allowed =
          _roleAllowedTools[role.key] ?? const <String>{};
      final List<String> configured = <String>[
        for (final Object? item
            in (data['tools'] as List<dynamic>? ?? role.defaultTools))
          if ('${item ?? ''}'.trim().isNotEmpty) '${item ?? ''}'.trim(),
      ];
      _roleTools[role.key] = <String>{
        for (final String tool in configured)
          if (allowed.contains(tool)) tool,
      };
      final List<String> dropped = <String>[
        for (final String tool in configured)
          if (!allowed.contains(tool)) tool,
      ];
      if (dropped.isNotEmpty) _droppedTools[role.key] = dropped;
      if (role.key == 'expert') {
        _expertEnabled = data['enabled'] == true;
        _expertMax = (data['max_per_task'] as num?)?.toInt() ?? 3;
      }
    }
    final Map<String, dynamic> executor = productionMap(
      widget.initial?['executor'],
    );
    final Map<String, dynamic> orchestrator = productionMap(
      widget.initial?['orchestrator'],
    );
    _orchestratorEnabled = orchestrator['enabled'] != false;
    _autoRetry = orchestrator['auto_retry'] != false;
    _stopOnBudget = orchestrator['stop_on_budget'] != false;
    final String configured = '${executor['agent_id'] ?? ''}'.trim();
    _executorAgentId = configured.isNotEmpty
        ? configured
        : (widget.initial == null ? widget.defaultAgentId.trim() : '');
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _workspace.dispose();
    _tickInterval.dispose();
    _maxAsks.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = '';
    });
    try {
      final List<Object> results = await Future.wait(<Future<Object>>[
        ApiService.getAgents(),
        ApiService.getModels(),
      ]);
      if (!mounted) return;
      setState(() {
        _agents = results[0] as List<Agent>;
        _models = chatModelsOf(results[1] as List<Map<String, dynamic>>);
        _loading = false;
        // 旧产线的角色模型是裸 model_id：能唯一对上就换成 `provider/model_id`；
        // 对不上（或池里根本没有）保持原值，由下拉标成"已失效"、提交被拦下。
        for (final _RoleDef role in _roles) {
          final String raw = (_roleModels[role.key] ?? '').trim();
          if (raw.isEmpty) {
            // 不再凭空写 `lfm3`：默认 = 模型池第一个 chat 模型（池空则留空）。
            if (_models.isNotEmpty) {
              _roleModels[role.key] = modelKeyOf(_models.first);
            }
            continue;
          }
          final String? canonical = _canonicalKey(raw);
          if (canonical != null) _roleModels[role.key] = canonical;
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = productionReadable(error, '执行 Agent / 模型池加载失败');
      });
    }
  }

  Future<void> _browse() async {
    final String? picked = await pickProductionDirectory('选择产线工作空间');
    if (picked == null || !mounted) return;
    setState(() => _workspace.text = picked);
  }

  /// 裸 model_id / 完整键 → 模型池里的唯一键；对不上返回 null（视为失效）。
  String? _canonicalKey(String raw) {
    final String value = raw.trim();
    if (value.isEmpty) return null;
    for (final Map<String, dynamic> model in _models) {
      if (modelKeyOf(model) == value) return modelKeyOf(model);
    }
    final List<Map<String, dynamic>> byBare = <Map<String, dynamic>>[
      for (final Map<String, dynamic> model in _models)
        if ('${model['model_id'] ?? ''}' == value) model,
    ];
    return byBare.length == 1 ? modelKeyOf(byBare.single) : null;
  }

  void _submit() {
    final String name = _name.text.trim();
    if (name.isEmpty) {
      _toast('请填写产线名称');
      return;
    }
    for (final _RoleDef role in _roles) {
      final String value = (_roleModels[role.key] ?? '').trim();
      if (value.isEmpty) {
        _toast('请为「${role.label}」选择模型');
        return;
      }
      if (_models.isNotEmpty && _canonicalKey(value) == null) {
        _toast('「${role.label}」的模型不在模型池里（已失效），请重新选择');
        return;
      }
    }
    if (!(_roleTools['executor'] ?? const <String>{}).contains('write') &&
        !(_roleTools['executor'] ?? const <String>{}).contains('edit')) {
      _toast('执行工具至少要有「写文件」或「编辑」：否则执行模型无法落地');
      return;
    }
    final Map<String, dynamic>? executor = _buildExecutor();
    Navigator.of(context).pop(
      ProductionLineSpec(
        name: name,
        workspace: _workspace.text.trim(),
        executor: executor,
        roles: _buildRoles(),
        orchestrator: _buildOrchestrator(),
      ),
    );
  }

  Map<String, dynamic>? _buildExecutor() {
    if (_executorAgentId.isEmpty && !_editing) return null;
    String teamId = '';
    for (final Agent agent in _agents) {
      if (agent.id == _executorAgentId) {
        teamId = agent.teamScopeId;
        break;
      }
    }
    return <String, dynamic>{
      'agent_id': _executorAgentId,
      'team_id': _executorAgentId.isEmpty ? '' : teamId,
    };
  }

  Map<String, dynamic> _buildRoles() {
    final Map<String, dynamic> current = productionMap(
      widget.initial?['roles'],
    );
    final Map<String, dynamic> roles = <String, dynamic>{};
    for (final _RoleDef role in _roles) {
      final Map<String, dynamic> existing = productionMap(current[role.key]);
      final Set<String> tools = _roleTools[role.key] ?? <String>{};
      final List<String> sorted = tools.toList()..sort();
      roles[role.key] = <String, dynamic>{
        ...existing,
        'model_id': _roleModels[role.key] ?? '',
        'tools': sorted,
        if (role.key == 'expert') ...<String, dynamic>{
          'enabled': _expertEnabled,
          'max_per_task': _expertMax,
        },
      };
    }
    return roles;
  }

  Map<String, dynamic> _buildOrchestrator() => <String, dynamic>{
    ...productionMap(widget.initial?['orchestrator']),
    'enabled': _orchestratorEnabled,
    'tick_interval_seconds': (int.tryParse(_tickInterval.text.trim()) ?? 5)
        .clamp(0, 3600),
    'auto_retry': _autoRetry,
    'max_asks_per_task': (int.tryParse(_maxAsks.text.trim()) ?? 3).clamp(0, 10),
    'stop_on_budget': _stopOnBudget,
  };

  void _toast(String text) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_editing ? '产线配置' : '新建产线'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _label('名称'),
              TextField(
                key: const Key('production-line-name'),
                controller: _name,
                autofocus: !_editing,
                decoration: const InputDecoration(
                  hintText: '标准开发流',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              _label('工作空间（可空）'),
              TextField(
                key: const Key('production-line-workspace'),
                controller: _workspace,
                decoration: InputDecoration(
                  hintText: 'E:/work/project',
                  helperText: '准备阶段与门控都在这个目录里执行',
                  isDense: true,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    key: const Key('production-line-workspace-pick'),
                    tooltip: '选择目录',
                    onPressed: _browse,
                    icon: const Icon(Icons.folder_open, size: 18),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              _label('执行 Agent'),
              if (_loading)
                const _LoadingLine(text: '正在加载 Agent 与模型池…')
              else if (_loadError.isNotEmpty)
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        _loadError,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                    TextButton(onPressed: _load, child: const Text('重试')),
                  ],
                )
              else
                KeyedSubtree(
                  key: const Key('production-line-executor'),
                  child: DropdownButtonFormField<String>(
                    key: ValueKey<String>('executor-$_executorAgentId'),
                    initialValue: _executorAgentId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      helperText: '打包 / 执行 / 专家都用这个 Agent 及其团队召员工',
                    ),
                    items: <DropdownMenuItem<String>>[
                      const DropdownMenuItem<String>(
                        value: '',
                        child: Text('（不指定）'),
                      ),
                      for (final Agent agent in _agents)
                        DropdownMenuItem<String>(
                          value: agent.id,
                          child: Text(
                            '${agent.name} · ${agent.id}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _loading
                        ? null
                        : (String? value) {
                            setState(() => _executorAgentId = value ?? '');
                          },
                  ),
                ),
              const SizedBox(height: 14),
              _label('角色配置（每个角色独立选模型与工具）'),
              const SizedBox(height: 6),
              for (final _RoleDef role in _roles) ...<Widget>[
                _roleCard(role),
                const SizedBox(height: 8),
              ],
              const Text(
                '执行角色至少要有「写文件」或「编辑」；打包 / 专家不能写文件（工具白名单）。',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              _label('主控决策循环（执行期）'),
              Wrap(
                spacing: 16,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Text('启用', style: TextStyle(fontSize: 11.5)),
                      Switch(
                        key: const Key('production-orchestrator-enabled'),
                        value: _orchestratorEnabled,
                        onChanged: (bool value) {
                          setState(() => _orchestratorEnabled = value);
                        },
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Text('间隔（秒）', style: TextStyle(fontSize: 11.5)),
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 64,
                        child: TextField(
                          key: const Key('production-orchestrator-tick'),
                          controller: _tickInterval,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Text('提问上限', style: TextStyle(fontSize: 11.5)),
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 64,
                        child: TextField(
                          key: const Key('production-orchestrator-asks'),
                          controller: _maxAsks,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Text('自动重试', style: TextStyle(fontSize: 11.5)),
                      Switch(
                        key: const Key('production-orchestrator-retry'),
                        value: _autoRetry,
                        onChanged: (bool value) {
                          setState(() => _autoRetry = value);
                        },
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Text('预算到点停止', style: TextStyle(fontSize: 11.5)),
                      Switch(
                        key: const Key('production-orchestrator-budget'),
                        value: _stopOnBudget,
                        onChanged: (bool value) {
                          setState(() => _stopOnBudget = value);
                        },
                      ),
                    ],
                  ),
                ],
              ),
              const Text(
                '主控工具只用于准备阶段参考，不参与执行期决策；间隔 0 = 只靠事件驱动。',
                style: TextStyle(fontSize: 11, color: Colors.grey),
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
          key: const Key('production-line-submit'),
          onPressed: _loading ? null : _submit,
          child: Text(_editing ? '保存' : '创建'),
        ),
      ],
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    ),
  );

  /// 一张角色卡：模型下拉 + 该角色允许的工具 chips（+ 专家开关）。
  Widget _roleCard(_RoleDef role) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Set<String> allowed =
        _roleAllowedTools[role.key] ?? const <String>{};
    final Set<String> selected = _roleTools[role.key] ?? <String>{};
    final List<String> dropped = _droppedTools[role.key] ?? const <String>[];
    return Container(
      key: Key('production-line-role-${role.key}'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                role.label,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (role.key == 'expert') ...<Widget>[
                const Spacer(),
                Text(
                  '启用',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
                Switch(
                  key: const Key('production-line-expert-enabled'),
                  value: _expertEnabled,
                  onChanged: (bool value) {
                    setState(() => _expertEnabled = value);
                  },
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          _modelDropdown(role),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 2,
            children: <Widget>[
              for (final (String tool, String label) in _toolDefs)
                if (allowed.contains(tool))
                  FilterChip(
                    key: Key('production-line-tool-${role.key}-$tool'),
                    label: Text(label, style: const TextStyle(fontSize: 12)),
                    selected: selected.contains(tool),
                    visualDensity: VisualDensity.compact,
                    onSelected: (bool value) {
                      setState(() {
                        final Set<String> next = _roleTools.putIfAbsent(
                          role.key,
                          () => <String>{},
                        );
                        if (value) {
                          next.add(tool);
                        } else {
                          next.remove(tool);
                        }
                      });
                    },
                  ),
            ],
          ),
          if (role.key == 'orchestrator')
            Text(
              '仅准备阶段参考，不参与执行决策',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          if (dropped.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              '已忽略非本角色允许的工具：${dropped.join('、')}（保存后剔除）',
              style: TextStyle(fontSize: 11, color: cs.error),
            ),
          ],
          if (role.key == 'expert' && _expertEnabled) ...<Widget>[
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                Text(
                  '单任务上限',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
                const SizedBox(width: 8),
                DropdownButton<int>(
                  key: const Key('production-line-expert-max'),
                  value: _expertMax,
                  isDense: true,
                  items: <DropdownMenuItem<int>>[
                    for (int i = 1; i <= 5; i++)
                      DropdownMenuItem<int>(
                        value: i,
                        child: Text('$i', style: const TextStyle(fontSize: 12)),
                      ),
                  ],
                  onChanged: (int? value) {
                    if (value == null) return;
                    setState(() => _expertMax = value);
                  },
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _modelDropdown(_RoleDef role) {
    final String current = (_roleModels[role.key] ?? '').trim();
    final List<String> options = <String>[
      for (final Map<String, dynamic> model in _models) modelKeyOf(model),
    ];
    final bool invalid = current.isNotEmpty && !options.contains(current);
    if (options.isEmpty && !invalid) {
      return Text(
        '模型池里没有 chat 模型：请先到「设置 → 模型池」新增',
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.error,
        ),
      );
    }
    return DropdownButtonFormField<String>(
      key: ValueKey<String>('role-${role.key}-$current'),
      initialValue: current.isEmpty ? null : current,
      isExpanded: true,
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
      ),
      items: <DropdownMenuItem<String>>[
        for (final String id in options)
          DropdownMenuItem<String>(
            value: id,
            child: Text(id, overflow: TextOverflow.ellipsis),
          ),
        // 存量产线的模型已被删除 / 不在池里：如实标失效，不静默替换。
        if (invalid)
          DropdownMenuItem<String>(
            value: current,
            child: Text(
              '$current（已失效）',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
      onChanged: (String? value) {
        if (value == null) return;
        setState(() => _roleModels[role.key] = value);
      },
    );
  }
}

class _LoadingLine extends StatelessWidget {
  const _LoadingLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 8),
        Text(text, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}
