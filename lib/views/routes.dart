import 'package:get/get.dart';

import 'package:oasx/views/layout/layout.dart';
import 'package:oasx/views/layout/binding.dart';
import 'package:oasx/views/login/login_view.dart';
import 'package:oasx/views/settings/settings_view.dart';
import 'package:oasx/views/server/server_view.dart';
import 'package:oasx/views/tasks/task_list_view.dart';

class Routes {
  /// when the app is opened, this page will be the first to be shown
  static const initial = '/login';

  /// 任务总览 / 任务列表（调度器）。
  ///
  /// 用法: `Get.toNamed(Routes.tasks, arguments: '配置名')`
  static const tasks = '/tasks';

  static final routes = [
    GetPage(
      name: '/login',
      page: () => LoginView(),
      binding: LoginBinding(),
    ),
    GetPage(
      name: '/main',
      page: () => const LayoutView(),
      binding: LayoutBinding(),
    ),
    GetPage(
      name: '/settings',
      page: () => const SettingsView(),
    ),
    GetPage(
      name: '/server',
      page: () => const ServerView(),
      binding: BindingsBuilder(() {
        Get.put<ServerController>(ServerController());
      }),
    ),    // 任务总览 / 任务列表 —— OAS 的**唯一调度控制台**
    // （取代原来"树状展开"的调参界面: 总览和列表本质是**横向对比**的
    //   界面 —— 一行一个任务, 一列一个维度; 树状结构不适合看全局）
    GetPage(
      name: tasks,
      page: () {
        final arg = Get.arguments;
        final name = arg is String
            ? arg
            : (arg is Map ? '${arg['script'] ?? ''}' : '');
        return TaskListView(scriptName: name);
      },
    ),
  ];
}
