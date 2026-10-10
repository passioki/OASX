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
                child: Text('（队列为空 —— 点右上「添加任务」，或先启用定时任务）'),
              )
            else
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

    // 「休息」条目给不同底色 —— 一眼看出"这里会停"
    final bg = isTask
        ? null
        : Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.3);

    return Container(
      key: ValueKey('queue-$i-${isTask ? cmd : 'rest-${e['minutes']}'}'),
      color: bg,
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
                          message: '定时任务启用后自动进入队列（不需要手动添加）',
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
                  tooltip: '移出队列（定时任务会同时停用）',
                  visualDensity: VisualDensity.compact,
                  onPressed: () async {
                    if (isTask) {
                      // ★ ⑨: 带上**条目身份** —— 否则同名多条会被**一删全删**
                      final eid = '${e['_entryId'] ?? ''}';
                      await _confirmAndRemove(context, cmd,
                          entryId: eid.isEmpty ? null : eid);
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
