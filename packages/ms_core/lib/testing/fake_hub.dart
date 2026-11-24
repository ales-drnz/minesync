// Solo per i test (di questo pacchetto e di chi lo usa): non è esportato da
// package:ms_core/ms_core.dart.
// Hub finto in memoria per i test del motore: stessa API v1, stesse regole
// essenziali (lock, compare-and-swap, guardia di cancellazione, commit
// idempotente) e guasti iniettabili. Il vero hub ha i suoi test in apps/hub.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:ms_protocol/ms_protocol.dart';

final class _Space {
  _Space(this.id, this.name);
  final String id;
  final String name;
  final gens = <Generation>[];
  String? lockToken;
  String? lockOwner;
  DateTime lockBeat = DateTime.now();

  /// Impostazioni effettive restituite da GET /spaces/{id} (null = l'hub
  /// non le manda).
  SpaceSettings? settings;
}

final class _Push {
  _Push(this.space, this.begin, this.owner);
  final _Space space;
  final PushBegin begin;
  final String owner;
  GenerationSummary? committed;
}

/// Corpo binario per una risposta di [FakeHub.stubs].
final class FakeBytes {
  FakeBytes(this.bytes, {ContentType? contentType, this.declaredLength, this.chunked = false})
    : contentType = contentType ?? ContentType.binary;

  final List<int> bytes;
  final ContentType contentType;

  /// Content-Length dichiarato se diverso dalla lunghezza vera (risposta
  /// troncata).
  final int? declaredLength;

  /// Senza Content-Length.
  final bool chunked;
}

final class FakeHub {
  FakeHub._(this._server);

  static Future<FakeHub> start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final hub = FakeHub._(s);
    s.listen(hub._handle);
    return hub;
  }

  final HttpServer _server;
  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}/');

  final blobs = <String, Uint8List>{};
  final _spaces = <String, _Space>{};
  final _pushes = <String, _Push>{};
  var _seq = 0;

  /// Identità di chi chiama (il vero hub la ricava dalla rete).
  String member = 'alice';
  bool admin = false;
  Duration lockTtl = const Duration(seconds: 90);
  int heartbeatMs = 20000;

  // --- guasti iniettabili ---
  /// Il prossimo commit va a buon fine ma la risposta si perde.
  bool dropNextCommitResponse = false;

  /// Blob serviti corrotti.
  final corrupt = <String>{};

  /// Blob il cui download si ferma a metà senza chiudere.
  final stall = <String>{};

  /// Hub «spento»: ogni connessione si chiude senza risposta.
  bool down = false;

  /// Contatori per le asserzioni.
  final calls = <String, int>{};
  final putCounts = <String, int>{};
  final missingHeader = <String>[];

  Future<void> close() => _server.close(force: true);

  // --- API di comodo per preparare gli scenari ---

  String createSpace(String name) {
    final id = name.toLowerCase();
    _spaces[id] = _Space(id, name);
    return id;
  }

  Generation? head(String id) => _spaces[id]!.gens.lastOrNull;

  /// Impostazioni effettive dello spazio (sessioni, storia, protezioni),
  /// come le calcola il vero hub; valgono anche per la guardia di
  /// cancellazione del finto.
  void setSettings(String id, SpaceSettings? s) => _spaces[id]!.settings = s;

  /// Scrive direttamente una generazione (come se l'avesse caricata un altro).
  Generation commitDirect(String id, Map<String, List<int>> files, {String author = 'bob'}) {
    final s = _spaces[id]!;
    final entries = <String, FileEntry>{};
    for (final f in files.entries) {
      final h = crypto.sha256.convert(f.value).toString();
      blobs[h] = Uint8List.fromList(f.value);
      entries[f.key] = FileEntry(size: f.value.length, h: h);
    }
    return _addGen(s, Manifest(entries), author, '', GenerationKind.push);
  }

  /// Sostituisce il contenuto dell'ultima generazione tenendo il numero (hub
  /// ripristinato da un backup).
  void rewriteHead(String id, Map<String, List<int>> files) {
    final s = _spaces[id]!;
    final old = s.gens.removeLast();
    final g = commitDirect(id, files);
    s.gens.removeLast();
    s.gens.add(
      Generation(
        GenerationSummary(
          n: old.n,
          parent: old.summary.parent,
          digest: g.digest,
          authorId: 'bob',
          author: 'bob',
          message: '',
          ts: 0,
          kind: GenerationKind.push,
          stats: g.summary.stats,
        ),
        g.manifest,
      ),
    );
  }

  /// Prende il lock come un altro membro.
  void stealLock(String id, String who) {
    final s = _spaces[id]!;
    s.lockToken = 'stolen-$who';
    s.lockOwner = who;
    s.lockBeat = DateTime.now();
  }

  Generation _addGen(_Space s, Manifest m, String author, String msg, GenerationKind kind) {
    final prev = s.gens.lastOrNull?.manifest ?? Manifest.empty;
    final d = ManifestDiff(prev, m);
    final g = Generation(
      GenerationSummary(
        n: s.gens.length + 1,
        parent: s.gens.length,
        digest: m.digest(),
        authorId: author,
        author: author,
        message: msg,
        ts: DateTime.now().millisecondsSinceEpoch,
        kind: kind,
        stats: GenerationStats(
          files: m.length,
          size: m.totalSize,
          added: d.added.length,
          changed: d.changed.length,
          removed: d.removed.length,
        ),
      ),
      m,
    );
    s.gens.add(g);
    return g;
  }

  bool _lockLive(_Space s) =>
      s.lockToken != null && DateTime.now().difference(s.lockBeat) < lockTtl;

  // --- HTTP ---

  Future<void> _handle(HttpRequest req) async {
    if (down) {
      (await req.response.detachSocket(writeHeaders: false)).destroy();
      return;
    }
    final res = req.response;
    final segs = req.uri.pathSegments.skip(2).toList(); // dopo api/v1
    final key =
        '${req.method} ${segs.isEmpty ? '' : segs.first}${segs.length > 2 ? '/${segs[2]}' : ''}';
    calls[key] = (calls[key] ?? 0) + 1;
    if (req.headers.value(csrfHeader) != '1') missingHeader.add(key);
    try {
      final out = await _route(req, segs);
      if (out == _streamed) return;
      res.statusCode = 200;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(out));
    } on ApiError catch (e) {
      res.statusCode = e.code.status;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(e.toJson()));
    }
    await res.close();
  }

  static const _streamed = Object();

  Future<Object?> _body(HttpRequest req) async {
    var bytes = await req.fold<List<int>>([], (a, b) => a..addAll(b));
    if (req.headers.value(HttpHeaders.contentEncodingHeader) == 'gzip') {
      bytes = gzip.decode(bytes);
    }
    return bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes));
  }

  final _gone = <String>{};

  /// Cancella lo spazio (come un admin dall'hub).
  void deleteSpace(String id) {
    _spaces.remove(id);
    _gone.add(id);
  }

  /// Ultimo LockInfo ricevuto per lo spazio (acquisizione o heartbeat).
  final lockInfos = <String, Map<String, Object?>>{};

  _Space _space(String id) =>
      _spaces[id] ??
      (throw _gone.contains(id)
          ? const ApiError(ErrorCode.spaceGone, 'space deleted')
          : const ApiError(ErrorCode.notFound, 'no such space'));

  /// Risposte preparate dai test per le rotte che il finto non implementa
  /// (o per sostituirne una): chiave `METODO percorso` dopo `api/v1/`, es.
  /// `POST spaces/survival/lock/port-check`. La funzione riceve la query e il
  /// corpo JSON e restituisce il corpo della risposta, oppure [FakeBytes];
  /// può lanciare un [ApiError].
  final stubs = <String, Object? Function(Map<String, String> query, Object? body)>{};

  /// Richieste arrivate alle rotte di [stubs], in ordine.
  final stubbed = <({String key, Map<String, String> query, Object? body})>[];

  Future<Object?> _route(HttpRequest req, List<String> s) async {
    final m = req.method;
    final stubKey = '$m ${s.join('/')}';
    final stub = stubs[stubKey];
    if (stub != null) {
      final body = await _body(req);
      stubbed.add((key: stubKey, query: req.uri.queryParameters, body: body));
      final out = stub(req.uri.queryParameters, body);
      if (out is FakeBytes) {
        final res = req.response
          ..statusCode = 200
          ..headers.contentType = out.contentType;
        if (!out.chunked) res.contentLength = out.declaredLength ?? out.bytes.length;
        res.add(out.bytes);
        try {
          await res.close();
        } on Object {
          // corpo più corto del dichiarato: la connessione si chiude
        }
        return _streamed;
      }
      return out;
    }
    if (s.length == 1 && s[0] == 'hub') {
      return {'name': 'test', 'version': '0.1.0', 'api': 1, 'time': 0};
    }
    if (s.length == 2 && s[0] == 'spaces' && m == 'GET') {
      final sp = _space(s[1]);
      return _details(sp);
    }
    if (s.length == 4 && s[0] == 'spaces' && s[2] == 'generations' && m == 'GET') {
      final sp = _space(s[1]);
      final g = s[3] == 'head'
          ? sp.gens.lastOrNull
          : sp.gens.where((g) => g.n == int.parse(s[3])).firstOrNull;
      if (g == null) throw const ApiError(ErrorCode.notFound, 'no such generation');
      return g.toJson();
    }
    if (s.length >= 3 && s[0] == 'spaces' && s[2] == 'lock') {
      final sp = _space(s[1]);
      final body = await _body(req) as Map<String, Object?>?;
      final info = body?['info'];
      if (info is Map<String, Object?>) lockInfos[sp.id] = info;
      if (s.length == 4 && s[3] == 'heartbeat') {
        if (body!['token'] != sp.lockToken) throw const ApiError(ErrorCode.lockLost, 'lock lost');
        sp.lockBeat = DateTime.now();
        return {'ok': true};
      }
      if (m == 'POST') {
        if (_lockLive(sp) && sp.lockOwner != member && body?['force'] != true) {
          throw ApiError(ErrorCode.locked, 'locked', details: {'owner': sp.lockOwner});
        }
        sp.lockToken = 'tok-${++_seq}';
        sp.lockOwner = member;
        sp.lockBeat = DateTime.now();
        return LockGrant(
          token: sp.lockToken!,
          ttlMs: lockTtl.inMilliseconds,
          heartbeatMs: heartbeatMs,
        ).toJson();
      }
      if (m == 'DELETE') {
        if (body?['token'] == sp.lockToken) sp.lockToken = null;
        return {'ok': true};
      }
    }
    if (s.length == 3 && s[0] == 'spaces' && s[2] == 'pushes' && m == 'POST') {
      final sp = _space(s[1]);
      final p = PushBegin.fromJson(await _body(req));
      if (!_lockLive(sp) || p.lockToken != sp.lockToken) {
        throw const ApiError(ErrorCode.locked, 'no lock');
      }
      final head = sp.gens.lastOrNull;
      if (p.parent != (head?.n ?? 0) || p.parentDigest != (head?.digest ?? emptyDigest)) {
        throw const ApiError(ErrorCode.staleBase, 'stale base');
      }
      final before = head?.manifest.length ?? 0;
      final removed = head == null ? 0 : ManifestDiff(head.manifest, p.manifest).removed.length;
      final guard = sp.settings?.protection ?? const ProtectionSettings();
      if (before >= guard.massDeleteMinFiles &&
          removed > before * guard.massDeleteRatio &&
          !(p.confirmMassDelete && admin)) {
        throw const ApiError(ErrorCode.massDelete, 'mass delete');
      }
      final id = 'push-${++_seq}';
      _pushes[id] = _Push(sp, p, member);
      return PushStarted(
        pushId: id,
        missing: [
          for (final b in p.manifest.blobs)
            if (!blobs.containsKey(b)) b,
        ],
      ).toJson();
    }
    if (s.length == 4 && s[0] == 'pushes' && s[2] == 'blobs' && m == 'PUT') {
      final p = _pushes[s[1]] ?? (throw const ApiError(ErrorCode.notFound, 'no push'));
      final h = s[3];
      putCounts[h] = (putCounts[h] ?? 0) + 1;
      if (!p.begin.manifest.blobs.contains(h)) {
        throw const ApiError(ErrorCode.badRequest, 'not in push');
      }
      final bytes = await req
          .fold<BytesBuilder>(BytesBuilder(), (a, b) => a..add(b))
          .then((b) => b.takeBytes());
      if (crypto.sha256.convert(bytes).toString() != h) {
        throw const ApiError(ErrorCode.badHash, 'bad hash');
      }
      blobs[h] = bytes;
      return {'ok': true};
    }
    if (s.length == 3 && s[0] == 'pushes' && s[2] == 'commit' && m == 'POST') {
      final p = _pushes[s[1]] ?? (throw const ApiError(ErrorCode.notFound, 'no push'));
      if (p.committed != null) return p.committed!.toJson();
      final sp = p.space;
      if (!_lockLive(sp) || p.begin.lockToken != sp.lockToken) {
        throw const ApiError(ErrorCode.lockLost, 'lock lost');
      }
      final missing = [
        for (final b in p.begin.manifest.blobs)
          if (!blobs.containsKey(b)) b,
      ];
      if (missing.isNotEmpty) {
        throw ApiError(ErrorCode.pushIncomplete, 'missing', details: {'missing': missing});
      }
      final head = sp.gens.lastOrNull;
      if (p.begin.parent != (head?.n ?? 0)) throw const ApiError(ErrorCode.staleBase, 'stale');
      final g = _addGen(sp, p.begin.manifest, p.owner, p.begin.message, p.begin.kind);
      p.committed = g.summary;
      if (dropNextCommitResponse) {
        dropNextCommitResponse = false;
        await req.response.detachSocket().then((sock) => sock.destroy());
        return _streamed;
      }
      return g.summary.toJson();
    }
    if (s.length == 2 && s[0] == 'blobs' && m == 'GET') {
      final b = blobs[s[1]] ?? (throw const ApiError(ErrorCode.notFound, 'no blob'));
      final res = req.response..headers.contentType = ContentType.binary;
      if (stall.contains(s[1])) {
        res.contentLength = b.length;
        res.add(b.sublist(0, b.length ~/ 2));
        await res.flush();
        await Future<void>.delayed(const Duration(hours: 1));
        return _streamed;
      }
      final out = Uint8List.fromList(b);
      if (corrupt.contains(s[1]) && out.isNotEmpty) out[0] ^= 0xff;
      res.add(out);
      await res.close();
      return _streamed;
    }
    throw ApiError(ErrorCode.notFound, 'no route ${req.method} ${req.uri.path}');
  }

  Map<String, Object?> _details(_Space sp) => SpaceDetails(
    SpaceSummary(
      id: sp.id,
      name: sp.name,
      profile: Profile.minecraft,
      createdAt: 0,
      head: sp.gens.lastOrNull?.summary,
      lock: null,
    ),
    exclusions: minecraftExclusions,
    ownExclusions: const [],
    settings: sp.settings,
  ).toJson();
}
