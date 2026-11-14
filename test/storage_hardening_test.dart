// ★★★ [11-14] 守卫：本地存储**不许被"启动时的无条件写"清空** ★★★
//
// ## 实机事故
// `Documents\GetStorage.gs` 从 175 B（含 `rootPathServer` / `address` / `dark`）
// 被覆盖成 **66 B，只剩 `temporaryDirectory`** ⇒ 用户"设置好后端位置、重启就丢"。
//
// ## 机制
// `get_storage` 的 write 是**整文件覆盖**。`SettingsController.updateTemporaryDirectory()`
// 在**启动时无条件** `storage.write('temporaryDirectory', …)`：
//   · 若本次启动读存储失败/读到空（`errno=5`、或上一实例占着文件）⇒ 内存是空 map
//   • 这行 write 就把「空 map + temporaryDirectory」落盘 ⇒ **其它设置全丢**
// `temporaryDirectory` 每次启动都能重新算 ⇒ **根本不需要持久化**。
//
// ## 本文件断言
// | # | 断言 |
// |---|---|
// | ① | `settings.dart` **不许**再写 `temporaryDirectory`（否则清空风险回来） |
// | ② | `main.dart` 必须有**备份**（`_backupStorage`）与**空存储恢复**（`_restoreStorageIfEmpty`） |
// | ③ | `main.dart` 的 `GetStorage.init()` 必须**带超时**（否则被占锁时永久无窗口） |
// | ④ | 顺序：备份 → init → 恢复 |
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String p) => File(p).readAsStringSync();

void main() {
  group('★ 本地存储加固（[11-14]）', () {
    test('① settings.dart 不许写 temporaryDirectory', () {
      final src = _read('lib/controller/settings.dart');
      // ★ 只看**代码行**：注释里也解释过这句（含同样的字符串），不能误判
      final code = src
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(code.contains("write('temporaryDirectory'"), isFalse,
          reason: '★ 这条 write 会在启动时整文件覆盖 GetStorage.gs '
              '⇒ 读到空时把全部设置清掉（实机已发生）');
      expect(src.contains("read('temporaryDirectory')"), isTrue,
          reason: '读取可保留（兼容旧数据）');
    });

    test('② main.dart 必须有备份 + 空存储恢复', () {
      final src = _read('lib/main.dart');
      expect(src.contains('_backupStorage'), isTrue, reason: '缺少启动前备份');
      expect(src.contains('_restoreStorageIfEmpty'), isTrue,
          reason: '缺少"读到空就从 .bak 恢复"');
      expect(src.contains('GetStorage.gs.bak'), isTrue,
          reason: '备份文件名必须是 GetStorage.gs.bak');
    });

    test('③ GetStorage.init() 必须带超时', () {
      final src = _read('lib/main.dart');
      expect(RegExp(r'GetStorage\.init\(\)\s*\.timeout\(').hasMatch(src), isTrue,
          reason: '★ 文件被另一实例占着时，无超时的 init 会永久卡住 '
              '⇒ 表现为"双击没窗口"');
    });

    test('④ 顺序：备份 → init → 恢复', () {
      final src = _read('lib/main.dart');
      final iBak = src.indexOf('await _backupStorage();');
      final iInit = src.indexOf('await GetStorage.init().timeout(');
      final iRes = src.indexOf('await _restoreStorageIfEmpty();');
      expect(iBak, greaterThan(0));
      expect(iInit, greaterThan(iBak), reason: '★ 必须先备份再 init');
      expect(iRes, greaterThan(iInit), reason: '★ 必须在 init 之后才做空存储恢复');
    });
  });
}
