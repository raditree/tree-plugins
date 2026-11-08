import 'package:test/test.dart';
import 'package:tree_agent_loop/src/agent/agent_engine.dart';
import 'package:tree_agent_loop/src/store/conversation_db.dart';
import 'package:tree_agent_loop/src/store/records.dart';

/// AC-1 加法 schema：CoreMessage / CoreMessageRef / 详情 payload 的信封元数据。
///
/// 判据三条：
/// 1. 老 JSON（无新键）读出来默认空串，行为不变；
/// 2. 新字段只在非空时写，老消息一行不多键；
/// 3. 详情端点透传新键，显示层不依赖它们。
void main() {
  CoreMessage message({bool withEnvelope = true}) => CoreMessage(
    id: 'msg_local',
    agentId: 'agt',
    sessionId: 'ses_a',
    role: 'user',
    content: '你好',
    timestamp: 1000,
    sourceMessageId: withEnvelope ? 'msg_upstream_1' : '',
    messageType: withEnvelope ? 'common_message' : '',
    messageSubtype: withEnvelope ? 'task' : '',
    injectMode: withEnvelope ? 'queue' : '',
    sourceTeamId: withEnvelope ? 'inner' : '',
    sourceAgentId: withEnvelope ? 'plugin_tree.agent' : '',
    sourceSessionId: withEnvelope ? 'main' : '',
  );

  test('老 JSON 无新键：默认空串，toJson 不多键', () {
    final CoreMessage legacy = CoreMessage.fromJson(<String, dynamic>{
      'id': 'm1',
      'agent_id': 'agt',
      'session_id': 'ses_a',
      'role': 'user',
      'content': '旧消息',
      'timestamp': 1000,
    });
    expect(legacy.sourceMessageId, '');
    expect(legacy.messageType, '');
    expect(legacy.messageSubtype, '');
    expect(legacy.injectMode, '');
    expect(legacy.sourceTeamId, '');
    expect(legacy.sourceAgentId, '');
    expect(legacy.sourceSessionId, '');

    final Map<String, dynamic> json = legacy.toJson();
    expect(json.containsKey('source_message_id'), isFalse);
    expect(json.containsKey('message_type'), isFalse);
    expect(json.containsKey('message_subtype'), isFalse);
    expect(json.containsKey('inject_mode'), isFalse);
    expect(json.containsKey('source_team_id'), isFalse);
    expect(json.containsKey('source_agent_id'), isFalse);
    expect(json.containsKey('source_session_id'), isFalse);
  });

  test('新字段往返：toJson/fromJson 逐字保留', () {
    final CoreMessage original = message();
    final Map<String, dynamic> json = original.toJson();
    expect(json['source_message_id'], 'msg_upstream_1');
    expect(json['message_type'], 'common_message');
    expect(json['message_subtype'], 'task');
    expect(json['inject_mode'], 'queue');
    expect(json['source_team_id'], 'inner');
    expect(json['source_agent_id'], 'plugin_tree.agent');
    expect(json['source_session_id'], 'main');

    final CoreMessage roundTrip = CoreMessage.fromJson(json);
    expect(roundTrip.sourceMessageId, original.sourceMessageId);
    expect(roundTrip.messageType, original.messageType);
    expect(roundTrip.messageSubtype, original.messageSubtype);
    expect(roundTrip.injectMode, original.injectMode);
    expect(roundTrip.sourceTeamId, original.sourceTeamId);
    expect(roundTrip.sourceAgentId, original.sourceAgentId);
    expect(roundTrip.sourceSessionId, original.sourceSessionId);
  });

  test('CoreMessageRef：默认空串与 envelope 判据', () {
    const CoreMessageRef legacy = CoreMessageRef(
      role: 'user',
      content: '旧消息',
    );
    expect(legacy.sourceMessageId, '');
    expect(legacy.isSystemMessage, isFalse);
    expect(legacy.isTip, isFalse);
    expect(legacy.isTask, isFalse);
    expect(legacy.isQueueInject, isFalse);

    const CoreMessageRef systemTip = CoreMessageRef(
      role: 'system',
      content: '上下文提示',
      messageType: 'system_message',
      messageSubtype: 'tip',
      injectMode: 'direct',
      sourceMessageId: 'm2',
    );
    expect(systemTip.isSystemMessage, isTrue);
    expect(systemTip.isTip, isTrue);
    expect(systemTip.isTask, isFalse);
    expect(systemTip.isQueueInject, isFalse);
  });

  test('详情 payload 透传新键；空值不出现', () {
    final Map<String, dynamic> withEnvelope = detailPayloadToJson(
      message().toJson(),
    );
    expect(withEnvelope['source_message_id'], 'msg_upstream_1');
    expect(withEnvelope['message_type'], 'common_message');
    expect(withEnvelope['message_subtype'], 'task');
    expect(withEnvelope['inject_mode'], 'queue');
    expect(withEnvelope['source_team_id'], 'inner');
    expect(withEnvelope['source_agent_id'], 'plugin_tree.agent');
    expect(withEnvelope['source_session_id'], 'main');

    final Map<String, dynamic> withoutEnvelope = detailPayloadToJson(
      message(withEnvelope: false).toJson(),
    );
    expect(withoutEnvelope.containsKey('source_message_id'), isFalse);
    expect(withoutEnvelope.containsKey('message_type'), isFalse);
    expect(withoutEnvelope.containsKey('inject_mode'), isFalse);
  });
}
