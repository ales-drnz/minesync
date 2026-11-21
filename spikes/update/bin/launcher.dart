// Launcher di MineSync (spike). Vedi lib/src/launcher.dart.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:spike_update/src/install.dart';
import 'package:spike_update/src/launcher.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--selftest')) {
    stdout.writeln('minesync-launcher build=$launcherBuild protocol=$launcherProtocol');
    exit(0);
  }
  final self = Platform.resolvedExecutable;
  // Linux portabile / Windows: la radice è la cartella del launcher.
  // (macOS: ~/Library/Application Support/MineSync, vedi README.)
  final root = Platform.environment['MINESYNC_ROOT_OVERRIDE'] ?? p.dirname(self);
  final timeout = int.tryParse(Platform.environment['MINESYNC_HEALTH_TIMEOUT_S'] ?? '') ?? 60;
  final l = Launcher(Install(root), self, healthTimeout: Duration(seconds: timeout));
  exit(await l.run(args));
}
