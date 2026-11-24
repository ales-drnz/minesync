// Stato centrale dell'app: configurazione, connessione all'hub (con eventi
// live e riconnessione), server dell'hub, attività, schermata corrente,
// preferenze di tema e lingua. Le schermate lo leggono e chiamano i suoi
// metodi; nessuna schermata parla con l'hub per conto suo.
import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:ms_core/ms_core.dart';
import 'package:ms_l10n/ms_l10n.dart';
import 'package:ms_minecraft/ms_minecraft.dart' show JavaRuntime;
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../l10n/l10n.dart';
import '../platform/platform.dart';
import 'modpack_env.dart';
import 'modpack_state.dart';
import 'new_server_state.dart';
import 'space_state.dart';
import 'session_state.dart';

export 'modpack_env.dart';
export 'pack_browser.dart';
export 'modpack_state.dart';
export 'new_server_state.dart';
export 'session_state.dart';

/// Stato della connessione all'hub.
enum Connection { none, connecting, online, offline }

/// Schermate dell'app.
sealed class AppRoute {
  const AppRoute();
}

final class FirstRunRoute extends AppRoute {
  const FirstRunRoute();
}

final class HomeRoute extends AppRoute {
  const HomeRoute();
}

final class ServerRoute extends AppRoute {
  const ServerRoute(this.space);
  final String space;
  @override
  bool operator ==(Object other) => other is ServerRoute && other.space == space;
  @override
  int get hashCode => space.hashCode;
}

final class SessionRoute extends AppRoute {
  const SessionRoute(this.space);
  final String space;
  @override
  bool operator ==(Object other) => other is SessionRoute && other.space == space;
  @override
  int get hashCode => space.hashCode;
}

final class HistoryRoute extends AppRoute {
  const HistoryRoute(this.space);
  final String space;
  @override
  bool operator ==(Object other) => other is HistoryRoute && other.space == space;
  @override
  int get hashCode => space.hashCode;
}

/// Scheda Mod di un server: [client] apre il pacchetto per i giocatori.
final class ModpackRoute extends AppRoute {
  const ModpackRoute(this.space, {this.client = false});
  final String space;
  final bool client;
  @override
  bool operator ==(Object other) =>
      other is ModpackRoute && other.space == space && other.client == client;
  @override
  int get hashCode => Object.hash(space, client);
}

/// Procedura «Nuovo server» (admin).
final class NewServerRoute extends AppRoute {
  const NewServerRoute();
}

final class SettingsRoute extends AppRoute {
  const SettingsRoute();
}

/// Dipendenze dell'app, sostituibili nei test.
final class AppDeps {
  AppDeps({
    required this.configDir,
    required this.platform,
    HubClient Function(Uri hub)? client,
    this.pollEvery = const Duration(seconds: 15),
    this.retryEvery = const Duration(seconds: 5),
    this.env = const {},
    this.session = const SessionEnv(),
    this.modpack,
  }) : makeClient = client ?? ((u) => HubClient(u, userAgent: 'minesync/0.1.0'));

  final String configDir;
  final PlatformServices platform;
  final HubClient Function(Uri hub) makeClient;

  /// Ogni quanto si misura la latenza e si rilegge lo stato dell'hub.
  final Duration pollEvery;

  /// Attesa tra un tentativo di riconnessione e l'altro.
  final Duration retryEvery;
  final Map<String, String> env;

  /// Come si avviano i server delle sessioni (server finto nei test).
  final SessionEnv session;

  /// Modrinth, download e strumenti del modpack (finti nei test); null =
  /// quelli veri.
  final ModpackEnv? modpack;
}

final class AppState extends ChangeNotifier {
  AppState(this.deps) : config = AppConfig.load(deps.configDir);

  final AppDeps deps;
  final AppConfig config;

  HubClient? _client;
  HubClient? get client => _client;

  Connection _connection = Connection.none;
  Connection get connection => _connection;

  HubInfo? _hub;
  HubInfo? get hub => _hub;
  Me? get me => _hub?.me;

  int? _latencyMs;
  int? get latencyMs => _latencyMs;

  DateTime? _offlineSince;
  DateTime? get offlineSince => _offlineSince;

  /// Ultimo errore di connessione (per i messaggi).
  Object? _lastError;
  Object? get lastError => _lastError;

  List<SpaceSummary> _spaces = const [];
  List<SpaceSummary> get spaces => _spaces;
  SpaceSummary? space(String id) => _spaces.where((s) => s.id == id).firstOrNull;

  final _events = ListQueue<HubEvent>();

  /// Eventi più vecchi caricati a richiesta ("Tutta l'attività"), dal più
  /// recente; tutti più vecchi di quelli in [_events].
  final _older = <HubEvent>[];
  bool _olderEnd = false;
  bool _olderLoading = false;
  Object? _olderError;

  /// Attività dell'hub, la più nuova per prima: quella recente e le pagine
  /// più vecchie caricate con [loadOlderEvents].
  List<HubEvent> get events => [..._events.toList().reversed, ..._older];
  int _lastSeq = 0;

  /// Non ci sono eventi più vecchi sull'hub.
  bool get olderEventsEnd => _olderEnd;
  bool get olderEventsLoading => _olderLoading;
  Object? get olderEventsError => _olderError;

  /// Carica la pagina di eventi precedente al più vecchio già noto
  /// (`GET /events?before=`): l'hub li legge anche dal disco.
  Future<void> loadOlderEvents({int page = 50}) async {
    final c = _client;
    if (c == null || _olderLoading || _olderEnd) return;
    final known = events;
    final before = known.isEmpty ? _maxSeq : known.last.seq;
    if (before <= 1) {
      _olderEnd = true;
      _notify();
      return;
    }
    _olderLoading = true;
    _olderError = null;
    _notify();
    try {
      final p = await c.eventsBefore(before, limit: page);
      for (final e in p.events) {
        if (e.seq < before) _older.add(e);
      }
      _olderEnd = !p.more;
    } on Object catch (e) {
      _olderError = e;
    } finally {
      _olderLoading = false;
      _notify();
    }
  }

  /// "Prima di tutto": un seq più grande di qualunque evento.
  static const _maxSeq = 9007199254740991;

  AppRoute _route = const HomeRoute();
  AppRoute get route => _route;

  Timer? _poll;
  Timer? _retry;
  StreamSubscription<HubEvent>? _sse;
  bool _disposed = false;

  // --- preferenze ---------------------------------------------------------------

  MsThemeData get theme => MsThemeData(
    palette: config.prefs['palette'] == 'abisso' ? MsPalette.abisso : MsPalette.prato,
    brightness: switch (config.prefs['theme']) {
      'light' => Brightness.light,
      'system' => WidgetsBinding.instance.platformDispatcher.platformBrightness,
      _ => Brightness.dark,
    },
    reducedMotion: config.prefs['reducedMotion'] == true,
    sizeStep: (config.prefs['sizeStep'] as int?) ?? 0,
  );

  Lang get lang => parseLang(config.lang) ?? langFromEnv(deps.env, fallback: Lang.it);

  Future<void> setTheme(MsThemeData t) async {
    config.prefs
      ..['palette'] = t.palette.name
      ..['theme'] = t.brightness == Brightness.light ? 'light' : 'dark'
      ..['reducedMotion'] = t.reducedMotion
      ..['sizeStep'] = t.sizeStep;
    await _save();
  }

  /// Lingua dell'app; null = come il sistema.
  Future<void> setLang(Lang? l) async {
    config.lang = l?.name;
    await _save();
  }

  /// Imposta una preferenza locale qualunque e la salva.
  Future<void> setPref(String key, Object? value) async {
    if (value == null) {
      config.prefs.remove(key);
    } else {
      config.prefs[key] = value;
    }
    // l'interfaccia cambia subito (es. «Avviso attivo»), il file si scrive dopo
    _notify();
    await _save();
  }

  /// Preferenza [name] del server [space] su questo PC (`java`, `xmx`,
  /// `autostop`), che vale subito anche per la sessione in corso.
  Future<void> setServerPref(String space, String name, Object? value) async {
    final key = ServerPrefs.key(space, name);
    if (value == null) {
      config.prefs.remove(key);
    } else {
      config.prefs[key] = value;
    }
    final s = session;
    if (s != null && s.space == space) s.updatePrefs(ServerPrefs.fromPrefs(config.prefs, space));
    // l'interfaccia cambia subito, il file si scrive dopo
    _notify();
    await _save();
  }

  Future<void> _save() async {
    await config.save(deps.configDir);
    _notify();
  }

  // --- navigazione --------------------------------------------------------------

  void go(AppRoute r) {
    if (_route == r) return;
    _route = r;
    _notify();
  }

  // --- avvio e connessione ------------------------------------------------------

  /// Avvia: senza hub configurato porta al primo avvio, altrimenti si collega.
  Future<void> start() async {
    if (config.hub == null) {
      _route = const FirstRunRoute();
      _notify();
      return;
    }
    await _connect(Uri.parse(config.hub!));
  }

  /// Collega l'app a un nuovo hub (primo avvio o "cambia hub"). Lancia se
  /// l'hub non risponde o non riconosce l'utente: niente viene salvato.
  Future<HubInfo> connectTo(String address) async {
    var a = address.trim();
    if (!a.contains('://')) a = 'http://$a';
    var uri = Uri.parse(a);
    if (!uri.hasPort) uri = uri.replace(port: 8084);
    final c = deps.makeClient(uri);
    try {
      final info = await c.hub();
      _replaceClient(c);
      config.hub = uri.toString();
      await config.save(deps.configDir);
      _hub = info;
      _setOnline();
      await refreshSpaces();
      _listen();
      _schedulePoll();
      _route = const HomeRoute();
      _notify();
      return info;
    } catch (_) {
      c.close(force: true);
      rethrow;
    }
  }

  Future<void> _connect(Uri uri) async {
    _replaceClient(deps.makeClient(uri));
    _connection = Connection.connecting;
    _notify();
    await _refreshHub();
  }

  void _replaceClient(HubClient c) {
    _sse?.cancel();
    _sse = null;
    _client?.close(force: true);
    _client = c;
  }

  /// Nuovo tentativo subito (pulsante "Riprova").
  Future<void> retry() async {
    _retry?.cancel();
    await _refreshHub();
  }

  Future<void> _refreshHub() async {
    final c = _client;
    if (c == null) return;
    final sw = Stopwatch()..start();
    try {
      _hub = await c.hub();
      _latencyMs = sw.elapsedMilliseconds;
      final wasOnline = _connection == Connection.online;
      _setOnline();
      if (!wasOnline) {
        await refreshSpaces();
        _listen();
      }
      _schedulePoll();
    } on Object catch (e) {
      _setOffline(e);
    }
    _notify();
  }

  void _setOnline() {
    _connection = Connection.online;
    _offlineSince = null;
    _lastError = null;
  }

  void _setOffline(Object e) {
    if (_connection != Connection.offline) _offlineSince = DateTime.now();
    _connection = Connection.offline;
    _lastError = e;
    _sse?.cancel();
    _sse = null;
    _poll?.cancel();
    _retry?.cancel();
    _retry = Timer(deps.retryEvery, _refreshHub);
  }

  void _schedulePoll() {
    _poll?.cancel();
    _poll = Timer(deps.pollEvery, _refreshHub);
  }

  /// Rilegge l'elenco dei server.
  Future<void> refreshSpaces() async {
    final c = _client;
    if (c == null) return;
    try {
      _spaces = await c.spaces();
      _afterSpacesRefresh();
      if (_events.isEmpty) {
        // le più recenti; le altre si sfogliano con loadOlderEvents
        final p = await c.eventsBefore(_maxSeq, limit: 100);
        p.events.reversed.forEach(_addEvent);
        _olderEnd = !p.more;
      }
      _notify();
    } on Object catch (e) {
      _setOffline(e);
      _notify();
    }
  }

  void _listen() {
    final c = _client;
    if (c == null || _sse != null) return;
    _sse = c
        .eventStream(after: _lastSeq == 0 ? null : _lastSeq)
        .listen(
          (e) {
            _addEvent(e);
            _onLiveEvent(e);
            _scheduleSpacesRefresh();
            _notify();
          },
          onError: (Object e) {
            _sse = null;
            _setOffline(e);
            _notify();
          },
          onDone: () {
            // lo stream si è chiuso (hub riavviato, rete): ci si ricollega
            _sse = null;
            if (!_disposed && _connection == Connection.online) _listen();
          },
        );
  }

  Timer? _spacesDebounce;
  void _scheduleSpacesRefresh() {
    _spacesDebounce?.cancel();
    _spacesDebounce = Timer(const Duration(milliseconds: 200), refreshSpaces);
  }

  void _addEvent(HubEvent e) {
    if (e.seq <= _lastSeq && _lastSeq != 0) return;
    _lastSeq = e.seq;
    _events.add(e);
    while (_events.length > 200) {
      final out = _events.removeFirst();
      // con pagine vecchie già caricate non si lasciano buchi in mezzo
      if (_older.isNotEmpty) {
        _older.insert(0, out);
      } else {
        _olderEnd = false;
      }
    }
  }

  // --- collegamenti locali ------------------------------------------------------

  /// Cartella locale di un server, o null se non è collegato.
  String? folderOf(String space) => config.links[space];

  Future<void> link(String space, String folder) async {
    config.links[space] = folder;
    await _save();
  }

  Future<void> unlink(String space) async {
    config.links.remove(space);
    await _save();
  }

  // === server su questo PC, primo avvio, azioni admin ============================
  // Sezione delle schermate Home, Server, Storia e Primo avvio: stato locale
  // dei server, pre-scarico in background, "avvisami quando si libera".

  /// Letture del PC (sostituibili nei test).
  LocalProbe localProbe = const LocalProbe();

  /// Orologio e fuso delle schermate (fissi nei test e nelle anteprime).
  DateTime Function() now = DateTime.now;
  DateTime Function(int ms) localTime = DateTime.fromMillisecondsSinceEpoch;

  final _spaceStates = <String, SpaceState>{};

  /// Stato locale del server [id] (creato alla prima richiesta).
  SpaceState spaceState(String id) => _spaceStates.putIfAbsent(id, () => SpaceState(this, id));

  /// Modrinth, download e strumenti del modpack.
  late final ModpackEnv modpackEnv = deps.modpack ?? ModpackEnv.io(deps.configDir, env: deps.env);

  final _modpacks = <String, ModpackController>{};

  /// Modpack del server [id] su questo PC.
  ModpackController modpack(String id) =>
      _modpacks.putIfAbsent(id, () => ModpackController(this, id));

  NewServerController? _newServer;

  /// La procedura «Nuovo server» in corso (resta viva se si cambia schermata).
  NewServerController get newServer => _newServer ??= NewServerController(this);

  /// Chiude la procedura: la prossima riparte da capo.
  void resetNewServer() {
    _newServer?.dispose();
    _newServer = null;
  }

  String get _home =>
      deps.env['HOME'] ??
      deps.env['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '.';

  /// Cartella in cui stanno i mondi (scelta al primo avvio).
  String get worldsDir =>
      config.prefs['worldsDir'] as String? ?? '$_home${Platform.pathSeparator}MineSync';

  /// Cartella proposta per il server [id].
  String defaultFolderFor(String id) => '$worldsDir${Platform.pathSeparator}$id';

  /// [path] con la cartella utente abbreviata in `~`.
  String displayPath(String path) {
    final h = _home;
    return h.length > 1 && path.startsWith(h) ? '~${path.substring(h.length)}' : path;
  }

  List<JavaRuntime>? _javas;
  DiskSpace? _worldsDisk;
  bool _pcProbed = false;

  /// Runtime Java trovati sul PC (null finché la ricerca non è finita).
  List<JavaRuntime>? get javas => _javas;

  /// Spazio del disco dei mondi.
  DiskSpace? get worldsDisk => _worldsDisk;

  /// Legge Java e spazio libero del PC, una volta (o di nuovo con [force]).
  Future<void> probePc({bool force = false}) async {
    if (_pcProbed && !force) return;
    _pcProbed = true;
    try {
      _worldsDisk = await localProbe.disk(worldsDir);
      _notify();
      _javas = await localProbe.java();
    } on Object {
      _javas ??= const [];
    }
    _notify();
  }

  /// Prova [address] senza salvare niente: chi sono per l'hub e quali server
  /// ci sono. Lancia come [connectTo].
  Future<(HubInfo, List<SpaceSummary>)> probeHub(String address) async {
    final o = debugProbeHub;
    if (o != null) return o(address);
    final c = deps.makeClient(hubUri(address));
    try {
      final info = await c.hub();
      final spaces = await c.spaces();
      return (info, spaces);
    } finally {
      c.close(force: true);
    }
  }

  /// Sostituisce [probeHub] nei test delle schermate (niente rete).
  @visibleForTesting
  Future<(HubInfo, List<SpaceSummary>)> Function(String address)? debugProbeHub;

  /// Indirizzo dell'hub normalizzato (schema e porta predefiniti).
  static Uri hubUri(String address) {
    var a = address.trim();
    if (!a.contains('://')) a = 'http://$a';
    var uri = Uri.parse(a);
    if (!uri.hasPort) uri = uri.replace(port: 8084);
    return uri;
  }

  /// Crea un server (solo admin).
  Future<SpaceSummary> createSpace(String name, Profile profile) async {
    final s = await _client!.createSpace(name, profile);
    await refreshSpaces();
    return s;
  }

  /// Libera il server [id] togliendo il lock a chi lo tiene: chiunque se è
  /// stale, solo un admin se è vivo. Si prende il lock con force e lo si
  /// rilascia subito, così il server resta libero per chi preme Gioca.
  Future<void> forceUnlock(String id) async {
    final c = _client!;
    final g = await c.acquireLock(
      id,
      const LockInfo(client: desktopClient, action: 'force'),
      force: true,
    );
    try {
      await c.releaseLock(id, g.token);
    } finally {
      await refreshSpaces();
    }
  }

  /// Riporta il server [id] alla versione [n] creando una nuova versione
  /// (solo admin).
  Future<GenerationSummary> restore(String id, int n) async {
    final g = await _client!.restore(id, n);
    await refreshSpaces();
    _spaceStates[id]?.invalidateHistory();
    return g;
  }

  // --- impostazioni dell'hub per server, prova della porta, pulizia ----------

  final _details = <String, SpaceDetails>{};
  final _detailsLoading = <String>{};

  /// Dettaglio del server [id] letto dall'hub (impostazioni effettive delle
  /// sessioni e protezioni), se già caricato con [loadDetails].
  SpaceDetails? details(String id) => _details[id];

  /// Impostazioni delle sessioni che l'hub vuole per [id] (i default di
  /// fabbrica finché non si sa).
  SessionSettings sessionSettings(String id) =>
      _details[id]?.settings?.sessions ?? const SessionSettings();

  /// Legge il dettaglio di [id] dall'hub (una volta; [force] per rileggere).
  Future<void> loadDetails(String id, {bool force = false}) async {
    final c = _client;
    if (c == null || _detailsLoading.contains(id) || (_details.containsKey(id) && !force)) return;
    _detailsLoading.add(id);
    try {
      _details[id] = await c.space(id);
      _notify();
    } on Object {
      // si riprova alla prossima richiesta
    } finally {
      _detailsLoading.remove(id);
    }
  }

  /// Il client, o [HubUnreachable] se l'app non è collegata a un hub.
  HubClient get _need => _client ?? (throw const HubUnreachable('not connected'));

  /// Rifà la prova della porta di chi ospita [id]. Lancia [ApiError] con
  /// `not_locked`, `feature_off` o `rate_limited` (tra due prove servono
  /// 10 s); il risultato arriva poi con l'evento `port`.
  Future<PortCheck> retryPortCheck(String id) async {
    final r = await _need.portCheck(id);
    unawaited(refreshSpaces());
    return r;
  }

  /// Anteprima della pulizia manuale dell'hub (admin): tiene le ultime
  /// [keep] versioni di ogni server.
  Future<GcPreview> gcPreview(int keep) => _need.gcPreview(keep: keep);

  /// Pulizia manuale adesso (admin); poi si rilegge lo spazio dell'hub.
  Future<GcReport> runGc(int keep) async {
    final r = await _need.gc(keep: keep);
    unawaited(_refreshHub());
    return r;
  }

  /// Notifica sul desktop quando il server [id] si libera.
  bool notifyWhenFree(String id) => config.prefs['notifyFree.$id'] == true;

  Future<void> setNotifyWhenFree(String id, bool on) => setPref('notifyFree.$id', on ? true : null);

  bool _updateDismissed = false;

  /// L'avviso di aggiornamento pronto è stato rimandato.
  bool get updateDismissed => _updateDismissed;

  void dismissUpdate() {
    _updateDismissed = true;
    _notify();
  }

  void _onLiveEvent(HubEvent e) {
    // impostazioni cambiate dall'Admin: si rileggono i dettagli già noti
    if (e.type == EventType.settings) {
      for (final k in _details.keys.toList()) {
        unawaited(loadDetails(k, force: true));
      }
    }
    final id = e.space;
    if (id == null) return;
    if (e.type == EventType.spaceUpdate && _details.containsKey(id)) {
      unawaited(loadDetails(id, force: true));
    }
    final name = space(id)?.name ?? id;
    final t = AppStrings(lang).session;
    final ns = deps.platform.notifications;
    // il server atteso si è liberato (avviso chiesto su quel server)
    if ((e.type == EventType.unlock || e.type == EventType.force) && notifyWhenFree(id)) {
      if (notifyPref('serverFree')) unawaited(ns.show(title: name, body: t.notifyFree));
      unawaited(setNotifyWhenFree(id, false));
    }
    // un amico ha avviato un server (non quando lo avvia questo PC)
    if (e.type == EventType.lock &&
        notifyPref('friendOpens') &&
        e.actor != null &&
        e.actor != me?.name &&
        session?.space != id) {
      unawaited(ns.show(title: name, body: t.notifyOpened(e.actor!)));
    }
    if (e.type == 'space.delete') {
      _spaceStates.remove(id)?.dispose();
      _modpacks.remove(id)?.dispose();
    }
  }

  /// Pre-scarico: il server che si sta scaricando in background, o null.
  String? get prefetching {
    for (final s in _spaceStates.values) {
      if (s.transfer?.background ?? false) return s.id;
    }
    return null;
  }

  /// Teste già tentate dal pre-scarico (per non riprovare in loop).
  final _prefetchTried = <String, int>{};
  bool _prefetchRunning = false;

  /// Dopo ogni rilettura dei server: pre-scarica le novità dei server
  /// collegati, uno alla volta, se nessuno di loro è in uso su questo PC.
  void _afterSpacesRefresh() {
    for (final s in _spaceStates.values) {
      if (s.loaded && !s.busy) unawaited(s.refresh());
    }
    if (config.prefs['prefetch'] == false || _prefetchRunning) return;
    unawaited(_prefetch());
  }

  Future<void> _prefetch() async {
    _prefetchRunning = true;
    try {
      for (final sp in List.of(_spaces)) {
        if (_disposed || _connection != Connection.online) return;
        final head = sp.head;
        if (head == null || folderOf(sp.id) == null) continue;
        if (sp.lock?.memberId == me?.id && sp.lock != null) continue;
        if (_prefetchTried[sp.id] == head.n) continue;
        final ss = spaceState(sp.id);
        if (ss.busy) continue;
        if (!ss.loaded) await ss.refresh();
        if (ss.baseN == head.n) continue;
        _prefetchTried[sp.id] = head.n;
        await ss.pull(background: true);
      }
    } finally {
      _prefetchRunning = false;
    }
  }

  // --- sessione di gioco (vedi session_state.dart) ------------------------------

  SessionController? _session;
  StreamSubscription<SessionSignal>? _sessionSignals;

  /// La sessione di gioco di questo PC (al massimo una). Resta anche dopo la
  /// fine, per l'esito, finché non la si chiude con [closeSession].
  SessionController? get session => _session;

  /// Vero se su questo PC gira (o sta partendo) un server.
  bool get hosting => _session?.active ?? false;

  /// Avvia una sessione su [space] (già collegato a una cartella) e porta
  /// alla schermata della sessione. Con [force] prende il lock di un altro.
  Future<SessionController> play(String space, {bool force = false}) async {
    final c = _client;
    final folder = folderOf(space);
    if (c == null || folder == null) throw StateError('server not linked');
    if (hosting) throw StateError('a session is already running');
    closeSession();
    final p = config.prefs;
    final s = SessionController(
      client: c,
      space: space,
      name: this.space(space)?.name ?? space,
      folder: folder,
      env: deps.session,
      processEnv: deps.env,
      prefs: ServerPrefs.fromPrefs(p, space),
      uploadLimit: UploadLimit.fromPrefs(
        p,
      ).bytesPerSecond((p[measuredUploadPref] as num?)?.toInt()),
      me: me?.name,
    );
    _session = s;
    s.addListener(_notify);
    _sessionSignals = s.signals.listen(_onSessionSignal);
    _route = ServerRoute(space);
    _notify();
    unawaited(s.start(force: force));
    return s;
  }

  /// Dimentica la sessione finita (o annullata).
  void closeSession() {
    final s = _session;
    if (s == null || s.active) return;
    _sessionSignals?.cancel();
    _sessionSignals = null;
    s.removeListener(_notify);
    s.dispose();
    _session = null;
    _notify();
  }

  /// Preferenza di notifica (chiave `notify.<nome>`), con i default del design.
  bool notifyPref(String name) => config.prefs['notify.$name'] as bool? ?? name != 'everySave';

  void _onSessionSignal(SessionSignal sig) {
    final s = _session;
    if (s == null) return;
    final t = AppStrings(lang).session;
    final ns = deps.platform.notifications;
    switch (sig) {
      case SignalSaved() when notifyPref('everySave'):
        unawaited(ns.show(title: s.name, body: t.notifySaved));
      case SignalCrashed(:final crash) when notifyPref('sessionProblems'):
        unawaited(ns.show(title: s.name, body: t.notifyCrashed(crash.restarting)));
      case SignalAlert(:final kind) when notifyPref('sessionProblems'):
        unawaited(ns.show(title: s.name, body: t.notifyAlert(kind, s.name)));
      case SignalHubLost() when notifyPref('sessionProblems'):
        unawaited(ns.show(title: s.name, body: t.hubLostTitle));
      case SignalEnded():
        final m = s.measuredUploadBps;
        if (m != null) unawaited(setPref(measuredUploadPref, m));
      default:
        break;
    }
  }

  // --- test ---------------------------------------------------------------------

  /// Imposta lo stato senza rete, per i test e le anteprime delle schermate.
  @visibleForTesting
  void debugSet({
    Connection? connection,
    HubInfo? hub,
    int? latencyMs,
    List<SpaceSummary>? spaces,
    List<HubEvent>? events,
    bool? olderEnd,
    Map<String, SpaceDetails>? details,
    AppRoute? route,
    DateTime? offlineSince,
  }) {
    if (connection != null) _connection = connection;
    if (hub != null) _hub = hub;
    if (latencyMs != null) _latencyMs = latencyMs;
    if (spaces != null) _spaces = spaces;
    if (offlineSince != null) _offlineSince = offlineSince;
    if (events != null) {
      _events.clear();
      _older.clear();
      _lastSeq = 0;
      events.forEach(_addEvent);
      _olderEnd = olderEnd ?? true;
    } else if (olderEnd != null) {
      _olderEnd = olderEnd;
    }
    if (details != null) _details.addAll(details);
    if (route != null) _route = route;
    _notify();
  }

  // --- notifiche ----------------------------------------------------------------

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Per i test: un client verso un hub finto, senza connessione né eventi
  /// live.
  @visibleForTesting
  void debugSetClient(HubClient? c) => _client = c;

  /// Per i test delle schermate: una sessione preparata a mano.
  @visibleForTesting
  void debugSetSession(SessionController? s) {
    _session = s;
    s?.addListener(_notify);
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _sessionSignals?.cancel();
    _session?.removeListener(_notify);
    _session?.dispose();
    _poll?.cancel();
    _retry?.cancel();
    _spacesDebounce?.cancel();
    _sse?.cancel();
    _client?.close(force: true);
    for (final m in _modpacks.values) {
      m.dispose();
    }
    _newServer?.dispose();
    for (final s in _spaceStates.values) {
      s.dispose();
    }
    super.dispose();
  }
}

/// Fornisce lo stato ai widget.
class AppStateScope extends InheritedNotifier<AppState> {
  const AppStateScope({super.key, required AppState state, required super.child})
    : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppStateScope>()!.notifier!;

  /// Lo stato senza dipendere dai suoi cambiamenti (per i callback).
  static AppState read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppStateScope>()!.notifier!;
}
