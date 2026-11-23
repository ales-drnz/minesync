// Web UI statica da MINESYNC_WEB (protocol.md, "Static web UI").
import 'dart:convert';
import 'dart:io';

import 'package:minesync_hub/minesync_hub.dart';
import 'package:test/test.dart';

import 'support.dart';
import 'web_support.dart';

void main() {
  late Directory web;
  late TestHub t;
  late String id;

  // abbastanza lunghi da essere compressi (> 256 byte)
  final js = 'console.log("minesync");\n' * 40;
  final wasm = [0, 97, 115, 109, 1, 0, 0, 0, ...List.filled(2000, 7)];
  final brBytes = [1, 2, 3, 4, 5];
  const index =
      '<!DOCTYPE html><html><head><meta name="minesync-build" content="__BUILD__">'
      '<link rel="icon" href="/b/__BUILD__/favicon.png"></head>'
      '<body><script src="/b/__BUILD__/flutter_bootstrap.js" defer></script></body></html>';

  setUp(() async {
    web = await Directory.systemTemp.createTemp('minesync-web-');
    await writeTree(web, {
      'index.html': index,
      'flutter_bootstrap.js': js,
      'flutter_bootstrap.js.br': brBytes,
      'main.dart.mjs': js,
      'main.dart.wasm': wasm,
      'main.dart.wasm.symbols': 'simboli',
      'main.dart.js.map': '{}',
      'canvaskit/skwasm.wasm': wasm,
      'favicon.png': [137, 80, 78, 71],
      'manifest.json': '{"name": "MineSync"}',
      'assets/fonts/x.ttf': [0, 1, 0, 0],
      '.last_build_id': 'abc',
    });
    t = await startHub(web: web.path);
    id = t.hub.web!.buildId;
  });
  tearDown(() async {
    await t.close();
    await web.delete(recursive: true);
  });

  group('build in memoria', () {
    test('id della build: 12 hex, cambia con il contenuto', () async {
      expect(id, matches(RegExp(r'^[0-9a-f]{12}$')));
      expect(
        WebStatic.computeBuildId({
          'a': [1],
        }),
        isNot(
          WebStatic.computeBuildId({
            'a': [2],
          }),
        ),
      );
      // percorso e byte non si confondono tra voci vicine
      expect(
        WebStatic.computeBuildId({
          'ab': [1],
        }),
        isNot(
          WebStatic.computeBuildId({
            'a': [...utf8.encode('b\u0000'), 1],
          }),
        ),
      );
      final again = await WebStatic.load(web.path);
      expect(again.buildId, id);
      await File('${web.path}/main.dart.mjs').writeAsString('altro');
      expect((await WebStatic.load(web.path)).buildId, isNot(id));
    });

    test('simboli, source map, file nascosti e .br restano fuori dalla mappa', () {
      final w = t.hub.web!;
      expect(w.asset('main.dart.wasm.symbols'), isNull);
      expect(w.asset('main.dart.js.map'), isNull);
      expect(w.asset('.last_build_id'), isNull);
      expect(w.asset('flutter_bootstrap.js.br'), isNull);
      expect(w.asset('flutter_bootstrap.js')!.br, brBytes);
      expect(w.asset('canvaskit/skwasm.wasm'), isNotNull);
      expect(
        w.skipped.map((s) => s.path),
        containsAll(['main.dart.wasm.symbols', '.last_build_id']),
      );
    });

    test('una build oltre il tetto non si carica; senza index.html nemmeno', () async {
      await expectLater(WebStatic.load(web.path, total: 1000), throwsStateError);
      final empty = await Directory.systemTemp.createTemp('minesync-web-empty-');
      addTearDown(() => empty.delete(recursive: true));
      await expectLater(WebStatic.load(empty.path), throwsA(isA<FileSystemException>()));
    });
  });

  group('index.html e rotte della SPA', () {
    test('__BUILD__ sostituito, no-cache + ETag, CSP della pagina, niente identità', () async {
      for (final p in ['/', '/index.html', '/server/abc', '/admin', '/dl', '/dl/']) {
        // 127.0.0.9 non è un membro: la pagina si serve lo stesso
        final r = await fetch(t, p, from: '127.0.0.9');
        expect(r.status, 200, reason: p);
        final body = utf8.decode(r.bytes);
        expect(body, contains('/b/$id/flutter_bootstrap.js'), reason: p);
        expect(body, isNot(contains('__BUILD__')));
        expect(r.headers.value('cache-control'), 'no-cache');
        expect(r.headers.value('etag'), isNotNull);
        expect(r.headers.contentType.toString(), 'text/html; charset=utf-8');
        expect(r.headers.value('content-security-policy'), webCsp);
        expect(r.headers.value('x-frame-options'), 'DENY');
        expect(r.headers.value('x-content-type-options'), 'nosniff');
      }
    });

    test('If-None-Match → 304', () async {
      final a = await fetch(t, '/');
      final b = await fetch(t, '/admin', headers: {'If-None-Match': a.headers.value('etag')!});
      expect(b.status, 304);
      expect(b.bytes, isEmpty);
    });

    test('Host fuori dalla lista: 403 anche per la web UI', () async {
      final r = await fetch(t, '/', headers: {'Host': 'evil.example'});
      expect(r.status, 403);
    });

    test('/api/… e /dl/<file> non ricadono sulla SPA; POST non serve pagine', () async {
      expect((await fetch(t, '/api/v1/nope')).status, 404);
      expect((await fetch(t, '/api/v2')).status, 404);
      expect((await fetch(t, '/api/v1/hub')).status, 200);
      // MINESYNC_DL non impostata
      expect((await fetch(t, '/dl/MineSync-0.1.0.exe')).status, 404);
      expect((await fetch(t, '/dl/qualcosa')).headers.contentType?.mimeType, 'application/json');
      final p = await fetch(t, '/admin', method: 'POST', headers: {'X-MineSync': '1'});
      expect(p.status, 404);
      expect(utf8.decode(p.bytes), isNot(contains('<html')));
    });
  });

  group('file della build', () {
    test('/b/<id>/ immutabile; un altro id dà il file attuale senza cache', () async {
      final r = await fetch(t, '/b/$id/main.dart.wasm');
      expect(r.status, 200);
      expect(r.bytes, wasm);
      expect(r.headers.value('cache-control'), 'public, max-age=31536000, immutable');
      expect(r.headers.contentType.toString(), 'application/wasm');
      final old = await fetch(t, '/b/000000000000/main.dart.wasm');
      expect(old.status, 200);
      expect(old.bytes, wasm);
      expect(old.headers.value('cache-control'), 'no-cache');
      expect((await fetch(t, '/b/$id/canvaskit/skwasm.wasm')).bytes, wasm);
    });

    test('gzip precalcolato e .br accanto, Vary: Accept-Encoding', () async {
      final g = await fetch(t, '/b/$id/main.dart.mjs', headers: {'Accept-Encoding': 'gzip'});
      expect(g.headers.value('content-encoding'), 'gzip');
      expect(g.headers.value('vary'), 'Accept-Encoding');
      expect(utf8.decode(gzip.decode(g.bytes)), js);
      expect(g.bytes.length, lessThan(js.length));
      final b = await fetch(
        t,
        '/b/$id/flutter_bootstrap.js',
        headers: {'Accept-Encoding': 'gzip, deflate, br'},
      );
      expect(b.headers.value('content-encoding'), 'br');
      expect(b.bytes, brBytes);
      // br con q=0 rifiutato: gzip
      final q = await fetch(
        t,
        '/b/$id/flutter_bootstrap.js',
        headers: {'Accept-Encoding': 'br;q=0, gzip'},
      );
      expect(q.headers.value('content-encoding'), 'gzip');
      final plain = await fetch(t, '/b/$id/main.dart.mjs');
      expect(plain.headers.value('content-encoding'), isNull);
      expect(utf8.decode(plain.bytes), js);
      // ETag diversi per forma, If-None-Match valido per tutte
      expect(plain.headers.value('etag'), isNot(g.headers.value('etag')));
      final n = await fetch(
        t,
        '/b/$id/main.dart.mjs',
        headers: {'Accept-Encoding': 'gzip', 'If-None-Match': plain.headers.value('etag')!},
      );
      expect(n.status, 304);
      final head = await fetch(t, '/b/$id/main.dart.mjs', method: 'HEAD');
      expect(head.status, 200);
      expect(head.headers.contentLength, js.length);
      expect(head.bytes, isEmpty);
    });

    test('file alla radice: no-cache + ETag; MIME con charset sul testo', () async {
      final fav = await fetch(t, '/favicon.png');
      expect(fav.status, 200);
      expect(fav.headers.contentType.toString(), 'image/png');
      expect(fav.headers.value('cache-control'), 'no-cache');
      expect(fav.headers.value('etag'), isNotNull);
      expect(fav.headers.value('content-encoding'), isNull);
      final man = await fetch(t, '/manifest.json');
      expect(man.headers.contentType.toString(), 'application/json; charset=utf-8');
      final mjs = await fetch(t, '/main.dart.mjs');
      expect(mjs.headers.contentType.toString(), 'text/javascript; charset=utf-8');
      final font = await fetch(t, '/assets/fonts/x.ttf');
      expect(font.headers.contentType.toString(), 'font/ttf');
      expect(webMimes['woff2'], 'font/woff2');
    });

    test('file mancanti o tenuti fuori: 404', () async {
      for (final p in [
        '/nope.js',
        '/b/$id/nope.js',
        '/b/$id/main.dart.wasm.symbols',
        '/main.dart.js.map',
        '/flutter_bootstrap.js.br',
        '/b/$id/',
      ]) {
        final r = await fetch(t, p);
        expect(r.status, 404, reason: p);
        expect(r.headers.value('content-security-policy'), webCsp, reason: p);
      }
      // un file nascosto non ha estensione: la SPA, mai il file
      expect(utf8.decode((await fetch(t, '/.last_build_id')).bytes), isNot('abc'));
      // nessun accesso al disco: al massimo la pagina della SPA
      for (final p in [
        '/b/$id/../../etc/passwd',
        '/%2e%2e/%2e%2e/etc/passwd',
        '/b/$id/%2e%2e/x.js',
      ]) {
        final (_, text) = await rawGet(t, p);
        expect(text, isNot(contains('root:')), reason: p);
      }
    });
  });

  test('senza MINESYNC_WEB: / è 404 e l\'API funziona', () async {
    final h = await startHub();
    addTearDown(h.close);
    expect(h.hub.web, isNull);
    expect((await fetch(h, '/')).status, 404);
    expect((await fetch(h, '/api/v1/hub')).status, 200);
  });

  test('MINESYNC_WEB senza index.html: l\'hub parte senza web UI', () async {
    final empty = await Directory.systemTemp.createTemp('minesync-web-empty-');
    addTearDown(() => empty.delete(recursive: true));
    final h = await startHub(web: empty.path);
    addTearDown(h.close);
    expect(h.hub.web, isNull);
    expect(h.logs.join('\n'), contains('MINESYNC_WEB'));
  });
}
