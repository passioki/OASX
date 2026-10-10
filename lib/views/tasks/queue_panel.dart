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
class QueuePanel extends StatefulWidget {
  const QueuePanel({super.key, required this.controller});

  final TaskListController controller;

  @override
  State<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<QueuePanel> {
  TaskListController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
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
    final sm = _scriptModel();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
                  onPressed: () => _pickAndAdd(context),
                  icon: const Icon(Icons.add, size: 16),
                  label: Text('添加任务'
                      '${c.enabledNotQueuedTasks.isEmpty ? '' : ' (${c.enabledNotQueuedTasks.length})'}'),
                ),
                // ★★ ⑦: **一键清空队列**（带确认弹窗）★★
                //
                // 语义与"单个移除"一致: 后端会把 `run_list` 置空 **并**停用所有
                // `auto_queue` 任务 —— 否则它们会被 `build_queue()` 补回队列。
                // **不删任何任务配置**, 随时可以重新启用 + 加回来。
                TextButton.icon(
                  onPressed: () => _confirmClearQueue(context),
                  icon: const Icon(Icons.playlist_remove, size: 16),
                  label: const Text('清空队列'),
                ),
              ],
            ),

            // ---------- 分类 0: 调度器 + 正在运行 ----------
            _statusBlock(context, sm),

            const SizedBox(height: 8),
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
            // **一个** `ReorderableListView`, 渲染 `c.queuedTaskRows`
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
                Text('执行顺序（拖 ⠿ 调整）',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        )),
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
            else ...[
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
              _segmentBar(context),
              // ★ 用 `ReorderableListView` 拖拽 ——
              //   `shrinkWrap` + `NeverScrollableScrollPhysics`:
              //   它住在外层 `ListView` 里, 自己不该再滚。
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: c.queuedTaskRows.length,
                onReorder: c.reorderQueue,
                itemBuilder: (_, i) => _queueRow(context, i),
              ),
            ],

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
                  TextButton(
                    onPressed: () => _pickAndAdd(context),
                    child: const Text('去添加'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// **调度器状态 + 正在运行**（合并成一个观察块）。
  ///
  /// ★ 这两条本来就是一件事 —— "调度器在跑吗 / 现在在跑什么"。
  Widget _statusBlock(BuildContext context, dynamic sm) {
    if (sm == null) {
      // ★ 服务未就绪 —— **不进 `Obx`**（没有 Rx 可读会让 GetX 抛异常）
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Text('（还没有运行状态 —— 脚本未启动）',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).disabledColor,
                )),
      );
    }
    return Obx(() => _statusContent(context, sm));
  }

  Widget _statusContent(BuildContext context, dynamic sm) {
    final state = sm.state.value;
    final running = state == ScriptState.running;
    return _runningRow(context, sm.runningTask.value, running: running);
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
  dynamic _scriptModel() {
    try {
      if (!Get.isRegistered<ScriptService>()) return null;
      return Get.find<ScriptService>().scriptModelMap[c.script];
    } catch (_) {
      return null;
    }
  }

  /// 「正在运行」这一行的**内容**（读 Rx 的结果传进来, 便于单独测/复用）。
  ///
  /// `running` = **调度器**是否在跑（`ScriptState.running`）;
  /// `cur`     = **此刻在跑的任务**（可能为 null = 空闲）。
  ///
  /// ★ 两者分开显示: 调度器在跑但两个任务之间会有短暂空闲,
  ///   那时"空闲"是对的（不是状态错了）。
  Widget _runningRow(BuildContext context, dynamic cur, {bool running = true}) {
    final name = (cur == null) ? '' : '${cur.taskName}';
    final busy = name.isNotEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
      color: busy ? Colors.green.withValues(alpha: 0.12) : Colors.transparent,
      child: Row(
        children: [
          Icon(
            running ? Icons.play_circle : Icons.pause_circle_outline,
            size: 18,
            color: running ? Colors.green : Colors.grey,
          ),
          const SizedBox(width: 6),
          // 调度器状态（中文 —— 直接 `'$state'` 会打印英文枚举名）
          Text(running ? '调度中' : '调度已停止',
              style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(width: 10),
          const VerticalDivider(width: 1),
          const SizedBox(width: 10),
          Icon(
            busy ? Icons.play_arrow : Icons.pause,
            size: 18,
            color: busy ? Colors.green : Theme.of(context).disabledColor,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              busy ? '正在运行: ${_zhName(name)}' : '正在运行: （空闲）',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: busy ? FontWeight.bold : null,
                    color: busy ? null : Theme.of(context).disabledColor,
                  ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (busy)
            TextButton(
              onPressed: () => Get.find<NavCtrl>().openTaskSettings(name),
              child: const Text('任务设置'),
            ),
          // ★★★ 「取消任务」按钮**已删除**（用户最终裁定）★★★
          //
          // 用户原话:
          // > "**就把这个功能聚合到暂停调度按钮上好了**, 点击暂停调度,
          // >  正在运行的任务**自动回退到队列首位, 视作等待执行**,
          // >  这样是不是更优雅。"
          //
          // ★ 是更优雅 —— "取消"与"暂停"本来就是同一个动作:
          //   停手 + 手头这个退回队首待命。所以**不需要**第二个按钮。
          // ★ 现在由 `RunControlBar` 的「暂停调度」按钮承担（见 `run_control_bar.dart`）,
          //   后端 `put_pause` 会**同时**做:置暂停 + 把 `running_task` 退回队首。
        ],
      ),
    );
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
  Future<void> _confirmAndRemove(BuildContext context, String cmd,
      {String? entryId}) async {
    final zh = _zhName(cmd);
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
  Future<void> _confirmClearQueue(BuildContext context) async {
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
  /// ★★ F6: 现在渲染 **`c.queuedTaskRows`**（有效队列）, 不是 `c.entries`。
  ///
  /// 两种来源:
  /// * `_queuedRow == false` -> 来自 `run_list`（用户编排, 含「休息」条目）
  /// * `_queuedRow == true`  -> **自动补齐**的定时任务（后端 `queued` 里有,
  ///   但不在 `run_list` 里）—— 用户报"启用了却看不到"的就是这些
  /// ★ C-5: 重复条目的标签 —— `第 2 条 · 10-10 14:30`。
  ///
  /// 同一任务在队列里出现多条时, 靠它区分（否则界面上分不清哪个是哪个）。
  /// 拿不到加入时间就只显示"第 N 条"（**不猜**）。
  String _dupLabel(Map<String, dynamic> e) {
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

  /// ★★ S6: **类别分段条**（放在队列**上方**）★★
  ///
  /// 显示成: `定时任务 3 条` ｜ `固定任务 12 条`, 前段那一边**高亮**。
  ///
  /// ★ 与队列**同一顺序依据**: `c.queuedTaskRows`（后端 `_segment_queue()`
  ///   已按模式排好段）—— 所以"第一个出现的段"就是"排在前面的段"。
  ///
  /// ★ 它**不参与拖拽**（在 `ReorderableListView` **外面**）, 不会打乱
  ///   `reorderQueue` 的下标。
  ///
  /// ⚠ **不能**用 `Get.find<TaskListController>()` —— 队列面板在多账号场景
  ///   下靠 **tag** 注册; 无 tag 的 `find` 会**抛异常**（实测 2 个测试失败）。
  ///   用面板自己的控制器（`c` getter）。
  Widget _segmentBar(BuildContext context) {
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
      message: '这是当前执行队列里**周期任务 / 临时任务**各有多少条。\n'
          '${timedFirst ? "周期任务" : "临时任务"}段目前排在前面。\n'
          '★ **所有条目都能自由拖动**, 不限类别。\n'
          '★ 只有「休息」条目固定排在最后（它会挡住后面的任务）。',
      child: Wrap(
        children: [
          seg('周期任务', nTimed, true, timedFirst),
          seg('临时任务', nFixed, false, !timedFirst),
        ],
      ),
    );
  }

  Widget _queueRow(BuildContext context, int i) {
    final rows = c.queuedTaskRows;
    if (i < 0 || i >= rows.length) return const SizedBox.shrink();
    final e = rows[i];
    final isTask = '${e['kind']}' == 'task';
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
      key: ValueKey('queue-$i-${isTask ? cmd : 'rest-${e['minutes']}'}'),
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
                  child: Row(
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
                      Flexible(
                        child: Text(
                          isTask ? _zhName(cmd) : '休息 ${e['minutes']} 分钟',
                          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                                // ★ 未到开放时间 -> 变灰（用户: "直接变灰放到等待中就行"）
                                color: isPending
                                    ? null
                                    : Theme.of(context).disabledColor,
                              ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
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
                              _dupLabel(e),
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
                if (isTask) _statusBadge(context, cmd),
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
                        final msg = await c.removeFromQueue(cmd,
                            entryId: eidOrNull);
                        if (!context.mounted) return;
                        Get.snackbar('已移出队列', msg,
                            snackPosition: SnackPosition.BOTTOM,
                            duration: const Duration(seconds: 5));
                      } else {
                        await _confirmAndRemove(context, cmd,
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
            if (isTask) _settingsRow(context, cmd),
          ],
        ),
      ),
    );
  }

  /// 一行的**次数 / 预期耗时 / 优先级**（内联可编辑）。
  ///
  /// ★ 复用 `_NumberCell` —— 与任务表格里用的是**同一个组件**
  ///   （失焦/回车才提交、有焦点时不覆盖用户输入、正确 dispose）。
  ///
  /// ⚠ 写入接口要的是**下划线键**（`row['name']`，如 `experience_youkai`），
  ///   不是大驼峰命令名（`ExperienceYoukai`）—— 踩过这个混淆。
  Widget _settingsRow(BuildContext context, String cmd) {
    final row = c.taskRowOf(cmd);
    final key = '${row['name']}';
    final countable = row['countable'] == true;
    final target = (row['target'] as num?)?.toInt() ?? 0;
    final fallback = (row['count'] as num?)?.toInt();
    final expected = (row['expected_minutes'] as num?)?.toInt() ?? 0;
    final priority = (row['priority'] as num?)?.toInt() ?? 5;

    return Padding(
      padding: const EdgeInsets.only(left: 50, bottom: 4, top: 2),
      child: Wrap(
        spacing: 10,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (countable) ...[
            Text('次数', style: Theme.of(context).textTheme.labelSmall),
            _NumberCell(
              key: ValueKey('q-count-$cmd-$target'),
              value: target,
              width: 60,
              hint: fallback == null ? '默认' : '默认 $fallback',
              min: 0,
              max: 999,
              onCommit: (n) async {
                await c.setTarget(key, n);
                await c.reload();
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
          // 优先级 —— 定时任务排序的最终裁判（数字小的先跑）
          Text('优先级', style: Theme.of(context).textTheme.labelSmall),
          _NumberCell(
            key: ValueKey('q-pri-$cmd-$priority'),
            value: priority,
            width: 44,
            hint: '5',
            min: 1,
            max: 9,
            onCommit: (n) async {
              await c.setTaskPriority(key, n);
              await c.reload();
            },
          ),
          // ★★ ④: **进该任务的设置页**（用户要求"别的任务行上也应该有"）★★
          //
          // 实测: 调度 tab 的 `TaskRowView` 有 `onTap -> openTaskSettings`,
          // 而队列行**没有** -> 用户看到"设置入口只在正在运行的任务行上"。
          //
          // ★ 用 `openTaskSettings` 而不是 `switchContent`: 后者有
          //   `useablemenus` 白名单（只列侧边栏里有的任务）, 点不在侧边栏的
          //   任务会被**静默忽略** -> "点了没反应"（踩过, 见 task_list_view）。
          Tooltip(
            message: '打开「${_zhName(cmd)}」的**任务设置**',
            child: TextButton.icon(
              icon: const Icon(Icons.tune, size: 15),
              label: const Text('设置'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 28),
              ),
              onPressed: () =>
                  Get.find<NavCtrl>().openTaskSettings(cmd),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 未编排行

  // ---------------------------------------------------------------- 徽标 / 工具

  /// **状态徽标** —— 说明这个任务为什么在等。
  ///
  /// 数据来自后端（`slot` / `reason` / `in_cooldown`）,
  /// 前端**不重新推导**调度规则。
  Widget _statusBadge(BuildContext context, String cmd) {
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

  String _zhName(String command) {
    final zh = c.zhNameOf(command);
    return zh.isEmpty ? command : zh;
  }

  /// 从**全部任务**里挑一个加入队列（也能加「休息」）。
  Future<void> _pickAndAdd(BuildContext context) async {
    final picked = await showDialog<_PickedEntry>(
      context: context,
      builder: (ctx) => _TaskPickerDialog(controller: c),
    );
    if (picked == null) return;
    if (picked.isRest) {
      if (!context.mounted) return;
      await _addRest(context);
      return;
    }
    await c.appendToQueue(picked.task);
    await c.reload();
  }

  Future<void> _addRest(BuildContext context) async {
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
    await c.addEntry({'kind': '${rest['value']}', 'minutes': minutes});
  }
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
