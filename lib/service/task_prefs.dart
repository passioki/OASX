import 'dart:convert';

import 'package:get_storage/get_storage.dart';

/// 任务表格的**多列排序 + 筛选偏好**，并**持久化记忆**。
///
/// ## 用户要求
///
/// > 支持多列排序筛选且可以**持久记忆**用户的偏好，同时可以**恢复默认**
/// > （有相关功能说明和弹窗提示）
///
/// ## 设计：把"排序规则"做成数据，而不是散落的 if
///
/// ```dart
/// SortSpec(column: 'next_run', ascending: true)
/// ```
///
/// 这样:
/// * 纯函数 `apply()` 可被**直接测试**（不必起界面）
/// * 持久化只是把对象序列化成 JSON
/// * 加新列只改一个表 `_accessors`
///
/// ★ 排序**只影响显示顺序**，**不影响调度**（用户明确选了这个方案）。
///   调度顺序由运行列表（`run_list`）与类别规则决定 ——
///   如果这里偷偷改了调度，用户会以为"排序等于调顺序"。
class TaskSortSpec {
  const TaskSortSpec({required this.column, this.ascending = true});

  /// 列 id（见 [TaskSorter.columns]）。
  final String column;

  /// 是否升序。
  final bool ascending;

  TaskSortSpec copyWith({String? column, bool? ascending}) => TaskSortSpec(
        column: column ?? this.column,
        ascending: ascending ?? this.ascending,
      );

  Map<String, dynamic> toJson() =>
      {'column': column, 'ascending': ascending};

  static TaskSortSpec? fromJson(dynamic v) {
    if (v is! Map) return null;
    final col = '${v['column'] ?? ''}';
    if (col.isEmpty) return null;
    return TaskSortSpec(column: col, ascending: v['ascending'] != false);
  }

  @override
  bool operator ==(Object other) =>
      other is TaskSortSpec &&
      other.column == column &&
      other.ascending == ascending;

  @override
  int get hashCode => Object.hash(column, ascending);

  @override
  String toString() => 'TaskSortSpec($column, ${ascending ? "asc" : "desc"})';
}

/// 排序 + 筛选偏好的**纯逻辑**（无 UI、无 IO）。
class TaskSorter {
  /// 可排序的列。
  ///
  /// `id` 用于持久化（**改 id 会让老偏好失效**，所以用稳定的英文标识）。
  static const columns = <Map<String, String>>[
    {'id': 'name', 'label': '任务名'},
    {'id': 'category', 'label': '类型'},
    {'id': 'state', 'label': '状态'},
    {'id': 'target', 'label': '目标次数'},
    {'id': 'progress', 'label': '进度 / 存量'},
    {'id': 'next_run', 'label': '下次运行'},
    // 定时任务内部排序的最终裁判（数字小的先跑）
    {'id': 'priority', 'label': '优先级'},
    // "休息时可穿插"的判据输入
    {'id': 'expected', 'label': '预期耗时'},
    {'id': 'record_runs', 'label': '累计次数'},
    {'id': 'record_seconds', 'label': '累计耗时'},
  ];

  /// 默认排序 —— 与原型一致（按"下次运行"升序）。
  static const defaultSpec = TaskSortSpec(column: 'next_run');

  static bool isKnownColumn(String id) =>
      columns.any((c) => c['id'] == id);

  /// 取某行的排序键。
  ///
  /// ★ 缺失值要给**同类型的兜底**，不能返回 `null` ——
  ///   `null` 与 `String` 混在一起比较会抛
  ///   `TypeError: '<' not supported between instances`。
  ///   （这个坑在本项目的后端 `_order_by_timed_priority` 里踩过一次。）
  static Comparable _key(Map<String, dynamic> task, String column,
      Map<String, dynamic> record) {
    switch (column) {
      case 'name':
        return '${task['name_zh'] ?? task['name'] ?? ''}';
      case 'category':
        return '${task['category'] ?? ''}';
      case 'state':
        // 能跑 < 不能跑（升序时"能跑的"在前）
        return task['can_run'] == true ? 0 : 1;
      case 'target':
        return (task['target'] as num?)?.toInt() ?? 0;
      case 'progress':
        final ch = task['charges'];
        if (ch is Map) return (ch['count'] as num?)?.toInt() ?? 0;
        return (task['count'] as num?)?.toInt() ?? 0;
      case 'next_run':
        // 空值给一个远期字符串, 保证同类型可比
        return '${task['next_run'] ?? '9999'}';
      case 'priority':
        // 数字小的先跑；缺失给一个大值排后面
        return (task['priority'] as num?)?.toInt() ?? 99;
      case 'expected':
        // 0（未知）排后面 —— 它与"很快能跑完"是两回事
        final e = (task['expected_minutes'] as num?)?.toInt() ?? 0;
        return e > 0 ? e : 99999;
      case 'record_runs':
        return (record['runs'] as num?)?.toInt() ?? 0;
      case 'record_seconds':
        return (record['seconds'] as num?)?.toInt() ?? 0;
      default:
        return '';
    }
  }

  /// 排序（**稳定**）。
  ///
  /// :param recordOf: `command -> 运行记录`（`record_runs`/`record_seconds` 用）
  static List<Map<String, dynamic>> apply(
    List<Map<String, dynamic>> tasks,
    TaskSortSpec spec, {
    Map<String, dynamic> Function(String command)? recordOf,
  }) {
    final col = isKnownColumn(spec.column) ? spec.column : defaultSpec.column;
    final list = List<Map<String, dynamic>>.from(tasks);
    // ★ 用 `index` 做最终裁判, 保证**稳定排序** ——
    //   否则同键的行每次刷新都会跳来跳去, 看起来像"闪"。
    final indexed = <MapEntry<int, Map<String, dynamic>>>[
      for (var i = 0; i < list.length; i++) MapEntry(i, list[i]),
    ];
    indexed.sort((a, b) {
      final ra = recordOf?.call('${a.value['command'] ?? ''}') ?? const {};
      final rb = recordOf?.call('${b.value['command'] ?? ''}') ?? const {};
      final ka = _key(a.value, col, ra);
      final kb = _key(b.value, col, rb);
      int c;
      try {
        c = ka.compareTo(kb);
      } catch (_) {
        c = 0; // 类型意外不一致时不当机, 保持原序
      }
      if (c == 0) return a.key.compareTo(b.key);
      return spec.ascending ? c : -c;
    });
    return [for (final e in indexed) e.value];
  }
}

/// 偏好存储的**接口**。
///
/// ★ 为什么要抽接口: `GetStorage` 依赖 `path_provider` **插件**,
///   在 `flutter test`（无平台通道）里会抛
///   `MissingPluginException: ... getApplicationDocumentsDirectory`。
///
///   抽成接口后:
///   * 生产用 [TaskPrefsStore]（真落盘）
///   * 测试用 [MemoryPrefsStore]（内存）—— 于是**逻辑可被测试**,
///     而不是"因为拿不到插件所以不测"
abstract class PrefsStore {
  Map<String, dynamic> read(String scriptName);

  void write(String scriptName, Map<String, dynamic> prefs);

  void clear(String scriptName);
}

/// 内存实现 —— 只为测试与"禁用持久化"的场景。
class MemoryPrefsStore implements PrefsStore {
  final _data = <String, Map<String, dynamic>>{};

  @override
  Map<String, dynamic> read(String scriptName) =>
      Map<String, dynamic>.from(_data[scriptName] ?? const {});

  @override
  void write(String scriptName, Map<String, dynamic> prefs) {
    _data[scriptName] = Map<String, dynamic>.from(prefs);
  }

  @override
  void clear(String scriptName) => _data.remove(scriptName);
}

/// 排序 + 筛选偏好的**持久化**（`GetStorage` 真落盘）。
///
/// 按账号隔离 —— 不同账号的任务集不同，共享偏好会很别扭。
class TaskPrefsStore implements PrefsStore {
  TaskPrefsStore({GetStorage? box}) : _box = box ?? GetStorage();

  final GetStorage _box;

  static String keyOf(String scriptName) => 'task_prefs_$scriptName';

  /// 读该账号的偏好（读不到/坏了都给默认，**不抛**）。
  @override
  Map<String, dynamic> read(String scriptName) {
    try {
      final raw = _box.read(keyOf(scriptName));
      if (raw == null) return {};
      if (raw is Map) return raw.cast<String, dynamic>();
      if (raw is String && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return decoded.cast<String, dynamic>();
      }
    } catch (_) {
      // 偏好坏了不该让任务列表打不开
    }
    return {};
  }

  @override
  void write(String scriptName, Map<String, dynamic> prefs) {
    try {
      _box.write(keyOf(scriptName), prefs);
    } catch (_) {
      // 存不下就算了（只读文件系统等），不影响使用
    }
  }

  /// 恢复默认 —— **删掉**该账号的偏好记录。
  @override
  void clear(String scriptName) {
    try {
      _box.remove(keyOf(scriptName));
    } catch (_) {}
  }
}
