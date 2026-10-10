part of server;

class ServerController extends GetxController with LogMixin {
  final rootPathServer = ''.obs;
  final rootPathAuthenticated = true.obs;
  final showDeploy = true.obs;

  final log = ''.obs;
  final deployContent = ''.obs;
  Shell? shell;

  /// 读取 OAS 子进程输出的行控制器。
  ///
  /// **必须显式指定 `encoding: utf8`**: `ShellLinesController()` 默认使用
  /// `shellContext.encoding`, 而它在 IO 平台上就是 Dart 的 `systemEncoding` ——
  /// Windows 下该值是 Latin-1(每个字节映射成一个字符), 不是 UTF-8。
  ///
  /// 而 OAS 侧 `deploy/launcher/*.bat` 与 `module/base/encoding.py` 都把标准输出
  /// 明确设为 UTF-8, 于是"写 UTF-8 / 按 Latin-1 读"就产生了乱码:
  ///   `════` (U+2550, UTF-8 为 E2 95 90 …) -> `鈺愨晲`
  ///   `伴生树` -> `ä¼´çæ`(中文) 或 `浼寸敓鏍`(若按 GBK 显示)
  /// 日志文件本身一直正常 —— 它由 Python 以 encoding='utf-8' 直接写入, 不经这条链路。
  ///
  /// 详见 process_run 的 lib/src/lines_utils_common.dart:
  ///   this.encoding = encoding ?? shellContext.encoding;
  ///   ... ctlr.add(encoding!.decode(currentLine!));
  var shellController = ShellLinesController(encoding: utf8);

  @override
  void onInit() {
    rootPathServer.value =
        Get.find<SettingsController>().storage.read('rootPathServer') ??
            'Please set OAS root path';
    shell = getShell;
    shellController.stream.listen((event) {
      addLog('INFO: $event');
    });
    rootPathAuthenticated.value = authenticatePath(rootPathServer.value);
    if (rootPathAuthenticated.value) {
      readDeploy();
    }
    super.onInit();
  }

  void updateRootPathServer(String value) {
    if (authenticatePath(value)) {
      rootPathAuthenticated.value = true;
    } else {
      rootPathAuthenticated.value = false;
    }
    // value = value.replaceAll('\\', '\\\\');
    rootPathServer.value = value;
    shell = getShell;
    Get.find<SettingsController>()
        .storage
        .write('rootPathServer', rootPathServer.value);
    if (rootPathAuthenticated.value) {
      readDeploy();
    }
  }

  bool authenticatePath(String root) {
    root.replaceAll('\\', '/');
    try {
      // 先是判断根目录
      Directory rootDir = Directory(root);
      if (!rootDir.existsSync()) {
        return false;
      }
      // 然后是判断python是否存在
      File python = File('${rootDir.path}/toolkit/python.exe');
      if (!python.existsSync()) {
        return false;
      }
      // 然后判断git是否存在
      File git = File('${rootDir.path}/toolkit/Git/cmd/git.exe');
      if (!git.existsSync()) {
        return false;
      }
      // 然后判断安装器是否存在
      File installer = File('${rootDir.path}/deploy/installer.py');
      if (!installer.existsSync()) {
        return false;
      }
      // 然后判断deploy是否存在
      File deploy = File('${rootDir.path}/config/deploy.yaml');
      if (!deploy.existsSync()) {
        return false;
      }
    } catch (e) {
      printError(info: e.toString());
      return false;
    }

    return true;
  }

  String get pathGit => '${rootPathServer.value}\\toolkit\\Git\\mingw64\\bin"';
  String get pathPython => '${rootPathServer.value}\\toolkit';
  String get pathAdb =>
      '${rootPathServer.value}\\toolkit\\Lib\\site-packages\\adbutils\\binaries';
  String get pathScripts => '${rootPathServer.value}\\toolkit\\Scripts';
  Map<String, String> get pathPATH => {
        'PATH':
            '${rootPathServer.value},$pathGit,$pathPython,$pathAdb,$pathScripts'
      };
  Shell get getShell => Shell(
        workingDirectory: rootPathServer.value,
        runInShell: true,
        environment: pathPATH,
        stdout: shellController.sink,
        verbose: false,
      );

  /// 允许失败的命令: 它失败是**预期行为**, 不应打印成 ERROR。
  ///
  /// `taskkill /f /t /im pythonw.exe` 在没有 pythonw 进程时退出码为 128,
  /// 于是每次启动 OASX 都会在日志顶部留下
  /// `ShellException(..., exitCode 128, ...)` 这条假错误, 把真正的问题淹没。
  ///
  /// 这里用 `|| ver >nul` 把退出码归一为 0(`ver` 是 Windows cmd 的恒真命令),
  /// 既保留命令的实际作用, 又不再产生误导性的错误日志。
  ///
  /// (原先还有 `pwd` —— 它已被下面的 `cd` 取代, 见 run()。)
  static const _toleratedCommands = {
    'taskkill /f /t /im pythonw.exe',
  };

  Future<void> runShell(String command) async {
    final tolerated = _toleratedCommands.contains(command);
    try {
      // process_run 的 Shell.run 返回 List<ProcessResult>; outText/errText 是
      // 定义在 List<ProcessResult> 上的扩展(见 process_run 的
      // process_result_common_extension.dart), 因此必须对整个结果列表取属性。
      final results =
          await shell!.run(tolerated ? '$command || ver >nul' : command);
      final out = results.outText;
      final err = results.errText;
      if (out.isNotEmpty) {
        printInfo(info: out);
      }
      if (err.isNotEmpty) {
        printInfo(info: err);
      }
    } on ShellException catch (e) {
      // 允许失败的命令即使仍然抛错也不记为 ERROR
      if (tolerated) {
        return;
      }
      addLog('ERROR: ${e.toString()}');
    }
  }

  void run() {
    clearLog();
    shell!.kill();
    runShell('echo OAS working directory: ').then((value) => null);
    // 用 `cd` 代替原先的 `pwd`: Windows 的 shell 没有 pwd, 每次启动都会报
    // ShellException(pwd, exitCode 1)。`cd` 在 cmd 下会打印当前目录, 语义等价。
    runShell('cd').then((value) => null);
    runShell('python -m deploy.installer').then((value) => null);
    runShell('echo Start OAS').then((value) => null);
    runShell('taskkill /f /t /im pythonw.exe').then((value) => null);
    runShell(".\\toolkit\\pythonw.exe  server.py").then((value) => null);
  }

  void readDeploy() {
    String filePath = '${rootPathServer.value}\\config\\deploy.yaml';
    try {
      File file = File(filePath);
      if (file.existsSync()) {
        deployContent.value = file.readAsStringSync();
        return;
      } else {
        deployContent.value = 'File not found';
        return;
      }
    } catch (e) {
      deployContent.value = 'Error reading file: $e';
      return;
    }
  }

  void writeDeploy(String value) {
    String filePath = '${rootPathServer.value}\\config\\deploy.yaml';
    deployContent.value = value;
    try {
      File file = File(filePath);
      if (file.existsSync()) {
        file.writeAsStringSync(deployContent.value);
        return;
      } else {
        deployContent.value = 'File not found';
        return;
      }
    } catch (e) {
      deployContent.value = 'Error writing file: $e';
      return;
    }
  }
}
