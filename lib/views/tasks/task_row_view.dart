part of task_list;

/// 任务行的显示模式。
enum TaskRowMode {
  /// 总览页:监控面板 —— 有批量选择框, **没有**启停开关。
  overview,

  /// 列表页:唯一控制台 —— 有启停开关、有目标次数输入框。
  list,
}

/// 单个任务行。
///
/// ## 与原型的 8 列对应
///
/// | 列 | 来源 |
/// |---|---|
/// | 任务 | `name_zh` |
/// | 类型 | `category_label`（后端给中文, 前端不自建映射）|
/// | 状态 | `can_run` + `reason` |
/// | 目标次数 | `count`（**只在列表页可改**）|
/// | 进度 / 存量 | `charges`（充能）或 `count`（固定）|
/// | 下次运行 | `next_run` |
/// | 对方 | `teams`（账号级组队状态）|
/// | 在列表 | `in_list` |
///
/// ## 两条不可违反的界面规则
///
/// 1. **总览页不放启停开关** —— `enable` 放两处必然出现"列表行开着却不跑"
///    的静默矛盾（架构文档 §5.2）
/// 2. **总览页不隐藏停用状态** —— 停用的行显示 `⚠ 配置中已停用`,
///    点一下即可到列表页启用, **不会静默不跑**
class TaskRowView extends StatefulWidget {
  const TaskRowView({
    super.key,
    required this.task,
    required this.mode,
    required this.controller,
    this.onTap,
  });

  final Map<String, dynamic> task;
  final TaskRowMode mode;

  /// 显式传入 —— 不靠 `Get.find` + 路由参数, 嵌套时更可靠。
  final TaskListController controller;

  final VoidCallback? onTap;

  @override
  State<TaskRowView> createState() => _TaskRowViewState();
}

class _TaskRowViewState extends State<TaskRowView> {
  /// ★ 必须是 State 字段, **不能**在 build 里 `new`。
  ///
  /// `TextEditingController` 是 `ChangeNotifier` —— 在 build 里新建且不
  /// dispose 会**每帧泄漏一个监听器**。54 行任务 × 每次重建 = 卡顿。
  /// (踩过: 第一版就写成 `final ctrl = TextEditingController(...)`。)
  late final TextEditingController _targetCtrl;

  Map<String, dynamic> get task => widget.task;
  TaskRowMode get mode => widget.mode;
  TaskListController get _c => widget.controller;
  VoidCallback? get onTap => widget.onTap;

  @override
  void initState() {
    super.initState();
    _targetCtrl = TextEditingController(text: _targetText());
  }

  @override
  void didUpdateWidget(covariant TaskRowView old) {
    super.didUpdateWidget(old);
    // 外部数据刷新后, 若输入框**没有焦点**(用户没在编辑), 同步一下新值;
    // 有焦点时不动 —— 否则会把用户正在输的内容冲掉。
    if (!_targetFocus.hasFocus) {
      final t = _targetText();
      if (_targetCtrl.text != t) _targetCtrl.text = t;
    }
  }

  @override
  void dispose() {
    _targetCtrl.dispose();
    super.dispose();
  }

  final _targetFocus = FocusNode();

  /// 目标次数输入框的初始值 —— 读 **`target`**（用户设的值），不是 `count`。
  ///
  /// `target == 0` 表示"用任务默认值", 所以显示为**空**
  /// （hint 里会写出默认值是多少）。
  String _targetText() {
    final t = (task['target'] as num?)?.toInt() ?? 0;
    return t > 0 ? t.toString() : '';
  }

  @override
  Widget build(BuildContext context) {
    final name = '${task['name']}';
    final enabled = task['enable'] == true;
    final canRun = task['can_run'] == true;
    final countable = task['countable'] == true;
    final isOverview = mode == TaskRowMode.overview;
    final inCooldown = task['in_cooldown'] == true;

    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          // 总览页有批量选择框; 列表页空出等宽位置保持列对齐
          if (isOverview)
            SizedBox(
              width: 28,
              child: Checkbox(
                value: _c.selected.contains(name),
                onChanged: (_) => _c.toggleSelected(name),
              ),
            )
          else
            const SizedBox(width: 28),
          // ★ **队列** —— 只读展示"这个任务在不在执行队列里"。
          //
          //   ⚠ 用户明确纠正过我:
          //     "这个位次列执行顺序和我的想法不相符，我要的 ↑↓ 是为了像 EXCEL
          //      那样方便查看和管理任务（如启停和运行一次的测试），
          //      这个任务表格**不涉及执行顺序的改变**"
          //
          //   所以这里只有 **✓ / —**（在队列 / 不在），**没有 ↑↓**。
          //   执行顺序统一在「执行队列」面板里拖拽。
          Expanded(flex: 8, child: _inQueueCell(context)),
          Expanded(flex: 22, child: _nameCell(context)),
          Expanded(
              flex: 12,
              child: Text('${task['category_label'] ?? task['category'] ?? ''}',
                  style: Theme.of(context).textTheme.labelSmall)),
          // ★ 在冷却中时**状态格改成冷却徽标** —— 比"等待到点"有用得多
          //   （那会让人以为调度器只是还没轮到它）。
          Expanded(
              flex: 18,
              child: inCooldown
                  ? _cooldownBadge(context)
                  : _statusCell(context, canRun, enabled)),
          Expanded(flex: 12, child: _targetCell(context, countable, isOverview)),
          Expanded(flex: 12, child: _progressCell(context, countable)),
          Expanded(
              flex: 16,
              child: Text(_shortTime('${task['next_run'] ?? ''}'),
                  style: Theme.of(context).textTheme.labelSmall)),
          Expanded(flex: 12, child: _peerCell(context)),
          Expanded(flex: 12, child: _inListCell(context, isOverview)),
          // 优先级 / 预期完成时间 —— 定时任务排序与"休息时穿插"的输入
          Expanded(flex: 8, child: _priorityCell(context, isOverview)),
          Expanded(flex: 12, child: _expectedCell(context, isOverview)),
          // 运行记录（累计次数 + 耗时）—— v2 新增
          Expanded(flex: 20, child: _recordCell(context)),
          // 列表页多一格:启停开关
          if (!isOverview)
            Switch(
              value: enabled,
              onChanged: _c.busy
                  ? null
                  : (v) async {
                      await _c.setEnabled(name, v);
                      await _c.reload();
                    },
            ),
        ],
      ),
    );

    // ★ 停用的行用**文字透明度**压暗, 而不是套一层 `Opacity`。
    //
    // `Opacity` 会给**每一行**建一个独立的合成层(`OpacityLayer`),
    // 54 行 = 54 个额外图层 —— 滚动时 GPU 压力很大。
    // 直接调 `DefaultTextStyle` 的 alpha 是零成本的, 视觉效果一样。
    return InkWell(
      onTap: onTap,
      child: DefaultTextStyle.merge(
        style: TextStyle(
          color: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.color
              ?.withValues(alpha: enabled ? 1.0 : 0.45),
        ),
        child: row,
      ),
    );
  }

  /// **队列** —— 只读展示"在不在执行队列里"。
  ///
  /// ## ★ 这里**故意不放 ↑↓**（用户纠正过我）
  ///
  /// 我第一版在这里放了"位次 + ↑↓"来调执行顺序, 用户明确说:
  ///
  /// > 这个位次列执行顺序和我的想法不相符，我要的 ↑↓ 是为了像 EXCEL 那样
  /// > 方便查看和管理任务（如启停和运行一次的测试），
  /// > **这个任务表格不涉及执行顺序的改变**
  ///
  /// 所以:
  ///
  /// | 面板 | 管什么 |
  /// |---|---|
  /// | **任务表格**（这里）| Excel 式的**批量查看与管理**: 启停 / 运行一次 / 排序 / 筛选 |
  /// | **执行队列** | **执行顺序**（拖拽）+ 每行次数 / 预期耗时 / 优先级 |
  ///
  /// 这一格只回答"在不在队列里" —— `✓` 在, `—` 不在。
  Widget _inQueueCell(BuildContext context) {
    final cmd = '${task['command'] ?? ''}';
    final inQueue = _c.entryPositionOf(cmd) > 0;
    return Tooltip(
      message: inQueue
          ? '在「执行队列」里（顺序请在队列面板拖拽调整）'
          : '不在执行队列里 —— 调度器会把它排在已编排的任务之后',
      child: Text(
        inQueue ? '✓' : '—',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: inQueue ? Colors.green : Theme.of(context).disabledColor,
              fontWeight: inQueue ? FontWeight.bold : null,
            ),
      ),
    );
  }

  Widget _nameCell(BuildContext context) {
    final desc = '${task['resource_describe'] ?? ''}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${task['name_zh'] ?? task['name']}',
            style: Theme.of(context).textTheme.bodyMedium),
        if (desc.isNotEmpty)
          Text(desc, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }

  /// 状态:可执行 / 等待 / **⚠ 配置中已停用** / 时段未到。
  Widget _statusCell(BuildContext context, bool canRun, bool enabled) {
    if (canRun) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _dot(Colors.green),
          const SizedBox(width: 6),
          Text('可执行', style: Theme.of(context).textTheme.labelSmall),
        ],
      );
    }
    final reason = '${task['reason'] ?? ''}';
    if (!enabled) {
      // ★ 不隐藏 —— 避免"看起来在跑其实没跑"
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _dot(Colors.grey),
          const SizedBox(width: 6),
          Flexible(
            child: Tooltip(
              message: '在「任务列表」里可启用',
              child: Text('⚠ 配置中已停用',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: Colors.orange)),
            ),
          ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _dot(task['in_window'] == false ? Colors.blueGrey : Colors.orange),
        const SizedBox(width: 6),
        Flexible(
          child: Text(reason,
              style: Theme.of(context).textTheme.labelSmall,
              overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }

  /// 目标次数。
  ///
  /// ★ **只在列表页可改**（用户决定）; 总览页只读显示当前值。
  /// ★ 非 countable(fixed/toppa)的任务**不显示输入框**, 而不是显示一个无效的框。
  /// **目标次数** —— 编辑的是 `scheduler.target`。
  ///
  /// ★★ 这里曾经读 `task['count']` ★★
  ///
  /// `count` 是**任务配置里的默认值**（能力上限），不是用户设的值。
  /// 用户在界面上改的是 `scheduler.target` —— 所以:
  ///
  /// * 输入框该显示 **`target`**（0 = 空, 表示"用下面的默认值"）
  /// * 旁边用**淡色**标出默认值, 让用户知道留空会发生什么
  /// * 两者相同时不显示提示（省得吵）
  ///
  /// 否则用户改了次数、看到的是配置里的旧数字, 会**以为没生效**
  /// （这正是"次数双轨"那套 bug 的表现）。
  Widget _targetCell(BuildContext context, bool countable, bool isOverview) {
    if (!countable) return const SizedBox.shrink();
    final target = (task['target'] as num?)?.toInt() ?? 0;
    final fallback = (task['count'] as num?)?.toInt();
    final effective = (task['effective_target'] as num?)?.toInt();

    if (isOverview) {
      // 总览页只读: 显示**实际生效**的值, 并在覆盖时标出来
      final text = effective == null
          ? '—'
          : (target > 0 ? '$effective（自定义）' : '$effective');
      return Tooltip(
        message: target > 0
            ? '自定义 $target 次（任务的默认上限是 ${fallback ?? "?"}）'
            : '用任务默认值 ${fallback ?? "?"}',
        child: Text(text, style: Theme.of(context).textTheme.labelMedium),
      );
    }
    return SizedBox(
      width: 76,
      child: TextField(
        // 复用 State 里的控制器 —— 不在 build 里新建(会每帧泄漏)
        controller: _targetCtrl,
        focusNode: _targetFocus,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          isDense: true,
          // 留空 = 用任务默认值; 把它显示在 hint 里
          hintText: fallback == null ? '默认' : '默认 $fallback',
          border: const OutlineInputBorder(),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        ),
        onSubmitted: (v) async {
          final n = int.tryParse(v.trim()) ?? 0;
          await _c.setTarget('${task['name']}', n);
          await _c.reload();
        },
      ),
    );
  }

  /// 进度/存量:
  ///   * 充能类 -> `charges.count / charges.max`(如 2/2)
  ///   * 固定类 -> 当前已打次数
  Widget _progressCell(BuildContext context, bool countable) {
    final charges = task['charges'];
    if (charges is Map) {
      return Text('${charges['count']}/${charges['max']}',
          style: Theme.of(context).textTheme.labelMedium);
    }
    if (!countable) return const SizedBox.shrink();
    return Text('—', style: Theme.of(context).textTheme.labelSmall);
  }

  /// "对方" —— 组队协同的队友在线状态。
  ///
  /// ⚠ 目前 `overview.teams` 是**账号级**的（哪些账号在线），
  ///   不是"这个任务的队友"。见 `docs/ui-api-mapping.md` 缺口清单 #2。
  Widget _peerCell(BuildContext context) {
    final teams = (_c.overview['teams'] as List?) ?? const [];
    if (teams.isEmpty) return const SizedBox.shrink();
    final online = teams
        .where((t) => (t as Map)['online'] == true)
        .map((t) => '${(t as Map)['config']}')
        .toList();
    if (online.isEmpty) {
      return Text('离线', style: Theme.of(context).textTheme.labelSmall);
    }
    return Tooltip(
      message: '在线账号: ${online.join(", ")}',
      child: Text('${online.length} 在线',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Colors.green)),
    );
  }

  Widget _inListCell(BuildContext context, bool isOverview) {
    final inList = task['in_list'] == true;
    return Text(inList ? '✓' : '—',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: inList ? Colors.green : null));
  }

  /// **运行记录** —— 累计次数 + 耗时（v2 新增）。
  ///
  /// 数据来自 `/schema` 的 `list.run_record`（后端已格式化好 `seconds_text`，
  /// 前端不重复实现一遍中文格式化）。
  /// **优先级** —— 定时任务内部排序的**最终裁判**（数字小的先跑）。
  ///
  /// 见 `docs/architecture.md` §5.4.1 的五级排序:
  /// 能否跑 > 到点程度 > 窗口快关 > 耗时短 > **用户自定义优先级**。
  Widget _priorityCell(BuildContext context, bool isOverview) {
    final p = (task['priority'] as num?)?.toInt();
    if (p == null) {
      return Text('—', style: Theme.of(context).textTheme.labelSmall);
    }
    if (isOverview) {
      return Text('$p', style: Theme.of(context).textTheme.labelSmall);
    }
    return _NumberCell(
      key: ValueKey('pri-$p-${task['name']}'),
      value: p,
      width: 44,
      hint: '5',
      min: 1,
      max: 9,
      onCommit: (n) async {
        await _c.setTaskPriority('${task['name']}', n);
        await _c.reload();
      },
    );
  }

  /// **预期完成时间**（分钟）—— "休息时可穿插"的判据输入。
  ///
  /// 判据: `预期完成时间 < 休息剩余时间` -> 允许在休息期间穿插这个任务。
  /// `0` = **未知** -> 不参与判定（保守, 宁可不穿插）。
  Widget _expectedCell(BuildContext context, bool isOverview) {
    final m = (task['expected_minutes'] as num?)?.toInt() ?? 0;
    if (isOverview) {
      return Tooltip(
        message: m > 0
            ? '预期 $m 分钟 —— 休息剩余时间比它长时才会被穿插'
            : '未设置 —— 不参与"休息时穿插"判定',
        child: Text(m > 0 ? '$m 分' : '—',
            style: Theme.of(context).textTheme.labelSmall),
      );
    }
    return _NumberCell(
      key: ValueKey('exp-$m-${task['name']}'),
      value: m,
      width: 64,
      hint: '未知',
      min: 0,
      max: 1440,
      onCommit: (n) async {
        await _c.setTaskExpectedMinutes('${task['name']}', n);
        await _c.reload();
      },
    );
  }

  /// **失败冷却徽标** —— 在冷却中时替代"状态"格显示。
  ///
  /// 见 `module/config/failure_state.py`: 连续失败到阈值不再 `exit(1)`,
  /// 而是给该任务加冷却。界面上要让用户**看见**并**能清除**。
  Widget _cooldownBadge(BuildContext context) {
    final mins = (task['cooldown_minutes'] as num?)?.toInt() ?? 0;
    final until = '${task['cooldown_until'] ?? ''}';
    return Tooltip(
      message: '连续失败 '
          '${task['failure_count'] ?? 0} 次, 冷却中至 $until\n'
          '修好之后可以点右侧的「清除失败」立刻重试',
      child: Chip(
        avatar: const Icon(Icons.error_outline, size: 14),
        label: Text('冷却 $mins 分'),
        visualDensity: VisualDensity.compact,
        // 点一下就能"清除失败 + 解除冷却"（修好之后不用等 1 小时）
        onDeleted: () => _c.clearFailure('${task['name']}'),
        deleteIcon: const Icon(Icons.close, size: 14),
        deleteButtonTooltipMessage: '清除失败记录, 解除冷却, 立刻可重试',
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  Widget _recordCell(BuildContext context) {
    final cmd = '${task['command'] ?? ''}';
    final rec = _c.recordOf(cmd);
    if (rec.isEmpty) {
      return Text('—', style: Theme.of(context).textTheme.labelSmall);
    }
    final runs = _c.runsOf(cmd);
    final text = _c.durationTextOf(cmd);
    final rounds = (rec['archived_rounds'] as num?)?.toInt() ?? 0;
    if (runs == 0 && text.isEmpty) {
      return Text('—', style: Theme.of(context).textTheme.labelSmall);
    }
    return Tooltip(
      message: '累计 $runs 次，$text'
          '${rounds > 0 ? '\n已归档 $rounds 轮（重置不会删除历史）' : ''}',
      child: Text(
        runs > 0 ? '$runs 次 · $text' : text,
        style: Theme.of(context).textTheme.labelSmall,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _dot(Color color) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );

  /// `2026-10-08 22:01:00` -> `10-08 22:01`
  static String _shortTime(String s) =>
      s.length >= 16 ? s.substring(5, 16) : s;
}

/// 一个**行内数字输入格**（优先级 / 预期完成时间 都用它）。
///
/// ## 为什么单独抽一个 StatefulWidget
///
/// `TextEditingController` 是 `ChangeNotifier` —— 在 `build` 里 `new` 一个
/// 会**每帧泄漏一个监听器**（54 行 × 每次重建 = 卡顿）。
/// 抽成 `StatefulWidget` 后, 控制器活在 `State` 里, 且能正确 `dispose`。
///
/// ## 关键行为
///
/// * **失焦或回车才提交** —— 每击键提交会打爆后端（每行都发一个 PUT）
/// * 外部数据刷新时同步新值, 但**有焦点时不动** ——
///   否则会把用户正在输的内容冲掉
class _NumberCell extends StatefulWidget {
  const _NumberCell({
    super.key,
    required this.value,
    required this.width,
    required this.hint,
    required this.onCommit,
    this.min = 0,
    this.max,
  });

  final int value;
  final double width;
  final String hint;
  final int min;
  final int? max;
  final Future<void> Function(int) onCommit;

  @override
  State<_NumberCell> createState() => _NumberCellState();
}

class _NumberCellState extends State<_NumberCell> {
  late final TextEditingController _ctrl;
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: _text());
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(covariant _NumberCell old) {
    super.didUpdateWidget(old);
    // 有焦点时不要覆盖用户正在输的内容
    if (!_focus.hasFocus) {
      final t = _text();
      if (_ctrl.text != t) _ctrl.text = t;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  String _text() => widget.value > 0 ? '${widget.value}' : '';

  void _commit() {
    final raw = _ctrl.text.trim();
    // 空 = 0（优先级不允许 0, 用最小值兜底）
    var n = raw.isEmpty ? (widget.min > 0 ? widget.min : 0) : int.tryParse(raw);
    if (n == null) {
      // 输入了非数字 -> 回退显示
      _ctrl.text = _text();
      return;
    }
    if (n < widget.min) n = widget.min;
    if (widget.max != null && n > widget.max!) n = widget.max!;
    if (n == widget.value) return;   // 没变就不发请求
    widget.onCommit(n);
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.hint,
      child: SizedBox(
        width: widget.width,
        child: TextField(
          controller: _ctrl,
          focusNode: _focus,
          keyboardType: TextInputType.number,
          style: Theme.of(context).textTheme.labelSmall,
          decoration: InputDecoration(
            isDense: true,
            hintText: widget.hint,
            hintStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).disabledColor,
                ),
            border: const OutlineInputBorder(),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          ),
          onSubmitted: (_) => _commit(),
        ),
      ),
    );
  }
}
