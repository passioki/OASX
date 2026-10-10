// ★★★ 「双击启动」的启动顺序守卫 ★★★
//
// ## 用户原话
//
// > "**然后双击启动后应该首先尝试启动后端，然后再尝试自动登录。**"
//
// ## 为什么必须有这个文件
//
// 这是本轮**唯一无法自动化端到端验证**的功能 —— 启动流程要真的双击 app
// 才会跑，而那条路径会 `taskkill /f /t /im pythonw.exe`（**杀掉本机所有
// pythonw**）。所以在自动化测试里**绝不能**真的执行它。
//
// ★ 不能端到端测 -> 就退化成**源码守卫**: 把"顺序对不对""有没有踩
//   已知的坑"钉住。这比"什么都不测"强得多，而且这些坑都是真实踩过的:
//
//   ① 顺序必须是 **先探 -> 再启动 -> 再轮询 -> 最后登录**
//      （反了就是"后端没起来就先登录"，用户报过）
//   ② 轮询**不能**用"探 N 次"计超时 —— 单次探测自带 3 秒连接超时，
//      按次数算总时长会变成几分钟，而提示文案写的是 30 秒
//   ③ **不能** 用 `sleep(` —— 会阻塞 UI 线程
//   ④ ★ 启动前必须判**目标是不是本机** —— 因为 `run()` 里有 `taskkill`。
//      否则"地址填另一台机器 + 那台不可达"会打掉**本机**正在跑的后端，
//      而且拉起的本机后端对远程地址毫无帮助（必超时）。
//      净效果: **既打断用户正在跑的任务, 又什么都没修好。**
//   ⑤ 轮询探测必须是**静默**的 —— 否则 30 秒弹 60 条网络错误
//
// ⚠⚠ 断言源码文本前**必须剥注释**（本仓库已记录 ≥5 次"守卫匹配到自己的
//   说明文字"的假失败 / 假通过）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥掉 `//` 之后的内容（含 `///` 文档注释）。
String _codeOnly(String path) {
  final raw = File(path).readAsStringSync();
  return raw
      .split('\n')
      .map((l) {
        final i = l.indexOf('//');
        return i >= 0 ? l.substring(0, i) : l;
      })
      .join('\n');
}

const _ctrl = 'lib/controller/login/login_controller.dart';
const _api = 'lib/api/api_client.dart';

/// `login_controller.dart` 里**某个方法**的代码体（剥注释后）。
///
/// ★ 按**缩进**取到方法结束, 不靠魔法数字。
///
/// ⚠ 我第一版写的是 `src.substring(i, i + 3000)` —— 而那个文件只有
///   ~230 行, 于是直接 `RangeError: Invalid value: Not in inclusive range
///   1910..4557: 4910`。★ 教训: **"取固定 3000 字符"是把文件长度当契约**,
///   文件一短就崩、一长就截断（后者更危险: 会**静默**漏掉方法后半段,
///   断言在残缺文本上跑, 变成假通过）。
String _method(String name) {
  final src = _codeOnly(_ctrl);
  final i = src.indexOf(name);
  expect(i, greaterThan(0), reason: '找不到 $name');
  // 该方法的**顶层缩进**（`class` 里一层 = 2 空格）
  final lineStart = src.lastIndexOf('\n', i) + 1;
  final indent = src.substring(lineStart, i);
  final end = src.indexOf('\n$indent}', i);
  expect(end, greaterThan(i), reason: '$name 没有找到结束的 `}`');
  return src.substring(i, end + indent.length + 2);
}

void main() {
  group('① 顺序: 先探 -> 再启动 -> 再轮询 -> 最后登录', () {
    test('`onInit` 走的是 `ensureBackendThenAutoLogin`（不是直接 login）', () {
      final body = _method('Future<void> onInit()');
      expect(body.contains('ensureBackendThenAutoLogin'), isTrue,
          reason: '★ onInit 必须走"先确保后端"那条路径 —— '
              '直接 login 就是用户报过的"后端没起来就报连不上"');
    });

    test('四步的相对顺序正确', () {
      final src = _codeOnly(_ctrl);
      final probe = src.indexOf('await probeBackend(target)');
      final start = src.indexOf('await startBackend()');
      final wait = src.indexOf('waitBackendReady(target)');
      final login = src.lastIndexOf('await login(target)');
      expect(probe, greaterThan(0), reason: '缺 probeBackend 调用');
      expect(start, greaterThan(0), reason: '缺 startBackend 调用');
      expect(wait, greaterThan(0), reason: '缺 waitBackendReady 调用');
      expect(login, greaterThan(0), reason: '缺 login 调用');
      expect(probe < start, isTrue,
          reason: '★ 必须先**探测**再**启动** —— '
              '否则已经在跑的后端会被 taskkill 重启（打断用户任务）');
      expect(start < wait, isTrue, reason: '★ 必须先启动再轮询等待');
      expect(wait < login, isTrue,
          reason: '★ 必须等后端就绪**之后**才自动登录（用户明确要求）');
    });

    test('★ 已经在跑的后端**不被重启**（探测通了就直接登录）', () {
      final body = _method('Future<void> ensureBackendThenAutoLogin()');
      // ★ 别用"截 140 字符"那种窗口 —— 那会把**下一个分支**也框进来
      //   （我第一版就这么错的: `startBackend` 出现在后面的 `else` 分支里,
      //    于是"探测通了不能启动"这条**假失败**了）。
      //   改成用**唯一子串**定界: 取 `if (probe...)` 到 `return;` 之间。
      final i = body.indexOf('if (await probeBackend(target))');
      expect(i, greaterThanOrEqualTo(0), reason: '找不到探测分支');
      final j = body.indexOf('return;', i);
      expect(j, greaterThan(i), reason: '找不到探测分支的 return');
      final branch = body.substring(i, j);
      expect(branch.contains('login('), isTrue,
          reason: '探测通了应直接登录');
      expect(branch.contains('startBackend'), isFalse,
          reason: '★ 探测通了**不能**再启动后端 —— `run()` 里有 taskkill, '
              '会打断用户正在跑的任务');
    });
  });

  group('② 超时判据: 墙上时钟, 不是"探 N 次"', () {
    test('`waitBackendReady` 用 deadline 而不是循环计数', () {
      final body = _method('Future<bool> waitBackendReady(');
      expect(body.contains('DateTime.now().add('), isTrue,
          reason: '★ 必须用 deadline（墙上时钟）');
      expect(body.contains('isBefore(deadline)'), isTrue,
          reason: '★ 循环条件应是"还没到 deadline"');
      expect(RegExp(r'\bfor\s*\(').hasMatch(body), isFalse,
          reason: '★ 不该用 `for (i < N)` 计次数 —— 单次探测自带 3 秒连接'
              '超时, 按次数算总时长会变成几分钟, 与"30 秒"的文案对不上');
    });

    test('轮询间隔与超时是**具名常量**（文案能用同一个值）', () {
      final src = _codeOnly(_ctrl);
      expect(src.contains('backendProbeInterval'), isTrue);
      expect(src.contains('backendReadyTimeout'), isTrue);
      // 超时提示必须引用常量, 而不是写死"30 秒"
      final body = _method('Future<void> ensureBackendThenAutoLogin()');
      expect(body.contains('backendReadyTimeout.inSeconds'), isTrue,
          reason: '★ 文案里的秒数必须来自那个常量 —— '
              '写死就会出现"改了超时但文案没改"');
    });

    test('★ 不阻塞 UI 线程（没有 sleep）', () {
      final src = _codeOnly(_ctrl);
      expect(RegExp(r'\bsleep\s*\(').hasMatch(src), isFalse,
          reason: '★ `sleep(` 会阻塞 UI 线程 —— 只能用 await + Future.delayed');
      expect(src.contains('Future.delayed'), isTrue);
    });
  });

  group('③ ★ 破坏性操作前的保险: 只对**本机**才 taskkill+重启', () {
    test('`startBackend` 里先做 loopback 判断', () {
      final body = _method('Future<bool> startBackend()');
      expect(body.contains('_isLoopbackTarget'), isTrue,
          reason: '★ `startBackend` 必须先判"目标是不是本机" —— '
              '`ServerController.run()` 里有 `taskkill /f /t /im pythonw.exe`, '
              '对远程地址执行会**打掉本机正在跑的后端**且毫无帮助');
      // 判断必须在 run() 之前
      final guard = body.indexOf('_isLoopbackTarget');
      final run = body.indexOf('server.run()');
      expect(guard, greaterThanOrEqualTo(0));
      expect(run, greaterThan(guard),
          reason: '★ loopback 判断必须在 `server.run()` **之前**');
    });

    test('`_isLoopbackTarget` 认得 4 种本机写法', () {
      final src = _codeOnly(_ctrl);
      for (final h in ["'127.0.0.1'", "'localhost'", "'::1'", "'0.0.0.0'"]) {
        expect(src.contains(h), isTrue,
            reason: '★ 本机判据应包含 $h');
      }
    });

    test('它还要处理协议前缀 / 路径 / IPv6 方括号', () {
      // ★★ 这里必须用**原始源码**, 不能用 `_codeOnly()` ★★
      //
      // 因为 `_codeOnly()` 按 `//` 切 —— 而**字符串字面量**
      // `'http://'` 里正好含 `//`, 会被截成 `'http:`。
      // ★ 于是 `src.contains("'http://'")` **永远为 false**。
      //   （我第一版就这么错的。）
      //
      // ⚠ 剥注释与"字符串里有 `//`"天然冲突。这里要查的就是那个字面量,
      //   所以**故意**用原始文本 —— 这不是偷懒, 是这条断言的性质决定的。
      final raw = File(_ctrl).readAsStringSync();
      expect(raw.contains("'http://'"), isTrue,
          reason: '★ 用户可能存成 `http://127.0.0.1:22288` —— 要能剥协议前缀');
      expect(raw.contains("startsWith('[')"), isTrue,
          reason: '★ IPv6 字面量是 `[::1]:22288`, 不能按冒号硬切');
      expect(raw.contains('parts.length == 2'), isTrue,
          reason: '★ 只在"恰好一个冒号"时当 host:port —— '
              '裸 `::1` 多于一个冒号, 硬切会被切烂');
    });
  });

  group('④ 轮询必须静默（否则 30 秒弹 60 条）', () {
    test('`probeBackend` 传 `silent: true`', () {
      final body = _method('Future<bool> probeBackend(');
      expect(body.contains('silent: true'), isTrue,
          reason: '★ 轮询 500ms × 60 次, 每次失败都弹提示就是刷屏');
    });

    test('`ApiClient.testAddress` / `request` 有 `silent` 且默认 false', () {
      final a = _codeOnly(_api);
      expect(RegExp(r'testAddress\(\{bool silent = false\}\)').hasMatch(a),
          isTrue, reason: '★ testAddress 应有默认 false 的 silent 参数');
      expect(RegExp(r'\{bool silent = false\}').hasMatch(a), isTrue,
          reason: '★ request 应有默认 false 的 silent 参数（老调用点行为不变）');
    });

    test('提示都是 BOTTOM（用户要求"从下边浮起来"）', () {
      final a = _codeOnly(_api);
      // 这个文件里的两个提示函数都必须指定 BOTTOM
      expect(a.contains('snackPosition: SnackPosition.BOTTOM'), isTrue,
          reason: '★ 网络错误提示要从下边浮起来');
      final c = _codeOnly(_ctrl);
      expect(c.contains('snackPosition: SnackPosition.BOTTOM'), isTrue,
          reason: '★ 登录/超时提示要从下边浮起来');
    });

    test('★ **全仓**不得再有"没指定位置"的 Get.snackbar', () {
      // ## 用户原话
      // > "把这个消息弹窗改成**从下边弹出**, 现在是从**顶部**弹出, 影响操作"
      //
      // **根因**: `Get.snackbar()` 不传 `snackPosition` 时 GetX 默认落
      //   `SnackPosition.TOP`（顶部居中）—— 正好压住 AppBar / 工具栏 /
      //   表格表头, 所以"影响操作"。
      //
      // ★ 这条守卫**扫全仓**（不只是登录相关文件）: 29 处调用里原本有
      //   **17 处**没指定位置, 分散在 6 个文件里 —— 只修一处等于没修。
      final lib = Directory('lib');
      final offenders = <String>[];
      for (final f in lib.listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final lines = f.readAsStringSync().split('\n');
        for (var i = 0; i < lines.length; i++) {
          if (!lines[i].contains('Get.snackbar(')) continue;
          // ★ 按**括号配平**取整次调用（不能只看这一行:
          //   `snackPosition` 常写在后面几行）
          final seg = lines.sublist(i, (i + 40).clamp(0, lines.length))
              .join('\n');
          var depth = 0;
          var end = -1;
          var inStr = false;
          for (var k = 0; k < seg.length; k++) {
            final ch = seg[k];
            if (inStr) {
              if (ch == r'\') {
                k++;
                continue;
              }
              if (ch == "'") inStr = false;
            } else if (ch == "'") {
              inStr = true;
            } else if (ch == '(') {
              depth++;
            } else if (ch == ')') {
              depth--;
              if (depth == 0) {
                end = k;
                break;
              }
            }
          }
          final call = end >= 0 ? seg.substring(0, end + 1) : seg;
          if (!call.contains('SnackPosition.BOTTOM')) {
            offenders.add('${f.path}:${i + 1}');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: '★ 这些 Get.snackbar 没指定位置 -> GetX 默认弹在**顶部**,\n'
              '会压住 AppBar/工具栏, 用户明确说"影响操作"。\n'
              '请补 `snackPosition: SnackPosition.BOTTOM`:\n'
              '${offenders.join('\n')}');
    });
  });

  group('⑤ 等待期要有进度反馈（不能静默 30 秒）', () {
    test('启动后端后弹一条"正在启动"的长提示', () {
      final body = _method('Future<void> ensureBackendThenAutoLogin()');
      expect(body.contains('showProgressIndicator'), isTrue,
          reason: '★ 后端冷启动 10-30 秒 —— 界面一动不动用户会以为卡死');
      expect(body.contains('正在启动') || body.contains('正在拉起'), isTrue,
          reason: '★ 要有可读的"正在启动"文案');
      // 必须指定 duration（否则用默认 3-4 秒, 等不到 30 秒就没了）
      expect(body.contains('duration:'), isTrue,
          reason: '★ 那条提示的 duration 要够长（后端可能 30 秒才起来）');
    });

    test('结果提示前先关掉进度提示（否则两个叠在一起）', () {
      final body = _method('Future<void> ensureBackendThenAutoLogin()');
      final close = body.indexOf('closeCurrentSnackbar');
      expect(close, greaterThanOrEqualTo(0),
          reason: '★ 成功/失败都要先关掉"正在启动"那条');
    });
  });

  group('⑥ 不能凭空启动: 环境没配好时只报错, 不发命令', () {
    test('`rootPathServer` 缺失/非法 -> 直接返回 false', () {
      final body = _method('Future<bool> startBackend()');
      expect(body.contains("storage.read('rootPathServer')"), isTrue);
      expect(body.contains('return false'), isTrue,
          reason: '★ 没配过根目录时不能调 run()（Shell 的 workingDirectory '
              '是无效路径, 只会抛异常刷日志）');
      expect(body.contains('authenticatePath'), isTrue,
          reason: '★ 路径必须校验过才敢启动');
    });

    test('`ServerController` 在登录页不能直接 `Get.find`（会抛）', () {
      final body = _method('ServerController? serverController()');
      expect(body.contains('isRegistered<ServerController>()'), isTrue,
          reason: '★ `ServerController` 只在 `/server` 的 binding 里 put, '
              '在 `/login` 里 find 必抛 —— 必须先 isRegistered');
      expect(body.contains('Get.put<ServerController>'), isTrue,
          reason: '★ 未注册时自己 put');
    });
  });
}
