import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_agent_loop/tree_agent_loop.dart';

/// MP-6：JEV `DecisionClient`（noul/choice/score、置信度、字段漂移可读）。
void main() {
  late HttpServer server;
  late List<Map<String, dynamic>> requests;
  late Map<String, dynamic> Function(Map<String, dynamic> body) responder;
  late DecisionClient client;

  setUp(() async {
    requests = <Map<String, dynamic>>[];
    responder = (Map<String, dynamic> body) => <String, dynamic>{
      'answers': <String, dynamic>{
        'route': <String, dynamic>{
          'choice': 'continue',
          'probabilities': <String, double>{
            'continue': 0.72,
            'retry': 0.18,
            'ask': 0.08,
            'stop': 0.02,
          },
          'confidence': 0.83,
        },
        'urgent': <String, dynamic>{'noul': 0.12},
        'difficulty': <String, dynamic>{
          'score': 2.1,
          'probabilities': <String, double>{'low': 0.05, 'mid': 0.35, 'high': 0.60},
        },
      },
      'usage': <String, dynamic>{'prompt_tokens': 42},
    };
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      final String text = await utf8.decoder.bind(request).join();
      final Map<String, dynamic> body =
          jsonDecode(text) as Map<String, dynamic>;
      requests.add(body);
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(responder(body)));
      await request.response.close();
    });
    client = DecisionClient();
  });

  tearDown(() async {
    await client.close();
    await server.close(force: true);
  });

  CoreModelConfig model({
    double threshold = 0.7,
    String kind = kModelKindDecision,
  }) => CoreModelConfig(
    modelId: 'jev',
    kind: kind,
    confidenceThreshold: threshold,
    baseUrl: 'http://127.0.0.1:${server.port}/v1',
    apiKey: 'sk-test',
  );

  test('三类问题：选中值 / 概率 / 置信度', () async {
    final DecisionResult result = await client.decide(
      model: model(),
      state: '任务上下文',
      questions: const <DecisionQuestion>[
        ChoiceQuestion('route', <String>['continue', 'retry', 'ask', 'stop']),
        NoulQuestion('urgent'),
        ScoreQuestion('difficulty', <String>['low', 'mid', 'high']),
      ],
    );
    expect(result.answers['route']?.choice, 'continue');
    expect(result.answers['route']?.confidence, 0.83);
    expect(result.answers['urgent']?.noul, 0.12);
    expect(result.answers['urgent']?.confidence, 0.88);
    expect(result.answers['difficulty']?.score, 2.1);
    expect(result.answers['difficulty']?.confidence, 0.60);
    expect(result.promptTokens, 42);
    expect(result.lowConfidence(0.7), <String>['difficulty']);

    final Map<String, dynamic> body = requests.single;
    expect(body['state'], '任务上下文');
    final Map<String, dynamic> questions =
        body['questions'] as Map<String, dynamic>;
    expect(questions.keys, containsAll(<String>['route', 'urgent', 'difficulty']));
    expect(
      (questions['route'] as Map<String, dynamic>)['type'],
      'choice',
    );
  });

  test('回包缺题 ⇒ invalid_response（不猜默认值）', () async {
    responder = (Map<String, dynamic> body) => <String, dynamic>{
      'answers': <String, dynamic>{
        'route': <String, dynamic>{'choice': 'continue', 'confidence': 0.9},
      },
    };
    await expectLater(
      client.decide(
        model: model(),
        state: 's',
        questions: const <DecisionQuestion>[
          ChoiceQuestion('route', <String>['continue', 'stop']),
          NoulQuestion('urgent'),
        ],
      ),
      throwsA(
        isA<DecisionFailure>().having(
          (DecisionFailure e) => e.code,
          'code',
          'invalid_response',
        ),
      ),
    );
  });

  test('选项越界 / 概率越界 ⇒ invalid_response', () async {
    responder = (Map<String, dynamic> body) => <String, dynamic>{
      'answers': <String, dynamic>{
        'route': <String, dynamic>{'choice': 'nope', 'confidence': 0.9},
      },
    };
    await expectLater(
      client.decide(
        model: model(),
        state: 's',
        questions: const <DecisionQuestion>[
          ChoiceQuestion('route', <String>['continue', 'stop']),
        ],
      ),
      throwsA(isA<DecisionFailure>()),
    );

    responder = (Map<String, dynamic> body) => <String, dynamic>{
      'answers': <String, dynamic>{
        'urgent': <String, dynamic>{
          'noul': 0.5,
          'probabilities': <String, dynamic>{'yes': 1.5},
        },
      },
    };
    await expectLater(
      client.decide(
        model: model(),
        state: 's',
        questions: const <DecisionQuestion>[NoulQuestion('urgent')],
      ),
      throwsA(isA<DecisionFailure>()),
    );
  });

  test('问题校验：重复名 / 选项不足 / 超上限', () async {
    await expectLater(
      client.decide(
        model: model(),
        state: 's',
        questions: const <DecisionQuestion>[
          NoulQuestion('a'),
          NoulQuestion('a'),
        ],
      ),
      throwsA(
        isA<DecisionFailure>().having(
          (DecisionFailure e) => e.code,
          'code',
          'invalid_question',
        ),
      ),
    );
    await expectLater(
      client.decide(
        model: model(),
        state: 's',
        questions: const <DecisionQuestion>[
          ChoiceQuestion('route', <String>['only']),
        ],
      ),
      throwsA(isA<DecisionFailure>()),
    );
    await expectLater(
      client.decide(
        model: model(),
        state: 's',
        questions: <DecisionQuestion>[
          for (int i = 0; i < 17; i++) NoulQuestion('q$i'),
        ],
      ),
      throwsA(
        isA<DecisionFailure>().having(
          (DecisionFailure e) => e.code,
          'code',
          'too_many_questions',
        ),
      ),
    );
    expect(requests, isEmpty);
  });

  test('非 decision 模型 / 缺阈值 ⇒ 明确拒绝', () async {
    await expectLater(
      client.decide(
        model: model(kind: kModelKindChat),
        state: 's',
        questions: const <DecisionQuestion>[NoulQuestion('a')],
      ),
      throwsA(
        isA<DecisionFailure>().having(
          (DecisionFailure e) => e.code,
          'code',
          'not_decision_model',
        ),
      ),
    );
    await expectLater(
      client.decide(
        model: model(threshold: 0),
        state: 's',
        questions: const <DecisionQuestion>[NoulQuestion('a')],
      ),
      throwsA(
        isA<DecisionFailure>().having(
          (DecisionFailure e) => e.code,
          'code',
          'invalid_model',
        ),
      ),
    );
  });

  test('MP-7 探测：成功给置信度，失败给可读原因', () async {
    responder = (Map<String, dynamic> body) => <String, dynamic>{
      'answers': <String, dynamic>{
        'ok': <String, dynamic>{'noul': 0.9},
      },
    };
    final Map<String, dynamic> ok = await client.probe(model: model());
    expect(ok['ok'], true);
    expect(ok['confidence'], 0.9);

    responder = (Map<String, dynamic> body) => <String, dynamic>{
      'answers': <String, dynamic>{},
    };
    final Map<String, dynamic> bad = await client.probe(model: model());
    expect(bad['ok'], false);
    expect(bad['code'], 'invalid_response');
  });
}
