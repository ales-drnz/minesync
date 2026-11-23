// Stato centrale della web UI: connessione all'hub (con latenza, eventi dal
// vivo e riconnessione), chi sono, server, attività, lingua e tema salvati
// nel browser. Le pagine lo leggono e chiamano i suoi metodi per i dati
// condivisi; i dati di una sola pagina (storia, mod…) li chiede la pagina
// direttamente a [HubState.api].
import 'dart:async';
import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:ms_l10n/ms_l10n.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../api/hub_api.dart';
import '../platform/web_platform.dart';

/// Stato della connessione all'hub.
enum HubConnection {
  /// Prima risposta non ancora arrivata.
  connecting,
  online,

  /// L'hub non risponde: si riprova da soli.
  offline,

  /// L'hub risponde 401: questo dispositivo non è nella rete ZeroTier.
  denied,
}

/// Tema scelto: come il sistema, chiaro o scuro.
enum ThemeChoice { system, light, dark }

/// Dipendenze, sostituibili nei test.
final class HubDeps {
  HubDeps({
    required this.api,
    required this.platform,
    this.pollEvery = const Duration(seconds: 15),
    this.retryEvery = const Duration(seconds: 5),
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  final HubApi api;
  final WebPlatform platform;

  /// Ogni quanto si rilegge `GET /hub` (latenza, disco, ruolo).
  final Duration pollEvery;

  /// Attesa tra un tentativo di riconnessione e l'altro.
  final Duration retryEvery;

  /// Orologio del browser (fisso nei test).
  final DateTime Function() clock;
}

/// Chiavi nel localStorage.
abstract final class PrefKeys {
  static const lang = 'minesync.lang';
  static const theme = 'minesync.theme';
}

/// Eventi tenuti in memoria per il feed.
const _maxEvents = 500;

/// Eventi chiesti per pagina ("Mostra le precedenti").
const eventPageSize = 50;

/// Il più alto seq possibile, per chiedere gli eventi più recenti.
const _maxSeq = 9007199254740991;

final class HubState extends ChangeNotifier {
  HubState(this.deps) {
    _langPref = parseLang(deps.platform.readPref(PrefKeys.lang));
    _theme = switch (deps.platform.readPref(PrefKeys.theme)) {
      'light' => ThemeChoice.light,
      'dark' => ThemeChoice.dark,
      _ => ThemeChoice.system,
    };
  }

  final HubDeps deps;
  HubApi get api => deps.api;
  WebPlatform get platform => deps.platform;

  HubConnection _connection = HubConnection.connecting;
  HubConnection get connection => _connection;
  bool get online => _connection == HubConnection.online;

  HubInfo? _hub;
  HubInfo? get hub => _hub;
  Me? get me => _hub?.me;
  bool get isAdmin => _hub?.me.admin ?? false;

  int? _latencyMs;
  int? get latencyMs => _latencyMs;

  DateTime? _offlineSince;
  DateTime? get offlineSince => _offlineSince;

  /// Ultimo errore (per i messaggi e la pagina di accesso negato).
  Object? _lastError;
  Object? get lastError => _lastError;

  /// Differenza tra l'orologio dell'hub e quello del browser.
  Duration _skew = Duration.zero;

  List<SpaceSummary> _spaces = const [];
  List<SpaceSummary> get spaces => _spaces;
  SpaceSummary? space(String id) => _spaces.where((s) => s.id == id).firstOrNull;

  /// Server caricati almeno una volta (per distinguere "vuoto" da "non so").
  bool _spacesLoaded = false;
  bool get spacesLoaded => _spacesLoaded;

  final _events = SplayTreeMap<int, HubEvent>((a, b) => b.compareTo(a));

  /// Attività dell'hub, la più nuova per prima.
  List<HubEvent> get events => _events.values.toList();

  bool _eventsMore = false;

  /// Ci sono eventi più vecchi da chiedere all'hub.
  bool get eventsMore => _eventsMore;

  bool _loadingOlder = false;
  bool get loadingOlder => _loadingOlder;

  Timer? _poll;
  Timer? _retry;
  Timer? _spacesDebounce;
  StreamSubscription<HubEvent>? _sse;
  bool _refreshing = false;
  bool _disposed = false;

  // --- orologio -------------------------------------------------------------

  /// Ora corrente, corretta sull'orologio dell'hub.
  DateTime now() => deps.clock().add(_skew);

  /// Un istante dell'hub (ms dall'epoch) nel fuso del browser.
  DateTime localTime(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);

  // --- lingua e tema --------------------------------------------------------

  Lang? _langPref;

  /// Lingua scelta in questo browser (null = automatica).
  Lang? get langPref => _langPref;

  /// Lingua in uso: la scelta salvata, poi quella dell'hub (Admin ›
  /// Generale) se non è `auto`, poi quella del browser, poi l'inglese.
  Lang get lang =>
      _langPref ??
      parseLang(_hub?.language == 'auto' ? null : _hub?.language) ??
      parseLang(platform.languages.join(',')) ??
      Lang.en;

  void setLang(Lang? l) {
    _langPref = l;
    platform.writePref(PrefKeys.lang, l?.name);
    _notify();
  }

  ThemeChoice _theme = ThemeChoice.system;
  ThemeChoice get themeChoice => _theme;

  void setTheme(ThemeChoice t) {
    _theme = t;
    platform.writePref(PrefKeys.theme, t == ThemeChoice.system ? null : t.name);
    _notify();
  }

  /// Luminosità effettiva, dato quella del sistema.
  Brightness brightnessFor(Brightness system) => switch (_theme) {
    ThemeChoice.light => Brightness.light,
    ThemeChoice.dark => Brightness.dark,
    ThemeChoice.system => system,
  };

  MsThemeData themeFor(Brightness system) => MsThemeData(brightness: brightnessFor(system));

  // --- connessione ----------------------------------------------------------

  /// Prima connessione: hub, server, attività, eventi dal vivo.
  Future<void> start() => _refreshHub();

  /// Nuovo tentativo subito ("Riprova").
  Future<void> retry() {
    _retry?.cancel();
    return _refreshHub();
  }

  Future<void> _refreshHub() async {
    if (_refreshing || _disposed) return;
    _refreshing = true;
    final sw = Stopwatch()..start();
    try {
      final info = await api.hub();
      _latencyMs = sw.elapsedMilliseconds;
      final local = deps.clock();
      _skew = Duration(milliseconds: info.time - local.millisecondsSinceEpoch - _latencyMs! ~/ 2);
      // sotto il secondo non conta: niente durate che saltano tra un poll e l'altro
      if (_skew.inSeconds.abs() < 2) _skew = Duration.zero;
      _hub = info;
      final wasOnline = online;
      _connection = HubConnection.online;
      _offlineSince = null;
      _lastError = null;
      if (!wasOnline) {
        await Future.wait([refreshSpaces(), _loadRecentEvents()]);
        _listen();
      }
      _schedulePoll();
    } on ApiError catch (e) {
      if (e.code == ErrorCode.unauthenticated) {
        _setDenied(e);
      } else {
        _setOffline(e);
      }
    } on Object catch (e) {
      _setOffline(e);
    } finally {
      _refreshing = false;
    }
    _notify();
  }

  void _setDenied(Object e) {
    _connection = HubConnection.denied;
    _lastError = e;
    _hub = null;
    _stopLive();
  }

  void _setOffline(Object e) {
    if (_connection != HubConnection.offline) _offlineSince = deps.clock();
    _connection = HubConnection.offline;
    _lastError = e;
    _stopLive();
    _retry?.cancel();
    _retry = Timer(deps.retryEvery, _refreshHub);
  }

  void _stopLive() {
    _sse?.cancel();
    _sse = null;
    _poll?.cancel();
    _poll = null;
  }

  void _schedulePoll() {
    _poll?.cancel();
    _poll = Timer(deps.pollEvery, _refreshHub);
  }

  /// Rilegge l'elenco dei server.
  Future<void> refreshSpaces() async {
    try {
      _spaces = await api.spaces();
      _spacesLoaded = true;
      _notify();
    } on HubOffline catch (e) {
      _setOffline(e);
      _notify();
    } on ApiError catch (e) {
      if (e.code == ErrorCode.unauthenticated) _setDenied(e);
      _notify();
    }
  }

  Future<void> _loadRecentEvents() async {
    try {
      final page = await api.events(before: _maxSeq, limit: eventPageSize);
      _eventsMore = page.more;
      for (final e in page.events) {
        _events[e.seq] = e;
      }
      _trimEvents();
    } on Object {
      // l'attività non è essenziale: resta vuota
    }
  }

  /// Chiede all'hub la pagina di eventi precedente al più vecchio in
  /// memoria. Restituisce quanti ne sono arrivati.
  Future<int> loadOlderEvents() async {
    if (_loadingOlder || _events.isEmpty) return 0;
    _loadingOlder = true;
    _notify();
    try {
      final page = await api.events(before: _events.lastKey()!, limit: eventPageSize);
      _eventsMore = page.more;
      for (final e in page.events) {
        _events[e.seq] = e;
      }
      return page.events.length;
    } finally {
      _loadingOlder = false;
      _notify();
    }
  }

  void _listen() {
    if (_sse != null || _disposed) return;
    final after = _events.isEmpty ? null : _events.firstKey();
    _sse = api
        .eventStream(after: after)
        .listen(
          _onLiveEvent,
          onError: (Object _) {
            // il flusso si riconnette da solo; intanto si verifica l'hub
            if (online) unawaited(_refreshHub());
          },
        );
  }

  void _onLiveEvent(HubEvent e) {
    _events[e.seq] = e;
    _trimEvents();
    _scheduleSpacesRefresh();
    // ruolo, nome dell'hub, disco: si rilegge GET /hub
    if (e.type == EventType.memberRole ||
        e.type == EventType.settings ||
        e.type == EventType.disk) {
      unawaited(_refreshHub());
    }
    _notify();
  }

  void _trimEvents() {
    while (_events.length > _maxEvents) {
      _events.remove(_events.lastKey());
      _eventsMore = true;
    }
  }

  void _scheduleSpacesRefresh() {
    _spacesDebounce?.cancel();
    _spacesDebounce = Timer(const Duration(milliseconds: 250), refreshSpaces);
  }

  // --- azioni condivise -----------------------------------------------------

  /// Crea un server (admin) e aggiorna l'elenco.
  Future<SpaceDetails> createSpace(String name, Profile profile) async {
    final d = await api.createSpace(name, profile);
    _spaces = [..._spaces.where((s) => s.id != d.summary.id), d.summary];
    _notify();
    unawaited(refreshSpaces());
    return d;
  }

  // --- servizio -------------------------------------------------------------

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Imposta lo stato senza rete (test e anteprime).
  @visibleForTesting
  void debugSet({
    HubConnection? connection,
    HubInfo? hub,
    int? latencyMs,
    List<SpaceSummary>? spaces,
    List<HubEvent>? events,
    bool? eventsMore,
    Object? lastError,
    DateTime? offlineSince,
  }) {
    if (connection != null) _connection = connection;
    if (hub != null) _hub = hub;
    if (latencyMs != null) _latencyMs = latencyMs;
    if (spaces != null) {
      _spaces = spaces;
      _spacesLoaded = true;
    }
    if (events != null) {
      _events
        ..clear()
        ..addEntries(events.map((e) => MapEntry(e.seq, e)));
    }
    if (eventsMore != null) _eventsMore = eventsMore;
    if (lastError != null) _lastError = lastError;
    if (offlineSince != null) _offlineSince = offlineSince;
    _notify();
  }

  /// Ferma timer e flusso dal vivo senza chiudere lo stato (test).
  @visibleForTesting
  void debugStop() {
    _poll?.cancel();
    _retry?.cancel();
    _spacesDebounce?.cancel();
    _stopLive();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _retry?.cancel();
    _spacesDebounce?.cancel();
    _sse?.cancel();
    super.dispose();
  }
}

/// Fornisce lo stato ai widget.
class HubStateScope extends InheritedNotifier<HubState> {
  const HubStateScope({super.key, required HubState state, required super.child})
    : super(notifier: state);

  /// Lo stato, ricostruendo il widget a ogni cambiamento.
  static HubState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HubStateScope>()!.notifier!;

  /// Lo stato senza dipendenza (callback, initState).
  static HubState read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<HubStateScope>()!.notifier!;
}
