# 调度架构：现状 → 目标（设计文档 + 台账）


---

# 附录 A：P-2 实施记录（**后端已完成**）

| 项 | 状态 |
|---|---|
| `config.py` `_tag_and_place_rest()` 的 `sorted(...)` | ✅ **已删** |
| `config.py` `place_rest_last()` | ✅ 改为**直通**（保留名字与两个调用点）|
| 两处误导性注释（"任何模式、任何情况都排最后"）| ✅ 改写为用户真实意图 |
| 后端提交 | `832f467e`（已推送）|
| 后端测试 | 1739 passed（另 4 条**既有**环境依赖失败，见附录 B）|

**测试改动**（原来的测试正是在断言被删掉的行为）：

* `tests/module/config/test_segment_rest_position.py`
  `TestRestAlwaysLast` -> **`TestRestKeepsUserPosition`**（19 条通过）
* `tests/module/server/test_drag_is_free.py`
  `TestRestIsNormalizedNotRejected` -> **`TestRestKeepsItsPosition`**（11 条通过）

**实测**：磁盘 `run_list` 与 `build_run_list()` 都**保持用户顺序**
（rest 在第一 / 中间 / 最后都原样；多个 rest 之间保序）。

## ★ P-2 前端待做（**未完成**）

| # | 要改的地方 | 说明 |
|---|---|---|
| 1 | `lib/controller/task_list/task_list_controller.dart:1200` | 删掉 `'__rest__'` 段名标记（后端已无约束，此标记只剩显示噪音）|
| 2 | 同文件 `_sameGroupReorder` 的 `'__rest__' -> rank 2` 分支 | 删掉 |
| 3 | `lib/views/tasks/queue_panel.dart:1099`、`lib/views/tasks/task_list_view.dart:1893` | "休息条目**总是排在最后**"的**界面说明文字**要改 |
| 4 | 休息行的"次数"编辑 UI | 与普通行统一（`minutes` 呈现为"分钟"）|
| 5 | ★ **重建** | 改完必须干净重建并覆盖 `D:\OASX-app`（用户实际运行的目录）|

---

# 附录 B：4 条**既有**测试失败（**与本次改动无关**，勿误判为回归）

| 测试 | 失败原因 |
|---|---|
| `tests/module/config/test_entry_id.py::TestPendingCarriesEntryId::test_pending_items_carry_entry_id` | `pending` 项没有 `entry_id` |
| `tests/module/config/test_execution_queue.py::TestBuildQueue::test_auto_tasks_are_appended` | 队列里有 `task=''`（即 `rest`）被当成"未启用的自动任务" |
| `tests/module/config/test_queue_clear_and_settings.py::TestClearQueueEndpoint::test_disables_auto_queue_tasks` | `disabled` 为空 —— 没有 `auto_queue` 任务可停用 |
| `tests/module/server/test_schema_router.py::TestOverview::test_at_least_one_task_outside_window` | 没有任务在窗口外 |

★ **验证方法**：把 `config.py` 还原成改动前的备份，这 4 条**同样失败**；
恢复改动后**仍同样失败** ⇒ 与 P-2 **无关**。

★ **共同根因（推断）**：它们跑**真实配置**（`恋鸟树`），而用户已把
自动补齐的任务**都编排进 `run_list`** ⇒ "没有待自动补齐的任务"
⇒ 这些断言的前置条件不成立。

★ **建议**（另开一轮）：把它们改成**自建前置条件**
（用临时配置名构造需要的状态），而不是依赖用户的真实配置 ——
否则每次用户改配置都会让它们红/绿，测试就失去意义。
