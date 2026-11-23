// Web UI statica (apps/hub_web) servita da MINESYNC_WEB.
//
// All'avvio tutta la build sta in memoria con il gzip già calcolato (sulla
// rete ZeroTier l'hub è in HTTP semplice e i browser chiedono `br` solo in
// HTTPS: il gzip è quello che conta davvero; un `<file>.br` accanto si usa se
// c'è). Flutter non mette hash nei nomi dei file, quindi l'id della build
// sta nel percorso: /b/<buildId>/<file> con cache immutabile di un anno,
// index.html e i file alla radice no-cache + ETag. Ogni percorso senza
// estensione fuori da /api/ e /dl/<file> riceve index.html (rotte della SPA).
//
// Nessuna identità richiesta: è l'app a mostrare «non riconosciuto» dal 401
// di GET /api/v1/hub. Le richieste non toccano mai il disco, quindi non
// esiste traversal: si cerca solo nella mappa caricata.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// CSP delle pagine della web UI (l'API resta con `default-src 'none'`).
const webCsp =
    "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; "
    "style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; "
    "font-src 'self'; connect-src 'self'; worker-src 'self' blob:; "
    "object-src 'none'; base-uri 'self'; form-action 'none'; "
    "frame-ancestors 'none'";

const _immutable = 'public, max-age=31536000, immutable';
const _noCache = 'no-cache';

/// Tipi MIME per estensione; il testo porta sempre `charset=utf-8`.
const webMimes = {
  'html': 'text/html; charset=utf-8',
  'js': 'text/javascript; charset=utf-8',
  'mjs': 'text/javascript; charset=utf-8',
  'css': 'text/css; charset=utf-8',
  'json': 'application/json; charset=utf-8',
  'map': 'application/json; charset=utf-8',
  'txt': 'text/plain; charset=utf-8',
  'wasm': 'application/wasm',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'svg': 'image/svg+xml; charset=utf-8',
  'ico': 'image/x-icon',
  'ttf': 'font/ttf',
  'otf': 'font/otf',
  'woff': 'font/woff',
  'woff2': 'font/woff2',
  'bin': 'application/octet-stream',
  'frag': 'application/octet-stream',
};

/// Tipi già compressi: il gzip non serve.
const _precompressed = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'woff', 'woff2', 'gz', 'br', 'zip'};

/// Estensione dell'ultimo segmento di [path] (senza punto, minuscola).
String webExt(String path) {
  final base = path.substring(path.lastIndexOf('/') + 1);
  final i = base.lastIndexOf('.');
  return i <= 0 ? '' : base.substring(i + 1).toLowerCase();
}

/// Un file della build, con le sue varianti compresse.
final class WebAsset {
  WebAsset._(this.path, this.bytes, this.mime, this.gzip, this.br, this.etag);

  factory WebAsset._of(String path, Uint8List bytes, {Uint8List? br}) {
    final ext = webExt(path);
    final mime = webMimes[ext] ?? 'application/octet-stream';
    Uint8List? gz;
    if (bytes.length > 256 && !_precompressed.contains(ext)) {
      final g = Uint8List.fromList(GZipCodec().encode(bytes));
      if (g.length < bytes.length) gz = g;
    }
    final h = sha256.convert(bytes).toString().substring(0, 20);
    return WebAsset._(path, bytes, mime, gz, gz == null ? null : br, '"$h"');
  }

  /// Percorso relativo alla radice della build, separatore '/'.
  final String path;
  final Uint8List bytes;
  final String mime;
  final Uint8List? gzip;
  final Uint8List? br;

  /// ETag della forma non compressa; le forme compresse aggiungono `-gz`/`-br`.
  final String etag;

  String _tag(String suffix) => '${etag.substring(0, etag.length - 1)}$suffix"';
}

/// Cosa la build ha lasciato fuori dalla memoria e perché.
typedef WebSkipped = ({String path, String reason});

/// La build di hub_web caricata in memoria.
final class WebStatic {
  WebStatic._(this.dir, this.buildId, this._assets, this.index, this.skipped, this.bytes);

  /// Totale dei byte non compressi tenuti in memoria al massimo.
  static const maxTotal = 256 << 20;

  /// Un singolo file oltre questa dimensione non si carica.
  static const maxFile = 64 << 20;

  /// Carica [dir]. Lancia [FileSystemException] se manca `index.html` o la
  /// cartella non si legge, [StateError] se la build supera [maxTotal].
  ///
  /// Restano fuori: file nascosti (`.last_build_id`), `*.symbols` (nomi dei
  /// simboli dart2js/dart2wasm per il debug, grandi e mai chiesti dal
  /// browser), `*.map` (source map: la build si fa con `--no-source-maps`,
  /// se ci sono comunque non si servono), `*.gz` (il gzip lo calcola l'hub)
  /// e i `.br` (usati solo come varianti del file accanto). Le varianti del
  /// motore (canvaskit, canvaskit/chromium, skwasm) restano tutte: il loader
  /// sceglie quella giusta nel browser e togliere una rompe un browser.
  static Future<WebStatic> load(String dir, {int total = maxTotal, int file = maxFile}) async {
    final root = Directory(dir).absolute;
    final rootPath = root.path.endsWith('/') ? root.path : '${root.path}/';
    final files = <String, Uint8List>{};
    final br = <String, Uint8List>{};
    final skipped = <WebSkipped>[];
    var sum = 0;
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = e.path.substring(rootPath.length).replaceAll('\\', '/');
      final segs = rel.split('/');
      if (segs.any((s) => s.startsWith('.'))) {
        skipped.add((path: rel, reason: 'hidden'));
        continue;
      }
      final ext = webExt(rel);
      if (ext == 'symbols' || ext == 'map' || ext == 'gz') {
        skipped.add((path: rel, reason: ext));
        continue;
      }
      final len = await e.length();
      if (len > file) {
        skipped.add((path: rel, reason: 'too large'));
        continue;
      }
      sum += len;
      if (sum > total) {
        throw StateError('MINESYNC_WEB: la build supera ${total >> 20} MiB');
      }
      final bytes = await e.readAsBytes();
      if (ext == 'br') {
        br[rel.substring(0, rel.length - 3)] = bytes;
      } else {
        files[rel] = bytes;
      }
    }
    final rawIndex = files['index.html'];
    if (rawIndex == null) {
      throw FileSystemException('index.html non trovato nella build', dir);
    }
    final keys = files.keys.toList()..sort();
    final buildId = computeBuildId({for (final k in keys) k: files[k]!});
    final assets = <String, WebAsset>{};
    for (final k in keys) {
      if (k == 'index.html') continue;
      assets[k] = WebAsset._of(k, files[k]!, br: br[k]);
    }
    // l'id della build entra in index.html; il .br eventuale non vale più
    final index = WebAsset._of(
      'index.html',
      Uint8List.fromList(utf8.encode(utf8.decode(rawIndex).replaceAll('__BUILD__', buildId))),
    );
    return WebStatic._(root.path, buildId, assets, index, skipped, sum);
  }

  /// Id della build: primi 12 hex dello SHA-256 su (percorso, byte) in ordine
  /// di percorso. Ogni voce è `percorso\0lunghezza\0byte`, così due build
  /// diverse non danno mai la stessa sequenza.
  static String computeBuildId(Map<String, List<int>> files) {
    final out = _DigestSink();
    final h = sha256.startChunkedConversion(out);
    for (final k in files.keys.toList()..sort()) {
      final b = files[k]!;
      h
        ..add(utf8.encode(k))
        ..add(const [0])
        ..add(utf8.encode('${b.length}'))
        ..add(const [0])
        ..add(b);
    }
    h.close();
    return out.value.toString().substring(0, 12);
  }

  final String dir;
  final String buildId;
  final Map<String, WebAsset> _assets;
  final WebAsset index;

  /// File lasciati fuori dalla memoria (diagnostica, GET /system).
  final List<WebSkipped> skipped;

  /// Byte non compressi tenuti in memoria.
  final int bytes;

  int get fileCount => _assets.length + 1;

  WebAsset? asset(String path) => _assets[path];

  /// Serve [req] se è un percorso della web UI; false se non lo è (API,
  /// `/dl/<file>`, metodi diversi da GET/HEAD) e la richiesta resta al resto
  /// dell'hub. Il controllo di Host e le intestazioni di sicurezza le ha già
  /// messe il server.
  Future<bool> handle(HttpRequest req) async {
    if (req.method != 'GET' && req.method != 'HEAD') return false;
    final segs = req.uri.pathSegments;
    if (segs.isNotEmpty && segs.first == 'api') return false;
    // /dl e /dl/ sono la pagina dei download della SPA; /dl/<file> no
    if (segs.isNotEmpty && segs.first == 'dl' && segs.length > 1 && segs[1].isNotEmpty) {
      return false;
    }
    final path = segs.join('/');
    WebAsset? a;
    var cache = _noCache;
    if (segs.length >= 3 && segs[0] == 'b') {
      a = _assets[segs.sublist(2).join('/')];
      // un'altra build (scheda aperta da prima di un aggiornamento): il file
      // attuale, ma senza cache lunga
      if (segs[1] == buildId) cache = _immutable;
    } else if (path == 'index.html' || webExt(path).isEmpty) {
      a = index;
    } else {
      a = _assets[path];
    }
    if (a == null) return _notFound(req);
    await _send(req, a, cache);
    return true;
  }

  Future<bool> _notFound(HttpRequest req) async {
    final res = req.response
      ..statusCode = HttpStatus.notFound
      ..headers.set('Content-Security-Policy', webCsp)
      ..headers.contentType = ContentType.text
      ..write('not found\n');
    await res.close();
    return true;
  }

  Future<void> _send(HttpRequest req, WebAsset a, String cache) async {
    final res = req.response;
    final h = res.headers
      ..set('Content-Security-Policy', webCsp)
      ..set('Referrer-Policy', 'no-referrer')
      ..set(HttpHeaders.cacheControlHeader, cache)
      ..set(HttpHeaders.contentTypeHeader, a.mime);
    final compressed = a.gzip != null;
    if (compressed) h.set(HttpHeaders.varyHeader, 'Accept-Encoding');
    final enc = compressed ? _pick(req.headers.value(HttpHeaders.acceptEncodingHeader), a) : null;
    final tag = switch (enc) {
      'br' => a._tag('-br'),
      'gzip' => a._tag('-gz'),
      _ => a.etag,
    };
    h.set(HttpHeaders.etagHeader, tag);
    if (_matches(req.headers.value(HttpHeaders.ifNoneMatchHeader), a)) {
      res.statusCode = HttpStatus.notModified;
      await res.close();
      return;
    }
    final body = switch (enc) {
      'br' => a.br!,
      'gzip' => a.gzip!,
      _ => a.bytes,
    };
    if (enc != null) h.set(HttpHeaders.contentEncodingHeader, enc);
    res.contentLength = body.length;
    if (req.method != 'HEAD') res.add(body);
    await res.close();
  }

  /// La codifica migliore che il client accetta (q > 0): br, poi gzip.
  static String? _pick(String? accept, WebAsset a) {
    if (accept == null) return null;
    final ok = <String>{};
    for (final part in accept.toLowerCase().split(',')) {
      final p = part.trim().split(';');
      final name = p.first.trim();
      var q = 1.0;
      for (final x in p.skip(1)) {
        final kv = x.trim();
        if (kv.startsWith('q=')) q = double.tryParse(kv.substring(2)) ?? 0;
      }
      if (q > 0) ok.add(name);
    }
    if (a.br != null && ok.contains('br')) return 'br';
    if (a.gzip != null && (ok.contains('gzip') || ok.contains('*'))) return 'gzip';
    return null;
  }

  /// If-None-Match vale per qualsiasi forma dello stesso contenuto.
  static bool _matches(String? inm, WebAsset a) {
    if (inm == null) return false;
    final tags = {a.etag, a._tag('-gz'), a._tag('-br')};
    for (final t in inm.split(',')) {
      var s = t.trim();
      if (s == '*') return true;
      if (s.startsWith('W/')) s = s.substring(2);
      if (tags.contains(s)) return true;
    }
    return false;
  }
}

final class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest d) => value = d;

  @override
  void close() {}
}
