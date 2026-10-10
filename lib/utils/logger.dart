import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'package:logger/logger.dart';

late Logger logger;

/// ★★★ 启动期**兜底日志器**（不依赖文件系统）★★★
///
/// ## 为什么必须有（实测踩到的真故障）
///
/// 原实现是 `getApplicationCacheDirectory().then((dir) { ... logger = ... })`
/// —— **既没有 `await`，也没有 `catchError`**。于是:
///
/// 1. `initLogger()` **立刻返回**，`logger` 仍是**未初始化的 `late`**；
///    此时任何 `logger.x` 都会抛 `LateInitializationError`。
/// 2. 若那个 `.then` 回调里抛异常（例如**目录不可写**:
///    `PathAccessException ... errno = 5`），它就成了一个
///    **未捕获的异步异常** —— 会**把进程整个带走**。
///
/// ★ 实测: 用户机器上 `%LOCALAPPDATA%\<appId>` 与
///   `Documents\GetStorage.gs` 都被拒绝访问(errno=5) ->
///   日志/存储初始化抛异常 -> `initService()` 抛出 ->
///   `runApp()` **永不执行** -> **窗口永不出现**（进程活着 = "打不开"）。
///
/// ★ 所以: 先给一个**一定能用**的控制台日志器；文件日志成功了再替换。
///   写不出文件只是"没日志"，**绝不该让应用起不来**。
Logger _fallbackLogger() => Logger(
      filter: ProductionFilter(),
      printer: SimplePrinter(printTime: true),
      output: CustomConsoleOutput(),
    );

Future<void> initLogger() async {
  // ★ 先兜底: 保证 `logger` 在任何情况下都**已被赋值**
  logger = _fallbackLogger();

  try {
    // ★★ 必须 `await` —— 见上面的说明
    final appDocDir = await getApplicationCacheDirectory();
    final logPath = appDocDir.path;
    final logDir = Directory('$logPath/logs');
    if (!logDir.existsSync()) {
      logDir.createSync(recursive: true);
    }
    final dateTime = DateTime.now().toIso8601String().substring(0, 10);
    logger = _getLogger(logDir.path, dateTime);
    logger.i('---------------------------------------------------------------');
    logger.i('Logger initialized');
    logger.i('log path: ${logDir.path}/$dateTime.txt');
    logger.i('App path: ${Directory.current.path}');

    await _cleanupOldLogs(logDir.path);
  } catch (e) {
    // ★ 文件日志不可用**不是致命错误** —— 降级到控制台继续启动
    logger = _fallbackLogger();
    logger.w('日志目录不可用, 已降级为控制台日志: $e');
    logger.w('App path: ${Directory.current.path}');
  }
}

class CustomConsoleOutput extends LogOutput {
  @override
  void output(OutputEvent event) {
    for (var line in event.lines) {
      stdout.write('$line\n');
    }
  }
}

Logger _getLogger(String logPath, String dateTime) {
  //
  LogFilter filter = ProductionFilter();
  //
  LogPrinter printer = SimplePrinter(printTime: true);
  //
  MultiOutput multiOutput = MultiOutput([
    FileOutput(
      file: File('$logPath/$dateTime.txt'),
      encoding: utf8,
    ),
    CustomConsoleOutput(),
  ]);

  return Logger(
    filter: filter,
    printer: printer,
    output: multiOutput,
  );
}

Future<void> _cleanupOldLogs(String logDirPath) async {
  try {
    final logDir = Directory(logDirPath);
    if (!logDir.existsSync()) return;

    final thirtyDaysAgo = DateTime.now().subtract(const Duration(days: 30));
    final files = logDir.listSync();
    int deletedCount = 0;
    for (var file in files) {
      if (file is File && file.path.endsWith('.txt')) {
        // 从文件名提取日期（假设文件名格式为 "yyyy-MM-dd.txt"）
        final fileName = file.uri.pathSegments.last;
        if (fileName.length >= 14 && fileName.endsWith('.txt')) {
          try {
            final dateStr = fileName.substring(0, 10);
            final fileDate = DateTime.parse(dateStr);
            if (fileDate.isBefore(thirtyDaysAgo)) {
              await file.delete();
              deletedCount++;
            }
          } catch (e) {
            continue;
          }
        }
      }
    }

    if (deletedCount > 0) {
      logger.i('Cleaned up $deletedCount old log files');
    }
  } catch (e) {
    logger.e('Error cleaning up old logs: $e');
  }
}
