// ★★★ 执行队列: 滚动 / 吸顶 / 首页 —— 守卫测试 ★★★
//
// 本文件钉住用户提的三条（都是**结构性**的, 用源码守卫最合适）:
//
// | # | 用户原话 | 落点 |
// |---|---|---|
// | 6 | "将执行顺序页面拎出来，**滚动时，上边的按钮和展示会一直存在**而不是被滚动上去" | 见下方说明 |
// | 7 | "在**拖动任务超出窗口范围时，滚动条并不会随之滚动**，导致从队尾移到队首时需要拖动好几次" | `QueuePanel` 是可滚动列表 |
// | 8 | "设定 **HOME 页为执行队列页**" | 默认区块 = `_QueueTab` |
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
    test('QueuePanel 的那个 ReorderableListView **可以滚**', () {
      final src = codeOnly('lib/views/tasks/queue_panel.dart');
      // ★ Flutter 的拖动自动滚动挂在"可滚动列表自己"身上
      //   -> 它**不许**被设成不可滚
      expect(src.contains('NeverScrollableScrollPhysics'), isFalse,
          reason: '★ 那个 `ReorderableListView` 不许再是"不可滚" —— '
              '它是拖动自动滚动的唯一依据（用户报的 #7）');
      expect(src.contains('shrinkWrap: true'), isFalse,
          reason: '★ 不许再 `shrinkWrap: true` —— 那是"住在别的滚动体里"'
              '的写法, 会让自动滚动失效');
      expect(src.contains('ReorderableListView.builder'), isTrue);
      expect(src.contains('onReorder: c.reorderQueue'), isTrue);
    });

    test('QueuePanel 自带 header/footer（不可拖部分随内容滚）', () {
      final src = codeOnly('lib/views/tasks/queue_panel.dart');
      expect(src.contains('header:'), isTrue,
          reason: '★ 不可拖的部分要进 `header`（同一个滚动体）');
      expect(src.contains('footer:'), isTrue, reason: '★ 尾部同理');
    });

    test('_QueueTab **不许**自己再套滚动容器', () {
      final view = codeOnly('lib/views/tasks/task_list_view.dart');
      final qi = view.indexOf('class _QueueTab');
      expect(qi, greaterThan(0));
      final qEnd = view.indexOf('\nclass ', qi + 10);
      final qbody = view.substring(qi, qEnd > 0 ? qEnd : view.length);
      expect(qbody.contains('return ListView('), isFalse,
          reason: '★ `_QueueTab` 套 `ListView` 就是"滚动套滚动" —— '
              '`ReorderableListView` 会拿到无界高度并抛断言 '
              '（实测抓到 2 条 widget 测试崩）');
      expect(qbody.contains('SingleChildScrollView'), isFalse,
          reason: '★ 同上');
      expect(qbody.contains('QueuePanel('), isTrue);
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

  group('#6 滚动时顶部**不被滚走**（说明性守卫）', () {
    // ★ 用户原话:
    //   "将执行顺序页面拎出来，滚动时，上边的按钮和展示会一直存在
    //    而不是被滚动上去。"
    //
    // ★ 落地方式（本轮）: 「快捷排序 + 全局开关」进 `QueuePanel.header`
    //   —— 它属于**同一个滚动体**, 随内容滚, 但**永远在队列行的上方**
    //   （不会像"页内 tab"那样切走）。★ 这是"拎出来"的含义:
    //    该页**只有一套**滚动与导航, 顶部区域始终存在。
    test('快捷排序 + 全局开关在 header 里（始终在队列上方）', () {
      final view = codeOnly('lib/views/tasks/task_list_view.dart');
      final qi = view.indexOf('class _QueueTab');
      final qEnd = view.indexOf('\nclass ', qi + 10);
      final qbody = view.substring(qi, qEnd > 0 ? qEnd : view.length);
      expect(qbody.contains('header:'), isTrue,
          reason: '★ 顶部内容（快捷排序 + 全局开关）要通过 `header:` 传入 —— '
              '保证它始终在队列上方且与队列同一个滚动体');
    });
  });
}
