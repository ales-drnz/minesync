// Launcher di MineSync: compilato AOT come `minesync-launcher` (Linux),
// `MineSync.exe` (Windows) o `MineSync` dentro MineSync.app (macOS).
// Vedi lib/src/launcher.dart e lib/src/layout.dart.
import 'dart:io';

import 'package:minesync_launcher/minesync_launcher.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--selftest')) {
    stdout.writeln(selftestLine);
    exit(0);
  }
  final env = Platform.environment;
  final layout = LauncherLayout.detect(env, Platform.resolvedExecutable);
  final timeout = int.tryParse(env['MINESYNC_HEALTH_TIMEOUT_S'] ?? '') ?? 60;
  final l = Launcher(layout, healthTimeout: Duration(seconds: timeout));
  exit(await l.run(args));
}
