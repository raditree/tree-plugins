// 插件公共骨架（**不属于任何插件**：目录里没有 plugin.json，装机合同与构建脚本都会跳过它）。
//
// 为什么要有这一份：仓库里过去有五个各自独立成文的 Python 示例，每个都自带一份
// "读循环 + 帧收发 + 假核心自检"。那五条副本各自漂——心跳漏答、异常不收敛、stdout
// 混日志这类问题在不同示例里表现不同，而**协议本身没有不同**。改成一个插件一个文件、
// 骨架只有一份：插件里只剩"这个插件干什么"，三条铁律在这里一次做对。
//
// 三条铁律（docs/plugin-development.md §1，写任何插件都不能破）的落点：
//   1. **stdout 只有协议帧**：只有 [PluginChannel.send] 往输出面写字节，日志一律走
//      [PluginChannel.log]（stderr）；自检把两面都换掉，但**仍然分开**——同一形状。
//   2. **读循环从不 await 业务**：每条请求 / 通知都挂在 unawaited 上，处理慢活时
//      `ping` 照样进得来、答得出（核心的心跳判活与中转请求的等待期都靠它续期）。
//   3. **异常必须收敛成响应**：处理器抛出 ⇒ 回 `-32603`，绝不让核心的在途请求挂住。
//
// 依赖纪律：只用 `dart:` SDK。插件要能被第三方独立编译，所以这里**不** import
// `package:tree_core` / `package:tree_protocol`。方法名这张表 [M] 与核心的
// `PluginRpcMethods` 由 `packages/tree_protocol/test/plugin_rpc_method_gate_test.dart`
// 逐字对齐——漂了那条门禁用例当场红，而不是到运行时报"未知方法"。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 插件侧用到的**方法名**（硬编码字面量，理由见文件头"依赖纪律"）。
///
/// 名字的家在核心侧：`tree_protocol` 的 `PluginRpcMethods`。这里只列**本骨架会用到的**
/// 那些，方向与它保持同一份语义（新增方法前先问"它属于哪一面"）。
abstract final class M {
  // ── 核心 → 插件（下行，插件必须实现）──────────────────────────────
  static const String hello = 'hello';
  static const String toolsList = 'tools/list';
  static const String toolsCall = 'tools/call';
  static const String ping = 'ping';
  static const String stationRequest = 'station/request';
  static const String stationCancel = 'station/cancel';
  static const String event = 'event';
  static const String shutdown = 'shutdown';

  /// 优雅挂起：核心请插件"把可续跑状态转储出来然后退出"。
  static const String suspend = 'suspend';

  // ── 插件 → 核心（上行请求，核心必须应答）─────────────────────────
  static const String stationCommand = 'station/command';
  static const String stationSubscribe = 'station/subscribe';
  static const String stationUnsubscribe = 'station/unsubscribe';
  static const String stationRegister = 'station/register';
  static const String stationUnregister = 'station/unregister';
  static const String stationTrigger = 'station/trigger';

  // ── 插件 → 核心（上行通知，不等应答）─────────────────────────────
  static const String stationStream = 'station/stream';
  static const String log = 'log';
}

/// **执行站命令名**（走 [M.stationCommand]，不是 method；D10 的口径）。
abstract final class Cmd {
  /// 递一份可续跑快照进核心的内存池（D4：只进内存，不落盘）。
  static const String stateDump = 'plugin.stateDump';

  /// 新一世取回上一世的快照（拿不到就按冷启动继续）。
  static const String stateFetch = 'plugin.stateFetch';
}

/// **插件 UI 的约定 method**（走通知，不是请求；也不在 `PluginRpcMethods` 里）。
///
/// 为什么单独一张表而不挂进 [M]：UI 帧的家在 `PluginUiFrameType`（核心把这两个
/// 通知转成前端帧），它们不是插件↔核心的 RPC 登记面。混进 [M] 会让那条门禁用例
/// 把"已登记的 UI method"误报成"未登记的协议方法"，于是两边谁也不信谁。
abstract final class Ui {
  /// 完整声明本插件的全部槽位（**发一次就够**：前端重连由核心按缓存补发）。
  static const String manifest = 'ui/manifest';

  /// 按 `slot_key` **整块替换**一个槽位的视图（`view: null` = 注销）。
  static const String update = 'ui/update';
}

/// 受限控件集（与核心 `PluginUiViewType.all` 逐字对齐；漂了由
/// `packages/tree_protocol/test/plugin_repo_contract_test.dart` 当场红）。
///
/// 为什么骨架要自带这份清单与校验：面板视图不合法的代价不在插件这边——核心
/// 要么整帧拒发、要么把未知类型当占位渲染，而插件自己看到的是"声明成功了"。
/// 三个插件都要造视图，校验写三遍就只会三种写法各自吞错。
const List<String> kUiViewTypes = <String>[
  'text',
  'list',
  'table',
  'form',
  'progress',
  'actions',
  'row',
  'column',
];

/// 自检用：递归查一个视图节点合不合法，返回**可读问题清单**（空 = 合法）。
///
/// 只查协议里真会拒的那几条（类型在集内、text 非空、表格列数与单元格数相符、
/// progress 在 0~1、actions 每个按钮都有 action_id + label）——**不拿它当渲染器写**，
/// 渲染口径的权威在核心侧。
List<String> validateUiView(Object? node, [String path = 'view']) {
  if (node is! Map) return <String>['$path 不是对象'];
  final Map<String, dynamic> view = asMap(node);
  final String kind = asString(view['type']);
  if (!kUiViewTypes.contains(kind)) {
    return <String>['$path 的类型「$kind」不在受限控件集内（${kUiViewTypes.join(' / ')}）'];
  }
  final List<String> problems = <String>[];
  switch (kind) {
    case 'text':
      if (asString(view['text']).isEmpty) problems.add('$path 是空文本');
    case 'table':
      final Object? columns = view['columns'];
      final Object? rows = view['rows'];
      if (columns is! List || columns.isEmpty) {
        problems.add('$path 表格缺列名');
      }
      if (rows is! List) {
        problems.add('$path 表格缺 rows');
      } else if (columns is List) {
        for (int index = 0; index < rows.length; index++) {
          final Object? row = rows[index];
          if (row is! List || row.length != columns.length) {
            problems.add('$path 第 ${index + 1} 行的单元格数与本列表不符');
          }
        }
      }
    case 'progress':
      final Object? value = view['value'];
      final double number = value is num ? value.toDouble() : double.nan;
      if (number.isNaN || number < 0 || number > 1) {
        problems.add('$path 的 progress.value 必须在 0~1：$value');
      }
    case 'actions':
      final Object? buttons = view['buttons'];
      if (buttons is! List || buttons.isEmpty) {
        problems.add('$path 的 actions 没有按钮');
      } else {
        for (int index = 0; index < buttons.length; index++) {
          final Map<String, dynamic> button = asMap(buttons[index]);
          if (asString(button['action_id']).isEmpty ||
              asString(button['label']).isEmpty) {
            problems.add('$path 第 ${index + 1} 个按钮缺 action_id / label');
          }
        }
      }
  }
  final Object? children = view['children'];
  if (children is List) {
    for (int index = 0; index < children.length; index++) {
      problems.addAll(
        validateUiView(children[index], '$path.children[$index]'),
      );
    }
  }
  return problems;
}

/// 一帧 → 一行字节（行分隔 JSON，UTF-8，`\n` 结尾）。
List<int> encodeFrame(Map<String, dynamic> frame) => <int>[
  ...utf8.encode(json.encode(frame, toEncodable: _encodable)),
  10,
];

Object _encodable(Object? value) => value.toString();

/// 一行 → 一条报文；空行 / 非法 JSON 返回 null（读循环留痕后跳过）。
Map<String, dynamic>? decodeFrame(String line) {
  final String text = line.trim();
  if (text.isEmpty) return null;
  try {
    final Object? decoded = json.decode(text);
    return decoded is Map ? asMap(decoded) : null;
  } catch (_) {
    return null;
  }
}

/// 宽松取 Map（从别处传来时可能是 `Map`，也可能是 null）。
Map<String, dynamic> asMap(Object? value) => value is Map
    ? value.map(
        (Object? key, Object? v) =>
            MapEntry<String, dynamic>(key.toString(), v),
      )
    : <String, dynamic>{};

/// 宽松取字符串并 trim（缺失 / null → 空串，**不猜默认值**）。
String asString(Object? value) => (value ?? '').toString().trim();

/// 宽松取一段 JSON **对象**：已是 Map 就剥一层，是字符串就解析，都不像就回空 Map。
///
/// 为什么在骨架里：插件读工具参数、读执行站回包、读点位事件，到处都要"把这块东西变成
/// Map"，而**解析失败不是异常**（铁律 3 说的是处理器抛出要收敛成响应，不是让数据问题
/// 去炸读循环）。每个插件各自 `try { json.decode }` 的结局是五种写法五种吞法。
Map<String, dynamic> asJson(Object? value) {
  if (value is Map) return asMap(value);
  final String text = asString(value);
  if (text.isEmpty) return <String, dynamic>{};
  try {
    final Object? decoded = json.decode(text);
    return decoded is Map ? asMap(decoded) : <String, dynamic>{};
  } catch (_) {
    return <String, dynamic>{};
  }
}

/// 执行站命令失败（原因已经是人话，直接转给日志或回包）。
class CmdFailureException implements Exception {
  CmdFailureException(this.message, [this.payload = const <String, Object?>{}]);
  final String message;

  /// 失败回包里**一并递回来的那份结果**。
  ///
  /// 为什么挂在异常上而不是只留一句 error：核心的 `llm.call` 在“调用失败”时也会把
  /// `text` / `error_kind` / `truncated_suspect` 放进 payload（`StationCommandOutcome
  /// .failedWith`，见 execute_mounts 的注释与 known-issues #31）——那是插件本地修复的
  /// **唯一依据**。只把 error 抛出去就等于在这一跳把已经付过费的那次调用丢掉（现场：
  /// 448k prompt 的总结已回来、只是正文不是合法 json，插件报“原文 0 字”当场弃权）。
  final Map<String, Object?> payload;

  @override
  String toString() => message;
}

/// 插件的 JSON-RPC 通道：协议面（[send]）与日志面（[log]）从构造起就是两条路。
class PluginChannel {
  PluginChannel({
    required this.logTag,
    void Function(List<int> bytes)? onWrite,
    void Function(String line)? onError,
  }) : _writeOut = onWrite,
       _writeError = onError;

  /// 生产用的通道（stdout = 协议面，stderr = 日志面）。
  factory PluginChannel.stdio(String logTag) => PluginChannel(
    logTag: logTag,
    onWrite: (List<int> bytes) {
      try {
        // 刻意不在每帧后 flush()：stdout.flush() 会把底层 sink 标成 "bound"，
        // 同一批到达的多帧再 add 时就抛 Bad state: StreamSink is bound to a stream
        //（tree_ssh_plugin 实测：stdin 是管道、多帧一次到齐时必现）。
        stdout.add(bytes);
      } catch (error) {
        // 对端已关（核心退出 / 管道被关）：写不出去不算错误，只留一行日志。
        stderr.writeln('[$logTag] 写 stdout 失败：$error');
      }
    },
    onError: (String line) => stderr.writeln(line),
  );

  final String logTag;
  void Function(List<int> bytes)? _writeOut;
  void Function(String line)? _writeError;

  int _nextId = 0;
  final Map<String, Completer<Map<String, dynamic>>> _pending =
      <String, Completer<Map<String, dynamic>>>{};

  /// 自检专用：把两个面改指到内存（**协议面与日志面依旧分开**，与生产同一形状）。
  void redirectTo({
    required void Function(List<int> bytes) out,
    required void Function(String line) error,
  }) {
    _writeOut = out;
    _writeError = error;
  }

  /// **协议面唯一的出口**：一行一条 JSON-RPC 报文。
  void send(Map<String, dynamic> frame) => _writeOut?.call(encodeFrame(frame));

  /// **日志面唯一的出口**。
  void log(String message) => _writeError?.call('[$logTag] $message');

  /// 回一条响应（`id` 用收到的原值——JSON-RPC 的对应关系就在这一位上）。
  void reply(Object? id, Map<String, dynamic> result) =>
      send(<String, dynamic>{'jsonrpc': '2.0', 'id': id, 'result': result});

  /// 回一条错误响应。**必须且只能回一条**：不让核心的在途请求挂住。
  void replyError(Object? id, int code, String message) =>
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'error': <String, dynamic>{'code': code, 'message': message},
      });

  /// 发一条通知（有 method、无 id）。
  void notify(String method, Map<String, dynamic> params) => send(
    <String, dynamic>{'jsonrpc': '2.0', 'method': method, 'params': params},
  );

  /// 向核心主动发一条请求并等回包。
  ///
  /// **无静态总超时**（不变量 8）：核心的在途请求同样没有时长上限，这里自己造一个
  /// 只会产生"核心还在做、插件已放弃"的双账。要放弃请显式取消。
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) {
    final String id = 'plugin-req-${++_nextId}';
    final Completer<Map<String, dynamic>> completer =
        Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    send(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    return completer.future.whenComplete(() => _pending.remove(id));
  }

  /// 下执行站命令，并把**命令的 payload** 交回来（外层信封已由核心剥掉）。
  ///
  /// [scope] 是**这一次命令的身份**（`agent_id` / `session_id` / `team_id` / `mode_key`）：
  /// 写进 params 顶层，不是 `arguments` 里。原因是核心的口径就是"单实例 + 每条消息
  /// 带身份"，team / mode 由它按目标 agent 的**真实归属**解析（插件声明只是上限）；
  /// 把身份塞进 `arguments` 也能过（那里也读），但两份真相写同一个东西一定漂。
  ///
  /// 失败（未接线 / 归属不成立 / 未知命令）以 [CmdFailureException] 抛出，携带可读原因
  /// **与失败回包里的 payload**（两者都不能丢，见 [CmdFailureException.payload]）。
  Future<Map<String, dynamic>> command(
    String command, [
    Map<String, dynamic> arguments = const <String, dynamic>{},
    String stationId = '',
    Map<String, dynamic> scope = const <String, dynamic>{},
  ]) async {
    final Map<String, dynamic> params = <String, dynamic>{
      if (stationId.isNotEmpty) 'station_id': stationId,
      'command': command,
      'arguments': arguments,
      // 空值不写：写了 `agent_id: ''` 在核心那边是"声明了一个不存在的 agent"。
      for (final MapEntry<String, dynamic> entry in scope.entries)
        if ('${entry.value}'.trim().isNotEmpty) entry.key: entry.value,
    };
    final Map<String, dynamic> response = await request(
      M.stationCommand,
      params,
    );
    final Object? error = response['error'];
    if (error != null && error.toString().isNotEmpty) {
      // **失败也要把 payload 带走**（不带走 = 插件只能弃权，见 [CmdFailureException.payload]）。
      final Object? payload = response['payload'];
      throw CmdFailureException(
        error.toString(),
        payload is Map ? asMap(payload) : const <String, Object?>{},
      );
    }
    final Object? payload = response['payload'];
    return payload is Map ? asMap(payload) : response;
  }

  /// 通道断开时收敛在途请求（调用方的 await 拿到异常，而不是永远悬着）。
  void rejectPending(String reason) {
    for (final Completer<Map<String, dynamic>> completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(CmdFailureException(reason));
      }
    }
    _pending.clear();
  }

  /// 读循环把"核心对我方主动请求的回包"（有 id、无 method）交到这里。
  void completeResponse(Map<String, dynamic> message) {
    final String? id = message['id']?.toString();
    if (id == null) return;
    final Completer<Map<String, dynamic>>? waiting = _pending.remove(id);
    if (waiting == null || waiting.isCompleted) return;
    final Object? error = message['error'];
    if (error is Map) {
      waiting.completeError(
        CmdFailureException(
          '${error['code'] ?? '?'} ${error['message'] ?? ''}',
        ),
      );
      return;
    }
    waiting.complete(asMap(message['result']));
  }
}

/// `tools/call` 的结果形状。
Map<String, dynamic> toolText(String text, {bool isError = false}) =>
    <String, dynamic>{
      'content': <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'text': text},
      ],
      'isError': isError,
    };

/// 一个插件服务：**骨架在这里，业务由回调递进来**。
///
/// `hello` / `ping` / `tools/list` / `suspend` / `shutdown` 由骨架统一回答——它们没有
/// 插件特异性，而**答错一次就是整条插件不可用**（心跳漏答会被打成 degraded、hello
/// 报不上身份就永远收不到事件）。其余请求交给 [onRequest]，通知交给 [onNotify]，
/// 工具交给 [onToolCall]。
class PluginKitServer {
  PluginKitServer({
    required this.channel,
    required this.pluginId,
    required this.displayName,
    this.capabilities = const <String>['tools'],
    this.tools = const <Map<String, dynamic>>[],
    this.onToolCall,
    this.onRequest,
    this.onNotify,
    this.onReady,
    this.onResume,
    this.dumpState,
    this.onStop,
    this.exitOnSuspend = true,
    this.exitOnShutdown = true,
  });

  final PluginChannel channel;

  /// 自报的兜底 id：`hello` 的 params 带来 `plugin_id` 时**以核心给的为准**
  /// （核心才是实例归属的权威，插件自述一律不采信）。
  final String pluginId;
  final String displayName;
  final List<String> capabilities;

  /// `tools/list` 的申报面（模型看到的名字由核心加 `plugin__<插件id>__` 前缀）。
  final List<Map<String, dynamic>> tools;

  /// 工具执行：返回 [toolText] 形状；未知工具请回 `isError: true` + 可读原因。
  final Map<String, dynamic> Function(
    String name,
    Map<String, dynamic> arguments,
  )?
  onToolCall;

  /// 骨架不认识的方法（`station/request` …）。返回 null = 让骨架回 `-32601`；
  /// 抛异常由骨架收敛成 `-32603`。
  final Future<Map<String, dynamic>?> Function(
    String method,
    Map<String, dynamic> params,
  )?
  onRequest;

  /// 通知（有 method、无 id）。返回 [FutureOr] 是为了让骨架能真的等完它再收尾，
  /// 而不是“看起来发了、其实插件还在跑”——但读循环本身从不 await 它（铁律 2）。
  final FutureOr<void> Function(String method, Map<String, dynamic> params)?
  onNotify;

  /// 握手完成后（核心已认身份）：订阅点位、声明 UI 槽位都从这里主动发请求。
  final Future<void> Function(PluginKitServer server)? onReady;

  /// 新一世取回了上一世的快照（没有快照就不会调这里）。
  final void Function(PluginKitServer server, Map<String, dynamic> snapshot)?
  onResume;

  /// 本世要交出去的可续跑状态（`suspend` 时递给 `plugin.stateDump`）。
  /// 返回 null = 声明"这一世没有值得续的东西"，骨架只 ack 不转储。
  final Map<String, dynamic>? Function()? dumpState;

  /// stdin 关闭 / shutdown / suspend 时的收尾（刷盘、关句柄）。
  final Future<void> Function()? onStop;

  /// 转储完成后是否自己退出进程（生产必须 true；自检里关掉以便继续断言）。
  final bool exitOnSuspend;

  /// 收到 `shutdown` 是否退出（同上）。
  final bool exitOnShutdown;

  /// 本世运行期数据（插件业务自己往里放；骨架除 [dumpState] 外不碰它）。
  final Map<String, Object?> state = <String, Object?>{};

  /// 核心交给本世的上一世快照 id（hello params；为空 = 冷启动）。
  String get resumeDumpId => _resumeDumpId;
  String _resumeDumpId = '';

  /// 核心认定的插件 id（hello 之后才有值）。
  String get effectivePluginId => _pluginId.isNotEmpty ? _pluginId : pluginId;
  String _pluginId = '';

  bool _stopping = false;

  /// 跑读循环。[input] 是字节流：生产传 `stdin`，自检传内存流（**同一套代码**）。
  Future<void> run(Stream<List<int>> input) async {
    channel.log('已启动，等待核心 hello（stdout 只走 JSON-RPC）');
    await for (final String line
        in input.transform(utf8.decoder).transform(const LineSplitter())) {
      final Map<String, dynamic>? message = decodeFrame(line);
      if (message == null) {
        if (line.trim().isNotEmpty) {
          channel.log('收到非 JSON 行（跳过）：${_clip(line)}');
        }
        continue;
      }
      final Object? id = message['id'];
      final Object? rawMethod = message['method'];
      final Map<String, dynamic> params = asMap(message['params']);
      if (rawMethod is! String || rawMethod.isEmpty) {
        // 核心对我方主动请求的回包（有 id、无 method）。
        if (id != null) channel.completeResponse(message);
        continue;
      }
      if (id == null) {
        // 通知：`shutdown` 由骨架收，其余不 await 地交给插件。
        if (rawMethod == M.shutdown && exitOnShutdown) {
          channel.log('收到 shutdown，退出');
          await _stopNow();
          break;
        }
        unawaited(_runNotify(rawMethod, params));
        continue;
      }
      // **另起一个异步任务**：读循环不能被子进程里的慢活占住（否则 ping 进不来）。
      unawaited(_handleRequest(id, rawMethod, params));
    }
    channel.log('stdin 已关闭（核心退出？），插件退出');
    channel.rejectPending('通道已关闭');
    await _stopNow();
  }

  Future<void> _handleRequest(
    Object id,
    String method,
    Map<String, dynamic> params,
  ) async {
    try {
      switch (method) {
        case M.hello:
          final String given = asString(params['plugin_id']);
          _pluginId = given.isEmpty ? pluginId : given;
          _resumeDumpId = asString(params['resume_dump_id']);
          channel.reply(id, <String, dynamic>{
            'plugin_id': effectivePluginId,
            'name': displayName,
            'capabilities': capabilities,
          });
          channel.log('握手完成：plugin_id=$effectivePluginId');
          // 新一世开局就来取回上一世的快照：核心把 id 放在 hello 的 **params** 里
          //（hello 是下行请求，插件无从知道池里有什么），所以取回只能由插件主动。
          if (_resumeDumpId.isNotEmpty) await _fetchResume();
          await onReady?.call(this);
          return;
        case M.ping:
          // 心跳：内容不看，**回了就算活着**（这里绝不做慢活）。
          channel.reply(id, <String, dynamic>{'ok': true});
          return;
        case M.toolsList:
          channel.reply(id, <String, dynamic>{'tools': tools});
          return;
        case M.toolsCall:
          final String name = asString(params['name']);
          final Map<String, dynamic> result =
              onToolCall?.call(name, asMap(params['arguments'])) ??
              toolText('未知工具 $name', isError: true);
          channel.reply(id, result);
          return;
        case M.suspend:
          await _handleSuspend(id);
          return;
        default:
          final Future<Map<String, dynamic>?> Function(
            String,
            Map<String, dynamic>,
          )?
          handler = onRequest;
          final Map<String, dynamic>? result = await handler?.call(
            method,
            params,
          );
          if (result == null) {
            channel.replyError(id, -32601, 'method not found: $method');
            return;
          }
          channel.reply(id, result);
      }
    } catch (error, stack) {
      // 异常**必须**变成响应：让核心挂住等于让整条生成挂住。
      channel.log('处理器异常（$method）：$error\n$stack');
      channel.replyError(id, -32603, '处理器异常：$error');
    }
  }

  /// `suspend`：先递快照、**再**回 ack，然后自己退出。
  ///
  /// 顺序是刻意的：核心因此不需要"等时长"就能确定快照已入池（两阶段关闭，D3）。
  Future<void> _handleSuspend(Object id) async {
    final Map<String, dynamic>? payload = dumpState?.call();
    if (payload != null) {
      try {
        final Map<String, dynamic> result = await channel.command(
          Cmd.stateDump,
          <String, dynamic>{'payload': payload},
        );
        channel.log(
          '快照已入池：dump_id=${asString(result['dump_id'])} '
          'bytes=${asString(result['bytes'])}',
        );
      } catch (error) {
        // 递不出去也要 ack 并说清原因：让核心等下去是更坏的结果（它会按"不可挂起"
        // 处理，走冷启动重启）。
        channel.reply(id, <String, dynamic>{
          'ok': false,
          'dumped': false,
          'error': '$error',
        });
        channel.log('转储失败（按不可挂起收尾）：$error');
        return;
      }
    }
    channel.reply(id, <String, dynamic>{'ok': true, 'dumped': payload != null});
    await _stopNow();
    if (exitOnSuspend) exit(0);
  }

  Future<void> _fetchResume() async {
    try {
      final Map<String, dynamic> result = await channel.command(Cmd.stateFetch);
      if (result['has_snapshot'] == true) {
        channel.log('已取回上一世快照：dump_id=${asString(result['dump_id'])}');
        onResume?.call(this, asMap(result['payload']));
        return;
      }
      channel.log('池里没有本插件上一世的快照（按冷启动继续）');
    } catch (error) {
      // 取不回不算致命错误：按冷启动继续，但**必须留一行**——否则"为什么我的上下文
      // 没了"又会变成一个查不出来的问题。
      channel.log('取回快照失败（按冷启动继续）：$error');
    }
  }

  Future<void> _runNotify(String method, Map<String, dynamic> params) async {
    try {
      await onNotify?.call(method, params);
    } catch (error, stack) {
      channel.log('通知处理异常（$method）：$error\n$stack');
    }
  }

  Future<void> _stopNow() async {
    if (_stopping) return;
    _stopping = true;
    final Future<void> Function()? stop = onStop;
    if (stop == null) return;
    try {
      await stop();
    } catch (error) {
      channel.log('收尾异常：$error');
    }
  }

  static String _clip(String text) =>
      text.length <= 200 ? text : '${text.substring(0, 200)}…';
}

/// 假核心自检：在**同一个进程里**把字节流两端接起来，收发都走真协议面。
///
/// 为什么值得单独一份：`--selftest` 是"装机后端到端验证"读退出码的那条路，必须与
/// 真进程跑同一套代码（包括那个读循环）——另写一套 mock 就等于自检绿了真核心照样能挂。
class FakeCore {
  FakeCore(PluginKitServer server) : _server = server {
    server.channel.redirectTo(out: _onBytes, error: _logs.add);
  }

  final PluginKitServer _server;
  final StreamController<List<int>> _toPlugin = StreamController<List<int>>();
  final List<Map<String, dynamic>> _received = <Map<String, dynamic>>[];
  final List<String> _logs = <String>[];
  final Set<String> _answered = <String>{};
  final Map<String, Map<String, dynamic> Function(Map<String, dynamic> params)>
  _rules =
      <String, Map<String, dynamic> Function(Map<String, dynamic> params)>{};

  void _onBytes(List<int> bytes) {
    for (final String line in utf8.decode(bytes).split('\n')) {
      final Map<String, dynamic>? frame = decodeFrame(line);
      if (frame == null) continue;
      _received.add(frame);
      _autoAnswer(frame);
    }
  }

  /// 自动应答：插件**主动发的请求**（有 method、有 id）撞上已装规则就当场答一句。
  ///
  /// 为什么需要它：探针 / 压缩这类插件会**持续**下命令（每拍一次 `terminal.exec`），
  /// 手写"轮询到一条、答一条"会把自检写成一台时序机器，而它真正要断言的是**形状**。
  /// 规则按 method 装、按 params 造回包，所以同一条 method 的不同请求可以拿到不同结果。
  void _autoAnswer(Map<String, dynamic> frame) {
    final Object? id = frame['id'];
    final Object? method = frame['method'];
    if (id == null || method is! String || _toPlugin.isClosed) return;
    final Map<String, dynamic> Function(Map<String, dynamic> params)? build =
        _rules[method];
    if (build == null) return;
    _toPlugin.add(
      encodeFrame(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'result': build(asMap(frame['params'])),
      }),
    );
  }

  /// 装一条自动应答规则（[build] 收到那条请求的 params，返回回包的 `result`）。
  void onMethod(
    String method,
    Map<String, dynamic> Function(Map<String, dynamic> params) build,
  ) {
    _rules[method] = build;
  }

  /// 跑起插件的读循环（不 await：它就是一条一直在听的服务）。
  Future<void> start() => _server.run(_toPlugin.stream);

  /// 核心 → 插件：一条请求。
  void ask(
    Object id,
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) {
    _toPlugin.add(
      encodeFrame(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
  }

  /// 核心 → 插件：一条通知。
  void notify(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
  ]) {
    _toPlugin.add(
      encodeFrame(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': method,
        'params': params,
      }),
    );
  }

  /// 回答插件主动发来的**第一条**该 method 的请求（订阅 / 执行站命令都走这里）。
  ///
  /// 同一个 method 的多条请求要分次答：每次调用答一条最早的未答请求。
  void answer(String method, Map<String, dynamic> result) {
    for (final Map<String, dynamic> frame in _received) {
      if (frame['method'] != method) continue;
      final Object? id = frame['id'];
      if (id == null) continue;
      final String key = '$method#$id';
      if (!_answered.add(key)) continue;
      _toPlugin.add(
        encodeFrame(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'result': result,
        }),
      );
      return;
    }
  }

  /// 轮询等"这些 id 的响应都到齐"（插件内部是异步任务，所以轮询而不是直接读）。
  Future<Map<Object?, Map<String, dynamic>>> waitFor(
    Iterable<Object?> ids, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final Set<Object?> want = ids.toSet();
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final Map<Object?, Map<String, dynamic>> got = responses();
      if (want.every(got.containsKey)) return got;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return responses();
  }

  /// 已收到的响应（按 id 取；错误响应也在里面，带 `error` 键）。
  Map<Object?, Map<String, dynamic>> responses() {
    final Map<Object?, Map<String, dynamic>> byId =
        <Object?, Map<String, dynamic>>{};
    for (final Map<String, dynamic> frame in _received) {
      if (frame['method'] != null) continue;
      final Object? id = frame['id'];
      if (id == null) continue;
      byId[id] = frame;
    }
    return byId;
  }

  /// 插件主动发过来的帧（有 method）：订阅、申报、推流都在这里断言。
  List<Map<String, dynamic>> outgoing([String? method]) => _received
      .where(
        (Map<String, dynamic> frame) =>
            frame['method'] != null &&
            (method == null || frame['method'] == method),
      )
      .toList();

  /// 插件发出的**全部帧，按到达顺序**：要断言"A 必须排在 B 之前"（转储请求 vs 挂起
  /// 的 ack）只能用这个——[outgoing] 滤掉了响应、[responses] 按 id 去过重，两边都
  /// 看不出先后，而**时序恰恰是这类断言的全部内容**。
  List<Map<String, dynamic>> get frames =>
      List<Map<String, dynamic>>.unmodifiable(_received);

  /// 插件日志面（失败时整段打出来：只说"没回包"查不出为什么）。
  List<String> get logs => List<String>.unmodifiable(_logs);

  /// 关掉喂给插件的流（等价于核心退出）。
  Future<void> close() => _toPlugin.close();
}

/// `--selftest` 的统一输出面：逐条结论 + 退出码。
///
/// 口径：**成功退 0、有失败项退 非 0**，并且每一条都要留下名字——"全部通过"必须
/// 能数得出来通过了哪几条，否则加一条用例就少一条证据。
class SelfTest {
  SelfTest({required this.name, void Function(String line)? emit})
    : _emit = emit ?? ((String line) => stderr.writeln(line));

  final String name;
  final void Function(String line) _emit;
  final List<String> _failures = <String>[];
  int _passed = 0;

  /// 逐字比较（拿 JSON 往返做深比较，避开 Map / List 的引用相等陷阱）。
  void check(Object? got, Object? want, String what) {
    if (_same(got, want)) {
      _passed++;
      _emit('[OK] $what');
      return;
    }
    _failures.add('$what：期望 ${_show(want)}，实得 ${_show(got)}');
    _emit('[FAIL] $what：期望 ${_show(want)}，实得 ${_show(got)}');
  }

  /// 只要一个条件成立（断言消息必须自带实际值，否则查不到现场）。
  void that(bool ok, String what, {String actual = ''}) {
    if (ok) {
      _passed++;
      _emit('[OK] $what');
      return;
    }
    _failures.add('$what${actual.isEmpty ? '' : '（$actual）'}');
    _emit('[FAIL] $what${actual.isEmpty ? '' : '（$actual）'}');
  }

  /// 打印插件日志（失败时才打，绿的时候不要掘场）。
  void dumpLogs(List<String> logs) {
    if (_failures.isEmpty || logs.isEmpty) return;
    _emit('— 插件日志 —');
    for (final String line in logs) {
      _emit('  $line');
    }
  }

  /// 收尾：返回退出码。[logs] 传进来时，失败项会附带插件日志。
  int finish([List<String> logs = const <String>[]]) {
    dumpLogs(logs);
    _emit(
      '$name 自检：${_failures.isEmpty ? '全部通过' : '有失败项'}'
      '（$_passed 通过 / ${_failures.length} 失败）',
    );
    return _failures.isEmpty ? 0 : 1;
  }

  static bool _same(Object? a, Object? b) {
    if (identical(a, b)) return true;
    try {
      return json.encode(a) == json.encode(b);
    } catch (_) {
      return a.toString() == b.toString();
    }
  }

  static String _show(Object? value) {
    final String text = value is String ? value : json.encode(value);
    return text.length <= 160 ? text : '${text.substring(0, 160)}…';
  }
}
