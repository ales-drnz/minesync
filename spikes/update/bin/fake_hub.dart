// Uso: dart run bin/fake_hub.dart --dir <cartella> [--port 8787]
import 'dart:io';

import 'package:spike_update/src/fake_hub.dart';

Future<void> main(List<String> args) async {
  String arg(String k, String d) {
    final i = args.indexOf(k);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : d;
  }

  final s = await startFakeHub(arg('--dir', '.'), port: int.parse(arg('--port', '8787')), log: print);
  stdout.writeln('HUB http://${s.address.address}:${s.port}/');
}
