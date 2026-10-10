// ★★ S4: **窗口列表编辑器**（用户裁定: "不是 window slots, 而是**设置多个 window**"）★★
//
// 本文件是 `args_view.dart` 的 `part`（与 `group_view.dart` / `date_time_picker.dart`
// 一致 —— 它们共享同一个 `args` library）。
//
// ## 设计依据
//
// `docs/scheduler-architecture.md` §1.1 / §5.1。
//
// ## 用户原话
//
//   "不是 window slots, 而是**设置多个 window**！slots 不是已经废弃了吗,
//    请**通读代码、设计文档并更新记忆**！**前后端要同步改**！"
//   "一天跑两次 = **两个窗口**"
//
// ## 交互
//
// * 一条窗口一行: `启用` · `周期` · `起` · `止` · `周几/几号` · `删除`
// * 「+ 添加窗口」新增一行
// * 保存走 **`PUT /{script}/tasks/{task}/windows`**（整单替换, 一次提交全部）
// * ★ 删/改**按 `id`**（"身份不是位置"）—— 新增的行没有 id, 由后端补
part of 'args_view.dart';

/// 周期选项（与后端 `WindowPeriod` 一致）。
const _periods = <String, String>{
  'daily': '每天',
  'weekly': '每周',
  'monthly': '每月',
};

class WindowEditor extends StatefulWidget {
  const WindowEditor({
    super.key,
    required this.scriptName,
    required this.task,
    required this.initial,
    required this.taskPeriod,
  });

  final String scriptName;
  final String task;

  /// ★ 该任务当前的**周期**（`scheduler.period`）—— `'none'`/`'daily'`/…。
  ///
  /// ★ 用户裁定: "**窗口必须在选了周期后才能设置**"。
  ///   `'none'`（不限 = 临时任务）-> 本编辑器**只读 + 提示去选周期**。
  final String taskPeriod;

  /// 周期未选（= 不限）-> 不允许新增窗口。
  bool get periodUnset => taskPeriod == 'none' || taskPeriod.isEmpty;

  /// 初始窗口列表（来自 `/args` 的 `value`）。
  final List<dynamic> initial;

  @override
  State<WindowEditor> createState() => _WindowEditorState();
}

class _WindowEditorState extends State<WindowEditor> {
  late List<Map<String, dynamic>> _rows;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _rows = widget.initial
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// 取 `HH:mm`（后端给 `HH:mm:ss`）。
  String _hm(dynamic v) {
    final s = '${v ?? ''}';
    return s.length >= 5 ? s.substring(0, 5) : s;
  }

  /// `HH:mm` -> `HH:mm:ss`（后端 `Time` 认这个格式）。
  String _hms(String hm) => hm.length == 5 ? '$hm:00' : hm;

  Future<void> _pickTime(int i, bool isStart) async {
    final cur = _hm(_rows[i][isStart ? 'start' : 'end']);
    final parts = cur.split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: int.tryParse(parts.isNotEmpty ? parts[0] : '0') ?? 0,
        minute: int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0,
      ),
    );
    if (picked == null) return;
    String two(int x) => x.toString().padLeft(2, '0');
    setState(() {
      _rows[i][isStart ? 'start' : 'end'] =
          '${two(picked.hour)}:${two(picked.minute)}:00';
    });
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    // ★ 规范化: 缺 `id` 的交给后端补; `start`/`end` 补成 `HH:mm:ss`
    final payload = _rows
        .map((r) => <String, dynamic>{
              if ('${r['id'] ?? ''}'.isNotEmpty) 'id': '${r['id']}',
              'enabled': r['enabled'] != false,
              'period': '${r['period'] ?? 'daily'}',
              'start': _hms('${r['start'] ?? '17:00'}'),
              'end': _hms('${r['end'] ?? '23:00'}'),
              'days': '${r['days'] ?? ''}',
              'days_of_month': '${r['days_of_month'] ?? ''}',
            })
        .toList();
    final res = await ApiClient()
        .putTaskWindows(widget.scriptName, widget.task, payload);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (res.containsKey('error')) {
        _error = '${res['error']}';
      } else {
        // ★ 用后端返回的（**带 id 的**）覆盖本地 —— 否则新增行还是没 id
        _rows = ((res['windows'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    });
    // ★★★ 后端会带 `needs_period` 标记 —— 说明"还没选周期, 不能加窗口" ★★★
    //
    // 用户裁定: "**窗口必须在选了周期后才能设置**。这样子判断依据就可以按
    // 有没有周期来判断"。
    // ★ 后端是**最终防线**（前端灰掉按钮可以被绕过, 而且还有别的客户端）——
    //   所以这里要把后端的话**原样上屏**, 告诉用户去哪选周期。
    final needsPeriod = res['needs_period'] == true;
    Get.snackbar(
      needsPeriod
          ? '请先选择「周期」'
          : (res.containsKey('error') ? '保存失败' : '已保存'),
      res.containsKey('error')
          ? '${res['error']}'
          : '窗口已更新（共 ${_rows.length} 个）',
      snackPosition: SnackPosition.BOTTOM,
      duration: Duration(seconds: needsPeriod ? 8 : 4),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('共 ${_rows.length} 个窗口',
                style: Theme.of(context).textTheme.labelMedium),
            const Spacer(),
            Tooltip(
              // ★ 说明走 Tooltip（用户要求"括号改悬停"）
              message: '任务的**可跑集合 = 所有启用窗口的并集**。\n'
                  '想"一天跑两次", 就加**两个**窗口（如 12:00-14:00 与 20:00-22:00）。',
              child: Icon(Icons.help_outline, size: 15, color: scheme.outline),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // ★★★ 周期未选（= 不限）时的**说明条**（用户裁定）★★★
        //
        // 用户原话: "**窗口必须在选了周期后才能设置。这样子判断依据就可以按
        // 有没有周期来判断**"
        //
        // ★ 这里**只提示 + 禁用新增**, **不隐藏/不清空已有窗口** ——
        //   历史数据（"有窗口但 period=none"）必须能看见、能编辑、能删,
        //   否则用户被锁死。★ 后端也只拦"新增"（见 `_require_period_for_windows`）。
        if (widget.periodUnset)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: scheme.errorContainer.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 15, color: scheme.error),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '这个任务的「周期」是**不限**（= 临时任务），所以不能'
                    '**新增**窗口。\n'
                    '★ 请先到上面「scheduler」组里把「周期」选成'
                    '**每天 / 每周 / 每月**。\n'
                    '⚠ 已有的窗口仍然可以**编辑和删除**（不会被锁住）。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        for (var i = 0; i < _rows.length; i++) _row(context, i),
        if (_rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text('还没配窗口 —— 不配的话按任务的开放时段（游戏机制）跑',
                style: Theme.of(context).textTheme.bodySmall),
          ),
        const SizedBox(height: 6),
        Row(
          children: [
            TextButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: const Text('添加窗口'),
              // ★ 周期未选时禁用（后端也会拦, 这是**体验**那一半）
              onPressed: (_saving || widget.periodUnset)
                  ? null
                  : () => setState(() {
                        _rows.add({
                          'id': '',
                          'enabled': true,
                          'period': 'daily',
                          'start': '17:00:00',
                          'end': '23:00:00',
                          'days': '',
                          'days_of_month': '',
                        });
                      }),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              icon: _saving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save, size: 16),
              label: const Text('保存窗口'),
              // ★ 周期未选时**只禁"新增"**, 不禁"保存" ——
              //   否则用户改不了/删不掉已有窗口（后端同样只拦新增）。
              //   真正的判据在后端（`needs_period`）; 这里只是不给按。
              onPressed: _saving ? null : _save,
            ),
            if (_error != null) ...[
              const SizedBox(width: 8),
              Text(_error!,
                  style: TextStyle(color: scheme.error, fontSize: 12)),
            ],
          ],
        ),
      ],
    );
  }

  Widget _row(BuildContext context, int i) {
    final r = _rows[i];
    final period = '${r['period'] ?? 'daily'}';
    final enabled = r['enabled'] != false;
    return Padding(
      key: ValueKey('win-${r['id'] ?? i}'),
      padding: const EdgeInsets.only(bottom: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Tooltip(
            message: enabled ? '这一段生效' : '这一段**不生效**（保留配置）',
            child: Checkbox(
              value: enabled,
              visualDensity: VisualDensity.compact,
              onChanged: (v) => setState(() => r['enabled'] = v ?? true),
            ),
          ),
          Tooltip(
            message: '窗口周期 —— 决定"时:分"是**哪一天**的时:分。\n'
                '开始与结束**共用**同一个周期。',
            child: DropdownButton<String>(
              isDense: true,
              value: _periods.containsKey(period) ? period : 'daily',
              items: [
                for (final e in _periods.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => setState(() => r['period'] = v ?? 'daily'),
            ),
          ),
          _timeButton(i, true),
          const Text('→'),
          _timeButton(i, false),
          if (period == 'weekly')
            _textField(r, 'days', '周几(0=一)',
                '周一=0 … 周日=6, 逗号分隔。留空 = 每天。'),
          if (period == 'monthly')
            _textField(r, 'days_of_month', '几号', '1-31, 逗号分隔。留空 = 整月。'),
          IconButton(
            tooltip: '删除这个窗口',
            icon: const Icon(Icons.delete_outline, size: 16),
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _rows.removeAt(i)),
          ),
        ],
      ),
    );
  }

  Widget _timeButton(int i, bool isStart) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 30),
      ),
      onPressed: () => _pickTime(i, isStart),
      child: Text(_hm(_rows[i][isStart ? 'start' : 'end'])),
    );
  }

  Widget _textField(Map<String, dynamic> r, String key, String label,
      String help) {
    return Tooltip(
      message: help,
      child: SizedBox(
        width: 110,
        child: TextFormField(
          initialValue: '${r[key] ?? ''}',
          decoration: InputDecoration(
              labelText: label,
              isDense: true,
              border: const OutlineInputBorder()),
          onChanged: (v) => r[key] = v,
        ),
      ),
    );
  }
}
