# 休息任务（乙-A）实施台账

> ## ⚠⚠ 这份文件**不是** `docs/scheduler-architecture.md`
>
> ★ 项目里有**两份**东西容易混（我踩过，且因此**覆盖过一次台账**）:
>
> | 文件 | 内容 | 权威性 |
> |---|---|---|
> | **`docs/scheduler-architecture.md`** | **调度域唯一权威设计文档**（实体层/集合层/不变量/CRUD/联动矩阵）| ★ **权威** —— 与它冲突时**改别的，不改它** |
> | **本文件**（`docs/REST-TASK-LEDGER.md`）| 某次会议的**实施台账**（待办 P-1~P-4 + 实施记录 + 既有失败清单）| 过程记录 |
>
> ★ **教训**: 我第一版把台账也叫 `scheduler-architecture.md`，然后
> "从 OAS 同步到 OASX" 时用 `WriteAllBytes` **把台账覆盖掉了**
> （`61c75f5` / `c3c0fc1`）。★ 同名的两份文档 + 自动同步 = 必然覆盖。
> **改名 + 这段说明** 就是为了不再犯。

---

# 调度架构：现状 → 目标（设计文档 + 台账）

> **状态**：★ **分部分**（别被"待决策"误导 —— 那只是 P-4）——
>
> | 部分 | 状态 |
> |---|---|
> | **P-2 休息条目同构** | ✅ **已完成**（含"休息=真正的任务"乙-A，见**附录 D**）|
> | **P-3 循环任务** | ✅ **已完成**（`6a1d9fdf`，见**附录 F**）|
> | **P-4 调度架构重构** | ★ **待决策**（用户选 R1 = 先写文档，后动工）|
> | **P-1 暂停修法** | ✅ **已完成**（`fe69d25f`，见**附录 H**；★ 提前做了 —— 它与 P-4 解耦）|
>
> 本文档的 **1-3 节**是 **R1** 的产物（P-4 的现状 vs 目标），尚未动工。
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

| ⚠ **要点** | ★ `get_next()` 选的是**全局最近 `next_run`**（不一定是队首）—— 所以"跑完最后一条就从头"必须**主动重排** `next_run`，不能只靠"队列空了" |

#### ⚠「空转」澄清（用户问过，我第一版表述不准）

用户原话：
> "**为什么会空转，设计的初衷是没到点的任务不会被执行啊，应该会直接跳过啊，
>  难道不是这么实现的吗。**"

★ **用户说得对，我第一版表述不准**：

| 我的说法 | 实际 |
|---|---|
| ~~"会疯狂空转"~~ | ★ **不对**。正常调度**不会空转** —— 用 `_handle_wait_during_idle()` **睡到最近的 `next_run`**；没到点的任务**根本不会被派发** |

★ **"循环"的真正副作用**（核对代码后确认）：
`get_next()` 选**全局最近 `next_run`** ⇒ "跑完最后一条"之后
**没有任何机制会"从头开始"** —— 调度器只会**等**最早到点的那个。
★ 要实现"循环"必须**主动重排 `next_run`** —— 那才是"空转"风险的来源
（**不是**"没到点被派发"）。

★ **用户对循环范围的裁定**（消除了大部分风险）：
> "循环只循环**临时任务**和**周期内未执行过的周期任务**"

⇒ "本周期已做"的周期任务**不会**被重排 ⇒ **天然避免**整队反复重跑。
★ 用户另裁定：**不加最小间隔** ——
> "临时任务本来就要循环啊，这个问题是**用户使用策略问题，不应该被咱们考虑**，
>  用户自己可以选择**添加休息时间**来避免狂刷。"

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
| 后端测试 | 当时 1739 passed（★ 最新见**附录 D.4**：1746 passed）|

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


---

# 附录 D：乙-A「休息 = 真正的任务」实施记录（**本次会话完成**）

> **用户定义（第三次提出，以此为准）**：
> > **休息就是临时任务（回庭院待着），只不过可以选择被定时任务插队。**
>
> **用户裁定**：
> > **乙-A**（休息是真正的任务，分钟数复用通用的 `scheduler.target`）
> > **乙**（`auto_queue=False` —— 用户主动添加）
> > "**1，读，不满足就跳过。默认是临时任务，无周期的。**"
> > "**2，可以，只要不要字段混乱就行。**"

## D.1 交付（4 片）

| 片 | 提交 | 内容 |
|---|---|---|
| 1 | OAS `ca0ba60e` | ★ 新建 `tasks/Rest/`（4 文件，**零改动中心文件**）+ `template.json` + i18n |
| 2 | OAS `49f86403` | 休息时长**优先取任务节点** `rest.scheduler.target` |
| 3 | OAS `2023d4bf` / OASX `6823ec8` | ★ 配置迁移（补缺失节点）+ `auto_queue=False` + 前端「添加休息」改为加 `Rest` 任务 |
| 4 | OAS `5193131c` | ★ 门禁（不满足就跳过）+ 旧 `kind='rest'` 条目**迁移** |

## D.2 关键设计（为什么这样做）

### 1. 休息是 `tasks/Rest/` 里的**真任务**，不新增字段

用户：**"有 `period` 和 `window` 属性, 是为了统一管理。"**

| 需求 | 落点（★ 全是**通用**字段）|
|---|---|
| 分钟数 | ★ `scheduler.target`（那个"目标次数"框 —— 对休息语义就是**分钟**）|
| 周期 | `scheduler.period`（★ 默认 `none` → 分进**临时任务**）|
| 窗口 | `scheduler.windows`（★ 可收到 12:00-14:00 → "只在这个时段休息"）|
| 启停 | `scheduler.enable` |

★ **零新字段** —— 这就是"统一管理"。

### 2. "空置任务天然带来阻塞"（用户洞察，已用代码核实）

> 用户：**"休息作为空置任务它本身就会带来阻塞的效果。"**

★ **对**。核实：`_order_by_queue()` 里 `if not cmd: continue`
—— 休息**不参与"哪些任务能跑"的判定**；
它只在**被执行到的那一刻**通过 `apply_run_list_blocker()` 阻塞整个队列。

### 3. 两道迁移（都**不需要一次性标记**，天然幂等）

| 迁移 | 判据 | 为什么不需要标记 |
|---|---|---|
| `migrate_missing_task_nodes_once()` | 模型里有没有这个节点 | 补上就"有"了 |
| `migrate_rest_entries_once()` | 列表里还有没有 `kind='rest'` | 迁移完就没了 |

★ 两者都：**只补/只改"不存在"的东西** —— 用户改过的值**绝不覆盖**。

## D.3 实测证据

```
① 门禁
   period=none,  enable=True  -> rest_is_open = True    ✓（默认不误挡）
   period=daily, enable=True  -> rest_is_open = True    ✓
   period=none,  enable=False -> _task_enabled = False  ✓（跳过）

② 休息时长（`_rest_minutes`）
   节点 target=45, 条目 minutes=5  -> 45   ✓（节点权威）
   节点 target=0,  条目 minutes=7  -> 7    ✓（向后兼容）
   两边都 0                        -> 30   ✓（可见默认）
   无 rest 节点,   条目 minutes=9  -> 9    ✓（不崩）

③ 迁移（补节点）
   迁移前 rest=False 顶层键=57 -> 迁移后 rest=True 顶层键=58  period='none'  ✓
   幂等: 第二次仍是 58 ✓        用户值未被覆盖 ✓

④ 迁移（旧 rest 条目）
   迁移前 ['task','rest','task'] -> 迁移后 [Exploration, Rest, RealmRaid]  ✓
   ★ target = 45（分钟数搬过去了）  无 kind=rest 残留 ✓  幂等 ✓
```

## D.4 测试

| 项 | 结果 |
|---|---|
| 后端 | ★ **1746 passed / 4 failed**（4 个是**既有基线失败**，跑真实配置）|
| 前端 | `flutter analyze lib` **0 error** · `flutter test` **148 passed** |

★ 修正了 **5 个测试文件**里因"休息从特殊条目变成任务"而失效的断言，
其中两个测试**钉的是已废除的约束**（"休息恒最后"）：
* `test_queue_sort.py`：`test_rest_always_last` -> `test_rest_is_a_normal_task`
* `test_category_label_consistency.py`：`test_rest_still_last` -> `test_rest_is_a_normal_task`
* ★ `test_auto_queue_matches_countable` / `test_count_tasks_only_when_ordered`：
  **显式豁免 `Rest` 并写明理由**（它是 `auto_queue=False` 却 **非次数任务**的控制类条目）

## D.5 ⚠ 部署前提：**必须重启后端**

★ 新任务节点要**重启后端**才进 schema（实测：旧进程 schema 只有 54 个任务，
无 `Rest`）。重启后**两道迁移自动跑**。

## D.6 ⏳ 仍未完成（见 P-1 / P-3 / P-4）

| 项 | 状态 |
|---|---|
| **P-1** 暂停退回队首显示"待执行" | ⏳ 用户裁定"等 P-4 完成后一起整" |
| **P-3** 循环任务（`WhenTaskQueueEmpty.LOOP`）| ⏳ **未开始** |
| **P-4** 调度架构重构（`next_run` 兼职三件事）| ⏳ **未开始**（用户选 R1 = 先文档）|

★ 另：前端 `queue_panel.dart` 里**旧的 `kind='rest'` 渲染分支**用户裁定
**保留**（保守：万一有别的客户端/旧配置还会写这种条目）。


---

# 附录 F：P-3「队列循环」实施记录（**本次会话完成**）

## F.1 用户裁定（原文）

> "**循环任务是指队列整体循环：跑完最后一条后从头再来**
>  （而不是停下 / 回庭院），界面在执行队列的某个按钮。"

> "**循环只循环临时任务和周期内未执行过的周期任务**，这样是不是没有遗漏了"

> "**临时任务本来就要循环啊，这个问题是用户使用策略问题，不应该被咱们考虑，
>  用户自己可以选择添加休息时间来避免狂刷**"

## F.2 交付（提交 `6a1d9fdf`）

| 文件 | 改动 |
|---|---|
| `tasks/Script/config_optimization.py` | `WhenTaskQueueEmpty` 新增 **`LOOP = 'loop'`** |
| `module/server/schema_router.py` | `queue_labels` 加 `loop -> '队列循环'` |
| `module/config/config.py` | 新增 **`reset_loop_next_run()`** |
| `script.py` | `get_next_task()` 里接线 + ★ 轻量节流 |

★ **前端零改动** —— 「跑空后」下拉的选项由后端 `for k in WhenTaskQueueEmpty`
  生成，**自动多一项**。

## F.3 关键设计

### 为什么必须**主动重排** `next_run`

`get_next()` 选的是**全局最近 `next_run`**（不一定是队首）。
所以"跑完最后一条"之后**没有任何机制会"从头开始"** ——
调度器只会**等**最早到点的那个。
★ 要实现循环，只能**主动把 `next_run` 拉回现在**。

### 重置范围（用户两条 + 三条安全边界）

| 任务 | 重置? | 判据 |
|---|---|---|
| ★ **临时任务**（`period=none`）| ✅ | 没有"本周期"概念 |
| ★ **周期任务，本周期还没做过** | ✅ | `is_completed_in_period()` == False |
| 周期任务，本周期**已做** | ❌ | ★ "没有遗漏"的关键 |
| 未启用 | ❌ | `_task_enabled()` |
| 不在执行队列 | ❌ | 队列是唯一调度依据（§2.2）|
| 有窗口且**当前不在窗口内** | ❌ | 重排了也跑不了 |

★ **天然不空转**: "本周期已做"的周期任务**不重排** ->
只有"还没做"的才会 -> 不会"整队反复重跑"。

### ★ 节流 5 秒（与用户"不加最小间隔"**不矛盾**）

| 概念 | 归属 | 做法 |
|---|---|---|
| **要不要连续刷** | ★ **用户策略** | 用户裁定**不加间隔** —— "用户自己可以选择**添加休息时间**来避免狂刷" |
| **防热循环** | ★ **实现缺陷** | 若一个任务**几秒完成**，无节流会**把 CPU 打满**。所以给 **5 秒**节流（只重置一次）|

★ 两件事分开: 5 秒节流**不阻止**连续循环，只防止"瞬间完成 -> 立刻重开"。

## F.4 实测

```
Exploration period = 'none'
AbyssShadows period = 'daily'
① 都被重置（临时任务 + 周期未做）: ['Exploration', 'Restart', ...]  ✓
② 周期任务标记"本周期已做"后 -> 不再被重置                      ✓
③ 未启用 -> 不再被重置                                          ✓
```

## F.5 ⚠ 待用户确认的一件事

★ **意外发现**: `Restart`（重启游戏）也被重置了 —— 因为它
`auto_queue=True` 且启用。它确实是 `period=none`（临时任务），
按用户给的范围**它该循环**。

⚠ 但这意味着**队列循环会把系统任务（如 `Restart`）也重跑**。
★ 如果这不是用户想要的，需在 `reset_loop_next_run()` 里加一条
"**排除系统任务**"的判据 —— ★ **待用户确认，不擅自加**。

## F.6 测试

**1745 passed / 5 failed** —— ★ 5 个**全是既有基线失败**。
新增的那条 `test_effective_target_matches_count_when_no_override`
（`RealmRaid: effective=50 count=30`）已用
"**暂存改动前后结果完全相同**"验证与本次无关。


---

# 附录 G：P-3b「循环轮数」+「重置循环计数」实施记录

## G.1 用户裁定（原文）

> "我觉得选中后应该加一个**跑几次**的额外输入框, **0代表一直跑**,
>  **1、2……代表跑几次**。"

> "如果要重跑这几次循环要怎么设置呢，我没想好，
>  是不是得有个**手动重置计数到设定值的按钮**"
> -> 在 甲（开始调度时重置）/ 乙（手动按钮）/ 丙（跨天）/ 丁（甲+乙）中选 **乙**

> "**照常跑（我建议）**" —— 到轮数后, 到点的周期任务**照常跑**

（另: A 选 **甲** = "跑几次"指**循环几轮**; B 选 **存盘**）

## G.2 交付

| 仓库 | 提交 | 内容 |
|---|---|---|
| OAS | `a25030f3` | `loop_times` 设置 + `task_state` 三个函数 + `script.py` 轮数控制 + 新端点 + `global_fields` 两个键 |
| OASX | `59f72be` | `api_client.resetLoopRounds()` + 控制器 `loopTimes`/`loopRoundsDone`/`setLoopTimes()`/`resetLoopRounds()` + 界面两个控件 |

## G.3 关键设计

### 两件事必须分开（用户选 B = 存盘）

| 名字 | 性质 | 存哪 |
|---|---|---|
| `script.optimization.loop_times` | ★ **用户设置**（我的意图）| 配置 JSON |
| `loop_rounds`（`task_state`）| ★ **运行进度**（已经跑了几轮）| **状态文件**（存盘）|

★ 分开的好处: "跑 N 轮"是**确定**的（改设置不改已跑进度）; 重启后端**不丢**。

### ★ 为什么"重置"是**清 0** 而不是"设成 `loop_times`"

★ **用户原话里就猜错了方向**（"重置计数**到设定值**"）——
  计数的语义是"**已经跑了几轮**":
  * 清 0 = "一轮都还没跑" -> 可以再跑 N 轮 ✓
  * 设成 N -> `已跑 >= 目标` **仍然成立** -> **还是不会跑**（是**反的**）

★ 所以实现成清 0, 并在代码注释里写清这个坑。

### 到轮数后"照常跑"的实现

★ 到轮数后**只停止"主动重排"** -> 退化成 `goto_main` 的行为 ->
  **到点的周期任务照常跑**（用户裁定）。
  ⚠ 换句话说: 「队列循环」与「回庭院待命」在**用尽轮数后行为相同** ——
    区别只在"跑满之前会不会主动再来一轮"。

### 只读进度也暴露给界面

`global_fields` 加 `loop_rounds_done`（**只读**）——
★ 用户要**看到"还剩几轮"**才会想点重置。这比只给一个按钮更有用。

## G.4 实测

```
loop_times = 2
初始已跑轮数 = 0 -> 跑1轮后 1 -> 跑2轮后 2（已达上限）
★ 重置端点: {"reset": true, "before": 2, "rounds": 0}
★ 重置后 = 0（可再跑 2 轮）
★ 消息: 循环计数已重置（2 -> 0）—— 可以重新跑设定的轮数

task_state 层: bump -> 1,2,3; 读回 3; reset -> 0;
  ★ 另一配置互不影响; ★ 不影响任务计数
```

## G.5 测试

* 后端 **1745 passed / 5 failed**（★ 5 个**全是既有基线失败**）
  ★ 修正 2 条因 `global_fields` 新增字段而失效的**键集守卫**
    （并在测试里写明: 这两个键**不是"模式"**，
     所以"`priority_mode` 不该回来"那条守卫**仍然成立**）
* 前端 `analyze` **0 error** · `test` **148 passed**

## G.6 ★ 部署前提（again）

★ 新字段 / 新端点要**重启后端**才进 schema ——
  实测: 后端 schema 起初只有旧 4 个 `global_fields` 键，
  「跑空后」选项**已有 `loop`**（P-3 的），但 `loop_times` **还没有**（P-3b 的）。


---

# 附录 H：P-1「暂停退回队首」实施记录（**已完成**）

## H.1 用户裁定（原文）

> "原先的设计是**暂停后，正在运行的自动退回到执行顺序队首，状态为待执行**，
>  目前测试发现是有出入的，请仔细检查。"

> "点击暂停调度, 正在运行的任务**自动回退到队列首位, 视作等待执行**"

## H.2 ★★ 实测把台账里的一条旧判断**证伪**了 ★★

台账 P-1 原来记着**两个缺口**。实测后: **一个被证伪、一个被证实**。

### ~~缺口 1: "`put_pause` 没碰 `next_run`"~~ → ★ **证伪**

实测（`Config` 建好**之后**再写未来值，排除"建 Config 时被改"）:

```
① 刚写完盘:        orochi.next_run = 18:53:42（未来）
② 再建 Config 后:  orochi.next_run = 08:53:42（★ 被拉了回来）
```

★ 是 **`Config.__init__` 的"修坏值"机制**（`fix_stale_next_run_once` /
`scheduler_next_run_now`）**顺手**做的 —— 所以界面上**本来就看到"待执行"**。

⚠ **但那是巧合** —— 语义由**别的机制**承担，不该依赖它。
★ 所以本片**显式**再加一次（见 H.3 ③）。

⚠ 我早先那条探针之所以看到"未来值"，是**探针本身的顺序问题**
（在建 `Config` 之前写盘）—— ★ **又一个"探针写错导致误判"的例子**。

### ★ 缺口 2: "只按**任务名**找条目" → **证实了**

队列里同一任务可以有**多条条目**（用户用重复条目表达"重复跑整个任务"）。
实测:

```
队列 = [Exploration(e1), Orochi(e2), Exploration(e3)]
正在跑 e3（第 2 条 Exploration）
★ 只按任务名 -> next(...) 命中 e1 -> 【退错那一条】
```

## H.3 改动

### ① `module/config/config_model.py` —— 新增 `running_entry_id`

★ 为什么必须**落盘**: 脚本跑在**独立进程**（`ScriptProcess`），
HTTP 端（`put_pause`）**拿不到**内存里的 `self.config.task`。

★ 为什么记 `entry_id` 而不是**下标**: 下标会随用户拖动而变
（"**身份，不是位置**" —— §1.5）。

### ② `script.py` —— 任务开始/结束时维护它

### ③ `module/server/schema_router.py` —— `put_pause` 精确匹配

* ★ **优先按 `entry_id`**（落盘的 `running_entry_id`；同进程时用内存的）
* ⚠ **向后兼容**: 老配置 / 拿不到 `entry_id` -> 退回按任务名找
  （行为与改动前**完全一致**）
* ★ **显式** `scheduler_next_run_now(task)` —— 不再依赖 H.2 那个巧合

## H.4 实测（5/5 通过）

```
队列(暂停后) = [('Exploration','e3'), ('Exploration','e1'), ('Orochi','e2')]
PASS  ★ e3（第 2 条）被退到队首
PASS  ★ 没有动错条目（e1 仍在原位）
PASS  ★ 三条都在（没丢）
PASS  ★ 向后兼容: 老配置（无 entry_id）按任务名也能退回
PASS  ★ 退回后 next_run <= now（视作"待执行"）
```

## H.5 测试

**1745 passed / 5 failed**（★ 5 个**全是既有基线失败**）。

★ 更新 `ConfigModel` 字段数断言（59 -> **60**），
  并在测试里**写清每个新字段的来历** —— 否则下一个人不知道该改哪个数。


---

# 附录 I：条目级「次数」—— 修「重复添加后改次数会同步」

## I.1 用户报的 bug（原文）

> "当前临时任务**重复添加**后，修改**次数/时间会同步到所有的同种任务**，
>  而不是分开"

## I.2 根因（架构层）

"次数"原来只存在**任务级** `scheduler.target`:

```
module\server\schema_router.py:676   'target': sch.get('target', 0)
tasks\base_task.py:133               target = int(getattr(sch, 'target', 0) or 0)
```

★ 而队列里同一任务可以有**多条条目**（用户用重复条目表达"重复跑整个任务"，
各带自己的 `entry_id`）。
⇒ 改一条的次数 = 改**任务级**字段 = **所有同任务条目一起变**。

## I.3 用户裁定

| # | 问题 | 裁定 |
|---|---|---|
| 1 | 任务级 `target` 保留为默认值？ | ★ **甲**（保留 —— 老配置不变, 等价于"给每条条目加一个覆盖值"）|
| 2 | 条目级次数给谁用？ | ★ **所有条目** |

## I.4 ★ 用户纠正了我的一个错误判断（记录在案）

我原来问"周期任务要不要也支持条目级次数"，用户指正:

> "定时任务是启用后**自动添加**进队列的，**不在添加任务池里**，
>  应该无法被重复添加，**你是不是看错了**"

★ **用户是对的**, 已实测证实:

```
GET /queue/candidates 规则 (schema_router.py:2378):
    if _auto_queue_of(meta, config): continue      # ★ 自动进队列的【排除】
实测: 候选池 11 个 -> 含 Exploration(临时任务) ✓
                     ★ 不含 DemonEncounter(周期任务) ✓
```

## I.5 改动（照 `entry_id` 的同一条路）

★ `entry_id` **已经是按条目独立传的**（`_order_by_queue()` 里 `deepcopy`
  保证每条一个 `Function`）—— 所以 per-entry target 走**同一条路**即可。

| # | 文件 | 改动 |
|---|---|---|
| 1 | `module/config/run_list.py` | `RunEntry` 新增 **`target`**; `to_dict` **非零才写**; `from_dict` 读它 |
| 2 | `module/config/config.py` | `_order_by_queue()` 把该条目的 target 写进各自的 `Function.target` |
| 3 | 同上 | `Function` 新增 `target`（`None` = 用任务级默认值）|
| 4 | `tasks/base_task.py` | ★ `effective_target()` **优先用条目级**, 0/None 才回落任务级 |

## I.6 实测（3/3 通过）

```
队列条目: Exploration(a, target=5) / Orochi(b) / Exploration(c, target=50)
★ _order_by_queue 返回:
    ('Exploration', 'a', 5)
    ('Exploration', 'c', 50)
PASS  ★ 两条同名条目的 entry_id 不同
PASS  ★ 两条同名条目的 target 不同（5 与 50）
PASS  ★ target 是按 entry_id 对应的
★ 落盘: [{"task":"Exploration","entry_id":"a","target":5}, ...,
         {"task":"Exploration","entry_id":"c","target":50}]
        （`Orochi` 那条**没有** target 键 —— 非零才写）
```

## I.7 ✅ 前端部分已完成（OASX `8bd8bc2`）

★ **核实后修正了原计划**（不猜、按代码事实）:

| 原计划 | 实际核实结果 |
|---|---|
| ① "`/overview` 的 `target` 改成按条目给" | ★ **不需要** —— 前端读次数的正确来源是 `GET /run_list` 的 `entries`（**已经带 `target`**，后端 `48b2f7b5` 加的）。`/overview` 的 `target` 是**任务级默认值**, 在**总览页**用, 那里本就该是任务级 |
| ② "前端 `setTarget()` 写到条目" | ✅ **已做** —— 新增 `entryTargetOf()` / `setEntryTarget()`, 走**已有的** `PUT /run_list`（不新开端点）|
| ③ "迁移: 任务级 target 分配给各条目" | ✅ **已提供工具** —— `seedEntryTargetsFromTaskLevel()`（只灌**还没设过**的条目, 不覆盖用户已设的）|
| ④ 干净重建 + 部署 | ✅ **已做** —— `app.so 5CA0E543` |

### 前端改动

* `task_list_controller.dart`: `entryTargetOf()` / `setEntryTarget()` /
  `seedEntryTargetsFromTaskLevel()`
* `queue_panel.dart`: `_settingsRow(context, c, cmd)` ->
  **`_settingsRow(context, c, cmd, entry)`**
  * 次数框 `value` = `entry['target'] > 0 ? 该值 : 任务级默认值`
  * `onCommit` -> ★ **`c.setEntryTarget(entry, n)`**（不再写任务级）
  * ★ **休息那支一并改**: 队列里可以加**多条**休息
    （"歇 10 分钟" + "歇 1 小时"）, 后端 `_rest_minutes()` 已优先读条目级
* **有意不改**: `task_row_view.dart:365` 的 `setTarget` 保留任务级 ——
  那是**总览页**（按**任务**列出）, 在那里改的本来就该是"该任务的默认次数"

### ⚠ 部署前提

★ **必须重启后端** —— 条目级 `target` 的后端部分（`48b2f7b5`）晚于
  上一次后端启动时间, 不重启则**后端仍按任务级处理**。
