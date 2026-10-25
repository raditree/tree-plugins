import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_agent_loop/src/agent/agent_engine.dart';
import 'package:tree_agent_loop/src/agent/question_store.dart';
import 'package:tree_agent_loop/src/delegate.dart';
import 'package:tree_agent_loop/src/paths.dart';
import 'package:tree_agent_loop/src/runtime/agent_runtime.dart';
import 'package:tree_agent_loop/src/store/file_store.dart';
import 'package:tree_agent_loop/src/store/records.dart';
import 'package:tree_agent_loop/src/store/tree_paths.dart';
import 'package:tree_agent_loop/src/tool/question_channel.dart';

/// G-1 四条 agent 路由（POST / PATCH / DELETE / transcript）的委派层测试。
///
/// 直接走 `api/delegate` 的同一个分发函数：状态码 / 错误体 / 落盘副作用都按
/// `docs/pluginization/agent_api_contract.md` 的 §1.1 #2/#4/#5/#9 断言。
void main() {
  late Directory temp;
  late AgentDataPaths paths;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tree_agent_delegate_');
    paths = AgentDataPaths(temp.path);
    _writeModels(paths);
    await AgentRuntime.debugCloseAll();
  });

  tearDown(() async {
    await AgentRuntime.debugCloseAll();
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {
      // Windows 偶发占用：临时目录交给系统清理。
    }
  });

  group('POST /api/agents', () {
    test('必填 / 模型校验与 500 类型口径', () async {
      _expectError(
        await _call('POST', '/api/agents', paths, body: <String, dynamic>{}),
        400,
        'name 不能为空',
      );
      _expectError(
        await _call(
          'POST',
          '/api/agents',
          paths,
          body: <String, dynamic>{'name': '   '},
        ),
        400,
        'name 不能为空',
      );
      _expectError(
        await _call(
          'POST',
          '/api/agents',
          paths,
          body: <String, dynamic>{'name': '夹具'},
        ),
        400,
        'model_id 不能为空',
      );
      _expectError(
        await _call(
          'POST',
          '/api/agents',
          paths,
          body: <String, dynamic>{'name': '夹具', 'model_id': 'nope'},
        ),
        400,
        '模型不存在：nope',
      );
      // 类型不符：与核心一致走未捕获异常 ⇒ 500（不是 400）。
      final Map<String, dynamic> badType = await _call(
        'POST',
        '/api/agents',
        paths,
        body: <String, dynamic>{'name': 123, 'model_id': 'm1'},
      );
      expect(badType['status'], 500);
      expect(_bodyOf(badType)['detail'], contains('核心进程内部错误'));
    });

    test('创建成功：22 键 / 默认会话 / 团队字段不可指定', () async {
      final Map<String, dynamic> reply = await _call(
        'POST',
        '/api/agents',
        paths,
        body: <String, dynamic>{
          'name': '新助手',
          'model_id': 'm1',
          'system_prompt': '你是新助手',
          'team_member_count': 2,
          'max_level': 9,
          'max_members_per_level': 1000,
          // 以下都是禁区：核心创建接口不接受，必须被忽略。
          'team_id': 'agt_top',
          'parent_agent_id': 'agt_top',
          'level': 2,
          'role': '成员',
          'review_status': 'approved',
        },
      );
      expect(reply['status'], 200);
      final Map<String, dynamic> body = _bodyOf(reply);
      expect(body['success'], true);
      final Map<String, dynamic> agent =
          (body['agent'] as Map).cast<String, dynamic>();
      final String id = agent['id'] as String;
      expect(id, startsWith('agt_'));
      expect(agent['name'], '新助手');
      expect(agent['type'], 'normal');
      expect(agent['system_prompt'], '你是新助手');
      expect(agent['model_id'], 'm1');
      expect(agent['workspace_id'], 'ws_$id');
      expect(agent['workspace_dir'], '');
      expect(agent['has_ssh'], false);
      expect(agent['last_message'], '');
      expect(agent['last_message_time'], isNull);
      expect(agent['unread_count'], 0);
      expect(agent['avatar_url'], isNull);
      expect(agent['pending_member_count'], 0);
      expect(agent['team_id'], '');
      expect(agent['parent_agent_id'], '');
      expect(agent['level'], 0);
      expect(agent['role'], '');
      expect(agent['duty'], '');
      expect(agent['can_lead_team'], true);
      expect(agent['review_status'], '');
      expect(agent['created_at'], isA<int>());
      expect(agent['updated_at'], isA<int>());

      // 默认会话：契约要求 create 建 `session_default`（并落盘）。
      expect(
        File(paths.sessionMetaFile(id, 'session_default')).existsSync(),
        isTrue,
      );
      final Map<String, dynamic> sessions = _bodyOf(
        await _call(
          'GET',
          '/api/agents/$id/sessions',
          paths,
          params: <String, String>{'agentId': id},
        ),
      );
      expect(
        (sessions['sessions'] as List<dynamic>)
            .map((dynamic s) => (s as Map)['session_id']),
        contains('session_default'),
      );
    });
  });

  group('PATCH /api/agents/{agentId}', () {
    test('404 / 禁区 / 字段级校验', () async {
      // 先落夹具再起运行时：插件进程内 store 的 agent 扫描只做一次（单写者形态）。
      await _seedAgent(paths);
      _expectError(
        await _call(
          'PATCH',
          '/api/agents/ghost',
          paths,
          params: <String, String>{'agentId': 'ghost'},
          body: <String, dynamic>{},
        ),
        404,
        'agent 不存在',
      );

      _expectError(
        await _call(
          'PATCH',
          '/api/agents/agt',
          paths,
          params: <String, String>{'agentId': 'agt'},
          body: <String, dynamic>{'model_id': 'nope'},
        ),
        400,
        '模型不存在：nope',
      );
      _expectError(
        await _call(
          'PATCH',
          '/api/agents/agt',
          paths,
          params: <String, String>{'agentId': 'agt'},
          body: <String, dynamic>{'workspace_dir': 'relative/dir'},
        ),
        400,
        'workspace_dir 必须是绝对路径或空串（空 = 用默认工作空间）',
      );
      _expectError(
        await _call(
          'PATCH',
          '/api/agents/agt',
          paths,
          params: <String, String>{'agentId': 'agt'},
          body: <String, dynamic>{'ssh': 5},
        ),
        400,
        'ssh 必须是对象或 null',
      );
      _expectError(
        await _call(
          'PATCH',
          '/api/agents/agt',
          paths,
          params: <String, String>{'agentId': 'agt'},
          body: <String, dynamic>{
            'ssh': <String, dynamic>{'host': ''},
          },
        ),
        400,
        'ssh.host 不能为空',
      );
      _expectError(
        await _call(
          'PATCH',
          '/api/agents/agt',
          paths,
          params: <String, String>{'agentId': 'agt'},
          body: <String, dynamic>{
            'ssh': <String, dynamic>{'host': '10.0.0.5'},
          },
        ),
        400,
        'SSH 需要 password 或 key_path 之一',
      );
      _expectError(
        await _call(
          'PATCH',
          '/api/agents/agt',
          paths,
          params: <String, String>{'agentId': 'agt'},
          body: <String, dynamic>{'max_seqlen': 0},
        ),
        400,
        'max_seqlen 必须为正整数，或 null 清除该项覆盖',
      );
      _expectError(
        await _call(
          'PATCH',
          '/api/agents/agt',
          paths,
          params: <String, String>{'agentId': 'agt'},
          body: <String, dynamic>{'max_output_tokens': -1},
        ),
        400,
        'max_output_tokens 必须为正整数，或 null 清除该项覆盖',
      );
      _expectError(
        await _call(
          'PATCH',
          '/api/agents/agt',
          paths,
          params: <String, String>{'agentId': 'agt'},
          body: <String, dynamic>{'compress_threshold': 0.05},
        ),
        400,
        'compress_threshold 必须在 0.1~0.95 之间，或 null 清除该项覆盖',
      );
      _expectError(
        await _call(
          'PATCH',
          '/api/agents/agt',
          paths,
          params: <String, String>{'agentId': 'agt'},
          body: <String, dynamic>{'thinking': 'yes'},
        ),
        400,
        'thinking 必须是 true / false，或 null 清除该项覆盖',
      );

      // 空 body：200，但仍重写 yaml 并 bump updated_at。
      final Map<String, dynamic> empty = await _call(
        'PATCH',
        '/api/agents/agt',
        paths,
        params: <String, String>{'agentId': 'agt'},
        body: <String, dynamic>{},
      );
      expect(empty['status'], 200);
      final Map<String, dynamic> emptyAgent =
          (_bodyOf(empty)['agent'] as Map).cast<String, dynamic>();
      expect(emptyAgent['name'], '旧名');
      expect(emptyAgent['updated_at'] as int, greaterThan(1));
    });

    test('更新成功：禁区不变 / SSH 脱敏 / 覆盖项 / 清除 / 镜像', () async {
      await _seedAgent(paths);
      final String dir = p.join(temp.path, '项目目录');
      final Map<String, dynamic> reply = await _call(
        'PATCH',
        '/api/agents/agt',
        paths,
        params: <String, String>{'agentId': 'agt'},
        body: <String, dynamic>{
          'name': '新名',
          'team_id': 'agt_top',
          'parent_agent_id': 'agt_top',
          'level': 9,
          'role': '成员',
          'review_status': 'approved',
          'system_prompt': '新提示',
          'model_id': 'm2',
          'workspace_dir': dir,
          'ssh': <String, dynamic>{
            'host': '10.0.0.5',
            'port': 2222,
            'username': 'dev',
            'password': 'secret',
            'root': '/srv/app',
          },
          'reasoning_effort': 'high',
          'max_seqlen': 64000,
          'max_output_tokens': 8192,
          'compress_threshold': 0.8,
          'thinking': true,
        },
      );
      expect(reply['status'], 200);
      final Map<String, dynamic> body = _bodyOf(reply);
      expect(body['success'], true);
      final Map<String, dynamic> agent =
          (body['agent'] as Map).cast<String, dynamic>();
      expect(agent['name'], '旧名', reason: 'PATCH 不能改 name');
      expect(agent['team_id'], '', reason: 'PATCH 不能改 team_id');
      expect(agent['parent_agent_id'], '');
      expect(agent['level'], 0);
      expect(agent['role'], '');
      expect(agent['review_status'], '');
      expect(agent['system_prompt'], '新提示');
      expect(agent['model_id'], 'm2');
      expect(agent['workspace_dir'], dir);
      expect(agent['has_ssh'], true);
      final Map<String, dynamic> ssh =
          (body['ssh'] as Map).cast<String, dynamic>();
      expect(ssh, <String, dynamic>{
        'host': '10.0.0.5',
        'port': 2222,
        'username': 'dev',
        'auth': 'password',
        'root': '/srv/app',
      });
      expect(ssh.containsKey('password'), false);
      expect(ssh.containsKey('key_passphrase'), false);

      final FileTreeStore store = FileTreeStore(TreePaths(temp.path));
      final CoreAgent saved = store.agent('agt')!;
      expect(saved.name, '旧名');
      expect(saved.teamId, '');
      expect(saved.level, 0);
      expect(saved.systemPrompt, '新提示');
      expect(saved.modelId, 'm2');
      expect(saved.workspaceDir, dir);
      expect(saved.reasoningEffort, 'high');
      expect(saved.maxSeqlenOverride, 64000);
      expect(saved.maxOutputTokens, 8192);
      expect(saved.compressThreshold, 0.8);
      expect(saved.thinkingOverride, true);
      expect(saved.sshConfig?.password, 'secret');
      await store.close();

      // PATCH ssh 缺 password ⇒ 保留旧密码；显式空串且无 key_path ⇒ 400。
      final Map<String, dynamic> keep = await _call(
        'PATCH',
        '/api/agents/agt',
        paths,
        params: <String, String>{'agentId': 'agt'},
        body: <String, dynamic>{
          'ssh': <String, dynamic>{'host': '10.0.0.6'},
        },
      );
      expect(keep['status'], 200);
      expect(
        ((_bodyOf(keep)['ssh'] as Map)['host']),
        '10.0.0.6',
      );
      final FileTreeStore store2 = FileTreeStore(TreePaths(temp.path));
      expect(store2.agent('agt')!.sshConfig?.password, 'secret');
      await store2.close();
      _expectError(
        await _call(
          'PATCH',
          '/api/agents/agt',
          paths,
          params: <String, String>{'agentId': 'agt'},
          body: <String, dynamic>{
            'ssh': <String, dynamic>{'host': '10.0.0.6', 'password': ''},
          },
        ),
        400,
        'SSH 需要 password 或 key_path 之一',
      );

      // clear_model_overrides：一次清空五项。
      final Map<String, dynamic> cleared = await _call(
        'PATCH',
        '/api/agents/agt',
        paths,
        params: <String, String>{'agentId': 'agt'},
        body: <String, dynamic>{'clear_model_overrides': true},
      );
      expect(cleared['status'], 200);
      final FileTreeStore store3 = FileTreeStore(TreePaths(temp.path));
      final CoreAgent afterClear = store3.agent('agt')!;
      expect(afterClear.reasoningEffort, '');
      expect(afterClear.maxSeqlenOverride, 0);
      expect(afterClear.maxOutputTokens, 0);
      expect(afterClear.compressThreshold, 0);
      expect(afterClear.thinkingOverride, isNull);
      await store3.close();

      // ssh: null 清除。
      final Map<String, dynamic> clearedSsh = await _call(
        'PATCH',
        '/api/agents/agt',
        paths,
        params: <String, String>{'agentId': 'agt'},
        body: <String, dynamic>{'ssh': null},
      );
      expect(clearedSsh['status'], 200);
      expect(_bodyOf(clearedSsh).containsKey('ssh'), false);
      expect(
        (_bodyOf(clearedSsh)['agent'] as Map)['has_ssh'],
        false,
      );
    });

    test('workspace_dir 变更把共享目录镜像给成员', () async {
      final FileTreeStore store = FileTreeStore(TreePaths(temp.path));
      final CoreAgent top = store.createAgent(name: '指挥', modelId: 'm1');
      final CoreAgent member = store.createAgent(name: '成员', modelId: 'm1')
        ..teamId = top.id
        ..parentAgentId = top.id
        ..level = 1;
      store.putAgent(member);
      await store.flush();
      await store.close();

      final String dir = p.join(temp.path, '共享目录');
      final Map<String, dynamic> reply = await _call(
        'PATCH',
        '/api/agents/${top.id}',
        paths,
        params: <String, String>{'agentId': top.id},
        body: <String, dynamic>{'workspace_dir': dir},
      );
      expect(reply['status'], 200);
      final FileTreeStore reloaded = FileTreeStore(TreePaths(temp.path));
      expect(reloaded.agent(top.id)!.workspaceDir, dir);
      expect(reloaded.agent(member.id)!.workspaceDir, dir);
      await reloaded.close();
    });
  });

  group('DELETE /api/agents/{agentId}', () {
    test('404 / 未级联 409 / 叶→根级联删除', () async {
      // 先落团队夹具再起运行时：agent 扫描只做一次。
      final ({String top, String child, String grandchild}) ids =
          await _seedTeam(paths);
      _expectError(
        await _call(
          'DELETE',
          '/api/agents/ghost',
          paths,
          params: <String, String>{'agentId': 'ghost'},
        ),
        404,
        'agent 不存在',
      );
      final Map<String, dynamic> blocked = await _call(
        'DELETE',
        '/api/agents/${ids.top}',
        paths,
        params: <String, String>{'agentId': ids.top},
      );
      expect(blocked['status'], 409);
      final Map<String, dynamic> blockedBody = _bodyOf(blocked);
      expect(blockedBody['detail'], '该 agent 还有 2 个下级成员，未指定 cascade');
      expect(blockedBody['error'], blockedBody['detail']);
      expect(blockedBody['cascade_required'], <dynamic>[
        <String, dynamic>{
          'member_id': ids.child,
          'name': '成员',
          'level': 1,
          'parent_agent_id': ids.top,
        },
        <String, dynamic>{
          'member_id': ids.grandchild,
          'name': '下级',
          'level': 2,
          'parent_agent_id': ids.child,
        },
      ]);
      expect(blockedBody['hint'], isNotEmpty);

      final Map<String, dynamic> removed = await _call(
        'DELETE',
        '/api/agents/${ids.top}',
        paths,
        params: <String, String>{'agentId': ids.top},
        query: <String, String>{'cascade': '1'},
      );
      expect(removed['status'], 200);
      expect(_bodyOf(removed), <String, dynamic>{
        'success': true,
        'removed': <dynamic>[ids.grandchild, ids.child, ids.top],
        'cascade': true,
      });
      expect(File(paths.agentFile(ids.top)).existsSync(), isFalse);
      expect(File(paths.agentFile(ids.child)).existsSync(), isFalse);
      expect(File(paths.agentFile(ids.grandchild)).existsSync(), isFalse);
      expect(
        Directory(paths.agentDataDir(ids.top)).existsSync(),
        isFalse,
      );
    });

    test('删除清提问记录；questions_removed 仅 >0 时出现', () async {
      final FileTreeStore store = FileTreeStore(TreePaths(temp.path));
      store.putAgent(
        CoreAgent(
          id: 'agt',
          name: '夹具',
          createdAt: 1,
          updatedAt: 1,
          modelId: 'm1',
        ),
      );
      await store.flush();
      await store.close();
      final FileQuestionStore questions = FileQuestionStore(
        TreePaths(temp.path),
      );
      questions.add(
        QuestionRecord(
          qid: 'q1',
          agentId: 'agt',
          sessionId: 'session_default',
          question: '继续吗',
          createdAt: 1,
        ),
      );
      await questions.flush();

      final Map<String, dynamic> reply = await _call(
        'DELETE',
        '/api/agents/agt',
        paths,
        params: <String, String>{'agentId': 'agt'},
      );
      expect(reply['status'], 200);
      final Map<String, dynamic> body = _bodyOf(reply);
      expect(body['success'], true);
      expect(body['removed'], <dynamic>['agt']);
      expect(body['cascade'], false);
      expect(body['questions_removed'], 1);
      final FileQuestionStore reloaded = FileQuestionStore(
        TreePaths(temp.path),
      );
      expect(reloaded.byId('q1'), isNull);
    });

    test('运行中 409（不动数据）；空闲后可删', () async {
      final FileTreeStore store = FileTreeStore(TreePaths(temp.path));
      store.putAgent(
        CoreAgent(
          id: 'agt',
          name: '夹具',
          createdAt: 1,
          updatedAt: 1,
          modelId: 'm1',
          systemPrompt: '你是夹具',
        ),
      );
      await store.flush();
      await store.close();

      final _BlockingEngine engine = _BlockingEngine();
      final AgentRuntime runtime = AgentRuntime(paths: paths, engine: engine);
      await runtime.sendMessage(agentId: 'agt', content: '跑起来');
      for (int i = 0; i < 200 && !runtime.conversation.isRunning('agt'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(runtime.conversation.isRunning('agt'), isTrue);

      final Map<String, dynamic> busy = await _call(
        'DELETE',
        '/api/agents/agt',
        paths,
        params: <String, String>{'agentId': 'agt'},
        runtimeFor: (_) => runtime,
      );
      expect(busy['status'], 409);
      final Map<String, dynamic> busyBody = _bodyOf(busy);
      expect(busyBody['detail'], 'agent 正在运行，不能删除');
      expect(busyBody['error'], 'agent 正在运行，不能删除');
      expect(busyBody['running'], <dynamic>['agt']);
      expect(busyBody['hint'], isNotEmpty);
      expect(File(paths.agentFile('agt')).existsSync(), isTrue);

      engine.release.complete();
      await runtime.waitIdle();
      final Map<String, dynamic> after = await _call(
        'DELETE',
        '/api/agents/agt',
        paths,
        params: <String, String>{'agentId': 'agt'},
        runtimeFor: (_) => runtime,
      );
      expect(after['status'], 200);
      expect(_bodyOf(after)['removed'], <dynamic>['agt']);
    });
  });

  group('GET transcript', () {
    test('按会话名册校验归属；只返回带 subagent_id 标记的消息', () async {
      await _seedTranscript(paths);
      final Map<String, dynamic> reply = await _call(
        'GET',
        '/api/agents/agt/subagents/sub_1/transcript',
        paths,
        params: <String, String>{'agentId': 'agt', 'subagentId': 'sub_1'},
        query: <String, String>{'session_id': 'session_default'},
      );
      expect(reply['status'], 200);
      final Map<String, dynamic> body = _bodyOf(reply);
      expect(body['agent_id'], 'agt');
      expect(body['subagent_id'], 'sub_1');
      expect(body['session_id'], 'session_default');
      expect(body['total'], 2);
      final List<dynamic> messages = body['messages'] as List<dynamic>;
      expect(
        messages.map((dynamic m) => (m as Map)['id']),
        <dynamic>['s1', 's3'],
        reason: '完成报告与别的临时员工消息都不进 transcript',
      );
      final Map<String, dynamic> first =
          (messages.first as Map).cast<String, dynamic>();
      expect(first['timestamp'], '2026-10-25T10:00:01.000');
      expect(first['subagent_id'], 'sub_1');
      expect(first['subagent_name'], '临时员工');
      expect(first['subagent_parent_id'], 'agt');
      expect(first['subagent_level'], 1);
      // 缺省 session_id ⇒ 用默认会话（与契约的"可选/默认 session_default"一致）。
      final Map<String, dynamic> defaulted = _bodyOf(
        await _call(
          'GET',
          '/api/agents/agt/subagents/sub_1/transcript',
          paths,
          params: <String, String>{'agentId': 'agt', 'subagentId': 'sub_1'},
        ),
      );
      expect(defaulted['session_id'], 'session_default');
      expect(defaulted['total'], 2);
      final Map<String, dynamic> question =
          (messages.last as Map).cast<String, dynamic>();
      expect(question['kind'], 'ask_user_question');
      expect(question['answered'], true);
      expect(question['answer'], '继续');
      expect(question['answers'], <dynamic>['继续']);
      expect(question['options'], <dynamic>['A', 'B']);
      expect(question['questions'], <dynamic>[
        <String, dynamic>{
          'question': '继续吗',
          'options': <String>['A', 'B'],
        },
      ]);
    });

    test('404：agent / 临时员工 / 跨会话', () async {
      await _seedTranscript(paths);
      _expectError(
        await _call(
          'GET',
          '/api/agents/ghost/subagents/sub_1/transcript',
          paths,
          params: <String, String>{
            'agentId': 'ghost',
            'subagentId': 'sub_1',
          },
        ),
        404,
        'agent 不存在',
      );
      _expectError(
        await _call(
          'GET',
          '/api/agents/agt/subagents/sub_999/transcript',
          paths,
          params: <String, String>{
            'agentId': 'agt',
            'subagentId': 'sub_999',
          },
        ),
        404,
        '临时员工不存在：sub_999',
      );
      // 先打开 ses_old 的名册（装载），再在默认会话里查它 ⇒ 跨会话 404。
      final Map<String, dynamic> other = await _call(
        'GET',
        '/api/agents/agt/subagents/sub_2/transcript',
        paths,
        params: <String, String>{'agentId': 'agt', 'subagentId': 'sub_2'},
        query: <String, String>{'session_id': 'ses_old'},
      );
      expect(other['status'], 200);
      expect(_bodyOf(other)['total'], 1);
      final Map<String, dynamic> crossed = await _call(
        'GET',
        '/api/agents/agt/subagents/sub_2/transcript',
        paths,
        params: <String, String>{'agentId': 'agt', 'subagentId': 'sub_2'},
        query: <String, String>{'session_id': 'session_default'},
      );
      expect(crossed['status'], 404);
      expect(
        _bodyOf(crossed)['detail'],
        '临时员工「旧员工」属于会话 ses_old，不在这个会话（session_default）里'
        '——跨会话不保留是硬不变量。',
      );
    });
  });
}

/// 委派信封：与核心 → 插件实际下发的字段一致。
Future<Map<String, dynamic>> _call(
  String method,
  String path,
  AgentDataPaths paths, {
  Map<String, String> params = const <String, String>{},
  Map<String, String> query = const <String, String>{},
  Map<String, dynamic>? body,
  AgentRuntime Function(String dataDir)? runtimeFor,
}) => handleApiDelegate(
  <String, dynamic>{
    'method': method,
    'path': path,
    'params': params,
    'query': query,
    'headers': <String, dynamic>{},
    'scope': <String, dynamic>{},
    'workspace_dir': '',
    'data_dir': paths.root,
    'agent_id': params['agentId'] ?? '',
    'team_id': '',
    'request_id': 'test-$method-$path',
    'body': ?body,
  },
  runtimeFor: runtimeFor,
);

Map<String, dynamic> _bodyOf(Map<String, dynamic> reply) =>
    (jsonDecode('${reply['body'] ?? '{}'}') as Map).cast<String, dynamic>();

void _expectError(
  Map<String, dynamic> reply,
  int status,
  String detail,
) {
  expect(reply['status'], status);
  expect(_bodyOf(reply), <String, dynamic>{'detail': detail});
}

Future<void> _seedAgent(AgentDataPaths paths) async {
  final FileTreeStore store = FileTreeStore(TreePaths(paths.root));
  store.putAgent(
    CoreAgent(
      id: 'agt',
      name: '旧名',
      createdAt: 1,
      updatedAt: 1,
      modelId: 'm1',
      systemPrompt: '旧提示',
    ),
  );
  await store.flush();
  await store.close();
}

Future<({String top, String child, String grandchild})> _seedTeam(
  AgentDataPaths paths,
) async {
  final FileTreeStore store = FileTreeStore(TreePaths(paths.root));
  final CoreAgent top = store.createAgent(name: '指挥', modelId: 'm1');
  final CoreAgent child = store.createAgent(name: '成员', modelId: 'm1')
    ..teamId = top.id
    ..parentAgentId = top.id
    ..level = 1;
  store.putAgent(child);
  final CoreAgent grandchild = store.createAgent(name: '下级', modelId: 'm1')
    ..teamId = top.id
    ..parentAgentId = child.id
    ..level = 2;
  store.putAgent(grandchild);
  await store.flush();
  await store.close();
  return (top: top.id, child: child.id, grandchild: grandchild.id);
}

Future<void> _seedTranscript(AgentDataPaths paths) async {
  final FileTreeStore store = FileTreeStore(TreePaths(paths.root));
  store.putAgent(
    CoreAgent(
      id: 'agt',
      name: '夹具',
      createdAt: 1,
      updatedAt: 1,
      modelId: 'm1',
    ),
  );
  await store.flush();
  store.putSubagent(
    CoreSubagent(
      id: 'sub_1',
      name: '临时员工',
      ownerAgentId: 'agt',
      sessionId: 'session_default',
      parentId: 'agt',
      level: 1,
      createdAt: 1761360000000,
      updatedAt: 1761360000000,
      agent: CoreAgent(
        id: 'sub_1',
        name: '临时员工',
        createdAt: 1761360000000,
        updatedAt: 1761360000000,
        parentAgentId: 'agt',
      ),
    ),
  );
  store.putSubagent(
    CoreSubagent(
      id: 'sub_2',
      name: '旧员工',
      ownerAgentId: 'agt',
      sessionId: 'ses_old',
      parentId: 'agt',
      level: 1,
      createdAt: 1761360000000,
      updatedAt: 1761360000000,
      agent: CoreAgent(
        id: 'sub_2',
        name: '旧员工',
        createdAt: 1761360000000,
        updatedAt: 1761360000000,
        parentAgentId: 'agt',
      ),
    ),
  );
  store.createSession('agt', title: '旧会话', sessionId: 'ses_old');
  int at(String iso) => DateTime.parse(iso).millisecondsSinceEpoch;
  store.appendMessage(
    CoreMessage(
      id: 's1',
      agentId: 'agt',
      sessionId: 'session_default',
      role: 'agent',
      content: '整理日志',
      kind: 'text',
      timestamp: at('2026-10-25T10:00:01.000'),
      subagentId: 'sub_1',
      subagentName: '临时员工',
      subagentParentId: 'agt',
      subagentLevel: 1,
    ),
  );
  store.appendMessage(
    CoreMessage(
      id: 's2',
      agentId: 'agt',
      sessionId: 'session_default',
      role: 'agent',
      content: '完成了',
      kind: 'subagent_report',
      timestamp: at('2026-10-25T10:00:02.000'),
      subagentId: 'sub_1',
      subagentName: '临时员工',
      subagentParentId: 'agt',
      subagentLevel: 1,
    ),
  );
  store.appendMessage(
    CoreMessage(
      id: 's3',
      agentId: 'agt',
      sessionId: 'session_default',
      role: 'agent',
      content: '继续吗',
      kind: 'ask_user_question',
      timestamp: at('2026-10-25T10:00:03.000'),
      subagentId: 'sub_1',
      subagentName: '临时员工',
      subagentParentId: 'agt',
      subagentLevel: 1,
    ),
  );
  store.appendMessage(
    CoreMessage(
      id: 's4',
      agentId: 'agt',
      sessionId: 'session_default',
      role: 'agent',
      content: '别的临时员工',
      kind: 'text',
      timestamp: at('2026-10-25T10:00:04.000'),
      subagentId: 'sub_x',
    ),
  );
  store.appendMessage(
    CoreMessage(
      id: 's9',
      agentId: 'agt',
      sessionId: 'ses_old',
      role: 'agent',
      content: '旧会话里的活',
      kind: 'text',
      timestamp: at('2026-10-25T10:00:05.000'),
      subagentId: 'sub_2',
      subagentName: '旧员工',
      subagentParentId: 'agt',
      subagentLevel: 1,
    ),
  );
  await store.flush();
  await store.close();

  final FileQuestionStore questions = FileQuestionStore(TreePaths(paths.root));
  questions.add(
    QuestionRecord(
      qid: 's3',
      agentId: 'agt',
      sessionId: 'session_default',
      questions: <AskedQuestion>[
        AskedQuestion(question: '继续吗', options: <String>['A', 'B']),
      ],
      answers: <String>['继续'],
      answer: '继续',
      status: QuestionStatus.answered,
      createdAt: 1761360003000,
      answeredAt: 1761360004000,
    ),
  );
  await questions.flush();
}

/// 模型池：POST /api/agents 要求 model_id 已在池中。
void _writeModels(AgentDataPaths paths) {
  final Directory dir = Directory(paths.modelsDir)
    ..createSync(recursive: true);
  File(p.join(dir.path, 'm1.yaml')).writeAsStringSync(
    'model_id: m1\n'
    'name: 模型一\n'
    'base_url: https://api.example.com/v1\n'
    'api_key: sk-secret\n'
    'max_seqlen: 64000\n',
  );
  File(p.join(dir.path, 'm2.yaml')).writeAsStringSync(
    'model_id: m2\n'
    'name: 模型二\n'
    'base_url: http://127.0.0.1:8080/\n',
  );
}

/// 会一直挂到 [release] 的引擎：用于稳定触发"运行中不能删"的 409。
class _BlockingEngine implements AgentEngine {
  final Completer<void> release = Completer<void>();

  @override
  Stream<AgentEvent> run(
    AgentRunContext context, {
    required bool Function() isCancelled,
  }) async* {
    await release.future;
    yield const AgentDone(finishReason: 'stop');
  }

  @override
  Future<void> close() async {}
}
