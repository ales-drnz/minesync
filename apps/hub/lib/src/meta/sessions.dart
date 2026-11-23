// Sessioni di gioco registrate dall'hub dal lock `play` e statistiche.
//
// Una sessione comincia quando si prende un lock con `info.action = play` e
// finisce al rilascio (`released`), alla presa forzata (`forced`) o quando
// il lock diventa stale e nessuno lo rinnova più (`stale`, fine = ultimo
// heartbeat). Uno stale rinnovato da un heartbeat continua la stessa
// sessione. I lock solo di push non sono sessioni.
//
// Fonte: `HubStore.lockListeners`, chiamati in modo sincrono a ogni
// cambiamento del lock (presa, heartbeat, rilascio, forzatura, stale) con il
// motivo esatto: nessun timer né euristica decide come è finita una
// sessione. A ogni heartbeat il tempo trascorso (al più 2 × l'intervallo) va
// a ogni nome in `info.players`. [SessionRecorder.sample] riallinea con lo
// stato del lock solo all'apertura (sessione adottata dopo un riavvio).
//
// Su disco: spaces/<id>/sessions.json, dalla più recente, al più
// `stats.sessionsKept` voci, quella in corso per prima (con il suo ultimo
// heartbeat, per adottarla dopo un riavvio). Scritto all'inizio e alla fine
// di una sessione e al più una volta al minuto nel mezzo.
import 'dart:async';
import 'dart:io';

import 'package:ms_protocol/ms_protocol.dart';

import '../events.dart';
import '../jsonfile.dart';
import '../store.dart';

/// La sessione in corso di uno spazio.
final class _Live {
  _Live(this.memberId, this.name, this.start, this.lastBeat, [Map<String, int>? players])
    : players = players ?? {};

  final String memberId;
  String name;
  final int start;
  int lastBeat;
  final Map<String, int> players;

  /// Il lock è stale: la sessione risulta finita così, salvo un heartbeat.
  bool stale = false;

  bool isOf(LockHolder h) => h.memberId == memberId && h.since == start;

  SessionRecord record({int? end, SessionEnd? ended}) => SessionRecord(
    memberId: memberId,
    name: name,
    start: start,
    end: end ?? (stale ? lastBeat : null),
    ended: ended ?? (stale ? SessionEnd.stale : SessionEnd.ongoing),
    players: Map.of(players),
  );
}

final class _Track {
  _Track(this.space);
  final String space;
  _Live? live;

  /// Finite, dalla più recente.
  final ended = <SessionRecord>[];
  bool dirty = false;
  int lastWrite = 0;
}

/// Registro delle sessioni di tutti gli spazi.
final class SessionRecorder {
  SessionRecorder(
    this._store,
    this._events, {
    required int Function() sessionsKept,
    Duration flushEvery = const Duration(minutes: 1),
    void Function(String)? log,
  }) : sessionsKeptOf = sessionsKept,
       _every = flushEvery,
       _log = log ?? ((m) => stderr.writeln(m));

  final HubStore _store;
  final EventLog _events;

  /// Quante sessioni conservare (`stats.sessionsKept`), letto a ogni uso.
  int Function() sessionsKeptOf;
  final Duration _every;
  final void Function(String) _log;
  final _tracks = <String, _Track>{};
  StreamSubscription<HubEvent>? _sub;
  Timer? _timer;
  Future<void> _io = Future.value();

  int get _cap => _store.options.heartbeat.inMilliseconds * 2;
  int get keep {
    final k = sessionsKeptOf();
    return k < 1 ? 1 : k;
  }

  String _path(String space) => '${_store.spacesDir}/$space/sessions.json';

  /// Carica le sessioni salvate e comincia ad ascoltare.
  Future<void> open() async {
    for (final s in _store.listSpaces()) {
      final t = _tracks[s.id] = _Track(s.id);
      final j = await tryReadJsonFile(_path(s.id));
      if (j is! List<Object?>) continue;
      for (final e in j) {
        try {
          final r = SessionRecord.fromJson(e);
          if (r.ended == SessionEnd.ongoing) {
            // in corso al momento dello spegnimento: si adotta al primo
            // campionamento, o finisce stale all'ultimo heartbeat
            final beat = (e! as Map<String, Object?>)['beat'];
            t.live ??= _Live(
              r.memberId,
              r.name,
              r.start,
              beat is int ? beat : r.start,
              Map.of(r.players),
            );
          } else {
            t.ended.add(r);
          }
        } on Object {
          // voce illeggibile: si salta
        }
      }
    }
    _sub = _events.live
        .where((e) => e.type == EventType.spaceDelete && e.space != null)
        .listen((e) => _tracks.remove(e.space));
    _store.lockListeners.add(_onLock);
    sample();
    // gli heartbeat segnano solo «da scrivere»: si salva al più una volta al minuto
    _timer = Timer.periodic(_every, (_) => _flushDirty());
  }

  void _flushDirty() {
    for (final t in _tracks.values) {
      if (t.dirty) _write(t);
    }
  }

  /// Aspetta che le scritture accodate siano su disco.
  Future<void> flush() => _io;

  /// Ferma il campionamento e salva.
  Future<void> close() async {
    _timer?.cancel();
    _store.lockListeners.remove(_onLock);
    await _sub?.cancel();
    for (final t in _tracks.values) {
      if (t.dirty) _write(t);
    }
    await _io;
  }

  // ---------------------------------------------------------------- lettura

  /// Sessioni conservate di [space], dalla più recente (quella in corso
  /// prima).
  List<SessionRecord> sessions(String space) {
    final t = _tracks[space];
    if (t == null) return const [];
    final out = [if (t.live != null) t.live!.record(), ...t.ended];
    return out.length > keep ? out.sublist(0, keep) : out;
  }

  /// L'ultima sessione finita di [space].
  SessionRecord? lastSession(String space) {
    final t = _tracks[space];
    if (t == null) return null;
    if (t.live != null && t.live!.stale) return t.live!.record();
    return t.ended.firstOrNull;
  }

  /// `GET /spaces/{id}/stats`: classifiche sulle sessioni conservate.
  SpaceStats stats(String space) {
    final list = sessions(space);
    final now = _store.clock.wallMs();
    final play = <String, int>{};
    final host = <String, int>{};
    final hostName = <String, String>{};
    for (final s in list) {
      s.players.forEach((k, v) => play[k] = (play[k] ?? 0) + v);
      final end = s.end ?? now;
      host[s.memberId] = (host[s.memberId] ?? 0) + (end > s.start ? end - s.start : 0);
      hostName.putIfAbsent(s.memberId, () => s.name); // il nome più recente
    }
    List<RankEntry> top(Map<String, int> m, RankEntry Function(String, int) f) {
      final e = m.entries.toList()
        ..sort((a, b) => b.value != a.value ? b.value.compareTo(a.value) : a.key.compareTo(b.key));
      return [for (final x in e.take(10)) f(x.key, x.value)];
    }

    return SpaceStats(
      kept: keep,
      sessions: list,
      play: top(play, (k, v) => RankEntry(name: k, ms: v)),
      hosting: top(host, (k, v) => RankEntry(name: hostName[k]!, ms: v, memberId: k)),
    );
  }

  // ---------------------------------------------------------------- registrazione

  void _onLock(LockChange c) {
    final t = _tracks.putIfAbsent(c.space, () => _Track(c.space));
    final h = c.holder;
    final live = t.live;
    final mine = live != null && live.isOf(h);
    switch (c.kind) {
      case LockChangeKind.acquired:
        // presa senza forzare: quello di prima era stale (o non c'era). Una
        // presa forzata arriva dopo `forced`, che ha già chiuso la sessione.
        if (live != null && !mine) _end(t, SessionEnd.stale, live.lastBeat);
        if (h.info.action == 'play' && t.live == null) _start(t, h);
      case LockChangeKind.renewed:
        if (mine) {
          _beat(t, live, h);
        } else if (h.info.action == 'play') {
          // un lock di push diventato di gioco, o mai visto (adozione)
          if (live != null) _end(t, SessionEnd.stale, live.lastBeat);
          _start(t, h);
        }
      case LockChangeKind.released:
        if (mine) {
          _end(t, live.stale ? SessionEnd.stale : SessionEnd.released, _store.clock.wallMs());
        }
      case LockChangeKind.forced:
        if (mine) _end(t, live.stale ? SessionEnd.stale : SessionEnd.forced, _store.clock.wallMs());
      case LockChangeKind.stale:
        if (mine && !live.stale) {
          live.stale = true;
          _write(t);
        }
    }
  }

  void _start(_Track t, LockHolder h) {
    t.live = _Live(h.memberId, h.name, h.since, h.lastBeat)..stale = h.stale;
    _write(t);
  }

  void _beat(_Track t, _Live live, LockHolder h) {
    live.name = h.name;
    if (h.lastBeat > live.lastBeat) {
      final d = h.lastBeat - live.lastBeat;
      final add = d > _cap ? _cap : d;
      for (final p in h.info.players) {
        live.players[p] = (live.players[p] ?? 0) + add;
      }
      live.lastBeat = h.lastBeat;
      t.dirty = true;
    }
    if (live.stale && !h.stale) {
      // rinnovato: è la stessa sessione
      live.stale = false;
      _write(t);
    } else if (t.dirty && _store.clock.wallMs() - t.lastWrite >= 60000) {
      _write(t);
    }
  }

  /// Riallinea con lo stato attuale dei lock (all'apertura, e nei test):
  /// adotta la sessione in corso, chiude quelle il cui lock non c'è più,
  /// segna gli stale. Gli heartbeat li conta solo [_onLock].
  void sample() {
    final seen = <String>{};
    for (final s in _store.listSpaces()) {
      seen.add(s.id);
      final t = _tracks.putIfAbsent(s.id, () => _Track(s.id));
      final h = s.lock;
      final live = t.live;
      if (live != null && h != null && live.isOf(h)) {
        if (h.stale && !live.stale) {
          live.stale = true;
          _write(t);
        }
        continue;
      }
      // il lock della sessione non c'è più (spento durante un riavvio)
      if (live != null) _end(t, SessionEnd.stale, live.lastBeat);
      if (h != null && h.info.action == 'play') _start(t, h);
    }
    _tracks.removeWhere((id, _) => !seen.contains(id));
  }

  void _end(_Track t, SessionEnd how, int end) {
    final l = t.live;
    if (l == null) return;
    t.live = null;
    final e = how == SessionEnd.stale ? l.lastBeat : end;
    t.ended.insert(0, l.record(end: e < l.start ? l.start : e, ended: how));
    if (t.ended.length > keep) t.ended.removeRange(keep, t.ended.length);
    _write(t);
  }

  void _write(_Track t) {
    t.dirty = false;
    t.lastWrite = _store.clock.wallMs();
    final live = t.live;
    final body = [
      if (live != null) {...live.record().toJson(), if (!live.stale) 'beat': live.lastBeat},
      ...[for (final r in t.ended) r.toJson()],
    ];
    if (body.length > keep) body.removeRange(keep, body.length);
    final space = t.space;
    _io = _io.then((_) async {
      // lo spazio può essere stato cancellato nel frattempo
      if (!_tracks.containsKey(space) || !Directory('${_store.spacesDir}/$space').existsSync()) {
        return;
      }
      try {
        await writeJsonAtomic(_path(space), body);
      } on FileSystemException catch (e) {
        _log('hub: sessioni di $space non scritte: $e');
      }
    });
  }
}
