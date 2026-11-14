import 'dart:convert';
import 'dart:io';

/// Task 10 UI 测试共用假核心：产线任务 / 计划 / 准备 / 附件 / 批量派发 / 漂移。
class ProductionFakeCore {
  ProductionFakeCore._(this._http);

  final HttpServer _http;

  List<Map<String, dynamic>> tasks = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> runs = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> questions = <Map<String, dynamic>>[];
  Map<String, dynamic> planV2 = <String, dynamic>{};
  Map<String, dynamic> planV1 = <String, dynamic>{};
  String planVersion = 'plan-v2';

  final List<String> calls = <String>[];
  final Map<String, Map<String, dynamic>> bodies =
      <String, Map<String, dynamic>>{};

  static Future<ProductionFakeCore> start() async {
    final HttpServer http = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final ProductionFakeCore core = ProductionFakeCore._(http);
    http.listen(core._handle);
    return core;
  }

  String get baseUrl => 'http://127.0.0.1:${_http.port}';
  Future<void> close() => _http.close(force: true);

  bool called(String method, String path) => calls.contains('$method $path');
  Map<String, dynamic> bodyOf(String method, String path) =>
      bodies['$method $path'] ?? <String, dynamic>{};

  Future<void> _handle(HttpRequest request) async {
    final String method = request.method;
    final String path = request.uri.path;
    final String raw = await utf8.decoder.bind(request).join();
    calls.add('$method $path');
    Map<String, dynamic> body = <String, dynamic>{};
    if (raw.trim().isNotEmpty) {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) {
        body = decoded.map(
          (Object? key, Object? value) =>
              MapEntry<String, dynamic>('$key', value),
        );
      }
    }
    bodies['$method $path'] = body;
    Map<String, dynamic> payload = <String, dynamic>{'success': true};

    if (path.endsWith('/upload_init')) {
      payload = <String, dynamic>{'upload_id': 'u1', 'chunk_size': 1024};
    } else if (path.endsWith('/upload_chunk')) {
      payload = <String, dynamic>{'received': 1, 'index': 0};
    } else if (path.endsWith('/upload_complete')) {
      payload = <String, dynamic>{
        'success': true,
        'path': '.input/20261114/${body['file_name'] ?? 'file.txt'}',
        'size': 12,
      };
    } else if (path.endsWith('/readiness')) {
      payload = <String, dynamic>{
        'ready': true,
        'phase': 'ready',
        'gates': <Object?>[],
        'missing': <Object?>[],
        'checked_at': '2026-11-14T10:00:00',
      };
    } else if (path.endsWith('/orchestrator')) {
      payload = <String, dynamic>{
        'config': <String, dynamic>{'enabled': true},
        'state': <String, dynamic>{'last_action': 'continue'},
        'open_questions': <Object?>[],
        'open_question_count': 0,
      };
    } else if (path.endsWith('/runs')) {
      final String taskId = request.uri.queryParameters['task_id'] ?? '';
      payload = <String, dynamic>{
        'runs': <Map<String, dynamic>>[
          for (final Map<String, dynamic> run in runs)
            if (taskId.isEmpty || '${run['task_id'] ?? ''}' == taskId) run,
        ],
        'count': runs.length,
      };
    } else if (path.endsWith('/plan')) {
      final int? version = int.tryParse(
        request.uri.queryParameters['version'] ?? '',
      );
      payload = <String, dynamic>{
        'version': version == null ? planVersion : 'plan-v$version',
        'plan': version == 1 ? planV1 : planV2,
        'findings': planV2['findings'] ?? <Object?>[],
      };
    } else if (path.endsWith('/questions')) {
      payload = <String, dynamic>{
        'questions': questions,
        'open': questions,
        'limit': 3,
      };
    } else if (path.endsWith('/decision')) {
      questions = <Map<String, dynamic>>[];
      payload = <String, dynamic>{'open': 0, 'ready': true};
    } else if (path.endsWith('/attachments')) {
      payload = <String, dynamic>{
        'attachment': <String, dynamic>{
          'path': '.input/20261114/design.png',
          'sha256': 'abcdef1234567890abcdef',
          'size': 12,
          'type': 'image/png',
          'kind': 'image',
          'name': body['name'] ?? 'design.png',
          'summary_by': 'manual_reference',
        },
        'task': <String, dynamic>{'id': 'T1'},
        'warnings': <String>['图片需要人工参考'],
        'deduplicated': false,
      };
    } else if (path.endsWith('/recon')) {
      payload = <String, dynamic>{
        'task': taskById('T1'),
        'open': questions.length,
      };
    } else if (path.endsWith('/finalize')) {
      payload = <String, dynamic>{
        'task': taskById('T1')..['status'] = 'queued',
        'created': <String>['T1'],
      };
    } else if (path.endsWith('/drift')) {
      payload = <String, dynamic>{
        'ok': true,
        'code': '',
        'results': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'BG-01',
            'code': '',
            'message': 'diff 与任务映射一致',
            'evidence': 'batches/B1/gates/BG-01.log',
          },
        ],
        'blocked': <Object?>[],
        'batch_id': 'B1',
      };
    } else if (path.endsWith('/dispatch')) {
      payload = <String, dynamic>{
        'batch_ids': <String>['T6'],
        'skipped': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'T2',
            'reason': 'write_scope_overlap',
            'with_task': 'T9',
          },
        ],
        'running': <String>['T3'],
        'slots_used': 1,
        'slots_free': 2,
        'max_parallel_tasks': 3,
        'dry_run': body['dry_run'] != false,
        'count': 1,
      };
    } else if (path.endsWith('/artifacts')) {
      payload = <String, dynamic>{
        'files': <Map<String, dynamic>>[
          <String, dynamic>{'path': 'plans/plan-v2/plan.json'},
          <String, dynamic>{'path': 'tasks/T1/pack.json'},
        ],
      };
    } else if (path.endsWith('/audit')) {
      payload = <String, dynamic>{
        'report': <String, dynamic>{'scanned': 1},
        'progress': <String, dynamic>{'done': true},
      };
    } else if (path.endsWith('/dedup')) {
      payload = <String, dynamic>{'run': <String, dynamic>{}};
    } else if (path.endsWith('/migrate')) {
      payload = <String, dynamic>{'note': '已迁移 0 条', 'migrated_count': 0};
    } else if (method == 'GET' && path.endsWith('/tasks')) {
      payload = <String, dynamic>{'tasks': tasks, 'count': tasks.length};
    } else if (method == 'POST' && path.endsWith('/tasks')) {
      final Map<String, dynamic> task = body['task'] is Map
          ? (body['task'] as Map).map(
              (Object? key, Object? value) =>
                  MapEntry<String, dynamic>('$key', value),
            )
          : <String, dynamic>{};
      task['id'] = 'T_new';
      tasks = <Map<String, dynamic>>[task, ...tasks];
      payload = <String, dynamic>{'task': task};
    } else if (method == 'PATCH' && path.contains('/tasks/')) {
      final String id = path.split('/').last;
      final Map<String, dynamic> task = taskById(id);
      final bool wasPacked = task['status'] == 'packed';
      task.addAll(body);
      if (wasPacked) {
        task['status'] = 'queued';
        payload = <String, dynamic>{
          'task': task,
          'pack_invalidated': true,
          'note': '已回到 queued：旧打包结果失效，需要重新打包',
        };
      } else {
        payload = <String, dynamic>{'task': task};
      }
    } else if (method == 'GET' && path.contains('/tasks/')) {
      payload = <String, dynamic>{'task': taskById(path.split('/').last)};
    }
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(payload));
    await request.response.close();
  }

  Map<String, dynamic> taskById(String id) {
    for (final Map<String, dynamic> task in tasks) {
      if ('${task['id'] ?? ''}' == id) return task;
    }
    return <String, dynamic>{'id': id};
  }
}

Map<String, dynamic> planFixture({
  bool openHigh = false,
  bool brokenTrace = false,
}) => <String, dynamic>{
  'requirements': <Map<String, dynamic>>[
    <String, dynamic>{'id': 'REQ-1', 'text': '会话列表可过滤'},
    if (brokenTrace) <String, dynamic>{'id': 'REQ-2', 'text': '断链需求'},
  ],
  'design': <String, dynamic>{'summary': '先读后写', 'migration': ''},
  'invariants': <Map<String, dynamic>>[
    <String, dynamic>{'id': 'INV-1', 'text': '旧行为保持', 'owner': 'executor'},
  ],
  'tasks': <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'T1',
      'title': '底座',
      'task_type': 'code',
      'risk': 'medium',
      'depends_on': <String>[],
      'write_scope': <String>['lib/a/'],
      'requirements': <String>['REQ-1'],
    },
    <String, dynamic>{
      'id': 'T2',
      'title': '界面',
      'task_type': 'code',
      'risk': 'low',
      'depends_on': <String>['T1'],
      'write_scope': <String>['lib/b/'],
      'requirements': <String>['REQ-1'],
    },
    <String, dynamic>{
      'id': 'T3',
      'title': '集成',
      'task_type': 'integration',
      'risk': 'high',
      'depends_on': <String>['T2'],
      'write_scope': <String>['lib/c/'],
      'requirements': <String>['REQ-1'],
    },
  ],
  'gates': <String, dynamic>{
    'T1': <Map<String, dynamic>>[
      <String, dynamic>{
        'text': '- [ ] dart test 通过',
        'evidence': 'runs/T1/test.log',
      },
    ],
    'T2': <Map<String, dynamic>>[
      <String, dynamic>{
        'text': '- [ ] 截图',
        'evidence': 'runs/T2/shot.png',
      },
    ],
    'T3': <Map<String, dynamic>>[
      <String, dynamic>{
        'text': '- [ ] 集成测试',
        'evidence': 'runs/T3/e2e.log',
      },
    ],
  },
  'traceability': <Map<String, dynamic>>[
    <String, dynamic>{
      'req': 'REQ-1',
      'tasks': <String>['T1', 'T2'],
      'gates': <Map<String, dynamic>>[
        <String, dynamic>{'task': 'T1', 'text': 'dart test 通过'},
      ],
    },
    if (brokenTrace)
      <String, dynamic>{
        'req': 'REQ-2',
        'tasks': <String>['T9'],
        'gates': <Map<String, dynamic>>[
          <String, dynamic>{'task': 'T9', 'text': '不存在的门控'},
        ],
      },
  ],
  'risks': <Map<String, dynamic>>[
    <String, dynamic>{'id': 'R1', 'text': '并发槽位', 'mitigation': '串行'},
  ],
  'unknowns': <Map<String, dynamic>>[],
  'change_control': <String, dynamic>{
    'plan_version': 'plan-v2',
    'decision_template': 'DEC-xx',
    'rollback_points': <String>['B1'],
  },
  'decisions': <Map<String, dynamic>>[
    <String, dynamic>{'id': 'DEC-1', 'text': '批准', 'status': 'approved'},
  ],
  'findings': <Map<String, dynamic>>[
    if (openHigh)
      <String, dynamic>{
        'id': 'F1',
        'severity': 'high',
        'status': 'open',
        'text': '写域交叠未解决',
        'evidence': 'plan:12',
      },
    <String, dynamic>{
      'id': 'F2',
      'severity': 'medium',
      'status': 'closed',
      'text': '测试覆盖不足',
    },
    <String, dynamic>{
      'id': 'F3',
      'severity': 'low',
      'status': 'open',
      'text': '命名可选优化',
    },
  ],
  'rounds': 2,
};
