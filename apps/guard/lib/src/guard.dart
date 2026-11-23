// Il guard: un piccolo processo AOT tra l'app e il server Minecraft.
//
//   app ──pipe (JSON lines)──▶ guard ──pipe──▶ sh/cmd ──▶ java (──▶ nipoti)
//
// Il server non deve mai sopravvivere all'app. Arresto pulito ("stop" sulla
// console, poi kill dell'albero dopo la grazia) quando:
//   1. lo stdin del guard va in EOF (l'app è morta o ha chiuso il pipe);
//   2. il genitore non c'è più (getppid cambiato su POSIX, handle del padre
//      segnalato su Windows con --parent-pid);
//   3. (Linux) arriva il PDEATHSIG del guard (SIGUSR2) e getppid è cambiato;
//   4. arriva SIGTERM (o SIGINT su POSIX) al guard.
// SIGHUP è ignorato: decidono l'EOF e il controllo del genitore.
//
// Contenimento: process group proprio e PR_SET_CHILD_SUBREAPER (Linux),
// process group (macOS), Job Object kill-on-close (Windows), sempre
// attivati prima di avviare il server.
//
// "Finito" vuol dire: figlio diretto uscito, suoi pipe chiusi e albero
// vuoto. Il guard non muore per un EPIPE; quando l'app non c'è più, la
// console va nel file --log.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'process_tree.dart';
import 'protocol.dart';

/// Opzioni della riga di comando del guard.
final class GuardOptions {
  GuardOptions({
    required this.command,
    this.grace = const Duration(seconds: 60),
    this.poll = const Duration(milliseconds: 250),
    this.parentPid,
    this.stdinEof = true,
    this.parentWatch = true,
    this.selfPdeathsig = true,
    this.logPath,
    this.cwd,
  });

  /// Comando del server ed eventuali argomenti.
  final List<String> command;

  /// Attesa tra "stop" sulla console e kill dell'albero.
  final Duration grace;

  /// Intervallo del controllo del genitore.
  final Duration poll;

  /// PID dell'app: su Windows serve a sorvegliarla, su POSIX a capire se è
  /// morta prima che il guard partisse.
  final int? parentPid;

  // Le tre opzioni seguenti esistono per la diagnostica e per i test, che
  // provano ogni via di rilevamento da sola.
  final bool stdinEof;
  final bool parentWatch;
  final bool selfPdeathsig;

  /// Dove scrivere la console quando l'app non c'è più.
  final String? logPath;

  /// Cartella di lavoro del server.
  final String? cwd;

  static const usage =
      'uso: minesync_guard [--grace S] [--parent-pid N] [--log FILE] [--cwd DIR]\n'
      '                    [--poll-ms N] [--no-stdin-eof] [--no-parent-watch]\n'
      '                    [--no-pdeathsig] -- comando argomenti...';

  /// Interpreta [a]; [FormatException] se non è valido.
  static GuardOptions parse(List<String> a) {
    var grace = const Duration(seconds: 60);
    var poll = const Duration(milliseconds: 250);
    int? parentPid;
    var stdinEof = true, parentWatch = true, selfPdeathsig = true;
    String? logPath, cwd;
    var command = const <String>[];
    String next(int i) {
      if (i >= a.length) throw FormatException('manca il valore di ${a[i - 1]}');
      return a[i];
    }

    for (var i = 0; i < a.length; i++) {
      switch (a[i]) {
        case '--grace':
          final s = double.parse(next(++i));
          if (s < 0) throw const FormatException('--grace negativo');
          grace = Duration(milliseconds: (s * 1000).round());
        case '--poll-ms':
          poll = Duration(milliseconds: int.parse(next(++i)).clamp(10, 60000));
        case '--parent-pid':
          parentPid = int.parse(next(++i));
        case '--log':
          logPath = next(++i);
        case '--cwd':
          cwd = next(++i);
        case '--no-stdin-eof':
          stdinEof = false;
        case '--no-parent-watch':
          parentWatch = false;
        case '--no-pdeathsig':
          selfPdeathsig = false;
        case '--':
          command = a.sublist(i + 1);
          i = a.length;
        default:
          throw FormatException('opzione sconosciuta ${a[i]}');
      }
    }
    if (command.isEmpty) throw const FormatException('manca il comando del server');
    return GuardOptions(
      command: command,
      grace: grace,
      poll: poll,
      parentPid: parentPid,
      stdinEof: stdinEof,
      parentWatch: parentWatch,
      selfPdeathsig: selfPdeathsig,
      logPath: logPath,
      cwd: cwd,
    );
  }
}

/// Punto d'ingresso del binario: il guard non deve mai morire per un errore
/// asincrono (per esempio EPIPE dopo la morte dell'app), perché lascerebbe
/// il server orfano.
void runGuard(List<String> argv) {
  final GuardOptions o;
  try {
    o = GuardOptions.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('minesync_guard: ${e.message}\n${GuardOptions.usage}');
    exit(GuardExitCode.usage);
  }
  Guard? g;
  runZonedGuarded(
    () {
      g = Guard(o);
      unawaited(g!.run());
    },
    (e, _) {
      g?._diag('errore non gestito: $e');
    },
  );
}

/// Un comando in attesa di essere scritto nello stdin del server.
final class _Cmd {
  _Cmd(this.line, this.id, this.deadline);
  final String line;
  final int? id;
  final DateTime? deadline;
}

/// Il supervisore. Un'istanza per processo.
final class Guard {
  Guard(this._o);

  final GuardOptions _o;
  final ProcessTree _tree = ProcessTree();
  Process? _child;
  StreamSubscription<String>? _outSub, _errSub;

  bool _stopping = false;
  bool _forced = false;
  bool _gaveUp = false;
  bool _finishing = false;
  String? _trigger;
  int? _childExit;
  bool _outDone = false, _errDone = false;
  Timer? _graceTimer, _leftoverTimer, _finishPoll;

  // Uscita verso l'app: si accumula e si scrive con un flush alla volta. Se
  // l'app non legge, oltre [_outHigh] byte si smette di leggere il server
  // (che a quel punto si blocca sulla console) invece di perdere righe o
  // crescere senza limite; si riprende sotto [_outLow].
  static const _outHigh = 8 << 20;
  static const _outLow = 1 << 20;
  final BytesBuilder _out = BytesBuilder(copy: false);
  bool _writerActive = false;
  bool _pipesPaused = false;
  bool _outBroken = false;
  bool _appGone = false;
  IOSink? _log;

  // Comandi verso il server, scritti uno alla volta.
  static const _maxQueued = 1024;
  final Queue<_Cmd> _cmds = Queue<_Cmd>();
  bool _writing = false;
  bool _stdinClosed = false;

  Future<void> run() async {
    unawaited(stdout.done.then<void>((_) {}, onError: (Object _) => _outBroken = true));

    final contain = _tree.contain(selfPdeathsig: _o.selfPdeathsig);
    _watchSignals();

    if (!_tree.watchParent(_o.parentPid)) {
      // l'app è morta prima che il guard partisse: non si avvia niente
      _emit({'t': GuardMsg.exit, 'code': null, 'reason': ExitReason.parentDeadAtStart});
      await _flushAndExit(GuardExitCode.parentDead);
      return;
    }

    if (_stopping) {
      // SIGTERM arrivato mentre si partiva: meglio non avviare niente
      _emit({'t': GuardMsg.exit, 'code': null, 'reason': ExitReason.stopped, 'trigger': _trigger});
      await _flushAndExit(GuardExitCode.ok);
      return;
    }
    final Process c;
    try {
      c = await Process.start(_o.command.first, _o.command.sublist(1), workingDirectory: _o.cwd);
    } on Object catch (e) {
      _emit({'t': GuardMsg.exit, 'code': null, 'reason': ExitReason.startFailed, 'message': '$e'});
      await _flushAndExit(GuardExitCode.startFailed);
      return;
    }
    _child = c;
    _emit({'t': GuardMsg.started, 'pid': c.pid, 'guard': pid, 'contain': contain});
    if (_stopping) _armStop();

    unawaited(c.stdin.done.then<void>((_) {}, onError: (Object _) => _stdinClosed = true));
    _outSub = _pump(c.stdout, GuardMsg.out, () => _outDone = true);
    _errSub = _pump(c.stderr, GuardMsg.err, () => _errDone = true);
    unawaited(
      c.exitCode.then((code) {
        _childExit = code;
        _maybeFinish();
      }),
    );

    stdin
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          _onAppLine,
          onDone: () {
            if (_o.stdinEof) _beginStop('stdin-eof');
          },
          onError: (Object _) {
            if (_o.stdinEof) _beginStop('stdin-error');
          },
        );

    if (_o.parentWatch) {
      Timer.periodic(_o.poll, (t) {
        if (!_tree.parentAlive()) {
          t.cancel();
          _parentGone('parent-dead');
        }
      });
    }
  }

  void _watchSignals() {
    // SIGHUP di default ucciderebbe il guard: decidono l'EOF e il genitore.
    ProcessSignal.sighup.watch().listen((_) => _diag('SIGHUP ignorato'));
    if (Platform.isWindows) {
      // Ctrl+C in una console arriva a tutti i processi attaccati: decide
      // l'app (che chiederà lo stop), il guard non deve morire.
      ProcessSignal.sigint.watch().listen((_) => _diag('Ctrl+C ignorato'));
      return;
    }
    ProcessSignal.sigterm.watch().listen((_) => _beginStop('sigterm'));
    ProcessSignal.sigint.watch().listen((_) => _beginStop('sigterm'));
    if (Platform.isLinux) {
      ProcessSignal.sigusr2.watch().listen((_) {
        if (!_tree.parentAlive()) {
          _parentGone('pdeathsig');
        } else {
          _diag('PDEATHSIG spurio (getppid invariato): ignorato');
        }
      });
    }
  }

  void _parentGone(String trigger) {
    _appGone = true;
    // nessuno legge più: la console va nel log, il server non va frenato
    _resumePipes();
    _beginStop(trigger);
  }

  void _onAppLine(String line) {
    Object? m;
    try {
      m = jsonDecode(line);
    } on FormatException {
      m = null;
    }
    if (m is! Map) {
      _enqueue(line);
      return;
    }
    switch (m['t']) {
      case AppMsg.cmd:
        final ttl = m['ttl'];
        _enqueue(
          '${m['l'] ?? ''}',
          id: m['id'] is int ? m['id'] as int : null,
          ttl: ttl is int ? Duration(milliseconds: ttl) : null,
        );
      case AppMsg.stop:
        _beginStop('app');
      case AppMsg.kill:
        _beginStop('app-kill', hard: true);
      default:
        _diag('messaggio sconosciuto: ${m['t']}');
    }
  }

  void _enqueue(String line, {int? id, Duration? ttl}) {
    if (_cmds.length >= _maxQueued) {
      if (id != null) _emit({'t': GuardMsg.nack, 'id': id, 'why': 'full'});
      return;
    }
    _cmds.add(_Cmd(line, id, ttl == null ? null : DateTime.now().add(ttl)));
    unawaited(_writeCommands());
  }

  /// Scrive i comandi in ordine, uno alla volta: l'ack parte solo quando la
  /// riga è nel pipe del server. Se il server non legge, il flush resta in
  /// attesa e i comandi dietro scadono (nack "timeout") invece di partire
  /// in ritardo.
  Future<void> _writeCommands() async {
    if (_writing) return;
    _writing = true;
    while (_cmds.isNotEmpty) {
      final c = _cmds.removeFirst();
      final child = _child;
      if (child == null || _stdinClosed || _childExit != null) {
        _nack(c, 'closed');
        continue;
      }
      final d = c.deadline;
      if (d != null && DateTime.now().isAfter(d)) {
        _nack(c, 'timeout');
        continue;
      }
      try {
        child.stdin.add(utf8.encode('${c.line}\n'));
        await child.stdin.flush();
        if (c.id != null) _emit({'t': GuardMsg.ack, 'id': c.id});
      } on Object {
        _stdinClosed = true;
        _nack(c, 'closed');
      }
    }
    _writing = false;
  }

  void _nack(_Cmd c, String why) {
    if (c.id != null) _emit({'t': GuardMsg.nack, 'id': c.id, 'why': why});
  }

  StreamSubscription<String> _pump(Stream<List<int>> s, String tag, void Function() done) {
    return s
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (l) => _emit({'t': tag, 'l': l, 'ts': DateTime.now().millisecondsSinceEpoch}),
          onDone: () {
            done();
            _maybeFinish();
          },
          onError: (Object _) {},
        );
  }

  void _beginStop(String trigger, {bool hard = false}) {
    if (!_stopping) {
      _stopping = true;
      _trigger = trigger;
      _emit({'t': GuardMsg.state, 's': 'stopping', 'trigger': trigger});
      // prima dell'avvio del server ci pensa run()
      if (_child != null) _armStop();
    }
    if (_child == null) return;
    if (hard) _hardKill();
    _maybeFinish();
  }

  void _armStop() {
    _enqueue('stop');
    _graceTimer = Timer(_o.grace, () {
      _diag('periodo di grazia scaduto: kill dell\'albero');
      _hardKill();
    });
  }

  void _hardKill() {
    if (_forced) return;
    _forced = true;
    _tree.killAll();
    // si ripete finché l'albero è vuoto: un fork in corso può sfuggire al
    // primo giro
    Timer.periodic(const Duration(milliseconds: 100), (t) {
      if (_tree.members().isEmpty) {
        t.cancel();
        _maybeFinish();
      } else if (t.tick > 100) {
        t.cancel();
        _gaveUp = true;
        _diag('albero non vuoto dopo 10 s di kill: si esce comunque');
        _maybeFinish();
      } else {
        _tree.killAll();
      }
    });
  }

  void _maybeFinish() {
    if (_finishing || _child == null) return;
    if (!_gaveUp) {
      if (_childExit == null || !_outDone || !_errDone) return;
      if (_tree.members().isNotEmpty) {
        // il figlio diretto è uscito ma resta qualcosa (java dopo sh, o un
        // nipote): si continua a sorvegliare e, se nessuno ha chiesto lo
        // stop, si chiede alla console e poi si uccide
        _finishPoll ??= Timer.periodic(const Duration(milliseconds: 200), (_) => _maybeFinish());
        if (!_stopping && _leftoverTimer == null) {
          _diag('il server è uscito ma restano processi: stop e poi kill');
          _enqueue('stop');
          final g = _o.grace < const Duration(seconds: 10) ? _o.grace : const Duration(seconds: 10);
          _leftoverTimer = Timer(g, _hardKill);
        }
        return;
      }
    }
    _finishing = true;
    _finishPoll?.cancel();
    _graceTimer?.cancel();
    _leftoverTimer?.cancel();
    final reason = !_stopping
        ? ExitReason.exited
        : _forced
        ? ExitReason.killed
        : ExitReason.stopped;
    _emit({
      't': GuardMsg.exit,
      'code': _childExit,
      'reason': reason,
      'trigger': _trigger,
      'forced': _forced,
    });
    unawaited(_flushAndExit(GuardExitCode.ok));
  }

  void _diag(String m) => _emit({'t': GuardMsg.diag, 'm': m});

  void _emit(Map<String, Object?> m) {
    final bytes = utf8.encode('${jsonEncode(m)}\n');
    if (_appGone || _outBroken) {
      _toLog(bytes);
      return;
    }
    _out.add(bytes);
    if (!_writerActive) {
      _writerActive = true;
      // un giro di event loop raccoglie più righe in una sola scrittura
      Timer.run(_writeOut);
    }
    if (_out.length > _outHigh && !_pipesPaused) {
      _pipesPaused = true;
      _outSub?.pause();
      _errSub?.pause();
    }
  }

  Future<void> _writeOut() async {
    while (_out.isNotEmpty) {
      final data = _out.takeBytes();
      if (_appGone || _outBroken) {
        _toLog(data);
        continue;
      }
      try {
        stdout.add(data);
        await stdout.flush();
      } on Object {
        _outBroken = true;
        _toLog(data);
      }
      if (_out.length < _outLow) _resumePipes();
    }
    _writerActive = false;
    _resumePipes();
  }

  void _resumePipes() {
    if (!_pipesPaused) return;
    _pipesPaused = false;
    _outSub?.resume();
    _errSub?.resume();
  }

  void _toLog(List<int> bytes) {
    final p = _o.logPath;
    if (p == null) return;
    try {
      _log ??= File(p).openWrite(mode: FileMode.append);
      _log!.add(bytes);
    } on Object {
      // il log è un aiuto, non deve fermare niente
    }
  }

  Future<void> _flushAndExit(int code) async {
    final end = DateTime.now().add(const Duration(seconds: 2));
    while ((_writerActive || _out.isNotEmpty) && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (_out.isNotEmpty) _toLog(_out.takeBytes());
    try {
      if (!_outBroken && !_appGone) await stdout.flush().timeout(const Duration(seconds: 2));
    } on Object {
      // l'app non legge più: pazienza
    }
    try {
      await _log?.close();
    } on Object {
      // idem
    }
    exit(code);
  }
}
