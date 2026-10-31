/// 流式管道固定压测（L-06 / G-6，known-issues #40）。
///
/// 只量**生成 → 攒帧合并 → 广播**这一条管道，不碰网络、不碰真端点：
/// - 引擎按脚本逐 token 吐字（token = 2 字符，与 `defaultTokenScale` 同口径）；
/// - token 管道（[TokenPacer]）按 `--rates` 给的 token/s 节流（模拟端点吐字节奏）；
/// - 攒帧（`_ChunkPump`）按 `--fps` 给的帧率合并 `msg_chunk`；
/// - 量：首帧延迟、每帧 token 数、实际帧率、整轮耗时、进程 CPU 占比。
///
/// 口径固定（同一 prompt / 同一模型档 / 同一会话长度），因此每一次跑出的数字
/// **可以和历史记录直接对比**。迁移前（核心内置实现）的实测数据不可得（实现已随
/// A5 撤走且当时未留档），本脚本建立的是一条"从今天起可复现"的基线：
/// 同一台机器、同一份脚本、同一组参数，重跑即可判定"是否变慢"。
///
/// 用法（插件包根目录）：
/// ```powershell
/// dart run tool/bench_stream_pipeline.dart
/// dart run tool/bench_stream_pipeline.dart --tokens=512 --history=80 --runs=5
/// dart run tool/bench_stream_pipeline.dart --out=tool/bench_baseline.json
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tree_agent_loop/src/agent/agent_engine.dart';
import 'package:tree_agent_loop/src/agent/conversation_service.dart';
import 'package:tree_agent_loop/src/compat/protocol_types.dart';
import 'package:tree_agent_loop/src/settings/core_settings.dart';
import 'package:tree_agent_loop/src/store/memory_store.dart';
import 'package:tree_agent_loop/src/store/tree_store.dart';
import 'package:tree_agent_loop/src/util/tokens.dart';
import 'package:tree_agent_loop/src/ws/ws_hub.dart';

/// 一个字符对应几个 token 的固定口径（与 [defaultTokenScale] 同值）。
const double _tokenScale = defaultTokenScale;

/// 每条正文 token 的字符数。
const int _charsPerToken = 2;

/// 某一帧的到达记录（只记 `msg_chunk`）。
class _Frame {
  _Frame(this.atMicros, this.chars);

  /// 相对本轮起点的到达时刻（微秒）。
  final int atMicros;

  /// 这一帧的字符数（token 数由 [_tokenScale] 换算）。
  final int chars;

  int get tokens => estimateTokensFromChars(chars, scale: _tokenScale);
}

/// 只记录、不发送的 hub（与 `test/conversation_stream_seq_test.dart` 同一形态）。
class _RecordingHub extends WsHub {
  _RecordingHub(this.onChunk);

  final void Function(String chunk) onChunk;

  @override
  void broadcast(Map<String, dynamic> frame) {
    if (frame['type'] == WsOutboundType.msgChunk) {
      onChunk(frame['chunk'] as String? ?? '');
    }
  }
}

/// 按脚本一次性产出全部事件（不模拟端点自身的延迟；节奏由 TokenPacer 负责）。
class _ScriptEngine implements AgentEngine {
  _ScriptEngine(this.events);

  final List<AgentEvent> events;

  @override
  Stream<AgentEvent> run(
    AgentRunContext context, {
    required bool Function() isCancelled,
  }) async* {
    for (final AgentEvent event in events) {
      yield event;
    }
  }

  @override
  Future<void> close() async {}
}

/// 单次跑的原始结果。
class _RunResult {
  _RunResult({
    required this.firstChunkMicros,
    required this.totalMicros,
    required this.frames,
  });

  final int firstChunkMicros;
  final int totalMicros;
  final List<_Frame> frames;

  int get frameCount => frames.length;

  int get tokensPerFrameMax =>
      frames.fold<int>(0, (int m, _Frame f) => f.tokens > m ? f.tokens : m);

  double get tokensPerFrameAvg =>
      frames.isEmpty ? 0 : _totalTokens / frames.length;

  int get _totalTokens => frames.fold<int>(0, (int s, _Frame f) => s + f.tokens);

  double get framesPerSecond => totalMicros == 0
      ? 0
      : frameCount / (totalMicros / Duration.microsecondsPerSecond);
}

/// 一组参数的多轮汇总（时间取中位数，每帧 token 取最差）。
class _Scenario {
  _Scenario({
    required this.tokenRate,
    required this.frameRate,
    required this.runs,
    required this.cpuPercent,
    required this.wallMillis,
  });

  final int tokenRate;
  final int frameRate;
  final List<_RunResult> runs;
  final double? cpuPercent;
  final int wallMillis;

  double get windowMs => 1000 / frameRate;

  int get firstChunkMsMedian => _median(
    runs.map((_RunResult r) => r.firstChunkMicros / 1000).toList(),
  );

  int get totalMsMedian => _median(
    runs.map((_RunResult r) => r.totalMicros / 1000).toList(),
  );

  int get framesMedian => _median(
    runs.map((_RunResult r) => r.frameCount.toDouble()).toList(),
  );

  double get tokensPerFrameAvg =>
      runs.fold<double>(0, (double s, _RunResult r) => s + r.tokensPerFrameAvg) /
      runs.length;

  int get tokensPerFrameMax =>
      runs.fold<int>(0, (int m, _RunResult r) => r.tokensPerFrameMax > m
          ? r.tokensPerFrameMax
          : m);

  double get framesPerSecondMedian => _medianDouble(
    runs.map((_RunResult r) => r.framesPerSecond).toList(),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'token_rate': tokenRate,
    'frame_rate': frameRate,
    'window_ms': windowMs,
    'runs': runs.length,
    'first_chunk_ms_median': firstChunkMsMedian,
    'total_ms_median': totalMsMedian,
    'frames_median': framesMedian,
    'tokens_per_frame_avg': _round1(tokensPerFrameAvg),
    'tokens_per_frame_max': tokensPerFrameMax,
    'frames_per_second_median': _round1(framesPerSecondMedian),
    'cpu_percent': cpuPercent == null ? null : _round1(cpuPercent!),
    'wall_ms': wallMillis,
  };
}

double _round1(double v) => (v * 10).round() / 10.0;

int _median(List<double> values) {
  if (values.isEmpty) return 0;
  final List<double> sorted = List<double>.of(values)..sort();
  final int mid = sorted.length ~/ 2;
  final double m = sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
  return m.round();
}

double _medianDouble(List<double> values) {
  if (values.isEmpty) return 0;
  final List<double> sorted = List<double>.of(values)..sort();
  final int mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

/// 进程累计 CPU 秒（仅 Windows 可得；其它平台返回 null 并在结果里注明）。
Future<double?> _processCpuSeconds() async {
  if (!Platform.isWindows) return null;
  try {
    final ProcessResult result = await Process.run('powershell', <String>[
      '-NoProfile',
      '-Command',
      '(Get-Process -Id $pid).TotalProcessorTime.TotalSeconds',
    ], stdoutEncoding: utf8);
    if (result.exitCode != 0) return null;
    return double.tryParse((result.stdout as String).trim());
  } on Object {
    return null;
  }
}

/// 跑一轮：起 store / hub / service，发一条用户消息，收集到达的每一帧。
Future<_RunResult> _runOnce({
  required int tokenRate,
  required int frameRate,
  required int outputTokens,
  required int historyMessages,
}) async {
  final MemoryStore store = MemoryStore();
  final CoreAgent agent = store.createAgent(name: '压测');
  const String sessionId = TreeStore.defaultSessionId;
  final int now = DateTime.now().millisecondsSinceEpoch;
  for (int i = 0; i < historyMessages; i++) {
    store.appendMessage(CoreMessage(
      id: 'h$i',
      agentId: agent.id,
      sessionId: sessionId,
      role: i.isEven ? 'user' : 'agent',
      content: '历史消息 $i：${'字' * 200}',
      timestamp: now + i,
    ));
  }

  final Stopwatch watch = Stopwatch();
  final List<_Frame> frames = <_Frame>[];
  final _RecordingHub hub = _RecordingHub((String chunk) {
    frames.add(_Frame(watch.elapsedMicroseconds, chunk.length));
  });
  final List<AgentEvent> events = <AgentEvent>[
    for (int i = 0; i < outputTokens; i++)
      AgentText('字' * _charsPerToken),
    const AgentUsage(<String, dynamic>{'total_tokens': 1}),
    const AgentDone(finishReason: 'stop'),
  ];
  final CoreSettings settings = CoreSettings(frameRate: frameRate)
    ..setTokenAcquisitionRate(tokenRate);
  final ConversationService service = ConversationService(
    store: store,
    hub: hub,
    settings: settings,
    engine: _ScriptEngine(events),
  );

  watch.start();
  await service.handleUserMessage(<String, dynamic>{
    'agent_id': agent.id,
    'content': '压测：请输出固定长度的正文',
    'session_id': sessionId,
  });
  final int totalMicros = watch.elapsedMicroseconds;
  watch.stop();
  await store.close();

  return _RunResult(
    firstChunkMicros: frames.isEmpty ? totalMicros : frames.first.atMicros,
    totalMicros: totalMicros,
    frames: frames,
  );
}

/// 一组参数：预热 1 轮（结果丢弃）+ [runs] 轮正式，同时量进程 CPU。
Future<_Scenario> _runScenario({
  required int tokenRate,
  required int frameRate,
  required int outputTokens,
  required int historyMessages,
  required int runs,
}) async {
  final double? cpuStart = await _processCpuSeconds();
  final Stopwatch wall = Stopwatch()..start();
  await _runOnce(
    tokenRate: tokenRate,
    frameRate: frameRate,
    outputTokens: outputTokens,
    historyMessages: historyMessages,
  );
  final List<_RunResult> results = <_RunResult>[];
  for (int i = 0; i < runs; i++) {
    results.add(await _runOnce(
      tokenRate: tokenRate,
      frameRate: frameRate,
      outputTokens: outputTokens,
      historyMessages: historyMessages,
    ));
  }
  wall.stop();
  final double? cpuEnd = await _processCpuSeconds();
  final double? cpuPercent = (cpuStart == null || cpuEnd == null)
      ? null
      : (cpuEnd - cpuStart) / (wall.elapsedMilliseconds / 1000.0) * 100;
  return _Scenario(
    tokenRate: tokenRate,
    frameRate: frameRate,
    runs: results,
    cpuPercent: cpuPercent,
    wallMillis: wall.elapsedMilliseconds,
  );
}

/// `--key=value` 取值；缺省用 [fallback]。
String _arg(List<String> args, String key, String fallback) {
  for (final String arg in args) {
    if (arg.startsWith('--$key=')) return arg.substring(key.length + 3);
  }
  return fallback;
}

List<int> _intList(String raw) => <int>[
  for (final String part in raw.split(','))
    if (part.trim().isNotEmpty) int.parse(part.trim()),
];

Future<void> main(List<String> args) async {
  final int outputTokens = int.parse(_arg(args, 'tokens', '256'));
  final int historyMessages = int.parse(_arg(args, 'history', '40'));
  final int runs = int.parse(_arg(args, 'runs', '3'));
  final List<int> rates = _intList(_arg(args, 'rates', '40,200,1000'));
  final List<int> fps = _intList(_arg(args, 'fps', '25,20'));
  final String outPath = _arg(args, 'out', '');

  stdout.writeln('流式管道压测（L-06 / G-6）：输出 $outputTokens token、'
      '历史 $historyMessages 条、每场景预热 1 + 正式 $runs 轮');
  stdout.writeln('token 速率 ${rates.join('/')} ｜ 帧率 ${fps.join('/')} ｜ '
      'CPU 口径：${Platform.isWindows ? '当前进程 TotalProcessorTime' : '本平台不可得'}');

  final List<_Scenario> scenarios = <_Scenario>[];
  for (final int rate in rates) {
    for (final int frame in fps) {
      scenarios.add(await _runScenario(
        tokenRate: rate,
        frameRate: frame,
        outputTokens: outputTokens,
        historyMessages: historyMessages,
        runs: runs,
      ));
    }
  }

  stdout.writeln('');
  stdout.writeln('| token/s | 帧率 | 窗口 | 首帧延迟 | 整轮 | 帧数 | token/帧 均 | token/帧 峰 | 实际帧率 | CPU |');
  stdout.writeln('| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |');
  for (final _Scenario s in scenarios) {
    stdout.writeln(
      '| ${s.tokenRate} | ${s.frameRate} | ${s.windowMs.toStringAsFixed(0)}ms'
      ' | ${s.firstChunkMsMedian}ms | ${s.totalMsMedian}ms'
      ' | ${s.framesMedian} | ${s.tokensPerFrameAvg.toStringAsFixed(1)}'
      ' | ${s.tokensPerFrameMax} | ${s.framesPerSecondMedian.toStringAsFixed(1)}'
      ' | ${s.cpuPercent == null ? 'n/a' : '${s.cpuPercent!.toStringAsFixed(1)}%'} |',
    );
  }

  final Map<String, Object?> report = <String, Object?>{
    'generated_at': DateTime.now().toIso8601String(),
    'platform': Platform.operatingSystem,
    'dart_version': Platform.version,
    'params': <String, Object?>{
      'output_tokens': outputTokens,
      'history_messages': historyMessages,
      'runs': runs,
      'chars_per_token': _charsPerToken,
      'token_scale': _tokenScale,
    },
    'scenarios': <Map<String, Object?>>[
      for (final _Scenario s in scenarios) s.toJson(),
    ],
  };
  if (outPath.isNotEmpty) {
    final File out = File(outPath);
    out.parent.createSync(recursive: true);
    out.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(report),
    );
    stdout.writeln('\nJSON 已写入 $outPath');
  } else {
    stdout.writeln('\n${const JsonEncoder.withIndent('  ').convert(report)}');
  }
}
