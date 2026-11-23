// Extra dell'hub sul mondo: dati della HEAD (mondo, giocatori, mod, icone)
// e sessioni/statistiche, con le loro rotte sotto /api/v1. Si collega al
// server con [WorldExtras.handle] e ai riassunti degli spazi con
// [WorldExtras.chip] e [WorldExtras.lastSession].
import 'dart:convert';
import 'dart:io';

import 'package:ms_protocol/ms_protocol.dart';

import '../events.dart';
import '../members.dart';
import '../store.dart';
import 'sessions.dart';
import 'world.dart';

export 'sessions.dart' show SessionRecorder;
export 'world.dart' show Icon, WorldMeta;

/// Mondo, giocatori, mod, icone, sessioni e statistiche degli spazi.
final class WorldExtras {
  WorldExtras(
    this._store,
    EventLog events, {
    int Function()? sessionsKept,
    void Function(String)? log,
  }) : world = WorldMeta(_store, log: log),
       sessions = SessionRecorder(
         _store,
         events,
         sessionsKept: sessionsKept ?? () => defaultSessionsKept(_store),
         log: log,
       ),
       _events = events;

  final HubStore _store;
  final EventLog _events;
  final WorldMeta world;
  final SessionRecorder sessions;

  /// `stats.sessionsKept` dalle impostazioni, 40 se la sezione non c'è.
  static int defaultSessionsKept(HubStore store) {
    final v = store.settings.section('stats')['sessionsKept'];
    return v is int && v > 0 ? v : 40;
  }

  Future<void> open() async {
    await sessions.open();
    _events.live.where((e) => e.type == EventType.spaceDelete && e.space != null).listen((e) {
      world.forget(e.space!).ignore();
    });
  }

  Future<void> close() async {
    await world.close();
    await sessions.close();
  }

  /// [WorldChip] della HEAD per `SpaceSummary.world` (null finché non è
  /// calcolato: il calcolo parte in sottofondo).
  WorldChip? chip(String space, String digest) => world.chip(space, digest);

  /// Per `SpaceSummary.lastSession`.
  SessionRecord? lastSession(String space) => sessions.lastSession(space);

  /// Gestisce le rotte degli extra; false se [segs] (il percorso dopo
  /// /api/v1) non è loro.
  Future<bool> handle(HttpRequest req, Identity who, bool admin, List<String> segs) async {
    if (req.method != 'GET' || segs.length < 3 || segs[0] != 'spaces') return false;
    final id = segs[1];
    switch (segs.sublist(2)) {
      case ['world']:
        await _json(req, (await world.world(id)).toJson());
      case ['players']:
        await _json(req, (await world.players(id)).toJson());
      case ['mods']:
        await _json(req, (await world.mods(id)).toJson());
      case ['stats']:
        _store.details(id); // not_found se lo spazio non c'è
        await _json(req, sessions.stats(id).toJson());
      case ['icon']:
        await _png(req, await world.icon(id), 'no server icon');
      case ['mods', final file, 'icon']:
        await _png(req, await world.modIcon(id, file), 'no icon for this mod');
      default:
        return false;
    }
    return true;
  }

  static Future<void> _json(HttpRequest req, Object? body) async {
    final res = req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await res.close();
  }

  static Future<void> _png(HttpRequest req, Icon? icon, String missing) async {
    if (icon == null) throw ApiError(ErrorCode.notFound, missing);
    final res = req.response;
    final etag = '"${icon.etag}"';
    res.headers
      ..set(HttpHeaders.cacheControlHeader, 'private, max-age=86400')
      ..set(HttpHeaders.etagHeader, etag);
    final inm = req.headers.value(HttpHeaders.ifNoneMatchHeader);
    if (inm != null && inm.split(',').map((s) => s.trim()).contains(etag)) {
      res.statusCode = HttpStatus.notModified;
      return res.close();
    }
    res
      ..statusCode = 200
      ..headers.contentType = ContentType('image', 'png')
      ..contentLength = icon.bytes.length
      ..add(icon.bytes);
    await res.close();
  }
}
