part of task_list;

/// **执行队列** —— 有序、可拖拽、每行带状态徽标。
///
/// ## 为什么是"一个队列"而不是"两个只读观察窗"
///
/// 用户原话:
///
/// > 待执行、等待中这类就是预期执行流程，也相当于包含所有任务的执行顺序，
/// > 也应该可以拖拽排列顺序
///
/// 原先把「待执行」和「等待中」做成两个**只读**观察窗，问题是:
///
/// * 它们是"**到没到点**"的划分（由**时间**决定），不是"顺序"
/// * 用户想管的其实是**顺序** —— 而顺序只能拖
///
/// 所以合并成一个 **有序队列**:
///
/// ```
/// 执行队列（拖拽即改执行顺序）
///   ⠿  1  探索          [待执行]  [5 次] [10 分]
///   ⠿  2  御魂          [待执行]  [30 次][--]
///   ⠿  3  日轮之陨      [等待中 18:00] [9 次]
///   ⠿  4  契灵之境      [冷却中 42 分]
///   ⠿  5  [休息 30 分钟]
///   ─── 未编排（拖上来即加入队列）───
///   ⠿  探索寮突         [待执行]
///   ⠿  金币妖怪         [等待中]
/// ```
///
/// * **有序部分** = 运行列表（`run_list`）—— 拖完直接存回后端
/// * **未编排部分** = 启用了但还没进列表的任务
/// * **状态徽标** = 后端给的 `slot` / `reason` / `in_cooldown` ——
///   前端**不重新推导**调度规则
/// * **每行的次数 / 预期耗时**可直接改（用户要求"把次数/分钟设置也放在任务上边"）
///
/// ## 与「任务表格」的分工（用户明确过）
///
/// | 面板 | 管什么 |
/// |---|---|
/// | **任务表格** | Excel 式的**批量查看与管理**（启停 / 运行一次 / 排序 / 筛选）—— **不改执行顺序** |
/// | **执行队列** | **执行顺序**（拖拽）+ 每任务的次数与预期耗时 |
///
/// ---
///
/// ## ★★★ 本 widget 现在是**一组 sliver**（#6 吸顶的前置条件）★★★
///
/// 用户原话:
/// > "将执行顺序页面拎出来，**滚动时，上边的按钮和展示会一直存在**
/// >  而不是被滚动上去。"
///
/// 「一直存在」= **吸顶**（pinned）, 不是"随内容滚"。要吸顶就必须
/// **外层**那个 `CustomScrollView` 说了算 —— 而 `ReorderableListView`
/// **自己就是一个滚动体**, 塞不进别人的 sliver 序列。
///
/// ★ 所以换成 `CustomScrollView` + `SliverReorderableList`:
///
/// ```
/// _QueueTab.build
/// └─ CustomScrollView
///      ├─ SliverPersistentHeader(pinned: true)   ← ★ 快捷排序 + 全局开关（吸顶）
///      └─ QueuePanel.slivers(...)                ← ★ 本 widget 现在的形态
///           ├─ SliverToBoxAdapter(标题行 + 调度状态 + 分段条)
///           ├─ SliverPadding(SliverReorderableList(行))   ← 行; 可拖
///           └─ SliverToBoxAdapter(尾部提示)
/// ```
///
/// ★ 为什么 `SliverReorderableList` 仍能**越界自动滚**（用户报的 #7）:
///   它的 `autoScrollerVelocityScalar` 走 **`Scrollable.of(context)`** ——
///   也就是外层那个 `CustomScrollView` 的 position。所以只要它在
///   **可滚动的 viewport 内部**就生效, 不再要求"自己就是滚动容器"。
///
/// ⚠ **不要**再在别处套 `ReorderableListView`（= 滚动套滚动 ->
///   `0<=h<=Infinity` 约束错）。本文件里它已经**一个都不剩**。
class QueuePanel extends StatefulWidget {
  const QueuePanel({super.key, required this.controller});

  final TaskListController controller;

  /// ★★ 本面板的**全部内容**, 作为一组 sliver 交给外层的 `CustomScrollView`。
  ///
  /// ★ 为什么是**静态方法**: 它不需要任何 State —— 每一行都是无状态的
  ///   `QueueRow`（也是本轮从 `_QueuePanelState` 里搬出来的, 见 `QueueRow`
  ///   的说明）。少一层 State 就少一处"拖到一半 State 被重建"的风险。
  static List<Widget> slivers(BuildContext context, TaskListController c) =>
      _queueSlivers(context, c);

  @override
  State<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<QueuePanel> {
  TaskListController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    // ★ 本 widget **自己**也是一个可滚动体（`CustomScrollView`）——
    //   这样单测可以 `pumpWidget(wrapBounded(QueuePanel(controller: c)))`
    //   直接验证队列渲染（既有测试就是这么做的一整批）。
    return CustomScrollView(
      slivers: QueuePanel.slivers(context, c),
    );
  }
}

/// **队列那一组 sliver**（从 `_QueuePanelState.build` 里整段搬出来）。
///
/// ★ 它**不依赖 State** —— 所以既能被 `QueuePanel` 用（自带滚动体）,
///   也能被 `_QueueTab` 用（吸顶的那个 `CustomScrollView`）。
List<Widget> _queueSlivers(BuildContext context, TaskListController c) {
  // ★★ 四类分区（用户确认的分类模型）★★
  //
  // | # | 分类 | 判定 | 可拖 |
  // |---|---|---|---|
  // | 0 | **正在运行** | WebSocket `runningTask` | ❌ |
  // | 1 | **可跑**（已到点）| `queued && slot == 'pending'` | ✅ |
  // | 2 | **未到窗口**（灰）| `queued && slot != 'pending'` | ✅ |
  // | 3 | **启用但不会运行** | `enable && !auto_queue && !queued` | — 只在【添加任务】里 |
  //
  // ★ 「待执行 / 等待中」两个**只读明细窗**保留在下面 ——
  //   用户说过: "你这次是直接删除了监控，而不是合并"。
  //   它们与队列是**同一件事的两个视角**: 队列是"我要什么顺序",
  //   这两个窗是"调度器此刻算出来什么"。
  final queued = c.queuedTasks;
  final pending = queued.where((t) => t['slot'] == 'pending').toList();
  final waiting = queued.where((t) => t['slot'] != 'pending').toList();

  // ★★★ 本组 sliver 必须住在一个**可滚动**的 viewport 里（修用户报的 #7）★★★
  //
  // ## 用户原话
  //
  // > "在**拖动任务超出窗口范围时，滚动条并不会随之滚动**，导致从队尾移到
  // >  队首时需要拖动好几次。"
  //
  // ## 根因（实测）
  //
  // Flutter 的**拖动自动滚动**（`autoScrollerVelocityScalar`）挂在
  // **可滚动列表自己**身上。原来可拖的行住在一个
  //     `ReorderableListView(shrinkWrap: true,
  //                           physics: NeverScrollableScrollPhysics())`
  // 里 —— ★ 它被明确设成"**不可滚**" -> 拖到边缘**不滚**
  // -> 只能"拖一点、松手、滚一下、再拖"。
  //
  // ## 现在
  //
  // ★ `SliverReorderableList` 自己不是滚动体, 但它的自动滚动读的是
  //   `Scrollable.of(context)` —— 也就是**外层** `CustomScrollView`
  //   （`QueuePanel` 或 `_QueueTab`）的 position。
  // ★ 所以"能滚"这件事由外层保证, 本文件**不许**出现
  //   `NeverScrollableScrollPhysics` / `shrinkWrap: true`。
  // ★ 不可拖的部分（标题/按钮/调度状态/说明）进 `SliverToBoxAdapter`
  //   —— 它们是同一个滚动体的一部分, 随内容滚（符合预期）。
  return [
    // ---------- 标题行（吸顶区之下的第一块, 随内容滚）----------
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ★★★ 片 11: 队列区最上的 `脚本未启动 [启动脚本]` **已删除** ★★★
            //
            // > 用户: "启动/停止脚本**放到共用顶部**"
            // > 用户: "**'} 一个按钮 ┘**"
            // > 用户: "执行队列页面**有两个脚本未启动，冗余了**，
            // >        保留顶部的一个即可"
            //
            // ⇒ ★ 「启停脚本」现在只在**共用顶部**（`RunControlBar`）一处；
            //   这里**不再有**自己的那一份。
            // ⇒ ★ 「暂停/继续调度」也不在标题行 —— 它在
            //   **"正在运行的那一行"**上（与 `[▶]` 互斥）。
            //
            // ★ 所以「执行队列」标题行现在就是：
            //   `执行队列   [添加] [清空]`
            Row(
              children: [
                Expanded(
                  child: _panelTitle(
                    context,
                    '执行队列',
                    '拖 ⠿ 改执行顺序 · 每行的次数/预期耗时可直接改',
                  ),
                ),
                // 加入队列 —— **只列已启用的次数任务**（走后端候选端点）
                TextButton.icon(
                  onPressed: () => pickAndAddToQueue(context, c),
                  icon: const Icon(Icons.add, size: 16),
                  label: Text('添加'
                      '${c.enabledNotQueuedTasks.isEmpty ? '' : ' (${c.enabledNotQueuedTasks.length})'}'),
                ),
                // ★★ ⑦: **一键清空队列**（带确认弹窗）★★
                //
                // 语义与"单个移除"一致: 后端会把 `run_list` 置空 **并**停用所有
                // `auto_queue` 任务 —— 否则它们会被 `build_queue()` 补回队列。
                // **不删任何任务配置**, 随时可以重新启用 + 加回来。
                TextButton.icon(
                  onPressed: () => confirmClearQueue(context, c),
                  icon: const Icon(Icons.playlist_remove, size: 16),
                  label: const Text('清空'),
                ),
              ],
            ),

            // ---------- 分类 0: ~~调度器 + 正在运行~~ **已删除** ----------
            //
            // ★★★ 片 5 (F2b): **「正在运行」不再占一行**（用户裁定）★★★
            //
            // ## ★★ 用户原话（两次强调）★★
            //
            // > "**执行队列那个正在运行个人突破不应该存在了啊**，这个不符合
            // >  咱们列表里流转[正在运行]状态的定义。"
            // > "**队首只是代表列表顺序第一个而已，但正在运行的可以使列表里
            // >  任意一个。**"
            //
            // ★ 原来这里是一个 `_statusBlock`（"▶ 调度中 │ ▶ 正在运行: xxx
            //   [任务设置]"）—— 它把"正在运行"表达成**固定的一行**，
            //   与"运行是列表里**流转的状态**"矛盾 ⇒ **整块删掉**。
            //
            // ★ 它的三个职责已分别安置：
            //   | 原职责 | 现在在哪 |
            //   |---|---|
            //   | "正在运行 X" | ★ **X 那一行上的「运行中」标记**（F2c）|
            //   | "任务设置" | ★ 删掉（队列行上本来就有设置，F2e）|
            //   | "调度中/已停止" | ★ 脚本进程状态在顶部 `RunControlBar` 已有（F2a）|

            const SizedBox(height: 4),
            const Divider(height: 1),
            const SizedBox(height: 6),

            // ---------- ★★ F6: **一套**可拖列表（用户要求合并）★★ ----------
            //
            // 用户原话:
            //   "待执行里为什么不能和执行顺序一样拖动呢, 他俩应该并在一起啊"
            //   "等待中（还没到点）更改为显式的意义, 如[未到开放时间]"
            //
            // ## 此前为什么是**两套**
            //
            // 上面一个可拖的「执行顺序」（渲染 `entries` = 只有 `run_list`）,
            // 下面两个**只读**的「待执行 / 等待中」观察窗。
            // 两者是同一件事的两个视角 —— 用户要的是**合并成一套**。
            //
            // ## 合并后
            //
            // **一个**可拖列表, 渲染 `c.queuedTaskRows`
            // （= `run_list` + 自动补齐的定时任务, 见 controller 的说明）。
            // 每行的状态徽标区分:
            //
            //   [待执行]          —— 已到点, 马上要跑
            //   [未到开放时间]     —— 不在窗口内, 变灰; 不是错误, 只是"还没到时候"
            //
            // ★ 顺带修掉一个用户报的 bug: 可拖列表此前只渲染 `entries`,
            //   而**自动补齐的任务不在 `entries` 里** -> 启用了金币妖怪/
            //   经验妖怪/狭间暗域却**在界面上看不到**。
            Row(
              children: [
                // ★ 解释说明走 **Tooltip**（用户裁定："**解释说明用 tooltip 来展示**"）
                //   —— 不在界面上占常驻空间
                Tooltip(
                  message: '拖动 ⠿ **调整执行顺序**\n'
                      '★ 顺序由队列本身说了算 —— 拖到哪就按哪跑',
                  child: Text('执行顺序',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          )),
                ),
                const SizedBox(width: 8),
                Text('待执行 ${pending.length} · 未到开放时间 ${waiting.length}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).disabledColor,
                        )),
              ],
            ),
            const SizedBox(height: 4),

            if (c.queuedTaskRows.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('（队列为空 —— 点右上「添加任务」，或先启用周期任务）'),
              )
            else
              // ★★ S6: **类别分段视觉** ★★
              //
              // 用户裁定:
              //   "拖动只在同类别内生效是在选了**定时优先**或者**固定任务优先**
              //    时, 如果选了**列表自定义**, 那么全都可以拖动次序。"
              //
              // 所以"只能同段内拖"时, 上面画一条**分段条** —— 一眼看出
              // "队列被分成两段、哪段在前"。
              //
              // ⚠ 我第一版用 `Row(crossAxisAlignment: stretch)` 把标签栏放在
              //   列表**左侧** —— **布局崩了**: 外层是 `SingleChildScrollView`
              //   （垂直**无界**）, 而 `stretch` 要求纵向填满 -> 约束非法
              //   （2 个 widget 测试报 `invalid constraints ... RenderClipRect`）。
              //   ★ 改成**不用 `Row`**、放在列表**上方**。
              // ★★★ S7: 类别条**恒显示**（用户裁定）★★★
              //
              // 原来这里是 `if (c.dragWithinGroupOnly) _segmentBar(...)`
              // —— 只在"非自定义模式"下显示, 因为那时它要**解释拖动约束**。
              //
              // ★ 用户裁定删掉三模式与跨类别约束（"我只需要保持可以自由
              //   拖动/改变执行顺序就行"）-> `dragWithinGroupOnly` 已删。
              // ★ 现在它只是**信息条**: 告诉你这堆条目里定时/固定各几条。
              _segmentBar(context, c),
          ],
        ),
      ),
    ),
    // ---------- 可拖的行（`SliverReorderableList`）----------
    SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      sliver: SliverReorderableList(
        itemCount: c.queuedTaskRows.length,
        onReorder: c.reorderQueue,
        // ★ key **必须**挂在返回的 widget 上 —— `SliverReorderableList`
        //   断言 `child.key != null`（实测: 挂在内部 `Container` 上会抛
        //   `All list items must have a key`）。
        itemBuilder: (_, i) => QueueRow(
          key: QueueRow.keyOf(c.queuedTaskRows[i], i),
          c: c,
          index: i,
        ),
      ),
    ),
    // ---------- 尾部提示 ----------
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---------- 分类 3 的提示（**不在这里罗列**）----------
            //
            // 用户原话: "启用的任务但不会执行的任务应该出现在添加任务里,
            //          而不是堆在未编排里"。
            // 所以这里只给一句指引, 具体任务在【添加任务】对话框里。
            if (c.enabledNotQueuedTasks.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Divider(height: 1),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 14, color: Theme.of(context).disabledColor),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '还有 ${c.enabledNotQueuedTasks.length} 个已启用的次数任务'
                      '不在队列里 —— 点右上「添加任务」加入',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: Theme.of(context).disabledColor,
                          ),
                    ),
                  ),
                  // ★ 2026-10-12：★ **本按钮保留** ——
                  //   ★ 我上一轮**误删**了它（★ 用户要删的是"添加任务弹窗里
                  //     重复的休息入口"，**不是**这个）。
                  //   > "**我不是让你去掉底部的添加任务入口**！是**添加任务中
                  //   >  有两个添加休息的方式**！点击添加任务后，出现窗口，
                  //   >  里边有一个**休息**和一个**添加休息**！"
                  TextButton(
                    onPressed: () => pickAndAddToQueue(context, c),
                    child: const Text('添加'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    ),
  ];
}

/// 只读的一行任务（**中文名** + 下次运行 + 任务设置入口）。

/// **安全**取该账号的 `ScriptModel`（拿不到返回 `null`）。
///
/// ★ 为什么不用 `Get.find<ScriptService>()`: 那在**服务未注册**时会抛
///   `"ScriptService" not found`, 整块面板渲染不出来。
///
///   两种情况都会遇到:
///   * widget 测试（没有 WebSocket 服务）
///   * 页面比服务先构建（启动瞬间）
///
///   拿不到就只显示"—", 不该让整个队列消失。
dynamic _scriptModelOf(TaskListController c) {
  try {
    if (!Get.isRegistered<ScriptService>()) return null;
    return Get.find<ScriptService>().scriptModelMap[c.script];
  } catch (_) {
    return null;
  }
}

  // ---------------------------------------------------------------- 移出队列
  //
  // ★★ 用户确认的行为 ★★
  //
  //   "可移除，移除后自动变为未启用状态，后续想要启用需自己在任务列表启用
  //    （弹窗确认和提示）"
  //
  // ★★ 行为**分两类**（用户 2026-10-10 明确修正）★★
  //
  //   | 任务类型        | auto_queue | 移除后                          |
  //   |----------------|------------|--------------------------------|
  //   | 定时任务        | true       | 出队列 **且 enable=false**      |
  //   | 固定/次数任务    | false      | **只出队列**, enable 保持不变    |
  //
  // 为什么定时任务必须同时**停用**:
  //   `auto_queue=True` 的任务只要 `enable=true` 就会被后端 `build_queue()`
  //   **重新补进队列** —— 只从 `run_list` 删掉是**无效操作**, 下次刷新它又回来了。
  //
  // 为什么次数任务**不能**停用:
  //   它们不在自动补齐范围内, 出队列后不会被补回来。若也停用, 用户想再跑
  //   就得先回任务列表启用 —— 那是多余的步骤。用户原话:
  //     "固定任务移除后应该返回添加任务的池子里。"
  //
  // ★ 我此前写成"**无条件停用**" —— 那是**错的**, 已修正。

/// 确认后移出队列（后端按 `auto_queue` 决定是否同时停用）。
///
/// ★ [entryId]: **精确移除某一条**（⑨）。
///   队列里同一任务可以出现多次 —— 只传任务名会**一删全删**
///   （实测: 两条「个人突破」删一条, 两条都没了）。
Future<void> confirmAndRemove(BuildContext context, TaskListController c,
    String cmd, {String? entryId}) async {
  final zh = _zhName(cmd, c);
  final auto = c.isAutoQueue(cmd);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('把「$zh」移出队列？'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(auto
              ? '「$zh」是**自动进队列**的任务。'
              : '「$zh」是**次数任务**，只在队列里时才会跑。'),
          const SizedBox(height: 8),
          Text(auto
              ? '把它移出队列会**同时停用它**（关闭启用开关），'
                  '否则它下次仍会被自动加入。'
              : '把它移出队列只会**让它离开队列**，'
                  '**不会停用**它 —— 它会回到【添加任务】里，可随时加回。'),
          const SizedBox(height: 8),
          Text(auto
              ? '之后想再跑：请先在**任务列表**里重新启用它'
                  '（启用后它会自动回到队列）。'
              : '之后想再跑：用【添加任务】把它加回队列即可。'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(auto ? '移出并停用' : '移出队列'),
        ),
      ],
    ),
  );
  if (ok != true) return;

  final message = await c.removeFromQueue(cmd, entryId: entryId);
  if (!context.mounted) return;
  // ★ 提示（用户要求"弹窗确认和提示"）
  Get.snackbar('已移出队列', message,
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 6));
}

/// ★★ ⑦: **一键清空队列** —— 确认后调用后端 `POST /queue/clear`。
///
/// ★ 弹窗必须说清**两件事**（否则用户会以为任务被删了）:
///   1. 会**同时停用**定时任务（否则它们被自动补回队列）
///   2. **不删任何任务配置**, 随时可以重新启用 + 加回来
Future<void> confirmClearQueue(BuildContext context, TaskListController c) async {
  final n = c.queuedTaskRows.length;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('清空整个执行队列？'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('队列里现在有 **$n** 条条目，全部移出。'),
          const SizedBox(height: 8),
          const Text('**周期任务会被同时停用** —— 否则它们会被自动补回队列；'
              '次数任务只离开队列。'),
          const SizedBox(height: 8),
          const Text('**不会删除任何任务配置**，随时可以重新启用 + 【添加任务】加回来。'),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error),
          child: const Text('清空'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  final message = await c.clearQueue();
  if (!context.mounted) return;
  Get.snackbar('已清空队列', message,
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 6));
}

  // ---------------------------------------------------------------- 已编排行

/// 一行「执行顺序」条目。
///
/// ★★ 本类从 `_QueuePanelState` **整段搬出来**（#6 吸顶的前置重构）★★
///
/// 为什么要搬: 吸顶要用 `CustomScrollView` + `SliverReorderableList`
/// —— 而 `SliverReorderableList` 跑在 `QueuePanel` **外面**（`_QueueTab`
/// 的 sliver 序列里）, 行不能再是 `_QueuePanelState` 的私有方法。
///
/// ★ 它是 `StatelessWidget`（不是 `State`）—— 行是**纯读 + 事件回调**,
///   不需要生命周期。搬出来时已逐个检查过那 7 个辅助方法:
///   没有一个用 `setState` / `mounted`（都是读 `c` + 弹窗）。
///
/// ★★ F6: 现在渲染 **`c.queuedTaskRows`**（有效队列）, 不是 `c.entries`。
///
/// 两种来源:
/// * `_queuedRow == false` -> 来自 `run_list`（用户编排, 含「休息」条目）
/// * `_queuedRow == true`  -> **自动补齐**的定时任务（后端 `queued` 里有,
///   但不在 `run_list` 里）—— 用户报"启用了却看不到"的就是这些
class QueueRow extends StatelessWidget {
  const QueueRow({super.key, required this.c, required this.index});

  final TaskListController c;
  final int index;

  /// 行 key —— ★ 必须**稳定且唯一**（`SliverReorderableList` 靠它认条目）。
  ///
  /// ⚠ 同一任务可以在队列里出现**多条**（"重复跑整轮"）—— 所以 key 里
  ///   必须带 `_entryId` / `_entryIndex`, 只带任务名会让两条行**撞 key**
  ///   （Flutter 会报 duplicate key, 拖动也会串行）。
  ///
  /// ⚠ 它**只用于** `itemBuilder` 返回的那个 widget ——
  ///   `SliverReorderableList` 断言 `child.key != null`, 把 key 挂在
  ///   该 widget **内部**的 `Container` 上不算（实测抛出
  ///   `All list items must have a key`）。
  static Key keyOf(Map<String, dynamic> e, int i) {
    final isTask = '${e['kind']}' == 'task';
    final id = '${e['_entryId'] ?? e['_entryIndex'] ?? e['_addedAt'] ?? ''}';
    return ValueKey(isTask ? 'queue-task-${e['task']}-$id' : 'queue-rest-$id-$i');
  }

  @override
  Widget build(BuildContext context) {
    // ★★★ 乙：**单行渲染失败不许炸整页**（修用户报的白屏）★★★
    //
    // ## ★★ 用户报的现象 + 他给的排查线索 ★★
    //
    // > "**执行顺序页面直接白屏了**"
    // > "这个白屏是在**启动脚本之后**出现的，而且在**脚本停止后并不会消失**。
    // >  **点击清理队列就会消失。**"
    //
    // ## 从时机推出来的结论
    //
    // ★ "清理队列就消失" ⇒ 由**某个队列条目**的渲染引起。
    // ★ "启动脚本之后才出现" ⇒ 那个条目是**启动时 `build_queue()` 补进来的**
    //   （★ 日志里就有 `已清理僵尸配置节点 ['orchi_moans']` ——
    //    队列条目引用的任务节点**已不在配置里**，`/overview` 里查不到它）。
    // ★ "脚本停止后不消失" ⇒ 它留在前端 `entries` 里（reload 来的，不随停止清）。
    //
    // ## 为什么测试查不出来
    //
    // ★ `analyze` 与 149 个测试用的都是**干净数据**；
    //   而实机是**脏数据**（僵尸任务 / 后端版本差）⇒ 只有运行时才炸。
    //
    // ## 修法
    //
    // ★ 把**一行**的渲染包进 `try/catch`：
    //   * 成功 -> 正常那行
    //   * 失败 -> ★ 只显示一行「（这一条数据异常）」**提示 + 原因**，
    //     **整页照常渲染** ⇒ ★ 再也不会白屏。
    // ★ 这**不动任何业务逻辑**，纯粹是"脏数据护栏"。
    try {
      return _queueRow(context, c, index);
    } catch (exc, stack) {
      // ★ 打日志（release 版也会进 stderr）—— 便于下一次定位真实原因
      debugPrint('QueueRow[$index] 渲染失败: $exc');
      debugPrint('$stack');
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(Icons.error_outline,
                size: 16, color: Theme.of(context).colorScheme.error),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '（这一条数据异常，已跳过渲染） $exc',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }
  }
}

/// ★ 队列行上的**状态小标记**（片 5 / F2c 抽出，三处共用）。
///
/// 统一外观: 圆角小胶囊 + 小图标 + 短文字。
Widget _queueBadge(BuildContext context,
    {required String text, required Color color, required IconData icon}) {
  return Container(
    margin: const EdgeInsets.only(right: 6),
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 2),
        // ★ 小窗口下标记文字可裁剪（父级 `Flexible` 会限宽）——
        //   ★ 不这么做时，长标记（"已运行 12 次"）会把整行顶出去
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
      ],
    ),
  );
}

/// ★★★ 片 5 (F2d): 点「▶ 播放」-> 让**这一条**立刻运行 ★★★
///
/// > 用户: "我还想添加一个按钮，**每个队列里的任务都有一个播放按钮**，
/// >  点一下就可以**切换成正在运行**。"
///
/// ★ 走 `PUT /{script}/run_control/entry_play`（把该条目的 `next_run`
///   拉到现在）；后端会**明确报错**如果这条当前不可跑（未启用/不在窗口内），
///   所以这里**必须把后端的原话上屏**，不能让用户以为"点了没反应"。
Future<void> _playEntry(BuildContext context, TaskListController c,
    Map<String, dynamic> e) async {
  final entryId = '${e['_entryId'] ?? e['entry_id'] ?? ''}';
  final name = _zhName('${e['task']}', c);
  if (entryId.isEmpty) {
    Get.snackbar('无法播放', '这一条没有条目身份（entry_id），请先刷新队列',
        snackPosition: SnackPosition.BOTTOM);
    return;
  }
  final msg = await c.playEntry(entryId);
  if (!context.mounted) return;
  Get.snackbar(msg.startsWith('✓') ? '已排到最前' : '无法播放：$name', msg,
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 4));
}

/// 一行「执行顺序」条目的**内容**（从 `_QueuePanelState._queueRow` 整段搬来）。
Widget _queueRow(BuildContext context, TaskListController c, int i) {
  final rows = c.queuedTaskRows;
  if (i < 0 || i >= rows.length) return const SizedBox.shrink();
  final e = rows[i];
  final isTask = '${e['kind']}' == 'task';
  // ★ 这一页里**没有任何条目在跑**？（暂停的边界兜底要用，见下面按钮那儿）
  final noRunningRow = !rows.any(
      (r) => '${r['kind']}' == 'task' && r['running'] == true);
  final cmd = isTask ? '${e['task']}' : '';
  final isAuto = e['_auto'] == true;

  // 状态: 待执行 / 未到开放时间
  final row = isTask ? c.taskRowOf(cmd) : null;
  final isPending = row == null || '${row['slot']}' == 'pending';

  // ★★ ③: **按类别区分**「定时任务」与「次数/固定任务」★★
  //
  // 用户原话:
  //   "如果是因为次数类只能在次序类里拖动, 定时只能在定时类任务队拖动,
  //    那么请用**不同颜色或两个边框框住来区分**。"
  //
  // 所以: 左侧一条**色条** + 一个类别小标签。色条比整行底色更克制,
  // 不会和「未到开放时间」的灰化冲突。
  //
  // ★ 类别来自后端（`taskRowOf` 的 `category` / `auto_queue`）,
  //   前端**不重新推导**调度规则。
  // ★★★ 色条与标签**都用 `priority_group`（有效分段）**, 不用 `auto_queue` ★★★
  //
  // ## 实机验收发现的**口径不一致**
  //
  // 用户原话:
  // > "执行顺序下边的任务统计数量显示：**定时任务2条，固定任务14条**,
  // >  但是**任务上的标签**显示的几乎都是紫色的定时, 红色的次数只有四个"
  //
  // **根因**: 这里原来用的是 `isAutoQueue(cmd)`（= `auto_queue`,
  //   "会不会**自动进队列**"）—— 那是**第三个**口径, 与
  //   `priority_group`（有效分段, 分段条用的）**不是一回事**。
  // ★ 实测 16 条队列里 10 条 `auto_queue` 与有效分段不一致 -> 颜色和
  //   分段条对不上。
  //
  // ★ 改成读 `priorityGroupOf(cmd)` —— 与分段条**同源**。
  // ★ 「会不会自动进队列」的信息仍在 `isAutoTask` 的 Tooltip 里说明
  //   （那是另一件有用的事, 只是不该拿它当**分段**的判据）。
  final isAutoTask = isTask && c.isAutoQueue(cmd);
  final group = isTask ? c.priorityGroupOf(cmd) : '';
  final accent = !isTask
      ? Theme.of(context).colorScheme.outline
      : (group == 'timed'
          ? Theme.of(context).colorScheme.primary // 定时
          : Theme.of(context).colorScheme.tertiary); // 固定/次数

  // 「休息」条目给不同底色 —— 一眼看出"这里会停"
  final bg = isTask
      ? null
      : Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.3);

  return Container(
    key: QueueRow.keyOf(e, i),
    // ★ 必须用 `decoration` 而不是 `color` —— Flutter 的 `Container`
    //   **不允许**同时给 `color` 与 `decoration`（会 assert 崩）。踩过。
    decoration: BoxDecoration(
      color: bg,
      // ★ ③ 左侧色条 —— 类别区分（定时 = primary, 次数 = tertiary）
      border: isTask
          ? Border(left: BorderSide(color: accent, width: 3))
          : null,
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 拖拽把手
              ReorderableDragStartListener(
                index: i,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(Icons.drag_handle, size: 18),
                ),
              ),
              SizedBox(
                width: 22,
                child: Text('${i + 1}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        )),
              ),
              Expanded(
                // ★ 步骤②：`Row` -> `Wrap`（自适应换行）
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  runSpacing: 2,
                  children: [
                    // ★★ ③: 类别小标签 —— 「定时」/「固定」★★
                    //
                    // 用户: "请用**不同颜色或两个边框**来区分"。
                    // 色条在左边（`decoration`）, 这里再给一枚文字标签,
                    // 色盲用户/截图里也能分辨。
                    // ★ 说明走 Tooltip（用户要求"括号改悬停"）。
                    //
                    // ⚠ 标签文字**原来**是 `isAutoTask ? '定时' : '次数'`
                    //   —— 按 **`auto_queue`**（会不会自动进队列）分,
                    //   与分段条（按 `priority_group`）**口径不同**,
                    //   于是"分段条说定时 2 条, 队列里却有 12 枚定时"。
                    // ★ 现在两处**同源**: 都用 `priorityGroupLabelOf()`。
                    //   分段条说"定时 N 条", 队列里就**恰好** N 枚"定时"。
                    if (isTask) ...[
                      Tooltip(
                        message: '${c.priorityGroupLabelOf(cmd)}任务'
                            '（${group == 'timed' ? '排在周期段' : '排在临时段'}）\n'
                            '${isAutoTask ? '启用后会**自动进队列**；' : '需要手动【添加任务】才进队列；'}\n'
                            '${c.inWindowNowOf(cmd) ? '当前**在**开放时段内。' : '当前**不在**开放时段内 —— 到点才会跑。'}\n'
                            '★ **拖动不受它限制** —— 任何条目都能互相拖。',
                        child: Container(
                          margin: const EdgeInsets.only(right: 6),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            c.priorityGroupLabelOf(cmd),
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                  color: accent,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                      ),
                    ],
                    // ★★★ 片 5 (F2b/F2c): 「**正在运行**」= **流转的状态标记** ★★★
                    //
                    // ## ★★ 用户裁定（原话）★★
                    //
                    // > "对于正在运行，就像是**音乐播放列表里的正在播放**一样，
                    // >  **他不是排在队首的**，而是一种**状态按顺序变更**的"
                    //
                    // > "这种正在运行的状态**不是在[队首]**，而是在当前'播放列表'里
                    // >  '正在播放'的'**音乐**'上，也就是说在当前'**正在运行**'的
                    // >  '**任务**'上，而**切换任务顺序的各个配置页就是切换不同的歌单**。"
                    //
                    // > "**队首只是代表列表顺序第一个而已，但正在运行的可以是
                    // >  列表里任意一个**"
                    //
                    // > "由于现在是**流转的运行**，那么就会出现**运行过，
                    // >  状态标记为已运行X次**"
                    //
                    // ## 三种状态（★ 数据全部来自后端 `/run_list`）
                    //
                    // | 条件 | 标记 |
                    // |---|---|
                    // | `e['running'] == true` 且脚本在跑 | 【▶ **运行中**】绿 |
                    // | `e['running'] == true` 但脚本**没在跑** | 【⏸ **已暂停**】橙 |
                    // | `e['runs'] > 0`（跑过）| 【✓ **已运行 N 次**】灰 |
                    // | 其它（还没跑）| 不显示 |
                    //
                    // ★ `running` 由后端按 **`running_entry_id`**（条目身份）判定
                    //   —— "**身份，不是位置**" ⇒ 标记**跟着任务走**，
                    //   与"第几行"无关（任务拖到哪它就跟到哪）。
                    // ★★★ 片 11: 标记按【**调度状态**】显示（用户裁定"改"）★★★
                    //
                    // ## ★★ 为什么改 ★★
                    //
                    // 原来只看**脚本进程**（`ScriptState.running`）——
                    // ★ 于是"**暂停调度后**（进程仍在跑）"标记**仍显示「运行中」**，
                    //   与用户刚点的「暂停」矛盾。
                    //
                    // ## 现在三态
                    //
                    // | 条件 | 标记 |
                    // |---|---|
                    // | 脚本进程**没跑** | 【⏹ **已停止**】灰 |
                    // | 进程在跑 + **调度已暂停** | 【⏸ **已暂停**】橙 |
                    // | 进程在跑 + 调度未暂停 | 【▶ **运行中**】绿 |
                    if (isTask && e['running'] == true) ...[
                      Builder(builder: (ctx) {
                        final sm = _scriptModelOf(c);
                        final procRunning =
                            sm?.state.value == ScriptState.running;
                        final paused = c.schedulerPaused;
                        final String text;
                        final Color color;
                        final IconData icon;
                        final String msg;
                        if (!procRunning) {
                          text = '已停止';
                          color = Colors.blueGrey;
                          icon = Icons.stop_circle_outlined;
                          msg = '★ **已停止** —— 这一条是刚在跑的，'
                              '但**脚本进程**已经停了。';
                        } else if (paused) {
                          text = '已暂停';
                          color = Colors.orange;
                          icon = Icons.pause_circle_outline;
                          msg = '★ **已暂停** —— 调度被暂停了（跑完当前这一场'
                              '就停手）。\n★ 点这一行的绿色 `[▶]` 可以**继续**。\n'
                              '★ **队列顺序没有被改动**。';
                        } else {
                          text = '运行中';
                          color = Colors.green;
                          icon = Icons.play_arrow;
                          msg = '★ **运行中** —— 当前正在运行的就是这一条。\n'
                              '它**不是固定的第一行**：调度按播放模式推进，'
                              '标记会跟着走到正在跑的那一条上。';
                        }
                        return Tooltip(
                          message: msg,
                          // ★★★ 2026-10-12 **白屏真凶就在这里**（二分法定位）★★★
                          //
                          // ## ★★ 排查过程（用户的数据一步步缩小范围）
                          //
                          // | 数据 | 排除了什么 |
                          // |---|---|
                          // | ★ 最大化也白 | ★ 与**窗口宽度**无关 |
                          // | ★ 停脚本后仍白 | ★ 与**是否在跑**无关 |
                          // | ★ 停掉"三个按钮"仍白 | ★ 与**按钮**无关 |
                          // | ★ 白屏**跟着"正在运行那行"走**、**只白一部分** | ★ 指向【这一块】|
                          // | ★ **停掉这一块 ⇒ 白屏消失** | ★★ **确认：真凶 = 这一块** |
                          //
                          // ## ★ 根因：**`Flexible` 套在 `Wrap` 里**
                          //
                          // ★ 外层容器已改为 **`Wrap`**（自适应换行）。
                          // ★ 而 `Flexible` **【必须】有 Flex 父级**（`Row`/`Column`/`Flex`）
                          //   —— ★ `Wrap` **不是** Flex
                          //   ⇒ ★ `Flexible` 拿不到"剩余宽度"的语义
                          //   ⇒ ★★ **布局期异常** ⇒ ★ release 下该子树**空白**
                          //     （★ 这正是"白屏只白一部分、且跟着运行行走"的成因）
                          //
                          // ★ 独立佐证：★ 我单独把外层 `Row` 换成 `Wrap` 时，
                          //   ★ "整行白"变成"**分隔成几段**" ——
                          //   ★ 就是 `Flexible` 语义失效后的表现。
                          //
                          // ## ★ 修法
                          //
                          // ★ **删掉这个 `Flexible`** —— ★ 标记按**自身内容宽度**渲染
                          //   （★ `_queueBadge` 内部已有 `mainAxisSize.min` + 省略号）
                          child: _queueBadge(
                            context,
                            text: text,
                            color: color,
                            icon: icon,
                          ),
                        );
                      }),
                    ] else if (isTask &&
                        ((e['total_runs'] as num?)?.toInt() ?? 0) > 0) ...[
                      // ★★★ 读 **`total_runs`**（累计），不是 `runs`（本轮/本周期）★★★
                      //
                      // ## ★★ 用户裁定（两份记录）★★
                      //
                      // > "一份**临时记录**只保留到当前（任务/周期）结束，
                      // >  **另一份共用的总记录**用于**结果展示**。"
                      //
                      // | 字段 | 内容 | 生命周期 |
                      // |---|---|---|
                      // | `runs` | 本轮/本周期已跑几次（**判据**）| 新一轮**清零** |
                      // | ★ `total_runs` | **累计**（**展示用**）| ★ **永不清零** |
                      //
                      // ⚠ 展示若读 `runs`，新一轮清零时"已运行 N 次"会**跟着归零**。
                      Tooltip(
                        message: '★ **已运行 N 次** —— 这一条**累计**跑过的次数。\n'
                            '★ 它取自**总记录**（`total_runs`）—— **永不清零**，\n'
                            '  所以换新一轮/新周期后这个数字**不会被抹掉**。\n'
                            '★ 计数**按条目**记（同一任务的多条条目互不混淆）。',
                        child: _queueBadge(
                          context,
                          text: '已运行 ${(e['total_runs'] as num).toInt()} 次',
                          color: Colors.blueGrey,
                          icon: Icons.check,
                        ),
                      ),
                    ],
                    // ★★★ F2d: 每行「▶ 播放」—— 点一下让**这一条**立刻跑 ★★★
                    //
                    // > 用户: "我还想添加一个按钮，**每个队列里的任务都有一个
                    // >  播放按钮**，点一下就可以**切换成正在运行**。"
                    //
                    // ★ 后端 `PUT /{script}/run_control/entry_play`
                    //   把该条目的 `next_run` 拉到现在（与"乱序"同一手法）
                    //   ⇒ 调度器下一轮自然选它，**不改调度核心**。
                    // ★ 正在跑的那一条不显示按钮（它已经在跑了）。
                    // ★★★ 片 11（用户最终裁定）: **暂停/恢复只在这一条上** ★★★
                    //
                    // ## ★★ 用户原话（两次收紧）★★
                    //
                    // > "这个**暂停调度/恢复调度**不是集成到**任务运行行里的
                    // >  按钮**上了吗，**这应该是 bug，不应该给别的按钮添加
                    // >  该功能造成混淆**。"
                    //
                    // > "**已暂停，只能是暂停中任务能恢复，这样才够优雅！**
                    // >  这个**恢复调度按钮是出现在暂停中任务行上**，
                    // >  **而不是任意行**"
                    //
                    // ## 三条分支（互斥，且**都锚在"那一条任务"上**）
                    //
                    // | 条件 | 按钮 | 点击 |
                    // |---|---|---|
                    // | ★ **正在跑 + 调度已暂停** | `[▶]` 绿 | **恢复 + 播放头设到这条** |
                    // | **正在跑**（未暂停）| `[⏸]` 橙 | **暂停调度** |
                    // | 未运行 | `[▶]` 描边 | 播放头设到这条 |
                    //
                    // ★ 关键：`e['running'] == true` 是**共同前提** ——
                    //   暂停/恢复**永远只长在"当前那一条"上**，
                    //   其它行只有"播放头"语义（`[▶]` 描边）。
                    // ★ 后端 `entry_play` 仍会顺带 `resume()`（幂等）——
                    //   所以点哪一条都不会出现"点了没反应"。
                    // ★ 边界兜底：**已暂停但"没有正在跑的那一条"**时，
                    //   恢复按钮落在**队首那一行**。
                    //
                    // ★ 什么时候会这样：
                    //   点 `[⏸]` 后，脚本在**安全点**才真的停手
                    //   （跑完当前这一场）—— 停手后 `script.py` 会
                    //   **清掉 `running_entry_id`** ⇒ 上面那个分支的
                    //   `e['running']` 变成 false ⇒ ★ **按钮消失** ⇒
                    //   用户**又找不到恢复入口**了。
                    // ★ 所以必须有一个兜底：**暂停态 + 没有任何条目在跑**
                    //   ⇒ 恢复按钮放在**队首**（恢复后就从它往下跑）。
                    //   ⚠ 这**不是**"任意行都能恢复" —— 只有**一行**有按钮。
                    if (isTask && c.schedulerPaused && e['running'] == true)
                      Tooltip(
                        message: '★ **恢复调度** —— 点它会**接着往下跑**。\n'
                            '★ 同时把**播放头**设回这一条（从这里继续）。\n'
                            '★ 队列顺序没有被改动过。',
                        child: IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 28, minHeight: 28),
                          onPressed: c.playingEntry == true
                              ? null
                              : () => _playEntry(context, c, e),
                          icon: const Icon(Icons.play_circle_filled,
                              size: 18, color: Colors.green),
                        ),
                      )
                    else if (isTask && c.schedulerPaused &&
                        noRunningRow && i == 0)
                      Tooltip(
                        message: '★ **恢复调度** —— 上次暂停后任务已停手。\n'
                            '★ 点它从**队首**继续往下跑。',
                        child: IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 28, minHeight: 28),
                          onPressed: c.playingEntry == true
                              ? null
                              : () => _playEntry(context, c, e),
                          icon: const Icon(Icons.play_circle_filled,
                              size: 18, color: Colors.green),
                        ),
                      )
                    // ★★★ [10-15] F9 修复：这里原来有一段**多余的 `else if`** ★★★
                    //
                    // 它的条件与**下面那一行**（`[⏸] 暂停调度` 分支）**逐字相同**
                    //   `isTask && e['running'] == true`
                    // ⇒ 按 Dart 的 if/else 语义，**下面那一段永远不可达**
                    // ⇒ ★ **`[⏸] 暂停调度` 从来不会显示** ——
                    //   这正是用户报的"**恢复调度按钮缺少了暂停调度**"。
                    //
                    // ★ 为什么它是多余的（不是"删错了"）：
                    //   "正在跑 **且** 调度已暂停" 的情况已经被**上面**那个分支
                    //   （`isTask && c.schedulerPaused && e['running'] == true`）接走；
                    //   走到这里的 `running == true` ⇒ **一定是"未暂停"**
                    //   ⇒ 按 §3.6 现行口径就该显示 **[⏸] 暂停调度**。
                    //   ⇒ ★ 删掉它，正好让本文件上方那张"三条互斥分支"表**成真**。
                    // ★ 守卫：`test/task_list_panel_test.dart` 的
                    //   `_f9PauseReachableTests()`（★ runtime 断言 `[⏸]` 真的渲染出来）
                    else if (isTask && e['running'] == true)
                      Tooltip(
                        message: '★ **暂停调度** —— 跑完**当前这一场**就停手。\n'
                            '★ **队列顺序不会被改动**（它是你编排的播放列表）。\n'
                            '★ 点「继续」后**接着往下跑**。',
                        child: IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 28, minHeight: 28),
                          onPressed: c.playingEntry == true
                              ? null
                              : () => _pauseSchedule(context, c),
                          icon: const Icon(Icons.pause_circle_filled,
                              size: 18, color: Colors.orange),
                        ),
                      )
                    else if (isTask)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 28, minHeight: 28),
                        tooltip: '让**这一条**立刻运行\n'
                            '（把**播放头**设到这一条；不改队列顺序）',
                        onPressed: c.playingEntry == true
                            ? null
                            : () => _playEntry(context, c, e),
                        icon: const Icon(Icons.play_circle_outline, size: 18),
                      ),
                    // ⚠ 这一行 `Flexible(` **必须留着** ——
                    //   我第一次插标记时把它挤掉了, `flutter analyze` 立刻报
                    //   `Undefined name 'child'`（下一个 widget 的 child 悬空）。
                      // ★ 步骤①：去掉 `Flexible` 包装（标题直接在容器里）
                      Text(
                        // ★★★ 休息任务的标题（用户裁定 乙-A）★★★
                        //
                        // > "休息就是临时任务（回庭院待着），只不过可以选择
                        // >  被定时任务插队。"
                        // > "需要**分钟**, 不是次数。"
                        //
                        // ★ `Rest` 是一个**真正的任务**（`tasks/Rest/`），
                        //   所以它走 `isTask` 分支；但标题要显示"休息 N 分钟"
                        //   而不是光秃秃的任务名 —— 分钟数取自
                        //   `c.taskRowOf('Rest')['target']`
                        //   （来自 `GET /{script}/overview` 的 `target` 字段,
                        //     = `rest.scheduler.target`）。
                        //
                        // ★★★ 2026-10-12 用户裁定：★ **标题改为"休息"** ★★★
                        //
                        // > "**如果我修改了次数，这个标题是也会变吗**，
                        // >  如果**不会变**，那么**把标题改为`休息`就行**。"
                        //
                        // ## ★ 实测结论：**不会变**
                        //
                        // ★ 原来标题读 `_restMinutesOf(c, cmd)` ⇒
                        //   ★ 它取的是**任务级** `rest.scheduler.target`
                        //     （由 `GET /overview` 返回）
                        //   ★ 而用户在那一行改的是**条目级** `target`
                        //     （★ 每条休息**各自独立**，见 §7.3）
                        //   ⇒ ★★ **改条目次数 ⇒ 标题不动**（用户实测确认）
                        //
                        // ## ★ 修法（★ 用户指定的做法）
                        //
                        // ★ 标题**只显示"休息"**（★ 不带分钟数）——
                        //   ★ 分钟数在**下面那一行的输入框**里（★ 那条按条目读写，
                        //     改完即时生效）。
                        isTask
                            ? (_isRestTask(cmd)
                                ? '休息'
                                : _zhName(cmd, c))
                            : '休息 ${e['minutes']} 分钟',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              // ★ 未到开放时间 -> 变灰（用户: "直接变灰放到等待中就行"）
                              color: isPending
                                  ? null
                                  : Theme.of(context).disabledColor,
                            ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    // ★ 步骤①：原来的 `Flexible(` 已去掉
                    if (isTask && isAuto) ...[
                      const SizedBox(width: 6),
                      Tooltip(
                        message: '周期任务启用后自动进入队列（不需要手动添加）',
                        child: Icon(Icons.autorenew,
                            size: 13,
                            color: Theme.of(context).colorScheme.primary),
                      ),
                    ],
                    // ★★ C-5: 同一任务出现**多条**时, 显示"第几条 + 加入时间"
                    //    以区分它们（否则界面上两个"个人突破"分不清）★★
                    if (isTask && c.queuedCountOf(cmd) > 1) ...[
                      const SizedBox(width: 6),
                      Tooltip(
                        message: '同一个任务在队列里加了多条 —— '
                            '**每一条都会跑一轮**（这是"重复跑整个任务"的方式）',
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .secondaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _dupLabel(e, c),
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (isTask) _statusBadge(context, c, cmd),
              // 移出队列 —— **带确认弹窗**（定时任务会同时停用; 次数任务只出队列）
              IconButton(
                icon: const Icon(Icons.remove_circle_outline, size: 16),
                tooltip: '移出队列（周期任务会同时停用）',
                visualDensity: VisualDensity.compact,
                onPressed: () async {
                  if (isTask) {
                    // ★ ⑨: 带上**条目身份** —— 否则同名多条会被**一删全删**
                    final eid = '${e['_entryId'] ?? ''}';
                    final eidOrNull = eid.isEmpty ? null : eid;
                    // ★★ ⑤: **次数类不弹确认**, 定时类才弹（用户要求）★★
                    //
                    // 用户原话: "**次数类任务被移除时不需要弹窗确认,
                    //           只有定时类任务才需要。**"
                    //
                    // 理由（我理解的）: 次数任务移除只是"出队列", 不会停用,
                    // 加回来一步就够, 弹窗是多余的摩擦; 而定时任务移除会
                    // **同时停用**, 影响更大, 值得确认。
                    if (!c.isAutoQueue(cmd)) {
                      final msg =
                          await c.removeFromQueue(cmd, entryId: eidOrNull);
                      if (!context.mounted) return;
                      Get.snackbar('已移出队列', msg,
                          snackPosition: SnackPosition.BOTTOM,
                          duration: const Duration(seconds: 5));
                    } else {
                      await confirmAndRemove(context, c, cmd,
                          entryId: eidOrNull);
                    }
                  } else {
                    // 「休息」条目只存在于 run_list -> 直接按条目下标删
                    final ei = e['_entryIndex'];
                    if (ei is int && ei >= 0 && ei < c.entries.length) {
                      c.entries.removeAt(ei);
                      await c.saveEntriesNow();
                      await c.reload();
                    }
                  }
                },
              ),
            ],
          ),
          // 次数 / 预期耗时 —— 就在任务下面（用户要求"放在任务上边"）
          // ★ 传 `e`（**这一条条目**）—— 次数按条目读写（修"改一条全变"）
          if (isTask) _settingsRow(context, c, cmd, e),
          // ★★★ 片 10 (F2c/②): **「暂停/继续调度」在队首右侧** ★★★
          //
          // ## ★★ 用户原话 ★★
          //
          // > "**② 暂停/开始调度移到队首右侧；原位置换成「停止脚本」**"
          //
          // ★ 为什么放**队首行**：它管的是"**队列要不要继续往下走**" ——
          //   而队首正是"下一个要跑的"位置 ⇒ **操作与对象在同一处**。
          // ★ 原来它在**运行控制条**（`run_control_bar.dart`）里 ——
          //   与"脚本进程开关"混在一起，用户要把它**移到队首右侧**。
          //
          // ⚠ 只画在**第一行**（`i == 0`）—— 队列里只需要一个开关，
          //   每行都画会变成一堆重复按钮。
          // ⚠ **右对齐**（`Align` + `Alignment.centerRight`）——
          //   这就是用户说的"队首**右侧**"；不硬塞进上面那个 `Row`
          //   （那里已经很满，挤进去会把任务名压扁）。
          // ★★★ 片 11: 队首行右侧的 `[⏸]` **已删除**（用户裁定）★★★
          //
          // > "**[⏸ 暂停调度] 应该和队列中任务点击运行那个按钮是一个东西，
          // >   放在外边就冗余了**"
          //
          // ⇒ ★ 暂停按钮现在**长在"正在运行的那一条"上**（与 `[▶]` 互斥），
          //   见上面那个 `if (isTask && e['running'] == true)` 分支。
          // ⇒ ★ 所以这里**不再单独画一个**（否则又变成"两个暂停"）。
        ],
      ),
    ),
  );
}

/// ★★★ 片 10 (F2c/②): **「暂停调度 / 继续调度」** —— 放在**队首行右侧** ★★★
///
/// ## ★★ 用户原话 ★★
///
/// > "**② 暂停/开始调度移到队首右侧；原位置换成「停止脚本」**"
///
/// ★ 它管的是"**队列要不要继续往下走**"，而队首正是"下一个要跑的"
///   ⇒ **操作与对象在同一处**（原来它在运行控制条里，与"脚本进程开关"混在一起）。
///
/// ★ 用 `GetBuilder`（不是 `Obx`）—— 跟随 `TaskListController.reload()` 刷新，
///   与 `RunControlBar` 同一手法（避免自己造一套刷新机制）。
/// ★★★ `[⏸] 暂停调度` —— **在"正在运行的那一行"上**（用户裁定）★★★
///
/// ## ★★ 用户原话 ★★
///
/// > "**[⏸ 暂停调度] 应该和队列中任务点击运行那个按钮是一个东西，
/// >   放在外边就冗余了**"
/// > "正在运行的行 [⏸] → **暂停调度**"
///
/// ★ 所以它**不在**卡片标题行，也不在共用顶部 ——
///   只在**正在跑的那一条**上（与 `[▶]` 互斥）。
///
/// ★ **不再"退回队首"**：
/// > "这个执行顺序就是个**播放列表**，**退回队首不应该是软件来操作的**"
/// ⇒ 后端 `put_pause` 已删掉 requeue 逻辑。
Future<void> _pauseSchedule(BuildContext context, TaskListController c) async {
  try {
    final res = await ApiClient().pauseScriptDetailed(c.script);
    if (!context.mounted) return;
    Get.snackbar(
      '已暂停调度',
      '${res['message'] ?? '跑完当前这一场就停手；队列顺序不动'}',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 6),
    );
    await c.reload();
  } catch (e) {
    if (context.mounted) {
      Get.snackbar('暂停失败', '$e', snackPosition: SnackPosition.BOTTOM);
    }
  }
}

/// 一行的**次数 / 预期耗时 / 优先级**（内联可编辑）。
///
/// ★ 复用 `_NumberCell` —— 与任务表格里用的是**同一个组件**
///   （失焦/回车才提交、有焦点时不覆盖用户输入、正确 dispose）。
///
/// ⚠ 写入接口要的是**下划线键**（`row['name']`，如 `experience_youkai`），
///   不是大驼峰命令名（`ExperienceYoukai`）—— 踩过这个混淆。
///
/// ★★★ 为什么必须带上 `entry`（条目对象）★★★
///
/// 用户报的 bug:
/// > "当前临时任务**重复添加**后，修改**次数/时间会同步到所有的同种任务**，
/// >  而不是分开"
///
/// ★ 根因: "次数"原来只写**任务级** `scheduler.target` —— 而队列里同一任务
///   可以有多条条目 ⇒ 改一条 = 所有同任务条目一起变。
/// ★ 修法: **次数读写都按条目**（`entry['target']`），
///   任务级 `scheduler.target` 只作**默认值**（用户裁定 **甲**）。
Widget _settingsRow(BuildContext context, TaskListController c, String cmd,
    Map<String, dynamic> entry) {
  final row = c.taskRowOf(cmd);
  final key = '${row['name']}';
  final countable = row['countable'] == true;
  // ★★★ 休息任务: 用**同一套字段**（`scheduler.target`）表达**分钟** ★★★
  //
  // 用户裁定（乙-A）:
  // > "有 period 和 window 属性, 是为了**统一管理**。"
  // > "需要**分钟**, 不是次数。"
  //
  // ★ 所以休息**不新增字段** —— 它的"分钟"就在 `scheduler.target`
  //   那个通用的"目标次数"框里。这里只是把**标签**改成"休息(分钟)"，
  //   让用户知道自己填的是分钟（而不是打几次）。
  final isRest = _isRestTask(cmd);
  // ★★ 条目级次数（用户裁定 —— 修 bug）★★
  //
  // | 值 | 含义 |
  // |---|---|
  // | `entry['target'] > 0` | ★ **这一条**跑几次 |
  // | `0` / 没有该键 | 用**任务级默认值**（`row['target']`）|
  final entryTarget = c.entryTargetOf(entry);
  final taskLevel = (row['target'] as num?)?.toInt() ?? 0;
  final target = entryTarget > 0 ? entryTarget : taskLevel;
  final fallback = (row['count'] as num?)?.toInt();
  final expected = (row['expected_minutes'] as num?)?.toInt() ?? 0;

  return Padding(
    padding: const EdgeInsets.only(left: 50, bottom: 4, top: 2),
    child: Wrap(
      spacing: 10,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // ★ 休息走这一支（`countable=false`），所以下面那个"次数"框
        //   对它**不适用** —— 用这个"休息(分钟)"框代替，**同一个字段**。
        //
        // ★★ 也是**条目级**（修"改一条全变"）★★
        //   用户裁定 乙-A: 休息是**真正的任务**, 分钟数 = `scheduler.target`。
        //   ⚠ 但队列里可以加**多条**休息（"歇 10 分钟" + "歇 1 小时"）——
        //     所以分钟数必须**按条目**存, 否则改一条 = 全变。
        //   ★ 后端 `_rest_minutes()` 已经**优先读条目级**, 这里只是跟上。
        if (isRest) ...[
          Text('休息(分钟)', style: Theme.of(context).textTheme.labelSmall),
          _NumberCell(
            key: ValueKey('q-rest-min-$cmd-$target-$entryTarget'),
            value: target > 0 ? target : _restMinutesOf(c, cmd),
            width: 60,
            hint: '分钟',
            min: 1,
            max: 24 * 60,
            onCommit: (n) async {
              // ★ 写**这一条**的分钟（不再写任务级）
              await c.setEntryTarget(entry, n);
            },
          ),
        ],
        if (countable) ...[
          Text('次数', style: Theme.of(context).textTheme.labelSmall),
          _NumberCell(
            key: ValueKey('q-count-$cmd-$target-$entryTarget'),
            value: target,
            width: 60,
            hint: fallback == null ? '默认' : '默认 $fallback',
            min: 0,
            max: 999,
            onCommit: (n) async {
              // ★★ 写**这一条**的次数（不再写任务级 —— 那会"改一条全变"）★★
              await c.setEntryTarget(entry, n);
            },
          ),
        ],
        Text('预期耗时(分)', style: Theme.of(context).textTheme.labelSmall),
        _NumberCell(
          key: ValueKey('q-expected-$cmd-$expected'),
          value: expected,
          width: 60,
          hint: '未知',
          min: 0,
          max: 1440,
          onCommit: (n) async {
            await c.setTaskExpectedMinutes(key, n);
            await c.reload();
          },
        ),
        // ★★★ 片 9: **「优先级」已删除**（用户裁定：废弃词条）★★★
        //
        // ## ★★ 用户原话 ★★
        //
        // > "这个**优先级似乎没有意义，应该属于废弃词条**了，
        // >  查一查看看要不要**全部删了**。"
        //
        // ## 实测依据（我查过）
        //
        // ```
        // ★ 调度 get_next() 按 next_run 排序 —— ★ 【不含 priority】
        // ★ Function.priority (config.py:94) 只被一个【调试字符串】用过
        // ★ 前端 setTaskPriority() 会【写】它, 但调度【不读】
        // ⇒ ★ 它是"死读死写链" —— 对"谁先跑"没有任何影响
        // ```
        //
        // ★ 顺序的**唯一权威是执行队列**（`_order_by_queue()`）——
        //   所以这里不再暴露"优先级"输入框。
        // ⚠ 后端字段**暂时保留**（老配置兼容 + 任务列表页仍可按它排序）；
        //   彻底删字段是**独立一片**（见台账）。
        // ★★ ④: **进该任务的设置页**（用户要求"**别的任务行上也应该有**"）★★
        //
        // ## ⚠⚠ 重要澄清（2026-10-11 用户纠正）⚠⚠
        //
        // 用户原话:
        // > "④任务设置入口　**删掉**（队列行已有设置）"
        //
        // ★ 我**理解错了** —— 以为是"删队列行的设置"。
        //   用户的纠正:
        // > "我说的应该是**正在运行行上的设置入口不需要**，
        // >  而**不是队列行的设置删掉**！"
        //
        // ⇒ 那个"要删掉的设置入口"在**旧「正在运行」整行**上 ——
        //   而那一行**已经被整块删掉了**（片 5 / F2b）⇒ **本项早已完成**。
        // ⇒ ★ **队列行的「设置」必须留着**（正是"别的任务行上也应该有"）。
        //
        // 实测: 调度 tab 的 `TaskRowView` 有 `onTap -> openTaskSettings`,
        // 而队列行**没有** -> 用户看到"设置入口只在正在运行的任务行上"。
        //
        // ★ 用 `openTaskSettings` 而不是 `switchContent`: 后者有
        //   `useablemenus` 白名单（只列侧边栏里有的任务）, 点不在侧边栏的
        //   任务会被**静默忽略** -> "点了没反应"（踩过, 见 task_list_view）。
        Tooltip(
          message: '打开「${_zhName(cmd, c)}」的**任务设置**',
          child: TextButton.icon(
            icon: const Icon(Icons.tune, size: 15),
            label: const Text('设置'),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 28),
            ),
            onPressed: () => Get.find<NavCtrl>().openTaskSettings(cmd),
          ),
        ),
      ],
    ),
  );
}

/// 命令名 -> **中文名**（拿不到就原样返回, 不显示空白）。
String _zhName(String command, TaskListController c) {
  final zh = c.zhNameOf(command);
  return zh.isEmpty ? command : zh;
}

/// ★★★ 休息任务（`Rest`）的两个小工具 ★★★
///
/// ## 依据（用户裁定 乙-A）
///
/// > "休息就是临时任务（回庭院待着），只不过可以选择被定时任务插队。"
/// > "有 period 和 window 属性, 是为了**统一管理**。"
/// > "需要**分钟**, 不是次数。"
///
/// ★ 所以"休息"是 `tasks/Rest/` 里的一个**真正的任务**，
///   而它的**分钟数**就是通用的 `scheduler.target`
///   （那个"目标次数"框对休息的语义 = 分钟）。
///
/// ⚠ 为什么只认 `'Rest'` 这一个名字: 它是 `tasks/Rest/meta.py` 里
///   `TaskSpec.task` 的值 —— **唯一契约**。★ 不猜别名。
const String _kRestTask = 'Rest';

/// 这个命令名是不是休息任务。
bool _isRestTask(String command) => command == _kRestTask;

/// 休息**多少分钟** —— 从 `/overview` 的 `target` 读（权威来源）。
///
/// ★ 拿不到时回退到 **30**（与后端 `Config.REST_DEFAULT_MINUTES` **同一值**）
///   —— ★ 两处必须一致, 否则界面显示的数字与实际休息时长会不同。
///   ⚠ 若后端改了那个常量, **这里也要改**（已用注释交叉引用）。
int _restMinutesOf(TaskListController c, String command) {
  final row = c.taskRowOf(command);
  final t = (row['target'] as num?)?.toInt() ?? 0;
  return t > 0 ? t : 30;
}

/// 从**全部任务**里挑一个加入队列（也能加「休息」）。
///
/// ★ 本函数是**顶层**的: 队列面板的「添加任务」按钮在 header（外层
///   `CustomScrollView` 的 sliver）里, 而"去添加"在尾部 —— 两处都要用它,
///   而它们都不再住在同一个 State 里。
Future<void> pickAndAddToQueue(BuildContext context, TaskListController c) async {
  final picked = await showDialog<_PickedEntry>(
    context: context,
    builder: (ctx) => _TaskPickerDialog(controller: c),
  );
  if (picked == null) return;
  if (picked.isRest) {
    if (!context.mounted) return;
    await _addRest(context, c);
    return;
  }
  await c.appendToQueue(picked.task);
  await c.reload();
}

/// 添加一个「休息 N 分钟」条目（时长选项来自 `/schema`，不硬编码）。
Future<void> _addRest(BuildContext context, TaskListController c) async {
  final rest = c.entryKinds.firstWhere(
    (k) => '${k['value']}' == 'rest',
    orElse: () => const {'value': 'rest', 'label': '休息', 'help': ''},
  );
  final minutes = await showDialog<int>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text('添加「${rest['label']}」'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Text('${rest['help']}',
              style: Theme.of(ctx).textTheme.labelMedium),
        ),
        for (final m in c.durationChoices)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, m),
            child: Text(m >= 60 && m % 60 == 0 ? '${m ~/ 60} 小时' : '$m 分钟'),
          ),
      ],
    ),
  );
  if (minutes == null) return;
  // ★★★ 用户裁定 乙: 添加一条**真正的 `Rest` 任务条目** ★★★
  //
  // ## 改动前（旧模型）
  //
  // ```dart
  // await c.addEntry({'kind': '${rest['value']}', 'minutes': minutes});
  // ```
  // ★ 造一个 `kind='rest'` 的**特殊条目** —— 它没有 `enable`/`period`/
  //   `windows`，所以"格格不入"（用户原话）。
  //
  // ## 现在（乙-A 模型）
  //
  // > "休息就是临时任务（回庭院待着），只不过可以选择被定时任务插队。"
  // > "有 period 和 window 属性, 是为了**统一管理**。"
  //
  // ★ 所以加的是 `Rest` **任务**（普通条目），它天然拥有
  //   `enable` / `target`(分钟) / `period` / `windows` —— 一套通用字段。
  //
  // ## ★ 三步，顺序有讲究
  //
  // | # | 动作 | 为什么 |
  // |---|---|---|
  // | 1 | `setEnabled('rest', true)` | ★ **必须先启用** —— `GET /queue/candidates` 的规则是 `enable == True` 才算候选；未启用时它不在候选里（用户原话: "如果需要进队列, 那么需要先在任务列表启用"）|
  // | 2 | `setTarget('rest', minutes)` | ★ 分钟数写进通用的 `scheduler.target`（用户: "需要分钟, 不是次数"）|
  // | 3 | `appendToQueue('Rest')` | 加一条**普通任务条目**（`kind='task'`, `task='Rest'`）|
  //
  // ⚠ 键名用**下划线形式**（`rest`），不是大驼峰命令名（`Rest`）——
  //   `setEnabled`/`setTarget` 写的是 `script.<key>.scheduler.<field>`（踩过这个混淆）。
  // ★★★ 2026-10-12 修：★ **分钟数写进【条目级】`target`** ★★★
  //
  // ## ★★ 用户报的 bug
  //
  // > "添加进去后甚至**标题都是休息 X 分钟**，我怀疑代码逻辑里有
  // >  **固定死的写法**，导致**无法更改次数**。"
  //
  // ## ★ 根因
  //
  // ★ 原来只写**任务级** `setTarget('rest', minutes)` ——
  //   ★ 那是**全局默认值**，★ 所有休息条目共用 ⇒ ★ 改一条全变
  //   ⇒ ★ 用户感觉"固定死、改不了"（★ 而且新建的条目读到的是
  //     配置里残留的旧值，如 5 分钟）。
  //
  // ## ★ 修法
  //
  // ★ 分钟数写进**条目级** `target`（★ `appendToQueue(..., target: minutes)`）
  //   ⇒ ★ 每条休息**各自独立**。
  // ★ 同时**仍**写一次任务级（作为新条目的默认值）—— ★ 保留但不再是唯一来源。
  await c.setEnabled('rest', true);
  await c.setTarget('rest', minutes);
  await c.appendToQueue(_kRestTask, target: minutes);
}

/// C-5: 重复条目的标签 —— `第 2 条 · 10-10 14:30`。
///
/// 同一任务在队列里出现多条时, 靠它区分（否则界面上分不清哪个是哪个）。
/// 拿不到加入时间就只显示"第 N 条"（**不猜**）。
String _dupLabel(Map<String, dynamic> e, TaskListController c) {
    final cmd = '${e['task']}';
    // 它在同任务里的序号（第几条）
    var n = 0;
    for (final r in c.queuedTaskRows) {
      if ('${r['kind']}' != 'task' || '${r['task']}' != cmd) continue;
      n++;
      if (identical(r, e) || r['_entryId'] == e['_entryId'] &&
          r['_entryIndex'] == e['_entryIndex']) {
        break;
      }
    }
    final raw = '${e['_addedAt'] ?? ''}';
    if (raw.isEmpty) return '第 $n 条';
    final at = DateTime.tryParse(raw);
    if (at == null) return '第 $n 条';
    String two(int x) => x.toString().padLeft(2, '0');
    return '第 $n 条 · ${two(at.month)}-${two(at.day)} '
        '${two(at.hour)}:${two(at.minute)}';
  }

/// **状态徽标** —— 说明这个任务为什么在等。
///
/// 数据来自后端（`slot` / `reason` / `in_cooldown`）,
/// 前端**不重新推导**调度规则。
Widget _statusBadge(BuildContext context, TaskListController c, String cmd) {
  final s = c.queueStatusOf(cmd);
  final scheme = Theme.of(context).colorScheme;
  final color = switch (s.tone) {
    0 => Colors.green, // 待执行
    1 => scheme.primary, // 等待中
    3 => scheme.error, // 冷却中
    _ => Theme.of(context).disabledColor, // 未启用 / 未知
  };
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Text(
      s.label,
      style: Theme.of(context)
          .textTheme
          .labelSmall
          ?.copyWith(color: color, fontWeight: FontWeight.w600),
    ),
  );
}

/// ★★ S6: **类别分段条**（放在队列**上方**）★★
///
/// 显示成: `定时任务 3 条` ｜ `固定任务 12 条`, 前段那一边**高亮**。
///
/// ★ 与队列**同一顺序依据**: `c.queuedTaskRows`（后端 `_segment_queue()`
///   已按模式排好段）—— 所以"第一个出现的段"就是"排在前面的段"。
///
/// ★ 它**不参与拖拽**（在可拖列表**外面**, 走 `SliverToBoxAdapter`）,
///   不会打乱 `reorderQueue` 的下标。
///
/// ⚠ **不能**用 `Get.find<TaskListController>()` —— 队列面板在多账号场景
///   下靠 **tag** 注册; 无 tag 的 `find` 会**抛异常**（实测 2 个测试失败）。
///   ★ 本函数是**顶层函数**（没有 State 的 `c` getter）, 所以 `c` 一律
///   由调用方传进来。
Widget _segmentBar(BuildContext context, TaskListController c) {
  final rows = c.queuedTaskRows
        .where((r) => '${r['kind']}' == 'task')
        .toList();
    if (rows.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    String gid(Map<String, dynamic> r) => '${r['group'] ?? 'fixed'}';
    final firstGroup = gid(rows.first);
    final nTimed = rows.where((r) => gid(r) == 'timed').length;
    final nFixed = rows.length - nTimed;
    final timedFirst = firstGroup == 'timed';

    Widget seg(String label, int n, bool timed, bool leading) {
      final on = leading;      // 排在前面的段高亮
      final col = timed ? scheme.primary : scheme.tertiary;
      return Container(
        margin: const EdgeInsets.only(right: 6, bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: on ? col.withValues(alpha: 0.18) : null,
          border: Border.all(
              color: on ? col : scheme.outlineVariant,
              width: on ? 1.2 : 1),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          '$label $n 条',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: on ? col : scheme.onSurfaceVariant,
                fontWeight: on ? FontWeight.w700 : FontWeight.w400,
              ),
        ),
      );
    }

    return Tooltip(
      // ★★★ S7: 文案改了（用户裁定）★★★
      //
      // 原来写的是「当前「XX」模式下, 队列**按类别分段** …… **只能在同一
      // 段内拖动**。想自由拖动请把「调度优先级」改成「自定义」。」
      //
      // ★ 三模式与跨类别约束都删了 -> 那段话**已经不成立**。
      // ★ 现在只说清"这是什么"与"能怎么拖"。
      // ★★ P-2: 「休息」也不再"固定排最后"（用户裁定, 见 OAS `832f467e`）★★
      message: '这是当前执行队列里**周期任务 / 临时任务**各有多少条。\n'
          '${timedFirst ? "周期任务" : "临时任务"}段目前排在前面。\n'
          '★ **所有条目都能自由拖动**, 不限类别 —— **包括「休息」**。\n'
          '★ 「休息」拖到中间时, 它**后面**的任务会等到休息结束才跑'
          '（这是**防封**设计, 符合预期）。',
      child: Wrap(
        children: [
          seg('周期任务', nTimed, true, timedFirst),
          seg('临时任务', nFixed, false, !timedFirst),
        ],
      ),
    );
}


/// 选择器的返回值 —— 要么是一个任务，要么是「休息」。
class _PickedEntry {
  const _PickedEntry.task(this.task) : isRest = false;
  const _PickedEntry.rest()
      : task = '',
        isRest = true;

  final String task;
  final bool isRest;
}

/// 任务选择对话框 —— 【添加任务】。
///
/// ## ★ 候选来自**后端端点**（不在前端重新实现过滤）
///
/// `GET /{script}/queue/candidates` 的规则:
///     `enable == True` **且** `auto_queue == False` **且** `queued == False`
///
/// 即 **已启用的次数任务, 且还没进队列的**。
///
/// ★ 为什么未启用的**不出现**（用户原话）:
///   "剩余的 34 个任务未启用，其中的次数任务并不会出现在添加任务按钮中，
///    如果需要进队列，那么需要先在任务列表启用，再添加任务才能进队列"。
///
/// ★ 为什么不在这里过滤 `allTasks`:
///   规则只有一处（后端），前端重复实现会**漂移** —— 本项目已因
///   "知识存在两处"栽过多次。
///
/// ## 「休息」仍然置顶
///
/// 它不是任务, 是控制条目 —— 与候选过滤无关, 始终可选。
class _TaskPickerDialog extends StatefulWidget {
  const _TaskPickerDialog({required this.controller});

  final TaskListController controller;

  @override
  State<_TaskPickerDialog> createState() => _TaskPickerDialogState();
}

class _TaskPickerDialogState extends State<_TaskPickerDialog> {
  String _q = '';
  List<Map<String, dynamic>>? _candidates;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.controller.fetchAddCandidates();
      if (!mounted) return;
      setState(() => _candidates = list);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _candidates = const [];
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = _candidates;
    var list = all ?? const <Map<String, dynamic>>[];
    if (_q.isNotEmpty) {
      final q = _q.toLowerCase();
      list = list
          .where((t) =>
              '${t['name_zh']}'.contains(_q) ||
              '${t['command']}'.toLowerCase().contains(q))
          .toList();
    }

    return AlertDialog(
      title: const Text('添加任务'),
      content: SizedBox(
        width: 460,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---------- 「休息」置顶（控制条目, 非任务）----------
            Card(
              margin: EdgeInsets.zero,
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.hotel, size: 20),
                title: const Text('休息（去庭院待着）'),
                subtitle: const Text('到这一行会停下来等 N 分钟'),
                onTap: () => Navigator.pop(context, const _PickedEntry.rest()),
              ),
            ),
            const Divider(height: 16),
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: '搜索任务名…',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _q = v.trim()),
            ),
            const SizedBox(height: 8),
            Expanded(child: _body(context, list, all)),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
      ],
    );
  }

  Widget _body(BuildContext context, List<Map<String, dynamic>> list,
      List<Map<String, dynamic>>? all) {
    if (all == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text('候选获取失败: $_error'));
    }
    if (all.isEmpty) {
      // ★ 空态要给**原因与出路**, 不能只说"没有"
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('没有可添加的任务'),
              const SizedBox(height: 8),
              Text(
                '这里只列「已启用、需要手动加入队列」的**次数任务**。\n'
                '· 定时类任务（逢魔之时 / 地域鬼王…）启用后会**自动**进队列，不在此列\n'
                '· 次数任务要先在**任务列表**里启用，再回来添加',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).disabledColor,
                    ),
              ),
            ],
          ),
        ),
      );
    }
    if (list.isEmpty) {
      return const Center(child: Text('没有匹配的任务'));
    }
    // ★★ 允许**重复添加同一任务**（用户 2026-10-10 裁定）★★
    //
    // 用户原话:
    //   "现在的任务执行里**添加任务应该设置为可以重复添加相同的任务**,
    //    这样就**变相实现了多次跑任务**"
    //
    // 所以这里**不再隐藏**已在队列的任务, 改为**标注**"已在队列 ×N",
    // 让用户知道"再点一次就是再加一轮"。
    final queuedCount = <String, int>{};
    // ⚠ 这里在 `_TaskPickerDialogState` 里, 控制器是 `widget.controller`,
    //   **没有** `c` 这个简写（`c` 是 `_QueuePanelState` 里的 getter）——
    //   写 `c` 会 `Undefined name 'c'`（踩过）。
    for (final r in widget.controller.queuedTaskRows) {
      if ('${r['kind']}' != 'task') continue;
      final k = '${r['task']}';
      queuedCount[k] = (queuedCount[k] ?? 0) + 1;
    }

    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (_, i) {
        final t = list[i];
        final cmd = '${t['command']}';
        final n = queuedCount[cmd] ?? 0;
        return ListTile(
          dense: true,
          title: Row(
            children: [
              Flexible(child: Text('${t['name_zh']}')),
              if (n > 0) ...[
                const SizedBox(width: 6),
                // ★ 不写括号解释, 用 Tooltip（用户要求"括号改悬停"）
                Tooltip(
                  message: '队列里已有 $n 条。\n'
                      '再点一次会**再加一条** —— 同一任务排多条,\n'
                      '就是让它多跑几次（这是变相实现"跑多次"的方式）。',
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('已在队列 ×$n',
                        style:
                            Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color: Theme.of(context).colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                )),
                  ),
                ),
              ],
            ],
          ),
          subtitle: Text(
            '${t['category_label'] ?? ''} · $cmd'
            '${'${t['resource_describe'] ?? ''}'.isEmpty ? '' : ' · ${t['resource_describe']}'}',
          ),
          // ★ 已在队列的也能再点（重复添加是允许的）
          trailing: const Icon(Icons.add, size: 18),
          onTap: () => Navigator.pop(context, _PickedEntry.task(cmd)),
        );
      },
    );
  }
}
