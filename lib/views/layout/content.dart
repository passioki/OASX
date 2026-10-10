import 'package:flutter/material.dart';
import 'package:get/get_state_manager/src/rx_flutter/rx_getx_widget.dart';

import 'package:oasx/views/args/args_view.dart';
import 'package:oasx/views/home/home_view.dart';
import 'package:oasx/views/home/tool_view.dart';
import 'package:oasx/views/home/updater_view.dart';
import 'package:oasx/views/nav/view_nav.dart';
import 'package:oasx/views/overview/overview_view.dart';
import 'package:oasx/views/tasks/task_list_view.dart';

Widget content() {
  return GetX<NavCtrl>(builder: (controller) {
    return switch ([
      controller.selectedScript.value,
      controller.selectedMenu.value
    ]) {
      ['Home', 'Home'] => const HomeView(),
      ['Home', 'Updater'] => const UpdaterView(),
      ['Home', 'Tool'] => const ToolView(),
      // ignore: prefer_const_constructors, unused_local_variable
      [String name, 'Overview'] => Overview(),
      // 任务总览 / 任务列表（调度器）—— **唯一的调度控制台**
      //
      // ★ 这是一张**扁平表格**(一行一个任务, 一列一个维度), 而不是
      //   原来"树状展开"的调参界面。总览和列表本质上是**横向对比**,
      //   树状结构不适合看全局。
      [String name, 'TaskList'] => TaskListView(scriptName: name),
      _ => const Args(),
    };
  });
}
