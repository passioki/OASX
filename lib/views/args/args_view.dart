library args;

// import 'dart:ffi';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pickers/pickers.dart';
import 'package:flutter_pickers/style/default_style.dart';
import 'package:get/get.dart';
import 'package:oasx/views/nav/view_nav.dart';
import 'package:styled_widget/styled_widget.dart';
import 'dart:convert';
import 'package:expansion_tile_group/expansion_tile_group.dart';
import 'dart:async';

import 'package:oasx/api/api_client.dart';
import 'package:oasx/service/locale_service.dart';

import '../../config/translation/i18n_content.dart';

part './group_view.dart';
part './date_time_picker.dart';
// ★ S4: **窗口列表编辑器**（`windows` 是 `List[TaskWindow]`, 原生表单渲染不了）
part './window_editor.dart';
part '../../controller/args/args_controller.dart';

class Args extends StatelessWidget {
  const Args({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return GetX<ArgsController>(builder: (controller) {
      return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: ExpansionTileGroup(
                      spaceBetweenItem: 10, children: _childrenGroup(context))
                  .constrained(maxWidth: 700, minWidth: 100))
          .alignment(Alignment.topCenter);
    });
  }

  List<ExpansionTileItem> _childrenGroup(BuildContext context) {
    ArgsController controller = Get.find();
    return controller.groupsName.value
        .map((name) => ExpansionTileItem(
              initiallyExpanded: true,
              isHasTopBorder: false,
              isHasBottomBorder: false,
              // collapsedBorderColor: Theme.of(context).colorScheme.secondaryContainer,
              // expendedBorderColor: Theme.of(context).colorScheme.outline,
              backgroundColor: Theme.of(context)
                  .colorScheme
                  .secondaryContainer
                  .withOpacity(0.24),
              borderRadius: const BorderRadius.all(Radius.circular(10)),
              title: Text(name.tr),
              children: _children(name),
            ))
        .toList();
  }

  List<Widget> _children(String groupName) {
    ArgsController controller = Get.find();
    GroupsModel groupsModel = controller.groupsData.value[groupName]!;
    List<Widget> result = [const Divider()];
    for (int i = 0; i < groupsModel.members.length; i++) {
      result.add(ArgumentView(
        setArgument: controller.setArgument,
        getGroupName: groupsModel.getGroupName,
        index: i,
      ));
    }
    return result;
  }
}

class ArgumentView extends StatefulWidget {
  final void Function(String? config, String? task, String? group,
      String argument, String type, dynamic value) setArgument;
  final String Function() getGroupName;
  final int index;

  const ArgumentView(
      {required this.setArgument,
      required this.getGroupName,
      required this.index,
      Key? key})
      : super(key: key);

  @override
  // ignore: library_private_types_in_public_api
  _ArgumentViewState createState() => _ArgumentViewState();
}

class _ArgumentViewState extends State<ArgumentView> {
  Timer? timer;
  bool landscape = true;

  ArgumentModel get model {
    ArgsController controller = Get.find();
    GroupsModel? groupsModel =
        controller.groupsData.value[widget.getGroupName()];
    return groupsModel!.members[widget.index];
  }

  @override
  Widget build(BuildContext context) {
    landscape = MediaQuery.of(context).orientation == Orientation.landscape;
    if (landscape) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _title(),
          ),
          _form(),
        ],
      ).padding(bottom: 8);
    } else {
      return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [_title(), _form()]).padding(bottom: 8);
    }
    // return LayoutBuilder(builder: (context, constraints) {
    //   if (constraints.maxWidth >= 350) {
    //     return Row(
    //       crossAxisAlignment: CrossAxisAlignment.start,
    //       children: [
    //         Expanded(
    //           child: _title(),
    //         ),

    //         // const Spacer(),
    //         _form(),
    //       ],
    //     );
    //   } else {
    //     return Column(
    //         crossAxisAlignment: CrossAxisAlignment.start,
    //         children: [_title(), _form()]);
    //   }
    // });
  }

  /// 翻译一个 key，**未命中就记录下来**（缺口可见）。
  ///
  /// ★ 不直接用 `.tr`: GetX 的 `.tr` 查不到时**原样返回 key**，
  ///   于是 `charge_enable_help` 赤裸裸显示在界面上却**没有任何报错** ——
  ///   这种静默降级让 113 个缺失 key 长期无人发现。
  String _t(String key) {
    if (key.isEmpty) return key;
    try {
      if (Get.isRegistered<LocaleService>()) {
        return Get.find<LocaleService>().trOrRecord(key);
      }
    } catch (_) {
      // 服务未就绪 -> 退回 GetX 默认行为
    }
    return key.tr;
  }

  Widget _title() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SelectableText(
        _t(model.title),
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      if (model.description != null && model.description!.isNotEmpty)
        SelectableText(
          _t(model.description!),
          style: Theme.of(context).textTheme.bodySmall,
        ),
    ]);
  }

  Widget _form() {
    // ★★ S4: `windows` 用**专用编辑器** ★★
    //
    // 它是 `List[TaskWindow]`, 后端 `/args` 里 `type = "array"` ——
    // 原生的 `"string"` 分支只会 `List.toString()` 出一堆垃圾, 用户根本改不了。
    //
    // 用户裁定: "不是 window slots, 而是**设置多个 window**！"
    if (model.name == 'windows') {
      final script = Get.find<NavCtrl>().selectedScript.value;
      final task = Get.find<NavCtrl>().selectedMenu.value;
      return WindowEditor(
        scriptName: script,
        task: task,
        initial: (model.value as List?) ?? const [],
      );
    }
    return switch (model.type) {
      "boolean" => Checkbox(value: model.value, onChanged: onCheckboxChanged)
          .alignment(Alignment.centerLeft)
          .constrained(width: landscape ? 200 : null),
      "string" => TextFormField(
          initialValue: model.value.toString(),
          onChanged: (value) {
            timer?.cancel();
            timer = Timer(const Duration(milliseconds: 1000),
                () => onStringChanged(value));
          }).constrained(width: landscape ? 200 : null),
      "multi_line" => TextFormField(
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          maxLines: null,
          initialValue: model.value.toString(),
          onChanged: (value) {
            timer?.cancel();
            timer = Timer(const Duration(milliseconds: 1000),
                () => onStringChanged(value));
          }).constrained(width: landscape ? 200 : null),
      "number" => TextFormField(
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp('[-0-9.]')),
          ],
          initialValue: model.value.toString(),
          onChanged: (value) {
            timer?.cancel();
            timer = Timer(const Duration(milliseconds: 1000),
                () => onNumberChanged(value));
          }).constrained(width: landscape ? 200 : null),
      "integer" => TextFormField(
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp('[-0-9]')),
          ],
          initialValue: model.value.toString(),
          onChanged: (value) {
            timer?.cancel();
            timer = Timer(const Duration(milliseconds: 1000),
                () => onIntegerChanged(value));
          }).constrained(width: landscape ? 200 : null),
      "enum" => DropdownButton<String>(
          isExpanded: !landscape,
          value: model.value.toString(),
          items: model.enumEnum!
              .map<DropdownMenuItem<String>>((e) => DropdownMenuItem(
                  value: e.toString(),
                  child: Text(
                    _t(e.toString()),
                    style: Theme.of(context).textTheme.bodyLarge,
                  ).constrained(width: landscape ? 177 : null)))
              .toList(),
          onChanged: onEnumChanged,
        ),
      "date_time" => DateTimePicker(
          value: model.value,
          onChange: onDateTimeChanged,
        ).constrained(width: landscape ? 200 : null),
      "time_delta" => TimeDeltaPicker(
          value: ensureTimeDeltaString(model.value),
          onChange: onTimeDeltaChanged,
        ).constrained(width: landscape ? 200 : null),
      "time" => TimePicker(
          value: model.value,
          onChange: onTimeChanged,
        ).constrained(width: landscape ? 200 : null),
      _ =>
        Text(model.value.toString()).constrained(width: landscape ? 200 : null)
    };
  }

  void onCheckboxChanged(bool? value) {
    setState(() {
      widget.setArgument(
          "", "", widget.getGroupName(), model.title, 'boolean', value);
      model.value = value;
    });
    showSnakbar(value);
  }

  void onStringChanged(String? value) {
    widget.setArgument(
        "", "", widget.getGroupName(), model.title, 'string', value);
    showSnakbar(value);
  }

  void onNumberChanged(String? value) {
    widget.setArgument(
        "", "", widget.getGroupName(), model.title, 'number', value);
    showSnakbar(value);
  }

  void onIntegerChanged(String? value) {
    widget.setArgument(
        "", "", widget.getGroupName(), model.title, 'integer', value);
    showSnakbar(value);
  }

  void onEnumChanged(String? value) {
    setState(() {
      model.value = value;
      widget.setArgument(
          "", "", widget.getGroupName(), model.title, 'enum', value);
    });
    showSnakbar(value);
  }

  void onDateTimeChanged(String? value) {
    setState(() {
      model.value = value;
      widget.setArgument(
          "", "", widget.getGroupName(), model.title, 'date_time', value);
    });
    showSnakbar(value);
  }

  void onTimeDeltaChanged(String? value) {
    setState(() {
      model.value = value;
      widget.setArgument(
          "", "", widget.getGroupName(), model.title, 'time_delta', value);
    });
    showSnakbar(value);
  }

  void onTimeChanged(String? value) {
    setState(() {
      model.value = value;
      widget.setArgument(
          "", "", widget.getGroupName(), model.title, 'time', value);
    });
    showSnakbar(value);
  }

// -----------------------------------------------------------------------------
  void showSnakbar(dynamic value) {
    Get.snackbar(I18n.setting_saved.tr, "$value",
        duration: const Duration(seconds: 1), snackPosition: SnackPosition.BOTTOM);
  }
}
