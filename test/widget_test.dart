// OASX 冒烟测试。
//
// ## 为什么换掉了原来的 "Counter increments smoke test"
//
// 那是 `flutter create` 的**模板遗留** —— 它在一个**计数器示例应用**上
// 断言"按 + 后数字从 0 变 1"。但 `OASXApp` 是真实应用，**根本没有那个
// 计数器**，所以 `find.byIcon(Icons.add)` 必然失败。
//
// 换句话说: **这个测试从一开始就是坏的**，只是以前没人跑它。
// 与其留着一条永远红的测试（会训练人忽略红灯），不如换成有意义的冒烟检查。
//
// ## 现在检查什么
//
// 1. 任务列表这个**库能正常加载**（import 链没断、part 文件都在）
// 2. 关键类都存在且可构造
// 3. **默认偏好存储是内存实现** —— 这是个刻意的设计决定:
//    `TaskPrefsStore` 的构造会起 `GetStorage` 的 `Timer`，
//    在 widget 测试里会留下 `A Timer is still pending...`。
//    所以默认必须是内存的，由 `main.dart` 在启动时升级。
//    （这条以前踩过，所以固化成断言。）
import 'package:flutter_test/flutter_test.dart';

import 'package:oasx/service/task_prefs.dart';
import 'package:oasx/views/tasks/task_list_view.dart';

void main() {
  group('OASX 冒烟', () {
    test('任务列表库能加载，关键类都在', () {
      // 能 import 到这个类型就说明 part 链完整
      expect(TaskListController, isNotNull);
      expect(TaskSorter.columns, isNotEmpty);
      expect(MemoryPrefsStore, isNotNull);
    });

    test('默认偏好存储是内存实现（不引入 GetStorage 的 Timer）', () {
      // ★ 若改成 `TaskPrefsStore()`，widget 测试会报到:
      //   "A Timer is still pending even after the widget tree was disposed"
      expect(TaskListController.defaultPrefsStore, isA<MemoryPrefsStore>(),
          reason: '默认必须是内存实现 —— 真落盘由 main.dart 启动时升级');
    });

    test('控制器可用注入的存储构造', () {
      final c = TaskListController(scriptName: 'acc');
      c.prefsStore = MemoryPrefsStore();
      expect(c.scriptName, 'acc');
      expect(c.tasks, isEmpty);
      // 默认排序与原型一致（按下次运行升序）
      expect(c.sortSpec.column, 'next_run');
      expect(c.sortSpec.ascending, isTrue);
      c.onClose();
    });
  });
}
