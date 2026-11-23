// Store dei blob, generazioni e sessioni di push (regole STORE, GEN, PUSH e
// PATH lato hub).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ms_core/ms_core.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late TestHub t;
  late String space;

  setUp(() async {
    t = await TestHub.start();
    space = await t.createSpace('World A');
  });
  tearDown(() => t.close());

  /// Inizia un push e restituisce (pushId, missing).
  Future<(String, List<String>)> begin(Manifest m, {String as = 'alice', String? token}) async {
    final tok = token ?? t.tokens['$space/$as'] ?? await t.lock(space, as: as);
    final h = await t.head(space);
    final r = await t.req(
      'POST',
      '/spaces/$space/pushes',
      as: as,
      body: PushBegin(parent: h.n, parentDigest: h.digest, lockToken: tok, manifest: m).toJson(),
    );
    expect(r.status, 201, reason: '$r');
    return (r.obj['pushId']! as String, (r.obj['missing']! as List<Object?>).cast<String>());
  }

  String hashOf(List<int> b) => sha256Hex(Uint8List.fromList(b));

  group('STORE', () {
    test(
      'B-STORE-01 un blob con hash sbagliato è rifiutato (422 bad_hash) e non resta niente',
      () async {
        final good = bytes('contenuto vero');
        final (id, missing) = await begin(manifestOf({'a.txt': good}));
        final h = missing.single;
        final r = await t.req('PUT', '/pushes/$id/blobs/$h', raw: bytes('contenuto VERO'));
        expect(r.status, 422);
        expect(r.code, 'bad_hash');
        expect(File(t.store.blobs.pathOf(h)).existsSync(), isFalse);
        expect(Directory('${t.data}/tmp').listSync(), isEmpty);
      },
    );

    test(
      'B-STORE-01 byte oltre la dimensione dichiarata: 413 too_large, niente su disco',
      () async {
        final good = bytes('dodici byte!');
        final (id, missing) = await begin(manifestOf({'a.txt': good}));
        final h = missing.single;
        // Content-Length già oltre: rifiutato prima di leggere
        final r = await t.req('PUT', '/pushes/$id/blobs/$h', raw: [...good, 1, 2, 3]);
        expect(r.status, 413);
        expect(r.code, 'too_large');
        // senza Content-Length (chunked): rifiutato al primo byte di troppo
        final r2 = await t.req(
          'PUT',
          '/pushes/$id/blobs/$h',
          stream: Stream.fromIterable([good, bytes('extra')]),
        );
        expect(r2.status, 413);
        expect(t.store.blobs.has(h), isFalse);
        expect(Directory('${t.data}/tmp').listSync(), isEmpty);
        // e un corpo troppo corto è bad_hash
        final r3 = await t.req('PUT', '/pushes/$id/blobs/$h', raw: good.sublist(0, 5));
        expect(r3.code, 'bad_hash');
        // il corpo giusto passa
        final ok = await t.req('PUT', '/pushes/$id/blobs/$h', raw: good);
        expect(ok.status, 201);
        expect(File(t.store.blobs.pathOf(h)).readAsBytesSync(), good);
      },
    );

    test('B-STORE-02 B-STORE-03 upload gzip: verificato sul contenuto decompresso', () async {
      final data = bytes('ripetuto ' * 1000);
      final (id, missing) = await begin(manifestOf({'a.txt': data}));
      final h = missing.single;
      final bad = await t.req(
        'PUT',
        '/pushes/$id/blobs/$h',
        raw: gzip.encode(bytes('altro')),
        headers: {'Content-Encoding': 'gzip'},
      );
      expect(bad.code, 'bad_hash');
      expect(t.store.blobs.has(h), isFalse);
      final ok = await t.req(
        'PUT',
        '/pushes/$id/blobs/$h',
        raw: gzip.encode(data),
        headers: {'Content-Encoding': 'gzip'},
      );
      expect(ok.status, 201);
      // il blob si conserva decompresso: GET restituisce i byte originali
      final g = await t.get('/blobs/$h');
      expect(g.bytes, data);
    });

    test('B-STORE-04 contenuto identico salvato una volta sola: zero blob mancanti', () async {
      final f = {'a.txt': bytes('uno'), 'b.txt': bytes('due')};
      expect((await t.push(space, f)).status, 200);
      final (_, missing) = await begin(manifestOf({...f, 'copia/a.txt': bytes('uno')}));
      expect(missing, isEmpty);
    });

    test('B-STORE-05 B-GEN-13 file a chunk: si chiedono i chunk, mai il blob intero', () async {
      final c1 = noise(300 << 10, 1), c2 = noise(200 << 10, 2);
      final whole = [...c1, ...c2];
      final m = Manifest({
        'world/r.0.0.mca': FileEntry(
          size: whole.length,
          h: hashOf(whole),
          chunks: [Chunk(hashOf(c1), c1.length), Chunk(hashOf(c2), c2.length)],
        ),
      });
      final (id, missing) = await begin(m);
      expect(missing.toSet(), {hashOf(c1), hashOf(c2)});
      expect(missing, isNot(contains(hashOf(whole))));
      // B-PUSH-02: commit rifiutato con un chunk mancante
      await t.req('PUT', '/pushes/$id/blobs/${hashOf(c1)}', raw: c1);
      final early = await t.req('POST', '/pushes/$id/commit');
      expect(early.code, 'push_incomplete');
      expect(early.details['missing'], [hashOf(c2)]);
      await t.req('PUT', '/pushes/$id/blobs/${hashOf(c2)}', raw: c2);
      final c = await t.req('POST', '/pushes/$id/commit');
      expect(c.status, 200);
      // riassemblando i chunk si ottiene l'hash del file intero
      final g = await t.get('/spaces/$space/generations/1');
      final e = Generation.fromJson(g.json).manifest['world/r.0.0.mca']!;
      final out = <int>[];
      for (final ch in e.chunks!) {
        out.addAll((await t.get('/blobs/${ch.h}')).bytes);
      }
      expect(hashOf(out), e.h);
      // restore di una generazione a chunk
      await t.push(space, {'x': bytes('y')});
      await t.req('DELETE', '/spaces/$space/lock', body: {'token': t.tokens['$space/alice']});
      final r = await t.req('POST', '/spaces/$space/restore', as: 'carol', body: {'generation': 1});
      expect(r.status, 201);
      final hd = Generation.fromJson((await t.get('/spaces/$space/generations/head')).json);
      expect(hd.manifest['world/r.0.0.mca'], e);
    });

    test('B-STORE-06 somma dei chunk diversa dalla dimensione: begin rifiutato', () async {
      final tok = await t.lock(space);
      final r = await t.req(
        'POST',
        '/spaces/$space/pushes',
        body: {
          'parent': 0,
          'parentDigest': emptyDigest,
          'lockToken': tok,
          'manifest': {
            'a': {
              'size': 10,
              'h': hashOf([1]),
              'chunks': [
                {
                  'h': hashOf([2]),
                  'size': 4,
                },
              ],
            },
          },
        },
      );
      expect(r.status, 400);
      expect(r.code, 'bad_request');
    });

    test('G-10 hash dei blob: solo 64 caratteri esadecimali minuscoli', () async {
      for (final h in ['abc', 'A' * 64, '..%2F..%2Fsettings.json', '${'a' * 63}g']) {
        final r = await t.get('/blobs/$h');
        expect(r.status, 400, reason: h);
        expect(r.code, 'bad_request');
      }
      final (id, _) = await begin(manifestOf({'a': bytes('a')}));
      final r = await t.req('PUT', '/pushes/$id/blobs/${'F' * 64}', raw: [1]);
      expect(r.status, 400);
      expect((await t.get('/blobs/${'0' * 64}')).code, 'not_found');
    });

    test('GET dei blob con Range (intervallo, suffisso, 416)', () async {
      final data = noise(1000);
      await t.push(space, {'a': data});
      final h = hashOf(data);
      Future<Res> range(String v) async {
        final r = await t.client('alice').getUrl(t.uri('/blobs/$h'));
        r.headers.set('Range', v);
        final res = await r.close();
        final b = <int>[];
        await for (final c in res) {
          b.addAll(c);
        }
        return Res(res.statusCode, res.headers, Uint8List.fromList(b));
      }

      final a = await range('bytes=10-19');
      expect(a.status, 206);
      expect(a.bytes, data.sublist(10, 20));
      expect(a.headers.value('content-range'), 'bytes 10-19/1000');
      expect((await range('bytes=-5')).bytes, data.sublist(995));
      expect((await range('bytes=990-')).bytes, data.sublist(990));
      expect((await range('bytes=2000-')).status, 416);
    });
  });

  group('GEN', () {
    test(
      'B-GEN-01 B-GEN-02 prima generazione 1, statistiche rispetto al padre, storia leggibile',
      () async {
        final r1 = await t.push(space, {'a': bytes('1'), 'b': bytes('2'), 'c': bytes('3')});
        expect(r1.obj['n'], 1);
        expect(r1.obj['stats'], {'files': 3, 'size': 3, 'added': 3, 'changed': 0, 'removed': 0});
        final r2 = await t.push(space, {'a': bytes('1'), 'b': bytes('due'), 'd': bytes('4')});
        expect(r2.obj['n'], 2);
        expect(r2.obj['parent'], 1);
        expect(r2.obj['stats'], {'files': 3, 'size': 5, 'added': 1, 'changed': 1, 'removed': 1});
        final g1 = Generation.fromJson((await t.get('/spaces/$space/generations/1')).json);
        expect(g1.manifest.files.keys, ['a', 'b', 'c']);
      },
    );

    test('B-GEN-03 B-GEN-07 compare-and-swap su parent e parentDigest (stale_base)', () async {
      await t.push(space, {'a': bytes('1')});
      final h = await t.head(space);
      final tok = t.tokens['$space/alice']!;
      Future<Res> beginWith(int parent, String digest) => t.req(
        'POST',
        '/spaces/$space/pushes',
        body: PushBegin(
          parent: parent,
          parentDigest: digest,
          lockToken: tok,
          manifest: manifestOf({'b': bytes('2')}),
        ).toJson(),
      );
      // padre vecchio
      final old = await beginWith(0, emptyDigest);
      expect(old.status, 409);
      expect(old.code, 'stale_base');
      // stesso numero, storia diversa
      final diff = await beginWith(1, emptyDigest);
      expect(diff.code, 'stale_base');
      expect(diff.obj['error'], containsPair('message', contains('generation 1')));
      // un padre che sull'hub non esiste
      expect((await beginWith(7, h.digest)).code, 'stale_base');
      // quello giusto
      expect((await beginWith(1, h.digest)).status, 201);
      // spazio vuoto: parent 0 con il digest vuoto
      final other = await t.createSpace('Other');
      final tok2 = await t.lock(other);
      final e = await t.req(
        'POST',
        '/spaces/$other/pushes',
        body: PushBegin(
          parent: 0,
          parentDigest: emptyDigest,
          lockToken: tok2,
          manifest: Manifest.empty,
        ).toJson(),
      );
      expect(e.status, 201);
    });

    test(
      'B-GEN-04 B-GEN-05 B-GEN-09 digest canonico, uguale in commit, generazione e storia',
      () async {
        final g0 = await t.get('/spaces/$space/generations/0');
        expect(g0.obj['digest'], emptyDigest);
        expect(g0.obj['digest'], matches(RegExp(r'^[0-9a-f]{64}$')));
        final c = await t.push(space, {'a&b': bytes('x'), 'b': bytes('y')});
        final d = c.obj['digest'];
        final g = await t.get('/spaces/$space/generations/1');
        expect(g.obj['digest'], d);
        final hist = await t.get('/spaces/$space/generations');
        expect(((hist.obj['generations']! as List).first as Map)['digest'], d);
        // il digest non dipende dall'ordine di inserimento e il percorso resta letterale
        final m1 = manifestOf({'a&b': bytes('x'), 'b': bytes('y')});
        final m2 = manifestOf({'b': bytes('y'), 'a&b': bytes('x')});
        expect(m1.digest(), m2.digest());
        expect(m1.digest(), d);
        expect(utf8.decode(m1.canonicalBytes()), contains('"a&b"'));
      },
    );

    test('B-GEN-10 il restore crea una nuova generazione uguale a quella vecchia', () async {
      await t.push(space, {'a': bytes('1')});
      await t.push(space, {'a': bytes('2')});
      await t.req('DELETE', '/spaces/$space/lock', body: {'token': t.tokens['$space/alice']});
      final r = await t.req('POST', '/spaces/$space/restore', as: 'carol', body: {'generation': 1});
      expect(r.status, 201);
      expect(r.obj['n'], 3);
      expect(r.obj['kind'], 'restore');
      expect(r.obj['restoredFrom'], 1);
      final g1 = await t.get('/spaces/$space/generations/1');
      final g3 = await t.get('/spaces/$space/generations/3');
      expect(g3.obj['manifest'], g1.obj['manifest']);
      expect(g3.obj['digest'], g1.obj['digest']);
      // la storia non è stata riscritta
      expect((await t.get('/spaces/$space/generations/2')).status, 200);
    });

    test(
      'B-GEN-14 restore rifiutato con un lock vivo di un altro (protocol.md: non il proprio)',
      () async {
        await t.push(space, {'a': bytes('1')});
        final r = await t.req(
          'POST',
          '/spaces/$space/restore',
          as: 'carol',
          body: {'generation': 1},
        );
        expect(r.status, 409);
        expect(r.code, 'locked');
        // l'admin che tiene il lock può ripristinare
        await t.req('DELETE', '/spaces/$space/lock', body: {'token': t.tokens['$space/alice']});
        await t.lock(space, as: 'carol');
        final ok = await t.req(
          'POST',
          '/spaces/$space/restore',
          as: 'carol',
          body: {'generation': 0},
        );
        expect(ok.status, 201);
        expect(ok.obj['stats'], containsPair('files', 0));
      },
    );

    test('B-GEN-17 generazione inesistente: 404 con messaggio', () async {
      final r = await t.get('/spaces/$space/generations/99');
      expect(r.status, 404);
      expect(r.code, 'not_found');
      expect(r.obj['error'], containsPair('message', 'generation 99: not found'));
      expect((await t.get('/spaces/nope/generations/head')).code, 'not_found');
    });

    test('storia a pagine, dalla più recente', () async {
      for (var i = 0; i < 7; i++) {
        await t.push(space, {'a': bytes('$i')});
      }
      final p1 = await t.get('/spaces/$space/generations?limit=3');
      final ns1 = [for (final g in p1.obj['generations']! as List) (g as Map)['n']];
      expect(ns1, [7, 6, 5]);
      expect(p1.obj['next'], 5);
      final p2 = await t.get('/spaces/$space/generations?limit=3&before=5');
      expect([for (final g in p2.obj['generations']! as List) (g as Map)['n']], [4, 3, 2]);
      final p3 = await t.get('/spaces/$space/generations?limit=3&before=2');
      expect([for (final g in p3.obj['generations']! as List) (g as Map)['n']], [1]);
      expect(p3.obj['next'], isNull);
      expect((await t.get('/spaces/$space/generations?limit=0')).status, 400);
    });
  });

  group('PUSH', () {
    test('B-PUSH-01 B-PUSH-07 begin, upload, commit; il commit non contiene il manifest', () async {
      final r = await t.push(space, {'a': bytes('x')});
      expect(r.status, 200);
      expect(r.obj['n'], 1);
      expect(r.obj.containsKey('manifest'), isFalse);
      expect(r.obj['replay'], false);
    });

    test(
      'B-PUSH-03 begin senza lock, con un token sbagliato o con il lock di un altro: locked',
      () async {
        final m = manifestOf({'a': bytes('x')}).toJson();
        Future<Res> b(String tok, {String as = 'alice'}) => t.req(
          'POST',
          '/spaces/$space/pushes',
          as: as,
          body: {'parent': 0, 'parentDigest': emptyDigest, 'lockToken': tok, 'manifest': m},
        );
        expect((await b('')).code, 'locked');
        final tok = await t.lock(space, as: 'bob');
        final r = await b('f' * 64);
        expect(r.status, 409);
        expect(r.code, 'locked');
        expect((r.details['lock']! as Map)['name'], 'bob');
        expect((r.details['lock']! as Map).containsKey('token'), isFalse);
        expect((await b(tok, as: 'bob')).status, 201);
      },
    );

    test('B-PUSH-04 un push è legato al lock con cui è iniziato', () async {
      final tok = await t.lock(space);
      final (id, missing) = await begin(manifestOf({'a': bytes('x')}), token: tok);
      await t.req('PUT', '/pushes/$id/blobs/${missing.single}', raw: bytes('x'));
      // il lock scade e lo prende bob
      t.clock.advance(const Duration(seconds: 91));
      await t.lock(space, as: 'bob');
      final c = await t.req('POST', '/pushes/$id/commit');
      expect(c.status, 409);
      expect(c.code, 'lock_lost');
      expect((await t.head(space)).n, 0);
      // rilasciato: stesso esito
      await t.req(
        'DELETE',
        '/spaces/$space/lock',
        as: 'bob',
        body: {'token': t.tokens['$space/bob']},
      );
      final tok2 = await t.lock(space);
      final (id2, _) = await begin(manifestOf({'a': bytes('x')}), token: tok2);
      await t.req('DELETE', '/spaces/$space/lock', body: {'token': tok2});
      expect((await t.req('POST', '/pushes/$id2/commit')).code, 'lock_lost');
      expect((await t.head(space)).n, 0);
    });

    test('B-PUSH-06 B-PUSH-13 commit idempotente; pushId sconosciuto 404', () async {
      final (id, missing) = await begin(manifestOf({'a': bytes('x')}));
      await t.req('PUT', '/pushes/$id/blobs/${missing.single}', raw: bytes('x'));
      final c1 = await t.req('POST', '/pushes/$id/commit');
      final seq = t.hub.events.lastSeq;
      final c2 = await t.req('POST', '/pushes/$id/commit');
      expect(c2.status, 200);
      expect(c2.obj['replay'], true);
      for (final k in ['n', 'ts', 'stats', 'digest']) {
        expect(c2.obj[k], c1.obj[k]);
      }
      expect(t.hub.events.lastSeq, seq, reason: 'nessun nuovo evento');
      expect((await t.head(space)).n, 1);
      expect((await t.req('POST', '/pushes/${'0' * 32}/commit')).status, 404);
      // anche dopo un riavvio
      await t.restart();
      final c3 = await t.req('POST', '/pushes/$id/commit');
      expect(c3.obj['n'], 1);
      expect(c3.obj['replay'], true);
    });

    test(
      'G-09 oltre la finestra di replay (3 h) un commit ripetuto non crea mai una generazione',
      () async {
        final (id, missing) = await begin(manifestOf({'a': bytes('x')}));
        await t.req('PUT', '/pushes/$id/blobs/${missing.single}', raw: bytes('x'));
        expect((await t.req('POST', '/pushes/$id/commit')).status, 200);
        t.clock.advance(const Duration(hours: 3, minutes: 1));
        await t.store.expirePushes();
        expect(File('${t.data}/pushes/$id.json').existsSync(), isFalse);
        final again = await t.req('POST', '/pushes/$id/commit');
        expect(again.status, anyOf(404, 410));
        expect((await t.head(space)).n, 1);
      },
    );

    test('B-PUSH-08 upload a push sconosciuto 404, blob fuori dal manifest rifiutato', () async {
      final r = await t.req('PUT', '/pushes/${'0' * 32}/blobs/${hashOf([1])}', raw: [1]);
      expect(r.status, 404);
      final (id, _) = await begin(manifestOf({'a': bytes('x')}));
      final r2 = await t.req('PUT', '/pushes/$id/blobs/${hashOf([1])}', raw: [1]);
      expect(r2.status, 400);
      // un push di un altro membro non si vede
      final r3 = await t.req('POST', '/pushes/$id/commit', as: 'bob');
      expect(r3.status, 404);
    });

    test('B-PUSH-09 al più 4 sessioni aperte per membro; scadenza per inattività (1 h)', () async {
      final ids = <String>[];
      for (var i = 0; i < 5; i++) {
        ids.add((await begin(manifestOf({'a': bytes('$i')}))).$1);
        t.clock.advance(const Duration(seconds: 1));
      }
      expect(t.store.openPushes, 4);
      expect((await t.req('POST', '/pushes/${ids.first}/commit')).code, 'push_expired');
      // usata di recente: sopravvive anche se creata da ore
      t.clock.advance(const Duration(minutes: 50));
      await t.req('PUT', '/pushes/${ids.last}/blobs/${hashOf(bytes('4'))}', raw: bytes('4'));
      t.clock.advance(const Duration(minutes: 50));
      expect((await t.req('POST', '/pushes/${ids[1]}/commit')).status, 410);
      expect((await t.req('POST', '/pushes/${ids[1]}/commit')).code, 'push_expired');
      // ids.last è stata usata 50 minuti fa: ancora viva; il lock è scaduto ma
      // nessuno l'ha preso, quindi il token vale ancora
      expect((await t.req('POST', '/pushes/${ids.last}/commit')).status, 200);
    });

    test('B-PUSH-10 begin gzip; gzip non valido 400; oltre il limite JSON 413', () async {
      final tok = await t.lock(space);
      final body = utf8.encode(
        jsonEncode(
          PushBegin(
            parent: 0,
            parentDigest: emptyDigest,
            lockToken: tok,
            manifest: manifestOf({'a': bytes('x')}),
          ).toJson(),
        ),
      );
      final ok = await t.req(
        'POST',
        '/spaces/$space/pushes',
        raw: gzip.encode(body),
        headers: {'Content-Encoding': 'gzip', 'Content-Type': 'application/json'},
      );
      expect(ok.status, 201);
      final bad = await t.req(
        'POST',
        '/spaces/$space/pushes',
        raw: [1, 2, 3, 4],
        headers: {'Content-Encoding': 'gzip'},
      );
      expect(bad.status, 400);
      // 80 MiB di spazi compressi: oltre i 64 MiB dopo la decompressione
      final bomb = gzip.encode(Uint8List(80 << 20)..fillRange(0, 80 << 20, 0x20));
      final big = await t.req(
        'POST',
        '/spaces/$space/pushes',
        raw: bomb,
        headers: {'Content-Encoding': 'gzip'},
      );
      expect(big.status, 413);
      expect(big.code, 'too_large');
    });

    test('abort di un push', () async {
      final (id, _) = await begin(manifestOf({'a': bytes('x')}));
      expect((await t.req('DELETE', '/pushes/$id')).status, 200);
      expect(File('${t.data}/pushes/$id.json').existsSync(), isFalse);
      expect((await t.req('POST', '/pushes/$id/commit')).status, 404);
    });

    test('push concorrenti sullo stesso spazio: ne committa uno solo', () async {
      final tok = await t.lock(space);
      final a = await begin(manifestOf({'a': bytes('A')}), token: tok);
      final b = await begin(manifestOf({'b': bytes('B')}), token: tok);
      await t.req('PUT', '/pushes/${a.$1}/blobs/${a.$2.single}', raw: bytes('A'));
      await t.req('PUT', '/pushes/${b.$1}/blobs/${b.$2.single}', raw: bytes('B'));
      final rs = await Future.wait([
        t.req('POST', '/pushes/${a.$1}/commit'),
        t.req('POST', '/pushes/${b.$1}/commit'),
      ]);
      expect(rs.where((r) => r.status == 200), hasLength(1));
      expect(rs.where((r) => r.code == 'stale_base'), hasLength(1));
      expect((await t.head(space)).n, 1);
      // due membri: chi non ha il lock non inizia nemmeno
      final other = await t.createSpace('Race');
      final locks = await Future.wait([
        t.req('POST', '/spaces/$other/lock', body: {}),
        t.req('POST', '/spaces/$other/lock', as: 'bob', body: {}),
      ]);
      expect(locks.where((r) => r.status == 200), hasLength(1));
      expect(locks.where((r) => r.code == 'locked'), hasLength(1));
    });

    test('il tipo restore è riservato all\'endpoint di restore', () async {
      final tok = await t.lock(space);
      final r = await t.req(
        'POST',
        '/spaces/$space/pushes',
        body: {
          ...PushBegin(
            parent: 0,
            parentDigest: emptyDigest,
            lockToken: tok,
            manifest: Manifest.empty,
          ).toJson(),
          'kind': 'restore',
        },
      );
      expect(r.status, 400);
    });
  });

  group('PATH', () {
    Future<Res> beginRaw(Map<String, Object?> manifest) async {
      final tok = t.tokens['$space/alice'] ?? await t.lock(space);
      return t.req(
        'POST',
        '/spaces/$space/pushes',
        body: {'parent': 0, 'parentDigest': emptyDigest, 'lockToken': tok, 'manifest': manifest},
      );
    }

    Map<String, Object?> entry() => {
      'size': 1,
      'h': hashOf([1]),
    };

    test(
      'B-PATH-01 B-PATH-02 B-PATH-04 percorsi non validi: 400 bad_path con il percorso',
      () async {
        for (final p in [
          '../x',
          'a/../b',
          '/x',
          r'a\b',
          '',
          'a:b',
          'a<b',
          'a|b',
          'a?b',
          'a*b',
          'a"b',
          'x\u0001y',
          'con',
          'NUL.txt',
          'dir/aux.tar.gz',
          'COM1',
          'lpt9.log',
          'dot.',
          'space ',
          '.minesync/base.json',
        ]) {
          final r = await beginRaw({p: entry()});
          expect(r.status, 400, reason: p);
          expect(r.code, 'bad_path', reason: p);
          expect(r.details['path'], p);
          expect((r.obj['error']! as Map)['message'], contains(p));
        }
        for (final p in ['COM0', 'LPT10.txt', 'CONx', 'console.log', 'config/a b.txt']) {
          final r = await beginRaw({p: entry()});
          expect(r.status, 201, reason: p);
        }
      },
    );

    test('B-PATH-03 collisioni di maiuscole: bad_path sul secondo in ordine', () async {
      final r = await beginRaw({'World/a': entry(), 'world/a': entry()});
      expect(r.code, 'bad_path');
      expect(r.details['path'], 'world/a');
    });
  });
}
