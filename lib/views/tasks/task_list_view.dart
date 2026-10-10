// 任务列表 / 总览 —— OAS 的**唯一调度控制台**
//
// ## 设计依据
//
// 严格按 `docs/task-list-prototype.html`(已确认的设计稿)与
// `docs/architecture.md` §5.2 / §5.4 实现, **不沿用 OASX 原有的树状风格**
// (用户明确说"挺难用的")。
//
// ## 原型结构
//
//   tab「任务总览」= 监控面板
//     ├─ 批量操作   (多选 + 批量启停 + 搜索 + 过滤)
//     └─ 任务总览   (表格)
//
//   tab「任务列表（调度器）」= 唯一调度控制台
//     ├─ 全局设置   (循环模式 + 优先级依据)
//     ├─ 执行顺序   (拖拽排序 + 添加/删除**条目**)
//     └─ 预期执行流程(推算)
//
// ## 界面职责（架构文档 §5.2 定的，不可违反）
//
// | 页面 | 能做什么 | 不能做什么 |
// |---|---|---|
// | 任务总览 | 看状态/进度/下次运行、**批量**启停 | ❌ 单个任务的启停开关 |
// | 任务列表 | 排序、每行启停、**每行次数**、全部停止/只停列表、全局模式 | — |
//
// ★ 理由: `enable` 放两处必然出现"列表行开着却不跑"的静默矛盾。
//   所以**只有一个开关**(列表行), 但总览页**不隐藏**状态 ——
//   停用的行显示 `⚠ 配置中已停用`。
//
// ★ 目标次数**只在列表页可改**(用户决定); 总览页只读显示。
//
// ## 运行列表 = 有序**条目清单**（模型 B）
//
// 列表里可以混入控制条目, 按**效果**命名:
//
//   task   执行某个任务
//   rest   **全部停止** N 分钟(连定时任务一起停)
//   delay  **只停列表** N 分钟(定时任务照常)
//
// ★ `task` 条目**不阻塞**列表(未就绪就跳过); `rest`/`delay` **阻塞**列表,
//   生效后自动移除(用户看到的是"这一行消失了")。
//
// ★ 条目类型的值/效果名/说明/标志**全部从 `/schema` 的 `list.entry_kinds` 读** ——
//   前端不硬编码, 否则又是"同一知识多处"。
library task_list;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:oasx/api/api_client.dart';
import 'package:oasx/component/log/log_mixin.dart';
import 'package:oasx/component/log/log_widget.dart';
import 'package:oasx/model/script_model.dart';
import 'package:oasx/service/script_service.dart';
import 'package:oasx/service/task_prefs.dart';
import 'package:oasx/views/nav/view_nav.dart';
part '../../controller/task_list/task_list_controller.dart';
part './task_row_view.dart';
part './run_control_bar.dart';
part './queue_panel.dart';
// ★ #6: 任务完成汇报面板（用户新需求）—— 替换原来右侧常驻的原始日志
part './task_report_panel.dart';

class TaskListView extends StatefulWidget {
  const TaskListView({super.key, required this.scriptName});

  /// 配置名（账号名）。由调用方传入 —— **不依赖 `Get.arguments`**,
  /// 因为子组件（`RunControlBar` / `TaskRowView`）也要用它,
  /// 靠路由参数传递会在嵌套时变得脆弱。
  final String scriptName;

  @override
  State<TaskListView> createState() => _TaskListViewState();
}

class _TaskListViewState extends State<TaskListView> {
  /// ★ **不能**写成 `late final` —— 切换账号时 Flutter 会复用同一个 State
  ///   (同类型 widget、同位置), 此时 `initState` **不会重跑**,
  ///   `late final` 的 tag 与控制器就一直是**旧账号**的 ——
  ///   表现就是"两个账号共享同一个任务列表"(用户实测反馈)。
  ///
  ///   所以: tag 与控制器都要能跟着 `widget.scriptName` **重新解析**。
  String? _tag;
  TaskListController? _c;

  /// 右上角时钟的定时器。
  ///
  /// ★ 用户反馈"时间不刷新挺别扭" —— 之前显示的是后端 `/overview` 里
  ///   `at` 字段(取数那一刻的时间戳), **不是现在的时间**。
  ///   现在改用本地时钟, 每秒刷新。
  Timer? _clock;
  DateTime _now = DateTime.now();

  /// 搜索框的控制器 —— **受控**（踩过的坑）。
  ///
  /// ★ 以前搜索框只有 `onChanged`，没有 controller，于是：
  ///   * 清空搜索后列表不恢复（控制器里 query 清了，显示没复位）
  ///   * `恢复默认` 清了 query，**输入框里的旧文字还在**
  ///   * 重启后偏好里的 query 恢复了，但**输入框是空的**
  ///
  /// ★ 放在 `State` 里并在 `dispose` 释放 —— 不能在 `build()` 里新建
  ///   （`TextEditingController` 是 `ChangeNotifier`，每帧新建会泄漏监听器）。
  final _searchCtrl = TextEditingController();

  /// **左面板宽度**（右半栏是日志）—— 可拖拽调整。
  ///
  /// 用户要求"日志面板和别的面板占用大小应改为可以拖动调整的"。
  /// 拖完存进偏好 —— 下次打开保持（按账号隔离）。
  double _splitWidth = 700;

  static const _splitKey = 'split_left_width';

  @override
  void initState() {
    super.initState();
    _bindController();
    _loadSplit();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  /// 读回上次拖好的宽度（**在 `_bindController` 之后调**）。
  void _loadSplit() {
    try {
      final c = _c;
      if (c == null) return;
      final box = c.prefsStore.read('${widget.scriptName}:layout');
      final v = box[_splitKey];
      if (v is num && v > 0) _splitWidth = v.toDouble();
    } catch (_) {
      // 偏好读不到 -> 用默认宽度（不是错误）
    }
  }

  /// 松手时存盘（拖动过程中不写, 免得每帧一个 IO）。
  void _saveSplit() {
    try {
      final c = _c;
      if (c == null) return;
      final key = '${widget.scriptName}:layout';
      final box = c.prefsStore.read(key);
      box[_splitKey] = _splitWidth;
      c.prefsStore.write(key, box);
    } catch (_) {
      // 存不下只影响"下次是否记得", 不影响使用
    }
  }

  @override
  void didUpdateWidget(covariant TaskListView old) {
    super.didUpdateWidget(old);
    // 账号切换 -> 换控制器, 让面板显示**该账号自己**的列表
    if (old.scriptName != widget.scriptName) {
      _bindController(previous: old.scriptName);
      _loadSplit();
    }
  }

  @override
  void dispose() {
    _clock?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 解析/创建当前账号的控制器。
  ///
  /// ★ 在 `initState`/`didUpdateWidget` 里做, **不要**写在 `build()` 里 ——
  ///   `build()` 期间注册会触发 `onInit()`, 若 `onInit` 里同步 `update()`
  ///   就有重入风险。
  void _bindController({String? previous}) {
    final tag = 'tasks:${widget.scriptName}';
    // 旧账号的控制器不再需要 -> 删掉, 避免它继续轮询/占内存
    if (previous != null && previous.isNotEmpty) {
      final oldTag = 'tasks:$previous';
      if (Get.isRegistered<TaskListController>(tag: oldTag)) {
        Get.delete<TaskListController>(tag: oldTag, force: true);
      }
    }
    if (!Get.isRegistered<TaskListController>(tag: tag)) {
      Get.put(TaskListController(scriptName: widget.scriptName),
          tag: tag, permanent: false);
    }
    _tag = tag;
    _c = Get.find<TaskListController>(tag: tag);

    // ★ 注册"控制器 -> 输入框"的反向同步。
    //
    //   任何改动 `query` 的路径（清空 / 恢复默认 / 载入偏好 / 切账号）
    //   都会通过它把文字写回搜索框 —— 这就是"清空后显示不同步"的修法。
    //
    //   同一时刻只有一个视图, 所以用**单个回调**即可;
    //   换控制器时直接覆盖, 不必维护监听器列表。
    _c!.onQueryChanged = (q) {
      if (!mounted) return;
      if (_searchCtrl.text == q) return; // 同值不写, 免得把光标弄跳
      _searchCtrl.text = q;
    };
    // 立刻用控制器里的当前值初始化输入框
    _searchCtrl.text = _c!.query;
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final tag = _tag;
    if (c == null || tag == null) {
      // 理论上不会发生(initState 已绑定); 兜底免得空断言崩
      return const Center(child: CircularProgressIndicator());
    }
    final wide = MediaQuery.of(context).size.width >= 1100;
    // ★★ #6: 右侧常驻的**原始日志**换成**任务完成汇报**（用户新需求）★★
    //
    // 用户原话:
    //   "添加一个**任务完成汇报 tab**, 现在的日志属于原始日志, 应该**转移到
    //    单独界面**用来 debug, 当前日志位置替换为**任务完成汇报**的 tab"
    //
    // 所以:
    //   * **原来放日志的位置** -> `TaskReportPanel`（简报: 完成了哪些 / 哪些出错）
    //   * **原始日志** -> 移到单独的「运行日志」界面（见下面的运行日志按钮）

    return GetBuilder<TaskListController>(
      tag: tag,
      // ★ 三个 tab —— 「调度」·「执行队列」·「任务汇报」。
      //
      //   ⚠ `length` **必须**与下面 `TabBar` 的 tab 数一致,
      //     不匹配会**运行时崩**（我踩过一次: 改了 TabBar 忘了改 length）。
      builder: (_) => DefaultTabController(
        length: 3,
        child: Column(
          children: [
            // ★ 这里**不要**用 `Obx` 包 `RunControlBar` ——
            //   `Obx` 要求"回调里**直接**读到 Rx 变量", 而 `RunControlBar`
            //   是个 StatefulWidget, 它的 build 里只调了个普通方法,
            //   GetX 认为"没订阅任何可观察对象"就抛
            //   `improper use of a GetX` -> 整页白屏。
            //
            //   正确做法: 把 `Obx` 放到**真正读 Rx 的那个小部件**里
            //   （`RunControlBar` 内部的脚本状态区）。
            RunControlBar(controller: c),
            _header(context, c),
            const TabBar(
              tabs: [
                // ★ 用户要求「队列单独一个 tab」。
                //
                //   * **调度** —— 状态行 · 批量操作 · 全局开关 · 任务表格
                //     （Excel 式的批量查看与管理, **不改执行顺序**）
                //   * **执行队列** —— 调度器/正在运行 · 执行顺序（拖拽）·
                //     待执行 · 未到开放时间
                //   * **任务汇报** —— 完成了哪些 / 哪些出错（原日志位）
                Tab(text: '调度'),
                Tab(text: '执行队列'),
                Tab(text: '任务汇报'),
              ],
            ),
            Expanded(
              child: wide
                  // ★ 左右分栏宽度**可拖拽调整**（用户要求）
                  //
                  //   用 `Stack` + 一个 7px 宽的拖拽条, 而不是
                  //   `Row` + 固定 `SizedBox` —— 后者没法调。
                  //
                  //   范围限制在 [420, 可用宽度-320]: 任一侧都不会被拖没。
                  //   （用户说过"看不到就以为功能没了", 这点必须防住。）
                  ? LayoutBuilder(
                      builder: (_, box) {
                        final maxLeft =
                            (box.maxWidth - 320).clamp(420.0, box.maxWidth);
                        final left = _splitWidth.clamp(420.0, maxLeft);
                        return Stack(
                          children: [
                            Positioned.fill(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  SizedBox(
                                    width: left,
                                    child: TabBarView(
                                      children: [
                                        _ScheduleTab(
                                            c: c, searchCtrl: _searchCtrl),
                                        _QueueTab(c: c),
                                        TaskReportPanel(controller: c),
                                      ],
                                    ),
                                  ),
                                  const VerticalDivider(width: 1),
                                  // ★ 右侧 = 任务完成汇报（原日志位）
                                  Expanded(
                                      child: TaskReportPanel(controller: c)),
                                ],
                              ),
                            ),
                            // 拖拽条 —— 压在分界线上（左右各 3px 热区, 好点中）
                            Positioned(
                              left: left - 3,
                              top: 0,
                              bottom: 0,
                              width: 7,
                              child: MouseRegion(
                                cursor: SystemMouseCursors.resizeColumn,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.translucent,
                                  onHorizontalDragUpdate: (d) {
                                    setState(() {
                                      _splitWidth = (_splitWidth + d.delta.dx)
                                          .clamp(420.0, maxLeft);
                                    });
                                  },
                                  // 松手才存盘 —— 拖动过程中不要每帧写存储
                                  onHorizontalDragEnd: (_) => _saveSplit(),
                                  child: const SizedBox.expand(),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    )
                  // 窄屏: 退化成一列（否则会挤成一团）
                  : Column(
                      children: [
                        Expanded(
                          child: TabBarView(
                            children: [
                              _ScheduleTab(c: c, searchCtrl: _searchCtrl),
                              _QueueTab(c: c),
                              TaskReportPanel(controller: c),
                            ],
                          ),
                        ),
                        // ★ #6: 底部原来是**原始日志**, 现在换成**任务完成汇报**
                        //   （用户: "当前日志位置替换为任务完成汇报的 tab"）。
                        //   原始日志已移到「运行日志」单独界面（见 `_logsButton`）。
                        SizedBox(
                            height: 220,
                            child: TaskReportPanel(controller: c)),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部:刷新 / 可执行数 / 本地时钟。
  Widget _header(BuildContext context, TaskListController c) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          IconButton(
            tooltip: '刷新',
            onPressed: c.loading ? null : c.reload,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 4),
          // ★ 之前只显示 "15/54", 用户说"花了一段时间才发现这个意义" ——
          //   现在带文字标签。
          Tooltip(
            message: '可执行 = 现在就能跑的任务数\n'
                '共 = 当前筛选条件下的任务数',
            child: Text(
              '可执行 ${c.runnableCount} / 共 ${c.tasks.length}',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          if (c.loading)
            const Padding(
              padding: EdgeInsets.only(left: 12),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          const Spacer(),
          // ★★ #6: 「运行日志」入口 ★★
          //
          // 用户要求把**原始日志转移到单独界面**用来 debug:
          //   "现在的日志属于原始日志, 应该**转移到单独界面**, 用来 debug"
          //
          // 所以它不再常驻, 而是从这里打开一个**独立窗口**。
          IconButton(
            tooltip: '运行日志（原始日志，供 debug 用）',
            onPressed: () => _showRunLogs(context, c),
            icon: const Icon(Icons.article_outlined, size: 18),
          ),
          // ★ 本地时钟(每秒刷新), 不再用后端取数时刻的时间戳
          Text(
            '${_two(_now.hour)}:${_two(_now.minute)}:${_two(_now.second)}',
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ],
      ),
    );
  }

  /// 打开**原始运行日志**（独立窗口, 供 debug）。
  ///
  /// ★ 为什么不放 tab 里: 用户明确说日志是"**原始日志**", 应当
  ///   "**转移到单独界面**用来 debug" —— 而原本那个位置要留给
  ///   **任务完成汇报**（给人看的简报）。
  ///
  /// ★ 复用同一个 `LogWidget`: key 用 `c.script` 而不是 `hashCode`,
  ///   账号切换时才会重建（否则会把两个账号的日志串起来）。
  Future<void> _showRunLogs(
      BuildContext context, TaskListController c) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 900,
          height: 620,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
                child: Row(
                  children: [
                    const Icon(Icons.article_outlined, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('运行日志 · ${c.script}',
                          style: Theme.of(ctx).textTheme.titleMedium),
                    ),
                    Tooltip(
                      message: '这是**原始日志**，供排查问题用；\n'
                          '日常看「任务汇报」就够了',
                      child: Icon(Icons.help_outline,
                          size: 16,
                          color: Theme.of(ctx).disabledColor),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: LogWidget(
                  key: ValueKey('log-${c.script}'),
                  controller: c,
                  title: '运行日志',
                  enableCollapse: false,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _two(int v) => v < 10 ? '0$v' : '$v';
}

// ============================================================ tab 1: 调度面板

/// **调度面板** —— 统一控制台的主视图。
///
/// ## 相对 v1 的变化（用户要求"合并", 不要两套监控）
///
/// * 这里是**唯一的**任务表格（原「总览 tab」+「任务列表 tab」的表格合并）
/// * **次数可以直接改**（原来总览只读、列表才能改 —— 现在只有一处）
/// * 顶部放**脚本进程开关**（进程级硬停; 调度级软停在运行控制条）
/// * **执行顺序**移到 tab 2（拖拽排序 + 全局设置）
/// * **实时监控**移到 tab 3（正在运行 / 待执行 / 等待中）
///
/// ## 与「执行顺序」的关系（两条独立的顺序）
///
/// | 顺序 | 在哪 | 影响调度吗 |
/// |---|---|---|
/// | **执行顺序**（运行列表）| 本页, 拖拽 | ✅ **是** |
/// | **列表排序**（表格列）| 本页, 点表头 | ❌ 否, 只影响显示 |
///
/// ## 混入两个 mixin
///
/// * `_GlobalPanelMixin` -> `_globalPanel`（全局设置）
mixin _GlobalPanelMixin {
  TaskListController get c;

  /// 全局设置 —— 两个总开关 / 定时优先 / 休息穿插 / 队列跑空 / 优先级依据。
  Widget _globalPanel(BuildContext context) {
    final modes = c.modes;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _panelTitle(context, '全局设置', null),
            const SizedBox(height: 8),

            // ---------- 两个总开关 + 两者关系 ----------
            //
            // ★★ 这一段是补一个**重大遗漏** ★★
            //
            // 后端把两个总开关 + 定时优先 + 休息穿插全做完了, `/schema` 的
            // `global_fields` 也暴露了 —— 但前端**一个都没渲染**,
            // 于是它们永远停在默认值, 用户在界面上根本改不了。
            //
            // 标签与说明一律从 `/schema` 读（`c.globalFieldLabel`）,
            // 前端**不硬编码**字段名与文案。
            _switchRow(
              context,
              key: 'enable_fixed',
              value: c.enableFixed,
              fallbackLabel: '启用固定任务',
              onChanged: c.toggleEnableFixed,
            ),
            _switchRow(
              context,
              key: 'enable_timed',
              value: c.enableTimed,
              fallbackLabel: '启用定时任务',
              onChanged: c.toggleEnableTimed,
            ),
            const SizedBox(height: 4),
            // 定时任务到点时怎么跟固定任务抢
            Row(
              children: [
                SizedBox(
                  width: 168,
                  child: Text(c.globalFieldLabel('timed_priority', '定时任务优先级')),
                ),
                DropdownButton<String>(
                  value: c.timedPriorityChoices
                          .any((e) => '${e['value']}' == c.timedPriority)
                      ? c.timedPriority
                      : (c.timedPriorityChoices.isNotEmpty
                          ? '${c.timedPriorityChoices.first['value']}'
                          : null),
                  isDense: true,
                  items: [
                    for (final e in c.timedPriorityChoices)
                      DropdownMenuItem<String>(
                        value: '${e['value']}',
                        child: Text('${e['label']}'),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) c.setTimedPriority(v);
                  },
                ),
              ],
            ),
            _switchRow(
              context,
              key: 'rest_interleave',
              value: c.restInterleave,
              fallbackLabel: '休息时可穿插定时任务',
              onChanged: c.toggleRestInterleave,
            ),
            const Divider(height: 16),

            Wrap(
              spacing: 16,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // 队列跑空后 —— **后端真实支持**的字段
                // （原型的"跑完循环整表"后端没有, 见 controller 里的说明）
                if (c.queueEmptyChoices.isNotEmpty)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(c.queueEmptyLabel),
                      const SizedBox(width: 8),
                      DropdownButton<String>(
                        value: c.queueEmptyChoices
                                .any((e) => '${e['value']}' == c.whenQueueEmpty)
                            ? c.whenQueueEmpty
                            : '${c.queueEmptyChoices.first['value']}',
                        isDense: true,
                        items: [
                          for (final e in c.queueEmptyChoices)
                            DropdownMenuItem<String>(
                              value: '${e['value']}',
                              child: Text('${e['label']}'),
                            ),
                        ],
                        onChanged: (v) {
                          if (v != null) c.setWhenQueueEmpty(v);
                        },
                      ),
                    ],
                  ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('优先级依据'),
                    const SizedBox(width: 8),
                    DropdownButton<String>(
                      value: c.scheduleRule,
                      isDense: true,
                      items: [
                        for (final m in modes)
                          DropdownMenuItem<String>(
                            value: '${m['value']}',
                            child: Text('${m['label']}'),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) c.setScheduleRule(v);
                      },
                    ),
                  ],
                ),
                if (c.scheduleRule != c.listModeValue)
                  Chip(
                    label: Text('⚠ 顺序要生效需选「${c.listModeLabel}」'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 一个**全局布尔开关**的行（标签 + Switch + 说明）。
  ///
  /// 标签与说明都从 `/schema` 的 `global_fields` 读 ——
  /// 后端改名/改说明前端自动跟上, 前端不维护一份文案。
  Widget _switchRow(
    BuildContext context, {
    required String key,
    required bool value,
    required String fallbackLabel,
    required Future<void> Function() onChanged,
  }) {
    final help = '${c.globalField(key)['help'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.globalFieldLabel(key, fallbackLabel)),
                if (help.isNotEmpty)
                  Text(help,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: Theme.of(context).disabledColor,
                          )),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: c.busy ? null : (_) => onChanged(),
          ),
        ],
      ),
    );
  }
}

class _ScheduleTab extends StatelessWidget with _GlobalPanelMixin {
  const _ScheduleTab({required this.c, required this.searchCtrl});

  @override
  final TaskListController c;

  /// 搜索框的控制器 —— 由 `_TaskListViewState` 持有并释放。
  ///
  /// ★ 为什么从这里传进来而不是在这里 `new`: 这个类是 `StatelessWidget`,
  ///   自己 new 一个 `TextEditingController` 就没人 `dispose` ——
  ///   而且它会在每次重建时泄漏一个（`ChangeNotifier`）。
  final TextEditingController searchCtrl;

  @override
  Widget build(BuildContext context) {
    // ★★ **一个页面管完**（三轮用户反馈后的最终结构）★★
    //
    // 用户的意见依次是:
    //   1. "把功能加入旧总览就行" -> 合并成一个控制台
    //   2. "执行顺序和监控不能合在一起吗" -> 3 tab 减到 2
    //   3. "监控窗口和预期流程不应该是一种东西吗"
    //      + "待执行、等待中、正在运行……不应该是一个东西吗"
    //      -> **全部并进「执行队列」**（队列的第 0 项就是"正在运行"）
    //
    // 所以「调度」tab 从上到下:
    //
    //   1. **状态行**（紧凑: 进程状态 / 待执行数 / 等待中数 / 冷却数）
    //   2. **批量操作** —— 脚本进程开关 + 批量启停 / 运行一次 / 重置选中 /
    //      搜索 / 筛选 / 恢复默认
    //   3. **全局开关（顶部）** —— 两个总开关 / 定时优先 / 休息穿插 /
    //      队列跑空 / 优先级依据
    //   4. **执行队列** —— 正在运行(第 0 项) + 待执行 + 等待中 +
    //      **预期执行流程**, 全是"接下来会跑什么"; 可拖拽改顺序;
    //      每行的次数/预期耗时/优先级可直接改
    //   5. **任务表格** —— Excel 式的**批量查看与管理**: 启停 / 运行一次 /
    //      多列排序 / 筛选（用户明确: **不改执行顺序**）
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        // 1. 紧凑状态行（进程状态 / 待执行数 / 等待中数 / 冷却数）
        _monitorStrip(context),
        const SizedBox(height: 8),
        // 2. 批量操作（脚本进程开关 + 批量启停 / 运行一次 / 重置选中 / 搜索 / 筛选）
        _bulkPanel(context),
        const SizedBox(height: 8),
        // 3. ★ 全局开关（**顶部** —— 用户要求, 不许埋在页底）
        _globalPanel(context),
        const SizedBox(height: 8),
        // 4. 任务表格 —— Excel 式的**批量查看与管理**（启停 / 运行一次 /
        //    多列排序 / 筛选）; **不改执行顺序**（用户明确过）。
        //
        //    ★ **执行队列已移到独立 tab**（用户要求）—— 顺序在那边拖。
        _tablePanel(context),
      ],
    );
  }

  /// **紧凑监控条** —— 一眼看出"在干什么"。
  ///
  /// ★ 数据来自 **WebSocket 推送**（`scriptModelMap`）, 是**实时**的。
  ///
  /// ★ 为什么紧凑（而不是原来那种四个可滚动观察窗）: 任务表格才是这一页的主角,
  ///   完整观察窗会占掉大半个屏幕。"待执行 / 等待中"的具体任务本来就能从
  ///   表格的「下次运行」列排出来。
  ///
  /// ★ `Obx` 必须包住**直接读 Rx** 的那一小块 —— 反面例子（回调里只构造组件、
  ///   没读 Rx）会让 GetX 抛 `improper use of a GetX` 并**整页白屏**（踩过）。
  Widget _monitorStrip(BuildContext context) {
    final svc = Get.find<ScriptService>();
    final sm = svc.scriptModelMap[c.script];
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        child: Obx(() {
          final state = sm?.state.value;
          final running = state == ScriptState.running;
          final cur = sm?.runningTask.value;
          final curName = (cur == null) ? '' : cur.taskName;
          final pending = sm?.pendingTaskList.length ?? 0;
          final waiting = sm?.waitingTaskList.length ?? 0;
          final cool = c.allTasks.where((t) => t['in_cooldown'] == true).length;
          return Wrap(
            spacing: 14,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    running ? Icons.play_circle : Icons.pause_circle_outline,
                    size: 18,
                    color: running ? Colors.green : Colors.grey,
                  ),
                  const SizedBox(width: 6),
                  // ★ 用中文标签 —— 直接 `'$state'` 会打印
                  //   `ScriptState.inactive` 这种**英文枚举名**（用户反馈过）。
                  Text(_stateLabel(state)),
                ],
              ),
              Text('正在运行: ${curName.isEmpty ? "（空闲）" : _zhName(curName)}'),
              Text('待执行 $pending'),
              Text('等待中 $waiting'),
              if (cool > 0)
                Chip(
                  avatar: const Icon(Icons.error_outline, size: 14),
                  label: Text('冷却中 $cool'),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
            ],
          );
        }),
      ),
    );
  }

  /// 命令名 -> 中文名（拿不到就回退命令名）。
  ///
  /// ★ WebSocket 推的 `taskName` 是**大驼峰命令名**（`DemonEncounter`）,
  ///   直接显示就是英文。中文名来自 `/overview` 的 `name_zh`
  ///   （源头是各任务的 `meta.py`）—— **前端不维护第二份**。
  String _zhName(String command) {
    final zh = c.zhNameOf(command);
    return zh.isEmpty ? command : zh;
  }

  /// **脚本进程** 状态 + 起停（进程级硬停）。
  ///
  /// ★ `Obx` 必须包住**直接读 Rx 变量**的那一小块。
  ///   这里 `sm.state.value` 就是直接读 —— 所以 GetX 能记录依赖。
  ///
  ///   反面例子（踩过）: 写 `Obx(() => SomeStatefulWidget(...))` ——
  ///   回调里只构造组件、没读 Rx, GetX 抛
  ///   "improper use of a GetX" 并导致**整页白屏**。
  Widget _scriptProcessRow(BuildContext context) {
    return Obx(() {
      final svc = Get.find<ScriptService>();
      final sm = svc.scriptModelMap[c.script];
      final running = sm?.state.value == ScriptState.running;
      return Row(
        children: [
          Icon(running ? Icons.play_circle : Icons.stop_circle,
              size: 18,
              color: running ? Colors.green : Theme.of(context).disabledColor),
          const SizedBox(width: 6),
          Text(running ? '脚本进程运行中' : '脚本进程已停止'),
          const SizedBox(width: 12),
          if (!running)
            FilledButton.icon(
              onPressed: c.busy
                  ? null
                  : () async {
                      await c.startScript();
                      await c.reload();
                    },
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('启动脚本'),
            ),
          if (running)
            Tooltip(
              message: '**结束子进程**（硬停）\n'
                  '与「暂停调度」不同 —— 那是软停，会跑完当前战斗',
              child: OutlinedButton.icon(
                onPressed: c.busy
                    ? null
                    : () async {
                        // 硬停会中断当前动作，所以要二次确认 ——
                        // 与"暂停调度"（安全点停）的危险程度不同。
                        final ok = await _confirmStopScript();
                        if (!ok) return;
                        await c.stopScript();
                        await c.reload();
                      },
                icon: const Icon(Icons.stop, size: 18),
                label: const Text('停止脚本'),
              ),
            ),
          const SizedBox(width: 8),
          Text('（进程级；调度级软停在任务列表页的运行控制条）',
              style: Theme.of(context).textTheme.labelSmall),
        ],
      );
    });
  }

  Future<bool> _confirmStopScript() async {
    final r = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('停止脚本进程？'),
        content: const Text('会**立即结束**脚本子进程。\n\n'
            '★ 如果正在战斗中，这一场会被打断（与「暂停调度」不同 ——'
            '那会跑完当前战斗再停）。\n\n'
            '确定继续吗？'),
        actions: [
          TextButton(
              onPressed: () => Get.back(result: false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Get.back(result: true), child: const Text('停止')),
        ],
      ),
    );
    return r == true;
  }

  Widget _bulkPanel(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---------- 脚本进程（进程级硬停）----------
            //
            // ★ 这块在 v1 里是放在**运行控制条**上的，v2 移到这里。
            //
            //   区别很重要:
            //   | 层级 | 做什么 | 在哪 |
            //   |---|---|---|
            //   | **进程级** | 起/停子进程（硬停）| 这里（俯视全局）|
            //   | **调度级** | 暂停调度 / 本轮跑完再停（软停，安全点）| 运行控制条 |
            //
            //   混在一起会让人以为"停止"和"暂停调度"是一回事。
            _scriptProcessRow(context),
            const Divider(height: 20),

            _panelTitle(context, '批量操作', '改的是 scheduler.enable（任务级长期开关）'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton(
                    onPressed: () => c.selectAll(), child: const Text('全选')),
                OutlinedButton(
                    onPressed: () => c.selectNone(), child: const Text('全不选')),
                OutlinedButton(
                    onPressed: () => c.selectInvert(), child: const Text('反选')),
                OutlinedButton(
                    onPressed: () => c.selectListOnly(),
                    child: const Text('只选列表里的')),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: c.selected.isEmpty || c.busy
                      ? null
                      : () => c.bulkApply(true),
                  child: Text('启用选中 (${c.selected.length})'),
                ),
                OutlinedButton(
                  onPressed: c.selected.isEmpty || c.busy
                      ? null
                      : () => c.bulkApply(false),
                  child: const Text('停用选中'),
                ),
                const SizedBox(width: 8),
                // ★ 「运行一次」与「重置选中」并排放在「停用选中」旁（用户要求）
                Tooltip(
                  message: '按选中顺序排队，**跑完当前任务/战斗后**依次插队运行\n'
                      '（不是立即打断 —— 那会卡在半途）',
                  child: OutlinedButton.icon(
                    onPressed:
                        c.selected.isEmpty || c.busy ? null : c.runOnceSelected,
                    icon: const Icon(Icons.playlist_play, size: 18),
                    label: Text('运行一次 (${c.selected.length})'),
                  ),
                ),
                Tooltip(
                  message: '把当前运行记录**归档**后从零重新计数\n'
                      '历史不会删除，仍可在归档里查看',
                  child: OutlinedButton.icon(
                    onPressed:
                        c.selected.isEmpty || c.busy ? null : c.resetSelected,
                    icon: const Icon(Icons.archive_outlined, size: 18),
                    label: const Text('重置选中'),
                  ),
                ),
                // 排队中的「运行一次」—— 显示出来并可取消
                if (c.runOnceQueue.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Tooltip(
                    message: '排队中（按点击顺序）:\n${c.runOnceQueue.join('\n')}',
                    child: InputChip(
                      avatar: const Icon(Icons.playlist_add_check, size: 16),
                      label: Text('排队中 ${c.runOnceQueue.length}'),
                      onDeleted: c.clearRunOnce,
                      deleteIcon: const Icon(Icons.close, size: 16),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                SizedBox(
                  width: 200,
                  child: TextField(
                    // ★ 受控: 用 `_TaskListViewState` 里的那个 controller
                    //   （它负责 dispose）。之前没有 controller,
                    //   导致"清空搜索后任务不恢复"。
                    controller: searchCtrl,
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search, size: 18),
                      hintText: '搜索任务名…',
                      border: const OutlineInputBorder(),
                      // ★ 有内容时才显示"清除" —— 一键让列表恢复
                      suffixIcon: c.query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear, size: 16),
                              tooltip: '清除搜索',
                              onPressed: () {
                                searchCtrl.clear();
                                c.clearQuery();
                              },
                            ),
                    ),
                    // 每击键 -> 控制器里**防抖**后再过滤（不阻塞输入）
                    onChanged: c.setQuery,
                    // 回车 -> 立刻应用（不等防抖）
                    onSubmitted: c.applyQueryNow,
                  ),
                ),
                FilterChip(
                  label: const Text('只看已启用'),
                  selected: c.onlyEnabled,
                  onSelected: (_) => c.toggleOnlyEnabled(),
                ),
                // 四个"只看 X"互斥（同时勾两个结果必为空，用户会以为坏了）
                FilterChip(
                  label: const Text('只看固定任务'),
                  selected: c.onlyFixed,
                  onSelected: (_) => c.toggleOnlyFixed(),
                ),
                FilterChip(
                  label: const Text('只看定时任务'),
                  selected: c.onlyTimed,
                  onSelected: (_) => c.toggleOnlyTimed(),
                ),
                FilterChip(
                  label: const Text('只看限时活动'),
                  selected: c.onlyLimited,
                  onSelected: (_) => c.toggleOnlyLimited(),
                ),
                // ★ 「恢复默认」放在最后 —— 它是个"退出"动作，
                //   放在筛选中间容易被误点（而且它有二次确认）。
                //
                //   用户要求: "同时可以恢复默认（有相关功能说明和弹窗提示）"。
                Tooltip(
                  message: '把排序与筛选恢复成默认值\n'
                      '（不影响任务配置、运行记录与执行顺序）',
                  child: TextButton.icon(
                    onPressed: c.busy ? null : c.restoreDefaults,
                    icon: const Icon(Icons.restart_alt, size: 16),
                    label: const Text('恢复默认'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// **任务表格**。
  ///
  /// ★ 用**预算高度**（`rowHeight * 行数 + 表头`）而不是 `Expanded` ——
  ///   因为现在整页是一个 `ListView`（用户要求把监控/顺序/设置合到一页）,
  ///   里面不能放 `Expanded`。
  ///
  ///   表格内部用 `ListView.builder`（懒加载, 只构建可见行）。
  ///   两层滚动不会打架: 外层滚到表格时, 手势先给内层（Flutter 的默认
  ///   手势竞技场行为）, 内层到底后再传给外层。
  ///
  /// ★ 行高固定 48（`itemExtent`）—— 让"预算高度"能算准,
  ///   同时避免 `ListView` 逐行测量（那也是卡顿来源之一）。
  static const double _rowHeight = 48;

  /// 表格最多显示多少行（超出则内部滚动）。
  static const int _maxVisibleRows = 12;

  Widget _tablePanel(BuildContext context) {
    if (c.tasks.isEmpty) {
      return const Card(
        margin: EdgeInsets.symmetric(horizontal: 12),
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: Text('没有符合条件的任务')),
        ),
      );
    }
    final rows = c.tasks.length;
    final visible = rows > _maxVisibleRows ? _maxVisibleRows : rows;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: _panelTitle(context, '任务表格（$rows 个）',
                '次数 / 优先级 / 预期耗时 直接改 · 表头可排序 · ↑↓ 调执行顺序'),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: _tableHeader(context),
          ),
          const Divider(height: 1),
          SizedBox(
            height: visible * _rowHeight,
            // ★ 懒加载 —— 只构建可见行
            child: ListView.builder(
              itemCount: rows,
              itemExtent: _rowHeight,
              itemBuilder: (_, i) => TaskRowView(
                key: ValueKey('${c.tasks[i]['name']}'),
                task: c.tasks[i],
                mode: TaskRowMode.overview,
                controller: c,
                // ★ 点任务行 -> 进该任务的**设置页**（用户要求）。
                //
                //   用 `openTaskSettings` 而不是 `switchContent`:
                //   后者开头有 `useablemenus` 白名单（只列侧边栏里有的任务）,
                //   点一个不在侧边栏的任务会被**静默忽略** ——
                //   用户看到的是"点了没反应", 很难排查。
                onTap: () => Get.find<NavCtrl>()
                    .openTaskSettings('${c.tasks[i]['command']}'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 表头 —— 与原型的 8 列 + 运行记录列。
  ///
  /// ★ 表头**可点击排序**（多列）。点同一列切换升降序，点别的列重置为升序。
  ///   当前排序列显示 ↑/↓，其余列显示淡色箭头提示"可点"。
  ///
  /// ★ 排序**只影响显示顺序**，不影响调度 —— 见 `TaskSorter` 的说明。
  Widget _tableHeader(BuildContext context) {
    final s = Theme.of(context).textTheme.labelMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const SizedBox(width: 28),
          // 与任务行的「队列」格对齐（只读 ✓/—）
          Expanded(
            flex: 8,
            child: Text('队列', style: s, textAlign: TextAlign.center),
          ),
          _sortableHeader(context, 'name', '任务', 22, s),
          _sortableHeader(context, 'category', '类型', 12, s),
          _sortableHeader(context, 'state', '状态', 18, s),
          _sortableHeader(context, 'target', '目标次数', 12, s),
          _sortableHeader(context, 'progress', '进度 / 存量', 12, s),
          _sortableHeader(context, 'next_run', '下次运行', 16, s),
          Expanded(flex: 12, child: Text('对方', style: s)),
          Expanded(flex: 12, child: Text('在列表', style: s)),
          _sortableHeader(context, 'priority', '优先级', 8, s),
          _sortableHeader(context, 'expected', '预期耗时', 12, s),
          _sortableHeader(context, 'record_runs', '运行记录', 20, s),
        ],
      ),
    );
  }

  /// 一个可点击排序的表头格。
  ///
  /// ★ 运行记录列点两下会依次切到「累计耗时」——
  ///   因为"运行记录"实际有两列可排（次数 / 耗时），
  ///   而表头只有一格宽。这样两个排序都能用到，且不用加宽表格。
  Widget _sortableHeader(BuildContext context, String column, String label,
      int flex, TextStyle? s) {
    final active = c.sortSpec.column == column;
    final next = column == 'record_runs' && active ? 'record_seconds' : column;
    return Expanded(
      flex: flex,
      child: InkWell(
        onTap: () => c.sortBy(next),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                style: s?.copyWith(
                  fontWeight: active ? FontWeight.bold : null,
                  color: active ? Theme.of(context).colorScheme.primary : null,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(
              active
                  ? (c.sortSpec.ascending
                      ? Icons.arrow_upward
                      : Icons.arrow_downward)
                  : Icons.unfold_more,
              size: 12,
              color: active
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).disabledColor,
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================ tab 2: 执行队列

/// **执行队列** tab（用户要求: 队列单独一个 tab）。
///
/// ## 这个 tab 里有什么 —— 都是"接下来会跑什么"
///
/// | 区块 | 性质 | 回答 |
/// |---|---|---|
/// | 调度器 / 正在运行 | 只读 | 调度器在跑吗 / 此刻在跑什么 |
/// | **执行顺序** | **可拖拽** | 我要按什么顺序跑（用户编排）|
/// | **待执行** | 只读 | 调度器**到点**了、马上要跑的 |
/// | **等待中** | 只读 | 还没到点的（定时 / 冷却）|
/// | 未编排 | 可加入 | 启用了但没进顺序列表的 |
///
/// ## ★ 为什么「执行顺序」和「待执行」要分开显示
///
/// 它们**看起来像**同一件事, 其实不是:
///
/// * **执行顺序** = `run_list` —— **用户**编排的清单（拖拽改）
/// * **待执行**   = 调度器**按时间**算出的"现在该跑谁"（`next_run <= now`）
///
/// 一个任务可以在顺序列表第 5 位, 同时因为定时到点而**立刻**进"待执行"。
/// 把两者混成一列会让人以为"拖了没用"。
///
/// ## ★ 我在这上面犯过的错（写下来防复犯）
///
/// 用户说过"执行队列和队列视图是一个东西吧, 合在一起" —— 我理解成
/// "把观察窗删掉, 只留一个紧凑条"。用户随即指出:
///
/// > 你这次是直接删除了监控，而不是合并
///
/// **删掉 ≠ 合并。** 观察窗（待执行 / 等待中）**必须保留** ——
/// 它们是队列的另一面, 不是冗余。
class _QueueTab extends StatelessWidget {
  const _QueueTab({required this.c});

  final TaskListController c;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        // 队列本体 —— 含 调度器/正在运行 · 执行顺序(拖拽) · 待执行 · 等待中
        //
        // ★ 这里**不放** `_monitorStrip` —— 它是 `_ScheduleTab` 的方法,
        //   而且队列自己的"待执行 N / 等待中 N"就在下面（那才是明细）。
        QueuePanel(controller: c),
      ],
    );
  }
}

// ============================================================ 共用

/// **`ScriptState` 的中文标签**。
///
/// ★ 为什么不直接 `'$state'`: Dart 的 `enum.toString()` 给出的是
/// `ScriptState.inactive` 这种**英文枚举名** ——
/// 界面上直接显示就是英文（用户反馈"监控中都是英文"）。
///
/// 映射放在**视图层**而不是 `ScriptState` 里: 那是模型层,
/// 不该塞界面文案（否则改文案要动模型）。
String _stateLabel(ScriptState? s) {
  switch (s) {
    case ScriptState.running:
      return '运行中';
    case ScriptState.inactive:
      return '已停止';
    case ScriptState.warning:
      return '异常';
    case ScriptState.updating:
      return '更新中';
    case null:
      return '未知';
  }
}

Widget _panelTitle(BuildContext context, String title, String? hint) {
  return Row(
    crossAxisAlignment: CrossAxisAlignment.baseline,
    textBaseline: TextBaseline.alphabetic,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleSmall),
      if (hint != null) ...[
        const SizedBox(width: 8),
        Flexible(
          child: Text(hint, style: Theme.of(context).textTheme.labelSmall),
        ),
      ],
    ],
  );
}
