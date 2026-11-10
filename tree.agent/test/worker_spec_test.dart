import 'package:test/test.dart';
import 'package:tree_agent_loop/src/worker/worker_spec.dart';

/// 产线员工（P4）的参数规格：角色默认工具与硬边界。
void main() {
  test('缺 role / 缺 task 给可读错误', () {
    expect(
      () => parseWorkerArguments(<String, Object?>{'task': '干活'}),
      throwsA(
        isA<WorkerSpecError>().having(
          (WorkerSpecError e) => e.message,
          'message',
          contains('role 只能是 packer / executor / expert'),
        ),
      ),
    );
    expect(
      () => parseWorkerArguments(<String, Object?>{'role': 'packer'}),
      throwsA(
        isA<WorkerSpecError>().having(
          (WorkerSpecError e) => e.message,
          'message',
          contains('缺少 task'),
        ),
      ),
    );
  });

  test('角色默认工具：打包不带写、执行必须有写、专家最小集', () {
    final WorkerSpec packer = parseWorkerArguments(<String, Object?>{
      'role': 'packer',
      'task': '打片段',
    });
    expect(packer.tools, kWorkerDefaultTools['packer']);
    expect(packer.name, '打包模型');

    final WorkerSpec executor = parseWorkerArguments(<String, Object?>{
      'role': 'executor',
      'task': '改文件',
    });
    expect(executor.tools, containsAll(<String>['read', 'write', 'edit']));

    final WorkerSpec expert = parseWorkerArguments(<String, Object?>{
      'role': 'expert',
      'task': '查 API',
    });
    expect(expert.tools, <String>['read', 'grep']);
  });

  test('硬边界：打包 / 专家不许写；执行必须能写；员工不能建团队 / 再召', () {
    expect(
      () => parseWorkerArguments(<String, Object?>{
        'role': 'packer',
        'task': '打片段',
        'tools': <String>['read', 'write'],
      }),
      throwsA(
        isA<WorkerSpecError>()
            .having((WorkerSpecError e) => e.code, 'code', 'worker_tools_invalid')
            .having((WorkerSpecError e) => e.message, 'message', contains('不许写文件')),
      ),
    );
    expect(
      () => parseWorkerArguments(<String, Object?>{
        'role': 'executor',
        'task': '改文件',
        'tools': <String>['read', 'terminal'],
      }),
      throwsA(
        isA<WorkerSpecError>().having(
          (WorkerSpecError e) => e.message,
          'message',
          contains('既没有 write 也没有 edit'),
        ),
      ),
    );
    for (final String role in <String>['packer', 'executor', 'expert']) {
      expect(
        () => parseWorkerArguments(<String, Object?>{
          'role': role,
          'task': '干活',
          'tools': <String>[
            'read',
            if (role == 'executor') 'write',
            'team',
          ],
        }),
        throwsA(
          isA<WorkerSpecError>().having(
            (WorkerSpecError e) => e.message,
            'message',
            contains('员工不能用 team'),
          ),
        ),
        reason: '$role 也不能建团队',
      );
    }
    // Q3：默认不能再召员工；只有显式 allow_spawn + 白名单里有 subagent 才放行。
    expect(
      () => parseWorkerArguments(<String, Object?>{
        'role': 'executor',
        'task': '改文件',
        'tools': <String>['read', 'write', 'subagent'],
      }),
      throwsA(
        isA<WorkerSpecError>().having(
          (WorkerSpecError e) => e.message,
          'message',
          contains('员工不能用 subagent'),
        ),
      ),
    );
    final WorkerSpec spawn = parseWorkerArguments(<String, Object?>{
      'role': 'executor',
      'task': '改文件',
      'tools': <String>['read', 'write', 'subagent'],
      'allow_spawn': true,
    });
    expect(spawn.tools, contains('subagent'));
  });

  test('工具去重、reuse / worker_id 兼容、显式空工具表合法（专家纯推理）', () {
    final WorkerSpec spec = parseWorkerArguments(<String, Object?>{
      'role': 'expert',
      'task': '纯推理',
      'tools': <String>[],
    });
    expect(spec.tools, isEmpty);
    expect(spec.reuse, '');

    final WorkerSpec reuse = parseWorkerArguments(<String, Object?>{
      'role': 'executor',
      'task': '接着改',
      'worker_id': 'sub_1',
    });
    expect(reuse.reuse, 'sub_1');
  });
}
