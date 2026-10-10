// ★ C-5: 前端侧 `entry_id` 的解析（重复条目的区分基础）。
//
// 用户裁定: "**entry_id 用当前时间 + task 来实现**, 这样可以**分拆也可以合并**"
// 以及 D: "重复添加是**重复跑整个任务**"。
//
// 所以同一任务在队列里可以出现**多条** —— 界面必须能区分它们,
// 否则用户看到两个"个人突破"分不清哪个是哪个。
//
// ★ 这里只测**纯逻辑**（`addedAtOfEntryId`）—— 界面契约用后端侧守卫 +
//   `flutter analyze` 保证（读源码字符串做断言太脆, 我第一版就写坏了）。

import 'package:flutter_test/flutter_test.dart';
// ⚠ `task_list_controller.dart` 是 `task_list_view.dart` 的 **part** ——
//   不能直接 `import`（会报 `import_of_non_library`）。要导入**宿主**文件。
import 'package:oasx/views/tasks/task_list_view.dart';

void main() {
  group('C-5: entry_id 的加入时间解析', () {
    test('★ 标准格式能解析', () {
      final at =
          TaskListController.addedAtOfEntryId('20261010T143005-RealmRaid');
      expect(at, isNotNull);
      expect(at!.year, 2026);
      expect(at.month, 10);
      expect(at.day, 10);
      expect(at.hour, 14);
      expect(at.minute, 30);
      expect(at.second, 5);
    });

    test('★ 带唯一化序号也能解析（同任务重复添加）', () {
      final at =
          TaskListController.addedAtOfEntryId('20261010T143005-RealmRaid-2');
      expect(at, isNotNull);
      expect(at!.hour, 14);
      expect(at.second, 5);
    });

    test('空 / 认不出 -> null（不猜）', () {
      expect(TaskListController.addedAtOfEntryId(''), isNull);
      expect(TaskListController.addedAtOfEntryId('RealmRaid'), isNull);
      expect(TaskListController.addedAtOfEntryId('whatever'), isNull);
      expect(TaskListController.addedAtOfEntryId('2026101XT143005-A'), isNull);
    });

    test('非法月份会被 Dart 滚动（记录行为, 不假装拒绝）', () {
      // ⚠ Dart 的 `DateTime(2026, 13, ...)` **不抛异常**, 而是**滚动**到
      //   2027-01。所以这里不断言 null —— 只记录这个行为, 免得以后误以为
      //   "解析器会拒绝非法月份"。
      //   （真正要防的是**崩溃**, 见下面那条。）
      final at =
          TaskListController.addedAtOfEntryId('20261310T143005-A');
      expect(at, isNotNull);
      expect(at!.year, 2027); // 滚动到次年 1 月
    });

    test('★ 绝不抛异常（这才是要防的）', () {
      for (final s in [
        '20261032T143005-A', // 32 日
        '20260000T000000-A', // 全 0
        '99999999T999999-A',
        '20261010T999999-A', // 时分秒越界
      ]) {
        // 只要不抛就算过
        expect(() => TaskListController.addedAtOfEntryId(s), returnsNormally,
            reason: '解析 $s 时抛异常了 —— 界面会崩');
      }
    });

    test('不同秒 -> 不同时间（重复添加的区分依据）', () {
      final a =
          TaskListController.addedAtOfEntryId('20261010T143005-RealmRaid');
      final b =
          TaskListController.addedAtOfEntryId('20261010T143006-RealmRaid');
      expect(a, isNotNull);
      expect(b, isNotNull);
      expect(a!.isBefore(b!), isTrue);
    });
  });
}
