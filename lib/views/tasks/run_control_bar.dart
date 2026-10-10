part of task_list;

/// 运行控制条（v2）—— **只有三个调度按钮**。
///
/// ## v2 去掉了什么
///
/// v1 有「全部停止 N 分钟」/「只停列表 N 分钟」两个**时长按钮**。
/// v2 之后**固定任务与定时任务分开管理**（各自有总开关），
/// "谁停谁不停"交给总开关表达 —— 这两个概念不再需要。
///
/// 同理列表里也只剩「休息」一种控制条目（去掉了 `delay`）。
///
/// ## 保留的三个按钮
///
/// | 按钮 | `mode` | 行为 |
/// |---|---|---|
/// | ⏸ 暂停调度 | `battle` | 跑完**当前这场战斗**（安全点）后不再开新任务 |
/// | ⏭ 本轮跑完再停 | `round` | 本任务本轮**打满目标次数**再停 |
/// | ▶ 继续调度 | （`resume`）| 恢复 |
///
/// ★ **不提供「立即停」** —— 会卡在半途（战斗中/组队房间中），不安全。
///
/// ## ★ 暂停的是**两者**
///
/// 「暂停调度」暂停的是**整个配置**（固定任务 + 定时任务都停）。
/// 想只停一边，用「全局设置」里的两个总开关。
///
/// ## 脚本进程开关不在这里
///
/// 它是**进程级硬停**（结束子进程），与"调度级软停"是两回事 ——
/// 已移到**任务总览页**（那里是俯视全局的地方）。
class RunControlBar extends StatefulWidget {
  const RunControlBar({super.key, required this.controller});

  final TaskListController controller;

  @override
  State<RunControlBar> createState() => _RunControlBarState();
}

class _RunControlBarState extends State<RunControlBar> {
  Map<String, dynamic> _state = {};
  bool _busy = false;

  /// 显式传入 —— 不靠 `Get.find` + 路由参数，嵌套时更可靠。
  TaskListController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await ApiClient().getRunControl(_c.script);
    if (!mounted) return;
    setState(() => _state = s);
  }

  Future<void> _do(Future<bool> Function() fn) async {
    setState(() => _busy = true);
    try {
      await fn();
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final paused = _state['paused'] == true;
    final restUntil = _state['rest_until'];

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        // ★★ 状态必须同时看**脚本进程**与**调度暂停**（修一个真 bug）★★
        //
        // 用户反馈: "虽然未暂停调度就绿色运行中，但是脚本进程停止时
        //            这个还显示运行中啊"
        //
        // 根因: 这里原先只看 `run_control` 的 `paused`（调度是否被暂停）,
        // **完全没看脚本进程** —— 没暂停就画绿点, 哪怕进程根本没跑。
        //
        // 修法: 圆点与文字先看**进程**（WebSocket 的 `ScriptModel.state`）,
        // 再看调度暂停。进程停了就一定是灰的, 不会再谎报。
        child: Obx(() {
          final svc = Get.find<ScriptService>();
          final sm = svc.scriptModelMap[_c.script];
          final procRunning = sm?.state.value == ScriptState.running;

          final Color dot;
          final String label;
          if (!procRunning) {
            dot = Colors.grey;
            label = '脚本未启动';
          } else if (restUntil != null) {
            dot = Colors.orange;
            label = '休息中 至 $restUntil';
          } else if (paused) {
            dot = Colors.orange;
            label = '已暂停调度';
          } else {
            dot = Colors.green;
            label = '运行中';
          }

          return Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // ---- 当前状态 ----
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 4),
              Text(label),

              // ---- 暂停 / 继续 ----
              //
              // ★ 用户要求**去掉「本轮跑完再停」**（此前的决策台账 1.2 已作废）。
              //   后端 `pause_mode='round'` 这个**能力保留不动**, 只是界面不再
              //   暴露入口 —— 与「只停列表」的处理一致。
              const SizedBox(width: 12),
              if (!paused)
                Tooltip(
                  message: '跑完当前这场战斗后不再开新任务\n'
                      '（安全停，不会卡在半途）\n'
                      '★ 固定任务与定时任务**都会**暂停',
                  child: FilledButton.icon(
                    // ★ 进程没跑时置灰 —— 暂停一个没在跑的东西没意义,
                    //   而且会让用户以为"点了有用"
                    onPressed: (_busy || !procRunning)
                        ? null
                        : () => _do(() => ApiClient()
                            .pauseScript(_c.script, mode: 'battle')),
                    icon: const Icon(Icons.pause, size: 18),
                    label: const Text('暂停调度'),
                  ),
                ),
              if (paused)
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _do(() => ApiClient().resumeScript(_c.script)),
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('继续调度'),
                ),
            ],
          );
        }),
      ),
    );
  }
}
