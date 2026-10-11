part of task_list;

/// 任务列表/总览的控制器。
///
/// ## 设计要点
///
/// * **不缓存任务知识** —— 类别标签、条目的效果名与说明、模式列表
///   全部来自 `/schema`, 前端不硬编码(否则又是"同一知识多处")
/// * **不做调度决策** —— `can_run` / `reason` / `next_run` 由后端算好
/// * 运行列表的**顺序**就是数组顺序(模型 B), 拖拽后整体 PUT 回去
/// * `task` 条目不阻塞、`rest` 阻塞 —— 这是后端语义,
///   前端只负责让用户看清"哪一条会停"
///
/// ## 日志（v2 新增）
///
/// v2 之后**任务列表页**是调度控制台, 日志显示在这里
/// （旧总览页的日志搬过来）。
///
/// 用 `LogMixin` 拿到 `logs` / `autoScroll` / `collapseLog` 等,
/// 再通过 `ScriptService.subscribeLog()` **订阅**该账号的日志 ——
/// **不额外开 WebSocket 连接**（那会让后端以为有第二个客户端,
/// 还会触发"already running and first stop it"那条路径）。
class TaskListController extends GetxController with LogMixin {
  TaskListController({required this.scriptName});

  final String scriptName;

  /// 取消日志订阅的函数（`onClose` 时调用）。
  void Function()? _unsubscribeLog;

  /// ★ **延迟**创建 `ApiClient`, 不要写成字段初始化 `final _api = ApiClient()`。
  ///
  /// `ApiClient` 的构造函数里会 `Get.find<SettingsController>()`,
  /// 所以字段初始化会让**构造控制器**就依赖 GetX 环境 ——
  /// widget 测试里直接 `FakeTaskListController(...)` 会抛
  /// "SettingsController not found"。改成懒加载后, 只读数据的测试
  /// 完全不需要 API 客户端。
  ApiClient? _apiCache;
  ApiClient get _api => _apiCache ??= ApiClient();

  // ---------------------------------------------------------------- 状态
  bool loading = false;
  bool busy = false;
  String? error;

  /// `/schema` 的原始内容。
  Map<String, dynamic> schema = {};

  /// `/overview` 的原始内容。
  Map<String, dynamic> overview = {};

  /// 运行列表的条目(原始 JSON, 顺序即执行顺序)。
  List<Map<String, dynamic>> entries = [];

  /// 「预期执行流程」推算。
  List<Map<String, dynamic>> flow = [];
  String flowDisclaimer = '推算, 不是预测';

  /// 界面用的任务行(已过滤)。
  List<Map<String, dynamic>> tasks = [];
  int runnableCount = 0;

  /// 批量选择。
  final Set<String> selected = {};

  // ---------------------------------------------------------------- 过滤
  String query = '';
  bool onlyEnabled = false;
  bool onlyFixed = false;
  /// 只看**定时任务**（`timed` / `charge` / `limited`）—— v2 补齐
  bool onlyTimed = false;
  /// 只看**限时活动**（`limited`）—— v2 补齐
  bool onlyLimited = false;

  // ---------------------------------------------------------------- 运行记录
  /// `task(command) -> {runs, seconds, seconds_text, archived_rounds, ...}`
  Map<String, dynamic> runRecord = {};

  /// 「运行一次」队列（按点击顺序）。
  List<String> runOnceQueue = [];

  // ---------------------------------------------------------------- 排序 + 偏好
  //
  // ★ 用户要求: "支持多列排序筛选且可以**持久记忆**用户的偏好，
  //   同时可以**恢复默认**（有相关功能说明和弹窗提示）"。
  //
  // ★ 排序**只影响显示顺序**，**不影响调度** —— 调度顺序由运行列表
  //   （`run_list`）与类别规则决定。若这里偷偷改了调度，
  //   用户会以为"排序等于调顺序"。

  /// 当前排序。默认与原型一致（按"下次运行"升序）。
  TaskSortSpec sortSpec = TaskSorter.defaultSpec;

  /// 偏好存储。
  ///
  /// ★ 默认是 **内存实现**，不是 `TaskPrefsStore` —— 后者在构造时会创建
  ///   `GetStorage`，而那会起一个 `Timer`，在 widget 测试里留下
  ///   `A Timer is still pending even after the widget tree was disposed`。
  ///
  /// ★ 真落盘由 `main.dart` 在 `GetStorage.init()` **之后**显式升级:
  ///
  ///     TaskListController.defaultPrefsStore = TaskPrefsStore();
  ///
  ///   这样"用哪种存储"是**启动时决定的事**，而不是每个控制器各自
  ///   去猜自己跑在测试还是生产里。
  static PrefsStore defaultPrefsStore = MemoryPrefsStore();

  PrefsStore prefsStore = TaskListController.defaultPrefsStore;

  bool _prefsLoaded = false;

  // ---------------------------------------------------------------- 脚本进程
  //
  // ★ 与"暂停调度"的区别:
  //     停止脚本 = OAS 的子进程结束(硬停, 可能停在半途)
  //     暂停调度 = 进程还在, 只是不再开新任务(安全停, 跑完当前这场)
  //   所以界面上**两者都要有** —— 只有暂停没有开始, 逻辑是断的(用户反馈)。

  /// 该账号的脚本现在是否在跑。
  ///
  /// 状态来自 WebSocket 推送的 `state`（`ScriptService` 在 `wsListener`
  /// 里维护 `ScriptModel.state`）—— 所以这里只是**读**，不额外发请求。
  /// ★★ T10（审计修复）: `scriptRunning` **已删除** ★★
  ///
  /// 它是**只读** getter, 但 `lib/` 内**无任何调用方**
  /// （实测引用数 = 1, 就是它自己的定义）。
  ///
  /// ★ 需要"进程在不在跑"的地方都直接读
  ///   `Get.find<ScriptService>().scriptModelMap[script]?.state.value`
  ///   —— 例如 `run_control_bar.dart` 就是这么写的（它要同时看
  ///   **进程**与**调度暂停**, 比这个单值 getter 更准）。

  /// 启动脚本。
  Future<bool> startScript() async {
    try {
      await Get.find<ScriptService>().startScript(scriptName);
      return true;
    } catch (e) {
      Get.snackbar('启动失败', '$e', snackPosition: SnackPosition.BOTTOM);
      return false;
    }
  }

  /// 停止脚本。
  Future<bool> stopScript() async {
    try {
      await Get.find<ScriptService>().stopScript(scriptName);
      return true;
    } catch (e) {
      Get.snackbar('停止失败', '$e', snackPosition: SnackPosition.BOTTOM);
      return false;
    }
  }

  // ---------------------------------------------------------------- 全局设置
  //
  // ⚠ 原型的「跑完循环整表」**后端没有对应字段** ——
  //   `Script.optimization` 里既没有 `loop_whole_list`, 也没有循环开关。
  //
  //   我没有为了"界面上有这一项"就造一个假字段(那会**静默失效** ——
  //   `script_set_arg` 遇到不存在的字段会返回 False 并记 error, 界面看不出来)。
  //
  //   改为暴露**后端真实支持**的 `when_task_queue_empty`:
  //   队列跑空之后要做什么(`goto_main` 回庭院 / `close_game` 关游戏)。
  //   见 `docs/ui-api-mapping.md` 缺口清单。
  //
  //   若将来要真正实现"循环整表", 需要后端加字段 + 调度器支持。

  /// 队列跑空之后的行为。
  String whenQueueEmpty = 'goto_main';

  /// 可选值（来自 `/schema` 的 `global_fields`，为空时用内置兜底）。
  List<Map<String, dynamic>> get queueEmptyChoices =>
      ((schemaGlobalFields['when_task_queue_empty']?['choices'] as List?) ??
              const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  Map<String, dynamic> get schemaGlobalFields =>
      (schemaList['global_fields'] as Map?)?.cast<String, dynamic>() ?? {};

  /// 队列跑空后那个下拉框的标题（来自 `/schema`，不硬编码）。
  String get queueEmptyLabel =>
      '${schemaGlobalFields['when_task_queue_empty']?['label'] ?? '队列跑空后'}';

  bool isQueueEmptyLoaded = false;

  // ★★★ P-3b: 队列循环的「循环轮数」与「已跑轮数」（用户裁定）★★★
  //
  // 用户原话:
  // > "我觉得选中后应该加一个**跑几次**的额外输入框, **0代表一直跑**,
  // >   **1、2……代表跑几次**。"
  // > "如果要重跑这几次循环要怎么设置呢 …… 是不是得有个**手动重置计数**
  // >  的按钮" -> ★ 用户选 **乙**: 加按钮

  /// 「循环轮数」—— **用户设置**（`0` = 一直跑）。
  ///
  /// ★ 只在**首次**从 `/schema` 读（与 `whenQueueEmpty` 同一理由:
  ///   否则用户刚改完、下次刷新又被打回去）。
  int loopTimes = 0;
  bool isLoopTimesLoaded = false;

  /// 「循环轮数」的界面标签（后端给中文，前端不维护映射）。
  String get loopTimesLabel =>
      '${schemaGlobalFields['loop_times']?['label'] ?? '循环轮数'}';

  /// 「已跑轮数」—— ★ **只读进度**（后端 `task_state` 里，**存盘**）。
  int get loopRoundsDone =>
      (schemaGlobalFields['loop_rounds_done']?['current'] as num?)?.toInt() ?? 0;

  /// 当前是不是"队列循环"模式 —— ★ 只在此时才显示轮数输入框与重置按钮。
  bool get isQueueLoop => whenQueueEmpty == 'loop';

  /// 写「循环轮数」（走既有通用接口，**不新开端点**）。
  Future<void> setLoopTimes(int n) async {
    loopTimes = n < 0 ? 0 : n;
    update();
    await _api.putScriptArg(scriptName, 'script', 'optimization',
        'loop_times', 'integer', loopTimes);
    await reload();
  }

  /// ★ **重置循环计数** —— 调新端点 `PUT /run_control/loop_reset`。
  ///
  /// ## 为什么是"清 0"而不是"设成 loop_times"
  ///
  /// 计数语义是"**已经跑了几轮**" —— 清 0 = "一轮都还没跑" = 可以再跑 N 轮。
  /// ★ "设成 N" 会让 `已跑 >= 目标` 仍然成立 -> **还是不会跑**（是反的）。
  Future<void> resetLoopRounds() async {
    final res = await _api.resetLoopRounds(scriptName);
    if (res.containsKey('error')) {
      _snack('重置失败', '${res['error']}');
      return;
    }
    _snack('已重置循环计数', '${res['message'] ?? '可以重新跑设定的轮数'}');
    await reload();
  }

  Map<String, dynamic> get schemaList =>
      (schema['list'] as Map?)?.cast<String, dynamic>() ?? {};

  // ★★ 第二轮复审（待办 #5）: `modes` / `listModeValue` / `listModeLabel`
  //   / `scheduleRule` / `scheduleRuleLabel` / `isScheduleRuleLoaded`
  //   **整簇已删除** ★★
  //
  // 它们读的是 `/schema` 的 `list.modes` / `list.mode_value` /
  // `list.current_mode` —— ★ 而那三个键**已从后端删除**
  // （T1 删掉 `TaskScheduler.schedule()` 调用后, 那四个调度模式
  // **不再影响排序**; S6 又并入 `priority_mode` 三模式）。
  //
  // ★ 危害: 这是"**已死的读写链**"—— 只差有人再调一次
  //   `setScheduleRule()`（它会 `putScriptArg('schedule_rule', ...)`
  //   **写配置**）就复活"两个排序权威"。
  //
  // ★ 现行做法: `priorityMode` / `priorityModeChoices` / `priorityModeLabel`
  //   （读 `global_fields.priority_mode`, 见下面）—— **活的**。

  /// 条目类型定义（值 + 效果名 + 说明 + 三个标志），**来自 `/schema`**。
  ///
  /// ★ 前端不硬编码 `task`/`rest`/`delay` 的名称 ——
  ///   后端改名(如从"休息"改成"全部停止")前端自动跟上。
  List<Map<String, dynamic>> get entryKinds =>
      ((schemaList['entry_kinds'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  List<int> get durationChoices =>
      ((schemaList['duration_choices'] as List?) ?? const [10, 30, 60])
          .map((e) => (e as num).toInt())
          .toList();

  /// 全部任务（不受过滤条件影响）。
  ///
  /// 「执行顺序」面板用它 —— 那是**用户编排**，不该跟着总览页的
  /// 搜索/过滤一起变。
  List<Map<String, dynamic>> get allTasks => _allTasks;

  /// 按任务名找任务行。列表里存的是 `command`（如 `FallenSun`），
  /// 而 `/overview` 的行里 `command` 与 `name`（下划线）都有，两边都认。
  Map<String, dynamic>? findTask(String commandOrKey) {
    for (final t in _allTasks) {
      if ('${t['command']}' == commandOrKey ||
          '${t['name']}' == commandOrKey) {
        return t;
      }
    }
    return null;
  }

  /// 某个条目类型的定义。
  Map<String, dynamic> kindOf(String kind) {
    for (final k in entryKinds) {
      if ('${k['value']}' == kind) return k;
    }
    return {'value': kind, 'label': kind, 'help': ''};
  }

  /// 条目的显示名（任务条目显示任务中文名，控制条目显示效果名）。
  String describeEntry(Map<String, dynamic> e) {
    final kind = '${e['kind']}';
    if (kind == 'task') {
      final t = '${e['task']}';
      return taskNameZh(t);
    }
    final k = kindOf(kind);
    final m = (e['minutes'] as num?)?.toInt() ?? 0;
    final dur = (m >= 60 && m % 60 == 0) ? '${m ~/ 60} 小时' : '$m 分钟';
    return '${k['label']} $dur';
  }

  // ★★ T10（审计修复）: `isTaskEntry()` **已删除** ★★
  //
  // 它只是 `'${e['kind']}' == 'task'` 的一行包装, 而 `lib/` 内**无调用方**
  // （实测引用数 = 1）。各处都直接写那个比较 —— 反而更清楚。

  /// 任务名(大驼峰) -> 中文名。
  String taskNameZh(String command) {
    for (final t in tasks) {
      if ('${t['command']}' == command) return '${t['name_zh'] ?? command}';
    }
    // 不在当前过滤结果里也在全量里找
    for (final t in _allTasks) {
      if ('${t['command']}' == command) return '${t['name_zh'] ?? command}';
    }
    return command;
  }

  List<Map<String, dynamic>> _allTasks = [];

  @override
  void onInit() {
    super.onInit();
    // ★ 用 microtask 延后一帧, 不要在 onInit 里同步拉数据 ——
    //   onInit 期间控制器的监听者还没挂好。
    Future.microtask(reload);
    _subscribeLog();
  }

  @override
  void onClose() {
    _searchDebounce?.cancel();
    // ★ 一定要取消订阅 —— 否则控制器销毁后 sink 还挂在
    //   `ScriptService` 上, 日志会往一个死控制器里塞。
    _unsubscribeLog?.call();
    _unsubscribeLog = null;
    super.onClose();
  }

  /// 订阅该账号的日志（复用已有的 WebSocket, 不另开连接）。
  void _subscribeLog() {
    try {
      final svc = Get.find<ScriptService>();
      _unsubscribeLog = svc.subscribeLog(scriptName, addLog);
      // 订阅那一刻可能已经有历史日志（`LogMixin` 自己缓存）
    } catch (e) {
      printError(info: '日志订阅失败: $e');
    }
  }

  // ---------------------------------------------------------------- 加载
  //
  // ★★ 方法名**不能叫 `refresh`** ★★
  //
  // `GetxController.refresh()` 是 GetX 的内置方法, 而且 `update()`
  // **内部会调用 `refresh()`**。如果覆盖它并在第一行写 `update()`,
  // 就会形成**同步死循环**:
  //
  //     update() -> GetX 调 refresh() -> 我的 refresh() 第一行 update() -> ...
  //
  // `update()` 在 `await` 之前是**同步**的, 所以 UI 线程直接卡死
  // (现象: 一点进任务列表就卡死)。踩过。
  //
  // 所以本方法叫 `reload`。
  Future<void> reload() async {
    loading = true;
    error = null;
    update();
    try {
      final results = await Future.wait([
        _api.getTaskSchema(scriptName),
        _api.getTaskOverview(scriptName),
        _api.getRunList(scriptName),
        _api.getRunListPreview(scriptName),
      ]);
      schema = results[0];
      overview = results[1];
      final rl = results[2];
      final pv = results[3];

      if (overview.containsKey('error')) error = '${overview['error']}';

      entries = ((rl['entries'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      flow = ((pv['flow'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      flowDisclaimer = '${pv['disclaimer'] ?? flowDisclaimer}';

      runnableCount = (overview['runnable'] as num?)?.toInt() ?? 0;
      _allTasks = ((overview['tasks'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      // 运行记录与「运行一次」队列 —— `/schema` 里已经带了, 不必多请求。
      final rr = schemaList['run_record'];
      runRecord = rr is Map ? rr.cast<String, dynamic>() : {};
      final mq = schemaList['manual_run'];
      runOnceQueue = ((mq is Map ? mq['tasks'] : null) as List?) == null
          ? <String>[]
          : ((mq as Map)['tasks'] as List).map((e) => '$e').toList();

      // ★★ 偏好要在**第一次过滤之前**载入 ★★
      //
      // ★ #9: 配置页列表也必须**先**拿到 —— 因为偏好的隔离键是
      //   `<账号>:<页id>`（用户裁定 2A: 三项前端偏好按页隔离）。
      //   顺序反了会读到"账号级"的旧 key, 看起来像"偏好丢了"。
      await loadQueueProfiles();
      _loadPrefs();
      // ★ 把载入的搜索词**同步回输入框** —— 否则重启后
      //   `query` 有值但输入框是空的（状态与显示不一致）。
      //   `TextEditingController.text` 同值赋值不会触发 listener,
      //   所以每次 reload 都调用是安全的。
      onQueryChanged?.call(query);

      // 全局设置: 当前值来自 `/schema` 的 `global_fields`
      // ★ 只在**首次**读取时赋值 —— 否则用户刚改完、下次刷新又被打回去
      //   (界面会看起来"改了不生效")
      if (!isQueueEmptyLoaded) {
        final qe = schemaGlobalFields['when_task_queue_empty'];
        if (qe is Map && '${qe['current']}'.isNotEmpty) {
          whenQueueEmpty = '${qe['current']}';
          isQueueEmptyLoaded = true;
        }
        // 调度模式同理 —— 不能硬编码 'Filter', 否则会误报
        // "顺序不生效"(实际用户早设成 List 了)
        // ★ 待办 #5: 原来这里从 `/schema` 的 `list.current_mode` 读
        //   "当前调度模式" —— 那个键**已从后端删除**
        //   （模式改由 `global_fields.priority_mode` 表达）。
      }

      // 已编排 -> 顺序由 entries 决定; 未编排 -> 用后端给的默认顺序
      _applyFilter();
    } catch (e) {
      error = '$e';
    } finally {
      loading = false;
      update();
    }
  }

  // ---------------------------------------------------------------- 过滤
  //
  // ★★ 搜索框必须**受控**（踩过的坑）★★
  //
  // 以前搜索框只有 `onChanged: c.setQuery`（没有 `TextEditingController`），
  // 而 `setQuery` 里的 `update()` **故意不重建输入框那部分**（为了输入流畅）。
  // 于是出现了"清空搜索后任务不恢复"：
  //
  //   * 控制器里 `query` 已经清了，但**输入框的显示与视图状态没跟着复位**
  //   * 反向也坏: `恢复默认` 清了 `query`, **输入框里的旧文字还在**
  //   * 重启后 `_loadPrefs()` 恢复了 `query`，但**输入框是空的**
  //
  // 修法: 视图持有一个 `TextEditingController`，并由控制器通过
  // `onQueryChanged` 回调**反向同步** —— 任何改动 `query` 的路径
  // （清空 / 恢复默认 / 加载偏好 / 切换账号）都会更新输入框。
  //
  // 同一时刻只有一个视图，所以用**单个回调**而不是监听器列表。

  /// 视图注册进来的"把 query 写回输入框"的回调。
  void Function(String query)? onQueryChanged;

  /// 搜索防抖 —— 输入时不要每敲一个键就重排 54 行。
  ///
  /// ★ 之前是**每击键**都 `_applyFilter() + update()`（54 行全重建），
  ///   这正是用户说的"调配并不流畅"的一个来源。
  Timer? _searchDebounce;

  static const _searchDebounceMs = 250;

  /// 输入框变化（**每击键**调用）。
  ///
  /// 立刻记住 `query`（便宜），但**延迟**过滤与重建（贵）。
  void setQuery(String v) {
    query = v.trim();
    _savePrefs();
    _searchDebounce?.cancel();
    _searchDebounce = Timer(
      const Duration(milliseconds: _searchDebounceMs),
      () {
        _applyFilter();
        update();
      },
    );
  }

  /// 立刻应用搜索（不防抖）—— 用于"清除"按钮与回车。
  void applyQueryNow(String v) {
    query = v.trim();
    _savePrefs();
    _searchDebounce?.cancel();
    _applyFilter();
    update();
    // 同步输入框（例如点了"清除"，输入框要跟着空）
    onQueryChanged?.call(query);
  }

  /// **清除搜索** —— 一键复位。
  void clearQuery() => applyQueryNow('');


  void toggleOnlyEnabled() {
    onlyEnabled = !onlyEnabled;
    _savePrefs();
    _applyFilter();
    update();
  }

  void toggleOnlyFixed() {
    onlyFixed = !onlyFixed;
    // 四个"只看 X"是**互斥**的 —— 同时勾"只看固定"和"只看定时"结果必为空,
    // 用户会以为坏了。勾一个就取消其他的。
    if (onlyFixed) {
      onlyTimed = false;
      onlyLimited = false;
    }
    _savePrefs();
    _applyFilter();
    update();
  }

  void toggleOnlyTimed() {
    onlyTimed = !onlyTimed;
    if (onlyTimed) {
      onlyFixed = false;
      onlyLimited = false;
    }
    _savePrefs();
    _applyFilter();
    update();
  }

  void toggleOnlyLimited() {
    onlyLimited = !onlyLimited;
    if (onlyLimited) {
      onlyFixed = false;
      onlyTimed = false;
    }
    _savePrefs();
    _applyFilter();
    update();
  }

  void _applyFilter() {
    var all = _allTasks;
    if (onlyEnabled) {
      all = all.where((t) => t['enable'] == true).toList();
    }
    if (onlyFixed) {
      // "固定任务"由后端给的 `countable` 决定（= fixed / toppa）
      all = all.where((t) => t['countable'] == true).toList();
    }
    if (onlyTimed) {
      // "定时任务"= 不是 countable 的**且有次数以外的时间语义**
      // 后端给的 `category` 是权威来源, 这里只做筛选, 不重新定义知识。
      all = all.where((t) =>
          ['timed', 'charge', 'limited'].contains('${t['category']}')).toList();
    }
    if (onlyLimited) {
      all = all.where((t) => '${t['category']}' == 'limited').toList();
    }
    if (query.isNotEmpty) {
      final q = query.toLowerCase();
      all = all.where((t) =>
          '${t['name_zh'] ?? ''}'.contains(query) ||
          '${t['name'] ?? ''}'.toLowerCase().contains(q) ||
          '${t['command'] ?? ''}'.toLowerCase().contains(q)).toList();
    }
    tasks = all;

    final names = tasks.map((t) => '${t['name']}').toSet();
    selected.removeWhere((n) => !names.contains(n));

    // ★ 排序放在**过滤之后** —— 顺序反了会让"按列排序"只作用于
    //   过滤前的全集, 看起来像排序不生效。
    _applySort();
  }

  // ---------------------------------------------------------------- 配置页（#9）
  //
  // 用户原话:
  // > "添加**执行顺序配置页 1/2/3/……**，可以添加、删除和切换配置页"
  //
  // ★ 一页 = **整页快照**（用户裁定「1甲」= 全都算）:
  //   队列 + 每任务调度（启停/次数/优先级/预期耗时）+ **全局开关**。
  // ★ 所以「切换 / 删除」之后必须 `reload()` —— 队列**和**全局开关都变了,
  //   只刷新队列会让界面显示旧的总开关（那就成了"改了不生效"）。

  /// 配置页列表（`[{id,name,count,active}]`）。空列表 = 后端没给 / 还没加载。
  List<Map<String, dynamic>> queueProfiles = [];

  /// 当前页 id（'' = 未知）。
  ///
  /// ★ 它同时是 `TaskPrefsStore` 的**隔离键**的一部分（见 `_prefsKey`）:
  ///   每页各有自己的排序列/筛选/分栏宽度（用户裁定「2A」= 算）。
  String queueProfileId = '';

  /// 当前页名字（找不到时回退成 id）。
  String get queueProfileName {
    final cur = queueProfiles.firstWhere(
      (p) => '${p['id']}' == queueProfileId,
      orElse: () => const {},
    );
    final n = '${cur['name'] ?? ''}';
    return n.isEmpty ? (queueProfileId.isEmpty ? '1' : queueProfileId) : n;
  }

  /// 加载配置页列表。
  ///
  /// ★ **失败不抛**: 后端旧版本没有这组端点时返回 404, 那时界面
  ///   只显示当前页, 不该让整个任务列表打不开。
  Future<void> loadQueueProfiles() async {
    try {
      final res = await _api.getQueueProfiles(scriptName);
      final err = '${res['error'] ?? ''}';
      if (err.isNotEmpty) {
        printError(info: '配置页读取失败: $err');
        return;
      }
      final list = (res['profiles'] as List?) ?? const [];
      queueProfiles = list
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      queueProfileId = '${res['active_id'] ?? ''}';
      if (queueProfileId.isEmpty && queueProfiles.isNotEmpty) {
        queueProfileId = '${queueProfiles.first['id'] ?? ''}';
      }
    } catch (e) {
      printError(info: '配置页读取异常: $e');
    }
  }

  /// 新建一页（后端把**当前**队列存为新页并切过去）。
  ///
  /// :return 给用户看的**中文提示**（后端 `message`, 界面直接上屏）
  Future<String> createQueueProfile({String? name, String? copyFrom}) async {
    final res = await _api.createQueueProfile(scriptName,
        name: name, copyFrom: copyFrom);
    if (res['ok'] == true) {
      await loadQueueProfiles();
      await reload();
      return '${res['message'] ?? '已新建配置页'}';
    }
    return '新建失败: ${res['error'] ?? '未知错误'}';
  }

  /// ★★★ 片 5 (F2d): **让某一条条目立刻运行**（队列行的「▶ 播放」）★★★
  ///
  /// > 用户: "我还想添加一个按钮，**每个队列里的任务都有一个播放按钮**，
  /// >  点一下就可以**切换成正在运行**。"
  ///
  /// ★ 后端把该条目的 `next_run` 拉到现在（与"乱序"同一手法）——
  ///   **不改调度核心**，调度器下一轮自然选它。
  /// ★ 返回**后端原话**（成功或失败原因都要上屏 ——
  ///   尤其"当前不可跑"必须让用户看见，不能静默）。
  Future<String> playEntry(String entryId) async {
    if (playingEntry == true) return '上一条还在处理…';
    playingEntry = true;
    update();
    try {
      final res = await _api.playEntry(scriptName, entryId);
      if (res['ok'] == true) {
        await reload();
        return '✓ ${res['message'] ?? '已排到最前'}';
      }
      return '${res['error'] ?? '未知错误'}';
    } finally {
      playingEntry = false;
      update();
    }
  }

  /// ★ 正在处理"播放"请求（防止连点）。
  bool? playingEntry = false;

  /// ★ **复制某一页**（歌单）—— 片 5 / F3。
  /// ★ 用户要求：
  /// > "目前对任务顺序配置页（歌单）的操作**少了一个复制**，
  /// >  后续需要添加这个功能"
  ///
  /// ★ 走**同一个端点**（`POST /queue/profiles` + `copy_from`），
  ///   **不新开端点** —— 与"新建"的区别只是模板来源：
  ///   新建 = 当前状态；复制 = **那一页的快照**。
  ///
  /// :return 给用户看的中文提示（后端 `message`）
  Future<String> copyQueueProfile(String id) async {
    final res = await _api.createQueueProfile(scriptName, copyFrom: id);
    if (res['ok'] == true) {
      await loadQueueProfiles();
      await reload();
      return '${res['message'] ?? '已复制配置页'}';
    }
    return '复制失败: ${res['error'] ?? '未知错误'}';
  }

  /// 切换到某一页。
  ///
  /// ★ 后端在同一个请求里先存当前页再载目标页（原子）, 前端只管刷新。
  Future<String> activateQueueProfile(String id) async {
    final res = await _api.activateQueueProfile(scriptName, id);
    if (res['ok'] == true) {
      // ★ 切页 -> **换偏好的隔离 key**（先把旧页三项存回, 再载新页的）
      _switchPrefsPage(id);
      await loadQueueProfiles();
      await reload();
      return '${res['message'] ?? '已切换配置页'}';
    }
    return '切换失败: ${res['error'] ?? '未知错误'}';
  }

  /// 给配置页改名（**只改名字**, 不动页内容）。
  Future<String> renameQueueProfile(String id, String name) async {
    final res = await _api.renameQueueProfile(scriptName, id, name);
    if (res['ok'] == true) {
      await loadQueueProfiles();
      update();
      return '${res['message'] ?? '已改名'}';
    }
    return '改名失败: ${res['error'] ?? '未知错误'}';
  }

  /// 删除一页（后端保证至少留一页）。
  ///
  /// ★ 删掉的如果是**当前页**, 后端会把 active 换成剩下第一页 ——
  ///   那时偏好 key 也要跟着走, 否则会显示"已删那页"的排序（看起来像串页）。
  Future<String> deleteQueueProfile(String id) async {
    final res = await _api.deleteQueueProfile(scriptName, id);
    if (res['ok'] == true) {
      final wasActive = id.trim() == queueProfileId.trim();
      await loadQueueProfiles();
      if (wasActive && queueProfileId.trim() != id.trim()) {
        // 只换 key（旧页已被删, 没必要再存回去）
        _prefsLoaded = false;
        _applyFilter();
      }
      await reload();
      return '${res['message'] ?? '已删除配置页'}';
    }
    return '删除失败: ${res['error'] ?? '未知错误'}';
  }

  /// 排序 + 过滤的入口（`_applyFilter` 之后调）。
  void _applySort() {
    tasks = TaskSorter.apply(
      tasks,
      sortSpec,
      recordOf: (cmd) => recordOf(cmd),
    );
  }

  // ---------------------------------------------------------------- 偏好持久化
  //
  // ★★★ 按**配置页**隔离（用户裁定「2A」）★★★
  //
  // 用户原话:
  // > "添加**执行顺序配置页 1/2/3/……**，可以添加、删除和切换配置页"
  // > "2：**算**（排序列/升降序 · 只看筛选 · 分栏宽度, 按页隔离）"
  //
  // 所以偏好 key 是 `<账号>:<页id>`（不是只按账号）——
  // 「日常」页按累计次数排序、「周末」页按下次运行排序, 互不干扰。
  //
  // ⚠ 兼容: 页 id 未知（后端旧版 / 还没加载完）时**退回只按账号** ——
  //   否则会读到一个永远空的 key, 用户的偏好看起来"丢了"。
  String get _prefsKey {
    final pid = queueProfileId.trim();
    return pid.isEmpty ? scriptName : '$scriptName:$pid';
  }

  /// 从磁盘读偏好（**只读一次** —— 之后以内存为准，避免把用户刚改的打回去）。
  void _loadPrefs() {
    if (_prefsLoaded) return;
    _prefsLoaded = true;
    try {
      final p = prefsStore.read(_prefsKey);
      final spec = TaskSortSpec.fromJson(p['sort']);
      if (spec != null && TaskSorter.isKnownColumn(spec.column)) {
        sortSpec = spec;
      }
      onlyEnabled = p['onlyEnabled'] == true;
      onlyFixed = p['onlyFixed'] == true;
      onlyTimed = p['onlyTimed'] == true;
      onlyLimited = p['onlyLimited'] == true;
      query = '${p['query'] ?? ''}';
    } catch (e) {
      printError(info: '偏好读取失败: $e');
    }
  }

  void _savePrefs() {
    try {
      prefsStore.write(_prefsKey, {
        'sort': sortSpec.toJson(),
        'onlyEnabled': onlyEnabled,
        'onlyFixed': onlyFixed,
        'onlyTimed': onlyTimed,
        'onlyLimited': onlyLimited,
        if (query.isNotEmpty) 'query': query,
      });
    } catch (e) {
      printError(info: '偏好保存失败: $e');
    }
  }

  /// 切页时**换偏好 key**: 先把当前三项存回 `<账号>:<当前页id>`,
  /// 再从 `<账号>:<目标页id>` 载入。
  ///
  /// ★ 调用方必须在 `activateQueueProfile()` **之前**调它 ——
  ///   那时 `queueProfileId` 还是**旧页**, 正好用来存旧页的偏好;
  ///   载新页要等后端返回新 id 之后（`reload()` 里 `_loadPrefs()`）。
  ///
  /// ⚠ 为什么不能只改 key 不搬数据: `_loadPrefs` 有 `_prefsLoaded` 重入闸
  ///   （只读一次盘）—— 不把它清掉, 切页后界面**还是旧页的排序**,
  ///   看起来"切页没反应"。
  void _switchPrefsPage(String nextProfileId) {
    final next = nextProfileId.trim();
    if (next.isEmpty || next == queueProfileId.trim()) return;
    _savePrefs();          // ★ ① 旧页的偏好落盘（key 里的 id 还是旧页）
    queueProfileId = next; // ★ ② 换 key
    _prefsLoaded = false;  // ★ ③ 允许再读一次盘（新页的）
    _loadPrefs();          // ★ ④ 载新页的偏好
    _applyFilter();
    update();
  }

  /// 切换排序列（点表头）。同一列再点 = 切换升降序。
  void sortBy(String column) {
    if (!TaskSorter.isKnownColumn(column)) return;
    if (sortSpec.column == column) {
      sortSpec = sortSpec.copyWith(ascending: !sortSpec.ascending);
    } else {
      // 换列时**重置为升序** —— 用户在 B 列想要的是"从头看",
      // 而不是继承 A 列的降序（那会让人困惑）。
      sortSpec = TaskSortSpec(column: column);
    }
    _savePrefs();
    _applyFilter();
    update();
  }

  /// 恢复默认 —— **要二次确认**（用户明确要求"有弹窗提示"）。
  Future<bool> restoreDefaults() async {
    final ok = await _confirm(
      '恢复默认',
      '会把这些**界面偏好**恢复成默认值：\n\n'
      '• 排序：按「下次运行」升序\n'
      '• 清除全部筛选与搜索词\n\n'
      '★ **不影响任务配置、运行记录与执行顺序** —— 只重置界面偏好。\n\n'
      '确定继续吗？',
    );
    if (!ok) return false;
    // ★ #9: 清的是**当前页**的偏好（`<账号>:<页id>`）—— 别的页不受影响
    prefsStore.clear(_prefsKey);
    sortSpec = TaskSorter.defaultSpec;
    onlyEnabled = false;
    onlyFixed = false;
    onlyTimed = false;
    onlyLimited = false;
    query = '';
    _applyFilter();
    update();
    // ★ 必须把输入框也清空 —— 否则界面显示"还在搜索"（踩过:
    //   控制器里清了、输入框里的旧文字还在, 用户以为没生效）。
    onQueryChanged?.call('');
    Get.snackbar('已恢复默认', '界面偏好已重置', snackPosition: SnackPosition.BOTTOM);
    return true;
  }

  // ---------------------------------------------------------------- 运行记录
  //
  // ★ 「重置」= **归档后重开**（不是删除）—— 后端 `run_record` 的语义。
  //   界面上要给二次确认弹窗（用户明确要求）。

  /// 某任务的运行记录（读不到给空）。
  ///
  /// ## ★★ 审计修复: 键必须**归一化** ★★
  ///
  /// 后端 `run_record` 的键是**小写、去下划线**（`module/config/run_record.py`
  /// 的 `_norm()`）, 实测真实状态文件 `log/.run_record.json` 的键是
  /// `demonencounter` / `realmraid` / `dailytrifles`。
  ///
  /// 而这里原来用**大驼峰 command**（`DemonEncounter`）直接查 -> **永远查不到**
  /// -> 「运行记录」列恒显示「—」, 按累计次数/耗时排序**恒为 0**。
  ///
  /// ★ 归一化规则与后端**逐字一致**: `lower()` + 去掉 `_`。
  static String _normKey(String s) => s.toLowerCase().replaceAll('_', '');

  Map<String, dynamic> recordOf(String command) {
    if (command.isEmpty) return const {};
    final r = runRecord[command] ?? runRecord[_normKey(command)];
    return r is Map ? r.cast<String, dynamic>() : const {};
  }

  /// 某任务的"跑了多久"可读文本（后端已格式化好）。
  String durationTextOf(String command) =>
      '${recordOf(command)['seconds_text'] ?? ''}';

  /// 某任务累计跑了几次。
  int runsOf(String command) =>
      (recordOf(command)['runs'] as num?)?.toInt() ?? 0;

  /// **重置选中** —— 归档后重开（会弹二次确认）。
  ///
  /// :return: 是否真的执行了
  Future<bool> resetSelected() async {
    final names = selected.map(nameToCommand).where((s) => s.isNotEmpty).toList();
    if (names.isEmpty) return false;
    final ok = await _confirm(
      '重置选中（${names.length} 个）',
      '会把它们的**当前运行记录归档**，然后从零重新计数。\n'
      '历史记录**不会删除**，仍可在归档里查看。\n\n'
      '确定继续吗？',
    );
    if (!ok) return false;
    busy = true;
    update();
    try {
      final r = await _api.resetRunRecord(scriptName, names);
      if (r.containsKey('error')) {
        Get.snackbar('重置失败', '${r['error']}', snackPosition: SnackPosition.BOTTOM);
        return false;
      }
      Get.snackbar('已重置', '归档了 ${r['archived_rounds'] ?? 0} 轮', snackPosition: SnackPosition.BOTTOM);
      selected.clear();
      return true;
    } finally {
      busy = false;
      update();
    }
  }

  /// **运行一次** —— 按选中顺序排队（跑完当前任务/战斗后插队）。
  Future<bool> runOnceSelected() async {
    final names = selected.map(nameToCommand).where((s) => s.isNotEmpty).toList();
    if (names.isEmpty) return false;
    busy = true;
    update();
    try {
      final r = await _api.requestRunOnce(scriptName, names);
      if (r.containsKey('error')) {
        Get.snackbar('排队失败', '${r['error']}', snackPosition: SnackPosition.BOTTOM);
        return false;
      }
      runOnceQueue = ((r['tasks'] as List?) ?? const [])
          .map((e) => '$e')
          .toList();
      Get.snackbar('已排队', '${names.length} 个任务将在当前任务结束后依次运行', snackPosition: SnackPosition.BOTTOM);
      selected.clear();
      return true;
    } finally {
      busy = false;
      update();
    }
  }

  /// 取消一个排队中的「运行一次」。
  Future<void> cancelRunOnce(String command) async {
    await _api.cancelRunOnce(scriptName, task: command);
    await reload();
  }

  /// 清空「运行一次」队列。
  Future<void> clearRunOnce() async {
    await _api.cancelRunOnce(scriptName);
    await reload();
  }

  /// `name`（下划线键）-> `command`（大驼峰）。找不到原样返回。
  String nameToCommand(String name) {
    for (final t in _allTasks) {
      if ('${t['name']}' == name) return '${t['command']}';
    }
    return name;
  }

  /// `command`（大驼峰）-> **中文名**。找不到返回空串。
  ///
  /// ## 为什么需要它（用户反馈"监控中都是英文"）
  ///
  /// WebSocket 推过来的 `taskName` 是**命令名**（`DemonEncounter`），
  /// 直接显示就是英文。这里用 `/overview` 里各任务的 `name_zh`
  /// 翻成中文 —— 那 54 个中文名来自各任务的 `meta.py`，
  /// **前端不维护第二份**。
  ///
  /// ★ 用懒加载的 `Map` 缓存: 监控列表每次刷新会查几十次,
  ///   线性扫描 54 个元素 × 每次重建 = 不必要。
  String zhNameOf(String command) {
    if (command.isEmpty) return '';
    if (_zhMap == null || _zhMapFor != _allTasks.length) {
      _zhMap = {
        for (final t in _allTasks) '${t['command']}': '${t['name_zh'] ?? ''}',
      };
      _zhMapFor = _allTasks.length;
    }
    return _zhMap![command] ?? '';
  }

  Map<String, String>? _zhMap;
  int _zhMapFor = -1;

  // ---------------------------------------------------------------- 批量选择
  void selectAll() {
    selected
      ..clear()
      ..addAll(tasks.map((t) => '${t['name']}'));
    update();
  }

  void selectNone() {
    selected.clear();
    update();
  }

  void selectInvert() {
    final all = tasks.map((t) => '${t['name']}').toSet();
    final keep = all.difference(selected);
    selected
      ..clear()
      ..addAll(keep);
    update();
  }

  void selectListOnly() {
    selected
      ..clear()
      ..addAll(tasks
          .where((t) => t['in_list'] == true)
          .map((t) => '${t['name']}'));
    update();
  }

  void toggleSelected(String name) {
    if (!selected.remove(name)) selected.add(name);
    update();
  }

  /// 批量启用/停用。
  ///
  /// ⚠ 目前是"逐个 PUT"(N 个任务 = N 次请求) —— 后端还没有批量写入端点。
  /// 见 `docs/ui-api-mapping.md` 的缺口清单。
  Future<void> bulkApply(bool enable) async {
    final names = selected.toList();
    if (names.isEmpty) return;
    busy = true;
    update();
    try {
      await Future.wait(names.map((n) => setEnabled(n, enable)));
      selected.clear();
    } finally {
      busy = false;
      update();
    }
    await reload();
  }

  // ---------------------------------------------------------------- 单行写入
  /// 启用/停用(任务级长期开关)。
  Future<bool> setEnabled(String taskName, bool enable) => _api.putScriptArg(
      scriptName, taskName, 'scheduler', 'enable', 'boolean', enable);

  /// 设置目标次数（**任务级默认值**）。
  ///
  /// ⚠ `scheduler.target` 是**调度决策**(本轮想打几次), 与任务配置里的
  ///   `limit_count`(**能力上限**)不是一回事。`0` = 用默认值。
  Future<bool> setTarget(String taskName, int target) => _api.putScriptArg(
      scriptName, taskName, 'scheduler', 'target', 'integer', target);

  // ★★★ 条目级「次数」（用户裁定 —— 修"改一条全变"的 bug）★★★
  //
  // ## 用户报的 bug
  //
  // > "当前临时任务**重复添加**后，修改**次数/时间会同步到所有的同种任务**，
  // >  而不是分开"
  //
  // ## 根因
  //
  // 次数原来只存在**任务级** `scheduler.target` —— 改一条 = 所有同任务条目
  // 一起变。而队列里同一任务可以有多条条目（用户用重复条目表达
  // "重复跑整个任务"）。
  //
  // ## 修法（用户裁定 **甲**）
  //
  // * ★ **条目级 `target > 0`** = "**这一条**跑几次"
  // * 否则回落任务级 `scheduler.target`（**保留为默认值**）
  //
  // ★ 写入走**已有的** `PUT /run_list`（整体替换）——
  //   **不新开端点**，且与"拖动排序"用同一条保存路径
  //   （`saveEntriesNow()`），所以不会出现"两套写盘逻辑打架"。

  /// 该条目**自己的**次数（`0` = 用任务级默认值）。
  ///
  /// ★ 读的是 `entries` 里的条目字段（来自 `GET /run_list` 的 `entries`），
  ///   **不是** `/overview` 的任务级 `target`。
  int entryTargetOf(Map<String, dynamic> entry) =>
      (entry['target'] as num?)?.toInt() ?? 0;

  /// ★ **改某一条条目自己的次数**（不动任务级默认值, 也不动别的条目）。
  ///
  /// 按 `entry_id` 精确定位（"**身份，不是位置**" —— 见
  /// `docs/scheduler-architecture.md` §1.5）；拿不到 `entry_id` 时退回按下标。
  ///
  /// :return 是否真的改到了（`false` = 找不到那条 -> 调用方应提示）
  Future<bool> setEntryTarget(Map<String, dynamic> entry, int target) async {
    final t = target < 0 ? 0 : target;
    final eid = '${entry['_entryId'] ?? entry['entry_id'] ?? ''}';
    var hit = false;
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      final same = eid.isNotEmpty
          ? '${e['entry_id'] ?? ''}' == eid
          : identical(e, entry) ||
              (e['_entryIndex'] == entry['_entryIndex'] &&
                  '${e['task']}' == '${entry['task']}');
      if (!same) continue;
      final copy = Map<String, dynamic>.from(e);
      if (t > 0) {
        copy['target'] = t;
      } else {
        // ★ 0 = 用任务级默认值 -> **删掉这个键**（与后端"非零才写"一致）
        copy.remove('target');
      }
      entries[i] = copy;
      hit = true;
      break;
    }
    if (!hit) {
      _snack('改次数失败', '队列里找不到这一条（可能刚被删除/重排）—— 请刷新');
      return false;
    }
    update();
    await saveEntriesNow();
    await reload();
    return true;
  }

  /// ★ 批量把**任务级 `scheduler.target`** 的当前值**灌进各条目**（迁移用）。
  ///
  /// 场景: 老配置里次数只在任务级；用户重复添加后想要"每条各设"。
  /// ★ 只对**还没设过条目级次数**的条目生效（不覆盖用户已设的）。
  Future<int> seedEntryTargetsFromTaskLevel() async {
    var n = 0;
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if ('${e['kind']}' != 'task') continue;
      if ((e['target'] as num?)?.toInt() != null &&
          (e['target'] as num?)!.toInt() > 0) {
        continue; // 已设过 -> 不覆盖
      }
      final row = taskRowOf('${e['task']}');
      final t = (row['target'] as num?)?.toInt() ?? 0;
      if (t <= 0) continue;
      final copy = Map<String, dynamic>.from(e);
      copy['target'] = t;
      entries[i] = copy;
      n++;
    }
    if (n > 0) {
      update();
      await saveEntriesNow();
      await reload();
    }
    return n;
  }

  // ---------------------------------------------------------------- 运行列表
  /// 拖拽重排（整体替换 —— 位置信息完整, 不做"保持原位"的猜测）。
  Future<void> reorderEntries(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex -= 1;
    final item = entries.removeAt(oldIndex);
    entries.insert(newIndex, item);
    update();
    await _saveEntries();
  }

  /// 把某个**任务命令名**在运行列表里**上移一位**。
  ///
  /// ★ 为什么需要它（用户要求"调度面板里就能控制顺序"）:
  ///   表格里每个任务行都要能直接调顺序, 不必切到另一个页面拖拽。
  ///
  /// 行为:
  /// * 任务**已在列表里** -> 与上一个条目交换位置
  /// * 任务**不在列表里** -> **追加到列表末尾**（首次加入 = 排在最后）
  ///
  /// :return: 是否真的改动了
  Future<bool> moveEntryUp(String command) async {
    final idx = _entryIndex(command);
    if (idx < 0) {
      // 不在列表里 -> 追加（加入后可以用 ↓ 往下调）
      await addEntry({'kind': 'task', 'task': command});
      return true;
    }
    if (idx == 0) return false;       // 已在最前
    final item = entries.removeAt(idx);
    entries.insert(idx - 1, item);
    update();
    await _saveEntries();
    return true;
  }

  /// 把某个**任务命令名**在运行列表里**下移一位**。
  ///
  /// 不在列表里时**不做任何事**（不能用"下移"来加入 —— 那语义反了,
  /// 会让人以为点了没反应). 返回 false 让界面提示"先加入"。
  Future<bool> moveEntryDown(String command) async {
    final idx = _entryIndex(command);
    if (idx < 0) return false;
    if (idx >= entries.length - 1) return false;   // 已在最后
    final item = entries.removeAt(idx);
    entries.insert(idx + 1, item);
    update();
    await _saveEntries();
    return true;
  }

  /// 某个任务命令名在运行列表里的**条目下标**（不在则 -1）。
  /// 找条目的下标。
  ///
  /// ★ [entryId] 非空时**按条目身份**定位（同名多条时必需）;
  ///   否则退回按任务名（找**第一条**）—— 向后兼容。
  int _entryIndex(String command, {String? entryId}) {
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if ('${e['kind']}' != 'task') continue;
      if (entryId != null && entryId.isNotEmpty) {
        if ('${e['entry_id'] ?? ''}' == entryId) return i;
        continue;
      }
      if ('${e['task']}' == command) return i;
    }
    return -1;
  }

  /// 某个任务命令名在运行列表里的**位次**（1 起; 不在则 0）。
  ///
  /// ★ 用途仅限于**任务表格的"队列"列**（只读展示"这个任务在不在队列里"）。
  ///
  ///   ⚠ 它**不是**执行顺序的编辑入口 —— 用户明确说过:
  ///     "这个位次列执行顺序和我的想法不相符, 我要的 ↑↓ 是为了像 EXCEL 那样
  ///      方便查看和管理任务（如启停和运行一次的测试）,
  ///      这个任务表格**不涉及执行顺序的改变**"
  ///
  ///   执行顺序统一在「执行队列」面板里拖拽。
  int entryPositionOf(String command) {
    final i = _entryIndex(command);
    return i < 0 ? 0 : i + 1;
  }

  // ---------------------------------------------------------------- 执行队列
  //
  // ★★ 用户要求: "待执行、等待中这类就是预期执行流程, 也相当于包含所有任务的
  //    执行顺序, 也应该可以拖拽排列顺序" ★★
  //
  // 所以不再把「待执行」「等待中」做成两个**只读**观察窗 ——
  // 而是一个**有序、可拖拽**的队列, 每行带一个状态徽标说明它为什么在等。
  //
  // 队列 = 运行列表（ordered=true, 拖拽即改执行顺序）
  //      + 未编排的启用任务（ordered=false, 拖上来即加入队列）

  /// 该任务的运行态（待执行 / 等待中 / 冷却中 / 休息中 / 未启用 / 未编排）。
  ///
  /// 数据来自 `/overview` 的 `slot` / `reason` / `in_cooldown` ——
  /// **前端不重新推导调度规则**（那会与后端漂移）。
  ({String label, int tone}) queueStatusOf(String command) {
    for (final t in _allTasks) {
      if ('${t['command']}' != command) continue;
      if (t['in_cooldown'] == true) {
        final m = (t['cooldown_minutes'] as num?)?.toInt() ?? 0;
        return (label: m > 0 ? '冷却中 $m 分' : '冷却中', tone: 3);
      }
      if (t['enable'] != true) return (label: '未启用', tone: 2);
      if (t['slot'] == 'pending') return (label: '待执行', tone: 0);
      final reason = '${t['reason'] ?? ''}';
      return (label: reason.isEmpty ? '等待中' : reason, tone: 1);
    }
    return (label: '未知', tone: 2);
  }

  // ---------------------------------------------------------------- 队列成员
  //
  // ★★ 权威在后端 ★★
  //
  // "谁在队列里"由后端 `build_queue()`（用户编排 + auto_queue 自动补齐）决定,
  // 前端**只看** `/overview` 的 `queued` 字段 —— 不自己推导。
  //
  // 自己推导会与后端漂移（本项目已因"知识存在两处"栽过多次）。

  /// 该任务是否**在队列里**（后端给的 `queued`）。
  bool isQueued(String command) {
    for (final t in _allTasks) {
      if ('${t['command']}' == command) return t['queued'] == true;
    }
    return false;
  }

  /// 该任务是否**自动进队列**（后端给的 `auto_queue`）。
  bool isAutoQueue(String command) {
    for (final t in _allTasks) {
      if ('${t['command']}' == command) return t['auto_queue'] == true;
    }
    return false;
  }

  /// 在队列里的任务（= 可拖拽的那部分，**不含**正在运行）。
  List<Map<String, dynamic>> get queuedTasks =>
      _allTasks.where((t) => t['queued'] == true).toList();

  /// ★★ F6: **有效队列** —— 「执行顺序」列表真正渲染的东西 ★★
  ///
  /// ## 此前的问题（用户报的 bug）
  ///
  /// 可拖列表渲染的是 `entries`（**只有 `run_list`**）—— 而队列里
  /// **大部分任务是自动补齐的**（`auto_queue=true` 启用后由后端
  /// `build_queue()` 追加, **不写入 `run_list`**）。
  ///
  /// 后果: 用户启用了金币妖怪 / 经验妖怪 / 狭间暗域, 后端 `queued` 里**有**,
  /// 但界面上**看不到**。用户原话:
  ///
  /// > "我启用了很多哦定时任务, 但是并没有出现在执行队列中,
  /// >  包括金币妖怪、狭间暗域、经验妖怪等等。"
  ///
  /// ## 语义
  ///
  /// 队列 = `run_list`（用户编排, 保序）**+ 自动补齐**（追加在后）。
  /// 本 getter 返回**统一的展示序列**, 每项带 `_queuedRow` 标记。
  ///
  /// * `_queuedRow == false` -> 来自 `entries`（含「休息」条目）, 可整体重排
  /// 解析 `entry_id` 里的**加入时间**（`20261010T143005-RealmRaid` -> DateTime）。
  ///
  /// ★ C-5: 同一任务在队列里出现**多条**时, 靠它区分（显示 `10-10 14:30`）。
  ///   认不出格式返回 `null`（**不猜**）。
  static DateTime? addedAtOfEntryId(String entryId) {
    if (entryId.isEmpty) return null;
    final head = entryId.split('-').first;
    if (head.length != 15 || head[8] != 'T') return null;
    final y = int.tryParse(head.substring(0, 4));
    final mo = int.tryParse(head.substring(4, 6));
    final d = int.tryParse(head.substring(6, 8));
    final h = int.tryParse(head.substring(9, 11));
    final mi = int.tryParse(head.substring(11, 13));
    final s = int.tryParse(head.substring(13, 15));
    if (y == null || mo == null || d == null || h == null ||
        mi == null || s == null) {
      return null;
    }
    return DateTime(y, mo, d, h, mi, s);
  }

  /// 该任务在**有效队列**里出现了几次（用于判断要不要显示加入时间）。
  int queuedCountOf(String command) {
    var n = 0;
    for (final r in queuedTaskRows) {
      if ('${r['kind']}' == 'task' && '${r['task']}' == command) n++;
    }
    return n;
  }

  /// * `_queuedRow == true`  -> 后端 `queued` 里有、但 `entries` 里没有
  ///   （即自动补齐的）, 首次拖动时才写入 `run_list`
  List<Map<String, dynamic>> get queuedTaskRows {
    final out = <Map<String, dynamic>>[];
    // ① entries（用户编排, 含休息, **含重复条目**）—— 保持原顺序
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      final eid = '${e['entry_id'] ?? ''}';
      out.add({
        ...e,
        // ★★ S6: **段名**（前端算, 与后端 `TaskSpec.priority_group` 同一判据）★★
        //
        // ⚠ `/run_list` 端点**不返回** `group` —— 它是 `build_queue()` 的
        //   **派生**结果（后端 `_segment_queue()` 刻意**不回写**配置）。
        //   所以前端按**同一规则**自己算。
        //
        // ★★★ P-2: `rest` **不再特殊标记**（用户裁定）★★★
        //
        // ## 曾经为什么打 `'__rest__'`
        //
        // 后端当时有硬约束「rest 必须在所有任务之后」。前端为了让**拒绝**
        // 发生在拖动**之前**，给 rest 打了 `'__rest__'`，再由
        // `_sameGroupReorder` 的 `'__rest__' -> rank 2` 分支算单调 rank。
        //
        // ## 现在为什么删掉
        //
        // 用户裁定:
        // > "休息**也是任务**, 只不过可以选择插入定时任务。"
        // > "休息当然就是**挡住后边的**, 本质为了**防封**, **符合预期**。"
        // > "1 **全删**"（`'__rest__'` 特殊标记）
        //
        // ★ 后端 `_tag_and_place_rest()` 的排序与 `place_rest_last()` 都已
        //   **改为直通**（见 OAS 提交 `832f467e`）；且 `_sameGroupReorder`
        //   与 `_check_drag_allowed` **早已删除**（见本文件 L1541 的记载）——
        //   ⇒ 这个标记**不再有任何约束作用**，只剩显示噪音。
        //
        // ⚠ 也不能退回 `priorityGroupOf('')` —— 它有"空任务名 -> fixed"的
        //   兜底，会让 rest 被渲染成**临时任务的类别色条**。
        //   ★ 所以显式给**空段名**：界面据此显示为「休息」（无类别）。
        'group': (('${e['task'] ?? ''}').isEmpty
            ? ''
            : priorityGroupOf('${e['task'] ?? ''}')),
        '_queuedRow': false,
        '_entryIndex': i,
        // ★ C-5: 带上条目身份, 供界面显示"加入时间"以区分同任务多条
        '_entryId': eid,
        '_addedAt': addedAtOfEntryId(eid)?.toIso8601String(),
      });
    }
    // ② 自动补齐的（**该任务一条都没编排过**才补）—— 补齐只补一次
    final seen = <String>{
      for (final e in entries)
        if ('${e['kind']}' == 'task') '${e['task']}'
    };
    for (final t in queuedTasks) {
      final cmd = '${t['command']}';
      if (cmd.isEmpty || seen.contains(cmd)) continue;
      out.add({
        'kind': 'task',
        'task': cmd,
        'group': priorityGroupOf(cmd),
        '_queuedRow': true,
        '_auto': true,
        '_entryId': '',
        '_addedAt': null,
      });
    }
    return out;
  }

  /// ★★ S6 / 审计修复: 任务属于哪个**优先级段** —— `'timed'` / `'fixed'` ★★
  ///
  /// ## ★★ 为什么必须读后端的 `priority_group`（我第一版踩了坑）★★
  ///
  /// 第一版用 `/overview` 的 `category`（**声明**类别）自己推:
  /// ```dart
  /// c == 'timed' || c == 'limited' ? 'timed' : 'fixed'   // ✗ 错
  /// ```
  /// 但后端判段用的是 `category_effective`（⑥: `timed` + `period=none`
  /// -> **`fixed`**）。实测: **54 个任务里 17 个**声明 `timed` 而最终是
  /// `fixed`（DemonEncounter / GoldYoukai / Tako / Duel / …）。
  ///
  /// 后果: **分段条计数、类别色条、拖动范围全错**; 更糟的是"拖动预检"
  /// 与后端 `_check_drag_allowed` 的判定**可能相反** —— 用户把 GoldYoukai
  /// 拖到 RealmRaid 前, 前端认为"timed 在 fixed 前"放行, 后端算出逆序
  /// -> 返回 `drag_blocked`, 用户只看到"不能跨类别拖动"却**看不出原因**。
  ///
  /// ★ 现在**优先读后端给的权威值**（`/overview` 的 `priority_group`,
  ///   53/53 个任务都有）。兜底才自己推 —— 且兜底也**按最终类别**推,
  ///   并配合 `period` 复现 ⑥ 的规则（`timed` + `period=none` -> `fixed`）。
  String priorityGroupOf(String command) {
    if (command.isEmpty) return 'fixed';
    for (final t in queuedTasks) {
      if ('${t['command']}' == command) return _groupOfRow(t);
    }
    // ★ 兜底: `queuedTasks` 里没有（该任务未启用 / 不在队列）就看全量表
    for (final t in _allTasks) {
      if ('${t['command']}' == command) return _groupOfRow(t);
    }
    return 'fixed';
  }

  /// ★★★ 段名的**中文标签**（`'定时'` / `'固定'`）—— 界面显示**只用这一个** ★★★
  ///
  /// ## 为什么需要它（实机验收发现的**口径不一致**）
  ///
  /// 用户原话:
  /// > "执行顺序下边的任务统计数量显示：**定时任务2条，固定任务14条**,
  /// >  但是**任务上的标签**显示的几乎都是紫色的定时, 红色的次数只有四个"
  ///
  /// **根因**: 界面有**三个口径**各读不同字段 ——
  ///
  /// | 界面位置 | 原来读的 | 语义 |
  /// |---|---|---|
  /// | 「执行顺序」下的分段条 | `priority_group` | ★ **有效分段**（权威）|
  /// | 任务表格的「类型」列 | `category_label` | **声明**类别 |
  /// | 队列行色条 / 「定时·次数」标签 | `auto_queue` | 会不会**自动进队列** |
  ///
  /// ★ 实测 `恋鸟树` 的 16 条队列里有 **10 条**声明 `timed` 而有效分段是
  ///   `fixed`（`Delegation`/`DemonEncounter`/`AreaBoss`/`GoldYoukai`/
  ///   `RichMan`/…）—— 于是界面**同时**说它"是定时"又说"按 fixed 排",
  ///   看起来就是**自相矛盾**。
  ///
  /// ★ 修法: 标签一律**从这个方法取**, 它读后端的
  ///   `priority_group_label`（与 `priority_group` 同源, 后端一处定义）。
  ///   前端不再自己拿 `category` / `auto_queue` 现编。
  ///
  /// ★ **拖动不受它影响** —— 拖动永远自由, 这个标签纯粹是**显示**。
  String priorityGroupLabelOf(String command) {
    // ① 后端给的权威标签
    for (final t in queuedTasks) {
      if ('${t['command']}' == command) {
        final l = '${t['priority_group_label'] ?? ''}';
        if (l.isNotEmpty) return l;
      }
    }
    for (final t in _allTasks) {
      if ('${t['command']}' == command) {
        final l = '${t['priority_group_label'] ?? ''}';
        if (l.isNotEmpty) return l;
      }
    }
    // ② 兜底: 由段名推（与后端 `PRIORITY_GROUP_LABEL` 同一套值）
    return priorityGroupOf(command) == 'timed' ? '周期' : '临时';
  }

  /// 该任务**当前是否在开放时段内**（`/overview` 的 `in_window_now`）。
  ///
  /// ★ 与 `slot` / `reason` 的区别: 后者是"调度器把它放哪了"
  ///（含未启用/不在队列等原因）, 这个是纯粹的"**窗口**开没开"。
  ///
  /// ★ 取不到时返回 `true`（保守: 不因为一个缺字段就把行画成"不能跑"）。
  bool inWindowNowOf(String command) {
    for (final t in queuedTasks) {
      if ('${t['command']}' == command) {
        final v = t['in_window_now'] ?? t['in_window'];
        if (v is bool) return v;
      }
    }
    for (final t in _allTasks) {
      if ('${t['command']}' == command) {
        final v = t['in_window_now'] ?? t['in_window'];
        if (v is bool) return v;
      }
    }
    return true;
  }

  /// 从一行任务数据里取段名 —— **先信后端, 再兜底复算**。
  String _groupOfRow(Map<String, dynamic> t) {
    final g = '${t['priority_group'] ?? ''}'.toLowerCase();
    if (g == 'timed' || g == 'fixed') return g;

    // ---- 兜底: 后端没给（旧版本后端）时自己推 ----
    // ★ 必须是**最终类别**: 用 `category_effective`（后端已加）;
    //   再不行才退回 `category`, 并按 ⑥ 的规则叠加 `period`。
    final eff = '${t['category_effective'] ?? ''}'.toLowerCase();
    if (eff == 'timed' || eff == 'limited') return 'timed';
    if (eff == 'fixed' || eff == 'toppa') return 'fixed';

    var c = '${t['category'] ?? ''}'.toLowerCase();
    final p = '${t['period'] ?? ''}'.toLowerCase();
    // ⑥: 声明为定时但周期"不限" -> 算固定
    if (c == 'timed' && p == 'none') c = 'fixed';
    return (c == 'timed' || c == 'limited') ? 'timed' : 'fixed';
  }

  /// ★ **任务完成汇报**（#6, 用户 2026-10-10 新需求）。
  ///
  /// 用户原话:
  ///   "添加一个**任务完成汇报 tab**, 现在的日志属于原始日志, 应该**转移到
  ///    单独界面**用来 debug, 当前日志位置替换为**任务完成汇报**的 tab,
  ///    只会报完成了哪些、**出错任务标注**等等其它可以作为简报的内容"
  ///
  /// 返回后端的报告结构（见 `GET /{script}/report`）:
  /// `{config, at, summary:{...}, tasks:[...], errors:[...]}`。
  ///
  /// ★ 走后端聚合（`run_record` + `task_state` + `failure_state`）,
  ///   前端**不自己推导**（避免"同一知识存在两处"）。
  Future<Map<String, dynamic>> fetchTaskReport() async {
    try {
      final res = await _api.getTaskReport(scriptName);
      _report = res;
      _reportError = res['error'] == null ? null : '${res['error']}';
    } catch (e) {
      _reportError = '$e';
    }
    update();
    return _report;
  }

  /// 最近一次汇报（未拉取过则为空）。
  Map<String, dynamic> get taskReport => _report;

  /// 拉取汇报时若出错, 这里给出可读原因（不静默失败）。
  String? get taskReportError => _reportError;

  Map<String, dynamic> _report = const {};
  String? _reportError;

  /// 汇报的简报行（`tasks`）。
  List<Map<String, dynamic>> get reportTasks {
    final v = _report['tasks'];
    if (v is List) {
      return v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    }
    return const [];
  }

  /// 汇报的**出错清单**（`errors`）—— 用户要求"出错任务标注"。
  List<Map<String, dynamic>> get reportErrors {
    final v = _report['errors'];
    if (v is List) {
      return v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    }
    return const [];
  }

  /// 汇报的汇总（`summary`）。
  Map<String, dynamic> get reportSummary {
    final v = _report['summary'];
    if (v is Map) return v.cast<String, dynamic>();
    return const {};
  }

  /// ★★ F6: 统一重排 ★★ —— 拖的是**有效队列**的展示位置。
  ///
  /// 把 `entries` 重排成"新的有效队列顺序里, 属于 `entries` 的那些"。
  ///
  /// 自动补齐的任务**不写进 `run_list`**（它们本来就靠补齐, 写进去反而
  /// 会把"用户编排"和"自动补齐"两件事混起来）—— 但**位置会被记住**:
  /// 因为 `entries` 的顺序变了, 补齐全在 `entries` 末尾, 所以相对位置
  /// 自然跟着变。
  ///
  /// ⚠ 只用**任务条目**计算 —— 「休息」条目也参与重排（用户可能想让
  ///   "跑完 A 休息 10 分钟再跑 B"）。
  void reorderQueue(int oldIndex, int newIndex) {
    final rows = queuedTaskRows;
    if (oldIndex < 0 || oldIndex >= rows.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    if (newIndex < 0) newIndex = 0;

    // ★★ 实机验收修复: **先深拷贝, 再改** —— 不要变异派生表 ★★
    //
    // ## 原来的写法（`rows.removeAt` / `rows.insert`）
    //
    // `queuedTaskRows` 是**派生 getter**: 每次调用都 `entries` + 自动补齐
    // **重建整表新 map**（见 `queuedTaskRows` 的实现）。原来的代码直接
    // `removeAt` / `insert` 改那张派生表, 再把里面的 map **原样存回
    // `entries`** —— 于是 `entries` 里存的是"派生 map"（带着
    // `group` / `_queuedRow` / `_entryIndex` / `_addedAt` 等派生字段）。
    //
    // ★ 隐患: 派生表与 `entries` 之间**没有清晰边界**; 只要下一次
    //   `queuedTaskRows` 的重建逻辑有一点偏差（例如某行被 `where` 滤掉、
    //   或 `_entryIndex` 变了）, **下一次 build 就会用新派生表覆盖**,
    //   视觉上就是"**松手后弹回原位**"。
    //
    // ★ 修法: 拷贝成**全新 map**（只含真正的条目字段）+ 重排 +
    //   **只从副本重建 `entries`**。这样操作的**只可能是自己的一次性副本**,
    //   不可能被下次派生覆盖。
    final working = rows
        .map((r) => Map<String, dynamic>.from(r))
        .toList(growable: true);
    final item = working.removeAt(oldIndex);
    working.insert(newIndex.clamp(0, working.length), item);

    // 按新顺序重建 entries（只保留原本属于 entries 的项, 保持它们的新相对次序）
    //
    // ★★ 必须**保留 `entry_id`** ★★
    //
    // 原来这里只写 `kind` / `task` / `minutes` —— **把 `entry_id` 抹掉了**。
    // 于是**每拖一次**后端就重新生成 id -> 按条目追踪（C）的完成状态
    // **全部失效**（同名多条还会互相覆盖）。实测抓到的严重 bug。
    // 按新顺序重建 `entries`。
    //
    // ★★★ 实机验收修复: **自动补齐的行也要写进去** ★★★
    //
    // ## 症状（用户原话）
    //
    // > "**现在只能拖动固定任务**。"
    //
    // ## 根因（实证）
    //
    // 用户的 `run_list` 只有 **4 条**, 而且**全是 FIXED**:
    //     GoryouRealm / Sougenbi / Exploration / BondlingFairyland
    // 队列里其它的（全部 TIMED）都是后端 `build_queue()` **自动补齐**的
    // -> 它们的 `_queuedRow == true`。
    //
    // 而这里原来是:
    // ```dart
    // final entryRows = working
    //     .where((r) => r['_queuedRow'] != true)   // ★ 把自动补齐的**丢掉**
    //     ...
    // ```
    // -> 自动补齐的行**永远不写进 `run_list`** -> `_saveEntries()` 之后
    //    `reload()` / 下次派生**又回到原位** -> **拖了必弹回**。
    // ★ 用户体感就是"**只有固定任务能拖**"（因为只有它们在 `run_list` 里）。
    //
    // ## 而且注释早就写明了正确行为
    //
    // `queuedTaskRows` 的注释（本文件 `:1012-1013`）说:
    // > `_queuedRow == true` -> 后端 `queued` 里有、但 `entries` 里没有
    // > （即自动补齐的）,**首次拖动时才写入 `run_list`**
    //
    // ★ **注释与实现不符** —— 注释说要写, 实现里 `where` 掉了。
    //
    // ## 修法: 全部写进去（对齐注释）
    //
    // ★ 为什么这样也对（回答早先那条"不该把自动补齐写进 `run_list`"的顾虑）:
    //
    // 那条顾虑是"**自动补齐是派生结果, 回写会分不清'用户没编排过'
    //   与'用户确实想要它在列表里'**"。这个顾虑对**没有被用户碰过**的
    // 自动任务成立 —— 所以 `build_queue()` **平时**不写盘。
    // ★ 但**用户拖动**就是"**他确实想要这个次序**"的**明确表态** ——
    //   此时写进 `run_list` 不是"系统擅自回写", 而是"**记录用户的编排**"。
    // ★ 不写 = 用户的拖动**必然丢失**, 那才是真 bug。
    //
    // ⚠ 自动补齐的行**没有 `entry_id`**（`_entryId: ''`）-> 这里不写它,
    //   让后端生成一个新的（`RunEntry` 会补）。
    final rebuilt = working
        .map((r) => {
              'kind': '${r['kind']}',
              if ('${r['kind']}' == 'task') 'task': '${r['task']}',
              // ★ 保留条目身份（为空则不写, 让后端生成）
              if (('${r['entry_id'] ?? ''}').isNotEmpty)
                'entry_id': '${r['entry_id']}',
              // ★ 保留**段名**（后端据此校验"休息不能排中间"）
              if (('${r['group'] ?? ''}').isNotEmpty) 'group': '${r['group']}',
              if ('${r['kind']}' != 'task') 'minutes': r['minutes'],
            })
        .toList();

    // ★★★ P-2: 「休息」**不再垫底** —— 它就是临时任务（用户裁定）★★★
    //
    // ## 用户的定义（第三次提出, 以此为准）
    //
    // > **休息就是临时任务**（回庭院待着），只不过**可以选择被定时任务插队**。
    //
    // ⇒ 休息与其它**临时任务同一套规则**：没有"恒排最后"、没有特殊段名、
    //   没有特殊 rank、**可自由拖动**。
    //   唯一特殊性 = **可被定时任务插队**（`rest_interleave`, 一个**可选能力**）。
    //
    // ## 这里原来是什么（★ 就是"松手弹回"的根因）
    //
    // ```dart
    // final tasks = rebuilt.where((e) => '${e['kind']}' == 'task').toList();
    // final rests = rebuilt.where((e) => '${e['kind']}' != 'task').toList();
    // entries..clear()..addAll(tasks)..addAll(rests);   // ★ 任务在前、休息垫底
    // ```
    //
    // ★ 注释当时写"用户确认: 任意拖，但「休息」条目仍强制排最后" ——
    //   **那句话不是用户的裁定**，是误记的临时约束。
    //   于是**无论用户把休息拖到哪，保存时都被挪到末尾** —— 用户实测
    //   "能拖，但松手弹回最后"。
    //
    // ★ 后端 `Config.place_rest_last()` 也曾有同样的归一化，现已改为**直通**
    //   （OAS `832f467e`）。★ 实测后端 `PUT /run_list` 已能正确保存
    //   休息的**任意位置**（含中间）。
    //
    // ⚠ 所以现在**两边都不再挪位**，用户拖到哪就存到哪。
    entries
      ..clear()
      ..addAll(rebuilt);
    update();
    _saveEntries();
  }

  // ★★★ S7: `dragRejection()` / `_sameGroupReorder()` / `_lastDragReason`
  // **已删除**（用户裁定）★★★
  //
  // 用户原话:
  // > "固定任务优先和定时任务优先以及**不能跨类别拖动太蠢了**。
  // >  我只需要保持**可以自由拖动/改变执行顺序**就行。"
  //
  // ★ 它们实现的是"非自定义模式下不能跨类别拖动"那条约束 ——
  //   现在**拖动永远自由**, 后端也不再校验（`_check_drag_allowed` 已删）。
  //
  // ⚠ 连带删掉了 `test/drag_constraint_behavior_test.dart` 的 18 条
  //   `dragRejection` 行为测试 —— 它们钉的是一个**已废除的规则**。
  //   ★ 替代它们的是新的「快捷排序」测试（见 `test/queue_sort_test.dart`）。

  /// **第 3 类**: 已启用 / 次数任务 / 还没进队列。
  ///
  /// = `enable && !auto_queue && !queued`（与后端候选端点同一规则）
  ///
  /// ★ 这些**只出现在【添加任务】里**, 不堆在队列下面。
  ///   用户原话: "启用的任务但不会执行的任务应该出现在添加任务里,
  ///             而不是堆在未编排里"。
  List<Map<String, dynamic>> get enabledNotQueuedTasks => _allTasks
      .where((t) =>
          t['enable'] == true &&
          t['auto_queue'] != true &&
          t['queued'] != true)
      .toList();

  // ★★ T10（审计修复）: `overviewRowOf()` **已删除** ★★
  //
  // 它在 `_allTasks` 里线性查一行 —— **只读**、**无调用方**（引用数 = 1）。
  // ★ `taskRowOf()` 是同一个用途的**在用**版本（`queue_panel` 等在用）。

  /// 【添加任务】的候选 —— **走后端端点**（不在前端重新实现过滤规则）。
  ///
  /// 后端规则: `enable && !auto_queue && !queued`（见
  /// `module/server/schema_router.py` 的 `get_queue_candidates`）。
  /// 前端重复实现会漂移, 所以只调接口。
  Future<List<Map<String, dynamic>>> fetchAddCandidates() async {
    final res = await _api.getQueueCandidates(scriptName);
    final list = (res['candidates'] as List?) ?? const [];
    return list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  /// **移出队列**。
  ///
  /// ★ 行为分两类（用户 2026-10-10 修正）:
  ///   * 定时任务（uto_queue=true）-> 出队列 **且停用**（否则会被自动补齐）
  ///   * 固定/次数任务（uto_queue=false）-> **只出队列**, 保持启用,
  ///     回到【添加任务】池子
  ///
  /// 返回值是后端给的中文提示（message），直接拿去展示。
  ///
  /// :return: 后端给的中文提示（失败时返回错误文本）
  /// **一键清空执行队列**（⑦）—— 返回后端的中文提示。
  Future<String> clearQueue() async {
    final res = await _api.clearQueue(scriptName);
    if (res['ok'] == true) {
      await reload();
      return '${res['message'] ?? '已清空队列'}';
    }
    return '清空失败: ${res['error'] ?? '未知错误'}';
  }

  /// ★★★ **取消正在运行的任务**（语义 (a): 暂停 + 移出队列）★★★
  ///
  /// 用户裁定:
  /// > "当前正在运行的**任务无法被取消**"
  /// > 取消 = **(a)**「暂停 + 移出队列」= 跑完当前这场战斗后停止且不再入队
  ///
  /// :return 给用户看的**中文提示**（界面直接上屏, 不再加工）
  Future<String> cancelRunning() async {
    final res = await _api.cancelRunning(scriptName);
    if (res['ok'] == true) {
      await reload();
      return '${res['message'] ?? '已取消'}';
    }
    return '取消失败: ${res['error'] ?? '未知错误'}';
  }

  /// 移出队列。
  ///
  /// ★ [entryId]: **精确移除某一条**（⑨）。同名条目必须带它, 否则
  ///   后端会删掉该任务的**所有**条目（"两条个人突破删一条 -> 两条都没了"）。
  Future<String> removeFromQueue(String command, {String? entryId}) async {
    final res =
        await _api.removeFromQueue(scriptName, command, entryId: entryId);
    if (res['ok'] == true) {
      await reload();
      return '${res['message'] ?? '已移出队列'}';
    }
    return '移出失败: ${res['error'] ?? '未知错误'}';
  }

  /// 不在运行列表里的**启用**任务（可作为"未编排"候选）。
  ///
  /// ## ★ 必须排除**正在运行**的那个（修一个真 bug）
  ///
  /// 用户反馈: "正在运行的逢魔之时，下边显示还可以加入逢魔之时，这是不是个bug"
  ///
  /// **是 bug。** 原因: 若 `run_list` 是空的（还没编排过）, 那么**所有**启用任务
  /// 都会落进这里 —— 包括**此刻正在跑**的那个。于是"正在运行"和
  /// "未编排（可加入）"里出现同一个任务, 看起来像调度器把它忘了。
  ///
  /// 实际上它只是**不在编排列表里**（默认顺序调度）, 这跟
  /// "可以加入队列" 是两件事。排除掉正在跑的, 队列就不会重复显示。
  List<Map<String, dynamic>> get unqueuedEnabledTasks {
    final inList = {
      for (final e in entries)
        if ('${e['kind']}' == 'task') '${e['task']}',
    };
    final running = runningTaskCommand;
    return _allTasks
        .where((t) =>
            t['enable'] == true &&
            !inList.contains('${t['command']}') &&
            '${t['command']}' != running)
        .toList();
  }

  /// **正在运行**的任务命令名（从 WebSocket 的 `ScriptModel` 取; 没有则空串）。
  ///
  /// ★ 安全查找: 服务未注册（widget 测试 / 启动瞬间）时返回空串,
  ///   不能让队列整块渲染失败。
  String get runningTaskCommand {
    try {
      if (!Get.isRegistered<ScriptService>()) return '';
      final sm = Get.find<ScriptService>().scriptModelMap[scriptName];
      final cur = sm?.runningTask.value;
      return (cur == null) ? '' : cur.taskName;
    } catch (_) {
      return '';
    }
  }

  /// 命令名 -> `/overview` 那一行（拿不到给空 map）。
  Map<String, dynamic> taskRowOf(String command) {
    for (final t in _allTasks) {
      if ('${t['command']}' == command) return t;
    }
    return const {};
  }

  /// 把任务**加入**队列末尾。
  ///
  /// ★★ ⑧ 修复: **允许重复添加同一任务** ★★
  ///
  /// 用户裁定: "现在的任务执行里**添加任务应该设置为可以重复添加相同的任务**,
  /// 这样就**变相实现了多次跑任务**"。
  ///
  /// 我此前有一行 `if (_entryIndex(command) >= 0) return;` —— **静默拒绝**,
  /// 用户点了没反应（实测到的 ⑧ 根因）。**已删除**。
  ///
  /// 后端会给每条生成**唯一** `entry_id`（同秒加两次 -> 追加序号）,
  /// 并按条目分别追踪完成状态（所以两条都会各跑一次）。
  Future<void> appendToQueue(String command) async {
    await addEntry({'kind': 'task', 'task': command});
  }

  /// 添加条目。`index = -1` 追加到末尾。
  ///
  /// ★ 模型 B 的关键能力: 控制条目可插到**任意位置**。
  Future<void> addEntry(Map<String, dynamic> entry, {int index = -1}) async {
    final res = await _api.addRunListEntry(scriptName, entry, index: index);
    if (res.containsKey('error')) {
      Get.snackbar('添加失败', '${res['error']}', snackPosition: SnackPosition.BOTTOM);
      return;
    }
    await reload();
  }

  /// 删除条目。
  Future<void> removeEntry(int index) async {
    final res = await _api.removeRunListEntry(scriptName, index);
    if (res.containsKey('error')) {
      Get.snackbar('删除失败', '${res['error']}', snackPosition: SnackPosition.BOTTOM);
      return;
    }
    await reload();
  }

  /// 保存运行列表到后端（**公开** —— 执行队列面板也需要它）。
  ///
  /// 为什么不直接暴露 `_saveEntries`: 队列面板在另一个 part 文件里,
  /// 虽然同属一个库（能调私有成员）, 但**公开名字更清楚地表达"这是对外契约"**。
  Future<void> saveEntriesNow() => _saveEntries();

  /// 保存运行列表到后端；**失败一定上屏 + 回滚**。
  ///
  /// ## ★★ 实机验收修复: 原来的判失败方式**漏掉了网络失败** ★★
  ///
  /// 原来写:
  /// ```dart
  /// final res = await _api.putRunList(scriptName, entries);
  /// if (res.containsKey('error')) { ... }
  /// ```
  /// 而 `putRunList` 是:
  /// ```dart
  /// final res = await request(...);
  /// return res.data ?? {};        // ★ 网络失败 -> `{}`
  /// ```
  /// -> **网络失败返回 `{}`** -> `containsKey('error')` 为 **false**
  ///    -> 被当成**成功** -> **不提示、不回滚** -> **静默丢弃用户的拖动**。
  ///
  /// ★ 这与本项目一贯纪律"**让静默失败变成看得见**"直接冲突,
  ///   而且它**正是"拖动弹回但没有任何提示"的一种成因**。
  ///
  /// ## ★★★ 第二次修: 成功判据原来会把**后端拒绝**当成成功 ★★★
  ///
  /// 我上一版写:
  /// ```dart
  /// final ok = res.containsKey('entries') || res.containsKey('count');
  /// ```
  /// 而**后端拒绝拖动时**返回的是（`schema_router.py` 的 `_check_drag_allowed`
  /// 分支）:
  /// ```python
  /// return {'error': reason, 'drag_blocked': True,
  ///         'entries': rl.to_list()}     # ★★ 带着 `entries`！
  /// ```
  /// -> **`ok` 为 `true`** -> 被当成"**保存成功**" ->
  ///    **不提示、不回滚** -> 而磁盘**根本没存** ->
  ///    下次 `reload()` 又拉回旧顺序。
  ///
  /// ★ 用户体感（实机原话）:
  /// > "**现在三种调度优先级，都变成随便拖了**"
  ///
  /// ★ 也就是: **后端一直在拒绝, 但前端一声不吭**。这与本项目纪律
  ///   "让静默失败变成看得见"**直接冲突** —— 而且是**我**引入的
  ///   （我上一版为了修"网络失败被当成功", 把判据改成"含 entries 就算成功",
  ///    却**没查后端失败时返回什么形状**）。
  ///
  /// ## 正确判据（**先看否定信号, 再看肯定信号**）
  ///
  /// 1. `error` 非空      -> **失败**（后端给了可读原因）
  /// 2. `drag_blocked` 真 -> **失败**（拖动被约束拒绝）
  /// 3. 否则要 `entries`/`count` 才算成功（防网络失败返回 `{}`）
  Future<void> _saveEntries() async {
    Map<String, dynamic> res;
    try {
      res = await _api.putRunList(scriptName, entries);
    } catch (exc) {
      // `request()` 自己会吞异常返回 ApiResult, 但保险起见兜一层
      //
      // ⚠⚠ **`GetxController` 没有 `mounted`**（那是 `State` 的）——
      //   我第一版写了 `if (mounted)`; `flutter analyze` **没报**,
      //   而 `flutter test` 的编译器直接报
      //   `The getter 'mounted' isn't defined for the class
      //    'TaskListController'`。
      //   ★ 教训: **analyze 干净 != 能编译**（analyze 只做静态检查,
      //     不解析全部泛型/继承链）。
      _snack('保存失败', '请求异常：$exc');
      await reload();
      return;
    }

    // ★ ① 后端给了错误 -> 失败（**这条必须在"含 entries"之前判**）
    final err = '${res['error'] ?? ''}';
    // ★ ② 拖动被约束拒绝 -> 失败
    final blocked = res['drag_blocked'] == true;
    // ★ ③ 都没有否定信号时, 才要求肯定信号（防网络失败 `{}`）
    final acked = res.containsKey('entries') || res.containsKey('count');

    if (err.isNotEmpty || blocked || !acked) {
      final why = err.isNotEmpty
          ? err
          : (blocked
              ? '队列顺序不符合当前调度优先级 —— 该拖动未被接受。'
              : '后端没有确认保存（返回 '
                  '${res.isEmpty ? "空" : res.keys.toList()}）'
                  '—— 可能是网络断了或后端没在跑。');
      _snack(blocked ? '不能跨类别拖动' : '保存失败', why);
      // 保存失败 -> 回滚到服务端状态, 免得界面显示的和实际不一致
      await reload();
    }
  }

  /// 统一的上屏提示。
  ///
  /// ⚠ **不要**在 `GetxController` 里写 `if (mounted)` —— 它没有那个 getter。
  ///   测试环境里没有 `GetMaterialApp`, `Get.snackbar` 会抛 -> 兜住即可。
  void _snack(String title, String message) {
    try {
      Get.snackbar(title, message,
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 5));
    } catch (_) {
      // 测试环境没有 GetMaterialApp -> 忽略（不要让提示失败变成新 bug）
    }
  }

  /// ★★ T10（审计修复）: `resetToDefault()` **已删除** ★★
  ///
  /// ## 为什么删（它是**危险**的死代码）
  ///
  /// ```dart
  /// Future<void> resetToDefault() async {
  ///   final ok = await _confirm('恢复默认顺序', '将清空运行列表, ...');
  ///   if (!ok) return;
  ///   entries = [];            // ★★ 清空用户的编排
  ///   update();
  ///   await _saveEntries();
  ///   await reload();
  /// }
  /// ```
  ///
  /// * **它会清空 `run_list`** —— 也就是用户**一行行拖出来的执行顺序**
  /// * 而 `lib/` 内**没有任何调用方**（实测引用数 = 1, 就是它自己的定义）
  ///
  /// ★ 一个"没人用、但一旦误接线就**毁掉用户编排**"的方法, 留在代码里
  ///   只有风险没有收益。**删掉。**
  /// ★ 真要"回默认顺序", 用户可以在队列里拖 —— 或者用「清空队列」
  ///   （`clearQueue()`, 那个有明确入口与二次确认）。

  // ---------------------------------------------------------------- 全局设置
  /// 队列跑空之后的行为。
  ///
  /// 字段名与取值都走既有通用配置接口, **不新开端点**。
  Future<void> setWhenQueueEmpty(String v) async {
    whenQueueEmpty = v;
    update();
    await _api.putScriptArg(scriptName, 'script', 'optimization',
        'when_task_queue_empty', 'string', v);
  }

  /// 切调度模式。
  ///
  /// ★ 顺序要生效, 必须选「列表优先」(`/schema` 的 `list.mode_value`)。
  ///   但我们**不替用户切** —— 那会悄悄改变他的调度策略; 界面给提示。
  // ★★ 第二轮复审（待办 #5）: `setScheduleRule()` **已删除** ★★
  //
  // ★★ 它是这一簇里**最危险**的一个: `lib/` 内 **0 调用方**, 但
  //   **会 `putScriptArg('schedule_rule', ...)` 写配置**。
  //
  // 也就是说: 只要有人重新接上它, 就会把 `schedule_rule` 写回去 ——
  // 而那个字段 **T1 之后完全不影响排序**, 于是用户会以为
  // "我设了列表优先, 为什么顺序还是不对"。
  //
  // ★ 现行做法: `setPriorityMode(v)` -> `PUT .../priority_mode/value`
  //   （并且后端会**同时**置 `priority_mode_explicit`, 防止迁移覆盖）。

  // ---------------------------------------------------------------- 全局开关
  //
  // ★★ 这一段是补一个**重大遗漏** ★★
  //
  // 后端把两个总开关 + 定时优先 + 休息穿插全做完了, `/schema` 的
  // `global_fields` 也暴露了 —— 但前端**一个都没渲染**。
  // 后果: 它们永远停在默认值, 用户在界面上根本改不了。
  //
  // 所以下面**不硬编码字段名与可选值**: 一律从 `schemaGlobalFields` 拿
  // （标签 / 类型 / 当前值 / 可选值 / 说明）。后端加字段前端自动跟上。

  /// 读一个全局字段的定义（来自 `/schema`）。
  Map<String, dynamic> globalField(String key) {
    final v = schemaGlobalFields[key];
    return v is Map ? v.cast<String, dynamic>() : const {};
  }

  /// 该全局字段的界面标签（后端给中文, 前端不维护映射）。
  String globalFieldLabel(String key, String fallback) =>
      '${globalField(key)['label'] ?? fallback}';

  /// 该全局字段的当前值。
  dynamic globalFieldValue(String key, dynamic fallback) {
    final f = globalField(key);
    return f.containsKey('current') ? f['current'] : fallback;
  }

  /// 布尔型全局开关的当前值。
  bool globalSwitch(String key, {bool fallback = false}) {
    final v = globalFieldValue(key, fallback);
    return v == true;
  }

  /// 写一个全局字段（走既有的通用接口 `/script/optimization/<field>/value`）。
  Future<void> setGlobalField(String key, String type, dynamic value) async {
    final f = globalField(key);
    final field = '${f['field'] ?? key}';
    // 乐观更新: 先改界面, 再发请求（失败时 reload 会把真实值拉回来）
    await _api.putScriptArg(scriptName, 'script', 'optimization',
        field, type, value);
  }

  // ---- 两个总开关 ----

  /// **启用固定任务** 总开关。
  bool get enableFixed => globalSwitch('enable_fixed', fallback: true);
  Future<void> toggleEnableFixed() async {
    final next = !enableFixed;
    await setGlobalField('enable_fixed', 'boolean', next);
    await reload();
  }

  /// **启用定时任务** 总开关。
  bool get enableTimed => globalSwitch('enable_timed', fallback: true);
  Future<void> toggleEnableTimed() async {
    final next = !enableTimed;
    await setGlobalField('enable_timed', 'boolean', next);
    await reload();
  }

  // ---- 两者关系 ----

  // ---- ★★★ S7: 「调度优先级三模式」已删除, 改成两个排序按钮 ★★★ ----
  //
  // ## 用户原话
  //
  // > "我觉得……这个**固定任务优先和定时任务优先以及不能跨类别拖动
  // >  太蠢了**。我只需要保持**可以自由拖动/改变执行顺序**就行,
  // >  固定任务优先和定时任务优先**直接作为一个快捷排序**就好,
  // >  而不是定义一些没有意义的不能跨类别拖动以及**单独的调度优先级**。"
  //
  // ## 删掉了什么
  //
  // `priorityMode` / `priorityModeChoices` / `priorityModeLabel`
  // / `dragWithinGroupOnly` / `setPriorityMode` —— 它们读的是
  // `/schema` 的 `global_fields.priority_mode`, 而那个字段**后端已删除**。
  //
  // ## 现在的模型
  //
  // * **执行顺序 = `run_list` 的顺序本身**（唯一权威）
  // * ★ **拖动永远自由** —— 没有任何模式或约束能拦（后端也不再校验）
  // * 排序是**一个动作**: `sortQueueBy('timed')` / `sortQueueBy('fixed')`
  //   -> `PUT /{script}/queue/sort` -> 后端重排 `run_list` 并写盘
  //   -> ★ **不留状态**: 排完之后用户可以随意再拖
  //
  // ⚠ 唯一固定的是「休息」条目（后端 `Config.place_rest_last()` 兜底挪到最后）。

  /// 排序请求进行中（禁用两个按钮, 防连点）。
  bool sortingQueue = false;

  /// ★★★ 片 5 (F2f): 「快捷排序」是**一个按钮**，点一下换一种排法 ★★★
  ///
  /// ## ★★ 用户裁定（原话）★★
  ///
  /// > "快捷排序**合并为一个快捷排序按钮**，点一下周期排前面，
  /// >  再点一下临时排前面，**不需要占三个按钮位置**。"
  /// > "**按钮文字不变，始终为快捷排序**。"
  ///
  /// ★ 这是**纯界面状态**（不持久化）—— 它只决定"下一次点击排哪一种"。
  ///   默认 `'timed'`（与旧界面的第一个按钮一致）。
  String nextSortTarget = 'timed';

  /// ★ 点一下「快捷排序」：按 `nextSortTarget` 排一次，然后**切换**下一次的目标。
  Future<void> sortQueueNext() async {
    final by = nextSortTarget;
    // ★ 先切换（用户连点两次就是两种排法交替），再执行
    nextSortTarget = (by == 'timed') ? 'fixed' : 'timed';
    update();
    await sortQueueBy(by);
  }

  /// ★ **一次性排序执行顺序** —— `by` ∈ `'timed'` / `'fixed'`。
  ///
  /// ★ 与旧的「切换调度优先级模式」的**本质区别**: 这**不留状态**。
  ///   旧实现设一个 `priority_mode` 之后, 每次 `build_queue()` 都按它排,
  ///   而且**限制拖动范围**; 现在只是"排这一次"。
  Future<void> sortQueueBy(String by) async {
    if (sortingQueue) return;
    sortingQueue = true;
    update();
    try {
      final res = await _api.sortQueue(scriptName, by);
      final err = '${res['error'] ?? ''}';
      if (err.isNotEmpty) {
        _snack('排序失败', err);
        return;
      }
      // ★ 后端会带回**重排后的** `entries` —— 直接用它, 免得界面闪一下旧顺序
      final ents = res['entries'];
      if (ents is List) {
        entries = ents
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      }
    } catch (exc) {
      _snack('排序失败', '请求异常：$exc');
      return;
    } finally {
      sortingQueue = false;
    }
    // ★ 拉一次服务端真值（也把 `sortingQueue` 的新值刷进界面）
    await reload();
  }

  /// ★★ T10（审计修复）: `timedPriority` / `timedPriorityChoices` /
  /// `setTimedPriority` **三件套已删除** ★★
  ///
  /// 它们读的是**已废弃**的 `global_fields.timed_priority` ——
  /// 而后端 `_global_fields()` **已不再返回**该键（S6 并入 `priority_mode`）。
  /// 于是:
  ///   * `timedPriorityChoices` 永远拿到**空列表**
  ///   * `timedPriority` 永远回退到默认 `'timed'`
  ///   * `setTimedPriority` 会去写一个**界面上不存在的字段**
  ///
  /// ★ 实测: `lib/` 内它们**各只有 1 处引用 = 自己的定义** -> 真正无人调。
  /// ★ 取代它们的是上面那组 `priorityMode` / `priorityModeChoices`
  ///   / `priorityModeLabel` / `dragWithinGroupOnly` / `setPriorityMode`。
  ///
  /// ⚠ 删它们**必须先改测试**: `test/task_list_panel_test.dart` 里有一条
  ///   `expect(ctrl.contains('timedPriorityChoices'), isTrue)` —— **给死代码
  ///   上了锁**（清理时它会失败, 于是没人敢删）。已改成断言
  ///   `priorityModeChoices` + **反向守卫**。

  /// **休息时可穿插定时任务**。
  bool get restInterleave =>
      globalSwitch('rest_interleave', fallback: false);
  Future<void> toggleRestInterleave() async {
    final next = !restInterleave;
    await setGlobalField('rest_interleave', 'boolean', next);
    await reload();
  }

  // ---------------------------------------------------------------- 每任务字段
  //
  // 这些走**各任务自己的** `scheduler` 分组（不是 `script.optimization`）,
  // 路径是 `/{script}/{task}/scheduler/{field}/value`。
  //
  // ★ `target` 的写入口是上面那个**已存在**的 `setTarget()`
  //   （`/value` 的 `types` 参数后端并不使用, 所以统一写 `'integer'`）。

  /// **优先级** —— 定时任务内部排序的最终裁判（数字小的先跑）。
  ///
  /// 见 `docs/architecture.md` §5.4.1 的五级排序:
  /// 能否跑 > 到点程度 > 窗口快关 > 耗时短 > **用户自定义优先级**。
  Future<bool> setTaskPriority(String taskName, int priority) =>
      _api.putScriptArg(
          scriptName, taskName, 'scheduler', 'priority', 'integer', priority);

  /// **预期完成时间**（分钟）—— "休息时可穿插"的判据输入。
  ///
  /// 判据: `预期完成时间 < 休息剩余时间` -> 允许穿插。
  /// `0` = 未知 -> 不参与判定（保守, 宁可不穿插）。
  Future<bool> setTaskExpectedMinutes(String taskName, int minutes) =>
      _api.putScriptArg(scriptName, taskName, 'scheduler',
          'expected_minutes', 'integer', minutes);

  /// **清除失败记录 + 解除冷却**。
  ///
  /// 用途: 用户修好了问题（改配置 / 换素材）之后**不想等 1 小时**,
  /// 点一下就能立刻重试。见 `module/config/failure_state.py`。
  ///
  /// ## ★★ 审计修复: 键**归一化**（双保险）★★
  ///
  /// 后端 `failure_state` 的键是**小写、去下划线**（`_norm()`）——
  /// 实测 `log/.failure_state.json` 的键是 `demonencounter`。
  /// 调用方若传了 `demon_encounter`（下划线形式）或 `DemonEncounter`
  /// （大驼峰形式）, 后端 `pop` 会**静默不命中**。
  ///
  /// ★ 这里统一成后端口径; 与 `recordOf()` 用**同一个** `_normKey`。
  Future<void> clearFailure(String taskKey) async {
    await _api.clearFailureState(scriptName, task: _normKey(taskKey));
    await reload();
  }

  Future<bool> _confirm(String title, String content) async {
    final r = await Get.dialog<bool>(
      AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
              onPressed: () => Get.back(result: false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Get.back(result: true),
              child: const Text('确定')),
        ],
      ),
    );
    return r == true;
  }

  String get script => scriptName;
}
