# OASX 乱码修复

## 问题
OASX 启动 OAS 时，终端里大量乱码：

```
鈺愨晲鈺愨晲鈺愨晲鈺愨晲   ← 应为 ════════════
鈹€鈹€鈹€鈹€ START 鈹€鈹€鈹€鈹€   ← 应为 ────── START ──────
涓枃娴嬭瘯: 浼寸敓鏍?      ← 应为 中文测试: 伴生树
```

日志文件本身正常（OAS 以 `encoding='utf-8'` 直接写文件），只有经 stdout 的那一路乱码。

## 根因
1. OAS 侧把标准输出明确设为 UTF-8
   （`deploy/launcher/*.bat` 的 `set PYTHONIOENCODING=utf-8` + `PYTHONUTF8=1`，
   以及 `module/base/encoding.py` 的 `setup_utf8_stdio()`）。
2. OASX 用 `process_run` 的 `ShellLinesController` 读子进程输出，但**没有指定编码**：

   ```dart
   // lib/controller/server/server_controller.dart:11 (修复前)
   var shellController = ShellLinesController();
   ```

3. `process_run` 于是回退到平台默认编码：

   ```dart
   // process_run 0.13.3  lib/src/lines_utils_common.dart:34-35
   ShellLinesController({Encoding? encoding}) {
     this.encoding = encoding ?? shellContext.encoding;   // <-- 回退
   }
   // ... 第 77 行用它解码每一行
   ctlr.add(encoding!.decode(currentLine!));

   // process_run  lib/src/shell_context_io.dart
   @override
   Encoding get encoding => systemEncoding;   // Dart 的 systemEncoding
   ```

   **Dart 的 `systemEncoding` 在 Windows 上是 Latin-1（每个字节映射成一个字符），不是 UTF-8。**

所以链路是：**OAS 写 UTF-8 字节 → process_run 按 Latin-1 解码 → 乱码**。
一个 3 字节的 `═`(U+2550, `E2 95 90`) 被解成 3 个 Latin-1 字符，正是你看到的 `鈺愨晲`。

逐字节实测（用与 server.py 相同的方式输出 `═` 并检查重定向后的字节）：

```
原始字节      : E2 95 90 E2 95 90 ...
按 UTF-8 解码 : ════════════════      ✓ 正确
按 GBK 解码   : 鈺愨晲鈺愨晲鈺愨晲...     ✗ 与 OASX 里的乱码一致
```

## 修复
只需在 OASX 侧显式指定 UTF-8（`ShellLinesController` 本来就支持这个参数）：

```dart
// lib/controller/server/server_controller.dart
var shellController = ShellLinesController(encoding: utf8);
```

配套加导入（`library server;` 里原本没有 `dart:convert`）：

```dart
// lib/views/server/server_view.dart
import 'dart:convert' show utf8;
```

全 OASX 只有这一处 `ShellLinesController`，改动作用域干净。

## 为什么不能靠升级依赖解决
`shell` 与 `process_run` 都已是 pub 上的最新版（`shell: 2.0.0`、`process_run: 0.13.3`），
上游没有修这个默认编码问题。所以必须自己带这个改动（fork 或本地路径依赖）。

## 需要你自己动手的两步
1. **安装 Flutter SDK**（本机尚未安装；工程 `environment: sdk ">=3.5.0 <4.0.0"`，
   上游 CHANGELOG 提到已更新到 Flutter 3.27.1）。
2. 在 OASX 源码目录执行 `flutter pub get` 然后 `flutter build windows`。

## 顺带修掉的假错误（同一文件）
`server_controller.dart` 的 `run()` 原本还会执行 `pwd`：

```dart
runShell('echo OAS working directory: ').then((value) => null);
runShell('pwd').then((value) => null);          // Windows 没有 pwd
runShell('python -m deploy.installer')...
runShell('taskkill /f /t /im pythonw.exe')...
runShell('.\\toolkit\\pythonw.exe  server.py')...
```

Windows 的 shell 没有 `pwd`，因此每次启动 OASX 都会在日志顶部留下：

```
ERROR: ShellException(pwd, exitCode 1, workingDirectory: D:\OAS-dev\OnmyojiAutoScript)
```

同理 `taskkill /f /t /im pythonw.exe` 在本来就没有 pythonw 进程时会返回 128：

```
ERROR: ShellException(taskkill /f /t /im pythonw.exe, exitCode 128, ...)
```

这两条都是"预期会失败"的命令，却以 `ERROR:` 出现在日志最上方，会淹没真正的问题。

改动：
* `pwd` → `cd`（cmd 下语义等价，都会打印当前目录）；
* `runShell` 增加"允许失败"名单：命中名单的命令在调用时追加 `|| ver >nul`
  把退出码归一为 0（`ver` 是 cmd 的恒真命令），并且即使仍抛
  `ShellException` 也不再记为 ERROR；
* 顺带把输出从"只打印 errText"改为 out/err 都打印（原来 `echo` 的结果被丢掉了）。

## OAS 侧要不要改
不需要。OAS 输出 UTF-8 是正确的一方，文件日志也一直正常。
在 OAS 侧做 ASCII 规避只是绕过，不解决问题（且会让中文也一并丢失）。

## 与跨平台的关系
OAS 后端本身是跨平台的（`deploy/docker/Dockerfile` 基于 Debian；
`module/device/env.py` 有 `IS_WINDOWS`/`IS_MACINTOSH`；模拟器管理在非 Windows 上
优雅降级）。而上面这些 `runShell(...)` 是**"OASX 顺便帮你启动本机后端"**的
Windows 专属便利功能 —— 在跨平台场景下后端跑在另一台机器上，这整段都不适用。

建议后续把"连接远程后端"提升为一等公民启动模式（首次启动就选
「本机启动后端」/「连接远程后端」），`/login` 页面已经支持填地址并做连通性检测，
只需把它从设置里提到启动流程。
