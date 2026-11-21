// Spike: server dart:io che serve la build di Flutter web.
//
// - Tutti i file della build stanno in memoria, già compressi (gzip calcolato
//   all'avvio, brotli letto da <file>.br se presente: Dart non ha un encoder
//   brotli, lo produce la CLI `brotli` nella fase di build/Docker).
// - Flutter non mette hash nei nomi dei file, quindi l'hash lo mettiamo noi
//   nel percorso: /b/<id-build>/<file> con cache immutabile di un anno;
//   index.html (che contiene il bootstrap inline) è no-cache + ETag.
// - Fallback SPA: ogni percorso senza estensione restituisce index.html,
//   così /admin ricaricato o aperto da un link funziona.
// - /api/events: SSE di prova (un evento ogni 2 s, rispetta Last-Event-ID).
//
// Uso: dart run bin/server.dart --root ../build/wasm --port 8080
//      [--coi] (COOP/COEP: abilita skwasm multi-thread solo in contesti sicuri)
//      [--preload] (link rel=preload per motore e programma wasm)
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

class Asset {
  Asset(this.bytes, this.mime, this.gzip, this.br, this.etag);
  final List<int> bytes;
  final String mime;
  final List<int>? gzip;
  final List<int>? br;
  final String etag;
}

const mimes = {
  'html': 'text/html; charset=utf-8',
  'js': 'text/javascript; charset=utf-8',
  'mjs': 'text/javascript; charset=utf-8',
  'wasm': 'application/wasm',
  'json': 'application/json',
  'css': 'text/css; charset=utf-8',
  'png': 'image/png',
  'ico': 'image/x-icon',
  'svg': 'image/svg+xml',
  'ttf': 'font/ttf',
  'otf': 'font/otf',
  'woff2': 'font/woff2',
  'bin': 'application/octet-stream',
  'frag': 'application/octet-stream',
  'symbols': 'text/plain; charset=utf-8',
  'txt': 'text/plain; charset=utf-8',
};

bool compressible(String mime) =>
    !mime.startsWith('image/png') && mime != 'font/woff2';

String ext(String p) {
  final base = p.split('/').last;
  final i = base.lastIndexOf('.');
  return i < 0 ? '' : base.substring(i + 1);
}

Future<void> main(List<String> args) async {
  String opt(String name, String def) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : def;
  }

  final root = Directory(opt('root', '../build/wasm'));
  final port = int.parse(opt('port', '8080'));
  final host = opt('host', '127.0.0.1');
  final coi = args.contains('--coi');
  final preload = args.contains('--preload');

  // Carica la build e calcola l'id (hash di nomi + contenuti).
  final files = <String, List<int>>{};
  final brFiles = <String, List<int>>{};
  await for (final e in root.list(recursive: true)) {
    if (e is! File) continue;
    final rel = e.path.substring(root.path.length).replaceAll('\\', '/');
    final p = rel.startsWith('/') ? rel.substring(1) : rel;
    if (p.endsWith('.br')) {
      brFiles[p.substring(0, p.length - 3)] = await e.readAsBytes();
    } else if (p.endsWith('.gz')) {
      continue;
    } else {
      files[p] = await e.readAsBytes();
    }
  }
  if (!files.containsKey('index.html')) {
    stderr.writeln('index.html non trovato in ${root.path}');
    exit(2);
  }
  final keys = files.keys.toList()..sort();
  final idSink = AccumulatorSink<Digest>();
  final hasher = sha256.startChunkedConversion(idSink);
  for (final k in keys) {
    if (k == 'index.html') continue;
    hasher.add(utf8.encode(k));
    hasher.add(files[k]!);
  }
  hasher.close();
  final buildId = idSink.events.single.toString().substring(0, 12);

  final gz = GZipCodec(level: 9);
  Asset mk(String p, List<int> bytes, {List<int>? br}) {
    final mime = mimes[ext(p)] ?? 'application/octet-stream';
    final comp = compressible(mime) && bytes.length > 512;
    return Asset(bytes, mime, comp ? gz.encode(bytes) : null,
        comp ? br : null, '"${sha256.convert(bytes).toString().substring(0, 16)}"');
  }

  final assets = <String, Asset>{};
  for (final k in keys) {
    if (k == 'index.html') continue;
    assets[k] = mk(k, files[k]!, br: brFiles[k]);
  }

  // index.html: sostituisce l'id della build e (opzionale) i preload.
  var indexSrc = utf8.decode(files['index.html']!);
  final pre = preload
      ? [
          '<link rel="modulepreload" href="/b/$buildId/main.dart.mjs">',
          '<link rel="modulepreload" href="/b/$buildId/canvaskit/skwasm.js">',
          '<link rel="preload" href="/b/$buildId/main.dart.wasm" as="fetch" crossorigin>',
          '<link rel="preload" href="/b/$buildId/canvaskit/skwasm.wasm" as="fetch" crossorigin>',
        ].join('\n  ')
      : '';
  indexSrc = indexSrc
      .replaceAll('__BUILD__', buildId)
      .replaceAll('__PRELOAD__', pre);
  final indexBytes = utf8.encode(indexSrc);
  final indexBr = await brotliOf(indexBytes);
  final index = mk('index.html', indexBytes, br: indexBr);

  final server = await HttpServer.bind(host, port);
  server.autoCompress = false; // la compressione la gestiamo noi
  stdout.writeln('build $buildId · ${assets.length} file · '
      'brotli ${brFiles.length} · http://$host:${server.port}/');

  var nextEventId = 1;
  final rnd = Random(42);

  await for (final req in server) {
    unawaited(handle(req, buildId, assets, index, coi, () => nextEventId++, rnd));
  }
}

Future<List<int>?> brotliOf(List<int> bytes) async {
  // Solo per index.html (generato all'avvio); se la CLI manca, niente br.
  try {
    final p = await Process.start('brotli', ['-c', '-q', '11']);
    p.stdin.add(bytes);
    await p.stdin.close();
    final out = await p.stdout.fold<List<int>>([], (a, b) => a..addAll(b));
    return await p.exitCode == 0 ? out : null;
  } catch (_) {
    return null;
  }
}

Future<void> handle(HttpRequest req, String buildId, Map<String, Asset> assets,
    Asset index, bool coi, int Function() nextId, Random rnd) async {
  final res = req.response;
  final path = req.uri.path;
  try {
    if (path == '/api/events') return await sse(req, nextId, rnd);
    if (path == '/healthz') {
      res.headers.contentType = ContentType.text;
      res.write('ok $buildId');
      return await res.close();
    }

    Asset? a;
    String cache;
    if (path.startsWith('/b/')) {
      final rest = path.substring(3);
      final slash = rest.indexOf('/');
      final id = slash < 0 ? rest : rest.substring(0, slash);
      final file = slash < 0 ? '' : rest.substring(slash + 1);
      // Id diverso: una scheda aperta su una build vecchia. Serviamo comunque
      // il file attuale ma senza cache lunga (meglio che un 404 a metà).
      a = assets[file];
      cache = id == buildId
          ? 'public, max-age=31536000, immutable'
          : 'no-cache';
    } else if (ext(path).isEmpty || path == '/index.html') {
      a = index; // fallback SPA
      cache = 'no-cache';
    } else {
      // File alla radice (manifest.json, favicon.png, ...): cache breve.
      a = assets[path.substring(1)];
      cache = 'public, max-age=300';
    }

    if (a == null) {
      res.statusCode = HttpStatus.notFound;
      return await res.close();
    }

    final h = res.headers;
    h.set('Cache-Control', cache);
    h.set('ETag', a.etag);
    h.set('Vary', 'Accept-Encoding');
    h.set('X-Content-Type-Options', 'nosniff');
    if (identical(a, index)) {
      h.set('Referrer-Policy', 'no-referrer');
      if (coi) {
        h.set('Cross-Origin-Opener-Policy', 'same-origin');
        h.set('Cross-Origin-Embedder-Policy', 'require-corp');
      }
    } else if (coi) {
      h.set('Cross-Origin-Resource-Policy', 'same-origin');
    }
    h.set('Content-Type', a.mime);

    if (req.headers.value('if-none-match') == a.etag) {
      res.statusCode = HttpStatus.notModified;
      return await res.close();
    }

    final ae = (req.headers.value('accept-encoding') ?? '').toLowerCase();
    List<int> body = a.bytes;
    if (a.br != null && ae.contains('br')) {
      h.set('Content-Encoding', 'br');
      body = a.br!;
    } else if (a.gzip != null && ae.contains('gzip')) {
      h.set('Content-Encoding', 'gzip');
      body = a.gzip!;
    }
    h.contentLength = body.length;
    if (req.method != 'HEAD') res.add(body);
    await res.close();
  } catch (e) {
    stderr.writeln('errore su $path: $e');
    try {
      await res.close();
    } catch (_) {}
  }
}

const _who = ['Sara', 'Luca', 'Teo', 'Admin'];
const _what = [
  ('salva', 'Isola · autosave'),
  ('avvio', 'Isola · aperto'),
  ('stop', 'Valle · chiuso'),
  ('disco', 'pulizia: liberati 1,2 GB'),
  ('stale', 'ATM 10 · blocco scaduto'),
  ('admin', 'impostazioni modificate'),
];

Future<void> sse(HttpRequest req, int Function() nextId, Random rnd) async {
  final res = req.response;
  res.bufferOutput = false;
  res.headers
    ..set('Content-Type', 'text/event-stream; charset=utf-8')
    ..set('Cache-Control', 'no-store')
    ..set('X-Accel-Buffering', 'no');
  // Il browser si riconnette da solo dopo 3 s se la linea cade.
  res.write('retry: 3000\n\n');
  await res.flush();
  void send() {
    final w = _what[rnd.nextInt(_what.length)];
    final id = nextId();
    final data = jsonEncode({
      'id': id,
      'kind': w.$1,
      'who': _who[rnd.nextInt(_who.length)],
      'what': w.$2,
      'at': DateTime.now().toUtc().toIso8601String(),
    });
    res.write('id: $id\ndata: $data\n\n');
  }

  // Primo evento subito, poi uno ogni 2 s; ping di keep-alive implicito.
  send();
  await res.flush();
  final t = Timer.periodic(const Duration(seconds: 2), (_) async {
    try {
      send();
      await res.flush();
    } catch (_) {}
  });
  await res.done.catchError((_) => null);
  t.cancel();
}

/// Piccolo sink per raccogliere il digest dello sha256 a blocchi.
class AccumulatorSink<T> implements Sink<T> {
  final events = <T>[];
  @override
  void add(T e) => events.add(e);
  @override
  void close() {}
}
