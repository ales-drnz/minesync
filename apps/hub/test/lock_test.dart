// Lock, ciclo di vita degli spazi ed eventi (regole LOCK, SPACE, EVENTS,
// G-08, G-20, G-22).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:minesync_hub/minesync_hub.dart';
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

  Future<Res> acquire({String as = 'alice', bool force = false, Map<String, Object?>? info}) =>
      t.req('POST', '/spaces/$space/lock', as: as, body: {'info': ?info, if (force) 'force': true});

  Future<Res> beat(String token, {String as = 'alice', Map<String, Object?>? info}) =>
      t.req('POST', '/spaces/$space/lock/heartbeat', as: as, body: {'token': token, 'info': ?info});

  Future<Res> release({String? token, String as = 'alice', bool force = false}) => t.req(
    'DELETE',
    '/spaces/$space/lock',
    as: as,
    body: {'token': ?token, if (force) 'force': true},
  );

  group('LOCK', () {
    test(
      'B-LOCK-01 lock libero concesso; il secondo riceve locked con il titolare, senza token',
      () async {
        final a = await acquire();
        expect(a.status, 200);
        final g = LockGrant.fromJson(a.json);
        expect(g.token, matches(RegExp(r'^[0-9a-f]{64}$')));
        // G-08: TTL 90 s e heartbeat 20 s restituiti con la concessione
        expect(g.ttlMs, 90000);
        expect(g.heartbeatMs, 20000);
        final b = await acquire(as: 'bob');
        expect(b.status, 409);
        expect(b.code, 'locked');
        final holder = LockHolder.fromJson(b.details['lock']);
        expect(holder.name, 'alice');
        expect(jsonEncode(b.json), isNot(contains(g.token)));
      },
    );

    test(
      'B-LOCK-02 heartbeat e rilascio con il token sbagliato falliscono; quello giusto libera',
      () async {
        final tok = LockGrant.fromJson((await acquire()).json).token;
        expect((await beat('0' * 64)).code, 'lock_lost');
        expect((await release(token: '0' * 64)).code, 'lock_lost');
        expect((await beat(tok)).status, 200);
        expect((await release(token: tok)).status, 200);
        expect((await t.get('/spaces/$space')).obj['lock'], isNull);
        expect(File('${t.data}/spaces/$space/lock.json').existsSync(), isFalse);
      },
    );

    test('B-LOCK-03 lock scaduto: chiunque lo prende, l\'evento dice chi aveva', () async {
      await acquire();
      t.clock.advance(const Duration(seconds: 89));
      expect((await acquire(as: 'bob')).code, 'locked');
      t.clock.advance(const Duration(seconds: 2));
      final s = await t.get('/spaces/$space');
      expect((s.obj['lock']! as Map)['stale'], true);
      final b = await acquire(as: 'bob');
      expect(b.status, 200);
      final e = t.hub.events.after(0).lastWhere((e) => e.type == 'lock');
      expect(e.actor, 'bob');
      expect(e.data['tookOver'], 'alice');
    });

    test('B-LOCK-04 il lock sopravvive a un riavvio dell\'hub', () async {
      final tok = LockGrant.fromJson(
        (await acquire(info: {'client': '0.1.0', 'port': 25565})).json,
      ).token;
      await t.restart();
      final s = await t.get('/spaces/$space');
      final l = LockHolder.fromJson(s.obj['lock']);
      expect(l.name, 'alice');
      expect(l.stale, isFalse);
      expect(l.info.port, 25565);
      expect((await acquire(as: 'bob')).code, 'locked');
      expect((await beat(tok)).status, 200);
      final m = jsonDecode(File('${t.data}/spaces/$space/lock.json').readAsStringSync()) as Map;
      expect(m['token'], tok);
      // 0600: solo il processo dell'hub legge il token
      expect(File('${t.data}/spaces/$space/lock.json').statSync().mode & 0x3f, 0);
    });

    test('B-LOCK-04 un lock che non rispondeva resta così dopo il riavvio', () async {
      final tok = LockGrant.fromJson((await acquire()).json).token;
      final lastBeat = t.clock.wallMs();
      t.clock.advance(const Duration(seconds: 91));
      t.hub.store.checkStaleLocks();
      final file = File('${t.data}/spaces/$space/lock.json');
      for (var i = 0; i < 100 && !file.readAsStringSync().contains('"stale"'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect((jsonDecode(file.readAsStringSync()) as Map)['stale'], true);
      int staleEvents() => t.hub.events.after(0).where((e) => e.type == 'stale').length;
      expect(staleEvents(), 1);
      t.clock.advance(const Duration(hours: 5));
      await t.restart();
      final l = LockHolder.fromJson((await t.get('/spaces/$space')).obj['lock']);
      expect(l.stale, isTrue, reason: 'nessuna nuova grazia per chi taceva già');
      expect(l.lastBeat, lastBeat, reason: 'il silenzio si conta dall\'ultimo battito vero');
      t.hub.store.checkStaleLocks();
      expect(staleEvents(), 1, reason: 'nessun nuovo annuncio');
      expect((await acquire(as: 'bob', info: {'action': 'play'})).status, 200);
      expect((await beat(tok)).code, 'lock_lost');
    });

    test('B-LOCK-04 chi riprende dopo il silenzio torna vivo anche dopo un riavvio', () async {
      final tok = LockGrant.fromJson((await acquire()).json).token;
      t.clock.advance(const Duration(seconds: 91));
      t.hub.store.checkStaleLocks();
      expect((await beat(tok)).status, 200);
      final file = File('${t.data}/spaces/$space/lock.json');
      expect((jsonDecode(file.readAsStringSync()) as Map).containsKey('stale'), isFalse);
      await t.restart();
      final l = LockHolder.fromJson((await t.get('/spaces/$space')).obj['lock']);
      expect(l.stale, isFalse);
      expect((await acquire(as: 'bob')).code, 'locked');
    });

    test('B-LOCK-05 il token è l\'autorità, il nome un\'etichetta', () async {
      final tok = LockGrant.fromJson((await acquire()).json).token;
      t.resolver.byIp[ipOf['alice']!] = const Identity('a1a1a1a1a1', 'alice-renamed');
      final r = await beat(tok);
      expect(r.status, 200);
      expect((r.obj['lock']! as Map)['name'], 'alice-renamed');
      expect((await beat('1' * 64)).code, 'lock_lost');
    });

    test('B-LOCK-06 B-LOCK-07 istanti in millisecondi UTC; scadenza sul tempo monotono', () async {
      final r = await acquire();
      final l = LockHolder.fromJson(r.obj['lock']);
      expect(l.since, t.clock.wallMs());
      // l'ora di sistema torna indietro di un giorno: il lock non scade e non
      // diventa "dal futuro"
      t.clock.setWall(DateTime.fromMillisecondsSinceEpoch(t.clock.wallMs() - 86400000));
      final b = await beat(LockGrant.fromJson(r.json).token);
      final h = LockHolder.fromJson(b.obj['lock']);
      expect(h.stale, isFalse);
      expect(h.lastBeat, t.clock.wallMs());
      t.clock.advance(const Duration(seconds: 60));
      expect(LockHolder.fromJson((await t.get('/spaces/$space')).obj['lock']).stale, isFalse);
    });

    test('B-LOCK-08 B-LOCK-10 lo stato del lock è una copia e si legge senza il mutex', () async {
      final tok = LockGrant.fromJson(
        (await acquire(
          info: {
            'players': ['steve'],
          },
        )).json,
      ).token;
      final snap = t.store.lockSnapshot(space)!;
      snap.info.players.clear();
      expect(t.store.lockSnapshot(space)!.info.players, ['steve']);
      // lockSnapshot è sincrona: non aspetta il mutex dello spazio. Un begin
      // con un manifest grande tiene il mutex mentre scrive la sessione; il
      // heartbeat in parallelo risponde lo stesso.
      final big = {for (var i = 0; i < 20000; i++) 'f/$i.dat': bytes('stesso')};
      final pending = t.push(space, big, token: tok);
      final r = await beat(tok).timeout(const Duration(seconds: 5));
      expect(r.status, 200);
      expect((await pending).status, 200);
      await release(token: tok);
      expect(t.store.lockSnapshot(space), isNull);
    });

    test(
      'B-LOCK-09 forzare il rilascio di un lock vivo è solo admin; uno scaduto chiunque',
      () async {
        await acquire();
        final m = await release(as: 'bob', force: true);
        expect(m.status, 403);
        expect(m.code, 'forbidden');
        final a = await release(as: 'carol', force: true);
        expect(a.status, 200);
        await acquire();
        t.clock.advance(const Duration(seconds: 120));
        expect((await release(as: 'bob', force: true)).status, 200);
      },
    );

    test('forzare l\'acquisizione: admin sì, membro no, il proprio lock sì', () async {
      await acquire();
      expect((await acquire(as: 'bob', force: true)).code, 'forbidden');
      expect((await acquire(force: true)).status, 200);
      final c = await acquire(as: 'carol', force: true);
      expect(c.status, 200);
      expect(t.hub.events.after(0).last.type, 'force');
      expect(t.hub.events.after(0).last.data['from'], 'alice');
    });

    test(
      'B-LOCK-11 heartbeat su uno spazio cancellato: space_gone, diverso da lock_lost',
      () async {
        final tok = LockGrant.fromJson((await acquire()).json).token;
        t.clock.advance(const Duration(seconds: 100));
        expect((await t.req('DELETE', '/spaces/$space', as: 'carol')).status, 200);
        final r = await beat(tok);
        expect(r.status, 404);
        expect(r.code, 'space_gone');
        expect((r.obj['error']! as Map)['message'], isNotEmpty);
      },
    );

    test('heartbeat aggiorna info', () async {
      final tok = LockGrant.fromJson((await acquire()).json).token;
      await beat(
        tok,
        info: {
          'client': '0.1.0',
          'players': ['alex'],
          'port': 25565,
          'address': '192.0.2.10',
        },
      );
      final list = (await t.get('/spaces')).obj['spaces']! as List<Object?>;
      final l = LockHolder.fromJson((list.first! as Map)['lock']);
      expect(l.info.players, ['alex']);
      expect(l.info.address, '192.0.2.10');
    });
  });

  group('SPACE', () {
    test(
      'B-SPACE-01 B-SPACE-02 cancellare con un lock vivo: locked; scaduto: ok, lock sparito',
      () async {
        await acquire();
        final r = await t.req('DELETE', '/spaces/$space', as: 'carol');
        expect(r.status, 409);
        expect(r.code, 'locked');
        t.clock.advance(const Duration(seconds: 91));
        expect((await t.req('DELETE', '/spaces/$space', as: 'carol')).status, 200);
        expect(t.store.lockSnapshot(space), isNull);
        expect((await t.get('/spaces/$space')).code, 'space_gone');
        expect(Directory('${t.data}/spaces/$space').existsSync(), isFalse);
      },
    );

    test('G-22 id dal nome: slug, collisioni, nomi non validi come cartella', () async {
      expect(space, 'world-a');
      expect(await t.createSpace('World A'), 'world-a-2');
      expect(await t.createSpace('  Ünïcode!! Server  '), 'n-code-server');
      expect(await t.createSpace('***'), 'space');
      expect(await t.createSpace('CON'), 'space-con');
      final long = await t.createSpace('x' * 64);
      expect(long.length, lessThanOrEqualTo(48));
      final bad = await t.req('POST', '/spaces', as: 'carol', body: {'name': '   '});
      expect(bad.code, 'bad_request');
      expect(
        (await t.req('POST', '/spaces', as: 'carol', body: {'name': 'x', 'profile': 'zzz'})).status,
        400,
      );
    });

    test(
      'dettagli: esclusioni effettive = profilo + proprie; rinomina e override (admin)',
      () async {
        final p = await t.req(
          'PATCH',
          '/spaces/$space',
          as: 'carol',
          body: {
            'name': 'World B',
            'exclusions': ['mods/cache/**'],
            'overrides': {
              'history': {'keepLast': 5},
            },
          },
        );
        expect(p.status, 200, reason: '$p');
        final d = SpaceDetails.fromJson((await t.get('/spaces/$space')).json);
        expect(d.summary.name, 'World B');
        expect(d.ownExclusions, ['mods/cache/**']);
        expect(d.exclusions, [...minecraftExclusions, 'mods/cache/**']);
        final s = (await t.get('/spaces/$space')).obj['settings']! as Map;
        expect((s['history']! as Map)['keepLast'], 5);
        expect((s['history']! as Map)['keepDays'], 7);
        final bad = await t.req(
          'PATCH',
          '/spaces/$space',
          as: 'carol',
          body: {
            'overrides': {
              'disk': {'minFreeBytes': 1},
            },
          },
        );
        expect(bad.code, 'bad_request');
        final g = await t.createSpace('Files', profile: 'generic');
        expect(
          SpaceDetails.fromJson((await t.get('/spaces/$g')).json).exclusions,
          genericExclusions,
        );
      },
    );

    test('G-07 il profilo minecraft esclude session.lock, log e backup', () async {
      final ex = Exclusions(SpaceDetails.fromJson((await t.get('/spaces/$space')).json).exclusions);
      for (final p in [
        'world/session.lock',
        'logs/latest.log',
        'crash-reports/c.txt',
        'backups/w.zip',
        'world_backup_2024/level.dat',
      ]) {
        expect(ex.excludes(p), isTrue, reason: p);
      }
      expect(ex.excludes('world/level.dat'), isFalse);
      expect(ex.excludes('libraries/x.jar'), isFalse);
    });
  });

  group('EVENTS', () {
    test('B-EVENTS-03 prendere il lock pubblica un evento con il nome del membro', () async {
      await acquire();
      final r = await t.get('/events?after=0');
      final evs = [for (final e in r.obj['events']! as List) HubEvent.fromJson(e)];
      final l = evs.lastWhere((e) => e.type == 'lock');
      expect(l.actor, 'alice');
      expect(l.space, space);
    });

    test('seq crescente anche dopo un riavvio; after filtra', () async {
      await acquire();
      final last = t.hub.events.lastSeq;
      await t.restart();
      await acquire(as: 'bob', force: true).then((_) {});
      await release(as: 'carol', force: true);
      expect(t.hub.events.lastSeq, greaterThan(last));
      final r = await t.get('/events?after=$last');
      final seqs = [for (final e in r.obj['events']! as List) (e as Map)['seq'] as int];
      expect(seqs.first, last + 1);
      for (var i = 1; i < seqs.length; i++) {
        expect(seqs[i], seqs[i - 1] + 1);
      }
      // su disco: JSON lines in sola aggiunta
      final files = Directory('${t.data}/events').listSync().whereType<File>().toList();
      final lines = [for (final f in files) ...f.readAsLinesSync()];
      expect(lines.length, t.hub.events.lastSeq);
    });

    test('G-20 SSE: ordine, keep-alive, ripresa con Last-Event-ID', () async {
      Future<(HttpClientResponse, StreamIterator<String>)> open({String? lastId}) async {
        final r = await t.client('alice').getUrl(t.uri('/events/stream'));
        if (lastId != null) r.headers.set('Last-Event-ID', lastId);
        final res = await r.close();
        final it = StreamIterator(res.transform(utf8.decoder).transform(const LineSplitter()));
        return (res, it);
      }

      final (res, it) = await open();
      expect(res.statusCode, 200);
      expect(res.headers.contentType?.mimeType, 'text/event-stream');
      await eventually(() => t.hub.sseClients == 1);
      final tok = LockGrant.fromJson((await acquire()).json).token;
      await release(token: tok);
      final ids = <int>[];
      var keepAlive = false;
      final types = <String>[];
      while (ids.length < 2 || !keepAlive) {
        expect(await it.moveNext().timeout(const Duration(seconds: 5)), isTrue);
        final l = it.current;
        if (l.startsWith('id: ')) ids.add(int.parse(l.substring(4)));
        if (l.startsWith('event: ')) types.add(l.substring(7));
        if (l == ': ka') keepAlive = true;
      }
      expect(types.take(2), ['lock', 'unlock']);
      expect(ids[1], ids[0] + 1);
      await it.cancel();
      // ripresa: arrivano gli eventi dopo l'ultimo visto
      await acquire(as: 'bob');
      final (_, it2) = await open(lastId: '${ids[0]}');
      final resumed = <int>[];
      while (resumed.length < 2) {
        expect(await it2.moveNext().timeout(const Duration(seconds: 5)), isTrue);
        if (it2.current.startsWith('id: ')) resumed.add(int.parse(it2.current.substring(4)));
      }
      expect(resumed, [ids[0] + 1, ids[0] + 2]);
      await it2.cancel();
    });
  });
}
