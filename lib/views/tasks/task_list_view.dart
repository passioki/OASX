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

  /// ★★ ① 任务汇报**抽屉**是否展开（用户要求）★★
  ///
  /// 用户原话: "取消单独的 tab 和右半窗口, 改为**可以收纳的形式**,
  ///           就是**点一下从右边滑出来, 再点一下收进去**。"
  ///
  /// 所以「任务汇报」**不再是 tab**, 也不再常驻 —— 由这个开关控制右侧滑出的
  /// 面板（**全局生效**: 宽屏在右栏位置、窄屏在底部位置）。
  // ★★★ 简报**默认展开**（用户要求）★★★
  //
  // 用户原话: "**简报默认展开**"。
  // ★ 之前默认收起, 用户每次进来都要先点一下才看得到汇报。
  bool _reportOpen = true;

  /// 抽屉宽度（宽屏用）。`final` 就好 —— 目前不提供拖拽调整宽度。
  final double _reportWidth = 380;

  /// ★★ ① **任务汇报抽屉** ★★
  ///
  /// 只在 `_reportOpen` 为真时渲染（见 `build` 里的宽屏/窄屏两处），
  /// 带一个短促的**滑入动画**。
  Widget _reportDrawer(BuildContext context, TaskListController c) {
    return TweenAnimationBuilder<double>(
      // 展开时从 0 -> 1 播一次。收起是**直接移除**（不做反向动画）,
      // 免得和 `Stack` 的布局抢帧。
      key: const ValueKey('report-drawer'),
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      builder: (_, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: child,
      ),
      child: SizedBox(
        width: _reportWidth,
        child: Column(
          children: [
            // ★★★ 「运行日志」界面 + 它的按钮（用户要求）★★★
            //
            // 用户原话:
            //   "目前点击出现的**日志窗口也继续保留**，**按钮放在日志窗口右边**"
            //
            // ★ 布局: 左边是日志本体（`LogWidget`, 常驻显示最新日志），
            //   右边是那个按钮 —— 点它打开**独立窗口**（`_showRunLogs`,
            //   大屏 900x600, 供 debug）。★ 窗口本身完全没改。
            //
            // ⚠ 高度固定 150: 抽屉总高有限, 剩下的都给下面的任务汇报。
            SizedBox(
              height: 150,
              child: Row(
                children: [
                  Expanded(
                    child: LogWidget(
                      key: ValueKey('drawer-log-${c.script}'),
                      controller: c,
                      title: '运行日志',
                      enableCollapse: false,
                    ),
                  ),
                  // ★ 按钮**在日志窗口右边**（用户指定的位置）
                  Padding(
                    padding: const EdgeInsets.only(left: 2, right: 2),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          tooltip: '打开独立运行日志窗口（大屏，供 debug）',
                          onPressed: () => _showRunLogs(context, c),
                          icon: const Icon(Icons.open_in_new, size: 18),
                        ),
                        Text('日志',
                            style: Theme.of(context).textTheme.labelSmall),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // 下半: 任务完成汇报（给人看的简报）
            Expanded(child: TaskReportPanel(controller: c)),
          ],
        ),
      ),
    );
  }

  /// 顶部工具条的「简报」按钮 —— 切换抽屉（用户要求"再点一下收进去"）。
  Widget _reportToggle(BuildContext context) {
    return Tooltip(
      message: '任务完成汇报 —— 点一下从右边滑出来, 再点一下收进去。\n'
          '只报**完成了哪些 / 哪些出错**；原始日志在「日志」按钮里。',
      child: TextButton.icon(
        icon: Icon(
            _reportOpen ? Icons.chevron_right : Icons.assessment_outlined,
            size: 16),
        label: Text(_reportOpen ? '收起简报' : '简报'),
        onPressed: () => setState(() => _reportOpen = !_reportOpen),
      ),
    );
  }

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
      // ★ **两个** tab —— 「调度」·「执行队列」。
      //
      //   ★ ①: 「任务汇报」**不再是 tab** —— 用户原话:
      //     "取消单独的 tab 和右半窗口, 改为可以收纳的形式"
      //     它现在是右侧**可收纳抽屉**（`_reportOpen` + `_reportDrawer`）。
      //
      //   ⚠ `length` **必须**与下面 `TabBar` 的 tab 数一致,
      //     不匹配会**运行时崩**（我踩过一次: 改了 TabBar 忘了改 length）。
      //
      // ★★★ 页内那个 Tab 控制器 **也一起删了**（TabBar 已移除）★★★
      //
      // 用户裁定: "把两个 tab 放到任务列表下边，即**调度：[任务列表，
      // 执行队列]**，调度和任务列表互换名字"。
      // ★ 现在**导航由左侧树负责**, 页内不再有 TabController ——
      //   留着它就是"没人用的状态", 而且 `length: 2` 配 0 个 tab
      //   本身就是错的（虽然不崩, 但误导后来人）。
      builder: (_) => Column(
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
            // ★★★ 运行日志**单行条** —— 横在最上方（用户要求）★★★
            //
            // 用户原话: "**运行日志也拉出个小框横在最上方，只需要能看到
            //            一行就行**。目前点击出现的日志窗口也继续保留，
            //            按钮放在日志窗口右边。"
            //
            // ★ 定位: 页面**最顶**（运行控制条下方、页头上方）——
            //   用户选的是"页面最顶（紧贴标题栏下方）"。
            // ★ 只显示**最新一条**（`c.logs.last`）, 单行、不换行、可横向滚动。
            // ★ 完整日志仍走原来的**独立窗口**（`_showRunLogs`）, 两者并存。
            _logStrip(context, c),
            _header(context, c),
            // ★★★ 页内 `TabBar` **已删除**（用户裁定）★★★
            //
            // 用户原话:
            //   "现在是任务列表、脚本：[脚本，重启]，我要把**两个 tab 放到
            //    任务列表下边**，即**调度：[任务列表，执行队列]**，
            //    **调度和任务列表互换名字**"
            //
            // ★ 也就是说: 这两个区块**改由左侧导航树导航** ——
            //     调度
            //       ├ 任务列表   -> `selectedMenu == 'TaskListPanel'`
            //       └ 执行队列   -> `selectedMenu == 'QueuePanel'`
            //   而不是页内再放一层 tab（那样"导航"和"页内 tab"两套并存,
            //   用户点树上的「任务列表」和页内的 tab 会**互相打架**）。
            //
            // ★ 显示哪个区块由 `_bodyFor(selectedMenu)` 决定, 见下面。
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
                        // ★★ T9（审计修复）: clamp 必须**扣掉抽屉宽度** ★★
                        //
                        // ## 原来的 bug（超宽 61px -> RenderFlex 溢出）
                        //
                        // 原来写死"右侧留 320":
                        //     maxLeft = box.maxWidth - 320
                        // 但右栏已从"常驻汇报"改成 **380 宽的抽屉**
                        // （`_reportWidth = 380`）。于是当 `left` 触顶
                        // （`maxLeft`）且抽屉打开时:
                        //     总宽 = left + 1(VerticalDivider) + 380
                        //          = (maxWidth - 320) + 1 + 380
                        //          = maxWidth + **61**   -> **溢出**
                        //
                        // ★ 触发条件不是"罕见": 拖动条的上限**允许**拖到该区间,
                        //   而且**换了更窄的窗口**后, 之前存的偏好值就会触顶。
                        //
                        // ## 修法
                        //
                        // 把"右侧要留多少"做成**跟随抽屉开合**的变量:
                        //   * 抽屉开 -> 留 `380 + 1`（抽屉 + 分隔线）
                        //   * 抽屉关 -> 留 320（原来那个"别把自己拖没"的下限）
                        //
                        // ★ 同时给 `maxLeft` 加**下界保护**（`>= 420`）——
                        //   窄窗口下 `maxWidth - 380` 可能小于 420, 那样
                        //   `clamp(420, maxLeft)` 会因为 `lower > upper` 而**抛异常**。
                        const double minLeft = 420;
                        // ★★ 用户报的 bug（抽屉收起后右侧大片空白）★★
                        //
                        // ## 原来的错误
                        //
                        // 我原来写 `_reportOpen ? _reportWidth + 1 : 320.0`
                        // —— 抽屉**关着**时仍按 320 预留。但 `Row` 里
                        // **只有左栏**（抽屉没渲染, 见下面 `if (_reportOpen)`）
                        // -> `left` 被限在 `maxWidth - 320` -> **右边空出
                        // 一大片**（最多 320px）。
                        //
                        // ★ 用户原话: "任务汇报收起后页面右侧留有大片空白。
                        //   应该在收起时主页面填充页面。"
                        //
                        // ## 修法
                        //
                        // * **抽屉关** -> 左栏**占满**（`reserved = 0`,
                        //   于是 `maxLeft == maxWidth`, 由下面的
                        //   `Expanded` 兜住剩余空间）
                        // * **抽屉开** -> 留 `380 + 1`（抽屉 + 分隔线）
                        //
                        // ★ 拖动条只在抽屉打开时渲染, 所以关着时不需要
                        //   "留出可拖的范围"。
                        final double reserved =
                            _reportOpen ? _reportWidth + 1 : 0.0;
                        final double maxLeft = (box.maxWidth - reserved)
                            .clamp(minLeft, box.maxWidth);
                        final double left =
                            _splitWidth.clamp(minLeft, maxLeft);
                        return Stack(
                          children: [
                            Positioned.fill(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  // ★★ 抽屉**关** -> 主区域**占满** ★★
                                  //
                                  // 用户原话: "任务汇报收起后页面右侧留有大片
                                  //   空白。应该在收起时主页面填充页面。"
                                  //
                                  // ⚠ 不能写成 `SizedBox(width: _reportOpen ? left : null)`
                                  //   —— 在 `Row` 里 `width: null` 会让子项按
                                  //   **固有宽度**排, 内容会塌成窄条。
                                  //   **必须**用 `Expanded` 才真的"占满"。
                                  if (_reportOpen) ...[
                                    SizedBox(
                                      width: left,
                                      child: _bodyFor(context, c),
                                    ),
                                    // ★★ ①: 右半栏不再是常驻汇报 —— 改为**按需滑出的抽屉** ★★
                                    //   用户原话: "取消单独的 tab 和右半窗口,
                                    //             改为可以收纳的形式（点一下从右边滑出来）"
                                    //   开关在顶部工具条的「简报」按钮。
                                    const VerticalDivider(width: 1),
                                    _reportDrawer(context, c),
                                  ] else
                                    Expanded(
                                      child: _bodyFor(context, c),
                                    ),
                                ],
                              ),
                            ),
                            // 拖拽条 —— 压在分界线上（左右各 3px 热区, 好点中）
                            //
                            // ★ T9: **只在抽屉打开时**渲染。抽屉关着时右侧
                            //   没有面板, 这根条**没有任何东西可分**, 拖它
                            //   只会让人困惑（审计指出"无意义可拖"）。
                            if (_reportOpen)
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
                                      // ★ T9: 与上面的 `left` 用**同一个** clamp
                                      //   （`minLeft` / `maxLeft` 已扣掉抽屉宽）
                                      _splitWidth = (_splitWidth + d.delta.dx)
                                          .clamp(minLeft, maxLeft);
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
                          // ★ 同宽屏: 由 `_bodyFor` 按导航选择决定区块
                          //   （页内 TabBar 已删除 —— 见 `_bodyFor` 的说明）
                          child: _bodyFor(context, c),
                        ),
                        // ★★ ①: 底部不再是常驻汇报 —— 改为**可收纳抽屉** ★★
                        //   用户原话: "取消单独的 tab 和右半窗口, 改为可以收纳的形式,
                        //             就是点一下从右边滑出来, 再点一下收进去"
                        if (_reportOpen) ...[
                          const Divider(height: 1),
                          SizedBox(
                              height: 260,
                              child: _reportDrawer(context, c)),
                        ],
                      ],
                    ),
            ),
          ],
        ),
    );
  }

  /// ★★★ 当前显示哪个区块 —— **由左侧导航树决定**（用户裁定）★★★
  ///
  /// 用户原话:
  /// > "现在是任务列表、脚本：[脚本，重启]，我要把**两个 tab 放到任务列表
  /// >  下边**，即**调度：[任务列表，执行队列]**，**调度和任务列表互换名字**"
  ///
  /// 导航树里的三个键都进本页（见 `views/layout/content.dart`）:
  ///
  /// | 导航树 | 界面名 | 显示 |
  /// |---|---|---|
  /// | `'TaskList'` | ★ **调度** | 任务列表（默认）|
  /// | `'TaskListPanel'` | ★ **任务列表** | 状态行·批量操作·全局开关·任务表格 |
  /// | `'QueuePanel'` | **执行队列** | 调度器·执行顺序(拖拽)·待执行·等待中 |
  ///
  /// ★ 之前这里是个 `TabBar`（页内两个 tab）。★ 两者**并存会打架** ——
  ///   用户在树上点「任务列表」、页内 tab 却还停在「执行队列」。
  ///   现在**只有一套导航**（树），页内 TabBar 已删除。
  Widget _bodyFor(BuildContext context, TaskListController c) {
    // ⚠ 必须**订阅** `NavCtrl` —— 本页外层是 `GetBuilder<TaskListController>`,
    //   它只监听**任务控制器**；而"切哪个区块"是改 `NavCtrl.selectedMenu`。
    //   ★ 不订阅的话: 状态变了、界面纹丝不动（点了没反应）。
    //
    // ★★★ `GetX` 的 `init` **绝不能为 null**（实测踩到的真故障）★★★
    //
    // ## 原来的写法（有 bug）
    //
    // ```dart
    // init: Get.isRegistered<NavCtrl>() ? Get.find<NavCtrl>() : null,
    // ```
    //
    // 意图是"没注册就兜住"。但 `GetX` 4.6.6 的 `GetXState.initState` 是:
    //
    // ```dart
    // // rx_getx_widget.dart:70-79
    // final isRegistered = GetInstance().isRegistered<T>(tag: widget.tag);
    // if (widget.global) {            // ★ global 默认 true
    //   if (isRegistered) { ... } else {
    //     controller = widget.init;                       // = null
    //     GetInstance().put<T>(controller!, tag: ...);     // ★ _TypeError!
    //   }
    // }
    // ```
    //
    // -> `init == null` 且 `NavCtrl` 未注册时抛
    //    `_TypeError: Null check operator used on a null value`。
    //
    // ## 后果（用户报的现象）
    //
    // > "收放汇总任务页面时 UI 的互动不联动，**有的动了，有的没变**，
    // >   导致了**不该有的遮挡**。"
    //
    // ★ 这个 `GetX` 子树渲染**失败** -> 该区块不更新、而别的区块照常更新
    //   -> 看起来就是"部分联动" + 布局错位遮挡。
    //
    // ## 修法
    //
    // 先**确保 `NavCtrl` 已注册**，再 `Get.find` 取（**永远 non-null**）。
    // 这样既保住了"没注册也不崩"的意图，又不会给 `init` 传 null。
    if (!Get.isRegistered<NavCtrl>()) {
      Get.put(NavCtrl(), permanent: true);
    }
    return GetX<NavCtrl>(
      init: Get.find<NavCtrl>(),
      builder: (nav) {
        final sel = nav.selectedMenu.value;
        // ★★★ 默认显示「**执行队列**」（用户裁定: "设定 HOME 页为执行队列页"）★★★
        //
        // 为什么把默认从 `TaskListPanel` 换成 `QueuePanel`:
        //   * 用户要"开屏就是执行队列"
        //   * ★ 而开屏落在**哪个区块**由这里决定（`selectedMenu == 'TaskList'`
        //     时走**默认分支**）—— 若默认仍是 `_ScheduleTab`,
        //     那"首页=执行队列"只对**手动点**执行队列生效, 开屏还是任务列表。
        //   * 显式点「任务列表」(`TaskListPanel`) 仍显示任务列表, 不受影响。
        if (sel == 'TaskListPanel') {
          return _safePage(() => _ScheduleTab(c: c, searchCtrl: _searchCtrl));
        }
        // `'QueuePanel'`（显式点「执行队列」）与 `'TaskList'`（导航树「调度」
        // 入口）都显示**执行队列**。
        return _safePage(() => _QueueTab(c: c));
      },
    );
  }

  /// ★★★ 乙（续）：**页面级兜底** —— 任何渲染异常都不再白屏 ★★★
  ///
  /// ## 用户报的现象
  ///
  /// > "**执行顺序页面直接白屏了**"
  /// > "这个白屏是在**启动脚本之后**出现的，**脚本停止后不消失**，
  /// >  **点击清理队列就会消失**。"
  ///
  /// ## 为什么再加一层（行级兜底之外）
  ///
  /// ★ 我在 `QueueRow.build` 加了**行级** try/catch（脏条目不再炸整页）。
  /// ★ 但页面里还有**别的**渲染入口也可能被脏数据炸到：
  ///   `_profilesRow`（配置页）/ `_sortActions`（快捷排序 + 全局开关）/
  ///   `_monitorStrip` / `_bulkPanel` / `_tablePanel` …
  ///   —— 它们**都不在**那一层保护里。
  /// ★ 所以这里再包一层：★ **整页渲染失败也给提示**，绝不白屏。
  ///
  /// ⚠ 这只是"护栏"，**不是**修根因 —— 真正的脏数据源应另行修掉；
  ///   但护栏能保证"**用户至少看得到原因**"，而不是对着白屏。
  Widget _safePage(Widget Function() build) {
    try {
      return build();
    } catch (exc, stack) {
      debugPrint('TaskListView 页面渲染失败: $exc');
      debugPrint('$stack');
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 32, color: Colors.red.shade400),
              const SizedBox(height: 12),
              const Text('这一页渲染出错了（已避免白屏）',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              SelectableText('$exc',
                  style: const TextStyle(fontSize: 12),
                  textAlign: TextAlign.center),
              const SizedBox(height: 8),
              const Text('★ 完整堆栈已打到日志（debug 版会显示）\n'
                  '★ 可先「清空队列」恢复，然后把这段文字发给开发者',
                  style: TextStyle(fontSize: 12),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
  }

  /// ★★★ 运行日志**单行条** —— 横在页面最上方（用户要求）★★★
  ///
  /// 用户原话:
  /// > "**运行日志也拉出个小框横在最上方，只需要能看到一行就行**。
  /// >  目前点击出现的日志窗口也继续保留，按钮放在日志窗口右边。"
  ///
  /// ## 设计
  ///
  /// * **位置**: 页面**最顶** —— `RunControlBar` 下方、页头上方
  ///   （用户选的是"页面最顶（紧贴标题栏下方）"）。
  /// * **内容**: 只显示**最新一条**（`c.logs.last`），**单行**、
  ///   不换行、`softWrap: false`；长了就**横向可滚**（`TextOverflow.fade`
  ///   会在长路径上把关键信息切掉，所以用滚动）。
  /// * ★ **完整日志仍走独立窗口**（`_showRunLogs`）—— 两者并存，不替代。
  /// * ★ 用 `Obx` 订阅 `c.logs`：**新日志到达就刷**（不用等页面整体重建）。
  Widget _logStrip(BuildContext context, TaskListController c) {
    final scheme = Theme.of(context).colorScheme;
    return Obx(() {
      // ⚠ `logs` 是 `RxList<String>` 且元素**自带换行**（`addLog` 传进来就带
      //   `\n`）—— 必须先把换行去掉，否则"一行"会被撑成多行。
      final raw = c.logs.isNotEmpty ? c.logs.last : '';
      final line = raw.replaceAll('\n', ' ').replaceAll('\r', ' ').trim();
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        child: Row(
          children: [
            Icon(Icons.terminal, size: 13, color: scheme.outline),
            const SizedBox(width: 6),
            Expanded(
              child: line.isEmpty
                  ? Text('（暂无日志）',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.outline))
                  // ★ `reverse: true` —— 长行时**自动停在末尾**（最新那段），
                  //   这正是看日志时想看的。
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      reverse: true,
                      child: Text(
                        line,
                        maxLines: 1,
                        softWrap: false,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(fontFamily: 'monospace'),
                      ),
                    ),
            ),
          ],
        ),
      );
    });
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
          // ★★★ 「运行日志」按钮**已从这里挪走**（用户要求）★★★
          //
          // 用户原话: "目前点击出现的日志窗口也继续保留，**按钮放在日志窗口
          //            右边**"。
          //
          // ★ 所以它现在在右侧抽屉（简报）里、`LogWidget` 的右边 ——
          //   见 `_reportDrawer()`。★ 窗口本身（`_showRunLogs`）**完全不变**。
          // ★★ ① **任务汇报抽屉**的开关（用户要求"点一下滑出来, 再点一下收进去"）★★
          //
          //   「任务汇报」已不再是 tab、也不再常驻右栏 —— 只由这个按钮控制。
          _reportToggle(context),
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

  /// 全局设置 —— 两个总开关 / **调度优先级** / 休息穿插 / 队列跑空。
  ///
  /// ★ T1: 原来的「优先级依据」(`schedule_rule`) 下拉**已删除** ——
  ///   它与「调度优先级」(`priority_mode`) 语义重叠, 是"拖了没用"的根源。

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
        // ★★★ 3. 全局开关**已移走** -> 「执行队列」（用户要求）★★★
        //
        // 用户原话:
        //   "只需要把**全局开关移到执行队列**，然后把任务列表里的滚动条
        //    统一起来就行，现在滑动使用两个滚动条很难受"
        //
        // ★ 理由: 全局开关（启用临时/周期任务、休息穿插、队列跑空后）是
        //   **运行时**操作, 与「执行队列」里的快捷排序/执行顺序同属一类;
        //   留在"看表格"的页面里只会打断视线。
        // ★ 现在它在 `_QueueTab` 里, 与快捷排序**同一行**（省 5 行）。
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
              // ★★★ 片 5 (F2e): **删掉「正在运行: xxx」这一项** ★★★
              //
              // ## ★★ 用户裁定（最新）★★
              //
              // > "**执行队列那个正在运行个人突破不应该存在了啊**，
              // >  这个不符合咱们列表里流转[正在运行]状态的定义。"
              // > "**队首只是代表列表顺序第一个而已，但正在运行的可以使
              // >  列表里任意一个。**"
              //
              // ★ 所以"正在运行的是谁"**只在执行队列里那一行上显示**
              //   （「运行中」标记，见 `queue_panel.dart`），
              //   这里**不该再有第二个说法** —— 否则又会出现"两处口径"。
              //
              // ⚠ 前面那个 `Icon + _stateLabel(state)`（**脚本进程状态**）保留 ——
              //   那是"脚本有没有在跑"，与"哪一条在跑"是**两件事**。
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
                    child: const Text('选队列')),
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
                  label: const Text('只看临时任务'),
                  selected: c.onlyFixed,
                  onSelected: (_) => c.toggleOnlyFixed(),
                ),
                FilterChip(
                  label: const Text('只看周期任务'),
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

  /// 表格最多显示多少行（超出则内部滚动）。

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
          // ★★★ 去掉内层滚动 —— 全页**只留一个滚动条**（用户要求）★★★
          //
          // 用户原话:
          //   "把任务列表里的**滚动条统一起来**就行，现在滑动使用**两个滚动条
          //    很难受**"
          //
          // ## 根因（两个 `ListView` 嵌套, 各出一个滚动条）
          //
          // 原来这里是:
          //     SizedBox(height: visible * _rowHeight)   <- 限高（最多 12 行）
          //       └ ListView.builder                     <- ★ 滚动条 2（独立滚）
          // 外面还有 `_ScheduleTab` 的 ListView      -> ★ 滚动条 1（整页滚）
          // ★ 于是鼠标在表格上和在表格外, 滚的是**两个不同的东西**。
          //
          // ## 现在
          //
          // ★ 行**直接摊开**到外层 `ListView` 里 -> 只有外层那**一个**滚动条。
          // ⚠ 代价: 54 行全部构建（外层 `ListView` 仍会跳过屏幕外的）。
          //   这个量级不卡; 若将来真卡, 正解是 `CustomScrollView` +
          //   单个 `SliverList`（既懒加载又只有一个滚动条）—— 改动更大,
          //   真遇到再做。
          ...c.tasks.map((t) => TaskRowView(
                key: ValueKey('${t['name']}'),
                task: t,
                mode: TaskRowMode.overview,
                controller: c,
                // ★ 点任务行 -> 进该任务的**设置页**（用户要求）。
                //
                //   用 `openTaskSettings` 而不是 `switchContent`:
                //   后者开头有 `useablemenus` 白名单（只列侧边栏里有的任务）,
                //   点一个不在侧边栏的任务会被**静默忽略** ——
                //   用户看到的是"点了没反应", 很难排查。
                // ⚠ 这里必须用 `t`（闭包当前元素）—— **不能**再用 `c.tasks[i]`:
                //   摊开后没有 `i` 了（那是 `itemBuilder` 的参数）。
                onTap: () => Get.find<NavCtrl>()
                    .openTaskSettings('${t['command']}'),
              )),
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
    // ★★★ #6: 「快捷排序 + 全局开关 + 配置页」**吸顶**（用户要求）★★★
    //
    // ## 用户原话
    //
    // > "将执行顺序页面拎出来，**滚动时，上边的按钮和展示会一直存在**
    // >  而不是被滚动上去。"
    //
    // ★ "一直存在" = **吸顶**（pinned）, 不是"随内容滚"。上一轮我把它放进了
    //   `QueuePanel(header:)` —— 那是**跟随滚动**, 用户要的不是那个。
    //
    // ## 为什么现在是 `CustomScrollView`
    //
    // `SliverPersistentHeader(pinned: true)` 只能活在 `CustomScrollView` 里；
    // 而 `ReorderableListView` **自己就是一个滚动体**, 塞不进别人的 sliver
    // 序列。所以两件事一起换:
    //
    //   `ReorderableListView.builder` -> `SliverReorderableList`
    //     （见 `queue_panel.dart` 的说明: 拖动自动滚仍走
    //       `Scrollable.of(context)` = 本 `CustomScrollView`, 所以 #7 不退化）
    //
    // ## 结构
    //
    // ```
    // CustomScrollView
    //  ├─ SliverPersistentHeader(pinned: true)
    //  │    ├─ _profilesRow(...)        ← ★ #9 配置页 chips（切页/新建/管理）
    //  │    └─ _sortActions(...)        ← 快捷排序 + 全局开关
    //  ├─ SliverToBoxAdapter(标题/状态/分段条)   ← QueuePanel.slivers 提供
    //  ├─ SliverPadding(SliverReorderableList)  ← 队列行
    //  └─ SliverToBoxAdapter(尾部提示)
    // ```
    //
    // ⚠ 本 tab **绝不能**再套 `ListView`/`SingleChildScrollView` ——
    //   那就是"滚动套滚动", Flutter 会抛"垂直方向无界高度"（踩过）。
    return CustomScrollView(
      slivers: [
        // ★★★ 吸顶区（pinned: true）★★★
        SliverPersistentHeader(
          pinned: true,
          delegate: _StickyQueueHeader(
            child: Container(
              color: Theme.of(context).scaffoldBackgroundColor,
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
              // ★★★ 对照实验：撤掉 `ClipRect`（用户裁定「1 可以」）★★★
              //
              // ## ★★ 为什么要撤（我必须先排除"是我的修造成的"）★★
              //
              // ★ 用户实测报过：
              //   * `Bottom overflowed by 60 pixels`（纵）
              //   * `right lowered by 41 pixels`（横）
              //   * `TransformLayer … invalid matrix`（★ 我引入的）
              //   ★ 而且 —— **debug 版【也没有条纹】**、release 版**白屏**。
              //
              // ★ "没有条纹"**推翻了"这是 RenderFlex 溢出"的假设**
              //   （Flutter 在 debug 一定会给溢出画黑黄条纹）。
              // ★ 而 `ClipRect` 会**抑制**溢出报错 + **裁掉**内容
              //   ⇒ ★ 它**可能正是白屏的成因**（把内容裁成空白）。
              //
              // ## 实验设计（一刀切开"是我造成的"还是"本来就有"）
              //
              // ★ 撤掉 `ClipRect` ⇒ 回到"原样透传"：
              //   * 若白屏**消失** ⇒ ★ 确认是我的修造成的
              //   * 若白屏**仍在** ⇒ ★ 说明是别的地方，我换方向查
              //
              // ⚠ 撤掉后溢出报错会重新出现（debug 会画条纹）——
              //   ★ 这正是我们要的**诊断信息**。
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ★ #9: 执行顺序**配置页**（1/2/3/… + 新建 + 管理）
                  _profilesRow(context, c),
                  const SizedBox(height: 4),
                  // 快捷排序 + 全局开关（原来就在这一行）
                  _sortActions(context, c),
                ],
              ),
            ),
          ),
        ),
        // ★ 队列本体（行 + 标题/状态/尾部）—— 由 `QueuePanel` 提供那一组 sliver
        ...QueuePanel.slivers(context, c),
      ],
    );
  }

  // ============================================================ #9 配置页
  //
  // 用户原话:
  // > "添加**执行顺序配置页 1/2/3/……**，可以添加、删除和切换配置页"
  //
  // ★ 用户已确认的设计（照做, 不再问）:
  //   * 布局 **A** —— 吸顶区下面**单起一行** `配置页 ▪1▪ ▪2▪ ▪3▪ [＋新建] [⋯管理]`
  //   * 一页存什么 **甲** —— 队列 + 每任务调度 + **全局开关**（后端整页快照）
  //   * 前端三项偏好 **A** —— 按页隔离（controller 的 `_prefsKey`）
  //   * 初始状态 —— **当前执行顺序就是页1**（后端自动建）
  //   * 重命名 **需要**（后端 `PUT /queue/profiles/rename` 已就绪）

  /// 配置页 chips 行 —— `配置页 ▪1▪ ▪2▪ … [＋新建] [⋯ 管理]`。
  ///
  /// * `▪N▪` 实心 = **当前页**；单击 = 切页；★ **双击 = 改名**
  /// * `[＋新建]` = `POST /queue/profiles`（不传名字, 后端自动编号）
  /// * `[⋯ 管理]` = 重命名 / 删除（菜单, 窄屏也放得下）
  ///
  /// ⚠ 文案一律用**后端返回的 `message`** —— 不再自己拼一遍（两处必然漂移）。
  Widget _profilesRow(BuildContext context, TaskListController c) {
    final scheme = Theme.of(context).colorScheme;
    final list = c.queueProfiles;
    // ★ 后端旧版本没有这组端点 -> 列表为空。那时**不显示整行**
    //   （不显示"配置页"三个字比显示一个空壳好）。
    if (list.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('配置页',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                )),
        for (final p in list) _profileChip(context, c, p),
        const SizedBox(width: 2),
        Tooltip(
          message: '把**当前**执行顺序 + 启停/次数/全局开关存成一个新配置页，并切过去。',
          child: OutlinedButton.icon(
            onPressed: c.loading ? null : () => _createProfile(context, c),
            icon: const Icon(Icons.add, size: 15),
            label: const Text('新建'),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 30),
            ),
          ),
        ),
        Tooltip(
          message: '管理**当前**配置页：重命名 / 删除。',
          child: OutlinedButton.icon(
            onPressed: () => _manageProfiles(context, c),
            icon: const Icon(Icons.more_horiz, size: 15),
            label: const Text('管理'),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 30),
            ),
          ),
        ),
      ],
    );
  }

  /// 一枚页码 chip —— `▪N▪`（当前页实心 + 主色）。
  ///
  /// ★ 单击 = 切页；**双击 = 改名**（用户确认「需要重命名」）。
  ///   ⚠ 不能只用 `onDoubleTap`（单击会延迟 ~300ms 才响应, 体感"点了没反应"）
  ///   —— 所以两个手势都接上: 单击立即切页, 双击再改名。
  Widget _profileChip(
      BuildContext context, TaskListController c, Map<String, dynamic> p) {
    final scheme = Theme.of(context).colorScheme;
    final id = '${p['id']}';
    final name = '${p['name'] ?? id}';
    final active = p['active'] == true || id == c.queueProfileId;
    final count = (p['count'] as num?)?.toInt() ?? 0;

    return Tooltip(
      message: '配置页「$name」（$count 条队列）\n'
          '★ 一页 = 队列 + 每任务启停/次数 + 全局开关（整页快照）\n'
          '单击切换 · **双击改名**',
      child: InkWell(
        onTap: active ? null : () => _activateProfile(context, c, id, name),
        onDoubleTap: () => _renameProfile(context, c, id, name),
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            // ★ 实心 = 当前页（用户确认的视觉）
            color: active ? scheme.primary : null,
            border: Border.all(
                color: active ? scheme.primary : scheme.outlineVariant),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            name,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: active ? scheme.onPrimary : scheme.onSurfaceVariant,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                ),
          ),
        ),
      ),
    );
  }

  /// 切页 —— ★ 成功后 `activateQueueProfile` 内部会 `reload()`。
  Future<void> _activateProfile(BuildContext context, TaskListController c,
      String id, String name) async {
    final msg = await c.activateQueueProfile(id);
    if (!context.mounted) return;
    // ★ 提示直接用后端的 `message`（它已说明"上一页已自动保存"）
    Get.snackbar('已切到「$name」', msg,
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 4));
  }

  /// 新建一页（后端自动编号 + 立即切过去）。
  Future<void> _createProfile(BuildContext context, TaskListController c) async {
    final msg = await c.createQueueProfile();
    if (!context.mounted) return;
    Get.snackbar('已新建配置页', msg,
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 4));
  }

  /// 改名（后端 `PUT /queue/profiles/rename`）。
  Future<void> _renameProfile(BuildContext context, TaskListController c,
      String id, String name) async {
    final ctrl = TextEditingController(text: name);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名配置页'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 24,
          decoration: const InputDecoration(
            isDense: true,
            labelText: '页名',
            helperText: '比如「日常 / 周末 / 肝活动」—— 一眼知道那页是干什么的',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (next == null || next.isEmpty) return;
    final msg = await c.renameQueueProfile(id, next);
    if (!context.mounted) return;
    Get.snackbar('已改名', msg,
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 4));
  }

  /// `[⋯ 管理]` —— 重命名 / 删除**当前页**。
  Future<void> _manageProfiles(
      BuildContext context, TaskListController c) async {
    final id = c.queueProfileId;
    if (id.isEmpty) return;
    final name = c.queueProfileName;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('管理配置页「$name」'),
        children: [
          // ★★★ 片 5 (F3a): 「复制」—— 用户要求补的功能 ★★★
          //
          // ★ 用户原话：
          // > "目前对任务顺序配置页（歌单）的操作**少了一个复制**，
          // >  后续需要添加这个功能"
          //
          // ★ 说明写清"复制的是什么"：整页快照（队列 + 启停/次数 + 全局开关），
          //   与"新建"的区别只是模板来源（那一页 vs 当前状态）。
          // ★★★ 片 6 (F6a): 「从别的配置复制…」—— 跨配置转移 ★★★
          //
          // ★ 用户原话：
          // > "现在有的任务顺序**配置页只能在当前配置中实现复制**，
          // >  我想要可以**跨配置转移**。如**复制 test 配置页到[伴生树]中**这样的操作。"
          //
          // ★ 与「复制这一页…」的区别：
          //   复制这一页 = **本配置内**另存一页（后端会切过去）
          //   从别的配置复制 = **把别的配置的某一页搬过来**（后端**不切**目标当前页）
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'transfer'),
            child: const Text('从别的配置复制'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'copy'),
            child: const Text('复制这一页'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'rename'),
            child: const Text('重命名…'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child: const Text('删除这一页'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (!context.mounted || action == null) return;
    if (action == 'transfer') {
      await _transferProfile(context, c);
      return;
    }
    if (action == 'copy') {
      await _copyProfile(context, c, id, name);
      return;
    }
    if (action == 'rename') {
      await _renameProfile(context, c, id, name);
      return;
    }
    await _deleteProfile(context, c, id, name);
  }

  /// ★★★ 片 6: **从别的配置复制一页过来**（跨配置转移，F6b）★★★
  ///
  /// ★ 用户要求：
  /// > "现在有的任务顺序**配置页只能在当前配置中实现复制**，
  /// >  我想要可以**跨配置转移**。如**复制 test 配置页到[伴生树]中**这样的操作。"
  ///
  /// ★ 两步选择（源配置 -> 那一页）+ 可改新名；数据来自
  ///   `GET /queue_profile/transfer_sources`（**排除当前配置** ——
  ///   本配置内的复制由「复制这一页…」负责）。
  /// ★ 后端**不会**切换本配置的当前页 ⇒ 提示里要说清"新页已加入，
  ///   可在配置页列表里切过去"，否则用户会以为没生效。
  Future<void> _transferProfile(
      BuildContext context, TaskListController c) async {
    final List<Map<String, dynamic>> sources;
    try {
      sources = await c.loadTransferSources();
    } catch (e) {
      if (!context.mounted) return;
      Get.snackbar('读取失败', '拿不到其它配置页: $e',
          snackPosition: SnackPosition.BOTTOM);
      return;
    }
    if (!context.mounted) return;
    if (sources.isEmpty) {
      Get.snackbar('没有可复制的来源', '其它配置里还没有配置页（歌单）',
          snackPosition: SnackPosition.BOTTOM);
      return;
    }

    String? fromConfig = '${sources.first['config']}';
    final profilesOf = (String cfg) {
      final one = sources.firstWhere(
        (s) => '${s['config']}' == cfg,
        orElse: () => const <String, dynamic>{},
      );
      return ((one['profiles'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    };
    String? profileId;
    final nameCtrl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final profs = profilesOf(fromConfig ?? '');
          if (profileId == null ||
              !profs.any((p) => '${p['id']}' == profileId)) {
            profileId = profs.isEmpty ? null : '${profs.first['id']}';
          }
          final cur = profs.firstWhere(
            (p) => '${p['id']}' == profileId,
            orElse: () => const <String, dynamic>{},
          );
          // ★ 默认名 = 源页名字（用户可改）
          if (nameCtrl.text.isEmpty && cur.isNotEmpty) {
            nameCtrl.text = '${cur['name']}';
          }
          return AlertDialog(
            title: const Text('从别的配置复制一页'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('会把**别的配置**里的某一页（歌单）复制到**当前配置**'
                    '（${c.script}）里。\n'
                    '★ 复制的是**整页快照**：队列顺序 + 每任务启停/次数 + 全局开关。\n'
                    '★ **不会切换**当前配置正在用的页 —— '
                    '复制完可以在配置页列表里切过去。'),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: fromConfig,
                  decoration: const InputDecoration(
                      labelText: '来源配置', isDense: true),
                  items: [
                    for (final s in sources)
                      DropdownMenuItem(
                        value: '${s['config']}',
                        child: Text('${s['config']}'),
                      ),
                  ],
                  onChanged: (v) => setLocal(() {
                    fromConfig = v;
                    profileId = null;      // 换配置 -> 重选页
                    nameCtrl.text = '';
                  }),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: profileId,
                  decoration:
                      const InputDecoration(labelText: '配置页', isDense: true),
                  items: [
                    for (final p in profs)
                      DropdownMenuItem(
                        value: '${p['id']}',
                        child: Text('${p['name']}（${p['count']} 条）'),
                      ),
                  ],
                  onChanged: (v) => setLocal(() {
                    profileId = v;
                    final one = profs.firstWhere(
                      (p) => '${p['id']}' == v,
                      orElse: () => const <String, dynamic>{},
                    );
                    nameCtrl.text = '${one['name']}';
                  }),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                      labelText: '复制到当前配置后的名字', isDense: true),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: (fromConfig == null || profileId == null)
                    ? null
                    : () => Navigator.pop(ctx, true),
                child: const Text('复制'),
              ),
            ],
          );
        },
      ),
    );
    if (!context.mounted || ok != true) return;
    final msg = await c.transferQueueProfile(
      fromConfig: fromConfig!,
      profileId: profileId!,
      name: nameCtrl.text.trim(),
    );
    if (!context.mounted) return;
    Get.snackbar('跨配置复制', msg,
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 5));
  }

  /// ★ **复制当前页**（歌单）—— 片 5 / F3a。
  ///
  /// ★ 用户要求：
  /// > "目前对任务顺序配置页（歌单）的操作**少了一个复制**，
  /// >  后续需要添加这个功能"
  ///
  /// ★ 行为：以**这一页**的快照为模板，另存为一个**新页**并切过去
  ///   （默认名 = 「<原名> 副本」，可在弹窗里改）。
  /// ★ 与「新建」的区别：新建 = 存**当前状态**；复制 = 存**那一页**。
  Future<void> _copyProfile(BuildContext context, TaskListController c,
      String id, String name) async {
    final ctrl = TextEditingController(text: '$name 副本');
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('复制配置页「$name」'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('会以**这一页**为模板，另存为一个**新页**并切过去。\n'
                '复制的是**整页快照**：队列顺序 + 每任务启停/次数/优先级 + 全局开关。\n\n'
                '★ **不会影响原页**，也不改任何任务配置。'),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '新配置页名字',
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('复制'),
          ),
        ],
      ),
    );
    if (!context.mounted || newName == null) return;
    final msg = await c.copyQueueProfile(id);
    if (!context.mounted) return;
    // ★ 与"新建/改名/删除"同款提示（本项目统一：底部弹出）
    Get.snackbar('已复制配置页', msg,
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 4));
  }

  /// 删除当前页（★ 带二次确认 —— 后端保证至少留一页）。
  ///
  /// ★ 弹窗必须说清**两件事**:
  ///   1. 删的是**整页快照**（队列 + 启停/次数 + 全局开关）
  ///   2. **不删任何任务配置**, 随时可以再建一页
  Future<void> _deleteProfile(BuildContext context, TaskListController c,
      String id, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除配置页「$name」？'),
        content: const Text('会删掉这一页的**整页快照**'
            '（队列顺序 + 每任务启停/次数/优先级 + 全局开关）。\n\n'
            '★ **不会删除任何任务配置** —— 随时可以新建一页再编排。\n'
            '★ 至少要保留一个配置页。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final msg = await c.deleteQueueProfile(id);
    if (!context.mounted) return;
    Get.snackbar('已删除配置页', msg,
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 4));
  }

  /// ★ **快捷排序**（两个按钮）—— 与执行顺序同屏。
  ///
  /// ## 用户裁定（唯一依据）
  ///
  /// > "固定任务优先和定时任务优先以及**不能跨类别拖动太蠢了**。
  /// >  我只需要保持**可以自由拖动/改变执行顺序**就行, 固定任务优先和
  /// >  定时任务优先**直接作为一个快捷排序**就好, 而不是定义一些没有
  /// >  意义的不能跨类别拖动以及**单独的调度优先级**。"
  ///
  /// ★ **它是一个动作, 不是一个状态**: 点一下, 排一次, 不留状态。
  ///   排完之后用户可以**随意再拖**（跨类别也行）。
  /// ★★★ 全局开关 —— **紧凑一行**（用户要求: "合理摆放, 节省空间"）★★★
  ///
  /// 用户原话:
  /// > "**全局开关设置放到执行队列里, 和别的功能按钮合理摆放, 节省空间**"
  ///
  /// ## 改之前（一张独立大卡片, 约 5 行）
  ///
  /// ```
  /// ┌ 全局设置 ────────────────────────┐   <- 标题占一整行
  /// │ ☑ 启用临时任务                    │   <- 每个开关各占一行（3 个 = 3 行）
  /// │ ☑ 启用周期任务                    │
  /// │ ☐ 休息时可穿插周期任务             │
  /// │ ─────────────────────           │   <- 又一条 Divider
  /// │ 队列跑空后  [什么都不做 ▾]         │   <- 下拉再占一行
  /// └──────────────────────────────────┘
  /// ```
  ///
  /// ## 改之后（0 行额外高度 —— 并进 `_sortActions` 那一行）
  ///
  /// ★ 拆掉卡片的**壳**（标题 + `Divider` + `Column`），4 个控件压成一行:
  ///   `[⇄][⇄][⇄] 队列跑空后 [▾]`
  /// * 每个开关 = **一枚图标按钮**（开=实心 / 关=空心, 一眼看出状态）
  /// * 标签 + 完整说明 -> **`Tooltip` 悬停显示**
  ///   ★ 与用户"提示改悬停"的要求一致, 也正好把 5 行压成 0 行
  /// * 标签文案仍从 `/schema` 读（`c.globalFieldLabel`）—— 前端**不硬编码**
  ///
  /// ⚠ 用 `Wrap` 而不是 `Row`: 窄窗口时自动折行, 不会 `RenderFlex` 溢出。
  Widget _globalSwitchesInline(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // ---------- 两个总开关 + 休息穿插 ----------
        //
        // ★ 后端早已把这三个字段 + `/schema` 的 `global_fields` 都做完了,
        //   前端此前**一个都没渲染**（它们永远停在默认值, 用户改不了）。
        //   现在由这里渲染; 标签/说明一律从 `/schema` 读。
        _inlineSwitch(
          context,
          key: 'enable_fixed',
          value: c.enableFixed,
          fallbackLabel: '启用临时任务',
          onChanged: c.toggleEnableFixed,
        ),
        _inlineSwitch(
          context,
          key: 'enable_timed',
          value: c.enableTimed,
          fallbackLabel: '启用周期任务',
          onChanged: c.toggleEnableTimed,
        ),
        _inlineSwitch(
          context,
          key: 'rest_interleave',
          value: c.restInterleave,
          fallbackLabel: '休息时可穿插周期任务',
          onChanged: c.toggleRestInterleave,
        ),
        // 分组竖线（替代原来的 Divider, 但不占高度）
        Container(
          width: 1,
          height: 20,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          color: scheme.outlineVariant,
        ),
        // ---------- 队列跑空后 ----------
        //
        // 后端**真实支持**的字段（原型的"跑完循环整表"后端没有,
        // 见 `task_list_controller` 里的说明）。
        if (c.queueEmptyChoices.isNotEmpty) ...[
          // ★★★ ⑥: 「播放模式」**只留下拉**（用户裁定）★★★
          //
          // > "现在:  播放模式  [顺序（跑一次就停，回庭院） ▾]
          // >  改成:            [顺序 ▾]     ← **只留下拉，去掉括号内的解释说明**，
          // >  即使要说明也应该是指针**悬停**说明"
          //
          // ★ 所以这里**不再画「播放模式」这四个字** —— 只有下拉；
          //   label 与每个选项的解释都走 **Tooltip（指针悬停）**。
          // ★ 选项文字由后端给短词（`顺序` / `循环` / `乱序`），
          //   每个选项的 `hint` 也由后端给 ⇒ 改文案不用动前端。
          Tooltip(
            message: '${c.queueEmptyLabel}\n\n${c.queueEmptyHelp}',
            child: DropdownButton<String>(
              value: c.queueEmptyChoices
                      .any((e) => '${e['value']}' == c.whenQueueEmpty)
                  ? c.whenQueueEmpty
                  : '${c.queueEmptyChoices.first['value']}',
              isDense: true,
              underline: const SizedBox.shrink(),
              style: Theme.of(context).textTheme.bodySmall,
              items: [
                for (final e in c.queueEmptyChoices)
                  DropdownMenuItem<String>(
                    value: '${e['value']}',
                    // ★ 每个选项**各自**的悬停说明（也来自后端）
                    child: Tooltip(
                      message: '${e['hint'] ?? e['label']}',
                      child: Text('${e['label']}'),
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v != null) c.setWhenQueueEmpty(v);
              },
            ),
          ),
          // ★★★ P-3b: 只在「队列循环」时显示 —— 循环轮数 + 重置计数 ★★★
          //
          // ## 用户裁定
          //
          // > "我觉得选中后应该加一个**跑几次**的额外输入框, **0代表一直跑**,
          // >   **1、2……代表跑几次**。"
          //
          // > "如果要重跑这几次循环要怎么设置呢，我没想好，
          // >  是不是得有个**手动重置计数到设定值的按钮**"
          // > -> 用户选 **乙**: 加按钮
          //
          // ★ 为什么只在这个模式下显示: 轮数**只对 `loop` 有意义** ——
          //   其它模式（回庭院/关游戏）没有"轮"的概念, 显示了只会让人困惑。
          if (c.isQueueLoop) ...[
            const SizedBox(width: 10),
            Tooltip(
              message: '${c.loopTimesLabel}\n'
                  '0 = **一直跑**；1、2…… = 循环几轮后停下（回庭院待命）。\n'
                  '★ 已跑 ${c.loopRoundsDone} 轮（存盘, 重启不丢）。',
              child: Text('${c.loopTimesLabel}：',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
            _NumberCell(
              // ★ key 里带当前值 -> 后端改了值时重建输入框（与其它 _NumberCell 同做法）
              key: ValueKey('loop-times-${c.loopTimes}-${c.loopRoundsDone}'),
              value: c.loopTimes,
              width: 52,
              hint: '0=一直跑',
              min: 0,
              max: 9999,
              onCommit: (n) async {
                await c.setLoopTimes(n);
              },
            ),
            const SizedBox(width: 8),
            // ★ 「重置循环计数」—— 清 0 已跑轮数 -> 又能跑满设定的轮数
            Tooltip(
              message: '把「已跑轮数」（现在 ${c.loopRoundsDone} 轮）清 0 —— '
                  '于是又能跑满设定的「循环轮数」。\n'
                  '★ 只有你想"再来 N 轮"时才需要点它。',
              child: TextButton.icon(
                icon: const Icon(Icons.restart_alt, size: 15),
                label: const Text('重置计数'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 28),
                ),
                onPressed: c.resetLoopRounds,
              ),
            ),
          ],
        ],
        // ★★ T1（审计修复）: 「优先级依据」四选一下拉**已删** ★★
        //
        // 它是旧的 `schedule_rule`（`Filter`/`FIFO`/`Priority`/`List`）控件,
        // 与新的排序方式**语义重叠** -> 构成**两个互相牵制的控件**
        // （用户拖了顺序, 却因为 `schedule_rule != List` 而不生效）。
        // ★ 后端 `update_scheduler()` 已不再读 `schedule_rule`,
        //   "队列是唯一顺序权威"。
      ],
    );
  }

  /// 全局开关的**一行紧凑开关** —— 一枚图标按钮 + `Tooltip`。
  ///
  /// * 开 = `Icons.toggle_on`（实心, 主色）/ 关 = `Icons.toggle_off`（灰）
  /// * 标签与说明**全部**走 `Tooltip` —— 不占版面
  /// * 文案从 `/schema` 读（`c.globalFieldLabel` / `globalFieldHelp`）,
  ///   前端不硬编码; 拿不到时用 `fallbackLabel` 兜底
  Widget _inlineSwitch(
    BuildContext context, {
    required String key,
    required bool value,
    required String fallbackLabel,
    required Future<void> Function() onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    // ⚠ 每个字段的开关是**异步**的（要等后端返回）—— 用 `onPressed: () => onChanged()`
    //   而不是 `async` 回调, 免得 `use_build_context_synchronously` 警告。
    // ⚠ `globalFieldHelp` 这个方法**不存在** —— 说明在 `globalField(key)['help']`
    //   里（与 `label` 同一个 map）。
    final f = c.globalField(key);
    final label = '${f['label'] ?? fallbackLabel}';
    final help = '${f['help'] ?? ''}';
    // ★★★ L2 开关：**图标 + 短文字**（用户设计图 `▣启用周期 ▣启用临时`）★★★
    //
    // ## ★★ 用户裁定 ★★
    //
    // > "其它功能按钮的文字也要像我上条发你那样**简洁**哈，**节省UI空间**"
    // > "解释说明用 **tooltip** 来展示"
    // > "L2 **休息时可穿插**"
    //
    // ★ 原来这里**只有一个开关图标**（label 只藏在 Tooltip 里）——
    //   用户看不到"这个开关是干什么的"。
    // ★ 现在 = **图标 + 短文字**；文字由后端给（`临时` / `周期` / `休息时可穿插`），
    //   完整解释仍在 **Tooltip**（不占常驻空间）。
    return Tooltip(
      message: help.isEmpty ? label : '$label\n$help',
      child: InkWell(
        onTap: () => onChanged(),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                value ? Icons.toggle_on : Icons.toggle_off,
                size: 24,
                color: value ? scheme.primary : scheme.outline,
              ),
              const SizedBox(width: 2),
              Text(label,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: value ? scheme.primary : scheme.outline,
                        fontWeight: FontWeight.w600,
                      )),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sortActions(BuildContext context, TaskListController c) {
    // ⚠ 这里**不能**用 `.padding(...)`（`styled_widget` 的扩展）——
    //   本文件**没有** import 它, 会报 `undefined_method`。
    //   用原生 `Padding` 包一层。
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      // ★★★ 用 `Wrap` 而不是 `Row`（用户报的遮挡 bug）★★★
      //
      // ## 用户原话
      //
      // > "前端**简报展开**后，快捷排序那一栏的按钮并没有随着展开进行
      // >  合理的收窄适应，表现为**展开后遮挡了按钮**。这个应当和执行顺序
      // >  那一栏保持同款或者合理的缩放。"
      //
      // ## 根因
      //
      // 原来这里是 **`Row`**（**不换行**）:
      // ```dart
      // child: Row(children: [
      //   const SizedBox(width: 168, child: Text('快捷排序')),   // ★ 固定 168px
      //   OutlinedButton.icon(...), const SizedBox(width: 8),
      //   OutlinedButton.icon(...), ...
      // ])
      // ```
      // ★ 简报抽屉展开时**左栏收窄** -> `Row` 的总宽超过可用宽度 ->
      //   右侧按钮被**挤出/裁掉**（看起来就是"被遮挡"）。
      //
      // ## 修法: 与**同一吸顶区的** `_profilesRow` **同款**
      //
      // `_profilesRow` 用的是 `Wrap` —— 宽度不够时**自动换行**，
      // 永不溢出。★ 这就是用户说的"**和执行顺序那一栏保持同款**"。
      // （`Wrap` 增高会被 `_StickyQueueHeader` 实测并上报 —— 见它的说明。）
      //
      // ⚠ 顺带去掉那个 `SizedBox(width: 168)` 的**固定标签占位** ——
      //   固定宽度在窄栏里就是纯粹的浪费；`Wrap` 里标签**自然宽度**即可。
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // ★★★ 片 5 (F2f): 快捷排序 = **一个按钮，点一下换一种排法** ★★★
          //
          // ## ★★ 用户裁定（原话）★★
          //
          // > "快捷排序**合并为一个快捷排序按钮**，点一下周期排前面，
          // >  再点一下临时排前面，**不需要占三个按钮位置**。"
          // > "**按钮文字不变，始终为快捷排序**。"
          //
          // ## 实现
          //
          // ★ **文字恒为「快捷排序」**（用户明确要求），
          //   点一下在"周期排前面 / 临时排前面"之间**切换**；
          //   ★ "这一次会排成什么"进 **Tooltip**（悬停显示，本项目惯例）。
          // ★ `c.nextSortTarget` = 下一次点击要排的那一类（前后端都不持久化,
          //   纯界面状态）。
          Tooltip(
            message: '★ 点一下**排一次序**（周期 / 临时谁在前面），'
                '再点一下换另一种。\n'
                '当前会排成：**${c.nextSortTarget == 'timed' ? '周期排前面' : '临时排前面'}**\n'
                '★ 排完之后**所有条目仍然可以任意拖动**，不限类别 ——\n'
                '**包括「休息」**（它拖到中间时, 后面的任务会等它结束再跑）。',
            child: OutlinedButton.icon(
              onPressed: c.sortingQueue
                  ? null
                  : () => c.sortQueueNext(),
              icon: Icon(
                c.nextSortTarget == 'timed'
                    ? Icons.schedule
                    : Icons.push_pin,
                size: 16,
              ),
              label: const Text('快捷排序'),
            ),
          ),
          // ★★★ 说明改为**悬停显示**（用户要求）★★★
          //
          // 用户原话: "把[排一次之后随便排]这类提示都作为**指针悬停后显示**"。
          //
          // ★ 原来是一枚**常驻** `Chip`（占横向空间、每时每刻都在喊）；
          //   现在只留一个小图标, 文字进 `Tooltip`。
          // ★ 与本项目既有惯例一致（`window_editor` 里注着
          //   "说明走 Tooltip（用户要求括号改悬停）"）。
          // ★★ P-2: 那句"唯一固定的是「休息」条目 —— 它总是排在最后"
          //    已**不成立**（用户裁定, 见 OAS `832f467e`）。★★
          const Tooltip(
            message: '★ 这两个按钮只是**排一次序**（周期 / 临时谁在前面）。\n'
                '排完之后**所有条目仍然可以任意拖动**，不限类别 ——\n'
                '**包括「休息」**（它拖到中间时, 后面的任务会等它结束再跑）。',
            child: Icon(Icons.help_outline, size: 17),
          ),
          // ⚠ 这里**不能**再写 `const SizedBox(width: 8)` ——
          //   `Wrap` 已经用 `spacing: 8` 统一给了间距;
          //   再写会变成 16（换行后尤其明显）。
          // ★ 分组竖线: 左边 = 快捷排序（动作）, 右边 = 全局开关（设置）
          //   ⚠ `Wrap` 里**不设 `height`**（`height: 22` 会在换行时把行高撑歪）;
          //     用一个自适应的细线容器即可。
          Container(
            width: 1,
            height: 20,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          // ★★★ 全局开关 —— 并进这一行（用户要求: "放到执行队列里,
          //     和别的功能按钮合理摆放, 节省空间"）★★★
          _globalSwitchesInline(context),
        ],
      ),
    );
  }
}

// ============================================================ #6 吸顶区

/// **吸顶区**的 `SliverPersistentHeaderDelegate`（#6）。
///
/// 用户原话:
/// > "将执行顺序页面拎出来，**滚动时，上边的按钮和展示会一直存在**
/// >  而不是被滚动上去。"
///
/// ## 它做什么
///
/// * `pinned: true` -> 滚动时**一直贴在顶部**（这就是用户要的"一直存在"）
/// * 折叠状态与展开状态**一样高**（`minExtent == maxExtent`）——
///   吸顶区里是**两行可点控件**（配置页 chips + 快捷排序/全局开关）,
///   压扁它们只会让按钮被裁掉、点不到。所以不做折叠动画。
///
/// ## ⚠ 高度**必须实测**, 不能写死
///
/// `SliverPersistentHeaderDelegate` 要求**先**给出 `minExtent`/`maxExtent`
/// （在 `build` **之前**）, 但这一行的真实高度取决于:
/// 系统字号缩放、`Wrap` 折了几行、`DropdownButton` 的固有高度。
///
/// ★ 所以: 在 `build` 里用 `LayoutBuilder` **量一次**真实高度, 存进
///   `_extent`, 下一帧起用实测值。量之前用 [_fallback] 兜底 ——
///   这样**首帧**也不会因为"高度是 0"而把内容裁掉。
///
/// ★ 这是 Flutter 里做"高度不定的吸顶区"的标准手法; 本项目**没有**
///   引第三方包（如 `sliver_tools`）, 所以手写这 20 行。
class _StickyQueueHeader extends SliverPersistentHeaderDelegate {
  _StickyQueueHeader({required this.child});

  final Widget child;

  /// ★★★ 固定高度（**不再"实测"**）★★★
  ///
  /// ## 为什么放弃"实测"（三轮失败的教训）
  ///
  /// 用户实测报过三个数：`Bottom overflowed by 60px` -> `right lowered by 41`
  /// -> `Bottom overflowed by 4.0 pixels`。我依次试过：
  ///
  /// | 尝试 | 结果 |
  /// |---|---|
  /// | `return child` + `LayoutBuilder` 读 `constraints.maxHeight` | ★ 读到的是**外层给的高度**（= 旧值），**量不到内容** |
  /// | 只把 `_fallback` 调大 | ★ 治标，内容再高一点又溢出 |
  /// | `Stack` + `Positioned` | ★ `Positioned` 只给 top/left/right ⇒ `LayoutBuilder` 量不到高度 |
  /// | `_MeasureSize`（`RenderProxyBox`）放在滚动体**外面** | ★ 量到的是**滚动体的视口高度**（= 旧值），**还是量不到内容** |
  /// | `_converged`（只允许变高一次） | ★ 首次量得不够就**永远纠正不了**（用户："**没变**"）|
  ///
  /// ⇒ ★ **结论：在这个 delegate 里"先知道高度"与"量到内容高度"是
  ///   互相矛盾的**（`minExtent`/`maxExtent` 必须在 `build` **之前**给出，
  ///   而 `build` 的返回值才是内容的真实尺寸）。
  /// ⇒ ★ 所以**不再实测**，改用**固定值 + 内容不溢出**：
  ///   * 高度给**足够大**的固定值（够"配置页行 + 排序行 + 循环轮数行"）
  ///   * 内容包一层"零滚动滚动体" ⇒ ★ **内容永不溢出**（超出部分裁掉）
  ///
  /// ## ⚠ 代价（可接受）
  ///
  /// ★ 吸顶区**下方可能有一点空白**（内容比固定高度矮时）。
  /// ★ 这比"按钮被裁 / 黑黄条纹 / 白屏"好得多 —— 且空白很小。
  ///
  /// ## 覆盖哪些行
  ///
  /// | 行 | 会不会换行 |
  /// |---|---|
  /// | 配置页 chips（`_profilesRow`）| 页数多时会（每 chip ~40px）|
  /// | 快捷排序 + 全局开关（`_sortActions`）| 窄屏会（3 个开关 + 下拉 + 按钮）|
  /// | 循环轮数 + 重置计数（跟在上面）| 循环模式下会出现 |
  ///
  /// ⇒ 按**最坏情况**（三行）+ 字号缩放余量，取 **190**。
  static const double _height = 190;

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    // ★★★ 内容包一层"零滚动滚动体" ⇒ **永不溢出** ★★★
    //
    // * 它给子级**无界高度** ⇒ `Wrap` / `Column` 按自身尺寸布局，
    //   即便比 `_height` 高也**不会报溢出**（超出部分被裁）
    // * `NeverScrollableScrollPhysics` ⇒ 用户**滚不动**
    //   （吸顶区本来也不该滚，只是借它"无界高度"的能力）
    // * ⚠ 不做任何"测量"——见 `_height` 的说明（实测方案已证明不可行）
    //
    // ★★★ 对照实验（用户裁定「1 可以」）★★★
    //
    // ★ 原来这里套了 `SingleChildScrollView(NeverScrollable)` ——
    //   ★ 它**同时也是一个裁剪体**，会把超出 `_height` 的内容**裁掉**。
    // ★ 用户实测："**debug 版也没有条纹**" ⇒ ★ 与"这是 RenderFlex 溢出"
    //   的假设**矛盾** ⇒ ★ 很可能是**裁剪**造成的"白屏"（而不是溢出）。
    // ★ 所以现在**撤掉它**，回到"原样透传"：
    //   * 白屏**消失** ⇒ ★ 确认是我的修造成的
    //   * 白屏**仍在** ⇒ ★ 换方向查（不是这里）
    // ⚠ 撤掉后若内容超过 `_height`，debug 会**画条纹并打印**
    //   `The relevant error-causing widget was: … file:line`
    //   —— ★ 那正是我们要的诊断信息。
    return SizedBox(
      height: _height,
      child: Material(
        // ★ 必须**不透明** —— 否则下面的队列行会从吸顶区底下透出来
        //   （看起来像字叠字）。
        color: Theme.of(context).scaffoldBackgroundColor,
        child: child,
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _StickyQueueHeader old) =>
      old.child != child;
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
