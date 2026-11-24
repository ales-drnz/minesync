// Prova della porta di gioco di chi ospita (`sessions.portTest`).
//
// Per un lock `play` vivo l'hub apre una connessione TCP verso l'indirizzo
// che vede sul socket di chi ospita (LockState.ip) e la porta pubblicata
// (info.port, 25565 se manca): timeout 3 s, una prova ogni 10 s finché è
// `pending`, per al massimo 3 minuti dalla presa del lock o dal cambio di
// porta (o di indirizzo). Il primo successo dà `reachable`, la finestra
// scaduta `blocked`; spenta o lock di solo push `off`. Il bersaglio non
// arriva mai dalla richiesta (niente SSRF): POST .../lock/port-check fa solo
// ripartire la finestra.
//
// Il servizio non tocca lo store: legge i lock da [PortChecker.locks] a ogni
// giro e scrive l'esito in LockState.portCheck, che finisce nel LockHolder.
import 'dart:async';
import 'dart:io';

import 'package:ms_protocol/ms_protocol.dart';

import 'clock.dart';
import 'state.dart';

/// Apre una connessione TCP verso [host]:[port] entro [timeout]: true se
/// riesce. Iniettabile nei test.
typedef PortConnector = Future<bool> Function(String host, int port, Duration timeout);

/// Connessione TCP vera, chiusa subito.
Future<bool> tcpConnect(String host, int port, Duration timeout) async {
  try {
    final s = await Socket.connect(host, port, timeout: timeout);
    s.destroy();
    return true;
  } on Object {
    return false;
  }
}

/// Porta di Minecraft quando il lock non ne pubblica una.
const defaultGamePort = 25565;

final class _Probe {
  _Probe(this.lock, this.ip, this.port, this.start);

  final LockState lock;
  final String? ip;
  final int port;

  /// Inizio della finestra (tempo monotono).
  final int start;

  /// Prossima prova (tempo monotono).
  late int next = start;
  bool inFlight = false;
}

/// La prova della porta di tutti gli spazi.
final class PortChecker {
  PortChecker({
    required this.clock,
    required this.locks,
    required this.lockTtl,
    required this.publish,
    bool Function(String spaceId)? enabled,
    PortConnector? connect,
    this.timeout = const Duration(seconds: 3),
    this.interval = const Duration(seconds: 10),
    this.window = const Duration(minutes: 3),
    this.rateLimit = const Duration(seconds: 10),
  }) : enabled = enabled ?? ((_) => true),
       connect = connect ?? tcpConnect;

  final Clock clock;

  /// I lock in memoria per spazio (vivi o scaduti).
  final Iterable<(String, LockState)> Function() locks;
  final Duration lockTtl;

  /// `sessions.portTest` effettivo dello spazio (override compreso).
  final bool Function(String spaceId) enabled;
  final PortConnector connect;

  /// Pubblica l'evento `port` (`{state, port}`) di uno spazio.
  final void Function(String spaceId, Map<String, Object?> data) publish;

  final Duration timeout;
  final Duration interval;
  final Duration window;

  /// Distanza minima tra due partenze della finestra per POST port-check.
  final Duration rateLimit;

  final _probes = <String, _Probe>{};

  /// Ultima partenza della finestra per spazio (tempo monotono), anche
  /// quando il lock cambia: il limite vale per lo spazio.
  final _lastStart = <String, int>{};
  Timer? _timer;
  bool _closed = false;

  /// Fa un giro ogni [every] finché non si chiama [close].
  void start({Duration every = const Duration(seconds: 1)}) {
    _timer ??= Timer.periodic(every, (_) => tick().ignore());
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _timer = null;
  }

  int get _now => clock.monoMs();

  static bool _isPlay(LockState l) => l.info.action == 'play';

  PortCheck _set(LockState l, PortState s, int port, {bool stamp = false}) =>
      l.portCheck = PortCheck(state: s, port: port, checkedAt: stamp ? clock.wallMs() : null);

  _Probe _begin(String id, LockState l, int port) {
    final p = _Probe(l, l.ip, port, _now);
    _probes[id] = p;
    _lastStart[id] = p.start;
    _set(l, PortState.pending, port);
    return p;
  }

  /// Un giro: allinea lo stato ai lock e lancia le prove dovute. Il Future
  /// finisce quando sono finite le prove lanciate in questo giro.
  Future<void> tick() async {
    if (_closed) return;
    final seen = <String>{};
    final running = <Future<void>>[];
    for (final (id, l) in locks()) {
      seen.add(id);
      final port = l.info.port ?? defaultGamePort;
      if (!_isPlay(l) || !enabled(id)) {
        _probes.remove(id);
        if (l.portCheck?.state != PortState.off) {
          l.portCheck = const PortCheck(state: PortState.off);
        }
        continue;
      }
      // server che parte o riparte dopo un crash: la finestra comincia quando
      // è in ascolto (un client vecchio non lo dice: si prova subito)
      if (l.info.ready == false) {
        _probes.remove(id);
        if (l.portCheck?.state != PortState.pending) {
          l.portCheck = PortCheck(state: PortState.pending, port: port);
        }
        continue;
      }
      var p = _probes[id];
      // lock nuovo, porta o indirizzo cambiati: la finestra riparte
      if (p == null || !identical(p.lock, l) || p.port != port || p.ip != l.ip) {
        p = _begin(id, l, port);
      }
      if (l.portCheck?.state != PortState.pending || p.inFlight) continue;
      // lock scaduto: nessuna prova finché non torna vivo
      if (l.isStale(clock, lockTtl)) continue;
      if (_now - p.start >= window.inMilliseconds) {
        _finish(id, p, PortState.blocked);
        continue;
      }
      if (_now < p.next) continue;
      running.add(_probe(id, p));
    }
    _probes.removeWhere((id, _) => !seen.contains(id));
    _lastStart.removeWhere((id, _) => !seen.contains(id));
    await Future.wait(running);
  }

  Future<void> _probe(String id, _Probe p) async {
    p.inFlight = true;
    final began = _now;
    var ok = false;
    try {
      final ip = p.ip;
      if (ip != null) {
        ok = await connect(
          ip,
          p.port,
          timeout,
        ).timeout(timeout + const Duration(seconds: 1), onTimeout: () => false);
      }
    } on Object {
      ok = false;
    } finally {
      p.inFlight = false;
    }
    // il lock è cambiato mentre si provava: l'esito non vale più
    if (_closed || !identical(_probes[id], p)) return;
    if (ok) {
      _finish(id, p, PortState.reachable);
    } else {
      p.next = began + interval.inMilliseconds;
    }
  }

  void _finish(String id, _Probe p, PortState s) {
    _set(p.lock, s, p.port, stamp: true);
    publish(id, {'state': s.name, 'port': p.port});
  }

  /// `POST /spaces/{id}/lock/port-check`: fa ripartire la finestra del lock
  /// `play` vivo di [spaceId]. `not_locked` senza, `feature_off` con la prova
  /// spenta, `rate_limited` entro [rateLimit] dall'ultima partenza.
  PortCheck restart(String spaceId) {
    LockState? l;
    for (final (id, x) in locks()) {
      if (id == spaceId) l = x;
    }
    if (l == null || l.isStale(clock, lockTtl) || !_isPlay(l)) {
      throw const ApiError(ErrorCode.notLocked, 'the port test needs a live play lock');
    }
    if (!enabled(spaceId)) {
      throw const ApiError(ErrorCode.featureOff, 'the port test is switched off');
    }
    final last = _lastStart[spaceId];
    if (last != null && _now - last < rateLimit.inMilliseconds) {
      final retry = rateLimit.inMilliseconds - (_now - last);
      throw ApiError(
        ErrorCode.rateLimited,
        'port test restarted too recently',
        details: {'retryMs': retry},
      );
    }
    final p = _begin(spaceId, l, l.info.port ?? defaultGamePort);
    return p.lock.portCheck!;
  }

  /// Stato attuale della prova di [spaceId] (null senza lock o prima del
  /// primo giro).
  PortCheck? stateOf(String spaceId) {
    for (final (id, l) in locks()) {
      if (id == spaceId) return l.portCheck;
    }
    return null;
  }
}
