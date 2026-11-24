// Sessione di gioco: chi ospita prende il lock, porta la copia locale alla
// testa dell'hub, avvia il server, salva periodicamente sull'hub senza
// fermare il gioco e alla fine carica lo stato e rilascia il lock.
//
// Salvataggio automatico: save-off → save-all flush → conferma del server →
// attesa che i file si fermino → istantanea nell'outbox → save-on, subito;
// il caricamento verso l'hub avviene dopo, in background, e non si
// sovrappone mai al ciclo successivo.
import 'dart:async';
import 'dart:collection';

import 'package:ms_core/ms_core.dart';
import 'package:ms_protocol/ms_protocol.dart';

import 'server_process.dart';

/// Stato della sessione.
enum SessionState {
  idle,

  /// Lock, caricamento delle modifiche lasciate in sospeso, pull.
  syncing,

  /// Server avviato, in attesa di "Done".
  starting,
  running,

  /// Ciclo di salvataggio (server in save-off).
  saving,
  stopping,

  /// Caricamento finale sull'hub.
  finalPush,
  ended,
  failed,
}

/// Eventi per le interfacce.
sealed class SessionEvent {
  const SessionEvent();
}

final class StateChanged extends SessionEvent {
  const StateChanged(this.state);
  final SessionState state;
}

final class LineReceived extends SessionEvent {
  const LineReceived(this.line);
  final ServerLine line;
}

final class PlayersChanged extends SessionEvent {
  const PlayersChanged(this.players);
  final Set<String> players;
}

/// Stato salvato sull'hub: generazione e ora dell'istantanea.
final class SavedToHub extends SessionEvent {
  const SavedToHub(this.generation, this.at);
  final int generation;
  final DateTime at;
}

/// Problema che non ferma la sessione (salvataggio saltato, hub non
/// raggiungibile, file illeggibili...). [code] è stabile, [cause] per i log.
final class SessionWarning extends SessionEvent {
  const SessionWarning(this.code, {this.cause, this.paths = const []});
  final String code;
  final Object? cause;
  final List<String> paths;
}

/// Problema grave e persistente da mostrare finché la sessione dura.
final class SessionAlert extends SessionEvent {
  const SessionAlert(this.kind);

  /// `lockLost`, `spaceGone`, `hubDiskFull`.
  final String kind;
}

final class ServerCrashed extends SessionEvent {
  const ServerCrashed(this.exitCode, {required this.restarting});
  final int? exitCode;
  final bool restarting;
}

final class TransferProgress extends SessionEvent {
  const TransferProgress(this.progress);
  final SyncProgress progress;
}

/// Esito di una richiesta di salvataggio manuale.
enum SaveRequest { started, queued, notRunning }

/// Le impostazioni `sessions` dell'hub sono cambiate (lette all'avvio e a
/// ogni salvataggio automatico, con [Session.followHub]).
final class SettingsApplied extends SessionEvent {
  const SettingsApplied(this.config);
  final SessionConfig config;
}

/// Parametri della sessione. I default sono quelli di fabbrica dell'hub
/// (Admin › Sessioni, [SessionSettings]); con [Session.followHub] la
/// sessione usa quelli effettivi dello spazio.
final class SessionConfig {
  const SessionConfig({
    this.autosaveEvery = const Duration(minutes: 5),
    this.emptyStopAfter = const Duration(minutes: 30),
    this.autostop = true,
    this.maxRestarts = 2,
    this.flushWait = const Duration(seconds: 60),
    this.quietStable = const Duration(seconds: 1),
    this.quietCap = const Duration(seconds: 15),
    this.consoleLines = 2000,
    this.uploadRetry = const Duration(seconds: 15),
  });

  final Duration autosaveEvery;

  /// Spegnimento dopo tanto tempo senza giocatori; null = mai.
  final Duration? emptyStopAfter;

  /// Spegnimento automatico acceso di default (la sessione può cambiarlo
  /// in corsa, vedi [Session.autostop]).
  final bool autostop;

  /// Riavvii automatici dopo un crash.
  final int maxRestarts;

  /// Questa configurazione con i valori `sessions` dell'hub (salvataggio
  /// automatico, spegnimento, riavvii); il resto resta com'è.
  SessionConfig withHub(SessionSettings s) => SessionConfig(
    autosaveEvery: Duration(minutes: s.autosaveMinutes),
    emptyStopAfter: Duration(minutes: s.autostopMinutes),
    autostop: s.autostop,
    maxRestarts: s.crashRestarts,
    flushWait: flushWait,
    quietStable: quietStable,
    quietCap: quietCap,
    consoleLines: consoleLines,
    uploadRetry: uploadRetry,
  );

  /// Stessi valori che contano per chi gioca.
  bool sameAs(SessionConfig o) =>
      autosaveEvery == o.autosaveEvery &&
      emptyStopAfter == o.emptyStopAfter &&
      autostop == o.autostop &&
      maxRestarts == o.maxRestarts;

  /// Attesa della conferma del salvataggio, riarmata a ogni riga del server.
  final Duration flushWait;

  /// I file devono restare fermi così a lungo prima dell'istantanea.
  final Duration quietStable;
  final Duration quietCap;

  /// Righe di console tenute in memoria per chi apre la vista dopo.
  final int consoleLines;

  /// Dopo un caricamento fallito perché l'hub non risponde, ogni quanto si
  /// riprova l'istantanea in attesa (senza aspettare il salvataggio dopo).
  final Duration uploadRetry;
}

/// Sessione di gioco su uno spazio.
final class Session {
  Session({
    required this.engine,
    required this.launch,
    required this.parse,
    this.config = const SessionConfig(),
    this.followHub = false,
    this.clientVersion = '0.1.0',
    this.address,
    this.port,
  });

  final SyncEngine engine;
  final ServerLauncher launch;
  final LineParser parse;

  /// Parametri in uso. Con [followHub] cambiano quando l'hub dice altro.
  SessionConfig config;

  /// Usa le impostazioni `sessions` effettive dello spazio (`GET
  /// /spaces/{id}`), lette all'avvio e dopo ogni salvataggio automatico.
  final bool followHub;
  final String clientVersion;
  String? address;

  /// Porta del server per i giocatori (si sa dopo il pull, da
  /// server.properties).
  int? port;

  HubClient get _client => engine.client;
  String get _space => engine.space;

  final _events = StreamController<SessionEvent>.broadcast();
  Stream<SessionEvent> get events => _events.stream;

  SessionState _state = SessionState.idle;
  SessionState get state => _state;

  final Set<String> _players = SplayTreeSet<String>();
  Set<String> get players => Set.unmodifiable(_players);

  /// Ultime righe della console.
  final console = ListQueue<ServerLine>();

  /// Scelta locale sullo spegnimento automatico per questa sessione; null =
  /// quella di [config] (cioè dell'hub con [followHub]).
  bool? autostopOverride;

  /// Spegnimento automatico quando il server è vuoto (modificabile in corsa:
  /// assegnarlo vale come scelta locale e vince sull'hub).
  bool get autostop => autostopOverride ?? config.autostop;
  set autostop(bool v) => autostopOverride = v;

  DateTime? _nextAutosave;

  /// Quando scatta il prossimo salvataggio automatico (null se il server
  /// non è in gioco).
  DateTime? get nextAutosave => _nextAutosave;

  LockGrant? _lock;
  final _lockCt = CancelToken();
  LockKeeper? _keeper;
  Exclusions _ex = Exclusions(const []);
  ServerProcess? _proc;
  bool _stopRequested = false;
  bool _serverStopping = false;
  String? _lockProblem;
  int _restarts = 0;
  Timer? _autosaveTimer;
  Timer? _emptyTimer;

  /// Nuovo tentativo di caricare l'istantanea in attesa (hub irraggiungibile).
  Timer? _retryTimer;

  bool _saving = false;
  bool _manualQueued = false;
  Completer<void>? _upload;
  CancelToken? _uploadCt;
  Completer<bool>? _flush;
  DateTime _lastLine = DateTime.now();

  void _emit(SessionEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  void _setState(SessionState s) {
    if (_state == s) return;
    _state = s;
    _emit(StateChanged(s));
  }

  LockInfo _info() => LockInfo(
    client: 'minesync/$clientVersion',
    action: 'play',
    players: _players.toList(),
    port: port,
    address: address,
  );

  /// Esegue l'intera sessione. Restituisce quando è finita; lancia se non è
  /// potuta partire (lock di un altro, modifiche locali divergenti...).
  Future<void> run({bool discardLocal = false}) async {
    _setState(SessionState.syncing);
    try {
      _lock = await _client.acquireLock(_space, _info());
    } on Object {
      _setState(SessionState.failed);
      rethrow;
    }
    _keeper = LockKeeper(_client, _space, _lock!, cancel: _lockCt, info: _info)..start();
    _lockCt.onCancel(() => _onLockProblem(_lockCt.reason));
    var failed = false;
    try {
      await _preSync(discardLocal);
      await _runServer();
      if (_lockProblem == null) await _finalPush();
    } on Object {
      failed = true;
      rethrow;
    } finally {
      _stopAutosave();
      _emptyTimer?.cancel();
      _keeper?.stop();
      if (_lockProblem == null) {
        try {
          await _client.releaseLock(_space, _lock!.token);
        } on Object {
          // scade da solo
        }
      }
      _setState(failed || _crashedOut ? SessionState.failed : SessionState.ended);
      await _events.close();
    }
  }

  bool _crashedOut = false;

  /// Prima del gioco: istantanea rimasta in sospeso, modifiche locali non
  /// divergenti (caricate), poi pull della testa.
  Future<void> _preSync(bool discardLocal) async {
    final d = await _client.space(_space);
    _ex = Exclusions(d.exclusions);
    _applyHub(d);
    try {
      await engine.pushSnapshot(lock: _lock!, keepAlive: false);
    } on SyncException catch (e) {
      if (e.kind != SyncErrorKind.staleBase && e.kind != SyncErrorKind.snapshotStale) rethrow;
    }
    try {
      await engine.pull(discardLocal: discardLocal);
    } on SyncException catch (e) {
      if (e.kind != SyncErrorKind.dirtyLocal || e.diverged) rethrow;
      // l'ultimo caricamento non era arrivato: lo si fa adesso
      await engine.push(lock: _lock!, keepAlive: false, message: AutoMessage.recovered);
      await engine.pull();
    }
  }

  Future<void> _runServer() async {
    while (true) {
      _setState(SessionState.starting);
      _serverStopping = false;
      final proc = _proc = await launch();
      final done = Completer<void>();
      final sub = proc.lines.listen(_onLine, onDone: done.complete);
      final end = await proc.exit;
      await done.future.timeout(const Duration(seconds: 5), onTimeout: () {});
      await sub.cancel();
      _stopAutosave();
      _emptyTimer?.cancel();
      _flush?.complete(false);
      if (_players.isNotEmpty) {
        _players.clear();
        _emit(PlayersChanged(players));
      }
      if (_stopRequested || _lockProblem != null) return;
      // /stop dato da un operatore dentro il gioco: arresto voluto, non crash
      if (_serverStopping && end.exitCode == 0) return;

      // crash: si mette al sicuro lo stato attuale, poi si riavvia se si può
      final restarting = _restarts < config.maxRestarts;
      _emit(ServerCrashed(end.exitCode, restarting: restarting));
      await _cancelUpload();
      try {
        await engine.clearOutbox();
        await engine.push(lock: _lock!, keepAlive: false, message: AutoMessage.afterCrash);
      } on Object catch (e) {
        _emit(SessionWarning('pushAfterCrashFailed', cause: e));
      }
      if (!restarting || _lockProblem != null) {
        _crashedOut = true;
        return;
      }
      _restarts++;
    }
  }

  void _onLine(ServerLine l) {
    _lastLine = l.at;
    console.add(l);
    while (console.length > config.consoleLines) {
      console.removeFirst();
    }
    _emit(LineReceived(l));
    final f = parse(l.text);
    switch (f) {
      case FactStarted():
        _setState(SessionState.running);
        _armAutosave();
        _armEmpty();
      case FactJoined(:final name):
        if (_players.add(name)) _emit(PlayersChanged(players));
        _emptyTimer?.cancel();
      case FactLeft(:final name):
        if (_players.remove(name)) _emit(PlayersChanged(players));
        _armEmpty();
      case FactSaved():
        final c = _flush;
        if (c != null && !c.isCompleted) c.complete(true);
      case FactStopping():
        _serverStopping = true;
        _setState(SessionState.stopping);
      case null:
        break;
    }
  }

  void _armEmpty() {
    final after = config.emptyStopAfter;
    if (after == null || _players.isNotEmpty) return;
    _emptyTimer?.cancel();
    _emptyTimer = Timer(after, () {
      if (autostop && _players.isEmpty && _state == SessionState.running) {
        _emit(const SessionWarning('autostop'));
        unawaited(stop());
      }
    });
  }

  void _stopAutosave() {
    _autosaveTimer?.cancel();
    _autosaveTimer = null;
    _nextAutosave = null;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  /// L'hub non rispondeva durante un salvataggio: ogni [SessionConfig.uploadRetry]
  /// lo si sonda con una richiesta leggera e, appena risponde, si carica
  /// l'istantanea rimasta in attesa (o se ne fa una nuova). Così il
  /// salvataggio arriva quando l'hub torna, non a quello automatico dopo, e
  /// finché l'hub è giù il server non viene disturbato.
  void _armRetry([DateTime? at]) {
    _retryTimer?.cancel();
    _retryTimer = Timer(config.uploadRetry, () async {
      _retryTimer = null;
      if (_stopRequested || _lockProblem != null) return;
      try {
        await _client.space(_space);
      } on Object {
        _armRetry(at);
        return;
      }
      if (_stopRequested || _lockProblem != null || _retryTimer != null) return;
      if (_state != SessionState.running || _saving || _upload != null) return;
      if (engine.state.loadPending(_space) != null) {
        _startUpload(at ?? DateTime.now());
      } else {
        unawaited(_saveCycle());
      }
    });
  }

  static bool _hubDown(Object e) => e is HubUnreachable || e is TransferStalled;

  /// Prossimo salvataggio automatico tra `config.autosaveEvery` (un timer
  /// alla volta, riarmato a ogni scatto: il periodo può cambiare dall'hub).
  void _armAutosave() {
    _autosaveTimer?.cancel();
    final every = config.autosaveEvery;
    _nextAutosave = DateTime.now().add(every);
    _autosaveTimer = Timer(every, () {
      _armAutosave();
      _tick();
    });
  }

  void _tick() {
    // un ciclo alla volta, e mai mentre si carica il precedente
    if (_saving || _upload != null || _state != SessionState.running) return;
    unawaited(_saveCycle().then((_) => _refreshHub()));
  }

  /// Applica le impostazioni `sessions` dello spazio, se le si segue e se
  /// l'hub le manda.
  void _applyHub(SpaceDetails d) {
    final s = d.settings;
    if (!followHub || s == null) return;
    final next = config.withHub(s.sessions);
    if (next.sameAs(config)) return;
    final periodChanged = next.autosaveEvery != config.autosaveEvery;
    config = next;
    if (periodChanged && _autosaveTimer != null && _autosaveTimer!.isActive) _armAutosave();
    _emit(SettingsApplied(next));
  }

  /// Rilegge le impostazioni dopo un salvataggio automatico. Un errore non
  /// conta: si resta con quelle che si hanno (l'hub può essere giù).
  Future<void> _refreshHub() async {
    if (!followHub || _state == SessionState.ended || _state == SessionState.failed) return;
    try {
      _applyHub(await _client.space(_space));
    } on Object {
      // si riprova al prossimo salvataggio
    }
  }

  /// Salvataggio chiesto dall'utente.
  SaveRequest saveNow() {
    if (_state != SessionState.running && _state != SessionState.saving) {
      return SaveRequest.notRunning;
    }
    if (_saving || _upload != null) {
      _manualQueued = true;
      return SaveRequest.queued;
    }
    unawaited(_saveCycle());
    return SaveRequest.started;
  }

  Future<void> _saveCycle() async {
    final proc = _proc;
    if (proc == null || !proc.running) return;
    // un'istantanea nuova sostituisce quella che si stava riprovando
    _retryTimer?.cancel();
    _retryTimer = null;
    _saving = true;
    _setState(SessionState.saving);
    var saveOff = false;
    Snapshot? snap;
    DateTime? at;
    try {
      await proc.send('save-off');
      saveOff = true;
      final c = _flush = Completer<bool>();
      await proc.send('save-all flush');
      final confirmed = await _waitFlush(c);
      _flush = null;
      if (!confirmed) {
        if (!_stopRequested) _emit(const SessionWarning('saveNotConfirmed'));
        return;
      }
      await waitQuiet(engine.root, _ex, stable: config.quietStable, cap: config.quietCap);
      at = DateTime.now();
      try {
        snap = await engine.snapshot();
      } on SyncException catch (e) {
        if (e.kind == SyncErrorKind.outboxNoSpace) {
          // niente spazio per l'outbox: si carica direttamente, a server fermo
          final r = await engine.push(
            lock: _lock!,
            keepAlive: false,
            kind: GenerationKind.autosave,
          );
          if (r.generation != null) _emit(SavedToHub(r.generation!.n, at));
        } else {
          _emit(SessionWarning('snapshotFailed', cause: e));
        }
      }
    } on Object catch (e) {
      _emit(SessionWarning('saveFailed', cause: e));
      if (_hubDown(e)) _armRetry();
    } finally {
      if (saveOff && proc.running) {
        try {
          await proc.send('save-on');
        } on Object catch (e) {
          _emit(SessionWarning('saveOnFailed', cause: e));
        }
      }
      _saving = false;
      if (_state == SessionState.saving) _setState(SessionState.running);
    }
    if (snap != null) _startUpload(at!);
  }

  /// Attende la conferma del salvataggio; il tempo riparte a ogni riga del
  /// server (un mondo grande scrive per un po').
  Future<bool> _waitFlush(Completer<bool> c) async {
    var deadline = DateTime.now().add(config.flushWait);
    while (!c.isCompleted) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return false;
      try {
        return await c.future.timeout(left);
      } on TimeoutException {
        final rearmed = _lastLine.add(config.flushWait);
        if (rearmed.isAfter(deadline)) {
          deadline = rearmed;
        } else {
          return false;
        }
      }
    }
    return c.future;
  }

  void _startUpload(DateTime at) {
    final done = _upload = Completer<void>();
    final ct = _uploadCt = CancelToken();
    unawaited(() async {
      try {
        final r = await engine.pushSnapshot(
          lock: _lock!,
          keepAlive: false,
          cancel: ct,
          kind: GenerationKind.autosave,
        );
        if (r?.generation != null && !ct.isCancelled) _emit(SavedToHub(r!.generation!.n, at));
        if (r != null && r.kept.isNotEmpty) {
          _emit(SessionWarning('unreadableKept', paths: r.kept));
        }
      } on Object catch (e) {
        if (!ct.isCancelled) {
          if (e is SyncException && e.kind == SyncErrorKind.hubDiskFull) {
            _emit(const SessionAlert('hubDiskFull'));
          }
          _emit(SessionWarning('uploadFailed', cause: e));
          if (_hubDown(e)) _armRetry(at);
        }
      } finally {
        _upload = null;
        _uploadCt = null;
        done.complete();
        if (_manualQueued && _state == SessionState.running) {
          _manualQueued = false;
          unawaited(_saveCycle());
        }
      }
    }());
  }

  Future<void> _cancelUpload() async {
    final u = _upload;
    if (u == null) return;
    _uploadCt?.cancel();
    await u.future;
  }

  /// Comando dalla console: `stop` diventa un arresto pulito della sessione.
  Future<void> send(String command) async {
    final c = command.trim();
    if (c == 'stop') return stop();
    final p = _proc;
    if (p == null || !p.running) throw StateError('server not running');
    await p.send(c);
  }

  /// Arresto pulito: annulla il caricamento in corso, ferma il server; il
  /// caricamento finale avviene a server spento, dai file veri.
  Future<void> stop() async {
    if (_stopRequested) return;
    _stopRequested = true;
    _manualQueued = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _setState(SessionState.stopping);
    _flush?.complete(false);
    await _cancelUpload();
    final p = _proc;
    if (p != null && p.running) await p.stop();
  }

  void _onLockProblem(SyncException? reason) {
    if (_lockProblem != null) return;
    final kind = reason?.kind == SyncErrorKind.spaceGone ? 'spaceGone' : 'lockLost';
    _lockProblem = kind;
    _emit(SessionAlert(kind));
    unawaited(stop());
  }

  Future<void> _finalPush() async {
    _setState(SessionState.finalPush);
    await _cancelUpload();
    try {
      await engine.clearOutbox();
      final r = await engine.push(lock: _lock!, keepAlive: false, message: AutoMessage.sessionEnd);
      if (r.generation != null) _emit(SavedToHub(r.generation!.n, DateTime.now()));
      if (r.kept.isNotEmpty) _emit(SessionWarning('unreadableKept', paths: r.kept));
    } on Object catch (e) {
      // il mondo resta su questo PC: la prossima sessione lo caricherà
      _emit(SessionWarning('finalPushFailed', cause: e));
      if (e is SyncException && e.kind == SyncErrorKind.hubDiskFull) {
        _emit(const SessionAlert('hubDiskFull'));
      }
    }
  }
}
