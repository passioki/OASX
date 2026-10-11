import 'package:flutter_nb_net/flutter_net.dart';
import 'package:get/get.dart';
import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';
import 'package:dio_cache_interceptor_file_store/dio_cache_interceptor_file_store.dart';
import 'package:oasx/api/api_interceptor.dart';

import 'package:oasx/component/dio_http_cache/dio_http_cache.dart';
import 'package:oasx/config/translation/i18n.dart';
import 'package:oasx/config/translation/i18n_content.dart';
import 'package:oasx/utils/check_version.dart';
import 'package:oasx/config/constants.dart';
import 'package:oasx/controller/settings.dart';
import './home_model.dart';
import './update_info_model.dart';

/// common result
class ApiResult<T> {
  final T? data;
  final String? error;
  final int? code;

  bool get isSuccess => data != null;

  ApiResult.success(this.data)
      : error = null,
        code = null;

  ApiResult.failure(this.error, [this.code]) : data = null;
}

class ApiClient {
  // 单例
  static final ApiClient _instance = ApiClient._internal();
  factory ApiClient() => _instance;
  ApiClient._internal() {
    NetOptions.instance
        .setConnectTimeout(const Duration(seconds: 3))
        .enableLogger(false)
        .addInterceptor(DioCacheInterceptor(
            options: CacheOptions(
          store:
              FileCacheStore(Get.find<SettingsController>().temporaryDirectory),
          policy: CachePolicy.request,
          hitCacheOnErrorExcept: [401, 403],
          maxStale: const Duration(days: 7),
          priority: CachePriority.normal,
          cipher: null,
          keyBuilder: CacheOptions.defaultCacheKeyBuilder,
          allowPostMethod: false,
        )))
        .addInterceptor(ApiInterceptor())
        .create();
  }

  // http://$address 地址的前缀开头
  String address = '127.0.0.1:22288';

  void setAddress(String address) {
    this.address = address;
    NetOptions.instance.dio.options.baseUrl = address;
  }

  /// common request method
  ///
  /// [silent] = true 时**网络失败只打日志、不弹提示**。
  /// 给"启动时轮询等后端起来"用(见 `LoginController.ensureBackendThenAutoLogin`):
  /// 后端冷启动要 10-30 秒, 每 500ms 探一次, 若每次都弹就成刷屏了。
  Future<ApiResult<T>> request<T>(Future<Result<T>> Function() apiFn,
      {bool silent = false}) async {
    try {
      final res = await apiFn();
      return res.when(
        success: (data) => ApiResult.success(data),
        failure: (msg, code) {
          printError(info: '${I18n.network_error_code}: $msg | $code'.tr);
          if (!silent) {
            switch (code) {
              case 403:
                break;
              case 404:
                showNetErrCodeSnackBar(I18n.network_not_found.tr, code);
                break;
              default:
                showNetErrCodeSnackBar(msg, code);
                break;
            }
          }
          return ApiResult.failure(msg, code);
        },
      );
    } catch (e) {
      printError(info: '${I18n.network_error.tr}: $e');
      if (!silent) {
        showNetErrSnackBar();
      }
      return ApiResult.failure(e.toString());
    }
  }

// ----------------------------------   服务端地址测试   ----------------------------------
  /// 探测后端是否可达(`GET /test`)。
  ///
  /// [silent] = true 时失败不弹提示(见 [request])。
  Future<bool> testAddress({bool silent = false}) async {
    final res = await request(() => get('/test'), silent: silent);
    return res.isSuccess && res.data == 'success';
  }

  Future<bool> killServer() async {
    final res = await request(() => get('/home/kill_server'));
    return res.isSuccess && res.data == 'success';
  }

// ----------------------------------   杂接口  --------------------------------------------
  Future<bool> notifyTest(String setting, String title, String content) async {
    final res = await request(() => post(
          '/home/notify_test',
          queryParameters: {
            'setting': setting,
            'title': title,
            'content': content
          },
        ));
    if (res.isSuccess && res.data == true) {
      Get.snackbar(I18n.notify_test_success.tr, '', snackPosition: SnackPosition.BOTTOM);
      return true;
    }
    Get.snackbar(I18n.notify_test_failed.tr, res.data.toString(), snackPosition: SnackPosition.BOTTOM);
    return false;
  }

  Future<GithubVersionModel> getGithubVersion() async {
    final res = await request(() => get(
          updateUrlGithub,
          options: buildCacheOptions(const Duration(days: 7)),
          decodeType: GithubVersionModel(),
        ));
    return res.isSuccess ? res.data : GithubVersionModel();
  }

  Future<ReadmeGithubModel> getGithubReadme() async {
    final res = await request(() => get(
          readmeUrlGithub,
          options: buildCacheOptions(const Duration(days: 7),
              options: Options(extra: {"cache": true})),
          decodeType: ReadmeGithubModel(),
        ));
    return res.isSuccess ? res.data : ReadmeGithubModel();
  }

  Future<UpdateInfoModel> getUpdateInfo() async {
    final res = await request(() => get(
          '/home/update_info',
          decodeType: UpdateInfoModel(),
        ));
    return res.isSuccess ? res.data : UpdateInfoModel();
  }

  Future<String?> getExecuteUpdate() async {
    final res = await request(() => get('/home/execute_update'));
    if (res.isSuccess) {
      showDialog('Update', res.data.toString());
      return res.data;
    }
    return res.data;
  }

  Future<Map?> exportDiagnostic({String configName = ''}) async {
    final res = await request(
        () => get('/home/export_diagnostic', queryParameters: {'config_name': configName}));
    if (res.isSuccess && res.data is Map) {
      return res.data as Map;
    }
    return null;
  }

  /// **权威全量**中文翻译表（后端 `module/config/i18n/zh-CN.json` + 额外词条）。
  ///
  /// ★ 这是**单一数据源** —— 启动时**拉取**它，而不是推自己那份。
  ///
  /// ## 为什么改了方向（踩过的坑）
  ///
  /// 原实现是 `putChineseTranslate()`：把前端 `i18n_cn.dart` 的 746 条
  /// **整份覆盖**到后端。而后端那份有 1090 条 —— 于是**每次启动丢 344 条**，
  /// 翻译永远补不齐。现在改成"后端权威、前端拉取"。
  Future<Map<String, String>> getChineseTranslate() async {
    final res = await request(() => get('/home/chinese_translate'));
    if (!res.isSuccess || res.data == null) return {};
    try {
      return (res.data as Map).cast<String, String>();
    } catch (_) {
      return {};
    }
  }

  /// ⚠ 已**降级**为"增量合并"（后端只补它没有的 key，不会删）。
  ///
  /// 正常流程**不需要**调用它 —— 翻译在后端维护。保留仅为兼容。
  Future<bool> putChineseTranslate() async {
    final res = await request(() => put(
          '/home/chinese_translate',
          data: Messages().all_cn_translate,
        ));
    return res.isSuccess && res.data == true;
  }

  /// **反馈**当前语言下缺失的翻译 key（后端会记日志，便于持续补齐）。
  Future<bool> reportMissingTranslate(List<String> keys) async {
    if (keys.isEmpty) return true;
    final res = await request(() => post(
          '/home/missing_translate',
          data: {'keys': keys},
        ));
    return res.isSuccess;
  }

  Future<Map<String, Map<String, String>>> getAdditionalTranslate() async {
    final res = await request(() => get('/home/additional_translate'));
    Map<String, Map<String, String>> result = {};
    if (res.isSuccess) {
      result["zh-CN"] = res.data["zh-CN"].cast<String, String>();
      result["en-US"] = res.data["en-US"].cast<String, String>();
    }
    return result;
  }

// ----------------------------------   菜单项管理   ----------------------------------
  Future<Map<String, List<String>>> getScriptMenu() async {
    final res = await request(() => get('/script_menu'));
    return ((res.data ?? {}) as Map).map((k, v) =>
        MapEntry(k.toString(), (v as List).map((e) => e.toString()).toList()));
  }

  Future<Map<String, List<String>>> getHomeMenu() async {
    final res = await request(() => get('/home/home_menu'));
    return ((res.data ?? {}) as Map).map((k, v) =>
        MapEntry(k.toString(), (v as List).map((e) => e.toString()).toList()));
  }

// ----------------------------------   配置文件管理   ----------------------------------
  Future<List<String>> getConfigList() async {
    final res = await request(() => get('/config_list'));
    return ['Home', ...(res.data?.cast<String>() ?? [])];
  }

  Future<List<String>> getScriptList() async {
    final res = await request(() => get('/config_list'));
    return [...(res.data?.cast<String>() ?? [])];
  }

  Future<String> getNewConfigName() async {
    final res = await request(() => get('/config_new_name'));
    return res.isSuccess ? res.data : '';
  }

  Future<List<String>> configCopy(String newName, String template) async {
    final res = await request(() => post(
          '/config_copy',
          queryParameters: {'file': newName, 'template': template},
        ));
    return ['Home', ...(res.data?.cast<String>() ?? [])];
  }

  Future<List<String>> getConfigAll() async {
    final res = await request(() => get('/config_all'));
    return res.data?.cast<String>() ?? ['template'];
  }

  Future<bool> deleteConfig(String name) async {
    final res = await request(() => delete(
          '/config',
          queryParameters: {'name': name},
        ));
    return res.isSuccess && res.data;
  }

  Future<bool> renameConfig(String oldName, String newName) async {
    final res = await request(() => put(
          '/config',
          queryParameters: {'old_name': oldName, 'new_name': newName},
        ));
    return res.isSuccess && res.data;
  }

// ---------------------------------   脚本实例管理   ----------------------------------

  Future<Map<String, dynamic>> getScriptTask(
      String scriptName, String taskName) async {
    final res = await request(() => get('/$scriptName/$taskName/args'));
    return res.data ?? {};
  }

  // ---------------------------------------------------------------- 窗口 CRUD（S4）
  //
  // 设计: `docs/scheduler-architecture.md` §5.1。
  // ★ **按 `id`** 定位（"身份不是位置"）—— 按下标在重排后会删错。

  /// 查某任务的**窗口列表**。
  Future<List<Map<String, dynamic>>> getTaskWindows(
      String scriptName, String task) async {
    final res =
        await request(() => get('/$scriptName/tasks/$task/windows'));
    final d = res.data ?? {};
    return ((d['windows'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// **整单替换**窗口列表（前端编辑器一次保存全部）。
  Future<Map<String, dynamic>> putTaskWindows(
      String scriptName, String task, List<Map<String, dynamic>> windows) async {
    final res = await request(() => put(
          '/$scriptName/tasks/$task/windows',
          data: windows,
        ));
    return res.data ?? {};
  }

  /// **新增**一条窗口（后端生成 `id`）。
  Future<Map<String, dynamic>> addTaskWindow(
      String scriptName, String task, Map<String, dynamic> window) async {
    final res = await request(() => post(
          '/$scriptName/tasks/$task/windows',
          data: window,
        ));
    return res.data ?? {};
  }

  /// **改**一条窗口（**按 `id`**）。
  Future<Map<String, dynamic>> updateTaskWindow(String scriptName, String task,
      String windowId, Map<String, dynamic> window) async {
    final res = await request(() => put(
          '/$scriptName/tasks/$task/windows/$windowId',
          data: window,
        ));
    return res.data ?? {};
  }

  /// **删**一条窗口（**按 `id`**）。
  Future<Map<String, dynamic>> deleteTaskWindow(
      String scriptName, String task, String windowId) async {
    final res = await request(
        () => delete('/$scriptName/tasks/$task/windows/$windowId'));
    return res.data ?? {};
  }

  Future<bool> putScriptArg(
    String scriptName,
    String taskName,
    String groupName,
    String argumentName,
    String type,
    dynamic value,
  ) async {
    final res = await request(() => put(
          '/$scriptName/$taskName/$groupName/$argumentName/value',
          queryParameters: {'types': type, 'value': value},
        ));
    return res.isSuccess && res.data == true;
  }

// -------------------------   任务知识 / 总览 / 运行控制   --------------------------
//
// 这三个接口是后端新加的, 目的是让前端**不必内置任务知识**
// (见 OAS 的 docs/ui-api-mapping.md)。
//
//   /schema       —— 静态元数据(中文名/类别/资源规则/可配字段)
//   /overview     —— 运行态总览(能不能跑/为什么不能/下次什么时候)
//   /run_control  —— 暂停 / 休息 / 延后
//
// 三者都用**原始 JSON**(不强类型 model), 因为字段会随
// `tasks/<Name>/meta.py` 演进, 前端只按需读取。

  /// 任务静态元数据。与账号无关。
  Future<Map<String, dynamic>> getTaskSchema(String scriptName) async {
    final res = await request(() => get('/$scriptName/schema'));
    return res.data ?? {};
  }

  /// 运行态总览:每个任务现在能不能跑、为什么不能、下次什么时候。
  ///
  /// 每任务含 `queued`（在不在执行队列）与 `auto_queue`（是否自动进队列）——
  /// 前端的四类分区就用这两个字段, **不自己推导**。
  Future<Map<String, dynamic>> getTaskOverview(String scriptName) async {
    final res = await request(() => get('/$scriptName/overview'));
    return res.data ?? {};
  }

  /// 【添加任务】的候选: `enable && !auto_queue && !queued`。
  ///
  /// ★ 走后端（`get_queue_candidates`）而不是前端重新实现过滤 ——
  ///   规则只有一处, 不会漂移。
  Future<Map<String, dynamic>> getQueueCandidates(String scriptName) async {
    final res = await request(() => get('/$scriptName/queue/candidates'));
    return res.data ?? {};
  }

  /// **移出执行队列**。
  ///
  /// * 定时任务（`auto_queue=True`）-> 后端**同时停用**（否则会被自动补回）
  /// * 固定/次数任务 -> **只出队列**, 仍可加回
  ///
  /// ★ [entryId] 用来**精确移除某一条**（⑨ 的修复）。
  ///   队列里同一任务可以出现多次（"重复跑整个任务"）——
  ///   只传任务名会**一删全删**（实测: 两条「个人突破」删一条, 两条都没了）。
  ///   不传则删该任务**全部**条目（向后兼容）。
  Future<Map<String, dynamic>> removeFromQueue(
      String scriptName, String task, {String? entryId}) async {
    final res = await request(() => post(
          '/$scriptName/queue/remove',
          data: {
            'task': task,
            if (entryId != null && entryId.isNotEmpty) 'entry_id': entryId,
          },
        ));
    return res.data ?? {};
  }

  /// ★★★ **取消正在运行的任务**（语义 (a) = 暂停 + 移出队列）★★★
  ///
  /// 用户裁定:
  /// > "当前正在运行的**任务无法被取消**和拖动"
  /// > 取消语义 = **(a)**「暂停 + 移出队列」= 跑完当前这场战斗后停止且不再入队
  ///
  /// 后端一次做两件事（顺序很重要）:
  ///   ① `request_pause(mode='battle')` —— 让它在**跑完本场战斗**后停下
  ///   ② 把它**移出 `run_list`**（周期任务顺带停用, 规则与 `queue/remove` 同一处）
  ///
  /// ⚠ 它是**异步生效**的: 返回 `ok` 只表示"已请求", 任务可能还要打完当前这场。
  ///   所以界面文案必须写"**跑完当前这场战斗后停止**", 不能写"立即停止"。
  Future<Map<String, dynamic>> cancelRunning(String scriptName) async {
    final res = await request(() => post('/$scriptName/running/cancel'));
    return res.data ?? {};
  }

  /// **一键清空执行队列**（⑦）。
  ///
  /// 后端会 ① `run_list` 置空 ② 把所有 `auto_queue` 任务 `enable=false`
  /// —— 后者是必须的, 否则它们会被 `build_queue()` **重新补回队列**
  /// （与单个移除的语义一致: 定时任务"移出"要落地为停用）。
  ///
  /// ★ **不删任何任务配置**, 用户随时可以重新启用 + 【添加任务】加回来。
  Future<Map<String, dynamic>> clearQueue(String scriptName) async {
    final res = await request(() => post('/$scriptName/queue/clear'));
    return res.data ?? {};
  }

  /// 运行控制状态(暂停/休息/延后)。
  Future<Map<String, dynamic>> getRunControl(String scriptName) async {
    final res = await request(() => get('/$scriptName/run_control'));
    return res.data ?? {};
  }

  /// ★★★ 暂停调度（**同时把正在运行的任务退回队列首位**）★★★
  ///
  /// 用户原话:
  /// > "就把这个功能**聚合到暂停调度按钮**上好了, 点击暂停调度,
  /// >  正在运行的任务**自动回退到队列首位, 视作等待执行**"
  ///
  /// ★ 后端会**同时**做两件事（顺序关键, 先暂停再挪位置）:
  ///   ① 置暂停 `mode='battle'`（跑完当前这场战斗后停）
  ///   ② 把 `running_task` 退回 `run_list` 首位（**不停用**）
  ///
  /// :return 后端原始响应（含 `requeued` = 退回的任务名, `message` = 中文说明）
  ///
  /// ⚠ 与 `pauseScript()` 的区别: 那个只返回 `bool`（成功与否）,
  ///   看不到"退回了哪个任务"。本方法给需要**展示说明**的调用方用。
  Future<Map<String, dynamic>> pauseScriptDetailed(
      String scriptName, {String mode = 'battle'}) async {
    final res = await request(() => put(
          '/$scriptName/run_control/pause',
          queryParameters: {'mode': mode},
        ));
    return res.data ?? {};
  }

  /// 暂停调度。
  ///
  /// [mode] 只能是 `battle`(⏸ 跑完当前这场战斗) 或 `round`(⏭ 本轮跑完再停)。
  /// **没有"立即停"** —— 那会卡在半途(战斗中/组队房间中), 不安全。
  Future<bool> pauseScript(String scriptName, {String mode = 'battle'}) async {
    final res = await request(() => put(
          '/$scriptName/run_control/pause',
          queryParameters: {'mode': mode},
        ));
    return res.isSuccess && res.data is Map && !res.data.containsKey('error');
  }

  /// 继续调度(解除暂停)。
  Future<bool> resumeScript(String scriptName) async {
    final res = await request(() => put('/$scriptName/run_control/resume'));
    return res.isSuccess && res.data is Map && !res.data.containsKey('error');
  }

  /// ★★★ P-3b: **重置队列循环计数**（用户裁定 乙 —— 手动按钮）★★★
  ///
  /// ## 用户原话
  ///
  /// > "如果要重跑这几次循环要怎么设置呢，我没想好，
  /// >  是不是得有个**手动重置计数到设定值的按钮**"
  ///
  /// ## 语义
  ///
  /// 把"**已经跑了几轮**"清 0 -> 于是又能跑满 `loop_times` 轮。
  /// ★ 返回后端给的 `message`（含 `before -> rounds`），直接上屏。
  ///
  /// ⚠ 与 `resumeScript` 不同: 这里**要返回数据**（不是 `bool`）——
  ///   因为界面要显示"重置前几轮"（用户点了才知道有效果）。
  Future<Map<String, dynamic>> resetLoopRounds(String scriptName) async {
    final res = await request(() => put('/$scriptName/run_control/loop_reset'));
    return res.data ?? {};
  }

  /// 休息 N 分钟(**全局**暂停, 定时任务也不跑)。`minutes=0` 取消。
  Future<bool> restScript(String scriptName, int minutes) async {
    final res = await request(() => put(
          '/$scriptName/run_control/rest',
          queryParameters: {'minutes': minutes},
        ));
    return res.isSuccess && res.data is Map && !res.data.containsKey('error');
  }

  /// 延后 N 分钟(只推迟**列表**推进, 定时任务照常)。`minutes=0` 取消。
  Future<bool> delayScript(String scriptName, int minutes) async {
    final res = await request(() => put(
          '/$scriptName/run_control/delay',
          queryParameters: {'minutes': minutes},
        ));
    return res.isSuccess && res.data is Map && !res.data.containsKey('error');
  }

  /// 平台能力(非 Windows 上部分功能不可用, 界面据此置灰)。
  Future<Map<String, dynamic>> getCapabilities() async {
    final res = await request(() => get('/capabilities'));
    return res.data ?? {};
  }

// -------------------------   运行记录 / 归档 / 运行一次   -------------------------
//
// ★ 「重置」= **归档后重开**（不是删除）—— 用户明确要求:
//   "点击重置选中后不是清除记录, 而是归档记录后开始新的记录。
//    这样后续可以分析运行记录和展示运行结果"。
//
// ★ 「运行一次」= 按**点击顺序**插队, 跑完当前任务/战斗后才切过去
//   （不是立即打断）。

  /// 读运行记录（不传 `task` 返回全部任务汇总）。
  Future<Map<String, dynamic>> getRunRecord(String scriptName,
      {String task = ''}) async {
    final res = await request(() => get(
          '/$scriptName/run_record',
          queryParameters: task.isEmpty ? null : {'task': task},
        ));
    return res.data ?? {};
  }

  /// ★ **任务完成汇报**（用户 2026-10-10 新需求）。
  ///
  /// 用户原话:
  ///   "添加一个**任务完成汇报 tab**, 现在的日志属于原始日志, 应该**转移到
  ///    单独界面**用来 debug, 当前日志位置替换为**任务完成汇报**的 tab,
  ///    只会报完成了哪些、**出错任务标注**等等其它可以作为简报的内容"
  ///
  /// 返回:
  /// ```json
  /// { "config", "at",
  ///   "summary": {"total","completed","failed","in_cooldown",
  ///                "total_runs","total_minutes"},
  ///   "tasks":   [{"key","name","runs","seconds","completed_in_period",
  ///                "fail_count","in_cooldown","cooldown_until",
  ///                "cooldown_minutes","charges","marks"}],
  ///   "errors":  [{"key","name","level","text"}] }
  /// ```
  ///
  /// ★ 后端**不新增状态存储** —— 汇总 `run_record` / `task_state` /
  ///   `failure_state` 三份已有数据（见 `module/config/report.py`）。
  Future<Map<String, dynamic>> getTaskReport(String scriptName) async {
    final res = await request(() => get('/$scriptName/report'));
    return res.data ?? {};
  }

  /// 读某任务的**归档明细**。
  Future<Map<String, dynamic>> getRunArchive(
      String scriptName, String task) async {
    final res = await request(() => get('/$scriptName/run_record/$task/archive'));
    return res.data ?? {};
  }

  /// 「重置选中」—— 归档后重开。`tasks` 为任务名数组。
  Future<Map<String, dynamic>> resetRunRecord(
      String scriptName, List<String> tasks) async {
    final res = await request(() => put(
          '/$scriptName/run_record/reset',
          data: tasks,
        ));
    return res.data ?? {};
  }

  /// 「运行一次」—— 按**数组顺序**（= 点击顺序）排队。
  Future<Map<String, dynamic>> requestRunOnce(
      String scriptName, List<String> tasks) async {
    final res = await request(() => put(
          '/$scriptName/manual_run',
          data: tasks,
        ));
    return res.data ?? {};
  }

  /// 读「运行一次」队列。
  Future<Map<String, dynamic>> getRunOnceQueue(String scriptName) async {
    final res = await request(() => get('/$scriptName/manual_run'));
    return res.data ?? {};
  }

  /// 取消「运行一次」排队（`task` 留空则清空）。
  Future<Map<String, dynamic>> cancelRunOnce(String scriptName,
      {String task = ''}) async {
    final res = await request(() => delete(
          '/$scriptName/manual_run',
          queryParameters: task.isEmpty ? null : {'task': task},
        ));
    return res.data ?? {};
  }

// -------------------------   失败冷却   -------------------------
//
// ★ 后端改造: 任务连续失败到阈值**不再 `exit(1)`** 退出进程
//   （那会造成"失败 3 次 → 重启 → 计数归零 → 又失败 3 次"的无限循环），
//   而是给该任务加**冷却**（默认 1 小时）。计数落盘，跨重启不丢。

  /// 读失败/冷却状态（`{task: {count, cooldown_until, cooldown_minutes}}`）。
  Future<Map<String, dynamic>> getFailureState(String scriptName) async {
    final res = await request(() => get('/$scriptName/failure_state'));
    return res.data ?? {};
  }

  /// 清除失败记录（**同时解除冷却**）—— 修好之后立刻重试，不用等。
  Future<Map<String, dynamic>> clearFailureState(String scriptName,
      {String task = ''}) async {
    final res = await request(() => delete(
          '/$scriptName/failure_state',
          queryParameters: task.isEmpty ? null : {'task': task},
        ));
    return res.data ?? {};
  }

// -------------------------   运行列表(有序条目清单)   --------------------------
//
// 列表不只是"任务顺序", 而是**有序条目**的序列。条目三种(按**效果**命名):
//
//   {"kind":"task",  "task":"FallenSun"}   执行任务
//   {"kind":"rest",  "minutes":30}         **全部停止** 30 分钟(连定时任务一起停)
//   {"kind":"delay", "minutes":30}         **只停列表** 30 分钟(定时任务照常)
//
// ★ 用**整体替换**而不是逐条增删: 界面拖拽后拿到的是**完整清单**
//   (含控制条目的位置), 整体写入最简单可靠, 也不会出现"拖到一半只写了一半"。
//
// ★ 条目类型的值/名称/说明**不在这里硬编码** —— 从 `/schema` 的
//   `list.entry_kinds` 读, 避免前端与后端各维护一份映射。

  // ---------------------------------  执行顺序**配置页**（#9）
  //
  // 用户原话:
  // > "添加**执行顺序配置页 1/2/3/……**，可以添加、删除和切换配置页"
  //
  // ★ 后端已就绪（`schema_router.py` 的 `/queue/profiles` 一族）:
  //
  //     GET    /{script}/queue/profiles               列出（含 active_id）
  //     POST   /{script}/queue/profiles               新建（不传 name 自动编号）
  //     PUT    /{script}/queue/profiles/activate      切换（★ 自动先存当前整页）
  //     PUT    /{script}/queue/profiles/rename        改名
  //     DELETE /{script}/queue/profiles/{id}          删除（至少留一页）
  //
  // ★★★ 所有响应的 `message` **已是**要显示给用户的中文说明 ★★★
  //   调用方**直接用**, 不要自己再拼一遍（两处文案必然漂移）。
  //
  // ★ 一页 = **整页快照**: 队列 + 每任务调度（启停/次数/优先级/预期耗时）
  //   + 全局开关（用户裁定「1甲」）—— 所以 `activate` 之后必须**整体 reload**。

  /// 列出执行顺序配置页。
  ///
  /// :return `{profiles: [{id,name,count,active}], active_id}`
  Future<Map<String, dynamic>> getQueueProfiles(String scriptName) async {
    final res = await request(() => get('/$scriptName/queue/profiles'));
    return res.data ?? {};
  }

  /// **新建一页**（后端把**当前** `run_list` 存为新页并切过去）。
  ///
  /// :param name: 可选; 不传则后端自动编号（`1` / `2` / `3` / …）
  Future<Map<String, dynamic>> createQueueProfile(
    String scriptName, {
    String? name,
  }) async {
    final res = await request(() => post(
          '/$scriptName/queue/profiles',
          data: {if (name != null && name.isNotEmpty) 'name': name},
        ));
    return res.data ?? {};
  }

  /// **切换到某一页**。
  ///
  /// ★ 后端在**同一个请求**里做两步（顺序关键, 原子）:
  ///   ① 先把**当前整页**存回当前页（否则刚拖的顺序 / 刚改的开关会丢）
  ///   ② 再把目标页的整页快照写回配置
  Future<Map<String, dynamic>> activateQueueProfile(
      String scriptName, String id) async {
    final res = await request(() => put(
          '/$scriptName/queue/profiles/activate',
          data: {'id': id},
        ));
    return res.data ?? {};
  }

  /// **给配置页改名**（只改名字, 不动页内容）。
  Future<Map<String, dynamic>> renameQueueProfile(
      String scriptName, String id, String name) async {
    final res = await request(() => put(
          '/$scriptName/queue/profiles/rename',
          data: {'id': id, 'name': name},
        ));
    return res.data ?? {};
  }

  /// **删除一页**。★ 后端保证**至少留一页**（删到最后一页会返回 error）。
  Future<Map<String, dynamic>> deleteQueueProfile(
      String scriptName, String id) async {
    final res = await request(
        () => delete('/$scriptName/queue/profiles/$id'));
    return res.data ?? {};
  }

  /// 读运行列表。
  Future<Map<String, dynamic>> getRunList(String scriptName) async {
    final res = await request(() => get('/$scriptName/run_list'));
    return res.data ?? {};
  }

  /// ★ **一次性排序执行顺序**（`PUT /{script}/queue/sort`）。
  ///
  /// `by` ∈ `'timed'` / `'fixed'`:
  ///   * `timed` -> **定时段**排前面
  ///   * `fixed` -> **固定段**排前面
  ///
  /// ## ★★★ 它是**动作**, 不是**状态** ★★★
  ///
  /// 旧的 `putPriorityMode` 设的是一个**持久模式**（`priority_mode`）:
  /// 一旦设定, 每次 `build_queue()` 都按它排, 而且**限制拖动范围**
  /// （不能跨类别拖）。
  ///
  /// ★ 用户裁定那太蠢:
  /// > "固定任务优先和定时任务优先以及**不能跨类别拖动太蠢了**。
  /// >  我只需要保持**可以自由拖动/改变执行顺序**就行, 固定任务优先和
  /// >  定时任务优先**直接作为一个快捷排序**就好。"
  ///
  /// ★ 所以: 点一次, 排一次, **不留状态**。排完之后用户可以随意再拖。
  ///
  /// :return 后端返回体（含 `ok` / `by` / `entries` / `error`）
  Future<Map<String, dynamic>> sortQueue(
      String scriptName, String by) async {
    final res = await request(() => put(
          '/$scriptName/queue/sort',
          data: {'by': by},
        ));
    return res.data ?? {};
  }

  /// **整体替换**运行列表(界面拖拽走这条)。
  Future<Map<String, dynamic>> putRunList(
      String scriptName, List<Map<String, dynamic>> entries) async {
    final res = await request(() => put(
          '/$scriptName/run_list',
          data: entries,
        ));
    return res.data ?? {};
  }

  /// 在指定位置插入一个条目。`index=-1` 表示追加到末尾。
  Future<Map<String, dynamic>> addRunListEntry(
    String scriptName,
    Map<String, dynamic> entry, {
    int index = -1,
  }) async {
    final res = await request(() => post(
          '/$scriptName/run_list/entry',
          queryParameters: {'index': index},
          data: entry,
        ));
    return res.data ?? {};
  }

  /// 删除指定位置的条目。
  Future<Map<String, dynamic>> removeRunListEntry(
      String scriptName, int index) async {
    final res = await request(() => delete(
          '/$scriptName/run_list/entry',
          queryParameters: {'index': index},
        ));
    return res.data ?? {};
  }

  /// 「预期执行流程」的**推算**。
  ///
  /// ⚠ 返回值里带 `disclaimer` —— 界面**必须**显示它,
  ///   不能让用户以为这是精确预测(实际还受体力/网络/开放时段影响)。
  Future<Map<String, dynamic>> getRunListPreview(String scriptName) async {
    final res = await request(() => get('/$scriptName/run_list/preview'));
    return res.data ?? {};
  }

// ---------------------------------   Snackbar --------------------------------
  void showDialog(String title, String content) {
    Get.snackbar(title, content, snackPosition: SnackPosition.BOTTOM);
  }

  void showNetErrSnackBar() {
    Get.snackbar(I18n.network_error.tr, I18n.network_connect_timeout.tr,
        duration: const Duration(seconds: 2),
        snackPosition: SnackPosition.BOTTOM);
  }

  void showNetErrCodeSnackBar(String msg, int code) {
    Get.snackbar(
        I18n.network_error.tr, '${I18n.network_error_code.tr}: $code | $msg',
        duration: const Duration(seconds: 2),
        snackPosition: SnackPosition.BOTTOM);
  }
}
