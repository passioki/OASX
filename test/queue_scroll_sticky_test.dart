// ★★★ 执行队列: 滚动 / 吸顶 / 首页 —— 守卫测试 ★★★
//
// 本文件钉住用户提的三条（都是**结构性**的, 用源码守卫最合适）:
//
// | # | 用户原话 | 落点 |
// |---|---|---|
// | 6 | "将执行顺序页面拎出来，**滚动时，上边的按钮和展示会一直存在**而不是被滚动上去" | `SliverPersistentHeader(pinned: true)` |
// | 7 | "在**拖动任务超出窗口范围时，滚动条并不会随之滚动**，导致从队尾移到队首时需要拖动好几次" | `SliverReorderableList` 住在可滚 viewport 里 |
// | 8 | "设定 **HOME 页为执行队列页**" | 默认区块 = `_QueueTab` |
//
// ⚠⚠ **本轮(#6)换了实现方式, 断言跟着换** ⚠⚠
//
// 上一轮把「快捷排序 + 全局开关」放进 `QueuePanel(header:)` —— 那是
// **跟随滚动**, 不是用户要的"一直存在"。本轮换成:
//
//     外层 `CustomScrollView` + `SliverPersistentHeader(pinned: true)`
//     行 -> `SliverReorderableList`（`ReorderableListView` 从 queue_panel 消失）
//
// ★ 为什么 `SliverReorderableList` 仍能**越界自动滚**（#7 不退化）:
//   它的 `autoScrollerVelocityScalar` 走 `Scrollable.of(context)` ——
//   也就是**外层** `CustomScrollView` 的 position。所以"自己不是滚动容器"
//   不再等于"不能自动滚"。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥注释（本项目反复踩过"守卫匹配到自己的注释"的坑）。
String codeOnly(String path) {
  final raw = File(path).readAsStringSync();
  return raw
      .split('\n')
      .map((l) => l.split('//').first)
      .join('\n');
}

void main() {
  group('#7 拖动越界**必须自动滚动**', () {
    test('队列行住在 `SliverReorderableList` 里（可拖 + 由外层滚动）', () {
      final src = codeOnly('lib/views/tasks/queue_panel.dart');
      // ★ Flutter 的拖动自动滚动读的是 `Scrollable.of(context)` ——
      //   所以行**必须**住在一个可滚 viewport 里, 且列表自己
      //   **不许**被设成不可滚。
      expect(src.contains('NeverScrollableScrollPhysics'), isFalse,
          reason: '★ 不许把滚动体设成"不可滚" —— '
              '拖动自动滚动就靠它（用户报的 #7）');
      expect(src.contains('shrinkWrap: true'), isFalse,
          reason: '★ 不许再 `shrinkWrap: true` —— 那是"住在别的滚动体里"'
              '的写法, 会让自动滚动失效');
      expect(src.contains('SliverReorderableList'), isTrue,
          reason: '★ 行必须由 `SliverReorderableList` 渲染 —— '
              '它才能住在 `CustomScrollView` 的 sliver 序列里（#6 吸顶的前提）');
      expect(src.contains('ReorderableListView'), isFalse,
          reason: '★ `ReorderableListView` **自己就是一个滚动体** —— '
              '塞不进外层 `CustomScrollView`（滚动套滚动 -> 无界高度约束错）');
      expect(src.contains('onReorder: c.reorderQueue'), isTrue);
    });

    test('不可拖的部分走 SliverToBoxAdapter（同一个滚动体, 随内容滚）', () {
      final src = codeOnly('lib/views/tasks/queue_panel.dart');
      expect(src.contains('SliverToBoxAdapter'), isTrue,
          reason: '★ 标题 / 调度状态 / 分段条 / 尾部提示要进 '
              '`SliverToBoxAdapter`（同一个滚动体）');
    });

    test('_QueueTab 是**唯一**的滚动体, 且用的是 CustomScrollView', () {
      final view = codeOnly('lib/views/tasks/task_list_view.dart');
      final qi = view.indexOf('class _QueueTab');
      expect(qi, greaterThan(0));
      final qEnd = view.indexOf('\nclass ', qi + 10);
      final qbody = view.substring(qi, qEnd > 0 ? qEnd : view.length);
      expect(qbody.contains('return ListView('), isFalse,
          reason: '★ `_QueueTab` 套 `ListView` 就是"滚动套滚动" —— '
              '`SliverReorderableList` 会拿到无界高度并抛断言');
      expect(qbody.contains('SingleChildScrollView'), isFalse,
          reason: '★ 同上');
      expect(qbody.contains('return CustomScrollView('), isTrue,
          reason: '★ #6 吸顶要求外层是 `CustomScrollView`'
              '（`SliverPersistentHeader` 只能住在它里面）');
      expect(qbody.contains('QueuePanel.slivers('), isTrue,
          reason: '★ 队列本体作为一组 sliver 交给这个 `CustomScrollView`');
    });
  });

  group('#8 首页 = **执行队列**', () {
    test('_bodyFor 的**默认**分支是 _QueueTab', () {
      final view = codeOnly('lib/views/tasks/task_list_view.dart');
      final i = view.indexOf('Widget _bodyFor(');
      expect(i, greaterThan(0));
      final body = view.substring(i, (i + 2200).clamp(0, view.length));
      // ★ 只有「任务列表」需要显式判断; 其余（含默认）都走执行队列
      expect(body.contains("sel == 'TaskListPanel'"), isTrue,
          reason: "★ 「任务列表」需要显式判断");
      final tail = body.substring(body.indexOf("if (sel == 'TaskListPanel')"));
      final afterIf = tail.substring(tail.indexOf('return _ScheduleTab(') + 1);
      expect(afterIf.contains('return _QueueTab('), isTrue,
          reason: '★ 默认（else）分支必须是 `_QueueTab` —— '
              '那就是"首页=执行队列"的落点（用户: "设定 HOME 页为执行队列页"）');
    });

    test('启动时自动选中第一个账号（不是主页）', () {
      final nav = codeOnly('lib/controller/ctrl_nav.dart');
      expect(nav.contains('await switchScript(1)'), isTrue,
          reason: '★ `onInit` 末尾要自动切到第一个账号 —— '
              '否则开屏仍是「主页」, "首页=执行队列"等于没做');
      expect(nav.contains('navNameList.length > 1'), isTrue,
          reason: '★ 必须判长度 —— 没有配置时列表只有 [Home], '
              '切过去会索引越界（启动崩）');
    });
  });

  group('#6 滚动时顶部**不被滚走**（= 吸顶, pinned）', () {
    // ★ 用户原话:
    //   "将执行顺序页面拎出来，滚动时，上边的按钮和展示会一直存在
    //    而不是被滚动上去。"
    //
    // ★★ 本轮(#6)的落地方式 ★★
    //   「快照页码 chips + 快捷排序 + 全局开关」进
    //   `SliverPersistentHeader(pinned: true)` —— **钉在顶部**,
    //   而不是上一轮那个 `QueuePanel.header`（那是**跟随滚动**,
    //   用户要的不是那个）。
    //
    // ★ 守卫必须钉住 `pinned: true` —— 少了它 `SliverPersistentHeader`
    //   一样能编译, 但滚上去就没了（= 用户报的 bug 原样复现）。
    test('顶部内容是 `SliverPersistentHeader(pinned: true)`', () {
      final view = codeOnly('lib/views/tasks/task_list_view.dart');
      expect(view.contains('SliverPersistentHeader'), isTrue,
          reason: '★ 缺 `SliverPersistentHeader` —— 那#6 就没有落点');
      expect(view.contains('pinned: true'), isTrue,
          reason: '★ `pinned: true` 才是"一直存在"；缺了它顶部照样被滚走');
      final qi = view.indexOf('class _QueueTab');
      final qEnd = view.indexOf('\nclass ', qi + 10);
      final qbody = view.substring(qi, qEnd > 0 ? qEnd : view.length);
      expect(qbody.contains('SliverPersistentHeader'), isTrue,
          reason: '★ 吸顶区必须在 `_QueueTab` 里（那是执行顺序页）');
      expect(qbody.contains('_sortActions(context, c)'), isTrue,
          reason: '★ 快捷排序 + 全局开关必须住进吸顶区 —— '
              '它们就是用户说的"上边的按钮和展示"');
    });

    test('吸顶区高度**实测**, 不写死（字号缩放 / Wrap 折行都不裁按钮）', () {
      final view = codeOnly('lib/views/tasks/task_list_view.dart');
      expect(view.contains('class _StickyQueueHeader'), isTrue,
          reason: '★ 缺 `SliverPersistentHeaderDelegate` 实现');
      final i = view.indexOf('class _StickyQueueHeader');
      final body = view.substring(i, (i + 3000).clamp(0, view.length));
      expect(body.contains('LayoutBuilder'), isTrue,
          reason: '★ 高度必须**实测**（`LayoutBuilder`）—— '
              '写死会在系统字号变大 / 窄屏 `Wrap` 折行时**裁掉按钮**');
      expect(body.contains('minExtent') && body.contains('maxExtent'), isTrue,
          reason: '★ delegate 必须给出 min/maxExtent');
    });
  });
}
