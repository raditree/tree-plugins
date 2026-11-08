import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_agent_loop/tree_agent_loop.dart';

/// MP-5：OpenAI 兼容 `/embeddings` 客户端（分批 / 维度 / 失败可读）。
void main() {
  late HttpServer server;
  late List<Map<String, dynamic>> requests;
  late Map<String, dynamic> Function(Map<String, dynamic> body) responder;
  late EmbeddingClient client;

  setUp(() async {
    requests = <Map<String, dynamic>>[];
    responder = (Map<String, dynamic> body) {
      final List<dynamic> inputs = body['input'] as List<dynamic>;
      return <String, dynamic>{
        'data': <Map<String, dynamic>>[
          for (int i = 0; i < inputs.length; i++)
            <String, dynamic>{
              'index': i,
              'embedding': <double>[0.1, -0.2, 0.3, 0.4],
            },
        ],
        'usage': <String, dynamic>{'prompt_tokens': inputs.length},
      };
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
    client = EmbeddingClient();
  });

  tearDown(() async {
    await client.close();
    await server.close(force: true);
  });

  CoreModelConfig model({
    int dimensions = 4,
    int maxInputTokens = 0,
    String kind = kModelKindEmbedding,
  }) => CoreModelConfig(
    modelId: 'emb',
    kind: kind,
    dimensions: dimensions,
    maxInputTokens: maxInputTokens,
    baseUrl: 'http://127.0.0.1:${server.port}/v1',
    apiKey: 'sk-test',
    tokenScale: 1.0,
  );

  test('成功：按输入顺序返回，请求带 model/input/dimensions', () async {
    responder = (Map<String, dynamic> body) {
      final int count = (body['input'] as List<dynamic>).length;
      return <String, dynamic>{
        'data': <Map<String, dynamic>>[
          for (int i = count - 1; i >= 0; i--)
            <String, dynamic>{
              'index': i,
              'embedding': <double>[i.toDouble(), 1, 2, 3],
            },
        ],
        'usage': <String, dynamic>{'prompt_tokens': 7},
      };
    };
    final EmbeddingResult result = await client.embed(
      model: model(),
      inputs: <String>['甲', '乙'],
    );
    expect(result.vectors, hasLength(2));
    expect(result.vectors.first, <double>[0, 1, 2, 3]);
    expect(result.vectors.last, <double>[1, 1, 2, 3]);
    expect(result.promptTokens, 7);
    expect(requests.single['model'], 'emb');
    expect(requests.single['dimensions'], 4);
    expect(requests.single['input'], <String>['甲', '乙']);
  });

  test('维度不符：整批失败，不返回半截', () async {
    responder = (Map<String, dynamic> body) => <String, dynamic>{
      'data': <Map<String, dynamic>>[
        <String, dynamic>{
          'index': 0,
          'embedding': <double>[0.1, 0.2, 0.3],
        },
      ],
    };
    await expectLater(
      client.embed(model: model(), inputs: <String>['x']),
      throwsA(
        isA<EmbeddingFailure>().having(
          (EmbeddingFailure e) => e.code,
          'code',
          'dimension_mismatch',
        ),
      ),
    );
  });

  test('自动分批：130 条按 64/64/2 发三次', () async {
    final List<String> inputs = <String>[
      for (int i = 0; i < 130; i++) 'item-$i',
    ];
    final EmbeddingResult result = await client.embed(
      model: model(),
      inputs: inputs,
    );
    expect(result.vectors, hasLength(130));
    expect(requests, hasLength(3));
    expect((requests[0]['input'] as List<dynamic>).length, 64);
    expect((requests[1]['input'] as List<dynamic>).length, 64);
    expect((requests[2]['input'] as List<dynamic>).length, 2);
  });

  test('单条超过 max_input_tokens 估算 ⇒ input_too_long，不发请求', () async {
    await expectLater(
      client.embed(
        model: model(maxInputTokens: 3),
        inputs: <String>['abcdef'],
      ),
      throwsA(
        isA<EmbeddingFailure>().having(
          (EmbeddingFailure e) => e.code,
          'code',
          'input_too_long',
        ),
      ),
    );
    expect(requests, isEmpty);
  });

  test('非 embedding 模型 / 缺维度 ⇒ 明确拒绝', () async {
    await expectLater(
      client.embed(
        model: model(kind: kModelKindChat, dimensions: 0),
        inputs: <String>['x'],
      ),
      throwsA(
        isA<EmbeddingFailure>().having(
          (EmbeddingFailure e) => e.code,
          'code',
          'not_embedding_model',
        ),
      ),
    );
    await expectLater(
      client.embed(model: model(dimensions: 0), inputs: <String>['x']),
      throwsA(
        isA<EmbeddingFailure>().having(
          (EmbeddingFailure e) => e.code,
          'code',
          'invalid_model',
        ),
      ),
    );
  });

  test('MP-7 探测：成功给维度，失败给可读原因', () async {
    final Map<String, dynamic> ok = await client.probe(model: model());
    expect(ok['ok'], true);
    expect(ok['dimensions'], 4);

    responder = (Map<String, dynamic> body) => <String, dynamic>{
      'data': <Map<String, dynamic>>[
        <String, dynamic>{'index': 0, 'embedding': <double>[1]},
      ],
    };
    final Map<String, dynamic> bad = await client.probe(model: model());
    expect(bad['ok'], false);
    expect(bad['code'], 'dimension_mismatch');
  });
}
