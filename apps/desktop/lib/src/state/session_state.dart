// Sessione di gioco nell'app: avvolge la Session di ms_session (lock, pull,
// server sotto il guard, salvataggi automatici, caricamento finale) e ne
// tiene lo stato per le schermate: fase, console, giocatori, salvataggi,
// avvisi gravi, conflitto con le modifiche locali e domande all'utente
// (EULA). Il motore non è duplicato qui: si sceglie solo come avviare il
// server, come nel comando `minesync play` della CLI.
import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ms_core/ms_core.dart';
import 'package:ms_minecraft/ms_minecraft.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_session/ms_session.dart';

export 'package:ms_session/ms_session.dart' show SaveRequest, SessionConfig;

/// Versione del client, scritta nel lock.
const String appVersion = '0.1.0';

/// Avvia il processo del server per un comando già costruito.
typedef ProcessStarter = Future<ServerProcess> Function(LaunchCommand cmd);

/// Cerca i runtime Java utilizzabili per la cartella del server.
typedef JavaFinder = Future<List<JavaRuntime>> Function(String serverRoot);

/// Come si avvia il server e cosa si legge dal sistema, sostituibili nei
/// test (server finto, Java finto, indirizzi fissi).
final class SessionEnv {
  const SessionEnv({this.start, this.findJava, this.addresses, this.config, this.pool});

  /// Avvio del processo; di default il guard ([guardCommand]).
  final ProcessStarter? start;

  /// Ricerca di Java; di default [findJavaRuntimes].
  final JavaFinder? findJava;

  /// Indirizzi IPv4 di questo PC per gli amici; di default le interfacce di
  /// rete.
  final Future<List<String>> Function()? addresses;

  /// Tempi della sessione (default: quelli del prodotto).
  final SessionConfig? config;
  final HashPool? pool;
}

/// Comando del guard: MINESYNC_GUARD, oppure minesync-guard[.exe] accanto
/// all'eseguibile dell'app. Null se non si trova.
List<String>? guardCommand(Map<String, String> env) {
  final fromEnv = env['MINESYNC_GUARD'];
  if (fromEnv != null && fromEnv.isNotEmpty) return [fromEnv];
  final exe = File(Platform.resolvedExecutable);
  final name = Platform.isWindows ? 'minesync-guard.exe' : 'minesync-guard';
  final sibling = File('${exe.parent.path}${Platform.pathSeparator}$name');
  return sibling.existsSync() ? [sibling.path] : null;
}

// --- errori di avvio ---------------------------------------------------------

/// Non si è potuta avviare la sessione per un motivo dell'app (non del sync).
sealed class SessionStartError implements Exception {
  const SessionStartError();
}

/// Manca Java della versione richiesta.
final class JavaMissing extends SessionStartError {
  const JavaMissing(this.required);
  final int required;
}

/// Non si trova come avviare il server (né script né jar).
final class NoLaunchFound extends SessionStartError {
  const NoLaunchFound();
}

/// L'utente non ha accettato l'EULA di Minecraft.
final class EulaDeclined extends SessionStartError {
  const EulaDeclined();
}

/// Il guard non è installato accanto all'app.
final class GuardMissing extends SessionStartError {
  const GuardMissing();
}

// --- preferenze ---------------------------------------------------------------

/// Modo del limite di banda dei salvataggi in background.
enum UploadLimitMode { auto, percent, fixed, none }

/// Limite di banda dalle preferenze ('uploadLimit': {mode, percent, kib}).
final class UploadLimit {
  const UploadLimit({this.mode = UploadLimitMode.auto, this.percent = 50, this.kib = 2048});

  factory UploadLimit.fromPrefs(Map<String, Object?> prefs) {
    final m = prefs['uploadLimit'];
    if (m is! Map) return const UploadLimit();
    return UploadLimit(
      mode: UploadLimitMode.values.asNameMap()[m['mode']] ?? UploadLimitMode.auto,
      percent: (m['percent'] as num?)?.toInt().clamp(10, 100) ?? 50,
      kib: (m['kib'] as num?)?.toInt().clamp(16, 1 << 20) ?? 2048,
    );
  }

  final UploadLimitMode mode;
  final int percent;
  final int kib;

  /// Quota della velocità misurata usata in automatico.
  static const autoShare = 70;

  Map<String, Object?> toJson() => {'mode': mode.name, 'percent': percent, 'kib': kib};

  UploadLimit copyWith({UploadLimitMode? mode, int? percent, int? kib}) =>
      UploadLimit(mode: mode ?? this.mode, percent: percent ?? this.percent, kib: kib ?? this.kib);

  /// Byte al secondo per il motore; 0 = nessun limite (anche quando la
  /// velocità non è ancora stata misurata).
  int bytesPerSecond(int? measured) => switch (mode) {
    UploadLimitMode.none => 0,
    UploadLimitMode.fixed => kib * 1024,
    UploadLimitMode.auto => measured == null ? 0 : measured * autoShare ~/ 100,
    UploadLimitMode.percent => measured == null ? 0 : measured * percent ~/ 100,
  };
}

/// Chiave della velocità di caricamento misurata (byte/s).
const String measuredUploadPref = 'measuredUploadBps';

/// Preferenze locali di un server (`server.<id>.<chiave>`).
final class ServerPrefs {
  const ServerPrefs({this.xmxMiB, this.javaPath, this.autostop});

  factory ServerPrefs.fromPrefs(Map<String, Object?> prefs, String space) => ServerPrefs(
    xmxMiB: (prefs[key(space, 'xmx')] as num?)?.toInt(),
    javaPath: prefs[key(space, 'java')] as String?,
    autostop: prefs[key(space, 'autostop')] as bool?,
  );

  static String key(String space, String name) => 'server.$space.$name';

  /// -Xmx in MiB; null = quella dello script.
  final int? xmxMiB;

  /// Java scelto a mano; null = automatico.
  final String? javaPath;

  /// Spegnimento automatico quando il server resta vuoto, scelto su questo
  /// PC; null = come dice l'hub (Admin › Sessioni, o la regola del server).
  final bool? autostop;
}

// --- stato esposto --------------------------------------------------------------

/// Fase della sessione per l'interfaccia.
enum SessionPhase {
  /// Lock, modifiche in sospeso, pull.
  syncing,

  /// Modifiche locali divergenti: serve una scelta ([SessionController.conflict]).
  conflict,
  starting,
  running,
  saving,
  stopping,

  /// Caricamento finale sull'hub.
  finalPush,
  ended,
  failed,

  /// Annullata prima di partire (conflitto annullato).
  cancelled,
}

/// Tipo di riga della console, come la colora l'interfaccia.
enum ConsoleKind { info, dim, warn, err, join, ok, cmd }

/// Messaggi di MineSync nella console, tradotti dalla schermata.
enum ConsoleNote { starting, ready, autosaved, uploaded, crashed, stopping, recovered }

/// Una riga della console: del server ([text]) o di MineSync ([note]).
@immutable
final class ConsoleEntry {
  const ConsoleEntry({
    required this.at,
    required this.kind,
    required this.level,
    this.text = '',
    this.note,
    this.args = const [],
  });

  final DateTime at;
  final ConsoleKind kind;

  /// Colonna del livello: INFO, WARN, ERR, JOIN, CMD, MS.
  final String level;
  final String text;
  final ConsoleNote? note;
  final List<Object?> args;

  bool get isWarnOrErr => kind == ConsoleKind.warn || kind == ConsoleKind.err;
}

final _lineRe = RegExp(
  r'^\[(?:\d\d:){2}\d\d\] \[[^\]]*/(INFO|WARN|WARNING|ERROR|FATAL|DEBUG)\](?: \[[^\]]*\])?: ?(.*)$',
);
final _lagRe = RegExp(r"Can't keep up!.*Running (\d+)ms");
final _joinRe = RegExp(r'^\.?\w+ (joined|left) the game$');

/// Riga del server → riga della console (livello e colore dal log).
ConsoleEntry classifyLine(ServerLine l) {
  final m = _lineRe.firstMatch(l.text);
  if (m == null) {
    return ConsoleEntry(
      at: l.at,
      kind: l.stderr ? ConsoleKind.err : ConsoleKind.info,
      level: l.stderr ? 'ERR' : '',
      text: l.text,
    );
  }
  final body = m[2]!;
  final (kind, level) = switch (m[1]) {
    'WARN' || 'WARNING' => (ConsoleKind.warn, 'WARN'),
    'ERROR' || 'FATAL' => (ConsoleKind.err, 'ERR'),
    'DEBUG' => (ConsoleKind.dim, 'DEBUG'),
    _ when _joinRe.hasMatch(body) => (ConsoleKind.join, 'JOIN'),
    _ => (ConsoleKind.info, 'INFO'),
  };
  return ConsoleEntry(at: l.at, kind: kind, level: level, text: body);
}

/// Salvataggio arrivato sull'hub.
@immutable
final class SavedInfo {
  const SavedInfo(this.n, this.at);
  final int n;
  final DateTime at;
}

/// Caricamento in corso (byte).
@immutable
final class UploadInfo {
  const UploadInfo({required this.done, required this.total, required this.bytesPerSecond});
  final int done;
  final int total;
  final int bytesPerSecond;
  double get fraction => total == 0 ? 0 : (done / total).clamp(0, 1);

  /// Secondi che mancano, null se non si sa.
  int? get secondsLeft =>
      bytesPerSecond <= 0 ? null : ((total - done) / bytesPerSecond).ceil().clamp(0, 1 << 30);
}

/// Come è partito il server (pannello "Server").
@immutable
final class LaunchInfo {
  const LaunchInfo({
    required this.label,
    this.javaVersion,
    this.xmxMiB,
    this.port,
    this.maxPlayers,
  });
  final String label;
  final String? javaVersion;
  final int? xmxMiB;
  final int? port;
  final int? maxPlayers;
}

/// Il server si è chiuso da solo.
@immutable
final class CrashInfo {
  const CrashInfo({
    required this.at,
    required this.exitCode,
    required this.restarting,
    required this.attempt,
    required this.maxAttempts,
    required this.lastErrors,
    this.savedN,
  });
  final DateTime at;
  final int? exitCode;
  final bool restarting;

  /// Tentativo di riavvio in corso (1-based).
  final int attempt;
  final int maxAttempts;

  /// Ultime righe d'errore della console.
  final List<String> lastErrors;

  /// Versione salvata sull'hub subito dopo il crash, se nota.
  final int? savedN;

  /// Sembra memoria finita.
  bool get outOfMemory => lastErrors.any((l) => l.contains('OutOfMemoryError'));
}

/// Avviso che non ferma la sessione (codici di [SessionWarning]).
@immutable
final class SessionNoticeEntry {
  const SessionNoticeEntry(this.at, this.code, {this.paths = const [], this.n});
  final DateTime at;
  final String code;
  final List<String> paths;
  final int? n;
}

/// Domanda all'utente durante l'avvio.
enum SessionPrompt { eula }

/// Scelta davanti alle modifiche locali divergenti.
enum ConflictChoice {
  /// Versione dell'hub, con copia di sicurezza dei file toccati.
  useHub,

  /// Le mie come nuova versione per tutti (l'hub la tiene nella storia).
  keepMine,
  cancel,
}

/// Fatto da segnalare (notifiche del desktop, toast, dialoghi).
sealed class SessionSignal {
  const SessionSignal();
}

final class SignalSaved extends SessionSignal {
  const SignalSaved(this.n);
  final int n;
}

final class SignalCrashed extends SessionSignal {
  const SignalCrashed(this.crash);
  final CrashInfo crash;
}

/// Avviso grave: `lockLost`, `spaceGone`, `hubDiskFull`.
final class SignalAlert extends SessionSignal {
  const SignalAlert(this.kind);
  final String kind;
}

final class SignalHubLost extends SessionSignal {
  const SignalHubLost();
}

/// L'hub è tornato e ha ricevuto [n].
final class SignalHubBack extends SessionSignal {
  const SignalHubBack(this.n);
  final int n;
}

final class SignalEnded extends SessionSignal {
  const SignalEnded({required this.ok});
  final bool ok;
}

// --- controller -------------------------------------------------------------------

/// Sessione di gioco su un server, per l'interfaccia.
final class SessionController extends ChangeNotifier {
  SessionController({
    required this.client,
    required this.space,
    required this.name,
    required this.folder,
    this.env = const SessionEnv(),
    this.processEnv = const {},
    ServerPrefs prefs = const ServerPrefs(),
    this.uploadLimit = 0,
    this.me,
    DateTime Function()? clock,
  }) : _prefs = prefs,
       _autostopOverride = prefs.autostop,
       _now = clock ?? DateTime.now;

  final HubClient client;
  final String space;

  /// Nome del server mostrato.
  final String name;
  final String folder;
  final SessionEnv env;
  final Map<String, String> processEnv;

  /// Nome di chi ospita (per l'elenco dei giocatori).
  final String? me;
  final DateTime Function() _now;
  ServerPrefs _prefs;

  /// Ora corrente (sostituibile nei test e nelle anteprime).
  DateTime now() => _now();

  /// Limite di banda dei salvataggi in background (byte/s, 0 = nessuno).
  int uploadLimit;

  /// Parametri della sessione: quelli dell'hub per questo server appena la
  /// sessione li ha letti, prima i default (o quelli dei test).
  SessionConfig get config => _session?.config ?? env.config ?? const SessionConfig();

  Session? _session;
  SyncEngine? _engine;
  StreamSubscription<SessionEvent>? _sub;
  bool _disposed = false;

  SessionPhase _phase = SessionPhase.syncing;
  SessionPhase get phase => _phase;

  /// La sessione è viva (c'è o ci sarà un server su questo PC).
  bool get active => switch (_phase) {
    SessionPhase.syncing ||
    SessionPhase.starting ||
    SessionPhase.running ||
    SessionPhase.saving ||
    SessionPhase.stopping ||
    SessionPhase.finalPush => true,
    _ => false,
  };

  /// Errore che ha impedito la sessione o l'ha chiusa.
  Object? _error;
  Object? get error => _error;

  SyncException? _conflict;

  /// Modifiche locali divergenti (fase [SessionPhase.conflict]).
  SyncException? get conflict => _conflict;

  SessionPrompt? _prompt;
  Completer<bool>? _promptAnswer;

  /// Domanda in attesa di risposta ([answerPrompt]).
  SessionPrompt? get prompt => _prompt;

  DateTime? _startedAt;

  /// Quando si è premuto Gioca.
  DateTime? get startedAt => _startedAt;
  DateTime? _runningSince;
  DateTime? get runningSince => _runningSince;
  DateTime? _endedAt;
  DateTime? get endedAt => _endedAt;

  final _players = <String, DateTime>{};

  /// Giocatori online con l'ora di ingresso.
  Map<String, DateTime> get players => UnmodifiableMapView(_players);
  final _seen = <String>{};

  /// Chi è entrato almeno una volta.
  Set<String> get seenPlayers => Set.unmodifiable(_seen);

  final List<ConsoleEntry> _console = [];

  /// Righe della console, dalla più vecchia (lista che cresce).
  List<ConsoleEntry> get console => _console;
  final _history = <String>[];

  /// Comandi inviati, dal più vecchio.
  List<String> get commandHistory => List.unmodifiable(_history);

  SavedInfo? _saved;
  SavedInfo? get lastSaved => _saved;
  int _savedCount = 0;

  /// Salvataggi arrivati sull'hub in questa sessione.
  int get savedCount => _savedCount;

  UploadInfo? _upload;
  UploadInfo? get upload => _upload;
  DateTime? _uploadStart;
  int? _measured;

  /// Velocità di caricamento misurata senza limite (byte/s).
  int? get measuredUploadBps => _measured;

  LaunchInfo? _launch;
  LaunchInfo? get launchInfo => _launch;

  List<String> _addresses = const [];

  /// Indirizzi IPv4 di questo PC.
  List<String> get addresses => _addresses;

  CrashInfo? _crash;

  /// Ultimo crash (resta finché non si riavvia con successo).
  CrashInfo? get crash => _crash;
  int _crashes = 0;

  final _alerts = <String>{};

  /// Avvisi gravi: `lockLost`, `spaceGone`, `hubDiskFull`.
  Set<String> get alerts => Set.unmodifiable(_alerts);
  DateTime? _alertAt;
  DateTime? get alertAt => _alertAt;

  bool _hubLost = false;

  /// L'hub non risponde ai caricamenti: il gioco continua in locale.
  bool get hubUnreachable => _hubLost;

  int? _lagMs;
  DateTime? _lagAt;

  /// Dopo l'avvio, per quanto il ritardo del server non si segnala.
  static const lagGrace = Duration(minutes: 2);

  /// Ritardo del server se segnalato negli ultimi 2 minuti.
  int? get lagMs =>
      _lagAt != null && _now().difference(_lagAt!) < const Duration(minutes: 2) ? _lagMs : null;

  final _notices = <SessionNoticeEntry>[];

  /// Avvisi recenti, il più nuovo per primo.
  List<SessionNoticeEntry> get notices => _notices.reversed.toList();

  final _signals = StreamController<SessionSignal>.broadcast();

  /// Fatti da segnalare all'utente.
  Stream<SessionSignal> get signals => _signals.stream;

  Completer<void> _done = Completer<void>();

  /// Completa quando la sessione è finita (anche con errore o conflitto).
  Future<void> get done => _done.future;

  /// Scelta locale sullo spegnimento automatico (preferenza del server su
  /// questo PC, o l'interruttore della sessione); null = quella dell'hub.
  bool? _autostopOverride;

  /// Spegnimento automatico in uso: la scelta locale se c'è, altrimenti
  /// quella dell'hub per questo server.
  bool get autostop => _autostopOverride ?? config.autostop;

  /// Cambia lo spegnimento automatico per questa sessione soltanto.
  set autostop(bool v) {
    _autostopOverride = v;
    _session?.autostop = v;
    _notify();
  }

  ServerPrefs get prefs => _prefs;

  /// Ora del prossimo salvataggio automatico, se si sta giocando.
  DateTime? get nextSaveAt {
    final since = _runningSince;
    if (since == null || !(phase == SessionPhase.running || phase == SessionPhase.saving)) {
      return null;
    }
    final planned = _session?.nextAutosave;
    if (planned != null) return planned;
    final every = config.autosaveEvery;
    final elapsed = _now().difference(since);
    final k = elapsed.inMicroseconds ~/ every.inMicroseconds + 1;
    return since.add(every * k);
  }

  // --- avvio --------------------------------------------------------------------

  /// Avvia la sessione. Con [force] prende il lock anche se un altro lo
  /// tiene (doppia conferma nell'interfaccia).
  Future<void> start({bool force = false}) async {
    _startedAt ??= _now();
    if (force) {
      // si libera il lock senza prenderlo: prenderlo per gioco e rilasciarlo
      // lascerebbe nella Storia una partita di 0 s
      try {
        await client.forceReleaseLock(space);
      } on Object catch (e) {
        _fail(e);
        return;
      }
    }
    unawaited(_loadAddresses());
    await _attempt(discardLocal: false);
  }

  Future<void> _loadAddresses() async {
    try {
      final f = env.addresses ?? _localAddresses;
      _addresses = await f();
      _session?.address = _addresses.firstOrNull;
      _notify();
    } on Object {
      // senza indirizzi si mostra solo la porta
    }
  }

  static Future<List<String>> _localAddresses() async {
    final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
    return [
      for (final i in ifs)
        for (final a in i.addresses)
          if (!a.isLoopback && !a.isLinkLocal) a.address,
    ];
  }

  LockInfo _lockInfo(String action) =>
      LockInfo(client: 'minesync/$appVersion', action: action, players: const []);

  SyncEngine _makeEngine() =>
      SyncEngine(client, space, folder, pool: env.pool, onProgress: _onProgress)
        ..uploadLimit = uploadLimit;

  Future<void> _attempt({required bool discardLocal}) async {
    _setPhase(SessionPhase.syncing);
    _error = null;
    _conflict = null;
    if (_done.isCompleted) _done = Completer<void>();
    final engine = _engine = _makeEngine();
    final s = _session = Session(
      engine: engine,
      launch: _launchServer,
      parse: minecraftParse,
      config: config,
      // salvataggio automatico, spegnimento e riavvii come li vuole l'hub
      followHub: true,
      clientVersion: appVersion,
      address: _addresses.firstOrNull,
    )..autostopOverride = _autostopOverride;
    await _sub?.cancel();
    _sub = s.events.listen(_onEvent);
    try {
      await s.run(discardLocal: discardLocal);
      _endedAt = _now();
      _setPhase(s.state == SessionState.ended ? SessionPhase.ended : SessionPhase.failed);
      _signal(SignalEnded(ok: s.state == SessionState.ended));
    } on SyncException catch (e) {
      if (e.kind == SyncErrorKind.dirtyLocal) {
        _conflict = e;
        _setPhase(SessionPhase.conflict);
      } else {
        _fail(e);
      }
    } on Object catch (e) {
      _fail(e);
    }
    if (_phase != SessionPhase.conflict && !_done.isCompleted) _done.complete();
    _notify();
  }

  void _fail(Object e) {
    _error = e;
    _endedAt = _now();
    _setPhase(SessionPhase.failed);
    _signal(const SignalEnded(ok: false));
    if (!_done.isCompleted) _done.complete();
  }

  /// Avvio del server come `minesync play`: rilevamento, EULA (chiesta
  /// all'utente), porta, Java, comando e guard.
  Future<ServerProcess> _launchServer() async {
    final layout = detectServer(folder);
    if (layout.launch == null) throw const NoLaunchFound();
    if (!isEulaAccepted(layout.workDir)) {
      if (!await _ask(SessionPrompt.eula)) throw const EulaDeclined();
      await acceptEula(layout.workDir);
    }
    final props = readServerProperties(layout.workDir);
    final port = serverPort(props) ?? 25565;
    _session?.port = port;
    JavaRuntime? java;
    final manual = _prefs.javaPath;
    if (manual != null) {
      java = await probeJava(manual);
    } else {
      final find = env.findJava ?? ((root) => findJavaRuntimes(serverRoot: root, env: processEnv));
      java = pickJava(await find(layout.workDir), layout.requiredJavaMajor);
    }
    final needsJava = layout.launch is! ScriptLaunch;
    if (needsJava && java == null) throw JavaMissing(layout.requiredJavaMajor);
    final cmd = buildLaunch(layout, java: java, xmxMiB: _prefs.xmxMiB, baseEnv: processEnv);
    _launch = LaunchInfo(
      label: layout.label,
      javaVersion: java?.version,
      xmxMiB: _prefs.xmxMiB,
      port: port,
      maxPlayers: int.tryParse(props['max-players'] ?? ''),
    );
    _addNote(ConsoleNote.starting, [layout.label, java?.version, _prefs.xmxMiB]);
    final start = env.start ?? _guardStart;
    return start(cmd);
  }

  Future<ServerProcess> _guardStart(LaunchCommand cmd) async {
    final guard = guardCommand(processEnv);
    if (guard == null) throw const GuardMissing();
    return GuardServerProcess.start(guard, cmd);
  }

  Future<bool> _ask(SessionPrompt p) {
    final c = _promptAnswer = Completer<bool>();
    _prompt = p;
    _notify();
    return c.future;
  }

  /// Risponde alla domanda in attesa ([prompt]).
  void answerPrompt(bool yes) {
    final c = _promptAnswer;
    _prompt = null;
    _promptAnswer = null;
    if (c != null && !c.isCompleted) c.complete(yes);
    _notify();
  }

  /// Scelta davanti alle modifiche locali divergenti.
  Future<void> resolveConflict(ConflictChoice choice) async {
    if (_phase != SessionPhase.conflict) return;
    switch (choice) {
      case ConflictChoice.cancel:
        _conflict = null;
        _endedAt = _now();
        _setPhase(SessionPhase.cancelled);
        if (!_done.isCompleted) _done.complete();
        _notify();
      case ConflictChoice.useHub:
        await _attempt(discardLocal: true);
      case ConflictChoice.keepMine:
        _setPhase(SessionPhase.syncing);
        try {
          await _keepMine();
        } on Object catch (e) {
          _fail(e);
          _notify();
          return;
        }
        await _attempt(discardLocal: false);
    }
  }

  /// Le modifiche locali diventano una nuova versione sopra la testa
  /// dell'hub: la base locale passa alla testa (i file restano quelli di
  /// questo PC) e si carica. La testa precedente resta nella storia.
  Future<void> _keepMine() async {
    final lock = await client.acquireLock(space, _lockInfo('push'));
    try {
      final engine = _makeEngine();
      final head = (await client.space(space)).summary.head;
      final local = LocalState(folder);
      await local.clearPullTarget();
      await engine.clearOutbox();
      if (head != null) {
        final g = await client.generation(space, n: head.n);
        await local.saveBase(Base(space, g.n, g.digest, g.manifest));
      }
      await engine.push(lock: lock, message: 'local changes kept over #${head?.n ?? 0}');
      _notices.add(SessionNoticeEntry(_now(), 'keptMine', n: head?.n));
    } finally {
      try {
        await client.releaseLock(space, lock.token);
      } on Object {
        // scade da solo
      }
    }
  }

  // --- comandi --------------------------------------------------------------------

  /// Salvataggio chiesto dall'utente.
  SaveRequest saveNow() => _session?.saveNow() ?? SaveRequest.notRunning;

  /// Arresto pulito (salva, carica, libera il server).
  Future<void> stop() async {
    _addNote(ConsoleNote.stopping, const []);
    await _session?.stop();
  }

  /// Arresto pulito e attesa della fine, al massimo [max]. Vero se la
  /// sessione è finita in tempo.
  Future<bool> stopAndWait({Duration max = const Duration(seconds: 60)}) async {
    if (!active) return true;
    unawaited(stop());
    try {
      await done.timeout(max);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  /// Comando per il server; `stop` è l'arresto pulito.
  Future<void> send(String command) async {
    final c = command.trim();
    if (c.isEmpty) return;
    if (_history.isEmpty || _history.last != c) _history.add(c);
    if (c != 'stop') {
      _console.add(ConsoleEntry(at: _now(), kind: ConsoleKind.cmd, level: 'CMD', text: '> $c'));
      _notify();
    }
    await _session?.send(c);
  }

  /// Preferenze del server cambiate durante la sessione (valgono dal
  /// prossimo avvio, tranne lo spegnimento automatico).
  void updatePrefs(ServerPrefs p) {
    _prefs = p;
    final a = p.autostop;
    if (a != null) autostop = a;
  }

  /// Nuovo limite di banda (vale dal prossimo caricamento).
  void setUploadLimit(int bytesPerSecond) {
    uploadLimit = bytesPerSecond;
    _engine?.uploadLimit = bytesPerSecond;
  }

  // --- eventi ---------------------------------------------------------------------

  void _onEvent(SessionEvent e) {
    switch (e) {
      case StateChanged(:final state):
        _onState(state);
      case LineReceived(:final line):
        final entry = classifyLine(line);
        _console.add(entry);
        final lag = _lagRe.firstMatch(line.text);
        // nei primi minuti un server con molte mod carica il mondo e resta
        // indietro: è normale, non è un problema da segnalare
        final since = _runningSince;
        final settled =
            since != null && phase == SessionPhase.running && _now().difference(since) >= lagGrace;
        if (lag != null && settled) {
          _lagMs = int.parse(lag[1]!);
          _lagAt = _now();
        }
        _trimConsole();
      case PlayersChanged(:final players):
        final now = _now();
        _players.removeWhere((k, _) => !players.contains(k));
        for (final p in players) {
          _players.putIfAbsent(p, () => now);
          _seen.add(p);
        }
        _session?.address ??= _addresses.firstOrNull;
      case SavedToHub(:final generation, :final at):
        _saved = SavedInfo(generation, at);
        _savedCount++;
        _upload = null;
        _addNote(ConsoleNote.uploaded, [generation]);
        if (_hubLost) {
          _hubLost = false;
          _signal(SignalHubBack(generation));
        }
        _signal(SignalSaved(generation));
      case SessionWarning(:final code, :final cause, :final paths):
        _notices.add(SessionNoticeEntry(_now(), code, paths: paths));
        while (_notices.length > 20) {
          _notices.removeAt(0);
        }
        if (code == 'uploadFailed' || code == 'finalPushFailed') _upload = null;
        if (cause is HubUnreachable || cause is TransferStalled) {
          if (!_hubLost) {
            _hubLost = true;
            _signal(const SignalHubLost());
          }
        }
      case SessionAlert(:final kind):
        if (_alerts.add(kind)) {
          _alertAt = _now();
          _signal(SignalAlert(kind));
        }
      case ServerCrashed(:final exitCode, :final restarting):
        _crashes++;
        final errs = [
          for (final l in _console.reversed.where((l) => l.kind == ConsoleKind.err).take(3)) l.text,
        ].reversed.toList();
        _crash = CrashInfo(
          at: _now(),
          exitCode: exitCode,
          restarting: restarting,
          attempt: _crashes,
          maxAttempts: config.maxRestarts,
          lastErrors: errs,
          savedN: _saved?.n,
        );
        _addNote(ConsoleNote.crashed, [exitCode]);
        _signal(SignalCrashed(_crash!));
      case TransferProgress() || SettingsApplied():
        break;
    }
    _notify();
  }

  void _onState(SessionState s) {
    switch (s) {
      case SessionState.syncing || SessionState.idle:
        _setPhase(SessionPhase.syncing);
      case SessionState.starting:
        _setPhase(SessionPhase.starting);
      case SessionState.running:
        if (_phase == SessionPhase.starting) {
          _runningSince = _now();
          _addNote(ConsoleNote.ready, const []);
        } else if (_phase == SessionPhase.saving) {
          _addNote(ConsoleNote.autosaved, const []);
        }
        _setPhase(SessionPhase.running);
      case SessionState.saving:
        _setPhase(SessionPhase.saving);
      case SessionState.stopping:
        _setPhase(SessionPhase.stopping);
      case SessionState.finalPush:
        _setPhase(SessionPhase.finalPush);
      case SessionState.ended || SessionState.failed:
        // la fase finale si decide quando run() restituisce
        break;
    }
  }

  void _onProgress(SyncProgress p) {
    if (p.phase == 'upload' && p.total > 0) {
      final now = _now();
      _uploadStart ??= now;
      final secs = now.difference(_uploadStart!).inMilliseconds / 1000;
      final bps = secs <= 0 ? 0 : (p.done / secs).round();
      _upload = UploadInfo(done: p.done, total: p.total, bytesPerSecond: bps);
      // misura utile solo senza limite e su un caricamento non minuscolo
      if (uploadLimit == 0 && p.done >= 1 << 20 && secs >= 1) _measured = bps;
      _notify();
    } else if (p.phase == 'commit' || p.phase == 'scan') {
      _uploadStart = null;
      if (p.phase == 'commit') _upload = null;
      _notify();
    }
  }

  void _addNote(ConsoleNote n, List<Object?> args) {
    final kind = switch (n) {
      ConsoleNote.starting || ConsoleNote.stopping => ConsoleKind.dim,
      ConsoleNote.crashed => ConsoleKind.err,
      _ => ConsoleKind.ok,
    };
    _console.add(ConsoleEntry(at: _now(), kind: kind, level: 'MS', note: n, args: args));
    _trimConsole();
    _notify();
  }

  void _trimConsole() {
    final max = config.consoleLines;
    if (_console.length > max + 200) _console.removeRange(0, _console.length - max);
  }

  void _setPhase(SessionPhase p) {
    if (_phase == p) return;
    _phase = p;
    if (p == SessionPhase.running) _crash = null;
    _notify();
  }

  void _signal(SessionSignal s) {
    if (!_signals.isClosed) _signals.add(s);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Per le anteprime e i test delle schermate: imposta lo stato a mano.
  @visibleForTesting
  void debugSet({
    SessionPhase? phase,
    DateTime? startedAt,
    DateTime? runningSince,
    Map<String, DateTime>? players,
    List<ConsoleEntry>? console,
    SavedInfo? saved,
    UploadInfo? upload,
    LaunchInfo? launch,
    List<String>? addresses,
    Set<String>? alerts,
    DateTime? alertAt,
    bool? hubUnreachable,
    int? lagMs,
    List<SessionNoticeEntry>? notices,
    Object? error,
    SyncException? conflict,
    CrashInfo? crash,
    SessionPrompt? prompt,
  }) {
    if (phase != null) _phase = phase;
    if (startedAt != null) _startedAt = startedAt;
    if (runningSince != null) _runningSince = runningSince;
    if (players != null) {
      _players
        ..clear()
        ..addAll(players);
      _seen.addAll(players.keys);
    }
    if (console != null) {
      _console
        ..clear()
        ..addAll(console);
    }
    if (saved != null) _saved = saved;
    _upload = upload ?? _upload;
    if (launch != null) _launch = launch;
    if (addresses != null) _addresses = addresses;
    if (alerts != null) _alerts.addAll(alerts);
    if (alertAt != null) _alertAt = alertAt;
    if (hubUnreachable != null) _hubLost = hubUnreachable;
    if (lagMs != null) {
      _lagMs = lagMs;
      _lagAt = _now();
    }
    if (notices != null) _notices.addAll(notices.reversed);
    if (error != null) _error = error;
    if (conflict != null) _conflict = conflict;
    if (crash != null) _crash = crash;
    if (prompt != null) _prompt = prompt;
    _notify();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _sub?.cancel();
    _signals.close();
    final c = _promptAnswer;
    if (c != null && !c.isCompleted) c.complete(false);
    super.dispose();
  }
}
