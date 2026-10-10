part of login;

class LoginController extends GetxController {
  static bool logined = false;
  var username = ''.obs;
  var password = ''.obs;
  var address = ''.obs;

  GetStorage storage = GetStorage();

  /// 「等后端就绪」的轮询间隔。
  static const Duration backendProbeInterval = Duration(milliseconds: 500);

  /// 「等后端就绪」的总超时。
  ///
  /// ★ 不能用固定 `Future.delayed(5s)` 猜时间: OAS 后端要先跑
  ///   `python -m deploy.installer` 再起 FastAPI, **首次启动 10-30 秒都正常**。
  ///   所以每 [backendProbeInterval] 探一次, 探通就走, 探不通才等到超时。
  ///
  /// ★ 判超时用**墙上时钟**(deadline)而不是"够 N 次": 单次探测本身也有耗时
  ///   (连接超时就是 3 秒), 按次数算会让总等待变成好几分钟, 而给用户看的
  ///   超时提示写的是 30 秒 —— 文案和实际必须对得上。
  static const Duration backendReadyTimeout = Duration(seconds: 30);

  @override
  Future<void> onInit() async {
    username.value = storage.read(StorageKey.username.name) ?? "";
    password.value = storage.read(StorageKey.password.name) ?? "";
    address.value = storage.read(StorageKey.address.name) ?? "";

    if (address.value.isNotEmpty && !logined) {
      logined = true;
      await ensureBackendThenAutoLogin();
    }
    super.onInit();
  }

  /// 「双击启动」的启动顺序: **先确保后端在跑, 再自动登录**。
  ///
  /// 以前这里是直接 `login()`: 后端还没起来就报 "Failed to connect to OAS
  /// server", 用户得自己进服务器设置点一次启动, 再回来重新登录。
  ///
  /// ★ 已经在跑的后端**绝不重启** —— `ServerController.run()` 里有
  ///   `taskkill /f /t /im pythonw.exe`, 盲目重启会打断用户正在跑的任务。
  ///   所以第一步先探一次: 通了就直接自动登录, 完全不碰后端。
  Future<void> ensureBackendThenAutoLogin() async {
    final target = address.value;

    // 1. 后端已经可达 -> 直接自动登录。
    if (await probeBackend(target)) {
      await login(target);
      return;
    }

    // 2. 不可达 -> 先把它拉起来(只有 OAS 根目录通过校验才敢启动,
    //    见 startBackend)。返回 false 表示"这次没发出启动命令"。
    if (await startBackend()) {
      // ★★ 进度反馈（不能静默等 30 秒）★★
      //
      // 后端冷启动要跑 `deploy.installer` 再起 FastAPI, **10-30 秒很正常**。
      // ★ 用户明确要求"**先启动后端再自动登录**", 那就必须让他看见
      //   "正在启动" —— 否则双击之后界面一动不动, 他会以为程序卡死了
      //   （那正是他之前反复点排序按钮时的体验）。
      //
      // ⚠ 用**一条**长提示, 而不是轮询里反复弹:
      //   轮询 500ms × 60 次, 每条都弹就是刷屏。
      Get.snackbar(
          '正在启动后端',
          'OAS 后端未在运行，正在拉起（首次可能要 10-30 秒）…',
          snackPosition: SnackPosition.BOTTOM,
          duration: backendReadyTimeout,
          showProgressIndicator: true);
      // 3. 轮询等它就绪 —— 不阻塞 UI 线程, 只 await。
      final ready = await waitBackendReady(target);
      // ★ 关掉那条进度提示（成功/失败都要关, 否则它会盖在结果提示上）
      if (Get.isSnackbarOpen) {
        Get.closeCurrentSnackbar();
      }
      if (!ready) {
        Get.snackbar(
            'Error',
            '后端启动超时（${backendReadyTimeout.inSeconds} 秒），请到「服务器设置」检查',
            snackPosition: SnackPosition.BOTTOM);
        return;
      }
    }

    // 4. 就绪了(或者压根没配过 OAS 根目录 —— 那就让 login() 去报"连不上")。
    await login(target);
  }

  /// 探测后端是否可达: 通了返回 true。
  ///
  /// ★ `silent: true` 是必须的 —— 轮询时每 500ms 探一次, 若走
  ///   `testAddress()` 的默认分支, `ApiClient` 会在**每次**失败时弹一条
  ///   网络错误提示, 30 秒能弹 60 条, 那就成了刷屏。
  Future<bool> probeBackend(String target) async {
    ApiClient().setAddress('http://$target');
    return ApiClient().testAddress(silent: true);
  }

  /// 轮询等后端就绪: 通了立刻返回 true, 等满 [backendReadyTimeout] 返回 false。
  ///
  /// 只有 `await` + `Future.delayed`, **不 sleep、不阻塞 UI 线程**。
  Future<bool> waitBackendReady(String target) async {
    final deadline = DateTime.now().add(backendReadyTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await probeBackend(target)) {
        return true;
      }
      await Future.delayed(backendProbeInterval);
    }
    return false;
  }

  /// 尝试拉起 OAS 后端; 返回**是否真的发出了启动命令**。
  ///
  /// ★ 用户没配过 `rootPathServer`(或配的目录已经失效)时**不能**调
  ///   `ServerController.run()`: `Shell` 的 workingDirectory 就是个无效路径,
  ///   只会抛异常刷日志; 而且"还没设根目录"这件事服务器设置页已经会提示。
  ///
  /// ## ★★ 必须先判「地址是不是本机」★★
  ///
  /// `ServerController.run()` 里有一条 `taskkill /f /t /im pythonw.exe` ——
  /// 它会**杀掉本机所有 pythonw**。所以"自动拉起后端"只在
  /// **目标是本机**时才成立。否则会发生这种事:
  ///
  ///   用户存的是 `192.168.1.50:22288`(另一台机器) 且那台机器关机了
  ///   -> 探测失败 -> 走 `run()` -> **打掉本机正在跑的后端**
  ///   -> 拉起来的**本机**后端对 `192.168.1.50` 毫无帮助 -> 探测仍然失败
  ///   -> 30 秒后报"后端启动超时"
  ///
  /// ★ 净效果: **既打断了本机正在跑的任务, 又什么都没修好。**
  ///   `taskkill` 是**破坏性**操作, 宁可不做也不能做错。
  ///
  /// ⚠ 代价(已知且接受): 地址不是 loopback 的用户**不会**再享受"自动拉后端"
  ///   —— 那是**正确**的, 因为本机后端不可能服务一个远程地址。
  ///   他们要自己保证那台机器上的后端在跑。
  Future<bool> startBackend() async {
    final rootPath = storage.read('rootPathServer');
    if (rootPath is! String || rootPath.isEmpty) {
      return false;
    }
    // ★ 只有"目标是本机"才敢 taskkill + 重启。
    if (!_isLoopbackTarget(address.value)) {
      return false;
    }
    final server = serverController();
    if (server == null || !server.authenticatePath(rootPath)) {
      return false;
    }
    // run() 内部是**发出去就不管**的异步命令(taskkill / installer /
    // pythonw server.py, 见 ServerController.run), 所以这里不会卡住 UI。
    server.run();
    return true;
  }

  /// `host:port` 里的 host 是不是**本机**。
  ///
  /// ★ 为什么单独一个方法: 这是"能不能安全 taskkill"的**唯一判据**,
  ///   值得能单测、也值得有个名字 (见 `test/login_startup_test.dart`)。
  ///
  /// 认得的写法: `127.0.0.1` / `localhost` / `::1` / `0.0.0.0`。
  /// ⚠ `0.0.0.0` 也算本机: 它是"监听所有网卡"的写法, 用户填它时
  ///   99% 是想连自己这台; 且连 `0.0.0.0` 在 Windows 上本来就会落到本机。
  ///
  /// ⚠ `[::1]:22288` 这种带方括号的 IPv6 写法也认(v6 地址里有冒号,
  ///   不能简单按最后一个冒号切, 所以先去方括号)。
  static bool _isLoopbackTarget(String raw) {
    var s = raw.trim().toLowerCase();
    if (s.isEmpty) {
      return false;
    }
    // 去掉协议前缀(用户可能存 `http://127.0.0.1:22288`)
    for (final p in const ['http://', 'https://']) {
      if (s.startsWith(p)) {
        s = s.substring(p.length);
      }
    }
    // 去掉路径 / 查询(只取 host[:port] 那一段)
    final slash = s.indexOf('/');
    if (slash >= 0) {
      s = s.substring(0, slash);
    }
    String host;
    if (s.startsWith('[')) {
      // IPv6 字面量: [::1]:22288
      final close = s.indexOf(']');
      if (close < 0) {
        return false;
      }
      host = s.substring(1, close);
    } else {
      // ⚠ 不能无脑 `split(':')`: `::1` 没有方括号时会被切烂。
      //   这里只在"恰好一个冒号"时按冒号切(host:port),
      //   多于一个冒号说明是裸 IPv6, 整体当 host。
      final parts = s.split(':');
      host = parts.length == 2 ? parts[0] : s;
    }
    const loopbacks = {'127.0.0.1', 'localhost', '::1', '0.0.0.0'};
    return loopbacks.contains(host);
  }

  /// 取(必要时创建) `ServerController`; 环境不完整时返回 null。
  ///
  /// ★ 为什么**不能**直接 `Get.find<ServerController>()`:
  ///   `ServerController` 只在 `/server` 路由的 binding 里 `Get.put`
  ///   (见 views/routes.dart), 而登录页的 `LoginBinding` 只注册了
  ///   `LoginController` —— 在 `/login` 里 find 它必然抛
  ///   "ServerController not found"。所以 `isRegistered` 为假时自己 put,
  ///   已经注册过(比如用户先去过服务器设置页)就复用同一个实例,
  ///   免得出现两份 Shell / 两份日志流。
  ///
  /// ★ 依赖顺序(写下来, 免得下一个人以为这里不安全):
  ///   `ServerController.onInit()` 会读 `Get.find<SettingsController>().storage`
  ///   拿 `rootPathServer`。而 `SettingsController` 是 `main.dart` 的
  ///   `OASXApp.onInit` 里 `Get.put` 的 —— 那是 `GetMaterialApp.onInit`,
  ///   执行时机在**初始路由(/login)构建之前**, 所以这里拿得到。
  ///   (`rootPathServer` 本身是从 `GetStorage()` 直接读的, 与
  ///    `ServerController.onInit` 读的是同一个键、同一个容器, 不额外依赖 GetX。)
  ///
  /// 下面这层 `isRegistered` 只是保险: 万一以后注册时机变了, 宁可
  /// "不启动后端、让 login() 去报连不上", 也不要在这里抛异常,
  /// 把整个自动登录静默打断(那是双击启动时无人看守的路径)。
  ServerController? serverController() {
    if (!Get.isRegistered<SettingsController>()) {
      return null;
    }
    if (Get.isRegistered<ServerController>()) {
      return Get.find<ServerController>();
    }
    return Get.put<ServerController>(ServerController());
  }

  /// 进入主页面
  Future<void> toMain({required Map<String, dynamic> data}) async {
    storage.write(StorageKey.username.name, data['username']);
    storage.write(StorageKey.password.name, data['password']);
    storage.write(StorageKey.address.name, data['address']);
    printInfo(info: data.toString());
    await login(data['address']);
  }

  Future<void> login(String address) async {
    ApiClient().setAddress('http://$address');
    if (await ApiClient().testAddress()) {
      Get.offAllNamed('/main');
    } else {
      // 报错提示一律**从下边浮起来**, 与队列/任务页的提示保持一致。
      Get.snackbar('Error', 'Failed to connect to OAS server',
          snackPosition: SnackPosition.BOTTOM);
    }
  }
}
