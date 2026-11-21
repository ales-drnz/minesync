// guard: piccolo supervisore AOT che sta tra l'app MineSync e il server.
//
//   app ──pipe──▶ guard ──pipe──▶ sh/cmd ──▶ java (──▶ eventuali nipoti)
//
// Protocollo (JSON lines):
//   app → guard (stdin):  {"t":"cmd","l":"say ciao"} | {"t":"stop"} | {"t":"kill"}
//                         (una riga non JSON è inoltrata così com'è alla console)
//   guard → app (stdout): {"t":"started","pid":N,"guard":N,"contain":{...}}
//                         {"t":"o","l":"..."}  stdout del server
//                         {"t":"e","l":"..."}  stderr del server
//                         {"t":"state","s":"stopping","reason":"..."}
//                         {"t":"diag","m":"..."}
//                         {"t":"exit","code":N,"reason":"...","forced":bool}
//
// Arresto pulito ("stop" sulla console, poi kill dell'albero dopo --grace) se:
//   1. lo stdin del guard va in EOF (l'app è morta o ha chiuso la pipe);
//   2. il genitore non c'è più (getppid cambiato / handle del padre segnalato);
//   3. (Linux) arriva il PDEATHSIG del guard (SIGUSR2) con getppid cambiato;
//   4. arriva SIGTERM al guard (logout, systemd, kill esplicito).
//
// Contenimento: process group proprio + PR_SET_CHILD_SUBREAPER (Linux),
// process group (macOS), Job Object kill-on-close (Windows).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:guard_spike/tree.dart';

class Options {
  Duration grace = const Duration(seconds: 60);
  Duration poll = const Duration(milliseconds: 250);
  int? parentPid;
  bool stdinEof = true; // solo per i test: false disattiva la via EOF
  bool parentWatch = true; // solo per i test
  bool selfPdeathsig = true; // Linux
  bool pdeathsigWrapper = false; // Linux: setpriv --pdeathsig TERM -- cmd
  String? logPath; // dove scrivere la console quando l'app non c'è più
  String? cwd;
  List<String> command = [];

  static Options parse(List<String> a) {
    final o = Options();
    for (var i = 0; i < a.length; i++) {
      switch (a[i]) {
        case '--grace':
          o.grace = Duration(milliseconds: (double.parse(a[++i]) * 1000).round());
        case '--poll-ms':
          o.poll = Duration(milliseconds: int.parse(a[++i]));
        case '--parent-pid':
          o.parentPid = int.parse(a[++i]);
        case '--no-stdin-eof':
          o.stdinEof = false;
        case '--no-parent-watch':
          o.parentWatch = false;
        case '--no-pdeathsig':
          o.selfPdeathsig = false;
        case '--pdeathsig-wrapper':
          o.pdeathsigWrapper = true;
        case '--log':
          o.logPath = a[++i];
        case '--cwd':
          o.cwd = a[++i];
        case '--':
          o.command = a.sublist(i + 1);
          i = a.length;
        default:
          stderr.writeln('guard: opzione sconosciuta ${a[i]}');
          exit(64);
      }
    }
    if (o.command.isEmpty) {
      stderr.writeln('uso: guard [opzioni] -- comando argomenti...');
      exit(64);
    }
    return o;
  }
}

void main(List<String> argv) {
  final o = Options.parse(argv);
  // Il guard non deve MAI morire per un errore asincrono (es. EPIPE sullo
  // stdout dopo la morte dell'app): lascerebbe il server orfano.
  runZonedGuarded(() => Guard(o).run(), (e, st) {
    Guard.current?.diag('errore non gestito: $e');
  });
}

class Guard {
  Guard(this.o) {
    current = this;
  }
  static Guard? current;

  final Options o;
  final ServerTree tree = ServerTree();
  Process? child;

  bool stopping = false, forced = false, outBroken = false, parentGone = false;
  String reason = 'exited';
  int? childExit;
  bool outDone = false, errDone = false;
  Timer? graceTimer, leftoverTimer, finishPoll;
  IOSink? _log;
  bool finishing = false;

  // buffer di uscita: si accumula per un giro di event loop e si scrive in
  // un colpo solo (a 5000 righe/s evita una write per riga)
  final BytesBuilder _buf = BytesBuilder(copy: false);
  bool _flushQueued = false;

  Future<void> run() async {
    stdout.done.then((_) {}, onError: (_) {
      outBroken = true;
    });

    final contain = tree.contain(selfPdeathsig: o.selfPdeathsig);
    if (!Platform.isWindows) _watchSignals();

    if (!tree.watchParent(o.parentPid)) {
      // l'app è morta prima che il guard partisse: non avviare niente
      emit({'t': 'exit', 'code': null, 'reason': 'parent-dead-at-start'});
      await _flushAndExit(3);
      return;
    }

    var cmd = o.command;
    if (o.pdeathsigWrapper && Platform.isLinux) {
      cmd = ['setpriv', '--pdeathsig', 'TERM', '--', ...cmd];
    }
    try {
      child = await Process.start(cmd.first, cmd.sublist(1),
          workingDirectory: o.cwd);
    } catch (e) {
      emit({'t': 'exit', 'code': null, 'reason': 'start-failed: $e'});
      await _flushAndExit(2);
      return;
    }
    final c = child!;
    emit({'t': 'started', 'pid': c.pid, 'guard': pid, 'contain': contain});

    c.stdin.done.then((_) {}, onError: (_) {});
    _pump(c.stdout, 'o', () => outDone = true);
    _pump(c.stderr, 'e', () => errDone = true);
    c.exitCode.then((code) {
      childExit = code;
      _maybeFinish();
    });

    // comandi dall'app
    stdin
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_onAppLine, onDone: () {
      if (o.stdinEof) beginStop('stdin-eof');
    }, onError: (_) {
      if (o.stdinEof) beginStop('stdin-error');
    });

    if (o.parentWatch) {
      Timer.periodic(o.poll, (t) {
        if (!tree.parentAlive()) {
          t.cancel();
          _parentGone('parent-dead');
        }
      });
    }
  }

  void _watchSignals() {
    // SIGTERM vero → arresto pulito
    ProcessSignal.sigterm.watch().listen((_) => beginStop('sigterm'));
    // SIGHUP: di default ucciderebbe il guard; decidono EOF / genitore
    ProcessSignal.sighup.watch().listen((_) => diag('SIGHUP ignorato'));
    if (Platform.isLinux) {
      ProcessSignal.sigusr2.watch().listen((_) {
        if (!tree.parentAlive()) {
          _parentGone('pdeathsig');
        } else {
          diag('PDEATHSIG spurio (getppid invariato): ignorato');
        }
      });
    }
  }

  void _parentGone(String why) {
    parentGone = true;
    beginStop(why);
  }

  void _onAppLine(String line) {
    Object? m;
    try {
      m = jsonDecode(line);
    } catch (_) {
      m = null;
    }
    if (m is Map) {
      switch (m['t']) {
        case 'cmd':
          _send('${m['l']}');
        case 'stop':
          beginStop('app');
        case 'kill':
          beginStop('app-kill');
          _hardKill();
      }
    } else {
      _send(line);
    }
  }

  void _send(String l) {
    try {
      child?.stdin.add(utf8.encode('$l\n'));
    } catch (_) {}
  }

  void _pump(Stream<List<int>> s, String tag, void Function() done) {
    s
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((l) => emit({'t': tag, 'l': l}), onDone: () {
      done();
      _maybeFinish();
    }, onError: (_) {});
  }

  void beginStop(String why) {
    if (stopping) return;
    stopping = true;
    reason = why;
    emit({'t': 'state', 's': 'stopping', 'reason': why});
    _send('stop');
    graceTimer = Timer(o.grace, _hardKill);
    _maybeFinish();
  }

  void _hardKill() {
    if (forced) return;
    forced = true;
    diag('periodo di grazia scaduto: kill dell\'albero');
    tree.killAll();
    // si ripete finché l'albero è vuoto (un fork in corso può sfuggire al
    // primo giro)
    Timer.periodic(const Duration(milliseconds: 100), (t) {
      if (tree.members().isEmpty || t.tick > 100) {
        t.cancel();
        _maybeFinish();
      } else {
        tree.killAll();
      }
    });
  }

  void _maybeFinish() {
    if (finishing || childExit == null || !outDone || !errDone) {
      return;
    }
    if (tree.members().isNotEmpty) {
      // il figlio diretto è uscito ma resta qualcosa (es. java dopo sh, o un
      // nipote): si continua a sorvegliare e, se non si sta già fermando,
      // si concede un po' di tempo prima del kill.
      finishPoll ??= Timer.periodic(
          const Duration(milliseconds: 200), (_) => _maybeFinish());
      if (!stopping) {
        leftoverTimer ??= Timer(
            o.grace < const Duration(seconds: 10)
                ? o.grace
                : const Duration(seconds: 10),
            _hardKill);
      }
      return;
    }
    finishing = true;
    finishPoll?.cancel();
    graceTimer?.cancel();
    leftoverTimer?.cancel();
    emit({
      't': 'exit',
      'code': childExit,
      'reason': reason,
      'forced': forced,
    });
    _flushAndExit(0);
  }

  void diag(String m) => emit({'t': 'diag', 'm': m});

  void emit(Map<String, Object?> m) {
    final bytes = utf8.encode('${jsonEncode(m)}\n');
    if (outBroken || parentGone) {
      _toLog(bytes);
      return;
    }
    _buf.add(bytes);
    if (!_flushQueued) {
      _flushQueued = true;
      Timer.run(_flush);
    }
  }

  void _flush() {
    _flushQueued = false;
    if (_buf.isEmpty) return;
    final data = _buf.takeBytes();
    if (outBroken || parentGone) {
      _toLog(data);
      return;
    }
    try {
      stdout.add(data);
    } catch (_) {
      outBroken = true;
      _toLog(data);
    }
  }

  void _toLog(List<int> bytes) {
    if (o.logPath == null) return;
    try {
      _log ??= File(o.logPath!).openWrite(mode: FileMode.append);
      _log!.add(bytes);
    } catch (_) {}
  }

  Future<void> _flushAndExit(int code) async {
    _flush();
    try {
      if (!outBroken && !parentGone) {
        await stdout.flush().timeout(const Duration(seconds: 2));
      }
    } catch (_) {}
    try {
      await _log?.close();
    } catch (_) {}
    exit(code);
  }
}
