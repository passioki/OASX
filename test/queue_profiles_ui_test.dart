// ★★★ #9 执行顺序**配置页** —— 前端守卫 ★★★
//
// ## 用户原话
//
// > "添加**执行顺序配置页 1/2/3/……**，可以添加、删除和切换配置页"
//
// ## 用户已确认的设计（**照这个做, 不要再问**）
//
// | 问题 | 用户回答 | 本文件钉在哪 |
// |---|---|---|
// | 布局 | **A** —— 吸顶区下面单起一行 `配置页 ▪1▪ ▪2▪ ▪3▪ [＋新建] [⋯管理]` | `_profilesRow` |
// | 一页存什么 | **甲（全都算）**: 队列 + 每任务调度 + **全局开关** | `reload()` 在切换之后 |
// | 前端三项 | **A（算）**: 排序列/升降序 · 只看筛选 · 分栏宽度, **按页隔离** | `_prefsKey` 含页 id |
// | 初始状态 | **当前执行顺序就是页1**（后端已自动建） | 后端 `575358d6` |
// | 重命名 | **需要**（后端 `PUT /queue/profiles/rename` 已就绪） | `renameQueueProfile` |
//
// ## ⚠⚠ 本项目纪律: 断言源码文本前**必须先剥注释** ⚠⚠
//
// 已经踩过至少 5 次: 守卫匹配到**自己的说明文字** -> 假失败或假通过。
// 所以下面一律走 `_codeOnly()`。
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

const _view = 'lib/views/tasks/task_list_view.dart';
const _ctrl = 'lib/controller/task_list/task_list_controller.dart';
const _api = 'lib/api/api_client.dart';

void main() {
  group('① api_client 有 5 个配置页方法（走后端专用端点）', () {
    late String api;

    setUpAll(() => api = _codeOnly(_api));

    test('GET / POST / activate / rename / DELETE 都在', () {
      for (final m in [
        'getQueueProfiles',
        'createQueueProfile',
        'activateQueueProfile',
        'renameQueueProfile',
        'deleteQueueProfile',
      ]) {
        expect(api.contains(m), isTrue,
            reason: '★ api_client 缺 `$m` —— 配置页就没有后端接口可用');
      }
    });

    test('路径与后端契约逐一对应（拼错就是 404 静默失败）', () {
      // ★ 只断言**路径片段**（不写引号）—— 免得守卫被引号风格绑死。
      expect(api.contains('queue/profiles'), isTrue,
          reason: '★ 列表 / 新建都走这一个路径');
      expect(api.contains('queue/profiles/activate'), isTrue,
          reason: '★ 切页是 `PUT /queue/profiles/activate`');
      expect(api.contains('queue/profiles/rename'), isTrue,
          reason: '★ 改名是 `PUT /queue/profiles/rename`');
      expect(api.contains("/queue/profiles/\$id"), isTrue,
          reason: '★ 删除是 `DELETE /queue/profiles/{id}`（id 在**路径**里, '
              '不是 query/body）');
    });

    test('★ 一页 = 整页快照: 切页后必须**整体**刷新（用户裁定 1甲）', () {
      // ★ 这条守卫的存在理由是**踩过的坑**: 只刷新队列的话, 全局开关
      //   （启用临时/周期、休息穿插、队列跑空后）会显示成**别的页**的值
      //   —— 用户看到"改了不生效"。
      final ctrl = _codeOnly(_ctrl);
      expect(ctrl.contains('await reload()'), isTrue);
      expect(ctrl.contains('loadQueueProfiles'), isTrue);
      expect(api.contains('activate'), isTrue,
          reason: '★ 切页必须走**专用端点**（后端在同一个请求里'
              '"先存当前页再载目标页" —— 前端拼两个请求会留下半新半旧的状态）');
    });
  });

  group('② controller 有列表状态 + 5 个动作', () {
    late String ctrl;

    setUpAll(() => ctrl = _codeOnly(_ctrl));

    test('列表 / 当前页 id', () {
      expect(ctrl.contains('List<Map<String, dynamic>> queueProfiles'), isTrue,
          reason: '★ 缺配置页列表');
      expect(ctrl.contains('String queueProfileId'), isTrue,
          reason: '★ 缺当前页 id —— 它同时是偏好隔离键的一半');
      expect(ctrl.contains('Future<void> loadQueueProfiles()'), isTrue);
    });

    test('5 个动作都在（切换 / 新建 / 改名 / 删除 / 加载）', () {
      for (final m in [
        'loadQueueProfiles',
        'createQueueProfile',
        'activateQueueProfile',
        'renameQueueProfile',
        'deleteQueueProfile',
      ]) {
        expect(ctrl.contains(m), isTrue, reason: '★ controller 缺 `$m`');
      }
    });

    test('★ 切换之后必须 `reload()`（用户裁定 1甲 = 连同全局开关一起换）', () {
      for (final fn in [
        'Future<String> activateQueueProfile(',
        'Future<String> deleteQueueProfile(',
        'Future<String> createQueueProfile(',
      ]) {
        final i = ctrl.indexOf(fn);
        expect(i, greaterThan(0), reason: '找不到 $fn');
        final body = ctrl.substring(i, (i + 900).clamp(0, ctrl.length));
        expect(body.contains('await reload()'), isTrue,
            reason: '★ `$fn` 成功之后**必须** `await reload()` —— '
                '一页 = 队列 **+ 每任务调度 + 全局开关**（用户裁定 1甲）; '
                '只刷队列会让总开关显示成旧值（"改了不生效"）');
      }
    });

    test('文案用后端 `message`, 不自己再拼一遍', () {
      final i = ctrl.indexOf('Future<String> activateQueueProfile(');
      final body = ctrl.substring(i, (i + 900).clamp(0, ctrl.length));
      expect(body.contains("res['message']"), isTrue,
          reason: '★ 后端 `message` 已是给用户看的中文说明 —— '
              '前端再拼一遍必然漂移');
    });

    test('后端没这组端点时**不许**让整个列表打不开', () {
      final i = ctrl.indexOf('Future<void> loadQueueProfiles()');
      final body = ctrl.substring(i, (i + 1200).clamp(0, ctrl.length));
      expect(body.contains('catch'), isTrue,
          reason: '★ 旧后端返回 404 时要吞掉异常（只打日志）—— '
              '否则任务列表整块渲染不出来');
    });
  });

  group('③ 前端偏好**按页隔离**（用户裁定 2A —— 最容易忘的一步）', () {
    late String ctrl;

    setUpAll(() => ctrl = _codeOnly(_ctrl));

    test('★ prefs key = `<账号>:<页id>`', () {
      expect(ctrl.contains('_prefsKey'), isTrue,
          reason: '★ 必须有一个"按页"的 key 解析器');
      expect(ctrl.contains("'\$scriptName:\$pid'"), isTrue,
          reason: '★ key 必须是 `<账号>:<页id>` —— 用户裁定'
              '「排序列/升降序 · 只看筛选 · 分栏宽度, **按页隔离**」');
      expect(ctrl.contains('prefsStore.read(_prefsKey)'), isTrue);
      expect(ctrl.contains('prefsStore.write(_prefsKey'), isTrue);
    });

    test('★ 切页会换 prefs key（存旧页 -> 换 key -> 载新页）', () {
      final i = ctrl.indexOf('void _switchPrefsPage(');
      expect(i, greaterThan(0), reason: '★ 缺 `_switchPrefsPage` —— '
          '它就是"切页会换 key"的落点');
      final body = ctrl.substring(i, (i + 900).clamp(0, ctrl.length));
      // ★ 顺序: 先存旧页（此时 key 还是旧页）, 再换 id, 最后载新页
      expect(body.contains('_savePrefs()'), isTrue,
          reason: '★ 换 key **之前**必须先把旧页的三项存回旧 key —— '
              '否则用户刚改的排序在切页时**丢**');
      expect(body.contains('queueProfileId = next'), isTrue,
          reason: '★ 必须真的换 key 的那一半（页 id）');
      expect(body.contains('_loadPrefs()'), isTrue,
          reason: '★ 换完 key 要**载新页**的偏好');
      // ★ `_loadPrefs` 有"只读一次盘"的重入闸 —— 不清掉它, 切页后
      //   界面还是旧页的排序（看起来"切页没反应"）。这是**实测**踩过的坑。
      expect(body.contains('_prefsLoaded = false'), isTrue,
          reason: '★ 必须清掉 `_prefsLoaded` 重入闸 —— 否则不会重读盘,'
              '切页后排序/筛选**根本没换**');
    });

    test('★ 切页动作真的调了它（不是定义了没人用）', () {
      final i = ctrl.indexOf('Future<String> activateQueueProfile(');
      final body = ctrl.substring(i, (i + 900).clamp(0, ctrl.length));
      expect(body.contains('_switchPrefsPage('), isTrue,
          reason: '★ `activateQueueProfile` 里必须调 `_switchPrefsPage`');
      // ★ 顺序: 后端确认成功之后才换 key（失败了不该动偏好）
      final okIdx = body.indexOf("res['ok'] == true");
      final swIdx = body.indexOf('_switchPrefsPage(');
      expect(okIdx, greaterThan(-1));
      expect(swIdx, greaterThan(okIdx),
          reason: '★ 换 key 必须在 `res[ok] == true` **之后** —— '
              '切页失败就不该改偏好');
    });

    test('恢复默认只清**当前页**的偏好', () {
      final i = ctrl.indexOf('Future<bool> restoreDefaults()');
      final body = ctrl.substring(i, (i + 900).clamp(0, ctrl.length));
      expect(body.contains('prefsStore.clear(_prefsKey)'), isTrue,
          reason: '★ 恢复默认不该把**别的页**的偏好一起清掉');
    });
  });

  group('④ `_QueueTab` 渲染配置页 chips（布局 A）', () {
    late String view;
    late String qbody;

    setUpAll(() {
      view = _codeOnly(_view);
      final qi = view.indexOf('class _QueueTab');
      final qEnd = view.indexOf('\nclass ', qi + 10);
      qbody = view.substring(qi, qEnd > 0 ? qEnd : view.length);
    });

    test('`_profilesRow` 存在且在吸顶区里被渲染', () {
      expect(qbody.contains('_profilesRow('), isTrue,
          reason: '★ `_QueueTab` 缺配置页那一行（用户裁定布局 A: '
              '吸顶区下面**单起一行**）');
      expect(qbody.contains('SliverPersistentHeader'), isTrue,
          reason: '★ 它在**吸顶区**里（#6）—— 滚动时也必须一直看得见');
    });

    test('三件套: 页码 chip / ＋新建 / ⋯管理', () {
      expect(qbody.contains('_profileChip('), isTrue, reason: '缺页码 chip');
      expect(qbody.contains('新建'), isTrue, reason: '缺 [＋新建]');
      expect(qbody.contains('管理'), isTrue, reason: '缺 [⋯管理]');
    });

    test('★ 单击切页 / **双击改名**（用户确认"需要重命名"）', () {
      expect(qbody.contains('onTap:'), isTrue, reason: '单击要能切页');
      expect(qbody.contains('onDoubleTap:'), isTrue,
          reason: '★ 双击页码要改名（用户回答"4: 需要重命名"）');
      expect(qbody.contains('_renameProfile('), isTrue,
          reason: '★ 缺改名动作 —— 后端 `PUT /queue/profiles/rename` 就没入口');
    });

    test('★ 当前页高亮（实心）+ 显示的是**页名**', () {
      expect(qbody.contains('p[\'active\']'), isTrue,
          reason: '★ 靠后端 `active` 判断当前页（不自己猜）');
      expect(qbody.contains('queueProfileId'), isTrue,
          reason: '★ 也要与 controller 的当前页 id 对齐');
    });

    test('★ 后端没有这组端点时**不显示空壳**', () {
      final i = qbody.indexOf('Widget _profilesRow(');
      expect(i, greaterThan(0));
      final body = qbody.substring(i, (i + 1200).clamp(0, qbody.length));
      expect(body.contains('SizedBox.shrink()'), isTrue,
          reason: '★ 列表为空时要整行不显示 —— 显示一个空壳比不显示更糟');
    });

    test('删除有二次确认, 且说清"不删任务配置"', () {
      final i = qbody.indexOf('Future<void> _deleteProfile(');
      expect(i, greaterThan(0));
      final body = qbody.substring(i, (i + 1600).clamp(0, qbody.length));
      expect(body.contains('AlertDialog'), isTrue, reason: '★ 删除必须二次确认');
      expect(body.contains('不会删除任何任务配置'), isTrue,
          reason: '★ 要说明白"不删任务配置" —— 否则用户以为任务没了');
    });

    test('★ 提示用后端 `message`（前端不重写文案）', () {
      for (final fn in ['_activateProfile(', '_createProfile(']) {
        final i = qbody.indexOf('Future<void> $fn');
        expect(i, greaterThan(0), reason: '找不到 $fn');
        final body = qbody.substring(i, (i + 900).clamp(0, qbody.length));
        expect(body.contains('msg'), isTrue,
            reason: '★ `$fn` 要把后端 `message` 直接上屏');
      }
    });
  });
}
