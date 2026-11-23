import 'dart:io';

import 'package:minesync_cli/minesync_cli.dart';

Future<void> main(List<String> args) async {
  final code = await runCli(args);
  await stdout.flush();
  await stderr.flush();
  exit(code);
}
