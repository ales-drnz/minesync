// Finto server Minecraft per i test del guard.
//
// - stampa righe di avvio e "Done (x s)! For help, type "help""
// - "stop" (o SIGTERM/SIGINT, come lo shutdown hook della JVM) → "Saving...",
//   attesa di 2 s, scrive <state>/saved, uccide il nipote ed esce 0
// - stdin in EOF: IGNORATO, come il server vanilla (la console smette di
//   leggere ma il server resta su): per questo serve il guard
// - "burst N R": N righe "BURST <seq> <µs>" a R righe/s (R=0: a tutta velocità)
// - genera un processo nipote (sé stesso con --helper) che dorme per sempre
//
// Opzioni: --state DIR  --hang (ignora stop/SIGTERM)  --helper-detached
//          --no-helper  --helper (modalità nipote)
import 'dart:async';
import 'dart:convert';
import 'dart:io';

late String state;
bool hang = false;
int? helperPid;
bool stopping = false;

// Come la JVM (PrintStream ignora gli errori di scrittura), il finto server
// non deve morire se la sua console si rompe (EPIPE dopo la morte del guard).
void main(List<String> a) {
  runZonedGuarded(() => realMain(a), (e, st) {});
}

Future<void> realMain(List<String> a) async {
  stdout.done.then((_) {}, onError: (_) {});
  stderr.done.then((_) {}, onError: (_) {});
  var detached = false, helper = false, noHelper = false;
  for (var i = 0; i < a.length; i++) {
    switch (a[i]) {
      case '--state':
        state = a[++i];
      case '--hang':
        hang = true;
      case '--helper-detached':
        detached = true;
      case '--helper':
        helper = true;
      case '--no-helper':
        noHelper = true;
    }
  }
  if (helper) {
    File('$state/helper.pid').writeAsStringSync('$pid');
    // il nipote "testardo": nessuna reazione a niente, dorme e basta
    Timer.periodic(const Duration(hours: 1), (_) {});
    return;
  }
  File('$state/server.pid').writeAsStringSync('$pid');
  final t0 = DateTime.now();

  out('[Server thread/INFO]: Starting minecraft server version 1.21.4');
  out('[Server thread/INFO]: Loading properties');
  out('[Server thread/INFO]: Preparing level "world"');

  if (!noHelper) {
    final args = ['--helper', '--state', state];
    if (detached) {
      // setsid + doppio fork: esce dal process group del guard
      final p = await Process.start(Platform.resolvedExecutable, args,
          mode: ProcessStartMode.detached);
      helperPid = p.pid;
    } else {
      final p = await Process.start(Platform.resolvedExecutable, args);
      helperPid = p.pid;
      p.stdout.drain<void>();
      p.stderr.drain<void>();
    }
  }

  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) => doStop('sigterm'));
    ProcessSignal.sigint.watch().listen((_) => doStop('sigint'));
  }

  final secs = DateTime.now().difference(t0).inMilliseconds / 1000;
  out('[Server thread/INFO]: Done (${secs.toStringAsFixed(3)}s)! For help, type "help"');

  stdin
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .listen((l) {
    final cmd = l.trim();
    if (cmd == 'stop') {
      doStop('console');
    } else if (cmd.startsWith('burst ')) {
      final f = cmd.split(' ');
      burst(int.parse(f[1]), int.parse(f[2]));
    } else if (cmd.startsWith('say ')) {
      out('[Server thread/INFO]: [Server] ${cmd.substring(4)}');
    } else {
      out('[Server thread/INFO]: Unknown or incomplete command: $cmd');
    }
  }, onDone: () {
    // come vanilla: nessuna reazione all'EOF della console
    File('$state/stdin_eof').writeAsStringSync('${DateTime.now()}');
  });
}

void out(String l) {
  try {
    stdout.writeln(l);
  } catch (_) {}
}

Future<void> doStop(String why) async {
  if (hang) {
    out('[Server thread/WARN]: ($why) ignoro lo stop (modalità --hang)');
    return;
  }
  if (stopping) return;
  stopping = true;
  out('[Server thread/INFO]: Stopping the server');
  out('[Server thread/INFO]: Saving players');
  out('[Server thread/INFO]: Saving worlds');
  await Future<void>.delayed(const Duration(seconds: 2));
  File('$state/saved').writeAsStringSync(why);
  if (helperPid != null) Process.killPid(helperPid!, ProcessSignal.sigkill);
  out('[Server thread/INFO]: ThreadedAnvilChunkStorage: All dimensions are saved');
  try {
    await stdout.flush().timeout(const Duration(seconds: 2));
  } catch (_) {}
  exit(0);
}

Future<void> burst(int n, int rate) async {
  final sw = Stopwatch()..start();
  var i = 0;
  if (rate <= 0) {
    while (i < n) {
      final sb = StringBuffer();
      for (var k = 0; k < 1000 && i < n; k++, i++) {
        sb.writeln('BURST $i ${DateTime.now().microsecondsSinceEpoch}');
      }
      stdout.write(sb);
      await Future<void>.delayed(Duration.zero);
    }
  } else {
    // a passi di 2 ms: si emette quanto dovuto fino a quell'istante
    while (i < n) {
      final due = (sw.elapsedMicroseconds * rate / 1e6).floor().clamp(0, n);
      if (due > i) {
        final sb = StringBuffer();
        for (; i < due; i++) {
          sb.writeln('BURST $i ${DateTime.now().microsecondsSinceEpoch}');
        }
        stdout.write(sb);
      }
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }
  out('BURST-END $n ${sw.elapsedMilliseconds}');
}
