# 调度架构：现状 → 目标（设计文档 + 台账）

> **状态**：★ **待决策**，尚未动工。本文档是 **R1** 的产物 ——
> 先把"现状 vs 目标"写清楚，供审阅后再单独开一轮实施。
>
> **用户原话（触发本文档）**：
> > "当前的排期是按 `next_run` 来的？总感觉怪怪的。如果是**周期任务**，
> >  不应该是用**当前周期内执行过与否**来判断吗？如果是**临时任务**，
> >  就**不应该存在 `next_run` 的排期**。你觉得对吗。"
>
> **答复**：★ **方向正确**。详见第 2 节。

---

## 1. 现状（实测，附代码位置）

### 1.1 已经是**两套门**，不是只有 `next_run`

| 门 | 位置 | 问的问题 |
|---|---|---|
| **① 到点了吗** | `update_scheduler()`（`config.py`）| `func.next_run < self.scheduler_update_dt` |
| **② 本周期做过了吗** | `_skip_by_period()` → `is_completed_in_period()` | 按 `reset_at` 算周期边界；已成功则跳过 |

```
# config.py:2162 _skip_by_period
period = scheduler.get('period')
if str(period_str).lower() in ('none', ''):
    return False          # ★ period=none（临时任务）-> 【不走】周期判定
```

### 1.2 已经存在的"周期内是否执行过"机制

`module/config/task_state.py`（505 行，**已实现**）:

| 函数 | 作用 |
|---|---|
| `period_key(period, reset_at)` | 按**游戏重置时间**算周期边界（不是机械取自然日）|
| `is_completed_in_period(config, task, period, reset_at, entry_id=)` | ★ **本周期内是否已成功完成** |
| `record_success(config, task, period, reset_at, ...)` | 跑成功时记一笔 |
| `get_count` / `add_count` / `reset_count` | 周期内次数计数 |
| `write_heartbeat` / `read_heartbeat` / `is_online` / `peers_status` | 多实例心跳 |

★ 且 `_skip_by_period` 是**按 `entry_id`** 判断的（C 选项 2）——
队列里同一任务出现多次时，**各条目独立**（各跑各的）。

### 1.3 所以两类任务实际靠什么判"该不该跑"

| 任务类型 | 判据 |
|---|---|
| **周期任务**（daily / weekly / monthly）| ★ **两道门**：`next_run` 到点 **且** 本周期没做过 |
| **临时任务**（`period = none`）| ★ **只有 `next_run` 一道门** |

---

## 2. 问题：`next_run` 一个字段承担了**三件不同的事**

| # | 用途 | 表现 |
|---|---|---|
| **① 时间窗排期** | "这个任务只在 07:00-09:00 能跑，排到明天 07:00" | `next_run_after()` / `AvailabilityWindow` |
| **② 资源 / 次数恢复** | "每天补 1 次，下次 12:00 能跑" | `Resource.next_available()`（`meta.py`）|
| **③ 失败退避重试** | "失败了，1 小时后再试" | `failure_state` + `task_delay(target=cooldown_until)` |

★ **把三件事压进一个字段**，就是"怪怪的"根源。具体症状（本会话已踩到并临时补过）：

| 症状 | 临时修法（已提交） | 反映的问题 |
|---|---|---|
| 任务显示「**等待到点**」但其实是**次数任务**（不该有窗口）| `scheduler_next_run_now()`（清失败记录时把 `next_run` 拉回来）| ① 与 ③ 混用 |
| 全天窗口的 `next_run_after(strict=True)` 算出**明天** | `next_run_after()` 跳过 `is_unrestricted`；加 `fix_stale_next_run_once()` 修盘上坏值 | ① 的表达力不足 |
| 临时任务被排到未来 -> 永远不跑 | `fix_stale_next_run_once()` | ③ 的残留污染 ① |
| 暂停退回队首后可能仍显示「等待到点」| （**未修**，见第 4 节 P-1）| ③ 在暂停后仍生效 |

---

## 3. 目标设计（待审）

### 3.1 核心想法

★ **把"是否完成"与"何时可跑"分开**：

| 概念 | 表达 | 适用 |
|---|---|---|
| **是否该跑（完成态）** | ★ **显式状态**：`period` 内已成功 / 未成功（`task_state` 已有）| 周期任务；临时任务用"队列条目存在与否" |
| **何时可跑（时间约束）** | ★ **只表达"最早可跑时刻"**，不再兼职"完成判定" | 有窗口 / 有资源恢复的任务；**临时任务可以没有** |

### 3.2 具体提议

| # | 提议 | 说明 |
|---|---|---|
| **T1** | ★ **`next_run` 语义收紧为"下次可跑的**最早**时刻"** | 它**只**回答"现在能不能跑"，**不再**承担"是否已完成"。完成判定一律走 `task_state` |
| **T2** | ★ **临时任务（`period=none`）不写 `next_run`**（或写为一个恒为"现在"的哨兵）| 它的"该不该跑"由**队列**决定：在队列里且未被跳过 -> 就跑 |
| **T3** | 周期任务**去掉 `next_run` 这道门**，只留"本周期是否已完成" | 需要窗口时，把窗口判定**单独**加一道（它本来就是独立概念）|
| **T4** | 失败退避**独立成字段**（如 `retry_after`）| 不再借用 `next_run`；判定时 `now < retry_after -> 跳过` |
| **T5** | 界面「slot」的取值与来源**写死文档** | `pending` / `waiting` / `done` / `blocked` 各自的**唯一**判据 |

### 3.3 ★ 迁移与兼容（必须一起设计）

| 关注点 | 提议 |
|---|---|
| 旧配置里的 `next_run` | 保留读入；按 T1-T4 重新解释（**不删字段**，避免破坏旧配置）|
| `task_state` 现有状态文件 | 已有 `period_key`，可直接复用；临时任务**不需要**迁移 |
| 全部 `next_run` 调用点 | 需**逐个人工审**（界面、端点、调度、测试）—— 见第 5 节工作量 |
| 现有测试 | ★ **1737 条**后端测试覆盖现行为；改完必须**全部重审**（不能只是跑绿）|

### 3.4 为什么**不能**在本次会话顺手动

| 风险 | 说明 |
|---|---|
| 改错会**静默不跑** | 调度不发任务，且**没有报错** |
| 改错会**狂跑** | 反而触发封号风险 |
| 两者都**难查** | 没有单元测试能覆盖"真实时间流逝 + 多任务竞争" |
| 影响面 | `update_scheduler` / `task_delay` / `task_call` / `next_run_after` / `task_state` / 窗口判定 / 全部界面 slot 显示 |

★ **结论**：**另开一轮**，先把本文件审完，再动手。

---

## 4. ★★ 台账（**待办，不要忘记**）

> ★ 本节的每一条都是**已确认要做、但因故推迟**的事项。
> **实施时必须逐条核对**，不要漏。

### P-1 暂停调度：退回队首后应显示「待执行」而非「等待到点」

| 项 | 内容 |
|---|---|
| **用户原话** | > "原先的设计是**暂停后，正在运行的自动退回到执行顺序队首，状态为待执行**，目前测试发现是**有出入**的，请仔细检查。" |
| **我的实测**（`PUT /pause` 直调 5 场景，全部 PASS）| 退回队首 ✓ · 补进队首 ✓ · 已在队首不破坏 ✓ · 无运行任务不报错 ✓ · 同名两条不丢 ✓ |
| ★ **发现的缺口 1** | `put_pause`（`schema_router.py:2657-2745`）**完全没有碰 `next_run`** —— 函数体里 `scheduler_next_run_now` / `next_run` **都不存在**。而"待执行 vs 等待到点"**完全由 `next_run` 决定**（`next_run <= now` → `slot='pending'` → 界面「待执行」）|
| ★ **发现的缺口 2** | 退回时按**任务名**找条目：`idx = next((i for i, e in enumerate(entries) if getattr(e, 'task', None) == task), None)` —— **忽略 `entry_id`**，同名多条会**选错那一条** |
| **时序根因** | 暂停请求**先**完成（此时 `next_run` 还是旧值）→ 任务在安全点停下 → `task_delay` 才把 `next_run` 排到**未来**。所以最终盘上是未来值 ⇒ 显示「等待到点」 |
| **⚠ 未确认** | 我的探针里那一项**偶然**变成了"现在"（`05:53:09`），说明还有**另一条路径**也会改它（`failure_state` 清除时调 `scheduler_next_run_now`）。**那条路径尚未查清**，所以不敢断言"实测必现" |
| **拟修法** | ① `put_pause` 退回时**同时** `scheduler_next_run_now(task)`；② 退回改用 `entry_id` 精确定位；③ 加测试断言 `next_run <= now` 且 slot 为 `pending` |
| **何时做** | ★ **用户裁定：等第 4 项（架构）完成后一起整** |
| **与架构的关系** | ★ 它本身就是"`next_run` 兼职完成判定"的症状之一（见第 2 节），所以**放进架构重构一起做更合理** |

### P-2 休息条目：与普通行完全同构 + 去 `'__rest__'`

| 项 | 内容 |
|---|---|
| **用户裁定** | > "**全删**"（`'__rest__'` 特殊标记）<br>> "休息**当然就是挡住后边的**，本质为了**防封**，**符合预期**" |
| **要删的三处** | ① `config.py:1752` `_tag_and_place_rest` 里的 `sorted(...)`<br>② `config.py:1844` `place_rest_last()`（并被 `schema_router.py:1087` / `:1245` 调用）<br>③ 前端 `task_list_controller.dart:1200` 的 `'__rest__'` 标记 + `_sameGroupReorder` 的 rank 分支 |
| **要保留的** | ★ **`rest_interleave`（"休息时可穿插定时任务"）必须保留** —— 见 `config.py:1936-1945` `can_interleave_timed` 判定。<br>用户原话提醒："休息任务的实现别忘了有个功能是可以选择**定时任务插进来**" |
| **改错的注释** | `config.py:1727-1731` 把"任意拖，但休息仍强制排最后 / 任何模式任何情况都排最后"**改写成用户真实意图**："休息也是任务，只是可以选择插入定时任务" |
| **副作用（用户已确认接受）** | 休息被拖到中间 -> 它**后面**的任务会等到休息结束才跑。★ **用户明确说这是预期**（防封）|

### P-3 循环任务（队列整体循环）

| 项 | 内容 |
|---|---|
| **用户定义** | > "循环任务是指**队列整体循环：跑完最后一条后从头再来**（而不是停下 / 回庭院），界面在执行队列的某个按钮。" |
| **落点** | `class WhenTaskQueueEmpty`（`tasks/Script/config_optimization.py:12`）**新增 `LOOP = 'loop'`**；后端 `script.py:426 _handle_wait_during_idle` 的 `strategy_map` 加分支；前端「跑空后」下拉自动多一项（选项来自后端 schema）|
| ★ **循环范围（用户裁定）** | > "循环只循环**临时任务**和**周期内未执行过的周期任务**" |
| **即** | `period=none` → 每轮都排；周期任务 → 仅当 `is_completed_in_period() == False` 时排；**本周期已做过的周期任务跳过、不重排** |
| ★ **最小间隔** | > "临时任务本来就要循环啊，这个问题是**用户使用策略问题，不应该被咱们考虑**，用户自己可以选择**添加休息时间**来避免狂刷"<br>⇒ ★ **不加间隔**（由用户自己加休息条目控制）|
| **为什么天然不空转** | 周期性任务因为"本周期已做"被跳过 ⇒ 只有"还没做"的才会被重排 ⇒ 不会出现"整队反复重跑" |
| **与架构的关系** | ★ 依赖第 2 节的目标设计（"该不该跑"与"何时可跑"分离）才能真正干净；**先做 P-2，P-3 可在架构前先用最小改法落地** |

### P-4 ★ 调度架构重构（本文档主体）

见第 1-3 节。**状态：待审**。

---

## 5. 工作量预估（供排期参考）

| 子项 | 需要动的文件 | 风险 |
|---|---|---|
| T1 `next_run` 语义收紧 | `config.py`（多处）、`script.py`、界面 slot 判定 | 中 |
| T2 临时任务不写 `next_run` | `task_delay` / `task_call` / `update_scheduler` | ★ **高** |
| T3 周期任务去掉 `next_run` 门 | `update_scheduler` / `_skip_by_period` | ★ **高** |
| T4 失败退避独立字段 | `failure_state` / `script.py` / `task_delay` | 中 |
| T5 slot 文档化 | 界面 + 端点 + docs | 低 |
| 测试重审 | `tests/` 全部（1737 条）| ★ **高**（工作量大）|

---

## 6. 相关代码索引（便于实施时定位）

| 主题 | 位置 |
|---|---|
| 队列清单 | `config.py:1648 build_queue()` |
| 周期完成记忆 | `config.py:2162 _skip_by_period()` |
| 周期状态存储 | `module/config/task_state.py`（`is_completed_in_period` / `record_success` / `period_key`）|
| 下次可跑时刻 | `config.py:2267 next_run_after()` |
| 排期写入 | `config.py:2500 task_delay()`、`config.py:2476 task_call()` |
| 把 next_run 拉回现在 | `config.py:2087 scheduler_next_run_now()` |
| 调度主循环 | `script.py:331`（`get_next()` → `next_run <= now` → `_handle_wait_during_idle`）|
| 队列跑空策略 | `script.py:420 _handle_wait_during_idle()`、`script.py:395`（排队/关模拟器）|
| 休息阻塞 + 穿插 | `config.py:1888 apply_run_list_blocker()`、`config.py:1936 can_interleave_timed` |
| 暂停 + 退回队首 | `schema_router.py:2657 put_pause()` |

---

# 附录 A：P-2 实施记录（**后端已完成**）

| 项 | 状态 |
|---|---|
| `config.py` `_tag_and_place_rest()` 的 `sorted(...)` | 已删 |
| `config.py` `place_rest_last()` | 改为**直通**（保留名字与两个调用点）|
| 两处误导性注释（"任何模式、任何情况都排最后"）| 改写为用户真实意图 |
| 后端提交 | `832f467e`（已推送）|
| 后端测试 | 1739 passed（另 4 条**既有**环境依赖失败，见附录 B）|

**测试改动**（原来的测试正是在断言被删掉的行为）：

* `tests/module/config/test_segment_rest_position.py`
  `TestRestAlwaysLast` -> **`TestRestKeepsUserPosition`**（19 条通过）
* `tests/module/server/test_drag_is_free.py`
  `TestRestIsNormalizedNotRejected` -> **`TestRestKeepsItsPosition`**（11 条通过）

**实测**：磁盘 `run_list` 与 `build_run_list()` 都**保持用户顺序**
（rest 在第一 / 中间 / 最后都原样；多个 rest 之间保序）。

## P-2 前端待做（**未完成**）

| # | 要改的地方 | 说明 |
|---|---|---|
| 1 | `lib/controller/task_list/task_list_controller.dart:1200` | 删掉 `__rest__` 段名标记（后端已无约束，此标记只剩显示噪音）|
| 2 | 同文件 `_sameGroupReorder` 的 `__rest__ -> rank 2` 分支 | 删掉 |
| 3 | `lib/views/tasks/queue_panel.dart:1099`、`lib/views/tasks/task_list_view.dart:1893` | "休息条目总是排在最后"的界面说明文字要改 |
| 4 | 休息行的"次数"编辑 UI | 与普通行统一（`minutes` 呈现为"分钟"）|
| 5 | **重建** | 改完必须干净重建并覆盖 `D:\OASX-app`（用户实际运行的目录）|

---

# 附录 B：4 条**既有**测试失败（**与本次改动无关**，勿误判为回归）

| 测试 | 失败原因 |
|---|---|
| `test_entry_id.py::TestPendingCarriesEntryId::test_pending_items_carry_entry_id` | `pending` 项没有 `entry_id` |
| `test_execution_queue.py::TestBuildQueue::test_auto_tasks_are_appended` | 队列里有 `task=''`（即 `rest`）被当成"未启用的自动任务" |
| `test_queue_clear_and_settings.py::TestClearQueueEndpoint::test_disables_auto_queue_tasks` | `disabled` 为空 —— 没有 `auto_queue` 任务可停用 |
| `test_schema_router.py::TestOverview::test_at_least_one_task_outside_window` | 没有任务在窗口外 |

**验证方法**：把 `config.py` 还原成改动前的备份，这 4 条**同样失败**；
恢复改动后**仍同样失败** => 与 P-2 **无关**。

**共同根因（推断）**：它们跑**真实配置**（`恋鸟树`），而用户已把自动补齐的任务
**都编排进 `run_list`** => "没有待自动补齐的任务" => 这些断言的前置条件不成立。

**建议**（另开一轮）：把它们改成**自建前置条件**（用临时配置名构造需要的状态），
而不是依赖用户的真实配置 —— 否则每次用户改配置都会让它们红/绿，测试就失去意义。