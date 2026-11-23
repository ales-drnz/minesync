import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:ms_core/ms_core.dart';

import 'src/app.dart';
import 'src/platform/desktop_platform.dart';
import 'src/platform/desktop_window.dart';
import 'src/platform/single_instance.dart';
import 'src/state/app_state.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final dir = configDir(env);

  // Una sola istanza: la seconda chiede alla prima di mostrarsi ed esce.
  final role = await SingleInstance.acquire(dir);
  if (role is SecondaryInstance) {
    if (!role.signaled) stderr.writeln('MineSync è già in esecuzione ma non risponde');
    exit(0);
  }

  final desktop = await DesktopPlatform.create(
    env: env,
    args: args,
    instance: role as PrimaryInstance,
  );
  final state = AppState(AppDeps(configDir: dir, platform: desktop.services, env: env));
  await desktop.attach(state);
  runApp(resizableFrame(MinesyncApp(state: state, platform: desktop.services)));
  unawaited(desktop.afterFirstFrame());
  await state.start();
}
