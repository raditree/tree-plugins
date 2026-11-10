import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../io/api_service.dart';
import '../../io/local_executor_service.dart';
import '../../io/platform_support.dart';
import '../app_radius.dart';
import '../services/download_center.dart';
import '../services/editor_buffer.dart';
import '../services/workspace_paths.dart';
import 'file_sync_button.dart';
import 'file_tree.dart';
import 'file_viewer.dart';
import 'split_panes.dart';

/// 同文件双开时的窗格提示：两侧**共享同一份缓冲**，不是两份各写各的。
const String _sharedBufferNotice = '同一文件已在另一窗格打开：两侧共享同一份缓冲，就地编辑即同步';

/// 文件管理面板——右栏「文件」**窗口**的身体。
///
/// 用户 2026-10-18 把右栏改成了窗口宿主（见 [RightPanelHost]）：原先这里一口气
/// 挂着「文件 / MCP 配置 / 模型信息 / 问题回复 / 正在执行的 tool / 详情 + 插件面板」
/// 六个顶层页签，现在拆成一个个**按需打开的窗口**——本控件只保留「文件」这一格。
///
/// 用户 2026-10-19 又做了两处调整：
/// - **Git 历史 / Todo 从本窗移出**，各归一个独立窗口（见 main_page 的
///   `git` / `todo` 窗口条目）——文件窗只干"看文件"这一件事；
/// - **支持多文件同时存在**：打开的文件排成一条 tab（[FileViewer] 上方的选项卡），
///   点文件树 / 点 tab 都能切，一个文档一份 [EditorBuffer]，切 tab 不丢改动；
///   分屏仍是"当前文件再开一个视图"（两侧共享同一份缓冲）。
///
/// 本窗口**不再需要 agent 的 workspace 才存在**：未选中 agent 时由宿主渲染
/// 「请先选择 Agent」的空态（见 main_page），所以右栏在没有 agent 时也长期在。
///
/// 点击文件时在**查看器**打开它：树与查看器**同屏**（左右分栏，比例默认 0.3，
/// 太窄时按 [SplitPanes] 的既有口径降级成一次只显示一个）；没打开文件时树独占整个区域。
/// 关闭查看器（tab 上的 × / tab 右键菜单 / 工具条）回到树独占。见 lib/README.md 不变量 16。
///
/// **分屏是"一个文件一份文档、两个视图"**：两侧共用同一个
/// [EditorBuffer]（同一个控制器 + 一份 dirty / saving / loadedSize），两边都能编辑、
/// 一边打字另一边立刻可见，保存只有一套语义（见 [lib/README.md] 不变量 13）。
class FilePanel extends StatefulWidget {
  /// 工作空间 ID
  final String workspaceId;

  /// 所属团队 ID（下载标注 / Todo 面板本地模式读取）
  final String? teamId;

  /// 所属团队显示名（下载列表里标注「来自哪个 team」）；为空时退回 [teamId]。
  final String teamName;

  /// 文件区外部刷新触发（由宿主监听 `WorkspaceArea.files` 递进来；本面板只叠加内部计数）
  final int fileRefreshTrigger;

  const FilePanel({
    super.key,
    required this.workspaceId,
    this.teamId,
    this.teamName = '',
    this.fileRefreshTrigger = 0,
  });

  @override
  State<FilePanel> createState() => _FilePanelState();
}

class _FilePanelState extends State<FilePanel> {
  /// 文件区**内部**刷新计数：本面板自己的动作（上传等）递增，与外部触发相加后交给 FileTree。
  int _fileRefreshTrigger = 0;

  /// 已打开的文件（查看器上方的 tab 条），顺序即 tab 顺序。
  ///
  /// 用户 2026-10-19：「支持多文件同时存在（目前仅支持单文件+二分屏）」。
  /// 一个路径只留一份：再点已开着的就切过去，不会叠出两个同名 tab。
  final List<String> _openFiles = <String>[];

  /// 每个已打开文件的**共享编辑缓冲**：一个文档一份 [EditorBuffer]，窗格只是它的视图
  /// （同文件双开时两个窗格取同一个实例，见 [EditorBuffer]）。
  final Map<String, EditorBuffer> _buffers = <String, EditorBuffer>{};

  /// 非分屏时，每个已打开文件那个查看器的 key：换文件 / 关 tab 前问它「未保存怎么办」。
  final Map<String, GlobalKey<FileViewerState>> _fileKeys =
      <String, GlobalKey<FileViewerState>>{};

  /// tab 条的水平滚动控制器：常显滑块 + 滚轮横滚 + 活动 tab 自动滚入视野。
  final ScrollController _tabScroll = ScrollController();

  /// 每个 tab 的 key：切到远处的 tab 时 `Scrollable.ensureVisible` 用它。
  final Map<String, GlobalKey> _tabKeys = <String, GlobalKey>{};

  /// 分屏时两格的 key（两格都看**当前文件**，共用同一份缓冲）。
  ///
  /// 固定两个实例：换文件时 viewing 的路径变了，[FileViewer] 的 didUpdateWidget 会重载，
  /// 不用重建 key（重建会把展开态 / 滚动位置丢掉）。
  final List<GlobalKey<FileViewerState>> _splitKeys =
      <GlobalKey<FileViewerState>>[
    GlobalKey<FileViewerState>(),
    GlobalKey<FileViewerState>(),
  ];

  /// 当前活动文件（null = 查看器关着，只剩文件树）
  String? _activeFile;

  /// 是否分屏（把当前文件再开一个视图）
  bool _split = false;

  /// 分屏方向（horizontal = 左右）与分隔比例
  Axis _splitAxis = Axis.horizontal;
  double _splitRatio = 0.5;

  /// 分屏时当前聚焦的窗格（0/1）
  int _activePane = 0;

  /// 窗格分隔条宽度（查看器内部两格 + 树/查看器上下分栏共用）
  static const double _paneDividerWidth = 7;

  /// 树与查看器**同屏分栏**时树占的比例（默认 0.3：目录当侧栏、查看器拿大头）。
  ///
  /// 左右分栏下这个比例会随面板宽度伸缩（400px ⇒ 树 200px；1000px ⇒ 树 300px），
  /// 拖过就记在面板状态里；夹取与最小宽度交给 [SplitPanes]。
  double _treeSplitRatio = 0.3;

  /// 同屏分栏每一侧的最小**宽度**（目录这边至少要放得下头部那排动作键与 Tab）
  static const double _treeSplitMinExtent = 200;

  /// 可用**宽度**低于它就降级成"只显示查看器"：再窄下去两侧都不够用（用户 2026-10-04：
  /// 与其把查看器压成一条，不如让它占满，目录用工具条上的按钮随时叫回来）
  static const double _treeSplitDegradeBelow = 400;

  /// 用户是否要显示目录（工具条按钮切换）。**意愿与"这一刻能不能显示"分开**：
  /// 面板太窄时 [SplitPanes] 会降级成只看查看器，但这里不清掉用户的意愿——
  /// 拖宽之后目录自己回来，不用再点一次。
  bool _treeWanted = true;

  /// 最近一次布局给树/查看器区域的可用宽度（只用来把"面板太窄"如实说给用户听）
  double _lastTreeAreaWidth = 0;

  /// 文件树那块的 key。
  ///
  /// 为什么需要它：打开 / 关闭查看器会把这块从「Expanded 的独子」**搬到** SplitPanes
  /// 的上格（或反过来）。没有 GlobalKey 的话元素树会重建——展开的目录、已加载的层、
  /// 选中项全丢（用户每开一个文件树就塌一次）；GlobalKey 让它被"搬"过去而不是重建。
  final GlobalKey _fileTabsKey = GlobalKey(debugLabel: 'file_panel_tabs');

  /// 是否正显示查看器
  bool get _viewerOpen => _activeFile != null;

  /// 文件树当前所在目录（空 = 根）；「同步到本地」按它限定作用域（M8b）
  String _treePath = '';

  /// 刷新文件树（本面板自己的动作，如上传完成；与外部触发叠加后交给 FileTree）
  void _refreshFileTree() {
    setState(() {
      _fileRefreshTrigger++;
    });
  }

  /// 一键重置工作空间里的系统提示词 / Spec。
  ///
  /// 核心侧语义：现有文件先备份成 `.bak.<n>`，再写回默认内容（Spec 的自定义文件
  /// 一并清理，备份里可找回）。这里不弹二次确认——"一键"就是它的用法，且备份保证可逆。
  Future<void> _resetWorkspace(String target) async {
    final String agentId = widget.teamId ?? '';
    if (agentId.isEmpty) {
      _showSnackBar('未选中 agent，无法重置');
      return;
    }
    try {
      await ApiService.resetAgentWorkspace(agentId, target: target);
      if (!mounted) return;
      _showSnackBar(
        target == 'spec'
            ? '已重置 Spec（旧文件已备份为 .bak.<n>）'
            : '已重置系统提示词（旧文件已备份为 .bak.<n>）',
      );
      if (target != 'system_prompt') _refreshFileTree();
    } catch (error) {
      if (!mounted) return;
      _showSnackBar('重置失败：$error');
    }
  }

  @override
  void initState() {
    super.initState();
    // 本地模式开关/工作目录变化时重新加载文件列表
    LocalExecutorService.instance.addListener(_onLocalModeChanged);
  }

  @override
  void dispose() {
    LocalExecutorService.instance.removeListener(_onLocalModeChanged);
    // 面板没了，手里那些共享缓冲（及其控制器）一起收掉；
    // 同文件双开时两格是同一个实例，去重后再 dispose。
    for (final EditorBuffer buffer in <EditorBuffer>{..._buffers.values}) {
      buffer.dispose();
    }
    _buffers.clear();
    _tabScroll.dispose();
    super.dispose();
  }

  /// 本地执行模式状态变化（切换开关/选择工作目录）时刷新文件树。
  ///
  /// 切换执行模式会改变文件面板的数据源（本机目录 / 远端工作空间），
  /// 若不刷新则仍显示上一个数据源的文件列表。
  void _onLocalModeChanged() {
    if (!mounted) return;
    _refreshFileTree();
  }

  /// 文件树里重命名成功：已打开文件（或其后代）的路径**跟着改名**。
  ///
  /// 只换路径字符串：缓冲实例不动（同一份文档换了个名字，不是两份文档），
  /// [FileViewer] 的 didUpdateWidget 会按新路径重新加载。
  void _onTreePathRenamed(String from, String to) {
    bool changed = false;
    for (int i = 0; i < _openFiles.length; i++) {
      final String old = _openFiles[i];
      final String next = workspacePathRemap(old, from, to);
      if (next == old) continue;
      _openFiles[i] = next;
      final EditorBuffer? buffer = _buffers.remove(old);
      if (buffer != null) _buffers[next] = buffer;
      final GlobalKey<FileViewerState>? key = _fileKeys.remove(old);
      if (key != null) _fileKeys[next] = key;
      final GlobalKey? tabKey = _tabKeys.remove(old);
      if (tabKey != null) _tabKeys[next] = tabKey;
      if (_activeFile == old) _activeFile = next;
      changed = true;
    }
    if (!changed || !mounted) return;
    setState(() {});
  }

  /// 文件树里删除了路径：指向它的 tab 一起关掉。
  ///
  /// 不再问"未保存的改动怎么办"——删除前已经确认过一次（那时文件还在，用户选了删），
  /// 删完再弹一次确认只会自相矛盾。缓冲按"还有没有别的 tab 引用"释放。
  void _onTreePathDeleted(String path) {
    final List<String> closing = <String>[
      for (final String p in _openFiles)
        if (workspacePathAtOrUnder(p, path)) p,
    ];
    if (closing.isEmpty) return;
    final List<EditorBuffer> released = <EditorBuffer>[];
    setState(() {
      for (final String p in closing) {
        _openFiles.remove(p);
        final EditorBuffer? buffer = _buffers.remove(p);
        if (buffer != null) released.add(buffer);
        _fileKeys.remove(p);
        _tabKeys.remove(p);
      }
      if (_activeFile == null || !_openFiles.contains(_activeFile)) {
        _activeFile = _openFiles.isEmpty ? null : _openFiles.last;
      }
      if (_openFiles.length < 2) _split = false;
      _activePane = 0;
    });
    if (_activeFile != null) _ensureTabVisible(_activeFile!);
    for (final EditorBuffer buffer in released) {
      _releaseBuffer(buffer);
    }
    _showSnackBar('文件已删除，查看器已关闭：$path');
  }

  /// 打开文件：已开着就切过去，否则加一个 tab 并切过去（别的文件一个字都不丢）。
  ///
  /// 与旧实现的关键差别：换文件**不再问"未保存的改动怎么办"**——旧实现是把窗格里的
  /// 文件顶掉，那才有丢改动的风险；现在是"再多开一个选项卡"，上一个文件的缓冲还挂在
  /// [_buffers] 里。只有**关掉一个 tab** 才需要问（见 [_closeFile]）。
  void _openFile(String path) {
    final bool isNew = !_openFiles.contains(path);
    setState(() {
      if (isNew) {
        _openFiles.add(path);
        _buffers[path] = EditorBuffer();
        _fileKeys[path] = GlobalKey<FileViewerState>();
      }
      _activeFile = path;
      _activePane = 0;
    });
    _ensureTabVisible(path);
  }

  /// 某个文件此刻**挂载着**的查看器 state（分屏时取第一格；非活动文件没挂载）。
  FileViewerState? _mountedStateFor(String path) {
    if (path != _activeFile) return null;
    if (_split) return _splitKeys[0].currentState;
    return _fileKeys[path]?.currentState;
  }

  /// 活动窗格里挂载着的查看器 state（tab 右键菜单的预览/源码、复制、重新加载
  /// 落在用户正看着的那一格；非活动文件没挂载查看器，没有这些动作）。
  FileViewerState? get _activePaneState {
    if (_activeFile == null) return null;
    if (_split) return _splitKeys[_activePane.clamp(0, 1)].currentState;
    return _fileKeys[_activeFile]?.currentState;
  }

  /// 离开某个文件前把未保存内容处理掉（true = 可以离开）。
  ///
  /// 非活动文件没挂载查看器 ⇒ 未保存内容只留在它的缓冲里、不会因为切 tab 丢
  /// （切走时 [FileViewer] 的 dispose 若开了失焦保存已经补写过），这里直接放行。
  Future<bool> _confirmLeavePath(String path) async {
    final FileViewerState? state = _mountedStateFor(path);
    if (state == null) return true;
    return state.confirmLeave();
  }

  /// 关掉一个文件的 tab（未保存的内容按设置自动保存或问一次）。返回是否真的关掉了。
  Future<bool> _closeFile(String path) async {
    final int index = _openFiles.indexOf(path);
    if (index < 0) return true;
    if (!await _confirmLeavePath(path)) return false;
    if (!mounted) return false;
    final EditorBuffer? buffer = _buffers.remove(path);
    setState(() {
      _openFiles.removeAt(index);
      _fileKeys.remove(path);
      _tabKeys.remove(path);
      if (_activeFile == path) {
        _activeFile = _openFiles.isEmpty
            ? null
            : _openFiles[index.clamp(0, _openFiles.length - 1)];
      }
      if (_openFiles.length < 2) _split = false;
      _activePane = 0;
    });
    if (_activeFile != null) _ensureTabVisible(_activeFile!);
    if (buffer != null) _releaseBuffer(buffer);
    return true;
  }

  /// 没有 tab 再引用这份缓冲了就释放它（控制器随 dispose 一起收掉）。
  ///
  /// 下一帧再释放：本帧刚被换掉的 TextField 还在拿它换 controller。
  /// **同文件双开时先关掉的那个视图不能把另一个视图正在用的控制器 dispose 掉**，
  /// 所以这里按实例判断"还有没有引用"。
  void _releaseBuffer(EditorBuffer buffer) {
    for (final EditorBuffer other in _buffers.values) {
      if (identical(other, buffer)) return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => buffer.dispose());
  }

  /// 分屏：把当前文件再开一个视图（两侧共享**同一份**缓冲，见 [EditorBuffer]）
  void _splitViewer() {
    if (_split || _activeFile == null) return;
    setState(() {
      _split = true;
      _activePane = 1;
    });
  }

  /// 关掉分屏的第二个视图（回到单视图）；两侧是同一份缓冲，不用问未保存。
  void _unsplitViewer() {
    if (!_split) return;
    setState(() {
      _split = false;
      _activePane = 0;
    });
  }

  /// 关闭整个查看器：每个打开的**文件**都要先处理未保存的改动，任何一个取消就整体不关。
  ///
  /// 逐个来：非活动文件先切过去把它的查看器挂起来，[FileViewer.confirmLeave] 才有得问。
  Future<void> _closeViewer() async {
    while (_openFiles.isNotEmpty) {
      final String path = _openFiles.contains(_activeFile)
          ? _activeFile!
          : _openFiles.first;
      if (_activeFile != path) {
        setState(() => _activeFile = path);
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
      }
      if (!await _closeFile(path)) return;
    }
    final List<EditorBuffer> closing = _buffers.values.toList(growable: false);
    setState(() {
      _openFiles.clear();
      _buffers.clear();
      _fileKeys.clear();
      _activeFile = null;
      _split = false;
      _activePane = 0;
    });
    for (final EditorBuffer buffer in closing) {
      _releaseBuffer(buffer);
    }
  }

  /// 当前文件的查看器是否在分屏里（两侧共享同一份缓冲 ⇒ 提示用户）
  bool get _isDuplicateView => _split && _activeFile != null;

  /// 处理文件/文件夹下载（M8c/M8d）
  ///
  /// - 文件：选保存目录后**流式**写盘，任务交给 [DownloadCenter] 在左栏「下载」
  ///   里展示进度（后台进行，不阻塞界面）；
  /// - 文件夹：核心先打成 tar.gz 再交给系统保存对话框（受核心打包上限约束）。
  Future<void> _handleDownload(String path, bool isDirectory) async {
    if (isMobile) {
      _showSnackBar('移动端暂不支持保存到本地文件系统，请到桌面端下载');
      return;
    }
    final String name = path.isEmpty ? 'workspace' : path.split('/').last;
    if (isDirectory) {
      final DownloadTask task = DownloadCenter.instance.begin(
        kind: DownloadKind.folder,
        name: '$name.tar.gz',
        sourceTeam: widget.teamName,
        sourceTeamId: widget.teamId ?? '',
      );
      try {
        _showSnackBar('正在打包 $name ...');
        final Uint8List bytes = await ApiService.downloadFolder(
          widget.workspaceId,
          path,
          teamId: widget.teamId ?? '',
        );
        final Uri? savedUri = await FilePicker.saveFile(
          dialogTitle: '保存文件夹',
          fileName: '$name.tar.gz',
          bytes: bytes,
        );
        if (!mounted) return;
        if (savedUri == null) {
          DownloadCenter.instance.cancel(task);
          return;
        }
        DownloadCenter.instance.complete(
          task,
          localPath: _uriToPath(savedUri),
          totalBytes: bytes.length,
        );
        _showSnackBar('已保存：${_uriBaseName(savedUri)}');
      } on Exception catch (e) {
        final String msg = e.toString().replaceFirst('Exception: ', '');
        DownloadCenter.instance.fail(task, msg);
        _showSnackBar('下载失败：$msg');
      }
      return;
    }

    final String? dirPath = await FilePicker.getDirectoryPath(
      dialogTitle: '选择保存目录',
    );
    if (dirPath == null || dirPath.isEmpty) return;
    if (!mounted) return;
    final String savePath = '$dirPath${Platform.pathSeparator}$name';
    unawaited(
      DownloadCenter.instance.startFileDownload(
        workspaceId: widget.workspaceId,
        path: path,
        savePath: savePath,
        name: name,
        sourceTeam: widget.teamName,
        sourceTeamId: widget.teamId ?? '',
        teamId: widget.teamId ?? '',
      ),
    );
    _showSnackBar('已加入下载列表：$name');
  }

  /// file_picker 返回的 Uri → 本地路径（非 file 协议时给原样字符串）。
  static String _uriToPath(Uri uri) =>
      uri.scheme == 'file' ? uri.toFilePath() : uri.toString();

  static String _uriBaseName(Uri uri) {
    final String path = _uriToPath(uri);
    return path.split(Platform.pathSeparator).last;
  }

  /// 显示 SnackBar 提示
  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 本控件就是「文件」窗口的身体：只有一块文件区（文件树 + 多文件查看器）。
    // 顶层没有 Tab 栏——窗口 chip、关闭、折叠都在宿主 [RightPanelHost] 的顶栏里；
    // Git 历史 / Todo 已于 2026-10-19 移出本窗，各归独立窗口。
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: _buildFileSection(),
    );
  }

  /// 查看器上方那条：文件 tab 条 + 视图动作（不再有横贯面板的顶栏）。
  ///
  /// IDE 口径（用户 2026-11-10）：tab 属于**编辑器组**，只贴在查看器上方，
  /// 不横跨左侧目录树；工作空间动作挂到目录树头部，视图动作留在这里。
  ///
  /// 「目录」这颗键（用户 2026-10-04）：目录在左时一键收起、收起后一键叫回来；
  /// 面板窄到放不下并排两栏时，这里**如实写出原因**（而不是让用户对着一个看起来
  /// 没反应的按钮猜）。
  Widget _buildViewerTabBar(ColorScheme cs) {
    final bool twoPanes = _split;
    return SizedBox(
      height: 28,
      child: Row(
        children: <Widget>[
          Expanded(child: _buildFileTabStrip()),
          // 目录在左但**这一刻显示不出来**（面板太窄被 SplitPanes 降级）：如实说原因。
          if (_treeWanted && _treeAreaTooNarrow)
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text(
                  '面板太窄 · 目录已收起（拖宽右栏恢复）',
                  key: const ValueKey<String>('tree-too-narrow-hint'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ),
            ),
          // 视图动作：目录收放 / 分屏 / 关闭查看器。
          _toolbarAction(
            // 目录在左：收起 = 箭头朝左、显示 = 箭头朝右（`left_panel_*` 这套图标
            // 在当前的 Flutter 版本里不存在，别用）
            icon: _treeWanted
                ? Icons.keyboard_double_arrow_left
                : Icons.keyboard_double_arrow_right,
            tooltip: _treeWanted ? '收起文件树（查看器占满）' : '显示文件树（目录在左）',
            color: cs.onSurfaceVariant,
            onPressed: () {
              setState(() {
                _treeWanted = !_treeWanted;
              });
            },
          ),
          if (twoPanes)
            _toolbarAction(
              icon: _splitAxis == Axis.horizontal
                  ? Icons.splitscreen_outlined
                  : Icons.view_agenda_outlined,
              tooltip: _splitAxis == Axis.horizontal ? '切成上下分屏' : '切成左右分屏',
              color: cs.onSurfaceVariant,
              onPressed: () {
                setState(() {
                  _splitAxis = _splitAxis == Axis.horizontal
                      ? Axis.vertical
                      : Axis.horizontal;
                });
              },
            ),
          if (!twoPanes)
            _toolbarAction(
              icon: Icons.vertical_split_outlined,
              tooltip: '分屏：同一个文件再开一个窗格（两侧共享同一份缓冲）',
              color: cs.onSurfaceVariant,
              onPressed: _splitViewer,
            ),
          if (twoPanes)
            _toolbarAction(
              icon: Icons.close_fullscreen,
              tooltip: '关闭当前窗格',
              color: cs.onSurfaceVariant,
              onPressed: _unsplitViewer,
            ),
          _toolbarAction(
            icon: Icons.close,
            tooltip: '关闭查看器',
            color: cs.onSurfaceVariant,
            onPressed: () => unawaited(_closeViewer()),
          ),
        ],
      ),
    );
  }

  /// 工作空间动作挂到目录树头部（IDE 的「资源管理器 ···」位置），
  /// 不再单独占一条横贯面板的顶栏。
  List<Widget> _workspaceActions() {
    return <Widget>[
      // 固定 22×22：IconButton 的默认 tap target 会撑到 40+，把目录头撑高/撑宽。
      SizedBox(
        width: 22,
        height: 22,
        child: IconButton(
          tooltip: '重置系统提示词（备份 .bak.<n>）',
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.assignment_return_outlined, size: 16),
          onPressed: () => _resetWorkspace('system_prompt'),
        ),
      ),
      SizedBox(
        width: 22,
        height: 22,
        child: IconButton(
          tooltip: '重置 Spec（备份 .bak.<n>）',
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.rule_folder_outlined, size: 16),
          onPressed: () => _resetWorkspace('spec'),
        ),
      ),
      // 同步按钮自带菜单，压到与头部图标同高，别把目录头撑高。
      SizedBox(
        width: 22,
        height: 22,
        child: FileSyncButton(
          workspaceId: widget.workspaceId,
          teamId: widget.teamId ?? '',
          currentPath: _treePath,
          onUploaded: _refreshFileTree,
        ),
      ),
    ];
  }

  /// 面板太窄、目录**这一刻**显示不出来（[SplitPanes] 会把并排两栏降级成只显示查看器）。
  ///
  /// 判据与 [SplitPanes] 逐字对齐：可用宽度 = 面板宽度 − 分隔条宽度。
  bool get _treeAreaTooNarrow =>
      _lastTreeAreaWidth > 0 &&
      (_lastTreeAreaWidth - _paneDividerWidth) < _treeSplitDegradeBelow;

  /// 工具条上的紧凑图标键：默认 IconButton 是 48×48，五颗键在 240px 的面板里会溢出
  /// （黄条警告）；这里与文件树头部同一种口径（22×22、内边距 2）。
  Widget _toolbarAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color? color,
  }) => IconButton(
    icon: Icon(icon, size: 16),
    tooltip: tooltip,
    color: color,
    visualDensity: VisualDensity.compact,
    padding: const EdgeInsets.all(2),
    constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
    onPressed: onPressed,
  );

  /// 已打开文件的 tab 条：一个文件一个选项卡（点 = 切过去，× = 关掉）。
  ///
  /// 用户 2026-10-19：「支持多文件同时存在（目前仅支持单文件+二分屏）」——
  /// 这一排 tab 就是"同时开着"的可见形态（与 VS Code 同一套心智）；一个文档一份
  /// 缓冲，切 tab 不丢改动，只有**关闭 tab** 才问未保存。
  ///
  /// 这条只占**查看器那一格**的宽度（IDE 口径）；tab 装不下时底部常显滑块，
  /// 滚轮落在上面也能横向翻。
  Widget _buildFileTabStrip() {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Listener(
      // 桌面端滚轮是竖直的：落在 tab 条上时转成横向滚动。
      onPointerSignal: _onTabPointerSignal,
      child: Scrollbar(
        key: const ValueKey<String>('file-tab-scrollbar'),
        controller: _tabScroll,
        // tab 多到装不下时，底部常显滑块——否则用户不知道右边还有 tab。
        thumbVisibility: true,
        scrollbarOrientation: ScrollbarOrientation.bottom,
        thickness: 4,
        radius: Radius.circular(AppRadius.pill),
        child: SingleChildScrollView(
          controller: _tabScroll,
          scrollDirection: Axis.horizontal,
          child: Row(
            children: <Widget>[
              for (final String path in _openFiles)
                KeyedSubtree(
                  key: _tabKeyFor(path),
                  child: _buildFileTab(cs, path),
                ),
            ],
          ),
        ),
      ),
    );
  }

  GlobalKey _tabKeyFor(String path) => _tabKeys.putIfAbsent(
        path,
        () => GlobalKey(debugLabel: 'file_panel_tab_$path'),
      );

  /// 一个文件 tab：图标 + 文件名 + 未保存圆点 + 关闭；**右键**弹菜单——旧头部的
  /// 文件级动作（预览/源码、复制、下载、重新加载、关闭）都收在这里。
  ///
  /// 视觉**对标标准代码编辑器**（用户 2026-10-19）：扁平**矩形**（不再是圆角胶囊）、
  /// 活动 tab 顶部一条 2px 主色细条 + 用正文底色连成一片、非活动 tab 融进顶栏底色、
  /// 相邻 tab 之间一条竖直分隔线。整块铺满顶栏高度（32）。
  Widget _buildFileTab(ColorScheme cs, String path) {
    final bool active = path == _activeFile;
    final String name = path.isEmpty ? '未知文件' : path.split('/').last;
    final EditorBuffer buffer = _buffers[path]!; // tab 开着 ⇔ 缓冲一定在
    final Color divider = Theme.of(context).dividerColor;
    final Color editorBg = Theme.of(context).scaffoldBackgroundColor;
    return Material(
      color: active ? editorBg : Colors.transparent,
      child: InkWell(
        key: ValueKey<String>('file-tab-$path'),
        onTap: () => _activateFile(path),
        onSecondaryTapUp: (TapUpDetails details) =>
            unawaited(_showTabMenu(path, details.globalPosition)),
        child: Container(
          height: 28,
          decoration: BoxDecoration(
            border: Border(
              // 活动 tab 顶部那条主色细条（VS Code 口径：活动文档一眼可辨）
              top: BorderSide(
                color: active ? cs.primary : Colors.transparent,
                width: 2,
              ),
              // tab 之间的竖直分隔线：非活动 tab 画，活动 tab 不画（与内容连成一片）
              right: BorderSide(
                color: active ? Colors.transparent : divider,
                width: 1,
              ),
            ),
          ),
          padding: const EdgeInsets.only(left: 10, right: 2),
          // 缓冲一变（打字 / 保存）就重建 tab：未保存的圆点要实时亮 / 熄
          child: ListenableBuilder(
            listenable: buffer,
            builder: (BuildContext context, Widget? _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.description_outlined,
                  size: 13,
                  color: active ? cs.primary : cs.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: active ? cs.onSurface : cs.onSurfaceVariant,
                  ),
                ),
                // 未保存的改动：tab 上一颗小圆点（旧头部的状态行随头部一起去掉了）
                if (buffer.dirty) ...<Widget>[
                  const SizedBox(width: 3),
                  Icon(
                    Icons.fiber_manual_record,
                    size: 8,
                    color: cs.primary,
                  ),
                ],
                const SizedBox(width: 2),
                InkWell(
                  key: ValueKey<String>('file-tab-close-$path'),
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                  onTap: () => unawaited(_closeFile(path)),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Icon(
                      Icons.close,
                      size: 12,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 切到某个已打开的文件（不丢别的文件，也不必问未保存——缓冲还在）
  void _activateFile(String path) {
    if (_activeFile == path) return;
    setState(() {
      _activeFile = path;
      _activePane = 0;
    });
    _ensureTabVisible(path);
  }

  /// 把某个 tab 滚进视野（tab 多到超出面板宽度时，点树里的文件也能看到它）。
  void _ensureTabVisible(String path) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final BuildContext? context = _tabKeys[path]?.currentContext;
      if (context == null) return;
      // 直接跳到位：tab 切换是高频动作，不要额外动画抢注意力，
      // 也让"打开远处文件后 tab 立刻可见"在测试里可断言。
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: Duration.zero,
      );
    });
  }

  /// 鼠标滚轮落在 tab 条上：竖直增量转成横向滚动（与右栏 chip 行同口径）。
  void _onTabPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!_tabScroll.hasClients) return;
    final double delta =
        event.scrollDelta.dy != 0 ? event.scrollDelta.dy : event.scrollDelta.dx;
    if (delta == 0) return;
    final double next = (_tabScroll.offset + delta)
        .clamp(0.0, _tabScroll.position.maxScrollExtent);
    if (next == _tabScroll.offset) return;
    _tabScroll.jumpTo(next);
  }

  /// tab 右键菜单：旧头部退场后，文件级动作的入口（用户 2026-10-19：
  /// 「相应功能右键标签」）。
  ///
  /// 预览/源码、复制、重新加载、保存要落在**挂载着的查看器 state** 上，只对活动
  /// 文件给（非活动文件没挂载查看器）；下载与关闭对任何 tab 都可用。
  Future<void> _showTabMenu(String path, Offset position) async {
    final FileViewerState? state =
        path == _activeFile ? _activePaneState : null;
    final String? action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: <PopupMenuEntry<String>>[
        if (state != null && state.isDirty)
          const PopupMenuItem<String>(
            value: 'save',
            child: Text('保存（Ctrl+S）'),
          ),
        if (state != null && state.canTogglePreview)
          PopupMenuItem<String>(
            value: 'toggle',
            child: Text(state.showingPreview ? '切到源码' : '切到预览'),
          ),
        if (state != null && state.canCopyContent)
          const PopupMenuItem<String>(
            value: 'copy',
            child: Text('复制内容'),
          ),
        if (state != null && state.canReload)
          const PopupMenuItem<String>(
            value: 'reload',
            child: Text('重新加载（放弃未保存的改动）'),
          ),
        const PopupMenuItem<String>(
          value: 'download',
          child: Text('下载'),
        ),
        const PopupMenuItem<String>(
          value: 'close',
          child: Text('关闭'),
        ),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'save':
        unawaited(state!.saveIfDirty());
      case 'toggle':
        state!.togglePreview();
      case 'copy':
        unawaited(state!.copyContent());
      case 'reload':
        unawaited(state!.reloadFromDisk());
      case 'download':
        unawaited(_handleDownload(path, false));
      case 'close':
        unawaited(_closeFile(path));
    }
  }

  /// 窗格区：单视图铺满；分屏（同一个文件两个视图）交给 [SplitPanes]
  /// （方向 / 比例 / 太窄降级都在那里，可单测）
  Widget _buildPanes() {
    final String? path = _activeFile;
    if (path == null) return const SizedBox.shrink();
    if (!_split) return _buildPaneFor(path, _fileKeys[path], 0);
    final int active = _activePane.clamp(0, 1);
    return SplitPanes(
      axis: _splitAxis,
      ratio: _splitRatio,
      dividerWidth: _paneDividerWidth,
      onRatioChanged: (double next) {
        setState(() {
          _splitRatio = next;
        });
      },
      first: _buildPaneFor(path, _splitKeys[0], 0),
      second: _buildPaneFor(path, _splitKeys[1], 1),
      degraded: _buildPaneFor(path, _splitKeys[active], active),
    );
  }

  /// 单个窗格：点它成为活动窗格；分屏时两侧共享同一份缓冲（只提示，不锁只读）
  Widget _buildPaneFor(
    String path,
    GlobalKey<FileViewerState>? key,
    int index,
  ) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool active = index == _activePane;
    final Widget viewer = FileViewer(
      key: key,
      workspaceId: widget.workspaceId,
      teamId: widget.teamId,
      teamName: widget.teamName,
      filePath: path,
      // 同一个文件的另一个视图共用这一份缓冲：就地编辑即同步（见 EditorBuffer）
      buffer: _buffers[path],
      paneNotice: _isDuplicateView ? _sharedBufferNotice : '',
    );
    if (!_split) return viewer;
    return Stack(
      children: <Widget>[
        Listener(
          onPointerDown: (_) {
            if (_activePane != index) {
              setState(() {
                _activePane = index;
              });
            }
          },
          child: viewer,
        ),
        // 活动窗格的描边：一眼看出保存键与文件树点击会落到哪个窗格
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: active
                      ? cs.primary.withValues(alpha: 0.7)
                      : Colors.transparent,
                  width: 1,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 文件分区：顶部**单行**（tab 条 / 标题 + 各类动作）+ 内容
  ///
  /// 内容区两种形态：没打开文件 = 文件树独占；打开文件 = 左右分栏（目录在左、查看器在右）。
  Widget _buildFileSection() {
    // IDE 口径（用户 2026-11-10）：tab 只贴在查看器上方，目录树保留自己的头部；
    // 不再有横跨整块面板的 tab / 工具条。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _lastTreeAreaWidth = constraints.maxWidth;
        if (!_viewerOpen) return _buildFileTree();
        final Widget viewer = _buildViewerArea();
        if (!_treeWanted) return viewer;
        // 为什么左右而不是上下（2026-10-04）：上下分栏把查看器压扁（代码按行看，
        // 高度比宽度更吃紧）；目录当左侧栏也更接近 VS Code。
        // 面板太窄（< [_treeSplitDegradeBelow]）时按 [SplitPanes] 的既有口径降级成
        // **只显示查看器**——查看器 tab 条上写着原因，拖宽右栏目录自己回来。
        return SplitPanes(
          axis: Axis.horizontal,
          ratio: _treeSplitRatio,
          minExtent: _treeSplitMinExtent,
          degradeBelow: _treeSplitDegradeBelow,
          dividerWidth: _paneDividerWidth,
          onRatioChanged: (double next) {
            setState(() {
              _treeSplitRatio = next;
            });
          },
          first: _buildFileTree(),
          second: viewer,
          degraded: viewer,
        );
      },
    );
  }

  /// 查看器一格：tab 条 + 分隔线 + 窗格。
  Widget _buildViewerArea() {
    return Column(
      children: <Widget>[
        _buildViewerTabBar(Theme.of(context).colorScheme),
        Divider(height: 1, thickness: 1, color: Theme.of(context).dividerColor),
        Expanded(child: _buildPanes()),
      ],
    );
  }

  /// 文件树那一格（原先文件子 Tab 的第一页）。
  ///
  /// 外面套 [KeyedSubtree] + [_fileTabsKey]：开 / 关查看器时这块会被搬进 / 搬出分栏，
  /// 有 key 才不会被重建（展开状态、选中项、已加载的目录都留着）。
  Widget _buildFileTree() {
    return KeyedSubtree(
      key: _fileTabsKey,
      child: FileTree(
        workspaceId: widget.workspaceId,
        teamId: widget.teamId,
        trailingActions: _workspaceActions(),
        refreshTrigger: _fileRefreshTrigger + widget.fileRefreshTrigger,
        onDownload: _handleDownload,
        onPathChanged: (String path) {
          if (path == _treePath) return;
          setState(() {
            _treePath = path;
          });
        },
        onFileSelected: _openFile,
        // 改名 / 删除之后查看器要跟着走（见 _onTreePathRenamed / _onTreePathDeleted）
        onPathRenamed: _onTreePathRenamed,
        onPathDeleted: _onTreePathDeleted,
      ),
    );
  }
}
