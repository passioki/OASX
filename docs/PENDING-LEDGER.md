# 未完成台账（前端 · OASX）

> ★ **本文件与后端 `D:\OAS-dev\backend\docs\PENDING-LEDGER.md` 同款** ——
> ★ 用户明令（后端台账原文）：
> > "**每次对话都要更新一遍未完成的台账，显式放到对话里来。**"
>
> ★ **为什么前端也要有一份**（`SESSION-HANDOFF.md §3` 的 `N5`）：
> ★ 本项目**唯一真相 = git**，"记忆必须外置"。★ 而后端的台账管不到前端的事
> ⇒ ★ 前端的问题（界面/交互/构建）会在**换会话时丢掉**。

---

## ★★ 铁律（与后端同一套，★ 违反即返工）

```
★ ① ★ 用户的话 = **规格**，不是建议 ⇒ ★ 不许降级成"打补丁"
★ ② ★ **读写双向**：★ 不只看用户说了什么，★ 还要看我提了什么选项、用户裁的是哪个
★ ③ ★ **禁止**拿"首行预览 / 截断"当读过 —— ★ 必须读正文
★ ④ ★ **边读边写**（防上下文压缩丢失）；★ 不攒到最后
★ ⑤ ★ 动手改代码前 ⇒ ★ 必须先出「**设计 vs 现状**」对照（符合 ✅ / 不符 ❌ + `文件:行号`）
★ ⑥ ★ **逐步法**：★ 一次只改 **1~2 个边界** ⇒ 立刻 `analyze` + `test` ⇒ 再做下一步
★ ⑦ ★ **完成定义**：★ 说"完成"前先列勾选清单；★ **没勾完不许说完成**
★ ⑧ ★ **台账**：★ 每条回复**必须**先更新台账文件、★ 并把全表贴进回复
★ ⑨ ★ **不许阴奉阳违**（★ 用户原话）
★ ⑩ ★ **注入验证**：★ 新增守卫必须"**真会红**"（★ 后端已抓到 **4 次空转守卫**，
      见后端台账 §C.3）；★ **"注入破坏后仍 pass" ⇒ 该守卫作废、必须重写**
```

---

## ★ 一、进行中 / 未开始

| # | 事项 | 依据（`文件:行号`）| 状态 | 验证方式 |
|---|---|---|---|---|
| **F5** | ★★ **「运行中」标记只覆盖 `run_list` 的行** —— 自动补齐行已在 `N9-7` 修好，★ 但**其余状态标记**（「已运行 N 次」）是否也该覆盖自动行？需**实机核对** | `lib/controller/task_list/task_list_controller.dart`（`queuedTaskRows` 的 ② 段）| ⬜ 待核 | ★ 实机：开一个周期任务，看它的行有没有「已运行 N 次」 |
| **F6** | ★★ **i18n 缺 `zh-CN.json`** —— 后端 4 条测试因此红（★ `module/config/i18n/zh-CN.json` 不存在）。★ 该文件的**生产者是前端**（经 `/chinese_translate` 推给后端）⇒ ★ 需确认**前端在什么时机推**、★ 是否要**开机自动推一次** | 后端台账 §C 的 `F-baseline-attrib` · 前端 `lib/service/locale_service.dart` | ⬜ 待核 | ★ 起后端 + 前端 ⇒ 看 `module/config/i18n/zh-CN.json` 是否出现 |
| **F7** | ★ **`generated_plugin*` 生成物反复变脏** —— 每次 `flutter pub get` / `flutter test` 都会改 7 个文件（linux/macos/windows 各 2-3 个），★ 让 worktree 长期不干净 ⇒ ★ 每次提交都要手动 `git checkout --`（本轮做了 3 次）| `linux/flutter/generated_plugin_registrant.*` · `windows/flutter/...` · `macos/Flutter/GeneratedPluginRegistrant.swift` | ⬜ 待决 | ★ 方案 A：加入 `.gitignore`（但它们是上游生成的、**曾被提交**⇒ 需要 `git rm --cached`）；★ 方案 B：保持现状，提交前手动还原 |
| **F8** | ★ **前端"自动化测试基线"已补** —— 基线要像后端那样**可核查**（★ 数字 + 复现命令 + 归因）| `test/`（10 个测试文件）| ✅ **已补（[10-15]）** | ★★ **[10-15] 现行基线（开发机 `D:\OAS-dev` 实测）**：`flutter test` = **160 passed**（★ 10-14 为 158；★ [10-15] F9 新增 **2 条** runtime 守卫）· `flutter analyze lib` = **0 error（4 warning + 17 info）** —— ★ **warning 位置固定**：`store_disk.dart:184/192` · `platform_utils.dart:63/64`（★ "0 error" 属实；★ 原写"4 条既有 info"**不准**）· ★ 复现命令见 §四（★ 一律走 `..\backend\dev_tools\flutter.bat`，★ 自动补 `--no-version-check`）|
| **F9** | ★★★ **「恢复调度」有按钮、「暂停调度」没有**（★ 用户 [10-15] 报："**恢复调度按钮缺少了暂停调度**"）—— ★★ **真因 = 两个 `else if` 条件逐字相同 ⇒ `[⏸]` 分支是死代码** | ★ `lib/views/tasks/queue_panel.dart`：**`:1042`** 与 **`:1059`** 的条件**逐字相同**（都是 `else if (isTask && e['running'] == true)`）⇒ ★ `:1059`（`Icons.pause_circle_filled` + `_pauseSchedule`）**永不执行**；★ 佐证：全仓 `pause_circle_filled` **只此 1 处**（`:1072`）· `_pauseSchedule` **只此 1 处**（`:1071`）⇒ ★ **界面上完全没有"暂停调度"入口**；★ 另：`lib/views/tasks/run_control_bar.dart:13-19` 的类注释仍写"保留的三个按钮：⏸ 暂停调度 / ⏭ 本轮跑完再停 / ▶ 继续调度"，★ 而 `:183-276` 实际只剩「启动脚本 / 停止脚本」⇒ ★ **注释过期**（同一处 bug 的另一面）| ✅ **已完成（[10-15]）** | ★★ **[10-15] 已按下面这个"最小修法"落地**：★ **删掉 `:1042-1058` 这个多余分支** —— ★ 依据 SPEC **§3.6 现行口径**只有三条：★ 暂停中行 `[▶]` 恢复 · ★ 运行中行 `[⏸]` 暂停 · ★ 未运行行 `[▶]` 描边 ⇒ ★ **设计里没有第 4 条**；★ 删后 `:1059` 自然可达。★ 守卫建议：★ 断言"**运行中行的 `[⏸]` 必须可达**"（★ 静态断言"相邻 `else if` 条件不得逐字重复"最省事，★ 且能防同类回归）。★ 验证：`flutter analyze lib` **0 error** + `flutter test` **158 passed** + ★★ **注入验证**（把删掉的分支塞回去 ⇒ 守卫必须变红）。★ 关联规则：SPEC **§1.4-Z3** · **§3.4-L3** · **§3.6-L3** · **分歧块③ 现行口径**<br>★★ **[10-15] 落地证据（可核查）**：① **代码** = 删 `:1042-1058`（★ 原处留"为什么它是多余的"注释 —— ★ 它想接的"运行中 **且** 已暂停"已被**上面**那个 `c.schedulerPaused` 分支接走）② **守卫** = `test/task_list_panel_test.dart` 新增 **2 条 runtime 断言** `_f9PauseReachableTests()` —— ★ **真 pump `QueuePanel`** 后 `find.byIcon(Icons.pause_circle_filled)`；★ **刻意不用**"相邻 `else if` 条件不得重复"那种**静态**断言 —— ★ 本项目已**三次**抓到源码级守卫**空转**（后端台账 §C.3 教训-C）③ **验证** = `flutter analyze lib` **0 error**（4w+17i）· `flutter test` **160 passed** ④ ★★ **注入验证** = 把那段重复分支塞回去 ⇒ **1 failed**（`+1 -1`）⇒ 还原后 SHA256 **逐字节一致**（`6AD94E42…`）⇒ 复跑回绿 ⑤ ★ 与后端 `E-6-n`「真漂移」**同源**，已一起收敛（SPEC **§4.5-㊱**）|

| **F11** | ★★★ **[11-13] 启动不稳定 + 设置回退（白主题 / 要重填后端地址 / 不自动拉后端）** —— ★★ **真因 = 存储容器分裂（结构性缺陷，不是偶发）** | ★ `lib/main.dart:165` 初始化的是 **`GetStorage.init('GetStorage-live')`**；★ 而 **7 个消费方全是无参 `GetStorage()`**：`theme_service.dart:8` · `login_controller.dart:9` · `window_service.dart:11` · `task_prefs.dart:203` · `settings.dart:15` · `script_service.dart:12` · `locale_service.dart:13`。★★ **`get_storage 2.1.1` 源码语义**（`storage_impl.dart:11-12` `factory GetStorage([String container = 'GetStorage', ...])` · `:40-42` `static Future<bool> init([String container = 'GetStorage'])`）⇒ ★ **`GetStorage()` 永远只用字面量默认容器**，**不跟随** `init('xxx')` 的名字 ⇒ **初始化一个盒子、全程用另一个盒子**。<br>★ 磁盘实证：`Documents\GetStorage-live.gs` = **`{}`（2 B）** · `Documents\GetStorage.gs` = **`dark:true` / `address:127.0.0.1:22287` / `rootPathServer:D:\OAS-live\backend`（用户真实设置）**<br>★ 连锁：`rootPathServer` 一旦读空 ⇒ `login_controller.dart:140-143` **直接 `return false`** ⇒ **不自动拉起后端**（三条症状同源）| ✅ **已修（[11-13]）** | ★ 修法：`main.dart` 改成 **`await GetStorage.init()`（默认容器 = 用户数据本来就在的那个）** ⇒ ★ **零数据迁移**；★ `catch` 由 `logger.w` 升为 **`logger.e` + `storageInitFailed` 标志**（不再静默）。<br>★ **守卫**：新增 `test/storage_container_test.dart`（**3 条**）：① `main.dart` 必须 `GetStorage.init()` 且**不含**带名字的 init ② `lib/` 全目录**不许**出现 `GetStorage.init('…')` ③ 消费方仍是无参 `GetStorage()`（反向前提）。<br>★★ **注入验证**：把 `init()` 改回 `init('GetStorage-live')` ⇒ **2 条变红** ⇒ 还原后 **SHA256 逐字节一致（`131327cf…`）** ⇒ 复跑 3 passed。<br>★ 基线：`flutter analyze lib` **0 error（4w+17i）** · `flutter test` **163 passed**（160 + 3）|
| **F12** | ★★★ **[11-13] 任务配置"改了又回退"（执行队列 → 执行顺序 → 任务行设置 → 如"探索等级"）** —— ★★ **真因 = 前端把【中文展示名 `model.title`】当字段名传给后端** | ★ `lib/views/args/args_view.dart` 的 **8 个 handler**（boolean/string/number/integer/enum/date_time/time_delta/time）全是 `setArgument("", "", widget.getGroupName(), **model.title**, type, value)`；★ 而后端按**字段名**取属性：`backend/module/config/config_model.py:502` `getattr(group_object, argument, None)` · `:504-506` 取不到 ⇒ `logger.error` + **`return False`**<br>★★ **API 实测（dev 后端 22288 · 探测脚本）**：`argument=探索等级` ⇒ **`200 false`**、磁盘**不变**；`argument=exploration_level` ⇒ **`200 true`**、磁盘**变化**<br>★ 假成功：前端**丢弃返回值**、还弹「设置已保存」（`args_view.dart:354-357` `showSnakbar`）| ✅ **已修（[11-13]）** | ★ 修法：8 处 `model.title` → **`model.name`**（★ `ArgumentModel` 早已写明"`name` 是字段名、`title` 是中文展示名"，`:109-112`，只是 handler 没用对）；★ `ArgsController.setArgument` **检查返回值**并弹「保存失败」（不再静默）<br>★ 守卫：`test/config_write_guards_test.dart`（① setArgument 必须传 `model.name` ② 必须检查返回值）<br>★★ 注入验证：改回一处 `model.title` ⇒ **1 failed**；去掉 `if (!ok)` ⇒ **1 failed**；还原后**逐字节一致** ⇒ 复跑全绿 |
| **F13** | ★★ **[11-13] 循环次数"改了变空 + 实测不循环"** —— ★ 拆成两个独立问题 | **① 变空（已修）**：`task_list_controller.dart` 的 `loopTimes` **从不从 `/schema` 读**（`isLoopTimesLoaded` 只声明、**零处使用**）⇒ 只要页面重建就回到 `0`；而 `task_row_view.dart:599` `_text() => value > 0 ? '$value' : ''` ⇒ **0 显示为空**。<br>**② 不循环（待核）**：★ **写入是好的**（API 实测 `loop_times 5→3→0` 均 `200 true` 且落盘）；★ 后端循环逻辑也**存在且正确**（`script.py:552-581`：`_wte=='loop'` + `_done>=_times` 才停）；★★ 但**实机日志里"队列循环"一条都没有**（`Start task` 有 115 条、`待命`/`队列里没有可跑` **0 条**）⇒ **循环分支从未被执行到** ⇒ 需运行时定位"队列到底有没有跑空" | ① ✅ **已修** · ② ⬜ **待核** | ① 修法：`reload()` 里**首次**从 `schemaGlobalFields['loop_times']['current']` 读一次（与 `when_task_queue_empty` 同手法），守卫见 `test/config_write_guards_test.dart`（注入 ⇒ 1 failed）<br>② 需要：★ 用户跑一次"循环"模式队列，确认**跑最后一条之后**界面/日志是什么（待命？回庭院？脚本停止？）⇒ 我据此定位是 `reset_loop_next_run()` 返回假、还是根本没进入 idle 分支 |

## ★ 二、已完成（★ 本轮 [10-14]，均有可核查证据）

| # | 事项 | 依据 | 状态 | 验证 |
|---|---|---|---|---|
| **N9-7** | ★★ 周期任务**无「运行中」标记** | 真因三层：★ ① 标记读 `/run_list`（`queue_panel.dart:864`）★ ② 而 `/run_list` 只遍历 `run_list`（后端 `schema_router.py:1256`）★ ③ 周期任务 `entry_id = None` ⇒ `running_entry_id` 恒空 | ✅ **已修** | ★ 修法：`queuedTaskRows` 的自动补齐段补 `running`（★ 无条目身份 ⇒ **按任务名比**，与后端兜底同口径 + 防重复）；★ 守卫 4 条**运行时**断言（`test/task_list_panel_test.dart` 的 `_n97RunningTagTests`）⇒ `flutter test` 全绿；★★ **注入验证真红**（判据置 `false` ⇒ 1 failed）|
| **N9-4** | ★★ 新建配置页**填的名称不生效** | 真因：`_createProfile` **既不弹框、也不传 `name`** ⇒ 后端永远自动编号（`schema_router.py:2149`）| ✅ **已修** | ★ 修法：新增 `_askProfileName()`（与 `_renameProfile` **同款**）+ 传 `name`（★ 取消 ⇒ 不新建 · ★ 留空 ⇒ `null` ⇒ 自动编号）；★ 守卫 4 条结构断言 ⇒ 157 passed；★★ **注入验证真红**（退回"不传 name" ⇒ 2 failed）|
| **F2** | ★ 滚动条被翻回顶部 | `task_list_controller.dart:389-399`（用户交互时跳过刷新）| ✅ 已完成 | ★ 149 passed · 已部署 `14F188E5` |
| **F1** | ★ 白屏（`Flexible` 套在 `Wrap` 里）| `lib/views/tasks/...` | ✅ 已完成 | ★ 用户实测"白屏好了" |
| **F3** | ★ 前端重建部署 | — | ✅ 已完成 | ★ app.so `14F188E500925454` |

## ★ 三、前端**关键约束**（★ 改代码前必读，★ 来自后端 `DESIGN-SPEC` 与用户明令）

| # | 约束 | 出处 |
|---|---|---|
| **P1** | ★★ **`"播放模式"` 这个标题是用户要求删掉的** ⇒ ★ 该处**只有下拉**（顺序/循环/乱序），★ **不要"修复"成带标题** | 用户明令 |
| **P2** | ★★ **前端不能放 `D:\MuMuPlayer\OAS\` 下** | 内核驱动 `PassGuard_x64.sys` 打了保护标记 ⇒ 双击打不开 |
| **RT1~RT4** | ★★ **「运行中」标记必须覆盖队列每一行**；★ 判据**条目身份优先、退回任务名**；★ **同任务只许亮一行** | 后端 `DESIGN-SPEC.md` §3.9.7 |
| **PN1~PN3** | ★★ 配置页「新建」**必须让用户填名字**；★ 名字**必须传给后端**；★ 取消⇒不新建 · 留空⇒自动编号 | 后端 `DESIGN-SPEC.md` §3.9.8 |

## ★ 四、常用命令（★ 与后端 `DEV-WORKFLOW.md` 对齐）

```bat
REM ★ [10-15] **去盘符**：用后端仓库里的包装脚本（★ 自动找 Flutter SDK + 自动补 --no-version-check）
REM   ★ 相对路径：前端仓库的上一级就是工作区根（★ 见后端 docs/LAYOUT.md）
..\backend\dev_tools\flutter.bat analyze lib      REM ★ 期望 0 error（[10-15] 实测：0 error / 4 warning / 17 info）
..\backend\dev_tools\flutter.bat test             REM ★ 期望 160 passed（★ [10-15] 实测 160；★ 10-14 为 158）
..\backend\dev_tools\flutter.bat build windows --release
REM   ★ ✅ [10-15] VS 2022 Build Tools 已装 ⇒ build **可用**（★ 台账 F10 / 后端 P17）
build\windows\x64\runner\Release\oasx-live.exe    REM ★ 开发前端（★ 无盘符）
REM   ★ 手敲原生命令时也必须带 `--no-version-check`：否则 flutter 对 SDK 仓库跑
REM     `git fetch --tags`（611285 对象）挂死（★ 后端坑 P16）
```

★ **产物交接口**：★ 实机前端 = `D:\OAS-live\frontend\oasx-live.exe`
（★ 由 `DEV-WORKFLOW.md §4` 的拷贝法部署）。
★ ⚠ **[10-15] 实机在【另一台电脑】上**（★ 用户原话："本机是开发机"）⇒ ★ 本机（`D:\OAS-dev\frontend`）**没有** `D:\OAS-live`。

## ★ 五、相关文档

* ★ 后端三件套：`D:\OAS-dev\backend\docs\` 的 `DESIGN-SPEC.md` · `PENDING-LEDGER.md` · `SESSION-HANDOFF.md`（★ [10-15] 本机路径 = `D:\OAS-dev`）
* ★ 本仓内：`docs/scheduler-architecture.md`（调度器架构）· `docs/REST-TASK-LEDGER.md` · `docs/BUILD.md` · `docs/STARTUP-TROUBLESHOOTING.md`
