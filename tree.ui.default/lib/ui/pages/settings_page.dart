import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_version.dart';
import '../font_service.dart';
import '../text_scale_service.dart';
import '../../io/api_service.dart';
import '../../io/tray_service.dart';
import '../services/code_highlight.dart';
import '../services/editor_settings.dart';
import '../services/model_pool.dart';
import '../theme_service.dart';
import '../widgets/core_log_card.dart';
import '../widgets/plugin_settings_card.dart';

/// 设置页面（desktop 分支：账号/等级/密码/后端地址/注销 五组设置已删除）
///
/// 保留的设置项：
/// - token 获取帧率 / 推送刷新帧率：agent 运行节奏控制
/// - 心跳判活参数（I=心跳间隔秒 / N=连续丢失阈值次）：核心判"链路失活"的唯一判据
///   （M9 规约 1.1 取消了静态时间超时）；判活窗口 I×N 必须大于前端固定的 10s 心跳
/// - 自定义模型：模型池 CRUD（M2 起落 `~/.tree/config/models/*.yaml`）
/// - 主题管理：浅色 / 深色 / 跟随系统三种模式
/// - 主题色：荧光绿 / 豆沙绿 / 薄荷绿 / 自定义十六进制（晃眼可换护眼色）
/// - 文字大小：全局文字缩放（MediaQuery.textScaler，叠加在系统无障碍缩放之上）
/// - 界面字体：字体族 + 字重（FontService 注入 ThemeData.textTheme，改完即时生效）
/// - 窗口与托盘：关闭按钮行为的开关 + 真正的退出入口
/// - 插件开发：文档入口（打开 `plugins/README.md`）+ 插件目录定位
/// - 版本信息：应用 / 核心 / 接口契约 / 核心进程与产物（含"核心比界面旧"告警）
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    this.versionInfo,
    this.focusModels = false,
    this.embedded = false,
    this.onReplayRequested,
    this.teamId = '',
  });

  /// 版本信息数据源（**测试注入用**；null = 从核心启动器读当前运行态）。
  final VersionInfo? versionInfo;

  /// 打开时**滚到「自定义模型」一节**（新手引导第 1 步：先配模型）。
  final bool focusModels;

  /// 嵌在右栏「设置」**窗口**里（用户 2026-10-18 右栏窗口化）：不套 Scaffold/AppBar，
  /// 标题由窗口 chip 承担；「重新显示新手引导」改为回调而不是 `Navigator.pop(true)`。
  final bool embedded;

  /// [embedded] 下点「重新显示新手引导」时的回调（非嵌入模式仍走 `pop(true)`）。
  final VoidCallback? onReplayRequested;

  /// 当前选中的 Agent / 团队 id（`tree.settings` 的库归属；空 = 未选择）。
  final String teamId;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

/// 设置页左侧目录的一个分类（用户 2026-11-08：IDE 式左目录 + 右内容）。
class _SettingsCategory {
  const _SettingsCategory({
    required this.id,
    required this.label,
    required this.icon,
    required this.sections,
  });

  /// 稳定 id（目录项 Key 与测试都用它：`settings-nav-<id>`）。
  final String id;

  /// 目录名（图标栏形态下作 Tooltip，chip 形态下作 chip 文案）。
  final String label;

  final IconData icon;

  /// 右侧内容区的分区（二级标题 + 卡片），按顺序渲染。
  final List<Widget Function()> sections;
}

class _SettingsPageState extends State<SettingsPage> {
  // --- token 获取帧率（从 LLM 流逐 token 取回复的节奏，帧/秒，20~1000） ---
  int _tokenRate = 1000;
  int _tokenRateMin = 20;
  int _tokenRateMax = 1000;

  /// 后端 token 帧率是否已加载。加载前不渲染滑块：_tokenRate 的初值是上限
  /// （1000，滑块最右端），加载完成后会左移到真实值，视觉上会先跳到最右再回来。
  bool _tokenRateLoaded = false;

  // --- 推送刷新帧率（把流式增量攒帧后合并下发的频率，帧/秒，20~1000） ---
  int _frameRate = 20;
  int _frameRateMin = 20;
  int _frameRateMax = 1000;

  /// 后端推送帧率是否已加载（同 [_tokenRateLoaded]，加载前不渲染滑块）。
  bool _frameRateLoaded = false;

  /// token 获取帧率输入框（允许直接键入，提交时按范围夹取）
  final TextEditingController _tokenRateController = TextEditingController();

  /// 推送刷新帧率输入框（允许用户直接键入，提交时按范围夹取）
  final TextEditingController _frameRateController = TextEditingController();

  // --- 心跳判活参数（判活窗口 = 心跳间隔 I × 连续丢失阈值 N，必须 > 前端 10s 心跳） ---
  int _heartbeatIntervalSeconds = 10;
  int _heartbeatIntervalMin = 1;
  int _heartbeatIntervalMax = 600;
  int _missedHeartbeatLimit = 3;
  int _missedHeartbeatLimitMin = 1;
  int _missedHeartbeatLimitMax = 60;

  /// 判活窗口必须**严格大于**的下限（秒）：前端 WS 心跳固定 10s
  /// （lib/io/websocket_service.dart，本页不可调），窗口不足会把"在线但空闲"的
  /// 连接判成失活并反复重连。
  int _minLivenessWindowSeconds = 10;

  /// 当前生效的判活窗口（= I×N，秒）。
  int _livenessWindowSeconds = 30;

  /// 核心侧**在线生效**的值：与设置值不一致 = 要重启核心（或该消费者重建）才完全一致。
  int _liveIntervalSeconds = 10;
  int _liveMissLimit = 3;

  /// 最近一次夹取的可读原因（没有夹取则为 null）。
  String? _livenessNotice;

  /// 心跳间隔 / 丢失阈值输入框
  final TextEditingController _heartbeatIntervalController =
      TextEditingController();
  final TextEditingController _missedHeartbeatLimitController =
      TextEditingController();

  // --- 插件发布源（安装/更新插件时按顺序逐个试源） ---
  /// 生效的源顺序（key）：只支持 gitee / github 两种排列。
  List<String> _releaseOrder = const <String>['gitee', 'github'];

  /// 令牌是否**已保存**（明文永远拿不到，核心只回 `token_set`）。
  bool _giteeTokenSet = false;
  bool _githubTokenSet = false;

  bool _releaseSourcesLoaded = false;
  bool _releaseSaving = false;
  bool _releaseTesting = false;

  /// 最近一次「测试连接」的逐源结果（null = 还没测过）。
  List<Map<String, dynamic>>? _releaseProbes;
  String? _releaseProbeError;

  final TextEditingController _giteeTokenController = TextEditingController();
  final TextEditingController _githubTokenController = TextEditingController();

  // --- 自定义模型（设置页 CRUD） ---
  List<Map<String, dynamic>> _models = <Map<String, dynamic>>[];
  bool _modelsLoading = false;
  String? _modelsError;

  // --- 插件开发入口（M9 §4.2 的开发面） ---

  /// 插件清单的**真实路径**（从插件快照拿；拿不到则为 null）。
  ///
  /// 为什么不写死 `<数据根>/config/plugins.yaml`：数据根可被环境变量改，猜出来的
  /// 路径会把用户送到一个不存在的地方。拿不到就退回"去插件面板看"的指引。
  String? _pluginConfigPath;

  /// 当前选中的设置分类（`_SettingsCategory.id`，默认「外观」）。
  String _category = 'appearance';

  @override
  void initState() {
    super.initState();
    _loadTokenRateSetting();
    _loadFrameRateSetting();
    _loadHeartbeatSetting();
    _loadPluginReleaseSources();
    _loadModelList();
    _loadPluginConfigPath();
    // 引导带过来的（focusModels）：直接落到「模型」分类（用户 2026-11-08 左目录改造后
    // 不再用滚动锚点，分类即导航）。
    if (widget.focusModels) _category = 'model';
  }

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 嵌在右栏窗口里时本控件常挂（IndexedStack），再次收到 focusModels
    // （引导「带我过去」又点了一次）得重新切回「模型」，不能只在 initState 里做一次。
    // 这里直接改字段：didUpdateWidget 之后紧跟一次 build，无需 setState。
    if (widget.focusModels && !oldWidget.focusModels) _category = 'model';
  }

  void _selectCategory(String id) {
    if (_category == id) return;
    setState(() => _category = id);
  }

  /// 读插件快照，只为拿 `config.path`（插件清单的真实路径）。
  ///
  /// 失败**不报错也不阻塞**：这只是设置页的一个提示行，拿不到就退回"去插件面板看"
  /// ——版本 / 开发信息本身不依赖核心可用（应用与核心都起来时才有快照）。
  Future<void> _loadPluginConfigPath() async {
    try {
      final Map<String, dynamic> snap = await ApiService.getPluginSnapshot();
      final Object? config = snap['config'];
      final String path = config is Map
          ? (config['path'] ?? '').toString()
          : '';
      if (!mounted || path.isEmpty) return;
      setState(() => _pluginConfigPath = path);
    } catch (_) {
      // 核心不可达 / 未接入插件总线：保留指引文案
    }
  }

  @override
  void dispose() {
    _tokenRateController.dispose();
    _frameRateController.dispose();
    _heartbeatIntervalController.dispose();
    _missedHeartbeatLimitController.dispose();
    _giteeTokenController.dispose();
    _githubTokenController.dispose();
    super.dispose();
  }

  /// 加载 token 获取帧率设置（权威值来自后端；后端不可达时用默认 1000）
  Future<void> _loadTokenRateSetting() async {
    try {
      final Map<String, dynamic> data = await ApiService.getTokenRate();
      if (!mounted) return;
      final int rate = (data['token_rate'] as num?)?.toInt() ?? _tokenRate;
      final int min = (data['min'] as num?)?.toInt() ?? _tokenRateMin;
      final int max = (data['max'] as num?)?.toInt() ?? _tokenRateMax;
      setState(() {
        _tokenRate = rate;
        _tokenRateMin = min;
        _tokenRateMax = max;
        _tokenRateController.text = '$rate';
        _tokenRateLoaded = true;
      });
    } catch (_) {
      // 后端不可达：保留默认值，控件仍可编辑（提交时后端会夹取范围）
      if (mounted) {
        setState(() {
          _tokenRateController.text = '$_tokenRate';
          _tokenRateLoaded = true;
        });
      }
    }
  }

  /// 提交 token 获取帧率（按后端声明的范围夹取，以后端返回的生效值为准）
  Future<void> _applyTokenRate(int value) async {
    final int clamped = value < _tokenRateMin
        ? _tokenRateMin
        : (value > _tokenRateMax ? _tokenRateMax : value);
    try {
      final int effective = await ApiService.setTokenRate(clamped);
      if (!mounted) return;
      setState(() {
        _tokenRate = effective;
        _tokenRateController.text = '$effective';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _tokenRateController.text = '$_tokenRate');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('token 帧率设置失败：$e'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// 加载推送刷新帧率设置（权威值来自后端；后端不可达时用默认 20）
  Future<void> _loadFrameRateSetting() async {
    try {
      final Map<String, dynamic> data = await ApiService.getFrameRate();
      if (!mounted) return;
      final int rate = (data['frame_rate'] as num?)?.toInt() ?? _frameRate;
      final int min = (data['min'] as num?)?.toInt() ?? _frameRateMin;
      final int max = (data['max'] as num?)?.toInt() ?? _frameRateMax;
      setState(() {
        _frameRate = rate;
        _frameRateMin = min;
        _frameRateMax = max;
        _frameRateController.text = '$rate';
        _frameRateLoaded = true;
      });
    } catch (_) {
      // 后端不可达：保留默认值，控件仍可编辑（提交时后端会夹取范围）
      if (mounted) {
        setState(() {
          _frameRateController.text = '$_frameRate';
          _frameRateLoaded = true;
        });
      }
    }
  }

  /// 提交推送刷新帧率（按后端声明的范围夹取，以后端返回的生效值为准）
  Future<void> _applyFrameRate(int value) async {
    final int clamped = value < _frameRateMin
        ? _frameRateMin
        : (value > _frameRateMax ? _frameRateMax : value);
    try {
      final int effective = await ApiService.setFrameRate(clamped);
      if (!mounted) return;
      setState(() {
        _frameRate = effective;
        _frameRateController.text = '$effective';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _frameRateController.text = '$_frameRate');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('帧率设置失败：$e'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// 加载心跳判活参数（权威值来自后端；后端不可达时保留默认 10s / 3 次）
  Future<void> _loadHeartbeatSetting() async {
    try {
      final Map<String, dynamic> data =
          await ApiService.getHeartbeatLivenessSettings();
      _applyHeartbeatResponse(data);
    } catch (_) {
      // 后端不可达：保留默认值，控件仍可编辑（提交时后端还会再夹一次）
      if (mounted) {
        setState(() {
          _heartbeatIntervalController.text = '$_heartbeatIntervalSeconds';
          _missedHeartbeatLimitController.text = '$_missedHeartbeatLimit';
        });
      }
    }
  }

  /// 把后端返回的心跳判活参数写进界面。
  ///
  /// 两个端点（heartbeat-interval / missed-heartbeat-limit）的响应**同形状**，
  /// 所以只解析一次：值、各自区间、当前的判活窗口、核心侧在线生效值、夹取说明。
  /// [fallbackNotice] 是前端预夹取时自己生成的说明（后端没夹取时用它）。
  void _applyHeartbeatResponse(
    Map<String, dynamic> data, {
    String? fallbackNotice,
  }) {
    if (!mounted) return;
    setState(() {
      _heartbeatIntervalSeconds =
          (data['heartbeat_interval'] as num?)?.toInt() ??
          _heartbeatIntervalSeconds;
      _missedHeartbeatLimit =
          (data['missed_heartbeat_limit'] as num?)?.toInt() ??
          _missedHeartbeatLimit;
      _heartbeatIntervalMin =
          (data['heartbeat_interval_min'] as num?)?.toInt() ??
          _heartbeatIntervalMin;
      _heartbeatIntervalMax =
          (data['heartbeat_interval_max'] as num?)?.toInt() ??
          _heartbeatIntervalMax;
      _missedHeartbeatLimitMin =
          (data['missed_heartbeat_limit_min'] as num?)?.toInt() ??
          _missedHeartbeatLimitMin;
      _missedHeartbeatLimitMax =
          (data['missed_heartbeat_limit_max'] as num?)?.toInt() ??
          _missedHeartbeatLimitMax;
      _minLivenessWindowSeconds =
          (data['min_window_seconds'] as num?)?.toInt() ??
          _minLivenessWindowSeconds;
      _livenessWindowSeconds =
          (data['window_seconds'] as num?)?.toInt() ??
          _heartbeatIntervalSeconds * _missedHeartbeatLimit;
      _liveIntervalSeconds =
          (data['live_interval_seconds'] as num?)?.toInt() ??
          _heartbeatIntervalSeconds;
      _liveMissLimit =
          (data['live_miss_limit'] as num?)?.toInt() ?? _missedHeartbeatLimit;
      _livenessNotice = (data['notice'] as String?) ?? fallbackNotice;
      _heartbeatIntervalController.text = '$_heartbeatIntervalSeconds';
      _missedHeartbeatLimitController.text = '$_missedHeartbeatLimit';
    });
  }

  /// 提交心跳判活参数。
  ///
  /// 两个字段**一起**下发：判活窗口是 I×N 的乘积，分两次写会经过非法中间态
  /// （例如从 10s/3 改成 3s/6 时，先把间隔改成 3 的那一瞬间窗口只剩 9s）。
  ///
  /// 前端按后端同一口径先算一遍：窗口必须严格大于 [_minLivenessWindowSeconds]
  /// （前端固定 10s 心跳），不足时抬高间隔 I——夹取而不是拒绝，并把可读原因同时
  /// 显示在卡片上（持久）与 SnackBar 里（当下），用户要能知道"我填的 1s 为什么
  /// 生效成 4s"。后端仍会独立夹取（它是权威），两侧口径一致。
  Future<void> _applyHeartbeatSetting({
    int? intervalSeconds,
    int? limit,
  }) async {
    int nextInterval = (intervalSeconds ?? _heartbeatIntervalSeconds).clamp(
      _heartbeatIntervalMin,
      _heartbeatIntervalMax,
    );
    final int nextLimit = (limit ?? _missedHeartbeatLimit).clamp(
      _missedHeartbeatLimitMin,
      _missedHeartbeatLimitMax,
    );
    String? localNotice;
    if (nextInterval * nextLimit <= _minLivenessWindowSeconds) {
      final int repaired = _minLivenessWindowSeconds ~/ nextLimit + 1;
      localNotice =
          '判活窗口 ${nextInterval}s×$nextLimit='
          '${nextInterval * nextLimit}s 不大于前端固定 '
          '${_minLivenessWindowSeconds}s 的心跳间隔，空闲连接会被误判失活并反复'
          '重连；已把心跳间隔夹到 ${repaired}s（判活窗口 ${repaired * nextLimit}s）';
      nextInterval = repaired;
    }
    try {
      final Map<String, dynamic> data =
          await ApiService.setHeartbeatLivenessSettings(
            heartbeatIntervalSeconds: nextInterval,
            missedHeartbeatLimit: nextLimit,
          );
      if (!mounted) return;
      _applyHeartbeatResponse(data, fallbackNotice: localNotice);
      final String? notice = (data['notice'] as String?) ?? localNotice;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(notice ?? '心跳判活参数已保存并生效'),
          duration: Duration(seconds: notice == null ? 2 : 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _heartbeatIntervalController.text = '$_heartbeatIntervalSeconds';
        _missedHeartbeatLimitController.text = '$_missedHeartbeatLimit';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('心跳判活参数保存失败：$e'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  // ── 插件发布源 ────────────────────────────────────────────────────────

  /// 当前选择的排列（两个源只有两种顺序，看第一个是谁即可）。
  List<String> get _selectedReleaseOrder => _releaseOrder.first == 'github'
      ? const <String>['github', 'gitee']
      : const <String>['gitee', 'github'];

  /// 读发布源设置（顺序 + 令牌是否已配；**明文令牌拿不到**）。
  Future<void> _loadPluginReleaseSources() async {
    try {
      final Map<String, dynamic> data =
          await ApiService.getPluginReleaseSources();
      if (!mounted) return;
      _applyReleaseSourcesResponse(data);
    } catch (_) {
      // 核心不可达：保留默认（Gitee → GitHub），控件仍可编辑
      if (mounted) setState(() => _releaseSourcesLoaded = true);
    }
  }

  /// 把核心返回的发布源设置写进界面（GET / POST 响应同形状）。
  void _applyReleaseSourcesResponse(Map<String, dynamic> data) {
    final Object? rawOrder = data['order'];
    final List<String> order = rawOrder is List
        ? rawOrder
              .map((Object? item) => item?.toString() ?? '')
              .where((String key) => key.isNotEmpty)
              .toList()
        : <String>[];
    bool giteeSet = false;
    bool githubSet = false;
    final Object? rawSources = data['sources'];
    if (rawSources is List) {
      for (final Object? item in rawSources) {
        if (item is! Map) continue;
        final String key = (item['key'] ?? '').toString();
        final bool set = item['token_set'] == true;
        if (key == 'gitee') giteeSet = set;
        if (key == 'github') githubSet = set;
      }
    }
    setState(() {
      _releaseOrder = order.isEmpty
          ? const <String>['gitee', 'github']
          : order;
      _giteeTokenSet = giteeSet;
      _githubTokenSet = githubSet;
      _releaseSourcesLoaded = true;
    });
  }

  /// 保存顺序与（本轮填过的）令牌：留空的令牌输入框**不改原值**。
  Future<void> _savePluginReleaseSources() async {
    if (_releaseSaving) return;
    setState(() => _releaseSaving = true);
    final String gitee = _giteeTokenController.text.trim();
    final String github = _githubTokenController.text.trim();
    try {
      final Map<String, dynamic> data =
          await ApiService.savePluginReleaseSources(
            order: _selectedReleaseOrder,
            giteeToken: gitee.isEmpty ? null : gitee,
            githubToken: github.isEmpty ? null : github,
          );
      if (!mounted) return;
      _applyReleaseSourcesResponse(data);
      _giteeTokenController.clear();
      _githubTokenController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('插件发布源已保存并生效'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$e'), duration: const Duration(seconds: 3)),
      );
    } finally {
      if (mounted) setState(() => _releaseSaving = false);
    }
  }

  /// 探测各源是否连通（带**未保存的草稿值**：先试通再保存）。
  Future<void> _testPluginReleaseSources() async {
    if (_releaseTesting) return;
    final String gitee = _giteeTokenController.text.trim();
    final String github = _githubTokenController.text.trim();
    setState(() {
      _releaseTesting = true;
      _releaseProbes = null;
      _releaseProbeError = null;
    });
    try {
      final Map<String, dynamic> data =
          await ApiService.testPluginReleaseSources(
            order: _selectedReleaseOrder,
            giteeToken: gitee.isEmpty ? null : gitee,
            githubToken: github.isEmpty ? null : github,
          );
      if (!mounted) return;
      final Object? rawSources = data['sources'];
      setState(() {
        _releaseProbes = rawSources is List
            ? <Map<String, dynamic>>[
                for (final Object? item in rawSources)
                  if (item is Map) Map<String, dynamic>.from(item),
              ]
            : <Map<String, dynamic>>[];
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _releaseProbeError = '$e');
    } finally {
      if (mounted) setState(() => _releaseTesting = false);
    }
  }

  /// 加载自定义模型列表
  Future<void> _loadModelList() async {
    if (mounted) {
      setState(() {
        _modelsLoading = true;
        _modelsError = null;
      });
    }
    try {
      final List<Map<String, dynamic>> models = await ApiService.getModels();
      if (!mounted) return;
      setState(() {
        _models = models;
        _modelsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _modelsLoading = false;
        _modelsError = '$e';
      });
    }
  }

  /// 设置分类表（用户 2026-11-08：左侧目录 + 右侧内容，IDE 式布局）。
  ///
  /// 分类顺序固定；组内分区沿用原单列顺序（「插件」「关于」按用户口径排列）。
  List<_SettingsCategory> get _categories => <_SettingsCategory>[
    _SettingsCategory(
      id: 'appearance',
      label: '外观',
      icon: Icons.palette_outlined,
      sections: <Widget Function()>[
        () => _section('主题管理', _buildThemeCard()),
        () => _section('主题色', const _AccentColorCard()),
        () => _section('文字大小', _buildTextScaleCard()),
        () => _section('界面字体', _buildFontCard()),
      ],
    ),
    _SettingsCategory(
      id: 'editor',
      label: '编辑器',
      icon: Icons.code,
      sections: <Widget Function()>[
        () => _section('编辑器', _buildEditorCard()),
      ],
    ),
    _SettingsCategory(
      id: 'model',
      label: '模型',
      icon: Icons.memory,
      sections: <Widget Function()>[
        () => _section('自定义模型', _buildCustomModelCard()),
      ],
    ),
    _SettingsCategory(
      id: 'runtime',
      label: '运行与链路',
      icon: Icons.speed,
      sections: <Widget Function()>[
        () => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _section('流式帧率', _buildTokenRateCard()),
            const SizedBox(height: 12),
            _buildFrameRateCard(),
          ],
        ),
        () => _section('心跳判活', _buildHeartbeatCard()),
      ],
    ),
    _SettingsCategory(
      id: 'plugins',
      label: '插件',
      icon: Icons.extension_outlined,
      sections: <Widget Function()>[
        () => _section(
          '插件设置',
          PluginSettingsCard(teamId: widget.teamId),
        ),
        () => _section('插件发布源', _buildPluginReleaseCard()),
        () => _section('插件开发', _buildPluginDevCard()),
      ],
    ),
    _SettingsCategory(
      id: 'window',
      label: '窗口与托盘',
      icon: Icons.window_outlined,
      sections: <Widget Function()>[
        () => _section('窗口与托盘', _buildTrayCard()),
      ],
    ),
    _SettingsCategory(
      id: 'about',
      label: '关于',
      icon: Icons.info_outline,
      sections: <Widget Function()>[
        () => _section('版本信息', _buildVersionCard()),
        () => _section('核心日志', const CoreLogCard()),
        () => _section('新手引导', _buildOnboardingCard()),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final List<_SettingsCategory> categories = _categories;
    final Widget body = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final ColorScheme cs = Theme.of(context).colorScheme;
        final double width = constraints.maxWidth;
        // 窄于 420：顶部一行横向分类 chip（右栏最窄 240 时仍可用）。
        if (width < 420) {
          return Column(
            children: <Widget>[
              _buildChipNav(cs, categories),
              const Divider(height: 1),
              Expanded(child: _buildCategoryContent(categories)),
            ],
          );
        }
        // ≥ 620：完整 IDE 双栏（文字目录）；420~619：图标栏。
        final bool wide = width >= 620;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              width: wide ? 176 : 44,
              child: _buildNav(cs, categories, wide: wide),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: _buildCategoryContent(categories)),
          ],
        );
      },
    );
    // 嵌入右栏窗口：不套 Scaffold/AppBar（标题由窗口 chip 承担，避免两层头）
    if (widget.embedded) {
      return Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: body,
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('设置'), centerTitle: false),
      body: body,
    );
  }

  /// 一个分区：二级标题 + 卡片。
  Widget _section(String title, Widget card) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildSectionTitle(title),
        const SizedBox(height: 8),
        card,
      ],
    );
  }

  /// 左侧目录（文字 / 图标两种形态共用同一份条目）。
  Widget _buildNav(
    ColorScheme cs,
    List<_SettingsCategory> categories, {
    required bool wide,
  }) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: <Widget>[
        for (final _SettingsCategory category in categories)
          _buildNavItem(cs, category, wide: wide),
      ],
    );
  }

  Widget _buildNavItem(
    ColorScheme cs,
    _SettingsCategory category, {
    required bool wide,
  }) {
    final bool selected = category.id == _category;
    final Color fg = selected ? cs.primary : cs.onSurfaceVariant;
    final Widget item = Container(
      height: 40,
      padding: EdgeInsets.symmetric(horizontal: wide ? 12 : 0),
      decoration: BoxDecoration(
        color: selected ? cs.primary.withValues(alpha: 0.12) : null,
        border: Border(
          left: BorderSide(
            color: selected ? cs.primary : Colors.transparent,
            width: 2,
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment:
            wide ? MainAxisAlignment.start : MainAxisAlignment.center,
        children: <Widget>[
          Icon(category.icon, size: 18, color: fg),
          if (wide) ...<Widget>[
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                category.label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: fg,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ],
      ),
    );
    return InkWell(
      key: Key('settings-nav-${category.id}'),
      onTap: () => _selectCategory(category.id),
      child: wide
          ? item
          : Tooltip(message: category.label, child: item),
    );
  }

  /// 顶部横向 chip 导航（设置页可用宽 < 420）。
  Widget _buildChipNav(ColorScheme cs, List<_SettingsCategory> categories) {
    return SizedBox(
      height: 48,
      child: ListView(
        key: const Key('settings-nav-chips'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: <Widget>[
          for (final _SettingsCategory category in categories)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                key: Key('settings-nav-chip-${category.id}'),
                avatar: Icon(category.icon, size: 16),
                label: Text(category.label),
                selected: category.id == _category,
                onSelected: (_) => _selectCategory(category.id),
              ),
            ),
        ],
      ),
    );
  }

  /// 右侧内容区：每个分类一个 `ListView`，用 `IndexedStack` 常挂。
  ///
  /// 为什么不是按需重建：切分类不丢滚动位置，也不丢 `_AccentColorCard` 里
  /// 未提交的自定义色号草稿（它是独立 StatefulWidget，销毁即清空输入）。
  Widget _buildCategoryContent(List<_SettingsCategory> categories) {
    int index = categories.indexWhere(
      (_SettingsCategory c) => c.id == _category,
    );
    if (index < 0) index = 0;
    return IndexedStack(
      key: const Key('settings-category-content'),
      index: index,
      sizing: StackFit.expand,
      children: <Widget>[
        for (final _SettingsCategory category in categories)
          ListView(
            key: Key('settings-content-scroll-${category.id}'),
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              for (int i = 0; i < category.sections.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(height: 24),
                category.sections[i](),
              ],
            ],
          ),
      ],
    );
  }

  /// 新手引导卡片：让用户随时把**首次使用的八步引导**再叫出来（用户 2026-10-04）。
  ///
  /// 为什么要在设置里给一个入口：引导第一次弹过 / 被跳过后就不再自动出现，
  /// 没有这个入口用户就只能删配置才能再看一遍——那既不友好，也没法验证。
  /// 口径：点一下返回 `true` 给 MainPage，由它清掉"看过"记录并**从头**弹一次。
  Widget _buildOnboardingCard() {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '首次使用的八步引导（模型 → 建 agent → 模型信息 → 工作目录 → 插件 → 文件 → Ctrl+J → demo）',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.35),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey<String>('settings-replay-onboarding'),
              onPressed: widget.embedded
                  ? widget.onReplayRequested
                  : () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.tips_and_updates_outlined, size: 16),
              label: const Text('重新显示新手引导'),
            ),
          ],
        ),
      ),
    );
  }

  /// 编辑器卡片：代码高亮 + 失焦/离开时自动保存。
  ///
  /// 为什么没有「定时自动保存」：定时器会在人正打到一半时写盘；真正会丢内容的
  /// 时刻是切走 / 关窗格，所以自动保存只做那两个时机（用户 2026-10-02 定夺）。
  Widget _buildEditorCard() {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: EditorSettings.instance,
      builder: (BuildContext context, Widget? child) {
        final EditorSettings settings = EditorSettings.instance;
        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '源码模式',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '源码按扩展名选择语言着色（Dart / Python / JS / Go / SQL / YAML …）；'
                  '超过 ${kHighlightMaxChars ~/ 1024} KB 的文件自动退回单色，保证输入不卡。'
                  '编辑仅限纯文本：图片 / PDF / Office / 二进制一律只读，'
                  '被截断的大文件也只读（否则保存会把文件截短）。'
                  '本机与 SSH 模式都由核心落盘，前端不直接写盘。',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: settings.highlight,
                  onChanged: (bool value) => settings.setHighlight(value),
                  activeThumbColor: cs.primary,
                  title: const Text('语法高亮', style: TextStyle(fontSize: 13)),
                  subtitle: const Text(
                    '关掉后退回单色等宽（大文件无论如何都不着色）。',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: settings.saveOnBlur,
                  onChanged: (bool value) => settings.setSaveOnBlur(value),
                  activeThumbColor: cs.primary,
                  title: const Text('切走 / 关闭时自动保存', style: TextStyle(fontSize: 13)),
                  subtitle: const Text(
                    '开启：失焦、关闭窗格、换文件时自动写回未保存的改动（不再弹确认框）；'
                    '关闭：只认手动保存（Ctrl+S 或标题栏保存键），离开前会问一次。',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 插件发布源卡片：面板的「安装 / 更新」按这里的顺序逐个试源。
  ///
  /// 令牌输入框只负责**写入**：已保存的明文永远拿不到（核心只回 `token_set`），
  /// 所以留空 = 保持原值；想验证填的值对不对，先点「测试连接」（带草稿值、不落盘）。
  Widget _buildPluginReleaseCard() {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '插件面板的「安装 / 更新」会按下面的顺序逐个尝试发布源，第一个通的生效。'
              '公开仓库不登录也能读；令牌只在被限流或需要私有访问时才用得上。',
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurfaceVariant,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 8),
            RadioGroup<String>(
              groupValue: _releaseOrder.first,
              onChanged: (String? value) {
                if (value == null) return;
                setState(() {
                  _releaseOrder = value == 'github'
                      ? const <String>['github', 'gitee']
                      : const <String>['gitee', 'github'];
                });
              },
              child: Column(
                children: <Widget>[
                  RadioListTile<String>(
                    key: const Key('plugin-release-order-gitee-first'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: 'gitee',
                    activeColor: cs.primary,
                    title: const Text(
                      'Gitee → GitHub（推荐）',
                      style: TextStyle(fontSize: 13),
                    ),
                    subtitle: const Text(
                      '国内访问更稳；Gitee 不通时自动换 GitHub。',
                      style: TextStyle(fontSize: 11),
                    ),
                  ),
                  RadioListTile<String>(
                    key: const Key('plugin-release-order-github-first'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: 'github',
                    activeColor: cs.primary,
                    title: const Text(
                      'GitHub → Gitee',
                      style: TextStyle(fontSize: 13),
                    ),
                    subtitle: const Text(
                      'GitHub 优先；不通时自动换 Gitee。',
                      style: TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('plugin-release-gitee-token'),
              controller: _giteeTokenController,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'Gitee token（可选）',
                hintText: _giteeTokenSet
                    ? '已保存（留空保持不变）'
                    : '未设置（公开仓库可留空）',
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('plugin-release-github-token'),
              controller: _githubTokenController,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'GitHub token（可选）',
                hintText: _githubTokenSet
                    ? '已保存（留空保持不变）'
                    : '未设置（公开仓库可留空）',
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                FilledButton.icon(
                  key: const Key('plugin-release-save'),
                  onPressed:
                      (_releaseSaving || !_releaseSourcesLoaded)
                      ? null
                      : _savePluginReleaseSources,
                  icon: _releaseSaving
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined, size: 16),
                  label: const Text('保存'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
                OutlinedButton.icon(
                  key: const Key('plugin-release-test'),
                  onPressed: _releaseTesting ? null : _testPluginReleaseSources,
                  icon: _releaseTesting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering_outlined, size: 16),
                  label: const Text('测试连接'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
              ],
            ),
            if (_releaseProbeError != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '探测失败：$_releaseProbeError',
                style: TextStyle(fontSize: 11, color: cs.error),
              ),
            ],
            if (_releaseProbes != null) ...<Widget>[
              const SizedBox(height: 8),
              for (final Map<String, dynamic> probe in _releaseProbes!)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    _releaseProbeLine(probe),
                    key: Key(
                      'plugin-release-probe-${(probe['key'] ?? '').toString()}',
                    ),
                    style: TextStyle(
                      fontSize: 11,
                      color: probe['usable'] == true
                          ? cs.onSurfaceVariant
                          : cs.error,
                      height: 1.3,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// 一条探测结果的展示文案（通了要给出"通到哪一版"，没通要给出原因）。
  String _releaseProbeLine(Map<String, dynamic> probe) {
    final String name = (probe['name'] ?? probe['key'] ?? '').toString();
    if (probe['ok'] != true) {
      return '$name：不通 —— ${probe['error'] ?? '未知原因'}';
    }
    final String tag = (probe['tag'] ?? '').toString();
    final bool hasIndex = probe['has_index'] == true;
    if (!hasIndex) {
      return '$name：可连通（release ${tag.isEmpty ? '未知' : tag}），'
          '但这一版没有 plugin-index.json ⇒ 还不能安装';
    }
    return '$name：可连通（release ${tag.isEmpty ? '未知' : tag}，'
        '${(probe['asset_count'] as num?)?.toInt() ?? 0} 个资产，含索引）';
  }

  /// 插件开发卡片（M9 §4.2 的开发面）。
  ///
  /// 为什么要一个"入口"而不是把文档抄进设置页：插件协议面（RPC 清单、17 个点位、
  /// `ui/manifest`、流式回填、`plugins.yaml` 全字段）已经写在**系统性开发指南**
  /// （`docs/plugin-development.md`，发行版在 `plugins/` 下）里，抄一份就是第二份
  /// 真相源，必然与代码漂移。这里只负责**把人送到那份文档**，并把文档的真实路径
  /// 摆在界面上（路径找不到时给可读原因，不静默）。
  Widget _buildPluginDevCard() {
    final cs = Theme.of(context).colorScheme;
    final String? path = PluginDocs.resolvePath();
    final String dirHintFallback =
        '未找到 ${PluginDocs.guideName}（发行版看应用目录下的 '
        '${PluginDocs.bundledDirName}/，源码仓库看 ${PluginDocs.repoDocDirName}/）';
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '开发一个插件',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            const Text(
              '插件是独立进程，走 stdio JSON-RPC 与核心通信：可申报工具（收集站）、'
              '订阅 35 个内置点位（中转/广播/执行/收集，含整轮 tool loop 接管）、主动下命令（执行站，'
              '含 LLM 调用与任意工具调用）、接管 LLM 生成、自建站点、声明前端面板。'
              '完整协议与可运行示例见 plugin-development.md。',
              style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton.icon(
                  key: const Key('plugin-docs-open'),
                  onPressed: () => _openPluginDocs(),
                  icon: const Icon(Icons.menu_book_outlined, size: 16),
                  label: const Text('打开插件开发说明'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  key: const Key('plugin-docs-reveal'),
                  onPressed: path == null ? null : () => _revealPluginDir(path),
                  icon: const Icon(Icons.folder_open_outlined, size: 16),
                  label: const Text('打开所在目录'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(
              path ?? dirHintFallback,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(
              '插件配置：${_pluginConfigPathHint()}'
              '（可直接编辑，保存后立即热应用；热应用失败时重启核心生效）',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  /// 插件清单路径提示：从插件快照拿（拿了才知道真实数据根在哪，不臆测）。
  ///
  /// 快照还没到手时给出"打开插件面板可见"的指引，而不是留空或编一个路径。
  String _pluginConfigPathHint() =>
      _pluginConfigPath ?? '见「插件」面板（面板里显示真实路径）';

  /// 打开插件开发说明（失败给可读原因）。
  Future<void> _openPluginDocs() async {
    final String? error = await PluginDocs.openReadme();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error ?? '已用系统默认程序打开插件开发说明'),
        duration: Duration(seconds: error == null ? 2 : 6),
      ),
    );
  }

  /// 在资源管理器里定位插件文档所在目录。
  Future<void> _revealPluginDir(String path) async {
    final String? error = await PluginDocs.openPath(File(path).parent.path);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error), duration: const Duration(seconds: 4)),
      );
    }
  }

  /// 版本信息卡片。
  ///
  /// 三个常被问到的"我到底跑的是哪一版"在这里一次答完：应用版本、核心版本、
  /// 核心进程（pid / 端口 / 是否附着）。另外把启动期算好的**产物陈旧告警**摆在
  /// 这里——核心是独立进程，产物可能比界面旧，此时新功能会"看起来没生效"，
  /// 这是真机上最难自证的一类问题。
  Widget _buildVersionCard() {
    final cs = Theme.of(context).colorScheme;
    final VersionInfo info =
        widget.versionInfo ?? VersionInfo.fromAttachment();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '版本',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                ),
                OutlinedButton.icon(
                  key: const Key('version-copy'),
                  onPressed: () => _copyVersionInfo(info),
                  icon: const Icon(Icons.copy_all_outlined, size: 16),
                  label: const Text('复制版本信息'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final InfoRow row in info.rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 76,
                      child: Text(
                        row.label,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Expanded(
                      child: SelectableText(
                        row.value,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            if (info.buildWarning != null) ...[
              const SizedBox(height: 6),
              Text(
                info.buildWarning!,
                key: const Key('version-build-warning'),
                style: const TextStyle(fontSize: 12, color: Colors.orange),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 复制版本信息（整块文本，便于贴到 issue / 对话里）。
  Future<void> _copyVersionInfo(VersionInfo info) async {
    await Clipboard.setData(ClipboardData(text: info.toReportText()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('版本信息已复制'), duration: Duration(seconds: 2)),
    );
  }

  /// token 获取帧率卡片
  ///
  /// 控制**从 LLM 流逐 token 取回复**的节奏：每消费一个文本/思考增量按该帧率
  /// 间隔让出一帧。常开、无开关——取代旧的「主动延迟」（那是一次性限 API 调用
  /// 次数，这里是连续可调的取词节奏）。范围 20~1000 帧/秒（1000 近似不限速）。
  Widget _buildTokenRateCard() {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'token 获取帧率（帧/秒）',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            const Text(
              '从 LLM 流逐 token 取回复的节奏，常开生效；越慢越能看清生成过程',
              style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: _tokenRateController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: '帧率',
                      helperText: '$_tokenRateMin~$_tokenRateMax',
                      isDense: true,
                    ),
                    onSubmitted: (String value) {
                      final int? parsed = int.tryParse(value.trim());
                      if (parsed != null) _applyTokenRate(parsed);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '减少 20',
                  onPressed: _tokenRate <= _tokenRateMin
                      ? null
                      : () => _applyTokenRate(_tokenRate - 20),
                  icon: const Icon(Icons.remove_circle_outline),
                  color: cs.primary,
                ),
                IconButton(
                  tooltip: '增加 20',
                  onPressed: _tokenRate >= _tokenRateMax
                      ? null
                      : () => _applyTokenRate(_tokenRate + 20),
                  icon: const Icon(Icons.add_circle_outline),
                  color: cs.primary,
                ),
                const Spacer(),
                OutlinedButton(
                  onPressed: () {
                    final int? parsed = int.tryParse(
                      _tokenRateController.text.trim(),
                    );
                    if (parsed != null) _applyTokenRate(parsed);
                  },
                  child: const Text('应用'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // 后端值返回前不渲染滑块：初值 1000 会让滑块先出现在最右端，加载
            // 完成后再左移，视觉上是明显的"跳一下"。用等高占位消除这段位移。
            if (_tokenRateLoaded)
              Slider(
                value: _tokenRate.toDouble().clamp(
                  _tokenRateMin.toDouble(),
                  _tokenRateMax.toDouble(),
                ),
                min: _tokenRateMin.toDouble(),
                max: _tokenRateMax.toDouble(),
                divisions: 49,
                label: '$_tokenRate fps',
                onChanged: (double value) {
                  setState(() => _tokenRate = value.round());
                },
                onChangeEnd: (double value) => _applyTokenRate(value.round()),
              )
            else
              const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }

  /// 推送刷新帧率卡片
  ///
  /// 控制**流式增量的合并下发频率**：把同一轮回复内的 token 攒帧后按该帧率合并
  /// 成一条 `msg_chunk` 推送，避免以 token 速度刷屏。常开、无开关。
  ///
  /// 与上面的「token 获取帧率」互不干扰：取词慢则下发帧数自然少；取词满速时由
  /// 这里决定实际刷新频率。范围 20~1000 帧/秒，可直接键入，提交时按范围夹取。
  Widget _buildFrameRateCard() {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '推送刷新帧率（帧/秒）',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            const Text(
              '把同一轮回复内的流式增量攒帧后按该帧率合并下发，常开生效',
              style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: _frameRateController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: '帧率',
                      helperText: '$_frameRateMin~$_frameRateMax',
                      isDense: true,
                    ),
                    onSubmitted: (String value) {
                      final int? parsed = int.tryParse(value.trim());
                      if (parsed != null) _applyFrameRate(parsed);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '减少 20',
                  onPressed: _frameRate <= _frameRateMin
                      ? null
                      : () => _applyFrameRate(_frameRate - 20),
                  icon: const Icon(Icons.remove_circle_outline),
                  color: cs.primary,
                ),
                IconButton(
                  tooltip: '增加 20',
                  onPressed: _frameRate >= _frameRateMax
                      ? null
                      : () => _applyFrameRate(_frameRate + 20),
                  icon: const Icon(Icons.add_circle_outline),
                  color: cs.primary,
                ),
                const Spacer(),
                OutlinedButton(
                  onPressed: () {
                    final int? parsed = int.tryParse(
                      _frameRateController.text.trim(),
                    );
                    if (parsed != null) _applyFrameRate(parsed);
                  },
                  child: const Text('应用'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // 同 token 帧率：加载完成前用等高占位，避免滑块先跳到默认值再回位。
            if (_frameRateLoaded)
              Slider(
                value: _frameRate.toDouble().clamp(
                  _frameRateMin.toDouble(),
                  _frameRateMax.toDouble(),
                ),
                min: _frameRateMin.toDouble(),
                max: _frameRateMax.toDouble(),
                divisions: 49,
                label: '$_frameRate fps',
                onChanged: (double value) {
                  setState(() => _frameRate = value.round());
                },
                onChangeEnd: (double value) => _applyFrameRate(value.round()),
              )
            else
              const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }

  /// 心跳判活参数卡片（心跳间隔 I 秒 / 连续丢失阈值 N 次）
  ///
  /// 核心判"链路失活"的唯一判据（M9 规约 1.1：静态时间超时全部取消，改心跳丢失），
  /// 所以这两个值直接决定"多久没有心跳就判死"。硬约束：判活窗口 I×N 必须**严格
  /// 大于**前端固定的 10s WS 心跳（lib/io/websocket_service.dart，本页不可调），
  /// 否则"在线但空闲"的连接会被判失活、关连接、反复重连；不足时前后端都会把 I 抬到
  /// 刚好够，并把可读原因显示在下面。
  Widget _buildHeartbeatCard() {
    final cs = Theme.of(context).colorScheme;
    // 核心侧的"在线生效值"可能落后于设置值：WS 判活节拍会立即热更新，但丢失阈值 N
    // 与插件宿主 / MCP 客户端的心跳参数要等下次启动核心（SSH 是下次建连）才用新值，
    // 这里如实说明生效时机，不含糊。
    final bool liveBehind =
        _liveIntervalSeconds != _heartbeatIntervalSeconds ||
        _liveMissLimit != _missedHeartbeatLimit;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '心跳判活参数',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            const Text(
              '核心判链路失活的唯一判据：连续 N 拍没收到心跳即判失活（不做静态时间'
              '超时）。判活窗口 = 间隔 × 阈值，必须大于前端固定 10s 的心跳，'
              '否则空闲连接会被误判失活并反复重连。',
              style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(
                  width: 104,
                  child: TextField(
                    key: const Key('heartbeat-interval-input'),
                    controller: _heartbeatIntervalController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: '间隔（秒）',
                      helperText:
                          '$_heartbeatIntervalMin~$_heartbeatIntervalMax',
                      isDense: true,
                    ),
                    onSubmitted: (String value) {
                      final int? parsed = int.tryParse(value.trim());
                      if (parsed != null) {
                        _applyHeartbeatSetting(intervalSeconds: parsed);
                      }
                    },
                  ),
                ),
                IconButton(
                  key: const Key('heartbeat-interval-decrease'),
                  tooltip: '间隔减少 1 秒',
                  onPressed: _heartbeatIntervalSeconds <= _heartbeatIntervalMin
                      ? null
                      : () => _applyHeartbeatSetting(
                          intervalSeconds: _heartbeatIntervalSeconds - 1,
                        ),
                  icon: const Icon(Icons.remove_circle_outline),
                  color: cs.primary,
                ),
                IconButton(
                  key: const Key('heartbeat-interval-increase'),
                  tooltip: '间隔增加 1 秒',
                  onPressed: _heartbeatIntervalSeconds >= _heartbeatIntervalMax
                      ? null
                      : () => _applyHeartbeatSetting(
                          intervalSeconds: _heartbeatIntervalSeconds + 1,
                        ),
                  icon: const Icon(Icons.add_circle_outline),
                  color: cs.primary,
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 104,
                  child: TextField(
                    key: const Key('heartbeat-limit-input'),
                    controller: _missedHeartbeatLimitController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: '阈值（次）',
                      helperText:
                          '$_missedHeartbeatLimitMin~'
                          '$_missedHeartbeatLimitMax',
                      isDense: true,
                    ),
                    onSubmitted: (String value) {
                      final int? parsed = int.tryParse(value.trim());
                      if (parsed != null) {
                        _applyHeartbeatSetting(limit: parsed);
                      }
                    },
                  ),
                ),
                IconButton(
                  key: const Key('heartbeat-limit-decrease'),
                  tooltip: '阈值减少 1 次',
                  onPressed: _missedHeartbeatLimit <= _missedHeartbeatLimitMin
                      ? null
                      : () => _applyHeartbeatSetting(
                          limit: _missedHeartbeatLimit - 1,
                        ),
                  icon: const Icon(Icons.remove_circle_outline),
                  color: cs.primary,
                ),
                IconButton(
                  key: const Key('heartbeat-limit-increase'),
                  tooltip: '阈值增加 1 次',
                  onPressed: _missedHeartbeatLimit >= _missedHeartbeatLimitMax
                      ? null
                      : () => _applyHeartbeatSetting(
                          limit: _missedHeartbeatLimit + 1,
                        ),
                  icon: const Icon(Icons.add_circle_outline),
                  color: cs.primary,
                ),
                const Spacer(),
                OutlinedButton(
                  key: const Key('heartbeat-apply'),
                  onPressed: () {
                    // 两个输入框一起提交（I×N 是一个整体）；解析失败的框按"保持原值"
                    // 处理，不静默当成 0
                    final int? interval = int.tryParse(
                      _heartbeatIntervalController.text.trim(),
                    );
                    final int? limit = int.tryParse(
                      _missedHeartbeatLimitController.text.trim(),
                    );
                    if (interval == null && limit == null) return;
                    _applyHeartbeatSetting(
                      intervalSeconds: interval,
                      limit: limit,
                    );
                  },
                  child: const Text('应用'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '判活窗口 ${_livenessWindowSeconds}s（间隔 '
              '${_heartbeatIntervalSeconds}s × 阈值 $_missedHeartbeatLimit 次；'
              '必须 > ${_minLivenessWindowSeconds}s）',
              style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
            ),
            if (liveBehind)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '核心侧在线生效：间隔 ${_liveIntervalSeconds}s × 阈值 '
                  '$_liveMissLimit 次 —— 丢失阈值与插件宿主 / MCP 客户端的'
                  '心跳参数在下次启动核心后完全一致（WS 判活节拍已立即生效），'
                  'SSH 在下次建连时生效',
                  style: const TextStyle(fontSize: 12, color: Colors.orange),
                ),
              ),
            if (_livenessNotice != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '已按安全下限夹取：$_livenessNotice',
                  style: const TextStyle(fontSize: 12, color: Colors.orange),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 自定义模型卡片（列出模型池 + 新增/编辑/删除入口）
  Widget _buildCustomModelCard() {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '模型池',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                ),
                IconButton(
                  tooltip: '刷新',
                  onPressed: _modelsLoading ? null : _loadModelList,
                  icon: const Icon(Icons.refresh, size: 18),
                ),
                FilledButton.icon(
                  onPressed: () => _openModelEditor(null),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('新增'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '写入 ~/.tree/config/models/<model_id>.yaml，保存后立即对全部 Agent 生效。'
              'API Key 以明文保存在该文件（已在 .gitignore 中忽略）。',
              style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 8),
            if (_modelsLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (_modelsError != null)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '模型列表加载失败：$_modelsError',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.redAccent,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _loadModelList,
                    child: const Text('重试'),
                  ),
                ],
              )
            else if (_models.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '模型池为空，请新增一个模型配置',
                  style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                ),
              )
            else
              ..._models.map((Map<String, dynamic> m) => _buildModelRow(m, cs)),
          ],
        ),
      ),
    );
  }

  /// 单个模型条目行
  Widget _buildModelRow(Map<String, dynamic> model, ColorScheme cs) {
    final String modelId = model['model_id'] as String? ?? '';
    final String name = model['name'] as String? ?? modelId;
    final bool hasKey = model['has_api_key'] as bool? ?? false;
    final String kind = modelKindOf(model);
    // 非 chat 模型只显示各自的定义性参数；chat 仍显示 thinking / vision。
    String kindDetail = '';
    if (kind == kModelKindEmbedding) {
      final num? dim = model['dimensions'] as num?;
      if (dim != null) kindDetail = ' · ${dim.toInt()} 维';
    } else if (kind == kModelKindDecision) {
      final num? threshold = model['confidence_threshold'] as num?;
      if (threshold != null) kindDetail = ' · 阈值 $threshold';
    }
    final String price = modelPricingLabel(model);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Flexible(child: Text(name, style: const TextStyle(fontSize: 14))),
          const SizedBox(width: 6),
          _buildKindBadge(kind, cs),
        ],
      ),
      subtitle: Text(
        '$modelId$kindDetail'
        '${hasKey ? '' : ' · 未配置 API Key'}'
        '${kind == kModelKindChat && (model['thinking'] as bool? ?? false) ? ' · thinking' : ''}'
        '${kind == kModelKindChat && (model['if_vision'] as bool? ?? false) ? ' · vision' : ''}'
        '${price.isEmpty ? '' : ' · $price'}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '编辑',
            icon: const Icon(Icons.edit_outlined, size: 18),
            color: cs.primary,
            onPressed: () => _openModelEditor(model),
          ),
          IconButton(
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline, size: 18),
            color: Colors.redAccent,
            onPressed: () => _deleteModel(model),
          ),
        ],
      ),
    );
  }

  /// 模型类型徽标（chat / embedding / decision）。
  Widget _buildKindBadge(String kind, ColorScheme cs) {
    final Color color = switch (kind) {
      kModelKindEmbedding => Colors.blue,
      kModelKindDecision => Colors.orange,
      _ => cs.primary,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        kind,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  /// 打开模型编辑对话框（[existing] 为 null 表示新增）
  Future<void> _openModelEditor(Map<String, dynamic>? existing) async {
    final Map<String, dynamic>? payload =
        await showDialog<Map<String, dynamic>>(
          context: context,
          builder: (BuildContext context) =>
              ModelEditorDialog(existing: existing),
        );
    if (payload == null || !mounted) return;
    try {
      if (existing == null) {
        await ApiService.createModel(payload);
      } else {
        final String modelId = existing['model_id'] as String? ?? '';
        await ApiService.updateModel(modelId, payload);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(existing == null ? '模型已新增' : '模型已更新'),
          duration: const Duration(seconds: 2),
        ),
      );
      await _loadModelList();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('保存失败：$e'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  /// 删除模型（二次确认；若仍有 agent 绑定则提示）
  Future<void> _deleteModel(Map<String, dynamic> model) async {
    final String modelId = model['model_id'] as String? ?? '';
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删除模型'),
        content: Text(
          '确定删除模型「${model['name'] ?? modelId}」？\n'
          '其配置文件将从服务器移除，操作不可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final Map<String, dynamic> result = await ApiService.deleteModel(modelId);
      final List<dynamic> bound =
          result['bound_agents'] as List<dynamic>? ?? <dynamic>[];
      if (!mounted) return;
      final String suffix = bound.isEmpty
          ? ''
          : '；注意：仍有 ${bound.length} 个 Agent 绑定该模型，需重新指定模型';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已删除$suffix'),
          duration: const Duration(seconds: 3),
        ),
      );
      await _loadModelList();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('删除失败：$e'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  /// 分区标题
  Widget _buildSectionTitle(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  /// 窗口与托盘卡片：关闭按钮的行为 + **真正的退出入口**。
  ///
  /// 为什么退出入口要放在设置页：默认关闭只隐藏窗口，如果用户关掉了托盘图标（Windows
  /// 允许隐藏托盘区图标），他就只剩"任务管理器杀进程"这一条路——那正是本功能要避免的
  /// 误终止。这里给一条明确的、两步确认过的退出路径。
  Widget _buildTrayCard() {
    final TrayService tray = TrayService.instance;
    return Card(
      margin: EdgeInsets.zero,
      child: AnimatedBuilder(
        animation: tray,
        builder: (BuildContext context, _) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SwitchListTile(
                key: const Key('close_to_tray_switch'),
                value: tray.closeToTray,
                onChanged: (bool value) => tray.setCloseToTray(value),
                secondary: const Icon(Icons.minimize_outlined),
                title: const Text('关闭窗口时最小化到系统托盘'),
                subtitle: Text(
                  tray.trayReady
                      ? '关闭按钮只隐藏窗口：Tree 与正在跑的任务继续运行。'
                            '双击托盘图标恢复窗口，右键托盘图标可以「退出 Tree」。'
                      : '当前环境托盘不可用（${tray.installError ?? '原因未知'}），'
                            '关闭窗口会直接退出。',
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.power_settings_new),
                title: const Text('退出 Tree'),
                subtitle: const Text('请核心优雅退出并关闭窗口；正在跑的任务会被终止'),
                trailing: OutlinedButton(
                  key: const Key('quit_tree_button'),
                  onPressed: _confirmQuit,
                  child: const Text('退出'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 退出前的二次确认（这是**会终止在跑任务**的动作，必须问一次）。
  Future<void> _confirmQuit() async {
    final bool confirmed =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('退出 Tree？'),
            content: const Text('正在跑的任务会被终止。仅关闭窗口不会终止任务——那只是把窗口收进托盘。'),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const Key('quit_tree_confirm'),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('退出'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await TrayService.instance.quit();
  }


  /// 文字大小卡片。
  ///
  /// 缩放通过 [TextScaleService] 注入 MaterialApp 的 MediaQuery，
  /// 全局所有 Text 自动跟随。滑杆拖动时实时生效（onChanged 立即提交），
  /// 因为字号变化是本页唯一能"所见即所得"的设置——拖动过程中看不到效果
  /// 就等于没有预览。
  ///
  /// 与系统无障碍缩放的关系：本值是**在系统缩放之上**再乘一次。
  /// 用户在 Windows 辅助功能里调过文本大小后，这里再调仍然有效。
  Widget _buildTextScaleCard() {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: TextScaleService.instance,
      builder: (BuildContext context, Widget? child) {
        final double scale = TextScaleService.instance.scale;
        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '界面文字大小',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 4),
                const Text(
                  '调整界面中所有文字的大小。系统级无障碍缩放仍会叠加生效。',
                  style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.text_fields,
                      size: 14,
                      color: cs.onSurfaceVariant,
                    ),
                    Expanded(
                      child: Slider(
                        key: const Key('text-scale-slider'),
                        value: scale,
                        min: TextScaleService.minScale,
                        max: TextScaleService.maxScale,
                        divisions: 7,
                        label: '${(scale * 100).round()}%',
                        onChanged: (double value) {
                          TextScaleService.instance.setScale(value);
                        },
                      ),
                    ),
                    const Icon(Icons.text_fields, size: 22),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 44,
                      child: Text(
                        '${(scale * 100).round()}%',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurfaceVariant,
                          fontFeatures: const <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 界面字体卡片（用户 2026-10-18：「增加更多字体设置（大小、粗细、字体等等）」）。
  ///
  /// 分工：**字号**在上一节「文字大小」（走 MediaQuery 的 textScaler），这一节管
  /// **字形**——字体族与字重（走 [FontService] 注入的 ThemeData.textTheme）。
  /// 两项都随 FontService 的 notifyListeners 触发根 Widget 重建，改完即时生效，
  /// 不用重启；选中的 chip 自己就长在新字体上，等于一个实时预览。
  Widget _buildFontCard() {
    const TextStyle hintStyle = TextStyle(fontSize: 12, color: Color(0xFF94A3B8));
    return Card(
      margin: EdgeInsets.zero,
      child: ListenableBuilder(
        listenable: FontService.instance,
        builder: (BuildContext context, Widget? child) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '字体族',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 4),
                const Text(
                  '全应用统一换字体。等宽体适合长时间看代码，系统默认交给 Windows 决定。',
                  style: hintStyle,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final UiFontFamily f in UiFontFamily.values)
                      ChoiceChip(
                        key: Key('ui-font-family-${f.key}'),
                        label: Text(f.label, style: const TextStyle(fontSize: 12)),
                        selected: FontService.instance.family == f,
                        onSelected: (bool on) {
                          if (on) FontService.instance.setFamily(f);
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text(
                  '字重',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 4),
                const Text(
                  '整体加粗一档：没写死粗细的文字都跟着变（标题本身更粗，不会被压平）。',
                  style: hintStyle,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final UiFontWeight w in UiFontWeight.values)
                      ChoiceChip(
                        key: Key('ui-font-weight-${w.key}'),
                        label: Text(w.label, style: const TextStyle(fontSize: 12)),
                        selected: FontService.instance.weight == w,
                        onSelected: (bool on) {
                          if (on) FontService.instance.setWeight(w);
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  '字号在上面的「文字大小」一节调整。',
                  style: hintStyle.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 主题管理卡片
  ///
  /// Flutter 3.32+ 起 Radio 的 groupValue/onChanged 迁移到 [RadioGroup] 祖先：
  /// 组状态与变更回调由 RadioGroup 统一持有，子项 RadioListTile 只声明自身 value。
  Widget _buildThemeCard() {
    final ThemeService themeService = ThemeService.instance;
    return Card(
      margin: EdgeInsets.zero,
      child: AnimatedBuilder(
        animation: themeService,
        builder: (BuildContext context, _) {
          return RadioGroup<ThemeMode>(
            groupValue: themeService.mode,
            onChanged: (ThemeMode? value) {
              if (value != null) {
                themeService.setMode(value);
              }
            },
            child: Column(
              children: [
                _buildThemeOption(
                  ThemeMode.light,
                  Icons.light_mode_outlined,
                  '浅色',
                  '明亮模式，适合白天使用',
                ),
                _buildThemeOption(
                  ThemeMode.dark,
                  Icons.dark_mode_outlined,
                  '深色',
                  '深色模式，适合夜间或省电',
                ),
                _buildThemeOption(
                  ThemeMode.system,
                  Icons.brightness_auto_outlined,
                  '跟随系统',
                  '根据操作系统自动切换',
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 单个主题选项（RadioListTile 风格；组状态由 [_buildThemeCard] 的 RadioGroup 持有）
  Widget _buildThemeOption(
    ThemeMode mode,
    IconData icon,
    String title,
    String subtitle,
  ) {
    final cs = Theme.of(context).colorScheme;
    return RadioListTile<ThemeMode>(
      value: mode,
      activeColor: cs.primary,
      secondary: Icon(icon, color: cs.primary),
      title: Text(title),
      subtitle: Text(subtitle),
    );
  }
}

/// 自定义模型编辑对话框（新增 / 编辑）
///
/// 提交时返回一份 `Map<String, dynamic>` 请求体（交给 `ApiService.createModel`
/// 或 `updateModel`）。编辑模式下 **不预填 API Key**（后端从不回显密钥）：
/// 留空即"不修改"，`has_api_key` 只用于提示当前是否已配置。
///
/// kind（chat / embedding / decision）决定协议与专属字段：
/// - 新增时可切换；**编辑时禁用**（后端规定 kind / protocol 创建后不可改）；
/// - protocol 由 kind 推导并只读展示（chat/embedding → openai，decision → jev）。
class ModelEditorDialog extends StatefulWidget {
  /// 待编辑模型（null = 新增）
  final Map<String, dynamic>? existing;

  const ModelEditorDialog({super.key, this.existing});

  @override
  State<ModelEditorDialog> createState() => _ModelEditorDialogState();
}

class _ModelEditorDialogState extends State<ModelEditorDialog> {
  final TextEditingController _modelId = TextEditingController();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _baseUrl = TextEditingController();
  final TextEditingController _apiKey = TextEditingController();
  final TextEditingController _maxSeqlen = TextEditingController();
  final TextEditingController _maxOutput = TextEditingController();

  /// embedding / decision 专属字段
  final TextEditingController _dimensions = TextEditingController();
  final TextEditingController _maxInputTokens = TextEditingController();
  final TextEditingController _confidenceThreshold = TextEditingController();

  /// 已存档位（模型 YAML 的 `reasoning_effort_options`）。
  List<String> _storedEffortOptions = <String>[];

  /// 端点探测到的档位（`GET /api/models/{id}` 的 `meta`，空 = 未声明）。
  List<String> _metaEffortOptions = <String>[];

  /// 端点元数据（价格 / 档位）；null = 还没探测过。
  Map<String, dynamic>? _meta;

  bool _metaLoading = false;
  String _metaError = '';

  bool _thinking = false;
  bool _ifVision = false;
  String _reasoningEffort = '';

  /// 新增时可选；编辑时固定为原值（后端禁止改 kind）。
  String _kind = kModelKindChat;

  /// 思考强度档位兜底（与后端 REASONING_EFFORT_CANONICAL 一致）。
  ///
  /// 只列**有实际区分度**的档位：端点接受的枚举全集里
  /// minimal/medium/xhigh/ultra 与服务端档位一一等价，列出来就是假选项。
  static const List<String> _reasoningEfforts = kFallbackReasoningEfforts;

  bool get _isEdit => widget.existing != null;

  /// 编辑前的 kind（null = 新增；旧数据缺省视为 chat）。
  String? get _originalKind =>
      widget.existing == null ? null : modelKindOf(widget.existing!);

  /// 档位候选：端点声明 > 已存档位 > 兜底。
  List<String> get _candidateEfforts {
    if (_metaEffortOptions.isNotEmpty) {
      return List<String>.of(_metaEffortOptions);
    }
    if (_storedEffortOptions.isNotEmpty) {
      return List<String>.of(_storedEffortOptions);
    }
    return List<String>.of(_reasoningEfforts);
  }

  /// 价格标签；端点没给价格 ⇒ 空串。
  String get _pricingLabel => modelPricingLabel(<String, dynamic>{
    if (_meta != null) 'meta': _meta,
  });

  @override
  void initState() {
    super.initState();
    final Map<String, dynamic>? e = widget.existing;
    if (e == null) return;
    _kind = modelKindOf(e);
    _modelId.text = e['model_id'] as String? ?? '';
    _name.text = e['name'] as String? ?? '';
    // base_url 后端已脱敏（仅协议+主机），编辑时留空表示"按原值不变"
    _thinking = e['thinking'] as bool? ?? false;
    _ifVision = e['if_vision'] as bool? ?? false;
    _reasoningEffort = e['reasoning_effort'] as String? ?? '';
    // 后端已按"模型声明或全局回退"解析好档位列表，直接回填（不预设当前选中值：
    // 列表仅表示"哪些可被 agent 覆盖"，与模型自身默认档位是两件事）
    final List<dynamic>? opts = e['reasoning_effort_options'] as List<dynamic>?;
    if (opts != null) {
      _storedEffortOptions = <String>[
        for (final dynamic v in opts)
          if ('$v'.trim().isNotEmpty) '$v'.trim(),
      ];
    }
    final Object? meta = e['meta'];
    if (meta is Map) {
      _meta = Map<String, dynamic>.from(meta);
      _metaEffortOptions = modelMetaEffortsOf(e);
      _metaError = '${_meta!['error'] ?? ''}';
    }
    final int? seq = (e['max_seqlen'] as num?)?.toInt();
    if (seq != null) _maxSeqlen.text = '$seq';
    final int? out = (e['max_output_tokens'] as num?)?.toInt();
    if (out != null) _maxOutput.text = '$out';
    final int? dim = (e['dimensions'] as num?)?.toInt();
    if (dim != null) _dimensions.text = '$dim';
    final int? maxInput = (e['max_input_tokens'] as num?)?.toInt();
    if (maxInput != null) _maxInputTokens.text = '$maxInput';
    final num? threshold = e['confidence_threshold'] as num?;
    if (threshold != null) _confidenceThreshold.text = '$threshold';
  }

  @override
  void dispose() {
    _modelId.dispose();
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _maxSeqlen.dispose();
    _maxOutput.dispose();
    _dimensions.dispose();
    _maxInputTokens.dispose();
    _confidenceThreshold.dispose();
    super.dispose();
  }

  /// 从端点探测价格与思考档位（仅编辑已保存的模型可用）。
  Future<void> _refreshMeta() async {
    final String modelId = widget.existing?['model_id'] as String? ?? '';
    if (modelId.isEmpty) return;
    setState(() {
      _metaLoading = true;
      _metaError = '';
    });
    try {
      final Map<String, dynamic> result = await ApiService.refreshModelMeta(
        modelId,
      );
      if (!mounted) return;
      final Object? meta = result['meta'];
      final String error = '${result['error'] ?? ''}';
      setState(() {
        _metaLoading = false;
        _metaError = error;
        if (meta is Map) {
          _meta = Map<String, dynamic>.from(meta);
          _metaEffortOptions = modelMetaEffortsOf(<String, dynamic>{
            'meta': _meta,
          });
        }
      });
      if (error.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('探测失败：$error')),
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _metaLoading = false;
        _metaError = '$error';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('探测失败：$error')),
      );
    }
  }

  /// 思考强度下拉项：候选来自端点探测 / 已存档位 / 兜底。
  ///
  /// 当前 `_reasoningEffort` 若不在候选中（如文件里存的是档位声明之外的旧值，
  /// 或端点刚把档位列表改窄）**必须补进 items**：`DropdownButtonFormField` 的
  /// value 不在 items 中会直接断言失败，整个编辑弹窗打不开。
  List<DropdownMenuItem<String>> _buildEffortItems() {
    final List<String> candidates = _candidateEfforts;
    if (_reasoningEffort.isNotEmpty && !candidates.contains(_reasoningEffort)) {
      candidates.add(_reasoningEffort);
    }
    return <DropdownMenuItem<String>>[
      const DropdownMenuItem<String>(value: '', child: Text('不设置')),
      ...candidates.map(
        (String e) => DropdownMenuItem<String>(value: e, child: Text(e)),
      ),
    ];
  }

  /// 从当前输入组装纯数据草稿（校验与请求体组装都在 [ModelEditorDraft]）。
  ModelEditorDraft _currentDraft() {
    return ModelEditorDraft(
      originalKind: _originalKind,
      kind: _isEdit ? _originalKind! : _kind,
      modelId: _modelId.text,
      name: _name.text,
      baseUrl: _baseUrl.text,
      apiKey: _apiKey.text,
      reasoningEffort: _reasoningEffort,
      reasoningEffortOptions: _candidateEfforts,
      maxSeqlen: int.tryParse(_maxSeqlen.text.trim()),
      maxOutputTokens: int.tryParse(_maxOutput.text.trim()),
      thinking: _thinking,
      ifVision: _ifVision,
      dimensions: int.tryParse(_dimensions.text.trim()),
      maxInputTokens: int.tryParse(_maxInputTokens.text.trim()),
      confidenceThreshold: double.tryParse(_confidenceThreshold.text.trim()),
    );
  }

  void _submit() {
    final ModelEditorDraft draft = _currentDraft();
    final String? error = draft.validate();
    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    Navigator.of(context).pop(draft.toPayload());
  }

  /// 档位来源（端点探测，替代手填）+ 价格行。
  Widget _buildEffortSourceRow() {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String source;
    if (_metaEffortOptions.isNotEmpty) {
      source = '端点声明档位：${_metaEffortOptions.join(' / ')}';
    } else if (_storedEffortOptions.isNotEmpty) {
      source = '未探测到端点档位，沿用已存档位：${_storedEffortOptions.join(' / ')}';
    } else {
      source = '未探测到端点档位，使用兜底：${_reasoningEfforts.join(' / ')}';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                source,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
            if (_isEdit)
              IconButton(
                tooltip: '从端点探测价格与档位',
                visualDensity: VisualDensity.compact,
                onPressed: _metaLoading ? null : _refreshMeta,
                icon: _metaLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_download_outlined, size: 18),
              ),
          ],
        ),
        if (!_isEdit)
          Text(
            '保存后可从端点探测价格与思考档位（替代手填）',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        if (_pricingLabel.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '价格：$_pricingLabel',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ),
        if (_metaError.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '上次探测失败：$_metaError',
              style: const TextStyle(fontSize: 11, color: Colors.orange),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool hasKey = widget.existing?['has_api_key'] as bool? ?? false;
    final ModelKindFields fields = modelKindFieldsOf(_kind);
    return AlertDialog(
      title: Text(_isEdit ? '编辑模型' : '新增模型'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              TextField(
                controller: _modelId,
                enabled: !_isEdit,
                decoration: const InputDecoration(
                  labelText: 'model_id',
                  helperText: '唯一标识，同时作为配置文件名（字母/数字/. _ -）',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: '显示名称',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                key: const Key('model-editor-kind'),
                initialValue: _kind,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: '模型类型（kind）',
                  helperText: _isEdit
                      ? '类型创建后不可修改'
                      : 'chat 对话 / embedding 检索 / decision 决策',
                  isDense: true,
                ),
                items: kModelKinds
                    .map(
                      (String k) => DropdownMenuItem<String>(
                        value: k,
                        child: Text(k),
                      ),
                    )
                    .toList(),
                onChanged: _isEdit
                    ? null
                    : (String? value) =>
                        setState(() => _kind = value ?? kModelKindChat),
              ),
              const SizedBox(height: 10),
              TextFormField(
                key: ValueKey<String>('model-editor-protocol-$_kind'),
                initialValue: protocolForKind(_kind),
                enabled: false,
                decoration: const InputDecoration(
                  labelText: 'protocol（由 kind 推导）',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _baseUrl,
                decoration: InputDecoration(
                  labelText: 'base_url',
                  helperText: _isEdit
                      ? '留空 = 保持原地址不变'
                      : 'OpenAI 兼容端点，如 https://api.example.com/v1',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _apiKey,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'api_key',
                  helperText: _isEdit
                      ? (hasKey ? '已配置；留空 = 不修改' : '当前未配置')
                      : '必填',
                  isDense: true,
                ),
              ),
              if (fields.chat) ...<Widget>[
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: _reasoningEffort,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '思考强度默认档位（reasoning_effort）',
                    helperText: '仅在该模型可选档位内；可被各 Agent 覆盖',
                    isDense: true,
                  ),
                  items: _buildEffortItems(),
                  onChanged: (String? value) {
                    setState(() => _reasoningEffort = value ?? '');
                  },
                ),
                const SizedBox(height: 10),
                _buildEffortSourceRow(),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _maxSeqlen,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '总上下文上限 tokens',
                          hintText: '如 65536',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _maxOutput,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '最大输出 tokens',
                          hintText: '留空不限',
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _thinking,
                  onChanged: (bool v) => setState(() => _thinking = v),
                  activeThumbColor: cs.primary,
                  title: const Text(
                    '思考模型（thinking）',
                    style: TextStyle(fontSize: 13),
                  ),
                  subtitle: const Text(
                    '开启后历史思考会按 DeepSeek 规则作为 reasoning_content 回传端点'
                    '（带 tools 时官方要求回传，缺失会 400）；'
                    '复用思考链能让后续思考更短、成功率更高，代价是输入 token 增加。',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _ifVision,
                  onChanged: (bool v) => setState(() => _ifVision = v),
                  activeThumbColor: cs.primary,
                  title: const Text(
                    '支持图像输入（if_vision）',
                    style: TextStyle(fontSize: 13),
                  ),
                  subtitle: const Text(
                    '开启后：对话里的图片会先上传到该模型的 Files API，'
                    '再以 file_id 引用发送（需端点支持 file 内容块，如 DeepSeek）；'
                    '关闭时模型只会拿到图片在工作空间里的路径。',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ],
              if (fields.embedding) ...<Widget>[
                const SizedBox(height: 10),
                TextField(
                  key: const Key('model-editor-dimensions'),
                  controller: _dimensions,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '维度（dimensions）',
                    hintText: '如 1024',
                    helperText: '必填且 > 0；须与端点返回的向量维度一致',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const Key('model-editor-max-input-tokens'),
                  controller: _maxInputTokens,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '最大输入 tokens（max_input_tokens）',
                    hintText: '留空不限制',
                    isDense: true,
                  ),
                ),
              ],
              if (fields.decision) ...<Widget>[
                const SizedBox(height: 10),
                TextField(
                  key: const Key('model-editor-confidence'),
                  controller: _confidenceThreshold,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '置信度阈值（confidence_threshold）',
                    hintText: '0~1，如 0.7',
                    helperText: '必填；低于阈值回退 chat / 人工',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const Key('model-editor-max-input-tokens'),
                  controller: _maxInputTokens,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '最大输入 tokens（max_input_tokens）',
                    hintText: '留空不限制',
                    isDense: true,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ElevatedButton(onPressed: _submit, child: Text(_isEdit ? '保存' : '创建')),
      ],
    );
  }
}

/// 主题色卡片：荧光绿 / 豆沙绿 / 薄荷绿 / 自定义（十六进制颜色码）。
///
/// 背景是用户反馈「荧光绿色块长期使用会晃眼」：主亮色块（用户消息气泡等）
/// 大面积铺在屏幕上，高饱和荧光绿看久了刺眼。这里选的颜色就是
/// `colorScheme.primary` 的来源，整套派生色（容器/边线/选中态）跟着换，
/// 实时生效并持久化（见 [ThemeService] 与 `main.dart` 的主题构建）。
///
/// 自定义输入框的提交时机：输入过程中只做合法性校验（实时预览色块 + 报错），
/// 回车/失焦才真正应用并落盘——否则每敲一个字符都重建一遍全局主题。
class _AccentColorCard extends StatefulWidget {
  const _AccentColorCard();

  @override
  State<_AccentColorCard> createState() => _AccentColorCardState();
}

class _AccentColorCardState extends State<_AccentColorCard> {
  final TextEditingController _hexController = TextEditingController();
  final FocusNode _hexFocus = FocusNode();

  /// 输入框是否已用服务端的当前值初始化过（只在首次同步，不打断正在编辑的草稿）
  bool _hexSynced = false;

  /// 当前输入的十六进制是否合法（只管报错展示，非法时不应用）
  bool _hexValid = true;

  @override
  void initState() {
    super.initState();
    _hexController.addListener(_onHexChanged);
  }

  @override
  void dispose() {
    _hexController.removeListener(_onHexChanged);
    _hexController.dispose();
    _hexFocus.dispose();
    super.dispose();
  }

  /// 输入过程：只校验格式并刷新预览，不切选项、不落盘
  void _onHexChanged() {
    setState(() {
      _hexValid = ThemeService.parseUserHex(_hexController.text) != null;
    });
  }

  /// 回车/失焦提交：合法才应用（ThemeService 内部还会再挡一道非法值）
  void _submitHex() {
    final String text = _hexController.text.trim();
    if (text.isEmpty) return;
    ThemeService.instance.applyCustomAccent(text);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final ThemeService service = ThemeService.instance;
    if (!_hexSynced) {
      _hexSynced = true;
      _hexController.text = service.customAccentHex;
      _onHexChanged();
    }
    final bool customSelected = service.accentKey == ThemeService.customAccentKey;
    // 预览色：输入合法用输入值；已选自定义但输入非法时回退到当前生效色
    final Color previewColor = ThemeService.parseUserHex(_hexController.text) ??
        service.accentColor;
    return Card(
      margin: EdgeInsets.zero,
      child: AnimatedBuilder(
        animation: service,
        builder: (BuildContext context, Widget? child) {
          return RadioGroup<String>(
            groupValue: service.accentKey,
            onChanged: (String? value) {
              if (value != null && value != ThemeService.customAccentKey) {
                service.setAccent(value);
              }
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                ...ThemeService.accentPresets.map(
                  (AccentPreset p) => _buildAccentOption(
                    value: p.key,
                    swatch: p.color,
                    title: p.label,
                    subtitle: '#${p.hex}',
                  ),
                ),
                RadioListTile<String>(
                  key: const Key('accent-custom-option'),
                  value: ThemeService.customAccentKey,
                  activeColor: cs.primary,
                  title: const Text('自定义'),
                  subtitle: const Text('输入十六进制颜色码，如 #7FD1AE'),
                ),
                // 自定义色号输入：所有选项下同宽展示，不必先选中才能填值
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: <Widget>[
                      _SwatchChip(color: previewColor),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          key: const Key('accent-custom-field'),
                          controller: _hexController,
                          focusNode: _hexFocus,
                          maxLength: 7,
                          inputFormatters: <TextInputFormatter>[
                            FilteringTextInputFormatter.allow(
                                RegExp(r'[0-9a-fA-F#]')),
                          ],
                          textCapitalization: TextCapitalization.characters,
                          style: const TextStyle(fontSize: 13),
                          decoration: InputDecoration(
                            isDense: true,
                            counterText: '',
                            hintText: '#RRGGBB',
                            errorText: _hexValid ? null : '格式非法，应为 #RRGGBB',
                            border: const OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => _submitHex(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 92,
                        child: FilledButton(
                          key: const Key('accent-custom-apply'),
                          style: FilledButton.styleFrom(
                            backgroundColor: cs.primary,
                            foregroundColor: cs.onPrimary,
                          ),
                          onPressed: _hexValid ? _submitHex : null,
                          child: Text(customSelected ? '已应用' : '应用'),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: Text(
                    '荧光绿长期使用晃眼时，可换豆沙绿/薄荷绿等低饱和护眼色；'
                    '选中即时生效，重启后保留。',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 单个预设选项：左侧色块预览，副标题直接标出色号
  Widget _buildAccentOption({
    required String value,
    required Color swatch,
    required String title,
    required String subtitle,
  }) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return RadioListTile<String>(
      key: Key('accent-option-$value'),
      value: value,
      activeColor: cs.primary,
      secondary: _SwatchChip(color: swatch),
      title: Text(title),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
    );
  }
}

/// 主题色预览色块（圆角小方块，带描边以便深色下也看得见）
class _SwatchChip extends StatelessWidget {
  const _SwatchChip({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: cs.outlineVariant),
      ),
    );
  }
}
