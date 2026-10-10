import 'package:flutter_test/flutter_test.dart';
import 'package:oasx/service/task_prefs.dart';

/// 任务表格的**多列排序 + 偏好持久化**测试。
///
/// 用户要求:
/// > 支持多列排序筛选且可以**持久记忆**用户的偏好，
/// > 同时可以**恢复默认**（有相关功能说明和弹窗提示）
///
/// ★ 这些是**纯逻辑**（`TaskSorter` / `TaskPrefsStore`），
///   不必起界面就能测 —— 所以语义能被真正固定下来。
void main() {
  Map<String, dynamic> t(String name,
          {String? cmd,
          String cat = 'fixed',
          bool canRun = true,
          int? target,
          String? nextRun,
          int? count}) =>
      {
        'name': name,
        'name_zh': name,
        'command': cmd ?? name,
        'category': cat,
        'can_run': canRun,
        if (target != null) 'target': target,
        if (nextRun != null) 'next_run': nextRun,
        if (count != null) 'count': count,
      };

  group('TaskSorter 基本排序', () {
    test('按任务名升序', () {
      final r = TaskSorter.apply(
        [t('C'), t('A'), t('B')],
        const TaskSortSpec(column: 'name'),
      );
      expect(r.map((e) => e['name']), ['A', 'B', 'C']);
    });

    test('降序', () {
      final r = TaskSorter.apply(
        [t('C'), t('A'), t('B')],
        const TaskSortSpec(column: 'name', ascending: false),
      );
      expect(r.map((e) => e['name']), ['C', 'B', 'A']);
    });

    test('按下次运行时间', () {
      final r = TaskSorter.apply([
        t('A', nextRun: '2026-01-02 00:00:00'),
        t('B', nextRun: '2026-01-01 00:00:00'),
      ], const TaskSortSpec(column: 'next_run'));
      expect(r.map((e) => e['name']), ['B', 'A']);
    });

    test('按状态 —— 能跑的在前', () {
      final r = TaskSorter.apply([
        t('A', canRun: false),
        t('B', canRun: true),
      ], const TaskSortSpec(column: 'state'));
      expect(r.map((e) => e['name']), ['B', 'A']);
    });

    test('按目标次数', () {
      final r = TaskSorter.apply([
        t('A', target: 30),
        t('B', target: 5),
      ], const TaskSortSpec(column: 'target'));
      expect(r.map((e) => e['name']), ['B', 'A']);
    });
  });

  group('TaskSorter 稳定性 —— 同键不跳', () {
    test('同键保持原序（升序）', () {
      final r = TaskSorter.apply([
        t('A', cat: 'fixed'),
        t('B', cat: 'fixed'),
        t('C', cat: 'fixed'),
      ], const TaskSortSpec(column: 'category'));
      expect(r.map((e) => e['name']), ['A', 'B', 'C']);
    });

    test('同键保持原序（降序也稳定）', () {
      // ★ 降序时**不能**把原来第一个翻到最后 —— 否则同键的行每次刷新都跳,
      //   看起来像界面在"闪"。
      final r = TaskSorter.apply([
        t('A', cat: 'fixed'),
        t('B', cat: 'fixed'),
      ], const TaskSortSpec(column: 'category', ascending: false));
      expect(r.map((e) => e['name']), ['A', 'B']);
    });
  });

  group('TaskSorter 缺值与类型混杂 —— 不该崩', () {
    test('next_run 缺失不崩', () {
      final r = TaskSorter.apply([
        t('A'),
        t('B', nextRun: '2026-01-01 00:00:00'),
      ], const TaskSortSpec(column: 'next_run'));
      expect(r, hasLength(2), reason: '缺 next_run 不该抛异常');
    });

    test('record 缺失时按 0 处理', () {
      final r = TaskSorter.apply([
        t('A'),
        t('B'),
      ], const TaskSortSpec(column: 'record_runs'));
      expect(r, hasLength(2));
    });

    test('未知列回落默认列（不崩、不空）', () {
      final r = TaskSorter.apply([
        t('A', nextRun: '2026-01-02 00:00:00'),
        t('B', nextRun: '2026-01-01 00:00:00'),
      ], const TaskSortSpec(column: 'nonsense'));
      expect(r.map((e) => e['name']), ['B', 'A'],
          reason: '未知列应回落到默认列, 而不是原样返回或崩');
    });

    test('空列表', () {
      expect(TaskSorter.apply([], TaskSorter.defaultSpec), isEmpty);
    });

    test('原列表不被改动', () {
      final src = [t('B'), t('A')];
      TaskSorter.apply(src, const TaskSortSpec(column: 'name'));
      expect(src.map((e) => e['name']), ['B', 'A'],
          reason: 'apply 不该原地改原列表');
    });
  });

  group('TaskSorter 运行记录列', () {
    test('按累计次数', () {
      final recs = {
        'A': {'runs': 3},
        'B': {'runs': 9},
      };
      final r = TaskSorter.apply(
        [t('A'), t('B')],
        const TaskSortSpec(column: 'record_runs'),
        recordOf: (c) => recs[c] ?? const {},
      );
      expect(r.map((e) => e['name']), ['A', 'B']);
    });

    test('按累计耗时', () {
      final recs = {
        'A': {'seconds': 900},
        'B': {'seconds': 60},
      };
      final r = TaskSorter.apply(
        [t('A'), t('B')],
        const TaskSortSpec(column: 'record_seconds'),
        recordOf: (c) => recs[c] ?? const {},
      );
      expect(r.map((e) => e['name']), ['B', 'A']);
    });

    test('降序按次数', () {
      final recs = {
        'A': {'runs': 3},
        'B': {'runs': 9},
      };
      final r = TaskSorter.apply(
        [t('A'), t('B')],
        const TaskSortSpec(column: 'record_runs', ascending: false),
        recordOf: (c) => recs[c] ?? const {},
      );
      expect(r.map((e) => e['name']), ['B', 'A']);
    });
  });

  group('列定义', () {
    test('列 id 唯一', () {
      final ids = TaskSorter.columns.map((c) => c['id']).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('每列都有中文标签（界面直接显示）', () {
      for (final c in TaskSorter.columns) {
        expect('${c['label']}'.isNotEmpty, isTrue, reason: '${c['id']} 缺标签');
      }
    });

    test('默认列是已知列', () {
      expect(TaskSorter.isKnownColumn(TaskSorter.defaultSpec.column), isTrue);
    });

    test('未知列判定', () {
      expect(TaskSorter.isKnownColumn('nonsense'), isFalse);
      expect(TaskSorter.isKnownColumn(''), isFalse);
    });
  });

  group('TaskSortSpec 序列化', () {
    test('往返', () {
      const s = TaskSortSpec(column: 'record_runs', ascending: false);
      final back = TaskSortSpec.fromJson(s.toJson());
      expect(back, s);
    });

    test('坏数据返回 null（而不是造一个坏 spec）', () {
      expect(TaskSortSpec.fromJson(null), isNull);
      expect(TaskSortSpec.fromJson('nonsense'), isNull);
      expect(TaskSortSpec.fromJson({}), isNull);
      expect(TaskSortSpec.fromJson({'column': ''}), isNull);
    });

    test('缺 ascending 时默认升序', () {
      final s = TaskSortSpec.fromJson({'column': 'name'})!;
      expect(s.ascending, isTrue);
    });

    test('copyWith', () {
      const s = TaskSortSpec(column: 'name');
      expect(s.copyWith(ascending: false), 
          const TaskSortSpec(column: 'name', ascending: false));
      expect(s.copyWith(column: 'target'),
          const TaskSortSpec(column: 'target'));
    });
  });

  group('偏好存储 —— 用内存实现测逻辑', () {
    // ★ 为什么不用真 `TaskPrefsStore`: `GetStorage` 依赖 `path_provider`
    //   **插件**, 在 `flutter test`（无平台通道）里会抛
    //   `MissingPluginException: ... getApplicationDocumentsDirectory`。
    //
    //   抽成 `PrefsStore` 接口 + `MemoryPrefsStore` 之后,
    //   持久化的**语义**（按账号隔离、恢复默认=删除、坏数据不崩）
    //   全都能测 —— 而不是"拿不到插件所以不测"。
    test('写后能读回', () {
      final store = MemoryPrefsStore();
      store.write('acc1', {
        'sort': const TaskSortSpec(column: 'record_runs', ascending: false)
            .toJson(),
        'onlyTimed': true,
      });
      final back = store.read('acc1');
      expect(TaskSortSpec.fromJson(back['sort']),
          const TaskSortSpec(column: 'record_runs', ascending: false));
      expect(back['onlyTimed'], isTrue);
    });

    test('账号之间隔离', () {
      final store = MemoryPrefsStore();
      store.write('accA', {'onlyTimed': true});
      expect(store.read('accB'), isEmpty);
    });

    test('恢复默认 = 删掉偏好（读回空）', () {
      final store = MemoryPrefsStore();
      store.write('acc2', {'onlyTimed': true});
      expect(store.read('acc2'), isNotEmpty);
      store.clear('acc2');
      expect(store.read('acc2'), isEmpty, reason: '恢复默认应清空偏好');
    });

    test('没写过 -> 空 map（不是 null）', () {
      final store = MemoryPrefsStore();
      expect(store.read('never_written'), isEmpty);
    });

    test('读回来的是副本 —— 改它不该污染存储', () {
      // ★ 这类"共享可变引用"的 bug 很难查: 界面改一下过滤条件,
      //   存储里的偏好也跟着变了（下次启动莫名恢复成上次的临时状态）。
      final store = MemoryPrefsStore();
      store.write('acc3', {'onlyTimed': false});
      final a = store.read('acc3');
      a['onlyTimed'] = true;
      expect(store.read('acc3')['onlyTimed'], isFalse);
    });

    test('覆盖写', () {
      final store = MemoryPrefsStore();
      store.write('acc4', {'x': 1});
      store.write('acc4', {'y': 2});
      expect(store.read('acc4').containsKey('x'), isFalse);
      expect(store.read('acc4')['y'], 2);
    });

    test('key 带账号名（避免跨账号串用）', () {
      expect(TaskPrefsStore.keyOf('accA'),
          isNot(TaskPrefsStore.keyOf('accB')));
    });
  });
}
