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
| **F8** | ★ **前端没有"自动化测试基线"记录** —— 后端台账有"49 failed / 1785 passed"这样的**可核查基线**；★ 前端只有"157 passed"一个数 | `test/`（10 个测试文件）| ⬜ 待补 | ★ 记录：`flutter test` = **157 passed**（[10-14]）· `flutter analyze` = 4 条**既有 info**（无 error）|

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
cd /d D:\OAS-dev\frontend
D:\flutter3271\bin\flutter.bat analyze lib            REM ★ 期望 0 error
D:\flutter3271\bin\flutter.bat test                   REM ★ 期望 157 passed
D:\flutter3271\bin\flutter.bat build windows --release
build\windows\x64\runner\Release\oasx-live.exe        REM ★ 开发前端
```

★ **产物交接口**：★ 实机前端 = `D:\OAS-live\frontend\oasx-live.exe`
（★ 由 `DEV-WORKFLOW.md §4` 的拷贝法部署）。

## ★ 五、相关文档

* ★ 后端三件套：`D:\OAS-dev\backend\docs\` 的 `DESIGN-SPEC.md` · `PENDING-LEDGER.md` · `SESSION-HANDOFF.md`
* ★ 本仓内：`docs/scheduler-architecture.md`（调度器架构）· `docs/REST-TASK-LEDGER.md` · `docs/BUILD.md` · `docs/STARTUP-TROUBLESHOOTING.md`
