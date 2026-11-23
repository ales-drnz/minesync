// Scenari con processi veri: GuardClient → guard (compilato) → script di
// avvio → finto server (→ nipote). Ogni scenario controlla che alla fine non
// resti nessun processo con la sua cartella di stato nella riga di comando.
@Tags(['scenario'])
library;

import 'dart:async';
import 'dart:io';

import 'package:minesync_guard/minesync_guard.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

late Binaries bin;
late Directory work;

void main() {
  setUpAll(() async {
    bin = await Binaries.build();
    work = Directory.systemTemp.createTempSync('ms_guard_work');
  });

  tearDownAll(() {
    bin.dispose();
    try {
      work.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows: file ancora aperti per un attimo
    }
  });

  Scenario scenario(String name) {
    final s = Scenario(work, name);
    addTearDown(s.cleanup);
    return s;
  }

  /// Avvia il finto server sotto il guard; le righe dello stderr arrivano
  /// nel log con il prefisso "ERR:".
  Future<(GuardClient, LineLog)> startServer(
    Scenario s, {
    List<String> serverArgs = const [],
    bool script = false,
    Duration grace = const Duration(seconds: 60),
  }) async {
    final args = ['--state', s.path, '--stop-ms', '400', ...serverArgs];
    final (exe, a) = script ? bin.viaScript(args) : (bin.fakeServer, args);
    final c = await GuardClient.start(
      guard: [bin.guard],
      executable: exe,
      args: a,
      workDir: s.path,
      grace: grace,
      logPath: s.file('guard.log'),
    );
    addTearDown(() async {
      if (c.running) await c.kill();
    });
    final log = LineLog();
    c.lines.listen((l) => log.add(l.stderr ? 'ERR:${l.text}' : l.text), onDone: log.close);
    return (c, log);
  }

  test('comandi e risposte sulla console (B-SESSION-19)', () async {
    final s = scenario('roundtrip');
    final (c, log) = await startServer(s);
    await log.waitFor('Done (');
    expect(c.running, isTrue);
    expect(c.serverPid, s.pidOf('server'));

    await c.send('list');
    await log.waitFor('There are 0 of a max of 20 players online: ');
    await c.send('fake:join Steve');
    await c.send('list');
    await log.waitFor('There are 1 of a max of 20 players online: Steve');
    await c.send('save-off');
    await log.waitFor('Automatic saving is now disabled');
    await c.send('save-all flush');
    await log.waitFor('Saved the game');
    await c.send('save-on');
    await log.waitFor('Automatic saving is now enabled');
    await c.send('fake:stderr attenzione');
    await log.waitFor('ERR:attenzione');
    await c.send('boh');
    await log.waitFor('Unknown or incomplete command');
    expect(() => c.send('a\nb'), throwsArgumentError);

    await c.stop();
    final e = await c.exit;
    expect(e.reason, GuardExit.stopped);
    expect(e.exitCode, 0);
    expect(c.running, isFalse);
    await log.done.future.timeout(const Duration(seconds: 5));
    await expectLater(c.send('list'), throwsA(isA<NotRunning>()));
  });

  test('arresto pulito: stop sulla console, poi albero vuoto', () async {
    final s = scenario('clean-stop');
    final (c, log) = await startServer(s, script: true, serverArgs: ['--grandchild']);
    await log.waitFor('Done (');
    expect(await s.waitFile('grandchild.pid'), isTrue);

    await c.stop();
    final e = await c.exit;
    expect(e.reason, GuardExit.stopped);
    expect(e.trigger, 'app');
    expect(e.forced, isFalse);
    expect(s.read('saved'), 'console');
    expect(log.lines, contains(endsWith('All dimensions are saved')));
    // il guard dichiara la fine solo ad albero vuoto
    expect(await s.leftovers(), isEmpty);
  });

  test('lo stop funziona anche se il server ignora SIGTERM (B-SESSION-20)', () async {
    final s = scenario('ignore-sigterm');
    final (c, log) = await startServer(s, script: true, serverArgs: ['--ignore-sigterm']);
    await log.waitFor('Done (');
    await c.stop();
    final e = await c.exit;
    expect(e.reason, GuardExit.stopped);
    expect(e.forced, isFalse);
    expect(s.read('saved'), 'console');
    expect(await s.leftovers(), isEmpty);
  });

  test('server che ignora stop: kill dell\'albero dopo la grazia', () async {
    final s = scenario('grace-kill');
    // su macOS non c'è il subreaper: un nipote staccato con setsid sfugge,
    // quindi lì resta nel gruppo
    final (c, log) = await startServer(
      s,
      script: true,
      grace: const Duration(seconds: 1),
      serverArgs: ['--ignore-stop', Platform.isMacOS ? '--grandchild' : '--grandchild-detached'],
    );
    await log.waitFor('Done (');
    expect(await s.waitFile('grandchild.pid'), isTrue);
    final sw = Stopwatch()..start();
    await c.stop();
    final e = await c.exit;
    expect(e.reason, GuardExit.killed);
    expect(e.forced, isTrue);
    expect(sw.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 900)));
    expect(sw.elapsed, lessThan(const Duration(seconds: 15)));
    expect(s.has('saved'), isFalse);
    expect(await s.waitNoLeftovers(), isEmpty);
  });

  test('kill immediato dell\'albero', () async {
    final s = scenario('kill');
    final (c, log) = await startServer(s, script: true, serverArgs: ['--grandchild']);
    await log.waitFor('Done (');
    expect(await s.waitFile('grandchild.pid'), isTrue);
    final sw = Stopwatch()..start();
    await c.kill();
    final e = await c.exit;
    expect(e.reason, GuardExit.killed);
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    expect(s.has('saved'), isFalse);
    expect(await s.waitNoLeftovers(), isEmpty);
  });

  test('crash del server: exit code, poi NotRunning (B-SESSION-18)', () async {
    final s = scenario('crash');
    final (c, log) = await startServer(s);
    await log.waitFor('Done (');
    await c.send('fake:crash 3');
    final e = await c.exit;
    expect(e.reason, GuardExit.exited);
    expect(e.exitCode, 3);
    expect(log.lines, contains('ERR:java.lang.IllegalStateException: fake crash'));
    expect(c.running, isFalse);
    await expectLater(c.send('list'), throwsA(isA<NotRunning>()));
    expect(await s.leftovers(), isEmpty);
  });

  test('console che non legge: send va in timeout (B-SESSION-18)', () async {
    final s = scenario('send-timeout');
    final (c, log) = await startServer(s);
    await log.waitFor('Done (');
    await c.send('fake:freeze');
    // righe grosse finché il pipe verso il server non si riempie
    final big = 'say ${'x' * 16000}';
    Object? err;
    for (var i = 0; i < 400 && err == null; i++) {
      try {
        await c.send(big, timeout: const Duration(milliseconds: 500));
      } on Object catch (e) {
        err = e;
      }
    }
    expect(err, isA<SendTimeout>());
    expect(err, isA<TimeoutException>());
    // quel che arriva dopo scade anch'esso, senza bloccare
    await expectLater(
      c.send('list', timeout: const Duration(milliseconds: 300)),
      throwsA(isA<SendTimeout>()),
    );
    expect(c.running, isTrue);
    await c.kill();
    expect((await c.exit).reason, GuardExit.killed);
    await expectLater(c.send('list'), throwsA(isA<NotRunning>()));
  });

  test('raffica di righe: nessuna persa, in ordine', () async {
    final s = scenario('burst');
    final (c, log) = await startServer(s);
    await log.waitFor('Done (');
    const n = 50000;
    await c.send('fake:burst $n 0');
    await log.waitFor('BURST-END', const Duration(seconds: 60));
    expect(_burstSeq(log.lines), List.generate(n, (i) => i));
    await c.stop();
    expect((await c.exit).reason, GuardExit.stopped);
  });

  test('listener in pausa: le righe aspettano e non si perdono', () async {
    final s = scenario('paused');
    final c = await GuardClient.start(
      guard: [bin.guard],
      executable: bin.fakeServer,
      args: ['--state', s.path, '--stop-ms', '100'],
      workDir: s.path,
    );
    addTearDown(() async {
      if (c.running) await c.kill();
    });
    final diag = <String>[];
    c.diagnostics.listen(diag.add);
    final got = <String>[];
    final ready = Completer<void>();
    final end = Completer<void>();
    final sub = c.lines.listen((l) {
      got.add(l.text);
      if (l.text.contains('Done (') && !ready.isCompleted) ready.complete();
      if (l.text.startsWith('BURST-END')) end.complete();
    });
    await ready.future.timeout(const Duration(seconds: 20));
    sub.pause();
    // oltre GuardClient.maxBufferedLines: il client smette di leggere dal
    // guard, il guard accumula e poi frena il server
    const n = 150000;
    await c.send('fake:burst $n 0');
    await Future<void>.delayed(const Duration(seconds: 3));
    final whilePaused = got.length;
    expect(got.where((l) => l.startsWith('BURST ')), isEmpty);
    sub.resume();
    await end.future.timeout(const Duration(seconds: 30));
    expect(got.length, greaterThan(whilePaused));
    expect(_burstSeq(got), List.generate(n, (i) => i));
    expect(diag, contains(contains('lettura dal guard sospesa')));
    await c.stop();
  });

  test('guard ucciso: fallback dell\'app (POSIX) o job object (Windows)', () async {
    final s = scenario('guard-killed');
    final (c, log) = await startServer(s, script: true, serverArgs: ['--grandchild']);
    await log.waitFor('Done (');
    expect(await s.waitFile('grandchild.pid'), isTrue);
    await killHard(c.guardPid);
    final e = await c.exit.timeout(const Duration(seconds: 30));
    expect(e.reason, GuardExit.guardDied);
    if (!Platform.isWindows) {
      // SIGTERM al gruppo = shutdown hook della JVM, cioè salvataggio
      expect(s.read('saved'), 'sigterm');
    }
    expect(await s.waitNoLeftovers(), isEmpty);
  });

  test('avvio impossibile: GuardStartFailed', () async {
    final s = scenario('start-failed');
    await expectLater(
      GuardClient.start(
        guard: [bin.guard],
        executable: s.file('non-esiste'),
        args: const [],
        workDir: s.path,
      ),
      throwsA(isA<GuardStartFailed>()),
    );
    await expectLater(
      GuardClient.start(
        guard: [s.file('guard-non-esiste')],
        executable: bin.fakeServer,
        args: const [],
        workDir: s.path,
      ),
      throwsA(isA<GuardStartFailed>()),
    );
  });

  test('SIGHUP ignorato, SIGTERM al guard = arresto pulito', testOn: '!windows', () async {
    final s = scenario('signals');
    final (c, log) = await startServer(s);
    await log.waitFor('Done (');
    Process.killPid(c.guardPid, ProcessSignal.sighup);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await c.send('list');
    await log.waitFor('There are 0');
    expect(c.running, isTrue);
    Process.killPid(c.guardPid, ProcessSignal.sigterm);
    final e = await c.exit;
    expect(e.reason, GuardExit.stopped);
    expect(e.trigger, 'sigterm');
    expect(s.read('saved'), 'console');
  });

  // L'app muore senza fermare il server: kill -9 (taskkill /F su Windows) o
  // exit improvvisa. Ogni via di rilevamento è provata anche da sola.
  final variants = <(String, List<String>, String?, bool)>[
    ('tutte le vie', [], null, true),
    ('exit senza stop', [], null, false),
    ('solo EOF dello stdin', ['--no-parent-watch', '--no-pdeathsig'], 'stdin-eof', true),
    ('solo controllo del genitore', ['--no-stdin-eof', '--no-pdeathsig'], 'parent-dead', true),
    if (Platform.isLinux)
      ('solo PDEATHSIG', ['--no-stdin-eof', '--no-parent-watch'], 'pdeathsig', true),
  ];
  for (final (name, guardArgs, trigger, hardKill) in variants) {
    test('app uccisa ($name): stop pulito, nessun orfano', () async {
      final s = scenario('host-${name.replaceAll(' ', '-')}');
      final (exe, args) = bin.viaScript(['--state', s.path, '--stop-ms', '400', '--grandchild']);
      final host = await Process.start(bin.host, [
        '--guard',
        bin.guard,
        '--state',
        s.path,
        for (final g in guardArgs) ...['--guard-arg', g],
        '--log',
        s.file('guard.log'),
        '--',
        exe,
        ...args,
      ]);
      unawaited(host.stdout.drain<void>());
      unawaited(host.stderr.drain<void>());
      expect(await s.waitFile('ready'), isTrue, reason: 'albero non partito');
      expect(await s.waitFile('grandchild.pid'), isTrue);

      if (hardKill) {
        await killHard(host.pid);
      } else {
        host.stdin.writeln('quit');
      }
      await host.exitCode;
      expect(await s.waitFile('saved'), isTrue, reason: 'arresto non pulito');
      expect(s.read('saved'), 'console');
      expect(await s.waitNoLeftovers(), isEmpty);
      // dopo la morte dell'app la console del guard finisce nel --log
      final glog = File(s.file('guard.log')).readAsStringSync();
      expect(glog, contains('"t":"exit"'));
      expect(glog, contains('"reason":"stopped"'));
      if (trigger != null) expect(glog, contains('"trigger":"$trigger"'));
    });
  }
}

/// Numeri di sequenza delle righe `BURST <seq> <µs>`.
List<int> _burstSeq(List<String> lines) => [
  for (final l in lines)
    if (l.startsWith('BURST ')) int.parse(l.split(' ')[1]),
];
