library login;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';
import 'package:oasx/model/const/storage_key.dart';
import 'package:styled_widget/styled_widget.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';

import 'package:oasx/api/api_client.dart';
import 'package:oasx/views/layout/appbar.dart';
import 'package:oasx/utils/platform_utils.dart';
// 「双击启动」要**先拉起后端**再自动登录, 后端归 ServerController 管。
// SettingsController 只用来挡一层"环境没就绪" —— 它由 main.dart 的
// GetMaterialApp.onInit 提前注册, 见 login_controller.dart 的说明。
import 'package:oasx/controller/settings.dart';
import 'package:oasx/views/server/server_view.dart' show ServerController;

part './login_binding.dart';
part '../../controller/login/login_controller.dart';

class LoginView extends StatelessWidget {
  LoginView({Key? key}) : super(key: key);
  final _formKey = GlobalKey<FormBuilderState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildPlatformAppBar(context, isCollapsed: false),
      // 「服务器设置」按钮原来浮在这里(floatingActionButton), 现在跟着表单
      // 落在 Login 按钮下面 —— 见 _serverButton()。
      body: _login(context),
    );
  }

  Widget _login(BuildContext context) {
    List<double> maxWidthHigh = switch (Theme.of(context).platform) {
      TargetPlatform.windows => [400, 500],
      TargetPlatform.linux => [400, 500],
      TargetPlatform.macOS => [400, 500],
      _ => [],
    };
    return FormBuilder(
      key: _formKey,
      child: <Widget>[
        _admin(context),
        _address(),
        _username(),
        _password(),
        _signin(),
        _serverButton(),
      ].toColumn(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.center),
    )
        .padding(vertical: 10)
        // .card(
        //     elevation: 10,
        //     shape: RoundedRectangleBorder(
        //       borderRadius: BorderRadius.circular(20),
        //     ))
        .constrained(
            maxHeight: maxWidthHigh.isNotEmpty ? maxWidthHigh[0] : 500,
            maxWidth: maxWidthHigh.isNotEmpty ? maxWidthHigh[1] : 400)
        .alignment(Alignment.center);
  }

  Widget _admin(BuildContext context) {
    ThemeData theme = Theme.of(context);
    return Text(
      'Admin Login',
      textAlign: TextAlign.center,
      style: TextStyle(
          color: theme.colorScheme.primary,
          fontSize: 24,
          fontWeight: FontWeight.bold),
    ).padding(horizontal: 20);
  }

  Widget _username() {
    LoginController loginController = Get.find<LoginController>();
    return FormBuilderTextField(
      name: 'username',
      initialValue: loginController.username.value,
      decoration: const InputDecoration(labelText: 'Username'),
      // validator: FormBuilderValidators.compose([
      //   FormBuilderValidators.maxLength(1, errorText: "Account does not exist"),
      // ]),
    ).padding(horizontal: 20, top: 5);
  }

  Widget _password() {
    LoginController loginController = Get.find<LoginController>();
    return FormBuilderTextField(
      name: 'password',
      initialValue: loginController.password.value,
      decoration: const InputDecoration(labelText: 'Password'),
      obscureText: true,
      // validator: FormBuilderValidators.compose([
      //   FormBuilderValidators.maxLength(1, errorText: "Incorrect password"),
      // ]),
    ).padding(horizontal: 20, top: 20);
  }

  Widget _address() {
    LoginController loginController = Get.find<LoginController>();
    return FormBuilderTextField(
      name: 'address',
      initialValue: loginController.address.value,
      decoration: const InputDecoration(labelText: 'Address'),
      // validator: FormBuilderValidators.compose([
      //   FormBuilderValidators.required(),
      //   FormBuilderValidators.match(RegExp(r"\\d+.\\d+.\\d+.\\d+:\\d+"),
      //       errorText: "Format: [ip]:[port]"),
      // ]),
    ).padding(horizontal: 20, top: 20);
  }

  Widget _signin() {
    LoginController loginController = Get.find<LoginController>();
    return ElevatedButton(
      onPressed: () async => {
        if (_formKey.currentState?.saveAndValidate() ?? false)
          {await loginController.toMain(data: _formKey.currentState!.value)}
      },
      child: const Text('Login'),
    ).padding(horizontal: 20, top: 40);
  }

  /// 「服务器设置」入口 —— 原来是 Scaffold **右下角**的 FloatingActionButton。
  ///
  /// 移到 Login 按钮**下面**: 后端没起来时用户得先在这里配好 OAS 根目录,
  /// 它属于**启动流程**的一部分, 跟着表单走比浮在角落里更容易被发现。
  ///
  /// 只在 Windows 显示 —— `/server` 页(拉起本地 OAS 后端 / 改 deploy.yaml /
  /// 看启动日志)只对 Windows 上的本地后端有意义。
  Widget _serverButton() {
    if (!PlatformUtils.isWindows) {
      return const SizedBox.shrink();
    }
    // 外层 Column 是 CrossAxisAlignment.stretch, 所以它和 Login 按钮**同宽**。
    return OutlinedButton.icon(
      onPressed: () {
        Get.toNamed('/server');
      },
      icon: const Icon(Icons.developer_board_rounded),
      label: const Text('服务器设置'),
    ).padding(horizontal: 20, top: 12);
  }
}
