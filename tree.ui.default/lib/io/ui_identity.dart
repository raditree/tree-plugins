import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../app_version.dart';

/// UI 插件的**身份**（`ui.hello` 的来源）。
///
/// 身份优先读可执行体同目录的 `plugin.json`（插件安装后的真实形态）；
/// 开发期 `flutter run` 没有清单，则退回内置默认 id 并**不发送 hello**——
/// 未在 `plugins.yaml` 声明的 id 会让核心 `_rejectAndClose` 掉整条连接，
/// 开发回路会直接断掉。这正是 U3 的取舍：**装成插件才声明身份**。
class UiIdentity {
  const UiIdentity({
    required this.pluginId,
    required this.version,
    required this.capabilities,
    required this.fromManifest,
    this.error = '',
    this.brandingIcon,
  });

  /// 打包清单里的默认 id（与 `plugin.json` 一致）。
  static const String defaultPluginId = 'tree.ui.default';

  /// 本界面确实实现了插件管理（引导页 / 插件面板），据此参与"是否需要引导页"的聚合。
  static const String capabilityPluginManage = 'plugin.manage';

  /// `ui.hello` 的帧类型名（协议包里的同一字面量）。
  static const String helloType = 'ui.hello';

  /// 品牌图标在插件目录内的相对路径。
  ///
  /// `assets/tray_icon.ico` 由 Flutter 复制到 `data/flutter_assets/assets/`，
  /// 打包脚本整目录拷贝，所以安装后这个路径稳定存在。品牌申报用 `role: exe`
  /// （Windows 快捷方式只认 `.ico`），文件缺失时**不申报**，让核心回默认图标，
  /// 而不是报一个坏路径。
  static const String brandingIconRelativePath =
      'data/flutter_assets/assets/tray_icon.ico';

  final String pluginId;
  final String version;

  /// 能力声明（默认 `plugin.manage`）。
  final List<String> capabilities;

  /// 是否来自同目录 `plugin.json`（只有 true 才发 `ui.hello`）。
  final bool fromManifest;

  /// 清单读取失败的可读原因（仅诊断用，不阻断启动）。
  final String error;

  /// 品牌图标的绝对路径；null = 文件不存在，不申报（核心回默认图标）。
  final String? brandingIcon;

  /// 连上核心后要发的握手帧；`fromManifest` 为 false 时返回 null（不发）。
  ///
  /// [windowId] 来自核心注入的 `TREE_UI_WINDOW_ID`：多窗口时它让核心把
  /// "连接"与"窗口"对上（`/api/meta.ui[].connections` 就是窗口数）。
  Map<String, dynamic>? helloFrame({String windowId = ''}) {
    if (!fromManifest || pluginId.isEmpty) return null;
    return <String, dynamic>{
      'type': helloType,
      'data': <String, dynamic>{
        'plugin_id': pluginId,
        'version': version,
        'capabilities': capabilities,
        if (windowId.isNotEmpty) 'window_id': windowId,
        if (brandingIcon != null)
          'branding': <String, dynamic>{
            'icon': brandingIcon,
            'role': 'exe',
          },
      },
    };
  }

  /// 读取身份：默认从 `Platform.resolvedExecutable` 同目录的 `plugin.json` 取。
  ///
  /// [appDir] / [manifestPath] 仅供测试注入。
  static UiIdentity load({Directory? appDir, String? manifestPath}) {
    final Directory baseDir =
        appDir ?? File(Platform.resolvedExecutable).parent;
    final String path = manifestPath ?? p.join(baseDir.path, 'plugin.json');
    final File file = File(path);
    if (!file.existsSync()) {
      return const UiIdentity(
        pluginId: defaultPluginId,
        version: kAppVersion,
        capabilities: <String>[capabilityPluginManage],
        fromManifest: false,
      );
    }
    try {
      final Object? decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) {
        return _fallback('$path 不是 JSON 对象');
      }
      final Object? rawId = decoded['id'];
      final String id = rawId == null ? '' : rawId.toString().trim();
      if (id.isEmpty) return _fallback('$path 缺少 id');
      final Object? rawVersion = decoded['version'];
      final String version = rawVersion == null
          ? kAppVersion
          : rawVersion.toString().trim();
      return UiIdentity(
        pluginId: id,
        version: version.isEmpty ? kAppVersion : version,
        capabilities: const <String>[capabilityPluginManage],
        fromManifest: true,
        brandingIcon: _brandingIconOf(baseDir),
      );
    } catch (error) {
      return _fallback('读 $path 失败：$error');
    }
  }

  static UiIdentity _fallback(String error) => UiIdentity(
    pluginId: defaultPluginId,
    version: kAppVersion,
    capabilities: const <String>[capabilityPluginManage],
    fromManifest: false,
    error: error,
  );

  /// 品牌图标绝对路径；文件不存在 ⇒ null（不申报，核心回默认）。
  static String? _brandingIconOf(Directory baseDir) {
    final File icon = File(
      p.joinAll(<String>[
        baseDir.path,
        ...brandingIconRelativePath.split('/'),
      ]),
    );
    return icon.existsSync() ? icon.path : null;
  }
}
