// ★★★ S7: 「快捷排序」的守卫测试 ★★★
//
// ## 背景（用户裁定）
//
// > "我觉得……这个**固定任务优先和定时任务优先以及不能跨类别拖动太蠢了**。
// >  我只需要保持**可以自由拖动/改变执行顺序**就行, 固定任务优先和定时任务
// >  优先**直接作为一个快捷排序**就好, 而不是定义一些没有意义的不能跨类别
// >  拖动以及**单独的调度优先级**。"
//
// ## 为什么必须有这个文件
//
// 我**删掉了 19 条** `drag_constraint_behavior_test.dart` 的测试
// （它们钉的是"非自定义模式下不能跨类别拖动"那条**已废除的规则**）。
// ★ 删掉约束而**不补上替代能力的守卫**, 等于"把测试删到绿" ——
//   下一个人把排序按钮删掉都不会有人发现。
//
// ## 这个文件钉什么
//
// ① UI 有**两个排序按钮**（周期排前面 / 临时排前面）
// ② UI **不再有**「调度优先级」下拉（那是被删掉的"模式"）
// ③ UI **不再有**任何拖动约束提示
// ④ controller 有 `sortQueueBy`, 且它**走专用端点**（不是通用写字段）
// ⑤ `reorderQueue` **不再丢弃**自动补齐的行（拖了必须能持久化）
// ⑥ `reorderQueue` 把「休息」**归一化到最后**（用户确认的唯一硬约束）
//
// ⚠⚠ **本项目纪律: 断言源码文本前必须先剥注释** ⚠⚠
//
// 已经踩过**至少 5 次**: 守卫匹配到**自己的说明文字** -> 假失败或假通过。
// 所以下面一律走 `_codeOnly()`。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥掉 `//` 之后的内容（含 `///` 文档注释）。
/// ★ 不做这个, 断言会匹配到我写在注释里的"反例原文"。
String _codeOnly(String path) {
  final raw = File(path).readAsStringSync();
  return raw
      .split('\n')
      .map((l) {
        final i = l.indexOf('//');
        return i >= 0 ? l.substring(0, i) : l;
      })
      .join('\n');
}

const _view = 'lib/views/tasks/task_list_view.dart';
const _ctrl = 'lib/controller/task_list/task_list_controller.dart';
const _api = 'lib/api/api_client.dart';

void main() {
  group('① 两个排序按钮（快捷排序）', () {
    test('视图里有「周期排前面」与「临时排前面」两个按钮', () {
      final v = _codeOnly(_view);
      expect(v.contains('周期排前面'), isTrue,
          reason: '★ 缺了「周期排前面」按钮 —— 用户要的快捷排序之一');
      expect(v.contains('临时排前面'), isTrue,
          reason: '★ 缺了「临时排前面」按钮 —— 用户要的快捷排序之一');
    });

    test('两个按钮分别调 sortQueueBy(timed) / sortQueueBy(fixed)', () {
      final v = _codeOnly(_view);
      expect(v.contains("sortQueueBy('timed')"), isTrue,
          reason: "「周期排前面」应调 sortQueueBy('timed')");
      expect(v.contains("sortQueueBy('fixed')"), isTrue,
          reason: "「临时排前面」应调 sortQueueBy('fixed')");
    });

    test('用 OutlinedButton（是"做一个动作", 不是"选一个模式"）', () {
      final v = _codeOnly(_view);
      expect(v.contains('OutlinedButton'), isTrue,
          reason: '★ 排序必须是**按钮**（动作）—— 若变回 Dropdown 就是'
              '又把"模式"请回来了');
    });
  });

  group('② 「调度优先级」下拉（已删的"模式"）不得回来', () {
    test('视图里没有 priority_mode 这个全局字段', () {
      final v = _codeOnly(_view);
      expect(v.contains("'priority_mode'"), isFalse,
          reason: '★ 「调度优先级三模式」已被用户裁定删除');
    });

    test('controller 里没有 priorityMode / setPriorityMode / '
        'dragWithinGroupOnly', () {
      final c = _codeOnly(_ctrl);
      for (final dead in [
        'priorityMode',
        'priorityModeChoices',
        'setPriorityMode',
        'dragWithinGroupOnly',
        'dragRejection',
      ]) {
        expect(c.contains(dead), isFalse,
            reason: '★ `$dead` 随三模式一起被删 —— 不得复活');
      }
    });

    test('api_client 里没有 putPriorityMode, 但有 sortQueue', () {
      final a = _codeOnly(_api);
      expect(a.contains('putPriorityMode'), isFalse,
          reason: '★ 已删的"设模式"接口不得复活');
      expect(a.contains('sortQueue'), isTrue,
          reason: '★ 缺 sortQueue —— 排序按钮就没有后端接口可用');
    });
  });

  group('③ 拖动永远自由（不得有任何约束提示）', () {
    test('视图里不再出现"只能同类别内拖动"这类文案', () {
      final v = _codeOnly(_view);
      for (final banned in ['只能同类别内拖动', '不能跨类别拖动', '想自由拖动']) {
        expect(v.contains(banned), isFalse,
            reason: '★ 拖动约束已被用户裁定删除 —— "$banned" 不得回来');
      }
    });

    test('视图里应说明"拖动自由"（且不能只藏在 Tooltip 里）', () {
      final v = _codeOnly(_view);
      // ★★ 为什么查这些词而不是某个固定文案 ★★
      //
      // 我第一版断言 `v.contains('可自由拖动')` —— 那**把一个 UI 文案
      // 当成了契约**。我后来把标签改成「排一次 · 之后随便拖」,
      // 守卫就**假失败**了（功能没坏, 只是字换了）。
      //
      // ★ 真正要钉的是**语义**: 界面上必须出现"拖是自由的 / 不限类别"
      //   这类说法。用户抱怨的正是"拖不动、而且不知道为什么"。
      const freedomHints = [
        '任意拖动',
        '随便拖',
        '不限类别',
        '可自由拖动',
      ];
      expect(freedomHints.any(v.contains), isTrue,
          reason: '★ 界面上必须让用户看到"拖动是自由的" —— '
              '现有文案里一个都没有（这正是用户抱怨的点）');
    });

    test('队列面板的类别条是信息条, 不再靠 dragWithinGroupOnly 显示', () {
      final q = _codeOnly('lib/views/tasks/queue_panel.dart');
      expect(q.contains('dragWithinGroupOnly'), isFalse,
          reason: '★ `dragWithinGroupOnly` 已删 —— 类别条应恒显示');
      expect(q.contains('_segmentBar'), isTrue,
          reason: '类别条本身要保留（显示定时/固定各几条）');
    });
  });

  group('④ sortQueueBy 走专用端点, 且失败要可见', () {
    test('它调 `_api.sortQueue`（不是通用写字段路径）', () {
      final c = _codeOnly(_ctrl);
      final i = c.indexOf('Future<void> sortQueueBy(');
      expect(i, greaterThan(0), reason: '找不到 sortQueueBy');
      final body = c.substring(i, i + 1600);
      expect(body.contains('_api.sortQueue'), isTrue,
          reason: '★ 必须走 `PUT /{script}/queue/sort` —— 通用写字段路径'
              '**不会重排 `run_list`**，用户会看不到变化（这是实测过的坑）');
    });

    test('后端给了 error 就上屏（不许静默失败）', () {
      final c = _codeOnly(_ctrl);
      final i = c.indexOf('Future<void> sortQueueBy(');
      final body = c.substring(i, i + 1600);
      expect(body.contains('_snack('), isTrue,
          reason: '★ 排序失败必须上屏 —— 本项目纪律'
              '"让静默失败变成看得见"');
    });

    test('有 sortingQueue 重入锁（防连点发两个请求）', () {
      final c = _codeOnly(_ctrl);
      expect(c.contains('sortingQueue'), isTrue,
          reason: '★ 连点两个按钮会并发写 `run_list` —— 必须加锁');
    });
  });

  group('⑤ 拖动必须能持久化（实机验收: "只能拖动固定任务"）', () {
    // ## 症状（用户原话）
    // > "**现在只能拖动固定任务**。"
    //
    // ## 根因（实证）
    // 用户的 `run_list` 只有 4 条且**全是 FIXED**; 队列里其它的（全部 TIMED）
    // 由后端 `build_queue()` **自动补齐** -> `_queuedRow == true`。
    // 而 `reorderQueue` 原来用 `where((r) => r['_queuedRow'] != true)`
    // **丢弃**这些行 -> 拖动**必然弹回**。
    test('reorderQueue 不再丢弃 `_queuedRow` 的行', () {
      final c = _codeOnly(_ctrl);
      final i = c.indexOf('void reorderQueue');
      expect(i, greaterThan(0), reason: '找不到 reorderQueue');
      final body = c.substring(i, i + 6000);
      expect(RegExp(r"where\(\(r\)\s*=>\s*r\['_queuedRow'\]").hasMatch(body),
          isFalse,
          reason: '★ reorderQueue 又在丢弃自动补齐的行 —— '
              '那些任务（全部 TIMED）拖了会弹回, 用户体感就是'
              '"只能拖动固定任务"');
    });

    test('`_queuedRow` 标记本身仍存在（别连带删了）', () {
      final c = _codeOnly(_ctrl);
      expect(c.contains('_queuedRow'), isTrue);
    });
  });

  group('⑥ 「休息」条目恒排最后（用户确认的唯一硬约束）', () {
    test('reorderQueue 落库前把 rest 归一化到最后', () {
      final c = _codeOnly(_ctrl);
      final i = c.indexOf('void reorderQueue');
      final body = c.substring(i, i + 6000);
      // ★ 用两趟过滤（Dart 的 List.sort **不保证稳定**, 所以不能用 sort）
      expect(body.contains("'kind'") && body.contains('!= \'task\''), isTrue,
          reason: '★ 应把非 task 条目（rest）分出来排到最后');
    });
  });
}
