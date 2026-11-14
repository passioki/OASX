import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';
import 'package:oasx/api/api_client.dart';
import 'package:oasx/service/script_service.dart';
import 'package:oasx/config/translation/i18n_content.dart';
import 'package:oasx/views/nav/view_nav.dart';
import 'package:path_provider/path_provider.dart';

import 'package:oasx/utils/check_version.dart';
import 'package:oasx/config/global.dart';

/// language: String ["en-US", "zh-CN", "zh-TW", "ja-JP"]
/// 关于桌面分辨率的适配： 不知道如何下手
class SettingsController extends GetxController {
  GetStorage storage = GetStorage();
  late String temporaryDirectory;

  @override
  void onInit() {
    updateTemporaryDirectory();
    getCurrentVersion().then((value) {
      GlobalVar.version = value;
    });
    super.onInit();
  }

  void updateTemporaryDirectory() {
    temporaryDirectory = storage.read('temporaryDirectory') ?? './';
    printInfo(info: 'Old TemporaryDirectory : $temporaryDirectory');
    getTemporaryDirectory().then((value) {
      temporaryDirectory = value.path;
      printInfo(info: 'New TemporaryDirectory : $temporaryDirectory');
      // ★★★ [11-14] 这里原来有一句 `storage.write('temporaryDirectory', …)` ★★★
      //
      // ## 它就是"设置好后端位置、重启就丢"的**直接执行者**
      //
      // `get_storage` 每次 write 都是**整文件覆盖**（`GetStorage.gs`）。
      // 而它写在**启动时无条件执行**：
      //   · 若本次启动读存储失败/读到空（历史 `PathAccessException errno=5`、
      //     或上一个实例还占着文件）⇒ 内存里是**空 map**
      //   · 紧接着这行 write 就把「空 map + temporaryDirectory」落盘
      //   ⇒ ★ **其它设置（`rootPathServer` / `address` / `dark` …）全部消失**
      //
      // 实机证据（[11-14]）：`GetStorage.gs` 从 175 B
      // （含 rootPathServer/address/dark）变成 **66 B，只剩 temporaryDirectory**，
      // 时间正好是那次启动。
      //
      // ## 为什么可以直接删掉
      // `temporaryDirectory` 是**每次启动都能重新算出来**的临时目录，
      // ★ **不需要持久化**：下面的 `getTemporaryDirectory()` 已经把它算好了。
      // 删掉这次写 = 去掉一个"每次都覆盖全部设置"的危险动作。
      // （读取那行保留：兼容旧数据，读到就用，读不到用 './'）
    });
  }

  Future<void> killServer() async {
    final success = await ApiClient().killServer();
    if (success) {
      Get.snackbar(I18n.kill_server_success.tr, '', snackPosition: SnackPosition.BOTTOM);
      Get.offAllNamed('/login');
      await Future.wait([
        Get.delete<ScriptService>(force: true),
        Get.delete<NavCtrl>(force: true),
      ]);
    } else {
      Get.snackbar(I18n.kill_server_failure.tr, '', snackPosition: SnackPosition.BOTTOM);
    }
  }
}
