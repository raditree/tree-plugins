import '../util/ids.dart';

/// 消息类型（recon §3.2 / §3.3）。
///
/// - [systemMessage]：**系统通道**，进模型上下文时是 `system` 角色，与钉住的
///   系统提示词分开（不改那一串字节）；
/// - [commonMessage]：普通对话消息，进上下文时是 `user` 角色。
///
/// 注意与 [AgentNotice]（UI 过程提示、`llm_hidden`）区分：后者根本不进模型上下文，
/// 不是本消息机的一条消息。
enum MessageType {
  systemMessage('system_message'),
  commonMessage('common_message');

  const MessageType(this.wire);

  /// 线上/落盘字符串。
  final String wire;

  /// 宽容解析（无法识别返回 null，由调用方给出可读错误）。
  static MessageType? tryParse(Object? raw) {
    final String value = (raw ?? '').toString().trim();
    for (final MessageType type in MessageType.values) {
      if (type.wire == value) return type;
    }
    return null;
  }
}

/// 消息子类型（recon §3.3）。
///
/// [tip] 只补上下文、**不唤醒 loop**；[task] 会启动一轮生成。
enum MessageSubtype {
  tip('tip'),
  task('task');

  const MessageSubtype(this.wire);

  /// 线上/落盘字符串。
  final String wire;

  /// 宽容解析（无法识别返回 null）。
  static MessageSubtype? tryParse(Object? raw) {
    final String value = (raw ?? '').toString().trim();
    for (final MessageSubtype subtype in MessageSubtype.values) {
      if (subtype.wire == value) return subtype;
    }
    return null;
  }
}

/// 注入模式（recon §3.3 / C11）。
///
/// [direct] 优先，在下一个可插入点注入；[queue] 等当前 loop 结束、逐条排空。
enum InjectMode {
  direct('direct'),
  queue('queue');

  const InjectMode(this.wire);

  /// 线上/落盘字符串。
  final String wire;

  /// 宽容解析（无法识别返回 null）。
  static InjectMode? tryParse(Object? raw) {
    final String value = (raw ?? '').toString().trim();
    for (final InjectMode mode in InjectMode.values) {
      if (mode.wire == value) return mode;
    }
    return null;
  }
}

/// 特殊来源 / 保留坐标（recon §3.4）。
///
/// 这些是**虚拟身份**：只能作为来源，不能作为目标（不为它们建 Agent 实例，
/// 也不让它们跑 loop）。
abstract final class MessageSources {
  /// 特殊来源固定使用的 team_id。
  static const String innerTeam = 'inner';

  /// 特殊来源固定使用的 session_id。
  static const String mainSession = 'main';

  /// 用户（界面）。
  static const String user = 'user';

  /// 内部系统（系统提示 / 编排插件注入）。
  static const String system = 'system';

  /// 其他插件来源的前缀；完整 id 形如 `plugin_tree.agent`。
  static const String pluginPrefix = 'plugin_';

  /// 是否为特殊来源身份（保留字）。
  static bool isSpecialAgentId(String id) =>
      id == user || id == system || id.startsWith(pluginPrefix);

  /// 是否为保留 team（真实团队不允许取它）。
  static bool isReservedTeamId(String id) => id == innerTeam;

  /// 是否为保留 session（真实会话不允许取它）。
  static bool isReservedSessionId(String id) => id == mainSession;
}

/// 信封来源坐标。
class MessageSource {
  const MessageSource({
    required this.teamId,
    required this.agentId,
    required this.sessionId,
  });

  /// 来源团队（特殊来源固定 `inner`；真实 agent 用真实归属）。
  final String teamId;

  /// 来源 agent（`user` / `system` / `plugin_<id>` / 真实 agent id）。
  final String agentId;

  /// 来源会话（特殊来源固定 `main`；真实 agent 用真实会话）。
  final String sessionId;

  bool get isInner => teamId == MessageSources.innerTeam;

  bool get isUser => agentId == MessageSources.user;

  bool get isSystem => agentId == MessageSources.system;

  bool get isPlugin => agentId.startsWith(MessageSources.pluginPrefix);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'team_id': teamId,
    'agent_id': agentId,
    'session_id': sessionId,
  };
}

/// 消息信封（recon §3.1）。
///
/// 这是**校验后的**入站消息形状：`type / subtype / inject_mode / source / target`
/// 全部已经收敛成枚举与非空坐标；发起者给的原始帧只在这里读一次。
class MessageEnvelope {
  const MessageEnvelope({
    required this.messageId,
    required this.type,
    required this.subtype,
    required this.injectMode,
    required this.source,
    required this.targetAgentId,
    required this.targetSessionId,
    required this.content,
    required this.attachments,
    required this.createdAt,
    this.generatedId = false,
  });

  /// 幂等键（历史去重看它）。
  final String messageId;

  /// 是否由本机补生成的 id（true = 发起者没给，不做历史去重）。
  final bool generatedId;

  final MessageType type;
  final MessageSubtype subtype;
  final InjectMode injectMode;
  final MessageSource source;

  /// 目标 agent（必须是真实 agent，不接受特殊来源 id）。
  final String targetAgentId;

  /// 目标会话；空串 = 由消息机解析（新建或默认会话）。
  final String targetSessionId;

  final String content;
  final List<dynamic> attachments;
  final int createdAt;

  bool get isTip => subtype == MessageSubtype.tip;

  bool get isTask => subtype == MessageSubtype.task;

  bool get isSystemMessage => type == MessageType.systemMessage;

  /// 进模型上下文时的角色（C4：`system_message` 走 system 通道）。
  String get llmRole => isSystemMessage ? 'system' : 'user';

  /// 是否需要唤醒 loop（tip 永不唤醒）。
  bool get wakesLoop => isTask;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'message_id': messageId,
    'type': type.wire,
    'subtype': subtype.wire,
    'inject_mode': injectMode.wire,
    'source': source.toJson(),
    'target': <String, dynamic>{
      'agent_id': targetAgentId,
      'session_id': targetSessionId,
    },
    'content': content,
    'attachments': attachments,
    'created_at': createdAt,
  };

  /// 校验并构造信封。
  ///
  /// 兼容两种输入形态：
  /// - 嵌套信封（`source` / `target` 是对象，recon §3.1 的目标形状）；
  /// - 旧式扁平字段（`agent_id` / `session_id` / `message_type` / `inject_mode` …）。
  ///
  /// **缺省值**（不影响老客户端）：`type=common_message`、`subtype=task`、
  /// `inject_mode=direct`、`source=inner/user/main`。**显式给了非法值一律拒绝**，
  /// 不做"猜一个最像的"。
  ///
  /// [newMessageId] 是缺省 id 生成器（便于测试固定）；null = [CoreIds.message]。
  static MessageEnvelope parse(
    Map<String, dynamic> raw, {
    String Function()? newMessageId,
  }) {
    final Map<String, dynamic> sourceMap = _mapOf(raw['source']);
    final Map<String, dynamic> targetMap = _mapOf(raw['target']);

    final String rawId = _text(raw['message_id'] ?? raw['id']);
    final bool generatedId = rawId.isEmpty;
    final String messageId = generatedId
        ? (newMessageId ?? CoreIds.message)()
        : rawId;

    final MessageType type = _parseType(
      raw['type'] ?? raw['message_type'],
    );
    final MessageSubtype subtype = _parseSubtype(
      raw['subtype'] ?? raw['message_subtype'],
    );
    final InjectMode injectMode = _parseInjectMode(
      raw['inject_mode'] ?? raw['injectMode'],
    );

    final String sourceTeam = _firstNonEmpty(<Object?>[
      sourceMap['team_id'],
      raw['source_team_id'],
      MessageSources.innerTeam,
    ]);
    final String sourceAgent = _firstNonEmpty(<Object?>[
      sourceMap['agent_id'],
      raw['source_agent_id'],
      MessageSources.user,
    ]);
    final String rawSourceSession = _firstNonEmpty(<Object?>[
      sourceMap['session_id'],
      raw['source_session_id'],
    ]);
    // 特殊来源固定 `main`；真实来源不推断（不知道就留空，校验不要求它有值）。
    final String sourceSession = rawSourceSession.isNotEmpty
        ? rawSourceSession
        : (sourceTeam == MessageSources.innerTeam
              ? MessageSources.mainSession
              : '');

    final String targetAgent = _firstNonEmpty(<Object?>[
      targetMap['agent_id'],
      raw['agent_id'],
    ]);
    final String targetSession = _firstNonEmpty(<Object?>[
      targetMap['session_id'],
      raw['session_id'],
    ]);

    // ── 目标校验：特殊身份不能当收件人 ────────────────────────────────
    if (targetAgent.isEmpty) {
      throw const MessageEnvelopeException('缺少目标 agent（target.agent_id）');
    }
    if (MessageSources.isSpecialAgentId(targetAgent) ||
        MessageSources.isReservedTeamId(targetAgent)) {
      throw MessageEnvelopeException(
        '目标不能是特殊来源/保留身份：$targetAgent'
        '（user / system / plugin_* / inner 只能作为来源）',
      );
    }
    if (MessageSources.isReservedSessionId(targetSession)) {
      throw MessageEnvelopeException(
        '目标会话不能是保留坐标 ${MessageSources.mainSession}'
        '（main 只用于特殊来源）',
      );
    }

    // ── 来源校验：inner 只配特殊身份 + main ───────────────────────────
    if (sourceTeam == MessageSources.innerTeam) {
      if (!MessageSources.isSpecialAgentId(sourceAgent)) {
        throw MessageEnvelopeException(
          '来源 team=${MessageSources.innerTeam} 时，来源 agent 必须是 '
          '${MessageSources.user} / ${MessageSources.system} / '
          '${MessageSources.pluginPrefix}<id>（收到 $sourceAgent）',
        );
      }
      if (sourceSession != MessageSources.mainSession) {
        throw MessageEnvelopeException(
          '来源 team=${MessageSources.innerTeam} 时，来源会话必须是 '
          '${MessageSources.mainSession}（收到 $sourceSession）',
        );
      }
    } else {
      if (sourceAgent.isEmpty || MessageSources.isSpecialAgentId(sourceAgent)) {
        throw MessageEnvelopeException(
          '真实团队来源必须是真实 agent id（收到 $sourceAgent）',
        );
      }
      if (MessageSources.isReservedTeamId(sourceTeam)) {
        throw MessageEnvelopeException(
          '来源团队不能是保留坐标 ${MessageSources.innerTeam}',
        );
      }
      if (MessageSources.isReservedSessionId(sourceSession)) {
        throw MessageEnvelopeException(
          '真实来源会话不能是保留坐标 ${MessageSources.mainSession}',
        );
      }
    }

    final Object? rawAttachments = raw['attachments'];
    final List<dynamic> attachments = rawAttachments is List
        ? List<dynamic>.from(rawAttachments)
        : const <dynamic>[];
    final int createdAt = (raw['created_at'] as num?)?.toInt() ?? 0;

    return MessageEnvelope(
      messageId: messageId,
      generatedId: generatedId,
      type: type,
      subtype: subtype,
      injectMode: injectMode,
      source: MessageSource(
        teamId: sourceTeam,
        agentId: sourceAgent,
        sessionId: sourceSession,
      ),
      targetAgentId: targetAgent,
      targetSessionId: targetSession,
      content: (raw['content'] ?? '').toString(),
      attachments: attachments,
      createdAt: createdAt,
    );
  }

  static MessageType _parseType(Object? raw) {
    final String value = (raw ?? '').toString().trim();
    if (value.isEmpty) return MessageType.commonMessage;
    final MessageType? parsed = MessageType.tryParse(value);
    if (parsed == null) {
      throw MessageEnvelopeException(
        '非法 type：$value（只接受 ${_wireList(MessageType.values.map((t) => t.wire))}）',
      );
    }
    return parsed;
  }

  static MessageSubtype _parseSubtype(Object? raw) {
    final String value = (raw ?? '').toString().trim();
    if (value.isEmpty) return MessageSubtype.task;
    final MessageSubtype? parsed = MessageSubtype.tryParse(value);
    if (parsed == null) {
      throw MessageEnvelopeException(
        '非法 subtype：$value（只接受 ${_wireList(MessageSubtype.values.map((s) => s.wire))}）',
      );
    }
    return parsed;
  }

  static InjectMode _parseInjectMode(Object? raw) {
    final String value = (raw ?? '').toString().trim();
    if (value.isEmpty) return InjectMode.direct;
    final InjectMode? parsed = InjectMode.tryParse(value);
    if (parsed == null) {
      throw MessageEnvelopeException(
        '非法 inject_mode：$value（只接受 ${_wireList(InjectMode.values.map((m) => m.wire))}）',
      );
    }
    return parsed;
  }

  static Map<String, dynamic> _mapOf(Object? raw) {
    if (raw is Map) {
      return raw.map(
        (dynamic key, dynamic value) => MapEntry(key.toString(), value),
      );
    }
    return const <String, dynamic>{};
  }

  static String _text(Object? raw) => (raw ?? '').toString().trim();

  static String _firstNonEmpty(List<Object?> values) {
    for (final Object? value in values) {
      final String text = _text(value);
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  static String _wireList(Iterable<String> values) => values.join(' / ');
}

/// 信封校验失败（消息机据此拒绝并回一条可读错误）。
class MessageEnvelopeException implements Exception {
  const MessageEnvelopeException(this.message);

  /// 可读原因（直接给用户看）。
  final String message;

  @override
  String toString() => message;
}
