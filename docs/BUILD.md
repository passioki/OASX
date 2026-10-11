# OASX 构建记录（Windows 桌面版）

> ★ 本文件是**实测记录**，不是推测。所有命令、路径、版本都来自本机实际执行的结果。
> 目的：**换机器 / 换会话也能一次构建成功**。

---

## 一、环境（实测）

| 项 | 值 |
|---|---|
| **Flutter** | **3.27.1** · channel **stable** · `Framework revision 17025dd882`（2024-12-17）|
| **Dart** | **3.6.0** · DevTools 2.40.2 |
| **Engine** | `cb4b5fff73` |
| **Flutter SDK 路径** | ★ **`D:\flutter3271`**（**不在 PATH 上** —— 必须写全路径）|
| **Flutter 上游** | `https://gitee.com/mirrors/Flutter.git`（镜像，非官方 —— `flutter doctor` 会警告，**可忽略**）|
| **OS** | Windows 10 `10.0.19045.6466`，locale `zh-CN` |
| **仓库路径** | ★ **`D:\OAS-dev\OASX-src`** |
| **远端** | `https://github.com/passioki/OASX.git` |
| **主分支（本地）** | `oas-tasks-ui` |
| **镜像分支（远端）** | `oas-tasks-ui-s7` |
| **`pubspec.yaml`** | `name: oasx` · `version: 0.3.2+1` · `sdk: ">=3.5.0 <4.0.0"` |

### `flutter doctor` 的已知警告（**都不影响 Windows 桌面构建**）

* `flutter binary is not on your path` —— 我们**总是写全路径** `D:\flutter3271\bin\flutter.bat`
* `Upstream repository ... is not a standard remote` —— gitee 镜像，正常
* `Android toolchain ... cmdline-tools component is missing` —— **我们只构建 Windows 桌面**，不需要 Android

★ 唯一**必须**有的是 **`[√] Windows Version`** + **Visual Studio 的 C++ 桌面工具链**
（`flutter build windows` 会自己检查；缺失时会明确报错告诉你要装什么）。

---

## 二、构建命令（★ 按顺序）

### 0) ★★ 先确保 **OASX 没在运行**

```powershell
Get-Process -Name 'oasx' -ErrorAction SilentlyContinue
```
★ **进程在跑时构建会写不进去**（产物不更新，你双击还是旧版）。
有的话先关掉。

### 1) 干净构建（推荐每次都用）

```powershell
$X = 'D:\OAS-dev\OASX-src'
Set-Location $X

# ★ 先删构建目录 —— 不删的话增量构建有时不会重新链接，产物可能不更新
Remove-Item "$X\build\windows" -Recurse -Force -ErrorAction SilentlyContinue

& 'D:\flutter3271\bin\flutter.bat' build windows --release
```

**实测耗时**：干净 `build\windows` -> **约 85 秒**；
若 `build\` 其余部分还在（只删了 `windows`）-> **约 38 秒**。

### 2) 校验产物（★ **必做**，"打不开"几乎都是这一步没过）

```powershell
$rel = "$X\build\windows\x64\runner\Release"
$exe = Get-Item "$rel\oasx.exe"
$src = Get-ChildItem "$X\lib" -Recurse -Filter '*.dart' |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1

"oasx.exe    $($exe.LastWriteTime)"
"最新 .dart  $($src.LastWriteTime)  $($src.Name)"
# ★ 产物时间必须 >= 最新源码时间
```

**★ 关键：`Release` 目录必须**恰好**有这 21 个文件**
（`oasx.exe` 只有 **62.5 KB** —— 它**依赖同目录的这些文件**；
少任何一个都会"双击没反应 / 闪退"）：

```
Release\
  oasx.exe                              62.5 KB
  flutter_windows.dll                 17,825 KB   ← ★ 必须有
  connectivity_plus_plugin.dll           97 KB
  screen_retriever_windows_plugin.dll   116 KB
  url_launcher_windows_plugin.dll        96 KB
  window_manager_plugin.dll             127 KB
  data\
    app.so                           10,625 KB   ← ★ 必须有（Dart 代码在这）
    icudtl.dat                          760 KB   ← ★ 必须有（国际化数据）
    flutter_assets\
      AssetManifest.bin / .json
      FontManifest.json
      NOTICES.Z
      assets\Lato-Regular.ttf
      assets\release.txt              ← ★ 有这个文件才是 release 构建
      assets\images\Icon-app.png
      fonts\MaterialIcons-Regular.otf
      packages\cupertino_icons\assets\CupertinoIcons.ttf
      packages\font_awesome_flutter\lib\fonts\fa-brands-400.ttf
      packages\font_awesome_flutter\lib\fonts\fa-regular-400.ttf
      packages\font_awesome_flutter\lib\fonts\fa-solid-900.ttf
      shaders\ink_sparkle.frag
```

★ **注意 `app.so` 与 `icudtl.dat` 在 `data\` 子目录**，不在 `Release` 根
（我第一次核对时按根目录找，误报"缺失"）。

### 3) 冒烟测试（可选，但推荐）

```powershell
$p = Start-Process -FilePath "$rel\oasx.exe" -PassThru
Start-Sleep -Seconds 6
if (Get-Process -Id $p.Id -ErrorAction SilentlyContinue) {
  '启动成功'; Stop-Process -Id $p.Id -Force
} else { "已退出，exit code $($p.ExitCode)" }
```

---

## 三、代码检查与测试（★ 与构建**串行**跑，不要并发）

```powershell
Set-Location 'D:\OAS-dev\OASX-src'

# 静态检查（基线：11 条**既有**问题，见下）
& 'D:\flutter3271\bin\flutter.bat' analyze lib

# 单元/源码守卫测试（基线：124 passed）
& 'D:\flutter3271\bin\flutter.bat' test
```

### ★ 基线（本记录写作时实测量的）

| 项 | 值 |
|---|---|
| `analyze lib` | **11 条既有问题**（8 个 `info` + 3 个 `warning`）—— ★ **0 条是我们引入的** |
| `flutter test` | **124 passed / 0 failed** |

**这 11 条既有问题的位置**（**不要去"修"它们**，那是既有噪音）：
`component/dio_http_cache/src/store/store_disk.dart` ×2 ·
`config/translation/i18n.dart` ×2 ·
`controller/overview/overview_controller.dart` ×1 ·
`utils/platform_utils.dart` ×2 ·
`views/args/args_view.dart` ×1 ·
`views/args/group_view.dart` ×1 ·
`views/server/server_view.dart` ×2

★ **判断标准**：构建/测试后如果 `analyze` 仍是 **11 条**、`test` 仍是 **124 passed**，
说明没有引入新问题。

---

## 四、★ 踩过的坑（务必避开）

| # | 坑 | 现象 | 做法 |
|---|---|---|---|
| 1 | **OASX 在运行时构建** | 构建"成功"但产物没更新，双击还是旧版 | ★ **先关进程**（第二节第 0 步）|
| 2 | **不删 `build\windows`** | 增量构建有时不重新链接 | ★ 每次都 `Remove-Item build\windows` |
| 3 | 只看 `√ Built` 就以为成功 | 偶尔只花 9.6 秒（其实没重编） | ★ **比对 `oasx.exe` 时间戳 vs 最新 `.dart`** |
| 4 | `analyze`/`test` 与 `build` **并发** | dart 编译缓存争用，出现莫名错误 | ★ **串行**执行 |
| 5 | 把备份放进 `build\windows\` 里 | 删 `build\windows` 时把备份一起删了 | ★ 备份放 `build\windows` **之外** |
| 6 | 按 `Release` 根目录找 `app.so` | 误报"缺失" | ★ 它们在 **`data\`** 子目录 |

---

## 五、★ 推送镜像分支（本项目的特殊流程）

★ 从本机 `D:\OAS-dev\OASX-src` **直接 push 会失败**：
它是 **shallow clone**，而 shallow 边界 `520d64d8` 在远端**已不存在**：

```
remote: fatal: did not receive expected object 92f63f57...
remote unpack failed: index-pack failed
```

`--no-thin` / 换分支名 / `--unshallow` **都试过，都不行**。

### ✅ 可行流程（全量镜像法）

```powershell
$X = 'D:\OAS-dev\OASX-src'
$V = 'D:\OAS-dev\_pushX'                     # 临时目录，放 build 之外

# 1) 全新**完整**克隆目标分支
git -c http.version=HTTP/1.1 clone --no-tags `
    --branch oas-tasks-ui-s7 https://github.com/passioki/OASX.git $V

# 2) ★ 用源仓库的**追踪文件集**覆盖镜像（并删掉镜像里多出来的）
Set-Location $X
$srcFiles = git ls-files
Set-Location $V
(git ls-files) | Where-Object { $_ -notin $srcFiles } |
    ForEach-Object { Remove-Item (Join-Path $V $_) -Force -ErrorAction SilentlyContinue }
foreach ($f in $srcFiles) {
  $d = Join-Path $V $f
  New-Item -ItemType Directory -Path (Split-Path $d -Parent) -Force | Out-Null
  Copy-Item (Join-Path $X $f) $d -Force
}

# 3) ★ 全量比对（**必须 248/248 / 或当前追踪文件数全一致**）
#    ★ 比对时**剥掉 `\r`** —— 否则 CRLF/LF 归一化会造成大量假差异
$bad = @()
foreach ($f in $srcFiles) {
  $a = [IO.File]::ReadAllText((Join-Path $X $f)) -replace "`r`n", "`n"
  $b = [IO.File]::ReadAllText((Join-Path $V $f)) -replace "`r`n", "`n"
  if ($a -cne $b) { $bad += $f }
}
if ($bad) { $bad | ForEach-Object { "** 不同: $_" } } else { "★ 全部一致" }

# 4) 在镜像里先跑测试，再提交推送
& 'D:\flutter3271\bin\flutter.bat' test
git add -A
git commit -m "..."
git -c http.postBuffer=524288000 -c http.version=HTTP/1.1 `
    push origin oas-tasks-ui-s7
```

★ 完成后**删掉 `$V`**。
★ 若 push 报网络错，**重试最多 10 次**（本项目遇到过瞬时失败）。

---

## 六、★ 写提交信息 / 临时文件的纪律（踩过多次）

| 坑 | 做法 |
|---|---|
| 多行 `git commit -m "..."` 里的中文引号被 PowerShell 拆坏 | ★ 写成文件，用 **`git commit -F <文件>`** |
| 临时文件被 `git add -A` **误提交** | ★ 临时脚本 / commit message 写到 **仓库外**（如 `D:\OAS-dev\_x.txt`）；或 `add` 前先删 |
| `_*.py` 探针残留在仓库 | ★ 每次用完 `Remove-Item`，`git status` 确认干净 |
