part of overview;

class TaskItemView extends StatelessWidget {
  final TaskItemModel model;
  const TaskItemView(this.model, {super.key});

  @override
  Widget build(BuildContext context) {
    return model.isAllEmpty()
        ? const SizedBox(height: 30)
        : <Widget>[
      _name(context),
      _action(context),
    ]
        .toRow(mainAxisAlignment: MainAxisAlignment.spaceBetween)
        .padding(bottom: 10);
  }

  Widget _name(BuildContext context) {
    return <Widget>[
      Text(model.taskName.tr, style: Theme.of(context).textTheme.labelLarge),
      Text(model.nextRun, style: Theme.of(context).textTheme.labelMedium)
    ].toColumn(crossAxisAlignment: CrossAxisAlignment.start);
  }

  Widget _action(BuildContext context) {
    return OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.all(0),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10.0),
          ),
        ),
        // ★ 用 `openTaskSettings` 而不是 `switchContent`。
        //
        //   `switchContent` 开头有 `useablemenus.contains(menu)` 守卫 ——
        //   侧边栏只列**当前账号启用/常用**的任务, 所以点一个不在侧边栏里的
        //   任务会被**静默忽略**（用户看到"点了没反应", 很难排查）。
        //
        //   这里是"用户明确点了这一行的设置按钮" —— 最强的意图表达,
        //   不该被白名单挡掉。
        //   （同一个坑在 `views/tasks/task_list_view.dart` 里也踩过。）
        onPressed: () =>
            Get.find<NavCtrl>().openTaskSettings(model.taskName),
        child: Text(I18n.task_setting.tr,
            style: Theme.of(context).textTheme.bodySmall))
        .constrained(maxWidth: 100, maxHeight: 30);
  }
}
