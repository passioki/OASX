// ★ 防回归: 启动期**三处必须容错** —— 实测踩过"白屏无提示"
//
// 用户报的现象: "双击 OASX 打不开"; 能开时是**白色半透明空窗口**。
// 根因链条(见 lib/main.dart / lib/utils/logger.dart 里的说明):
//   i18n 缓存损坏 -> LocaleService 起不来 -> 服务没注册
//   -> OASXApp.build() 的 `Get.find<LocaleService>()` 抛异常
//   -> **首帧渲染失败** -> 白屏
//
// 本文件钉住修复:
//   * `initLogger` 必须 **await** 且失败要降级(不能留未初始化的 late)
//   * 服务必须**一定被注册**(不能"失败就跳过")
//   * 首帧**绝不允许白屏**(Get.find 失败要兜底)
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String codeOnly(String path) {
  final raw = File(path).readAsStringSync();
  return raw.split('\n').map((l) => l.split('//').first).join('\n');
}

void main() {
  group('启动期容错(防白屏回归)', () {
    test('initLogger 必须 await，且失败要降级', () {
      final src = codeOnly('lib/utils/logger.dart');
      expect(src.contains('await getApplicationCacheDirectory()'), isTrue,
          reason: '★ 原来没有 await -> `late Logger logger` 可能从未初始化, '
              '而且回调异常会变成**未捕获的异步异常**');
      // ★ 必须先兜底赋值, 再尝试文件日志
      expect(src.contains('logger = _fallbackLogger()'), isTrue,
          reason: '★ 必须有一个不依赖文件系统的兜底日志器');
      expect(src.contains('catch'), isTrue,
          reason: '★ 日志目录不可用(实测 errno=5)不能阻止启动');
    });

    test('服务必须一定被注册（_ensureService 有重试与降级）', () {
      final src = codeOnly('lib/main.dart');
      expect(src.contains('_ensureService<LocaleService>'), isTrue,
          reason: '★ LocaleService 缺注册会让首帧 Get.find 抛异常 -> 白屏');
      expect(src.contains('_ensureService<ThemeService>'), isTrue);
      // ★ 不能再用"失败就跳过"的老写法
      expect(src.contains('_tryPut('), isFalse,
          reason: '★ "失败就跳过"正是白屏的成因, 已被 _ensureService 取代');
      expect(src.contains('attempt <= 2'), isTrue,
          reason: '★ 要有重试(很多失败是时序问题)');
    });

    test('OASXApp.build 的 Get.find 必须有兜底（绝不白屏）', () {
      final src = codeOnly('lib/main.dart');
      final i = src.indexOf('Widget build(BuildContext context) {');
      expect(i, greaterThan(0));
      final body = src.substring(i, (i + 1200).clamp(0, src.length));
      expect(body.contains('Get.find<LocaleService>()'), isTrue);
      expect(body.contains('catch'), isTrue,
          reason: '★ 裸 Find 抛异常 = 首帧失败 = 白屏（用户实测到的现象）');
      expect(body.contains('_ServiceDegradedBanner'), isTrue,
          reason: '★ 降级必须**可见** —— 以后同类问题不该再是静默白屏');
    });
  });
}