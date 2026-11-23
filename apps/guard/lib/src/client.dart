// Lato app del guard: avvia il binario, parla il protocollo JSON lines e
// offre al motore della sessione righe di console, comandi, stop e kill.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'posix.dart' as px;
import 'protocol.dart';

/// Una riga della console del server.
final class ConsoleLine {
  const ConsoleLine(this.text, {required this.stderr, required this.at});

  /// Testo senza il fine riga.
  final String text;

  /// Vero se la riga viene dallo stderr del server.
  final bool stderr;

  /// Quando il guard l'ha letta dal server.
  final DateTime at;

  @override
  String toString() => stderr ? '[err] $text' : text;
}

/// Come è finito il server.
final class GuardExit {
  const GuardExit({
    required this.exitCode,
    required this.reason,
    this.trigger,
    this.forced = false,
    this.message,
  });

  /// Il server è uscito da solo (crash, o "stop" mandato come comando).
  static const exited = 'exited';

  /// Arresto chiesto (da [GuardClient.stop], o dal guard perché l'app è
  /// sparita o ha ricevuto SIGTERM) e server uscito entro la grazia.
  static const stopped = 'stopped';

  /// Albero ucciso: [GuardClient.kill] o grazia scaduta.
  static const killed = 'killed';

  /// Il guard è morto senza dire com'è finita; l'app ha fermato il suo
  /// process group (POSIX) o ci ha pensato il job (Windows).
  static const guardDied = 'guardDied';

  /// Il server (o il guard stesso) non è partito.
  static const startFailed = 'startFailed';

  /// Exit code del processo avviato dal guard (lo script o java); null se
  /// non è noto.
  final int? exitCode;

  /// Uno tra [exited], [stopped], [killed], [guardDied], [startFailed].
  final String reason;

  /// Cosa ha avviato l'arresto, se c'è stato: `app`, `app-kill`,
  /// `stdin-eof`, `parent-dead`, `pdeathsig`, `sigterm`.
  final String? trigger;

  /// Vero se almeno un processo dell'albero è stato ucciso.
  final bool forced;

  /// Dettaglio in chiaro (per esempio l'errore di avvio).
  final String? message;

  @override
  String toString() =>
      'GuardExit($reason, code: $exitCode'
      '${trigger == null ? '' : ', trigger: $trigger'}${forced ? ', forced' : ''}'
      '${message == null ? '' : ', $message'})';
}

/// Il server non è (più) in esecuzione.
final class NotRunning implements Exception {
  const NotRunning();

  @override
  String toString() => 'NotRunning: il server non è in esecuzione';
}

/// La console del server non ha accettato il comando in tempo (server che
/// non legge lo stdin): il comando non è stato inviato.
final class SendTimeout extends TimeoutException {
  SendTimeout(this.command, Duration timeout)
    : super('console del server bloccata: comando non inviato', timeout);

  final String command;
}

/// Il guard o il server non sono partiti.
final class GuardStartFailed implements Exception {
  const GuardStartFailed(this.message);
  final String message;

  @override
  String toString() => 'GuardStartFailed: $message';
}

/// Il server Minecraft avviato attraverso il guard.
///
/// Righe di console: [lines] consegna ogni riga, in ordine, senza perderne.
/// Le righe che il listener non ha ancora preso restano in un buffer del
/// client fino a [maxBufferedLines]; oltre, il client smette di leggere dal
/// guard finché il listener non scende sotto la metà. A quel punto anche il
/// guard accumula (fino a qualche MiB) e poi smette di leggere il server, che
/// si blocca sulla console come con un terminale lento: si rallenta, non si
/// perde niente e la memoria resta limitata. Mentre la lettura è ferma
/// arrivano in ritardo anche gli esiti di [send] e la fine del server, quindi
/// chi usa il client deve ascoltare [lines] (anche solo per scartarle).
final class GuardClient {
  GuardClient._(this._proc, this._grace);

  /// Righe tenute dal client per un listener lento o assente.
  static const maxBufferedLines = 100000;

  /// Avvia il guard e, attraverso lui, [executable] con [args] in [workDir].
  ///
  /// [guard] è il comando del guard: `[exePath]` per il binario compilato, o
  /// `[dartExe, 'run', '<path>/bin/minesync_guard.dart']` in sviluppo e nei
  /// test. Usare percorsi assoluti: guard e server partono in [workDir].
  /// [env] si aggiunge all'ambiente corrente e arriva al server. [grace] è
  /// l'attesa tra "stop" sulla console e il kill dell'albero. [logPath]
  /// raccoglie la console quando l'app non c'è più.
  ///
  /// Termina quando il server è partito; [GuardStartFailed] se non parte.
  static Future<GuardClient> start({
    required List<String> guard,
    required String executable,
    required List<String> args,
    required String workDir,
    Map<String, String>? env,
    Duration grace = const Duration(seconds: 60),
    String? logPath,
  }) async {
    if (guard.isEmpty) throw ArgumentError.value(guard, 'guard', 'comando vuoto');
    final argv = [
      ...guard.skip(1),
      '--parent-pid',
      '$pid',
      '--grace',
      '${grace.inMilliseconds / 1000}',
      if (logPath != null) ...['--log', logPath],
      '--cwd',
      workDir,
      '--',
      executable,
      ...args,
    ];
    final Process p;
    try {
      p = await Process.start(guard.first, argv, workingDirectory: workDir, environment: env);
    } on ProcessException catch (e) {
      throw GuardStartFailed('guard non avviabile: ${e.message}');
    }
    final c = GuardClient._(p, grace);
    c._listen();
    try {
      await c._started.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      c._killRequested = true;
      c._killGuardProcess();
      await c.exit;
      throw const GuardStartFailed('il guard non ha avviato il server entro 30 s');
    }
    return c;
  }

  final Process _proc;
  final Duration _grace;
  final Completer<void> _started = Completer<void>();
  final Completer<GuardExit> _exit = Completer<GuardExit>();
  final Map<int, Completer<void>> _pending = {};
  int _nextId = 0;
  int? _serverPid;
  int? _guardPid;
  bool _running = false;
  bool _killRequested = false;
  Map<Object?, Object?>? _exitMsg;
  bool _procExited = false;
  int? _procCode;
  bool _stdoutDone = false;
  final StringBuffer _stderrTail = StringBuffer();
  Timer? _watchdog;

  late final StreamSubscription<String> _up;
  bool _upPaused = false;
  final Queue<ConsoleLine> _queue = Queue<ConsoleLine>();
  bool _cancelled = false;
  bool _draining = false;
  late final StreamController<ConsoleLine> _lines = StreamController<ConsoleLine>(
    sync: true,
    onListen: () => scheduleMicrotask(_drain),
    onResume: () => scheduleMicrotask(_drain),
    onCancel: () {
      _cancelled = true;
      _queue.clear();
      _resumeUp();
    },
  );
  final StreamController<String> _diag = StreamController<String>.broadcast();

  /// Ogni riga della console, in ordine (stream a un solo listener). Si
  /// chiude dopo l'ultima riga, quando il guard ha finito.
  Stream<ConsoleLine> get lines => _lines.stream;

  /// Diagnostica del guard e del client, in chiaro, per i log.
  Stream<String> get diagnostics => _diag.stream;

  /// Vero dal momento in cui il server è partito fino alla sua fine.
  bool get running => _running && _exitMsg == null && !_exit.isCompleted;

  /// PID del processo avviato dal guard (lo script o java).
  int? get serverPid => _serverPid;

  /// PID del guard.
  int get guardPid => _guardPid ?? _proc.pid;

  /// Fine del server e di tutto il suo albero. Non fallisce mai.
  Future<GuardExit> get exit => _exit.future;

  /// Manda [command] alla console del server.
  ///
  /// Termina quando la riga è nello stdin del server. [SendTimeout] se non
  /// ci arriva entro [timeout] (il comando allora non parte più), e
  /// [NotRunning] se il server non è in esecuzione o finisce prima.
  Future<void> send(String command, {Duration timeout = const Duration(seconds: 5)}) async {
    if (command.contains('\n') || command.contains('\r')) {
      throw ArgumentError.value(command, 'command', 'una riga sola');
    }
    if (!running) throw const NotRunning();
    final id = ++_nextId;
    final done = Completer<void>();
    _pending[id] = done;
    _write({'t': AppMsg.cmd, 'l': command, 'id': id, 'ttl': timeout.inMilliseconds});
    try {
      await done.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(id);
      if (!running) throw const NotRunning();
      throw SendTimeout(command, timeout);
    }
  }

  /// Arresto pulito: "stop" sulla console e kill dell'albero se il server
  /// non esce entro la grazia. Termina quando il server è finito.
  Future<void> stop() async {
    if (_exit.isCompleted) return;
    _write({'t': AppMsg.stop});
    // se il guard non risponde, lo si chiude: dietro ci sono il fallback
    // sul process group (POSIX) e il job (Windows)
    _watchdog ??= Timer(_grace + const Duration(seconds: 15), () {
      _killRequested = true;
      _killGuardProcess();
    });
    await exit;
  }

  /// Kill immediato dell'albero del server. Termina quando è finito.
  Future<void> kill() async {
    if (_exit.isCompleted) return;
    _killRequested = true;
    _write({'t': AppMsg.kill});
    _watchdog?.cancel();
    _watchdog = Timer(const Duration(seconds: 15), _killGuardProcess);
    await exit;
  }

  void _listen() {
    unawaited(_proc.stdin.done.then<void>((_) {}, onError: (Object _) {}));
    _proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen((s) {
      if (_stderrTail.length < 8192) _stderrTail.write(s);
    }, onError: (Object _) {});
    _up = _proc.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          _onGuardLine,
          onDone: () {
            _stdoutDone = true;
            _maybeDone();
          },
          onError: (Object _) {},
        );
    unawaited(
      _proc.exitCode.then((code) {
        _procExited = true;
        _procCode = code;
        // il guard non scrive più: quel che resta nel pipe è poco, va letto
        // comunque per arrivare alla fine
        _resumeUp();
        _maybeDone();
      }),
    );
  }

  void _onGuardLine(String line) {
    final Object? m;
    try {
      m = jsonDecode(line);
    } on FormatException {
      _diagLine('riga non valida dal guard: $line');
      return;
    }
    if (m is! Map) return;
    switch (m['t']) {
      case GuardMsg.out || GuardMsg.err:
        final ts = m['ts'];
        _push(
          ConsoleLine(
            '${m['l'] ?? ''}',
            stderr: m['t'] == GuardMsg.err,
            at: ts is int ? DateTime.fromMillisecondsSinceEpoch(ts) : DateTime.now(),
          ),
        );
      case GuardMsg.ack:
        _pending.remove(m['id'])?.complete();
      case GuardMsg.nack:
        final c = _pending.remove(m['id']);
        if (c == null) return;
        if (m['why'] == 'closed') {
          c.completeError(const NotRunning());
        } else {
          c.completeError(TimeoutException('${m['why']}'));
        }
      case GuardMsg.started:
        _serverPid = m['pid'] as int?;
        _guardPid = m['guard'] as int?;
        _running = true;
        _diagLine('server avviato: pid $_serverPid, contenimento ${jsonEncode(m['contain'])}');
        if (!_started.isCompleted) _started.complete();
      case GuardMsg.state:
        _diagLine('arresto in corso (${m['trigger']})');
      case GuardMsg.diag:
        _diagLine('guard: ${m['m']}');
      case GuardMsg.exit:
        _exitMsg = m;
        _failPending();
    }
  }

  void _push(ConsoleLine l) {
    if (_cancelled) return;
    _queue.add(l);
    _drain();
    if (_queue.length >= maxBufferedLines && !_upPaused && !_procExited) {
      _upPaused = true;
      _up.pause();
      _diagLine('listener lento: lettura dal guard sospesa');
    }
  }

  void _drain() {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty && _lines.hasListener && !_lines.isPaused) {
        _lines.add(_queue.removeFirst());
      }
    } finally {
      _draining = false;
    }
    if (_queue.length < maxBufferedLines ~/ 2) _resumeUp();
    _maybeCloseLines();
  }

  void _resumeUp() {
    if (!_upPaused) return;
    _upPaused = false;
    _up.resume();
  }

  void _maybeCloseLines() {
    if (_exit.isCompleted && (_queue.isEmpty || _cancelled) && !_lines.isClosed) {
      unawaited(_lines.close());
    }
  }

  void _write(Map<String, Object?> m) {
    try {
      _proc.stdin.writeln(jsonEncode(m));
    } on Object {
      // guard già morto: se ne accorge _maybeDone
    }
  }

  void _killGuardProcess() {
    if (_procExited) return;
    _proc.kill(ProcessSignal.sigkill);
  }

  void _failPending() {
    for (final c in _pending.values) {
      c.completeError(const NotRunning());
    }
    _pending.clear();
  }

  void _diagLine(String s) {
    if (!_diag.isClosed) _diag.add(s);
  }

  bool _finishing = false;

  Future<void> _maybeDone() async {
    if (_finishing || !_procExited || !_stdoutDone) return;
    _finishing = true;
    _watchdog?.cancel();
    _failPending();
    final m = _exitMsg;
    final GuardExit result;
    if (m != null) {
      final reason = switch (m['reason']) {
        ExitReason.startFailed || ExitReason.parentDeadAtStart => GuardExit.startFailed,
        final String r => r,
        _ => GuardExit.exited,
      };
      result = GuardExit(
        exitCode: m['code'] as int?,
        reason: reason,
        trigger: m['trigger'] as String?,
        forced: m['forced'] == true,
        message:
            m['message'] as String? ?? (reason == GuardExit.startFailed ? '${m['reason']}' : null),
      );
    } else {
      final tail = _stderrTail.toString().trim();
      _diagLine('guard uscito con codice $_procCode senza esito');
      // anche prima di "started": il guard può essere morto subito dopo
      // aver avviato il server
      await _fallback();
      result = GuardExit(
        exitCode: null,
        reason: _started.isCompleted ? GuardExit.guardDied : GuardExit.startFailed,
        forced: true,
        message: 'guard uscito con codice $_procCode${tail.isEmpty ? '' : ': $tail'}',
      );
    }
    _running = false;
    if (!_started.isCompleted) {
      _started.completeError(GuardStartFailed(result.message ?? result.reason));
      // l'errore lo raccoglie start(); questo evita che risulti non gestito
      unawaited(_started.future.then<void>((_) {}, onError: (Object _) {}));
    }
    _exit.complete(result);
    _maybeCloseLines();
    unawaited(_diag.close());
  }

  /// Il guard è morto senza esito: su POSIX il suo process group gli
  /// sopravvive e lo si ferma da qui (SIGTERM, che per la JVM vuol dire
  /// salvataggio, poi SIGKILL dopo la grazia). Su Windows il job kill-on-close
  /// si è già portato via l'albero con la morte del guard.
  Future<void> _fallback() async {
    if (Platform.isWindows) return;
    final g = guardPid;
    if (px.groupMembers(g).isEmpty) return;
    _diagLine('fallback: ${_killRequested ? 'SIGKILL' : 'SIGTERM'} al gruppo $g');
    px.kill(-g, _killRequested ? px.sigkill : px.sigterm);
    final end = DateTime.now().add(_killRequested ? const Duration(seconds: 2) : _grace);
    while (px.groupMembers(g).isNotEmpty && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (px.groupMembers(g).isNotEmpty) {
      _diagLine('fallback: SIGKILL al gruppo $g');
      px.kill(-g, px.sigkill);
      final end2 = DateTime.now().add(const Duration(seconds: 5));
      while (px.groupMembers(g).isNotEmpty && DateTime.now().isBefore(end2)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }
}
