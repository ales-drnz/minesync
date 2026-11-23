// Client HTTP dell'API v1 dell'hub. Ogni richiesta porta l'intestazione
// X-MineSync; gli errori dell'hub diventano ApiError, quelli di rete
// HubUnreachable, i trasferimenti fermi TransferStalled.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ms_protocol/ms_protocol.dart';

/// L'hub non risponde (rete, DNS, connessione rifiutata, timeout).
final class HubUnreachable implements Exception {
  const HubUnreachable(this.cause);
  final Object cause;
  @override
  String toString() => 'HubUnreachable: $cause';
}

/// Un trasferimento non avanza più: interrotto dal watchdog.
final class TransferStalled implements Exception {
  const TransferStalled(this.what);
  final String what;
  @override
  String toString() => 'TransferStalled: $what';
}

/// Client dell'hub.
final class HubClient {
  HubClient(
    Uri base, {
    HttpClient? http,
    this.idleTimeout = const Duration(seconds: 30),
    this.userAgent = 'minesync/0.1.0',
  }) : base = base.replace(path: base.path.endsWith('/') ? base.path : '${base.path}/'),
       _http = http ?? (HttpClient()..connectionTimeout = const Duration(seconds: 10));

  final Uri base;
  final HttpClient _http;

  /// Senza un byte in entrata o in uscita per tanto tempo, il trasferimento
  /// è considerato fermo.
  final Duration idleTimeout;
  final String userAgent;

  Uri _u(String path, [Map<String, String>? query]) {
    final p = base.resolve('api/v1/$path');
    return query == null || query.isEmpty ? p : p.replace(queryParameters: query);
  }

  void close({bool force = false}) => _http.close(force: force);

  // --- chiamate JSON ----------------------------------------------------------

  Future<HubInfo> hub() async => HubInfo.fromJson(await _json('GET', 'hub'));

  Future<List<SpaceSummary>> spaces() async {
    final j = await _json('GET', 'spaces') as Map<String, Object?>;
    return [for (final s in j['spaces'] as List<Object?>) SpaceSummary.fromJson(s)];
  }

  Future<SpaceDetails> space(String id) async =>
      SpaceDetails.fromJson(await _json('GET', 'spaces/${_seg(id)}'));

  Future<SpaceSummary> createSpace(String name, Profile profile) async => SpaceSummary.fromJson(
    await _json('POST', 'spaces', body: {'name': name, 'profile': profile.name}),
  );

  /// Generazione [n], o la testa se null.
  Future<Generation> generation(String id, {int? n}) async =>
      Generation.fromJson(await _json('GET', 'spaces/${_seg(id)}/generations/${n ?? 'head'}'));

  Future<List<GenerationSummary>> generations(String id, {int? before, int? limit}) async {
    final j =
        await _json(
              'GET',
              'spaces/${_seg(id)}/generations',
              query: {'before': ?before?.toString(), 'limit': ?limit?.toString()},
            )
            as Map<String, Object?>;
    return [for (final g in j['generations'] as List<Object?>) GenerationSummary.fromJson(g)];
  }

  /// Crea una nuova testa uguale alla generazione [n] (solo admin, a lock
  /// libero o proprio). Non si perde niente: la vecchia testa resta nella storia.
  Future<GenerationSummary> restore(String id, int n, {String message = ''}) async =>
      GenerationSummary.fromJson(
        await _json(
          'POST',
          'spaces/${_seg(id)}/restore',
          body: {'generation': n, if (message.isNotEmpty) 'message': message},
        ),
      );

  Future<LockGrant> acquireLock(String id, LockInfo info, {bool force = false}) async =>
      LockGrant.fromJson(
        await _json(
          'POST',
          'spaces/${_seg(id)}/lock',
          body: {'info': info.toJson(), if (force) 'force': true},
        ),
      );

  Future<void> heartbeat(String id, String token, LockInfo info) => _json(
    'POST',
    'spaces/${_seg(id)}/lock/heartbeat',
    body: {'token': token, 'info': info.toJson()},
  );

  Future<void> releaseLock(String id, String token) =>
      _json('DELETE', 'spaces/${_seg(id)}/lock', body: {'token': token});

  /// Inizio di un push. Il corpo (che contiene il manifest) va compresso.
  Future<PushStarted> beginPush(String id, PushBegin push) async => PushStarted.fromJson(
    await _json('POST', 'spaces/${_seg(id)}/pushes', body: push.toJson(), gzipBody: true),
  );

  Future<GenerationSummary> commitPush(String pushId) async =>
      GenerationSummary.fromJson(await _json('POST', 'pushes/${_seg(pushId)}/commit'));

  Future<void> abortPush(String pushId) => _json('DELETE', 'pushes/${_seg(pushId)}');

  Future<List<HubEvent>> events({int? after}) async => (await eventsAfter(after ?? 0)).events;

  /// Eventi con seq > [after], dal più vecchio, filtrabili per spazio e tipi.
  Future<EventPage> eventsAfter(
    int after, {
    int? limit,
    String? space,
    List<String>? types,
  }) async => EventPage.fromJson(
    await _json(
      'GET',
      'events',
      query: {if (after > 0) 'after': '$after', ..._eventFilters(limit, space, types)},
    ),
  );

  /// Eventi più vecchi di [before], **dal più recente** (anche quelli già
  /// usciti dalla memoria dell'hub, letti dal disco): per sfogliare
  /// l'attività all'indietro.
  Future<EventPage> eventsBefore(
    int before, {
    int? limit,
    String? space,
    List<String>? types,
  }) async => EventPage.fromJson(
    await _json(
      'GET',
      'events',
      query: {'before': '$before', ..._eventFilters(limit, space, types)},
    ),
  );

  static Map<String, String> _eventFilters(int? limit, String? space, List<String>? types) => {
    'limit': ?limit?.toString(),
    'space': ?space,
    if (types != null && types.isNotEmpty) 'types': types.join(','),
  };

  // --- lock, storia, pulizia, mondo -------------------------------------------

  /// Fa ripartire la prova della porta del lock di gioco. 409 `not_locked`
  /// senza un lock di gioco vivo, 409 `feature_off` con la prova spenta,
  /// 429 `rate_limited` entro 10 s dall'ultima partenza.
  Future<PortCheck> portCheck(String id) async =>
      PortCheck.fromJson(await _json('POST', 'spaces/${_seg(id)}/lock/port-check'));

  /// Anteprima della pulizia (admin): con [keep] tiene le ultime N
  /// generazioni di ogni spazio, con [history] prova regole non salvate,
  /// senza nessuno dei due applica le regole attuali. Con [space] riguarda
  /// solo quello spazio. Non cambia niente.
  Future<GcPreview> gcPreview({int? keep, HistorySettings? history, String? space}) async =>
      GcPreview.fromJson(
        await _json(
          'POST',
          space == null ? 'gc/preview' : 'spaces/${_seg(space)}/gc/preview',
          body: {'keep': ?keep, if (history != null) 'history': history.toJson()},
        ),
      );

  /// Pulizia adesso (admin), con le stesse regole di [gcPreview].
  Future<GcReport> gc({int? keep, String? space}) async => GcReport.fromJson(
    await _json('POST', space == null ? 'gc' : 'spaces/${_seg(space)}/gc', body: {'keep': ?keep}),
  );

  /// Spazio occupato sull'hub, per spazio.
  Future<HubUsage> usage() async => HubUsage.fromJson(await _json('GET', 'usage'));

  /// level.dat, server.properties e riassunto del mondo della HEAD.
  Future<WorldInfo> world(String id) async =>
      WorldInfo.fromJson(await _json('GET', 'spaces/${_seg(id)}/world'));

  Future<PlayerList> players(String id) async =>
      PlayerList.fromJson(await _json('GET', 'spaces/${_seg(id)}/players'));

  Future<ModList> mods(String id) async =>
      ModList.fromJson(await _json('GET', 'spaces/${_seg(id)}/mods'));

  /// Sessioni e classifiche.
  Future<SpaceStats> stats(String id) async =>
      SpaceStats.fromJson(await _json('GET', 'spaces/${_seg(id)}/stats'));

  /// Cosa cambia la generazione [n] rispetto alla precedente; al più
  /// [limit] righe per gruppo (default dell'hub: [diffDefaultLimit]).
  Future<GenerationChanges> diff(String id, int n, {int? limit}) async =>
      GenerationChanges.fromJson(
        await _json(
          'GET',
          'spaces/${_seg(id)}/generations/$n/diff',
          query: {'limit': ?limit?.toString()},
        ),
      );

  /// Nuova testa uguale all'attuale con un solo file ripreso da una
  /// generazione precedente (admin, nessun lock vivo).
  Future<GenerationSummary> restoreFile(String id, RestoreFileRequest r) async =>
      GenerationSummary.fromJson(
        await _json('POST', 'spaces/${_seg(id)}/restore-file', body: r.toJson()),
      );

  /// Byte che si libererebbero eliminando la generazione [n] (admin).
  Future<int> freedBy(String id, int n) async {
    final j = await _json('GET', 'spaces/${_seg(id)}/generations/$n/freed') as Map<String, Object?>;
    return j['bytes'] as int? ?? 0;
  }

  /// Elimina la generazione [n], non la testa (admin, irreversibile).
  Future<({int deleted, int bytes})> deleteGeneration(String id, int n) async {
    final j = await _json('DELETE', 'spaces/${_seg(id)}/generations/$n') as Map<String, Object?>;
    return (deleted: j['deleted'] as int? ?? n, bytes: j['bytes'] as int? ?? 0);
  }

  /// Scarica la generazione [n] (la testa se null) come ZIP nel file [path].
  /// Il file compare solo completo: si scrive in `<path>.part` e si rinomina
  /// alla fine; con un errore il parziale si cancella. [onProgress] riceve i
  /// byte arrivati e il totale (se l'hub lo dice). Restituisce i byte scritti.
  Future<int> exportZip(
    String id,
    String path, {
    int? n,
    void Function(int received, int? total)? onProgress,
    Future<Object>? abort,
  }) async {
    final what = 'zip $id';
    final req = await _open('GET', _u('spaces/${_seg(id)}/generations/${n ?? 'head'}/zip'));
    final watch = _Watchdog(idleTimeout, () => req.abort(TransferStalled(what)));
    Object? aborted;
    unawaited(
      abort?.then((reason) {
        aborted = reason;
        req.abort(reason);
      }),
    );
    final part = File('$path.part');
    IOSink? out;
    var done = false;
    try {
      final res = await _close(req);
      watch.kick();
      if (res.statusCode != 200) await _drainOrThrow(res);
      watch.stop();
      final total = res.contentLength >= 0 ? res.contentLength : null;
      final sink = out = part.openWrite();
      var got = 0;
      await for (final b in _idle(res, what)) {
        sink.add(b);
        got += b.length;
        onProgress?.call(got, total);
      }
      out = null;
      await sink.close();
      if (total != null && got != total) {
        throw HubUnreachable('ZIP incompleto: $got di $total byte');
      }
      await part.rename(path);
      done = true;
      return got;
    } on FileSystemException {
      // disco locale (pieno, permessi): non è colpa dell'hub
      rethrow;
    } on IOException catch (e) {
      if (aborted != null) throw aborted!;
      throw watch.fired ? TransferStalled(what) : HubUnreachable(e);
    } finally {
      watch.stop();
      if (!done) {
        try {
          await out?.close();
        } on Object {
          // il parziale si cancella comunque
        }
        try {
          if (part.existsSync()) part.deleteSync();
        } on FileSystemException {
          // niente da fare
        }
      }
    }
  }

  /// Eventi in tempo reale (Server-Sent Events). Lo stream finisce quando la
  /// connessione cade: chi lo usa si riconnette passando l'ultimo `seq` visto
  /// in [after]. Un keep-alive dell'hub arriva almeno ogni 15 s, quindi un
  /// silenzio più lungo di [idleTimeout] chiude lo stream.
  Stream<HubEvent> eventStream({int? after}) {
    late final StreamController<HubEvent> out;
    StreamSubscription<String>? sub;
    out = StreamController<HubEvent>(
      onListen: () async {
        try {
          final req = await _open('GET', _u('events/stream'));
          req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
          if (after != null) req.headers.set('Last-Event-ID', '$after');
          final res = await _close(req);
          if (res.statusCode >= 400) {
            await _drainOrThrow(res);
            return;
          }
          if (out.isClosed) {
            res.detachSocket().then((s) => s.destroy()).ignore();
            return;
          }
          final data = StringBuffer();
          sub = _idle(res, 'events')
              .cast<List<int>>()
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen(
                (line) {
                  if (line.isEmpty) {
                    if (data.isEmpty) return;
                    final text = data.toString();
                    data.clear();
                    try {
                      out.add(HubEvent.fromJson(jsonDecode(text)));
                    } on FormatException {
                      // evento non riconosciuto: si salta
                    }
                  } else if (line.startsWith('data:')) {
                    if (data.isNotEmpty) data.write('\n');
                    data.write(line.substring(5).trimLeft());
                  }
                  // "id:", "event:" e i commenti ": keep-alive" non servono:
                  // il seq è nel JSON
                },
                onError: (Object e) {
                  if (!out.isClosed) out.addError(e is IOException ? HubUnreachable(e) : e);
                },
                onDone: () => out.close(),
                cancelOnError: true,
              );
        } on Object catch (e) {
          if (!out.isClosed) {
            out.addError(e);
            await out.close();
          }
        }
      },
      // la cancellazione non aspetta la connessione: un await qui resterebbe
      // appeso fino al prossimo evento dell'hub
      onCancel: () {
        sub?.cancel().ignore();
      },
    );
    return out.stream;
  }

  // --- blob -------------------------------------------------------------------

  /// Carica un blob. [data] produce esattamente [size] byte; [onProgress]
  /// riceve i byte inviati.
  Future<void> uploadBlob(
    String pushId,
    String hash,
    int size,
    Stream<List<int>> data, {
    void Function(int sent)? onProgress,
    Future<Object>? abort,
  }) async {
    final req = await _open('PUT', _u('pushes/${_seg(pushId)}/blobs/$hash'));
    req.headers
      ..contentType = ContentType.binary
      ..contentLength = size;
    final watch = _Watchdog(idleTimeout, () => req.abort(TransferStalled('upload $hash')));
    Object? aborted;
    unawaited(
      abort?.then((reason) {
        aborted = reason;
        req.abort(reason);
      }),
    );
    try {
      await req.addStream(
        data.map((b) {
          watch.kick();
          onProgress?.call(b.length);
          return b;
        }),
      );
      final res = await _close(req);
      watch.kick();
      await _drainOrThrow(res);
    } on TransferStalled {
      rethrow;
    } on ApiError {
      rethrow;
    } on IOException catch (e) {
      if (aborted != null) throw aborted!;
      throw watch.fired ? TransferStalled('upload $hash') : HubUnreachable(e);
    } finally {
      watch.stop();
    }
  }

  /// Scarica un blob (o un intervallo con [offset]) in [sink]. Restituisce i
  /// byte ricevuti. [onProgress] riceve i byte man mano.
  Future<int> downloadBlob(
    String hash,
    void Function(Uint8List chunk) sink, {
    void Function(int received)? onProgress,
    int offset = 0,
  }) async {
    final req = await _open('GET', _u('blobs/$hash'));
    if (offset > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
    final watch = _Watchdog(idleTimeout, () => req.abort(TransferStalled('download $hash')));
    var got = 0;
    try {
      final res = await _close(req);
      watch.kick();
      if (res.statusCode != 200 && res.statusCode != 206) await _drainOrThrow(res);
      watch.stop();
      await for (final b in _idle(res, 'download $hash')) {
        final u = b is Uint8List ? b : Uint8List.fromList(b);
        sink(u);
        got += u.length;
        onProgress?.call(u.length);
      }
      return got;
    } on ApiError {
      rethrow;
    } on TransferStalled {
      rethrow;
    } on IOException catch (e) {
      throw watch.fired ? TransferStalled('download $hash') : HubUnreachable(e);
    } finally {
      watch.stop();
    }
  }

  // --- interni ----------------------------------------------------------------

  Future<HttpClientRequest> _open(String method, Uri uri) async {
    try {
      final req = await _http.openUrl(method, uri);
      req.headers
        ..set(csrfHeader, '1')
        ..set(HttpHeaders.userAgentHeader, userAgent);
      return req;
    } on IOException catch (e) {
      throw HubUnreachable(e);
    }
  }

  Future<HttpClientResponse> _close(HttpClientRequest req) async {
    try {
      return await req.close();
    } on IOException catch (e) {
      throw HubUnreachable(e);
    }
  }

  Future<Object?> _json(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    bool gzipBody = false,
  }) async {
    final req = await _open(method, _u(path, query));
    final watch = _Watchdog(idleTimeout, () => req.abort(TransferStalled('$method $path')));
    try {
      if (body != null) {
        var bytes = utf8.encode(jsonEncode(body));
        req.headers.contentType = ContentType.json;
        if (gzipBody) {
          bytes = Uint8List.fromList(gzip.encode(bytes));
          req.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
        }
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final res = await _close(req);
      watch.kick();
      watch.stop();
      final raw = BytesBuilder(copy: false);
      await for (final b in _idle(res, '$method $path')) {
        raw.add(b);
      }
      final text = utf8.decode(raw.takeBytes(), allowMalformed: true);
      final Object? decoded;
      try {
        decoded = text.isEmpty ? null : jsonDecode(text);
      } on FormatException {
        if (res.statusCode >= 400) {
          throw ApiError(ErrorCode.internal, 'HTTP ${res.statusCode}', status: res.statusCode);
        }
        rethrow;
      }
      if (res.statusCode >= 400) throw ApiError.fromJson(decoded, status: res.statusCode);
      return decoded;
    } on IOException catch (e) {
      throw watch.fired ? TransferStalled('$method $path') : HubUnreachable(e);
    } finally {
      watch.stop();
    }
  }

  Future<void> _drainOrThrow(HttpClientResponse res) async {
    final raw = BytesBuilder(copy: false);
    await for (final b in res) {
      raw.add(b);
    }
    if (res.statusCode < 400) return;
    Object? j;
    try {
      j = jsonDecode(utf8.decode(raw.takeBytes(), allowMalformed: true));
    } on FormatException {
      j = null;
    }
    throw ApiError.fromJson(j, status: res.statusCode);
  }

  /// Lo stream della risposta con il watchdog: se tra due pezzi passa più di
  /// [idleTimeout] la sottoscrizione si annulla (e la connessione si chiude).
  Stream<List<int>> _idle(Stream<List<int>> s, String what) => s.timeout(
    idleTimeout,
    onTimeout: (sink) {
      sink
        ..addError(TransferStalled(what))
        ..close();
    },
  );

  static String _seg(String s) => Uri.encodeComponent(s);
}

/// Timer che scatta se nessuno lo "calcia" per [timeout].
final class _Watchdog {
  _Watchdog(this.timeout, this.onFire) {
    kick();
  }

  final Duration timeout;
  final void Function() onFire;
  Timer? _t;
  bool fired = false;

  void kick() {
    _t?.cancel();
    _t = Timer(timeout, () {
      fired = true;
      onFire();
    });
  }

  void stop() => _t?.cancel();
}

/// Una pagina di `GET /events`: [events] nell'ordine della richiesta (dal
/// più vecchio con `after`, dal più recente con `before`), [last] = ultimo
/// seq dell'hub, [oldest] = il più vecchio ancora sul disco, [more] = ce ne
/// sono altri oltre questa pagina.
final class EventPage {
  const EventPage({required this.events, this.last, this.oldest, this.more = false});

  factory EventPage.fromJson(Object? j) {
    if (j is! Map<String, Object?>) throw const FormatException('events: atteso un oggetto');
    final list = j['events'];
    if (list is! List<Object?>) throw const FormatException('events: attesa una lista');
    return EventPage(
      events: [for (final e in list) HubEvent.fromJson(e)],
      last: j['last'] as int?,
      oldest: j['oldest'] as int?,
      more: j['more'] == true,
    );
  }

  final List<HubEvent> events;
  final int? last;
  final int? oldest;
  final bool more;
}
