import 'dart:io';

import 'package:path/path.dart' as p;

/// 每个 agent 的**私有状态目录**（工作空间相对路径，`<agent>` 是 **agent id**）。
///
/// 为什么需要它：团队成员与 leader **共享同一个工作目录**（[TeamWorkspace]），但 `.self/`
/// 装的都是"这个 agent 自己的东西"——系统提示词、规范文件、规范附带文档、超长工具结果的
/// 落点、活动日志、计划/侦察笔记……共享一个根就会互相覆盖（实测：成员的
/// `[start(成员)]/[done(成员)]` 与 leader 的条目混进同一个 `.self/activity.log`）。
/// 因此在共享根下按 agent 分栏：
///
/// ```
/// <共享工作目录>/
///   <项目文件…>            所有成员共用（leader 与成员看到同一份）
///   .input/<日期>/…        共享输入（附件上传落点）
///   .tree/<agent_id>/.self/   ← 本函数：这个 agent 的私有状态
/// ```
String privateSelfDir(String agentId) => '.tree/$agentId/.self';

/// 把**模型口径**的相对路径翻译成真实的工作空间相对路径：只翻 `.self` 这一族。
///
/// 内置规范与工具提示里写的都是 `.self/plan/…`、`.self/results/…`（模型的口径），
/// 磁盘上却必须按 agent 分栏，两者由本函数单向翻译：
/// - 入参（读/写/编辑/搜索/列目录/resolve）`.self/…` → `.tree/<agent_id>/.self/…`；
/// - 其它路径（含已经是真实路径的 `.tree/<agent_id>/.self/…`）原样返回 ⇒ **两种写法都是
///   合法入参**，工具结果里回显的真实路径可以继续拿来用。
///
/// 只做"前缀替换"、不做 `..` 解析：越界判定仍然全部交给 IO 的 `resolve`。
String mapPrivatePath(String relativePath, String agentId) {
  String path = relativePath.trim();
  while (path.startsWith('./')) {
    path = path.substring(2);
  }
  if (path == '.self') return privateSelfDir(agentId);
  const String prefix = '.self/';
  if (path.startsWith(prefix)) {
    return '${privateSelfDir(agentId)}/${path.substring(prefix.length)}';
  }
  return relativePath;
}

/// 一次性迁移：把旧的 `<工作空间>/.self` 搬到 `.tree/<agent_id>/.self`（幂等）。
///
/// 为什么需要：2026-10-02 起私有状态按 agent 分栏，旧工作空间的 `.self` 里可能装着
/// 用户改过的系统提示词、自定义规范、计划笔记（这些**只在本机**，丢了就找不回来）。
/// 只在**目标还不存在**时搬；搬不动（跨卷 / 占用）就记日志、不阻断启动。
///
/// 只应由"该工作空间的主人"（团队 TOP）调用：团队成员与 leader 共享目录，旧 `.self`
/// 不可能是成员留下的（成员以前有自己的目录，那份留在原地）。
void migrateLegacySelfDir({
  required String workspaceDir,
  required String agentId,
  void Function(String message)? log,
}) {
  final Directory legacy = Directory(p.join(workspaceDir, '.self'));
  final Directory target = Directory(
    p.join(workspaceDir, '.tree', agentId, '.self'),
  );
  if (!legacy.existsSync() || target.existsSync()) return;
  try {
    target.parent.createSync(recursive: true);
    legacy.renameSync(target.path);
    log?.call('私有状态已迁移到 ${privateSelfDir(agentId)}（$workspaceDir）');
  } catch (error) {
    log?.call('私有状态迁移失败（$workspaceDir）：$error');
  }
}
