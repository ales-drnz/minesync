// Client dell'API v2 di Modrinth (https://docs.modrinth.com/api/): ricerca,
// progetti, versioni filtrate per versione del gioco e loader, riconoscimento
// dei jar per hash e aggiornamenti. User-Agent descrittivo come chiede
// Modrinth, limiti di frequenza rispettati (X-Ratelimit-*, 429 con attesa),
// cache piccola delle risposte. Il trasporto è iniettato: nei test un falso,
// mai la rete vera.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ms_protocol/ms_protocol.dart' show Loader;

import 'http.dart';
import 'modrinth_models.dart';
import 'pack.dart';

/// Indirizzo dell'API di produzione.
final Uri modrinthApi = Uri.parse('https://api.modrinth.com/v2/');

/// Pagina del progetto MineSync, per lo User-Agent (Modrinth chiede un
/// contatto per le app).
const String minesyncHomepage = 'https://github.com/ales-drnz/minesync';

/// `minesync/<versione> (+<homepage>)`.
String modrinthUserAgent(String version, {String homepage = minesyncHomepage}) =>
    'minesync/$version (+$homepage)';

/// Ordinamento della ricerca.
enum MrSearchIndex { relevance, downloads, follows, newest, updated }

/// Algoritmo degli hash per il riconoscimento dei file.
enum MrHash { sha1, sha512 }

/// Errore di Modrinth: risposta non 2xx o corpo non valido.
final class ModrinthException implements Exception {
  const ModrinthException(this.status, this.message, {this.error});

  /// Stato HTTP (0 se la risposta non si poteva leggere).
  final int status;
  final String message;

  /// Campo `error` della risposta di Modrinth, se c'è.
  final String? error;

  bool get notFound => status == 404;

  @override
  String toString() => 'ModrinthException($status${error == null ? '' : ' $error'}): $message';
}

/// Modrinth non risponde (rete, DNS, timeout, 5xx ripetuti): la UI mostra
/// «Modrinth non risponde» e riprova più tardi.
final class ModrinthUnavailable implements Exception {
  const ModrinthUnavailable(this.cause);
  final Object cause;
  @override
  String toString() => 'ModrinthUnavailable: $cause';
}

/// Stato dei limiti di frequenza letto dall'ultima risposta.
final class RateLimit {
  const RateLimit({required this.limit, required this.remaining, required this.resetMs});

  final int limit;
  final int remaining;

  /// Quando si azzera (ms dall'epoca, orologio del client).
  final int resetMs;
}

/// Una risposta in cache.
final class CachedBody {
  const CachedBody(this.body, this.expiresAtMs);
  final Uint8List body;
  final int expiresAtMs;
}

/// Cache delle risposte, per chiave (metodo, URL, corpo).
abstract interface class ResponseCache {
  Future<CachedBody?> get(String key);
  Future<void> put(String key, CachedBody value);
}

/// Cache in memoria, LRU con al più [maxEntries] voci.
final class MemoryCache implements ResponseCache {
  MemoryCache({this.maxEntries = 256});

  final int maxEntries;
  final _m = <String, CachedBody>{};

  @override
  Future<CachedBody?> get(String key) async {
    final v = _m.remove(key);
    if (v != null) _m[key] = v;
    return v;
  }

  @override
  Future<void> put(String key, CachedBody value) async {
    _m.remove(key);
    _m[key] = value;
    while (_m.length > maxEntries) {
      _m.remove(_m.keys.first);
    }
  }
}

/// I nomi dei loader come li usa Modrinth.
String mrLoader(Loader l) => switch (l) {
  Loader.neoforge => 'neoforge',
  Loader.forge => 'forge',
  Loader.fabric => 'fabric',
  Loader.quilt => 'quilt',
  Loader.paper => 'paper',
  Loader.vanilla => 'minecraft',
};

/// Loader di Modrinth che una mod può avere per girare su [l]: Quilt carica
/// anche le mod Fabric.
List<String> compatibleLoaders(Loader l) => switch (l) {
  Loader.quilt => const ['quilt', 'fabric'],
  _ => [mrLoader(l)],
};

/// Il client.
final class ModrinthClient {
  ModrinthClient({
    required HttpTransport transport,
    required this.userAgent,
    Uri? base,
    ResponseCache? cache,
    this.cacheTtl = const Duration(minutes: 10),
    this.hashCacheTtl = const Duration(hours: 24),
    this.maxRetries = 3,
    this.maxWait = const Duration(seconds: 60),
    Future<void> Function(Duration)? sleep,
    int Function()? nowMs,
  }) : _t = transport,
       base = base ?? modrinthApi,
       _cache = cache ?? MemoryCache(),
       _sleep = sleep ?? ((d) => Future<void>.delayed(d)),
       _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch) {
    if (userAgent.trim().isEmpty) throw ArgumentError('userAgent vuoto');
  }

  final HttpTransport _t;
  final String userAgent;
  final Uri base;
  final ResponseCache _cache;

  /// Validità in cache di ricerche, progetti e versioni.
  final Duration cacheTtl;

  /// Validità in cache del riconoscimento per hash (un hash non cambia
  /// versione).
  final Duration hashCacheTtl;
  final int maxRetries;

  /// Attesa massima dopo un 429 o un limite esaurito.
  final Duration maxWait;
  final Future<void> Function(Duration) _sleep;
  final int Function() _now;

  RateLimit? _rate;

  /// I limiti dall'ultima risposta, se Modrinth li ha mandati.
  RateLimit? get rateLimit => _rate;

  // ---------------------------------------------------------------- API

  /// Cerca progetti. [loader] filtra per categoria (Quilt include Fabric),
  /// [side] per dove devono funzionare (`client`: client_side required o
  /// optional; `server`: server_side; `both`: tutti e due).
  Future<MrSearchResult> search({
    String query = '',
    String projectType = 'mod',
    String? gameVersion,
    Loader? loader,
    Iterable<String> categories = const [],
    PackSide? side,
    MrSearchIndex index = MrSearchIndex.relevance,
    int offset = 0,
    int limit = 20,
  }) async {
    if (limit < 1 || limit > 100) throw ArgumentError.value(limit, 'limit', '1…100');
    final facets = searchFacets(
      projectType: projectType,
      gameVersion: gameVersion,
      loader: loader,
      categories: categories,
      side: side,
    );
    final j = await _get('search', {
      if (query.isNotEmpty) 'query': query,
      'facets': jsonEncode(facets),
      'index': index.name,
      'offset': '$offset',
      'limit': '$limit',
    });
    return _decode(() => MrSearchResult.fromJson(j));
  }

  /// Un progetto per id o slug.
  Future<MrProject> project(String idOrSlug) async {
    final j = await _get('project/${Uri.encodeComponent(idOrSlug)}');
    return _decode(() => MrProject.fromJson(j));
  }

  /// Più progetti in una richiesta (quelli che non esistono mancano).
  Future<List<MrProject>> projects(Iterable<String> ids) async {
    final l = ids.toSet().toList()..sort();
    if (l.isEmpty) return const [];
    final j = await _get('projects', {'ids': jsonEncode(l)});
    return _decode(() => [for (final p in _list(j)) MrProject.fromJson(p)]);
  }

  /// Le versioni di un progetto, filtrate da Modrinth per versioni del gioco
  /// e loader (nomi di Modrinth: vedi [compatibleLoaders]).
  Future<List<MrVersion>> versions(
    String project, {
    Iterable<String>? gameVersions,
    Iterable<String>? loaders,
    bool? featured,
  }) async {
    final j = await _get('project/${Uri.encodeComponent(project)}/version', {
      if (gameVersions != null) 'game_versions': jsonEncode(gameVersions.toList()),
      if (loaders != null) 'loaders': jsonEncode(loaders.toList()),
      if (featured != null) 'featured': '$featured',
    });
    return _decode(() => [for (final v in _list(j)) MrVersion.fromJson(v)]);
  }

  /// Una versione per id.
  Future<MrVersion> version(String id) async {
    final j = await _get('version/${Uri.encodeComponent(id)}');
    return _decode(() => MrVersion.fromJson(j));
  }

  /// Più versioni per id.
  Future<List<MrVersion>> versionsByIds(Iterable<String> ids) async {
    final l = ids.toSet().toList()..sort();
    if (l.isEmpty) return const [];
    final j = await _get('versions', {'ids': jsonEncode(l)});
    return _decode(() => [for (final v in _list(j)) MrVersion.fromJson(v)]);
  }

  /// Riconosce i file dai loro hash: hash → versione (quelli sconosciuti
  /// mancano dalla mappa).
  Future<Map<String, MrVersion>> versionFiles(
    Iterable<String> hashes, {
    MrHash algorithm = MrHash.sha1,
  }) async {
    final l = hashes.map((h) => h.toLowerCase()).toSet().toList()..sort();
    if (l.isEmpty) return const {};
    final j = await _post('version_files', {
      'hashes': l,
      'algorithm': algorithm.name,
    }, ttl: hashCacheTtl);
    return _decode(() => _versionMap(j));
  }

  /// Ultima versione compatibile per ogni file: hash → versione (anche la
  /// stessa, se è già l'ultima).
  Future<Map<String, MrVersion>> updates(
    Iterable<String> hashes, {
    MrHash algorithm = MrHash.sha1,
    required Iterable<String> loaders,
    required Iterable<String> gameVersions,
  }) async {
    final l = hashes.map((h) => h.toLowerCase()).toSet().toList()..sort();
    if (l.isEmpty) return const {};
    final j = await _post('version_files/update', {
      'hashes': l,
      'algorithm': algorithm.name,
      'loaders': loaders.toList(),
      'game_versions': gameVersions.toList(),
    }, ttl: cacheTtl);
    return _decode(() => _versionMap(j));
  }

  /// Versioni del gioco conosciute da Modrinth.
  Future<List<MrGameVersion>> gameVersions() async {
    final j = await _get('tag/game_version', const {}, const Duration(hours: 6));
    return _decode(() => [for (final v in _list(j)) MrGameVersion.fromJson(v)]);
  }

  // ---------------------------------------------------------------- trasporto

  Future<Object?> _get(String path, [Map<String, String> q = const {}, Duration? ttl]) =>
      _call('GET', base.resolve(path).replace(queryParameters: q.isEmpty ? null : q), null, ttl);

  Future<Object?> _post(String path, Object body, {Duration? ttl}) =>
      _call('POST', base.resolve(path), utf8.encode(jsonEncode(body)), ttl);

  Future<Object?> _call(String method, Uri url, List<int>? body, Duration? ttl) async {
    final key = '$method $url${body == null ? '' : ' ${utf8.decode(body)}'}';
    final hit = await _cache.get(key);
    if (hit != null && hit.expiresAtMs > _now()) return _json(hit.body);
    final bytes = await _send(method, url, body);
    await _cache.put(key, CachedBody(bytes, _now() + (ttl ?? cacheTtl).inMilliseconds));
    return _json(bytes);
  }

  Future<Uint8List> _send(String method, Uri url, List<int>? body) async {
    for (var attempt = 0; ; attempt++) {
      await _waitForLimit();
      final HttpRes res;
      try {
        res = await _t.send(
          HttpReq(
            method,
            url,
            headers: {
              'User-Agent': userAgent,
              'Accept': 'application/json',
              if (body != null) 'Content-Type': 'application/json',
            },
            body: body,
          ),
        );
      } on HttpUnavailable catch (e) {
        if (attempt >= maxRetries) throw ModrinthUnavailable(e);
        await _sleep(_backoff(attempt));
        continue;
      }
      _readLimit(res.headers);
      if (res.ok) {
        try {
          return await res.readAll(max: 32 << 20);
        } on HttpBodyTooLarge {
          throw const ModrinthException(0, 'response too large');
        }
      }
      if (res.status == 429 && attempt < maxRetries) {
        await res.drain();
        await _sleep(_retryAfter(res.headers) ?? _backoff(attempt));
        continue;
      }
      if (res.status >= 500 && attempt < maxRetries) {
        await res.drain();
        await _sleep(_backoff(attempt));
        continue;
      }
      final b = await res.readAll(max: 1 << 20).catchError((Object _) => Uint8List(0));
      if (res.status >= 500 || res.status == 429) {
        throw ModrinthUnavailable(ModrinthException(res.status, _describe(b)));
      }
      throw ModrinthException(res.status, _describe(b), error: _errorCode(b));
    }
  }

  Duration _backoff(int attempt) {
    final ms = 1000 * (1 << attempt.clamp(0, 6));
    return Duration(milliseconds: ms.clamp(0, maxWait.inMilliseconds));
  }

  /// `Retry-After` (secondi) o `X-Ratelimit-Reset` (secondi all'azzeramento).
  Duration? _retryAfter(Map<String, String> h) {
    final s = int.tryParse(h['retry-after'] ?? '') ?? int.tryParse(h['x-ratelimit-reset'] ?? '');
    if (s == null || s < 0) return null;
    final d = Duration(seconds: s);
    return d > maxWait ? maxWait : d;
  }

  void _readLimit(Map<String, String> h) {
    final limit = int.tryParse(h['x-ratelimit-limit'] ?? '');
    final rem = int.tryParse(h['x-ratelimit-remaining'] ?? '');
    final reset = int.tryParse(h['x-ratelimit-reset'] ?? '');
    if (limit == null || rem == null || reset == null) return;
    _rate = RateLimit(limit: limit, remaining: rem, resetMs: _now() + reset * 1000);
  }

  /// Con il limite esaurito aspetta l'azzeramento (al più [maxWait]).
  Future<void> _waitForLimit() async {
    final r = _rate;
    if (r == null || r.remaining > 0) return;
    final wait = r.resetMs - _now();
    if (wait > 0) {
      await _sleep(Duration(milliseconds: wait.clamp(0, maxWait.inMilliseconds)));
    }
    _rate = null;
  }

  static Object? _json(Uint8List b) {
    try {
      return jsonDecode(utf8.decode(b));
    } on FormatException catch (e) {
      throw ModrinthException(0, 'invalid JSON: ${e.message}');
    }
  }

  static T _decode<T>(T Function() f) {
    try {
      return f();
    } on FormatException catch (e) {
      throw ModrinthException(0, 'unexpected response: ${e.message}');
    }
  }

  static List<Object?> _list(Object? j) =>
      j is List<Object?> ? j : throw const FormatException('attesa una lista');

  static Map<String, MrVersion> _versionMap(Object? j) {
    if (j is! Map<String, Object?>) throw const FormatException('atteso un oggetto');
    return {for (final e in j.entries) e.key.toLowerCase(): MrVersion.fromJson(e.value)};
  }

  static String _describe(Uint8List b) {
    try {
      final j = jsonDecode(utf8.decode(b));
      if (j is Map<String, Object?> && j['description'] is String) {
        return j['description']! as String;
      }
    } on FormatException {
      // corpo non JSON
    }
    return 'HTTP error';
  }

  static String? _errorCode(Uint8List b) {
    try {
      final j = jsonDecode(utf8.decode(b));
      if (j is Map<String, Object?> && j['error'] is String) return j['error']! as String;
    } on FormatException {
      // corpo non JSON
    }
    return null;
  }
}

/// Facet della ricerca: liste in AND di liste in OR, come vuole Modrinth.
/// Per i modpack il loader è quello esatto (un modpack Fabric non è un
/// modpack Quilt); per le mod Quilt include Fabric.
List<List<String>> searchFacets({
  String projectType = 'mod',
  String? gameVersion,
  Loader? loader,
  Iterable<String> categories = const [],
  PackSide? side,
}) => [
  ['project_type:$projectType'],
  if (gameVersion != null) ['versions:$gameVersion'],
  if (loader != null && loader != Loader.vanilla)
    [
      for (final l in projectType == 'modpack' ? [mrLoader(loader)] : compatibleLoaders(loader))
        'categories:$l',
    ],
  for (final c in categories) ['categories:$c'],
  if (side != null && side.onClient) ['client_side:required', 'client_side:optional'],
  if (side != null && side.onServer) ['server_side:required', 'server_side:optional'],
];
