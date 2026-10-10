# 启动故障排查记录（2026-10-11）

> 本文件记录一次真实排障的**完整证据链**。所有"根因"都有实测支撑，
> 所有**被推翻的假设**也保留下来 —— 避免后人重复踩坑。
>
> ★ 结论先行：
> * **白屏 / 内容空白** = 启动流程零容错（已修）
> * **后端起不来** = `pythonw.exe` 下 `sys.stdout is None`（已修）
> * **双击打不开** = **构建产物不一致**（换干净目录重建解决）
> * **配置从未丢失**（用户以为丢了）

---

## 一、白屏 / 「打不开」（窗口在、内容空白）

### 现象

* 双击 OASX → 「鼠标转一下圈，无事发生」
* 把 exe 路径粘贴进资源管理器地址栏 → 回车 → 弹出「无法验证发布者」
  确认框 → 点「运行」→ **能开，但界面是白色半透明空窗口，没有关闭/最小化按钮**

### 定位方法：**阶梯探针**（同一 Flutter 3.27.1 引擎编译）

| 探针 | 含什么 | 结果 |
|---|---|---|
| `minimal_probe` | 纯 Flutter | ★ 正常显示 |
| `wm_probe` | + `window_manager` | ★ 正常（无关闭按钮 = `TitleBarStyle.hidden`，正常）|
| `init_probe` | + `GetStorage` + 启动流程（**带 try/catch**）| ★ 正常 |
| `ui_probe` | + `DevicePreview` + `ResponsiveApp` + `GetMaterialApp` | ★ 正常 |
| **OASX** | 完整 | **白屏** |

→ ★ **渲染管线 / window_manager / GetStorage / UI 框架层全部正常**，
  白屏来自 **OASX 自己的首帧代码**。

### 根因链条

```
① AppData\Local\com.oas\oasx\i18n\zh-CN.json 被写坏
     （中文全是乱码 "鍗曞眬Boss闄愬埗鏃堕棿"，JSON 非法）
② LocaleService.onInit -> _loadLocaleMessage('zh-CN') 解析失败
③ 异常冒到 initService() -> 服务注册被跳过
④ OASXApp.build() 第一行 `Get.find<LocaleService>()` 抛异常
⑤ ★ 首帧渲染失败 -> 窗口在、内容空白
```

### 修的三处（`lib/main.dart` / `lib/utils/logger.dart`）

| # | 缺陷 | 修法 |
|---|---|---|
| 1 | ★ `initLogger()` **没有 `await`**：`getApplicationCacheDirectory().then((d){... logger = ...})` 既没 await 也没 catchError → `late Logger logger` 可能**从未赋值**；回调异常 = **未捕获的异步异常** | 先给一个**一定能用**的控制台日志器（保证 `logger` 已赋值），再 `await` 文件日志；失败**降级到控制台**并给出可见警告 |
| 2 | ★ 服务**必须一定被注册** —— 缺注册会让首帧 `Get.find` 抛异常 | `_ensureService<T>`：失败**重试一次**，仍失败则用**降级实例**兜底注册 |
| 3 | ★ **首帧绝不允许白屏** | `Get.find` 失败也画界面 + 底部叠一条**红色可见横幅**（以后同类问题**可见**，不再静默白屏）|

### 关键教训

> ★ **"容错"不能是"静默跳过"**。第一版修法把失败的服务"跳过"，
> 结果**制造了白屏** —— 因为首帧立刻 `Get.find` 那个服务。
> 正确做法是**一定注册一个可用的东西**。

---

## 二、后端起不来（前端连不上 → 显示默认值）

### 现象

用户以为"配置被重置了"。★ **实际配置一直完好**
（后端 API 返回 `tasks 53 / 在队列 52 / 启用 26`）。

### 根因

OASX 启动后端用的命令（`server_controller.dart`）:

```
.\toolkit\pythonw.exe  server.py
```

★ `pythonw.exe` **没有控制台** → `sys.stdout` / `sys.stderr` 都是 **None**。
而 `module/logger.py` 用 `rich` 的 `RichHandler`（默认写 `sys.stdout`）
→ `None.write(...)` → `AttributeError` → **进程在启动阶段直接死**。

### 实测三组对照（同机同代码，只改 stdout 是否存在）

| 方式 | 结果 |
|---|---|
| `pythonw.exe server.py` | ★ 进程死，端口 22288 **永不监听** |
| `pythonw.exe server.py` + 输出重定向 | 正常启动 |
| `python.exe server.py` | 正常启动（约 2 秒）|

→ 差别**只在 stdout 是否存在**，与代码逻辑无关。

### 修法（`module/base/encoding.py`）

`setup_utf8_stdio()` 原来在流为 `None` 时直接 `continue`，**没有兜底**：

```python
for name in ('stdout', 'stderr'):
    if getattr(sys, name, None) is None:
        setattr(sys, name, open(os.devnull, 'w', encoding='utf-8'))
```

★ 文件侧日志照常记录 —— **"没有控制台"不等于"没有日志"**。

### 验证

```
pythonw server.py
  -> ★ TCP 22288 第 2 秒就通（原来永不监听）
  -> ★ 25 秒后进程仍存活（原来直接死）
  -> ★ API 数据完好: tasks 53 / 队列 52 / 启用 26
```

### ⚠ 排查中遇到的一个假象

日志出现 `startup done` 后**立刻** `shutdown done`。
★ 那是一个**残留的旧 `python` 进程占着 22288 端口**造成的，**不是**本 bug。
清掉残留后一切正常 —— **排查时务必先确认端口占用**。

---

## 三、双击打不开（鼠标转圈、无事发生）

### 现象对比（★ 同一份 `app.so`，只有目录不同）

| 位置 | 双击 |
|---|---|
| `D:\OAS-dev\OASX-src\build\...\Release\oasx.exe` | ✗ 无事发生（**连权限确认框都不弹**）|
| `D:\OASX-app\oasx.exe`（干净重建）| ★ **能开**（会弹 Win10 权限确认框）|

### 根因：**构建产物不一致**

| 对比项 | 旧仓库产物 | 新目录产物 |
|---|---|---|
| 源码 | ✓ 一致（251/251 文件）| ✓ |
| `pubspec.lock` | ✓ 一致 | ✓ |
| `flutter_windows.dll` | `3499C3F0` | `3499C3F0` ✓ **相同** |
| **`oasx.exe`** | `E8997A16` | `5831C8F0` ✗ |
| **4 个插件 DLL** | 全部不同 ✗ | — |
| **`data\app.so`** | `F58D6B49` | `9928A5D3` ✗ |

★ **源码与依赖都一致，但二进制全都不同** → 旧仓库的构建缓存/产物
处于**不一致状态**（插件 DLL 是旧缓存残留，与新的 `app.so` **ABI 不匹配**）
→ 旧产物在 `FlutterWindow::Create` / 插件注册阶段就死
→ **连"请求权限"的框都来不及弹**。

### 「新仓库弹权限框、旧仓库没反应」的解读

★ 那个框是 **Win10 的"允许此应用对你的设备进行更改/全屏"确认**。
它是在**窗口创建阶段**才需要的 —— 旧产物**死在那之前**，所以不弹。
**"不弹框"本身就是"死在更早阶段"的证据。**

### 解决

★ **换干净目录重建**：

```powershell
git clone --branch oas-tasks-ui-s7 https://github.com/passioki/OASX.git D:\OASX-clean
cd D:\OASX-clean
D:\flutter3271\bin\flutter.bat pub get
D:\flutter3271\bin\flutter.bat build windows --release
# 再把 build\windows\x64\runner\Release 的 21 个文件复制到运行目录
```

### ⚠ 踩过的坑

* ★ **`flutter build` 前必须彻底清理**（`build/` + `.dart_tool/`
  + `windows/flutter/ephemeral/`），否则会沿用残留的插件 DLL
  → **产物 ABI 不一致 → 启动即死且无任何提示**
* ★ 只比对"文件数 + `oasx.exe` 时间戳"**不够** —— 必须比对
  **`data/app.so` 与各插件 DLL 的哈希**
* ★ 排查时**不要用旧仓库的 Release 产物**做基准

---

## 四、★ 被推翻的假设（保留下来，避免重走）

| 曾经的假设 | 为什么是错的 |
|---|---|
| "`window_manager` 版本不匹配是元凶" | ✗ 探针证明 `window_manager` 单独能正常开窗 |
| "`pythonw.exe` 静默失败、无解" | ✗ 我**只等了 10 秒**（实际冷启动约 12 秒）；加输出重定向就正常。真正的原因见第二节 |
| "缺 `RUNASADMIN` 兼容性标记导致双击失败" | ✗ 用户实测「以管理员身份运行」**也打不开**，提权不是原因 |
| "新会话乱改了代码" | ✗ `b518ed2` 只动了任务列表面板 7 个文件，**完全没碰启动路径**；那两处启动缺陷**基线就存在** |
| "i18n 缓存损坏是根因" | ⚠ **只是触发条件**。根因是"启动流程零容错"—— 任何一步失败都会导致白屏 |
| "`GetStorage.gs` 被探针覆盖了" | ✗ 逐字节核对：**从未被改动**（`dark:true` / `rootPathServer` / `address` 全在）|

### ★ 关于"沙箱假象"

排查时我在受约束的环境里启动 exe，反复看到
`PathAccessException ... errno = 5 (拒绝访问)` ——
★ 那些是**父进程能写、子进程被拒**的**环境限制**，**不是**用户机器的问题。
**教训：不要用受约束环境的子进程行为去推断用户机器的故障。**

---

## 五、最终状态

### 目录

| 路径 | 作用 | 分支 |
|---|---|---|
| ★ `D:\OASX-app` | **正式运行目录**（21 个产物文件 + 启动器）| — |
| ★ `D:\OASX-clean` | ★ **唯一权威源码仓库**（从 GitHub 全新克隆，**非 shallow**，能推送）| `oas-tasks-ui-s7` |
| `D:\OAS-dev\OASX-src` | 历史开发仓库。⚠ 它是 **shallow clone**（推送历史会失败）；其 ~~`build\`~~ 产物**已删除** | `recover-session` 等 |
| `D:\OAS-dev\OnmyojiAutoScript` | 后端（含 `pythonw` 修复）| `dev` |

#### ⚠ 推送纪律（踩过）

远端**只有一个工作分支** `oas-tasks-ui-s7`（另有 `main`）。

* ★ 在 `D:\OASX-clean` 里推送 —— 本地分支名就叫 `oas-tasks-ui-s7`：
  `git push origin oas-tasks-ui-s7`
* ★ 在 `D:\OAS-dev\OASX-src` 里本地分支叫 `recover-session`：
  想更新那个唯一远端分支要写 **`git push origin recover-session:oas-tasks-ui-s7`**
* ★ **我踩过**：在 `recover-session` 分支上执行 `git push origin oas-tasks-ui-s7`
  → `error: src refspec oas-tasks-ui-s7 does not match any`
  （**本地没有这个分支名**，不是网络/权限问题）

### 提交

| 仓库 | 提交 |
|---|---|
| OASX | `72a5244`（启动三处修复）、`48983b5`（防回归测试）、`8fe1027`（cherry-pick 到 `recover-session`）、`dc8a419`（镜像）|
| OAS | `dd44ef28`（`pythonw` stdout 修复）|

### 测试基线

* `flutter analyze lib` → **0 error**
* `flutter test` → **148 passed**（`recover-session`）/ **127 passed**（回退版）
* 后端 `pytest` → **1737 passed / 3 skipped / 0 failed**

---

## 六、给后人的检查清单

启动类故障（"打不开 / 白屏 / 连不上后端"）按此顺序查：

1. **产物自洽性** —— `data/app.so` 与 4 个插件 DLL 的哈希，
   是否与**同一次**干净构建一致？（★ 最容易漏）
2. **端口 22288** —— 是否被**残留进程**占用？（会造成 `shutdown done` 假象）
3. **应用日志** —— `%LOCALAPPDATA%\com.oas\oasx\logs\<日期>.txt`
   * **没有新日志** = 进程死在 `initLogger()` 之前（原生层问题）
   * 有日志但之后无记录 = 死在 `initService()` 里
4. **偏好文件** —— `Documents\GetStorage.gs`（`GetStorage` 的落盘位置；
   ★ 不在仓库目录里）
5. **i18n 缓存** —— `%LOCALAPPDATA%\com.oas\oasx\i18n\*.json`
   是否合法 JSON？（坏文件会拖垮 `LocaleService`）
6. **阶梯探针法** —— 从"纯 Flutter"开始逐层加依赖，
   一刀切出"是环境问题还是本项目代码问题"
