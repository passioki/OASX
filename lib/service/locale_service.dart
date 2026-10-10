import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';
import 'package:oasx/api/api_client.dart';
import 'package:oasx/model/const/storage_key.dart';

import 'package:oasx/config/translation/i18n.dart';
import 'package:path_provider/path_provider.dart';

class LocaleService extends GetxService with DynamicMessages {
  final _storage = GetStorage();
  final language = 'zh-CN'.obs;

  final fallbackLocale = const Locale('zh', 'CN');

  Locale get currentLocale => _loadLocaleFromStorage();

  @override
  void onInit() {
    loadMessage();
    language.value = _storage.read(StorageKey.language.name) ?? 'zh-CN';
    _updateLocale(language.value);
    super.onInit();
  }

  void switchLanguage(String lang) {
    language.value = lang;
    _storage.write(StorageKey.language.name, lang);
    _updateLocale(lang);
  }

  void _updateLocale(String lang) {
    final locale = switch (lang) {
      'zh-CN' => const Locale('zh', 'CN'),
      'en-US' => const Locale('en', 'US'),
      _ => fallbackLocale,
    };
    Get.updateLocale(locale);
  }

  Locale _loadLocaleFromStorage() {
    final code = _storage.read(StorageKey.language.name);
    if (code == null) return fallbackLocale;
    return Locale(code);
  }
}

mixin DynamicMessages {
  late final Messages _messages = Messages();
  Messages get messages => _messages;

  /// 运行时**未命中**的 key（去重）。
  ///
  /// ★ 为什么要收集: GetX 的 `.tr` 查不到 key 时**原样返回 key** ——
  ///   于是 `charge_enable_help` 就赤裸裸显示在界面上，**没有任何报错**。
  ///   这种"静默降级"让翻译缺口长期不可见（本次实测: 113 个 key 两边都没有，
  ///   界面上一直显示英文，却无人发现）。
  ///
  ///   现在记录并上报给后端（`POST /home/missing_translate`），
  ///   后端写入 `log/missing_translate.txt`，于是"还剩哪些没翻"变得**可见**。
  final Set<String> missingKeys = <String>{};

  Future<bool> loadMessage() async {
    await _loadLocaleMessage('zh-CN');
    await _loadLocaleMessage('en-US');
    return true;
  }

  /// **从后端拉取权威全量中文表**（单一数据源）。
  ///
  /// ★ 方向与原来相反:
  ///   * 原来: 前端 `PUT` 自己那 746 条 -> **整份覆盖**后端 1090 条 -> 每次丢 344 条
  ///   * 现在: 前端 `GET` 后端全量表 -> 合并进来（后端优先，因为是权威）
  ///
  /// 本地缓存(`getApplicationCacheDirectory()/i18n/zh-CN.json`)仍会读，
  /// 但它是**旧版本残留**，优先级低于后端。
  Future<void> loadFromBackend(ApiClient api) async {
    try {
      final remote = await api.getChineseTranslate();
      if (remote.isEmpty) return;
      remote.forEach((key, value) =>
          _messages.translateUpdate(key, value, locale: 'zh-CN'));
      printInfo(info: 'Loaded ${remote.length} translations from backend');
    } catch (e) {
      printError(info: 'loadFromBackend failed: $e');
    }
  }

  Future<bool> _loadLocaleMessage(String lang) async {
    try {
      Directory appDocDir = await getApplicationCacheDirectory();
      // final json = await rootBundle.loadString('assets/i18n/$lang.json');
      String filePath = '${appDocDir.path}/i18n/$lang.json';
      File file = File(filePath);
      String json = await file.readAsString();
      final dataMap = jsonDecode(json) as Map<String, dynamic>;
      dataMap.forEach(
          (key, value) => _messages.translateUpdate(key, value, locale: lang));
    } catch (e) {
      // ★ 缓存不存在是**正常情况**（首次启动），不该当成错误刷屏
      printInfo(info: 'No cached i18n for $lang (first run?)');
    }
    return true;
  }

  /// 翻译一个 key；**未命中就记下来**并原样返回。
  ///
  /// 界面统一走它而不是直接 `.tr` —— 这样缺口不会被静默吞掉。
  String trOrRecord(String key) {
    if (key.isEmpty) return key;
    final hit = _messages.all_cn_translate[key];
    if (hit != null && hit.isNotEmpty) return hit;
    missingKeys.add(key);
    return key;
  }

  /// 把当前语言下缺失的 key 反馈给后端（失败不影响使用）。
  Future<void> reportMissing(ApiClient api) async {
    if (missingKeys.isEmpty) return;
    try {
      await api.reportMissingTranslate(missingKeys.toList());
      printInfo(info: 'Reported ${missingKeys.length} missing keys');
    } catch (e) {
      printError(info: 'reportMissing failed: $e');
    }
  }

  Future<bool> saveAdditionalTranslate(
      Map<String, Map<String, String>> data) async {
    await _saveAdditionalTranslate(data["zh-CN"]!, lang: 'zh-CN');
    await _saveAdditionalTranslate(data["en-US"]!, lang: 'en-US');
    return true;
  }

  Future<bool> _saveAdditionalTranslate(Map<String, String> data,
      {String lang = "zh-CN"}) async {
    try {
      JsonEncoder encoder = const JsonEncoder.withIndent('  ');
      String jsonString = encoder.convert(data);
      Directory appDocDir = await getApplicationCacheDirectory();
      String i18nDirPath = '${appDocDir.path}/i18n';
      Directory i18nDir = Directory(i18nDirPath);
      if (!i18nDir.existsSync()) {
        i18nDir.createSync(recursive: true);
      }
      String filePath = '$i18nDirPath/$lang.json';
      printInfo(info: 'Save additional translate to $filePath');
      File file = File(filePath);
      await file.writeAsString(jsonString);
    } catch (e) {
      printError(info: e.toString());
    }
    return true;
  }
}
