// Server HTTP dell'hub su dart:io (niente shelf: servono il controllo
// diretto dello stream della richiesta per la backpressure, bufferOutput
// spento per SSE e lo stream della risposta per i Range).
//
// Ogni richiesta passa, in ordine: intestazioni di sicurezza, controllo di
// Host (DNS rebinding), guardia CSRF sulle richieste che cambiano stato,
// identità dall'indirizzo del socket, instradamento sotto /api/v1.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ms_protocol/ms_protocol.dart';

import 'blobs.dart';
import 'clock.dart';
import 'config.dart';
import 'disk.dart';
import 'downloads.dart';
import 'events.dart';
import 'members.dart';
import 'port_check.dart';
import 'settings.dart';
import 'meta/meta.dart';
import 'meta/pack.dart';
import 'store.dart';
import 'system.dart';
import 'web_static.dart';

const _apiBase = ['api', 'v1'];

const _smallJson = 1 << 20;

/// Endpoint aggiunto da un'altra parte dell'hub sotto /api/v1: riceve i
/// segmenti dopo `api/v1`; restituisce vero se ha risposto. Le guardie
/// (Host, CSRF, identità) sono già passate; un [ApiError] lanciato diventa la
/// risposta di errore.
typedef ApiRoute =
    Future<bool> Function(HttpRequest req, Identity who, bool admin, List<String> segs);

/// Gestore di un percorso fuori da /api/v1 (interfaccia web, /dl): gira dopo
/// le intestazioni di sicurezza, il controllo di Host e la guardia CSRF, senza
/// identità (si usa [Hub.identify] se serve). Restituisce vero se ha risposto.
typedef RawRoute = Future<bool> Function(HttpRequest req);

/// L'hub in esecuzione.
final class Hub {
  Hub._(
    this.config,
    this.store,
    this.events,
    this.members,
    this._resolver,
    this._server,
    this._socket,
    this._log,
    this.dns,
    this.extras,
    this.startedAt,
  );

  /// Apre /data, carica lo stato e si mette in ascolto.
  static Future<Hub> start(
    HubConfig config, {
    IdentityResolver? resolver,
    Clock? clock,
    DiskProbe? disk,
    StoreOptions? options,
    void Function(String)? log,
    PortConnector? portConnector,
  }) async {
    final c = clock ?? SystemClock();
    final lg = log ?? (String m) => stderr.writeln(m);
    final root = config.dataDir;
    await Directory(root).create(recursive: true);
    final events = EventLog('$root/events', clock: c);
    await events.open();
    final dns = DnsRuntime(
      zone: config.dnsZone,
      addr: config.dnsAddr ?? (config.dnsZone == null ? null : ':53'),
    );
    final extras = HubExtras();
    final blobs = BlobStore(root, maxUploads: config.maxUploads);
    final swept = await blobs.open();
    if (swept > 0) lg('hub: tolti $swept upload interrotti da tmp/');
    final store = HubStore(
      root: root,
      clock: c,
      events: events,
      blobs: blobs,
      disk: disk ?? systemDiskProbe,
      options: options ?? StoreOptions(minFreeOverride: config.minFree),
      dns: dns,
      extras: extras,
      log: lg,
    );
    await store.open();
    // mondo, giocatori, mod e sessioni dai blob della testa
    final world = WorldExtras(
      store,
      events,
      sessionsKept: () => store.settings.sessionsKept,
      log: lg,
    );
    store
      ..worldChipOf = world.chip
      ..lastSessionOf = world.lastSession;
    await world.open();
    final members = Members('$root/members.json', admins: config.admins, clock: c);
    await members.load();
    final res = resolver ?? defaultResolver(config, c, lg);
    final ss = await ServerSocket.bind(config.address, config.port, v6Only: false);
    final server = HttpServer.listenOn(
      config.receiveBuffer > 0 ? _TunedServerSocket(ss, config.receiveBuffer) : ss,
    );
    server.idleTimeout = const Duration(seconds: 120);
    final hub = Hub._(config, store, events, members, res, server, ss, lg, dns, extras, c.wallMs());
    // web UI, /dl e prova della porta
    hub.web = await _loadWeb(config.webDir, lg);
    hub.downloads = Downloads(config.dlDir);
    hub.portChecks = PortChecker(
      clock: c,
      locks: store.lockStates,
      lockTtl: store.options.lockTtl,
      connect: portConnector,
      enabled: (id) => store.effectiveSettingsOf(id).sections.sessions.portTest,
      publish: (id, data) => events.publish('port', space: id, data: data),
    )..start();
    hub._world = world;
    // pacchetto per i giocatori dal minesync-pack.json della HEAD
    hub.apiRoutes.add(PackRoutes(store, log: lg).handle);
    hub._wire();
    hub._listen();
    return hub;
  }

  /// Resolver dalle variabili d'ambiente: identità di sviluppo (solo
  /// loopback) e/o ZTNET. Senza nessuno dei due nessuno è riconosciuto.
  static IdentityResolver defaultResolver(
    HubConfig config,
    Clock clock,
    void Function(String) log,
  ) {
    final list = <IdentityResolver>[
      if (config.devUser != null) DevResolver(config.devUser!),
      if (config.hasZtnet)
        ZtnetResolver.http(
          url: config.ztnetUrl!,
          token: config.ztnetToken!,
          networkId: config.ztnetNetwork!,
          clock: clock,
          log: log,
        ),
    ];
    if (list.isEmpty) log('hub: né ZTNET né MINESYNC_DEV_USER configurati: nessuno può entrare');
    return ChainResolver(list);
  }

  final HubConfig config;
  final HubStore store;
  final EventLog events;
  final Members members;
  final IdentityResolver _resolver;
  final HttpServer _server;

  /// Il socket in ascolto: HttpServer.listenOn non lo chiude da solo.
  final ServerSocket _socket;
  final void Function(String) _log;
  final _sse = <HttpResponse>{};

  /// Stato del DNS integrato: lo imposta il server DNS.
  final DnsRuntime dns;

  /// Dati di /dl e della build web: li impostano i rispettivi gestori.
  final HubExtras extras;

  /// Avvio dell'hub (ora di parete).
  final int startedAt;

  /// Endpoint in più sotto /api/v1, provati in ordine dopo quelli propri.
  final apiRoutes = <ApiRoute>[];

  /// Gestori dei percorsi fuori da /api/v1, provati in ordine.
  final rawRoutes = <RawRoute>[];

  /// Il resolver ZTNET, se configurato.
  ZtnetResolver? get ztnet => findZtnet(_resolver);

  late final WorldExtras _world;

  /// Mondo, giocatori, mod, sessioni e statistiche.
  WorldExtras get world => _world;
  Timer? _keepAlive;
  bool _closing = false;

  int get port => _server.port;

  /// Impostazioni applicate a caldo e stato di ZTNET negli eventi.
  void _wire() {
    void apply(Settings s) {
      final z = ztnet;
      if (z == null) return;
      final m = s.members;
      z
        ..ttl = Duration(seconds: m.refreshSeconds)
        ..grace = Duration(hours: m.trustHours);
    }

    store.settingsListeners.add(apply);
    apply(store.settings);
    ztnet?.onChange = (down, error) =>
        events.publish(EventType.ztnet, data: {'state': down ? 'error' : 'ok', 'error': ?error});
    final w = web;
    extras
      ..updates = downloads.updates
      ..webBuild = () => w?.buildId;
  }

  /// Build di hub_web in memoria (MINESYNC_WEB), o null.
  WebStatic? web;
  late final Downloads downloads;
  late final PortChecker portChecks;

  static Future<WebStatic?> _loadWeb(String? dir, void Function(String) log) async {
    if (dir == null) return null;
    try {
      final w = await WebStatic.load(dir);
      log('hub: web UI ${w.buildId} da $dir (${w.fileCount} file, ${w.bytes >> 10} KiB)');
      return w;
    } on Object catch (e) {
      log('hub: MINESYNC_WEB non caricata: $e');
      return null;
    }
  }

  Future<Identity?> _identify(HttpRequest req) async {
    final remote = req.connectionInfo?.remoteAddress;
    return remote == null ? null : _resolver.resolve(remote);
  }

  void _listen() {
    _keepAlive = Timer.periodic(config.keepAlive, (_) => _broadcast(': ka\n\n'));
    _server.listen((req) {
      _handle(req).catchError((Object e, StackTrace st) {
        _log('hub: ${req.method} ${req.uri.path}: $e\n$st');
        try {
          req.response.close().ignore();
        } catch (_) {
          // risposta già chiusa
        }
      });
    });
  }

  /// Spegnimento pulito: niente nuove connessioni, stream SSE chiusi, stato
  /// su disco.
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    _keepAlive?.cancel();
    await portChecks.close();
    for (final r in _sse.toList()) {
      try {
        await r.close();
      } catch (_) {
        // client già andato
      }
    }
    _sse.clear();
    await _server.close(force: true);
    await _socket.close();
    await _world.close();
    await store.close();
    await members.flush();
    await events.close();
  }

  // ---------------------------------------------------------------- guardie

  /// Host ammesso: un IP letterale, localhost, un nome nella zona DNS
  /// dell'hub o in MINESYNC_HOSTS (porta ignorata, senza maiuscole).
  bool hostAllowed(String? raw) {
    if (raw == null) return false;
    var h = raw.trim().toLowerCase();
    if (h.isEmpty) return false;
    if (h.startsWith('[')) {
      final e = h.indexOf(']');
      if (e < 0) return false;
      return InternetAddress.tryParse(h.substring(1, e))?.type == InternetAddressType.IPv6;
    }
    final colon = h.indexOf(':');
    if (colon >= 0) {
      if (h.lastIndexOf(':') != colon) return InternetAddress.tryParse(h) != null;
      h = h.substring(0, colon);
    }
    if (h.endsWith('.')) h = h.substring(0, h.length - 1);
    if (h.isEmpty) return false;
    if (InternetAddress.tryParse(h) != null) return true;
    if (h == 'localhost' || h.endsWith('.localhost')) return true;
    final zone = config.dnsZone;
    if (zone != null && zone.isNotEmpty && (h == zone || h.endsWith('.$zone'))) return true;
    return config.allowedHosts.any((a) => a.toLowerCase() == h);
  }

  static bool _changesState(String m) => m == 'POST' || m == 'PUT' || m == 'PATCH' || m == 'DELETE';

  // ---------------------------------------------------------------- richiesta

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('X-Frame-Options', 'DENY')
      ..set('Content-Security-Policy', "default-src 'none'; frame-ancestors 'none'")
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    try {
      if (!hostAllowed(req.headers.value(HttpHeaders.hostHeader))) {
        throw const ApiError(ErrorCode.forbidden, 'host not allowed');
      }
      if (_changesState(req.method)) {
        if (req.headers.value(csrfHeader) != '1') {
          throw const ApiError(ErrorCode.forbidden, 'missing X-MineSync header');
        }
        if (req.headers.value('Sec-Fetch-Site')?.toLowerCase() == 'cross-site') {
          throw const ApiError(ErrorCode.forbidden, 'cross-site request refused');
        }
      }
      final segs = req.uri.pathSegments;
      // /dl/<file> e web UI: fuori da /api/v1, prima delle rotte aggiunte
      if (segs.isEmpty || segs[0] != _apiBase[0]) {
        if (await downloads.handle(req, () => _identify(req))) return;
        if (await web?.handle(req) ?? false) return;
      }
      if (segs.length < 2 || segs[0] != _apiBase[0] || segs[1] != _apiBase[1]) {
        for (final r in rawRoutes.toList()) {
          if (await r(req)) return;
        }
        throw const ApiError(ErrorCode.notFound, 'no such endpoint');
      }
      final who = await identify(req);
      if (who == null) {
        throw const ApiError(
          ErrorCode.unauthenticated,
          'this device is not a member of the private network: join the network to use the hub',
        );
      }
      await _route(req, who, members.isAdmin(who), segs.sublist(2));
    } on ApiError catch (e) {
      await _error(req, e);
    } on ManifestError catch (e) {
      await _error(
        req,
        ApiError(
          ErrorCode.badPath,
          'invalid path "${e.path}" (${e.reason})',
          details: {'path': e.path, 'reason': e.reason},
        ),
      );
    } on FormatException catch (e) {
      await _error(req, ApiError(ErrorCode.badRequest, 'bad request: ${e.message}'));
    } on HttpException catch (e) {
      // client caduto a metà richiesta
      _log('hub: ${req.method} ${req.uri.path}: connessione interrotta ($e)');
      try {
        await res.close();
      } catch (_) {
        // già chiusa
      }
    } catch (e, st) {
      _log('hub: ${req.method} ${req.uri.path}: $e\n$st');
      await _error(req, const ApiError(ErrorCode.internal, 'internal error'));
    }
  }

  /// Il membro che chiama, solo dall'indirizzo del socket (X-Forwarded-For e
  /// simili non contano mai); null se sconosciuto. Lo registra come visto.
  Future<Identity?> identify(HttpRequest req) async {
    final remote = req.connectionInfo?.remoteAddress;
    final who = remote == null ? null : await _resolver.resolve(remote);
    if (who != null) members.seen(who);
    return who;
  }

  /// Risposta JSON (per [apiRoutes]).
  Future<void> sendJson(HttpRequest req, Object? body, {int status = 200}) =>
      _json(req, body, status: status);

  /// Risposta di errore nella forma dell'API (per [rawRoutes]).
  Future<void> sendError(HttpRequest req, ApiError e) => _error(req, e);

  /// Corpo JSON oggetto entro [limit] byte (per [apiRoutes]).
  Future<Map<String, Object?>> readObject(
    HttpRequest req, {
    int limit = _smallJson,
    bool optional = false,
  }) => _readObject(req, limit: limit, optional: optional);

  Future<void> _error(HttpRequest req, ApiError e) async {
    final res = req.response;
    try {
      res
        ..statusCode = e.httpStatus
        ..headers.contentType = ContentType.json
        // il corpo della richiesta potrebbe non essere stato letto tutto
        ..persistentConnection = false
        ..write(jsonEncode(e.toJson()));
      await res.close();
    } on StateError {
      // intestazioni già inviate (stream): si chiude e basta
      await res.close();
    } on HttpException {
      // client già andato
    }
  }

  Future<void> _json(HttpRequest req, Object? body, {int status = 200}) async {
    final res = req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await res.close();
  }

  bool _gzip(HttpRequest req) =>
      req.headers.value(HttpHeaders.contentEncodingHeader)?.toLowerCase().trim() == 'gzip';

  Stream<List<int>> _body(HttpRequest req) {
    return _gzip(req) ? gzip.decoder.bind(req) : req;
  }

  /// Corpo JSON entro [limit] byte (dopo la decompressione gzip).
  Future<Object?> _readJson(HttpRequest req, {int limit = _smallJson}) async {
    if (!_gzip(req) && req.contentLength > limit) {
      throw ApiError(
        ErrorCode.tooLarge,
        'body larger than $limit bytes',
        details: {'limit': limit},
      );
    }
    final b = BytesBuilder(copy: false);
    var n = 0;
    try {
      await for (final c in _body(req)) {
        n += c.length;
        if (n > limit) {
          throw ApiError(
            ErrorCode.tooLarge,
            'body larger than $limit bytes',
            details: {'limit': limit},
          );
        }
        b.add(c);
      }
    } on FormatException {
      throw const ApiError(ErrorCode.badRequest, 'invalid gzip body');
    }
    if (b.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(b.takeBytes()));
    } on FormatException {
      throw const ApiError(ErrorCode.badRequest, 'invalid JSON body');
    }
  }

  Future<Map<String, Object?>> _readObject(
    HttpRequest req, {
    int limit = _smallJson,
    bool optional = false,
  }) async {
    final j = await _readJson(req, limit: limit);
    if (j == null && optional) return const {};
    if (j is! Map<String, Object?>) {
      throw const ApiError(ErrorCode.badRequest, 'expected a JSON object');
    }
    return j;
  }

  static int? _intParam(HttpRequest req, String k, {int min = 0}) {
    final v = req.uri.queryParameters[k];
    if (v == null) return null;
    final n = int.tryParse(v);
    if (n == null || n < min) throw ApiError(ErrorCode.badRequest, 'parameter $k: invalid value');
    return n;
  }

  static String _hash(String h) =>
      isHash(h) ? h : throw const ApiError(ErrorCode.badRequest, 'invalid blob hash');

  /// Indirizzo del socket di chi chiama, in forma canonica.
  static String? _remoteIp(HttpRequest req) {
    final a = req.connectionInfo?.remoteAddress;
    return a == null ? null : canonicalIp(a);
  }

  static void _admin(bool admin) {
    if (!admin) throw const ApiError(ErrorCode.forbidden, 'admin only');
  }

  // ---------------------------------------------------------------- instradamento

  static int _genParam(String n) {
    final k = int.tryParse(n);
    if (k == null || k < 0 || '$k' != n) {
      throw const ApiError(ErrorCode.badRequest, 'invalid generation number');
    }
    return k;
  }

  /// `keep` di una pulizia: 1–10000 (B-GC-08); null se assente.
  static int? _keepParam(Map<String, Object?> b) {
    if (!b.containsKey('keep') || b['keep'] == null) return null;
    final k = b['keep'];
    if (k is! int || k < 1 || k > 10000) {
      throw const ApiError(
        ErrorCode.badRequest,
        'keep: must be an integer between 1 and 10000',
        details: {'field': 'keep'},
      );
    }
    return k;
  }

  static Set<String>? _typesParam(HttpRequest req) {
    final v = req.uri.queryParameters['types'];
    if (v == null) return null;
    final t = {
      for (final s in v.split(','))
        if (s.trim().isNotEmpty) s.trim(),
    };
    return t.isEmpty ? null : t;
  }

  static String? _hint(String? s) =>
      s == null ? null : (s.length <= 4 ? s : s.substring(s.length - 4));

  ZtnetStatus ztnetStatus() {
    final z = ztnet;
    if (z == null) return const ZtnetStatus(state: ZtnetState.off);
    return ZtnetStatus(
      state: z.down ? ZtnetState.error : ZtnetState.ok,
      members: z.authorizedCount,
      lastRefresh: z.lastRefresh,
      lastError: z.lastError,
      lastErrorAt: z.lastErrorAt,
      url: config.ztnetUrl,
      tokenHint: _hint(config.ztnetToken),
      networkHint: _hint(config.ztnetNetwork),
    );
  }

  MemberList memberList() => MemberList(members: members.list(ztnet?.roster), ztnet: ztnetStatus());

  Future<MemberInfo> _setRole(Identity who, String id, Object? body) async {
    final b = body is Map<String, Object?> ? body : const <String, Object?>{};
    final MemberRole role;
    try {
      role = MemberRole.parse(b['role']);
    } on FormatException {
      throw const ApiError(
        ErrorCode.badRequest,
        'role: expected admin or member',
        details: {'field': 'role'},
      );
    }
    final all = members.list(ztnet?.roster);
    final m = all.where((m) => m.id == id).firstOrNull;
    if (m == null) throw ApiError(ErrorCode.notFound, 'member $id: not found');
    if (m.role == role) return m;
    if (role == MemberRole.member) {
      if (m.fromConfig) {
        throw ApiError(
          ErrorCode.fromConfig,
          'member ${m.name} is an admin from MINESYNC_ADMINS',
          details: {'memberId': id},
        );
      }
      if (!all.any((o) => o.id != id && o.role == MemberRole.admin && o.authorized)) {
        throw const ApiError(ErrorCode.lastAdmin, 'the hub would be left without an admin');
      }
    }
    await members.setRole(id, m.name, role == MemberRole.admin ? Role.admin : Role.member);
    events.publish(
      EventType.memberRole,
      actor: who.name,
      data: {'memberId': id, 'member': m.name, 'role': role.name},
    );
    return members.list(ztnet?.roster).firstWhere((x) => x.id == id);
  }

  Future<SystemInfo> systemInfo() async => SystemInfo(
    version: hubVersion,
    startedAt: startedAt,
    time: store.clock.wallMs(),
    disk: store.diskInfo(),
    http: config.http,
    dns: dns.toStatus(),
    dataDir: config.dataDir,
    allowedHosts: config.allowedHosts,
    admins: config.admins,
    minFreeEnv: config.minFree,
    dlDir: config.dlDir,
    updates: await extras.updates(),
    timeZone: config.timeZone,
    webDir: config.webDir,
    webBuild: extras.webBuild(),
  );

  Future<void> _zip(HttpRequest req, String id, int? n) async {
    final z = await store.exportZip(id, n);
    final res = req.response;
    try {
      res
        ..statusCode = 200
        ..headers.contentType = ContentType('application', 'zip')
        ..headers.set('Content-Disposition', 'attachment; filename="${z.fileName}"')
        ..contentLength = z.plan.length;
      try {
        await z.plan.write(res, store.blobs.pathOf);
      } catch (e) {
        // intestazioni già inviate: la risposta resta corta e la connessione
        // si chiude (Content-Length dice al client che è incompleta)
        _log('hub: export ZIP di $id interrotto: $e');
      }
      try {
        await res.close();
      } catch (_) {
        // connessione chiusa o corpo più corto del dichiarato
      }
    } finally {
      z.release();
    }
  }

  Future<void> _route(HttpRequest req, Identity who, bool admin, List<String> p) async {
    if (await _world.handle(req, who, admin, p)) return;
    switch ((req.method, p)) {
      case ('GET', ['hub']):
        final settings = store.settings;
        return _json(
          req,
          HubInfo(
            name: settings.hubName,
            version: hubVersion,
            api: apiVersion,
            time: store.clock.wallMs(),
            disk: store.diskInfo(),
            me: Me(id: who.id, name: who.name, admin: admin),
            language: settings.language,
            dnsZone: dns.activeZone,
          ).toJson(),
        );

      case ('GET', ['spaces']):
        return _json(req, {
          'spaces': [for (final s in store.listSpaces()) s.toJson()],
        });
      case ('POST', ['spaces']):
        _admin(admin);
        final b = await _readObject(req);
        final name = b['name'];
        if (name is! String) throw const ApiError(ErrorCode.badRequest, 'name: expected a string');
        final ex = b['exclusions'];
        if (ex != null && (ex is! List<Object?> || ex.any((e) => e is! String))) {
          throw const ApiError(ErrorCode.badRequest, 'exclusions: expected a list of strings');
        }
        final d = await store.createSpace(
          who,
          name: name,
          profile: Profile.parse(b['profile'] ?? 'minecraft'),
          exclusions: ex == null ? const [] : (ex as List<Object?>).cast<String>(),
        );
        return _json(req, d, status: 201);
      case ('GET', ['spaces', final id]):
        return _json(req, store.details(id));
      case ('PATCH', ['spaces', final id]):
        _admin(admin);
        return _json(req, await store.patchSpace(who, id, await _readObject(req)));
      case ('DELETE', ['spaces', final id]):
        _admin(admin);
        await store.deleteSpace(who, id);
        return _json(req, {'deleted': id});

      case ('GET', ['spaces', final id, 'generations']):
        final limit = min(_intParam(req, 'limit', min: 1) ?? 50, 500);
        return _json(req, store.history(id, before: _intParam(req, 'before'), limit: limit));
      case ('GET', ['spaces', final id, 'generations', final n]):
        return _json(req, (await store.generation(id, n == 'head' ? null : _genParam(n))).toJson());
      case ('GET', ['spaces', final id, 'generations', final n, 'diff']):
        final limit = _intParam(req, 'limit', min: 1) ?? diffDefaultLimit;
        if (limit > 1000) {
          throw const ApiError(ErrorCode.badRequest, 'parameter limit: at most 1000');
        }
        return _json(req, (await store.diff(id, _genParam(n), limit: limit)).toJson());
      case ('GET', ['spaces', final id, 'generations', final n, 'zip']):
        return _zip(req, id, n == 'head' ? null : _genParam(n));
      case ('GET', ['spaces', final id, 'generations', final n, 'freed']):
        _admin(admin);
        final k = _genParam(n);
        return _json(req, {'n': k, 'bytes': await store.freedBy(id, k)});
      case ('DELETE', ['spaces', final id, 'generations', final n]):
        _admin(admin);
        await req.drain<void>();
        final r = await store.deleteGeneration(who, id, _genParam(n));
        return _json(req, {'deleted': r.deleted, 'bytes': r.bytes});
      case ('POST', ['spaces', final id, 'restore']):
        _admin(admin);
        final b = await _readObject(req);
        final g = b['generation'];
        if (g is! int) {
          throw const ApiError(ErrorCode.badRequest, 'generation: expected an integer');
        }
        final s = await store.restore(who, id, g, message: b['message'] as String? ?? '');
        return _json(req, s.toJson(), status: 201);
      case ('POST', ['spaces', final id, 'restore-file']):
        _admin(admin);
        final r = RestoreFileRequest.fromJson(await _readObject(req));
        return _json(req, (await store.restoreFile(who, id, r)).toJson(), status: 201);

      case ('POST', ['spaces', final id, 'gc', 'preview']):
        _admin(admin);
        final b = await _readObject(req, optional: true);
        final h = b['history'];
        return _json(
          req,
          (await store.gcPreview(
            keep: _keepParam(b),
            history: h == null ? null : validateSection('history', h),
            spaceId: id,
          )).toJson(),
        );
      case ('POST', ['spaces', final id, 'gc']):
        _admin(admin);
        final b = await _readObject(req, optional: true);
        return _json(req, (await store.gc(who, keep: _keepParam(b), spaceId: id)).toJson());
      case ('POST', ['gc', 'preview']):
        _admin(admin);
        final b = await _readObject(req, optional: true);
        final h = b['history'];
        return _json(
          req,
          (await store.gcPreview(
            keep: _keepParam(b),
            history: h == null ? null : validateSection('history', h),
          )).toJson(),
        );
      case ('POST', ['gc']):
        _admin(admin);
        final b = await _readObject(req, optional: true);
        return _json(req, (await store.gc(who, keep: _keepParam(b))).toJson());
      case ('GET', ['usage']):
        return _json(req, (await store.usage()).toJson());

      case ('POST', ['exclusions', 'test']):
        _admin(admin);
        final b = await _readObject(req);
        final path = b['path'];
        if (path is! String) {
          throw const ApiError(
            ErrorCode.badRequest,
            'path: expected a string',
            details: {'field': 'path'},
          );
        }
        final pats = b['patterns'];
        if (pats != null && (pats is! List<Object?> || pats.any((e) => e is! String))) {
          throw const ApiError(
            ErrorCode.badRequest,
            'patterns: expected a list of strings',
            details: {'field': 'patterns'},
          );
        }
        final sid = b['spaceId'];
        return _json(
          req,
          store
              .testExclusions(
                path: path,
                spaceId: sid is String ? sid : null,
                profile: b['profile'] == null ? null : Profile.parse(b['profile']),
                patterns: pats == null ? null : (pats as List<Object?>).cast<String>(),
              )
              .toJson(),
        );

      case ('GET', ['members']):
        _admin(admin);
        return _json(req, memberList().toJson());
      case ('PUT', ['members', final id, 'role']):
        _admin(admin);
        return _json(req, (await _setRole(who, id, await _readJson(req))).toJson());
      case ('POST', ['members', 'refresh']):
        _admin(admin);
        await req.drain<void>();
        await ztnet?.refreshNow();
        return _json(req, ztnetStatus().toJson());

      case ('GET', ['system']):
        _admin(admin);
        return _json(req, (await systemInfo()).toJson());

      case ('GET' || 'HEAD', ['blobs', final h]):
        return _getBlob(req, _hash(h));

      case ('POST', ['spaces', final id, 'pushes']):
        final b = PushBegin.fromJson(await _readJson(req, limit: config.jsonLimit));
        return _json(
          req,
          (await store.begin(who, admin: admin, id: id, b: b)).toJson(),
          status: 201,
        );
      case ('PUT', ['pushes', final pid, 'blobs', final h]):
        final stored = await store.upload(
          who,
          pid,
          _hash(h),
          _body(req),
          contentLength: _gzip(req) ? -1 : req.contentLength,
        );
        return _json(req, {'hash': h, 'stored': stored}, status: stored ? 201 : 200);
      case ('POST', ['pushes', final pid, 'commit']):
        await req.drain<void>();
        final (s, replay) = await store.commit(who, pid);
        return _json(req, {...s.toJson(), 'replay': replay});
      case ('DELETE', ['pushes', final pid]):
        await req.drain<void>();
        await store.abort(who, pid);
        return _json(req, {'aborted': pid});

      case ('POST', ['spaces', final id, 'lock']):
        final b = await _readObject(req, optional: true);
        final (grant, holder) = await store.acquire(
          who,
          admin: admin,
          id: id,
          info: LockInfo.fromJson(b['info']),
          force: b['force'] == true,
          ip: _remoteIp(req),
        );
        return _json(req, {...grant.toJson(), 'lock': holder.toJson()});
      case ('POST', ['spaces', final id, 'lock', 'heartbeat']):
        final b = await _readObject(req);
        final token = b['token'];
        if (token is! String) {
          throw const ApiError(ErrorCode.badRequest, 'token: expected a string');
        }
        final holder = await store.heartbeat(
          who,
          id,
          token,
          b['info'] == null ? null : LockInfo.fromJson(b['info']),
          ip: _remoteIp(req),
        );
        return _json(req, {
          'lock': holder.toJson(),
          'ttlMs': store.options.lockTtl.inMilliseconds,
          'heartbeatMs': store.options.heartbeat.inMilliseconds,
        });
      case ('DELETE', ['spaces', final id, 'lock']):
        final b = await _readObject(req, optional: true);
        await store.release(
          who,
          admin: admin,
          id: id,
          token: b['token'] as String?,
          force: b['force'] == true,
        );
        return _json(req, {'released': true});

      case ('GET', ['dl']):
        return _json(req, (await downloads.listing()).toJson());
      case ('POST', ['spaces', final id, 'lock', 'port-check']):
        await req.drain<void>();
        return _json(req, portChecks.restart(id).toJson());

      case ('GET', ['events']):
        final space = req.uri.queryParameters['space'];
        final types = _typesParam(req);
        final before = _intParam(req, 'before');
        if (before != null) {
          final limit = min(_intParam(req, 'limit', min: 1) ?? 100, 500);
          final r = await events.before(before, limit: limit, space: space, types: types);
          return _json(req, {
            'events': [for (final e in r.events) e.toJson()],
            'last': events.lastSeq,
            'oldest': events.oldestSeq,
            'more': r.more,
          });
        }
        final after = _intParam(req, 'after') ?? 0;
        final limit = min(_intParam(req, 'limit', min: 1) ?? 500, 1000);
        final list = events.after(after, limit: limit, space: space, types: types);
        return _json(req, {
          'events': [for (final e in list) e.toJson()],
          'last': events.lastSeq,
          'oldest': events.oldestSeq,
          'more': list.length >= limit,
        });
      case ('GET', ['events', 'stream']):
        return _stream(req);

      case ('GET', ['settings']):
        _admin(admin);
        return _json(req, store.hubSettings().toJson());
      case ('PATCH', ['settings', final section]):
        _admin(admin);
        final s = await store.patchSettings(who, section, await _readObject(req));
        return _json(req, s.toJson());
    }
    for (final r in apiRoutes.toList()) {
      if (await r(req, who, admin, p)) return;
    }
    throw const ApiError(ErrorCode.notFound, 'no such endpoint');
  }

  // ---------------------------------------------------------------- blob

  Future<void> _getBlob(HttpRequest req, String h) async {
    final res = req.response;
    final f = File(store.blobs.pathOf(h));
    final int len;
    try {
      len = await f.length();
    } on FileSystemException {
      throw ApiError(ErrorCode.notFound, 'blob $h: not found');
    }
    var start = 0, end = len - 1; // estremi inclusi
    res.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..contentType = ContentType.binary;
    final range = req.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range.trim());
      var ok = m != null && (m[1]!.isNotEmpty || m[2]!.isNotEmpty);
      if (ok) {
        if (m[1]!.isEmpty) {
          start = max(0, len - int.parse(m[2]!)); // suffisso: ultimi n byte
        } else {
          start = int.parse(m[1]!);
          if (m[2]!.isNotEmpty) end = min(int.parse(m[2]!), len - 1);
        }
        ok = start < len && start <= end;
      }
      if (!ok) {
        res
          ..statusCode = HttpStatus.requestedRangeNotSatisfiable
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */$len');
        return res.close();
      }
      res
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$len');
    }
    res.contentLength = end - start + 1;
    if (req.method == 'HEAD' || len == 0) return res.close();
    // openRead legge a blocchi da 64 KiB e addStream rispetta la
    // backpressure del socket: la memoria non cresce con il blob
    await res.addStream(f.openRead(start, end + 1));
    await res.close();
  }

  // ---------------------------------------------------------------- SSE

  Future<void> _stream(HttpRequest req) async {
    final res = req.response;
    final last = req.headers.value('Last-Event-ID');
    final after = (last == null ? null : int.tryParse(last.trim())) ?? _intParam(req, 'after');
    res
      ..bufferOutput = false
      ..statusCode = 200
      ..headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8')
      ..headers.set('X-Accel-Buffering', 'no');
    res.write(': hello\n\n');
    // gli eventi arretrati e poi quelli nuovi, nello stesso turno: nessuno
    // può infilarsi in mezzo
    if (after != null) {
      for (final e in events.after(after, limit: 1 << 30)) {
        res.write(_frame(e));
      }
    }
    final sub = events.live.listen((e) {
      try {
        res.write(_frame(e));
      } catch (_) {
        // client andato: lo toglie done
      }
    });
    _sse.add(res);
    await req.drain<void>();
    await res.flush();
    await res.done.catchError((Object _) => null);
    await sub.cancel();
    _sse.remove(res);
  }

  static String _frame(HubEvent e) =>
      'id: ${e.seq}\nevent: ${e.type}\ndata: ${jsonEncode(e.toJson())}\n\n';

  void _broadcast(String s) {
    for (final r in _sse.toList()) {
      try {
        r.write(s);
      } catch (_) {
        _sse.remove(r);
      }
    }
  }

  /// Client SSE collegati (test e diagnostica).
  int get sseClients => _sse.length;
}

/// ServerSocket che limita SO_RCVBUF su ogni connessione accettata: dart:io
/// legge dal socket tutto ciò che è disponibile (fino a ~4 MiB) in un colpo,
/// e con l'autotuning del kernel i pezzi del corpo crescono con il ritmo del
/// mittente (misurato). Un buffer di ricezione piccolo tiene piccoli i
/// pezzi e fa lavorare la backpressure a grana fine.
final class _TunedServerSocket extends StreamView<Socket> implements ServerSocket {
  _TunedServerSocket(this._ss, int bytes)
    : super(
        _ss.map((s) {
          // SOL_SOCKET = 1, SO_RCVBUF = 8 su Linux (asm-generic, x86_64 e arm64)
          if (Platform.isLinux) {
            final v = ByteData(4)..setInt32(0, bytes, Endian.host);
            s.setRawOption(RawSocketOption(1, 8, v.buffer.asUint8List()));
          }
          return s;
        }),
      );
  final ServerSocket _ss;

  @override
  InternetAddress get address => _ss.address;

  @override
  int get port => _ss.port;

  @override
  Future<ServerSocket> close() => _ss.close();
}
