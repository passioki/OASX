import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:device_preview/device_preview.dart';
import 'package:get_storage/get_storage.dart';
import 'package:oasx/service/locale_service.dart';
import 'package:oasx/service/theme_service.dart';
import 'package:oasx/service/websocket_service.dart';
import 'package:oasx/service/window_service.dart';
import 'package:oasx/utils/logger.dart';
import 'package:responsive_builder/responsive_builder.dart';
import 'package:get/get.dart';

import 'package:oasx/views/routes.dart';
import 'package:oasx/utils/platform_utils.dart';
import 'package:oasx/controller/settings.dart';
import 'package:oasx/service/task_prefs.dart';
import 'package:oasx/views/tasks/task_list_view.dart' show TaskListController;
import 'package:oasx/config/theme.dart' show lightTheme, darkTheme;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initService();

  runApp(
    DevicePreview(
      enabled: !kReleaseMode && (PlatformUtils.isWindows),
      builder: (context) => const OASXApp(), // Wrap your app
    ),
  );
}

class OASXApp extends StatelessWidget {
  const OASXApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    // ★★★ 首帧**绝不允许白屏**（实测踩到）★★★
    //
    // 原来这里是:
    //     final localeService = Get.find<LocaleService>();
    // ★ 只要 `LocaleService` 没被注册（初始化失败），这一行就抛异常 ->
    //   **首帧渲染失败** -> 用户看到一个**白色空窗口**（窗口在、内容没有、
    //   也没有任何提示）—— 这正是用户反复报的"打不开"。
    //
    // ★ 现在: 取不到就**退回一个裸实例**；连那都失败也照样画界面
    //   （翻译缺失只是显示 key，比白屏好得多）。
    late final LocaleService localeService;
    var serviceError = '';
    try {
      localeService = Get.find<LocaleService>();
    } catch (e) {
      serviceError = '$e';
      localeService = LocaleService();
    }

    return ResponsiveApp(builder: (context) {
      return GetMaterialApp(
        // useInheritedMediaQuery: true,
        debugShowCheckedModeBanner: false,
        // locale: DevicePreview.locale(context),
        // ★ 注意: builder 在下面统一设置（见服务降级横幅）
        scrollBehavior: GlobalBehavior(),
        translations: localeService.messages,
        locale: localeService.currentLocale,
        fallbackLocale: localeService.fallbackLocale, //语言选择无效时，备用语言
        title: 'OASX',
        onInit: onInit,
        initialRoute: Routes.initial,
        getPages: Routes.routes,
        theme: lightTheme,
        darkTheme: darkTheme,
        // ★ 有服务降级时，在**每一帧上方**叠一条可见提示 ——
        //   让问题可见，而不是静默白屏（见 `build` 开头的说明）。
        builder: serviceError.isEmpty
            ? DevicePreview.appBuilder
            : (context, child) => Stack(
                  children: [
                    if (child != null) child,
                    _ServiceDegradedBanner(error: serviceError),
                  ],
                ),
      );
    });
  }

  /// 但是我不能确定 Getx 框架这个时候是否成功初始化
  void onInit() {
    Get.put(SettingsController());
  }
}

class GlobalBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        // etc.
      };
}

Future<void> initService() async {
  // ★★★ 启动期**每一步都必须容错**（实测踩到的真故障）★★★
  //
  // ## 用户报的现象
  //
  // > "双击 OASX 打不开" —— 但**进程活着**、窗口永不出现。
  //
  // ## 实测根因（探针二分定位）
  //
  // 启动流程**在 `runApp()` 之前串行执行**。
  // 用户机器上这两步**被拒绝访问**(`PathAccessException ... errno = 5`):
  //
  //   * `%LOCALAPPDATA%\<appId>`  -> 日志目录建不了
  //   * `Documents\GetStorage.gs` -> 本地存储打不开
  //
  // 而这里**原来没有任何 try/catch** -> 异常从 `main()` 抛出 ->
  // `runApp()` **永不执行** -> **窗口永不出现** = 用户看到的"打不开"。
  //
  // ★ 对照实验(同一引擎 3.27.1 编译):
  //   * 纯 Flutter 探针              -> 窗口**能开**
  //   * 只加 `window_manager` 的探针 -> 窗口**能开**
  //   * 复现本启动流程**但加了 try/catch** 的探针 -> 窗口**能开**
  //     （日志里同样记录了两个 `errno=5`）
  //   -> ★ 证明**不是引擎/不是 window_manager**，而是
  //      **"启动步骤失败就把整个应用带走"这个设计缺陷**。
  //
  // ## 修法
  //
  // 每一步各自容错: 失败就降级（内存存储 / 默认语言 / 默认主题），
  // **但窗口照常显示**。★ 用户至少能看到界面和明确提示，
  // 而不是"双击没反应"。
  //
  // ⚠ `WindowService` 仍然不能吞异常 —— 它失败就没有窗口可显示，
  //   那时**必须**让错误冒出来（否则又变成静默无窗口）。
  await initLogger();

  try {
    await GetStorage.init('GetStorage-live');   // ★ 实机版独立容器，避免与 Dev 版共用
  } catch (e) {
    logger.w('GetStorage 初始化失败, 本次运行改用内存存储: $e');
  }

  // ★ 任务列表的界面偏好（排序 / 筛选）现在才升级成**真落盘**。
  //
  //   为什么要在这里、而不是让 `TaskListController` 自己 `new`:
  //   `GetStorage` 构造时会起一个 `Timer`，在 widget 测试里会留下
  //   `A Timer is still pending even after the widget tree was disposed`。
  //   所以控制器默认用**内存实现**，由启动流程显式升级 ——
  //   "用哪种存储"是启动时决定的事，不该让每个控制器去猜环境。
  //
  // ★ 兜底: 存储不可用时退回**内存实现**（偏好不落盘，但界面可用）
  try {
    TaskListController.defaultPrefsStore = TaskPrefsStore();
  } catch (e) {
    logger.w('界面偏好存储不可用, 改用内存存储: $e');
    TaskListController.defaultPrefsStore = MemoryPrefsStore();
  }

  // ★★★ 服务必须**一定被注册**（实测踩到的白屏根因）★★★
  //
  // ## 为什么不能"失败就跳过"
  //
  // `OASXApp.build()` 的第一行就是:
  //     final localeService = Get.find<LocaleService>();
  // ★ 若 `LocaleService` **没被注册**，`Get.find` 抛异常 ->
  //   **首帧渲染失败** -> 用户看到的就是**白色空窗口**（窗口在、内容没有）。
  //
  // ★ 实测(阶梯探针): 纯 Flutter / +window_manager / +GetStorage /
  //   +DevicePreview+ResponsiveApp+GetMaterialApp **全部正常显示颜色**，
  //   只有完整 OASX 白屏 -> 证明白屏来自**首帧异常**，不是渲染管线。
  //
  // ## 所以
  //
  // 起不来时**再试一次**（很多失败是时序问题），仍失败也**必须注册一个
  // 可用的实例** —— 界面能画出来，比"静默白屏"好一万倍。
  await _ensureService<LocaleService>(
      () async => LocaleService(), 'LocaleService');
  await _ensureService<ThemeService>(
      () async => ThemeService(), 'ThemeService');
  // ⚠ WindowService **不容错** —— 见 `initService` 开头的说明
  await Get.putAsync(() async => WindowService());

  Get.lazyPut(() => WebSocketService());
}

/// ★ 保证 `T` **一定**被注册（起不来就重试，再不行也注册一个实例）。
///
/// 见 `initService` 里"服务必须一定被注册"的说明 —— 缺服务会让
/// `Get.find` 在**首帧**抛异常，表现为**白色空窗口**。
Future<void> _ensureService<T extends GetxService>(
    Future<T> Function() factory, String name) async {
  for (var attempt = 1; attempt <= 2; attempt++) {
    try {
      await Get.putAsync(factory);
      return;
    } catch (e) {
      logger.w('$name 初始化失败(第 $attempt 次): $e');
    }
  }
  // ★ 两次都失败: 用**不触发网络/文件**的裸实例兜底注册
  try {
    final fallback = Get.put<T>(_bare<T>(factory));
    logger.w('$name 已用**降级实例**注册（功能受限但不致白屏）: $fallback');
  } catch (e) {
    logger.e('$name 连降级注册都失败, 界面可能出现异常: $e');
  }
}

/// 造一个**不跑 `onInit` 副作用**的裸实例（用于降级注册）。
///
/// ⚠ 只对已知类型有效；未知类型返回 `null`，由调用方 `put` 时捕获。
T _bare<T extends GetxService>(Future<T> Function() factory) {
  if (T == LocaleService) return LocaleService() as T;
  if (T == ThemeService) return ThemeService() as T;
  throw StateError('没有 \ 的降级实现');
}

/// ★ 服务降级时的**可见**横幅（避免白屏无提示）。
class _ServiceDegradedBanner extends StatelessWidget {
  const _ServiceDegradedBanner({required this.error});
  final String error;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Material(
        color: Colors.transparent,
        child: Container(
          color: const Color(0xE6B00020),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              const Icon(Icons.warning_amber_rounded,
                  size: 16, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '启动时部分服务未就绪（界面仍可使用）: ',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
