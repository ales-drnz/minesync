// Finta app per i test: avvia il server con GuardClient e scrive lo stato in
// file sotto --state, così il test può ucciderla e vedere cosa resta.
//
// uso: host --guard EXE --state DIR [--guard-arg X]... [--grace S]
//           [--log FILE] -- eseguibile argomenti...
// File: host.pid, guard.pid, child.pid, ready (riga "Done" vista),
// host_console.log, exit.txt (GuardExit quando arriva).
// Comandi sullo stdin: "stop" (arresto pulito, poi exit 0), "quit" (exit 0
// immediato, senza dire niente al guard).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:minesync_guard/minesync_guard.dart';

Future<void> main(List<String> a) async {
  String? guard, state, log;
  final guardArgs = <String>[];
  var grace = const Duration(seconds: 60);
  var server = <String>[];
  for (var i = 0; i < a.length; i++) {
    switch (a[i]) {
      case '--guard':
        guard = a[++i];
      case '--state':
        state = a[++i];
      case '--guard-arg':
        guardArgs.add(a[++i]);
      case '--grace':
        grace = Duration(milliseconds: (double.parse(a[++i]) * 1000).round());
      case '--log':
        log = a[++i];
      case '--':
        server = a.sublist(i + 1);
        i = a.length;
    }
  }
  final sep = Platform.pathSeparator;
  void put(String n, String v) => File('$state$sep$n').writeAsStringSync(v, flush: true);
  put('host.pid', '$pid');
  final console = File('$state${sep}host_console.log').openWrite();

  final c = await GuardClient.start(
    guard: [guard!, ...guardArgs],
    executable: server.first,
    args: server.sublist(1),
    workDir: state!,
    grace: grace,
    logPath: log,
  );
  put('guard.pid', '${c.guardPid}');
  put('child.pid', '${c.serverPid}');
  c.diagnostics.listen((d) => console.writeln('# $d'));
  c.lines.listen((l) {
    console.writeln(l.text);
    if (l.text.contains('Done (')) put('ready', '1');
  });
  unawaited(
    c.exit.then((e) async {
      put('exit.txt', '$e');
      await console.flush();
    }),
  );

  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((cmd) async {
    switch (cmd) {
      case 'stop':
        await c.stop();
        await console.close();
        exit(0);
      case 'quit':
        exit(0);
    }
  });
}
