import 'dart:convert';

import '../spec/spec_service.dart';
import '../workspace/workspace_io.dart';
import 'tool_runner.dart';

/// `spec` 工具（S1）：Spec 规范域的**工具入口**。
///
/// 语义（与 Q9 的“索引注入系统提示词”互补）：
/// - `list`：列出当前工作空间里的全部规范（内置 + 自定义）与本会话已选 id，
///   方便模型在提示词索引之外核对 id / 版本；
/// - `read`：按 id 取一份规范全文（不挂 hook，适合只查一次历史决策）；
/// - `select`：选择 / 取消选择（空数组 = 取消），并在结果里**直接带全文**；
/// - `create` / `update`：沉淀、维护自定义规范（内置规范不可改）；
/// - `reset`：备份并重建 `.self/spec/`（**破坏性**：会清掉自定义规范，只应在
///   用户明确要求时调用）。
///
/// 工具层只做参数归一与结果格式化；文件与语义全部经 [SpecService] + [WorkspaceIO]，
/// 工作空间由运行时按 agent 解析（本机 / SSH 同一条执行站路径）。
abstract final class SpecTool {
  static const String name = 'spec';

  /// 动作词表（顺序稳定，直接作为 JSON Schema 的 enum）。
  static const List<String> actions = <String>[
    'list',
    'read',
    'select',
    'create',
    'update',
    'reset',
  ];

  /// tree.agent 自建 `agent_tools` 执行站命令（extra-tools 等插件经站调用）。
  ///
  /// 与 [actions] 一一对应；命令名是“域 + 动作”，参数与工具参数同形。
  static const List<String> stationCommands = <String>[
    'spec.list',
    'spec.read',
    'spec.select',
    'spec.create',
    'spec.update',
    'spec.reset',
  ];

  /// 模型面向的工具声明。
  static ToolSpec spec() => ToolSpec(
    name: name,
    description:
        '[规范-Spec 域] 把任务经验沉淀为可复用规范，并在开工前挂上。\n'
        '**何时用：几乎没有例外**——开工第一步就按系统提示词里的 Spec 索引判型并 select；'
        '会改动文件或需要多步执行的任务不允许跳过（“先探索再说”也不行，探索前就该挂好），'
        '只有纯问答/查资料（不改任何文件）才可以不挂。\n'
        '动作：list=核对工作空间规范清单与本会话已选；read=按 id 读原文（不挂 hook）；'
        'select=挂 hook 并**直接返回全文**（不需要先 read；空数组 = 取消全部）；'
        'create/update=沉淀、维护自定义规范（内置规范只读）；'
        'reset=先备份再重建 .self/spec/（**破坏性**，只在用户明确要求时调用）。\n'
        '边界：list/read/reset 是工作空间级；select 的 selected_spec_ids 是**会话级**；'
        'create/update 只改自定义规范，内置 id 不可 update。',
    parameters: <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'action': <String, dynamic>{
          'type': 'string',
          'description': '[规范-Spec 域] list=清单 / read=读全文 / select=挂载 / '
              'create=新建 / update=改自定义 / reset=备份重建',
          'enum': actions,
        },
        'spec_id': <String, dynamic>{
          'type': 'string',
          'description': 'read/update 的目标规范 id（create 时可省略，按 title 生成）',
        },
        'spec_ids': <String, dynamic>{
          'type': 'array',
          'items': <String, dynamic>{'type': 'string'},
          'description': 'select 的目标 id 列表；空数组 = 取消全部选择',
        },
        'title': <String, dynamic>{
          'type': 'string',
          'description': 'create 必填 / update 可改的规范标题',
        },
        'task_type': <String, dynamic>{
          'type': 'string',
          'description': '任务类型（create 默认 custom）',
        },
        'description': <String, dynamic>{
          'type': 'string',
          'description': '一句话说明这份规范解决什么问题',
        },
        'classification': <String, dynamic>{
          'type': 'string',
          'description': '分类（默认“内部规范”）',
        },
        'risk': <String, dynamic>{
          'type': 'string',
          'description': '风险等级（默认 low）',
        },
        'when': <String, dynamic>{
          'type': 'array',
          'items': <String, dynamic>{'type': 'string'},
          'description': '适用条件（逐条）',
        },
        'workflow': <String, dynamic>{
          'type': 'string',
          'description': 'create/update 的工作流正文',
        },
        'rules': <String, dynamic>{
          'type': 'string',
          'description': 'create/update 的该类任务规范正文',
        },
        'notes': <String, dynamic>{
          'type': 'string',
          'description': 'create/update 的注意事项正文',
        },
      },
      'required': <String>['action'],
    },
  );

  /// 执行一次工具调用（工具层入口）。
  ///
  /// [io] 为 null（执行站未接线 / SSH 配置不完整）时显式报错，绝不假装成功。
  static Future<ToolOutcome> run(
    ToolInvocation invocation,
    SpecService service,
    WorkspaceIO? io,
  ) async {
    if (io == null) {
      return const ToolOutcome(
        '工作空间不可用（未接线 / SSH 配置不完整），无法执行 spec 工具',
        isError: true,
      );
    }
    try {
      final Map<String, dynamic> result = await runAction(
        service: service,
        io: io,
        invocation: invocation,
      );
      return ToolOutcome(
        const JsonEncoder.withIndent('  ').convert(result),
        isError: result.containsKey('error'),
      );
    } catch (error) {
      return ToolOutcome('spec 工具执行失败：$error', isError: true);
    }
  }

  /// 执行一个动作并返回结构化结果（工具层与 agent_tools 执行站共用）。
  ///
  /// [action] 为 null 时取 `arguments['action']`；执行站命令会显式传命令后缀。
  /// 返回 Map 里带 `error` 表示业务失败（不是异常）。
  static Future<Map<String, dynamic>> runAction({
    required SpecService service,
    required WorkspaceIO io,
    required ToolInvocation invocation,
    String? action,
  }) async {
    final String verb = (action ?? invocation.arguments['action'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    switch (verb) {
      case 'list':
        final List<SpecDocument> documents = await service.index(
          invocation.agentId,
          io,
        );
        final List<String> selected =
            service.store
                .session(invocation.agentId, invocation.sessionId)
                ?.selectedSpecIds ??
            const <String>[];
        return <String, dynamic>{
          'action': 'list',
          'spec_dir': SpecService.specDir,
          'session_id': invocation.sessionId,
          'count': documents.length,
          'specs': <Map<String, dynamic>>[
            for (final SpecDocument document in documents)
              document.toMetaJson(),
          ],
          'selected_spec_ids': selected,
        };
      case 'read':
        final String id =
            (invocation.arguments['spec_id'] ?? invocation.arguments['id'] ?? '')
                .toString()
                .trim();
        if (id.isEmpty) {
          return <String, dynamic>{'error': 'read 需要 spec_id'};
        }
        final SpecDocument? document = await service.detail(
          invocation.agentId,
          io,
          id,
        );
        if (document == null) {
          return <String, dynamic>{
            'error': 'Spec 不存在: $id（可用 spec list 查看可用 id）',
          };
        }
        return <String, dynamic>{
          'action': 'read',
          'spec': document.toMetaJson(),
          'content': document.raw,
        };
      case 'reset':
        final Map<String, dynamic> reset = await service.reset(io);
        // reset 会重建内置副本：索引与已选全文快照都要跟着热一次。
        await service.refreshIndex(invocation.agentId, io);
        await service.refreshSelectedSpecs(
          invocation.agentId,
          invocation.sessionId,
          io,
        );
        return <String, dynamic>{'action': 'reset', ...reset};
      case 'select':
      case 'create':
      case 'update':
        // 既有 Q9 语义（选择 / 沉淀 / 维护）全部复用 SpecService.run。
        final Map<String, dynamic> arguments = <String, dynamic>{
          ...invocation.arguments,
          'action': verb,
        };
        return service.run(
          ToolInvocation(
            id: invocation.id,
            name: invocation.name,
            arguments: arguments,
            agentId: invocation.agentId,
            sessionId: invocation.sessionId,
            rawArguments: invocation.rawArguments,
          ),
          io,
        );
      default:
        return <String, dynamic>{
          'error': '未知 spec 动作: ${verb.isEmpty ? '(空)' : verb}'
              '（支持 ${actions.join(' / ')}）',
        };
    }
  }
}
