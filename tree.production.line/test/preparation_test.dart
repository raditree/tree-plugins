import 'package:test/test.dart';
import 'package:tree_production_line/tree_production_line.dart';

/// P3 准备阶段的纯领域：需求模板、追问上限、侦查/计划解析、台账重放、文档渲染。
void main() {
  group('需求模板（§8.2）', () {
    test('目标 / 验收为空 ⇒ 阻断；其余栏可空', () {
      final IntakeResult empty = normalizeIntake(const <String, Object?>{});
      expect(empty.ok, isFalse);
      expect(empty.blocking.join(), contains('目标'));
      expect(empty.blocking.join(), contains('验收'));

      final IntakeResult ok = normalizeIntake(const <String, Object?>{
        'goal': '会话列表能按项目过滤',
        'acceptance': '选中项目后只剩该项目会话；有测试',
      });
      expect(ok.ok, isTrue);
      expect(ok.warnings, isEmpty);
      expect(ok.values['current'], '');
    });

    test('空泛词只提示不阻断，并给改写建议', () {
      final IntakeResult result = normalizeIntake(const <String, Object?>{
        'goal': '优化一下列表',
        'acceptance': '好用了就行',
        'deadline': '尽快',
      });
      expect(result.ok, isTrue);
      expect(result.warnings.any((String w) => w.contains('优化')), isTrue);
      expect(result.warnings.any((String w) => w.contains('好用了就行')), isTrue);
      expect(result.warnings.any((String w) => w.contains('尽快')), isTrue);
      expect(result.warnings.first, contains('写成'));
    });
  });

  group('追问上限（§8.4）', () {
    test('默认 3，夹到 1–10', () {
      expect(clampQuestionLimit(null), 3);
      expect(clampQuestionLimit(''), 3);
      expect(clampQuestionLimit(0), 1);
      expect(clampQuestionLimit(-5), 1);
      expect(clampQuestionLimit(4), 4);
      expect(clampQuestionLimit(99), 10);
    });
  });

  group('理解摘要与双查询（§5.2）', () {
    test('digest 提示词含需求五栏与附件元数据；缺 requirement_summary 拒绝', () {
      final String prompt = digestUserPrompt(
        intake: const <String, String>{
          'goal': '会话列表能按项目过滤',
          'current': '只有 flat 列表',
          'acceptance': '选中项目后只剩该项目会话',
          'forbidden': '不动数据库',
          'deadline': '今天',
        },
        attachments: <Map<String, Object?>>[
          <String, Object?>{
            'id': 'A1',
            'name': 'design.png',
            'mime': 'image/png',
            'size': 245760,
          },
        ],
      );
      expect(prompt, contains('目标：会话列表能按项目过滤'));
      expect(prompt, contains('现状：只有 flat 列表'));
      expect(prompt, contains('验收：选中项目后只剩该项目会话'));
      expect(prompt, contains('禁区：不动数据库'));
      expect(prompt, contains('期限：今天'));
      expect(prompt, contains('id=A1'));
      expect(prompt, contains('name=design.png'));
      expect(prompt, contains('mime=image/png'));
      expect(digestSystemPrompt(), contains('不要调用工具'));

      final Digest digest = parseDigestJson(<String, Object?>{
        'requirement_summary': '让会话列表按项目过滤',
        'keywords': <String, Object?>{
          'terms': <String>['会话列表', '项目过滤'],
          'synonyms': <String>['session list'],
          'entities': <String>['AgentList'],
          'files': <String>['lib/ui/agent_list.dart'],
          'apis': <String>['SessionFilter'],
        },
        'constraints': <String>['不动数据库'],
        'attachment_summaries': <Object?>[
          <String, Object?>{
            'id': 'A1',
            'summary': '左栏设计稿',
            'keywords': <String>['项目下拉'],
            'status': 'vision',
          },
        ],
        'ambiguities': <String>['过滤状态是否持久化'],
      });
      expect(digest.requirementSummary, '让会话列表按项目过滤');
      expect(
        digest.keywords.all,
        containsAll(<String>['会话列表', 'AgentList', 'SessionFilter']),
      );
      expect(digest.attachmentSummaries.single.keywords, <String>['项目下拉']);
      expect(digest.ambiguities, <String>['过滤状态是否持久化']);
      expect(
        () => parseDigestJson(const <String, Object?>{}),
        throwsA(
          isA<ProductionFailure>().having(
            (ProductionFailure e) => e.code,
            'code',
            'digest_empty',
          ),
        ),
      );
    });

    test('查询 A 用原文、查询 B 用关键词；RRF 按 doc+heading 去重并截到 8', () {
      final String queryA = requirementSearchQuery(const <String, String>{
        'goal': '会话列表能按项目过滤',
        'acceptance': '选中项目后只剩该项目会话',
      });
      expect(queryA, contains('目标：会话列表能按项目过滤'));
      expect(queryA, contains('验收：选中项目后只剩该项目会话'));

      const Digest digest = Digest(
        requirementSummary: '让会话列表按项目过滤',
        keywords: DigestKeywords(
          terms: <String>['会话列表'],
          entities: <String>['AgentList'],
        ),
      );
      final String queryB = digestSearchQuery(digest);
      expect(queryB, contains('会话列表'));
      expect(queryB, contains('AgentList'));

      final List<Map<String, Object?>> primary = <Map<String, Object?>>[
        for (int i = 1; i <= 10; i++)
          <String, Object?>{
            'doc': 'docs/d$i.md',
            'heading': 'H',
            'snippet': 's$i',
          },
        <String, Object?>{
          'doc': 'docs/d1.md',
          'heading': 'H',
          'snippet': 'dup',
        },
      ];
      final List<ReconEvidence> evidence = mergeRetrievalEvidence(
        primary: primary,
        secondary: <Map<String, Object?>>[
          <String, Object?>{
            'doc': 'docs/d1.md',
            'heading': 'H',
            'snippet': 's1',
          },
          <String, Object?>{
            'doc': 'docs/d2.md',
            'heading': 'H2',
            'snippet': 's2',
          },
        ],
      );
      expect(evidence, hasLength(8));
      expect(evidence.first.id, 'E1');
      final ReconEvidence shared = evidence.firstWhere(
        (ReconEvidence item) =>
            item.path == 'docs/d1.md' && item.heading == 'H',
      );
      expect(shared.queries, containsAll(<String>['A', 'B']));
      expect(
        evidence.where(
          (ReconEvidence item) =>
              item.path == 'docs/d1.md' && item.heading == 'H',
        ),
        hasLength(1),
      );
    });

    test('旧 recon JSON 无 evidence_ids 仍可解析；缺失证据标 unknown，伪证据被丢弃', () {
      final ReconDraft old = parseReconJson(<String, Object?>{
        'regular': <Object?>['改列表'],
        'questions': <Object?>[
          <String, Object?>{
            'text': '要不要分页',
            'default': '不',
            'recommended': '是',
            'consequence': '不分页会更慢',
          },
        ],
      }, maxQuestions: 3);
      expect(old.regular.single.evidenceIds, isEmpty);
      expect(old.regular.single.unknown, isTrue);
      expect(old.questions.single.evidenceIds, isEmpty);

      final ReconDraft draft = parseReconJson(
        <String, Object?>{
          'regular': <Object?>[
            <String, Object?>{
              'text': '有证据的要求',
              'evidence_ids': <String>['E1', 'E9'],
            },
            <String, Object?>{'text': '没有证据的要求'},
          ],
          'questions': <Object?>[
            <String, Object?>{
              'text': '带证据的问题',
              'evidence_ids': <String>['E2', 'E9'],
            },
          ],
        },
        maxQuestions: 3,
        knownEvidence: <String>{'E1', 'E2'},
      );
      expect(draft.regular.first.evidenceIds, <String>['E1']);
      expect(draft.regular.first.unknown, isFalse);
      expect(draft.regular.last.evidenceIds, isEmpty);
      expect(draft.regular.last.unknown, isTrue);
      expect(draft.questions.single.evidenceIds, <String>['E2']);
      expect(
        (draft.toJson()['regular'] as List<dynamic>).last,
        containsPair('unknown', true),
      );

      // 本次检索为空（空集合而非 null）时，模型自造的 evidence_id 一律丢弃。
      final ReconDraft noEvidence = parseReconJson(
        <String, Object?>{
          'regular': <Object?>[
            <String, Object?>{
              'text': '凭空引用',
              'evidence_ids': <String>['E1'],
            },
          ],
        },
        maxQuestions: 3,
        knownEvidence: const <String>{},
      );
      expect(noEvidence.regular.single.evidenceIds, isEmpty);
      expect(noEvidence.regular.single.unknown, isTrue);
    });
  });

  group('侦查解析（§8.3）', () {
    test('行序即编号；flags 截到 8；超限问题计数', () {
      final ReconDraft draft = parseReconJson(<String, Object?>{
        'regular': <Object?>[
          <String, Object?>{'text': '改列表', 'landing': 'lib/ui/agent_list.dart'},
          '补测试',
        ],
        'special': <Object?>[
          <String, Object?>{'text': '要本地模型', 'why': '云端延迟太高'},
        ],
        'questions': <Object?>[
          for (int i = 1; i <= 12; i++)
            <String, Object?>{
              'text': '问题 $i',
              'default': '默认 $i',
              'recommended': '推荐 $i',
              'consequence': '后果 $i',
            },
        ],
        'fallbacks': <Object?>['退回云端模型'],
        'notes': <Object?>['数据库不可动'],
        'flags': <String>[for (int i = 1; i <= 12; i++) 'lib/f$i.dart'],
      }, maxQuestions: 10);
      expect(draft.regular, hasLength(2));
      expect(draft.regular.first.note, 'lib/ui/agent_list.dart');
      expect(draft.special.single.note, '云端延迟太高');
      expect(draft.questions, hasLength(10));
      expect(draft.droppedQuestions, 2);
      expect(draft.flags, hasLength(8));
    });

    test('缺常规要求 ⇒ recon_empty（不许凭空侦查）', () {
      expect(
        () => parseReconJson(const <String, Object?>{}, maxQuestions: 3),
        throwsA(
          isA<ProductionFailure>().having(
            (ProductionFailure e) => e.code,
            'code',
            'recon_empty',
          ),
        ),
      );
    });
  });

  group('追问额度合并（§8.4 规则 6）', () {
    QuestionState state(String qid, String text, {bool answered = false}) {
      final QuestionState question = QuestionState(
        taskId: 'T0',
        qid: qid,
        text: text,
        defaultValue: 'd',
        recommended: 'r',
        consequence: 'c',
        round: 1,
        windowId: 'win_1',
        askedAt: 't',
      );
      question.answered = answered;
      question.answer = answered ? '已答' : '';
      return question;
    }

    test('未答问题不占新额度，重复问题不重复登记', () {
      final ({List<ReconQuestionSpec> added, int dropped}) planned =
          planNewQuestions(
            incoming: <ReconQuestionSpec>[
              const ReconQuestionSpec(
                text: '旧问题',
                defaultValue: '',
                recommended: '',
                consequence: '',
              ),
              const ReconQuestionSpec(
                text: '新问题 A',
                defaultValue: '',
                recommended: '',
                consequence: '',
              ),
              const ReconQuestionSpec(
                text: '新问题 B',
                defaultValue: '',
                recommended: '',
                consequence: '',
              ),
            ],
            existing: <QuestionState>[
              state('Q1', '旧问题'),
              state('Q2', '已答问题', answered: true),
            ],
            limit: 2,
          );
      // 未答 1 条 ⇒ 新额度 1；"旧问题"重复、只剩 A 入选，B 被截断。
      expect(planned.added.map((ReconQuestionSpec q) => q.text), <String>[
        '新问题 A',
      ]);
      expect(planned.dropped, 1);
      expect(nextQuestionId(<String>['Q1', 'Q3']), 'Q4');
    });

    test('全部答完 ⇒ 新额度恢复为 limit', () {
      final ({List<ReconQuestionSpec> added, int dropped}) planned =
          planNewQuestions(
            incoming: <ReconQuestionSpec>[
              for (int i = 1; i <= 5; i++)
                ReconQuestionSpec(
                  text: '新 $i',
                  defaultValue: '',
                  recommended: '',
                  consequence: '',
                ),
            ],
            existing: <QuestionState>[state('Q1', '旧', answered: true)],
            limit: 3,
          );
      expect(planned.added, hasLength(3));
      expect(planned.dropped, 2);
    });
  });

  group('计划解析（§8.5）', () {
    test('缺 id 按行序补；kind 非法回 conventional；缺验收 ⇒ 报错', () {
      final ScopePlan plan = parseScopeJson(<String, Object?>{
        'in': <String>['列表过滤'],
        'out': <String>['不动数据库'],
        'not_doing': <String>['不做搜索'],
        'tasks': <Object?>[
          <String, Object?>{
            'title': '改列表',
            'kind': 'weird',
            'acceptance': <String>['用例全绿'],
            'write_scope': <String>['lib/ui/agent_list.dart'],
            'estimated_files': 2,
          },
          <String, Object?>{
            'id': 'T2',
            'title': '补测试',
            'depends_on': <String>['T1'],
            'acceptance': <String>['新用例覆盖过滤'],
          },
        ],
      });
      expect(plan.tasks.first.id, 'T1');
      expect(plan.tasks.first.kind, 'conventional');
      expect(plan.tasks.last.id, 'T2');
      expect(plan.tasks.last.dependsOn, <String>['T1']);
      expect(plan.outOfScope, <String>['不动数据库']);
    });

    test('重复 id / 缺验收 / 空任务各自报 plan_incomplete / plan_empty', () {
      Matcher failure(String code) => throwsA(
        isA<ProductionFailure>().having(
          (ProductionFailure e) => e.code,
          'code',
          code,
        ),
      );
      expect(
        () => parseScopeJson(<String, Object?>{
          'tasks': <Object?>[
            <String, Object?>{
              'id': 'T1',
              'title': 'a',
              'acceptance': <String>['x'],
            },
            <String, Object?>{
              'id': 'T1',
              'title': 'b',
              'acceptance': <String>['y'],
            },
          ],
        }),
        failure('plan_incomplete'),
      );
      expect(
        () => parseScopeJson(<String, Object?>{
          'tasks': <Object?>[
            <String, Object?>{'id': 'T1', 'title': 'a'},
          ],
        }),
        failure('plan_incomplete'),
      );
      expect(
        () => parseScopeJson(const <String, Object?>{'tasks': <Object?>[]}),
        failure('plan_empty'),
      );
    });
  });

  group('台账重放', () {
    test('同任务 answer 覆盖；不同任务的 Q1 不串号', () {
      final List<QuestionState> questions = replayQuestions(
        <Map<String, Object?>>[
          <String, Object?>{
            'type': 'question',
            'task_id': 'T0',
            'qid': 'Q1',
            'text': 'A',
            'round': 1,
            'window_id': 'win_1',
          },
          <String, Object?>{
            'type': 'question',
            'task_id': 'T9',
            'qid': 'Q1',
            'text': 'B',
            'round': 1,
            'window_id': 'win_1',
          },
          <String, Object?>{
            'type': 'answer',
            'task_id': 'T0',
            'qid': 'Q1',
            'value': '选了 A',
            'source': '用户回答',
          },
          <String, Object?>{'type': 'window', 'id': 'win_1'},
        ],
      );
      expect(questions, hasLength(2));
      final QuestionState first = questions.firstWhere(
        (QuestionState q) => q.taskId == 'T0',
      );
      expect(first.answered, isTrue);
      expect(first.answer, '选了 A');
      expect(
        questions.firstWhere((QuestionState q) => q.taskId == 'T9').answered,
        isFalse,
      );
    });
  });

  group('文档渲染（固定结构）', () {
    ReconDraft draft() => ReconDraft(
      regular: const <ReconPoint>[
        ReconPoint(text: '改列表', note: 'lib/ui/agent_list.dart'),
      ],
      special: const <ReconPoint>[ReconPoint(text: '本地模型', note: '云端延迟高')],
      questions: const <ReconQuestionSpec>[],
      fallbacks: const <ReconPoint>[ReconPoint(text: '退回云端')],
      notes: const <ReconPoint>[ReconPoint(text: '数据库不可动')],
      flags: const <String>['lib/ui/agent_list.dart'],
      droppedQuestions: 0,
    );

    QuestionState question(String qid, String text, {bool answered = false}) {
      final QuestionState state = QuestionState(
        taskId: 'T0',
        qid: qid,
        text: text,
        defaultValue: '默认',
        recommended: '推荐',
        consequence: '后果',
        round: 1,
        windowId: 'win_1',
        askedAt: '2026-11-09T10:00:00.000',
      );
      state.answered = answered;
      state.answer = answered ? '用户选了 X' : '';
      state.source = answered ? '用户回答' : '';
      return state;
    }

    test('recon.md 四节顺序固定，Q 用台账编号', () {
      final String md = renderReconMd(
        taskId: 'T0',
        title: '列表过滤',
        intake: const <String, String>{
          'goal': '列表能过滤',
          'current': '只有 flat',
          'acceptance': '只剩该项目',
          'forbidden': '不动库',
          'deadline': '今天',
        },
        recon: draft(),
        questions: <QuestionState>[question('Q3', '要不要分页')],
      );
      final List<int> order = <int>[
        md.indexOf('## 1. 常规要求'),
        md.indexOf('## 2. 特殊要求'),
        md.indexOf('## 3. 疑惑与待拍板'),
        md.indexOf('## 4. 回退选项与注意事项'),
      ];
      expect(order.every((int i) => i >= 0), isTrue);
      expect(order, <int>[...order]..sort());
      expect(md, contains('**Q3** 要不要分页'));
      expect(md, contains('读取标旗（每会话 ≤ 8 文件）：lib/ui/agent_list.dart'));
      expect(md, contains('**R1** 改列表（落点：lib/ui/agent_list.dart）'));
      expect(md, contains('**S1** 本地模型（为什么常规做不到：云端延迟高）'));
      expect(md, contains('**F1** 退回云端'));
      expect(md, contains('**N1** 数据库不可动'));
    });

    test('decisions.md 按窗口分组：open / answered / 覆盖记录', () {
      final String md = renderDecisionsMd(
        lineName: '标准开发流',
        questions: <QuestionState>[
          question('Q1', '要不要分页', answered: true),
          question('Q2', '要不要缓存'),
        ],
        windows: <Map<String, Object?>>[
          <String, Object?>{
            'id': 'win_1',
            'round': 1,
            'opened_at': '2026-11-09T10:00:00.000',
          },
        ],
        answers: <Map<String, Object?>>[
          <String, Object?>{
            'qid': 'Q1',
            'previous': '旧回答',
            'value': '用户选了 X',
            'answered_at': '2026-11-09T10:03:00.000',
          },
        ],
      );
      expect(md, contains('## 窗口 win_1（第 1 轮'));
      expect(md, contains('**Q1** 要不要分页 → ✅ 用户回答：用户选了 X'));
      expect(md, contains('**Q2** 要不要缓存 → ⏳ open'));
      expect(md, contains('## 变更（以最新回答为准）'));
      expect(md, contains('「旧回答」→ 「用户选了 X」'));
    });

    test('scope/plan/acceptance 的固定形状', () {
      final ScopePlan plan = parseScopeJson(<String, Object?>{
        'in': <String>['列表过滤'],
        'out': <String>['不动数据库'],
        'not_doing': <String>['不做搜索'],
        'tasks': <Object?>[
          <String, Object?>{
            'id': 'T1',
            'title': '改列表',
            'acceptance': <String>['用例全绿'],
            'write_scope': <String>['lib/ui/agent_list.dart'],
          },
          <String, Object?>{
            'id': 'T2',
            'title': '补测试',
            'depends_on': <String>['T1'],
            'acceptance': <String>['新用例'],
          },
        ],
      });
      final String scope = renderScopeMd(taskId: 'T0', plan: plan);
      expect(scope, contains('## 范围内'));
      expect(scope, contains('## 范围外'));
      expect(scope, contains('## 明确不做'));
      final String planMd = renderPlanMd(
        lineName: '标准开发流',
        taskId: 'T0',
        plan: plan,
      );
      expect(planMd, contains('| 任务 | 标题 | 类型 | 依赖 | 写域 | 预计文件 |'));
      expect(planMd, contains('| T2 | 补测试 | conventional | T1 |'));
      expect(planMd, contains('T1 → T2'));
      final String acceptance = renderAcceptanceMd(
        taskId: 'T2',
        title: '补测试',
        acceptance: const <String>['新用例'],
      );
      expect(acceptance, contains('- [ ] 新用例'));
    });

    test('分发摘要 ≤ 10 行且带常规/特殊占比', () {
      final List<String> summary = distributionSummary(
        tasks: <PlanTaskSpec>[
          const PlanTaskSpec(
            id: 'T1',
            title: 'a',
            kind: 'conventional',
            dependsOn: <String>[],
            readScope: <String>[],
            writeScope: <String>[],
            acceptance: <String>['x'],
            estimatedFiles: 1,
          ),
          const PlanTaskSpec(
            id: 'T2',
            title: 'b',
            kind: 'special',
            dependsOn: <String>[],
            readScope: <String>[],
            writeScope: <String>[],
            acceptance: <String>['y'],
            estimatedFiles: 1,
          ),
        ],
        openQuestions: 0,
        questionLimit: 3,
      );
      expect(summary.length, lessThanOrEqualTo(10));
      expect(summary.first, '任务 2 个（常规 1 / 特殊 1）');
    });
  });

  group('读取预算（§8.1）', () {
    test('文件 8 个、grep 2 轮为上限', () {
      final ReadBudget budget = ReadBudget();
      for (int i = 0; i < 8; i++) {
        expect(budget.canReadFile, isTrue);
        budget.files += 1;
      }
      expect(budget.canReadFile, isFalse);
      expect(budget.canGrep, isTrue);
      budget.grepRounds += 1;
      expect(budget.canGrep, isTrue);
      budget.grepRounds += 1;
      expect(budget.canGrep, isFalse);
    });
  });
}
