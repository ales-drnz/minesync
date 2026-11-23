// Retention automatica e GC dei blob (regole RET e GC).
import 'dart:io';
import 'dart:typed_data';

import 'package:minesync_hub/minesync_hub.dart';
import 'package:ms_core/ms_core.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late TestHub t;
  late String space;

  Future<void> boot({DateTime? start, StoreOptions? options}) async {
    t = await TestHub.start(clock: FakeClock(start), options: options);
    space = await t.createSpace('World A');
  }

  tearDown(() => t.close());

  String hashOf(List<int> b) => sha256Hex(Uint8List.fromList(b));
  bool stored(List<int> b) => t.store.blobs.has(hashOf(b));
  Future<List<int>> history() async {
    final r = await t.get('/spaces/$space/generations?limit=500');
    return [for (final g in r.obj['generations']! as List) (g as Map)['n'] as int];
  }

  Future<void> history0(int keepLast, {int keepHours = 0, int keepDays = 0}) async {
    final r = await t.req(
      'PATCH',
      '/settings/history',
      as: 'carol',
      body: {'keepLast': keepLast, 'keepHours': keepHours, 'keepDays': keepDays},
    );
    expect(r.status, 200, reason: '$r');
  }

  test('B-RET-01 la retention non cancella mai le generazioni più giovani di 24 h', () async {
    await boot();
    await t.req('PATCH', '/settings/history', as: 'carol', body: {'keepLast': 3});
    final world = noise(5000);
    await t.push(space, {'world/level.dat': world});
    for (var i = 0; i < 30; i++) {
      await t.req('PATCH', '/spaces/$space', as: 'carol', body: {});
      expect((await t.push(space, {'world/level.dat': world})).status, 200);
      t.clock.advance(const Duration(minutes: 5));
    }
    final rep = await t.store.maintenance();
    expect(rep.error, isNull);
    expect(rep.generationsDeleted, 0);
    expect(await history(), hasLength(31));
    expect(stored(world), isTrue);
  });

  test(
    'B-RET-02 oltre 24 h: ultime keepLast più la più recente di ogni giorno per 7 giorni',
    () async {
      final now = DateTime(2026, 6, 15, 12);
      await boot(start: now.subtract(const Duration(days: 20)));
      await t.req('PATCH', '/settings/history', as: 'carol', body: {'keepLast': 2});
      final blobs = <List<int>>[];
      Future<void> gen(int i) async {
        blobs.add(bytes('gen $i'));
        expect((await t.push(space, {'f': blobs.last})).status, 200);
      }

      // 20 g, 20 g, 3 g, 3 g, 2 g, 1 g, adesso, adesso
      await gen(1);
      await gen(2);
      t.clock.advance(const Duration(days: 17));
      await gen(3);
      t.clock.advance(const Duration(minutes: 1));
      await gen(4);
      t.clock.advance(const Duration(days: 1));
      await gen(5);
      t.clock.advance(const Duration(days: 1));
      await gen(6);
      t.clock.setWall(now);
      await gen(7);
      await gen(8);
      final rep = await t.store.maintenance();
      expect(rep.generationsDeleted, 3);
      expect(await history(), [8, 7, 6, 5, 4]);
      expect(stored(blobs[0]), isFalse);
      expect(stored(blobs[2]), isFalse);
      expect(stored(blobs[3]), isTrue);
      // calcolo puro: stessa risposta
      final ts = <int, int>{};
      for (final g in t.store.listSpaces()) {
        expect(g.head!.n, 8);
      }
      ts.addAll({
        1: now.subtract(const Duration(days: 20)).millisecondsSinceEpoch,
        2: now.subtract(const Duration(days: 20)).millisecondsSinceEpoch,
        3: now.subtract(const Duration(days: 3)).millisecondsSinceEpoch,
        4: now.subtract(const Duration(days: 3)).millisecondsSinceEpoch,
        5: now.subtract(const Duration(days: 2)).millisecondsSinceEpoch,
        6: now.subtract(const Duration(days: 1)).millisecondsSinceEpoch,
        7: now.millisecondsSinceEpoch,
        8: now.millisecondsSinceEpoch,
      });
      final s = Settings.defaults().patched('history', {'keepLast': 2});
      expect(HubStore.retained(ts, head: 8, s: s, now: now), {4, 5, 6, 7, 8});
    },
  );

  test(
    'B-RET-03 la retention gira da sola dopo i commit e non blocca heartbeat e commit',
    () async {
      await boot(options: const StoreOptions(maintenanceDelay: Duration(milliseconds: 20)));
      await history0(1);
      final old = bytes('vecchio');
      await t.push(space, {'a': old});
      await t.push(space, {'a': bytes('nuovo')});
      final tok = t.tokens['$space/alice']!;
      // heartbeat e push mentre la manutenzione può girare
      for (var i = 0; i < 5; i++) {
        final hb = await t.req('POST', '/spaces/$space/lock/heartbeat', body: {'token': tok});
        expect(hb.status, 200);
        expect((await t.push(space, {'a': bytes('n$i')})).status, 200);
      }
      await eventually(() => !stored(old));
      await eventually(() => t.hub.events.after(0).any((e) => e.type == 'gc'));
      // l'ultima manutenzione programmata (dopo il commit 7) può essere
      // ancora in corso
      final end = DateTime.now().add(const Duration(seconds: 5));
      while ((await history()).length > 1 && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(await history(), [7]);
    },
  );

  test('B-GC-01 keepLast 2 su 5 generazioni: ne restano 2 e solo i loro blob', () async {
    await boot();
    final bs = [for (var i = 0; i < 5; i++) bytes('blob $i')];
    for (final b in bs) {
      await t.push(space, {'f': b});
    }
    await history0(2);
    final rep = await t.store.maintenance();
    expect(rep.generationsDeleted, 3);
    expect(rep.blobsDeleted, 3);
    expect(await history(), [5, 4]);
    expect([for (final b in bs) stored(b)], [false, false, false, true, true]);
    expect(File('${t.data}/spaces/$space/generations/1.json').existsSync(), isFalse);
  });

  test('B-GC-03 i chunk referenziati non si cancellano mai', () async {
    await boot();
    final c1 = noise(1000, 3), c2 = noise(1000, 4);
    final whole = [...c1, ...c2];
    final tok = await t.lock(space);
    final b = await t.req(
      'POST',
      '/spaces/$space/pushes',
      body: PushBegin(
        parent: 0,
        parentDigest: emptyDigest,
        lockToken: tok,
        manifest: Manifest({
          'r.mca': FileEntry(
            size: 2000,
            h: hashOf(whole),
            chunks: [Chunk(hashOf(c1), 1000), Chunk(hashOf(c2), 1000)],
          ),
        }),
      ).toJson(),
    );
    final pid = b.obj['pushId']! as String;
    await t.req('PUT', '/pushes/$pid/blobs/${hashOf(c1)}', raw: c1);
    await t.req('PUT', '/pushes/$pid/blobs/${hashOf(c2)}', raw: c2);
    expect((await t.req('POST', '/pushes/$pid/commit')).status, 200);
    await t.store.maintenance();
    expect(stored(c1) && stored(c2), isTrue);
  });

  test(
    'B-GC-04 i blob di un push aperto (caricati o deduplicati) sopravvivono a GC e retention',
    () async {
      await boot();
      final old = bytes('dedup');
      await t.push(space, {'a': old});
      await t.push(space, {'a': bytes('altro')});
      final h = await t.head(space);
      final fresh = bytes('appena caricato');
      final b = await t.req(
        'POST',
        '/spaces/$space/pushes',
        body: PushBegin(
          parent: h.n,
          parentDigest: h.digest,
          lockToken: t.tokens['$space/alice']!,
          manifest: manifestOf({'a': old, 'b': fresh}),
        ).toJson(),
      );
      final pid = b.obj['pushId']! as String;
      expect(b.obj['missing'], [hashOf(fresh)]);
      await t.req('PUT', '/pushes/$pid/blobs/${hashOf(fresh)}', raw: fresh);
      await history0(1);
      final rep = await t.store.maintenance();
      expect(rep.generationsDeleted, 1); // la generazione 1, l'unica con "dedup"
      expect(stored(old), isTrue);
      expect(stored(fresh), isTrue);
      expect((await t.req('POST', '/pushes/$pid/commit')).status, 200);
      // anche dopo un riavvio la sessione aperta protegge i suoi blob
      final h2 = await t.head(space);
      final keep = bytes('dopo il riavvio');
      final b2 = await t.req(
        'POST',
        '/spaces/$space/pushes',
        body: PushBegin(
          parent: h2.n,
          parentDigest: h2.digest,
          lockToken: t.tokens['$space/alice']!,
          manifest: manifestOf({'k': keep}),
        ).toJson(),
      );
      final pid2 = b2.obj['pushId']! as String;
      await t.req('PUT', '/pushes/$pid2/blobs/${hashOf(keep)}', raw: keep);
      await t.restart();
      await t.store.maintenance();
      expect(stored(keep), isTrue);
    },
  );

  test('B-GC-05 una generazione illeggibile ferma la GC: non si cancella niente', () async {
    await boot();
    final bs = [for (var i = 0; i < 4; i++) bytes('b$i')];
    for (final b in bs) {
      await t.push(space, {'f': b});
    }
    await history0(1);
    File('${t.data}/spaces/$space/generations/2.json').writeAsStringSync('{rotto');
    final rep = await t.store.maintenance();
    expect(rep.error, contains('generation 2'));
    expect(rep.generationsDeleted, 0);
    expect(rep.blobsDeleted, 0);
    for (final b in bs) {
      expect(stored(b), isTrue);
    }
    expect(File('${t.data}/spaces/$space/generations/1.json').existsSync(), isTrue);
    expect(t.hub.events.after(0).any((e) => e.type == 'gc.error'), isTrue);
  });

  test('B-GC-06 B-GC-07 un push che riusa un blob orfano mentre la GC gira lo tiene', () async {
    await boot();
    // molti orfani per allungare la GC (lista e cancellazione cedono il turno)
    final orphans = [for (var i = 0; i < 1500; i++) bytes('orfano $i')];
    final tok = await t.lock(space);
    final b = await t.req(
      'POST',
      '/spaces/$space/pushes',
      body: PushBegin(
        parent: 0,
        parentDigest: emptyDigest,
        lockToken: tok,
        manifest: manifestOf({for (var i = 0; i < orphans.length; i++) 'o/$i': orphans[i]}),
      ).toJson(),
    );
    final pid = b.obj['pushId']! as String;
    for (final o in orphans) {
      await t.req('PUT', '/pushes/$pid/blobs/${hashOf(o)}', raw: o);
    }
    await t.req('DELETE', '/pushes/$pid');
    // la GC parte; nel frattempo un push riusa l'orfano 0 e committa
    final gc = t.store.maintenance();
    final r = await t.push(space, {'kept': orphans[0], 'new': bytes('nuovo')});
    expect(r.status, 200);
    final rep = await gc;
    expect(rep.error, isNull);
    final head = Generation.fromJson((await t.get('/spaces/$space/generations/head')).json);
    for (final h in head.manifest.blobs) {
      expect(t.store.blobs.has(h), isTrue, reason: 'blob della testa $h');
    }
    // gli altri orfani spariscono (subito o alla GC successiva)
    await t.store.maintenance();
    expect(stored(orphans[1]), isFalse);
    expect(stored(orphans[0]), isTrue);
  });
}
