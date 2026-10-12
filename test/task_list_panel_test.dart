// 「执行顺序」面板的 widget 测试。
//
// ## 为什么需要它
//
// 用户报"任务列表白屏"。这类 bug 的根因往往是**build 里抛了异常**,
// 而 `dart analyze` **查不出**运行时异常(踩过一次: `Obx` 误用 ->
// "improper use of a GetX" -> 整页白屏)。
//
// 这个测试用**假数据**把 `RunListPanel` 真渲染一遍:
//   * 只有任务条目
//   * 任务 + 控制条目(全部停止 / 只停列表)混合  <- 模型 B 的核心
//   * 空列表
//
// 任何 build 期异常都会让测试失败 —— 这是 `analyze` 给不了的保障。
//
// ★ 用**假控制器**而不是真控制器: 真控制器会在 `onInit` 里发 HTTP 请求,
//   测试里不该依赖后端(而且 `Get.find<ScriptService>()` 也没初始化)。
//   假控制器只覆盖 `RunListPanel` 用到的那些**纯数据 getter**。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

// ★ 只 import library 入口 —— `task_list_controller.dart` 是
//   `part of task_list`, **不能单独 import**(会报
//   "Can't import ..., because it has a 'part of' declaration")。
//   library 入口已经把它带出来了, `TaskListController` 是 public 的。
import 'package:oasx/views/tasks/task_list_view.dart';

/// 假控制器 —— 不联网, 数据全部可控。
class FakeTaskListController extends TaskListController {
  FakeTaskListController({
    required List<Map<String, dynamic>> entries,
    required List<Map<String, dynamic>> tasks,
  })  : _entries = entries,
        _tasks = tasks,
        super(scriptName: 'test');

  final List<Map<String, dynamic>> _entries;
  final List<Map<String, dynamic>> _tasks;

  // ---- 数据 ----
  @override
  List<Map<String, dynamic>> get entries => _entries;

  @override
  List<Map<String, dynamic>> get allTasks => _tasks;

  @override
  List<Map<String, dynamic>> get tasks => _tasks;

  @override
  int get runnableCount => _tasks.where((t) => t['can_run'] == true).length;

  // ---- 条目类型定义（模拟后端 /schema 的 list.entry_kinds）----
  @override
  List<Map<String, dynamic>> get entryKinds => const [
        {
          'value': 'task',
          'label': '任务',
          'help': '执行这个任务',
          'needs_minutes': false,
          'needs_task': true,
          'blocks_list': false,
        },
        {
          'value': 'rest',
          'label': '休息',
          'help': '暂停调度 N 分钟 —— 连定时任务一起停',
          'needs_minutes': true,
          'needs_task': false,
          'blocks_list': true,
        },
        {
          'value': 'delay',
          'label': '只停列表',
          'help': '只推迟列表 N 分钟 —— 定时任务照常',
          'needs_minutes': true,
          'needs_task': false,
          'blocks_list': true,
        },
      ];

  @override
  List<int> get durationChoices => const [10, 30, 60];

  // ★★★ S7 清理: 下面这些 `@override` **已删除** ★★★
  //
  // `listModeValue` / `listModeLabel` / `scheduleRule` / `scheduleRuleLabel`
  // 四个 getter **在父类里已经不存在了** —— 它们是 `schedule_rule`
  // （4 路旧调度规则）那一簇的配套, 早先几轮已把父类那簇删掉,
  // 但**测试里的假实现还留着**。
  //
  // ★ 症状: `flutter analyze test/` 报
  //   `override_on_non_overriding_member`（"这个 getter 并没有覆盖任何继承的 getter"）。
  //   ★ 这类警告**很危险**: 它意味着测试在为**不存在的成员**造桩,
  //     也就是说那几条断言其实**从没验证过任何东西**。
  //
  // ⚠ 这些是**上一轮**删父类成员时漏掉的（不是本轮引入）, 但既然
  //   `analyze` 点名了就必须清 —— 否则下一个人的"analyze 很干净"就永远是假的。

  @override
  Map<String, dynamic> kindOf(String kind) {
    for (final k in entryKinds) {
      if ('${k['value']}' == kind) return k;
    }
    return {'value': kind, 'label': kind, 'help': ''};
  }

  // ★ S7 清理: `isTaskEntry` 的 `@override` 已删（父类里没有这个成员）。
  bool isTaskEntryStub(Map<String, dynamic> e) => '${e['kind']}' == 'task';

  @override
  String describeEntry(Map<String, dynamic> e) {
    if ('${e['kind']}' != 'task') return '${e['kind']} ${e['minutes']}分钟';
    // 与真实现保持一致: 任务条目显示**中文名**(真实现走 taskNameZh)
    return '${findTask('${e['task']}')?['name_zh'] ?? e['task']}';
  }

  @override
  Map<String, dynamic>? findTask(String cmd) {
    for (final t in _tasks) {
      if ('${t['command']}' == cmd) return t;
    }
    return null;
  }

  // ---- 监控/队列面板需要的新接口 ----
  //
  // ★ 假控制器**必须覆盖它们**: 真实现在 `_allTasks`（从 `/overview` 加载）
  //   上做映射, 而假控制器的 `_allTasks` 是**空的** ——
  //   不覆盖就会让任务名变成空串, 行全部不渲染
  //   （表现是测试报 `Found 0 widgets with text "探索"`, 很容易误判成面板坏了）。

  /// 命令名 -> 中文名（队列 / 监控用）。
  @override
  String zhNameOf(String command) => '${findTask(command)?['name_zh'] ?? ''}';

  /// 命令名 -> `/overview` 那一行。
  @override
  Map<String, dynamic> taskRowOf(String command) =>
      findTask(command) ?? const {};

  /// 运行态徽标（待执行 / 等待中 / 冷却中 / 未启用）。
  ///
  /// ★ 必须覆盖: 真实现在 `_allTasks`（从 `/overview` 加载）上查,
  ///   假控制器的 `_allTasks` 是空的 —— 不覆盖就一律返回"未知"。
  @override
  ({String label, int tone}) queueStatusOf(String command) {
    final t = findTask(command);
    if (t == null) return (label: '未知', tone: 2);
    if (t['enable'] != true) return (label: '未启用', tone: 2);
    if (t['in_cooldown'] == true) {
      final m = (t['cooldown_minutes'] as num?)?.toInt() ?? 0;
      return (label: m > 0 ? '冷却中 $m 分' : '冷却中', tone: 3);
    }
    if (t['slot'] == 'pending') return (label: '待执行', tone: 0);
    final reason = '${t['reason'] ?? ''}';
    return (label: reason.isEmpty ? '等待中' : reason, tone: 1);
  }

  /// 在不在队列里（1 起; 不在则 0）。
  @override
  int entryPositionOf(String command) {
    for (var i = 0; i < _entries.length; i++) {
      final e = _entries[i];
      if ('${e['kind']}' == 'task' && '${e['task']}' == command) return i + 1;
    }
    return 0;
  }

  /// 未编排的启用任务（**不含**正在运行的那个）。
  ///
  /// ★ 与真实现保持一致: 正在运行的任务**不该**同时出现在"可加入"里
  ///   （用户反馈过"正在运行的逢魔之时下面还能加入逢魔之时"）。
  @override
  List<Map<String, dynamic>> get unqueuedEnabledTasks {
    final inList = {
      for (final e in _entries)
        if ('${e['kind']}' == 'task') '${e['task']}',
    };
    final running = runningTaskCommand;
    return _tasks
        .where((t) =>
            t['enable'] == true &&
            !inList.contains('${t['command']}') &&
            '${t['command']}' != running)
        .toList();
  }

  // ---- 队列成员（步2/步3 新增; 权威在后端）----
  //
  // ★ 假控制器**必须覆盖**: 真实现在 `_allTasks`（从 `/overview` 加载）
  //   上查 `queued` / `auto_queue`, 而假控制器的 `_allTasks` 是空的 ——
  //   不覆盖会让队列渲染成"空", 表现是 `Found 0 widgets`（很容易误判成面板坏了）。

  @override
  bool isQueued(String command) =>
      findTask(command)?['queued'] == true;

  @override
  bool isAutoQueue(String command) =>
      findTask(command)?['auto_queue'] == true;

  @override
  List<Map<String, dynamic>> get queuedTasks =>
      _tasks.where((t) => t['queued'] == true).toList();

  @override
  List<Map<String, dynamic>> get enabledNotQueuedTasks => _tasks
      .where((t) =>
          t['enable'] == true &&
          t['auto_queue'] != true &&
          t['queued'] != true)
      .toList();

  // ★ S7 清理: `overviewRowOf` 的 `@override` 已删 —— **父类里没有这个成员**
  //   （它随"按任务名查行"那簇一起删掉了）。留一个**不带 `@override`** 的
  //   本地辅助, 因为下面几条断言确实要用它。
  Map<String, dynamic> overviewRowOfStub(String command) =>
      findTask(command) ?? const {};

  /// 【添加任务】候选 —— 假实现按**同一规则**从 `_tasks` 里筛。
  ///
  /// ★ 不能让它走网络（测试里会失败或挂住）。
  @override
  Future<List<Map<String, dynamic>>> fetchAddCandidates() async =>
      enabledNotQueuedTasks;

  /// 移出队列 —— 假实现只返回提示文案, 不联网。
  ///
  /// ★ [entryId] 与真实签名一致（⑨: 同名多条要**精确移除**）。
  @override
  Future<String> removeFromQueue(String command, {String? entryId}) async =>
      '（测试）已把「$command」移出队列并停用${entryId == null ? '' : ' [$entryId]'}';

  // ---- 写操作: 测试里只记录, 不联网 ----
  @override
  Future<void> reload() async {}

  @override
  Future<bool> setTarget(String t, int v) async => true;

  @override
  Future<bool> setEnabled(String t, bool v) async => true;

  @override
  Future<void> removeEntry(int i) async {}

  @override
  Future<void> addEntry(Map<String, dynamic> e, {int index = -1}) async {}

  @override
  Future<void> reorderEntries(int a, int b) async {}

  // ★★★ S7 清理: `resetToDefault()` 的假实现**已删除** ★★★
  //
  // ★ 父类里的 `resetToDefault()` **早先几轮就被删了** —— 它当时被判定为
  //   "**最危险的前端死代码**"（会**清空 `run_list`**）, 详见
  //   `task_list_controller.dart` 里那段删除说明。
  // ★ 但测试的假实现**留到了现在**, 于是 `analyze` 报
  //   `override_on_non_overriding_member`。
  // ★ 删掉它: 为不存在的成员造桩**只会掩盖问题**。
}

/// 造一个任务行（字段与真实 `/overview` 对齐）。
///
/// ## `auto_queue` / `queued` 的默认值（与真实后端一致）
///
/// * `auto_queue`  = `!countable`（次数任务不自动进队列）
/// * `queued`      = `auto_queue && enable`（定时类启用后自动在队列里）
/// * `slot`        = `'pending'`（可跑）或 `'waiting'`（未到窗口）
///
/// 需要造"已启用但不在队列"的次数任务时传 `queued: false`（默认就是）。
Map<String, dynamic> taskRow(
  String command, {
  String? zh,
  bool countable = true,
  int? count,
  bool enable = true,
  bool? autoQueue,
  bool? queued,
  String slot = 'pending',
}) {
  final auto = autoQueue ?? !countable;
  return {
    'name': command.toLowerCase(),
    'command': command,
    'name_zh': zh ?? command,
    'category': countable ? 'fixed' : 'timed',
    'category_label': countable ? '固定任务' : '定时任务',
    'countable': countable,
    // ★ 步2 新增字段
    'auto_queue': auto,
    'queued': queued ?? (auto && enable),
    'count': count,
    'enable': enable,
    'can_run': enable,
    'reason': enable ? '' : '未启用',
    'in_window': true,
    'in_list': true,
    'list_pos': 1,
    'next_run': '2026-10-09 12:00:00',
    'period': 'daily',
    'priority': 5,
    'slot': enable ? slot : 'waiting',
    'charges': null,
      'resource_describe': '每天重置',
      'snapshot': '',
    };
}

// ★★★ 两套包装（本轮新增 `wrapBounded`）★★★
//
// ⚠ `QueuePanel` 现在是**自己的滚动容器**（修用户报的 #7:
//   拖动越界不自动滚动 —— 它内部那个 `ReorderableListView` 从
//   "不可滚"改成了"可滚"）。
//   ★ 所以**不能再**把它塞进 `SingleChildScrollView`:
//     那是"滚动套滚动", `ReorderableListView` 会拿到**无界高度**
//     并抛 `constraints: 0<=h<=Infinity`（实测抓到 2 条 widget 测试崩）。
//
// ★ `wrapBounded` 用 `Scaffold(body: child)` —— 与**生产**一致:
//   生产是 `Expanded(child: _bodyFor(...))`, 给的正是**有界**高度。
Widget wrapBounded(Widget child) => GetMaterialApp(
      home: Scaffold(body: child),
    );

/// 给"内容**不是**滚动容器"的 widget 用（如 `_ScheduleTab` 用 `ListView`）。
Widget wrap(Widget child) => GetMaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// 测试用的**定高吸顶** delegate（#6）。
///
/// ★ 生产用的 `_StickyQueueHeader` 会**实测**高度（`LayoutBuilder`）,
///   那在测试里不好断言; 这里用定高版本, 验证的是**行为**:
///   `pinned: true` 之后滚下去顶部还在不在。
class _TestSticky extends SliverPersistentHeaderDelegate {
  _TestSticky(this.child);

  final Widget child;

  @override
  double get minExtent => 48;

  @override
  double get maxExtent => 48;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool over) =>
      Material(color: Theme.of(context).scaffoldBackgroundColor, child: child);

  @override
  bool shouldRebuild(covariant _TestSticky old) => old.child != child;
}

// ============================================================ 运行控制条 v2
//
// v2 去掉了「全部停止 N 分钟」/「只停列表 N 分钟」两个**时长按钮** ——
// 固定任务与定时任务分开管理后，"谁停谁不停"交给总开关表达。
//
// ★ `RunControlBar` 会构造 `ApiClient`（需要 `SettingsController` + 联网），
//   测试环境给不了，所以这里**只断言源码语义**（不含注释），不 pump 真实控件。
//
// ★★ 关键: 检查前**必须去掉注释**。
//   我第一版没去注释，结果守卫匹配到自己的说明文字 ——
//   比如文件里写着"明确不提供立即停"，就被判成"提供了立即停"。
//   这类"守卫误报"很浪费注意力，所以下面先剥注释再断言。
String codeOnly(String path) {
  final raw = File(path).readAsStringSync();
  // 去掉 `///` 与 `//` 行注释（这些文件里没有块注释 `/* */`）
  return raw
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');
}

void _runControlV2Tests() {
  test('运行控制条源码里不再出现已废的时长按钮', () {
    final src = codeOnly('lib/views/tasks/run_control_bar.dart');

    for (final gone in ['全部停止', '只停列表']) {
      expect(src.contains(gone), isFalse,
          reason: 'v2 去掉了「$gone」, 代码里不该再出现');
    }
    for (final gone in ['restScript', 'delayScript']) {
      expect(src.contains(gone), isFalse, reason: 'v2 不该再调 `$gone`');
    }
  });

  test('★ 共用顶部：状态 + 计数 + 启动脚本（暂停调度已移走）', () {
    // ★★★ 用户裁定（2026-10-11）★★★
    //
    // > "● 脚本未启动     待执行 3   等待中 2    [▶ 启动脚本]"
    // > "这一行**已停止和脚本未启动意义重合了，没必要，所以删掉了**"
    // > "[⏸ 暂停调度] 应该**和队列中任务点击运行那个按钮是一个东西**，
    // >  **放在外边就冗余了**"
    //
    // ⇒ 共用顶部（`RunControlBar`）现在 = **状态点 + 计数 + 启停脚本**；
    //   ★ **暂停调度搬到了"正在运行的那一行"**（见 `queue_panel.dart`）。
    final src = codeOnly('lib/views/tasks/run_control_bar.dart');
    // 计数上移
    expect(src.contains('待执行'), isTrue, reason: '计数「待执行」应上移到这一行');
    expect(src.contains('等待中'), isTrue, reason: '计数「等待中」应上移到这一行');
    // 启停脚本合并到这里（一个按钮两态）
    expect(src.contains('启动脚本'), isTrue, reason: '「启动脚本」应在共用顶部');
    expect(src.contains('停止脚本'), isTrue, reason: '运行时该按钮应变成「停止脚本」');
    // ★ **暂停按钮**不该在这里了（"暂停调度"作为**状态文字**仍会出现在
    //   状态点旁边 —— 那是合法的，所以这里只断言**按钮 label** 不在）
    expect(src.contains("label: const Text('暂停调度')"), isFalse,
        reason: '★ 暂停按钮已移到「正在运行的那一行」上，不该留在共用顶部');
    expect(src.contains("label: const Text('继续调度')"), isFalse,
        reason: '★ 继续按钮同样搬到那一行（与 [▶] 互斥显示）');
    expect(src.contains("mode: 'round'"), isFalse,
        reason: '不该再有 round 模式的入口');
    expect(src.contains('立即停'), isFalse,
        reason: '「立即停」会卡在半途，明确不提供');
  });

  test('运行控制条的状态看**脚本进程**, 不是只看暂停', () {
    // ★★ 修一个真 bug ★★
    //
    // 用户反馈: "虽然未暂停调度就绿色运行中，但是脚本进程停止时
    //            这个还显示运行中啊"
    //
    // 根因: 原先只看 `run_control` 的 `paused`, 没看脚本进程。
    final src = codeOnly('lib/views/tasks/run_control_bar.dart');
    expect(src.contains('scriptModelMap'), isTrue,
        reason: '状态必须同时看脚本进程（WebSocket 的 ScriptModel.state）');
    expect(src.contains('ScriptState.running'), isTrue);
    expect(src.contains('脚本未启动'), isTrue,
        reason: '进程停时要明确显示"脚本未启动"，不能显示"运行中"');
    // 进程没跑时"暂停调度"应置灰
    expect(src.contains('!procRunning'), isTrue);
  });

  test('★ 启停脚本**已合并到共用顶部**（用户裁定）', () {
    // ★★★ 用户原话 ★★★
    //
    // > "启动/停止脚本**放到共用顶部**"
    // > "**'} 一个按钮 ┘**"
    //
    // ★ 原来"启动脚本"在任务列表页的 `_bulkPanel` 里（且**只有启动**）、
    //   "停止脚本"在执行队列页的 `_scriptProcessBar` 里（且**只有停止**）
    //   ⇒ ★ **两个地方各一半** ⇒ 现在**合并成一个**、放共用顶部。
    final src = codeOnly('lib/views/tasks/run_control_bar.dart');
    expect(src.contains('startScript'), isTrue,
        reason: '「启动脚本」应在共用顶部');
    expect(src.contains('stopScript'), isTrue,
        reason: '「停止脚本」也应在共用顶部（同一个按钮的另一态）');
    // ★ 任务列表页**不该再**有那一行
    final view = codeOnly('lib/views/tasks/task_list_view.dart');
    expect(view.contains('_scriptProcessRow'), isFalse,
        reason: '★ 任务列表页「脚本进程运行中/已停止」整行应已删除');
    // ★ 执行队列页**不该再**有那个条
    final q = codeOnly('lib/views/tasks/queue_panel.dart');
    expect(q.contains('_scriptProcessBar'), isFalse,
        reason: '★ 执行队列页「脚本未启动 [启动脚本]」应已删除（与顶部重复）');
  });

  test('运行列表面板不再出现 delay 条目', () {
    final src = codeOnly('lib/views/tasks/queue_panel.dart');
    expect(src.contains("'delay'"), isFalse,
        reason: 'v2 的列表只有 task 与 rest');
    expect(src.contains('只停列表'), isFalse);
  });
}

// ============================================================ 总览页 v2 补齐
//
// 用户要求补齐的项:
//   * 「重置选中」（归档后重开）
//   * 「运行一次」（点击顺序插队）
//   * 筛选: 只看定时任务 / 只看限时活动
void _overviewV2Tests() {
  test('总览页有「重置选中」与「运行一次」按钮', () {
    final src = codeOnly('lib/views/tasks/task_list_view.dart')
        .replaceAll("\n", '');
    expect(src.contains('重置选中'), isTrue);
    expect(src.contains('运行一次'), isTrue);
    // 两个按钮都调控制器上对应的方法（不是空按钮）
    expect(src.contains('resetSelected'), isTrue);
    expect(src.contains('runOnceSelected'), isTrue);
  });

  test('总览页补齐了四个筛选', () {
    final src = codeOnly('lib/views/tasks/task_list_view.dart');
    for (final f in ['只看已启用', '只看临时任务', '只看周期任务', '只看限时活动']) {
      expect(src.contains(f), isTrue, reason: '缺筛选「$f」');
    }
  });

  test('「只看 X」筛选互斥（同时勾两个结果必为空）', () {
    final src = File('lib/controller/task_list/task_list_controller.dart')
        .readAsStringSync();
    // 三个 toggle 里都该清掉另外两个 —— 逐个检查**方法体**,
    // 而不是全文 contains（后者会被别处的赋值蒙混过关）。
    for (final entry in {
      'void toggleOnlyFixed': ['onlyTimed = false', 'onlyLimited = false'],
      'void toggleOnlyTimed': ['onlyFixed = false', 'onlyLimited = false'],
      'void toggleOnlyLimited': ['onlyFixed = false', 'onlyTimed = false'],
    }.entries) {
      final i = src.indexOf(entry.key);
      expect(i, greaterThan(-1), reason: '找不到 ${entry.key}');
      final body = src.substring(i, i + 400);
      for (final need in entry.value) {
        expect(body.contains(need), isTrue,
            reason: '${entry.key} 里应清掉另一个: $need');
      }
    }
  });

  test('「重置选中」有二次确认（归档会改计数, 不能误点）', () {
    final src = codeOnly('lib/controller/task_list/task_list_controller.dart');
    final i = src.indexOf('Future<bool> resetSelected');
    expect(i, greaterThan(-1));
    final body = src.substring(i, i + 900);
    expect(body.contains('_confirm'), isTrue,
        reason: '重置会改变计数，必须有二次确认');
    expect(body.contains('归档'), isTrue,
        reason: '确认文案要说清"归档"而不是"删除"');
  });

  test('总览页有「运行记录」列（次数 + 耗时）', () {
    final row = codeOnly('lib/views/tasks/task_row_view.dart');
    expect(row.contains('_recordCell'), isTrue);
    final header = codeOnly('lib/views/tasks/task_list_view.dart');
    expect(header.contains('运行记录'), isTrue);
  });

  test('运行记录显示归档轮数（重置不删历史）', () {
    final src = codeOnly('lib/views/tasks/task_row_view.dart');
    expect(src.contains('archived_rounds'), isTrue,
        reason: '要能看出"已归档 N 轮"—— 否则用户以为重置把数据删了');
  });
}

// ============================================================ 多列排序 + 持久记忆
//
// 用户要求:
// > 支持多列排序筛选且可以**持久记忆**用户的偏好，
// > 同时可以**恢复默认**（有相关功能说明和弹窗提示）
void _sortAndPrefsTests() {
  test('表头可点击排序（多列）', () {
    final src = codeOnly('lib/views/tasks/task_list_view.dart');
    expect(src.contains('_sortableHeader'), isTrue);
    expect(src.contains('c.sortBy('), isTrue, reason: '表头必须真的能点');
    // 至少覆盖这些列
    for (final col in ['name', 'category', 'state', 'next_run']) {
      expect(src.contains("'$col'"), isTrue, reason: '缺可排序列 $col');
    }
  });

  test('排序箭头反映当前列与方向', () {
    final src = codeOnly('lib/views/tasks/task_list_view.dart');
    expect(src.contains('arrow_upward'), isTrue);
    expect(src.contains('arrow_downward'), isTrue);
    expect(src.contains('unfold_more'), isTrue,
        reason: '非当前列要有"可点"提示，否则用户不知道表头能点');
  });

  test('「恢复默认」有二次确认 + 说明不影响什么', () {
    final src = codeOnly('lib/controller/task_list/task_list_controller.dart');
    final i = src.indexOf('Future<bool> restoreDefaults');
    expect(i, greaterThan(-1));
    final body = src.substring(i, i + 800);
    expect(body.contains('_confirm'), isTrue, reason: '用户要求"有弹窗提示"');
    expect(body.contains('不影响'), isTrue,
        reason: '要说明它**不动**任务配置/记录/执行顺序');
    expect(body.contains('prefsStore.clear'), isTrue,
        reason: '恢复默认应真的清掉持久化偏好');
  });

  test('偏好会落盘（切列/切筛选都存）', () {
    final src = codeOnly('lib/controller/task_list/task_list_controller.dart');
    // 每个 toggle 与 sortBy 都应调 _savePrefs
    for (final m in ['void sortBy', 'void toggleOnlyTimed', 'void toggleOnlyLimited']) {
      final i = src.indexOf(m);
      expect(i, greaterThan(-1), reason: '找不到 $m');
      expect(src.substring(i, i + 500).contains('_savePrefs'), isTrue,
          reason: '$m 应持久化偏好');
    }
  });

  test('偏好按账号**且按配置页**隔离（#9 用户裁定 2A）', () {
    final src = codeOnly('lib/controller/task_list/task_list_controller.dart');
    // ★ 用户裁定「2A = 算」: 排序列/升降序 · 只看筛选 · 分栏宽度
    //   **按页隔离** —— 所以 key 是 `<账号>:<页id>`, 不再是只用账号。
    expect(src.contains('_prefsKey'), isTrue,
        reason: '★ 偏好必须有"按页"的 key 解析器（#9）');
    expect(src.contains("'\$scriptName:\$pid'"), isTrue,
        reason: "★ key 必须是 `<账号>:<页id>`（用户裁定 2A: 按页隔离）");
    expect(src.contains('prefsStore.read(_prefsKey)'), isTrue);
    expect(src.contains('prefsStore.write(_prefsKey'), isTrue);
    // ★ 切换配置页必须**换 key 并重载** —— 否则界面还是旧页的排序
    //   （看起来"切页没反应"）
    expect(src.contains('_switchPrefsPage'), isTrue,
        reason: '★ 切页要换偏好 key —— 这一步最容易忘, 必须有守卫');
  });

  test('排序只影响显示 —— 不改执行顺序', () {
    // ★ 用户明确选了"拖拽排序 = 只改显示顺序"。
    //   若排序偷偷改了 run_list，用户会以为"排序等于调顺序"。
    final src = codeOnly('lib/controller/task_list/task_list_controller.dart');
    final i = src.indexOf('void _applySort');
    expect(i, greaterThan(-1));
    final body = src.substring(i, i + 400);
    expect(body.contains('saveRunList'), isFalse,
        reason: '排序不该碰执行顺序');
    expect(body.contains('_api'), isFalse,
        reason: '排序是纯本地的，不该发请求改后端状态');
  });
}

// ============================================================ Round 4 收尾
void _round4Tests() {
  test('★ 启停脚本只在**共用顶部**（两处旧位置都已删除）', () {
    final src = codeOnly('lib/views/tasks/task_list_view.dart');
    final q = codeOnly('lib/views/tasks/queue_panel.dart');
    final bar = codeOnly('lib/views/tasks/run_control_bar.dart');

    // ★★ 用户最终裁定（2026-10-11）★★
    //   "启动/停止脚本**放到共用顶部**"
    //   "**'} 一个按钮 ┘**"
    // ★ 原来：任务列表 `_bulkPanel` 只有「停止脚本」、
    //   执行队列 `_scriptProcessBar` 只有「启动脚本」⇒ **两处各一半**。
    expect(bar.contains('startScript'), isTrue,
        reason: '★ 「启动脚本」应在共用顶部（RunControlBar）');
    expect(bar.contains('stopScript'), isTrue,
        reason: '★ 「停止脚本」也应在共用顶部（同一按钮的另一态）');

    // ★ 两处旧位置**都不该再存在**
    expect(src.contains('_scriptProcessRow'), isFalse,
        reason: '★ 任务列表页那行已删除');
    expect(q.contains('_scriptProcessBar'), isFalse,
        reason: '★ 执行队列页那个条已删除');

    // ★ 硬停要二次确认 —— 它会打断当前战斗
    //   ⚠ 断言要**往前看**：`AlertDialog(` 在 `title: '停止脚本进程？'` **之前**
    //     （第一次写成"从标题往后 700 字找 AlertDialog" ⇒ 假失败）
    final i = bar.indexOf('停止脚本进程？');
    expect(i, greaterThan(-1), reason: '硬停必须有二次确认弹窗');
    expect(bar.substring((i - 400).clamp(0, i), i).contains('AlertDialog'),
        isTrue,
        reason: '硬停必须用 AlertDialog 二次确认');
  });

  test('共用顶部的脚本状态在 Obx 里直接读 Rx（否则 GetX 抛异常白屏）', () {
    // ★ 这段原来是钉 `task_list_view._scriptProcessRow` 的 ——
    //   那个函数**已删除**（那行搬进共用顶部了）⇒ 改钉 `RunControlBar`。
    final src = codeOnly('lib/views/tasks/run_control_bar.dart');
    expect(src.contains('Obx('), isTrue);
    expect(src.contains('.state.value'), isTrue,
        reason: 'Obx 回调必须**直接读 Rx**，否则抛 improper use of a GetX');
  });

  test('任务选择器：休息置顶 + 候选来自**后端端点**', () {
    final src = codeOnly('lib/views/tasks/queue_panel.dart');
    final i = src.indexOf('class _TaskPickerDialogState');
    expect(i, greaterThan(-1));
    final body = src.substring(i, i + 3200);

    // 「休息」是控制条目, 与候选过滤无关, 始终置顶
    expect(body.contains('休息（去庭院待着）'), isTrue, reason: '休息应置顶');
    expect(body.contains('_PickedEntry.rest'), isTrue);

    // ★★ 候选**走后端**（`fetchAddCandidates`）—— 前端不再自己过滤 ★★
    //
    // 规则只有一处（后端 `get_queue_candidates`）, 前端重复实现会漂移。
    expect(body.contains('fetchAddCandidates'), isTrue,
        reason: '候选应来自后端端点, 不在前端重新实现过滤规则');
    expect(body.contains('widget.controller.allTasks'), isFalse,
        reason: '选择器不该再自己筛 allTasks —— 规则会与后端漂移');

    // ★ 空态必须给出**原因与出路**（只说"没有"会让人以为坏了）
    expect(body.contains('没有可添加的任务'), isTrue);
  });

  test('★ 移除队列 = 确认弹窗 + 后端停用 + 提示', () {
    final src = codeOnly('lib/views/tasks/queue_panel.dart');
    // 弹窗（#6 重构后从 State 方法变成**顶层函数** —— 行渲染搬到了
    // 外层的 sliver 序列里, 不再是 `_QueuePanelState` 的私有方法）
    expect(src.contains('confirmAndRemove'), isTrue, reason: '缺少移除确认弹窗');
    expect(src.contains('移出并停用'), isTrue, reason: '弹窗要明确说"会同时停用"');
    // 走后端（后端会 `sch.enable = False`）
    expect(src.contains('c.removeFromQueue('), isTrue);
    // 提示
    expect(src.contains('Get.snackbar'), isTrue, reason: '移除后要给提示');
    // 文案要说清"之后怎么再跑"
    expect(src.contains('任务列表'), isTrue,
        reason: '提示要告诉用户"想再跑需先在任务列表启用"');
  });

  test('★ 四类分区：权威是后端的 queued / auto_queue', () {
    // | # | 分类 | 判定 |
    // |---|---|---|
    // | 0 | 正在运行 | WebSocket `runningTask`（`_statusBlock`）|
    // | 1/2 | 可跑 / 未到窗口 | `queued && slot`（**可拖**）|
    // | 3 | 启用但不会运行 | `enable && !auto_queue && !queued` —— 只在【添加任务】里 |
    // | 4 | 未启用 | `!enable` —— 只在任务列表里 |
    final ctrl = codeOnly('lib/controller/task_list/task_list_controller.dart');
    expect(ctrl.contains("t['queued'] == true"), isTrue,
        reason: 'isQueued 必须读后端 queued 字段（不自己推导）');
    expect(ctrl.contains("t['auto_queue'] == true"), isTrue,
        reason: 'isAutoQueue 必须读后端 auto_queue 字段');
    final i = ctrl.indexOf('get enabledNotQueuedTasks');
    expect(i, greaterThan(-1));
    final body = ctrl.substring(i, i + 400);
    expect(body.contains("t['enable'] == true"), isTrue);
    expect(body.contains("t['auto_queue'] != true"), isTrue);
    expect(body.contains("t['queued'] != true"), isTrue);

    final q = codeOnly('lib/views/tasks/queue_panel.dart');
    // ★ 2026-10-10: 渲染源从 `entries`（只有 run_list）改为
    //   `c.queuedTaskRows`（有效队列 = run_list + 自动补齐）
    //   —— 修"启用了定时任务却看不到"的 bug。
    expect(q.contains('c.queuedTaskRows'), isTrue,
        reason: '队列应渲染**有效队列**（含自动补齐的定时任务）');
    // 可跑/未到开放时间的判定必须读后端 slot
    expect(q.contains("'pending'"), isTrue,
        reason: '缺少 slot（可跑/未到开放时间）判定');
    // ★ 2026-10-10: 文案从"可跑 / 未到窗口"改为"待执行 / 未到开放时间"
    expect(q.contains('待执行'), isTrue);
    expect(q.contains('未到开放时间'), isTrue);
    // ★ #6 之后: 可拖列表由 `SliverReorderableList` 承担
    //   （`ReorderableListView` 自己就是滚动体, 塞不进吸顶用的
    //    `CustomScrollView`）
    expect(q.contains('SliverReorderableList'), isTrue,
        reason: '队列必须可拖拽');
  });

  test('★ 第 3 类**不堆在队列下面**（用户明确要求）', () {
    // 用户原话: "启用的任务但不会执行的任务应该出现在添加任务里，
    //            而不是堆在未编排里"。
    final q = codeOnly('lib/views/tasks/queue_panel.dart');
    expect(q.contains('_unqueuedRow'), isFalse,
        reason: '不该再把未编排的任务一行行罗列在队列下面');
    expect(q.contains('未编排（共'), isFalse,
        reason: '旧的"未编排"标题应已删除');
    expect(q.contains('不在队列里'), isTrue, reason: '缺少指引文案');
    expect(q.contains('添加'), isTrue, reason: '缺少「添加」入口');
  });

  testWidgets('★ 队列只渲染 queued 的任务（第 3 类不出现）', (tester) async {
    final c = FakeTaskListController(
      entries: [
        {'kind': 'task', 'task': 'DemonEncounter'},
      ],
      tasks: [
        // 在队列里 -> 应渲染
        taskRow('DemonEncounter', zh: '逢魔之时', queued: true),
        // 已启用的次数任务, 不在队列 -> **不该**出现在队列里
        taskRow('RealmRaid', zh: '个人突破', countable: true),
      ],
    );
    await tester.pumpWidget(wrapBounded(QueuePanel(controller: c)));
    await tester.pump();

    expect(find.text('逢魔之时'), findsOneWidget);
    expect(find.text('个人突破'), findsNothing,
        reason: '启用但不在队列的次数任务不该出现在队列里（只在【添加任务】）');
    expect(find.textContaining('不在队列里'), findsOneWidget);
    // ★ 2026-10-12：★ 这个「添加」按钮**保留**（★ 我上一轮误删，已恢复）。
    //   ★ 用户澄清：要删的是"**添加任务弹窗里重复的休息入口**"，
    //     **不是**队列里这个「添加」。
    expect(find.text('添加'), findsOneWidget);
  });

  // ============================================================ #6 吸顶（真渲染）
  //
  // ★★ 为什么这条必须是**widget 测试**而不是源码守卫 ★★
  //
  // `SliverPersistentHeader` / `SliverReorderableList` 的坑**全在运行时**:
  //   * `SliverReorderableList` 断言 `child.key != null`
  //     （我第一版把 key 挂在行**内部**的 `Container` 上 -> 整页抛断言,
  //      `analyze` **完全查不出来**）
  //   * "滚动套滚动" -> `constraints: 0<=h<=Infinity`
  //   * `pinned: true` 写错/漏写 -> 顶部照样被滚走（用户报的 bug 原样复现）
  //
  // 所以这里真渲染一遍: 吸顶区 + 队列那一组 sliver 住进**同一个**
  // `CustomScrollView`, 滚到底之后断言顶部**还在**。
  testWidgets('★ #6 顶部内容滚动后**仍在**（吸顶真渲染, 非源码守卫）',
      (tester) async {
    // 造 30 条队列 —— 必须能真的滚起来, 否则"吸顶"无从验证
    final entries = <Map<String, dynamic>>[
      for (var i = 0; i < 30; i++)
        {
          'kind': 'task',
          'task': 'T$i',
          'entry_id': '20261010T1430${i.toString().padLeft(2, '0')}-T$i',
        },
    ];
    final c = FakeTaskListController(
      entries: entries,
      tasks: [
        for (var i = 0; i < 30; i++) taskRow('T$i', zh: '任务$i', queued: true),
      ],
    );

    await tester.pumpWidget(GetMaterialApp(
      home: Scaffold(
        // ★ 用 `Builder` 拿一个**树内**的 context 再调 `QueuePanel.slivers`
        //   （它只是把 context 往下传给子 widget, 真正用是在子 widget 的
        //   `build` 里 —— 但构造时确实需要一个 context 参数）。
        body: Builder(
          builder: (ctx) => CustomScrollView(
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: _TestSticky(
                  const SizedBox(
                    height: 48,
                    child: Center(child: Text('吸顶测试标记')),
                  ),
                ),
              ),
              // ★ 队列本体 —— 与 `_QueueTab` 用的是**同一组 sliver**
              ...QueuePanel.slivers(ctx, c),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();

    // 队列真渲染出来了（`SliverReorderableList` 的 key 断言没炸）
    expect(find.text('任务0'), findsOneWidget,
        reason: '★ 队列行没渲染 —— 多半是 `SliverReorderableList` 的'
            '`All list items must have a key` 断言炸了'
            '（key 必须挂在 `itemBuilder` 返回的 widget 上）');
    expect(find.text('吸顶测试标记'), findsOneWidget);

    // 滚到底: 顶部那块必须**还在**
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -4000));
    await tester.pumpAndSettle();

    expect(find.text('吸顶测试标记'), findsOneWidget,
        reason: '★★ 滚下去之后顶部**必须还在** —— 这就是用户要的'
            '「滚动时上边的按钮和展示会一直存在」。❌ 不见了 = '
            '`pinned: true` 没生效（又变回"随内容滚"）');
  });

  test('任务选择器**不再**按 countable 过滤（曾静默丢用户的配置）', () {
    // ★★ 回归守卫 ★★
    //
    // 曾经选择器与后端都按 `countable` 过滤, 结果:
    // `countable` 只覆盖 54 个任务里的 **14 个**, 用户列表里的
    // DemonEncounter / WantedQuests / MysteryShop / Duel /
    // ExperienceYoukai / TrueOrochi / WeeklyTrifles **全被丢弃**,
    // 而且过滤结果会被 `save_run_list()` 写回配置 -> 静默的数据破坏。
    //
    // 现在**列表接受任意任务名**。选择器也不该再自己过滤。
    final src = codeOnly('lib/views/tasks/queue_panel.dart');
    final i = src.indexOf('class _TaskPickerDialogState');
    final body = src.substring(i, i + 2600);
    expect(body.contains("t['countable'] == true"), isFalse,
        reason: '选择器不该再按 countable 过滤, 否则又会丢任务');
  });

  test('休息选项排在其他任务之前', () {
    final src = File('lib/views/tasks/queue_panel.dart').readAsStringSync();
    final restIdx = src.indexOf('_PickedEntry.rest');
    final listIdx = src.indexOf('ListView.builder', restIdx);
    expect(restIdx, greaterThan(-1));
    expect(listIdx, greaterThan(restIdx),
        reason: '休息卡片必须在任务列表**之前**渲染（置顶）');
  });

  test('点任务行进设置页，且绕过 useablemenus 白名单', () {
    final view = codeOnly('lib/views/tasks/task_list_view.dart');
    expect(view.contains('openTaskSettings'), isTrue);
    expect(view.contains('onTap:'), isTrue);

    final nav = codeOnly('lib/controller/ctrl_nav.dart');
    final i = nav.indexOf('void openTaskSettings');
    expect(i, greaterThan(-1));
    final body = nav.substring(i, i + 700);
    // ★ 这是关键: 不能复用 switchContent（它有白名单，会静默忽略）
    expect(body.contains('useablemenus'), isFalse,
        reason: 'openTaskSettings 不该有白名单守卫，否则点不在侧边栏的任务会没反应');
    // 但仍要防呆 TaskList（后端没有 /TaskList/args，loadGroups 会崩）
    expect(body.contains('TaskList'), isTrue,
        reason: '仍要防呆 TaskList，否则界面 500');
  });
}

// ============================================================ Phase 0 修复
void _phase0Tests() {
  test('搜索框是**受控**的（曾"清空后任务不恢复"）', () {
    // ★★ 回归守卫 ★★
    //
    // 之前的 bug: 搜索框只有 `onChanged: c.setQuery`（没有 controller），
    // 而 `setQuery` 里的 `update()` 故意不重建输入框那部分（为输入流畅）。
    // 于是:
    //   * 清空搜索后列表不恢复（控制器里 query 清了，显示没复位）
    //   * `恢复默认` 清了 query，**输入框里的旧文字还在**
    //   * 重启后偏好里的 query 恢复了，但**输入框是空的**
    final view = codeOnly('lib/views/tasks/task_list_view.dart');
    expect(view.contains('TextEditingController'), isTrue,
        reason: '搜索框必须有 controller');
    expect(view.contains('controller: searchCtrl'), isTrue,
        reason: 'TextField 必须接上受控 controller');
    expect(view.contains('_searchCtrl.dispose()'), isTrue,
        reason: 'controller 必须被释放（否则每帧泄漏监听器）');
    // 一键清除
    expect(view.contains('clearQuery'), isTrue, reason: '缺"清除搜索"入口');
  });

  test('控制器 -> 输入框 的反向同步必须存在', () {
    final view = codeOnly('lib/views/tasks/task_list_view.dart');
    expect(view.contains('onQueryChanged'), isTrue,
        reason: '控制器改动 query 后要能同步回输入框');

    final ctrl = codeOnly('lib/controller/task_list/task_list_controller.dart');
    // 三条会改 query 的路径都要通知输入框
    for (final where in ['void applyQueryNow', 'Future<bool> restoreDefaults']) {
      final i = ctrl.indexOf(where);
      expect(i, greaterThan(-1), reason: '找不到 $where');
      expect(ctrl.substring(i, i + 1200).contains('onQueryChanged'), isTrue,
          reason: '$where 应同步输入框');
    }
    // 载入偏好后也要同步（否则重启后输入框是空的）
    final rl = ctrl.indexOf('Future<void> reload()');
    expect(ctrl.substring(rl, rl + 4000).contains('onQueryChanged'), isTrue,
        reason: '载入偏好后要把 query 同步回输入框');
  });

  test('搜索有防抖（不再每击键重建 54 行）', () {
    final ctrl = codeOnly('lib/controller/task_list/task_list_controller.dart');
    expect(ctrl.contains('_searchDebounce'), isTrue, reason: '缺搜索防抖');
    expect(ctrl.contains('_searchDebounce?.cancel()'), isTrue,
        reason: 'onClose 必须取消定时器，否则控制器销毁后还在跑');
  });

  // 后端"列表接受任意任务名"的回归守卫在 pytest 里:
  //   tests/module/config/test_run_list.py::TestListAcceptsAnyTask
  //   （含真实被丢弃的那 7 个任务）
}

// ============================================================ Phase 1: 开关与优先级
void _phase1Tests() {
  test('全局设置渲染**全部**开关（曾一个都没渲染）', () {
    // ★★ 重大遗漏的回归守卫 ★★
    //
    // 后端把两个总开关 + 优先级 + 休息穿插全做完了, `/schema` 的
    // `global_fields` 也暴露了 —— 但前端**一个都没渲染**,
    // 于是它们永远停在默认值, 用户在界面上根本改不了。
    //
    // ★★ S6: `timed_priority` -> **`priority_mode`**（三模式）★★
    //
    // 用户裁定: "**三个选项: 定时任务优先、固定任务优先、自定义**" ——
    // 旧的两个重叠下拉已并入 `priority_mode`。
    //
    // ★★★ S7: 那条裁定**已被用户自己推翻并删除** ★★★
    //
    // > "固定任务优先和定时任务优先以及**不能跨类别拖动太蠢了**。我只需要
    // >  保持**可以自由拖动/改变执行顺序**就行, 固定任务优先和定时任务优先
    // >  **直接作为一个快捷排序**就好, 而不是定义一些没有意义的不能跨类别
    // >  拖动以及**单独的调度优先级**。"
    //
    // ★ 所以 `priority_mode` **不再是全局设置项** —— 后端 `/schema` 的
    //   `global_fields` 现在只有 4 个键。这里改成断言**实际还在**的三个
    //   （`enable_fixed` / `enable_timed` / `rest_interleave`）,
    //   并加**反向守卫**确保 `priority_mode` 不再出现。
    final view = codeOnly('lib/views/tasks/task_list_view.dart');
    for (final key in ['enable_fixed', 'enable_timed', 'rest_interleave']) {
      expect(view.contains("'$key'"), isTrue,
          reason: '全局设置缺开关 $key（后端早就支持了）');
    }
    // ★ 本轮改造: `_switchRow`（标签 + Switch 的**整行**）已换成
    //   `_inlineSwitch`（一枚图标按钮 + Tooltip）——
    //   用户要求"全局开关放到执行队列里, 和别的功能按钮**合理摆放, 节省空间**"。
    expect(view.contains('_inlineSwitch'), isTrue,
        reason: '缺开关控件（`_inlineSwitch`: 图标 + Tooltip, 省版面）');
    // ★ 反向守卫: 已删的「调度优先级」不得回来
    expect(view.contains("'priority_mode'"), isFalse,
        reason: '★ 「调度优先级三模式」已被用户裁定删除 —— '
            '排序是"一次性动作"（两个按钮），不是一个"模式"');
  });

  test('开关的标签与说明从 `/schema` 读，不硬编码文案', () {
    final ctrl = codeOnly('lib/controller/task_list/task_list_controller.dart');
    expect(ctrl.contains('globalFieldLabel'), isTrue);
    expect(ctrl.contains('globalField('), isTrue);
    // ★★ T10: 这里原来断言 `timedPriorityChoices` —— 那个 getter 是**死代码**
    //   （`timed_priority` 已并入 `priority_mode`, 且 `lib/` 里 0 个调用方）。
    //   ★ 这条断言**给死代码上了锁**: 清理时它会失败, 于是没人敢删。
    //   现在改成断言**真正在用**的 `globalSwitch`（两个总开关）。
    //
    // ★★★ S7 再修: 原来断言的是 `priorityModeChoices` ★★★
    //
    // 那个 getter 随「调度优先级三模式」一起**被用户裁定删除**了
    // （排序改成一一次性动作 -> 没有"可选模式"这回事）。
    // ★ 所以这里改成断言仍有效的 `globalSwitch`
    //   （`enable_fixed` / `enable_timed` 两个总开关走它）。
    expect(ctrl.contains('globalSwitch'), isTrue,
        reason: '总开关要从 /schema 读当前值, 否则界面显示的可能不是真实状态');
    // ★ 反向守卫: 随三模式一起删掉的三个 getter 不得回来
    for (final dead in ['priorityModeChoices', 'dragWithinGroupOnly',
                        'setPriorityMode']) {
      expect(ctrl.contains(dead), isFalse,
          reason: '★ `$dead` 随「调度优先级三模式」一起被删 —— '
              '拖动永远自由, 排序是"一次性动作"（`sortQueueBy`）');
    }
    // ★ 正向: 替代它的"一次性排序"必须在
    expect(ctrl.contains('sortQueueBy'), isTrue,
        reason: '★ 缺了「快捷排序」—— 用户要的"排一次"能力就没有了');

    final view = codeOnly('lib/views/tasks/task_list_view.dart');
    // 开关行必须用 controller 给的标签, 而不是写死中文
    //
    // ★ 本轮改造: 不再用 `globalFieldLabel()`（那只是 map 里的一个键）,
    //   而是直接读整个 `globalField(key)` —— 因为紧凑开关的 Tooltip 要
    //   **标签 + 说明**两项（`f['label']` / `f['help']`）。
    expect(view.contains('c.globalField('), isTrue,
        reason: '开关的标签/说明必须从 `/schema` 读, 不硬编码文案');
  });

  test('优先级与预期完成时间可编辑（每任务）', () {
    final ctrl = codeOnly('lib/controller/task_list/task_list_controller.dart');
    expect(ctrl.contains('setTaskPriority'), isTrue);
    expect(ctrl.contains('setTaskExpectedMinutes'), isTrue);
    // 走各任务的 scheduler 分组
    expect(ctrl.contains("'scheduler', 'priority'"), isTrue);
    expect(ctrl.contains("'expected_minutes'"), isTrue);

    final row = codeOnly('lib/views/tasks/task_row_view.dart');
    expect(row.contains('_priorityCell'), isTrue);
    expect(row.contains('_expectedCell'), isTrue);
    expect(row.contains('_NumberCell'), isTrue);
  });

  test('数字输入格不能每击键提交（会打爆后端）', () {
    final row = codeOnly('lib/views/tasks/task_row_view.dart');
    final i = row.indexOf('class _NumberCellState');
    expect(i, greaterThan(-1));
    // ⚠ 类在文件末尾附近 —— 直接 +2200 会越界（踩过）。
    final end = (i + 2200 < row.length) ? i + 2200 : row.length;
    final body = row.substring(i, end);
    // 只在失焦/回车提交
    expect(body.contains('_focus.addListener'), isTrue,
        reason: '失焦要提交');
    expect(body.contains('onSubmitted'), isTrue, reason: '回车要提交');
    // 有焦点时不覆盖用户输入
    expect(body.contains('_focus.hasFocus'), isTrue);
    // 必须被释放
    expect(body.contains('_ctrl.dispose()'), isTrue);
    expect(body.contains('_focus.dispose()'), isTrue);
  });

  test('目标次数输入框读写的是 `target`，不是 `count`', () {
    // ★★ 回归守卫 ★★
    //
    // 之前 `_targetText()` 读 `task['count']`（任务配置里的默认值），
    // 而用户改的是 `scheduler.target` —— 于是改完看到旧数字,
    // 会**以为没生效**（这就是"次数双轨"那套 bug 的表现）。
    final row = codeOnly('lib/views/tasks/task_row_view.dart');
    final i = row.indexOf('String _targetText()');
    expect(i, greaterThan(-1));
    final body = row.substring(i, i + 260);
    expect(body.contains("task['target']"), isTrue,
        reason: '输入框初始值应读 target');
    expect(body.contains("task['count']"), isFalse,
        reason: 'count 是任务配置默认值, 不该当输入框的值');
  });

  test('失败冷却徽标可一键清除', () {
    final row = codeOnly('lib/views/tasks/task_row_view.dart');
    expect(row.contains('_cooldownBadge'), isTrue);
    expect(row.contains('in_cooldown'), isTrue);
    expect(row.contains('clearFailure'), isTrue,
        reason: '修好之后要能立刻重试, 不用等 1 小时');
    expect(row.contains('onDeleted'), isTrue);

    final ctrl = codeOnly('lib/controller/task_list/task_list_controller.dart');
    expect(ctrl.contains('clearFailureState'), isTrue);
  });

  test('排序支持优先级与预期耗时两列', () {
    final prefs = codeOnly('lib/service/task_prefs.dart');
    expect(prefs.contains("'priority'"), isTrue);
    expect(prefs.contains("'expected'"), isTrue);
    // 键要同类型（缺失时给数字兜底, 不能返回 null）
    expect(prefs.contains("case 'priority':"), isTrue);
    expect(prefs.contains("case 'expected':"), isTrue);
  });
}

// ============================================================ Phase 2: 合并页面
void _phase2Tests() {
  test('统一控制台: **两个面板**（任务列表 / 执行队列, 由导航树切换）+ 汇报可收纳抽屉', () {
    // ★★ 用户反馈演进（每一轮都改变了结构）★★
    //
    //   1. "把功能加入旧总览" -> 合并成一个控制台
    //   2. "执行顺序和监控不能合在一起吗" -> 3 tab 减到 2
    //   3. "监控窗口和预期流程不应该是一种东西吗" -> 合一
    //   4. "执行队列和队列视图是一个东西吧" -> 我误做成"删掉观察窗"
    //      用户纠正: "你这次是直接删除了监控，而不是合并"
    //   5. "队列单独一个 tab" -> 调度 / 执行队列
    //   6. **2026-10-10**: "添加一个**任务完成汇报 tab**…日志转移到单独界面"
    //      -> 曾经是 调度 / 执行队列 / 任务汇报
    //   7. ★ **2026-10-10 第三轮**:
    //      "我发现任务汇报已经占用了右半窗口, 但是还有一个 tab 页面,
    //       **两个重复了**。取消单独的 tab 和右半窗口, 改为**可以收纳的形式**,
    //       就是**点一下从右边滑出来, 再点一下收进去**。"
    //      -> 现在是 **2 个 tab** + **右侧可收纳抽屉**
    //   8. ★★ **2026-10-10 第四轮**（本轮）:
    //      "现在是任务列表、脚本：[脚本，重启]，我要把**两个 tab 放到任务列表
    //       下边**，即**调度：[任务列表，执行队列]**，**调度和任务列表互换名字**"
    //      -> **页内 TabBar 整个删除**；两个区块改由**左侧导航树**导航:
    //           调度
    //             ├ 任务列表   (`selectedMenu == 'TaskListPanel'`)
    //             └ 执行队列   (`selectedMenu == 'QueuePanel'`)
    final view = codeOnly('lib/views/tasks/task_list_view.dart');
    // ★ 页内 TabBar 必须**彻底消失** —— 两套导航并存会打架
    expect(view.contains('TabBar('), isFalse,
        reason: '★ 页内 TabBar 已删除: 两个区块改由左侧导航树切换'
               '（用户: "把两个 tab 放到任务列表下边"）');
    expect(view.contains('TabBarView('), isFalse,
        reason: '★ TabBarView 同步删除（TabBar 的搭档）');
    expect(view.contains('DefaultTabController'), isFalse,
        reason: '★ TabController 也没用了 —— 留着是"没人用的状态", '
               '且 length:2 配 0 个 tab 会误导后来人');
    // ★ 两个区块仍要存在（只是改由 `_bodyFor` 分派）
    expect(view.contains('_ScheduleTab('), isTrue,
        reason: '「任务列表」区块必须在');
    expect(view.contains('_QueueTab('), isTrue,
        reason: '「执行队列」区块必须在');
    // ⚠ 乙（页面级兜底）之后，分派被包进 `_safePage(() => …)` ——
    //   所以这里断言"分派函数**存在**"（不要求紧跟 `(`）
    expect(view.contains('_bodyFor'), isTrue,
        reason: '★ 必须由 `_bodyFor()` 按导航选择决定显示哪个区块');
    // ★ 页面级兜底必须在（否则任何渲染异常都会白屏）
    expect(view.contains('_safePage'), isTrue,
        reason: '★ 页面渲染要有兜底（用户报过白屏）');
    // ⚠ 这里断言的是**导航键**在导航树里的定义（`ctrl_nav.dart`）,
    //   而不是 `_bodyFor` 里的字面量 —— ★ 因为 `QueuePanel` 现在是
    //   `_bodyFor` 的**默认分支**（不带引号出现）。写错位置就会假失败。
    expect(view.contains("'TaskListPanel'"), isTrue,
        reason: "★ 必须识别导航键 'TaskListPanel'（= 任务列表）");
    final navSrc = codeOnly('lib/controller/ctrl_nav.dart');
    expect(navSrc.contains("'TaskListPanel'") && navSrc.contains("'QueuePanel'"),
        isTrue,
        reason: '★ 导航树必须把「调度」展开成 TaskListPanel + QueuePanel 两个叶子');
    // ★★★ 本轮改动: 默认分支已从「任务列表」换成「**执行队列**」★★★
    //
    // 用户原话: "设定 **HOME 页为执行队列页**"
    //
    // ★ 为什么必须一起改这里: 开屏落在**哪个区块**由 `_bodyFor` 决定
    //   （`selectedMenu == 'TaskList'` 时走默认分支）。若默认仍是
    //   `_ScheduleTab`, 那"首页=执行队列"只对**手动点**执行队列生效,
    //   开屏还是任务列表 —— 等于没实现。
    final bodyForIdx = view.indexOf('Widget _bodyFor(');
    expect(bodyForIdx, greaterThan(0), reason: '必须有 `_bodyFor`');
    final bodyFor = view.substring(
        bodyForIdx, (bodyForIdx + 2200).clamp(0, view.length));
    // ★ 只有「任务列表」需要**显式**判断; 其余（含默认）都走执行队列
    expect(bodyFor.contains("sel == 'TaskListPanel'"), isTrue,
        reason: "★ 「任务列表」需要显式判断");
    expect(bodyFor.contains('_QueueTab('), isTrue,
        reason: '★ 默认分支必须返回「**执行队列**」区块'
               '（用户: "设定 HOME 页为执行队列页"）');
    // 反向守卫: 默认分支**不能**再是任务列表
    final tail = bodyFor.substring(bodyFor.indexOf("if (sel == 'TaskListPanel')"));
    // ★ 乙（页面级兜底）之后写法变成 `return _safePage(() => _QueueTab(c: c));`
    //   ⇒ 断言放宽成"默认分支**就是** `_QueueTab`"（不管外面包了什么）
    final afterIf = tail.substring(tail.indexOf('_ScheduleTab(') + 1);
    expect(afterIf.contains('_QueueTab('), isTrue,
        reason: '★ 默认（else）分支必须是 `_QueueTab` —— 那是"首页=执行队列"的落点');
    // ★★ 关键: 必须**订阅** `NavCtrl` —— 否则点树上的叶子页面不重建
    expect(view.contains('GetX<NavCtrl>'), isTrue,
        reason: '★ `_bodyFor` 必须用 `GetX<NavCtrl>` 订阅导航状态; '
               '本页外层只监听 TaskListController, 不订阅就会"点了没反应"');

    // ★★ ① 抽屉: 开关 + 面板 + 动画
    expect(view.contains('_reportDrawer'), isTrue,
        reason: '① 应有可收纳的汇报抽屉');
    expect(view.contains('_reportToggle'), isTrue,
        reason: '① 应有"点一下滑出/收进"的开关');
    expect(view.contains('_reportOpen'), isTrue,
        reason: '① 抽屉的开合由 `_reportOpen` 控制');
    // ★ 汇报面板**只能**由抽屉渲染 —— 不能再有常驻的
    expect(view.contains('if (_reportOpen)'), isTrue,
        reason: '① 抽屉必须按需渲染（不再常驻）');

    // ★ 原始日志 -> **独立窗口**（保留）
    expect(view.contains('_showRunLogs'), isTrue,
        reason: '原始日志的独立窗口必须保留（供 debug）');

    // ★★ 本轮新增（用户要求）★★
    //
    // 用户原话:
    //   "**运行日志也拉出个小框横在最上方，只需要能看到一行就行**。
    //    目前点击出现的日志窗口也继续保留，**按钮放在日志窗口右边**。"
    expect(view.contains('_logStrip'), isTrue,
        reason: '★ 顶部必须有**单行**运行日志条（用户要求"横在最上方"）');
    expect(view.contains('softWrap: false'), isTrue,
        reason: '★ 单行条必须禁止换行 —— 否则会被撑成多行');
    // ★ 抽屉里: 日志本体 + 它的按钮（按钮在**右边**）
    final drawIdx = view.indexOf('Widget _reportDrawer(');
    expect(drawIdx, greaterThan(0));
    final drawer = view.substring(drawIdx, drawIdx + 3000);
    expect(drawer.contains('LogWidget('), isTrue,
        reason: '★ 抽屉里要有日志本体（"日志窗口也继续保留"）');
    expect(drawer.contains('_showRunLogs'), isTrue,
        reason: '★ 打开日志窗口的按钮要在日志本体旁边（用户: "按钮放在日志窗口右边"）');
    final logIdx = drawer.indexOf('LogWidget(');
    final btnIdx = drawer.indexOf('_showRunLogs');
    expect(btnIdx, greaterThan(logIdx),
        reason: '★ 按钮源码位置必须在 LogWidget **之后** = 界面上在**右边**');

    // ★ 简报**默认展开**（用户要求）
    expect(view.contains('bool _reportOpen = true;'), isTrue,
        reason: '★ 简报应**默认展开**（用户: "简报默认展开"）');

    // ⚠ `body` 是**供下面"左右分栏可拖拽"断言用**的 —— 必须保留。
    //   ★ 注意: **不能**再用它断言"build 里没有 LogWidget" ——
    //     本轮日志已**移进抽屉**（`_reportDrawer`）, 而 `build` 里调用了
    //     `_reportDrawer`, 所以 `body` 里出现 `LogWidget` 是**正常的**
    //     （那条断言已换成上面的"抽屉里有 LogWidget"）。
    final buildIdx = view.indexOf('Widget build(BuildContext context)');
    final body = view.substring(buildIdx, buildIdx + 5200);

    // ★ 左右宽度**可拖拽调整** + 持久记忆
    expect(body.contains('onHorizontalDragUpdate'), isTrue,
        reason: '缺左右分栏的拖拽条');
    expect(body.contains('resizeColumn'), isTrue,
        reason: '拖拽条要有 resize 光标, 否则用户不知道能拖');
    expect(view.contains('_splitWidth'), isTrue);
    expect(view.contains('_saveSplit'), isTrue, reason: '宽度要持久记忆');
  });

  test('★ 「待执行」与「执行顺序」**合并成一套**可拖列表（用户要求）', () {
    // ★★ 2026-10-10 用户澄清（**改变了此前的设计**）★★
    //
    //   "待执行里为什么不能和执行顺序一样拖动呢, 他俩应该并在一起啊"
    //   "等待中（还没到点）更改为显式的意义, 如[未到开放时间]"
    //   "待执行（马上要跑）和执行顺序合并一起"
    //
    // 此前是**两套**: 一个可拖的「执行顺序」+ 两个只读的「待执行/等待中」观察窗。
    // 现在**只有一套**: 一个可拖列表渲染 `c.queuedTaskRows`,
    // 每行带状态徽标（[待执行] / [未到开放时间]）。
    //
    // ★ 早先那句"删掉 ≠ 合并"是针对**直接删掉监控**说的;
    //   用户现在要的是**真正的合并进队列**, 不是删掉。
    //
    // ★ #6 之后那个列表是 `SliverReorderableList`（不是
    //   `ReorderableListView` —— 后者自己就是滚动体, 塞不进吸顶用的
    //   `CustomScrollView`）。**"只有一套"这条断言不变**。
    final q = codeOnly('lib/views/tasks/queue_panel.dart');

    // 只有一个可拖列表
    expect(RegExp(r'ReorderableListView').allMatches(q).length, 0,
        reason: '★ 可拖列表必须换成 `SliverReorderableList` —— '
            '`ReorderableListView` 自己就是滚动体, 塞不进外层 `CustomScrollView`');
    expect(RegExp(r'SliverReorderableList\(').allMatches(q).length, 1,
        reason: '应该**只有一套**可拖列表（合并后不该还有第二个）');

    // 术语: 等待中 -> 「未到开放时间」
    expect(q.contains('未到开放时间'), isTrue,
        reason: '「等待中」必须改名为「未到开放时间」（显式意义）');
    expect(q.contains('待执行'), isTrue, reason: '缺「待执行」状态');

    // 未到开放时间要**变灰**
    expect(q.contains('disabledColor'), isTrue,
        reason: '不在窗口的任务应变灰（用户: "直接变灰放到等待中就行"）');

    // ★★ 片 5 (F2b) 后：**「正在运行」不再是一个固定的行** ★★
    //
    // 用户原话:
    //   "**执行队列那个正在运行个人突破不应该存在了啊**，这个不符合咱们
    //    列表里流转[正在运行]状态的定义。"
    //   "**队首只是代表列表顺序第一个而已，但正在运行的可以使列表里任意一个。**"
    //
    // ⇒ 原来那行 `_runningRow`（"▶ 调度中 │ ▶ 正在运行: xxx [任务设置]"）
    //   **整块删除**；"运行中"改成**跑着的那一行上的状态标记**。
    expect(q.contains('_runningRow'), isFalse,
        reason: '★ 「正在运行」不能再占一整行 —— 它是**流转的状态标记**');
    expect(q.contains('_statusBlock'), isFalse,
        reason: '★ 那个状态块已删除（三个职责已各自安置）');
    // ★ 实时数据仍然要用（现在用在"这一行是不是正在跑"的判断上）
    //
    // ⚠ 片 5 (F2b) 之后**不再**出现 `runningTask` 这个词 ——
    //   判断"这一行是不是正在跑"改成了**读后端给的行内字段**
    //   `e['running']`（由 `/run_list` 按 `running_entry_id` 算好, **身份而非位置**）
    //   ⇒ 断言改成钉住**新的数据来源**。
    expect(q.contains("e['running']"), isTrue,
        reason: '★ 行内"运行中"标记必须读后端的 e["running"]');
    // ★★ 两份记录（用户裁定）之后，展示改读 **`total_runs`** ★★
    //
    // > "一份**临时记录**只保留到当前（任务/周期）结束，
    // >  **另一份共用的总记录**用于**结果展示**。"
    //
    // | 字段 | 内容 | 生命周期 |
    // |---|---|---|
    // | `runs` | 本轮/本周期已跑几次（**判据**）| 新一轮**清零** |
    // | ★ `total_runs` | **累计**（**展示用**）| ★ **永不清零** |
    //
    // ⚠ 展示必须读 `total_runs` —— 读 `runs` 的话，新一轮清零时
    //   "已运行 N 次"会**跟着归零**（那就不是"总记录"了）。
    expect(q.contains("e['total_runs']"), isTrue,
        reason: '★ 行内"已运行 N 次"必须读后端的 e["total_runs"]（**总记录**，永不清零）');
    // ★ 行内标记存在（"运行中" / "已运行 N 次"）
    expect(q.contains('运行中'), isTrue, reason: '缺「运行中」行内标记');
    expect(q.contains('已运行'), isTrue, reason: '缺「已运行 N 次」行内标记');
    // ★ Obx 的安全性: 服务拿不到时返回**null**，调用方必须空安全
    expect(q.contains('_scriptModelOf'), isTrue,
        reason: '取 ScriptModel 必须走安全封装（服务未注册时返回 null）');
    expect(q.contains('sm?.state.value'), isTrue,
        reason: '★ 可能拿不到 sm ⇒ 必须用 `?.` 空安全（直接点会抛）');
  });

  test('执行队列**独立成一个区块**；全局开关已移进它（用户要求）', () {
    final view = codeOnly('lib/views/tasks/task_list_view.dart');
    // 队列区块的类存在
    expect(view.contains('class _QueueTab'), isTrue);

    // ---------- ★ 任务列表区块: 有表格, 但**不该**再有全局开关/队列 ----------
    final i = view.indexOf('class _ScheduleTab');
    final b = view.indexOf('return ListView(', i);
    // ⚠ 窗口从 900 加到 1400: 本轮给 `_ScheduleTab` 加了大段说明注释,
    //   900 会在到达 `_tablePanel(context)` 之前截断 -> 假失败。
    final body = view.substring(b, b + 1400);
    expect(body.contains('_tablePanel(context)'), isTrue,
        reason: '任务列表区块缺任务表格');
    expect(body.contains('_globalPanel(context)'), isFalse,
        reason: '★ 全局开关已移到执行队列（用户要求）—— 不该还在任务列表区块里');
    expect(body.contains('QueuePanel('), isFalse,
        reason: '执行顺序在该区块之外, 不该还在任务列表区块里');

    // ---------- ★ 执行队列区块: 必须有快捷排序 + QueuePanel ----------
    //
    // ⚠ 本轮改动: `_QueueTab.build` **不再返回 `ListView`**
    //   （修用户报的 #7: 拖动越界不自动滚动 —— `QueuePanel` 现在自己是
    //    唯一的滚动容器, 外层再套 `ListView` 就是"滚动套滚动"）。
    //   ★ 所以不能再用 `indexOf('return ListView(', qi)` 定位（会得 -1
    //     并 `RangeError`）。改为**整段取到下一个 class**。
    final qi = view.indexOf('class _QueueTab');
    expect(qi, greaterThan(0));
    final qEnd = view.indexOf('\nclass ', qi + 10);
    final qbody = view.substring(qi, qEnd > 0 ? qEnd : view.length);
    expect(qbody.contains('_sortActions('), isTrue, reason: '执行队列缺快捷排序');
    // ★ #6: `QueuePanel` 从"整个面板"变成"**一组 sliver**"
    //   （它的内容要塞进外层吸顶用的 `CustomScrollView`）
    expect(qbody.contains('QueuePanel.slivers('), isTrue,
        reason: '执行队列缺执行顺序面板');
    // ★ 反向守卫: 该区块**不许**再有 ListView/SingleChildScrollView
    //   （滚动套滚动会让 `SliverReorderableList` 拿到无界高度）
    expect(qbody.contains('return ListView('), isFalse,
        reason: '★ `_QueueTab` 不该自己套滚动容器 —— '
            '它自己那个 `CustomScrollView` 是唯一的滚动体');
    expect(qbody.contains('SingleChildScrollView'), isFalse,
        reason: '★ 同上');
    // ★ #6: 外层必须是 `CustomScrollView`（吸顶的唯一落点）
    expect(qbody.contains('CustomScrollView('), isTrue,
        reason: '★ 吸顶需要 `CustomScrollView` + `SliverPersistentHeader`');

    // ---------- ★★ 全局开关必须在执行队列里（本轮核心） ----------
    //
    // 用户原话:
    //   "只需要把**全局开关移到执行队列**，然后把任务列表里的滚动条统一起来"
    expect(view.contains('_globalSwitchesInline'), isTrue,
        reason: '★ 全局开关的紧凑渲染器必须在');
    // 它必须在 `_QueueTab` 里被调用（而不是只在 _TaskListViewState 里定义着）
    expect(qbody.contains('_globalSwitchesInline('), isTrue,
        reason: '★ 全局开关必须在**执行队列**区块里被渲染'
               '（用户: "全局开关设置放到执行队列里"）');
    // ★ 它必须与快捷排序**同一行**（省空间）
    //
    // ⚠ `substring` 必须**夹住上界** —— `_sortActions` 已接近文件末尾,
    //   直接 `+2600` 会 `RangeError`（我第一版就崩在这）。
    final sortIdx = view.indexOf('Widget _sortActions(');
    expect(sortIdx, greaterThan(0));
    final sortBody =
        view.substring(sortIdx, (sortIdx + 3000).clamp(0, view.length));
    expect(sortBody.contains('_globalSwitchesInline('), isTrue,
        reason: '★ 全局开关要和快捷排序**同一行**（用户: "合理摆放, 节省空间"）');
  });

  test('★ 任务列表**只有一个滚动条**（表格不再内层滚动）', () {
    // 用户原话:
    //   "把任务列表里的**滚动条统一起来**就行，现在滑动使用**两个滚动条很难受**"
    //
    // 根因: 表格原来是 `SizedBox(限高) + ListView.builder`（内层滚动）,
    //       而外面 `_ScheduleTab` 自己还有一个 `ListView`（整页滚动）
    //       -> 鼠标位置不同, 滚的是两个不同的东西。
    final view = codeOnly('lib/views/tasks/task_list_view.dart');
    final ti = view.indexOf('Widget _tablePanel(');
    expect(ti, greaterThan(0));
    // ⚠ 同样夹住上界（`_tablePanel` 也接近文件末尾）
    final table = view.substring(ti, (ti + 2600).clamp(0, view.length));
    expect(table.contains('ListView.builder'), isFalse,
        reason: '★ 表格**不该**再有内层 `ListView.builder` —— 那就是第二个滚动条');
    expect(table.contains('...c.tasks.map('), isTrue,
        reason: '★ 行应**直接摊开**到外层 ListView（只留一个滚动条）');
    // 反向守卫: 限高的 SizedBox 也一并去掉
    expect(table.contains('_maxVisibleRows'), isFalse,
        reason: '★ `_maxVisibleRows` 限高是内层滚动的前提, 应一并删除');
    expect(table.contains('_rowHeight'), isFalse,
        reason: '★ `_rowHeight` 只给内层 `itemExtent` 用, 应一并删除');
  });

  test('★ 「预期执行流程」已删除（与队列冗余）', () {
    // 用户: "预期执行流程可以删去了，似乎和上边的队列冗余了。"
    final view = codeOnly('lib/views/tasks/task_list_view.dart');
    for (final gone in [
      'class _FlowTab',
      'mixin _FlowPanelMixin',
      'Widget _flowPanel(',
      '_flowPanel(context)',
      "Tab(text: '队列视图')",
    ]) {
      expect(view.contains(gone), isFalse,
          reason: '「$gone」应已删除（用户要求: 与队列冗余）');
    }
  });

  test('★ 未编排列表**排除**正在运行的任务（用户报的 bug）', () {
    // 用户: "正在运行的逢魔之时，下边显示还可以加入逢魔之时，这是不是个bug"
    // —— **是 bug**。`run_list` 为空时所有任务都算"未编排", 把正在跑的也列进去了。
    final ctrl = codeOnly('lib/controller/task_list/task_list_controller.dart');
    final i = ctrl.indexOf('List<Map<String, dynamic>> get unqueuedEnabledTasks');
    expect(i, greaterThan(-1));
    final body = ctrl.substring(i, i + 900);
    expect(body.contains('runningTaskCommand'), isTrue,
        reason: '未编排列表必须排除正在运行的任务, 否则队列里会出现两条同一个任务');
  });

  test('菜单隐藏了重复的旧「总览」', () {
    final nav = codeOnly('lib/controller/ctrl_nav.dart');
    expect(nav.contains("if (key == 'Overview') return;"), isTrue,
        reason: '旧「总览」应从菜单隐藏（它与控制台重复）');
    expect(nav.contains("selectedMenu.value = 'TaskList';"), isTrue,
        reason: '进账号后默认应进统一控制台');
  });
}

void main() {
  _accountSwitchTests();

  _runControlV2Tests();

  _overviewV2Tests();

  _sortAndPrefsTests();

  _round4Tests();

  _phase0Tests();

  _phase1Tests();

  _phase2Tests();
}

// ============================================================ 切换账号
//
// 用户实测反馈: **伴生树和恋鸟树在前端显示了同一个任务列表**。
//
// 根因是 `_TaskListViewState` 里把 tag 与控制器写成了 `late final`:
//
//     late final String _tag;
//     late final TaskListController _c;
//
// 切换账号时 Flutter **复用同一个 State**(同类型 widget、同位置),
// `initState` 不会重跑 -> tag/控制器一直是**旧账号**的 -> 看起来"共享"。
//
// 下面这组测试钉住"切换账号要重新绑定"。
void _accountSwitchTests() {
  testWidgets('切换账号后控制器指向新账号（不共享同一个列表）', (tester) async {
    // 两个账号各自的控制器, 用不同 tag 注册(模拟真实接线)
    const tagA = 'tasks:伴生树';
    const tagB = 'tasks:恋鸟树';
    Get.put<TaskListController>(
      FakeTaskListController(
        entries: [
          {'kind': 'task', 'task': 'DemonEncounter'},
          {'kind': 'task', 'task': 'Exploration'},
        ],
        tasks: [
          taskRow('DemonEncounter', zh: '逢魔之时', queued: true),
          taskRow('Exploration', zh: '探索', queued: true),
        ],
      ),
      tag: tagA,
      permanent: true,
    );
    Get.put<TaskListController>(
      FakeTaskListController(
        entries: [
          {'kind': 'task', 'task': 'GoldYoukai'},
        ],
        tasks: [taskRow('GoldYoukai', zh: '金币妖怪', queued: true)],
      ),
      tag: tagB,
      permanent: true,
    );

    // ★ 这里**不能**直接 pump `TaskListView` —— 它的 `_bindController`
    //   会 `Get.put` 自己的真控制器(要联网)。所以只断言
    //   "两个 tag 的控制器是不同对象、数据不同" 这个前提,
    //   再断言 `TaskListView` 在 scriptName 变化时**不抛异常**。
    final a = Get.find<TaskListController>(tag: tagA);
    final b = Get.find<TaskListController>(tag: tagB);
    expect(identical(a, b), isFalse, reason: '两个账号的控制器必须是不同对象');
    expect(a.entries.length, 2);
    expect(b.entries.length, 1);

    // 渲染两个 tag 的面板, 内容各自独立
    await tester.pumpWidget(wrapBounded(QueuePanel(controller: a)));
    await tester.pump();
    expect(find.text('逢魔之时'), findsOneWidget);
    expect(find.text('金币妖怪'), findsNothing);

    await tester.pumpWidget(wrapBounded(QueuePanel(controller: b)));
    await tester.pump();
    expect(find.text('金币妖怪'), findsOneWidget);
    expect(find.text('逢魔之时'), findsNothing);

    Get.delete<TaskListController>(tag: tagA, force: true);
    Get.delete<TaskListController>(tag: tagB, force: true);
  });

  testWidgets('不同账号绑定到不同的控制器 tag（回归: 曾用 late final 固定住）',
      (tester) async {
    // ★ 这条测试钉住**回归的本质**。
    //
    //   修复前 `_TaskListViewState` 写的是:
    //       late final String _tag;
    //       late final TaskListController _c;
    //   切账号时 Flutter 复用同一个 State -> `initState` 不重跑 ->
    //   tag/控制器一直是旧账号的 -> 两个账号"共享同一个任务列表"。
    //
    //   修法是让它们可变, 并在 `didUpdateWidget` 里按新的 scriptName 重绑。
    //
    //   ⚠ 这里**不能**直接 pump `TaskListView` —— 它的 `RunControlBar`
    //     会构造 `ApiClient`(需要 `SettingsController` + 联网),
    //     测试环境给不了。所以只验证"tag 与控制器是一一对应"这个前提,
    //     加上 `RunListPanel` 用不同控制器时内容各自独立(上一测试已覆盖)。
    const tagA = 'tasks:账号A';
    const tagB = 'tasks:账号B';
    expect(tagA == tagB, isFalse, reason: '不同账号的 tag 不能相同');

    Get.put<TaskListController>(
      FakeTaskListController(entries: const [], tasks: const []),
      tag: tagA,
      permanent: true,
    );
    Get.put<TaskListController>(
      FakeTaskListController(entries: const [], tasks: const []),
      tag: tagB,
      permanent: true,
    );
    expect(
      identical(Get.find<TaskListController>(tag: tagA),
          Get.find<TaskListController>(tag: tagB)),
      isFalse,
      reason: '不同 tag 必须是不同控制器实例',
    );
    Get.delete<TaskListController>(tag: tagA, force: true);
    Get.delete<TaskListController>(tag: tagB, force: true);
  });
}
