// ★★★ [11-13] 守卫：`GetStorage` 的 **init 目标** 必须与 **所有消费方** 一致 ★★★
//
// ## 为什么要有这条守卫（[11-13] 实测事故）
//
// `get_storage 2.1.1` 的真实语义（源码 `storage_impl.dart:11-12 / 40-42`）：
//
//     factory GetStorage([String container = 'GetStorage', ...])
//     static Future<bool> init([String container = 'GetStorage'])
//
// ⇒ `GetStorage()` **永远只用字面量默认容器 `'GetStorage'`**，
//   **不会**跟随 `init('xxx')` 传入的名字（2.1.1 里没有"当前容器"这个静态量）。
//
// 原代码：`main.dart` 写 `GetStorage.init('GetStorage-live')`，
// 而 7 个消费方全是无参 `GetStorage()`（theme_service / login_controller /
// window_service / task_prefs / settings / script_service / locale_service）
// ⇒ **初始化的是 `GetStorage-live.gs`（`{}`），读写的却是 `GetStorage.gs`**
// ⇒ 设置读不到 ⇒ 白主题 + 要重填后端地址 + `rootPathServer` 空
// ⇒ `login_controller.dart:140` 直接 `return false` ⇒ **不自动拉起后端**。
//
// 修法：init 用**默认容器**，两个盒子合一（零数据迁移）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String p) => File(p).readAsStringSync();

/// 形如 `GetStorage.init('xxx'` / `GetStorage.init(\n  "xxx"` —— 带容器名的初始化
/// ★ 用**三引号原始字符串**：普通原始字符串里 `\"` 不是转义，会把字面量截断。
final _namedInit = RegExp(r"""GetStorage\.init\(\s*['"]""");

void _storageContainerGuards() {
  test('main.dart 必须以【默认容器】初始化：GetStorage.init()', () {
    final src = _read('lib/main.dart');
    expect(src.contains('GetStorage.init()'), isTrue,
        reason: 'main.dart 必须写 `await GetStorage.init();`（无参数）');
    expect(_namedInit.hasMatch(src), isFalse,
        reason: '★ main.dart 里出现带容器名的 GetStorage.init(...) '
            '⇒ 会与无参 GetStorage() 拆成两个盒子（[11-13] 事故重演）');
  });

  test('lib/ 下任何文件都不许带容器名调用 GetStorage.init(...)', () {
    final offenders = <String>[];
    for (final e in Directory('lib').listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final m = _namedInit.firstMatch(e.readAsStringSync());
      if (m != null) offenders.add('${e.path} -> ${m.group(0)}');
    }
    expect(offenders, isEmpty,
        reason: '★ 这些文件用带名字的容器初始化，会与消费方拆开：$offenders');
  });

  test('消费方仍然是无参 GetStorage()（本守卫的语义前提）', () {
    // ★ 反向守卫：如果哪天有人把消费方改成带容器名，
    //   上面两条就失去意义 ⇒ 一起钉住。
    const consumers = [
      'lib/service/theme_service.dart',
      'lib/controller/login/login_controller.dart',
      'lib/service/window_service.dart',
    ];
    for (final p in consumers) {
      final src = _read(p);
      expect(src.contains('GetStorage()'), isTrue,
          reason: '$p 应使用无参 GetStorage()；改了就必须同步更新本守卫');
    }
  });
}

void main() {
  group('★ 存储容器一致性（[11-13]）', _storageContainerGuards);
}
