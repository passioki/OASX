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

  /// ★★ T11（审计修复）: **跟随控制器刷新** ★★
  ///
  /// ## 原来的 bug
  ///
  /// `_state` 只在 `initState` 拉一次（`_load()`）, 之后**再不刷新**
  /// —— 于是队列里 `rest`（休息）条目造成的「休息中」、以及**外部**暂停
  /// **都不会显示**, 圆点/文案长期停在旧值。
  ///
  /// ## 修法（★ 我第一版猜错了 API, 第二轮又发现去重写错）
  ///
  /// 我第一版写了 `ever(_c.updateFlag, ...)` —— **`updateFlag` 不存在**
  /// （我猜的）。`GetxController.update()` 只是**通知 `GetBuilder` 重建**,
  /// 不是可监听对象。
  ///
  /// 第二版改用 `GetBuilder` + 一个**按 `script` 记忆**的去重门 ——
  /// 复审员指出那门**只在首帧/换账号时为真**, 之后所有重建都被挡掉
  /// -> "跟随刷新"**仍然没生效**（已复核成立, 见 `_inFlight`）。
  ///
  /// ★ 最终方案: `GetBuilder`（重建）+ `_inFlight`（**只防同一次在飞**）。
  ///
  /// ★ 另: 中途用过的 `Rx<TaskListController> _ctl` **已删除** ——
  ///   复审员实测它**只被写、0 处读**（改用 `GetBuilder` 后忘了删）, 纯死接线。

  /// ★★ T11（第二轮复审修复）: **按 `script` 记忆是错的 —— 改成"在飞标志"** ★★
  ///
  /// ## 原来的 bug（复审员指出, 我复核成立）
  ///
  /// 我原来写:
  /// ```dart
  /// if (_loadedFor != _c.script) { _loadedFor = _c.script; ... _load(); }
  /// ```
  /// 那门只在**首帧**与**换账号**时为真 —— 之后**每次 `update()` 触发的重建
  /// 都被它挡掉** -> `_load()` **再也不会重拉** -> T11 声称的
  /// "外部暂停 / 队列里 `rest` 造成的休息中都会显示"**不成立**。
  ///
  /// ★ 正确做法: 去重**只防"同一次在飞"**, 不能防"下次刷新"。
  bool _inFlight = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant RunControlBar old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      _load();
    }
  }

  Future<void> _load() async {
    // ★ 只防"上一次还没回来就再发一次", 不防"以后再也不发"
    if (_inFlight) return;
    _inFlight = true;
    try {
      final s = await ApiClient().getRunControl(_c.script);
      if (!mounted) return;
      setState(() => _state = s);
    } finally {
      _inFlight = false;
    }
  }

  /// ★★ T11: 执行动作 —— **失败要上屏**（原来静默丢弃返回值）★★
  ///
  /// ## 原来的 bug
  ///
  /// `_do()` 里 `await fn();` —— 返回的 `bool` **被丢弃**。
  /// 后端失败时 `api_client` 返回 `false`, 而界面**毫无反应**
  /// -> 用户看到"点了没反应"（本项目反复强调要避免的体验）。
  Future<void> _do(Future<bool> Function() fn, String what) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ok = await fn();
      if (!mounted) return;
      if (!ok) {
        Get.snackbar(
          '操作失败',
          '「$what」没能生效 —— 请确认后端在运行, 然后看日志。',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 4),
        );
      }
      await _load();          // 成功失败都刷新（状态可能已部分变化）
    } catch (e) {
      if (mounted) {
        Get.snackbar('操作失败', '「$what」异常: $e',
            snackPosition: SnackPosition.BOTTOM,
            duration: const Duration(seconds: 5));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // ★★ T11: 跟随控制器 `reload()` 刷新 `run_control` 状态 ★★
    //
    // `TaskListController` 是 `GetxController`, 每次 `reload()` 会 `update()`;
    // 用 `GetBuilder` 包住 -> `update()` 时 builder 重跑 -> 我们重新 `_load()`。
    //
    // ⚠ **不能**在 build 里直接 `_load()`（会 `setState` during build 报错）
    //   -> 用 `addPostFrameCallback` 推到下一帧。
    // ⚠ 去重交给 `_load()` 内部的 `_inFlight`（**不能**按 script 记忆 ——
    //   那样会把后续所有刷新都挡掉, 见 `_inFlight` 的说明）。
    return GetBuilder<TaskListController>(
      // ★ 换账号时 `tag` 变 -> 用 `key` 强制重建 State 与**订阅**
      //   （GetBuilder 的 `didUpdateWidget` 只在 `id` 变时重订阅,
      //    `tag` 变了不会迁移, 会**继续订阅已被删除的旧控制器**）
      key: ValueKey('runcontrol:${_c.script}'),
      init: _c,                       // 不新建, 复用外部传入的那个
      tag: 'tasks:${_c.script}',      // ★ 与注册时的 tag 一致（多账号必需）
      builder: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _load();
        });
        return _body(context);
      },
    );
  }

  Widget _body(BuildContext context) {
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
                      '★ 临时任务与周期任务**都会**暂停',
                  child: FilledButton.icon(
                    // ★ 进程没跑时置灰 —— 暂停一个没在跑的东西没意义,
                    //   而且会让用户以为"点了有用"
                    onPressed: (_busy || !procRunning)
                        ? null
                        : () => _do(
                            () => ApiClient()
                                .pauseScript(_c.script, mode: 'battle'),
                            '暂停调度'),
                    icon: const Icon(Icons.pause, size: 18),
                    label: const Text('暂停调度'),
                  ),
                ),
              if (paused)
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _do(
                          () => ApiClient().resumeScript(_c.script),
                          '继续调度'),
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
