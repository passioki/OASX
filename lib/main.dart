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
    final localeService = Get.find<LocaleService>();

    return ResponsiveApp(builder: (context) {
      return GetMaterialApp(
        // useInheritedMediaQuery: true,
        debugShowCheckedModeBanner: false,
        // locale: DevicePreview.locale(context),
        builder: DevicePreview.appBuilder, // 上面三个是使用device_preview
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
  await initLogger();
  await GetStorage.init();

  // ★ 任务列表的界面偏好（排序 / 筛选）现在才升级成**真落盘**。
  //
  //   为什么要在这里、而不是让 `TaskListController` 自己 `new`:
  //   `GetStorage` 构造时会起一个 `Timer`，在 widget 测试里会留下
  //   `A Timer is still pending even after the widget tree was disposed`。
  //   所以控制器默认用**内存实现**，由启动流程显式升级 ——
  //   "用哪种存储"是启动时决定的事，不该让每个控制器去猜环境。
  TaskListController.defaultPrefsStore = TaskPrefsStore();

  await Future.wait([
    Get.putAsync(() async => LocaleService()),
    Get.putAsync(() async => ThemeService()),
    Get.putAsync(() async => WindowService()),
  ]);

  Get.lazyPut(() => WebSocketService());
}
