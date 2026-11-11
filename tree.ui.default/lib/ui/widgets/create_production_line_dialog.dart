import 'package:flutter/material.dart';

import '../../io/api_service.dart';
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
  });

  final String name;
  final String workspace;

  /// `{agent_id, team_id}`；新建且没选执行 Agent 时为 null（不下发）。
  final Map<String, dynamic>? executor;

  /// 四个角色槽位（model_id + tools；专家保留 enabled / max_per_task）。
  final Map<String, dynamic> roles;
}

class _RoleDef {
  const _RoleDef(this.key, this.label, this.defaultModel, this.defaultTools);

  final String key;
  final String label;
  final String defaultModel;
  final List<String> defaultTools;
}

const List<_RoleDef> _roleDefs = <_RoleDef>[
  _RoleDef('orchestrator', '主控', 'lfm3', <String>['read', 'grep', 'message']),
  _RoleDef(
    'packer',
    '打包',
    'lfm3',
    <String>['read', 'list', 'grep', 'terminal', 'message'],
  ),
  _RoleDef(
    'executor',
    '执行',
    'lfm3',
    <String>['read', 'write', 'edit', 'terminal', 'message', 'spec'],
  ),
  _RoleDef('expert', '专家', 'lfm3', <String>['read', 'grep']),
];

/// 执行模型可勾选的工具（§6.4 工具分组）。
const List<(String, String)> _executorToolDefs = <(String, String)>[
  ('read', '读文件'),
  ('list', '列目录'),
  ('grep', '搜索'),
  ('write', '写文件'),
  ('edit', '编辑'),
  ('terminal', '命令'),
  ('message', '协作'),
  ('spec', '规范'),
];

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
  final Set<String> _tools = <String>{};

  bool get _editing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final Map<String, dynamic> roles = productionMap(widget.initial?['roles']);
    for (final _RoleDef role in _roles) {
      final Object? raw = roles[role.key];
      final Map<String, dynamic> data = productionMap(raw);
      final String model = '${data['model_id'] ?? ''}'.trim();
      _roleModels[role.key] = model.isEmpty ? role.defaultModel : model;
      if (role.key == 'executor') {
        final List<dynamic> tools =
            data['tools'] as List<dynamic>? ?? role.defaultTools;
        _tools.addAll(tools.map((dynamic item) => '$item'));
      }
    }
    final Map<String, dynamic> executor = productionMap(
      widget.initial?['executor'],
    );
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

  void _submit() {
    final String name = _name.text.trim();
    if (name.isEmpty) {
      _toast('请填写产线名称');
      return;
    }
    if (!_tools.contains('write') && !_tools.contains('edit')) {
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
      final List<dynamic> tools =
          existing['tools'] as List<dynamic>? ?? role.defaultTools;
      roles[role.key] = <String, dynamic>{
        if (role.key == 'expert') ...<String, dynamic>{
          'enabled': existing['enabled'] ?? false,
          'max_per_task': existing['max_per_task'] ?? 3,
        },
        ...existing,
        'model_id': _roleModels[role.key] ?? role.defaultModel,
        'tools': role.key == 'executor'
            ? (_tools.toList()..sort())
            : List<dynamic>.of(tools),
      };
    }
    return roles;
  }

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
              _label('角色与模型'),
              const SizedBox(height: 6),
              for (int i = 0; i < _roles.length; i += 2) ...<Widget>[
                Row(
                  children: <Widget>[
                    Expanded(child: _modelField(_roles[i])),
                    const SizedBox(width: 10),
                    Expanded(
                      child: i + 1 < _roles.length
                          ? _modelField(_roles[i + 1])
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
                if (i + 2 < _roles.length) const SizedBox(height: 10),
              ],
              const SizedBox(height: 14),
              _label('执行工具'),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 2,
                children: <Widget>[
                  for (final (String tool, String label) in _executorToolDefs)
                    FilterChip(
                      key: Key('production-line-tool-$tool'),
                      label: Text(label, style: const TextStyle(fontSize: 12)),
                      selected: _tools.contains(tool),
                      visualDensity: VisualDensity.compact,
                      onSelected: (bool selected) {
                        setState(() {
                          if (selected) {
                            _tools.add(tool);
                          } else {
                            _tools.remove(tool);
                          }
                        });
                      },
                    ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                '写文件 / 编辑至少勾一个，否则执行模型无法落地',
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

  Widget _modelField(_RoleDef role) {
    final String current = _roleModels[role.key] ?? role.defaultModel;
    final Set<String> options = <String>{
      for (final Map<String, dynamic> model in _models)
        '${model['model_id'] ?? ''}',
      current,
    }..remove('');
    if (options.isEmpty) options.add(role.defaultModel);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(role.label, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 4),
        DropdownButtonFormField<String>(
          key: ValueKey<String>('role-${role.key}-$current'),
          initialValue: current,
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
          ],
          onChanged: (String? value) {
            if (value == null) return;
            setState(() => _roleModels[role.key] = value);
          },
        ),
      ],
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
