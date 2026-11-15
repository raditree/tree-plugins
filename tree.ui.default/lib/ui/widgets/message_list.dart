import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../app_radius.dart';
import '../app_theme.dart';
import '../models/message.dart';
import '../services/message_window.dart';
import 'collapsed_run_row.dart';
import 'hook_notice_card.dart';
import 'message_scrollbar.dart';
import 'thinking_card.dart';
import 'tool_call_card.dart';
import 'welcome_mark.dart';

/// 消息列表组件（StatelessWidget）
///
/// 渲染中栏消息列表。用户消息右对齐（中性气泡 + 1px 中性边框），agent 消息左对齐
/// （中性高亮块：左侧 3px 竖条、无底色）。流式消息在内容末尾显示闪烁光标。
///
/// **槽位表**（用户 2026-10-04：「滑到哪加载哪，限制缓存长度，仅缓存窗口附近的消息」）：
/// [slots] 按**全局下标**寻址（0 = 最旧那条），元素为 null 表示这一段还没取回来——
/// 画成等高占位槽。于是：
///
/// - 槽位表长度**只随新消息增长**，加载/淘汰都不改变它 ⇒ 右侧滑块
///   （[MessageScrollbar]，按全局下标算几何）上滑补页时不会跳来跳去；
/// - 列表把**本帧真正显示在视口里的下标区间**帧后报给面板（[onWindowChanged]），
///   面板据此只补那一段、并淘汰离得远的槽位（限制缓存长度）；
/// - 「回到底部」= 请面板**重载末尾一段**（[onReloadTail]），不再在几千条估算高度里
///   做一次动画——落点确定，必然到底。
class MessageList extends StatelessWidget {
  /// 槽位表：全局下标 → 消息（null = 还没加载）。
  ///
  /// 面板持有同一个列表并**原地**放置/淘汰（见 MessageWindow），靠 [revision]
  /// 触发重建。
  final List<ChatMessage?> slots;

  /// 哪些消息**进主消息流**（null = 全部可见）。
  ///
  /// 临时员工的消息不进主消息流（它们在中栏只出现在"那次 subagent 工具调用的详情"里）：
  /// 面板传 (m) => !m.isSubagentMessage。这类槽位渲染成**零高度**（不占版面、也不
  /// 打断下标连续性）。
  final bool Function(ChatMessage message)? visible;

  /// 消息版本号：每次槽位表发生结构性变化（放置/追加/淘汰/清空）时递增，
  /// 用于触发重建与滚动跟随。由于 [slots] 是同一个可变列表引用，
  /// 无法通过长度/引用比较检测变化，故使用版本号信号。
  final int revision;

  /// 内联提问卡片的选择回调（参数为消息 id 与**逐题答案**；多问题时一次交齐）
  final void Function(String messageId, List<String> answers)? onAskAnswer;

  /// 定位目标消息 id：非空且 [scrollToRevision] 变化时滚动定位到该消息
  final String? scrollToMessageId;

  /// 定位触发号：外部递增触发滚动定位（与 [scrollToMessageId] 配合）
  final int scrollToRevision;

  /// 本次 revision 变化是否以「无动画直达底部」方式响应。
  ///
  /// 历史重载/重载末尾一段（切会话/切 agent/清空重拉/回到底部）传 true：
  /// 恢复跟随并直达底部。流式追加/增量更新传 false。
  final bool bottomJump;

  /// **在视口上方补了页**（递增的标记）：布局阶段按内容高度差补偿一次滚动位置，
  /// 免得"上面那一段由占位变实体"把正在看的内容推走。
  final int padAboveStamp;

  /// **本帧内容高度在"别处"变了**（递增的标记）：补页落在视口里/视口下方
  /// （横跨视口顶的那一份），或者淘汰掉了远处的槽位（真消息 → 88px 占位槽）。
  ///
  /// 为什么单独一个信号：这类变化**不是**"整段都在视口上方"（那走 [padAboveStamp]），
  /// 但也一样会让用户正在读的那一段整段下移/上移。列表侧用**实测锚点**
  /// （视口顶那条真消息的底边，见 [_MessageListViewState._resolveShiftAbove]）
  /// 把它补回来 —— 补的量在两个信号下是同一套口径，分开只是为了面板能表达
  /// "这一帧变的是哪一类"，也让测试能分别钉住（回归用例 N5/N6/N7）。
  final int contentShiftStamp;

  /// 本帧**真正显示在视口里**的下标区间（帧后回调；面板据此补页 + 淘汰）。
  ///
  /// 口径见 [_MessageListViewState._visibleRangeFromRenderTree]：不含缓存区、不含
  /// 折叠组里零高度的组员——否则长工具组折叠/展开时区间会成百格地跳。
  final void Function(int first, int last)? onWindowChanged;

  /// 展开中的折叠组的**槽位区间**（`[组首, 组尾+1)`；null = 没有展开组）。
  ///
  /// 面板据此在淘汰时**整段钉住**这一组：展开组一旦被窗口打洞（真消息 → 88px 占位槽），
  /// 分组边界就变了 —— 组首一换，展开态判定就对不上，整组瞬间塌回一行，
  /// 视口跟着跳一大截（长组滚到一半时最明显）。
  ///
  /// 回调可能在本帧布局**之前**同步发出（组边界是渲染层现算的），接收方只许
  /// 记字段、不许 setState。
  final ValueChanged<MessageRange?>? onExpandedRunChanged;

  /// 「回到底部」：请面板重载末尾一段（空 = 退回旧的平滑回底行为）。
  final VoidCallback? onReloadTail;

  /// 消息流末尾追加的**插件内联卡片**（Q12）：按到达顺序排在最后一条消息之后。
  final List<Widget> trailingCards;

  /// 这一份会话的历史**正在路上**（切 agent / 首载 / 切会话）。
  ///
  /// 期间槽位表必然还是空的，但**不许**把它当成"真的没有消息"——空态（欢迎页）只在
  /// "确实加载完且真的没有消息"时出现（用户 2026-10-03 症状 1：切 agent 先闪一下
  /// 空窗口再载入历史）。加载中改渲染静态骨架（见 [_MessageListViewState.build]）。
  final bool loading;

  const MessageList({
    super.key,
    required this.slots,
    this.visible,
    this.revision = 0,
    this.onAskAnswer,
    this.scrollToMessageId,
    this.scrollToRevision = 0,
    this.bottomJump = false,
    this.padAboveStamp = 0,
    this.contentShiftStamp = 0,
    this.onWindowChanged,
    this.onExpandedRunChanged,
    this.onReloadTail,
    this.trailingCards = const <Widget>[],
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return _MessageListView(
      slots: slots,
      visible: visible,
      revision: revision,
      onAskAnswer: onAskAnswer,
      scrollToMessageId: scrollToMessageId,
      scrollToRevision: scrollToRevision,
      bottomJump: bottomJump,
      padAboveStamp: padAboveStamp,
      contentShiftStamp: contentShiftStamp,
      onWindowChanged: onWindowChanged,
      onExpandedRunChanged: onExpandedRunChanged,
      onReloadTail: onReloadTail,
      trailingCards: trailingCards,
      loading: loading,
    );
  }
}

/// 内部带滚动控制的状态视图
class _MessageListView extends StatefulWidget {
  final List<ChatMessage?> slots;
  final bool Function(ChatMessage message)? visible;
  final int revision;
  final void Function(String messageId, List<String> answers)? onAskAnswer;
  final String? scrollToMessageId;
  final int scrollToRevision;
  final bool bottomJump;
  final int padAboveStamp;
  final int contentShiftStamp;
  final void Function(int first, int last)? onWindowChanged;
  final ValueChanged<MessageRange?>? onExpandedRunChanged;
  final VoidCallback? onReloadTail;
  final List<Widget> trailingCards;
  final bool loading;

  const _MessageListView({
    required this.slots,
    this.visible,
    this.revision = 0,
    this.onAskAnswer,
    this.scrollToMessageId,
    this.scrollToRevision = 0,
    this.bottomJump = false,
    this.padAboveStamp = 0,
    this.contentShiftStamp = 0,
    this.onWindowChanged,
    this.onExpandedRunChanged,
    this.onReloadTail,
    this.trailingCards = const <Widget>[],
    this.loading = false,
  });

  @override
  State<_MessageListView> createState() => _MessageListViewState();
}

/// 占位槽的高度（px）。**固定值**：滑块的下标换算、以及"拖到某个下标"的落点估算
/// 都建立在"没加载的那一段每格一样高"这个前提上（见 [MessageScrollbar]）。
const double kMessagePlaceholderExtent = 88;

/// 「刚补了页」时的**布局前快照**：视口顶 + 已布局子项的顶边（下标 → 内容坐标）。
///
/// 与布局后再扫一遍配成对，用来量**实测**位移（见
/// [_MessageListViewState._resolveShiftAbove]）。
class _BuiltTopsSnapshot {
  const _BuiltTopsSnapshot({required this.viewportTop, required this.tops});

  /// 布局前的视口顶（sliver 自己的坐标系；已扣掉列表内边距）
  final double viewportTop;

  /// 布局前：这一趟真被布局过的子项 → 顶边
  final Map<int, double> tops;
}

/// 一个折叠组（run）的渲染期信息（规格 §3.2.1/§3.2.2，纯渲染层现算）。
class _RunInfo {
  const _RunInfo({
    required this.head,
    required this.tail,
    required this.runId,
    required this.collapsed,
    required this.toolCount,
    required this.thinkingCount,
    required this.toolCountsByLabel,
  });

  /// 组首/组尾下标（含）
  final int head;
  final int tail;

  /// 组标识 = 组首条消息 id（展开态记它；全局同时只展开一个）
  final String runId;

  /// 是否处于折叠态（「有就折叠」：默认折叠，只有 [_MessageListViewState._expandedAnchorId]
  /// 命中的那一组展开）
  final bool collapsed;

  /// 组内已完成工具条数 / 思考段条数 / 按 `toolLabel` 分类的工具计数
  final int toolCount;
  final int thinkingCount;
  final Map<String, int> toolCountsByLabel;
}

/// 底部锚定滚动控制器：把「钉在底部」做成**布局同帧**的同步操作。
///
/// 列表为常规（非反转）布局：offset 0 在顶部，maxScrollExtent 即底部。
/// - 跟随模式：内容变化时在布局阶段把 offset 同步钉到 maxScrollExtent
///   （早于绘制，无「先位移一帧再拉回」的逐帧闪烁抖动）。
/// - 阅读模式：**不做任何校正**。常规布局下在末尾追加/增长内容不会移动
///   已渲染内容的坐标，视口天然稳定，因此零漂移（无需任何 offset 补偿）——
///   唯一的例外是"视口**上方**补页"（占位槽换成真消息，高度变了），
///   由 [shiftAbove] 标记在布局阶段补偿（见 [padAboveStamp]）。
class _BottomAnchorScrollController extends ScrollController {
  _BottomAnchorScrollController({required this.shouldFollow});

  /// 是否处于跟随模式（需要钉底）
  final bool Function() shouldFollow;

  /// 是否需要把 offset 钉到底部：内容变化/首帧时由 State 置位，布局时消费。
  bool pinToBottom = false;

  /// **首帧即底部**（切 agent / 切会话 / 历史重载 / 回到底部 / 首次进入）。
  ///
  /// 与 [pinToBottom] 的分工：那个是"跟随模式"下每次内容变化都粘底的**持续**请求
  /// （消费一次之后靠"本来就贴底"继续跟）；这个是"新一份窗口内容落地"的**一次性**
  /// 要求，而且必须在这**同一次布局**里校到收敛——[applyContentDimensions] 返回
  /// false 会让 RenderViewport 在同帧内重跑布局，**绘制发生在收敛之后**，于是不会
  /// 出现"先按顶部渲染一帧、下一帧再跳到底"（用户 2026-10-03 症状 2）。
  bool firstFrameBottom = false;

  /// [firstFrameBottom] 上一轮校到的"底"（-1 = 这一轮还没校过）。
  /// 相邻两轮目标一致 ⇒ 已经收敛，收工（避免和 RenderViewport 的布局循环打架）。
  double firstFrameBottomTarget = -1;

  /// 视口**上方/视口里**刚补了页：布局阶段按**实测**高度差把 offset 挪同样多。
  bool shiftAbove = false;

  /// [shiftAbove] 的**实测解析器**：返回"用户正在读的那一段**实际**被顶下去了多少"
  /// （null = 实测拿不到 → 退回估算 + 限幅）。
  ///
  /// 为什么不能用 `maxScrollExtent` 的帧间差：长列表里它是**外推值**，
  /// 误差 ∝ 剩余条数（详见 [_BottomAnchorScrollPosition.applyContentDimensions]）。
  /// 由 [_MessageListViewState] 注入——它拿着列表的 [GlobalKey]，可以在布局前后
  /// 各读一遍渲染树（只有它知道"用户当时在看哪一条"）。
  double? Function()? resolveShiftAbove;

  /// 从渲染树读「某个子项**此刻**的顶边」（内容坐标；拿不到 = null）。
  /// 由 [_MessageListViewState] 注入（它拿着列表的 [GlobalKey]）。
  double? Function(int index)? readChildTop;

  /// 布防（[shiftAbove]）那一刻的滚动位置：补偿的**绝对目标**以它为基准。
  ///
  /// 为什么不能用"当前 pixels + 位移量"：布局期间 `RenderViewport` 自己也会做
  /// `scrollOffsetCorrection`（`ViewportOffset.correctBy` 直接改 `_pixels`，**不**走
  /// `correctPixels` 也不发通知）。这时再叠加一次同样的位移就补了两遍
  /// （实测：视口顶那一行本来该位移 120px，结果位移 -56px）。
  /// 绝对目标 = 布防时的 pixels + 用户此后的滚动量 + 锚点位移，与框架补了几次无关。
  double? shiftBasePixels;

  /// 自布防以来**用户/程序**滚动过的量（[ScrollPosition.didUpdateScrollPositionBy] 累计；
  /// 框架自己的 `correctBy` 不走这条路，正是我们要区分开的）。
  double scrollSinceArm = 0;

  /// 最近一次**用户/程序**滚动方向（-1 上 / +1 下 / 0 还不知道）。
  ///
  /// 只认 `didUpdateScrollPositionBy`（真滚动）：补页补偿、框架的 `correctBy`
  /// 也会改 `pixels`，按"像素差"判方向会把一次补页当成用户往下滚。
  int userScrollDirection = 0;

  /// 上一帧内容的总高度（-1 = 还不知道）。用来判断"刚才是不是贴着底"，
  /// 并作为补页补偿的**兜底**估算值（实测拿不到时才用，且有限幅）。
  double lastMaxExtent = -1;

  /// 这一次补偿在**布局阶段没量出来**（[resolveShiftAbove] 返回 null）：
  /// 请求帧后重试一次（渲染树这时已经稳定，锚点通常已经在布局范围里）。
  bool retryShiftRequested = false;

  /// 这一帧算出来的**绝对目标**：帧后再核一次（null = 没有要核的）。
  ///
  /// 为什么还要核：`correctPixels` 之后我们返回 false 让 RenderViewport 同帧重跑布局，
  /// 那一趟里框架**还会**按它自己的 `scrollOffsetCorrection` 再挪一次（`correctBy`
  /// 是增量、直接改 `_pixels`），于是最终位置可能偏离我们算好的目标几十像素
  /// （实测：目标 341，最终落在 294，视口顶那一行位移差 205px）。帧后位置已定，
  /// 再对一次绝对目标即可（不动就一直不动，不存在来回抢）。
  double? assertPixels;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _BottomAnchorScrollPosition(
      physics: physics,
      context: context,
      oldPosition: oldPosition,
      controller: this,
    );
  }
}

/// 见 [_BottomAnchorScrollController]：在布局阶段同步钉底 / 补偿上方补页。
class _BottomAnchorScrollPosition extends ScrollPositionWithSingleContext {
  _BottomAnchorScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    required this.controller,
  });

  final _BottomAnchorScrollController controller;

  /// 用户/程序发起的滚动量（`setPixels` / `jumpTo` 都会报；框架自己的
  /// `correctBy` 不报——补偿的绝对目标要把这两者分开，见 [shiftBasePixels]）。
  @override
  void didUpdateScrollPositionBy(double delta) {
    if (delta.abs() > 0.5) {
      controller.userScrollDirection = delta > 0 ? 1 : -1;
    }
    if (controller.shiftBasePixels != null) controller.scrollSinceArm += delta;
    super.didUpdateScrollPositionBy(delta);
  }

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final bool ok =
        super.applyContentDimensions(minScrollExtent, maxScrollExtent);
    final bool following = controller.shouldFollow();
    final bool requested = controller.pinToBottom;
    // ① **首帧即底部**：新一份窗口内容落地的那一帧就落在底部（静默校正，走同一套
    //    `correctPixels` 通路；**不**动下面那套"实测锚点补偿"的口径）。
    //    只认跟随模式：用户在读历史时不抢他的位置。
    if (controller.firstFrameBottom) {
      if (!following) {
        controller.firstFrameBottom = false;
        controller.firstFrameBottomTarget = -1;
      } else {
        final double target =
            maxScrollExtent.clamp(minScrollExtent, maxScrollExtent);
        final bool settled = controller.firstFrameBottomTarget >= 0 &&
            (target - controller.firstFrameBottomTarget).abs() <= 0.5;
        if (settled) {
          // 连着两轮的"底"一样：估算已经稳定（懒构建把真实高度补完了）⇒ 收工
          controller.firstFrameBottom = false;
          controller.firstFrameBottomTarget = -1;
        } else {
          controller.firstFrameBottomTarget = target;
          if ((pixels - target).abs() > 0.01) {
            correctPixels(target);
            // 同帧重跑布局（绘制在收敛之后 ⇒ 没有"先在顶部再跳"的中间帧）
            return false;
          }
        }
      }
    }
    // **粘底**：请求贴底（首帧 / 历史重载 / 追加），或者上一帧我们本来就贴着底。
    //
    // 为什么"本来就贴着底"也算一次：列表的滚动范围是**估算**的，随着视口周围
    // 构建出真实内容，maxScrollExtent 还会再长——只认一次性的请求就会停在半路。
    // 用户一旦上滚，pixels 立刻离开 max，这里就不再校正。
    final bool glued =
        controller.lastMaxExtent >= 0 &&
        (pixels - controller.lastMaxExtent).abs() <= 1.0;
    // 刚补过页：**标记一定要消费掉**（跟随模式下由贴底接管，不能留到以后
    // 阅读模式下突然生效）；只有"不在跟随"时才需要自己补偿。
    final bool shiftAbove = controller.shiftAbove;
    controller.shiftAbove = false;
    final double? Function()? resolveShift = controller.resolveShiftAbove;
    controller.resolveShiftAbove = null;
    if (!shiftAbove) {
      // 没布防（或已被贴底接管）：基准作废
      controller.shiftBasePixels = null;
      controller.scrollSinceArm = 0;
    }
    // 兜底口径：上一帧"内容总高"的差。**只在实测拿不到时用**，而且要限幅——
    // 长列表里它是外推值（见下面 shiftAbove 分支的注释）。
    final double estimatedDelta = controller.lastMaxExtent >= 0
        ? maxScrollExtent - controller.lastMaxExtent
        : 0;
    controller.lastMaxExtent = maxScrollExtent;
    if (shiftAbove && !following) {
      // 补页会让内容高度变（占位槽 88px ↔ 真消息），把 offset 加同样多，
      // 正在看的那一段就还在原地。返回 false 请求同帧重跑布局（绘制前就已补偿，不闪）。
      //
      // **补偿量取"实测位移"，不能取 maxScrollExtent 的差**：
      // 列表是懒构建的、没到底时 `maxScrollExtent` 是**外推值**
      // （SDK `RenderSliverList.estimateMaxScrollOffset` =
      // `末尾已布局偏移 + 已建子项平均高 × 剩余条数`），误差 **∝ 剩余条数**：
      // 真机会话几千条、视口在中段 ⇒ 单帧可差上千像素，而"真正长高的高度"
      // 最多几百像素（只有 cache extent 内那几行会被布局）⇒ 补偿量被噪声主导，
      // 视口被随机搬走（用户 2026-10-03：「触发一次懒加载后抖动非常厉害」）。
      //
      // 实测口径见 [_MessageListViewState._resolveShiftAbove]：
      // 锚点 = "用户**当时**正在看的第一条内容"（跳过这一帧刚换过高度的格子），
      // 补偿量 = 锚点**底边**的实测位移（`layoutOffset` 是实测子项高度逐个累加的真值）。
      //
      // **目标是绝对值**（不是 `pixels + 位移`）：布防之后框架自己可能已经做过一次
      // `scrollOffsetCorrection`，叠加就会补两遍（见 [shiftBasePixels]）。
      final double? resolved = resolveShift?.call();
      final double? base = controller.shiftBasePixels;
      final double sinceArm = controller.scrollSinceArm;
      double? target;
      if (resolved != null) {
        target = (base ?? pixels) + sinceArm + resolved;
      } else if (estimatedDelta.abs() <= viewportDimension * 2) {
        // 实测拿不到（还没布局过 / 锚点不在这一趟布局里）：退回估算值，
        // 且**只在不超过两屏时采信**——宁可不补，也不要错补上千像素。
        target = pixels + estimatedDelta;
      } else if (resolveShift != null) {
        // 实测彻底拿不到（这一趟布局里没有"高度没变"的锚点）：请求帧后重试一次。
        // 帧后渲染树已经稳定，锚点通常已经在布局范围里；补完再画下一帧，
        // 比"这一帧整个不补、视口被推走几百像素"好得多。
        controller.retryShiftRequested = true;
      }
      if (target == null) return ok;
      if ((target - pixels).abs() <= 0.01) {
        // 已经在对的位置：清掉基准（这一趟不需要再补）
        controller.shiftBasePixels = null;
        controller.scrollSinceArm = 0;
        return ok;
      }
      correctPixels(target.clamp(minScrollExtent, maxScrollExtent));
      controller.assertPixels = target;
      controller.shiftBasePixels = null;
      controller.scrollSinceArm = 0;

      return false;
    }
    if (!ok || !following) return ok;
    if (!requested && !glued) return ok;
    controller.pinToBottom = false; // 消费一次
    if ((pixels - maxScrollExtent).abs() > 0.01) {
      correctPixels(maxScrollExtent.clamp(minScrollExtent, maxScrollExtent));
      // 返回 false 请求 RenderViewport 用校正后的 offset 同帧重跑布局：
      // 绘制前即已贴底（下一次迭代残差归零 → 返回 true 收敛）。
      return false;
    }
    return ok;
  }
}

class _MessageListViewState extends State<_MessageListView> {
  /// 底部锚定滚动控制器（见 [_BottomAnchorScrollController]）
  late final _BottomAnchorScrollController _controller;

  /// 模式开关（唯一的滚动行为状态）：
  /// - false = 跟随模式：始终钉在底部，随新内容一起移动；
  /// - true = 阅读模式：用户主动上滚查看历史，视口锁定、不随新内容移动。
  ///
  /// 进入阅读：任意一次离开底部的滚动；恢复跟随：**完全压到底部**才切换。
  bool _userDetached = false;

  /// 「回到底部」动画进行中：期间的中间位置不算用户上滚。
  bool _returningToBottom = false;

  /// 贴底判定阈值（px）：与底部距离不超过该值即视为「完全压到底部」。
  static const double _bottomEpsilon = 1.0;

  /// 消息 id → GlobalKey（定位目标可寻址）
  final Map<String, GlobalKey> _itemKeys = <String, GlobalKey>{};

  /// 当前高亮定位的消息 id
  String? _highlightedId;

  /// 高亮清除定时器
  Timer? _highlightTimer;

  /// 定位重试次数（防止目标未构建时无限重试）
  int _scrollRetries = 0;

  /// **本帧构建到的下标区间**（-1 = 本帧还没构建任何槽位）。
  ///
  /// 只是**兜底**口径：权威口径是渲染树里 SliverList 实际持有的子项区间
  /// （见 [_builtRangeFromRenderTree]）——滚动时只有"新进视口的"子项会被重建，
  /// itemBuilder 收集不到整段可见区间。
  int _builtFirst = -1;
  int _builtLast = -1;

  /// 视口在整份历史里的坐标（帧后刷新）。
  ///
  /// **拇指直接监听它**：滚动时只重绘拇指，不重建列表（"鼠标滚动丝滑"的关键）；
  /// 面板的补页 / 淘汰也以它为准（见 [MessageList.onWindowChanged]）。
  final ValueNotifier<MessageWindowCoordinate> _coordinate =
      ValueNotifier<MessageWindowCoordinate>(MessageWindowCoordinate.unknown);

  /// 这一帧已经安排过帧后刷新（同帧去重）。
  bool _flushScheduled = false;

  /// 正在做"我们自己发起的跳转"（滚动通知里据此区分用户滚动，见 [_handleScrollNotification]）。
  bool _programmaticJump = false;

  /// 正在做的落点校正（null = 没有）。用户一动就丢掉，绝不和用户抢。
  MessageSeekCorrection? _seekCorrection;

  /// 列表自己的 key：从渲染树读"权威构建区间"要用它（见 [_builtRangeFromRenderTree]）。
  final GlobalKey _listKey = GlobalKey(debugLabel: 'message-list');

  /// `_itemKeys` 的上限：超了就按"还在槽位表里"清一次（长会话里它只增不减会漏）。
  static const int _itemKeysLimit = 2000;

  /// 直达底部的"收尾"帧数上限（见 [_jumpToBottomSettling]）。
  static const int _pinSettleLimit = 120;
  int _pinSettleFrames = 0;
  double _lastMaxExtent = -1;

  /// 程序化的"直达底部"进行中：期间不把滚动通知当成用户上滚。
  bool _jumpingToBottom = false;

  /// 当前展开的折叠组（锚点 = 展开时组首那条消息）。
  ///
  /// 全局同时只允许一个展开组（规格 Q5）：点开新组时旧组自动收起。展开态是
  /// O(1) 的单个 id + 下标，渲染负担上限 = 一个 run + 视口。
  ///
  /// 判定"这一段是不是展开组"用**锚点下标是否落在 [head, tail] 内**，而不是
  /// "组首 id 相等"：补页可能在组首之前接进更多工具/思考（组首换人），按 id 判
  /// 会把用户正看着的展开组当场判成折叠，视口跳一大截。
  String? _expandedAnchorId;

  /// 展开锚点的槽位下标（-1 = 没有展开组）。
  int _expandedAnchor = -1;

  /// 上一次报给面板的展开组区间（去重用；组边界沿锚点现算，不缓存组首）。
  MessageRange? _reportedExpandedRun;

  /// 把"展开中的折叠组的槽位区间"报给面板（面板据此在淘汰时整段钉住）。
  ///
  /// 为什么不钉：长组里只要有一格被淘汰回 88px 占位槽，组就被切成两段——
  /// 后一段的组首换了 id，展开态判定（[_RunInfo.collapsed]）就对不上，
  /// 整组塌回一行，视口瞬跳。
  void _publishExpandedRun() {
    final String? id = _expandedAnchorId;
    MessageRange? range;
    if (id != null) {
      final List<ChatMessage?> slots = widget.slots;
      int anchor = _expandedAnchor;
      if (anchor < 0 || anchor >= slots.length || slots[anchor]?.id != id) {
        // 只在这种"缓存失效"的稀有路径上扫一次（锚点一般稳定：面板已钉住它）
        anchor = slots.indexWhere((ChatMessage? m) => m?.id == id);
      }
      if (anchor < 0) {
        // 锚点已经不在了（窗口整表换过内容）：展开态没有落点，按"没有展开组"上报
        _expandedAnchorId = null;
        _expandedAnchor = -1;
      } else {
        _expandedAnchor = anchor;
        int from = anchor;
        while (_groupableAt(from - 1)) {
          from--;
        }
        int to = anchor;
        while (_groupableAt(to + 1)) {
          to++;
        }
        range = MessageRange(from, to + 1);
      }
    } else {
      _expandedAnchor = -1;
    }
    if (range == _reportedExpandedRun) return;
    _reportedExpandedRun = range;
    widget.onExpandedRunChanged?.call(range);
  }

  @override
  void initState() {
    super.initState();
    _controller = _BottomAnchorScrollController(
      shouldFollow: () => !_userDetached,
    );
    // 首帧即把视口钉到底部（最新消息），避免「顶部闪一下再落底」。
    //
    // **首帧也要"连续几帧贴底"**：导入长会话走的就是这条路径（不是 didUpdateWidget），
    // 懒构建列表首帧的 maxScrollExtent 只是估算值——只贴一帧就会停在半路。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _jumpToBottomSettling();
    });
    _controller.pinToBottom = true;
    // 首帧即底部：首屏（挂载时就带着槽位表）也走同一条"同帧校到收敛"的路，
    // 于是第一个被绘制的帧就已经在底部。
    _controller.firstFrameBottom = true;
    _controller.firstFrameBottomTarget = -1;
  }

  @override
  void didUpdateWidget(covariant _MessageListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 面板补了页：占位槽换成真消息会改变内容高度，布局阶段补回来。
    // - [padAboveStamp]：整段都在视口上方的那一份；
    // - [contentShiftStamp]：横跨视口顶 / 落在视口里的那一份（视口顶那条真消息**以下**
    //   那一段必须由它来保住）。
    // 补偿量必须在本帧布局**之前**量（此刻渲染树里是上一帧的 layoutOffset）——
    // 见 [_snapshotShiftAnchor] 与 [_BottomAnchorScrollPosition]。
    if (oldWidget.padAboveStamp != widget.padAboveStamp ||
        oldWidget.contentShiftStamp != widget.contentShiftStamp) {
      _beginShiftCompensation();
    }
    if (oldWidget.revision != widget.revision) {
      // 槽位表变了：刷新一次视口坐标（面板可能还要按它补页 / 淘汰）
      _scheduleCoordinateFlush();
      _pruneItemKeys();
      // 展开组可能因为补页接进了更多成员 ⇒ 区间要跟着往两边长，
      // 面板才能在**这一帧之后**的淘汰里把整段钉住（必须早于淘汰发生）。
      _publishExpandedRun();
      if (widget.bottomJump) {
        // 重载（切会话 / 切 agent / 回到底部 / 清空重拉）：恢复跟随并直达底部
        _jumpToBottomSettling();
      } else if (!_userDetached) {
        // 跟随模式：本帧布局阶段同步钉底
        _schedulePin();
      }
      // 阅读模式：不做任何校正——常规布局下末尾新增/增长内容不会移动
      // 已渲染内容，视口天然稳定（零漂移）。
    } else if (!_userDetached) {
      _schedulePin();
    }
    // 定位触发：scrollToRevision 变化且存在目标消息 id
    if (oldWidget.scrollToRevision != widget.scrollToRevision &&
        widget.scrollToMessageId != null &&
        widget.scrollToMessageId!.isNotEmpty) {
      _scrollRetries = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToMessage(widget.scrollToMessageId!);
      });
    }
  }

  /// 请求在本次布局帧内把视口同步钉到底部（细节见 [_BottomAnchorScrollPosition]）。
  void _schedulePin() {
    _controller.pinToBottom = true;
  }

  /// 历史重载后**连续几帧**继续贴底。
  ///
  /// 为什么不能只贴一帧：ListView.builder 是懒构建的，长会话里
  /// maxScrollExtent 在首帧只是**估算值**；贴一次底之后，随着视口周围真正构建出
  /// 内容，额外高度才补上——用户看到的现象就是「导入长会话后没能到最底部」。
  /// 跟随模式下逐帧复查，直到位移归零或帧数用尽（用户上滚立即停手）。
  void _jumpToBottomSettling() {
    _userDetached = false;
    // **这一跳是程序发起的**：期间不管收到什么滚动通知都不许把它判成"用户上滚"。
    _jumpingToBottom = true;
    // 首帧即底部：这一次内容落地就在**首帧**（同帧内校到收敛）落到真底部，
    // 而不是"先渲染一帧再在下一帧跳过去"。
    _controller.firstFrameBottom = true;
    _controller.firstFrameBottomTarget = -1;
    _schedulePin();
    _lastMaxExtent = -1;
    _pinSettleFrames = _pinSettleLimit;
    _settlePin();
  }

  void _settlePin() {
    if (!mounted || _pinSettleFrames <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pinSettleFrames <= 0 || _userDetached) {
        _jumpingToBottom = false;
        return;
      }
      if (!_controller.hasClients) {
        _jumpingToBottom = false;
        return;
      }
      _pinSettleFrames--;
      final ScrollPosition pos = _controller.position;
      final double max = pos.maxScrollExtent;
      // 还没贴底，或者内容又长高了（懒构建把额外高度补上来了）⇒ 再贴一帧
      final bool stillGrowing = max > _lastMaxExtent + 0.5;
      _lastMaxExtent = max;
      if ((pos.pixels - max).abs() > 0.5 || stillGrowing) {
        _schedulePin();
        // 重新贴底**必须再要一帧**：pinToBottom 只是个标记，没有新一帧就不会再
        // 触发一次布局（post-frame 回调本身不排帧）。少了这一句，长列表会停在中途。
        WidgetsBinding.instance.scheduleFrame();
        _settlePin();
        return;
      }
      // 收敛了：这一跳结束，此后才允许按滚动通知判定用户上滚
      _jumpingToBottom = false;
      _settlePin();
    });
  }

  /// 帧后把**视口坐标**算出来（[MessageWindowCoordinate]）并通知出去。
  ///
  /// 为什么要"帧后 + 每帧"：视口区间是靠**布局**才定下来的（渲染树里的子项区间），
  /// 而**滚动不重建父组件**——早先只在 `build` 里注册一次帧后回调，于是滚动时一次都
  /// 不上报，右侧拇指就死在原地（用户 2026-10-03：「页面上滚，拇指不动」）。
  void _scheduleCoordinateFlush() {
    if (_flushScheduled) return;
    _flushScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _flushScheduled = false;
      _flushCoordinate();
    });
  }

  void _flushCoordinate() {
    if (!mounted) return;
    // 上一帧的补页补偿没量出来：帧后补一次（见 [_retryShift]）
    _retryShift();
    // 布局阶段算好的绝对目标，帧后再核一次（见 [assertPixels]）
    _assertShiftTarget();
    // **空槽位表没有坐标可报**：这一刻 `_builtFirst/_builtLast` 里是上一份内容的残留，
    // 报上去只会让面板为"还不存在的窗口"发一串补页请求（切 agent 时实测：
    // 新 agent 的窗口刚被清空，就照着旧坐标发了 from=… 的请求）。
    if (widget.slots.isEmpty) {
      _builtFirst = -1;
      _builtLast = -1;
      return;
    }
    // **坐标口径 = "真正与视口相交的显示行"**（不是"本帧构建到的下标区间"）。
    // 后者含视口上下各一段缓存、以及折叠组里那些零高度的组员：长工具组折叠时，
    // 滚过它的一帧里 `first/last` 会成百格地跳，右侧拇指就跟着跳
    // （用户 2026-11-15「展开工具调用后拇指乱跳」）。见 [_visibleRangeFromRenderTree]。
    final MessageRange? authoritative =
        _visibleRangeFromRenderTree() ?? _builtRangeFromRenderTree();
    final int first;
    final int last;
    if (authoritative != null) {
      first = authoritative.from;
      last = authoritative.to - 1;
    } else {
      // 兜底：itemBuilder 收集到的并集（比真值宽，但至少会更新，不会静默冻住）
      first = _builtFirst;
      last = _builtLast;
    }
    _builtFirst = -1;
    _builtLast = -1;
    if (first < 0 || last < first) return;
    // 本帧滚动方向（拇指据此区分"用户真的在往回滚"和"下标估算在抖"）。
    // 在 `next == _coordinate.value` 之前算：方向变了不广播坐标，但要跟着最新坐标走。
    final int dir = _controller.userScrollDirection;
    final MessageWindowCoordinate next = MessageWindowCoordinate(
      first: first,
      last: last.clamp(first, widget.slots.length - 1),
      total: widget.slots.length,
      scrollDirection: dir,
    );
    if (next == _coordinate.value) return;
    _coordinate.value = next;
    // 面板据它补页 / 淘汰（"滑到哪加载哪、只缓存坐标附近"）
    widget.onWindowChanged?.call(next.first, next.last);
    // 有落点校正在进行：拿这次实测的落点反馈下一步（见 [_pumpSeekCorrection]）
    _pumpSeekCorrection();
  }

  /// 从渲染树读**视口坐标**：真正**显示在视口里**的第一条 / 最后一条下标。
  ///
  /// 与 [_builtRangeFromRenderTree] 的区别（这条是滑块几何的口径）：
  /// - **不算缓存区**：滑出视口上下各一段缓存的子项仍被布局，但它们不在屏幕上；
  /// - **不算零高度行**：折叠组里被收起的组员是 `SizedBox.shrink()`，它们不占版面，
  ///   长组（上百条）折叠时"构建到哪"会被它们撑大成百格，拇指随每帧的构建区间
  ///   来回跳（用户 2026-11-15：「展开工具调用后右侧拇指乱跳」）。
  ///
  /// 判据：有正高度、且 `[top, bottom)` 与视口 `[scrollOffset, scrollOffset+剩余绘制范围)`
  /// 相交。逐行扫（视口里就那么几十格），结果稳定 ⇒ 匀速滚动时拇指单调、单步位移小。
  ///
  /// 一格都量不到（还没布局 / 内容全零高度）时返回 null，调用方退回构建区间。
  MessageRange? _visibleRangeFromRenderTree() {
    final RenderSliverList? target = _sliverListFromRenderTree();
    if (target == null || !target.attached) return null;
    final double top = target.constraints.scrollOffset;
    final double bottom = top + target.constraints.remainingPaintExtent;
    int? first;
    int? last;
    RenderBox? item = target.firstChild;
    while (item != null) {
      final double? at = target.childScrollOffset(item);
      final ParentData? data = item.parentData;
      if (at != null &&
          data is SliverMultiBoxAdaptorParentData &&
          data.index != null) {
        // 帧后扫（不在布局里）⇒ 读 size 是安全的
        final double extent = item.size.height;
        if (extent > 0.5 && at < bottom - 0.01 && at + extent > top + 0.01) {
          first ??= data.index!;
          last = data.index!;
        }
      }
      item = target.childAfter(item);
    }
    if (first == null || last == null) return null;
    final int slotCount = widget.slots.length;
    if (slotCount <= 0) return null;
    return MessageRange(
      first.clamp(0, slotCount - 1),
      (last + 1).clamp(1, slotCount),
    );
  }

  /// 从渲染树读**权威**的"构建到哪"：SliverList 实际持有的子项区间。
  ///
  /// 为什么不靠 itemBuilder 收集：滚动时 SliverList 只**创建**新进视口的子项，
  /// 留在原地的那些不会重建 ⇒ 收集到的区间是残缺的（早先的实现在滚动期间干脆
  /// 一次都不上报）。渲染树里的 `SliverMultiBoxAdaptorParentData.index` 才是真值。
  ///
  /// 找不到（结构变了 / 还没布局）时返回 null，调用方退回兜底口径。
  MessageRange? _builtRangeFromRenderTree() {
    final RenderSliverList? target = _sliverListFromRenderTree();
    if (target == null) return null;
    int? first;
    int? last;
    RenderBox? item = target.firstChild;
    while (item != null) {
      // **只认这一趟真的被布局过的子项**：`layoutOffset == null` 的是被
      // `AutomaticKeepAlive` 留在树里的屏外子项（滚动过的历史），它们不是"视口里看得到的"。
      if (target.childScrollOffset(item) != null) {
        final ParentData? data = item.parentData;
        if (data is SliverMultiBoxAdaptorParentData) {
          final int? index = data.index;
          if (index != null) {
            first ??= index;
            last = index;
          }
        }
      }
      item = target.childAfter(item);
    }
    if (first == null || last == null) return null;
    final int slotCount = widget.slots.length;
    if (slotCount <= 0) return null;
    // 末尾的插件内联卡片也在这张表里：夹进槽位范围
    return MessageRange(
      first.clamp(0, slotCount - 1),
      (last + 1).clamp(1, slotCount),
    );
  }

  /// 列表内部那个 [RenderSliverList]（懒构建子项都挂在它下面；null = 还没布局）。
  ///
  /// 注意：ListView 的 renderObject **不是** Viewport（外面还裹着 Scrollable 的
  /// Listener/Semantics/IgnorePointer…），所以在子树里找 `RenderSliverList`。
  RenderSliverList? _sliverListFromRenderTree() {
    final BuildContext? context = _listKey.currentContext;
    if (context == null) return null;
    final RenderObject? root = context.findRenderObject();
    if (root == null) return null;
    RenderSliverList? list;
    void find(RenderObject node) {
      if (list != null) return;
      if (node is RenderSliverList) {
        list = node;
        return;
      }
      node.visitChildren(find);
    }

    if (root is RenderSliverList) {
      list = root;
    } else {
      root.visitChildren(find);
    }
    return list;
  }

  /// 扫一遍渲染树：这一趟**真被布局过**的子项 → 顶边（下标 → 内容坐标）。
  ///
  /// 这个值来自 `SliverMultiBoxAdaptorParentData.layoutOffset`：由**实测**子项高度
  /// 逐个累加而来，不是 `maxScrollExtent` 那种外推估算——所以它才是
  /// "上面真正长高了多少"的真值。
  ///
  /// 注意**不要读子项的 `.size`**：那超出了 `RenderBox.size` 的许可范围
  /// （布局期间只有"声明了 parentUsesSize 的父对象"能读），会在布局断言里炸。
  /// 需要"某格的底边"时取它**下一条**子项的顶边（渲染树里子项是连续排布的）。
  /// `childScrollOffset == null` 的是被 `AutomaticKeepAlive` 留在树里的屏外子项。
  Map<int, double> _builtTopsFromRenderTree([RenderSliverList? target]) {
    final RenderSliverList? list = target ?? _sliverListFromRenderTree();
    final Map<int, double> out = <int, double>{};
    if (list == null) return out;
    RenderBox? item = list.firstChild;
    while (item != null) {
      final double? top = list.childScrollOffset(item);
      final ParentData? data = item.parentData;
      if (top != null &&
          data is SliverMultiBoxAdaptorParentData &&
          data.index != null) {
        out[data.index!] = top;
      }
      item = list.childAfter(item);
    }
    return out;
  }

  /// 布局**前**的快照：记下视口顶与已布局子项的顶边。
  ///
  /// 为什么必须在布局**之前**取：决定"用户**当时**在看哪一条"要按变化之前的位置判
  /// ——内容一长高，"视口顶之下的第一条真消息"就变成刚补进来的那几格了。
  /// 此刻渲染树里还是**上一帧**的 `layoutOffset`，正是"布局前"的真值。
  ///
  /// `!attached` 时不取（极端首帧路径下 `constraints` 会踩调试断言）：返回 null
  /// 即"实测拿不到"，调用方退回估算 + 限幅——不会抛异常。
  _BuiltTopsSnapshot? _snapshotBuiltTops() {
    final RenderSliverList? list = _sliverListFromRenderTree();
    if (list == null || !list.attached) return null;
    return _BuiltTopsSnapshot(
      viewportTop: list.constraints.scrollOffset,
      tops: _builtTopsFromRenderTree(list),
    );
  }

  /// 布局**后**再扫一遍 → 算出补偿量（null = 实测拿不到，调用方退回估算 / 帧后重试）。
  ///
  /// 锚点 = 布局前**视口里（含压着视口顶那一格）第一条这一帧高度没变的内容**
  /// （占位槽也算）：
  /// - 高度变了的（占位槽 → 真消息 / 折叠组展开 / 流式长高）是"刚出现的新内容"，
  ///   不是用户正在读的那一段：真机补页**先补横跨视口顶的那一份**，紧贴视口顶的
  ///   那一格往往**自身就是**被换掉的那一格，锚在它身上会漏补它下面已经加载的内容
  ///   （回归用例 N5：漏补 104px，用户看到的就是"整段下移"）；
  /// - 视口里没有稳定的内容时，退而取视口顶之上最后一条稳定内容。
  ///
  /// 补偿量 = 锚点**底边**的实测位移（= 它下一条子项顶边的差）：于是锚点**以下整段**
  /// 在屏幕上的位置也不动（N5 断言 ②）。
  double? _resolveShiftAbove(_BuiltTopsSnapshot before) {
    final Map<int, double> after = _builtTopsFromRenderTree();
    if (before.tops.isEmpty || after.isEmpty) return null;

    /// 这一格**自身高度**这一帧变了没有（null = 量不到：两个快照里缺相邻顶边）。
    ///
    /// 高度 = 下一条子项的顶边 - 它自己的顶边（渲染树里子项连续排布）。
    /// 两个快照都得有这一对才量得出来——只有一边有（这一帧才构建出来 / 已经不在
    /// 这一趟布局里）时返回 null，不能当成"没变"。
    bool? heightChanged(int index) {
      final double? t0 = before.tops[index];
      final double? t1 = after[index];
      final double? n0 = before.tops[index + 1];
      final double? n1 = after[index + 1];
      if (t0 == null || t1 == null || n0 == null || n1 == null) return null;
      return ((n1 - t1) - (n0 - t0)).abs() > 0.01;
    }

    /// 这一格**底边**的位移（内容坐标）：优先用它下一条的顶边（那就是底边），
    /// 那条读不到就退回它自己的顶边。
    ///
    /// 早先只按 `after` 判断下一条在不在，`before` 里没有（锚点正好是上一帧最后一格）
    /// 时整次实测作废 ⇒ 退化成估算，而"大高度差"那一帧估算被限幅丢掉 ⇒
    /// 补偿整个不发生，视口被推走几百像素。
    double? shiftOf(int index) {
      final double? was1 = before.tops[index + 1];
      final double? now1 = after[index + 1];
      if (was1 != null && now1 != null) return now1 - was1;
      final double? was0 = before.tops[index];
      final double? now0 = after[index];
      if (was0 != null && now0 != null) return now0 - was0;
      return null;
    }

    // 锚点 = 布局前**视口里（含压着视口顶那一格）第一条高度没变的内容**（占位槽也算）。
    //
    // 为什么允许占位槽：快速滑进还没加载的一段时，视口里全是占位槽，一页补回来
    // 它们**全体**都变了高度——这时"第一条没变的"常常就在视口下方（缓存区里的
    // 占位槽）。钉住它照样把视口里那一段钉住；只认真消息的话这一帧就没有锚点，
    // 补偿整个不发生（实测：一页占位变真消息，视口被推走几百像素）。
    //
    // 为什么"压着视口顶那一格"也要算：它的顶边在视口上方，但它占着视口最上面一截，
    // 正是用户眼睛落着的那一行。跳过它去钉下面那几行，一旦它们之间某一格高度变了，
    // 这一行就会被推走（实测：一页补进视口，顶部那一行位移差几十像素）。
    int? below;
    int? above;
    before.tops.forEach((int index, double top) {
      if (heightChanged(index) != false) return; // 变了 / 量不到：不是"正在读的那一段"
      // 底边用下一条的顶边（渲染树里子项连续排布）；最末一格读不到就按自己的顶边算
      final double bottom = before.tops[index + 1] ?? top;
      if (bottom > before.viewportTop + 0.01) {
        if (below == null || top < before.tops[below]!) below = index;
      } else if (above == null || top > before.tops[above]!) {
        above = index;
      }
    });
    final int? anchor = below ?? above;
    if (anchor == null) return null;
    return shiftOf(anchor);
  }

  /// 开始一次"补页补偿"：布局前拍照 + 把解析器挂到控制器上（布局时消费一次）。
  ///
  /// 两个信号都走这里：[padAboveStamp]（整段在视口上方）与 [contentShiftStamp]
  /// （横跨视口顶 / 落在视口里）——补偿口径是同一套，锚点由
  /// [_resolveShiftAbove] 按"用户当时在看哪一条"现场判定。
  void _beginShiftCompensation() {
    final _BuiltTopsSnapshot? snapshot = _snapshotBuiltTops();
    _pendingShiftSnapshot = snapshot;
    _controller.retryShiftRequested = false;
    // 绝对目标的基准：布防这一刻的滚动位置（此后的用户滚动量单独累计，见
    // [_BottomAnchorScrollController.scrollSinceArm]）
    _controller.shiftBasePixels =
        _controller.hasClients ? _controller.position.pixels : null;
    _controller.scrollSinceArm = 0;
    _controller.resolveShiftAbove =
        snapshot == null ? null : () => _resolveShiftAbove(snapshot);
    _controller.shiftAbove = true;
  }

  /// 布局阶段没量出来的那次补偿的**布局前快照**（帧后重试用，见 [_retryShift]）。
  _BuiltTopsSnapshot? _pendingShiftSnapshot;

  /// 布局阶段没量出补偿量时，帧后**再量一次**并校正偏移。
  ///
  /// 为什么需要：`_resolveShiftAbove` 只能在布局阶段读渲染树，而"大高度差"那一帧
  /// （一整页占位变真消息 / 长折叠组进出视口）里，这一趟布局过的子项可能**全都**
  /// 换过高度、或者锚点还没被布局到 ⇒ 量不出来。这一帧就整个不补，视口被推走
  /// 几百像素（实测：814 条会话匀速滚动时有 0.4% 的帧这样）。
  ///
  /// 帧后渲染树已经稳定，同样的量法通常就能拿到 ⇒ 补一次偏移。代价是那一帧
  /// 先画出去再校正（一帧的位移），换掉的是"整段内容被永久推走"。
  void _retryShift() {
    if (!_controller.retryShiftRequested) return;
    _controller.retryShiftRequested = false;
    final _BuiltTopsSnapshot? before = _pendingShiftSnapshot;
    if (before == null || !mounted || !_controller.hasClients) return;
    final double? shift = _resolveShiftAbove(before);
    if (shift == null) return;
    final double? base = _controller.shiftBasePixels;
    final ScrollPosition pos = _controller.position;
    final double target =
        ((base ?? pos.pixels) + _controller.scrollSinceArm + shift)
            .clamp(pos.minScrollExtent, pos.maxScrollExtent);
    _controller.shiftBasePixels = null;
    _controller.scrollSinceArm = 0;
    if ((target - pos.pixels).abs() <= 0.01) return;
    pos.correctPixels(target);

  }

  /// 帧后核对补偿的**绝对目标**：框架在同一帧的重跑布局里还会按它自己的
  /// `scrollOffsetCorrection` 再挪一次，最终位置可能偏离我们算好的目标（见
  /// [_BottomAnchorScrollController.assertPixels]）。这里对一次就收工。
  void _assertShiftTarget() {
    final double? target = _controller.assertPixels;
    if (target == null) return;
    _controller.assertPixels = null;
    if (!mounted || !_controller.hasClients) return;
    final ScrollPosition pos = _controller.position;
    if ((pos.pixels - target).abs() <= 0.5) return;
    pos.correctPixels(target.clamp(pos.minScrollExtent, pos.maxScrollExtent));


  }

  /// 滚动定位到指定消息并短暂高亮。
  ///
  /// 兼容目标未构建（懒加载、目标在视口外）的情况：先按索引比例粗跳使目标进入构建
  /// 范围，下一帧重试精确定位；最终 [Scrollable.ensureVisible] 保证目标必达。
  /// **目标不在槽位表里**（还没加载）时直接返回：面板会先把它所在的那一段拉回来
  /// （见 message_panel 的 _locateMessage）。
  void _scrollToMessage(String id) {
    if (!_controller.hasClients) return;
    final int idx = widget.slots.indexWhere(
      (ChatMessage? m) => m?.id == id,
    );
    if (idx < 0) return;
    // 目标在折叠组里：先就地展开（定位要看见那一行），下一帧再滚
    final _RunInfo? run = _runAt(idx);
    if (run != null && run.collapsed) {
      setState(() {
        _expandedAnchorId = run.runId;
        _expandedAnchor = run.head;
      });
      // 展开组整段钉住（与点开折叠行走同一条口径，见 [_publishExpandedRun]）
      _publishExpandedRun();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToMessage(id);
      });
      return;
    }
    final GlobalKey? key = _itemKeys[id];
    final BuildContext? ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.2,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
      setState(() {
        _highlightedId = id;
        // 定位到历史消息：视为用户脱离跟随（不把视口再拽回底部）
        _userDetached = true;
      });
      _highlightTimer?.cancel();
      _highlightTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) {
          setState(() {
            _highlightedId = null;
          });
        }
      });
    } else {
      // 目标尚未构建：按下标比例粗跳，下一帧重试精确定位
      if (_scrollRetries >= 2 || widget.slots.isEmpty) return;
      _scrollRetries++;
      final double ratio = widget.slots.length <= 1
          ? 0.0
          : idx / (widget.slots.length - 1);
      _controller.jumpTo(_controller.position.maxScrollExtent * ratio);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToMessage(id);
      });
    }
  }

  /// 滚动通知：在「跟随 / 阅读」两种模式间切换（完全贴底 → 跟随）。
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollMetricsNotification) {
      // 内容尺寸变了（补页 / 流式增长）：视口区间可能跟着变，刷新一次坐标
      _scheduleCoordinateFlush();
      return false;
    }
    if (notification is! ScrollUpdateNotification) return false;
    // **滚动也要刷坐标**：滚动不重建父组件，只有这条路上能拿到新的视口区间
    // （用户 2026-10-03：「页面上滚，拇指不动」就是漏了这一步）。
    _scheduleCoordinateFlush();
    // 用户自己滚了 ⇒ 正在做的落点校正作废（不跟用户抢）
    if (!_programmaticJump) _cancelSeekCorrection();
    // 回底动画 / 程序化直达底部的中间帧不算用户上滚
    if (_returningToBottom) return false;
    if (_jumpingToBottom) return false;
    final ScrollMetrics m = notification.metrics;
    _setUserDetached(m.maxScrollExtent - m.pixels > _bottomEpsilon);
    return false;
  }

  /// 更新模式（仅在变化时 setState，驱动「回到底部」按钮显隐）
  void _setUserDetached(bool value) {
    if (_userDetached == value) return;
    setState(() {
      _userDetached = value;
    });
  }

  /// 平滑滚到底部并恢复跟随（没有 [MessageList.onReloadTail] 时的退路）。
  void _returnToBottom() {
    if (!_controller.hasClients) return;
    _setUserDetached(false);
    _returningToBottom = true;
    _controller
        .animateTo(
          _controller.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        )
        .whenComplete(() {
      _returningToBottom = false;
      if (!mounted || !_controller.hasClients) return;
      final ScrollPosition pos = _controller.position;
      _setUserDetached(pos.maxScrollExtent - pos.pixels > _bottomEpsilon);
    });
  }

  /// 拖到某个全局下标（右侧滑块）：按**坐标**算落点，帧后按实测落点校正。
  ///
  /// 落点为什么不能只算一次：`pixels ↔ 全局下标` 只是估算——占位槽恒定 88px
  /// （[kMessagePlaceholderExtent]），已加载消息的真实高度各不相同。所以：
  /// 先按 [pixelOffsetForIndex]（以视口第一条为锚点）跳过去，再由
  /// [MessageSeekCorrection] 用"实际落在哪"反馈修正（拖拽期间只粗跟，
  /// 松手时 [onSeekSettled] 收口，见 [_beginSeekCorrection]）。
  ///
  /// **下标的上限是"最后一条正好落在视口底"**（`total - 看得见的条数`）——滑块几何就是这么
  /// 定的（见 [messageScrollbarThumb]：看到末尾 = 贴底）。所以拖到最底下时必须**直达底部**，
  /// 否则会停在"最新那几条还差一屏"的地方。
  void _seekToIndex(int index) {
    if (!_controller.hasClients) return;
    // 新的落点请求作废上一次校正：别让两次校正互相甩
    _cancelSeekCorrection();
    final ScrollPosition pos = _controller.position;
    final MessageWindowCoordinate at = _coordinate.value;
    if (at.total > 0 && index >= at.lastSeekable) {
      _jumpTo(pos.maxScrollExtent);
      return;
    }
    _jumpTo(
      pixelOffsetForIndex(
        index: index,
        at: at,
        anchorPixels: pos.pixels,
        step: kMessagePlaceholderExtent,
      ).clamp(pos.minScrollExtent, pos.maxScrollExtent),
    );
  }

  /// 我们自己发起的跳转：置标记，让滚动通知别把它当成"用户上滚"，也用来作废校正。
  void _jumpTo(double pixels) {
    if (!_controller.hasClients) return;
    _programmaticJump = true;
    _controller.jumpTo(pixels);
    WidgetsBinding.instance.addPostFrameCallback((_) => _programmaticJump = false);
  }

  /// 松手/点击之后：把落点校正到目标下标（≤[MessageSeekCorrection.maxAttempts] 次）。
  ///
  /// 用户的直觉是"拖到哪就停在哪"：拇指松手后画的是**真实坐标**，所以内容必须真的
  /// 落到那个下标附近——否则拇指会"回落"到内容真正所在的地方（用户 2026-10-03 报的
  /// 第 3 条：「松开后拇指回落到底部或顶部，但中间页面不会随其回落」）。
  void _beginSeekCorrection(int index) {
    if (!_controller.hasClients) return;
    if (!_coordinate.value.known) return;
    _seekCorrection = MessageSeekCorrection(
      target: index,
      step: kMessagePlaceholderExtent,
    );
    _pumpSeekCorrection();
  }

  /// 用**实测落点**推进校正：拿当前坐标（帧后刷新）当反馈，决定要不要再跳一次。
  void _pumpSeekCorrection() {
    final MessageSeekCorrection? correction = _seekCorrection;
    if (correction == null) return;
    if (correction.finished || !mounted || !_controller.hasClients) {
      _cancelSeekCorrection();
      return;
    }
    final MessageWindowCoordinate at = _coordinate.value;
    if (!at.known) return; // 还没量出来：等下一次坐标刷新
    final ScrollPosition pos = _controller.position;
    final double? next = correction.observe(
      landed: at.first,
      pixels: pos.pixels,
    );
    if (next == null) {
      _cancelSeekCorrection();
      return;
    }
    _jumpTo(next.clamp(pos.minScrollExtent, pos.maxScrollExtent));
  }

  void _cancelSeekCorrection() => _seekCorrection = null;

  /// 清掉已经不在槽位表里的 GlobalKey（只增不减的话，长会话里是一份隐性内存）。
  ///
  /// 阈值触发 + 整表扫一次：平时的开销是零，扫的时候是一次 O(条数)（稀有事件）。
  void _pruneItemKeys() {
    if (_itemKeys.length <= _itemKeysLimit) return;
    final Set<String> alive = <String>{
      for (final ChatMessage? m in widget.slots)
        if (m != null) m.id,
    };
    _itemKeys.removeWhere((String id, GlobalKey _) => !alive.contains(id));
  }

  /// 占位槽：**还没加载**的那一段（等高，见 [kMessagePlaceholderExtent]）。
  Widget _buildPlaceholder(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: kMessagePlaceholderExtent,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          width: 180,
          height: 10,
          margin: const EdgeInsets.only(left: 6),
          decoration: BoxDecoration(
            color: cs.onSurface.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
        ),
      ),
    );
  }

  /// 这条槽位能不能进折叠组（规格 §3.2.1）。
  ///
  /// 已完成工具（`kind=='tool'` 且不在跑）与思考段（`kind=='thinking'`）可入组；
  /// **跑着的/流式的永不参与折叠**（用户要看得见进行中状态），null 槽（还没加载）
  /// 与不进主消息流的槽位（临时员工）都是组边界（组在其处闭合）。
  bool _groupableAt(int index) {
    if (index < 0 || index >= widget.slots.length) return false;
    final ChatMessage? m = widget.slots[index];
    if (m == null) return false;
    final bool Function(ChatMessage message)? visible = widget.visible;
    if (visible != null && !visible(m)) return false;
    if (m.isStreaming) return false;
    if (m.kind == 'thinking') return true;
    if (m.kind == 'tool') return !m.toolRunning;
    return false;
  }

  /// 下标所在折叠组（run）的信息；不在组里返回 null。
  ///
  /// 纯渲染层现算：只向两侧走**组本身的长度**（O(run)），不做全表扫描
  /// （规格 §5.5「折叠不得反噬渲染」）；简述计数只读显示行里本来就有的字段。
  _RunInfo? _runAt(int index) {
    if (!_groupableAt(index)) return null;
    int head = index;
    while (_groupableAt(head - 1)) {
      head--;
    }
    int tail = index;
    while (_groupableAt(tail + 1)) {
      tail++;
    }
    int toolCount = 0;
    int thinkingCount = 0;
    final Map<String, int> toolCountsByLabel = <String, int>{};
    for (int i = head; i <= tail; i++) {
      final ChatMessage m = widget.slots[i]!;
      if (m.kind == 'thinking') {
        thinkingCount++;
        continue;
      }
      toolCount++;
      final String label = toolLabel(m.toolName ?? '');
      toolCountsByLabel[label] =
          (toolCountsByLabel[label] ?? 0) + 1;
    }
    final String runId = widget.slots[head]!.id;
    return _RunInfo(
      head: head,
      tail: tail,
      runId: runId,
      // 展开态按**锚点下标落不落在这一段里**判，不按"组首 id 相等"：
      // 补页可能在组首之前接进更多工具/思考（组首 id 变了），按 id 判会把用户
      // 正看着的展开组当场判成折叠 —— 内容突然塌回一行，视口跳一大截。
      collapsed: _expandedAnchor < head || _expandedAnchor > tail,
      toolCount: toolCount,
      thinkingCount: thinkingCount,
      toolCountsByLabel: toolCountsByLabel,
    );
  }

  /// 点开/收起折叠组：走既有「上方补页补偿」通路（[_beginShiftCompensation]），
  /// 保证上方内容零位移（TC-COLLAPSE-01）。控制条两态同高 ⇒ 增量只发生在它下方；
  /// 组横跨视口顶时由实测锚点精确补偿，净位移仍为 0。
  ///
  /// 展开后立刻把区间报给面板（[_publishExpandedRun]）：面板从下一帧起会把它整段
  /// 钉在缓存里，避免滚动时淘汰在组中间打洞、整组塌陷引发视口跳变。
  void _toggleRun(_RunInfo run) {
    _beginShiftCompensation();
    setState(() {
      final bool expanding = run.collapsed;
      _expandedAnchorId = expanding ? run.runId : null;
      _expandedAnchor = expanding ? run.head : -1;
    });
    _publishExpandedRun();
  }

  /// 一个槽位（或末尾的插件内联卡片）。
  Widget _buildItem(BuildContext context, int index) {
    final int slotCount = widget.slots.length;
    if (index >= slotCount) {
      // 消息之后的槽位让给插件内联卡片（Q12）：按到达顺序逐项渲染
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: widget.trailingCards[index - slotCount],
      );
    }
    if (_builtFirst < 0 || index < _builtFirst) _builtFirst = index;
    if (index > _builtLast) _builtLast = index;
    // 本帧有子项被构建 ⇒ 帧后刷新一次视口坐标（滚动时只有"新进视口"的子项会走到这里）
    _scheduleCoordinateFlush();
    final ChatMessage? message = widget.slots[index];
    if (message == null) return _buildPlaceholder(context);
    // 不进主消息流的那种（临时员工的消息）：零高度 —— 不占版面、也不打断下标连续性
    final bool Function(ChatMessage message)? visible = widget.visible;
    if (visible != null && !visible(message)) {
      return const SizedBox.shrink();
    }
    // 折叠组（规格 §3.2.1「有就折叠」）：组内非首格收起时零高度（不占版面），
    // 组首格画控制条；展开态组员各画各的行。
    final _RunInfo? run =
        (message.kind == 'tool' || message.kind == 'thinking')
        ? _runAt(index)
        : null;
    if (run != null && run.collapsed && index != run.head) {
      return const SizedBox.shrink();
    }
    final Widget card = _buildMessageCard(context, index, message);
    if (run == null || (!run.collapsed && index != run.head)) return card;
    // 控制条两态同高 ⇒ 展开/收起的高度增量只发生在它下方（TC-COLLAPSE-01 的
    // 结构性保证）；折叠态的组首格只画控制条（组内消息行隐藏）。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: CollapsedRunRow(
            key: ValueKey<String>('collapsed-run-${run.runId}'),
            toolCount: run.toolCount,
            thinkingCount: run.thinkingCount,
            toolCountsByLabel: run.toolCountsByLabel,
            expanded: !run.collapsed,
            onTap: () => _toggleRun(run),
          ),
        ),
        if (!run.collapsed) card,
      ],
    );
  }

  /// 一条消息的正常行（折叠组展开时组员的行也走这里）。
  ///
  /// 临时员工的消息：在他的那一段**开头**标一次（同一个人的连续消息/工具
  /// 只在第一行顶标签，避免每条都占一行）。
  Widget _buildMessageCard(
    BuildContext context,
    int index,
    ChatMessage message,
  ) {
    final ChatMessage? previous = index > 0 ? widget.slots[index - 1] : null;
    final bool showSubagentTag =
        message.isSubagentMessage &&
        (previous == null || previous.subagentId != message.subagentId);
    Widget child;
    if (message.kind == 'tool') {
      child = Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: ToolCallCard(message: message),
      );
    } else if (message.kind == 'thinking') {
      child = Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: ThinkingCard(message: message),
      );
    } else if (message.kind == 'ask_user_question') {
      child = Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _AskQuestionCard(
          message: message,
          onAnswer: widget.onAskAnswer,
        ),
      );
    } else if (message.kind == 'notice') {
      child = Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: HookNoticeCard(message: message),
      );
    } else {
      child = Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _MessageBubble(message: message),
      );
    }
    if (showSubagentTag) {
      child = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _SubagentTagBar(
            name: message.subagentName,
            level: message.subagentLevel,
          ),
          child,
        ],
      );
    }
    // 定位目标：为每条消息挂 GlobalKey，命中定位时短暂高亮
    final GlobalKey key = _itemKeys.putIfAbsent(message.id, GlobalKey.new);
    final bool highlighted = _highlightedId == message.id;
    if (!highlighted) {
      return KeyedSubtree(key: key, child: child);
    }
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      key: key,
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: cs.primary, width: 2),
      ),
      child: child,
    );
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _coordinate.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final int slotCount = widget.slots.length;
    if (slotCount == 0 && widget.trailingCards.isEmpty) {
      // **加载中**（切 agent / 首载 / 切会话）：窗口本来就是空的，但这不是"没有消息"
      // ——渲染静态骨架，别闪空态（用户 2026-10-03 症状 1）。面板在历史真正落地
      // （或明确失败）之后才把 [MessageList.loading] 摘掉，那时才会走到下面的欢迎页。
      if (widget.loading) return _buildLoadingSkeleton(context);
      // 空态：居中排版（有插件卡片时不显示欢迎页）。标识本身见 [WelcomeMark]：
      // 主题色的 TREE 字标 + HUD 三段线（用户 2026-10-04 定稿；原来是平台彩色的 👋，
      // 染不上主题色，在绿 + 近黑的配色里是外来色）。
      return const Center(child: WelcomeMark());
    }
    // 本帧构建到哪由 _buildItem 收集（只是兜底）+ 渲染树读取（权威），见 [_flushCoordinate]。
    // 首帧也要安排一次：否则空表 / 全占位时坐标一直是 unknown（拇指不画）。
    _scheduleCoordinateFlush();
    return Stack(
      children: <Widget>[
        // 滚动通知：切换跟随/阅读模式（见 _onScrollNotification）
        NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          // **关掉桌面自动挂上的原生 Scrollbar**（用户 2026-10-03：「滑块乱跳」）：
          // 桌面 ScrollBehavior 会给每个竖向 Scrollable 自动包一条 Material Scrollbar
          // （`MaterialScrollBehavior.buildScrollbar`），它的几何来自**已构建内容**的
          // 估算范围（取回来的按真实高度、占位槽按占位高度，平均值随构建到哪而变）
          // ⇒ 窗口化列表里必然乱跳，而且就画在自绘的 MessageScrollbar 旁边（同一条窄带里
          // 两条拇指，一条稳一条跳）。这里只关滚动条（scrollbars: false），
          // 物理/越界指示/拖拽设备都保留。
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
            child: ListView.builder(
              key: _listKey,
              controller: _controller,
              // 常规（非反转）布局：offset 0 = 顶部（最旧），maxScrollExtent = 底部。
              // 跟随模式下由 _BottomAnchorScrollPosition 在布局阶段同步钉底；
              // 阅读模式下不做任何补偿（零漂移）。
              // 右侧留出滑块的宽度（它画在列表之上、不占滚动区域）。
              padding: const EdgeInsets.only(
                left: 16,
                right: 24,
                top: 12,
                bottom: 12,
              ),
              itemCount: slotCount + widget.trailingCards.length,
              itemBuilder: _buildItem,
            ),
          ),
        ),
        // 右侧滑块：**按全局下标算几何**（用户 2026-10-04）——自带 Scrollbar 的
        // 几何来自"已构建内容"的估算范围，窗口化列表里会随滚动来回跳。
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: 14,
          child: MessageScrollbar(
            coordinate: _coordinate,
            onSeek: _seekToIndex,
            onSeekSettled: _beginSeekCorrection,
          ),
        ),
        // 「回到底部」按钮：用户脱离跟随（向上查看历史）时显示，点击后**重载末尾
        // 一段**并回到最新（没有回调时退回平滑回底）。
        Positioned(
          right: 24,
          bottom: 16,
          child: AnimatedOpacity(
            opacity: _userDetached ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            child: IgnorePointer(
              ignoring: !_userDetached,
              child: _buildScrollToBottomButton(),
            ),
          ),
        ),
      ],
    );
  }

  /// 加载中骨架：几条静态灰条（**不带任何动画**——加载指示器的循环动画会让
  /// `pumpAndSettle` 永不收敛，而"闪一下"本来就是这次要修的症状）。
  ///
  /// 用 [SingleChildScrollView] + 不可滚动物理包一层：窗口再矮也不会溢出
  /// （溢会在 widget 测试里直接抛错），同时不产生第二个可滚动位置。
  Widget _buildLoadingSkeleton(BuildContext context) {
    final Color bar = Theme.of(context).colorScheme.surfaceContainerHighest;
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 24, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final double widthFactor in <double>[0.45, 0.72, 0.55, 0.64, 0.5])
              Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: widthFactor,
                  child: Container(
                    height: 40,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: bar,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 「回到底部」悬浮按钮
  Widget _buildScrollToBottomButton() {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: '回到底部',
      child: Material(
        color: cs.surface,
        elevation: 3,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: _scrollToBottomFromButton,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(
              Icons.arrow_downward,
              size: 18,
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  /// 点击「回到底部」：请面板**重载末尾一段**（落点确定，必然到底）；没有回调
  /// （别处复用本组件的场景）时退回平滑回底。
  void _scrollToBottomFromButton() {
    final VoidCallback? reload = widget.onReloadTail;
    if (reload != null) {
      _setUserDetached(false);
      reload();
      return;
    }
    _returnToBottom();
  }
}

/// 临时员工标记条（一行式消息流里「这一段是谁在说」）。
///
/// 为什么需要它：临时员工没有自己的会话，它的话与工具调用都写进**会话主人**的消息流
/// （`agent_id` 仍是主人，前端过滤口径不变），不打标就会看起来像主 agent 在说话。
/// 只在同一个临时员工的**那一段开头**画一次（见调用处的 `showSubagentTag`）。
class _SubagentTagBar extends StatelessWidget {
  const _SubagentTagBar({required this.name, required this.level});

  final String name;
  final int level;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String label = name.trim().isEmpty ? '未命名' : name.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4, left: 2),
      child: Row(
        children: <Widget>[
          Icon(Icons.person_outline, size: 12, color: cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              '临时员工「$label」 · 层级 $level',
              key: const ValueKey<String>('subagent-tag-bar'),
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// 单条消息气泡
///
/// 用户消息：右对齐，主色背景（浅色 #00904A + 白字 / 深色 #00FF8C + 墨绿字），
/// 文字用 onPrimary，保证对比度。
/// agent 消息：左对齐，背景 cs.surface（浅色白底 / 深色黑底），文字 onSurface
/// （浅色墨绿 / 深色浅绿白），边框 dividerColor。
/// 流式消息在内容末尾追加闪烁光标（"|" 与空格每 500ms 交替）。
/// 附件以小卡片形式展示在内容上方，含文件图标、文件名与大小。
///
/// **流式平滑揭示**（用户 2026-10-15 报告：生成方一慢，界面更新帧率就跟着掉）：
/// 增量帧到达的节奏 = 模型吐字的节奏，直接「来一帧画一次」会把显示帧率钉死在
/// 到达帧率上。气泡内把「揭示进度」交给一只按需运行的 Ticker：账上有积压才
/// 逐帧追赶（积压越多放得越快，指数收敛），追平即停表——没新字时绝不常驻
/// 占帧。光标闪烁仍用 500ms Timer（不排帧、不阻塞 pumpAndSettle）。封口
/// （msg_end）后全量交还 markdown 渲染，两个计时器都停掉。
class _MessageBubble extends StatefulWidget {
  final ChatMessage message;

  const _MessageBubble({required this.message});

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble>
    with SingleTickerProviderStateMixin {
  /// 光标闪烁定时器（只在流式期间计数；不用 Ticker：常驻时钟会把帧一直排着，
  /// 测试里 pumpAndSettle 永不收敛，真机上白耗电）
  Timer? _blinkTimer;

  /// 揭示时钟：**只在账上有积压时活着**，追平即停表（见 _syncReveal/_onTick）
  Ticker? _ticker;

  /// 上一次 tick 的时钟读数（Duration.zero = 还没打第一拍，只记基准不出字）
  Duration _lastElapsed = Duration.zero;

  /// 已揭示的字符数（double 累加、取整渲染——慢速 trickle 时单帧不足一个字也能记账）
  double _revealed = 0;

  /// 当前是否显示光标（"|" 与空格交替）
  bool _showCursor = true;

  /// 上一帧读到的是否还在流式。**不能拿 oldWidget.message 比较**：
  /// ChatMessage 是原地可变的，新旧 widget 持有同一个对象，msg_end 封口后
  /// 两边的 isStreaming 读出来都是 false，"停表"分支永远不命中（旧实现里
  /// 闪烁 Timer 就是这么停不下来、每 500ms 空转重建已收尾气泡的）。
  bool _wasStreaming = false;

  /// 鼠标是否悬停在气泡上（用于显示「复制全文」按钮）
  bool _hoverCopy = false;

  /// 气泡圆角
  static const double _radius = AppRadius.md;

  /// 揭示保底速度（字/秒）：增量再少，正文也至少以这个速率逐帧生长
  static const double _minRevealSpeed = 12;

  /// 积压追赶系数：速度 = 保底 + 积压 × 系数 ⇒ 积压按 ~0.17s 时间常数指数收敛，
  /// 一次性到达的大段增量会在几帧内消化完，不会形成永久滞后
  static const double _revealCatchup = 6;

  @override
  void initState() {
    super.initState();
    _wasStreaming = widget.message.isStreaming;
    if (widget.message.isStreaming) {
      // 中途挂上（切走再切回 / 滚出视口再滚回来）：已到达的正文全量显示，
      // 只对之后的增量做平滑追赶——不把整段话重打一遍打字机
      _revealed = widget.message.content.length.toDouble();
      _startBlinking();
      _syncReveal();
    }
  }

  @override
  void didUpdateWidget(covariant _MessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool nowStreaming = widget.message.isStreaming;
    if (nowStreaming == _wasStreaming) {
      if (nowStreaming) {
        if (!identical(widget.message, oldWidget.message)) {
          // 复用 State 换跟另一段流式正文：旧内容直接给全
          _revealed = widget.message.content.length.toDouble();
        }
        // 父级每截增量都会重建到这里：账上有新积压就把揭示时钟叫醒
        _syncReveal();
      }
      return;
    }
    _wasStreaming = nowStreaming;
    if (nowStreaming) {
      _revealed = widget.message.content.length.toDouble();
      _startBlinking();
      _syncReveal();
    } else {
      // 封口：停掉两个计时器，全量正文交还 markdown 渲染（本帧就是父级
      // setState 触发的重建，停表后不再有任何常驻帧）
      _stopBlinking();
      _stopReveal();
    }
  }

  /// 启动光标闪烁（每 500ms 切换一次）
  void _startBlinking() {
    _stopBlinking();
    _blinkTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) {
        setState(() {
          _showCursor = !_showCursor;
        });
      }
    });
  }

  /// 停止光标闪烁
  void _stopBlinking() {
    _blinkTimer?.cancel();
    _blinkTimer = null;
  }

  /// 按需启动揭示时钟：账上有积压才活着，追平/无积压绝不占帧（幂等）
  void _syncReveal() {
    if (_ticker != null) {
      if (_revealed >= widget.message.content.length) _stopReveal();
      return;
    }
    if (_revealed < widget.message.content.length) {
      // 基准直接取当前帧时间戳：时钟是-build 期间被增量帧叫醒的，下一拍
      // 就能正常推进，不浪费一拍“只记基准”的空帧
      final Duration frame = SchedulerBinding.instance.currentFrameTimeStamp;
      _lastElapsed = frame;
      _ticker = createTicker(_onTick)..start();
    }
  }

  /// 停止揭示时钟
  void _stopReveal() {
    _ticker?.dispose();
    _ticker = null;
  }

  /// 有积压时每帧一拍：向正文实际长度逐帧追赶，追平即停表；只在真变了才重画
  void _onTick(Duration elapsed) {
    final Duration last = _lastElapsed;
    _lastElapsed = elapsed;
    if (last == Duration.zero) return; // 第一拍只建立基准
    final double dt = (elapsed - last).inMicroseconds / 1e6;
    if (dt <= 0) return;
    final int total = widget.message.content.length;
    final int before = _revealed.toInt();
    if (_revealed >= total) {
      _stopReveal();
      return;
    }
    // 积压越多放得越快：保底匀速 + 指数收敛，一次性的大段增量几帧内消化完
    final double backlog = total - _revealed;
    _revealed = math.min(
      total.toDouble(),
      _revealed + (_minRevealSpeed + backlog * _revealCatchup) * dt,
    );
    final bool done = _revealed >= total;
    if (done) _stopReveal();
    if (done || _revealed.toInt() != before) setState(() {});
  }

  /// 揭示进度 → 正文截断点：落在代理对中间时回退一格，避免表情被切出乱码
  int _revealCut(String text) {
    final int cut = _revealed.toInt();
    if (cut <= 0) return 0;
    if (cut >= text.length) return text.length;
    final int cu = text.codeUnitAt(cut - 1);
    return (cu >= 0xD800 && cu <= 0xDBFF) ? cut - 1 : cut;
  }

  @override
  void dispose() {
    _stopBlinking();
    _stopReveal();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ChatMessage message = widget.message;
    final bool isUser = message.isUser;
    final ThemeData theme = Theme.of(context);
    final cs = theme.colorScheme;
    // 用户气泡改中性块（用户 2026-11-08：消息流一起中性化，绿色只留标志性位置）；
    // 深浅各一档底色，配 1px 中性边框，不再用主色满色底。
    final Color userBubbleColor = theme.brightness == Brightness.dark
        ? AppTheme.userBubbleDark
        : AppTheme.userBubbleLight;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 气泡最大宽度：只留一小段内边距，不再按 70% 压缩。
        // 中栏被拖窄时（最小 360px）70% 只剩下 ~250px，右侧会空出一大块；
        // 留 7% 既能撑满可用宽度，又让左右气泡的对齐关系看得出来。
        final double maxBubbleWidth = constraints.maxWidth * 0.93;
        return Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxBubbleWidth),
            child: Container(
              padding: isUser
                  ? const EdgeInsets.symmetric(horizontal: 12, vertical: 8)
                  : const EdgeInsets.fromLTRB(12, 8, 14, 8),
              decoration: isUser
                  ? BoxDecoration(
                      color: userBubbleColor,
                      borderRadius: BorderRadius.circular(_radius),
                      border: Border.all(color: theme.dividerColor),
                    )
                  // 模型消息不给「边框盒子」，改成**高亮块**：左侧中性竖条，无底色。
                  // 盒子会把消息流切成一格一格，去掉之后整轮对话读起来是连续的；
                  // 竖条仍让人一眼认出「这段是模型说的」（中性色，不再抢主色）。
                  : BoxDecoration(
                      border: Border(
                        left: BorderSide(
                          color: cs.outline,
                          width: 3,
                        ),
                      ),
                    ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.attachments != null &&
                      message.attachments!.isNotEmpty) ...<Widget>[
                    _buildAttachments(),
                    const SizedBox(height: 6),
                  ],
                  _buildContent(message, isUser),
                  const SizedBox(height: 4),
                  _buildTime(message, isUser),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 构建消息内容（流式时追加闪烁光标）
  Widget _buildContent(ChatMessage message, bool isUser) {
    // 用户气泡已是中性底（用户 2026-11-08：消息流去绿），文字用正文色；
    // 模型消息同样用正文色，两者靠气泡/竖条区分角色，不再靠主色。
    final Color textColor = Theme.of(context).colorScheme.onSurface;
    final String text = message.content;
    // 流式：只画「已揭示」的那一截，没揭示到的部分在账上等着逐帧放出来
    final String shown = message.isStreaming
        ? text.substring(0, _revealCut(text))
        : text;
    // 流式但尚无内容（或首字还没轮到揭示）：仅显示闪烁光标
    if (message.isStreaming && shown.isEmpty) {
      return Text(
        _showCursor ? '|' : ' ',
        style: TextStyle(
          color: textColor,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    if (message.isStreaming) {
      return RichText(
        text: TextSpan(
          children: <InlineSpan>[
            TextSpan(
              text: shown,
              style: TextStyle(color: textColor, fontSize: 14, height: 1.4),
            ),
            TextSpan(
              text: _showCursor ? '|' : ' ',
              style: TextStyle(
                color: textColor,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }
    // 用户消息保持纯文本（可选中复制）
    if (isUser) {
      return SelectableText(
        text,
        style: TextStyle(color: textColor, fontSize: 14, height: 1.4),
      );
    }
    // agent 消息渲染 markdown（模型输出默认 markdown 格式）
    // - selectable: true → 段落/代码块内可任意框选复制（Flutter 3.7 下
    //   SelectionArea 无法选择 flutter_markdown 输出的 RichText，故启用
    //   markdown 自带选择模式；跨段落一次性拖选不受支持）
    // - hover 显示「复制全文」按钮（跨段落整条复制兜底）
    return _buildMarkdownContent(message, textColor);
  }

  /// 构建 agent 消息的 markdown 内容：可选择文本 + hover「复制全文」按钮
  Widget _buildMarkdownContent(ChatMessage message, Color textColor) {
    final bool streaming = message.isStreaming;
    return MouseRegion(
      onEnter: (_) {
        setState(() {
          _hoverCopy = true;
        });
      },
      onExit: (_) {
        setState(() {
          _hoverCopy = false;
        });
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // selectable: true → 段落/代码块内可框选复制（跨段落复制用「复制全文」）
          // 正文字重 w500 + 行距 1.55：跟工具行 / 思考行（12.5 常规体）拉开层次，
          // 模型的话一眼就是「正文」，工具与思考是「脚注」。
          MarkdownBody(
            data: message.content,
            selectable: true,
            styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
              p: TextStyle(
                fontSize: 14,
                height: 1.55,
                fontWeight: FontWeight.w500,
                color: textColor,
              ),
            ),
          ),
          // 流式输出中不显示复制按钮（内容仍在变化）
          if (_hoverCopy && !streaming)
            Positioned(
              top: -8,
              right: -8,
              child: _buildCopyButton(),
            ),
        ],
      ),
    );
  }

  /// 「复制全文」按钮：复制原始 markdown 文本到剪贴板
  Widget _buildCopyButton() {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface,
      elevation: 2,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: _copyFullText,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.copy, size: 12, color: cs.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(
                '复制',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 复制消息全文（原始 markdown 内容）
  Future<void> _copyFullText() async {
    await Clipboard.setData(ClipboardData(text: widget.message.content));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已复制全文'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  /// 构建时间戳（小号灰色文字，含日期：MM-dd HH:mm，跨年补年份）
  Widget _buildTime(ChatMessage message, bool isUser) {
    final DateTime t = message.timestamp;
    final String mm = t.month.toString().padLeft(2, '0');
    final String dd = t.day.toString().padLeft(2, '0');
    final String hour = t.hour.toString().padLeft(2, '0');
    final String minute = t.minute.toString().padLeft(2, '0');
    final String date = t.year == DateTime.now().year
        ? '$mm-$dd'
        : '${t.year}-$mm-$dd';
    final Color color = isUser
        ? Theme.of(context).colorScheme.onSurfaceVariant
        : Theme.of(context).colorScheme.outline;
    return Text(
      '$date $hour:$minute',
      style: TextStyle(fontSize: 11, color: color),
    );
  }

  /// 构建附件卡片列表
  Widget _buildAttachments() {
    final List<Attachment> attachments = widget.message.attachments!;
    final cs = Theme.of(context).colorScheme;
    // 气泡已中性化（用户 2026-11-08）：附件卡跟随气泡文字色，用中性描边/底色，
    // 不再用 onPrimary 的半透明绿。
    final Color textColor = cs.onSurface;
    final Color subColor = cs.onSurfaceVariant;
    final Color borderColor = Theme.of(context).dividerColor;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: attachments.map((Attachment a) {
        final Widget card = Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.insert_drive_file, size: 16, color: subColor),
              const SizedBox(width: 6),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      a.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: textColor,
                      ),
                    ),
                    Text(
                      _formatSize(a.size),
                      style: TextStyle(fontSize: 10, color: subColor),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
        // 附件在**工作空间**里的相对路径（发送时上传得到，核心把它写进提示词）。
        // 只是提示，不占版面；旧数据没有该字段时不显示。
        if (a.path.isEmpty) return card;
        return Tooltip(message: '工作空间路径：${a.path}', child: card);
      }).toList(),
    );
  }

  /// 格式化文件大小
  String _formatSize(int bytes) {
    if (bytes <= 0) return '';
    const List<String> units = <String>['B', 'KB', 'MB', 'GB'];
    double size = bytes.toDouble();
    int unitIdx = 0;
    while (size >= 1024 && unitIdx < units.length - 1) {
      size /= 1024;
      unitIdx++;
    }
    return '${size.toStringAsFixed(size >= 10 ? 0 : 1)} ${units[unitIdx]}';
  }
}

/// 内联提问卡片（AskUserQuestion 的非阻塞展示）
///
/// 替代全屏遮罩对话框：提问以卡片形式插入消息流，答题者仍可滚动查看
/// 模型最近输出与右侧信息后再做决策。
///
/// **多问题**（用户 2026-10-04）：一次提问可以有 N 道题。
/// - **单问**保持原行为：点选项 = 立即作答；输入后回车 / 点发送 = 作答。
/// - **多问**：每题各自点选选项或自由输入，底部「提交全部回答」**一次性**回传
///   全部答案（未作答的题按空串回传，核心/界面显示为「未作答」），按钮旁标注
///   还有几题未答。
class _AskQuestionCard extends StatefulWidget {
  final ChatMessage message;
  final void Function(String messageId, List<String> answers)? onAnswer;

  const _AskQuestionCard({required this.message, this.onAnswer});

  @override
  State<_AskQuestionCard> createState() => _AskQuestionCardState();
}

class _AskQuestionCardState extends State<_AskQuestionCard> {
  /// 每题一个输入框（键 = 题号，从 0 起）。
  final Map<int, TextEditingController> _controllers =
      <int, TextEditingController>{};

  /// 每题点选的选项（键 = 题号）；自由输入**优先于**点选。
  final Map<int, String> _picked = <int, String>{};

  int get _count => widget.message.questions.length;

  TextEditingController _controllerAt(int index) =>
      _controllers.putIfAbsent(index, TextEditingController.new);

  @override
  void dispose() {
    for (final TextEditingController controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// 逐题收集答案：自由输入优先，其次点选的选项，都没有 = 空串（未作答）。
  List<String> _collectAnswers() {
    final List<String> answers = <String>[];
    for (int i = 0; i < _count; i++) {
      final String typed = _controllerAt(i).text.trim();
      answers.add(typed.isNotEmpty ? typed : (_picked[i] ?? ''));
    }
    return answers;
  }

  bool get _enabled => !widget.message.answered && widget.onAnswer != null;

  /// 单问：点选项立刻作答（与"只支持单问题"时期逐字一致）。
  void _answerSingle(String answer) {
    if (!_enabled || answer.isEmpty) return;
    widget.onAnswer!(widget.message.id, <String>[answer]);
  }

  /// 单问：自由输入发送。
  void _submitSingle(int index) {
    if (!_enabled) return;
    final String text = _controllerAt(index).text.trim();
    if (text.isEmpty) return;
    widget.onAnswer!(widget.message.id, <String>[text]);
  }

  /// 多问：一次交齐（未作答项传空串）。
  void _submitAll() {
    if (!_enabled) return;
    widget.onAnswer!(widget.message.id, _collectAnswers());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ChatMessage message = widget.message;
    final bool multi = message.hasMultipleQuestions;
    final bool enabled = _enabled;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: cs.primary, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.help_outline, size: 16, color: cs.primary),
                const SizedBox(width: 6),
                Text(
                  message.answered
                      ? '已提交你的选择'
                      : multi
                      ? 'Agent 需要你的输入（共 ${message.questions.length} 题）'
                      : 'Agent 需要你的输入',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: cs.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (int i = 0; i < message.questions.length; i++)
              _buildQuestion(context, i, multi),
            if (message.answered &&
                message.answers.any((String a) => a.trim().isNotEmpty))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (
                      int i = 0;
                      i < message.questions.length;
                      i++
                    )
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          multi
                              ? '第 ${i + 1} 题：${_answerAt(message, i)}'
                              : '已回答：${_answerAt(message, i)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (multi && !message.answered) ...<Widget>[
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  FilledButton(
                    onPressed: enabled ? _submitAll : null,
                    child: const Text('提交全部回答'),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _unansweredCount() == 0
                        ? '已全部作答'
                        : '还有 ${_unansweredCount()} 题未作答',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 一道题：题面 + 选项（单问点选即作答，多问点选为选中）+ 自由输入。
  ///
  /// 已作答的卡片不再显示输入框（答案在卡片底部逐题列出）。
  Widget _buildQuestion(BuildContext context, int index, bool multi) {
    final cs = Theme.of(context).colorScheme;
    final ChatMessage message = widget.message;
    final AskQuestionItem item = message.questions[index];
    final bool enabled = _enabled;
    return Padding(
      padding: EdgeInsets.only(top: index == 0 ? 0 : 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            multi ? '${index + 1}. ${item.question}' : item.question,
            style: TextStyle(fontSize: 14, color: cs.onSurface, height: 1.4),
          ),
          if (item.options.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            for (final String option in item.options)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: !enabled
                        ? null
                        : () {
                            if (!multi) {
                              // 单问：点选项立刻作答（老行为）
                              _answerSingle(option);
                              return;
                            }
                            setState(() {
                              if (_picked[index] == option) {
                                _picked.remove(index);
                              } else {
                                _picked[index] = option;
                              }
                            });
                          },
                    style: OutlinedButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          _isPicked(message, index, option, multi)
                              ? Icons.check_circle_outline
                              : Icons.radio_button_unchecked,
                          size: 16,
                          color: cs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            option,
                            style: TextStyle(fontSize: 13, color: cs.onSurface),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
          if (!message.answered) ...<Widget>[
            const SizedBox(height: 8),
            TextField(
              controller: _controllerAt(index),
              enabled: enabled,
              maxLines: 2,
              minLines: 1,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) =>
                  multi ? _submitAll() : _submitSingle(index),
              decoration: InputDecoration(
                hintText: multi
                    ? '或直接输入第 ${index + 1} 题的答案…'
                    : '或直接输入回答…',
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: multi
                    ? null
                    : IconButton(
                        onPressed: enabled ? () => _submitSingle(index) : null,
                        icon: const Icon(Icons.send, size: 18),
                        tooltip: '发送',
                      ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 某个选项是否处于"选中/命中"状态（多问看当前点选，单问看已作答的答案）。
  bool _isPicked(
    ChatMessage message,
    int index,
    String option,
    bool multi,
  ) {
    if (!multi) {
      return message.answered && _answerAt(message, index) == option;
    }
    return _picked[index] == option;
  }

  String _answerAt(ChatMessage message, int index) {
    if (index >= message.answers.length) return '（未作答）';
    final String text = message.answers[index].trim();
    return text.isEmpty ? '（未作答）' : text;
  }

  /// 多问还有几题没答（底部提交按钮旁的提示）。
  int _unansweredCount() =>
      _collectAnswers().where((String a) => a.isEmpty).length;
}
