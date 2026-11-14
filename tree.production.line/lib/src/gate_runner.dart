/// 独立门控 runner（SG-04）：执行者不能自签，门控命令与证据由 runner 跑并封签。
///
/// 结果落 `tasks/<task>/gates/<run_id>/gate.json`：
/// ```jsonc
/// {"version":1,"run_id":"...","runner_id":"...","fencing":3,
///  "started_at":"...","finished_at":"...","ok":true,
///  "commands":[{"command":"dart analyze","ok":true,"exit_code":0,"output":"..."}],
///  "checklist":[{"text":"...","evidence":"...","ok":true,"sha256":"..."}],
///  "evidence_hashes":{"reports/test.log":"..."},
///  "sealed":true}
/// ```
/// `ProductionStore.writeGate` 对已 sealed 且 `runner_id` 不同的覆盖返回
/// `gate_tampered`；执行者进程拿不到 runner_id 之外的写权限。
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'execution.dart';
import 'models.dart';
import 'store.dart';

/// 一次门控执行。
class GateRunner {
  const GateRunner();

  Future<Map<String, Object?>> run({
    required String runnerId,
    required String runId,
    required List<String> commands,
    required List<Map<String, Object?>> checklist,
    required String workspace,
    required Future<CommandResult> Function(String command) commandRunner,
    required ProductionStore store,
    required String lineId,
    required String taskId,
    required int fencing,
  }) async {
    final String startedAt = store.nowText();
    final List<Map<String, Object?>> commandResults = <Map<String, Object?>>[];
    bool ok = true;
    for (final String raw in commands) {
      final String command = raw.trim();
      if (command.isEmpty) continue;
      final CommandResult result = await commandRunner(command);
      commandResults.add(<String, Object?>{
        'command': command,
        'ok': result.ok,
        'exit_code': result.exitCode,
        'output': _clip(result.output, 4000),
      });
      if (!result.ok) {
        ok = false;
        break;
      }
    }

    final List<Map<String, Object?>> checklistResults =
        <Map<String, Object?>>[];
    final Map<String, Object?> evidenceHashes = <String, Object?>{};
    for (final Map<String, Object?> item in checklist) {
      final String text = textOf(item['text']);
      final String evidence = textOf(item['evidence']);
      final _EvidenceCheck check = _verifyEvidence(workspace, evidence);
      if (check.hash.isNotEmpty) evidenceHashes[evidence] = check.hash;
      checklistResults.add(<String, Object?>{
        'text': text,
        'evidence': evidence,
        'ok': check.ok,
        'sha256': check.hash,
        if (check.error.isNotEmpty) 'error': check.error,
      });
      if (!check.ok) ok = false;
    }

    final Map<String, Object?> gate = <String, Object?>{
      'version': 1,
      'run_id': runId,
      'runner_id': runnerId,
      'fencing': fencing,
      'started_at': startedAt,
      'finished_at': store.nowText(),
      'ok': ok,
      'commands': commandResults,
      'checklist': checklistResults,
      'evidence_hashes': evidenceHashes,
    };
    return store.writeGate(lineId, taskId, runId, gate);
  }
}

class _EvidenceCheck {
  const _EvidenceCheck({required this.ok, this.hash = '', this.error = ''});

  final bool ok;
  final String hash;
  final String error;
}

/// 证据判据（与出口门 TG-11/12 一致）：占位 / 缺失 / 越界一律不通过。
_EvidenceCheck _verifyEvidence(String workspace, String evidence) {
  final String text = evidence.trim();
  if (_placeholder(text)) {
    return const _EvidenceCheck(ok: false, error: '门控缺 evidence');
  }
  // `run:xx` / `evidence:xx` / 带 `#` 的引用视为逻辑证据，不做文件校验。
  if (text.contains('#') ||
      text.startsWith('run:') ||
      text.startsWith('evidence:')) {
    return const _EvidenceCheck(ok: true);
  }
  final String root = p.normalize(workspace);
  final String path = p.normalize(
    p.joinAll(<String>[root, ...text.split('/')]),
  );
  final String prefix = root.endsWith(p.separator) ? root : '$root${p.separator}';
  if (path != root && !path.startsWith(prefix)) {
    return _EvidenceCheck(ok: false, error: '证据路径越出工作空间：$text');
  }
  final File file = File(path);
  if (!file.existsSync()) {
    return _EvidenceCheck(ok: false, error: '证据文件不存在：$text');
  }
  try {
    return _EvidenceCheck(
      ok: true,
      hash: sha256.convert(file.readAsBytesSync()).toString(),
    );
  } catch (error) {
    return _EvidenceCheck(ok: false, error: '证据读取失败：$text（$error）');
  }
}

bool _placeholder(String value) {
  final String text = value.trim().toLowerCase();
  return text.isEmpty ||
      text == '-' ||
      text == '—' ||
      text == '无' ||
      text == 'todo' ||
      text == 'tbd';
}

String _clip(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max)}…';
