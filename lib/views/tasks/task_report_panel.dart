part of 'task_list_view.dart';

/// ★★ #6 **任务完成汇报** 面板（用户 2026-10-10 新需求）★★
///
/// 用户原话:
///   "添加一个**任务完成汇报 tab**, 现在的日志属于原始日志, 应该**转移到
///    单独界面**用来 debug, 当前日志位置替换为**任务完成汇报**的 tab,
///    只会报完成了哪些、**出错任务标注**等等其它可以作为简报的内容"
///
/// ## 这一页回答什么
///
/// * **完成了哪些** —— 每个任务跑了几次 / 花了多久 / 本周期是否已完成
/// * **哪些出错了** —— 失败计数 · 冷却中（还等几分钟）· 短运行
/// * 充能任务**还剩几次**
///
/// ## 数据从哪来
///
/// **全部来自后端的 `GET /{script}/report`** —— 前端**不自己推导**
/// （同一知识只存一处; 见 `module/config/report.py`）。
///
/// ★ 原始日志**不在这里** —— 它已移到「运行日志」单独界面（见 `_logsButton`）,
///   那一页是给 debug 用的。
class TaskReportPanel extends StatefulWidget {
  const TaskReportPanel({super.key, required this.controller});

  final TaskListController controller;

  @override
  State<TaskReportPanel> createState() => _TaskReportPanelState();
}

class _TaskReportPanelState extends State<TaskReportPanel> {
  TaskListController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    // 首次进来自动拉一次（不阻塞 UI）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      c.fetchTaskReport();
    });
  }

  @override
  Widget build(BuildContext context) {
    final sm = c.reportSummary;
    final tasks = c.reportTasks;
    final errors = c.reportErrors;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // ---------- 标题 + 刷新 ----------
        Row(
          children: [
            Expanded(
              child: Text('任务完成汇报',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            if (c.taskReportError != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Tooltip(
                  message: '${c.taskReportError}',
                  child: Icon(Icons.error_outline,
                      size: 16, color: Theme.of(context).colorScheme.error),
                ),
              ),
            IconButton(
              icon: const Icon(Icons.refresh, size: 18),
              tooltip: '重新拉取汇报',
              onPressed: () => c.fetchTaskReport(),
            ),
          ],
        ),
        Text(
          c.taskReport['at'] == null ? '还没拉到数据' : '数据时间：${c.taskReport['at']}',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).disabledColor,
              ),
        ),
        const SizedBox(height: 10),

        // ---------- 汇总 ----------
        _summaryRow(context, sm),
        const SizedBox(height: 12),

        // ---------- 出错清单（用户要求"出错任务标注"）----------
        if (errors.isNotEmpty) ...[
          Text('需要注意',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                    fontWeight: FontWeight.bold,
                  )),
          const SizedBox(height: 4),
          for (final e in errors) _errorRow(context, e),
          const SizedBox(height: 12),
        ] else if (tasks.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Icon(Icons.check_circle_outline,
                    size: 16, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 6),
                const Text('没有出错的任务'),
              ],
            ),
          ),

        // ---------- 明细 ----------
        if (tasks.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('（还没有运行记录 —— 跑过任务后这里会有简报）'),
          )
        else ...[
          Text('各任务明细',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  )),
          const SizedBox(height: 4),
          for (final t in tasks) _taskRow(context, t),
        ],
      ],
    );
  }

  // ------------------------------------------------------------ 汇总
  Widget _summaryRow(BuildContext context, Map<String, dynamic> s) {
    Widget cell(String label, String value, {Color? color}) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: color,
                        fontWeight: FontWeight.bold,
                      )),
              Text(label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).disabledColor,
                      )),
            ],
          ),
        );

    if (s.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        cell('任务数', '${s['total'] ?? 0}'),
        cell('已完成', '${s['completed'] ?? 0}', color: scheme.primary),
        cell('有失败', '${s['failed'] ?? 0}',
            color: (s['failed'] ?? 0) == 0 ? null : scheme.error),
        cell('冷却中', '${s['in_cooldown'] ?? 0}',
            color: (s['in_cooldown'] ?? 0) == 0 ? null : scheme.error),
        cell('总运行', '${s['total_runs'] ?? 0}'),
        cell('总耗时', '${s['total_minutes'] ?? 0} 分'),
      ],
    );
  }

  // ------------------------------------------------------------ 出错行
  Widget _errorRow(BuildContext context, Map<String, dynamic> e) {
    final scheme = Theme.of(context).colorScheme;
    final level = '${e['level']}';
    final (icon, color, tag) = switch (level) {
      'cooldown' => (Icons.hourglass_bottom, scheme.error, '冷却中'),
      'failed' => (Icons.error_outline, scheme.error, '失败'),
      'short' => (Icons.timer_off_outlined, Colors.orange, '疑似没做成'),
      _ => (Icons.info_outline, scheme.outline, level),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text('${e['text'] ?? e['name']}',
                style: Theme.of(context).textTheme.bodySmall),
          ),
          // ★ 不写括号解释 —— 用 Tooltip（用户要求"括号改悬停"）
          Tooltip(
            message: switch (level) {
              'cooldown' => '失败后进入冷却，冷却结束前不会再派发这个任务',
              'failed' => '该任务有失败记录',
              'short' => '运行时间很短就结束，可能进去看了一眼就退了',
              _ => level,
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(tag,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w600,
                      )),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 任务行
  Widget _taskRow(BuildContext context, Map<String, dynamic> t) {
    final scheme = Theme.of(context).colorScheme;
    final marks = (t['marks'] as List?)?.cast<String>() ?? const <String>[];
    final failed = marks.contains('failed');
    final cooldown = marks.contains('cooldown');
    final done = marks.contains('completed');
    final short = marks.contains('short');
    final seconds = (t['seconds'] as num?)?.toInt() ?? 0;
    final mins = seconds >= 60 ? '${(seconds / 60).toStringAsFixed(1)} 分'
                              : '$seconds 秒';

    return Container(
      margin: const EdgeInsets.only(bottom: 3),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: (failed || cooldown)
            ? scheme.errorContainer.withValues(alpha: 0.22)
            : null,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text('${t['name']}',
                style: Theme.of(context).textTheme.labelLarge,
                overflow: TextOverflow.ellipsis),
          ),
          SizedBox(
            width: 58,
            child: Text('${t['runs']} 次',
                style: Theme.of(context).textTheme.labelSmall),
          ),
          SizedBox(
            width: 70,
            child: Text(mins,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).disabledColor,
                    )),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Wrap(
              spacing: 4,
              children: [
                if (done) _chip(context, '已完成', scheme.primary,
                    '本周期已经做过了（不会重复做）'),
                if (cooldown)
                  _chip(
                      context,
                      '冷却 ${t['cooldown_minutes']} 分',
                      scheme.error,
                      '失败后冷却中，冷却结束前不会再派发'),
                if (failed && !cooldown)
                  _chip(context, '失败 ${t['fail_count']} 次', scheme.error,
                      '该任务有失败记录'),
                if (short)
                  _chip(context, '短运行', Colors.orange,
                      '运行时间很短就结束，可能没做成事'),
                if (t['charges'] is Map)
                  _chip(
                      context,
                      '还剩 ${(t['charges'] as Map)['count']} 次',
                      scheme.outline,
                      '充能任务剩余可用次数'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 一个小标签。★ 说明一律走 Tooltip（用户要求"括号改悬停"）。
  Widget _chip(BuildContext context, String text, Color color, String tip) {
    return Tooltip(
      message: tip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                )),
      ),
    );
  }
}
