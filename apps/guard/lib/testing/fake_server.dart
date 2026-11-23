// Finto server Minecraft per i test: imita la console del server vanilla
// abbastanza da provare il guard e il motore della sessione senza Java.
// Si avvia con `bin/fake_minecraft.dart` (o compilato con dart compile exe).
//
// Le righe hanno il formato vanilla `[HH:mm:ss] [Server thread/INFO]: ...`.
// All'avvio stampa "Starting minecraft server version ...", "Preparing level
// "world"" e poi `Done (0.123s)! For help, type "help"`.
//
// Comandi della console (stdin):
//   stop            "Stopping the server", "Stopping server", "Saving players",
//                   "Saving worlds", attesa di --stop-ms, "...All chunks are
//                   saved", "ThreadedAnvilChunkStorage: All dimensions are
//                   saved", poi exit 0 (scrive <state>/saved con "console")
//   save-off        "Automatic saving is now disabled" (o "Saving is already
//                   turned off")
//   save-on         "Automatic saving is now enabled" (o "Saving is already
//                   turned on")
//   save-all [flush] "Saving the game (this may take a moment!)", attesa di
//                   --save-ms, "Saved the game"
//   list            "There are N of a max of M players online: a, b"
//   say MSG         "[Server] MSG"
//   altro           "Unknown or incomplete command, see below for error" e
//                   "<--[HERE]"
// Comandi di controllo per i test (non esistono nel vero server):
//   fake:join NOME / fake:leave NOME   "NOME joined the game" / "NOME left the game"
//   fake:burst N [R]  N righe "BURST <seq> <µs epoch>" a R righe/s (0 o
//                   assente: a tutta velocità), poi "BURST-END N <ms>"
//   fake:stderr MSG una riga sullo stderr
//   fake:crash [C]  stack trace finto sullo stderr ed exit C (default 1)
//   fake:freeze     smette per sempre di leggere lo stdin (console bloccata)
//
// Comportamento come vanilla: l'EOF dello stdin è ignorato (scrive
// <state>/stdin-eof); SIGTERM e SIGINT (POSIX) fanno lo stesso arresto di
// "stop", come lo shutdown hook della JVM (in <state>/saved: "sigterm").
// Un errore di scrittura sulla console (EPIPE) non lo fa morire.
//
// Opzioni:
//   --state DIR            file di stato: server.pid, grandchild.pid, saved,
//                          stdin-eof (scritti in modo atomico)
//   --grandchild           avvia un nipote che dorme per sempre e viene
//                          ucciso a fine arresto
//   --grandchild-detached  idem, ma staccato (setsid: esce dal process group)
//   --ignore-stop          ignora "stop", SIGTERM e SIGINT (server bloccato)
//   --ignore-sigterm       ignora solo SIGTERM e SIGINT
//   --crash-on CMD         quel comando fa come fake:crash
//   --stop-ms N            durata del salvataggio finale (default 1000)
//   --save-ms N            durata di save-all (default 100)
//   --startup-ms N         attesa prima di "Done" (default 0)
//   --players a,b          giocatori già connessi
//   --max-players N        default 20
//   --mc-version V         default 1.21.4
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Avvia il finto server con le opzioni [args] (vedi l'intestazione).
void runFakeServer(List<String> args) {
  runZonedGuarded(() => unawaited(_FakeServer(_Opts.parse(args)).run()), (e, _) {
    // come la JVM (PrintStream ignora gli errori di scrittura): mai morire
    // per la console rotta
  });
}

final class _Opts {
  String? state;
  bool grandchild = false;
  bool grandchildDetached = false;
  bool grandchildMode = false;
  bool ignoreStop = false;
  bool ignoreSigterm = false;
  String? crashOn;
  int stopMs = 1000;
  int saveMs = 100;
  int startupMs = 0;
  List<String> players = [];
  int maxPlayers = 20;
  String version = '1.21.4';

  static _Opts parse(List<String> a) {
    final o = _Opts();
    for (var i = 0; i < a.length; i++) {
      switch (a[i]) {
        case '--state':
          o.state = a[++i];
        case '--grandchild':
          o.grandchild = true;
        case '--grandchild-detached':
          o.grandchild = true;
          o.grandchildDetached = true;
        case '--grandchild-mode':
          o.grandchildMode = true;
        case '--ignore-stop':
          o.ignoreStop = true;
        case '--ignore-sigterm':
          o.ignoreSigterm = true;
        case '--crash-on':
          o.crashOn = a[++i];
        case '--stop-ms':
          o.stopMs = int.parse(a[++i]);
        case '--save-ms':
          o.saveMs = int.parse(a[++i]);
        case '--startup-ms':
          o.startupMs = int.parse(a[++i]);
        case '--players':
          o.players = a[++i].split(',').where((p) => p.isNotEmpty).toList();
        case '--max-players':
          o.maxPlayers = int.parse(a[++i]);
        case '--mc-version':
          o.version = a[++i];
      }
    }
    return o;
  }
}

/// Comando che riavvia questo stesso programma (JIT o compilato).
List<String> _selfCommand() {
  final exe = Platform.resolvedExecutable;
  final name = exe.split(RegExp(r'[/\\]')).last.toLowerCase();
  if (name == 'dart' || name == 'dart.exe') {
    return [exe, ...Platform.executableArguments, Platform.script.toFilePath()];
  }
  return [exe];
}

final class _FakeServer {
  _FakeServer(this.o);

  final _Opts o;
  late final Set<String> _players = {...o.players};
  bool _autosave = true;
  bool _stopping = false;
  int? _grandchild;
  StreamSubscription<String>? _stdin;

  Future<void> run() async {
    unawaited(stdout.done.then<void>((_) {}, onError: (Object _) {}));
    unawaited(stderr.done.then<void>((_) {}, onError: (Object _) {}));
    if (o.grandchildMode) {
      _writeState('grandchild.pid', '$pid');
      // il nipote testardo: non reagisce a niente, dorme e basta
      Timer.periodic(const Duration(hours: 1), (_) {});
      return;
    }
    _writeState('server.pid', '$pid');
    final sw = Stopwatch()..start();
    _info('Starting minecraft server version ${o.version}');
    _info('Loading properties');
    _info('Default game type: SURVIVAL');
    _info('Preparing level "world"');

    if (o.grandchild) {
      final self = _selfCommand();
      final args = [
        ...self.skip(1),
        '--grandchild-mode',
        if (o.state != null) ...['--state', o.state!],
      ];
      if (o.grandchildDetached) {
        final p = await Process.start(self.first, args, mode: ProcessStartMode.detached);
        _grandchild = p.pid;
      } else {
        final p = await Process.start(self.first, args);
        _grandchild = p.pid;
        unawaited(p.stdout.drain<void>());
        unawaited(p.stderr.drain<void>());
      }
    }

    if (!Platform.isWindows) {
      ProcessSignal.sigterm.watch().listen((_) => _signal('sigterm'));
      ProcessSignal.sigint.watch().listen((_) => _signal('sigterm'));
    }
    if (o.startupMs > 0) await Future<void>.delayed(Duration(milliseconds: o.startupMs));
    final secs = (sw.elapsedMilliseconds / 1000).toStringAsFixed(3);
    _info('Done (${secs}s)! For help, type "help"');

    _stdin = stdin
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          _onCommand,
          onDone: () => _writeState('stdin-eof', DateTime.now().toIso8601String()),
          onError: (Object _) {},
        );
  }

  void _signal(String why) {
    if (o.ignoreStop || o.ignoreSigterm) {
      _warn('($why) ignored');
      return;
    }
    unawaited(_stop(why));
  }

  void _onCommand(String raw) {
    final cmd = raw.trim();
    if (cmd.isEmpty) return;
    if (o.crashOn != null && cmd == o.crashOn) {
      _crash(1);
      return;
    }
    final sp = cmd.indexOf(' ');
    final head = sp < 0 ? cmd : cmd.substring(0, sp);
    final rest = sp < 0 ? '' : cmd.substring(sp + 1).trim();
    switch (head) {
      case 'stop':
        if (o.ignoreStop) {
          _warn('stop ignored');
        } else {
          unawaited(_stop('console'));
        }
      case 'save-off':
        _info(_autosave ? 'Automatic saving is now disabled' : 'Saving is already turned off');
        _autosave = false;
      case 'save-on':
        _info(_autosave ? 'Saving is already turned on' : 'Automatic saving is now enabled');
        _autosave = true;
      case 'save-all':
        unawaited(_saveAll());
      case 'list':
        final names = _players.join(', ');
        _info('There are ${_players.length} of a max of ${o.maxPlayers} players online: $names');
      case 'say':
        _info('[Server] $rest');
      case 'fake:join':
        if (_players.add(rest)) _info('$rest joined the game');
      case 'fake:leave':
        if (_players.remove(rest)) _info('$rest left the game');
      case 'fake:burst':
        final f = rest.split(' ');
        unawaited(_burst(int.parse(f[0]), f.length > 1 ? int.parse(f[1]) : 0));
      case 'fake:stderr':
        _err(rest);
      case 'fake:crash':
        _crash(int.tryParse(rest) ?? 1);
      case 'fake:freeze':
        _stdin?.pause();
      default:
        _info('Unknown or incomplete command, see below for error');
        _info('$cmd<--[HERE]');
    }
  }

  Future<void> _saveAll() async {
    _info('Saving the game (this may take a moment!)');
    await Future<void>.delayed(Duration(milliseconds: o.saveMs));
    _info('Saved the game');
  }

  Future<void> _stop(String why) async {
    if (_stopping) return;
    _stopping = true;
    _info('Stopping the server');
    _info('Stopping server');
    _info('Saving players');
    _info('Saving worlds');
    _info("Saving chunks for level 'ServerLevel[world]'/minecraft:overworld");
    await Future<void>.delayed(Duration(milliseconds: o.stopMs));
    _info('ThreadedAnvilChunkStorage (world): All chunks are saved');
    _info('ThreadedAnvilChunkStorage: All dimensions are saved');
    _writeState('saved', why);
    final g = _grandchild;
    if (g != null) Process.killPid(g, ProcessSignal.sigkill);
    await _flush();
    exit(0);
  }

  void _crash(int code) {
    _err('Exception in server tick loop');
    _err('java.lang.IllegalStateException: fake crash');
    _err('\tat net.minecraft.server.MinecraftServer.runServer(MinecraftServer.java:1)');
    unawaited(_flush().then((_) => exit(code)));
  }

  Future<void> _burst(int n, int rate) async {
    final sw = Stopwatch()..start();
    var i = 0;
    if (rate <= 0) {
      while (i < n) {
        final sb = StringBuffer();
        for (var k = 0; k < 1000 && i < n; k++, i++) {
          sb.writeln('BURST $i ${DateTime.now().microsecondsSinceEpoch}');
        }
        _write(stdout, sb.toString());
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
          _write(stdout, sb.toString());
        }
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    }
    _write(stdout, 'BURST-END $n ${sw.elapsedMilliseconds}\n');
  }

  void _writeState(String name, String content) {
    final dir = o.state;
    if (dir == null) return;
    try {
      final tmp = File('$dir${Platform.pathSeparator}.$name.tmp');
      tmp.writeAsStringSync(content, flush: true);
      tmp.renameSync('$dir${Platform.pathSeparator}$name');
    } on FileSystemException {
      // solo diagnostica per i test
    }
  }

  static String _clock() {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '[${two(t.hour)}:${two(t.minute)}:${two(t.second)}]';
  }

  void _info(String m) => _write(stdout, '${_clock()} [Server thread/INFO]: $m\n');
  void _warn(String m) => _write(stdout, '${_clock()} [Server thread/WARN]: $m\n');
  void _err(String m) => _write(stderr, '$m\n');

  void _write(IOSink s, String text) {
    try {
      s.write(text);
    } on Object {
      // console rotta: si ignora, come la JVM
    }
  }

  Future<void> _flush() async {
    for (final s in [stdout, stderr]) {
      try {
        await s.flush().timeout(const Duration(seconds: 2));
      } on Object {
        // idem
      }
    }
  }
}
