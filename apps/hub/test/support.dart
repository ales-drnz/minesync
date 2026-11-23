// Supporto ai test dell'hub: server in-process su porta effimera, cartella
// dati temporanea, identità finte per indirizzo di loopback (alice da
// 127.0.0.1, bob da 127.0.0.2, carol admin da 127.0.0.3) e un client HTTP per
// ciascuno, che si collega dal proprio indirizzo sorgente.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:minesync_hub/minesync_hub.dart';
import 'package:ms_core/ms_core.dart';
import 'package:ms_protocol/ms_protocol.dart';

const alice = Identity('a1a1a1a1a1', 'alice');
const bob = Identity('b2b2b2b2b2', 'bob');
const carol = Identity('c3c3c3c3c3', 'carol');

const ipOf = {'alice': '127.0.0.1', 'bob': '127.0.0.2', 'carol': '127.0.0.3'};

/// Risposta letta tutta.
final class Res {
  Res(this.status, this.headers, this.bytes);
  final int status;
  final HttpHeaders headers;
  final Uint8List bytes;

  Object? get json => bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes));
  Map<String, Object?> get obj => json! as Map<String, Object?>;
  String? get code => (obj['error'] as Map<String, Object?>?)?['code'] as String?;
  Map<String, Object?> get details =>
      ((obj['error'] as Map<String, Object?>?)?['details'] as Map<String, Object?>?) ?? const {};

  @override
  String toString() => 'Res($status, ${utf8.decode(bytes, allowMalformed: true)})';
}

/// Disco finto: valori modificabili dai test.
final class FakeDisk {
  int free = 100 << 30;
  int total = 200 << 30;
  DiskUsage? probe(String _) => (free: free, total: total);
}

final class TestHub {
  TestHub._(this.dir, this.clock, this.disk, this.options, this._admins, this._config, this._wrap);

  static Future<TestHub> start({
    Directory? dir,
    FakeClock? clock,
    StoreOptions? options,
    List<String> admins = const ['carol'],
    HubConfig Function(String dataDir)? config,
    IdentityResolver Function(StaticResolver base)? resolver,
  }) async {
    final d = dir ?? await Directory.systemTemp.createTemp('minesync-hub-test-');
    final t = TestHub._(
      d,
      clock ?? FakeClock(),
      FakeDisk(),
      options ?? const StoreOptions(maintenanceDelay: Duration(days: 1)),
      admins,
      config,
      resolver,
    );
    await t._boot();
    return t;
  }

  final Directory dir;
  final FakeClock clock;
  final FakeDisk disk;
  final StoreOptions options;
  final List<String> _admins;
  final HubConfig Function(String)? _config;
  final IdentityResolver Function(StaticResolver)? _wrap;
  final resolver = StaticResolver({
    ipOf['alice']!: alice,
    ipOf['bob']!: bob,
    ipOf['carol']!: carol,
  });
  late Hub hub;
  final _clients = <String, HttpClient>{};
  final logs = <String>[];

  String get data => dir.path;
  HubStore get store => hub.store;

  Future<void> _boot() async {
    final cfg =
        _config?.call(data) ??
        HubConfig(
          dataDir: data,
          address: InternetAddress.loopbackIPv4,
          port: 0,
          admins: _admins,
          keepAlive: const Duration(milliseconds: 200),
        );
    hub = await Hub.start(
      cfg,
      resolver: _wrap?.call(resolver) ?? resolver,
      clock: clock,
      disk: disk.probe,
      options: options,
      log: logs.add,
    );
  }

  /// Ferma e riavvia l'hub sulla stessa cartella dati.
  Future<void> restart() async {
    await hub.close();
    await _boot();
  }

  Future<void> close({bool keepData = false}) async {
    for (final c in _clients.values) {
      c.close(force: true);
    }
    await hub.close();
    if (!keepData) await dir.delete(recursive: true);
  }

  HttpClient client(String who) => _clients.putIfAbsent(who, () {
    final src = InternetAddress(ipOf[who]!);
    return HttpClient()
      ..connectionFactory = (uri, proxyHost, proxyPort) =>
          Socket.startConnect(InternetAddress.loopbackIPv4, uri.port, sourceAddress: src);
  });

  Uri uri(String path) => Uri.parse('http://127.0.0.1:${hub.port}/api/v1$path');

  /// Una richiesta come [as]. Le richieste che cambiano stato portano
  /// X-MineSync se [csrf].
  Future<Res> req(
    String method,
    String path, {
    String as = 'alice',
    Object? body,
    List<int>? raw,
    Stream<List<int>>? stream,
    int? contentLength,
    Map<String, String> headers = const {},
    bool csrf = true,
  }) async {
    final r = await client(as).openUrl(method, uri(path));
    if (csrf && method != 'GET' && method != 'HEAD') r.headers.set(csrfHeader, '1');
    headers.forEach(r.headers.set);
    if (body != null) {
      final b = utf8.encode(jsonEncode(body));
      r.headers.contentType = ContentType.json;
      r.contentLength = b.length;
      r.add(b);
    } else if (raw != null) {
      r.contentLength = contentLength ?? raw.length;
      r.add(raw);
    } else if (stream != null) {
      if (contentLength != null) r.contentLength = contentLength;
      await r.addStream(stream);
    }
    final res = await r.close();
    final bb = BytesBuilder(copy: false);
    await for (final c in res) {
      bb.add(c);
    }
    return Res(res.statusCode, res.headers, bb.takeBytes());
  }

  Future<Res> get(String path, {String as = 'alice'}) => req('GET', path, as: as);

  // ------------------------------------------------------------ scorciatoie

  Future<String> createSpace(String name, {String profile = 'minecraft'}) async {
    final r = await req('POST', '/spaces', as: 'carol', body: {'name': name, 'profile': profile});
    if (r.status != 201) throw StateError('createSpace: $r');
    return r.obj['id']! as String;
  }

  /// L'ultimo push iniziato da [push].
  String? lastPush;

  /// Token dei lock presi con [lock], per spazio e membro.
  final tokens = <String, String>{};

  Future<String> lock(String space, {String as = 'alice'}) async {
    final r = await req(
      'POST',
      '/spaces/$space/lock',
      as: as,
      body: {
        'info': {'client': 'test'},
      },
    );
    if (r.status != 200) throw StateError('lock: $r');
    return tokens['$space/$as'] = r.obj['token']! as String;
  }

  Future<({int n, String digest})> head(String space) async {
    final r = await get('/spaces/$space/generations/head');
    return (n: r.obj['n']! as int, digest: r.obj['digest']! as String);
  }

  /// Push completo di [files] (percorso → contenuto) sulla testa attuale.
  Future<Res> push(
    String space,
    Map<String, List<int>> files, {
    String as = 'alice',
    String? token,
    bool confirmMassDelete = false,
  }) async {
    final t = token ?? tokens['$space/$as'] ?? await lock(space, as: as);
    final h = await head(space);
    final m = manifestOf(files);
    final b = await req(
      'POST',
      '/spaces/$space/pushes',
      as: as,
      body: PushBegin(
        parent: h.n,
        parentDigest: h.digest,
        lockToken: t,
        manifest: m,
        confirmMassDelete: confirmMassDelete,
      ).toJson(),
    );
    if (b.status != 201) return b;
    final id = lastPush = b.obj['pushId']! as String;
    final byHash = {for (final c in files.values) sha256Hex(Uint8List.fromList(c)): c};
    for (final hh in (b.obj['missing']! as List<Object?>).cast<String>()) {
      final u = await req('PUT', '/pushes/$id/blobs/$hh', as: as, raw: byHash[hh]);
      if (u.status != 201 && u.status != 200) return u;
    }
    return req('POST', '/pushes/$id/commit', as: as);
  }
}

/// Manifest di file piccoli (un blob per file).
Manifest manifestOf(Map<String, List<int>> files) => Manifest({
  for (final e in files.entries)
    e.key: FileEntry(size: e.value.length, h: sha256Hex(Uint8List.fromList(e.value))),
});

List<int> bytes(String s) => utf8.encode(s);

/// Byte pseudo-casuali deterministici.
Uint8List noise(int n, [int seed = 1]) {
  final out = Uint8List(n);
  var x = seed * 0x9E3779B9 + 7;
  for (var i = 0; i < n; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    out[i] = x >> 16;
  }
  return out;
}

/// Mille file distinti: "f/<i>.txt".
Map<String, List<int>> manyFiles(int n, [String tag = '']) => {
  for (var i = 0; i < n; i++) 'f/$i.txt': bytes('file $i $tag'),
};

/// Aspetta che [cond] diventi vero (al più [timeout]).
Future<void> eventually(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condizione mai vera');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
