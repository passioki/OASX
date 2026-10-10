import 'dart:convert';

import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';
import 'package:oasx/api/api_client.dart';
import 'package:oasx/model/script_model.dart';
import 'package:oasx/service/websocket_service.dart';
import 'package:oasx/views/overview/overview_view.dart';

class ScriptService extends GetxService {
  // ignore: unused_field
  final _storage = GetStorage();
  final wsService = Get.find<WebSocketService>();
  final scriptModelMap = <String, ScriptModel>{}.obs;

  @override
  Future<void> onInit() async {
    final scriptList = await ApiClient().getScriptList();
    if (scriptList.isNotEmpty) {
      await Future.wait(scriptList.map((name) => connectScript(name)));
    }
    super.onInit();
  }

  @override
  Future<void> onClose() async {
    await Future.wait([
      ...scriptModelMap.keys.map((e) => Future.wait([
            stopScript(e),
            wsService.close(e),
            Get.delete<OverviewController>(tag: e, force: true)
          ])),
    ]);
    scriptModelMap.clear();
    super.onClose();
  }

  Future<void> connectScript(String name) async {
    if (!scriptModelMap.containsKey(name)) {
      addScriptModel(name);
    }
    wsService.removeAllListeners(name);
    await wsService.connect(name: name, listener: (mg) => wsListener(mg, name));
  }

  Future<void> startScript(String name) async {
    await connectScript(name);
    await wsService.send(name, 'start');
    await wsService.send(name, 'get_state');
  }

  /// 日志订阅者 —— `account -> [sink, ...]`。
  ///
  /// ## 为什么需要它
  ///
  /// 日志原先**硬编码**发给 `OverviewController`（旧的总览页）。
  /// 但 v2 之后**任务列表页**才是调度控制台，日志要显示在那里 ——
  /// 而同一个账号可能有多个页面在看日志。
  ///
  /// 与其在 `wsListener` 里 `if` 每个可能的控制器，不如让订阅者自己注册。
  /// 这样**新页面加日志不用改这里**。
  ///
  /// ★ 每个订阅者拿到的 `msg` 是**原始文本**（可能不是 JSON）——
  ///   与原先发给 `OverviewController` 的完全一样。
  final _logSinks = <String, List<void Function(String)>>{};

  /// 订阅某个账号的日志。返回取消订阅的函数。
  void Function() subscribeLog(String name, void Function(String) sink) {
    final list = _logSinks.putIfAbsent(name, () => []);
    list.add(sink);
    return () {
      list.remove(sink);
      if (list.isEmpty) _logSinks.remove(name);
    };
  }

  void _emitLog(String name, String text) {
    for (final sink in List.of(_logSinks[name] ?? const [])) {
      try {
        sink(text);
      } catch (e) {
        printError(info: 'log sink error: $e');
      }
    }
  }

  void wsListener(dynamic message, String name) {
    if (message is! String) {
      printError(info: 'Websocket push data is not of type string and map');
      return;
    }
    if (!message.startsWith('{') || !message.endsWith('}')) {
      // 先发给订阅者（v2 的任务列表页等），再兼容旧的总览页。
      _emitLog(name, message);
      if (Get.isRegistered<OverviewController>(tag: name)) {
        Get.find<OverviewController>(tag: name).addLog(message);
      }
      return;
    }
    Map<String, dynamic> data = jsonDecode(message);
    if (data.containsKey('state')) {
      scriptModelMap[name]!.update(state: ScriptState.getState(data['state']));
      return;
    }
    if (data.containsKey('schedule')) {
      Map run = data['schedule']['running'];
      List<dynamic> pending = data['schedule']['pending'];
      List<dynamic> waiting = data['schedule']['waiting'];
      TaskItemModel runningTask = run.isNotEmpty
          ? TaskItemModel(run['name'], run['next_run'])
          : TaskItemModel.empty();
      final pendingList =
          pending.map((e) => TaskItemModel(e['name'], e['next_run'])).toList();
      final waitingList =
          waiting.map((e) => TaskItemModel(e['name'], e['next_run'])).toList();
      scriptModelMap[name]!.update(
          runningTask: runningTask,
          pendingTaskList: pendingList,
          waitingTaskList: waitingList);
    }
  }

  Future<void> stopScript(String name) async {
    if (!scriptModelMap.containsKey(name)) return;
    await wsService.send(name, 'stop');
  }

  void addScriptModel(dynamic sm) {
    if (sm is String) {
      sm = ScriptModel(sm);
    }
    if (scriptModelMap.containsKey(sm.name)) return;
    scriptModelMap[sm.name] = sm;
  }

  void updateScriptModel(ScriptModel sm) {
    if (!scriptModelMap.containsKey(sm.name)) return;
    scriptModelMap[sm.name] = sm;
  }

  void addOrUpdateScriptModel(ScriptModel sm) {
    if (scriptModelMap.containsKey(sm.name)) {
      updateScriptModel(sm);
    } else {
      addScriptModel(sm);
    }
  }

  void deleteScriptModel(String name) {
    if (!scriptModelMap.containsKey(name)) return;
    scriptModelMap.remove(name);
    wsService.close(name);
  }

  ScriptModel? findScriptModel(String name) {
    return scriptModelMap[name];
  }
}
