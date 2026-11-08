import '../message/inbox_ledger.dart';
import '../paths.dart';

/// Agent 活动状态（AC-1 骨架；AC-2 起由消息机驱动迁移）。
enum AgentActivityState {
  idle('idle'),
  working('working');

  const AgentActivityState(this.wire);

  /// 广播/落盘字符串。
  final String wire;

  static AgentActivityState? tryParse(Object? raw) {
    final String value = (raw ?? '').toString().trim();
    for (final AgentActivityState state in AgentActivityState.values) {
      if (state.wire == value) return state;
    }
    return null;
  }
}

/// 一个 **agent 实例**的运行时骨架（AC-1）。
///
/// 它只持有「随实例存活的状态」：活动状态、按会话分区的收件箱台账、更新时间。
/// 模型/工作区/历史/名册/工具表仍是存储与服务的真值，不在这里复制一份——
/// 见 `docs/pluginization/agent-loop-restructure-recon.md` §2.1 的结论。
///
/// AC-1 只建骨架与生命周期，不改现有消息处理路径；AC-2 才把消息机接到
/// [inbox] / [markWorking] / [markIdle] 上。
class AgentInstance {
  AgentInstance({
    required this.agentId,
    required this.paths,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    _updatedAt = _now();
  }

  /// 真实 agent id（特殊来源 `user` / `system` / `plugin_*` 不建实例）。
  final String agentId;

  /// 数据根布局（收件箱路径由它推导）。
  final AgentDataPaths paths;

  final DateTime Function() _clock;

  final Map<String, MessageInbox> _inboxes = <String, MessageInbox>{};

  AgentActivityState _state = AgentActivityState.idle;
  late int _updatedAt;

  /// 当前活动状态（AC-1 默认 idle；AC-2 由消息机驱动）。
  AgentActivityState get state => _state;

  bool get isWorking => _state == AgentActivityState.working;

  /// 最近一次状态变更时间（毫秒）。
  int get updatedAt => _updatedAt;

  /// 某个会话的收件箱（懒建；同一会话复用同一实例）。
  MessageInbox inbox(String sessionId) => _inboxes.putIfAbsent(
    sessionId,
    () => MessageInbox(
      path: paths.inboxFile(agentId, sessionId),
      clock: _clock,
    ),
  );

  /// 已创建的会话收件箱（只读视图）。
  Iterable<MessageInbox> get inboxes => _inboxes.values;

  /// 进入 working（幂等；状态未变不更新时间）。
  void markWorking() => _setState(AgentActivityState.working);

  /// 进入 idle（幂等）。
  void markIdle() => _setState(AgentActivityState.idle);

  /// 等待全部收件箱写入完成。
  Future<void> flush() async {
    for (final MessageInbox inbox in _inboxes.values) {
      await inbox.flush();
    }
  }

  /// 释放实例：先 flush，再丢掉内存里的收件箱引用（文件保留）。
  Future<void> dispose() async {
    await flush();
    _inboxes.clear();
  }

  void _setState(AgentActivityState next) {
    if (_state == next) return;
    _state = next;
    _updatedAt = _now();
  }

  int _now() => _clock().millisecondsSinceEpoch;
}

/// agent 实例注册表：按 agent id 懒建、复用、统一 flush/dispose。
///
/// 线程模型：Dart 单线程，`putIfAbsent` 足够；并发消息先到 [instanceOf] 再入队。
class AgentInstanceRegistry {
  AgentInstanceRegistry({required this.paths, this.clock});

  final AgentDataPaths paths;

  /// 测试注入的时钟；null = `DateTime.now`。
  final DateTime Function()? clock;

  final Map<String, AgentInstance> _instances = <String, AgentInstance>{};

  /// 取（必要时创建）某 agent 的实例。
  AgentInstance instanceOf(String agentId) => _instances.putIfAbsent(
    agentId,
    () => AgentInstance(agentId: agentId, paths: paths, clock: clock),
  );

  /// 已存在的实例（不创建）。
  AgentInstance? existing(String agentId) => _instances[agentId];

  /// 已创建的实例（只读视图）。
  Iterable<AgentInstance> get values => _instances.values;

  int get length => _instances.length;

  /// 等待全部实例的收件箱写入完成。
  Future<void> flush() async {
    for (final AgentInstance instance in _instances.values) {
      await instance.flush();
    }
  }

  /// 释放单个 agent 的实例（agent 删除时调用；文件保留，由会话目录删除逻辑处理）。
  Future<void> dispose(String agentId) async {
    final AgentInstance? instance = _instances.remove(agentId);
    if (instance != null) await instance.dispose();
  }

  /// 释放全部实例（插件关停时调用）。
  Future<void> disposeAll() async {
    final List<AgentInstance> all = _instances.values.toList(growable: false);
    _instances.clear();
    for (final AgentInstance instance in all) {
      await instance.dispose();
    }
  }
}
