// ★★★ [11-13] 守卫：**配置写入**链路的两个硬约束 ★★★
//
// ## bug① 真因（实测复现）
// `args_view.dart` 的 8 个 handler 把 **中文展示名 `model.title`** 当成
// 字段名传给 `setArgument`，而后端按**字段名**取属性：
//     config_model.py:502  argument_object = getattr(group_object, argument, None)
//     config_model.py:504  if argument_object is None: logger.error(...); return False
// ⇒ 后端回 `200 false`、磁盘不变；前端**丢弃返回值**、还弹「设置已保存」
// ⇒ 用户看到"改了、退出回来又变回去了"。
// ★ API 实测（dev 后端 22288）：
//     argument=探索等级          -> body=False, 磁盘不变
//     argument=exploration_level -> body=True,  磁盘变化
//
// ## bug② 真因（同源：读不到初值）
// `task_list_controller.dart` 的 `loopTimes` **从不从 /schema 读**
// （`isLoopTimesLoaded` 只声明、零处使用），而 `_NumberCell` 在 value==0 时
// **显示为空**（`task_row_view.dart:599`）⇒ "循环轮数改完又变空"。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String p) => File(p).readAsStringSync();

void main() {
  group('★ 配置写入守卫（[11-13]）', () {
    test('bug① args_view 的 setArgument 必须传【字段名 model.name】', () {
      final src = _read('lib/views/args/args_view.dart');
      // 只看 setArgument 调用行：它们都形如 `..., widget.getGroupName(), model.X, 'type', value)`
      final calls = RegExp(r'getGroupName\(\)\s*,\s*(model\.\w+)\s*,')
          .allMatches(src)
          .map((m) => m.group(1))
          .toList();
      expect(calls.length, greaterThanOrEqualTo(8),
          reason: '期望至少 8 个 setArgument 调用，实际 ${calls.length}');
      final bad = calls.where((c) => c != 'model.name').toList();
      expect(bad, isEmpty,
          reason: '★ 这些调用传的不是 model.name：$bad —— 后端会 getattr 取不到 ⇒ 回 false ⇒ 静默不保存');
    });

    test('bug① setArgument 的返回值必须被检查（不许静默失败）', () {
      final src = _read('lib/controller/args/args_controller.dart');
      expect(src.contains('if (!ok)'), isTrue,
          reason: '★ setArgument 必须检查 putScriptArg 的返回值并提示「保存失败」');
    });

    test('bug② loopTimes 必须从 /schema 读一次（否则输入框永远显示空）', () {
      final src = _read('lib/controller/task_list/task_list_controller.dart');
      expect(src.contains("schemaGlobalFields['loop_times']"), isTrue,
          reason: '★ 需要从 /schema 的 global_fields.loop_times.current 读初值');
      expect(src.contains('isLoopTimesLoaded = true'), isTrue,
          reason: '★ 读初值后必须置位 isLoopTimesLoaded（否则每次刷新都覆盖用户刚改的值）');
      // 反向前提：`_NumberCell` 在 value==0 时显示空 —— 这条不改的话，
      // 上面两条守卫就失去意义。
      final cell = _read('lib/views/tasks/task_row_view.dart');
      expect(cell.contains("widget.value > 0 ?"), isTrue,
          reason: '★ _NumberCell 的 0 值显示为空是既知行为；若改了，请同步复核本守卫');
    });
  });
}
