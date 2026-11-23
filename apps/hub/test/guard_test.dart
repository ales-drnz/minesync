// Guardie dell'hub: cancellazione di massa e disco pieno (regole GUARD lato
// hub) e impostazioni applicate subito.
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

  Map<String, List<int>> keepFirst(Map<String, List<int>> m, int n) =>
      Map.fromEntries(m.entries.take(n));

  group('mass delete', () {
    test('B-GUARD-01 togliere più di metà dei file è rifiutato; esattamente metà no', () async {
      final all = manyFiles(30);
      expect((await t.push(space, all)).status, 200);
      final r = await t.push(space, keepFirst(all, 10));
      expect(r.status, 409);
      expect(r.code, 'mass_delete');
      expect(r.details, {'removed': 20, 'total': 30});
      expect((await t.push(space, keepFirst(all, 15))).status, 200);
    });

    test('B-GUARD-02 la guardia vale solo da 20 file in su', () async {
      expect((await t.push(space, manyFiles(10))).status, 200);
      expect((await t.push(space, {})).status, 200);
      expect((await t.push(space, manyFiles(19))).status, 200);
      expect((await t.push(space, {})).status, 200);
    });

    test(
      'B-GUARD-03 confirmMassDelete (protocol.md, al posto di ?allowMassDelete): admin sì, membro 403',
      () async {
        await t.push(space, manyFiles(30));
        final m = await t.push(space, {}, confirmMassDelete: true);
        expect(m.status, 403);
        expect(m.code, 'forbidden');
        await t.req('DELETE', '/spaces/$space/lock', body: {'token': t.tokens['$space/alice']});
        final a = await t.push(space, {}, as: 'carol', confirmMassDelete: true);
        expect(a.status, 200);
        expect(a.obj['stats'], containsPair('removed', 30));
      },
    );

    test('soglie dalle impostazioni e dagli override dello spazio, applicate subito', () async {
      await t.push(space, manyFiles(10));
      final s = await t.req(
        'PATCH',
        '/settings/protection',
        as: 'carol',
        body: {'massDeleteMinFiles': 5, 'massDeleteRatio': 0.2},
      );
      expect(s.status, 200);
      expect((await t.push(space, manyFiles(7))).code, 'mass_delete');
      await t.req(
        'PATCH',
        '/spaces/$space',
        as: 'carol',
        body: {
          'overrides': {
            'protection': {'massDeleteRatio': 1.0},
          },
        },
      );
      expect((await t.push(space, manyFiles(7))).status, 200);
    });
  });

  group('disk', () {
    test(
      'B-GUARD-09 soglia predefinita max(1 GiB, 2 %); sotto: lock, begin, upload e restore rifiutati',
      () async {
        expect(defaultMinFree(10 << 30), 1 << 30);
        expect(defaultMinFree(1000 << 30), (1000 << 30) ~/ 50);
        final tok = await t.lock(space);
        await t.push(space, {'a': bytes('1')});
        final h = await t.head(space);
        final b = await t.req(
          'POST',
          '/spaces/$space/pushes',
          body: PushBegin(
            parent: h.n,
            parentDigest: h.digest,
            lockToken: tok,
            manifest: manifestOf({'a': bytes('1'), 'b': bytes('2')}),
          ).toJson(),
        );
        final pid = b.obj['pushId']! as String;
        t.disk
          ..total = 100 << 30
          ..free = (2 << 30) - 1; // 2 % di 100 GiB = 2 GiB
        final begin = await t.req(
          'POST',
          '/spaces/$space/pushes',
          body: PushBegin(
            parent: h.n,
            parentDigest: h.digest,
            lockToken: tok,
            manifest: manifestOf({'c': bytes('3')}),
          ).toJson(),
        );
        expect(begin.code, 'disk_full');
        final up = await t.req(
          'PUT',
          '/pushes/$pid/blobs/${(b.obj['missing']! as List).single}',
          raw: bytes('2'),
        );
        expect(up.code, 'disk_full');
        expect((await t.req('POST', '/spaces/$space/lock', as: 'bob', body: {})).code, 'disk_full');
        await t.req('DELETE', '/spaces/$space/lock', body: {'token': tok});
        final rs = await t.req(
          'POST',
          '/spaces/$space/restore',
          as: 'carol',
          body: {'generation': 0},
        );
        expect(rs.code, 'disk_full');
        // con spazio sufficiente si riparte
        t.disk.free = 2 << 30;
        expect((await t.req('POST', '/spaces/$space/lock', as: 'bob', body: {})).status, 200);
      },
    );

    test('B-GUARD-09 dimensioni: 5GiB, 500MB, 1024, 1.5 GiB; senza numero errore', () {
      expect(parseBytes('5GiB'), 5 << 30);
      expect(parseBytes('500MB'), 500000000);
      expect(parseBytes('1024'), 1024);
      expect(parseBytes('1.5 GiB'), (1.5 * (1 << 30)).round());
      expect(() => parseBytes('GiB'), throwsFormatException);
      expect(() => parseBytes('5 parsec'), throwsFormatException);
      final c = HubConfig.fromEnv({'MINESYNC_MIN_FREE': '5GiB'});
      expect(c.minFree, 5 << 30);
    });

    test(
      'B-GUARD-10 disco pieno: 507 disk_full con messaggio, un solo evento disk all\'ora, /hub espone il disco',
      () async {
        t.disk.free = 1 << 20;
        final r1 = await t.req('POST', '/spaces/$space/lock', body: {});
        expect(r1.status, 507);
        expect(r1.code, 'disk_full');
        expect((r1.obj['error']! as Map)['message'], contains('full'));
        await t.req('POST', '/spaces/$space/lock', body: {});
        expect(t.hub.events.after(0).where((e) => e.type == 'disk'), hasLength(1));
        t.clock.advance(const Duration(minutes: 61));
        await t.req('POST', '/spaces/$space/lock', body: {});
        expect(t.hub.events.after(0).where((e) => e.type == 'disk'), hasLength(2));
        final hub = HubInfo.fromJson((await t.get('/hub')).json);
        expect(hub.disk.free, 1 << 20);
        expect(hub.disk.total, t.disk.total);
        expect(hub.disk.minFree, defaultMinFree(t.disk.total));
      },
    );

    test('la soglia delle impostazioni vince sul default', () async {
      t.disk.free = 5 << 30; // sopra il default (2 % di 200 GiB = 4 GiB)
      expect((await t.req('POST', '/spaces/$space/lock', body: {})).status, 200);
      await t.req('PATCH', '/settings/disk', as: 'carol', body: {'minFreeGiB': 6});
      expect((await t.req('POST', '/spaces/$space/lock', as: 'bob', body: {})).code, 'disk_full');
    });

    test('provvisoria: systemDiskProbe legge il volume dei dati su Linux', () {
      final u = systemDiskProbe(Directory.systemTemp.path);
      if (!Platform.isLinux) return;
      expect(u, isNotNull);
      expect(u!.total, greaterThan(0));
      expect(u.free, inInclusiveRange(0, u.total));
    });
  });
}
