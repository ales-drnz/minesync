// Finta app MineSync: avvia il guard con stdin/stdout in pipe, legge il
// protocollo JSON lines e scrive lo stato in file sotto --state, così il
// driver dei test (scenarios.dart) può ucciderla e controllare cosa resta.
//
// Comandi dal driver (stdin dell'app):
//   stop        arresto normale: {"t":"stop"} al guard, attesa dell'uscita
//   abrupt      exit(0) immediato senza avvisare il guard (→ EOF)
//   closestdin  chiude lo stdin del guard restando viva
//   burst N R   inoltra "burst N R" alla console del server
//
// --fallback: se il guard muore senza evento "exit", l'app (ancora viva)
// manda SIGTERM e poi SIGKILL al process group del guard (solo POSIX).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:guard_spike/src/posix.dart' as px;

late String state;
bool exitSeen = false;

Future<void> main(List<String> a) async {
  String? guardExe;
  var fallback = false;
  var fallbackGrace = 10;
  final guardArgs = <String>[];
  var server = <String>[];
  for (var i = 0; i < a.length; i++) {
    switch (a[i]) {
      case '--guard':
        guardExe = a[++i];
      case '--state':
        state = a[++i];
      case '--fallback':
        fallback = true;
      case '--fallback-grace':
        fallbackGrace = int.parse(a[++i]);
      case '--guard-arg':
        guardArgs.add(a[++i]);
      case '--':
        server = a.sublist(i + 1);
        i = a.length;
    }
  }
  File('$state/app.pid').writeAsStringSync('$pid');
  final log = File('$state/app_console.log').openWrite();

  final g = await Process.start(
      guardExe!, [...guardArgs, '--parent-pid', '$pid', '--', ...server]);
  File('$state/guard.pid').writeAsStringSync('${g.pid}');
  g.stdin.done.then((_) {}, onError: (_) {});
  g.stderr.listen((d) => log.add(d));

  final burst = _Burst();
  g.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .listen((line) {
    final now = DateTime.now().microsecondsSinceEpoch;
    Map<String, Object?> m;
    try {
      m = (jsonDecode(line) as Map).cast<String, Object?>();
    } catch (_) {
      log.writeln('NON-JSON: $line');
      return;
    }
    switch (m['t']) {
      case 'started':
        File('$state/child.pid').writeAsStringSync('${m['pid']}');
        File('$state/contain.json').writeAsStringSync(jsonEncode(m['contain']));
        log.writeln(line);
      case 'o' || 'e':
        final l = m['l'] as String;
        if (l.startsWith('BURST ')) {
          burst.add(l, now);
          return; // non si logga ogni riga della raffica
        }
        log.writeln(line);
        if (l.startsWith('BURST-END ')) {
          burst.finish(l, now);
        } else if (l.contains('Done (')) {
          File('$state/ready').writeAsStringSync('$now');
        }
      case 'exit':
        exitSeen = true;
        File('$state/guard_exit.json').writeAsStringSync(line);
        log.writeln(line);
      default:
        log.writeln(line);
    }
  });

  g.exitCode.then((code) async {
    await log.flush();
    if (!exitSeen && fallback && !Platform.isWindows) {
      // il guard è morto male: l'app ferma il gruppo (che sopravvive al suo
      // leader). SIGTERM = shutdown hook della JVM, cioè salvataggio.
      File('$state/fallback').writeAsStringSync('guard exit $code');
      px.kill(-g.pid, px.sigterm);
      await Future<void>.delayed(Duration(seconds: fallbackGrace));
      px.kill(-g.pid, px.sigkill);
    }
    File('$state/guard_gone').writeAsStringSync('$code');
  });

  stdin
      .transform(const Utf8Decoder())
      .transform(const LineSplitter())
      .listen((cmd) async {
    if (cmd == 'stop') {
      g.stdin.writeln(jsonEncode({'t': 'stop'}));
      await g.exitCode;
      await log.close();
      exit(0);
    } else if (cmd == 'abrupt') {
      exit(0);
    } else if (cmd == 'closestdin') {
      await g.stdin.close();
    } else if (cmd.startsWith('burst ')) {
      burst.reset();
      g.stdin.writeln(jsonEncode({'t': 'cmd', 'l': cmd}));
    }
  });
}

class _Burst {
  int count = 0, next = 0, gaps = 0, dup = 0;
  int firstRecv = 0;
  final lat = <int>[];
  void reset() {
    count = next = gaps = dup = firstRecv = 0;
    lat.clear();
  }

  void add(String l, int now) {
    final f = l.split(' ');
    final seq = int.parse(f[1]);
    final ts = int.parse(f[2]);
    if (count == 0) firstRecv = now;
    count++;
    if (seq == next) {
      next++;
    } else if (seq > next) {
      gaps += seq - next;
      next = seq + 1;
    } else {
      dup++;
    }
    lat.add(now - ts);
  }

  void finish(String endLine, int now) {
    final f = endLine.split(' ');
    final n = int.parse(f[1]);
    lat.sort();
    int pct(double p) => lat.isEmpty ? 0 : lat[((lat.length - 1) * p).round()];
    final res = {
      'expected': n,
      'received': count,
      'lost': n - (count - dup),
      'gaps': gaps,
      'dup': dup,
      'outOfOrder': next != n,
      'serverEmitMs': int.parse(f[2]),
      'recvSpanMs': (now - firstRecv) ~/ 1000,
      'latencyUs': {
        'p50': pct(0.5),
        'p99': pct(0.99),
        'max': lat.isEmpty ? 0 : lat.last
      },
    };
    File('$state/burst.json').writeAsStringSync(jsonEncode(res));
  }
}
