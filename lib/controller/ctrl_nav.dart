part of nav;

class NavCtrl extends GetxController {
  final navNameList = <String>['Home', 'oas1'].obs; // 列表
  // ★★★ 启动默认页 = **执行队列**（用户裁定）★★★
  //
  // 用户原话:
  // > "设定 **HOME 页为执行队列页**"
  //
  // ★ 落地方式: 启动就选中**第一个账号**(`selectedIndex = 1`) +
  //   菜单 `'TaskList'`（导航树里的「**调度**」）。
  //   ★ 而「调度」区块的**默认显示**是「执行队列」（见
  //     `TaskListView._bodyFor` 的默认分支）-> 于是开屏就是执行队列。
  //
  // ⚠ 为什么**不**改 `'Home'` 菜单本身: `Home` 是「主页」导航项,
  //   它下面还有「更新器 / 工具」两个子页; 把它整个换成执行队列会
  //   连带弄丢那两个入口。★ 改"默认选中谁"更准确、副作用更小。
  //
  // ⚠ 初始 `selectedIndex` 用 0 而非 1: `navNameList` 此刻只有占位的
  //   `['Home','oas1']`, 真正的账号列表要等 `onInit` 拉取后才就位。
  //   ★ 索引越界会让 `switchScript` 直接抛异常, 所以"默认进账号页"
  //   这件事放在 `onInit` 末尾做（那时列表已是真实的）。
  final selectedIndex = 0.obs;
  final selectedScript = 'Home'.obs; // 当前选中的名字
  final selectedMenu = 'Home'.obs; // 当前选中的第二级名字

  // 二级菜单控制
  final isHomeMenu = true.obs;
  var homeMenuJson = <String, List<String>>{
    'Home': [],
    'Updater': [],
    'Tool': [],
  }.obs;
  var scriptMenuJson = <String, List<String>>{}.obs;

  @override
  Future<void> onInit() async {
    // ★★ 翻译：**从后端拉取**（单一数据源），不再推自己那份 ★★
    //
    // 原实现（已删）:
    //     await ApiClient().putChineseTranslate();          // 推 746 条
    //     final additionalTranslate = await getAdditionalTranslate();
    //     ...saveAdditionalTranslate(additionalTranslate);  // 读另一个文件
    //
    // 后果: 后端 `module/config/i18n/zh-CN.json` 有 1090 条,
    //      被前端 746 条**整份覆盖** -> **每次启动丢 344 条**,
    //      翻译永远补不齐。
    //
    // 现在: 后端权威, 前端只读。本地缓存仍会读（旧版本残留），
    //      但后端值优先级更高（在后面覆盖）。
    final api = ApiClient();
    final localeService = Get.find<LocaleService>();
    await localeService.loadFromBackend(api);
    // 额外词条（assets/i18n）—— 后端端点已把两层合并, 这里保留是为兼容旧后端
    final additionalTranslate = await api.getAdditionalTranslate();
    if (additionalTranslate.isNotEmpty) {
      await localeService.saveAdditionalTranslate(additionalTranslate);
    }

    navNameList.value = await api.getConfigList();
    homeMenuJson.value = await api.getHomeMenu();
    scriptMenuJson.value = await api.getScriptMenu();

    // 加入「任务列表」入口。
    //
    // ★ 必须是**独立的顶层键**(值用空列表), 两种错误做法都会出问题:
    //
    //   1. `items.insert(0, 'TaskList')` 插进**每个组** ->
    //      8 个组各出现一个「任务列表」-> 界面上看就是"重了"
    //   2. 用某个组名当键(如塞进已有的 'Overview') -> 与既有「总览」冲突
    //
    // 用 `'TaskList': []` 的形式 —— 与后端已有的 `'Overview': []` 同构,
    // 而 `useablemenus` 的 `value.isNotEmpty ? value : [key]` 会把它
    // 正确解析成菜单项 `'TaskList'`。
    //
    // ★★ 现在它是**唯一的调度控制台**（用户要求合并, 不要两套监控）★★
    //
    //   控制台已包含: 实时监控（调度器/运行中/待执行/等待中）+
    //   任务表格（次数/排序/筛选/优先级/预期耗时/运行记录）+
    //   执行顺序（拖拽）+ 全局设置 + 运行控制条 + 日志。
    //
    //   所以旧「总览」是**多余的** —— 它的内容被完全覆盖,
    //   留着只会让人在两个页面之间犹豫（"我该看哪个?"）。
    //
    //   ⚠ 旧「总览」的**视图文件保留**（`views/overview/`）——
    //     里面的 `OverviewController` 还承担着历史日志路由
    //     （`ScriptService` 会 `Get.isRegistered<OverviewController>`）,
    //     而 `TaskItemModel` 是 `script_model.dart` 的依赖。
    //     删除它们要连带重构两处, 风险大于收益; 从菜单隐藏即可。
    //
    // ★★★ 树结构（用户裁定）★★★
    //
    // 用户原话:
    //   "现在是任务列表、脚本：[脚本，重启]，我要把**两个 tab 放到任务列表
    //    下边**，即**调度：[任务列表，执行队列]**，**调度和任务列表互换名字**"
    //
    // 所以:
    //     调度              <- ★ 导航树入口（不是叶子: 它下面还有两个面板）
    //       ├ 任务列表       <- 原页内「调度」tab（Excel 式扁平表格）
    //       └ 执行队列       <- 原页内「执行队列」tab
    //     脚本
    //       重启
    //
    // ★ 内部键仍是 `'TaskList'`（`content.dart` 的分派键 + 防崩白名单都用它）,
    //   **只改显示名** —— 显示名走 `.tr` 翻译（`_cn_menu`）。
    // ★ 两个子项 `TaskListPanel` / `QueuePanel` 是**面板标识**,
    //   必须同时在防崩白名单里（见 `switchContent` 的注释）。
    final menu = <String, List<String>>{
      // 放最前: "看全局并调度"比"调某个任务的参数"更常用
      'TaskList': const ['TaskListPanel', 'QueuePanel'],
    };
    scriptMenuJson.forEach((key, items) {
      // ★ **隐藏后端给的 `'Overview'` 菜单项** —— 见上面的说明:
      //   它的内容已被统一控制台完全覆盖, 同时存在两个"总览"会让人犹豫。
      if (key == 'Overview') return;
      menu[key] = items;
    });
    scriptMenuJson.value = menu;

    // ★★★ 启动默认页 = **执行队列**（用户裁定: "设定 HOME 页为执行队列页"）★★★
    //
    // ★ 放在**这里**（`onInit` 末尾）而不是字段初始化处:
    //   `navNameList` 此刻才拉到**真实**账号列表, 这时 `switchScript(1)`
    //   才安全（★ 索引越界会直接抛异常）。
    //
    // ★ 为什么用 `switchScript(1)` 而不是手写几个 `.value = ...`:
    //   它已经是一条**完整的切换路径**（设菜单 + 设脚本 + 注册控制器 +
    //   校验 `useablemenus`）, 复用它避免"改了默认页却漏了某一步"。
    //
    // ⚠ 只有在**真的有账号**（长度 > 1）时才切 ——
    //   没有配置时列表只有 `['Home']`, 切过去会越界。
    try {
      if (navNameList.length > 1) {
        await switchScript(1);
        printInfo(info: '启动默认页: 第一个账号 -> 调度 -> 执行队列');
      }
    } catch (exc) {
      // ★ 默认页切失败**绝不能**让启动崩 —— 退回首页即可
      printInfo(info: '默认进执行队列失败($exc), 保持首页');
    }

    super.onInit();
  }

  @override
  Future<void> onReady() async {
    useablemenus;
    super.onReady();
  }

  Future<void> switchScript(int idx) async {
    if (idx == selectedIndex.value &&
        navNameList[idx] == selectedScript.value) {
      return;
    }
    // 切换二级菜单的
    if (idx == 0) {
      selectedMenu.value = 'Home';
      isHomeMenu.value = true;
    } else {
      // ★ 默认进**统一控制台**（`TaskList`）而不是旧「总览」。
      //
      //   控制台现在包含了监控 / 任务表格 / 执行顺序 / 日志 ——
      //   是日常真正要待的地方。旧「总览」仍保留（它更轻, 只有观察窗）,
      //   但不再是默认页。
      selectedMenu.value = 'TaskList';
      isHomeMenu.value = false;
    }

    // 切换导航栏的
    selectedIndex.value = idx;
    // ignore: invalid_use_of_protected_member
    selectedScript.value = navNameList[idx];

    // 注册控制器的
    if (!Get.isRegistered<OverviewController>(tag: selectedScript.value) &&
        idx != 0) {
      Get.put(
          tag: selectedScript.value,
          permanent: true,
          OverviewController(name: selectedScript.value));
    }
  }

  // 获取能够有内容的二级菜单
  List<String> get useablemenus {
    final result = <String>[];
    void collectMenus(Map<String, List<String>> menuMap) {
      menuMap.forEach((key, value) {
        result.addAll(value.isNotEmpty ? value : [key]);
      });
    }

    collectMenus(homeMenuJson);
    collectMenus(scriptMenuJson);
    if (kDebugMode) {
      printInfo(info: 'useablemenus = $result');
    }
    return result;
  }

  void switchContent(String menu) {
    if (!useablemenus.contains(menu)) {
      return;
    }
    selectedMenu.value = menu;

    // args的切换
    //
    // ★ 'TaskList' 必须在这里提前返回 —— 它**不是一个任务**, 后端没有
    //   `/{script}/TaskList/args`(会返回空对象 `{}`), 而 `loadGroups`
    //   拿到空对象会崩 -> 界面 500。
    //   它的页面由 `views/layout/content.dart` 里的 `[name, 'TaskList']` 分派。
    //
    // ★★ 同理, 导航树里「调度」下的两个**子面板**
    //    `TaskListPanel` / `QueuePanel` 也**不是任务** —— 它们是
    //    `TaskListView` 页内的两个区块标识。★ 少了它们, 点一下就会去请求
    //    `/{script}/任务列表/args` -> 后端返回 `{}` -> **界面崩**。
    if (['Home', 'Overview', 'Updater', 'Tool', 'TaskList',
         'TaskListPanel', 'QueuePanel'].contains(menu)) {
      return;
    }
    if (selectedScript.value == 'Home') {
      return;
    }
    final argsController = Get.find<ArgsController>();
    argsController.loadGroups(config: selectedScript.value, task: menu);
  }

  /// **点任务表格的某一行** -> 跳到那个任务的设置页。
  ///
  /// ## 为什么不直接用 `switchContent`
  ///
  /// `switchContent` 开头有 `useablemenus.contains(menu)` 的守卫 ——
  /// 侧边栏里只列出**当前账号启用/常用**的任务, 所以点一个不在
  /// 侧边栏里的任务会被静默忽略（用户看到"点了没反应"）。
  ///
  /// 这里**绕过白名单**, 因为"用户明确点了这一行"就是最强的意图表达。
  ///
  /// ★ 仍然要做 `TaskList` 的防呆: 它不是一个任务, 后端没有
  ///   `/{script}/TaskList/args`, `loadGroups` 会崩。
  void openTaskSettings(String task) {
    if (task.isEmpty) return;
    // ★ 与 `switchContent()` **同一份**防崩白名单（见那里的注释）——
    //   `TaskListPanel` / `QueuePanel` 是面板标识, **不是任务名**。
    if (['Home', 'Overview', 'Updater', 'Tool', 'TaskList',
         'TaskListPanel', 'QueuePanel'].contains(task)) {
      return;
    }
    if (selectedScript.value == 'Home') return;
    selectedMenu.value = task;
    final argsController = Get.find<ArgsController>();
    argsController.loadGroups(config: selectedScript.value, task: task);
  }

  Future<void> addConfig(String newName, String templateName) async {
    navNameList.value = await ApiClient().configCopy(newName, templateName);
    Get.find<ScriptService>().addScriptModel(newName);
  }

  Future<void> deleteConfig(String name) async {
    final int idx = navNameList.indexOf(name);
    if (idx == -1) return;
    // delete remote config
    if (!await ApiClient().deleteConfig(name)) return;
    // force delete controller
    if (Get.isRegistered<OverviewController>(tag: name)) {
      try {
        Get.delete<OverviewController>(tag: name, force: true);
      } catch (e) {
        // ignore
      }
    }
    // delete local config
    navNameList.removeAt(idx);
    Get.find<ScriptService>().deleteScriptModel(name);

    if (idx < selectedIndex.value) {
      // deleted script is before selected script, change selected script index
      selectedIndex.value -= 1;
    } else if (idx == selectedIndex.value) {
      // deleted script is selected
      if (idx < navNameList.length) {
        // not end script, select next script
        switchScript(idx);
      } else {
        // end script, select previous script
        switchScript(idx - 1);
      }
    }
  }

  Future<void> renameConfig(String oldName, String newName) async {
    final int idx = navNameList.indexOf(oldName);
    if (idx == -1) return;
    // rename remote config
    if (!await ApiClient().renameConfig(oldName, newName)) return;
    // rename local config
    navNameList[idx] = newName;
    // force delete controller and register new one
    try {
      // when delete, ws can auto close, so force delete controller
      Get.delete<OverviewController>(tag: oldName, force: true);
      Get.find<ScriptService>().deleteScriptModel(oldName);
    } catch (_) {}
    // reactive new controller on current idx
    if (idx == selectedIndex.value) {
      switchScript(idx);
      return;
    }
    Get.put(tag: newName, permanent: true, OverviewController(name: newName));
    Get.find<ScriptService>().addScriptModel(newName);
  }
}
